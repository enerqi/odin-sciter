// Events: getting the engine to call Odin when something happens in the document.
//
// One handler is attached to one element and hears about that element's subtree. Which categories it
// hears about is the `subscription` mask - the engine asks for it once, right after attaching, by
// calling the handler with SUBSCRIPTIONS_REQUEST, and this package answers that automatically.
//
// Everything below runs on the engine's thread, inside the message pump, with the context that was
// current when the handler was attached.
package sciter_app

import sciter ".."
import "base:runtime"
import "core:fmt"
import "core:time"

// What the engine reports. `params` points at the group's own parameter struct - use the typed
// accessors below rather than casting it by hand.
Event :: struct {
	element: Element, // the element the event reached
	group:   sciter.Event_Groups, // which category `params` belongs to
	params:  rawptr,
}

// An attached handler. Allocate one per attachment and keep it alive for as long as it is attached -
// the engine stores its address as the handler's tag, so it must not move. Embedding it in a struct
// that outlives the window is the usual arrangement.
//
//	handler := sciter_app.Event_Handler {
//		subscription = {.BEHAVIOR_EVENT},
//		on_event     = on_event,
//	}
//	sciter_app.attach_handler(root, &handler)
Event_Handler :: struct {
	// Which event categories to receive. `{}` receives nothing but initialization events, which are
	// delivered regardless.
	subscription: sciter.Event_Groups,

	// Return true to mark the event handled. Whoever sent it is told - `send_event` reports it - and
	// the rest of the trip carries the HANDLED bit, so later handlers see `handled = true` on the typed
	// parameters (and `event_handled(cmd)` on the raw code). It does not cancel delivery: the bubbling
	// pass still arrives at this handler, which is why acting on every phase acts twice - and the phase
	// stays readable after something claims the event, which is what makes acting once possible.
	on_event:     proc(handler: ^Event_Handler, event: Event) -> bool,

	// Yours. The handler is passed back to `on_event`, so this is how state gets in.
	user_data:    rawptr,

	// Captured by `attach_handler`. The engine calls back as `proc "system"`, where Odin's implicit
	// context does not exist, so it has to be carried across explicitly.
	ctx:          runtime.Context,
}

// Attaches `handler` to `element`. It hears about `element` and everything below it.
attach_handler :: proc(element: Element, handler: ^Event_Handler) -> Error {
	handler.ctx = context
	return dom_err(engine().SciterAttachEventHandler(sciter.Helement(element), event_trampoline, handler))
}

// Attaches `handler` to the window's whole document, including elements that do not exist yet.
attach_window_handler :: proc(window: Window, handler: ^Event_Handler) -> Error {
	handler.ctx = context
	return dom_err(
		engine().SciterWindowAttachEventHandler(rawptr(window), event_trampoline, handler, handler.subscription),
	)
}

detach_handler :: proc(element: Element, handler: ^Event_Handler) -> Error {
	return dom_err(engine().SciterDetachEventHandler(sciter.Helement(element), event_trampoline, handler))
}

detach_window_handler :: proc(window: Window, handler: ^Event_Handler) -> Error {
	return dom_err(engine().SciterWindowDetachEventHandler(rawptr(window), event_trampoline, handler))
}

@(private)
event_trampoline :: proc "system" (tag: rawptr, he: sciter.Helement, evtg: sciter.Event_Groups, prms: rawptr) -> b32 {
	handler := (^Event_Handler)(tag)
	context = handler.ctx

	// Right after attaching, the engine asks what to send. Answering is not optional: a handler that
	// ignores this receives nothing.
	if evtg == sciter.SUBSCRIPTIONS_REQUEST {
		(^sciter.Event_Groups)(prms)^ = handler.subscription
		return true
	}

	if handler.on_event == nil {
		return false
	}
	return b32(handler.on_event(handler, {element = Element(he), group = evtg, params = prms}))
}

// ---------------------------------------------------------------------------------------------------
// Event codes
//
// The `cmd` field of every parameter struct is an event code with the propagation phase OR'ed into it,
// which is why `package sciter` leaves it a bare integer: `MOUSE_DOWN | SINKING` is not a value of the
// MOUSE_EVENTS enum. Split the two before comparing.

// The phase bits live above every real event code (SINKING is 0x8000, HANDLED is 0x10000).
EVENT_CODE_MASK :: 0x7FFF

// The raw `cmd` word out of a parameter struct: an event code with the phase bits OR'ed into it.
//
// Distinct from the plain `u32` code deliberately, because the two are not interchangeable and mixing
// them fails **quietly**: `event_phase` of an already-masked code is always `.Bubbling`, which is a
// correct-looking answer to a question that was asked of the wrong number. `event_code` returns a bare
// `u32` for comparing against `sciter.Mouse_Events` and friends, so the compiler now stops
// `event_phase(event_code(cmd))` instead of letting it read a phase that has been masked away.
//
//	phase := sciter_app.event_phase(sciter_app.Event_Cmd(params.cmd))
Event_Cmd :: distinct u32

// Which way the event is travelling. **This is not where "handled" lives**: the C API has SINKING as a
// bit (0x8000) and HANDLED as a separate, independent one (0x10000), so an event can be sinking *and*
// handled at once. Modelling all three as one enum made `.Handled` shadow the direction - every handler
// downstream of one that claimed the event lost the ability to tell sinking from bubbling, and the
// documented way to act exactly once (`if ev.phase == .Bubbling`) silently stopped acting. Use
// `handled` on the typed parameters, or `event_handled` on a raw code.
Event_Phase :: enum {
	Bubbling, // travelling back up from the target - the normal case
	Sinking, // travelling down towards the target, before it sees the event
}

