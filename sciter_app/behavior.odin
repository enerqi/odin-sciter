// Behavior methods: talking to the code *behind* an element rather than to the element.
//
// Three things can answer for a `<button>`. The DOM is one - `set_text`, `set_attribute`, and the rest
// of `dom.odin` - and script is another, reached with `call_method`. The third is the **intrinsic
// behavior**: the native code inside the engine that makes a button a button, a checkbox toggle, a
// hyperlink navigate. That code is not in the DOM and not in script, and this is the door to it.
//
//	handled, err := sciter_app.do_click(button)   // a real click: state changes, BUTTON_CLICK fires
//
// The distinction is worth being precise about, because `send_event` looks like it does the same job
// and does not. `send_event(button, .BUTTON_CLICK)` *injects the event code* into the element chain:
// handlers see a BUTTON_CLICK, and nothing else happens - measured on a checkbox, it leaves `:checked`
// exactly as it was. `do_click` calls the behavior, which does the work and then raises the event
// itself: the checkbox flips, a `VALUE_CHANGED` arrives ahead of the `BUTTON_CLICK`, and a hyperlink
// navigates. `send_event` is for application event codes of your own; this is for driving the widgets
// the engine already implements.
//
// The channel runs both ways. `SciterCallBehaviorMethod` delivers a `.METHOD_CALL` event to the
// handlers attached to the element, so an `Event_Handler` can *implement* a method as well as call one
// - see "Answering a method call" at the bottom of this file.
package sciter_app

import sciter ".."

// ---------------------------------------------------------------------------------------------------
// What behavior an element has

// Which intrinsic behavior an element carries: `.EDIT` for a text `<input>`, `.BUTTON`, `.CHECKBOX`,
// `.DD_SELECT` for a `<select>`, `.TEXTAREA`. `.NO` for an element with no behavior at all, which is
// most of a document - a `<div>`, a `<p>`, and `<html>` itself all answer `.NO`.
//
// This is the question to ask before `do_click` or `behavior_value`: it says what the element actually
// *is* to the engine, where the tag name only says what the markup called it. A `<div>` with
// `behavior: button` in its CSS answers `.BUTTON`.
//
// `.UNKNOWN` means there is a behavior but it is not one of the engine's own - a native behavior the
// host attached through `SC_ATTACH_BEHAVIOR`. `element_asset` in `som.odin` is the other half of the
// picture: what a *SOM* asset the element carries exposes.
control_type :: proc(element: Element) -> (type: sciter.Ctl_Type, err: Error) {
	dom_err(sciter.api().SciterControlGetType(sciter.Helement(element), &type)) or_return
	return type, nil
}

// ---------------------------------------------------------------------------------------------------
// Calling a method
//
// Every one of these reports `handled` separately from `err`, and the difference matters. The engine
// answers a method nothing implements with `OK_NOT_HANDLED`, which is a *success*: the call was
// well-formed and no behavior wanted it. That is not an error and it is not a result either, so it
// comes back as `handled = false` with `err = nil`. A real failure - a detached element, a null handle
// - is `err`.

// Clicks the element, through its behavior.
//
// `handled = true` means a behavior did something: a `<button>` raised `.BUTTON_CLICK`, a checkbox
// toggled `:checked` and raised `.VALUE_CHANGED` then `.BUTTON_CLICK`, a hyperlink navigated. An
// element with no behavior - a `<div>`, a `<p>` - is `handled = false` and nothing happens.
//
// Measured against this engine: a `<select>` answers `handled = false`, so this is not the way to open
// a dropdown. An element that is not in a document is `.PASSIVE_HANDLE`.
do_click :: proc(element: Element) -> (handled: bool, err: Error) {
	params := sciter.Method_Params {
		methodID = u32(sciter.Behavior_Method_Identifiers.DO_CLICK),
	}
	return call_behavior_method(element, &params)
}

