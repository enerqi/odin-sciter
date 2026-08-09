// The DOM: finding elements, and reading and writing them.
//
// An element handle is a borrowed pointer into the engine's document tree. It stays valid as long as
// the element is in the document, which for anything reached from `root` during an event handler or
// straight after a load is the whole time you are looking at it. To hold one for longer - across the
// message pump, in a struct that outlives the callback - take a reference with `use_element` and give
// it back with `unuse_element`, or the handle turns into a dangling pointer the moment script removes
// the element.
package sciter_app

import sciter ".."
import "base:runtime"
import "core:mem"

// A DOM element. Sciter's HELEMENT.
Element :: distinct sciter.Helement

// A DOM node - text and comments, the things that are not elements.
Node :: distinct sciter.Hnode

// Marks the element as in use, so the engine will not free it while the handle is held. Pair with
// `unuse_element`. Not needed for a handle you use and drop inside one callback.
use_element :: proc(element: Element) -> Error {
	return dom_err(sciter.api().Sciter_UseElement(sciter.Helement(element)))
}

unuse_element :: proc(element: Element) -> Error {
	return dom_err(sciter.api().Sciter_UnuseElement(sciter.Helement(element)))
}

// ---------------------------------------------------------------------------------------------------
// Finding elements

// The first element matching a CSS selector, searched within `element`'s subtree.
//
//	button, err := sciter_app.select_first(root, "button#ok")
//
// Returns `.Not_Found` if nothing matches. The selector is the same dialect the document's CSS uses.
select_first :: proc(element: Element, selector: string) -> (found: Element, err: Error) {
	sink := First_Sink {
		ctx = context,
	}
	w := utf16_from_string(selector, context.temp_allocator)

	dom_err(sciter.api().SciterSelectElementsW(sciter.Helement(element), raw_data(w), first_callback, &sink)) or_return

	if sink.found == nil {
		return nil, .Not_Found
	}
	return sink.found, nil
}

// Every element matching a CSS selector, in document order. The slice is the caller's to `delete`; the
// handles in it are borrowed and are not `use_element`d.
select_all :: proc(
	element: Element,
	selector: string,
	allocator := context.allocator,
) -> (
	found: []Element,
	err: Error,
) {
	sink := All_Sink {
		ctx = context,
		out = make([dynamic]Element, allocator),
	}
	w := utf16_from_string(selector, context.temp_allocator)

	if e := dom_err(sciter.api().SciterSelectElementsW(sciter.Helement(element), raw_data(w), all_callback, &sink));
	   e != nil {
		delete(sink.out)
		return nil, e
	}
	return sink.out[:], nil
}

// ---------------------------------------------------------------------------------------------------
// Traversal

child_count :: proc(element: Element) -> (n: int, err: Error) {
	count: u32
	dom_err(sciter.api().SciterGetChildrenCount(sciter.Helement(element), &count)) or_return
	return int(count), nil
}

child :: proc(element: Element, n: int) -> (child: Element, err: Error) {
	he: sciter.Helement
	dom_err(sciter.api().SciterGetNthChild(sciter.Helement(element), u32(n), &he)) or_return
	if he == nil {
		return nil, .Not_Found
	}
	return Element(he), nil
}

// The parent element, or `.Not_Found` at the root.
parent :: proc(element: Element) -> (parent: Element, err: Error) {
	he: sciter.Helement
	dom_err(sciter.api().SciterGetParentElement(sciter.Helement(element), &he)) or_return
	if he == nil {
		return nil, .Not_Found
	}
	return Element(he), nil
}

// The element's tag name - "div", "button". Borrowed from the engine, valid for the element's lifetime.
tag :: proc(element: Element) -> (tag: string, err: Error) {
	p: cstring
	dom_err(sciter.api().SciterGetElementType(sciter.Helement(element), &p)) or_return
	return string(p), nil
}

// ---------------------------------------------------------------------------------------------------
// Text, HTML and attributes

// The element's text content, allocated in `allocator`.
text :: proc(element: Element, allocator := context.allocator) -> (text: string, err: Error) {
	sink := String_Sink {
		ctx       = context,
		allocator = allocator,
	}
	dom_err(sciter.api().SciterGetElementTextCB(sciter.Helement(element), wide_receiver, &sink)) or_return
	return sink.out, nil
}

set_text :: proc(element: Element, text: string) -> Error {
	w := utf16_from_string(text, context.temp_allocator)
	return dom_err(sciter.api().SciterSetElementText(sciter.Helement(element), raw_data(w), u32(len(w) - 1)))
}

// The element's HTML, allocated in `allocator`. `outer` includes the element's own tag.
html :: proc(element: Element, outer := false, allocator := context.allocator) -> (html: string, err: Error) {
	sink := String_Sink {
		ctx       = context,
		allocator = allocator,
	}
	dom_err(sciter.api().SciterGetElementHtmlCB(sciter.Helement(element), b32(outer), bytes_receiver, &sink)) or_return
	return sink.out, nil
}