// The event code with the phase bits removed.
event_code :: proc(cmd: Event_Cmd) -> u32 {
	return u32(cmd) & EVENT_CODE_MASK
}

// **`sciter.Behavior_Events` names the engine's codes and does not close the set.** Everything at or
// above `.FIRST_APPLICATION_EVENT_CODE` (256) belongs to the application, and the engine passes those
// through untouched - so a `switch` on `Behavior_Event.code` or `Fired_Event.code` can legitimately see
// a value with no name, and needs a `case:` for it. This is the one enum in the package that is used as
// both a named set and an open number space.
//
// `app_event` is how to spell one of your own. It asserts the floor, because a code below it collides
// with an engine event - and `.BUTTON_CLICK` is 0, so the collision that costs the most time to find is
// the one you get by forgetting to add the base at all.
app_event :: proc(n: u32, loc := #caller_location) -> sciter.Behavior_Events {
	base := u32(sciter.Behavior_Events.FIRST_APPLICATION_EVENT_CODE)
	fmt.assertf(
		n >= base,
		"an application event code must be at or above FIRST_APPLICATION_EVENT_CODE (%d), got %d",
		base,
		n,
		loc = loc,
	)
	return sciter.Behavior_Events(n)
}

// The mouse group needs one more bit taken off. `MOUSE_EVENTS.DRAGGING` is 0x100, and the header says
// it is "ORed with MOUSE_ENTER...MOUSE_DOWN codes above" - so it sits *below* `EVENT_CODE_MASK` and
// survives `event_code`, which would leave a drag's `.MOUSE_MOVE` reading as 258 and matching nothing.
// `Mouse_Event.dragging` carries the bit instead.
@(private)
mouse_code :: proc(cmd: Event_Cmd) -> u32 {
	return event_code(cmd) & ~u32(sciter.Mouse_Events.DRAGGING)
}

// The direction bit, and only that. Readable whether or not anything has claimed the event.
event_phase :: proc(cmd: Event_Cmd) -> Event_Phase {
	return .Sinking if u32(cmd) & u32(sciter.Phase_Mask.SINKING) != 0 else .Bubbling
}

// Whether something upstream has already claimed this event. Independent of the phase: an event can
// arrive sinking and handled, or bubbling and handled.
event_handled :: proc(cmd: Event_Cmd) -> bool {
	return u32(cmd) & u32(sciter.Phase_Mask.HANDLED) != 0
}

// ---------------------------------------------------------------------------------------------------
// Typed parameters
//
// Each returns false if the event is not of that group, so the usual shape is:
//
//	if be, ok := behavior_event(event); ok && be.code == .BUTTON_CLICK { ... }

Behavior_Event :: struct {
	// Named for the engine's own events, but **not a closed set**: an application code passes through
	// unnamed, so a `switch` on this needs a `case:`. See `app_event`.
	code:    sciter.Behavior_Events,
	phase:   Event_Phase,
	handled: bool, // something upstream already claimed it - independent of the phase
	target:  Element, // the element the behavior belongs to - the button that was clicked
	source:  Element, // the element the event originated from
	reason:  uintptr, // a CLICK_REASON or EDIT_CHANGED_REASON, depending on `code`
	data:    ^Value, // event payload; borrowed, do not clear
	raw:     ^sciter.Behavior_Event_Params,
}

behavior_event :: proc(event: Event) -> (be: Behavior_Event, ok: bool) {
	if event.group != {.BEHAVIOR_EVENT} || event.params == nil {
		return {}, false
	}
	p := (^sciter.Behavior_Event_Params)(event.params)
	return Behavior_Event {
			code = sciter.Behavior_Events(event_code(Event_Cmd(p.cmd))),
			phase = event_phase(Event_Cmd(p.cmd)),
			handled = event_handled(Event_Cmd(p.cmd)),
			target = Element(p.heTarget),
			source = Element(p.he),
			reason = p.reason,
			data = &p.data,
			raw = p,
		},
		true
}

// The name carried by a `.CUSTOM` behaviour event - the one `fire_event` was given, and the one script
// wrote in `element.on("name", …)`. Allocated in `allocator`; `""` for every other event, which have no
// name rather than an empty one.
//
// It is decoded on demand rather than sitting in `Behavior_Event` because the engine hands it over as
// UTF-16 and most handlers never look at it.
event_name :: proc(be: Behavior_Event, allocator := context.allocator) -> string {
	if be.raw == nil || be.raw.name == nil {
		return ""
	}
	return string_from_utf16_cstring(be.raw.name, allocator)
}

// `buttons` is every button held during the event, so it is empty for an ordinary move and holds two
// entries when two are down - `.MAIN_MOUSE_BUTTON in me.buttons` is the question to ask.
//
// `dragging` is the engine's *internal* drag, which is the `DRAGGING` flag OR'ed into the event code
// rather than a code of its own: during one, `.MOUSE_ENTER` and friends arrive with it set and
// `dragged` naming the element being dragged over. It is unrelated to the `.EXCHANGE` group, which is
// the system's cross-application drag - see `Exchange_Event`.
Mouse_Event :: struct {
	code:     sciter.Mouse_Events,
	phase:    Event_Phase,
	handled:  bool, // something upstream already claimed it - independent of the phase
	target:   Element,
	pos:      [2]i32, // relative to the target element
	buttons:  sciter.Mouse_Buttons,
	dragging: bool, // the DRAGGING flag was set on the code
	dragged:  Element, // the element being dragged over; nil unless `dragging`
	raw:      ^sciter.Mouse_Params,
}

