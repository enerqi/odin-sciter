// Geometry: where an element ended up, how big it wants to be, and what is scrolled where.
//
// Everything here reads the result of layout, so it only answers once layout has run. Straight after
// `load_html` the document is laid out and these are ready; straight after `set_html` on a subtree
// they may still describe the previous arrangement, and an element that is not in the document, or is
// `display: none`, has no box at all - `visible` is how to ask.
//
// One flag from the C API is deliberately not surfaced: ELEMENT_AREAS' `AS_PPX`, which asks for
// physical pixels. It returned identical rectangles on the display this was measured against, and
// there was no scaled display here to establish what it does otherwise, so rather than ship an
// argument nobody has checked, `sciter.api().SciterGetElementLocation` takes the raw flag word -
// `u32(box) | u32(origin) | 0x8000`.
package sciter_app

import sciter ".."

// A rectangle in pixels. The engine reports edges; this carries the corner and the size, which is what
// layout code asks for - `right`/`bottom` are `x + width` / `y + height`.
Rect :: struct {
	x, y:          i32, // the top-left corner, in whatever origin was asked for
	width, height: i32,
}

// Which box of the CSS box model to measure. The first four nest outwards in that order, so `.Border`
// is the visible extent of the element and `.Margin` includes the space reserved around it.
//
// `.Scrollable` is the odd one: it is documented as the scrollable area inside the content box, and
// measured against this engine it reports the same rectangle as the visible box rather than the full
// content. `scroll_info` is what answers "how much is there to scroll".
Box :: enum u32 {
	Content          = 0, // the inner box: no padding, no border
	Padding          = 0x10, // content + padding
	Border           = 0x20, // content + padding + border - the painted extent
	Margin           = 0x30, // content + padding + border + margin
	Background_Image = 0x40, // where a no-repeat background-image sits, relative to the content origin
	Foreground_Image = 0x50, // the same for foreground-image
	Scrollable       = 0x60, // see above
}

// What the coordinates are relative to.
//
// `.Root` and `.View` are both anchored outside the element - they differ by a fixed offset, where the
// root element sits inside the window - so scrolling an ancestor moves what they report, by the same
// amount. **Measured, that offset is zero on this engine**: every element tried answered identically
// for the two, `<html>` at (0,0) and elements inside a scrolled container included. So the two are
// interchangeable in practice on 6.0.4.9, and the reason to prefer one is which the call you are
// feeding documents - `element_at`, `send_mouse` and `show_popup_at` are all specified against the
// window, which is `.View`.
//
// `.Container` is measured from the container's own content origin and does not move when that
// container scrolls; that one genuinely differs, as does `.Self`.
//
// `.Self` is how to ask for a size and ignore a position: the content box comes back at (0, 0), and an
// outer box comes back with negative x and y, which is how to read a padding or border width.
Origin :: enum u32 {
	Root      = 1, // the document's root element - or the nearest windowed container, e.g. a popup
	Self      = 2, // the element's own content origin
	Container = 3, // inside the immediate container
	View      = 4, // the window's client area
}

// Where `element` is, and how big.
//
//	box, err := sciter_app.location(button)                    // the painted extent, in the document
//	box, err := sciter_app.location(button, .Border, .View)    // the same, relative to the window
//	box, err := sciter_app.location(button, .Border, .Self)    // just the size: x and y are the insets
//
// `box` and `origin` are separate fields of one flag word in the C API, which is why they are two
// arguments here rather than one enum with every combination in it.
//
// An element with no box - one that is `display: none`, or not in the document - does not fail and
// does not report zero: it keeps answering with the last rectangle it had. `visible` is the question
// to ask; a rectangle is never the way to find out whether an element is there.
location :: proc(element: Element, box := Box.Border, origin := Origin.Root) -> (rect: Rect, err: Error) {
	r: sciter.Rect
	dom_err(sciter.api().SciterGetElementLocation(sciter.Helement(element), &r, u32(box) | u32(origin))) or_return
	return Rect{x = r.left, y = r.top, width = r.right - r.left, height = r.bottom - r.top}, nil
}

// Whether the element has a box at all. False for an element outside the document and for one hidden
// by `display: none`; true for one hidden by `visibility: hidden`, which still takes up space.
visible :: proc(element: Element) -> (visible: bool, err: Error) {
	flag: b32
	dom_err(sciter.api().SciterIsElementVisible(sciter.Helement(element), &flag)) or_return
	return bool(flag), nil
}

// Whether the element is enabled - neither `:disabled` itself nor inside a disabled container.
enabled :: proc(element: Element) -> (enabled: bool, err: Error) {
	flag: b32
	dom_err(sciter.api().SciterIsElementEnabled(sciter.Helement(element), &flag)) or_return
	return bool(flag), nil
}

// ---------------------------------------------------------------------------------------------------
// Intrinsic sizes
//
// What the content wants, before the layout it is actually given. This is the measurement a container
// needs in order to decide how much room to hand out - the same numbers CSS calls `min-content` and
// `max-content`.

// The narrowest and widest the element's content can be: `min` is where it can no longer be wrapped
// any further, `max` is what it takes laid out on one line.
intrinsic_widths :: proc(element: Element) -> (min, max: i32, err: Error) {
	dom_err(sciter.api().SciterGetElementIntrinsicWidths(sciter.Helement(element), &min, &max)) or_return
	return min, max, nil
}

