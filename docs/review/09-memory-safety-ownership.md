# Review: memory safety, resource lifetimes, and ownership across the boundary

Scope: `sciter_app/*.odin` (all 19 files), `src/prelude.odin`, `docs/rules.md`, plus targeted reads of
`examples/` for lifetime discipline. Everything asserted below about engine behaviour or Odin semantics
was measured with a throwaway probe; the probes are described inline so they can be re-run.
Date: 2026-08-13

## Summary

The rules are right, written down well, and unenforced. `docs/rules.md` states four lifetime contracts
that are — as far as this pass can tell — accurate, and the wrapper follows them in almost every
place. What is missing is any mechanism that makes following them cheaper than not following them: the
whole discipline lives in doc comments, so the compiler cannot help, `grep` cannot help, and the test
suite cannot help. The proof is that the package's own examples break the rules in three places, and
one of those was measured leaking **195 kB per call**.

The single biggest problem is therefore not a bug, it is the absence of enforcement — and Odin has
better tools for this than the package currently uses. `@(deferred_out)` was measured to release a
resource at scope end *even when the caller writes `_, _ =`*, which is exactly the failure the examples
have. `@(require_results)` — the obvious guess, and the attribute the package already uses on three
procs — was measured **not** to catch that form, only a bare call. That distinction decides which
recommendation is worth acting on and is easy to get backwards.

Eight defects follow, then the ownership analysis. Two are `major` and both are latent rather than
firing today. Three areas that looked dangerous were measured clean and are recorded as such, because
"we checked and it is fine" is worth as much here as a finding.

## Findings

### R9-01 — `resize_windowless` leaves `view.pixels` dangling when the engine refuses the resize  [severity: major]

**Where:** `sciter_app/windowless.odin:244-258`
**What:** Both branches that free the old surface do so *before* `SXM_SIZE` is sent, and neither clears
`view.pixels` / `view.owns_pixels`. If `SciterProcX` then answers false, the function returns with
`view.pixels` pointing at freed memory and `view.owns_pixels` still `true`:

```odin
if surface == nil {
    if view.owns_pixels {
        delete(view.pixels, view.allocator)   // freed here
    }
    surface = make([]u8, row * int(height), view.allocator)
    owns = true
} else if ... {
} else if view.owns_pixels {
    delete(view.pixels, view.allocator)       // and here
}
...
if !bool(sciter.api().SciterProcX(rawptr(view.window), &message.header)) {
    if owns {
        delete(surface, view.allocator)
    }
    return .Window_Failed                     // view.pixels still describes the freed block
}
```

**Why it matters:** the caller's natural response to `.Window_Failed` is to tear the view down, and
`destroy_windowless` does `delete(view.pixels, view.allocator)` on a block already freed — a double
free. `windowless_pixel` on the same view reads freed memory and reports whatever now lives there.

**Measured:** I could not force `SXM_SIZE` to fail on this engine, so this path is unexercised rather
than observed. The related *ordering* concern — freeing the surface the engine is currently holding
before handing it the new one — was tested and is **not** a live use-after-free: five successive
resizes of a painted 320x240 view under `-sanitize:address` produced no report, so the engine does not
read the old surface while handling `SXM_SIZE`. It is still an ordering the code does not have to take.

**Fix:** two lines. Set `view.pixels, view.owns_pixels = nil, false` immediately after each `delete`,
and prefer sending `SXM_SIZE` first and freeing the old buffer only once it has succeeded.

### R9-02 — `load_embedded` drops the candidate list `sciter.load` hands it, on every call  [severity: major]

**Where:** `sciter_app/embed.odin:96`
**What:** `if lerr, _ := sciter.load(full); lerr != .None && lerr != .Already_Loaded {`. The discarded
second result is the `tried` slice, which `src/prelude.odin:93-95` documents as *"returned on every
path, success included - each string separately allocated - so the caller owns it and has to free it
either way"*, and which `docs/rules.md:224-226` lists as one of the two cases that have caught people.

**Why it matters:** it leaks the dynamic array's backing plus one heap-allocated string per candidate,
in the caller's allocator, on the success path. It is small and happens once per process, but it is a
leak the bindings report against themselves under any tracking allocator, in the one file whose whole
job is a tidy first-run experience — and `load_engine` twenty files away is the worked example of doing
it correctly.

**Fix:** mirror `load_engine`: bind the list and free it in a `defer`.