mouse_event :: proc(event: Event) -> (me: Mouse_Event, ok: bool) {
	if event.group != {.MOUSE} || event.params == nil {
		return {}, false
	}
	p := (^sciter.Mouse_Params)(event.params)
	return Mouse_Event {
			code = sciter.Mouse_Events(mouse_code(Event_Cmd(p.cmd))),
			phase = event_phase(Event_Cmd(p.cmd)),
			handled = event_handled(Event_Cmd(p.cmd)),
			target = Element(p.target),
			pos = {i32(p.pos.x), i32(p.pos.y)},
			buttons = p.button_state,
			dragging = p.cmd & u32(sciter.Mouse_Events.DRAGGING) != 0,
			dragged = Element(p.dragging),
			raw = p,
		},
		true
}

Key_Event :: struct {
	code:      sciter.Key_Events,
	phase:     Event_Phase,
	handled:   bool, // something upstream already claimed it - independent of the phase
	target:    Element,
	key_code:  u32, // a virtual key for KEY_DOWN/KEY_UP, a character for KEY_CHAR
	modifiers: sciter.Keyboard_States,
	raw:       ^sciter.Key_Params,
}

key_event :: proc(event: Event) -> (ke: Key_Event, ok: bool) {
	if event.group != {.KEY} || event.params == nil {
		return {}, false
	}
	p := (^sciter.Key_Params)(event.params)
	return Key_Event {
			code = sciter.Key_Events(event_code(Event_Cmd(p.cmd))),
			phase = event_phase(Event_Cmd(p.cmd)),
			handled = event_handled(Event_Cmd(p.cmd)),
			target = Element(p.target),
			key_code = p.key_code,
			modifiers = p.alt_state,
			raw = p,
		},
		true
}

// A drag-and-drop event - the engine's EXCHANGE group, which is system drag-and-drop rather than
// anything the document does on its own.
//
// The sequence for one drop, measured against an X11 drag source on 6.0.4.9, is
//
//	WILL_ACCEPT_DROP -> DRAG_ENTER -> DRAG -> WILL_ACCEPT_DROP -> DROP
//
// each delivered twice, sinking then bubbling. **The target has to consume both `.WILL_ACCEPT_DROP` and
// `.DRAG`** - that is `on_event` returning true for them - or the engine tells the drag source it is
// not interested and no `.DROP` ever arrives. `sciter-x-behavior.h` mentions only the first of the two;
// consuming just that was measured to leave the drop refused. See docs/events.md.
Exchange_Event :: struct {
	code:    sciter.Exchange_Cmd,
	phase:   Event_Phase,
	handled: bool, // something upstream already claimed it - independent of the phase
	target:  Element, // the element under the cursor
	source:  Element, // the dragged element, and nil for a drag from another application
	pos:     [2]i32, // relative to the target element
	view:    [2]i32, // relative to the window
	mode:    sciter.Dd_Modes, // copy / move / link, as the source offered it
	data:    ^Value, // the dragged payload; borrowed, do not clear
	raw:     ^sciter.Exchange_Params,
}

exchange_event :: proc(event: Event) -> (xe: Exchange_Event, ok: bool) {
	if event.group != {.EXCHANGE} || event.params == nil {
		return {}, false
	}
	p := (^sciter.Exchange_Params)(event.params)
	return Exchange_Event {
			code = sciter.Exchange_Cmd(event_code(Event_Cmd(p.cmd))),
			phase = event_phase(Event_Cmd(p.cmd)),
			handled = event_handled(Event_Cmd(p.cmd)),
			target = Element(p.target),
			source = Element(p.source),
			pos = {i32(p.pos.x), i32(p.pos.y)},
			view = {i32(p.pos_view.x), i32(p.pos_view.y)},
			mode = p.mode,
			data = &p.data,
			raw = p,
		},
		true
}

// A paint request - the engine's DRAW group, and the onscreen way to get a `Graphics`.
//
// One repaint of an element produces four of these, one per layer, in order: `.BACKGROUND`, `.CONTENT`,
// `.FOREGROUND`, `.OUTLINE`. Returning true from `on_event` **replaces** that layer: the engine's own
// painting of it does not happen. Returning false draws over it instead, leaving the engine's own
// background or content underneath.
//
// This is a high-frequency event. Subscribe to `.DRAW` only on the elements you actually draw.
Draw_Event :: struct {
	layer: sciter.Draw_Events,
	gfx:   Graphics, // the engine's context, valid for this call only
	area:  Rect, // the element's area, in the context's coordinates
	raw:   ^sciter.Draw_Params,
}

draw_event :: proc(event: Event) -> (de: Draw_Event, ok: bool) {
	if event.group != {.DRAW} || event.params == nil {
		return {}, false
	}
	p := (^sciter.Draw_Params)(event.params)
	return Draw_Event {
			layer = sciter.Draw_Events(p.cmd),
			gfx = Graphics(p.gfx),
			area = Rect {
				x = p.area.left,
				y = p.area.top,
				width = p.area.right - p.area.left,
				height = p.area.bottom - p.area.top,
			},
			raw = p,
		},
		true
}

Timer_Event :: struct {
	id:  Timer_Id, // the id given to `set_timer`; 0 for the element's unnamed timer
	raw: ^sciter.Timer_Params,
}

timer_event :: proc(event: Event) -> (te: Timer_Event, ok: bool) {
	if event.group != {.TIMER} || event.params == nil {
		return {}, false
	}
	p := (^sciter.Timer_Params)(event.params)
	return Timer_Event{id = Timer_Id(p.timerId), raw = p}, true
}

