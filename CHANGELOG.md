# Changelog

Releases are named after the Sciter engine they vendor, because that is the question anyone reading a
tag actually has. `v6.0.4.9` is the first release against engine 6.0.4.9; `v6.0.4.9-2` would be a
second release of the bindings against the same engine. The policy, and the upgrade procedure behind
it, are in [`docs/UPGRADING.md`](docs/UPGRADING.md).

## Unreleased

Fixes and hardening from a whole-repository review, [`docs/review/`](docs/review/). Headings follow
[Keep a Changelog](https://keepachangelog.com/); the v6.0.4.9 entry below predates that and is a
feature inventory rather than a diff, because it is the first release and there was nothing to diff
against.

### Fixed

- **`asset_get` / `asset_set` called through a union without reading its tag.** `som_property_def_t` is
  discriminated by `type`, and for a constant property the bytes where the getter pointer would be are
  the constant itself — so reading one was an indirect call to whatever the constant happened to be.
  Reproduced as a segfault. Constants now come back as Values, and a constant has no setter.
- **`sort_children` clamped `last` but not `first`.** A negative `first` reached the engine as
  `max(u32)`, which the neighbouring `insert_element` documents as a segfault.
- **`graphics_api()` and `request_api()` returned nil before `load()`** and ~90 procs dereferenced the
  result. They now assert, as `sciter.api()` does.
- **`load_embedded` reused a cached engine on a size match alone.** The cache path is a pure function of
  the shipped engine and therefore predictable; reuse now hashes the file contents, and the cache
  directory is created owner-only.
- **`set_timer` turned a negative interval into "stop"** — the engine's spelling of stopping — instead
  of reporting it. Now `.INVALID_PARAMETER`, as is an interval over `max(u32)` milliseconds.
- **`combine_url` truncated silently** at a fixed 1024-unit guess. It now detects the truncation and
  retries.
- **`serve` could not answer with a legitimately empty resource.** `nil` is "I have nothing"
  (`.DISCARD`); an empty-but-present slice is now `.OK` with a zero size.
- **`create_window` built a degenerate frame** when exactly one of width/height was zero. Rejected now.
- **`shutdown` leaked the argv** `init` allocated, so an init → shutdown → init cycle lost it.
- **`string_from_utf16` allocated 3× the string's length** and returned it, making every `delete` of
  such a string a wrong-size free. It now clones at the exact length.
- **`value_make_array(0)` returned an `.UNDEFINED` Value**, not an empty array.
- **`value_to_bool` read `.BIG_INT` as false.** Both integer widths now work; measured, because
  `ValueInt64Data` refuses a `.BOOL` and `ValueIntData` silently zeroes a `.BIG_INT`.
- **`set_default_debug_output` allocated per message from a per-thread arena** that nothing freed, from
  a callback the engine may make on another thread. It decodes into a fixed buffer now.
- **`save_image` grew its scratch buffer in the caller's allocator** and then copied, doubling peak
  memory — permanently, when that allocator was the temp allocator.
- **`make_text_node` / `make_comment_node` did not check for a nil handle**, unlike every sibling.
- **`set_global_asset(nil)` dereferenced nil** instead of answering `.Asset_Failed`.
- **CI told macOS maintainers to vendor the engine at `lib/macos/`**; the loader searches `lib/macosx`.

- **`resize_windowless` left `view.pixels` dangling when the engine refused the resize.** The old
  surface was freed before `SXM_SIZE` was sent and the view still described it on the failure path, so
  the caller's natural response — `destroy_windowless` — was a double free. The new surface is now built
  alongside the old one and the old one released only after the handover succeeds.
- **`load_embedded` dropped the candidate list `sciter.load` returns on every path**, leaking it and one
  string per candidate.
- **`save_image`'s chunk scratch never used the temp allocator.** A zero-valued `[dynamic]` adopts
  `context.allocator` at its first `append` and ignores an allocator stored beside it, so the doubling
  growth stayed in the caller's allocator. The allocator now lives on the array.
- **`sciter.load` leaked `filepath.dir(os.args[0])`**, and **`combine_url` abandoned each oversized
  retry buffer** in the caller's temp arena.
- **Two examples discarded reference-owning Values.** Measured: 2000 discarded `eval`s of a 100 kB
  string grow the process by 390 MB.

### Fixed — documentation that was wrong

- **`eval` never reports `.Eval_Failed` for a script error**, and `call`, `call_function` and
  `call_method` behave the same way. Measured identically in a window and a windowless view: the error
  code answers *could I call it?* — a name nothing defines is a real error with an `.UNDEFINED` result —
  and the returned **Value** answers *did it work?* A function that ran and threw comes back with
  `err = nil` and an `.ERROR`-unit string carrying the message and a stack trace. The documented route
  (install a debug handler) was wrong, the real one needs no handler, and because that string owns a
  reference the natural "it failed, drop it" shape leaked on every script error.
- **Over-releasing a borrowed handle is a segfault, not a leak.** Measured: one spurious
  `unuse_request` on a handle from `request_of` answers `.OK` and then kills the process; for
  `unuse_element` on a borrowed element it takes two calls. Every call reports success.
- **`http_request`'s temp-allocator arguments are safe** — the URL, the parameter array and both strings
  of every pair are copied by the engine during the call, despite the request being asynchronous.
  Measured with a poisoned arena and a canary, for `.Get` and `.Post`; the comment asserted it and
  nothing had checked.

### Changed

- **`make_element`, `clone_element`, `use_element` and `remove_element(finalize = false)` hand back an
  `Owned_Element`.** The borrowed handle every lookup returns and the one that owes an `unuse_element`
  are now separate types, and `unuse_element` accepts only the second — so releasing a handle you never
  held does not compile. `use_element` returns `(Owned_Element, Error)` and `remove_element` returns
  `(Owned_Element, Error)`, the handle being nil when it destroyed the element. `borrow_element(owned)`
  is the free cast for everything that reads, writes or moves it; borrowing once at the top of a scope
  is the idiom, and is what kept this change to a handful of lines per call site. **Breaking**, for code
  that creates, clones, holds or removes elements.
- **`take_request` and `use_request` hand back an `Owned_Request`.** The borrowed handle a load callback
  receives and the taken one that owes an `unuse_request` are now separate types, and `unuse_request`
  accepts only the second — so releasing a handle you never took does not compile. This is the type
  standing in for a rule because the failure is a first-call segfault the engine reports as `.OK`.
  `borrow_request(owned)` is the free cast for handing a held request to the readers and answerers;
  borrowing once at the top of a scope is the idiom. `use_request` additionally returns the handle it
  took. **Breaking**, for code storing a taken request or calling `use_request`.
- **`Event_Phase` no longer has a `.Handled` variant.** HANDLED is an independent bit in the C API, not
  a third phase, and folding it in made the direction unreadable once anything claimed an event — so
  `if ev.phase == .Bubbling`, the documented way to act exactly once, silently stopped acting. The
  typed event parameters gain a `handled: bool` alongside `phase`, and `event_handled(cmd)` reads the
  bit from a raw code. **Breaking**, on all seven event parameter structs.
- **`Api_Error` gains `Option_Failed`, `Archive_Failed` and `Too_Many_Members`.** `set_option`, both
  master-CSS setters, the archive calls and `make_asset_class`'s member cap used to borrow
  `Load_Failed` and `Wrong_Type`, which sent a reader of the log to the wrong place. **Breaking**, for
  code matching on those two.
- **`Attribute_Change` gains `removed: bool`** — the header distinguishes a removed attribute from an
  emptied one and the wrapper was losing it.
- **`insert_element`'s index is `Maybe(Child_Index)`**, so "append" is spelled `nil` rather than `-1`.
  The signature now says what the doc comment used to have to. A number out of range still clamps.
  **Breaking**, for callers passing `-1` explicitly.
- **`window_state` returns `(state, ok)`.** A destroyed window answers `0xFFFFFFFE`, which is not a
  member of `SCITER_WINDOW_STATE`; returning it as one handed back an out-of-range enum value. Adding a
  member for it was the alternative and would have put the binding out of step with the C API.
  **Breaking**.

### Added

- **`sciter_app/value_scope.odin`** — a `Value_Scope` holds a batch of engine references with one
  lifetime and releases them together, which is what `scoped_` cannot do for a pile produced in a loop
  (`@(deferred_out)` fires at the end of the calling scope, which there is one iteration). The same
  move rule 4 already recommends for allocations, applied to the other half: an arena for the Odin
  memory and a scope for the references, released at the same `defer`.
- **`just leak-check`**, in CI — builds `examples/leak_sweep.odin` with `-debug`, exercises the
  resource-owning paths, and fails if the engine is still holding anything at exit. It is a program
  rather than a test because an Odin test binary has no end-of-run hook: measured, neither `@(fini)`
  nor a libc `atexit` handler runs in one, since the runner leaves through `os.exit`.
- **`sciter_app/tracking.odin`** — debug-build tracking for the resources that live *inside* the engine,
  which `mem.Tracking_Allocator` cannot see: Values, element and node references, taken requests,
  images, paths, texts and archives, plus the graphics state stack and unanswered `.DELAYED` requests.
  `track_resources(true)` then `report_leaked_resources()`. Handles are reported with the site that
  acquired them; Values are counted rather than identified, because a Value is passed by value and
  `value_copy` makes two of them share a payload. Compiles to nothing without `-debug`.
- **`scoped_` procedures** (`sciter_app/scoped.odin`) — a twin of every `Value` producer plus
  `scoped_make_element` / `scoped_clone_element`, releasing at the end of the calling scope via
  `@(deferred_out)`. It fires even when the caller writes `_, _ =`, which `@(require_results)` does not
  reject — measured, and that is the exact shape that leaked in the examples.
- **`just check-ownership`**, in CI — asserts the rule that if a procedure takes an allocator its result
  is yours and otherwise it is borrowed. It holds across all 30 procedures that return memory.
- **[`docs/review/09-memory-safety-ownership.md`](docs/review/09-memory-safety-ownership.md)** — the
  memory-safety, resource-lifetime and ownership pass, with the measurements behind everything above.
- **`just parity`** — which C-API slots `sciter_app` reaches, measured from the headers with comments
  and `#if 0` blocks stripped. `--check` diffs against `docs/parity-baseline.txt` and runs in CI, so a
  slot added by a future SDK is a one-line diff during the upgrade rather than a silent gap.
- **`just stats`** — the counts the docs quote about this repository. `--check` fails when they drift;
  they had, by 29 tests.
- **`just lint` runs in CI**, and now covers `sciter_app` as well as the root package. The `-vet` flags
  were configured and enforcing nothing.
- **[`docs/README.md`](docs/README.md)** — an index and a reading order for the 27 documents.
- **[`docs/rules.md`](docs/rules.md)** — the four cross-cutting contracts (thread affinity, `Value`
  ownership, handle lifetime, allocator conventions) in one place.
- **`app_event(n)`** — an application event code that asserts the `FIRST_APPLICATION_EVENT_CODE` floor.

### Known issues

- `just format` exits 1 on `examples/dom_walk.odin` (a local named `inline`) and rewrites
  `custom_loader.odin` and `extension.odin` on every run. Pre-existing; it is why there is no formatter
  gate in CI yet.
- The `examples/` files do not pass `-vet` (unused imports, shadowed `err` in a dozen files), so the CI
  lint step covers the two library packages only.
- The timer tests in `examples/events.odin` flake under load.

## Unreleased — v6.0.4.9

First release. Odin bindings for [Sciter.JS](https://sciter.com/) 6.0.4.9, `SCITER_API_VERSION` 10,
vendored from [gitlab.com/sciter-engine/sciter-js-sdk](https://gitlab.com/sciter-engine/sciter-js-sdk)
tag `6.0.4.9-bis`.

### Packages

- **`package sciter`** — generated from the vendored headers by
  [odin-c-bindgen](https://github.com/karl-zylinski/odin-c-bindgen), 1-to-1 with the C API so that
  sciter.com's documentation reads across directly. All 189 `ISciterAPI` slots, verified against the
  shipped engine. Idiomatic types applied declaratively so they survive regeneration: `bit_set`s for
  the flag enums, real enums for parameters the headers type as `UINT`, and `Scdom_Result` on all 101
  DOM slots. `sciter-om-def.h` is part of the flattened input, so the SOM passport and its property and
  method definition structs are generated rather than hand-written.
- **`package sciter_app`** — hand-written, Odin-shaped: `string` in and out, an `Error` union that
  carries the engine's own result codes, and ownership rules stated rather than hidden. Covers the
  application lifecycle, windows, `Value`, the DOM (elements and nodes, including building and moving
  them), geometry and scrolling, events (including drag-and-drop and custom painting) and element
  timers, graphics (images, paths, text and the 2D renderer), the host resource callback, the request
  API
  (`sciter-x-request.h`) behind it, archives, engine options, and embedding the engine itself.
  Elements and nodes cross into script as Values (`element_to_value` / `element_from_value`), so an
  element can be an argument or a return value; `select_parent` searches upwards the way script's
  `closest` does; attributes enumerate; inline style has its own pair apart from the `style` attribute,
  and `update_element` / `refresh_element_area` / `request_paint` are what re-resolve and repaint it;
  the master stylesheet and the window's `@media` type and flags are settable; popups and mouse capture
  are wrapped; focus and the inspector's highlight are readable and settable; `fire_event` carries a
  named event with a payload, which is the channel to script's `element.on("name", …)`; **behavior
  methods** - `behavior.odin` - reach the native code behind an element, so `do_click` produces a real
  click where `send_event` only injects the event code, `control_type` says which behavior an element
  actually carries, and a `.METHOD_CALL` handler can implement a method for native code to call;
  `element_at` hit-tests a point and `ppi` / `min_width` / `min_height` report the window's metrics;
  **synthesised input** - `send_mouse`, `send_key` and `send_text` push events through the element
  chain the way the window system's own input does, so the intrinsic behaviors run and a button really
  is pressed, a text field really is typed into; `request_animation_frame` is the engine's frame clock,
  with the `.TIMER` inversion where the handler's return value decides whether it fires again; the
  event groups that had no typed accessor now have one - `.FOCUS`, `.SCROLL`, `.ATTRIBUTE_CHANGE`,
  `.GESTURE` and `.DATA_ARRIVED`, with `request_element_data` to cause the last of them; `expando` and
  `call_function` reach an element's script object and the functions visible from it; `combine_url`
  resolves a relative URL against a document, `http_request` fetches with a method and parameters and
  delivers the body as `.DATA_ARRIVED`, and `graphics_caps` reports what the renderer can do;
  `post_callback` is the one call safe from another thread, delivering two words to the engine's thread
  as `Host_Handler.on_posted`, which is how a worker gets its results into the UI, and the rest of the
  notification family is wrapped alongside it - all nine `SCITER_CALLBACK_NOTIFICATION` codes, including
  `on_invalidate_rect` (which a windowed embedding receives constantly, not only a windowless one),
  `on_keyboard_request`, `on_set_cursor`, `on_graphics_failure`, `on_data_loaded`,
  `on_engine_destroyed`, and
  **`on_attach_behavior`**, which answers a `behavior:` name the document asked for with an
  `Event_Handler`, so a *stylesheet* rather than a call site decides which elements get native code;
  and **SOM** -
  `som.odin` - exposes an Odin object to script, with properties and methods, through
  `make_asset_class` / `make_asset` / `set_global_asset`, while `asset_passport` / `asset_members` /
  `asset_method_arity` / `asset_call` / `asset_get` / `asset_set` / `asset_interface` go the other way and read an asset the
  *engine* owns - a behavior's own native interface, which is not the same set of members script sees -
  with `value_to_asset` / `value_from_asset` carrying one in a Value; `value_parse` reads text as a
  value and `value_each` walks a
  container in one call; and `atom` / `atom_name` cover the engine's interned names, which the SOM side
  of the API is keyed on. **Video** - `video.odin` - is the one area that is not in `ISciterAPI` at all:
  `sciter::video_destination` is a C++ class of pure virtuals with no C declaration, so its virtual
  table is laid out by hand, verified against the engine's own `vtable for
  html::behavior::fragmented_video_destination` symbol, and driven through `video_destination` /
  `video_start_streaming` / `video_render_frame` / `video_render_frame_part` /
  `video_render_external_frame` / `video_stop_streaming`. **Windowless views** - `windowless.odin` - are
  the engine's other mode: no window, no pump, and the document drawn into a buffer the host allocated,
  which is what makes Sciter a pane inside somebody else's renderer. `create_windowless` /
  `resize_windowless` / `paint_windowless` / `windowless_heartbeat` / `windowless_mouse` /
  `windowless_key` / `windowless_focus` / `destroy_windowless` are one `SXM_*` message each over
  `SciterProcX`, and everything else in the package works on a view unchanged because its `window` field
  is an ordinary `Window`. The surface can be the host's own memory at the host's own stride, so a view
  renders straight into a rectangle of a larger image with no copy. **The `.OPENGL` backend** renders on
  the GPU instead: `backend` and `device` on `Windowless_Options` hand the engine a `glGetProcAddress`,
  and it draws with its own Skia GPU pipeline into the framebuffer bound to the host's context - a
  texture, if that is what the host bound - so a UI reaches a game engine or a tool with nothing copied
  and nothing uploaded.

### Loading

- The library is opened at runtime — there is no static linking without a commercial licence — with an
  explicit five-step search order and a failure that reports every candidate it tried.
- The `ISciterAPI` version is checked at load and a mismatch is refused, because a mismatched table
  means every call lands in a different function than intended.
- `sciter.adopt()` takes a table the host already has, which is what a native extension needs.

### Examples

Twenty-nine, each a single self-contained file with its explanation in the header comment:
`hello_window`, `api_map`, `load_file`, `eval`, `call_odin_from_js` (a native functor and a SOM asset),
`dom_walk`, `events`, `behavior`, `input`, `task_list` (a whole small application, script-free),
`workbench` (a harder one - ten thousand rows virtualised, editable and live, with type-ahead search
running on a worker thread, rows reordered by dragging, undo/redo over the model, and a second window
that has its own host handler, and the experiment behind `docs/VDOM.md`),
`worker_thread`, `drag_and_drop`, `graphics`, `graphics_gallery` (every call in the 2D API drawn once
and asserted once, and the eight places the renderer is wrong), `video` (frames generated in Odin,
streamed into a `<video>` element), `named_behavior` (widgets a stylesheet asks for by name),
`custom_loader`, `request_loader`, `archive`, `single_binary`, `inspector`,
`windowless` (no window at all - the engine renders into a buffer the host owns, for a pane inside
somebody else's renderer), `windowless_gl` (the same on the GPU: Sciter's own Skia pipeline drawing
straight into the host's OpenGL texture, with an offscreen EGL context),
`integration` (a Sciter pane inside a window this repository owns and draws - raw Xlib, the host's own
frame buffer and event loop, the pane composited in and fully interactive; the SDK's
`demos/integration`), `script_bridge` (the capabilities with no host API at all - clipboard, dialogs,
`@sys`, `@env` - driven by asking the document, with the clipboard's NUL and CF_HTML traps pinned),
`native_child` (the inverse of `integration`: a native X11 window *inside* a Sciter window, tracking an
element's box - which works because the engine's `HWINDOW` is an X11 window id on Linux),
`extension` (Odin as a native extension the engine loads), and `sqlite_extension` (the same mechanism at
the size of a real library binding: `SQLite`, `DB` and `Recordset` over the system's own `libsqlite3`,
opened with `dynlib` so there is no header, no link flag and no development package).

`api_map` is the one to run after any engine change: it walks every slot and resolves each pointer back
to the symbol and module it belongs to — `dladdr` on Linux and macOS, dbghelp plus `VirtualQuery` on
Windows.

### Tests

362 `@(test)` procs living beside the code they cover. The headless ones — `Value` round-trips and
refcounting, native functors, UTF-16 conversion, the four `value_parse` dialects and the error string a
failure comes back as, container enumeration and its early stop, atom round-trips, archive lookup, the
event parameter accessors and the event-code/phase split, the embedded engine's cache naming and
write-once behaviour, the host callback's serve / discard / not-ours decision, and every request
wrapper's answer to a nil handle — run anywhere. The windowed ones, including the event handler
trampoline with its subscription reply, the box/origin geometry queries, attribute enumeration, the
used-value/inline-value split in style, `closest`-style ancestor search, the redraw calls, globals
published and read back, the media-type/media-flag split, the master stylesheet's replace-and-append
behaviour, popups going out of flow and what they refuse, mouse capture's answer to an element in no
document, focus following the `:focus` state, named events with their payloads and the broadcast that
only window handlers see, a SOM asset read, written and called from script, elements crossing into
script and back in both directions, the behavior methods - `do_click` toggling a checkbox where
`send_event` leaves it alone, a method of the caller's own round-tripping through a `.METHOD_CALL`
handler, and the measured fact that no intrinsic behavior implements `GET_VALUE` / `SET_VALUE` /
`IS_EMPTY` on this engine - hit testing and the window metrics, posted callbacks from this thread and
from a worker with their ordering and their delivery by `heartbeat` alone, synthesised mouse and
keyboard input against a button, a checkbox and a text field - including the measured rule that a press
without a button in the set is delivered and then ignored by the behavior - the animation frame's
inverted return value, the element expando in both directions, `combine_url`'s resolutions, the task
list application rendering its model and answering its keys, the workbench's virtualised list - the
window arithmetic at both ends of the model, an edit surviving a re-render only because the model holds
it, a search worker's index arriving through `post_callback` and a stale one being dropped, a drag driven
by synthesised mouse events reordering the model while a press that never moved does not, undo and redo
over the three actions the model has, a second
window answering its own behaviors and its own posted messages, and the one order in which that window
can be closed - the request API driven by a real
document load, and the video destination - the behavior's published member list, the fact that the
member is invisible to script, the asset Value it returns, the interface pointer being a *different*
subobject from the asset pointer, and every streaming call answering true, which is what checks that
the hand-laid vtable is in the right order, and the named behaviors - the request arriving inside
`load_html`, one per name per element, intrinsic names never reaching the host, an unclaimed name not
being an error, elements created later being asked about too, and `.DETACH` firing on both element
removal and document replacement so nothing leaks - skip themselves without a display.
Drag-and-drop is covered by decoding tests only: no test can stage a system drag, so
the event sequence was established by driving a real X11 drag by hand (see `RESEARCH-METHOD.md`).

### Continuous integration

Three workflows in `.github/workflows/`, and between them they automate the mechanical half of
`docs/UPGRADING.md`'s nine-step upgrade procedure.

- **`ci`** — on Linux, the engine's runtime dependencies installed and the suite run under Xvfb with
  `XMODIFIERS=@im=none`: `just api-map-verify`, `just check`, `just example-tests`, and `Value`
  refcounting under ASan. Plus `just cross-check` — `odin check` for `windows_amd64` and
  `darwin_amd64` over both packages, the doc snippets and every portable example, which is the part
  that rots silently when nothing builds for those targets day to day. The `windows-2022` and
  `macos-14` jobs are written and dormant: they skip with a notice while no engine binary is vendored
  for the platform, and committing one turns them on.
- **`bindgen`** — regenerates `sciter.odin` from the vendored headers with a pinned odin-c-bindgen and
  fails if the result differs from what is committed, which is `PLAN.md` §5's byte-identical claim
  turned into a test.
- **`canary`** — weekly, the one that is not a regression gate. It asks GitLab for the newest SDK tag,
  and if it is not the pinned one, swaps that engine's headers and Linux binary into a scratch tree,
  regenerates, and runs the checks against it — committing nothing and moving no pin. A reordered
  `ISciterAPI`, a changed `SCITER_API_VERSION`, or a `flatten_headers.py` patch that stopped matching
  therefore arrives as an issue with a diffstat rather than as a surprise mid-upgrade.

`api_map` prints its table and leaves the judging to a human, which is right for a diagnostic and
useless as a gate, so `.github/scripts/check-api-map.sh` applies the rules its header comment states —
189 slots, `ISciterAPI` version 10, every non-null slot resolving to its own name plus the engine's
`Imp` suffix (with the three real exceptions: the two `Get…API` slots and the C++-mangled
`SciterEGLGetProcAddress`), and the platform's null list unchanged. On Windows, where `sciter.dll`
exports one symbol and there is nothing to resolve, the rule falls back to module containment, which is
the weaker check the example already documented.

### Documentation

Eleven guides in `docs/`, plus `PLAN.md` (findings and decisions), `RESEARCH-METHOD.md` (how each was
established), `UPGRADING.md` (version policy, upgrade procedure, repository-size budget) and
`WINDOWS-CHECKLIST.md`. Every Odin code block in the guides also lives in `docs/snippets/` and is type
checked by `just check`.

### Platforms

| | Vendored | Tested |
| --- | --- | --- |
| Linux x64 | yes | yes |
| Windows x64 | no | no — type checks for `windows_amd64`; see `docs/WINDOWS-CHECKLIST.md` |
| macOS | no | no |

### Known issues

- **X11 input-method segfault.** This machine's engine build crashes in `XSetICFocus` shortly after a
  window takes focus — 3 runs out of 3. `XMODIFIERS=@im=none` avoids it, 0 out of 3. The fault is
  inside the vendored engine binary, not the bindings.
- **`SciterGetViewExpando` is NULL on every platform** in Sciter 6, so there is no `globalThis` Value
  to assign into. `SciterSetVariable` does the job and is what `set_global` uses — with the caveat that
  its `hwndOrNull` parameter is not optional: passing NULL reports success and publishes nothing.
- **A SOM global asset appears at the next document load**, not when it is published, and is withdrawn
  on the same schedule. Publish before `load_html` / `load_file`.
- **A SOM method thunk ignores `argc` and segfaults on a short argument list.** The engine reads a
  method's arguments positionally whatever count it is handed, so calling a passport method with fewer
  arguments than it declares faults inside `sciter::om::member_function<…>::thunk` — measured on
  `edit.insertText`, `select.showPopup` and `terminal.read`. `asset_call` refuses with `.Wrong_Arity`
  rather than making the call, and `asset_method_arity` reports the required count. Extra arguments are
  ignored by the engine and are safe. [`docs/BEHAVIORS.md`](docs/BEHAVIORS.md) carries the arity of
  every intrinsic behavior's methods.
- **The SOM passport's "any property" interceptors are never called.** `prop_getter` / `prop_setter`,
  which take the property atom and would allow a dynamic member list, are ignored; only the
  `properties` and `methods` tables are consulted. That is why an `Asset_Class` is a fixed list and why
  `MAX_ASSET_MEMBERS` exists — the C API passes no member index, so there is one thunk per slot.
- **Clearing `.FOCUS` does not unfocus the window.** The element stops matching `:focus` while
  `SciterGetFocusElement` keeps reporting it. Move the focus instead; there is no "focus nothing".
- **Popups only half-work on a window that has never been shown.** `SciterShowPopup` reports success
  and the element takes its `:popup` state, but the anchor never gains `:owns-popup` and
  `SciterHidePopup` does not clear `:popup`. On a shown window both are correct. `show_popup`
  documents it, and a test pins the boundary so a future engine fixing it is visible.
- **`SciterSetMediaType` only takes effect once per window.** The first call is honoured; every later
  one reports success and changes nothing, across reloads included. `set_media_type` documents it, and
  `set_media_vars` — which does switch every time — is the way to make `@media` state changeable.
- **`SciterGetElementByUID` refuses every UID `SciterGetElementUID` produces** on the vendored 6.x
  engine — either window handle, used or not, made or found — so `element_by_uid` is present and
  documented as non-functional rather than quietly wrong.
- **`SciterAtomNameCB` segfaults on an integer that is not an atom** when the engine has not been
  initialised — it answers with an empty name once it has. There is no way to ask whether an integer is
  an atom, and the number space is shared with an encoding of immediates (1, 2, 3 decode to `"null"`,
  `"false"`, `"true"`), so `atom_name` documents that only atoms `atom` returned may be passed to it.
- **`SciterInsertElement` segfaults on a very large index.** `max(u32)` is the obvious spelling of
  "append" and crashes inside the engine, so `insert_element` clamps to the child count.
- **A bare `SciterDetachElement` can free the element out from under the caller**, and the next use of
  the handle is a segfault rather than an error. `remove_element(el, finalize = false)` takes a
  reference first and hands it to the caller.
- **`gCreate` answers `.NOTSUPPORTED`**: a graphics context cannot be made from an image directly. The
  engine hands one out instead - through `paint_image` offscreen, or a `.DRAW` event onscreen - and
  everything else in the graphics table works normally through those.
- **`.RAW` image encoding is BGRA**, not the `[a,b,g,r]` `sciter-x-graphics.h` describes. Measured by
  clearing an image to pure red and reading `[0, 0, 255, 255]` back.
- **`gStar` is broken.** It answers `.OK` and paints a scatter of disconnected line fragments that never
  closes and never fills - 63 lit pixels against 353 for the same star built by hand, and deterministic,
  so the geometry is wrong rather than the memory. Build the points and use `draw_polygon`.
- **`gFillMode` answers `.NOTSUPPORTED` and the renderer is always even-odd.** Two nested squares wound
  the same way come out with a hole whichever rule is asked for.
- **`gWorldToScreen` and `gScreenToWorld` ignore the transform.** They answer `.OK` and hand the point
  straight back under translate, scale, rotate, skew and a full matrix alike. Drawing *is* transformed;
  only these two accessors lie, so a widget hit-testing a transformed shape must keep its own matrix.
- **`textSetBox` does nothing.** Every width from 200 down to 20 leaves `lines = 1` and the metrics
  untouched on a string whose tightest wrap is 35 wide, and the drawn pixels are identical. Text through
  the graphics API is one line.
- **An unbalanced `gStateSave` kills the process.** A painter that returns with the state stack still
  pushed aborts on the way out - `terminate called without an active exception`, no error code. The
  other direction is harmless: restoring more often than you saved is `.OK`, from an empty stack too.
- **`gDrawText`'s anchor numbers are a numeric keypad**, so 7/8/9 is the top row and 1 is bottom-left.
  This package had `Text_Anchor` upside down until each of the nine was measured; the horizontal half
  was right either way, which is why it went unnoticed.
- **`gRoundedRectangle` reads eight numbers, not four** - an `rx` and an `ry` per corner, as the header's
  own comment says. This package passed four, so the engine read four floats of stack past the end and
  the corners came out square. `draw_rounded_rect` is now a proc group taking either form.
- **`gArc` fills the segment under its chord, not the pie wedge** - the centre of the ellipse stays
  unpainted. And `pathArcTo` has two usable flag combinations rather than four: `clockwise` picks the
  arc, and `clockwise = true` with `large_arc = false` produces no arc at all.
- **`image_from_element` inside a `.DRAW` handler recurses until the stack is gone.** It renders the
  element by painting it, so from within a paint it re-enters the paint already running - ~39,500 frames
  of the engine's own `do_draw` before the segfault. Snapshot between frames.
- **The `vUnWrap*` calls do not fail on the wrong type.** Unwrapping a `Value` holding an integer as a
  graphics handle answers `.OK` and a nil handle, so the handle is the thing to check, not the error.
- **`ValueIsolate` does not break the sharing it exists to break.** After `value_copy`, isolating either
  side (or both) leaves a write through one visible through the other, for maps and arrays, nested or
  not. An independent copy has to be rebuilt.
- **`ValueIntData` reads `.INT` only: a `.BIG_INT` answers 0 with no error**, including one holding 5.
  `value_from(i64(...))` makes a `.BIG_INT`, so anything that went through an `i64` reads back as zero
  through the 32-bit accessor. Use `value_to_i64`.
- **`SciterNodeRemove(finalize = false)` does not produce a node you can reinsert.** The handle stays
  readable - type and text still answer - but every insertion of it is `.INVALID_HANDLE`, with or
  without a `node_add_ref` first, into the old parent or a new one. There is no node move.
- **`SciterNodeSetText` on an element node answers `.OK` and does nothing.** It pairs with
  `SciterNodeGetText`, which reports `""` for an element; both work on the node's own text, and an
  element has none. `set_text(element)` is the call that replaces an element's content.
- **`SciterSetCSS` replaces the document's own stylesheet rather than layering under it.** A window
  sheet that never mentions `#target` leaves it unstyled, and a `!important` document rule loses to a
  plain rule here. A reload drops the window sheet; each call replaces the last; unparseable CSS is
  accepted and still replaces, leaving the document with no styling and no error anywhere.
- **`SciterWindowExec`'s state is reported as `.SHOWN` or `.CLOSED` and nothing else.** `.MINIMIZED`,
  `.MAXIMIZED`, `.FULL_SCREEN` and `.HIDDEN` are accepted and never reflected back, and a window that
  has been created but never shown reports `.CLOSED`, not `.HIDDEN`.
- **Closing a secondary window that has a document crashes the engine on the next pump.** The segfault
  is inside its own `check_paint`, down in `GetWindowSizeX11` on a window it destroyed but left on the
  paint list - and the window stays on that list, so every later pump in the process dies too. A window
  that never had a document closes cleanly. **There is exactly one order that also works: `hide`, then
  at least one turn of the pump, then `close`** - the pump is what takes the window off the paint list,
  so hiding and closing in the same turn crashes like closing outright, and unloading the document
  first (`load_html` of an empty page) crashes too. Five teardowns were measured, on windows that had
  been shown and on windows that never were; the table is on `close` in `window.odin`, and
  `examples/workbench.odin` closes its details window that way and pins the order with a test.
- **The windowless `.OPENGL` backend needs a *desktop* GL context.** On a GLES 3.2 context `SXM_PAINT`
  answers true and draws nothing, because Skia compiles `#version 150` desktop shaders the driver
  refuses; desktop GL 4.6 works in core and compatibility profiles alike. `SL_TARGET_OPENGLES` as a
  backend is refused outright - `SXM_PAINT` answers false on either kind of context.
- **A GPU backend with a nil `device` segfaults the engine** on the first paint, so `create_windowless`
  refuses it. It wants a `glGetProcAddress`-shaped function; the engine's own `SciterEGLGetProcAddress`
  behaves identically to the host's.
- **A GPU-backed view's target is fixed when it is created**, not read at paint time, and the paint
  leaves the engine's own framebuffer bound rather than restoring the host's.
- **A windowless view still needs a display.** With `DISPLAY` and `WAYLAND_DISPLAY` both unset on Linux,
  `SXM_CREATE` segfaults - before a document, a surface or a paint. "Windowless" means the engine makes
  no window of its own, not that it runs without a windowing system.
- **One `SXM_DESTROY` ends windowless mode for the process.** After any destroy the next `SXM_CREATE`
  segfaults inside the create call, with the same key or a fresh one. Views created before any destroy
  coexist; a second destroy of the same view is a harmless false. Swap a view's document with
  `load_html` rather than destroying and recreating it.
- **`SXM_HEARTBIT`'s timestamp is ignored; windowless script timers run on the wall clock.**
  `setTimeout`, `setInterval` and `requestAnimationFrame` fire as real time passes, whatever `elapsed`
  says - passing 0 every time behaves identically - and do not fire at all without a heartbeat to drain
  them. A host rendering frames faster than real time therefore sees no timers and must drive animation
  itself.
- **`MOUSE_PARAMS::button_state` and `alt_state` are masks, not choices.** The headers type both as
  `MOUSE_BUTTONS` / `KEYBOARD_STATES` enums whose members are single bits, but the fields carry every
  button held and every modifier down at once - two buttons is 3, nothing held is 0, and neither is a
  member. Both are `bit_set`s here (`Mouse_Button` / `Keyboard_State` singulars, the C-named plurals in
  signatures), and the headers' `KEYBOARD_STATE_SHIFT` / `_CONTROL` / `_ALT` / `_COMMAND` become
  multi-bit constants, being the left-or-right pairs rather than keys of their own. Applied in
  `bindgen.sjson`, so regeneration keeps it.
- **The remaining unconditional "enum wearing a UINT" event fields are typed**: `MOUSE_PARAMS`'
  `cursor_type` and `dragging_mode`, `SCROLL_PARAMS::source`, `EXCHANGE_PARAMS::mode`, and the three
  `dataType` fields, plus `SciterRequestElementData` / `SciterHttpRequest`'s type parameters. Fields
  whose enum is chosen by a *sibling* field - `SCROLL_PARAMS::reason`, `FOCUS_PARAMS::cause`,
  `SCN_SET_CURSOR::cursorId`, every `cmd` - stay `UINT` on purpose, and `bindgen.sjson` says why.
- **Element-child and node-child indices are different numberings of the same parent**, and now
  different types: `Child_Index` counts elements only, `Node_Index` counts text and comment nodes too -
  measured, five node children against two element children for a `<ul>` written across several lines.
  Handing one to the other's getter used to compile and quietly return the wrong node; it is a compile
  error now. Range loops, arithmetic and comparison are unchanged, so the whole codebase needed five
  conversions, every one of them at a real model-to-DOM boundary.
- **`SciterGraphicsCaps` is an ordinal scale, not a capability bitmask.** `sciter-x-def.h` documents it
  as 0 = no compatible graphics, 1 = compatible but Direct2D uses the WARP software driver, 2 = Direct2D
  hardware backend - so `Graphics_Caps` is an enum of those three. The wording predates this engine's
  Skia backend and names an API that does not exist off Windows, and what the number means elsewhere is
  not stated upstream; the vendored Linux build answers `.Software`. An earlier note here saying the
  headers documented nothing about it was wrong.
- **A request's parameters, request headers and response headers are three independently numbered
  lists**, and the C API indexes all three with a bare `UINT`. `Parameter_Index`,
  `Request_Header_Index` and `Response_Header_Index` keep them apart, because an index from the wrong
  list reads a real entry and reports success - wrong data rather than an error.
- **`request_time`** returns the duration between the two `request_times` timestamps as a
  `time.Duration`, with a `done` flag that is false while `ended` is still 0. The timestamps themselves
  stay bare integers: they are on the engine's own clock with an epoch nothing here relates to a wall
  clock, so only the difference means anything.
- **`CONTENT_CHANGE_BITS` is a mask too** - the header says `CONTENT_CHANGED`'s reason "is combination
  of CONTENT_CHANGE_BITS", so content both added and removed in one change is 3, which is not a member.
  A `bit_set` now. Nothing cast it before, because it arrives in `BEHAVIOR_EVENT_PARAMS::reason` and
  that stays untyped; this is the shape corrected before something relies on it.
- **`VALUE::t` is a `Value_Type`** rather than a `UINT`. Measured across every constructor here - int,
  float, bool, string, array, map, undefined, error string - `t` is exactly the type each time, 0 is
  `T_UNDEFINED` and a real member, and no flag bits appear; the qualifiers all live in `u`, which is why
  that one stays a `UINT`.
- **`MOUSE_EVENTS::DRAGGING` (0x100) is OR'ed into the event code**, and it sits below the phase bits,
  so masking the code with `0x7FFF` is not enough to recover it: a drag's `MOUSE_MOVE` arrives as 258.
  `Mouse_Event` splits it out as `dragging` / `dragged`.
- **`SXM_RESOLUTION` crashes one message later**, in `html::iwindow::setup_window_frame` on a view that
  has no native window frame. There is deliberately no wrapper for it; a windowless view runs at the
  engine's default DPI.
- **A SOM method's `params` caps how many arguments *script* may pass.** A member declared `params = 1`
  and called as `obj.method(a, b, c)` receives only `a`; the rest are dropped with no error anywhere.
  Declaring more than a caller passes is harmless. Found through `sqlite_extension.odin`, where it
  presented as every bound database parameter arriving as NULL. (The host-side rule is the opposite -
  `asset_call` requires *at least* `params`, because the engine's thunks segfault on a short list.)
- **`HWINDOW` is an X11 window id on Linux**, not an opaque handle. The type is `void*` and the value is
  the engine's own window: `XGetWindowAttributes` succeeds on it, a native child created with it as
  parent maps and stays viewable across the engine's repaints. Not a defect - a capability, and the one
  `native_child.odin` rests on.
- **Clipboard strings come back with a trailing NUL inside them**, on the text flavour as much as the
  HTML one, so `"hello\x00" != "hello"` and a host comparing what it wrote with what it read fails for
  a reason that does not show in a log. HTML additionally comes back wrapped in
  `<html><!--StartFragment-->…<!--EndFragment--></html>`. `script_bridge.odin` trims both.
- **`eval` cannot import a module.** `eval("await import(\"@sys\")")` fails to *parse* - the expression
  evaluator has no top-level await and no dynamic import - so `@sys`, `@env`, `@sciter` and `@storage`
  are unreachable from `eval` at any privilege level. A `<script type="module">` that hangs them on
  `globalThis` is the way in; see `docs/JS-RUNTIME.md`.
- **A behavior's event is posted, so it arrives on the next windowless heartbeat**, not inside the
  `windowless_mouse` call that caused it. Measured: straight after the `.MOUSE_UP` a `<button>`'s
  `click` handler has not run; after one `windowless_heartbeat` it has. (Two earlier notes here were
  wrong and are retracted: windowless mouse input works, *and* the intrinsic behaviors act on it - a
  click presses a button, toggles a checkbox and focuses an editor. Both measurements used pages whose
  widgets were `position:absolute`, which this engine collapses - see the next entry - so every event
  landed on `<body>`.)
- **Out-of-flow elements collapse, two ways.** A **percentage height** on an absolutely positioned
  element lays out as 1px (the width resolves), and an **inline-level widget** - `<button>`,
  `<input>` - positioned absolutely lays out 1x1 entirely, whatever size the CSS asks for;
  `display: block` restores it. A `<div>`, a `<span>` and a `<select>` in the same position are fine,
  and `position: fixed` behaves like `absolute`. An element with no box receives no events, which is
  how three separate findings in this file came to be wrong. `flow: stack` is the alternative that
  works. See `docs/html-css-js.md`.
- **`.FULL_SCREEN` changes the monitor's display mode and nothing puts it back.** A 300x200 window taken
  full screen on X11 dropped a 1920x1200 panel to 320x180, and it stayed there after the process exited.
- **`SciterDataReady` works from inside a load callback and nowhere else.** Called after the callback
  returns it answers false, for a request left in flight by `.DELAYED` as well as for a URL nothing
  asked for. `SciterDataReadyAsync`, which carries the request id, is the one that answers later.
- **A URL's query string is not parsed into request parameters.** `request_url` hands back the whole
  string and `request_parameter_count` is zero; what does arrive there is what `http_request` was given.
  The engine also appends a `Content-Encoding` response header of its own once a request is answered.
- **`SciterSetupDebugOutput` reports the document's script errors, not `eval`'s.** A `<script>` that
  will not parse produces a `.SCRIPT` diagnostic at `.ERROR` and an unhandled throw one at `.WARNING`,
  while a failing `eval` produces nothing at all - its return value is the only report.
- **A drop target must consume `.DRAG` as well as `.WILL_ACCEPT_DROP`.** `sciter-x-behavior.h` documents
  only the second; consuming just that leaves the engine telling the drag source it is not interested,
  and no `.DROP` arrives. Measured by driving a real X11 drag against every combination.
- **Drag-and-drop on Linux delivers the events but not the data**: a real X11 drop arrives as
  `.DROP` with the right target and position and an empty payload map. There is also no drag *source* -
  script's `Window.this.performDrag` returns null immediately, and `ISciterAPI` has no slot for it.
- **A deferred resource answer does not rewind the document.** Taking a request over with `.MYSELF` and
  answering it later works for what the document consumes on arrival - a deferred image cleared its
  element's `.INCOMPLETE` and `.BUSY` state as soon as the answer landed - but a `<script src>` answered
  after parsing has moved past it is fetched and never executed.
- **`request_requestor` reports the element the resource is for, not the one that named it**: a
  stylesheet pulled in by `<link>` in the head reports `html`.
- **A `.TIMER` handler must return true to keep its timer running.** The return value is inverted for
  that one group, so a handler ending in the usual `return false` gets exactly one tick. Timers are
  also delivered only to handlers on the element they were set on — they do not bubble.
- **`scroll_to_view` does nothing until the window has been shown and rendered at least once** — the
  call succeeds and the scroll position does not change. `set_scroll_pos` has no such requirement.
  Without `to_top` the scroll is also applied on the engine's own schedule, so reading the position
  straight back can show the old one.
- **`behavior: video` needs libVLC and fails silently without it.** `<video>`'s default behavior is
  implemented on top of libVLC, dlopened by name. Missing, the behavior does not attach at all: the
  element stays inert, `element_asset` answers `.OPERATION_FAILED`, `VIDEO_BIND_RQ` is never sent, and
  script sees no `load` / `play` / `isPlaying` — with no error reported anywhere. `behavior:
  custom-video`, which `video.odin` uses, needs no codec library.
- **`renderingSite` is in the video behavior's passport and not in script.** `element_asset(el,
  "video")` lists it; `document.$("video").renderingSite()` answers "not a function". Neither the
  `custom-video` behavior nor the method appears in the SDK's documentation. A passport is the native
  interface, and the script interface is a separate decision each behavior makes.
- **A `som_asset_t*` is not the object's address.** For `<video>` the `video_destination` base
  subobject is 24 bytes before the `som_asset_t` the API hands back, and the wrong offset puts a
  destructor where `is_alive` should be. `asset_interface` is the only thing that knows; nothing should
  compute one by hand.
- **A `behavior:` name the engine implements never reaches the host.** `SC_ATTACH_BEHAVIOR` is sent only
  for names the engine does not know, so `behavior: button` cannot be intercepted and a name of your own
  cannot shadow a built-in. The set of names it implements is not enumerable.
- **There is no "behavior detached" notification.** A handler returned from `on_attach_behavior` is
  allocated per element and can only free itself from `Initialization_Events.DETACH`, which arrives on
  element removal and on document replacement. Note that `HANDLE_INITIALIZATION` is `0x0000`, so that
  group is the *empty* `Event_Groups` set rather than a bit of its own - easy to read past in the header,
  and missing it leaks one handler per behavior per load.