// The value a behavior reports for the element, through the `GET_VALUE` method.
//
// **Read this before reaching for it: the engine's own behaviors do not implement `GET_VALUE` on
// Sciter 6.** Measured on a text `<input>`, a `<select>` and a `<div>`, every one answers
// `handled = false` and leaves the value undefined. `element_value` - which is `SciterGetValue`, a
// different call altogether - is what reads an `<input>`'s text, and it works.
//
// What this *is* good for is a behavior of your own: `GET_VALUE` is the protocol a native behavior
// implements so that generic code can ask any element for its value without knowing what it is. See
// "Answering a method call" below for the receiving side.
//
// The Value owns a reference when `handled` is true; `value_clear` it.
behavior_value :: proc(element: Element) -> (value: Value, handled: bool, err: Error) {
	params := sciter.Value_Params {
		methodID = u32(sciter.Behavior_Method_Identifiers.GET_VALUE),
	}
	handled, err = call_behavior_method(element, &params)
	if err != nil || !handled {
		value_clear(&params.val)
		return {}, handled, err
	}
	return params.val, true, nil
}

// Hands a behavior a new value, through the `SET_VALUE` method. The same caveat as `behavior_value`:
// **no intrinsic behavior implements it on Sciter 6** - use `set_element_value` for an `<input>` - and
// this is here for behaviors of your own.
//
// **`value` is borrowed, on both sides.** This wrapper does not consume it - it copies the 16-byte
// struct into the parameter block without taking a reference, and the caller still owns the one
// reference that exists. The receiving behavior therefore borrows it too, for the duration of the call
// only: a `SET_VALUE` implementation that wants to keep what it was handed must `value_copy` it, and
// must not `value_clear` it, or the caller is left holding a reference to a freed value. See
// "Answering a method call" below for the same rule from the implementer's side.
set_behavior_value :: proc(element: Element, value: ^Value) -> (handled: bool, err: Error) {
	params := sciter.Value_Params {
		methodID = u32(sciter.Behavior_Method_Identifiers.SET_VALUE),
	}
	if value != nil {
		params.val = value^
	}
	return call_behavior_method(element, &params)
}

// Whether a behavior considers the element empty - the `IS_EMPTY` method, which is what `:empty` is
// meant to reflect for a behavior that has an opinion. The same caveat again: **no intrinsic behavior
// implements it on Sciter 6**, so `handled` is false for every element in a plain document.
behavior_is_empty :: proc(element: Element) -> (is_empty: bool, handled: bool, err: Error) {
	params := sciter.Is_Empty_Params {
		methodID = u32(sciter.Behavior_Method_Identifiers.IS_EMPTY),
	}
	handled, err = call_behavior_method(element, &params)
	return params.is_empty != 0, handled, err
}

// Calls a behavior method by its raw parameter block - the escape hatch under the four wrappers above,
// and the only way to call a method of your own.
//
// A method's parameters are a struct whose **first field is the `u32` method id**; everything after it
// is that method's business, and the behavior writes its answer back into the same struct. So a method
// of your own is a struct you declare:
//
//	Set_Zoom_Params :: struct {
//		method_id: u32,       // must be first
//		factor:    f32,
//		applied:   b32,       // the behavior writes this
//	}
//
//	p := Set_Zoom_Params{method_id = SET_ZOOM, factor = 1.5}
//	handled, err := sciter_app.call_behavior_method(chart, &p)
//
// Pass any pointer; it is cast to the engine's `^Method_Params`, which is that leading id and nothing
// else. Ids below `sciter.Behavior_Method_Identifiers.FIRST_APPLICATION_METHOD_ID` (256) belong to the
// engine - use one at or above it. An id nobody implements is `handled = false`, not an error.
call_behavior_method :: proc(element: Element, params: rawptr) -> (handled: bool, err: Error) {
	if params == nil {
		return false, sciter.Scdom_Result.INVALID_PARAMETER
	}
	r := sciter.api().SciterCallBehaviorMethod(sciter.Helement(element), (^sciter.Method_Params)(params))
	// `OK_NOT_HANDLED` is a success that means "no behavior wanted it", which is exactly the
	// distinction `handled` carries - so it is read here, before `dom_err` folds it into nil.
	return r == .OK, dom_err(r)
}

