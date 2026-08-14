# Review: Value marshalling, SOM, atoms, archive, embed

Scope: `sciter_app/value.odin`, `sciter_app/som.odin`, `sciter_app/atom.odin`, `sciter_app/archive.odin`,
`sciter_app/embed.odin`, `sciter_app/app.odin`, `sciter_app/sciter_app.odin`, `src/prelude.odin`,
headers `value.h`, `sciter-om-def.h`, `sciter-x-api.h`.
Date: 2026-08-13

## Summary

This is the strongest-documented layer in the project. Ownership rules are stated at the top of
`value.odin` and repeated per proc; the measured-behaviour notes (`value_isolate` not working,
`value_to_int` reading zero for `.BIG_INT`, atoms not round-tripping non-ASCII) are the kind of thing
most binding projects never write down. The callback contracts check out against the headers —
`KeyValueCallback` really does mean "return TRUE to continue", and the wrapper says so.

The single biggest problem is `asset_get` / `asset_set`: they read a tagged union without reading the
tag, so a *constant* property in somebody else's passport is decoded as a function pointer and called.
Both are already pointed at engine-owned assets in `examples/behavior.odin` and `examples/video.odin`.
After that, the notable items are a content-integrity gap in `load_embedded` and a scattering of
`Api_Error` variants used for things they do not describe.

## Findings

### R1-01 — `asset_get` / `asset_set` call through a union without checking the discriminant  [severity: critical]

**Where:** `sciter_app/som.odin:371` (`asset_get`), `sciter_app/som.odin:394` (`asset_set`)
**What:** `som_property_def_t` is a tagged union. `sciter-om-def.h:41-52`:

```c
typedef struct som_property_def_t {
  intptr_t      type; // SOM_PROP_TYPE
  som_atom_t    name;
  union {
    struct { som_prop_getter_t getter; som_prop_setter_t setter; } accs;
    int32_t i32;
    int64_t i64;
    double  f64;
    const char* str;
  } u;
```

with `SOM_PROP_ACCSESSOR = 0, SOM_PROP_INT32 = 1, SOM_PROP_INT64 = 2, SOM_PROP_FLOAT = 3,
SOM_PROP_STRING = 4` (`sciter-om-def.h:34-39`). Only for `type == SOM_PROP_ACCSESSOR` is `u.accs`
the live member. Both wrappers ignore `def.type` entirely and go straight to `def.u.accs.getter` /
`def.u.accs.setter`, guarding only against nil:

```odin
if def.u.accs.getter == nil {
    return {}, .Not_Found
}
if !def.u.accs.getter(asset, &result) {
```

For a constant property built by `SOM_CONST(name, val)` (`sciter-om-def.h:149`) the first 8 bytes of
`u` are the constant itself — `100` for `SOM_CONST(MAX, 100)`, or a `const char*` for a string
constant. That is non-nil, so the guard passes and the wrapper calls it.

