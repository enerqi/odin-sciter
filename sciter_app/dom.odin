// The DOM: finding elements, reading and writing them, and building new ones.
//
// An element handle is a borrowed pointer into the engine's document tree. It stays valid as long as
// the element is in the document, which for anything reached from `root` during an event handler or
// straight after a load is the whole time you are looking at it. To hold one for longer - across the
// message pump, in a struct that outlives the callback - take a reference with `use_element` and give
// it back with `unuse_element`, or the handle turns into a dangling pointer the moment script removes
// the element.
//
// The exception is an element you made rather than found: `make_element` and `clone_element` hand back
// a reference that is already yours, and it stays yours after the element is inserted. See "Building
// and moving elements" below.
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
// Building and moving elements
//
// `set_html` replaces a subtree with markup and is the right tool most of the time. This is the other
// way: build the element, fill it in, and put it where it goes - which is what you want when the
// content comes from data rather than from a template, and the only way to *move* an element rather
// than re-create it.
//
// One rule, and it is the C API's rather than this package's: **`make_element` and `clone_element`
// hand back an element with a reference already taken, and that reference is yours.** Inserting it
// does not consume it - the document takes its own. So the shape is always
//
//	item := sciter_app.make_element("li", "third") or_return
//	defer sciter_app.unuse_element(item)          // yours either way, inserted or not
//	sciter_app.insert_element(item, list) or_return
//
// and an element that is created and never unused leaks inside the engine, where Odin's allocator
// tracking cannot see it.

// A new element, disconnected from any document. `text` is plain text and is not parsed - markup in it
// is text, not elements.
//
// The returned element carries a reference that belongs to the caller: `unuse_element` it once it has
// been inserted, or to throw it away.
make_element :: proc(tag: string, text := "") -> (element: Element, err: Error) {
	he: sciter.Helement

	w: [^]u16
	if text != "" {
		w = raw_data(utf16_from_string(text, context.temp_allocator))
	}

	dom_err(sciter.api().SciterCreateElement(to_cstring(tag, context.temp_allocator), w, &he)) or_return
	if he == nil {
		return nil, .Not_Found
	}
	return Element(he), nil
}

// A deep copy of `element`, disconnected from any document: children, attributes and all. Same
// ownership as `make_element` - the copy carries a reference that is yours.
clone_element :: proc(element: Element) -> (copy: Element, err: Error) {
	he: sciter.Helement
	dom_err(sciter.api().SciterCloneElement(sciter.Helement(element), &he)) or_return
	if he == nil {
		return nil, .Not_Found
	}
	return Element(he), nil
}

// Puts `element` into `parent` at `index`. The default appends: an index past the end is not an error,
// it lands at the end.
//
// Inserting an element that already has a parent is a **move** - the engine disconnects it first.
// Nothing else is needed to move an element around, and re-creating it would lose its state and its
// attached behaviors.
insert_element :: proc(element: Element, parent: Element, index := -1) -> Error {
	// The index is clamped to the child count rather than handed over as given. The C API documents an
	// index past the end as an append, and a moderate one behaves that way - but a very large one
	// (`max(u32)`, the obvious spelling of "at the end") segfaults inside the engine rather than
	// appending, so the count is what gets passed.
	n := child_count(parent) or_return
	at := n if index < 0 || index > n else index

	return dom_err(sciter.api().SciterInsertElement(sciter.Helement(element), sciter.Helement(parent), u32(at)))
}

// Takes `element` out of its document. The same `finalize` flag, with the same meaning, as
// `node_remove`.
//
// `finalize = true` destroys it, behaviors and all, and the handle is dead when this returns.
//
// `finalize = false` detaches it and **hands the caller a reference**, exactly like `make_element`:
// unuse it once it has been inserted somewhere else, or to throw it away. That reference is taken here
// rather than left to the caller because the C API does not take one - a bare `SciterDetachElement`
// drops the last reference to an element nobody else is holding, and the next use of the handle is a
// segfault rather than an error code.
remove_element :: proc(element: Element, finalize := true) -> Error {
	if finalize {
		return dom_err(sciter.api().SciterDeleteElement(sciter.Helement(element)))
	}

	// Before, not after: after the detach there may be nothing left to take a reference to.
	use_element(element) or_return
	if err := dom_err(sciter.api().SciterDetachElement(sciter.Helement(element))); err != nil {
		unuse_element(element)
		return err
	}
	return nil
}

// Exchanges the positions of two elements - both their indexes and their parents, so this moves them
// between containers as readily as within one.
swap_elements :: proc(a, b: Element) -> Error {
	return dom_err(sciter.api().SciterSwapElements(sciter.Helement(a), sciter.Helement(b)))
}

// Orders `element`'s children in place. Return a negative number, zero or a positive one, as with
// every other comparator.
Element_Comparator :: proc(a, b: Element, user_data: rawptr) -> int

// Sorts the children in `[first, last)` - `last` is one past the end, and the default sorts all of
// them. The comparator runs on this thread, with this context, before `sort_children` returns.
sort_children :: proc(
	element: Element,
	cmp: Element_Comparator,
	user_data: rawptr = nil,
	first := 0,
	last := -1,
) -> Error {
	if cmp == nil {
		return sciter.Scdom_Result.INVALID_PARAMETER
	}

	stop := last
	if stop < 0 {
		stop = child_count(element) or_return
	}
	if first >= stop {
		return nil // nothing to order, which is not a failure
	}

	sink := Sort_Sink {
		ctx       = context,
		cmp       = cmp,
		user_data = user_data,
	}
	return dom_err(
		sciter.api().SciterSortElements(sciter.Helement(element), u32(first), u32(stop), sort_callback, &sink),
	)
}

// ---------------------------------------------------------------------------------------------------
// Identity
//
// A UID is a plain integer that survives being stored somewhere a handle cannot go - a script value, a
// map key, a message to another part of the program. It is only meaningful for as long as the element
// is in its document, and only within the window it came from.

element_uid :: proc(element: Element) -> (uid: u32, err: Error) {
	dom_err(sciter.api().SciterGetElementUID(sciter.Helement(element), &uid)) or_return
	return uid, nil
}

// The element a UID refers to. Returns `.Not_Found` for a UID this window does not know.
element_by_uid :: proc(window: Window, uid: u32) -> (element: Element, err: Error) {
	he: sciter.Helement
	dom_err(sciter.api().SciterGetElementByUID(rawptr(window), uid, &he)) or_return
	if he == nil {
		return nil, .Not_Found
	}
	return Element(he), nil
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

@(private)
Sort_Sink :: struct {
	ctx:       runtime.Context,
	cmp:       Element_Comparator,
	user_data: rawptr,
}

@(private)
sort_callback :: proc "system" (he1: sciter.Helement, he2: sciter.Helement, param: rawptr) -> i32 {
	sink := (^Sort_Sink)(param)
	context = sink.ctx
	return i32(sink.cmp(Element(he1), Element(he2), sink.user_data))
}