// The focus moving. Six codes, and the pair that matter are `.LOST` and `.GOT` on the element itself;
// `.OUT` and `.IN` are the container's view of the same move, and `.REQUEST` / `.ADVANCE_REQUEST` are
// asked on the way up the chain before it happens.
//
// `target` is the *other* element in the move: for `.LOST` it is the element about to receive the
// focus, for `.GOT` the one that had it, and it can be nil at either end of the document.
//
// Setting `raw.cancel` during `.REQUEST` or `.LOST` refuses the move, which is how a form keeps the
// focus in a field that has not been filled in properly. It is a field of the caller's struct, so it
// only counts while the handler is on the stack.
Focus_Event :: struct {
	code:    sciter.Focus_Events,
	phase:   Event_Phase,
	handled: bool, // something upstream already claimed it - independent of the phase
	target:  Element,
	cause:   u32, // how the focus was moved; a FOCUS_CMD_TYPE for `.ADVANCE_REQUEST`
	raw:     ^sciter.Focus_Params,
}

focus_event :: proc(event: Event) -> (fe: Focus_Event, ok: bool) {
	if event.group != {.FOCUS} || event.params == nil {
		return {}, false
	}
	p := (^sciter.Focus_Params)(event.params)
	return Focus_Event {
			code = sciter.Focus_Events(event_code(Event_Cmd(p.cmd))),
			phase = event_phase(Event_Cmd(p.cmd)),
			handled = event_handled(Event_Cmd(p.cmd)),
			target = Element(p.target),
			cause = p.cause,
			raw = p,
		},
		true
}

// Something scrolled. **Delivered only to handlers on the element that scrolled** - measured: a
// handler attached with `attach_window_handler` never sees one, so this is an `attach_handler` event.
//
// `code` is deliberately a bare `u32` rather than `sciter.Scroll_Events`. The header's enum stops at
// `.ANIMATION_END` (12) and this engine emits **14** for an ordinary `set_scroll_pos`, so a typed
// field would print a value that does not exist. Compare against `u32(sciter.Scroll_Events.POS)` and
// friends where the code is one of the documented ones.
//
// **14 is a real code, not a flag on top of `.POS` (6).** Worth stating because 14 is 6 | 8 and that is
// exactly the shape `MOUSE_EVENTS.DRAGGING` has - but measured, a smooth `scroll_to_view` brackets its
// run with the header's own `.ANIMATION_START` (11) and `.ANIMATION_END` (12), delivered as 11 and 12
// with no extra bit set. If 8 were a flag those would arrive as 19 and 20. So the vendored header is
// simply behind the engine here, and masking anything off `code` would corrupt it.
//
// The same measurement shows 14 is not only a `set_scroll_pos` code: during a smooth scroll it arrives
// once per frame between 11 and 12, with `source` reading `.ANIMATOR` rather than `.SCROLLBAR`.
//
// `source` says where the scroll came from, and it chooses what `reason` means: a key code for
// `.KEYBOARD`, a SCROLLBAR_PART for `.SCROLLBAR`, nothing for the rest.
Scroll_Event :: struct {
	code:     u32,
	phase:    Event_Phase,
	handled:  bool, // something upstream already claimed it - independent of the phase
	target:   Element,
	pos:      i32, // the new offset, for a position-carrying code
	vertical: bool, // false means the horizontal scrollbar
	source:   sciter.Scroll_Source,
	reason:   u32,
	raw:      ^sciter.Scroll_Params,
}

scroll_event :: proc(event: Event) -> (se: Scroll_Event, ok: bool) {
	if event.group != {.SCROLL} || event.params == nil {
		return {}, false
	}
	p := (^sciter.Scroll_Params)(event.params)
	return Scroll_Event {
			code = event_code(Event_Cmd(p.cmd)),
			phase = event_phase(Event_Cmd(p.cmd)),
			handled = event_handled(Event_Cmd(p.cmd)),
			target = Element(p.target),
			pos = p.pos,
			vertical = bool(p.vertical),
			source = p.source,
			reason = p.reason,
			raw = p,
		},
		true
}

// An attribute was written or removed - the engine's ATTRIBUTE_CHANGE group, and the way to watch a
// document for a change your own code did not make.
//
// **Delivered only to handlers on the element itself**, like `.SCROLL`. Measured: it fires for
// `set_attribute` from Odin and for `setAttribute` from script alike, and a removal arrives with
// `value` empty rather than as a separate code.
//
// `removed` is the distinction that emptiness alone cannot carry. The header says "new attribute value,
// NULL if attribute was deleted" (sciter-x-behavior.h), and a nil pointer decodes to `""` - so without
// this flag `removeAttribute("data-x")` and `setAttribute("data-x", "")` are the same event, and
// "there is no state" reads as "the state is empty".
//
// `name` is borrowed from the engine and valid for the call. `value` is decoded into `allocator`,
// because the engine hands it over as UTF-16.
Attribute_Change :: struct {
	element: Element,
	name:    string,
	value:   string,
	removed: bool,
	raw:     ^sciter.Attribute_Change_Params,
}

attribute_change_event :: proc(event: Event, allocator := context.allocator) -> (ac: Attribute_Change, ok: bool) {
	if event.group != {.ATTRIBUTE_CHANGE} || event.params == nil {
		return {}, false
	}
	p := (^sciter.Attribute_Change_Params)(event.params)
	return Attribute_Change {
			element = Element(p.he),
			name    = string(p.name),
			value   = string_from_utf16_cstring(p.value, allocator),
			removed = p.value == nil, // read before the decode turns nil into ""
			raw     = p,
		}, true
}

// A touch gesture. The engine keeps the group and the parameter struct, but the `GESTURE_CMD` enum is
// **commented out** in sciter-x-behavior.h on this SDK, so `code` is a bare number here: there is no
// list of values upstream to name it against.
Gesture_Event :: struct {
	code:    u32,
	phase:   Event_Phase,
	handled: bool, // something upstream already claimed it - independent of the phase
	target:  Element,
	pos:     [2]i32, // relative to the target element
	raw:     ^sciter.Gesture_Params,
}

