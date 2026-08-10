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
