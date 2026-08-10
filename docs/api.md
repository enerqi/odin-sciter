# API guide

A tour of `package sciter_app`, the Odin-shaped layer, plus the conventions that hold across all of it.
For the generated `package sciter`, [sciter.com's documentation](https://docs.sciter.com/) reads across
1-to-1 — `api.SciterCreateWindow` is `SciterCreateWindow`.

Everything below is in [`sciter_app/`](../sciter_app/), one file per area, and every procedure has a
doc comment above it. This page is the map, not a replacement for reading them.

## Conventions

**Errors.** Anything that can fail returns `Error`, a `#shared_nil` union:

```odin
Error :: union #shared_nil {
	Api_Error,              // Not_Loaded, Window_Failed, Load_Failed, Eval_Failed, Call_Failed,
	                        // Not_Found, Wrong_Type
	sciter.Scdom_Result,    // the engine's own DOM result code
	sciter.Value_Result,    // ... and its Value result code
}
```

`nil` is success. The engine's own codes are carried through rather than flattened, because the
difference between `.INVALID_HANDLE` and `.PASSIVE_HANDLE` is the whole diagnosis when a DOM call
fails. Two engine codes are *successes* with negative values — `.OK_NOT_HANDLED` and `.OK_TRUE` — and
the wrapper accounts for that, so an `Error` you receive is always a real failure.

`or_return` composes as usual:

```odin
do_thing :: proc(window: sciter_app.Window) -> sciter_app.Error {
	root := sciter_app.root(window) or_return
	el   := sciter_app.select_first(root, "#count") or_return
	return sciter_app.set_text(el, "0")
}
```

**Allocators.** Anything that returns a string or a slice takes an `allocator`, defaulting to
`context.allocator`, and the result is yours to `delete`. Arguments built for a call go through
`context.temp_allocator` internally. Borrowed results are documented as such: `tag`, `value_to_bytes`
and `archive_item` hand back memory the engine owns.

**Strings.** You pass and receive Odin `string`s. The C API is UTF-16 throughout and the wrapper
converts; `utf16_from_string`, `string_from_utf16` and `string_from_utf16_cstring` are exported for
when you drop to the raw table.

**Values.** Ownership rules are in
[`calling-between-odin-and-js.md`](./calling-between-odin-and-js.md#value) and are not repeated in
every signature: anything a procedure returns as a `Value` owns a reference and needs `value_clear`;
anything you pass in is not consumed.

**Callbacks.** Every handler struct you hand to the engine — `Event_Handler`, `Host_Handler` — has its
address stored by the engine, so it must not move and must outlive the attachment. Each captures the
calling `context` at attach time, because the engine calls back as `proc "system"`.

## Application — `app.odin`

| | |
| --- | --- |
| `load_engine(path := "") -> bool` | `sciter.load` plus a useful error message on stderr |
| `init(args: []string = nil, allocator := context.allocator) -> Error` | `SCITER_APP_INIT`; defaults to `os.args`. Required before any window. |
| `run() -> int` | the message pump; returns when `stop` is called or the last `.MAIN` window closes |
| `run_once() -> bool` | one iteration, for sharing the thread with another event source |
| `heartbeat()` | services tasks and timers without processing input; pair with `run_once` |
| `stop()` | asks the pump to return. Safe from an event handler. |
| `shutdown()` | releases the engine's resources; call after `run` returns |
| `version() -> [4]u32` | `[major, minor, revision, build]` |
| `set_option(option, value: uintptr, window = nil) -> Error` | any `Sciter_Rt_Options`; `value`'s meaning is chosen by `option` |
| `set_script_features(features: sciter.Script_Runtime_Features) -> Error` | `{.FILE_IO, .SOCKET_IO, .EVAL, .SYSINFO, .CMODULES}` — all denied by default |
| `set_debug_mode(enabled := true, window = nil) -> Error` | lets the SDK's inspector attach; pairs with the window's `.ENABLE_DEBUG` flag |
| `set_default_debug_output(window: Window = nil)` | routes CSS/script diagnostics to stderr |
| `set_debug_output(handler, param, window)` | the same, with your own `proc "system"` |

Install the debug output before loading anything. Without it a CSS typo, a bad URL and a script
exception are all completely silent.

## Windows — `window.odin`

| | |
| --- | --- |
| `create_window(opts := Window_Options{}) -> (Window, Error)` | `{}` flags means `{.MAIN}`; `0,0` size lets the engine choose |
| `load_html(window, html: string, base_url := "") -> Error` | UTF-8 HTML. Without a base URL, relative references have nowhere to look. |
| `load_file(window, url: string) -> Error` | a path, `file://`, `http://`, or `this://app/...` |
| `set_home_url(window, url) -> Error` | the base for relative references |
| `set_css(window, css, base_url := "", media_type := "") -> Error` | adds to the *master* stylesheet, under every document's own CSS |
| `show` / `hide` / `close` / `activate` | window state; a window is created hidden |
| `window_state` / `set_window_state` | the full `Sciter_Window_State` |
| `eval(window, script) -> (Value, Error)` | script in the global scope |
| `call(window, function: string, args: ..Value) -> (Value, Error)` | a function already defined in the document |
| `set_global(window, name: string, value: ^Value) -> Error` | publishes into `globalThis`; redo after every load |
| `root(window) -> (Element, Error)` | the `<html>` element |

`Window_Options` is `{x, y, width, height: i32, flags: sciter.Sciter_Create_Window_Flags, parent: Window}`.

Sciter 6 removed the `SW_TITLEBAR` / `SW_RESIZEABLE` / `SW_CONTROLS` / `SW_GLASSY` / `SW_ALPHA` /
`SW_TOOL` flags 4.x had; a plain top-level window is the default and chrome is a CSS concern. What
remains is `.CHILD`, `.MAIN`, `.POPUP`, `.ENABLE_DEBUG`. **The window title comes from the document's
`<title>`** — there is no title API.

## Values — `value.odin`

Lifecycle: `value_init`, `value_clear`, `value_copy`, `value_isolate`, `value_equal`.

Inspection: `value_type` → `(sciter.Value_Type, units: u32)`, `value_is_undefined`, `value_is_null`,
`value_is_function`.

Construction — each returns a `Value` you own: `value_from_bool`, `value_from_int` (i32),
`value_from_i64`, `value_from_f64`, `value_from_string`, `value_from_bytes`, `value_make_array`, and
the `value_from` overload group over all of them.

Extraction: `value_to_bool`, `value_to_int`, `value_to_i64`, `value_to_f64`, `value_to_string`,
`value_to_bytes`, and `value_to_display_string(v, how := .SIMPLE)` which renders *any* value — pass
`.JSON_LITERAL` for containers.

Containers, arrays and maps being the same machinery: `value_len`, `value_at`, `value_key_at`,
`value_set_at`, `value_get`, `value_set`, `value_get_key`, `value_set_key`.

Functions: `value_from_function(fn: Native_Function, user_data: rawptr = nil, allocator)` wraps an Odin
procedure so script can call it; `value_invoke(fn, this = nil, args = nil)` calls one you hold.

```odin
Native_Function :: proc(args: []Value, user_data: rawptr) -> Value
```

`args` is borrowed for the call. The returned `Value` is handed to the engine, which takes ownership —
do not clear it.

## The DOM — `dom.odin`

`Element` (a distinct `sciter.Helement`) and `Node` (`sciter.Hnode`).

| | |
| --- | --- |
| `use_element` / `unuse_element` | reference counting, needed only to hold a handle past the current callback |
| `select_first(el, selector) -> (Element, Error)` | `.Not_Found` if nothing matched |
| `select_all(el, selector, allocator) -> ([]Element, Error)` | document order; `delete` the slice |
| `child_count` / `child` / `parent` | traversal, elements only |
| `tag(el) -> (string, Error)` | borrowed — do not free |
| `text` / `set_text` | text content |
| `html(el, outer := false)` / `set_html(el, html, where_ := .SIH_REPLACE_CONTENT)` | markup |
| `attribute` / `set_attribute` | `""` reads an absent attribute and removes an existing one |
| `element_state` / `set_element_state` | the CSS pseudo-class bits as a `bit_set` |
| `element_value` / `set_element_value` | script's `element.value`, typed by the attached behavior |
| `eval_element(el, script)` | script with `this` bound to the element |
| `call_method(el, method, args: ..Value)` | a method on the element's script object, including behavior methods |

`state(x)` and `set_state(x, …)` are overload groups resolving to the element or window version.

## Geometry — `layout.odin`

Reads the result of layout, so it answers once layout has run and not before.

| | |
| --- | --- |
| `location(el, box := .Border, origin := .Root) -> (Rect, Error)` | `Rect` is `x, y, width, height` |
| `Box` | `.Content`, `.Padding`, `.Border`, `.Margin`, `.Background_Image`, `.Foreground_Image`, `.Scrollable` |
| `Origin` | `.Root`, `.Self`, `.Container`, `.View` — the two halves of one C flag word, kept apart |
| `visible(el)` / `enabled(el)` | `display: none` has no box; hidden is not disabled |
| `intrinsic_widths(el) -> (min, max, Error)` | min-content and max-content |
| `intrinsic_height(el, for_width) -> (i32, Error)` | how tall it becomes at that width |
| `scroll_info(el) -> (Scroll_Info, Error)` | `pos`, `view` and `content` together |
| `set_scroll_pos(el, pos, smooth := false)` | clamped, not refused |
| `scroll_to_view(el, to_top := false, smooth := false)` | needs a shown window — see [`dom.md`](./dom.md#geometry) |

An element with no box keeps reporting the last rectangle it had, so `location` is never the way to
ask whether an element is there — `visible` is.

## Nodes — `node.odin`

The text-and-comments half of the DOM. `Node` is a distinct `sciter.Hnode`.

| | |
| --- | --- |
| `node_add_ref` / `node_release` | node handles are **not** reference counted on the way out |
| `node_from_element` / `node_to_element` | crossing between the two views; the latter fails on a text node |
| `node_type` | `.ELEMENT`, `.TEXT`, `.COMMENT` |
| `node_first_child` / `node_last_child` / `node_next_sibling` / `node_prev_sibling` | `.Not_Found` ends the walk |
| `node_child` / `node_child_count` / `node_parent` | `node_parent` returns an `Element` |
| `node_text` / `node_set_text` | the text a `.TEXT` or `.COMMENT` node carries |
| `make_text_node` / `make_comment_node` | detached, and yours until inserted |
| `node_insert(node, where_, what)` | `.BEFORE`, `.AFTER`, `.APPEND`, `.PREPEND` |
| `node_remove(node, finalize := true)` | `false` detaches instead of destroying — that is a move |

## Events — `events.odin`

```odin
Event_Handler :: struct {
	subscription: sciter.Event_Groups,
	on_event:     proc(handler: ^Event_Handler, event: Event) -> bool,
	user_data:    rawptr,
	ctx:          runtime.Context,   // captured at attach time
}
```

`attach_handler(el, &h)` / `attach_window_handler(window, &h)` / `detach_handler` /
`detach_window_handler`.

The handler must not move and must outlive the attachment. `subscription` is the answer to the
engine's `SUBSCRIPTIONS_REQUEST`, which the wrapper replies to for you — a handler subscribing to
nothing receives nothing.

Decoding: `event_code(cmd)`, `event_phase(cmd)` → `Event_Phase{.Bubbling, .Sinking, .Handled}`, and
the typed accessors `behavior_event`, `mouse_event`, `key_event`, each returning `ok = false` if the
event is not of that group and each exposing `.raw` for what is not surfaced.

Synthesising: `send_event(el, code, source, reason) -> (handled, Error)` and `post_event(...)`. These
bypass the intrinsic behavior, and a nil `source` delivers nothing at all — see
[`events.md`](./events.md#synthesising-events).

## Host callback — `host.odin`

```odin
Host_Handler :: struct {
	on_load_data: proc(handler: ^Host_Handler, request: ^Load_Request) -> Load_Result,
	user_data:    rawptr,
	ctx:          runtime.Context,
}
```

`set_host_handler(window, &h)` — **before** loading a document. `serve(request, data)` answers with
bytes and returns the right code. `Load_Request` is `{uri: string, type: Sciter_Resource_Type, raw:
^Scn_Load_Data}`; `Load_Result` is the engine's `.OK` / `.DISCARD` / `.DELAYED` / `.MYSELF`.

For an answer that cannot be given inside the callback: return `.DELAYED`, keep `request.raw.requestId`,
and answer later with `data_ready_async(window, uri, data, request_id)`. Every delayed request must
eventually be answered or it leaks. `data_ready(window, uri, data)` is the same push without a request
id; both copy the data, unlike `serve`.

## Archives — `archive.odin`

`open_archive(blob: []u8)` (the blob must stay valid and unmoved — use `#load`), `close_archive`,
`archive_item(archive, path) -> ([]u8, bool)`, and
`serve_archive(request, archive, prefix := ARCHIVE_URL_PREFIX) -> (Load_Result, handled: bool)`.
`ARCHIVE_URL_PREFIX` is `"this://app/"`, a host convention rather than an engine feature.

## Embedding the engine — `embed.odin`

`load_embedded(blob: []u8, allocator) -> (path: string, err: Error)` — writes the engine to
`<cache>/odin-sciter/<hash>/libsciter.so` and loads it. See
[`deployment.md`](./deployment.md#one-file-or-two) for when that is a good idea.

## Utilities — `sciter_app.odin`

`utf16_len`, `utf16_from_string`, `string_from_utf16`, `string_from_utf16_cstring`. The encoder
NUL-terminates and includes the terminator in `len`, so the length to pass to the engine is
`len(result) - 1`.

## Dropping to the raw table

Anything not covered above is one call away, and mixing is expected rather than a fallback:

```odin
import sciter ".."

api := sciter.api()
api.SciterSetOption(nil, .SET_DEBUG_MODE, 1)                     // let the inspector attach
api.SciterCreateWindow({.MAIN, .ENABLE_DEBUG}, &frame, nil, nil, nil)
```

`sciter_app.Window` is a distinct `rawptr`, `Element` a distinct `sciter.Helement`, and `Value` is
`sciter.Value` outright, so converting is a cast or nothing at all.

Things you will reach for the raw table for today: graphics (`SciterGraphics*`), the request API
(`sciter-x-request.h`), element timers (`SciterSetTimer`), drag-and-drop,
`SciterSetHighlightedElement`, and `SciterUpdateElement` / `SciterRefreshElementArea`.

From `package sciter` itself: `load`, `adopt`, `api`, `loaded`, `unload`, `LIBRARY_NAME`,
`SCITER_API_VERSION`, `Scdom_Result`, and the ~1800 lines of generated types.

## Naming, so you can guess

- `x` reads, `set_x` writes — `text`/`set_text`, `attribute`/`set_attribute`
- `value_*` is the variant type; `element_*` disambiguates against a window equivalent
- `*_from_*` constructs and you own the result; `*_to_*` extracts
- upstream spellings survive where they appear in signatures you write: `Scdom_Result`,
  `Sciter_Window_State`, `Event_Groups`
- generated enum members keep their upstream values with the common prefix stripped: `SW_MAIN` is
  `.MAIN`, `STATE_HOVER` is `.HOVER`, `SIH_REPLACE_CONTENT` keeps its prefix because stripping it
  would have produced names that exist nowhere upstream