### R9-03 — `save_image`'s scratch comes from the caller's allocator, not the temp allocator its comment describes  [severity: major]

**Where:** `sciter_app/graphics.odin:230-233` and `889-897`
**What:** the sink is built as

```odin
sink := Byte_Sink {
    ctx       = context,
    allocator = context.temp_allocator,
}
```

but `image_writer` never reads `sink.allocator` — it does `append(&sink.out, ..data[:n])`, and
`sink.out` is a zero-valued `[dynamic]u8`. **Measured** (isolated Odin probe, tracking allocators on
both slots): a zero-valued dynamic array adopts `context.allocator` at its first append — 1 allocation
in the context allocator, 0 in the temp allocator. `Byte_Sink.allocator` is dead code; `grep sink.allocator
sciter_app/graphics.odin` returns nothing.

**Why it matters:** the doc comment above it explains that growing the scratch in the caller's allocator
"meant peak memory of twice the encoded image - tens of megabytes for a 4K PNG", and describes this
sink as the fix. The fix is not in effect: the doubling still happens in `context.allocator`. The
second half of the old bug is genuinely fixed — `defer delete(sink.out)` now matches the array's own
allocator, so nothing leaks — but the memory characteristic the comment promises is not the one the
code has.

**Fix:** one line — `sink.out.allocator = context.temp_allocator` after construction (or build it with
`make([dynamic]u8, 0, 0, context.temp_allocator)`), and drop the unused field.

### R9-04 — the examples discard reference-owning Values; measured at 195 kB leaked per call  [severity: major]

**Where:** `examples/input.odin:638`, `examples/native_child.odin:227`
**What:** both drop the `Value` an `eval` returned:

```odin
_, serr := sciter_app.eval_element(name, `this.odin_note = "set by Odin"`)   // input.odin:638
_, _ = sciter_app.eval(window, `document.$("#toggle").on("click", ...)`)     // native_child.odin:227
```

**Measured, two probes against the vendored engine through a windowless view:**

- 2000 evals of `"x".repeat(100000)` **without** `value_clear`: RSS grew from 34,844 kB to 425,428 kB,
  a delta of **390,584 kB** — 195 kB per call, which is the 100k-character string at UTF-16 width. The
  same 2000 evals **with** `value_clear`: delta of **76 kB**, i.e. flat. So a dropped string-bearing
  Value leaks the engine's whole allocation, and the discipline in `docs/rules.md` §2 is load-bearing.
- The result type of each script above, read with `value_type`: an assignment expression
  (`globalThis.note = "set by Odin"`, `el.innerHTML = "x"`) evaluates to **`STRING`**, and
  `el.on("click", fn)` evaluates to **`RESOURCE`**. Both own a reference.

**Why it matters:** beyond the two sites, this establishes a rule worth writing down, because the
shape of the script does not tell you: a statement-looking `eval` is *not* safe to discard. `"…; true"`
returns `BOOL` and is free; the `.on(...)` registration next to it is not.

Other `_, _ =` sites were checked and are **not** leaks: `asset_call(asset, "noSuchMethod")`,
`asset_get(asset, "noSuchProperty")`, `value_key_at` on an array and `expando` on a detached element
all fail, and a failed call leaves the out-Value zeroed.

**Fix:** clear both. And see the ownership section — this class is what `@(deferred_out)` or a debug
tracker would catch mechanically, which matters more than the two sites.

### R9-09 — `eval` never reports `.Eval_Failed`, and every failing script leaks a Value  [severity: major]

**Where:** `sciter_app/window.odin:319-328`, and the claim in its doc comment
**What:** found while writing a test for R9-04's fix, and it invalidates the documented failure model.
`eval`'s comment said *"a script error is reported through `set_debug_output` and comes back here as
`.Eval_Failed` - without a debug output handler installed there is nothing else to see"*. Measured on
6.0.4.9, identically in a real window and in a windowless view:

| script | `err` | result type | `value_is_error` | result text |
|---|---|---|---|---|
| `this is not valid (((` | **nil** | STRING | true | `expecting ';'\n    at <eval>:1\n` |
| `throw new Error("boom")` | **nil** | STRING | true | `boom\n    at <script> (<eval>)\n` |
| `noSuchFunction()` | **nil** | STRING | true | `'noSuchFunction' is not defined\n    at <script…` |
| `1+1` | nil | INT | false | `2` |