gesture_event :: proc(event: Event) -> (ge: Gesture_Event, ok: bool) {
	if event.group != {.GESTURE} || event.params == nil {
		return {}, false
	}
	p := (^sciter.Gesture_Params)(event.params)
	return Gesture_Event {
			code = event_code(Event_Cmd(p.cmd)),
			phase = event_phase(Event_Cmd(p.cmd)),
			handled = event_handled(Event_Cmd(p.cmd)),
			target = Element(p.target),
			pos = {i32(p.pos.x), i32(p.pos.y)},
			raw = p,
		},
		true
}

// `.SIZE` has no accessor because it has no parameters: the engine passes nothing at all, and
// `event.element` - the element whose box changed - is the entire payload. Measured, it is delivered
// to handlers on that element only, and it is the element's own resize rather than the window's:
// maximizing and restoring the window produced none, restyling a `<div>`'s width produced one.

// ---------------------------------------------------------------------------------------------------
// Asking the engine to fetch something
//
// The engine's loader, aimed at one element: it fetches a URL through the same pipeline a document's
// own resources go through - the host callback included - and hands the bytes to that element as a
// `.DATA_ARRIVED` event.
//
// This is the way to load data *for* an element without doing the I/O yourself, and it is where
// `this://app/` archive URLs and any custom scheme the host implements keep working.

// Asks for `url`, to be delivered to `element` as `.DATA_ARRIVED`.
//
// `data_type` is a `sciter.Sciter_Resource_Type` handed back untouched in the event, so it is a label
// for the requester rather than something the engine interprets. `initiator` is likewise carried
// through as `Data_Arrived.initiator`, for telling several requests apart.
//
// The call returns as soon as the request is queued; the answer arrives on a later turn of the pump.
// **A failure is reported through the event too**, not here: a URL that does not exist still returns
// `nil` and arrives with `len(data) == 0`.
//
// `http_request` below is the same delivery with a method and parameters, for when the URL is not
// enough.
request_element_data :: proc(
	element: Element,
	url: string,
	data_type := sciter.Sciter_Resource_Type.RAW,
	initiator: Element = nil,
) -> Error {
	w := utf16_from_string(url, context.temp_allocator)
	return dom_err(
		engine().SciterRequestElementData(
			sciter.Helement(element),
			raw_data(w),
			data_type,
			sciter.Helement(initiator),
		),
	)
}

// How `http_request` asks. The C API's synchronous variants are deliberately not surfaced: measured,
// `GET_SYNC` returns `.OPERATION_FAILED` immediately, issues the request anyway, and then delivers the
// answer asynchronously like the others - so there is nothing synchronous about it to offer.
Http_Method :: enum {
	Get,
	Post,
}

// Fetches a URL over HTTP with a method, parameters and the engine's own networking, and delivers the
// body to `element` as `.DATA_ARRIVED` - the same event `request_element_data` produces.
//
//	sciter_app.http_request(list, "https://api.example.com/rows", .Get, {{"page", "2"}})
//
// **Parameters go where the method puts them**, measured against a real server: a `.Get` encodes them
// into the query string - `?page=2&q=two%20words`, escaping done for you - and a `.Post` sends them as
// the body. Passing none is fine.
//
// The `status` in the event is the HTTP one, so 200 is success and 404 arrives with the server's error
// page as `data` rather than as a failure here. A connection that could not be made arrives with
// `status = 0` and no data. See `Data_Arrived` for the whole story about that field.
//
// **The engine denies socket access by default**, so this returns success and nothing ever arrives
// until `set_script_features({.SOCKET_IO})` has been called - before the window, like every other
// engine option. That is the first thing to check when a request goes quiet.
//
// A `file://` URL works here too, which makes this a superset of `request_element_data`; that call is
// the one to reach for when there is no method or parameters to give.
http_request :: proc(
	element: Element,
	url: string,
	method := Http_Method.Get,
	params: []Name_Value = nil,
	data_type := sciter.Sciter_Resource_Type.RAW,
) -> Error {
	w := utf16_from_string(url, context.temp_allocator)

	// The engine wants an array of {name, value} UTF-16 pointers, and everything here - the URL, the
	// array, and both strings of every pair - is built in the temp allocator while the request itself is
	// **asynchronous**, which is the shape a use-after-free hides in: a caller that frees its arena at
	// the end of the turn would pull the memory out from under an in-flight request.
	//
	// Measured, because "the engine copies it" was an assumption and this is where being wrong is
	// expensive. Against a local server, for `.Get` and `.Post` alike: issue the request, `free_all` the
	// temp arena, overwrite it (a canary taken next to these allocations reads 0xAA afterwards, so the
	// overwrite lands), then pump. The server received `?page=2&q=two%20words` and the POST body
	// `page=2&q=two%20words` intact both times. So the engine copies during the call and the temp
	// allocator is correct here.
	encoded: []sciter.Request_Param
	if len(params) > 0 {
		encoded = make([]sciter.Request_Param, len(params), context.temp_allocator)
		for pair, i in params {
			encoded[i] = {
				name  = raw_data(utf16_from_string(pair.name, context.temp_allocator)),
				value = raw_data(utf16_from_string(pair.value, context.temp_allocator)),
			}
		}
	}

	request_type := sciter.Request_Type.GET_ASYNC if method == .Get else sciter.Request_Type.POST_ASYNC
	return dom_err(
		engine().SciterHttpRequest(
			sciter.Helement(element),
			raw_data(w),
			data_type,
			request_type,
			raw_data(encoded),
			u32(len(encoded)),
		),
	)
}

