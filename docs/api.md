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
| `show` / `hide` / `close` / `activate` | window state; a window is created hidden. **A secondary window is closed by `hide`, a turn of the pump, then `close`** — any other order segfaults the engine |
| `window_state(window) -> (state, ok)` / `set_window_state` | `ok` is false when the engine answers something outside the enum — a destroyed window reports `0xFFFFFFFE` |
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
| `element_at(window, pos: [2]i32) -> (Element, Error)` | hit testing: the topmost element at a point in the window's client area. Off the document is `.Not_Found` |
| `child_count` / `child` / `parent` | traversal, elements only; indices are `Child_Index` |
| `element_index(el) -> (Child_Index, Error)` | position among the parent's *elements*; text nodes do not shift it |
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
| `insert_element(el, parent, index: Maybe(Child_Index) = nil)` | `nil` appends; a move if `el` already had a parent |
| `remove_element(el, finalize := true)` | `false` detaches **and takes a reference for you** |
| `swap_elements(a, b)` | exchanges indexes and parents |
| `sort_children(el, cmp, user_data, first, last)` | in place; `last` is one past the end |
| `element_uid` / `element_by_uid` | trade an `Element_Uid` (`distinct u32`); `element_by_uid` is broken on 6.x — see [`dom.md`](./dom.md#identity) |
| `eval_element(el, script)` | script with `this` bound to the element |
| `call_method(el, method, args: ..Value)` | a method on the element's script object, including behavior methods |
| `call_function(el, name, args: ..Value)` | a *function* visible from the element, `globalThis`'s included — what `call_method` cannot find |
| `expando(el) -> (Value, Error)` | the element's script object, to `value_get` / `value_set` — **read the string caveat below** |
| `combine_url(el, url, allocator)` | resolves a relative URL against the element's document base |

`state(x)` and `set_state(x, …)` are overload groups resolving to the element or window version.

**`expando` reads reliably in both directions and writes only scalars.** Measured: `value_set` of an
`i32`, `f64` or `bool` round-trips and is visible to script immediately, and anything script put on the
element reads back intact. `value_set` of a **string** reports success and then reads back as garbage
from both sides — `value_isolate` first does not help, and a later unrelated `value_clear` has aborted
the process. Put a string there through script instead, which is one line:

```odin
sciter_app.eval_element(el, `this.note = "hello"`)   // not value_set(&expando, "note", &s)
```

This is the same family as the rule in `set_global`: a Value handed to an engine-owned object is not
always copied the way the header implies, and strings are where it shows.

## Behavior methods — `behavior.odin`

The native code *behind* an element: the intrinsic behavior that makes a button a button. Neither the
DOM nor script reaches it.

| | |
| --- | --- |
| `control_type(el) -> (sciter.Ctl_Type, Error)` | which behavior the element carries: `.BUTTON`, `.CHECKBOX`, `.EDIT`, `.DD_SELECT`, … `.NO` for an element with none |
| `do_click(el) -> (handled: bool, Error)` | a **real** click: the widget's state changes and it raises the events a user's click would |
| `behavior_value(el)` / `set_behavior_value(el, ^Value)` | the `GET_VALUE` / `SET_VALUE` protocol |
| `behavior_is_empty(el)` | the `IS_EMPTY` protocol |
| `call_behavior_method(el, params: rawptr) -> (handled: bool, Error)` | any method id, including your own |
| `method_call(event) -> (Method_Call, ok)` / `method_args(mc) -> Method_Args` | the receiving side, in a `.METHOD_CALL` handler |

`handled` is separate from `err` because the engine answers a method nothing implements with
`OK_NOT_HANDLED`, which is a success: `handled = false`, `err = nil`. A detached element is
`.PASSIVE_HANDLE` and that *is* an error.

`do_click` is the shortcut for one case; `send_mouse` / `send_key` under "Synthesising input" below are
the general mechanism, and the only route to hover, drag, the wheel and the keyboard.

**`do_click` is not `send_event(el, .BUTTON_CLICK)`.** `send_event` injects the event code into the
element chain and nothing else happens — measured on a checkbox, `:checked` is untouched. `do_click`
calls the behavior, so the checkbox flips and a `VALUE_CHANGED` arrives ahead of the `BUTTON_CLICK`.
The state change is synchronous; the events it raises are queued, so a handler has not seen them until
the pump turns.

**No intrinsic behavior implements `GET_VALUE`, `SET_VALUE` or `IS_EMPTY` on Sciter 6.** Measured on a
text `<input>`, a `<select>` and a `<div>`: every one answers `handled = false`. `element_value` /
`set_element_value` (`SciterGetValue`, a different call) is what reads an `<input>`. The three exist
for behaviors of your own.

Going the other way, a method call arrives as a `.METHOD_CALL` event whose parameter block is the
caller's struct, written in place:

```odin
Set_Zoom_Params :: struct { method_id: u32, factor: f32, applied: b32 }   // id must be first

// caller
p := Set_Zoom_Params{method_id = SET_ZOOM, factor = 1.5}
handled, err := sciter_app.call_behavior_method(chart, &p)

// handler, subscribed to {.METHOD_CALL} and attached with attach_handler
mc, ok := sciter_app.method_call(event)
switch args in sciter_app.method_args(mc) {
case ^sciter.Value_Params:    args.val = sciter_app.value_from(i32(42)); return true
case ^sciter.Is_Empty_Params: args.is_empty = 1;                    return true
}
```

Returning true is what makes the caller's `handled` true. Ids at or above
`sciter.Behavior_Method_Identifiers.FIRST_APPLICATION_METHOD_ID` (256) are yours. **A method call is
delivered only to handlers attached to that exact element** — it does not sink or bubble, and a
handler attached with `attach_window_handler` never sees one. See `examples/behavior.odin`.

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
| `ppi(window) -> [2]u32` | the window's resolution; 96 is unscaled, so `dpi / 96` is the scale factor |
| `min_width(window) -> i32` / `min_height(window, for_width) -> i32` | the **root element's** intrinsic size, not the document's — see below |

An element with no box keeps reporting the last rectangle it had, so `location` is never the way to
ask whether an element is there — `visible` is.

`min_width` / `min_height` are measured to return exactly `intrinsic_widths(root).min` and
`intrinsic_height(root, …)`. Because `<html>` fills the view by default its min-content width is a
small constant — 16px on this engine — whatever the content inside it is, so on an ordinary document
`min_width` answers the same number for a 600px-wide child and for an empty body. They mean something
only when the root is sized by its content (`html, body { width: max-content }`), and `min_height`
ignores its `for_width` argument. To size a window to its document, ask `intrinsic_widths` /
`intrinsic_height` of the element that holds the content.

## Nodes — `node.odin`

The text-and-comments half of the DOM. `Node` is a distinct `sciter.Hnode`, and `Owned_Node` is a
distinct `Node` — the borrowed/owned split `Element` and `Request` also carry.

| | |
| --- | --- |
| `node_add_ref` / `node_release` | node handles are **not** reference counted on the way out; `node_add_ref` hands back the `Owned_Node` that owes the release |
| `borrow_node(owned)` | the free cast, for everything that reads or writes an owned node |
| `node_from_element` / `node_to_element` | crossing between the two views; the latter fails on a text node |
| `node_type` | `.ELEMENT`, `.TEXT`, `.COMMENT` |
| `node_first_child` / `node_last_child` / `node_next_sibling` / `node_prev_sibling` | `.Not_Found` ends the walk |
| `node_child` / `node_child_count` / `node_parent` | indices are `Node_Index`, `distinct` from `Child_Index` — text and comment nodes count here and do not there; `node_parent` returns an `Element` |
| `node_text` / `node_set_text` | the text a `.TEXT` or `.COMMENT` node carries |
| `make_text_node` / `make_comment_node` | detached `Owned_Node`s, each owing one `node_release` — inserting one does not settle it |
| `node_insert(node, where_, what)` | `.BEFORE`, `.AFTER`, `.APPEND`, `.PREPEND`; `what` is an `Owned_Node`, and the document takes its own reference rather than yours |
| `node_remove(node, finalize := true)` | `false` detaches instead of destroying, but the node can never be reinserted and you get no `Owned_Node` back — there is no node move |
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

Decoding: `event_code(cmd)`, `event_phase(cmd)` → `Event_Phase{.Bubbling, .Sinking}` and
`event_handled(cmd)` — the phase and the handled bit are independent, so they are two calls. `cmd` is an
`Event_Cmd`, a distinct `u32`, because a raw `cmd` word and the code `event_code` strips out of it are
not interchangeable: `event_phase` of a masked code always answers `.Bubbling`, which is a plausible
answer to the wrong question. Then the typed accessors `behavior_event`, `mouse_event`, `key_event`, `timer_event`, `exchange_event`,
`draw_event`, `method_call`, `focus_event`, `scroll_event`, `gesture_event`,
`attribute_change_event(event, allocator)` and `data_arrived_event(event, allocator)` — each returning
`ok = false` if the event is not of that group and each exposing `.raw` for what is not surfaced. The
last two take an allocator because the engine hands their strings over as UTF-16.

Three of the groups are **delivered only to handlers attached to the element itself** — measured, a
window handler never sees them: `.METHOD_CALL`, `.SCROLL` and `.ATTRIBUTE_CHANGE`, plus the animation
frame below. `attach_handler` is the only attachment that receives one.

`.SIZE` has no accessor because it has no parameters: `event.element`, the element whose box changed,
is the whole payload. It is the element's own resize, not the window's — maximizing and restoring the
window produced none; restyling a `<div>`'s width produced one.

`Scroll_Event.code` is a bare `u32` on purpose: the header's `SCROLL_EVENTS` stops at `.ANIMATION_END`
(12) and this engine emits **14** for an ordinary `set_scroll_pos`, so a typed field would print a
value that does not exist. `Gesture_Event.code` likewise — `GESTURE_CMD` is commented out upstream in
this SDK.

Drag and drop is the `.EXCHANGE` group and nothing else — `exchange_event` gives
`{code, phase, target, source, pos, view, mode, data, raw}`. Consume both `.WILL_ACCEPT_DROP` and
`.DRAG` or no `.DROP` arrives; on Linux the payload comes through empty and there is no drag source at
all. See [`events.md`](./events.md#drag-and-drop).

Animation frames: `request_animation_frame(el, code, reason)` is script's `requestAnimationFrame` from
native code — the engine's frame clock, where `set_timer` is a millisecond clock that ticks whether or
not anything is drawn. `code` arrives as an ordinary `.BEHAVIOR_EVENT`, so use one at or above
`.FIRST_APPLICATION_EVENT_CODE` (the C API's 0 is `.BUTTON_CLICK`). **The handler's return value
decides whether it happens again** — the `.TIMER` inversion: true re-arms it for the next frame, false
stops it. Measured, and the engine brackets each request with its own `.ANIMATION` events, `reason = 1`
before and `reason = 0` after, which *do* bubble to a window handler.

Timers: `set_timer(el, interval: time.Duration, id: Timer_Id = 0)` and `stop_timer(el, id)`. The event
arrives in the `.TIMER` group as `Timer_Event{id, raw}`. `Timer_Id` is a distinct `uintptr` — an opaque
token the engine hands back unchanged, kept apart from the package's other `uintptr`s (`set_option`'s
value, an animation frame's `reason`), and untyped constants still work. **The return value is inverted for this
group** — `true` keeps the timer running, `false` stops it — and a timer is delivered only to handlers
on the element it was set on. See [`events.md`](./events.md#timers).

Synthesising: `send_event(el, code, source, reason) -> (handled, Error)` and `post_event(...)`. These
bypass the intrinsic behavior, and a nil `source` delivers nothing at all — see
[`events.md`](./events.md#synthesising-events).

Synthesising input: `send_mouse(el, code, pos, buttons, modifiers)` and `send_key(el, code, key_code,
modifiers)` are `SciterTraverseUIEvent` — they sink-and-bubble the event the way the window system's
own input does, so the **intrinsic behaviors run**: the button really is pressed and clicked, the
`<input>` really is typed into. `send_text(el, text)` is the `.DOWN`/`.CHAR`/`.UP` loop over a string.
Three requirements, each measured: `el` must not be nil (there is no hit testing inside — `element_at`
turns a point into the element to name); `buttons` must carry the button or the behavior ignores the
press entirely (the event is still delivered, and `processed` comes back false); and `pos` is in the
window's client area, the space `location(el, .Border, .View)` and `element_at` use — the engine
recomputes the element-relative `pos` each handler sees. See `examples/input.odin`.

Loading for an element: `request_element_data(el, url, data_type, initiator)` fetches a URL through the
engine's own pipeline — host callback, archives and custom schemes included — and delivers the bytes to
`el` as `.DATA_ARRIVED`. `http_request(el, url, method, params, data_type)` is the same delivery with a
method and parameters: measured against a real server, a `.Get` encodes them into the query string
(`?page=2&q=two%20words`, escaping done for you) and a `.Post` sends them as the body. The C API's
synchronous variants are not surfaced — `GET_SYNC` returns `.OPERATION_FAILED` immediately, issues the
request anyway, and delivers asynchronously like the rest. **The engine denies socket access by
default**, so an HTTP request goes quiet until `set_script_features({.SOCKET_IO})`.

Failures are reported through the event rather than the call, and **`status` is not one scale** —
measured: an HTTP response puts its own code there (200, 404 with the server's error page as `data`), a
`file://` load that worked answers 0 rather than 200, a missing file answers an errno (2), and a
connection that could not be made answers 0 with no data. `len(data) == 0` is the reliable failure
test; `status` says why.

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

**S**citer **O**bject **M**odel. The SDK never expands the acronym anywhere — it appears only as a bare
tag in its CHANGELOG and in macro names — so this reading comes from the naming: the C++ namespace is
`sciter::om`, the headers are `sciter-om.h` / `sciter-om-def.h`, and every C symbol is prefixed `som_`.
Upstream's own word for the things in it is **assets**, which is why the API says `som_asset_t`,
`SciterSetGlobalAsset` and `element_asset`.

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
| `MAX_ASSET_MEMBERS` | 32 properties and 32 methods per class; over that is `.Too_Many_Members` |

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

### Reading somebody else's asset

`element_asset` hands back an asset the *engine* owns. Everything it can do is in its passport, and
these read that description and use it — on any `^sciter.Som_Asset_T`, whoever made it.

| | |
| --- | --- |
| `asset_passport(asset) -> ^sciter.Som_Passport_T` | the description itself, or nil |
| `asset_members(asset, allocator) -> (properties, methods: []string)` | discovering it rather than assuming it |
| `asset_method_arity(asset, method) -> (arity: int, found: bool)` | how many arguments a method **requires** |
| `asset_call(asset, method, args, check_arity := true) -> (Value, Error)` | `.Not_Found` for an unlisted method, `.Wrong_Arity` for too few arguments |
| `asset_get(asset, property)` / `asset_set(asset, property, ^Value)` | likewise; `.Not_Found` also means "read-only" |
| `asset_interface(asset, name) -> rawptr` | the C++ side's `dynamic_cast` |

```odin
edit, _ := sciter_app.element_asset(input, "edit")
props, methods := sciter_app.asset_members(edit, context.temp_allocator)
// props   -> ["selectionStart", "selectionEnd", "selectionText", "isStandalone"]
// methods -> ["selectAll", "selectRange", "removeText", "insertText", "appendText"]
```

**A method's `params` cuts both ways.** On the *script* side it is a cap: a member declared
`params = 1` and called as `obj.method(a, b, c)` receives only `a`, and the extras vanish with no error
— measured, and it presented as every bound parameter in a database call arriving as NULL. Declare the
most a method will ever take. On the *host* side it is a floor, for the reason below.

**Arity is a memory-safety rule, not a convention.** The engine's thunks read their arguments
positionally and ignore `argc`, so a method declared with one parameter called with none faults inside
the engine. `asset_call` refuses with `.Wrong_Arity` instead of making the call; passing *more* than
declared is harmless. `check_arity = false` waives the guard, and there is exactly one honest reason
to: an asset **you** made with `make_asset_class` tolerates a short call, because the thunk is this
package's own. [`BEHAVIORS.md`](./BEHAVIORS.md) carries the measured arity of every intrinsic
behavior's methods.

**A passport is the native interface, and the script interface is a separate decision the behavior
makes.** `edit`'s members are in both; `<video>`'s `renderingSite` is in the passport and *not* in
script — calling it from script answers "not a function".

`asset_interface` is the only thing that knows where a named interface lives inside a C++ asset. The
pointer it returns is **not** the asset pointer: for `<video>` the `video_destination` base subobject
is 24 bytes before the `som_asset_t`. Never compute that offset by hand.

`value_to_asset(^Value) -> (^sciter.Som_Asset_T, Error)` and `value_from_asset` cross the last gap:
a `.ASSET` Value carries an asset pointer, and that is how one comes back from a SOM method. The
pointer is borrowed from the Value, so keep the Value to keep the asset.

## Video — `video.odin`

Streaming frames into a `<video>` element. This is the one part of the API **not in `ISciterAPI`**:
`sciter::video_destination` is a C++ class of pure virtuals with no C declaration, so there is no slot
to call and `video.odin` lays its virtual table out by hand. Full story in
[`examples/video.odin`](../examples/video.odin).

```odin
dest, _ := sciter_app.video_destination(element)
sciter_app.video_start_streaming(dest, 640, 480)          // .RGB32 by default
sciter_app.video_render_frame(dest, frame)                // BGRA, top-down
sciter_app.video_stop_streaming(dest)
```

| | |
| --- | --- |
| `video_destination(element) -> (^Video_Destination, Error)` | the element's rendering site |
| `video_is_alive(dest)` | false once the element or document is gone |
| `video_start_streaming(dest, w, h, space := .RGB32, source := nil)` | announces the geometry |
| `video_stop_streaming(dest)` | the element keeps the last frame |
| `video_render_frame(dest, frame)` | one whole frame, copied during the call |
| `video_render_frame_with_stride(dest, frame, stride)` | for padded rows |
| `video_render_frame_part(dest, frame, x, y, w, h)` | only the rectangle that changed |
| `video_render_external_frame(dest, frame, stride, release, user_data)` | zero-copy; the engine reads later and calls `release` |
| `video_add_ref` / `video_release` | for a destination that outlives the call it arrived in |

Three measured facts, none of them in the SDK's documentation:

- **`behavior: video` is backed by libVLC on Linux** and does not attach at all without it —
  `element_asset` answers `.OPERATION_FAILED` and no `VIDEO_BIND_RQ` is ever sent. See
  [`deployment.md`](./deployment.md).
- **`behavior: custom-video` is the one for host-fed frames.** It needs no codec library, and publishes
  a SOM asset named `video` whose single method `renderingSite` returns the destination.
- **`.RGB32` is BGRA**, the same inversion `.RAW` image encoding has.

The vtable layout is the Itanium C++ ABI's — Linux and macOS. Windows is expected to match (vptr at
offset 0, slots in declaration order, `this` in the first argument's register) but is unverified, and
`api_map` cannot check a C++ vtable. `examples/video.odin`'s tests are the check.

## Graphics — `graphics.odin`

`graphics_caps() -> (Graphics_Caps, bool)` reports how the system's graphics rate. **It is an ordinal
scale, not a bitmask** — `sciter-x-def.h` documents exactly three values, `.None` / `.Software` /
`.Hardware` — but it is worded in terms of Direct2D, which predates this engine's Skia backend and does
not exist off Windows. The vendored Linux build answers `.Software`. Read it, print it in a bug report;
don't branch on it off Windows without checking what it reports there.

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

`draw_rounded_rect` is a proc group: `[4]f32` is one radius per corner, `[4][2]f32` the engine's own
`{rx, ry}` pairs, clockwise from the top-left. `Text_Anchor`'s numbers are a **numeric keypad** - 7/8/9
is the top row - which is not what reading order suggests.

Five of these do not work on the vendored engine and are documented at their definitions and in
`CHANGELOG.md`'s known issues: `draw_star` paints fragments, `set_fill_mode` is `.NOTSUPPORTED` (the
renderer is always even-odd), `world_to_screen` / `screen_to_world` ignore the transform, and
`set_text_box` never wraps. **An unbalanced `save_state` aborts the process** when the painter returns.

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
	on_load_data:        proc(handler: ^Host_Handler, request: ^Load_Request) -> Load_Result,
	on_data_loaded:      proc(handler: ^Host_Handler, loaded: ^Data_Loaded),
	on_attach_behavior:  proc(handler: ^Host_Handler, request: ^Behavior_Request) -> ^Event_Handler,
	on_posted:           proc(handler: ^Host_Handler, posted: Posted),
	on_invalidate_rect:  proc(handler: ^Host_Handler, window: Window, rect: sciter.Rect),
	on_keyboard_request: proc(handler: ^Host_Handler, window: Window, keyboard_type: string),
	on_set_cursor:       proc(handler: ^Host_Handler, window: Window, cursor_id: u32, cursor_url: string),
	on_graphics_failure: proc(handler: ^Host_Handler, window: Window),
	on_engine_destroyed: proc(handler: ^Host_Handler),
	user_data:           rawptr,
	ctx:                 runtime.Context,
}
```

That is **all nine** `SCITER_CALLBACK_NOTIFICATION` codes. The last four read like windowless-mode
plumbing from where the header puts them, and two of them are not:

| | Measured on this engine, windowed |
| --- | --- |
| `on_invalidate_rect` | **fires constantly** — 32 times just getting a window on screen, with the real damaged rect. The engine has already drawn; this is for a host that wants to know |
| `on_keyboard_request` | fires when a text field takes focus, carrying Android's `inputType` vocabulary |
| `on_set_cursor` | never seen — the engine owns the window and sets the cursor itself |
| `on_graphics_failure` | never seen |

Both live ones need a window that is **on screen and rendering**, which is why they are demonstrated by
running `examples/named_behavior` rather than asserted in its tests.

```odin
```

`set_host_handler(window, &h)` — **before** loading a document. A nil handler detaches (the trampoline
stays installed with a null parameter: a window whose callback pointer is actually NULL segfaults
inside the engine at the next notification). `serve(request, data)` answers with
bytes and returns the right code. `Load_Request` is `{uri: string, type: Sciter_Resource_Type, raw:
^Scn_Load_Data}`; `Load_Result` is the engine's `.OK` / `.DISCARD` / `.DELAYED` / `.MYSELF`.

For an answer that cannot be given inside the callback: return `.DELAYED`, keep `request.raw.requestId`,
and answer later with `data_ready_async(window, uri, data, request_id)`. Every delayed request must
eventually be answered or it leaks. `data_ready(window, uri, data)` is the same push without a request
id; both copy the data, unlike `serve`.

`on_data_loaded` reports a resource the engine fetched *itself*, after the fact — `Data_Loaded{uri,
type, data, status, raw}`, where `status` is 0 for an unknown error and otherwise an HTTP code. It
cannot intervene; `on_load_data` runs first and is the one that can.

### Named behaviors — the document asking for Odin by name

`attach_handler` is the host reaching into the document. This is the reverse, and the only route where
a **stylesheet** decides which elements get native code:

```odin
// div.gauge { behavior: my-gauge; }

on_attach_behavior :: proc(h: ^sciter_app.Host_Handler, r: ^sciter_app.Behavior_Request) -> ^sciter_app.Event_Handler {
	if r.name != "my-gauge" {
		return nil                  // not ours; the element just gets no behavior
	}
	gauge := new(Gauge)
	gauge.subscription = {.MOUSE}
	gauge.on_event = on_gauge_event
	return gauge                    // attached immediately, before this returns
}
```

`Behavior_Request` is `{name: string, element: Element, window: Window, raw: ^Scn_Attach_Behavior}`;
`name` is in the callback's temp allocator. What comes back is an ordinary `Event_Handler`, so every
accessor in `events.odin` works on it and the same `subscription` rules apply.

Six measured rules, each pinned by a test in [`examples/named_behavior.odin`](../examples/named_behavior.odin):

| | |
| --- | --- |
| **`set_host_handler` must come first** | the requests arrive *inside* `load_html`, before it returns |
| one request per name per element | `behavior: my-gauge my-logger` gives two, both on that element |
| **intrinsic names never reach the host** | `behavior: button` produces no request — you cannot shadow a built-in |
| later elements are asked about too | a document that grows stays wired up |
| the return value is ignored | handing back a handler is what attaches it |
| **`.DETACH` is the only teardown hook** | there is no "behavior destroyed" notification |

That last one is the ownership rule. The handler is allocated per element by the factory, and the only
place it can free itself is `Initialization_Events.DETACH`, which arrives when the element is removed
*and* when the document is replaced. Note the group: `HANDLE_INITIALIZATION` is `0x0000` upstream, so
it is the **empty** bit_set, not a bit of its own —

```odin
if event.group == {} && event.params != nil {
	if sciter.Initialization_Events((^sciter.Initialization_Params)(event.params).cmd) == .DETACH {
		free(widget)
	}
}
```

Miss it and a long-running application leaks one handler per behavior per document load.

### Posting work to the engine's thread

`post_callback(window, wparam, lparam := 0)` is **the only call in this package that is safe from
another thread**. It returns immediately and the two words come back out on the engine's thread as
`on_posted(handler, Posted{wparam, lparam, raw})`, where the DOM is reachable again — which is how a
background thread gets its results into the UI.

Measured: it is delivery, not a call — the C API's `timeoutms` is not surfaced because a 3-second
timeout from a worker thread against an engine thread stalled for 300ms still returned in
microseconds, and the notification's `lreturn` never reaches the poster. Messages arrive in the order
they were posted; `heartbeat` delivers them as well as `run_once`; a window with no host handler, and a
nil window, drop them silently. Two words is a wake-up, not a transport — anything larger travels in a
structure the two threads share. See `examples/worker_thread.odin`.

`callback_param(window) -> rawptr` returns the handler pointer the engine holds, for a `proc "system"`
callback that was handed only an HWINDOW: `(^Host_Handler)(callback_param(w)).user_data`.

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
sciter_app.succeed_request(sciter_app.borrow_request(app.pending), bytes)
sciter_app.unuse_request(app.pending)
```

`Request` is a distinct `sciter.Hrequest` and is **borrowed** — valid for the callback it arrived in.
`request_of(load_request)` gets one out of a callback, and `request_api()` is the raw
`SciterRequestAPI` table.

`take_request` and `use_request` hand back an **`Owned_Request`** instead, which is the one that owes an
`unuse_request` — and `unuse_request` accepts nothing else, so releasing a handle you never took does
not compile. That is not a style preference: a single `unuse_request` on a borrowed handle answers `.OK`
and then segfaults the process a request or two later, measured, with nothing on the stack pointing at
it. `borrow_request(owned)` is the free cast for passing a held handle to the readers and answerers,
and borrowing once at the top of a scope is the usual shape.

Answering: `serve_request(request, data, mime := "", encoding := "", status := 200) -> Load_Result`,
`succeed_request(rq, data, status := 200)`, `fail_request(rq, status := 404, data = nil)`,
`append_request_data(rq, chunk)` (chunks accumulate; `succeed_request(rq, nil)` completes them),
`set_request_mime`, `set_request_encoding`, `set_request_header`, `set_response_header`.

Lifetime: `use_request` → `(Owned_Request, Error)` / `unuse_request(owned)`, and `take_request` which is
`use_request` plus `.MYSELF`. A handle is the engine's to recycle the moment the callback returns unless
a reference is taken.

Reading: `request_url`, `request_content_url`, `request_method` (`"GET"`), `request_data_type`,
`request_mime`, `request_times` (engine-clock timestamps) and `request_time` → `(elapsed, done)` for
the duration between them, `request_status` → `(state, status)`, `request_data`, `request_requestor`,
`request_proxy_host`, `request_proxy_port`, and the three name/value lists — `request_parameters`,
`request_headers`, `response_headers`, each with `_count` and indexed forms, all returning
`[]Name_Value` to free with `delete_name_values`. The three lists are numbered independently, so their
indices are three distinct types — `Parameter_Index`, `Request_Header_Index`, `Response_Header_Index` —
and one cannot be handed to another's getter.

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

## Windowless views — `windowless.odin`

No window and no pump: the engine renders the document into a buffer the host owns. One `SXM_*` message
per call, over `SciterProcX`.

| | |
| --- | --- |
| `create_windowless(opts: Windowless_Options, allocator) -> (Windowless_View, Error)` | `SXM_CREATE` + `SXM_SIZE`. `opts.pixels` nil allocates the surface; supply one to render into your own memory at your own `stride`. `opts.backend = .OPENGL` with a `glGetProcAddress` in `opts.device` renders on the GPU instead |
| `resize_windowless(view, width, height, pixels := nil, stride := 0) -> Error` | a new size and surface; the document reflows |
| `paint_windowless(view, rect := nil, element := nil, fore := true) -> Error` | draws. Nothing else writes pixels and nothing schedules this |
| `windowless_heartbeat(view, elapsed := 0)` | the engine's clock: drains posted work, settles a load. `elapsed` is ignored by the engine |
| `windowless_mouse(view, event, pos, button, modifiers) -> bool` | delivered to the document; the return is always false |
| `windowless_key(view, event, code, modifiers) -> bool` | delivered; pair with `set_focus` on the element |
| `windowless_focus(view, got := true) -> bool` | `SXM_FOCUS` |
| `destroy_windowless(view)` | `SXM_DESTROY` — **once per process**, see below |
| `windowless_pixel(view, x, y) -> (r, g, b, a)` | reads one pixel in `PIXEL_ORDER` (RGBA, BGRA on Windows) |

`view.window` is an ordinary `Window`, so `load_html`, `root`, `select_first`, `eval`,
`set_host_handler` and the rest of this package work on a view unchanged. `on_invalidate_rect` is the
signal that a repaint is due.

Five measured rules, all with a test in [`examples/windowless.odin`](../examples/windowless.odin):
**it still needs a display** (no `DISPLAY` segfaults `SXM_CREATE`); **do not call `init`**; **one
destroy ends windowless mode for the process** — swap documents instead; **script timers run on the
wall clock**, so a host rendering faster than real time sees none; and **input is complete** — the
intrinsic behaviors act on the mouse too, with the caveat that a behavior's event is *posted* and so
arrives on the next heartbeat rather than inside the call.

The **`.OPENGL` backend** ([`examples/windowless_gl.odin`](../examples/windowless_gl.odin)) draws into
the framebuffer bound to the host's GL context — a texture, if that is what is bound. Its own rules:
the context must be **desktop** GL rather than GLES (a GLES one paints nothing and reports success),
`device` is mandatory, the target is captured when the view is created, and the paint leaves the
engine's framebuffer bound. `.OPENGLES` is refused by this build. There is no
wrapper for `SXM_RESOLUTION` because it crashes. [`EMBEDDING.md`](./EMBEDDING.md) is the long version.

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

Things you will reach for the raw table for today: `SciterHttpRequest`, and `gGetNativeDC` in the
graphics table.

Two DOM slots are **dead on this engine** and are deliberately not wrapped: `SciterGetObject` and
`SciterGetElementNamespace` both answer `.OPERATION_FAILED` for every element tried, leftovers from the
removed script VM in the same way `SciterGetViewExpando` is. `expando` is the call that works.

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