So `SciterEval` answers TRUE for a failed script and reports the failure *in the result*, as the same
`.ERROR`-unit string `value_parse` uses. `.Eval_Failed` is unreachable for script errors.

**Why it matters:** three things at once, and the third is why it belongs in this review.

1. The documented way to diagnose a failed `eval` does not work — and the real one is *better* than the
   documented one: the message and a stack trace are in the returned Value, with no debug handler
   installed. The header comment sent readers to the one place the answer is not.
2. `value_is_error(&v)` is the actual test for "did this script fail", and nothing said so.
3. **The error string owns a reference like any other Value**, so the natural shape — check `err`,
   drop the result because "it failed, there is nothing in it" — leaks on *every* script error, in the
   one path a program takes when things are already going wrong.

**Fix:** applied. `eval`'s doc comment now states the measured behaviour with the `value_is_error`
recipe; the stale claims in `examples/eval.odin` are corrected; and
`test_a_failing_eval_returns_an_error_string_and_is_still_released` pins it, in the file
`just test_sanitize eval` runs under ASan.

**Follow-up, measured: `call`, `call_function` and `call_method` behave the same way, and the model is
cleaner than "eval is odd".** The four entry points share one failure split, and the two halves never
overlap:

> **the error code answers "could I call it?"; the returned Value answers "did it work?"**

| call | works | throws | name not defined |
|---|---|---|---|
| `call` | `nil`, INT | **`nil`**, error string | `.Call_Failed`, UNDEFINED |
| `call_function` | `nil`, INT | **`nil`**, error string | `.OPERATION_FAILED`, UNDEFINED |
| `call_method` | `nil`, INT | **`nil`**, error string | `.OPERATION_FAILED`, UNDEFINED |
| `eval` | `nil`, INT | **`nil`**, error string | — |

A *lookup* failure is a real error code with an `.UNDEFINED` result that holds no reference and is safe
to drop — which is why the `_, _ = asset_call(…, "noSuchMethod")` sites in the examples are not leaks. A
*script* failure is never in the error code, and its result is a live reference. So on all four, a
caller who checks only `err` both misreads a thrown exception as success and leaks while doing it.

All three doc comments now state this, and
`test_a_script_call_reports_a_throw_in_the_value_and_a_missing_name_in_the_error` pins all six cases.

### R9-10 — over-releasing a borrowed element handle segfaults, and both the type and the return code say it is fine  [severity: major, documentation]

**Where:** `sciter_app/dom.odin:27-33`, and the `Element` type itself
**What:** `use_element` / `unuse_element` are a reference-counting pair, and the package's own header
says an element from `select_*`, `child`, `parent` or an event is **borrowed** — the caller holds no
reference. Giving one back anyway is an under-flow. Measured on 6.0.4.9, against an element selected
with `select_first` and never `use_element`d:

| spurious `unuse_element` calls | result |
|---|---|
| 1 | returns `nil`; the element still reads, re-selects and re-reads fine |
| 2 | returns `nil` **twice**, then the process dies with SIGSEGV |

The engine reports success for every call, including the one that kills it. The fault lands after the
call returns, so there is no return code to check and nothing on the stack pointing at the mistake.

**Why it matters:** the review's other findings are leaks — bounded, diagnosable, survivable. This is the
opposite failure of the same missing distinction, and it is a crash. `Element` is one type for two
regimes, so "hand the reference back" and "hand back a reference you never had" are the same line of
code, and the second is only wrong because of where the handle came from — which the type does not say
and the engine will not tell you.

It is also the asymmetry that decides how much the type-level fix is worth: `scoped_*` and a leak
tracker address forgetting to release, and neither can see an over-release. Only the type can.

**Fix:** documented at `use_element` rather than tested, because the test would be a segfault. The
type-level fix is the `distinct` owned handles discussed below, whose value this measurement raises
considerably.

### R9-05 — `sciter.load` leaks the executable-directory candidate  [severity: minor]

**Where:** `src/prelude.odin:132`
**What:** `add(&candidates, filepath.dir(os.args[0]))`. `filepath.dir` allocates in
`context.allocator`; `add` then clones or joins that string into the candidates allocator and the
original is never freed. Every other input to `add` is either a literal or comes from the temp
allocator.

**Why it matters:** one leaked string per process. Harmless in effect, but it is inside the load path
of a library whose documentation makes a point of the caller owning every allocation it hands back, so
it is the kind of thing a user's tracking allocator reports as "the bindings leak".