// How tall the element's content becomes if it is given exactly `for_width` pixels. Asking at a width
// between the two `intrinsic_widths` is the point: that is where the answer is not obvious.
intrinsic_height :: proc(element: Element, for_width: i32) -> (height: i32, err: Error) {
	dom_err(sciter.api().SciterGetElementIntrinsicHeight(sciter.Helement(element), for_width, &height)) or_return
	return height, nil
}

// ---------------------------------------------------------------------------------------------------
// Window metrics
//
// The two questions a window has about itself: what a pixel is worth here, and how small it is allowed
// to get.

// The window's resolution, in dots per inch, horizontally and vertically. 96 is the unscaled desktop
// value and the one every CSS pixel in the document is defined against, so `dpi / 96` is the scale
// factor to multiply a hand-computed pixel size by.
//
// Everything else in this package - `location`, `Rect`, `show_popup_at`, `element_at` - is already in
// the engine's scaled pixels ("ppx"), so this is only needed when talking to something that is not:
// a bitmap to be drawn at the right size, a platform API, a saved window geometry.
ppi :: proc(window: Window) -> (dpi: [2]u32) {
	x, y: u32
	sciter.api().SciterGetPPI(rawptr(window), &x, &y)
	return {x, y}
}

// The narrowest the window's content can be, and the height it needs at a given width - the engine's
// `SciterGetMinWidth` / `SciterGetMinHeight`, the pair a resizable window's minimum size is meant to
// come from.
//
// **Measured, and it is the whole story about these two: they report the *root element's* intrinsic
// size, not the document's.** They come back exactly equal to `intrinsic_widths(root).min` and
// `intrinsic_height(root, …)` on every document tried. Because `<html>` fills the view by default, its
// min-content width is a small constant - 16px against this engine - however wide the content inside
// it is, so on an ordinary document `min_width` answers 16 for a 600px-wide child and for an empty
// body alike. It only becomes the content's width when the root is sized by its content:
//
//	html, body { width: max-content; height: max-content }   // now min_width is the real thing
//
// with which a 500x250 child measured 516 and 296.
//
// Two more measured details. `min_height` **ignores its `width` argument** - the same number comes
// back for 100, 400 and 800 - so it is a single number rather than the height-for-width curve the
// signature suggests. And both are only meaningful once the document has been laid out; read straight
// after `load_html`, before the pump has turned, they can be off by a factor of a hundred.
//
// For "how big does this document want to be", `intrinsic_widths` and `intrinsic_height` on the
// element that actually holds the content - usually `<body>` - are the calls that answer.
min_width :: proc(window: Window) -> i32 {
	return i32(sciter.api().SciterGetMinWidth(rawptr(window)))
}

// See `min_width`. `for_width` is accepted because the C API takes it, and is ignored by this engine.
min_height :: proc(window: Window, for_width: i32) -> i32 {
	return i32(sciter.api().SciterGetMinHeight(rawptr(window), u32(for_width)))
}

// ---------------------------------------------------------------------------------------------------
// Scrolling

// Where a scrollable element is scrolled to, and how much there is to scroll.
Scroll_Info :: struct {
	pos:     [2]i32, // the current offset, from the top-left of the content
	view:    Rect, // the visible window onto the content, in the element's own coordinates
	content: [2]i32, // the full content size; anything larger than `view` is what scrolls
}

// Reads all three at once, because that is what the engine returns and they are only meaningful
// together: `pos` alone says nothing without `content - view` to compare it against.
//
// An element that does not scroll answers with a zero `pos` and a `content` no larger than `view`.
scroll_info :: proc(element: Element) -> (info: Scroll_Info, err: Error) {
	pos: sciter.Point
	view: sciter.Rect
	content: sciter.Size
	dom_err(sciter.api().SciterGetScrollInfo(sciter.Helement(element), &pos, &view, &content)) or_return

	return Scroll_Info {
			pos = {pos.x, pos.y},
			view = {x = view.left, y = view.top, width = view.right - view.left, height = view.bottom - view.top},
			content = {content.cx, content.cy},
		},
		nil
}

// Scrolls `element`'s content to `pos`. Out-of-range values are clamped by the engine rather than
// refused. `smooth` animates rather than jumping, and returns before the animation has finished.
set_scroll_pos :: proc(element: Element, pos: [2]i32, smooth := false) -> Error {
	return dom_err(sciter.api().SciterSetScrollPos(sciter.Helement(element), {pos.x, pos.y}, b32(smooth)))
}

// Scrolls whatever contains `element` until `element` is in view. This is the one to reach for after
// adding a row to a list or moving a selection with the keyboard.
//
// `to_top` puts the element at the top of the view instead of scrolling the shortest distance that
// makes it visible. `smooth` animates, and returns before the animation has finished.
//
// Two things measured against this engine, both of which look like the call being ignored:
//
//   - nothing moves until the window has been shown and rendered at least once. Before that the call
//     succeeds and the scroll position does not change. `set_scroll_pos` has no such requirement.
//   - without `to_top` the scroll is applied on the engine's own schedule, so reading the position
//     straight back can still show the old one. With `to_top` it has landed by the time this returns.
scroll_to_view :: proc(element: Element, to_top := false, smooth := false) -> Error {
	flags: sciter.Sciter_Scroll_Flags
	if to_top {
		flags += {.TO_TOP}
	}
	if smooth {
		flags += {.SMOOTH}
	}
	return dom_err(sciter.api().SciterScrollToView(sciter.Helement(element), flags))
}