// ---------------------------------------------------------------------------------------------------
// Answering a method call
//
// A method call arrives at the element's own handlers as a `.METHOD_CALL` event, so implementing one
// is an `Event_Handler` like any other:
//
//	handler := sciter_app.Event_Handler {
//		subscription = {.METHOD_CALL},
//		on_event     = on_event,
//	}
//	sciter_app.attach_handler(chart, &handler)
//
//	on_event :: proc(h: ^sciter_app.Event_Handler, ev: sciter_app.Event) -> bool {
//		mc, ok := sciter_app.method_call(ev)
//		if !ok { return false }
//		switch args in sciter_app.method_args(mc) {
//		case ^sciter.Value_Params:              // GET_VALUE / SET_VALUE
//			args.val = sciter_app.value_from(42)
//			return true
//		case ^sciter.Is_Empty_Params:           // IS_EMPTY
//			args.is_empty = 1
//			return true
//		}
//		if mc.id == SET_ZOOM {
//			p := (^Set_Zoom_Params)(mc.params)
//			...
//			return true
//		}
//		return false
//	}
//
// **Returning true is what makes the caller's `handled` true**, and it is also what makes anything
// written into the parameter block count - the block is the caller's memory, written in place, and the
// call is synchronous, so the caller sees it the moment `call_behavior_method` returns.
//
// Which settles who owns the Values in it, in both directions:
//
//   - **`GET_VALUE`: what you write into `args.val` is handed to the caller, and the caller owns it.**
//     The `value_from(42)` above makes a fresh Value with one reference and gives that reference away;
//     do not clear it here. Returning a Value you also keep means `value_copy` first.
//   - **`SET_VALUE`: `args.val` is borrowed for the call only.** The caller still owns the reference,
//     so keeping the value past the call means `value_copy`, and clearing it is a use-after-free in
//     the caller.
//
// One measured rule that shapes where the handler goes: **a method call is delivered only to handlers
// attached to that exact element.** It does not sink, it does not bubble, and a handler attached with
// `attach_window_handler` never sees one. `attach_handler` on the element itself is the only
// attachment that works.

// A `.METHOD_CALL` event: someone called `call_behavior_method` on this element.
Method_Call :: struct {
	// The method id. Compare against `sciter.Behavior_Method_Identifiers` for the engine's own, or
	// against your own constants at or above `.FIRST_APPLICATION_METHOD_ID`.
	id:     u32,

	// The caller's parameter block, to be cast to whatever struct that id means. `method_args` does
	// the cast for the ids the engine defines.
	params: rawptr,
}

// The typed parameter block behind a `Method_Call`, for the ids the engine defines. Both variants are
// **pointers into the caller's struct**: write to them and the caller sees it.
//
// `nil` for `DO_CLICK`, which carries no parameters beyond its id, and for any id of your own - cast
// `Method_Call.params` yourself for those.
Method_Args :: union {
	^sciter.Value_Params, // GET_VALUE and SET_VALUE
	^sciter.Is_Empty_Params, // IS_EMPTY
}

// Reads a `.METHOD_CALL` event's parameters. False for every other event group, like the other typed
// accessors in `events.odin`.
method_call :: proc(event: Event) -> (mc: Method_Call, ok: bool) {
	if event.group != {.METHOD_CALL} || event.params == nil {
		return {}, false
	}
	p := (^sciter.Method_Params)(event.params)
	return Method_Call{id = p.methodID, params = event.params}, true
}

// The engine-defined parameter block for a method call, or nil for `DO_CLICK` and for application ids.
method_args :: proc(mc: Method_Call) -> Method_Args {
	if mc.params == nil {
		return nil
	}
	switch sciter.Behavior_Method_Identifiers(mc.id) {
	case .GET_VALUE, .SET_VALUE:
		return (^sciter.Value_Params)(mc.params)
	case .IS_EMPTY:
		return (^sciter.Is_Empty_Params)(mc.params)
	// `.FIRST_APPLICATION_METHOD_ID` is a floor, not a method - 256, the first id an application may
	// use - and it is listed here only because the switch is exhaustive over the enum. The three real
	// methods beside it carry no parameter struct.
	case .DO_CLICK, .SET_CURRENT_GL_CONTEXT, .RELEASE_CURRENT_GL_CONTEXT, .FIRST_APPLICATION_METHOD_ID:
		return nil
	}
	return nil
}
