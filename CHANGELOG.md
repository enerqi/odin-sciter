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
  named event with a payload, which is the channel to script's `element.on("name", …)`; and **SOM** -
  `som.odin` - exposes an Odin object to script, with properties and methods, through
  `make_asset_class` / `make_asset` / `set_global_asset`; `value_parse` reads text as a value and `value_each` walks a
  container in one call; and `atom` / `atom_name` cover the engine's interned names, which the SOM side
  of the API is keyed on.

### Loading

- The library is opened at runtime — there is no static linking without a commercial licence — with an
  explicit five-step search order and a failure that reports every candidate it tried.
- The `ISciterAPI` version is checked at load and a mismatch is refused, because a mismatched table
  means every call lands in a different function than intended.
- `sciter.adopt()` takes a table the host already has, which is what a native extension needs.

### Examples

Fifteen, each a single self-contained file with its explanation in the header comment: `hello_window`,
`api_map`, `load_file`, `eval`, `call_odin_from_js`, `dom_walk`, `events`, `drag_and_drop`, `graphics`,
`custom_loader`, `request_loader`, `archive`, `single_binary`, `inspector`, and `extension` (Odin as a
native extension the engine loads).

`api_map` is the one to run after any engine change: it walks every slot and resolves each pointer back
to the symbol and module it belongs to — `dladdr` on Linux and macOS, dbghelp plus `VirtualQuery` on
Windows.

### Tests

123 `@(test)` procs living beside the code they cover. The headless ones — `Value` round-trips and
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
script and back in both directions, and the request API driven by a real document load, skip themselves
without a display. Drag-and-drop is covered by decoding tests only: no test can stage a system drag, so
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
