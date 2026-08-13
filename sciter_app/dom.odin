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

// The nearest **ancestor or self** matching a CSS selector - script's `element.closest(selector)`.
//
//	row, err := sciter_app.select_parent(clicked, "tr")
//
// `select_first` searches downwards, which is the wrong direction for the commonest question an event
// handler has: given the thing that was clicked, which row/panel/form is it in.
//
// `depth` limits how far up to look, and it counts the element itself as the first level: the default
// 0 is unlimited, 1 searches only `element`, 2 searches `element` and its parent, and so on. Returns
// `.Not_Found` when nothing matches.
//
// One measured limitation: **`<html>` never matches**, from any element and at any depth. Use
// `root(window)` for the document element rather than a `"html"` selector here.
select_parent :: proc(element: Element, selector: string, depth := 0) -> (found: Element, err: Error) {
	w := utf16_from_string(selector, context.temp_allocator)
	he: sciter.Helement
	dom_err(sciter.api().SciterSelectParentW(sciter.Helement(element), raw_data(w), u32(depth), &he)) or_return
	if he == nil {
		return nil, .Not_Found
	}
	return Element(he), nil
}

// The topmost element at a point in the window - hit testing, the question a mouse asks.
//
//	el, err := sciter_app.element_at(window, {x, y})
//
// `pos` is in the window's client area, which is the space `location(el, .Border, .View)` reports and
// the space `show_popup_at` takes - so a context menu at the pointer is these two calls back to back.
// A point outside the document is `.Not_Found` rather than an error, and so is a negative one.
//
// "Topmost" is what a click would reach: the innermost element painted at that point, with `z-index`
// and popups respected. Note that Sciter 6 draws its own titlebar as part of the document, so a point
// near the top of the window can legitimately answer `<window-caption>`.
//
// A window that has never been shown still hit-tests, as long as its document has been laid out.
element_at :: proc(window: Window, pos: [2]i32) -> (element: Element, err: Error) {
	he: sciter.Helement
	dom_err(sciter.api().SciterFindElement(rawptr(window), {x = pos.x, y = pos.y}, &he)) or_return
	if he == nil {
		return nil, .Not_Found
	}
	return Element(he), nil
}

// ---------------------------------------------------------------------------------------------------
// Traversal

// A position among an element's **element** children. The node view counts text and comment nodes as
// well, so the same `<ul>` has two element children and five node children - see `Node_Index`, which is
// `distinct` from this one precisely so the two numberings cannot be swapped by accident. Converting
// between them means walking, not casting.
//
// It is an ordinary integer otherwise: `for i in 0 ..< child_count(el)` infers the type, `n - 1` and
// `i > 0` work, and only mixing one with an unrelated `int` needs a cast.
Child_Index :: distinct int

child_count :: proc(element: Element) -> (n: Child_Index, err: Error) {
	count: u32
	dom_err(sciter.api().SciterGetChildrenCount(sciter.Helement(element), &count)) or_return
	return Child_Index(count), nil
}