**Why it matters:** a jump to address `100` (segfault) or, for `SOM_PROP_STRING`, a jump into a live
string literal in the engine's rodata — an indirect call to attacker-influenced-in-principle,
certainly-not-code memory. The reach is real, not theoretical: `asset_get` is applied to engine-owned
assets at `examples/behavior.odin:749` (`edit`'s `columns`), `examples/behavior.odin:771`
(`caretColumn`) and `examples/video.odin:419` (`selectionStart`), and `asset_members`
(`sciter_app/som.odin:265`) lists constant properties by name alongside accessors, so it actively
advertises the names that will crash. Nothing today happens to trip it only because the intrinsic
behaviors probed so far publish accessors; the next behavior probed, or the next engine version, decides
that.

Note the doc comment on `asset_get` (`sciter_app/som.odin:359-360`) already describes the correct
behaviour — "a passport may also hold a constant, and those are returned from the definition itself" —
so this is code that fell behind its own contract.

**Fix:** read the tag first, in both procs:

```odin
if def.type != int(sciter.Som_Prop_Type.ACCSESSOR) {
    // constant: build the Value from def.u.i32 / .i64 / .f64 / .str per def.type
}
```

Return the constant as a `Value` in `asset_get` (which is what the comment promises), and `.Not_Found`
from `asset_set` since a constant has no setter. `make_asset_class` already writes
`type = int(sciter.Som_Prop_Type.ACCSESSOR)` at `sciter_app/som.odin:138`, so this package's own assets
are unaffected either way — the exposure is entirely on assets from `element_asset`.

### R1-02 — `load_embedded` reuses a cached engine on a size match alone  [severity: major]

**Where:** `sciter_app/embed.odin:74`, `sciter_app/embed.odin:117` (`is_file_of_size`)
**What:** the cache directory is named by `hash.fnv64a(blob)` (`embed.odin:60`), but the decision to
reuse an already-extracted library is `is_file_of_size(full, len(blob))` — an `os.stat` size comparison.
The bytes in the file are never checked against the bytes in the executable.
**Why it matters:** anything that can write into `~/.cache/odin-sciter/<hash>/libsciter.so` gets its
code `dlopen`ed by every subsequent run of the program, and only has to match a 25 MB size to do it. The
path is fully predictable — the hash is a function of the shipped blob, so it is the same for every user
of a given build. This is a local privilege/persistence vector on any machine where the cache directory
is reachable by another account or a compromised process running as the same user, and it also silently
tolerates a truncated-then-padded or partially-overwritten file. The atomic-rename dance in
`write_engine` (`embed.odin:106`) correctly protects against a half-written file from *this* code, which
makes the weaker check on the reuse path stand out more.
**Fix:** hash the existing file and compare against `hash.fnv64a(blob)` before reusing it; rewrite on a
mismatch. FNV-1a over 25 MB is a few milliseconds once per process start, against a 25 MB write. If even
that is unwanted, at minimum create the directory `0700` and document the trust assumption in the
file-header comment, which currently discusses noexec mounts and anti-malware but not this.

### R1-03 — `init` leaks the previous argv on an `init` → `shutdown` → `init` cycle  [severity: minor]

**Where:** `sciter_app/app.odin:72-77`, `sciter_app/app.odin:107-110`
**What:** `init` allocates `g_argv_storage`, `g_argv` and one `utf16_from_string` per argument, guarded
by `g_initialized`. `shutdown` sets `g_initialized = false` and frees none of it, so the next `init`
overwrites both globals with fresh allocations and the previous set becomes unreachable.

To be clear about what is *not* the bug: holding the argv for the life of the process is deliberate and
correct, and `app.odin:45-47` says why — "the engine is not documented to copy them and
`application::start()` in sciter-x-window.hpp keeps the vector it builds". The test suite knows this too
and allocates around it (`examples/dom_walk.odin:256-259`: "The engine holds onto the argv it is given
and the window for the life of the process, so both are allocated outside the test runner's tracking
allocator"). The defect is only the second `init`.
**Why it matters:** bounded and small — `len(os.args)` UTF-16 buffers plus two slices per cycle — and
invisible to a single-shot application, which is why it has survived. It matters to anything that cycles
the engine deliberately: a plugin host, an embedded scripting scenario, or a test that wants to prove
`shutdown` really releases everything. It also means the workaround in the test harness has to stay,
because a tracking allocator cannot otherwise distinguish this from a real leak.
**Fix:** free the three allocations in `shutdown`, after `SCITER_APP_SHUTDOWN` has run — which is where
`shutdown` already is, so the engine no longer holds the pointers by then. Remember the allocator `init`
was given.

### R1-04 — `set_default_debug_output` captures one thread's context and allocates from it per message  [severity: major]

**Where:** `sciter_app/app.odin:164-183`
**What:** `set_default_debug_output` stores `context` in the package global `g_debug_ctx`, and the
`proc "system"` callback restores it and then calls `string_from_utf16(..., context.temp_allocator)`.
**Why it matters:** two problems, both invisible until they are not.

1. `context.temp_allocator` is a per-thread arena. If the engine ever emits a diagnostic from a thread
   other than the one that called `set_default_debug_output` — which the engine gives no promise it will
   not, and `worker_thread.odin` establishes there *are* other threads — two threads bump the same arena
   with no synchronisation.
2. Nothing frees that arena. A GUI process that runs `run()` forever and never calls
   `free_all(context.temp_allocator)` grows it by one message-sized allocation per diagnostic,
   indefinitely. The messages are small, but a document with a per-frame script warning makes it a real
   leak.

**Fix:** decode into a fixed stack buffer (diagnostics are bounded and truncation is acceptable for a
default logger), or `defer free_all(context.temp_allocator)` inside the callback since nothing outlives
it. For the threading half, either document that this must be called from the thread that will run the
pump, or use a context with a thread-safe allocator.

### R1-05 — `value_make_array(0)` returns a Value that is not an array  [severity: minor]

**Where:** `sciter_app/value.odin:126-133`
**What:** the proc documents itself as "An empty array of `length` undefined slots", but the write that
creates the array is skipped when `length == 0`, so a zeroed — i.e. `.UNDEFINED` — Value is returned.
**Why it matters:** `value_len` on the result is `.INCOMPATIBLE_TYPE` rather than `0`, and
`value_set_at(v, 0, x)` then makes it an array with one element by the header's own fallback rule
(`value.h:224-228`: "If the VALUE is not of one of types above then it makes it of type T_ARRAY with
single element"). So the zero case works by accident for the append pattern and fails for the
inspect-then-branch pattern. Code that builds an array whose length is computed — the common case —
gets a type that depends on whether the input was empty.
**Fix:** either produce a real empty array (parse `[]` via `value_parse`, which the engine does support)
or change the doc comment to say that a zero length yields `.UNDEFINED` and that the caller must handle
it. The first is better; the second is at least honest.

### R1-06 — `string_from_utf16` returns a string whose backing allocation is up to 3× its length  [severity: minor]

**Where:** `src/prelude.odin:99-110`
**What:** `buf := make([]u8, n * 3, allocator)` then `return string(buf[:written])`. The returned string
has `len == written`, but the allocation is `n * 3`.
**Why it matters:** every caller that does `delete(s, allocator)` frees with the wrong size. The default
heap allocator ignores the size argument so nothing breaks there, which is why this has not shown up —
but `mem.Rollback_Stack`, an arena with a free-list, or any size-checked allocator gets a wrong size, and
`mem.Tracking_Allocator`'s bad-free detection will report it. It is also a 3× overshoot on every string
crossing out of the engine: for ASCII, which is the overwhelming majority of DOM text, attribute values,
and script results, two thirds of every such allocation is waste held for the string's whole life.
This proc is on the return path of `value_to_string`, `element_text`, `element_html`, `atom_name` and
more, so it is the hottest allocation in the package.
**Fix:** decode into `context.temp_allocator` at `n*3` and then clone the exact `written` bytes into
`allocator`; or compute the exact UTF-8 length in a first pass (cheap — it is the same scan
`utf16_len` already does in the other direction) and allocate once at the right size.

### R1-07 — `Api_Error.Load_Failed` is returned for four unrelated failures  [severity: minor]

**Where:** `sciter_app/app.odin:127` (`set_option`), `sciter_app/app.odin:206` (`set_master_css`),
`sciter_app/app.odin:212` (`append_master_css`), `sciter_app/archive.odin:43` (`close_archive`)
**What:** `Api_Error.Load_Failed` is documented at `sciter_app/sciter_app.odin:43` as "SciterLoadHtml /
SciterLoadFile returned FALSE". It is also what you get when an engine option is rejected, when the
master stylesheet is refused, and when closing an archive fails.
**Why it matters:** the error enum is the package's whole error vocabulary, and a caller that logs
`Load_Failed` from `set_script_features` will go looking at its HTML. `Api_Error` already has eleven
carefully-distinguished variants; these four calls are the ones that undo that work.
**Fix:** add `Option_Failed` (covering `set_option` and the two CSS setters, all of which are
"the engine said no to a configuration call") and reuse `.Not_Found` or a new `Archive_Failed` for
`close_archive`. Related: `make_asset_class` returns `.Wrong_Type` for "more than `MAX_ASSET_MEMBERS`
members" at `sciter_app/som.odin:124`, which is the same category of mismatch.

### R1-08 — `value_to_bool` inherits `value_to_int`'s `.BIG_INT` blind spot, undocumented  [severity: minor]

**Where:** `sciter_app/value.odin:182-186`
**What:** `value_to_bool` calls `ValueIntData`, the same slot as `value_to_int`. The doc comment on
`value_to_int` (`value.odin:188-191`) carefully records that this reads `.INT` and `.BOOL` only and
answers `0` with no error on a `.BIG_INT`. `value_to_bool` has no comment at all and the same behaviour:
a `.BIG_INT` of 5 reads back as `false`.
**Why it matters:** `value_from(i64(...))` produces `.BIG_INT` (`value.odin:102-105`), so any boolean
that made a round trip through an `i64` — or arrived from script as a large number — reads `false`
silently. The `value_to_int` comment exists precisely because this was found the hard way; the sibling
proc did not get the same treatment.
**Fix:** carry the same warning onto `value_to_bool`, or implement it over `ValueInt64Data` like
`value_to_i64` so both integer widths work.

### R1-09 — the atom interning of member names in `make_asset_class` runs before `init` is guaranteed  [severity: minor]

**Where:** `sciter_app/som.odin:139`, `sciter_app/som.odin:147`, `sciter_app/som.odin:160`
**What:** `make_asset_class` calls `atom(...)` three times per class. `atom.odin:24-29` documents that
the atom space is only safe after the engine is initialised — "`atom_name(Atom(12345))` **segfaults**
inside the engine before `init` has run" — and `atom` itself goes straight to
`sciter.api().SciterAtomValue`, which asserts only that `load` has happened, not `init`.
**Why it matters:** `make_asset_class` reads like configuration and the natural place to call it is at
the top of `main`, before `init()`. Whether interning (as opposed to reverse lookup) is safe pre-`init`
is not established anywhere in the tree; the atom file's own warning is about the reverse direction only.
**Fix:** either measure it and record the answer in `atom.odin`'s header comment next to the other four
measured properties, or add the cheap guard — `if !g_initialized { return ..., .Not_Loaded }` — to
`make_asset_class` and say so in its doc comment.

### R1-10 — `load` hands back an allocated `tried` list on the success path with no note in its own doc  [severity: minor]

**Where:** `src/prelude.odin:93` (doc), `src/prelude.odin:173` (the success return)
**What:** the doc comment says "On failure `tried` lists every candidate that was attempted"; the code
returns `candidates[:]` on success too, with every element separately allocated.
**Why it matters:** the one in-tree caller gets it right and says so — `load_engine`
(`sciter_app/app.odin:22-29`) has a comment explicitly correcting the doc: "hands the candidate list to
the caller on every path, including success". Anyone calling `sciter.load` directly, which the README
and `docs/architecture.md` both show as a supported thing to do, reads the doc comment instead and leaks
the list plus every string in it.
**Fix:** one sentence in the doc comment on `load` saying the list is returned and owned by the caller on
every path, success included.

## Nits

- `sciter_app/value.odin:390` — `to_cstring` is a one-line alias for `strings.clone_to_cstring` living in
  `value.odin` but used from `atom.odin` and `som.odin`. It belongs in `sciter_app.odin` next to the
  other conversion helpers.
- `sciter_app/embed.odin:171` — `strings.clone("." + "/" + APP, allocator)` is a compile-time constant
  written as a runtime-looking concatenation; `"./odin-sciter"` reads the same and is what it is.
- `sciter_app/som.odin:528-633` — the three 32-entry tables are 106 lines of mechanical repetition with
  a comment explaining why. Odin's `#unroll` cannot supply the constant, but a small
  `@(init)`-time loop over an array of thunks generated by a `for` over a constant range is worth a
  second look; if it stays, the comment at `som.odin:525-526` is the right thing to have.
- `sciter_app/archive.odin:99` — `serve_archive` returning `.OK, false` for a non-matching URL means the
  `.OK` is meaningless in that case. `{}, false` would make misuse of the ignored value harmless.