// Bytes that `request_element_data` or `http_request` asked for. Delivered to handlers on the
// **receiving element**, the one the request named.
//
// `data` and `uri` both point into the engine's memory and are valid for the call only - copy anything
// that has to outlive the handler.
//
// **`status` is not one scale, so do not test it for success.** Measured, all four cases:
//
//   - an `http://` response puts its own code there - 200 for a fetch that worked, 404 with the
//     server's error page as `data`, 501, and so on
//   - a `file://` load that worked answers **0**, not 200
//   - a `file://` load that failed answers an errno - 2 for a missing file
//   - a connection that could not be made answers 0, with no data
//
// So 0 means both "a local file, fine" and "the network went nowhere", which is why the header's
// comment that 0 is an unknown error is only a third right. **`len(data) == 0` is the reliable failure
// test**; `status` is worth reading afterwards to say *why*, and is the HTTP code when there was one.
Data_Arrived :: struct {
	initiator: Element, // whatever was passed to `request_element_data`
	data:      []u8,
	type:      sciter.Sciter_Resource_Type,
	status:    u32,
	uri:       string, // decoded into the accessor's allocator
	raw:       ^sciter.Data_Arrived_Params,
}

data_arrived_event :: proc(event: Event, allocator := context.allocator) -> (da: Data_Arrived, ok: bool) {
	if event.group != {.DATA_ARRIVED} || event.params == nil {
		return {}, false
	}
	p := (^sciter.Data_Arrived_Params)(event.params)

	data: []u8
	if p.data != nil && p.dataSize > 0 {
		data = p.data[:p.dataSize]
	}
	return Data_Arrived {
			initiator = Element(p.initiator),
			data = data,
			type = p.dataType,
			status = p.status,
			uri = string_from_utf16_cstring(p.uri, allocator),
			raw = p,
		},
		true
}

// ---------------------------------------------------------------------------------------------------
// Mouse capture
//
// While an element holds the capture, every mouse event goes to it wherever the pointer is - outside
// the element, outside the window. That is what a drag needs: a `.MOUSE_DOWN` handler that starts one
// takes the capture, follows `.MOUSE_MOVE` until `.MOUSE_UP`, and releases it there.
//
//	case .MOUSE_DOWN: sciter_app.set_capture(handle)
//	case .MOUSE_UP:   sciter_app.release_capture(handle)
//
// Note that this is *mouse* capture, unrelated to the drag-and-drop events in this file - those are
// the system's own drag protocol, for data crossing an application boundary.

// Routes all mouse events to `element` until the capture is released. `.INVALID_HWND` if the element
// is not in a document, since the capture belongs to the window.
//
// Taking the capture while another element holds it moves it, rather than failing.
set_capture :: proc(element: Element) -> Error {
	return dom_err(engine().SciterSetCapture(sciter.Helement(element)))
}

// Gives the capture back. Releasing when nothing was captured, or when another element has it, is not
// an error - the engine reports success either way, so this is safe to call unconditionally on the way
// out of a drag.
release_capture :: proc(element: Element) -> Error {
	return dom_err(engine().SciterReleaseCapture(sciter.Helement(element)))
}

// ---------------------------------------------------------------------------------------------------
// Timers
//
// A timer belongs to an element and delivers a `.TIMER` event to the handlers on it. It is the engine's
// own clock rather than a thread: the event arrives on the engine's thread, inside the message pump,
// so a handler can touch the DOM directly and needs no synchronisation.
//
// The return value of `on_event` means something different here, and it is the one place in this
// package where returning false is not the safe default:
//
//	if te, ok := sciter_app.timer_event(event); ok {
//		tick(te.id)
//		return true    // keep the timer running; false stops it
//	}
//
// A handler that ends in `return false` - the advice for every other group, so that nothing is
// swallowed - stops the timer after its first tick.

// Which timer on an element. It is an opaque token rather than a number the engine interprets: any
// value distinguishes one timer from another, and it comes back unchanged as `Timer_Event.id`.
//
// Distinct because `uintptr` is the package's escape hatch elsewhere too - `set_option`'s value, an
// animation frame's `reason` - and those are not the same thing, so passing one where another belongs
// used to type check. Untyped constants still work (`set_timer(el, TICK, 7)`), which is how these ids
// are written in practice.
Timer_Id :: distinct uintptr

// Starts, or restarts, a timer on `element`. The element must stay in the document: a timer goes away
// with the element it belongs to.
//
// `id` distinguishes several timers on one element and arrives back as `Timer_Event.id`. Calling this
// again with the same `id` replaces that timer rather than adding a second one, so it doubles as
// "change the interval".
//
// The engine counts in whole milliseconds. A positive `interval` shorter than one millisecond is
// raised to one rather than rounded down, because rounding down to zero would stop the timer - see
// `stop_timer`, which is what that spelling means.
//
// A negative interval is `.INVALID_PARAMETER`, and so is one over `max(u32)` milliseconds (~49.7 days).
// Both used to reach the engine as a `u32`: the first as 0, which silently *stopped* a running timer
// from what was usually an arithmetic slip, and the second wrapped to whatever the low 32 bits held.
// `stop_timer` is the only spelling of stopping.
set_timer :: proc(element: Element, interval: time.Duration, id: Timer_Id = 0) -> Error {
	if interval < 0 {
		return sciter.Scdom_Result.INVALID_PARAMETER
	}
	ms := i64(interval / time.Millisecond)
	if interval > 0 && ms < 1 {
		ms = 1
	}
	if ms > i64(max(u32)) {
		return sciter.Scdom_Result.INVALID_PARAMETER
	}
	return dom_err(engine().SciterSetTimer(sciter.Helement(element), u32(ms), uintptr(id)))
}

// Stops the timer `id` on `element`. Stopping one that is not running is not an error.
stop_timer :: proc(element: Element, id: Timer_Id = 0) -> Error {
	return dom_err(engine().SciterSetTimer(sciter.Helement(element), 0, uintptr(id)))
}