child :: proc(element: Element, n: Child_Index) -> (child: Element, err: Error) {
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

// The element's position among its parent's children, counting **elements only** - a text node before
// it does not shift the index. That is the same numbering `child` and `insert_element` use, so it is
// the number to hand back to either of them.
element_index :: proc(element: Element) -> (index: Child_Index, err: Error) {
	n: u32
	dom_err(sciter.api().SciterGetElementIndex(sciter.Helement(element), &n)) or_return
	return Child_Index(n), nil
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

// An attribute as `attributes` reports it. Both strings are allocated in the allocator that call was
// given, and `delete_attributes` frees them.
Attribute :: struct {
	name:  string,
	value: string,
}

// How many attributes the element carries. This counts what is *written on the element* - the ones
// `attributes` will report - not everything the cascade gave it.
attribute_count :: proc(element: Element) -> (n: int, err: Error) {
	count: u32
	dom_err(sciter.api().SciterGetAttributeCount(sciter.Helement(element), &count)) or_return
	return int(count), nil
}

// The nth attribute, in the order it appears in the markup. Both strings are allocated in `allocator`.
// An index past the end is `.INVALID_PARAMETER` rather than an empty result.
attribute_at :: proc(element: Element, n: int, allocator := context.allocator) -> (attribute: Attribute, err: Error) {
	// The name comes back as UTF-8 and the value as UTF-16 - two different receivers, which is why
	// this is two calls rather than one.
	name_sink := String_Sink {
		ctx       = context,
		allocator = allocator,
	}
	dom_err(
		sciter.api().SciterGetNthAttributeNameCB(sciter.Helement(element), u32(n), bytes_receiver, &name_sink),
	) or_return

	value_sink := String_Sink {
		ctx       = context,
		allocator = allocator,
	}
	if e := dom_err(
		sciter.api().SciterGetNthAttributeValueCB(sciter.Helement(element), u32(n), wide_receiver, &value_sink),
	); e != nil {
		delete(name_sink.out, allocator)
		return {}, e
	}
	return {name = name_sink.out, value = value_sink.out}, nil
}

// Every attribute on the element, in markup order. The slice and both strings in each entry come from
// `allocator`; `delete_attributes` gives them all back.
//
//	attrs, _ := sciter_app.attributes(el, context.temp_allocator)
//	for a in attrs {
//		fmt.printfln("%s = %q", a.name, a.value)
//	}
//
// This is the way to discover what is on an element - `attribute` answers only for a name you already
// know, and an absent attribute and an empty one read the same through it.
attributes :: proc(element: Element, allocator := context.allocator) -> (found: []Attribute, err: Error) {
	n := attribute_count(element) or_return
	if n == 0 {
		return nil, nil
	}

	out := make([]Attribute, n, allocator)
	for i in 0 ..< n {
		attribute, e := attribute_at(element, i, allocator)
		if e != nil {
			// Not `delete_attributes(out[:i])`: that would free the slice too, and `out` is one
			// allocation - the second `delete` would be freeing it again.
			for done in out[:i] {
				delete(done.name, allocator)
				delete(done.value, allocator)
			}
			delete(out, allocator)
			return nil, e
		}
		out[i] = attribute
	}
	return out, nil
}

// Frees what `attributes` allocated.
delete_attributes :: proc(attributes: []Attribute, allocator := context.allocator) {
	for a in attributes {
		delete(a.name, allocator)
		delete(a.value, allocator)
	}
	delete(attributes, allocator)
}

// Removes every attribute from the element in one call, `class` and `id` included.
//
// The rules that were matching on those stop matching, but not until the cascade next runs, and this
// call does not make it run: `style` keeps reporting the old answer until something else does. See the
// note under "Style" below.
clear_attributes :: proc(element: Element) -> Error {
	return dom_err(sciter.api().SciterClearAttributes(sciter.Helement(element)))
}

// ---------------------------------------------------------------------------------------------------
// Style
//
// Inline style - what script reaches through `element.style` and what the `style` attribute holds in
// markup. Two things about it are not obvious and are worth having in mind before either call:
//
//   - **reading gives you the used value, not the inline one.** `style(el, "color")` on an element
//     coloured only by a stylesheet answers with the stylesheet's colour, resolved: `#FF0000`, not
//     `red` and not `""`. A property nothing set reads as `""`.
//   - **writing does not touch the `style` attribute.** After `set_style(el, "color", "blue")`,
//     `attribute(el, "style")` is still whatever it was, usually `""`. The two are separate stores;
//     `set_attribute(el, "style", …)` is the other way in, and it replaces the lot.
//
// And a third, which is a reading hazard rather than a rule: that used value is *stored*, so it is
// only as fresh as the last time the cascade ran. Writing an attribute re-runs it; `clear_attributes`
// does not, and the old colour keeps being reported until something forces the update -
// `sciter.api().SciterUpdateElement(he, true)` being the direct way.

// A style property's used value - a colour as `#RRGGBB`, a length in the unit the engine resolved it
// to. `""` for a property with no value, including one this build does not know.
style :: proc(element: Element, name: string, allocator := context.allocator) -> (value: string, err: Error) {
	sink := String_Sink {
		ctx       = context,
		allocator = allocator,
	}
	dom_err(
		sciter.api().SciterGetStyleAttributeCB(
			sciter.Helement(element),
			to_cstring(name, context.temp_allocator),
			wide_receiver,
			&sink,
		),
	) or_return
	return sink.out, nil
}

// Sets one inline style property, as script's `el.style.setProperty(name, value)` would. Pass `""` to
// drop it, after which the property goes back to whatever the stylesheets say.
//
// The engine does not report an unknown property or an unparseable value - both come back OK and do
// nothing - so a rule that fails to apply is a matter for the inspector rather than for the error.
set_style :: proc(element: Element, name: string, value: string) -> Error {
	w: [^]u16
	if value != "" {
		w = raw_data(utf16_from_string(value, context.temp_allocator))
	}
	return dom_err(
		sciter.api().SciterSetStyleAttribute(sciter.Helement(element), to_cstring(name, context.temp_allocator), w),
	)
}

// ---------------------------------------------------------------------------------------------------
// Popups
//
// A popup is an element of the document shown *out of flow*, in a window of its own that is allowed to
// extend past the main window's edge - a menu, a dropdown, a tooltip. The element is an ordinary part
// of the document the rest of the time, usually hidden by CSS, and it stays where it is in the tree:
// showing it does not move it.
//
//	menu, _ := sciter_app.select_first(root, "#context-menu")
//	sciter_app.show_popup(menu, button, .Bottom)
//	...
//	sciter_app.hide_popup(menu)
//
// The declarative route is `context-menu: selector(#menu)` in CSS, which needs no Odin at all. This is
// for the cases where what to show, or where, is decided in code.
//
// **A popup wants a shown window.** On a window that has never been shown the calls report success and
// the element takes the popup state, but the engine does not finish the job: the anchor never gets its
// `.OWNS_POPUP` state and `hide_popup` does not clear the popup's `.POPUP` state. Everything below is
// written for a real, visible window.

// Where a popup goes, named the way a numeric keypad is laid out - which is exactly how the C API
// numbers it. The two calls read it differently:
//
//   - `show_popup` names the side of the *anchor* the popup goes on: `.Bottom` is below it, `.Top`
//     above, `.Left` and `.Right` beside it.
//   - `show_popup_at` names the corner of the *popup* that lands on the given point: `.Top_Left` puts
//     the point at its top-left, which is the usual "here is where the mouse is" placement.
Popup_Placement :: enum u32 {
	Bottom_Left  = 1,
	Bottom       = 2,
	Bottom_Right = 3,
	Left         = 4,
	Center       = 5,
	Right        = 6,
	Top_Left     = 7,
	Top          = 8,
	Top_Right    = 9,
}

// Shows `popup` as a popup positioned against `anchor`.
//
// Both elements have to be in a document: a detached element is `.PASSIVE_HANDLE`, not an error about
// the popup.
show_popup :: proc(popup: Element, anchor: Element, placement := Popup_Placement.Bottom) -> Error {
	return dom_err(sciter.api().SciterShowPopup(sciter.Helement(popup), sciter.Helement(anchor), u32(placement)))
}

// Shows `popup` at a point in the window's coordinates - the ones `location(el, .Border, .Root)`
// reports. A mouse event's `pos` is relative to the element it was delivered to, so showing a menu
// where the pointer is means adding that element's `.Root` origin to it.
show_popup_at :: proc(popup: Element, pos: [2]i32, placement := Popup_Placement.Top_Left) -> Error {
	return dom_err(sciter.api().SciterShowPopupAt(sciter.Helement(popup), {x = pos.x, y = pos.y}, u32(placement)))
}

// Hides a popup. Takes the popup element itself, or one inside it - **not** the anchor it was shown
// against, which reports `.OK_NOT_HANDLED` and leaves the popup where it is.
//
// Hiding one that is not shown is not an error.
hide_popup :: proc(popup: Element) -> Error {
	return dom_err(sciter.api().SciterHidePopup(sciter.Helement(popup)))
}

// ---------------------------------------------------------------------------------------------------
// Redrawing
//
// The engine keeps its own idea of what is dirty, and everything that goes through this package -
// `set_text`, `set_attribute`, `set_html` - marks it. These are for the cases where it cannot know:
// after `clear_attributes`, which leaves the resolved style stale (see "Style" above), and after
// painting into an element from a `.DRAW` handler, where the pixels changed and the DOM did not.

// Re-runs style and layout for the element. `render = true` also repaints it there and then rather
// than at the next frame, which is what makes it the way to force the cascade to re-resolve.
update_element :: proc(element: Element, render := false) -> Error {
	return dom_err(sciter.api().SciterUpdateElement(sciter.Helement(element), b32(render)))
}

// Marks a rectangle *inside* the element as needing a repaint - `area` is in the element's own
// coordinates, the ones `location(el, .Border, .Self)` reports. Neither style nor layout is re-run.
refresh_element_area :: proc(element: Element, area: Rect) -> Error {
	r := sciter.Rect {
		left   = area.x,
		top    = area.y,
		right  = area.x + area.width,
		bottom = area.y + area.height,
	}
	return dom_err(sciter.api().SciterRefreshElementArea(sciter.Helement(element), r))
}

// Asks for the whole element to be repainted at the next frame. The cheapest of the three: no style,
// no layout, no synchronous draw.
request_paint :: proc(element: Element) -> Error {
	return dom_err(sciter.api().SciterRequestPaint(sciter.Helement(element)))
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
insert_element :: proc(element: Element, parent: Element, index := Child_Index(-1)) -> Error {
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
	first := Child_Index(0),
	last := Child_Index(-1),
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

// An element's identity within one window. `distinct` for the same reason `Atom` is: it is an opaque
// token the engine hands out and takes back, never a count, an index or a length, and the two calls
// below are the only things that should ever produce or consume one.
Element_Uid :: distinct u32

element_uid :: proc(element: Element) -> (uid: Element_Uid, err: Error) {
	raw: u32
	dom_err(sciter.api().SciterGetElementUID(sciter.Helement(element), &raw)) or_return
	return Element_Uid(raw), nil
}

// The element a UID refers to. Returns `.Not_Found` for a UID this window does not know.
element_by_uid :: proc(window: Window, uid: Element_Uid) -> (element: Element, err: Error) {
	he: sciter.Helement
	dom_err(sciter.api().SciterGetElementByUID(rawptr(window), u32(uid), &he)) or_return
	if he == nil {
		return nil, .Not_Found
	}
	return Element(he), nil
}

// ---------------------------------------------------------------------------------------------------
// URLs

// Resolves `url` against the base of the document `element` is in - the engine's own resolution, the
// same one that turns `<img src="logo.png">` into something it can fetch.
//
//	full, _ := sciter_app.combine_url(el, "images/logo.png", context.temp_allocator)
//	// -> "file:///home/me/app/assets/images/logo.png"
//
// This is what a host callback needs when it has a relative reference and has to answer for it, and
// what an application needs before handing a URL to anything outside the engine. Measured against a
// document loaded with a base URL: a relative path resolves against it, `..` walks up, a leading `/`
// becomes root-relative, and an already-absolute URL with a scheme is returned unchanged. An empty
// string answers with the base itself.
//
// The result is allocated in `allocator`. A detached element is `.INVALID_HANDLE`, since the base
// comes from the document.
combine_url :: proc(element: Element, url: string, allocator := context.allocator) -> (full: string, err: Error) {
	// The C API resolves in place, in a buffer the caller sizes, and **truncates silently** rather than
	// reporting that it did not fit - a four-unit buffer came back OK holding "fil". So the buffer is
	// sized here from the input plus generous room for a base, rather than left to the caller.
	size := utf16_len(url) + 1024
	buf := make([]u16, size, context.temp_allocator)
	w := utf16_from_string(url, context.temp_allocator)
	copy(buf, w)

	dom_err(sciter.api().SciterCombineURL(sciter.Helement(element), raw_data(buf), u32(size))) or_return
	return string_from_utf16_cstring(raw_data(buf), allocator), nil
}

// ---------------------------------------------------------------------------------------------------
// Elements as Values
//
// This is the crossing between the DOM and script's data model, and it goes both ways: an element put
// in a Value is an `Element` to JavaScript - `instanceof Element` is true, `.tag`, `.id`, `.style` and
// the rest all work - and an element script handed *you*, as a functor argument or a call's result,
// comes back out as a handle.
//
//	// script calling into Odin: fn(document.$("#row"), 3)
//	on_click :: proc(args: []sciter_app.Value, user_data: rawptr) -> sciter_app.Value {
//		el, err := sciter_app.element_from_value(&args[0])
//		...
//	}
//
// Without this an element cannot be an argument or a return value, and the only way to name one across
// the boundary is its UID (see "Identity" above) or a selector that finds it again.
//
// **The Value holds its own reference to the element.** An element stays alive for as long as a Value
// wraps it, even after the `use_element` reference the caller had is given back - measured, not
// assumed. The handle from `element_from_value` is borrowed on the same terms as every other handle
// here: fine for the length of the call, and `use_element` if it has to outlive the Value.

// Wraps an element so script can be handed it. The Value owns a reference and is cleared like any
// other; it reports its type as `.RESOURCE` and renders as `""`, so `value_to_display_string` is no
// use for looking at one.
element_to_value :: proc(element: Element) -> (v: Value, err: Error) {
	// Declared as returning UINT rather than SCDOM_RESULT, but the codes are that enum's - a wrap of a
	// null handle or an unwrap of the wrong type answers .OPERATION_FAILED.
	dom_err(sciter.Scdom_Result(sciter.api().SciterElementWrap(&v, sciter.Helement(element)))) or_return
	return v, nil
}

// The element inside a Value, from script or from `element_to_value`. `.OPERATION_FAILED` if the Value
// holds anything else - a number, a string, or a text node.
element_from_value :: proc(v: ^Value) -> (element: Element, err: Error) {
	he: sciter.Helement
	dom_err(sciter.Scdom_Result(sciter.api().SciterElementUnwrap(v, &he))) or_return
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

// The element's script object, as a Value - what script reaches through `document.$(sel)` and hangs
// its own properties on.
//
//	expando, err := sciter_app.expando(el)
//	defer sciter_app.value_clear(&expando)
//	n, _ := sciter_app.value_get(&expando, "rowIndex")     // read what script put there
//	sciter_app.value_set(&expando, "rowIndex", &value)     // and write it back
//
// This is the general form of the crossing that `call_method` and `eval_element` do one call at a
// time: with the object in hand, every `value_get` in `value.odin` applies, and reading is reliable
// in both directions - a string or a number script put on the element comes back intact, and so does
// one written from here.
//
// **Writing has one measured hole, and it is a sharp one: `value_set` of a *string* does not
// survive.** The call reports success, and the property then reads back as garbage from Odin and from
// script alike; a later `value_clear` of an unrelated Value has been seen to abort the process.
// `value_isolate` before the set does not help. Numbers and booleans are fine - `i32`, `f64` and
// `bool` all round-trip and are visible to script immediately. For a string, go through script, which
// is one line and correct:
//
//	sciter_app.eval_element(el, `this.note = "hello"`)   // instead of value_set(&expando, "note", &s)
//
// This is the same family as the rule in `set_global`: a Value handed to an engine-owned object is not
// always copied the way the header implies, and strings are where it shows.
//
// The C API's `forceCreation` flag is not surfaced: an element that has never been touched by script
// answers with an object either way, so there is nothing for it to choose. A **detached** element is
// `.INVALID_HANDLE` - the object belongs to the document.
//
// The result owns a reference; `value_clear` it.
expando :: proc(element: Element) -> (value: Value, err: Error) {
	dom_err(sciter.api().SciterGetExpando(sciter.Helement(element), &value, true)) or_return
	return value, nil
}

// Calls a *function* from the element's scope - one the document defined, reached with the element as
// the starting point rather than the window.
//
// The difference from `call_method` is which name is looked up: `call_method` wants a method **on the
// element**, and `call_function` finds a function visible from it, `globalThis`'s included. Measured:
// a plain `function` in the document answers here and is `.OPERATION_FAILED` through `call_method`.
//
// The result owns a reference; `value_clear` it. The arguments do not.
call_function :: proc(element: Element, function: string, args: ..Value) -> (result: Value, err: Error) {
	argv: ^sciter.Value
	if len(args) > 0 {
		argv = &args[0]
	}
	dom_err(
		sciter.api().SciterCallScriptingFunction(
			sciter.Helement(element),
			to_cstring(function, context.temp_allocator),
			argv,
			u32(len(args)),
			&result,
		),
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