// Replaces or adds HTML. `.SIH_REPLACE_CONTENT` (the default) replaces the element's children;
// `.SOH_REPLACE` replaces the element itself.
set_html :: proc(element: Element, html: string, where_ := sciter.Set_Element_Html.SIH_REPLACE_CONTENT) -> Error {
	return dom_err(sciter.api().SciterSetElementHtml(sciter.Helement(element), raw_data(html), u32(len(html)), where_))
}

// An attribute's value, allocated in `allocator`. An absent attribute reads as "".
attribute :: proc(element: Element, name: string, allocator := context.allocator) -> (value: string, err: Error) {
	sink := String_Sink {
		ctx       = context,
		allocator = allocator,
	}
	dom_err(
		sciter.api().SciterGetAttributeByNameCB(
			sciter.Helement(element),
			to_cstring(name, context.temp_allocator),
			wide_receiver,
			&sink,
		),
	) or_return
	return sink.out, nil
}

// Sets an attribute. Pass "" to remove it.
set_attribute :: proc(element: Element, name: string, value: string) -> Error {
	w: [^]u16
	if value != "" {
		w = raw_data(utf16_from_string(value, context.temp_allocator))
	}
	return dom_err(
		sciter.api().SciterSetAttributeByName(sciter.Helement(element), to_cstring(name, context.temp_allocator), w),
	)
}

// ---------------------------------------------------------------------------------------------------
// State and value

// The element's :hover / :focus / :checked / ... bits.
element_state :: proc(element: Element) -> (state: sciter.Element_State_Bits, err: Error) {
	dom_err(sciter.api().SciterGetElementState(sciter.Helement(element), &state)) or_return
	return state, nil
}

set_element_state :: proc(
	element: Element,
	set: sciter.Element_State_Bits,
	clear := sciter.Element_State_Bits{},
	update_view := true,
) -> Error {
	return dom_err(sciter.api().SciterSetElementState(sciter.Helement(element), set, clear, b32(update_view)))
}

// The element's value, as script's `element.value` sees it: the text of an <input>, the selection of a
// <select>, the checked state of a checkbox. The result owns a reference; `value_clear` it.
element_value :: proc(element: Element) -> (value: Value, err: Error) {
	dom_err(sciter.api().SciterGetValue(sciter.Helement(element), &value)) or_return
	return value, nil
}

// Sets the element's value. `value` is not consumed.
set_element_value :: proc(element: Element, value: ^Value) -> Error {
	return dom_err(sciter.api().SciterSetValue(sciter.Helement(element), value))
}

// ---------------------------------------------------------------------------------------------------
// Script, scoped to an element

// Runs a script with `this` bound to the element. The result owns a reference; `value_clear` it.
eval_element :: proc(element: Element, script: string) -> (result: Value, err: Error) {
	w := utf16_from_string(script, context.temp_allocator)
	dom_err(
		sciter.api().SciterEvalElementScript(sciter.Helement(element), raw_data(w), u32(len(w) - 1), &result),
	) or_return
	return result, nil
}

// Calls a method on the element's script object. The result owns a reference; `value_clear` it.
call_method :: proc(element: Element, method: string, args: ..Value) -> (result: Value, err: Error) {
	argv: ^sciter.Value
	if len(args) > 0 {
		argv = &args[0]
	}
	dom_err(
		sciter.api().SciterCallScriptingMethod(
			sciter.Helement(element),
			to_cstring(method, context.temp_allocator),
			argv,
			u32(len(args)),
			&result,
		),
	) or_return
	return result, nil
}

// ---------------------------------------------------------------------------------------------------
// Callback plumbing
//
// The engine calls these back as `proc "system"`, which means Odin's implicit `context` is not set up.
// Every one of them therefore carries the calling context across in its param struct and restores it
// before touching anything that allocates.

@(private)
String_Sink :: struct {
	ctx:       runtime.Context,
	allocator: mem.Allocator,
	out:       string,
}

@(private)
wide_receiver :: proc "system" (str: [^]u16, str_length: u32, param: rawptr) {
	sink := (^String_Sink)(param)
	context = sink.ctx
	sink.out = string_from_utf16(str, uint(str_length), sink.allocator)
}

@(private)
bytes_receiver :: proc "system" (bytes: [^]u8, num_bytes: u32, param: rawptr) {
	sink := (^String_Sink)(param)
	context = sink.ctx
	if bytes == nil || num_bytes == 0 {
		sink.out = ""
		return
	}
	// The engine hands HTML back as UTF-8 already.
	buf := make([]u8, num_bytes, sink.allocator)
	copy(buf, bytes[:num_bytes])
	sink.out = string(buf)
}

@(private)
First_Sink :: struct {
	ctx:   runtime.Context,
	found: Element,
}

// Returning TRUE stops the enumeration, which is what makes this "first".
@(private)
first_callback :: proc "system" (he: sciter.Helement, param: rawptr) -> b32 {
	sink := (^First_Sink)(param)
	context = sink.ctx
	sink.found = Element(he)
	return true
}

@(private)
All_Sink :: struct {
	ctx: runtime.Context,
	out: [dynamic]Element,
}

@(private)
all_callback :: proc "system" (he: sciter.Helement, param: rawptr) -> b32 {
	sink := (^All_Sink)(param)
	context = sink.ctx
	append(&sink.out, Element(he))
	return false // keep going
}