// ---------------------------------------------------------------------------------------------------
// Animation frames
//
// The engine's own frame clock, which `set_timer` is not: a timer counts milliseconds and fires
// whether or not anything is being drawn, while this fires once, on the next frame the engine paints.
// It is script's `requestAnimationFrame` reached from native code, and it is what an animation driven
// from Odin should be paced by.

// Asks the engine to deliver `code` to `element` on the next frame.
//
// **The handler's return value decides whether it happens again**, which is the same inversion the
// `.TIMER` group has and the opposite of the advice everywhere else in this file: returning true
// re-arms it for the next frame, returning false stops it. Measured - one request answered `false`
// produced exactly one event however long the pump ran afterwards, and answered `true` produced one
// per frame.
//
//	on_event :: proc(h: ^sciter_app.Event_Handler, ev: sciter_app.Event) -> bool {
//		if be, ok := sciter_app.behavior_event(ev); ok && be.code == TICK {
//			advance(h)
//			return h.still_animating    // true keeps the frames coming; false is the last one
//		}
//		return false
//	}
//
// So a handler that ends in a blanket `return false` gets one frame and stops, and one that returns
// true unconditionally animates for the life of the element.
//
// `code` arrives as an ordinary `.BEHAVIOR_EVENT` carrying `reason`, so use one of your own at or
// above `.FIRST_APPLICATION_EVENT_CODE`: the default here is `.BUTTON_CLICK`'s numeric value 0 in the
// C API, which would be indistinguishable from a real click. The event goes to handlers on `element`
// itself.
//
// Three measured details. The event is delivered **only to handlers on `element`** - a window handler
// never sees it, so this needs `attach_handler`. The engine brackets it with its own `.ANIMATION`
// events - `reason = 1` before and `reason = 0` after, and those two *do* bubble to a window handler -
// so a handler watching for `.ANIMATION` sees a pair around every request. And a nil element is
// `.INVALID_HANDLE`.
request_animation_frame :: proc(element: Element, code: sciter.Behavior_Events, reason: uintptr = 0) -> Error {
	return dom_err(engine().SciterRequestAnimationFrameEvent(sciter.Helement(element), u32(code), reason))
}

// ---------------------------------------------------------------------------------------------------
// Synthesising events

// Sends a behaviour event synchronously down to `element` and back up, and reports whether a handler
// claimed it.
//
// This is *not* the same as the user doing it. It injects the event code into the element chain
// directly, which bypasses the intrinsic behavior that would normally produce it. Handlers do hear the
// event - a window handler counting `.BUTTON_CLICK`s counts this one - but nothing else happens:
// measured on a checkbox, sending `.BUTTON_CLICK` leaves `:checked` exactly as it was. Use it for
// application event codes of your own (BEHAVIOR_EVENTS values at or above
// `FIRST_APPLICATION_EVENT_CODE`), which have no behavior behind them.
//
// To drive the widget rather than announce it, call the behavior: `do_click` in `behavior.odin` flips
// the checkbox and raises the events a real click would. Going through script -
// `eval(window, "document.$(sel).click()")` - is the other way there.
//
// `source` has to be an element. The engine delivers nothing at all for a nil one - not to `element`,
// not to anything on the chain - and says so by reporting the call as succeeded and not handled, which
// is indistinguishable from an event nobody wanted. Pass `element` itself if there is no separate
// originating element. The same goes for `post_event`.
//
// Which handle ends up where is worth knowing before matching on it: `source` arrives as the
// parameters' *target* (`Behavior_Event.target`) and `element` as their *source*
// (`Behavior_Event.source`), the opposite way round from an event an intrinsic behavior produced.
send_event :: proc(
	element: Element,
	code: sciter.Behavior_Events,
	source: Element = nil,
	reason: uintptr = 0,
) -> (
	handled: bool,
	err: Error,
) {
	was_handled: b32
	dom_err(
		engine().SciterSendEvent(sciter.Helement(element), u32(code), sciter.Helement(source), reason, &was_handled),
	) or_return
	return bool(was_handled), nil
}

// The same, queued rather than run immediately. Returns before any handler sees it.
post_event :: proc(
	element: Element,
	code: sciter.Behavior_Events,
	source: Element = nil,
	reason: uintptr = 0,
) -> Error {
	return dom_err(engine().SciterPostEvent(sciter.Helement(element), u32(code), sciter.Helement(source), reason))
}

// ---------------------------------------------------------------------------------------------------
// Synthesising input
//
// `send_event` announces that something happened; these make it happen. They are the engine's
// `SciterTraverseUIEvent`, which sinks-and-bubbles a mouse or key event through the element chain the
// way the window system's own input does - so the intrinsic behaviors run, and a `<button>` really is
// pressed and clicked, an `<input>` really is typed into.
//
//	sciter_app.send_mouse(button, .MOUSE_DOWN, centre, {.MAIN_MOUSE_BUTTON})
//	sciter_app.send_mouse(button, .MOUSE_UP, centre, {.MAIN_MOUSE_BUTTON})   // BUTTON_CLICK follows
//
// This is what a test that wants to drive its own UI needs, and what an accessibility or automation
// layer is built on. `do_click` in `behavior.odin` is the shortcut for the one common case; this is
// the general mechanism, and the only route to hover, drag, the wheel and the keyboard.
//
// Three things are required, each of which fails silently-ish if missed:
//
//   - **`element` must not be nil.** The C API takes the target inside the parameter block and there is
//     no hit testing here: a nil one is `.INVALID_HANDLE`. `element_at` is how to turn a point into the
//     element to name.
//   - **`buttons` must say which button is down** for a press to count. Measured: `.MOUSE_DOWN` with an
//     empty set is delivered to handlers, reports `processed = false`, and the button behavior ignores
//     it - no `:active`, no `.BUTTON_CLICK`. With `{.MAIN_MOUSE_BUTTON}` the behavior runs.
//   - **the position is in the window's client area**, the space `location(el, .Border, .View)` and
//     `element_at` use. The engine recomputes the element-relative `pos` each handler sees from it.

