# Changelog

Releases are named after the Sciter engine they vendor, because that is the question anyone reading a
tag actually has. `v6.0.4.9` is the first release against engine 6.0.4.9; `v6.0.4.9-2` would be a
second release of the bindings against the same engine. The policy, and the upgrade procedure behind
it, are in [`docs/UPGRADING.md`](docs/UPGRADING.md).

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
  `asset_call` / `asset_get` / `asset_set` / `asset_interface` go the other way and read an asset the
  *engine* owns - a behavior's own native interface, which is not the same set of members script sees -
  with `value_to_asset` / `value_from_asset` carrying one in a Value; `value_parse` reads text as a
  value and `value_each` walks a
  container in one call; and `atom` / `atom_name` cover the engine's interned names, which the SOM side
  of the API is keyed on. **Video** - `video.odin` - is the one area that is not in `ISciterAPI` at all:
  `sciter::video_destination` is a C++ class of pure virtuals with no C declaration, so its virtual
  table is laid out by hand, verified against the engine's own `vtable for
  html::behavior::fragmented_video_destination` symbol, and driven through `video_destination` /
  `video_start_streaming` / `video_render_frame` / `video_render_frame_part` /
  `video_render_external_frame` / `video_stop_streaming`.

### Loading

- The library is opened at runtime — there is no static linking without a commercial licence — with an
  explicit five-step search order and a failure that reports every candidate it tried.
- The `ISciterAPI` version is checked at load and a mismatch is refused, because a mismatched table
  means every call lands in a different function than intended.
- `sciter.adopt()` takes a table the host already has, which is what a native extension needs.

### Examples

Twenty-three, each a single self-contained file with its explanation in the header comment:
`hello_window`, `api_map`, `load_file`, `eval`, `call_odin_from_js` (a native functor and a SOM asset),
`dom_walk`, `events`, `behavior`, `input`, `task_list` (a whole small application, script-free),
`workbench` (a harder one - ten thousand rows virtualised, editable and live, and the experiment behind
`docs/VDOM.md`),
`worker_thread`, `drag_and_drop`, `graphics`, `graphics_gallery` (every call in the 2D API drawn once
and asserted once, and the eight places the renderer is wrong), `video` (frames generated in Odin,
streamed into a `<video>` element), `named_behavior` (widgets a stylesheet asks for by name),
`custom_loader`, `request_loader`, `archive`, `single_binary`, `inspector`, and `extension` (Odin as a
native extension the engine loads).

`api_map` is the one to run after any engine change: it walks every slot and resolves each pointer back
to the symbol and module it belongs to — `dladdr` on Linux and macOS, dbghelp plus `VirtualQuery` on
Windows.

### Tests

309 `@(test)` procs living beside the code they cover. The headless ones — `Value` round-trips and
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
list application rendering its model and answering its keys, the request API driven by a real
document load, and the video destination - the behavior's published member list, the fact that the
member is invisible to script, the asset Value it returns, the interface pointer being a *different*
subobject from the asset pointer, and every streaming call answering true, which is what checks that
the hand-laid vtable is in the right order, and the named behaviors - the request arriving inside
`load_html`, one per name per element, intrinsic names never reaching the host, an unclaimed name not
being an error, elements created later being asked about too, and `.DETACH` firing on both element
removal and document replacement so nothing leaks - skip themselves without a display.
Drag-and-drop is covered by decoding tests only: no test can stage a system drag, so
the event sequence was established by driving a real X11 drag by hand (see `RESEARCH-METHOD.md`).

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
  that never had a document closes cleanly. `close` is therefore the one wrapper with no test.
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
