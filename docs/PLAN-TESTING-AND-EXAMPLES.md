# Plan: close the testing gap, and build a larger example

A worklist for a fresh session. Written 2026-08-11 against a tree where `just check` passes with 21
examples and `just example-tests` runs 183 tests in 14 suites, all green.

Two goals, in this order:

1. **Close the testing gap.** ~76 exported procedures in `sciter_app` are called from nowhere — not
   "demonstrated but unasserted", *never referenced by any example or snippet*. That is where a wrong
   argument order or a bad slot ships silently.
2. **Build one larger application example**, plus a small number of focused ones, exercising Sciter
   features the current set does not reach.

Both outputs are for people learning this library, so **the commenting standard in
[§0](#0-how-to-work-here) is part of the deliverable, not decoration**.

---

## 0. How to work here

House rules that will otherwise cost you time. All of these are load-bearing.

- **Measure before documenting.** Write a throwaway `@(test)` or a scratch `main` that prints what the
  engine actually does, read it, *then* write the assertion and the prose. Delete the probe. Across
  every API area in this repository this has caught a wrong assumption — including several taken
  straight from the C headers. See [`RESEARCH-METHOD.md`](./RESEARCH-METHOD.md).
- **Do not `git commit`.** The repository owner curates commits. Leave the tree dirty and report what
  changed.
- **Windowed runs need `XMODIFIERS=@im=none`** on X11 — the engine segfaults in `XSetICFocus`
  otherwise. Treat `timeout N ./target/debug/x.exe` returning 124 as the pass.
- **`just format` exits 1**, on `examples/dom_walk.odin` — a local variable named `inline`, which
  odinfmt's parser rejects and the compiler does not. Pre-existing. It also rewrites
  `examples/custom_loader.odin` and `examples/extension.odin` every time; `git checkout --` those two
  afterwards and check `git status --short` shows only your work.
- **`events` timer tests flake under load.** Pre-existing at HEAD. Re-run on a quiet machine; don't chase.
- **`just example-tests` uses `set -e`**, so one failure skips every suite after it. Run the remainder
  individually when hunting.
- **Tests that need a window gate themselves** on `DISPLAY`/`WAYLAND_DISPLAY` and share one `g_window`
  across the suite. Copy the harness from `examples/behavior.odin` or `examples/named_behavior.odin`.
  Allocate anything the engine keeps (the window, handlers) from `runtime.default_allocator()` or the
  test runner reports it as a leak.
- **`ODIN_TEST_THREADS=1` is required** — already in the `example-test` recipe.

### The duplicated fixture is a stated cost, not an oversight

`test_window` is written out in ten files. `have_display`, the `load_engine()` boilerplate and the
`runtime.default_allocator()` swap are repeated at the same scale. That is the price of the build model
and it is worth naming so nobody "fixes" it by accident:

**Every example is a standalone single file**, built and tested with `odin build examples/x.odin -file`
and `odin test examples/x.odin -file`. `-file` compiles exactly one file as its own `package main`, so
there is no second file for a shared helper to live in. A helper package (`examples/harness/`) would
work for the tests and would break the property the examples exist for: that one file, readable top to
bottom, is a complete program you can copy out of the repository. `src/prelude.odin` is not an option
either — it is `bindgen.sjson`'s `imports_file`, pasted verbatim into the generated `sciter.odin`.

The cost is real and has already been paid once: the skip messages have drifted apart between files, and
a change to the fixture is a ten-file edit. When you make one, make it in all ten.

### `docs/snippets/` is compiled, `spike/` is not

**`docs/snippets/snippets.odin` is every Odin code block in the guides**, wrapped in just enough
scaffolding to compile, and `just check` type-checks it. That is what stops the documentation from
rotting silently, and it is worth knowing about before you write a code block: add the snippet there,
in the section matching the guide, and the guide's block becomes something CI keeps honest.

**`spike/` is the opposite and should probably go.** `spike/skeleton`, `spike/windowless` and
`spike/smoke` are 752 lines of development scratch programs. `just format` formats them; nothing
compiles them - `just check` does not - so they can stop building without anyone noticing, and what
they demonstrate is now covered by `examples/windowless.odin` and `examples/hello_window.odin`. They are
left in place because deleting somebody's scratch work is not a reviewer's call, but they are the only
Odin in this tree that nothing verifies.

### Advancing the engine in a test

The engine has no "quiesce" call, so a test that waits for the engine to do something has to pump it.
Three spellings appear in the suite — a fixed number of `run_once` turns, `heartbeat` in a loop, and
`time.sleep`. Prefer, in order:

1. **Pump until a predicate, with a turn cap.** `for i in 0 ..< 200 { if done() { break }; run_once() }`
   and then assert on the predicate. Robust against a slow machine, and it fails as "the thing never
   happened" rather than as a mystery.
2. **A fixed number of turns**, when there is nothing to predicate on — a "nothing should arrive" test.
3. **`time.sleep`** only where the engine's own clock is the thing under test, as in the timer tests.

The known-flaky timer tests are what option 3 costs, and they are why 1 is the default.

### The commenting standard

This is what makes the work useful to somebody who has not used Sciter. Match the existing files.

- **Every example opens with a header comment** that says what concept it teaches, how to run it, and —
  crucially — *what surprised us*. See `examples/named_behavior.odin` for the shape: six numbered
  measured rules before a line of code.
- **Test names are sentences.** `test_removing_the_element_detaches_the_behavior`, not `test_detach_2`.
  A reader scanning `just example-test x` output should learn the API's rules from the names alone.
- **Each test's comment says what rule it pins and why anyone cares**, not what the code does. "Rule 3:
  the engine keeps its own names. This is the one that decides whether a `behavior:` name of your own
  can shadow a built-in — it cannot."
- **Write down engine behaviour that is surprising, wrong, or undocumented** in the example header, in
  the wrapper's doc comment, and in `CHANGELOG.md`'s known-issues list. Where the engine is defective
  rather than merely surprising, keep a characterization test that fails loudly if a future engine
  fixes it.

---

## 1. The testing gap, file by file

### How the list was produced, and its one trap

References counted **inside `@(test)` proc bodies only** — `main()` doesn't count as coverage. Then
split into "demonstrated in an example but never asserted" and "never appears anywhere".

**The trap: match a call, then check the proc group.** Six of `value.odin`'s apparent misses
(`value_from_bool`, `value_from_int`, `value_from_i64`, `value_from_f64`, `value_from_string`,
`value_from_bytes`) are members of the `value_from :: proc{…}` group and are reached through it — tests
call `value_from(...)` 61 times. They are probably already covered. **Verify per overload before
writing a test for one**, or you will write tests for code that is already exercised. This is the same
class of error as the one recorded for the API coverage scan: the naive scan overstates the gap.

Re-run the scan after each batch:

```sh
python3 - <<'PY'
import re, glob, os
bodies=[]
for f in glob.glob('examples/*.odin'):
    s=open(f).read()
    for m in re.finditer(r'^@\(test\)\n(.*?)^\}', s, re.S|re.M): bodies.append(m.group(1))
tests="\n".join(bodies)
allex="".join(open(f).read() for f in glob.glob('examples/*.odin')+glob.glob('docs/snippets/*.odin'))
for f in sorted(glob.glob('sciter_app/*.odin')):
    src=open(f).read()
    procs=[p for p in re.findall(r'^([a-z][a-z0-9_]*) :: proc', src, re.M)
           if not re.search(r'@\(private[^\)]*\)\s*\n'+re.escape(p)+r' :: proc', src)]
    nt=[p for p in procs if not re.search(r'\b'+re.escape(p)+r'\(', tests)]
    never=[p for p in nt if not re.search(r'\b'+re.escape(p)+r'\(', allex)]
    if nt: print(f"{os.path.basename(f):18} {len(procs)-len(nt):3}/{len(procs):3}  never: {never}")
PY
```

### Batch A — `graphics.odin`, 29/73. The biggest hole by far.

**33 never called:** `rgba`, `image_from_element`, `retain_image`, `set_line_join`, `set_line_cap`,
`set_fill_mode`, `set_fill_gradient_linear`, `set_line_gradient_linear`, `set_line_gradient_radial`,
`scale`, `skew`, `transform`, `world_to_screen`, `screen_to_world`, `draw_rounded_rect`, `draw_arc`,
`draw_star`, `draw_polyline`, `draw_image`, `push_clip_path`, `retain_graphics`, `path_quad_to`,
`retain_path`, `create_text_with_style`, `retain_text`, and all eight of
`value_from_graphics`/`value_from_image`/`value_from_path`/`value_from_text` and their `value_to_*`
inverses.

**11 demonstrated but unasserted:** `set_line_width`, `set_fill_gradient_radial`, `rotate`, `draw_line`,
`draw_ellipse`, `draw_polygon`, `path_arc_to`, `path_bezier_to`, `create_text`, `set_text_box`,
`draw_text`.

Do this as a **new example, `graphics_gallery`**, rather than by bolting 40 tests onto
`examples/graphics.odin`. It doubles as the reference page a new user wants ("how do I draw a gradient
arc?"), which the current graphics example is too narrow to be.

How to assert drawing without eyeballing it: `paint_image` gives an offscreen `Graphics`, and
`save_image(img, .RAW)` reads pixels back — **`.RAW` is BGRA**, four bytes a pixel. So every drawing
test is "draw into a known-size image, read the pixel where the shape should be, assert the colour".
`examples/graphics.odin` already does exactly this; copy the helper.

Specific things worth pinning because they are guessable and probably wrong:

- the winding rule `set_fill_mode` actually applies, on a self-intersecting polygon
- whether `world_to_screen` / `screen_to_world` round-trip exactly under a rotation, and what they do
  with no transform set
- `draw_star`'s parameter meaning — `r1`/`r2`/`start`/`rays` are undocumented upstream
- `path_quad_to` vs `path_bezier_to` producing the same curve for equivalent control points
- whether `retain_*`/`release_*` on an image the engine handed you is safe, and what a double release does
- `create_text_with_style` versus `create_text` with a class — which wins, and what an invalid style does
- the eight `value_from_*`/`value_to_*` conversions round-tripping, and what `value_to_image` does with
  a Value holding something else (it should be an error, not a bad handle)

### Batch B — `node.odin`, 10/20

**9 never called:** `node_add_ref`, `node_release`, `node_child_count`, `node_child`, `node_last_child`,
`node_prev_sibling`, `node_set_text`, `make_comment_node`, `node_remove`.

Add to `examples/dom_walk.odin`, which already owns nodes and has the harness. This is the whole
mutation-and-navigation half of the node API, and it is exactly where a lifetime bug hides. Pin:

- the reference counting pair, including what happens to a handle after the last release (expect a
  characterization test here; the element API has a matching hazard where `remove_element` can free out
  from under the caller)
- `make_comment_node` surviving a round trip through `set_html`/`html` — comments are usually eaten
- text vs element node counts: does `node_child_count` include whitespace text nodes? Almost certainly
  yes, and it is the first thing that surprises people
- `node_remove` versus `remove_element` — whether the node API has the same free-out-from-under hazard

### Batch C — `request.odin`, 19/34

**11 never called:** `delete_name_values`, `request_content_url`, `request_mime`, `request_proxy_host`,
`request_proxy_port`, `request_parameter_count`, `request_parameter`, `request_header`,
`response_header_count`, `response_header`, `response_headers`.

Add to `examples/request_loader.odin`. Most of these are the header/parameter surface, which needs a
request that actually carries them — drive it with `http_request(el, url, method, params)` against a
`this://app/` URL served by the host, so no network is involved. Pin what a nil handle answers for each
(the existing tests already do this for the other wrappers — extend the same table-driven test).

`request_proxy_host`/`request_proxy_port` may well be empty/zero on every request this engine makes;
that is a fine thing to assert, with a note.

### Batch D — `window.odin`, 12/23

**6 never called:** `set_css`, `set_window_state`, `window_state`, `hide`, `close`, `activate`.

Careful — `close` on the `.MAIN` window ends the pump and will take the test runner with it. Test window
state on a **second, non-`.MAIN` window** created for the purpose. Pin:

- `window_state` round-tripping through `set_window_state` for each state, and which ones are refused
- whether `hide` then `show` preserves anything (scroll, focus)
- `set_css` layering: it sits under the document's own CSS and over the master sheet — assert that
  ordering with three competing rules, because it is stated in the docs and never checked
- what `close` does to a window that was never shown

### Batch E — `value.odin`, 24/39

**8 real misses after discounting the proc group:** `value_init`, `value_isolate`, `value_is_null`,
`value_to_i64`, `value_from_asset`, `value_key_at`, `value_get_key`, `value_set_key`.

Add to `examples/eval.odin`, which owns `Value`. The interesting ones:

- `value_isolate` — the copy-on-write break. Pin that mutating an isolated copy leaves the original
  alone, which is the entire reason it exists
- the key-based map trio against non-string keys (int keys, and a key that is itself a map)
- `value_from_asset` — pairs with `value_to_asset`, which `examples/video.odin` already tests. The
  header says it does *not* add_ref, so the asset must outlive the Value; pin the pairing at least

Run this batch under ASan too — `just test_sanitize eval` — since `Value` refcounting is exactly what it
catches.

### Batch F — the small remainder

| | |
| --- | --- |
| `app.odin` | `set_debug_output` (never called). The 8 "demoed" ones are lifecycle and mostly untestable in-process; leave them |
| `behavior.odin` | `set_behavior_value` — the setter half of a protocol `examples/behavior.odin` proved no intrinsic behavior implements. Assert it fails the same way |
| `events.odin` | `gesture_event` — may be unreachable without touch hardware. **Probe first**; if the engine never sends `.GESTURE` here, say so in a comment and move on rather than faking it |
| `host.odin` | `data_ready` (the copying push, vs `data_ready_async`) |
| `som.odin` | `asset_passport`, `asset_set` — both new this week, and `asset_set` is the only untested writer |
| `sciter_app.odin` | `string_from_utf16_cstring`, `set_state` |
| `video.odin` | `video_render_external_frame` — the zero-copy path. Needs a release callback; pin that it *is* called, which is the leak-or-not question |

### Batch G — the examples with no tests

Seven have zero `@(test)`. Five are fine as they are: `hello_window` (a demo), `api_map` (a diagnostic
tool), `inspector` and `extension` (need the external SDK), `load_file` (trivial).

**Two are testable and should be tested:**

- **`call_odin_from_js.odin`** (326 lines) — the showcase for native functors *and* SOM assets, and the
  single most likely thing a new user copies. Untested. Cover: a functor called from script with each
  argument type, its return crossing back, what a functor that throws does, and the asset's properties
  and methods read/written/called from script.
- **`custom_loader.odin`** (150 lines) — the showcase for `SC_LOAD_DATA`. Cover: serving CSS and an
  image from memory, `.DISCARD` on an unknown URL, and leaving the engine's own `sciter:` requests
  alone (the rule the header does not state and that breaks documents when you get it wrong).

---

## 2. The larger example

### First: a decision, because `task_list` is already a todo app

[`examples/task_list.odin`](../examples/task_list.odin) is 924 lines and 11 tests of exactly the common
todo app — add, toggle, delete, select, keyboard commands, JSON persistence, no script. Adding a second
todo list would duplicate it.

Two ways forward. **Recommendation: option B.**

- **A — grow `task_list` into full TodoMVC.** Add filters (all/active/completed), in-place editing on
  double-click, toggle-all, clear-completed, live counts. *Against it:* `task_list` is deliberately the
  gentle "how do the pieces fit" example, it is referenced from the README, PLAN and CHANGELOG, and
  making it twice as big makes it worse at that job.
- **B — leave `task_list` alone and add one genuinely harder application** that is not a second todo
  list, and that hits the parts of Sciter nothing currently exercises. Keeps the gentle example gentle
  and gives the advanced one room.

### The proposal: `examples/workbench.odin`

A small data browser. Chosen because every feature below is *load-bearing for the app* rather than
bolted on, and together they cover the biggest holes in §1.

```
┌────────────┬──────────────────────────────────┐
│ tree       │ toolbar: filter, theme, count    │
│ (folders,  ├──────────────────────────────────┤
│  nodes,    │ virtualised table of rows        │
│  lazy)     │  - focusable, editable cells     │
│            │  - live-updating from a worker   │
│            │  - a sparkline per row (DRAW)    │
├────────────┴──────────────────────────────────┤
│ status bar                                    │
└───────────────────────────────────────────────┘
```

What each part is there to teach, and what it covers:

| Feature | Teaches | Covers |
| --- | --- | --- |
| **Virtualised row list** (render only the visible window of 10k rows) | the technique every real list app needs, and which nothing here shows | scroll geometry, `scroll_to_view`, the `set_html` cost that [`VDOM.md`](./VDOM.md) is about |
| **In-place cell editing** | focus surviving — or not surviving — a re-render | `set_focus`, focus events, the `:focus` known issue |
| **Worker thread producing rows** | the only safe cross-thread call | `post_callback` in an app, not a test |
| **Sparkline as `behavior: sparkline`** | an Odin widget the *stylesheet* asks for | `named_behavior` + a real `.DRAW` handler, and much of Batch A |
| **Theme switch at runtime** | restyling a live document | `set_css`, `set_media_vars` (Batch D) |
| **Filter/sort persisted as a Value** | state that survives a restart with no serializer | the `value_*` map trio (Batch E) |
| **Tree pane built from nodes** | the node API as something other than trivia | Batch B |
| **UI served from an archive** | shipping shape | `this://app/`, request headers (Batch C) |

**It is also the experiment [`VDOM.md`](./VDOM.md) asks for.** That note's recommended first move is
"write a harder example *without* a layer and see what actually hurts". A virtualised, focusable,
live-updating list built with `set_html` is precisely that. **Keep notes while building it** — where
focus was lost, where scroll jumped, where a transition restarted, where escaping was nearly forgotten —
and write them into a "what hurt" section at the end of `VDOM.md`. That evidence is the deliverable that
turns the vdom question from a guess into a decision.

Scope control: this is easily a 1,200–1,500 line example. If it is running long, **cut the tree pane
first** and cover Batch B with tests in `dom_walk` instead. The virtualised list is the part that must
survive.

### Stretch extensions, in the order they are worth doing

1. ~~**Drag to reorder rows**~~ **done, but not the way this item assumed.** `.EXCHANGE` cannot do it:
   the engine has **no drag source on Linux** — `performDrag` returns null and no exchange event
   follows — so that group can only *receive* a drag from another application, payload empty.
   An in-application reorder is therefore the `.MOUSE` group: press, move with the button down,
   release, with the three drag states in the model because the rows are destroyed and rebuilt
   mid-drag. Two tests drive it with `send_mouse`, including the press-without-movement case.
2. ~~**Type-ahead search off the UI thread**~~ **done** — worker filters 10k rows, posts back, list
   updates. The measurement it was for: the scan costs ~1.2 ms and the `set_html` of the 31 rows it puts
   on screen costs ~2-3 ms, so **the render is the expensive half** - written up in the "What the
   numbers say" section of [`VDOM.md`](./VDOM.md). The part worth more than the thread is the
   generation number: an answer that lands after the next keystroke is correct and wrong at the same
   time, and `search_apply` drops it.
3. ~~**Undo/redo over the model**~~ **done** — three actions (rename, move, pin), one stack, no Sciter
   call anywhere in the section, which is the proof the thesis was asking for. Four headless tests,
   including that a new action throws the redo stack away and that a no-op rename is not an action.
4. ~~**An inspector-friendly mode**~~ **done** — `WORKBENCH_INSPECT=1` turns on `set_debug_mode` and
   adds `.ENABLE_DEBUG` to the window flags. Off by default because it opens a socket.
5. ~~**A second window**~~ **done** — a details window opened by double-clicking a row, with its own
   host handler: it answers its own `behavior:` requests and receives its own posted messages, and the
   feed thread posts to both windows. It also settled `close`, which Batch D had to leave alone:
   **`hide`, pump, `close`** is the one teardown that survives, and unloading the document first - the
   workaround `window.odin` used to recommend - does not. The table of what was measured is on `close`
   in `window.odin`.

---

## 3. Acceptance

Done when all of these hold. **All of them do, as of 2026-08-12** — the boxes are ticked with what was
run rather than with an opinion.

**The figures below are what was measured on that date, and they are lower than today's.** They are
kept as run rather than refreshed, because a ticked box is a record of a check passing and rewriting it
would destroy that. For the current numbers run `just stats`, which is the only place they are
maintained.

- [x] the scan in §1 reports **zero** never-called procedures, or every remaining one has a comment in
      its wrapper saying why it cannot be reached here (touch hardware, platform-only, needs a network).
      *Every name the scan still lists is a proc-group member reached through its group; 310 of 347
      exported procedures are called from a test.*
- [x] `just check` passes — both packages, `docs/snippets`, every example
- [x] `just example-tests` is green in one run on a quiet machine — *321 tests, 18 files*
- [x] `odin check -target:windows_amd64` and `-target:darwin_amd64` pass for `sciter_app`, the snippets
      and every new example. *The one failure on both was `single_binary`, which `#load`s the target
      platform's engine and so needs that platform's binary on disk. `just cross-check` now skips it
      per target when the file is absent and checks it when `just fetch-engine` has installed it.*
- [x] every new example runs: `XMODIFIERS=@im=none timeout 15 ./target/debug/NAME.exe`, exit 124
- [x] `just test_sanitize eval` is clean after Batch E — 27/27, and `workbench` is clean under ASan too,
      which is what covers the search thread. **It needed a fix to the recipe rather than to the code**:
      ASan dies on the engine's first C++ throw unless the system `libstdc++` is preloaded, because an
      Odin binary links no C++ runtime for its `__cxa_throw` interceptor to forward to. The recipe does
      it now, and says why.
- [x] every new test's name reads as a sentence, and every new example has the header comment described
      in §0
- [x] anything measured that contradicts the headers is in the example header, the wrapper doc comment,
      and `CHANGELOG.md`'s known-issues list — *the secondary-window close order, which corrected advice
      `window.odin` had been giving*
- [x] counts updated: `CHANGELOG.md` (examples, tests), `README.md` (the badge line and the example
      table), `docs/PLAN.md` (§9 list and the status paragraph), `docs/api.md` if any signature moved
- [x] `docs/VDOM.md` has a "what actually hurt" section written from the workbench experience, and a
      "what the numbers say" section from the search work
- [x] `just format` run, then `git checkout -- examples/custom_loader.odin examples/extension.odin`, and
      `git status --short` shows only intended files. *`just format` now exits 0: a local named `inline`
      in `dom_walk` made `odinfmt` fail to parse the file, which failed the recipe and stopped it before
      it reached `spike/`.*
- [x] **nothing committed** — report the dirty tree

## 4. Suggested order

Batches first: they are mechanical, they teach you the API surface you are about to build an app on, and
each is independently finishable.

1. **Batch A** (`graphics_gallery`) — biggest hole, self-contained, and the new example is immediately
   useful to readers.
2. **Batches B, E, F** — additions to `dom_walk`, `eval` and their owners. Small and quick.
3. **Batch G** — tests for `call_odin_from_js` and `custom_loader`.
4. **Batches C, D** — request headers and window state; fiddlier, needs care with `close`.
5. **The workbench**, with the VDOM notes kept as you go.
6. **Stretch extensions**, as far as time allows. Stopping after (2) is a fine outcome.

Re-run the §1 scan and `just example-tests` at the end of each numbered step, not at the end.