**Fix:** `dir := filepath.dir(os.args[0], context.temp_allocator)`.

### R9-06 — the windowless surface is a fifth "the engine keeps your pointer" case, and `rules.md` lists four  [severity: minor]

**Where:** `docs/rules.md:214-220`, against `sciter_app/windowless.odin:219-276`
**What:** the "Never the temp allocator for anything the engine keeps" list names the `init` argv, an
`Asset_Class` passport, an attached handler struct, and the bytes handed to `serve`. A caller-supplied
`pixels` buffer belongs on it: `resize_windowless` puts `raw_data(surface)` into the `SXM_SIZE` message
and the engine draws into it on every subsequent `paint_windowless`, for the life of the view or until
the next resize. The archive blob passed to `open_archive` is a sixth — that one *is* documented, at
the call site (`archive.odin:21-23`), but not in the consolidated list.

**Why it matters:** the list exists precisely because it is the checklist a reader consults, and the
windowless case is the one where a caller is most likely to reach for scratch memory — it looks like a
frame buffer, and frame buffers are per-frame things. A `context.temp_allocator` surface is a
use-after-free at the caller's next `free_all`, with the engine writing into it.

**Fix:** two rows in the table, and a sentence in `create_windowless`'s doc comment.

### R9-07 — `combine_url` abandons each oversized retry buffer in the caller's arena  [severity: minor]

**Where:** `sciter_app/dom.odin:729-742`
**What:** the retry loop does `buf := make([]u16, size, context.temp_allocator)` and, on a suspected
truncation, `size *= 4` and goes round again without freeing the previous buffer.

