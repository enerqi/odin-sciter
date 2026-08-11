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
	sciter.Request_Result,  // ... and its request result code
	sciter.Graphin_Result,  // ... and its graphics result code
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
| `set_master_css(css) -> Error` | the sheet under every document in the process. **Replaces**; `""` is refused. |
| `append_master_css(css) -> Error` | adds to it, keeping what is there |

Install the debug output before loading anything. Without it a CSS typo, a bad URL and a script
exception are all completely silent.

## Windows — `window.odin`

| | |
| --- | --- |
| `create_window(opts := Window_Options{}) -> (Window, Error)` | `{}` flags means `{.MAIN}`; `0,0` size lets the engine choose |
| `load_html(window, html: string, base_url := "") -> Error` | UTF-8 HTML. Without a base URL, relative references have nowhere to look. |
| `load_file(window, url: string) -> Error` | a path, `file://`, `http://`, or `this://app/...` |
| `set_home_url(window, url) -> Error` | the base for relative references |
| `set_css(window, css, base_url := "", media_type := "") -> Error` | this window's sheet, under the document's own CSS and over the master one |
| `set_media_type(window, media_type) -> Error` | `"screen"` (default), `"print"`, … — **only the first call on a window takes** |
| `set_media_vars(window, vars: ^Value) -> Error` | media *flags*: `{dark: true}` makes `@media dark` match. Merges; switches every time. |
| `update_window(window)` | repaint what is dirty now, rather than at the next turn of the pump |
| `show` / `hide` / `close` / `activate` | window state; a window is created hidden |
| `window_state` / `set_window_state` | the full `Sciter_Window_State` |
| `eval(window, script) -> (Value, Error)` | script in the global scope |
| `call(window, function: string, args: ..Value) -> (Value, Error)` | a function already defined in the document |
| `set_global(window, name: string, value: ^Value) -> Error` | publishes into `globalThis`; redo after every load |
| `global(window, name) -> (Value, Error)` | reads one back; a name nobody set is undefined, not an error |
| `focus_element(window) -> (Element, Error)` | who has the keyboard focus; `.Not_Found` when nothing does |
| `set_focus(element) -> Error` | moves it. There is no "clear the focus" — see [`dom.md`](./dom.md#focus) |
| `highlighted_element` / `set_highlighted_element(window, el)` | the inspector's debug outline; a nil element clears it |
| `root(window) -> (Element, Error)` | the `<html>` element |

`Window_Options` is `{x, y, width, height: i32, flags: sciter.Sciter_Create_Window_Flags, parent: Window}`.

Sciter 6 removed the `SW_TITLEBAR` / `SW_RESIZEABLE` / `SW_CONTROLS` / `SW_GLASSY` / `SW_ALPHA` /
`SW_TOOL` flags 4.x had; a plain top-level window is the default and chrome is a CSS concern. What
remains is `.CHILD`, `.MAIN`, `.POPUP`, `.ENABLE_DEBUG`. **The window title comes from the document's
`<title>`** — there is no title API.

## Values — `value.odin`

Lifecycle: `value_init`, `value_clear`, `value_copy`, `value_isolate`, `value_equal`.

Inspection: `value_type` → `(sciter.Value_Type, units: u32)`, `value_is_undefined`, `value_is_null`,
`value_is_function`, `value_is_error` (a string carrying the `.ERROR` unit — how the engine reports a
parse failure and how script reports a thrown one).

Construction — each returns a `Value` you own: `value_from_bool`, `value_from_int` (i32),
`value_from_i64`, `value_from_f64`, `value_from_string`, `value_from_bytes`, `value_make_array`, and
the `value_from` overload group over all of them.

Parsing — `value_parse(s, how := .JSON_LITERAL)` reads text *as* a value, where `value_from_string`
stores the text in one. `.SIMPLE` parses one terminal value the way an attribute would and never fails;
`.JSON_LITERAL` and `.XJSON_LITERAL` parse documents; `.JSON_MAP` resumes an object whose `{` has
already been consumed, so it wants `a:1}` and rejects `{"a":1}`. A failure is `.Parse_Failed`, and the
Value that comes back **is the engine's message** — `value_to_string` it, and clear it like any other.

Extraction: `value_to_bool`, `value_to_int`, `value_to_i64`, `value_to_f64`, `value_to_string`,
`value_to_bytes`, and `value_to_display_string(v, how := .SIMPLE)` which renders *any* value — pass
`.JSON_LITERAL` for containers.

Containers, arrays and maps being the same machinery: `value_len`, `value_at`, `value_key_at`,
`value_set_at`, `value_get`, `value_set`, `value_get_key`, `value_set_key`.

`value_each(v, visit, user_data)` walks a container in one call instead of one per element, and hands
back no reference to clear. An array's keys are *undefined*, not indexes — count if the position
matters. Anything that is not a container is `.INCOMPATIBLE_TYPE` rather than an empty walk.

```odin
Value_Visitor :: proc(key: ^Value, value: ^Value, user_data: rawptr) -> bool   // false stops
```

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
| `select_parent(el, selector, depth := 0) -> (Element, Error)` | `closest()`: nearest ancestor **or self**; `depth` counts from the element, 0 is unlimited |
| `child_count` / `child` / `parent` | traversal, elements only |
| `element_index(el) -> (int, Error)` | position among the parent's *elements*; text nodes do not shift it |
| `tag(el) -> (string, Error)` | borrowed — do not free |
| `text` / `set_text` | text content |
| `html(el, outer := false)` / `set_html(el, html, where_ := .SIH_REPLACE_CONTENT)` | markup |
| `attribute` / `set_attribute` | `""` reads an absent attribute and removes an existing one |
| `attribute_count` / `attribute_at(el, n, allocator)` | markup order; past the end is `.INVALID_PARAMETER` |
| `attributes(el, allocator) -> ([]Attribute, Error)` | all of them; `delete_attributes` frees names, values and slice |
| `clear_attributes(el)` | removes every attribute, `class` and `id` included |
| `style(el, name, allocator)` | the **used** value, resolved — not just what was set inline |
| `set_style(el, name, value)` | inline; `""` removes; does **not** touch the `style` attribute |
| `element_to_value(el)` / `element_from_value(&v)` | an element as a script `Element`, and back |
| `show_popup(popup, anchor, placement := .Bottom)` | the element out of flow, against an anchor. Needs a **shown** window. |
| `show_popup_at(popup, pos: [2]i32, placement := .Top_Left)` | the same, at a point in window coordinates |
| `hide_popup(popup)` | takes the popup or something inside it — **not** the anchor |
| `update_element(el, render := false)` | re-runs style and layout; what makes a stale cascade re-resolve |
| `refresh_element_area(el, area: Rect)` / `request_paint(el)` | repaint only: an area in the element's own coordinates, or all of it |
| `element_state` / `set_element_state` | the CSS pseudo-class bits as a `bit_set` |
| `element_value` / `set_element_value` | script's `element.value`, typed by the attached behavior |
| `make_element(tag, text := "")` | detached; **the reference is yours**, inserted or not |
| `clone_element(el)` | detached deep copy, same ownership |
| `insert_element(el, parent, index := -1)` | default appends; a move if `el` already had a parent |
| `remove_element(el, finalize := true)` | `false` detaches **and takes a reference for you** |
| `swap_elements(a, b)` | exchanges indexes and parents |
| `sort_children(el, cmp, user_data, first, last)` | in place; `last` is one past the end |
| `element_uid` / `element_by_uid` | `element_by_uid` is broken on 6.x — see [`dom.md`](./dom.md#identity) |
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
| `node_to_value` / `node_from_value` | the node half of `element_to_value`; an element's Value unwraps either way |

## Atoms — `atom.odin`

`Atom` is a distinct `u64`: the engine's interned name, and the currency of the SOM side of the API
(`SciterGetElementAsset` takes one where a name would read more naturally).

| | |
| --- | --- |
| `atom(name) -> Atom` | never fails — an unseen name is interned there and then |
| `atom_name(a, allocator) -> (string, ok: bool)` | `ok` is false when the engine reports no name |

Three things to know, all measured: the mapping is stable **within one process** and meaningless
outside it, so never persist or hard-code one; names are bytes rather than text, so anything outside
ASCII does not round-trip; and `atom_name` must only be given an atom `atom` returned — an invented
integer segfaults inside the engine before `init` has run, and the number space is shared with an
encoding of immediates besides (1, 2, 3 decode to `"null"`, `"false"`, `"true"`).

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
the typed accessors `behavior_event`, `mouse_event`, `key_event`, `timer_event`, `exchange_event`, each
returning `ok = false` if the event is not of that group and each exposing `.raw` for what is not
surfaced.

Drag and drop is the `.EXCHANGE` group and nothing else — `exchange_event` gives
`{code, phase, target, source, pos, view, mode, data, raw}`. Consume both `.WILL_ACCEPT_DROP` and
`.DRAG` or no `.DROP` arrives; on Linux the payload comes through empty and there is no drag source at
all. See [`events.md`](./events.md#drag-and-drop).

Timers: `set_timer(el, interval: time.Duration, id: uintptr = 0)` and `stop_timer(el, id)`. The event
arrives in the `.TIMER` group as `Timer_Event{id, raw}`. **The return value is inverted for this
group** — `true` keeps the timer running, `false` stops it — and a timer is delivered only to handlers
on the element it was set on. See [`events.md`](./events.md#timers).

Synthesising: `send_event(el, code, source, reason) -> (handled, Error)` and `post_event(...)`. These
bypass the intrinsic behavior, and a nil `source` delivers nothing at all — see
[`events.md`](./events.md#synthesising-events).

Named events: `fire_event(Fired_Event{…}, post := false) -> (handled, Error)` carries a **name** and a
**payload** where `send_event` carries only a code, which is what makes it the channel to script —
`.CUSTOM` plus `name = "data-arrived"` arrives at `element.on("data-arrived", …)`. A nil `target`
broadcasts to every window, and only handlers attached with `attach_window_handler` receive that.
`event_name(be, allocator)` decodes the name on the receiving side. The engine copies both the name and
the payload, so neither has to outlive the call even with `post = true`.

Mouse capture: `set_capture(el)` / `release_capture(el)`. While an element holds it every mouse event
goes to that element wherever the pointer is, which is what a `.MOUSE_DOWN`-to-`.MOUSE_UP` drag needs.
Taking it from another element, and releasing when nothing was captured, both succeed;
`.INVALID_HWND` is what an element outside any document gets.

## SOM — `som.odin`

A native functor gives script a *function*; an **asset** gives it an object with properties and methods.

```odin
class, _ := sciter_app.make_asset_class(
	"Backend",
	{{name = "count", get = get_count, set = set_count}},   // nil `set` is read-only
	{{name = "reload", params = 1, call = reload}},
)
asset := sciter_app.make_asset(class, &state)
sciter_app.set_global_asset(asset)      // *before* the document that uses it is loaded
```

| | |
| --- | --- |
| `make_asset_class(name, properties, methods, allocator)` | one per kind; must outlive the engine |
| `make_asset(class, user_data, allocator)` / `destroy_asset` | one per object; the engine holds its address, so it must not move |
| `set_global_asset(asset)` / `release_global_asset(asset)` | publishes it as a global under the class name |
| `element_asset(el, behavior) -> (^sciter.Som_Asset_T, Error)` | a behavior's own asset — `element_asset(input, "edit")` |
| `MAX_ASSET_MEMBERS` | 32 properties and 32 methods per class; over that is `.Wrong_Type` |

```odin
Asset_Getter :: proc(asset: ^Asset) -> (value: Value, ok: bool)   // the Value is handed to the engine
Asset_Setter :: proc(asset: ^Asset, value: ^Value) -> bool
Asset_Call   :: proc(asset: ^Asset, args: []Value) -> (result: Value, ok: bool)
```

Four things measured rather than assumed: a global asset **appears at the next document load**, not
immediately (and is withdrawn on the same schedule); the passport's "any property" interceptors are
**never called** by this engine, so a class is a fixed list of members; SOM members are **not
enumerable**, so `Object.keys` is empty; and assigning to a property with no setter **throws** in
script rather than being dropped.

## Graphics — `graphics.odin`

The engine's own 2D renderer, in a second function table. Full guide:
[`graphics.md`](./graphics.md).

`Image`, `Graphics`, `Path` and `Text` are distinct handles, all reference counted (`retain_*` /
`release_*`; releasing nil is not an error). `Color` is built with `rgb` / `rgba`, and `graphics_api()`
is the raw table.

**You never create a `Graphics`** — `gCreate` answers `.NOTSUPPORTED` on this engine. The engine hands
one to you, either offscreen through `paint_image(image, painter, user)` or onscreen through the
`.DRAW` event, decoded with `draw_event(event) -> Draw_Event{layer, gfx, area, raw}`. A `DRAW` handler
returning true **replaces** that layer.

Images: `create_image`, `image_from_pixels`, `load_image`, `image_from_element`, `image_size`,
`clear_image`, `save_image(image, encoding := .PNG, quality := 90, allocator)`. **`.RAW` is BGRA**, four
bytes a pixel, which is how the drawing tests assert.

Drawing: `set_fill_color` / `set_line_color` / `set_line_width` / `set_line_join` / `set_line_cap` /
`set_fill_mode`, the four `set_*_gradient_*`, `save_state` / `restore_state`, `translate` / `scale` /
`rotate` / `skew` / `transform`, `world_to_screen` / `screen_to_world`, `draw_line` / `draw_rect` /
`draw_rounded_rect` / `draw_ellipse` / `draw_arc` / `draw_star` / `draw_polygon` / `draw_polyline` /
`draw_path` / `draw_image` / `draw_text`, `push_clip_rect` / `push_clip_path` / `pop_clip`, and
`flush`. Every shape both fills and strokes.

Paths: `create_path`, `path_move_to`, `path_line_to`, `path_arc_to`, `path_quad_to`, `path_bezier_to`,
`path_close`.

Text: `create_text(element, text, class_name := "")`, `create_text_with_style(element, text, style)`,
`text_metrics` → `Text_Metrics{min_width, max_width, height, ascent, descent, lines}`, `set_text_box`.
Text is laid out against an element because that is where the font comes from.

To script: `value_from_graphics` / `value_from_image` / `value_from_path` / `value_from_text` and the
`value_to_*` inverses.

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

## Requests — `request.odin`

The other half of `SC_LOAD_DATA`. Every load notification carries an `HREQUEST`; returning `.MYSELF`
hands that request to the host, which can then answer with a status code and a MIME type, answer later,
or stream the body in chunks.

```odin
// inside on_load_data - answer now, with a type the URL does not imply
return sciter_app.serve_request(request, css, mime = "text/css")

// or take it over and answer later
rq, result := sciter_app.take_request(request)   // result is .MYSELF
app.pending = rq
return result

// ... later, on the engine's thread
sciter_app.succeed_request(app.pending, bytes)   // or fail_request(rq, 404)
sciter_app.unuse_request(app.pending)
```

`Request` is a distinct `sciter.Hrequest`, `request_of(load_request)` gets one out of a callback, and
`request_api()` is the raw `SciterRequestAPI` table.

Answering: `serve_request(request, data, mime := "", encoding := "", status := 200) -> Load_Result`,
`succeed_request(rq, data, status := 200)`, `fail_request(rq, status := 404, data = nil)`,
`append_request_data(rq, chunk)` (chunks accumulate; `succeed_request(rq, nil)` completes them),
`set_request_mime`, `set_request_encoding`, `set_request_header`, `set_response_header`.

Lifetime: `use_request` / `unuse_request`, and `take_request` which is `use_request` plus `.MYSELF`.
A handle is the engine's to recycle the moment the callback returns unless a reference is taken.

Reading: `request_url`, `request_content_url`, `request_method` (`"GET"`), `request_data_type`,
`request_mime`, `request_times`, `request_status` → `(state, status)`, `request_data`,
`request_requestor`, `request_proxy_host`, `request_proxy_port`, and the three name/value lists —
`request_parameters`, `request_headers`, `response_headers`, each with `_count` and indexed forms, all
returning `[]Name_Value` to free with `delete_name_values`.

Two measured behaviours worth knowing: deferring works for what the document consumes on arrival
(images, fonts, media) but **not** for `<script src>`, which is fetched and never run if the answer
misses the parse; and `request_requestor` reports the element the resource is *for* — a stylesheet
pulled in by `<link>` in the head reports `html`, not the `<link>`. See
[`resources.md`](./resources.md#taking-a-request-over).

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

Things you will reach for the raw table for today: `SciterFindElement` (hit-testing a point),
`SciterCallBehaviorMethod`, `SciterHttpRequest`, and `gGetNativeDC` in the graphics table.

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
