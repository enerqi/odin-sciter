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
	// the rest of the trip carries the HANDLED bit, so later handlers see `Event_Phase.Handled`. It
	// does not cancel delivery: the bubbling pass still arrives at this handler, which is why acting
	// on every phase acts twice.
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
	return dom_err(sciter.api().SciterAttachEventHandler(sciter.Helement(element), event_trampoline, handler))
}

// Attaches `handler` to the window's whole document, including elements that do not exist yet.
attach_window_handler :: proc(window: Window, handler: ^Event_Handler) -> Error {
	handler.ctx = context
	return dom_err(
		sciter.api().SciterWindowAttachEventHandler(rawptr(window), event_trampoline, handler, handler.subscription),
	)
}

detach_handler :: proc(element: Element, handler: ^Event_Handler) -> Error {
	return dom_err(sciter.api().SciterDetachEventHandler(sciter.Helement(element), event_trampoline, handler))
}

detach_window_handler :: proc(window: Window, handler: ^Event_Handler) -> Error {
	return dom_err(sciter.api().SciterWindowDetachEventHandler(rawptr(window), event_trampoline, handler))
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

Event_Phase :: enum {
	Bubbling, // travelling back up from the target - the normal case
	Sinking, // travelling down towards the target, before it sees the event
	Handled, // something already claimed it
}

// The event code with the phase bits removed.
event_code :: proc(cmd: u32) -> u32 {
	return cmd & EVENT_CODE_MASK
}

event_phase :: proc(cmd: u32) -> Event_Phase {
	switch {
	case cmd & u32(sciter.Phase_Mask.HANDLED) != 0:
		return .Handled
	case cmd & u32(sciter.Phase_Mask.SINKING) != 0:
		return .Sinking
	}
	return .Bubbling
}

// ---------------------------------------------------------------------------------------------------
// Typed parameters
//
// Each returns false if the event is not of that group, so the usual shape is:
//
//	if be, ok := behavior_event(event); ok && be.code == .BUTTON_CLICK { ... }

Behavior_Event :: struct {
	code:   sciter.Behavior_Events,
	phase:  Event_Phase,
	target: Element, // the element the behavior belongs to - the button that was clicked
	source: Element, // the element the event originated from
	reason: uintptr, // a CLICK_REASON or EDIT_CHANGED_REASON, depending on `code`
	data:   ^Value, // event payload; borrowed, do not clear
	raw:    ^sciter.Behavior_Event_Params,
}

behavior_event :: proc(event: Event) -> (be: Behavior_Event, ok: bool) {
	if event.group != {.BEHAVIOR_EVENT} || event.params == nil {
		return {}, false
	}
	p := (^sciter.Behavior_Event_Params)(event.params)
	return Behavior_Event {
			code = sciter.Behavior_Events(event_code(p.cmd)),
			phase = event_phase(p.cmd),
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

Mouse_Event :: struct {
	code:    sciter.Mouse_Events,
	phase:   Event_Phase,
	target:  Element,
	pos:     [2]i32, // relative to the target element
	buttons: sciter.Mouse_Buttons,
	raw:     ^sciter.Mouse_Params,
}

mouse_event :: proc(event: Event) -> (me: Mouse_Event, ok: bool) {
	if event.group != {.MOUSE} || event.params == nil {
		return {}, false
	}
	p := (^sciter.Mouse_Params)(event.params)
	return Mouse_Event {
			code = sciter.Mouse_Events(event_code(p.cmd)),
			phase = event_phase(p.cmd),
			target = Element(p.target),
			pos = {i32(p.pos.x), i32(p.pos.y)},
			buttons = sciter.Mouse_Buttons(p.button_state),
			raw = p,
		},
		true
}

Key_Event :: struct {
	code:      sciter.Key_Events,
	phase:     Event_Phase,
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
			code = sciter.Key_Events(event_code(p.cmd)),
			phase = event_phase(p.cmd),
			target = Element(p.target),
			key_code = p.key_code,
			modifiers = sciter.Keyboard_States(p.alt_state),
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
	code:   sciter.Exchange_Cmd,
	phase:  Event_Phase,
	target: Element, // the element under the cursor
	source: Element, // the dragged element, and nil for a drag from another application
	pos:    [2]i32, // relative to the target element
	view:   [2]i32, // relative to the window
	mode:   sciter.Dd_Modes, // copy / move / link, as the source offered it
	data:   ^Value, // the dragged payload; borrowed, do not clear
	raw:    ^sciter.Exchange_Params,
}

exchange_event :: proc(event: Event) -> (xe: Exchange_Event, ok: bool) {
	if event.group != {.EXCHANGE} || event.params == nil {
		return {}, false
	}
	p := (^sciter.Exchange_Params)(event.params)
	return Exchange_Event {
			code = sciter.Exchange_Cmd(event_code(p.cmd)),
			phase = event_phase(p.cmd),
			target = Element(p.target),
			source = Element(p.source),
			pos = {i32(p.pos.x), i32(p.pos.y)},
			view = {i32(p.pos_view.x), i32(p.pos_view.y)},
			mode = sciter.Dd_Modes(p.mode),
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
	id:  uintptr, // the id given to `set_timer`; 0 for the element's unnamed timer
	raw: ^sciter.Timer_Params,
}

timer_event :: proc(event: Event) -> (te: Timer_Event, ok: bool) {
	if event.group != {.TIMER} || event.params == nil {
		return {}, false
	}
	p := (^sciter.Timer_Params)(event.params)
	return Timer_Event{id = p.timerId, raw = p}, true
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
	return dom_err(sciter.api().SciterSetCapture(sciter.Helement(element)))
}

// Gives the capture back. Releasing when nothing was captured, or when another element has it, is not
// an error - the engine reports success either way, so this is safe to call unconditionally on the way
// out of a drag.
release_capture :: proc(element: Element) -> Error {
	return dom_err(sciter.api().SciterReleaseCapture(sciter.Helement(element)))
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
set_timer :: proc(element: Element, interval: time.Duration, id: uintptr = 0) -> Error {
	ms := i64(interval / time.Millisecond)
	if interval > 0 && ms < 1 {
		ms = 1
	}
	if ms < 0 {
		ms = 0
	}
	return dom_err(sciter.api().SciterSetTimer(sciter.Helement(element), u32(ms), id))
}

// Stops the timer `id` on `element`. Stopping one that is not running is not an error.
stop_timer :: proc(element: Element, id: uintptr = 0) -> Error {
	return dom_err(sciter.api().SciterSetTimer(sciter.Helement(element), 0, id))
}

// ---------------------------------------------------------------------------------------------------
// Synthesising events

// Sends a behaviour event synchronously down to `element` and back up, and reports whether a handler
// claimed it.
//
// This is *not* the same as the user doing it. It injects the event code into the element chain
// directly, which bypasses the intrinsic behavior that would normally produce it: sending
// `.BUTTON_CLICK` to a <button> does not go through the button behavior, and a handler watching for
// clicks will not see one. Use it for application event codes of your own (BEHAVIOR_EVENTS values at
// or above `FIRST_APPLICATION_EVENT_CODE`), which have no behavior behind them.
//
// To simulate a real interaction, go through script instead - `eval(window, "document.$(sel).click()")`
// runs the behavior and produces the genuine event.
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
		sciter.api().SciterSendEvent(
			sciter.Helement(element),
			u32(code),
			sciter.Helement(source),
			reason,
			&was_handled,
		),
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
	return dom_err(sciter.api().SciterPostEvent(sciter.Helement(element), u32(code), sciter.Helement(source), reason))
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
	dom_err(sciter.api().SciterFireEvent(&params, b32(post), &was_handled)) or_return
	return bool(was_handled), nil
}