**Why it matters:** the worst path leaves buffers of `n`, `4n`, `16n` and `64n` units in the caller's
temp arena — about 85x the final answer — for a call the docs recommend running per-request. Not a
correctness bug (the arena is the caller's and `free_all` reclaims it), but this is the package's own
"you own the boundary" contract being spent carelessly by the wrapper.

**Fix:** `defer delete(buf, context.temp_allocator)` inside the loop body, or size the retry from the
NUL scan rather than by quadrupling.

### R9-08 — `select_all` and `sciter.load` return a slice whose backing allocation is larger than its length  [severity: nit]

**Where:** `sciter_app/dom.odin:78`, `src/prelude.odin:154` and `:175`
**What:** both build a `[dynamic]` by appending and hand back `x[:]`. The caller's `delete` then reports
`len * size_of(E)` to the allocator while `cap * size_of(E)` was allocated.

**Measured:** with the default heap allocator and `mem.Tracking_Allocator` this is harmless — a 5-element,
8-capacity dynamic array freed as a 5-element slice produced `bad_free_count = 0` and left nothing in the
allocation map, because those allocators free by pointer and ignore the reported size. So this is not
the bad-free the package's own comment in `string_from_utf16` anticipates ("a bad-free report on a
tracking or size-checked one") — worth knowing, since that comment is the stated reason for an extra
copy on the hottest path in the package.

**Why it matters:** only that the two facts should agree. Either the hazard is real, in which case these
two need to hand back exactly-sized copies, or it is not, in which case `string_from_utf16`'s rationale
should rest on the memory-waste argument alone — which is by itself sufficient and is the more honest
half.

**Fix:** pick one and make the comment and the code say the same thing.

## Three things that looked dangerous and are not

Recorded because the absence of a finding here is itself the useful result.

- **The string receivers do not chunk.** `wide_receiver` and `bytes_receiver` (`dom.odin:896-914`)
  *overwrite* `sink.out` on every call, so a receiver invoked twice would leak the first allocation and
  return only the last fragment. Measured against a 3.8 MB document: `html(el, outer = true)` returned
  3,800,020 bytes and `text(el)` returned 3,100,000 bytes — the whole thing, in one call. The one API in
  this package that *does* chunk is `imageSave`, and that path correctly accumulates into a growing
  buffer.
- **The 4096-byte debug buffer cannot overflow.** `default_debug_output` (`app.odin:206-222`) decodes
  into a fixed `[4096]u8`. `utf16.decode_to_utf8` bounds-checks (`if n >= len(d) { return }` and
  `n += copy(d[n:], b[:w])`), so an over-long diagnostic truncates rather than overflowing. The comment's
  cross-thread claim also holds: `fmt.eprintfln` was measured making **zero** allocations from
  `context.temp_allocator`, so the captured context's per-thread arena is not touched from another thread.
- **`http_request`'s temp-allocator arguments survive an async request.** This was the last unmeasured
  lifetime claim in the package and the one shaped most like a real bug: `events.odin:594-607` builds the
  URL, the `Request_Param` array and both strings of every pair in `context.temp_allocator`, and the
  request is asynchronous, so a caller freeing its arena at the end of the turn would be pulling memory
  out from under an in-flight request. Measured against a local server, for `.Get` and `.Post`: issue,
  `free_all`, overwrite the arena, then pump. A canary allocated next to those buffers reads `0xAA`
  afterwards — so the overwrite really landed — and the server still received
  `?page=2&q=two%20words` and the POST body `page=2&q=two%20words` intact. The engine copies during the
  call. No bug, and the comment now says so with the evidence.
- **The gradient-stop cast is layout-safe.** `set_fill_gradient_*` casts `[]Color_Stop` straight to
  `^sciter.Sc_Color_Stop`. `Color_Stop` is `{Color, f32}`, `Sc_Color_Stop` is `{Sc_Color, f32}` and
  `SC_COLOR_STOP` in `sciter-x-graphics.h:35-39` is `{SC_COLOR color; float offset;}` — all three agree.

Also confirmed fixed since the previous pass: the `som_property_def_t` union was being called through
without reading its tag (R1-01); `asset_get`/`asset_set` now switch on `def.type` and refuse types they
do not know. `graphics_api()` and `request_api()` now assert instead of returning nil (R3-01).

Every `proc "system"` trampoline in the package — 18 of them — restores a captured `runtime.Context`
before doing anything that allocates. The three that do not (`asset_add_ref`, `asset_release`,
`asset_get_interface`) allocate nothing, and `asset_get_passport` only dereferences. That is a clean
sweep and it is the failure mode most likely to produce unexplainable corruption, so it is worth saying.

---

## Ownership across the boundary

### What the reader has to know, and where it is written

There are **nine distinct ownership regimes** in this API. Every one of them is correctly documented,
and not one of them is visible in a type:

| # | what crosses | direction | who releases | how you find out |
|---|---|---|---|---|
| 1 | `Value` out of the engine — `eval`, `call`, `value_at`, `value_get`, `element_value`, `expando`, `asset_get`, `asset_call`, `value_invoke`, `value_parse`, `element_to_value`, `value_from_*` … (~30 procs) | engine → you | you, `value_clear` | doc comment |
| 2 | `Value` in as an argument | you → engine | you, still | doc comment |
| 3 | `Value` returned *from your callback* — `Native_Function`, `Asset_Getter`, `Asset_Call`, `GET_VALUE`'s `args.val` | you → engine | **the engine** | doc comment |
| 4 | `Value` handed *to* your callback — `Value_Visitor` args, `Native_Function` args, `Behavior_Event.data`, `SET_VALUE`'s `args.val` | engine → you, borrowed | nobody; clearing it is a UAF in the caller | doc comment |
| 5 | `Element` from `select_*`, `child`, `parent`, `root`, `element_at`, event params | borrowed | nobody | doc comment |
| 6 | `Element` from `make_element`, `clone_element`, `remove_element(finalize = false)` | engine → you | you, `unuse_element` | doc comment |
| 7 | `Node` from traversal (borrowed) vs `make_text_node` / `make_comment_node` (yours), and `node_insert` transfers to the document | both | depends | doc comment |
| 8 | `Request` — borrowed for the callback, owned after `take_request` / `use_request` | both | you, `unuse_request` | doc comment |
| 9 | `Image` / `Path` / `Text` (owned, `release_*`) vs the `Graphics` from a `.DRAW` event or `paint_image` (borrowed for the call) | both | depends | doc comment |

Plus the strings and slices, which have their own split: `text`, `html`, `attribute`, `value_to_string`,
`atom_name`, `request_url` … allocate into your allocator and are yours to `delete`; `tag`,
`request_method`, `Attribute_Change.name`, `value_to_bytes`, `archive_item`, `Data_Arrived.data` and the
keyboard/cursor strings in the host callbacks are borrowed. Both kinds are spelled `string` or `[]u8`.

So the answer to "is it clear where ownership is handed off" is: **it is clearly *written*, and it is
nowhere *encoded*.** `Value` is one type covering regimes 1 through 4, in which the receiver owes a
clear, owes nothing, gives ownership away, and must not clear — four different contracts, one type. At a
call site there is nothing to read but the name of the procedure, and R9-04 is what that costs.

### The one invariant that *is* mechanically true

Scanning every procedure in the package that returns a `string` or a slice: 22 of them take an
`allocator` parameter, and exactly three do not — `tag`, `request_method` and the private
`behavior_name`. All three are documented borrows. (`value_to_bytes` and `archive_item` are two more
borrows the signature scan's regex missed; both take no allocator, so they follow the same rule.)

That is a genuine law, holding across the whole package by construction:

> **If it takes an allocator, the result is yours. If it does not, it is borrowed.**

It is not stated anywhere as a law — `rules.md` §4 says the allocator is always the last parameter and
that borrowing procs say so in prose, which is the same information in a weaker form. Promoting it to
a rule costs a sentence, and it is checkable by a script in CI, which is this project's established
pattern for keeping a claim true (`just api-map-verify` and friends). That is the cheapest ownership
win available and it is already 100% earned.

### What Odin can actually enforce — measured, because the obvious answer is wrong

**`@(require_results)` does not solve this.** The package already uses it on three procs, and it is the
natural thing to reach for. Measured on a two-result `proc(...) -> (Value, Error)`:

| call form | `@(require_results)` |
|---|---|
| `producer()` — bare call | **error**: "requires that its results must be handled" |
| `_, _ = producer()` | **compiles silently** |
| `_, err := producer()` | compiles (correctly — the error *is* handled) |

`_, _ =` is precisely the form in `examples/native_child.odin:227`. So the attribute would not have
caught R9-04, and adding it to 30 Value-returning procs buys almost nothing. Worth knowing before
spending an afternoon on it.

**`@(deferred_out)` does.** Measured: a proc marked `@(deferred_out = cleanup)` has *all* of its results
passed to `cleanup` at the end of the calling scope, in reverse order, **including when the caller wrote
`_, _ =`**. That is real enforcement, from the language, with no runtime cost and no discipline required.

Four options, ranked by value against cost.

**1. A `scoped_*` family built on `@(deferred_out)` — cheap, additive, enforces at compile time.**

```odin
@(deferred_out = clear_result)
scoped_eval :: proc(window: Window, script: string) -> (result: Value, err: Error) {
    return eval(window, script)
}

@(private)
clear_result :: proc(v: Value, err: Error) {
    v := v
    value_clear(&v)
}
```

The caller writes `v, err := sciter_app.scoped_eval(w, script)`, uses `v` inside the scope, and cannot
leak it — the drop is the language's job. That covers the overwhelmingly common case (read a value, use
it here, done) while plain `eval` stays available for the value that has to outlive the scope. The same
shape applies to `scoped_select_all`, `scoped_make_element`, `scoped_text`. It adds procedures rather
than changing any, so nothing existing breaks.

**Measured against this package, not in the abstract.** The code above compiles as written and was run
against the vendored engine through a windowless view. 2000 iterations of the exact leaking shape from
R9-04 — `_, _ = scoped_eval(view.window, `"x".repeat(100000)`)`, both results discarded — grew RSS by
**76 kB**, identical to the hand-cleared baseline and against **390,584 kB** for the same loop through
plain `eval`. The deferred release fires on the discarding call form, which is the one form
`@(require_results)` cannot see. **This is the recommendation.**

**2. A debug-build Value tracker, modelled on `mem.Tracking_Allocator` — catches what escapes anyway.**

Every producer bumps a counter and records `#caller_location`; `value_clear` decrements; a
`value_tracker_report()` at shutdown or at a scope boundary names the sites that still owe a clear. All
of it inside `when ODIN_DEBUG`, so release builds pay nothing. Odin users already know this ergonomic
exactly — it is how they find leaks in their own allocators — and it would have found R9-04 in the
existing test suite without anyone thinking about it. It also covers what `scoped_*` cannot: Values that
genuinely outlive their scope. Cost: one counter, one map, one line in each of ~30 producers.

**3. `distinct` types for owned handles — the only option that can stop an over-release.**

```odin
Owned_Element :: distinct Element    // from make_element / clone_element / remove_element(false)
```

Be precise about what this does and does not buy. Odin has no linear types and no destructors, so
dropping an `Owned_Element` is still legal and still leaks — this is **not** a leak fix, and options 1
and 2 remain the leak story. What it buys is the other direction, and R9-10 is what makes that worth
paying for: `unuse_element` would take an `Owned_Element` and nothing else, so handing back a reference
you never held stops being expressible. Today that is a two-call segfault the engine reports as `.OK`
twice, and it is the one failure in this review that neither a scope nor a tracker can see.

Secondary benefits: `insert_element(owned, parent)` needs a visible conversion, so the transfer is
legible at the call site; a struct field's type says which regime it stores; and `select_all`'s slice
being `[]Element` rather than `[]Owned_Element` states the borrow that its doc comment currently has to.

The cost is real and should not be hidden: Odin does not implicitly convert `distinct` types, so every
read of a created element — `set_text(item, …)`, `insert_element(item, list)` — needs a conversion at
the call site. Roughly sixty procedures take an `Element`, and making them all polymorphic over both
regimes would double the surface, which is worse than the disease.

The precedent for it is already in the tree and is the best argument for the shape: `graphics.odin`
*already* does this. `Image`, `Path` and `Text` are owned and have `release_*`; `Graphics`, which
arrives borrowed from a `.DRAW` event or `paint_image`, is a **different type**, so
`release_graphics(gfx_from_an_event)` is not a mistake anyone can make by accident. The suggestion is
only to extend a pattern this package already found for itself.

**Where to apply it first: `Request`, not `Element`.** It is the same borrowed/taken split with a
twentieth of the surface, the taking is already an explicit call (`take_request`), and the docs already
say "every `take_request` owes an `unuse_request`".

**Done — and the hazard is worse here than for elements.** Measured before building it, because the
whole case rests on the under-flow being real: inside `on_load_data`, **one** spurious `unuse_request`
on a handle from `request_of` answers `.OK` and then segfaults the process a request or two later. Not
two calls as with elements — one. Every call reports success.

The shape now shipped:

```odin
Request       :: distinct sciter.Hrequest   // borrowed: valid for the callback
Owned_Request :: distinct Request           // taken: owes an unuse_request

take_request   :: proc(^Load_Request) -> (Owned_Request, Load_Result)
use_request    :: proc(Request) -> (Owned_Request, Error)
unuse_request  :: proc(Owned_Request) -> Error       // a borrowed handle does not compile
borrow_request :: proc(Owned_Request) -> Request     // free cast, marks each crossing
```

**What the migration actually cost**, since the review's own objection to this pattern was call-site
noise: two struct fields changed type, three answering calls gained a `borrow_request`, one test's local
gained one, and `use_request`'s extra result changed one assertion. That is it, across the example, the
snippets and `docs/api.md`. The twelve compiler errors that looked like the worst of it all came from a
*single* local — `rq := g_probe.deferred` — and were fixed by borrowing once at the top of the scope,
which is the idiom to teach: **borrow once at the boundary, then use it as an ordinary handle.** The
friction is per-scope, not per-call, which is materially better than this review estimated.

`Element` is still an API version's worth of change and should follow. But the estimate that made it
look expensive was measured here and came in low, which is worth knowing before pricing that one.

**4. A `Value_Scope` batch, matching `rules.md`'s existing arena advice — best fit for handlers.**

`rules.md` §4 already tells the reader to give a batch of allocations its own arena and free the lot at
one `defer`. The natural completion is the same move for engine references:

```odin
scope: sciter_app.Value_Scope
defer sciter_app.scope_release(&scope)          // clears every Value tracked below

rows  := sciter_app.scope_add(&scope, sciter_app.eval(w, "getRows()"))
first := sciter_app.scope_add(&scope, sciter_app.value_at(&rows, 0))
```

One `defer` then covers both halves of a handler's lifetime — the arena for Odin memory, the scope for
engine references — which is the mental model the docs already teach, extended to the resource the docs
say is "the thing most likely to leak". This composes with option 1 rather than competing: `scoped_*`
for the single value, a scope for the batch.

### What to do first

1. Fix R9-01 through R9-04 — four small, local edits, one of them a measured 195 kB-per-call leak.
2. Write the allocator invariant down as a fifth rule and add the script that checks it. It is already
   true; the only work is making it stay true.
3. Add `scoped_eval` and friends (option 1) and the debug tracker (option 2). Between them they turn the
   `Value` contract from something a reader must remember into something the build and the tests check.
4. Leave `distinct` owned handles (option 3) until after the above, and treat it as an API version's
   worth of change rather than an addition.

Nothing in this file changes any source, doc or config file outside `docs/review/`.