// Delivers a mouse event to `element` and reports whether anything acted on it.
//
// `pos` is in the window's client area. `buttons` is which buttons are held *during* the event, so a
// press and its release both carry the button - it is not "which button changed".
send_mouse :: proc(
	element: Element,
	code: sciter.Mouse_Events,
	pos: [2]i32,
	buttons: sciter.Mouse_Buttons = {},
	modifiers: sciter.Keyboard_States = {},
) -> (
	processed: bool,
	err: Error,
) {
	params := sciter.Mouse_Params {
		cmd = u32(code),
		target = sciter.Helement(element),
		pos = {x = pos.x, y = pos.y},
		pos_view = {x = pos.x, y = pos.y},
		button_state = buttons,
		alt_state = modifiers,
	}
	was: b32
	// The group is passed as the *mask*, not the enum's ordinal - `Event_Group.MOUSE` is 0 and would be
	// `.INVALID_PARAMETER`. Only the mouse and key masks are accepted; anything else is refused.
	dom_err(engine().SciterTraverseUIEvent(transmute(u32)sciter.Event_Groups{.MOUSE}, &params, &was)) or_return
	return bool(was), nil
}

// Delivers a key event to `element`. `key_code` is a virtual key for `.DOWN` and `.UP`, and a
// character for `.CHAR`.
//
// A real keystroke is three of these - `.DOWN`, `.CHAR`, `.UP` - and the editing behaviors act on the
// `.CHAR`. `send_text` is the loop over them.
send_key :: proc(
	element: Element,
	code: sciter.Key_Events,
	key_code: u32,
	modifiers: sciter.Keyboard_States = {},
) -> (
	processed: bool,
	err: Error,
) {
	params := sciter.Key_Params {
		cmd       = u32(code),
		target    = sciter.Helement(element),
		key_code  = key_code,
		alt_state = modifiers,
	}
	was: b32
	dom_err(engine().SciterTraverseUIEvent(transmute(u32)sciter.Event_Groups{.KEY}, &params, &was)) or_return
	return bool(was), nil
}

// Types `text` into `element`, one character at a time, as `.DOWN` / `.CHAR` / `.UP` triples.
//
// The element has to be one that accepts typing and has the focus - `set_focus` first - and what
// arrives is real input: the edit behavior raises `.VALUE_CHANGING` and `.VALUE_CHANGED`, and
// `element_value` reads back what was typed. Measured on a text `<input>`.
//
// Each rune is sent as one key code, which is right for text and not for anything needing a modifier -
// use `send_key` for those.
send_text :: proc(element: Element, text: string) -> Error {
	for r in text {
		send_key(element, .DOWN, u32(r)) or_return
		send_key(element, .CHAR, u32(r)) or_return
		send_key(element, .UP, u32(r)) or_return
	}
	return nil
}

// ---------------------------------------------------------------------------------------------------
// Named events
//
// `send_event` and `post_event` carry a code, a source and a reason. This carries a *name* and a
// *payload* as well, which is what makes it the channel to script:
//
//	document.$("#chart").on("data-arrived", function(e) { redraw(e.data); });
//
//	value := sciter_app.value_parse(json)
//	defer sciter_app.value_clear(&value)
//	sciter_app.fire_event({code = .CUSTOM, name = "data-arrived", target = chart, data = &value})
//
// Script sees an ordinary event whose type is the name, so a document can be written against events it
// declares and Odin can raise them without knowing what listens.

// One event to raise. Everything but `code` is optional.
Fired_Event :: struct {
	// `.CUSTOM` for a named event; a `Behavior_Events` value at or above `.FIRST_APPLICATION_EVENT_CODE`
	// for an application code of your own. Sending an engine code here does not run the behavior that
	// would normally produce it - see `send_event`.
	code:   sciter.Behavior_Events,

	// The name script matches on, for `.CUSTOM`. Ignored otherwise.
	name:   string,

	// Where it goes: down to `target` and back up, the same two phases every event has.
	//
	// **A nil target broadcasts** - the event goes to every window's document rather than nowhere. Only
	// handlers attached with `attach_window_handler` receive it; an element handler, `root`'s included,
	// does not.
	target: Element,

	// Arrives as `Behavior_Event.source`. Unlike `send_event`, a nil one here still delivers.
	source: Element,
	reason: uintptr,

	// Borrowed for the call and not consumed - the engine copies it, `post` included.
	data:   ^Value,
}

// Raises `event`, and reports whether a handler claimed it.
//
// `post = false` runs the handlers before returning, and `handled` is their answer. `post = true`
// queues it and returns immediately, so `handled` is always false and the event arrives on a later turn
// of the message pump - measured to copy the name and the payload, so neither has to outlive the call.
fire_event :: proc(event: Fired_Event, post := false) -> (handled: bool, err: Error) {
	params := sciter.Behavior_Event_Params {
		cmd      = u32(event.code),
		heTarget = sciter.Helement(event.target),
		he       = sciter.Helement(event.source),
		reason   = event.reason,
	}
	if event.data != nil {
		params.data = event.data^
	}
	if event.name != "" {
		params.name = raw_data(utf16_from_string(event.name, context.temp_allocator))
	}

	was_handled: b32
	dom_err(engine().SciterFireEvent(&params, b32(post), &was_handled)) or_return
	return bool(was_handled), nil
}
