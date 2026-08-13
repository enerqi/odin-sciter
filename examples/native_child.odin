// The inverse of `integration.odin`: somebody else's native view **inside** a Sciter window.
//
//   just example native_child
//   odin test examples/native_child.odin -file
//
// [`integration.odin`](./integration.odin) puts a Sciter pane inside a window this repository owns.
// This goes the other way, which is the arrangement the SDK's `sciter-webview` needs and the answer to
// "can a Sciter application host a native control - a video surface, a GL viewport, an OS webview -
// inside its layout?"
//
// **On Linux, yes, and the reason is one measurement that is not in any header:**
//
//	window, _ := sciter_app.create_window({width = 900, height = 600})
//	xid := x11.Window(uintptr(rawptr(window)))          // <- HWINDOW *is* an X11 window id
//
// `sciter-x-types.h` types `HWINDOW` as an opaque `void*`, and `docs/architecture.md` reads it as one.
// It is not: on Linux the value is the engine's own X11 window, and `XGetWindowAttributes` on it
// succeeds. Measured on 6.0.4.9 - handle `0x2E00007`, attributes returned, `map_state` viewable. That
// makes a Sciter window an ordinary parent, so `XCreateSimpleWindow` with it as the parent works, and
// **the child stays mapped across the engine's own repaints** - Sciter draws with Skia into its own
// window and never touches the child's.
//
// What this file does with that: reserves a `<div>` in the document, asks the engine where that div
// ended up, and keeps a native X11 child window exactly on top of it - drawn here by hand, but it could
// be anything that takes a window id. The document scrolls and resizes; the child follows.
//
// The three rules that make it work, each with a test:
//
//   - **Ask the DOM where the box is, every frame.** `location(el, .Border, .View)` is in the same
//     coordinates as the window, which is what `XMoveResizeWindow` wants. Nothing tells the host when
//     layout moved, so the cheap version is to compare the rectangle each turn of the pump.
//   - **The child is above the document, always.** X11 stacking, not CSS: the native window is a
//     sibling of nothing in the DOM, so `z-index` cannot put an element over it and the placeholder
//     must be *reserved space* rather than decoration. This is exactly the limitation the SDK's own
//     webview behavior lives with.
//   - **`display:none` has no effect on it.** Hiding the placeholder leaves the child sitting there;
//     the host has to unmap it. `sync_child` below does that by treating a zero-area box as "hide".
//
// **What this is not: a webview.** Stage 5 of [`SDK-PARITY.md`](../docs/SDK-PARITY.md) asks for a
// `sciter-webview` equivalent, and the honest answer is that the *embedding* half is above and the
// *browser* half is not portable here. Upstream's own WebKitGTK backend
// (`sciter-webview/webview/sciter_webkitgtk.cpp`) has `set_parent_window() { return false; }` - it
// cannot reparent on Linux at all and opens a detached top-level window instead - and a GTK webview
// wants its own main loop besides. On Windows and macOS the same file would hand this window handle to
// WebView2 or WKWebView and the rest would follow.
package main

import "../sciter_app"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import x11 "vendor:x11/xlib"

W :: 820
H :: 560

DOC :: `<html>
<head><style>
  html, body { margin:0; padding:0; width:100%; height:100%; background:#1e1e2e; color:#cdd6f4;
               font:15px system; }
  h1     { color:#89b4fa; margin:0 0 6px 0; font-size:20px; }
  #page  { padding:20px; }
  /* Reserved space, not decoration: the native child sits on top of this, and nothing the document
     draws can appear above it. */
  #slot  { display:block; width:100%; height:240px; background:#313244; border:1px dashed #585b70; }
  #under { margin-top:14px; color:#a6adc8; }
  button { display:block; width:180px; height:32px; margin-top:12px; }
</style></head>
<body>
  <div id="page">
    <h1>a native window lives here</h1>
    <div id="slot"></div>
    <div id="under">the dashed box is the document's; the coloured square inside it is an X11 window
      this program owns, kept on the box by the host</div>
    <button id="toggle">hide / show it</button>
  </div>
</body>
</html>`

// The child window, and the rectangle it was last put at.
Native_Child :: struct {
	display: ^x11.Display,
	window:  x11.Window,
	gc:      x11.GC,
	at:      sciter_app.Rect,
	mapped:  bool,
	frame:   int,
}

// Creates the child inside `parent`, which is the Sciter window's own X11 window.
make_native_child :: proc(display: ^x11.Display, parent: x11.Window) -> (child: Native_Child) {
	screen := x11.DefaultScreen(display)
	child.display = display
	child.window = x11.CreateSimpleWindow(
		display,
		parent,
		0,
		0,
		1,
		1, // moved into place by the first `sync_child`
		0,
		x11.BlackPixel(display, screen),
		x11.BlackPixel(display, screen),
	)
	child.gc = x11.CreateGC(display, x11.Drawable(child.window), {}, nil)
	return
}

destroy_native_child :: proc(child: ^Native_Child) {
	if child.window != 0 {
		x11.DestroyWindow(child.display, child.window)
		child.window = 0
	}
}

// Puts the child on `box`, mapping or unmapping it as the box appears and disappears. Returns true when
// something actually changed, which is the signal to redraw it.
sync_child :: proc(child: ^Native_Child, box: sciter_app.Rect) -> bool {
	// A zero-area box is how a hidden placeholder arrives - `display:none` on the element does nothing
	// to a native window, so the host has to take it away.
	if box.width <= 0 || box.height <= 0 {
		if child.mapped {
			x11.UnmapWindow(child.display, child.window)
			child.mapped = false
			return true
		}
		return false
	}
	moved := box != child.at
	if moved {
		x11.MoveResizeWindow(child.display, child.window, box.x, box.y, u32(box.width), u32(box.height))
		child.at = box
	}
	if !child.mapped {
		x11.MapWindow(child.display, child.window)
		child.mapped = true
		moved = true
	}
	return moved
}

// The child's own content. Anything that takes a window id could be here instead - a video decoder, a
// GL context, a webview on a platform that has one.
draw_native_child :: proc(child: ^Native_Child) {
	if !child.mapped {
		return
	}
	width := int(child.at.width)
	height := int(child.at.height)

	// A moving bar, so it is obvious the child is live rather than a screenshot.
	x11.SetForeground(child.display, child.gc, 0x00181825)
	x11.FillRectangle(child.display, x11.Drawable(child.window), child.gc, 0, 0, u32(width), u32(height))

	x11.SetForeground(child.display, child.gc, 0x00a6e3a1)
	bar := (child.frame * 3) % max(width - 60, 1)
	x11.FillRectangle(child.display, x11.Drawable(child.window), child.gc, i32(bar), 20, 60, u32(max(height - 40, 1)))

	x11.SetForeground(child.display, child.gc, 0x00f38ba8)
	x11.DrawRectangle(child.display, x11.Drawable(child.window), child.gc, 0, 0, u32(width - 1), u32(height - 1))
	x11.Flush(child.display)
}

// Where the placeholder ended up, in the window's coordinates - the same space `XMoveResizeWindow`
// works in. A hidden element has no box, which comes back as a zero rectangle.
placeholder_box :: proc(root: sciter_app.Element, selector: string) -> sciter_app.Rect {
	element, err := sciter_app.select_first(root, selector)
	if err != nil {
		return {}
	}
	if visible, verr := sciter_app.visible(element); verr != nil || !visible {
		return {}
	}
	box, berr := sciter_app.location(element, .Border, .View)
	if berr != nil {
		return {}
	}
	return box
}

main :: proc() {
	if !sciter_app.load_engine() {
		os.exit(1)
	}
	sciter_app.set_default_debug_output()
	sciter_app.init()

	window, err := sciter_app.create_window({width = W, height = H})
	if err != nil {
		fmt.eprintln("could not create the window:", err)
		os.exit(1)
	}
	if err := sciter_app.load_html(window, DOC); err != nil {
		fmt.eprintln("could not load the document:", err)
		os.exit(1)
	}
	sciter_app.show(window)

	display := x11.OpenDisplay(nil)
	if display == nil {
		fmt.eprintln("no X display - this example is Linux/X11 only")
		os.exit(1)
	}

	// **The measurement this example rests on.** On Linux the engine's HWINDOW is its X11 window.
	parent := x11.Window(uintptr(rawptr(window)))
	attributes: x11.XWindowAttributes
	if x11.GetWindowAttributes(display, parent, &attributes) == 0 {
		fmt.eprintln("HWINDOW is not an X11 window on this build - nothing below will work")
		os.exit(1)
	}
	fmt.printfln("Sciter's window is X11 window 0x%x, %dx%d", uintptr(parent), attributes.width, attributes.height)

	child := make_native_child(display, parent)
	defer destroy_native_child(&child)

	// The document's button hides the placeholder; the host notices the box went away and unmaps.
	root, _ := sciter_app.root(window)
	if button, berr := sciter_app.select_first(root, "#toggle"); berr == nil {
		_, _ = sciter_app.eval(
			window,
			`document.$("#toggle").on("click", function(){
			   const slot = document.$("#slot");
			   slot.style.display = slot.style.display == "none" ? "block" : "none";
			 });`,
		)
		_ = button
	}

	// The loop: pump the engine, ask where the box is, keep the child on it, draw.
	for sciter_app.run_once() {
		child.frame += 1
		sync_child(&child, placeholder_box(root, "#slot"))
		draw_native_child(&child)
	}
	fmt.println("closed")
}

// ---------------------------------------------------------------------------------------------------
// Tests

@(private = "file")
have_display :: proc() -> bool {
	when ODIN_OS == .Windows || ODIN_OS == .Darwin {
		return true
	} else {
		return(
			os.get_env("DISPLAY", context.temp_allocator) != "" ||
			os.get_env("WAYLAND_DISPLAY", context.temp_allocator) != "" \
		)
	}
}

@(private = "file")
g_window: sciter_app.Window

@(private = "file")
test_window :: proc(t: ^testing.T) -> (window: sciter_app.Window, root: sciter_app.Element, ok: bool) {
	if !have_display() {
		fmt.println("no DISPLAY or WAYLAND_DISPLAY - skipping, this test needs a window")
		return nil, nil, false
	}
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}
	if g_window == nil {
		context.allocator = runtime.default_allocator()
		sciter_app.init()
		w, err := sciter_app.create_window({width = W, height = H})
		testing.expect_value(t, err, nil)
		if w == nil {
			return nil, nil, false
		}
		g_window = w
		sciter_app.show(w)
	}
	testing.expect_value(t, sciter_app.load_html(g_window, DOC), nil)
	for _ in 0 ..< 10 {
		sciter_app.run_once()
	}
	r, rerr := sciter_app.root(g_window)
	testing.expect_value(t, rerr, nil)
	return g_window, r, true
}

// The measurement everything here depends on, pinned: **`HWINDOW` is an X11 window id on Linux**, not
// an opaque handle. If a later engine changes that, this fails first and says so.
@(test)
test_the_engines_window_is_an_x11_window :: proc(t: ^testing.T) {
	window, _, ok := test_window(t)
	if !ok {return}

	display := x11.OpenDisplay(nil)
	testing.expect(t, display != nil, "an X display")
	if display == nil {return}
	defer x11.CloseDisplay(display)

	attributes: x11.XWindowAttributes
	status := x11.GetWindowAttributes(display, x11.Window(uintptr(rawptr(window))), &attributes)
	testing.expect(t, status != 0, "the HWINDOW value is a window this X server knows")
	testing.expect(t, attributes.width > 0 && attributes.height > 0, "and it has a size")
}

// The arrangement itself: a native child inside the engine's window, on the element's box, still there
// after the engine has repainted over the area.
@(test)
test_a_native_child_lives_inside_the_sciter_window :: proc(t: ^testing.T) {
	window, root, ok := test_window(t)
	if !ok {return}

	display := x11.OpenDisplay(nil)
	if display == nil {return}
	defer x11.CloseDisplay(display)

	child := make_native_child(display, x11.Window(uintptr(rawptr(window))))
	defer destroy_native_child(&child)

	box := placeholder_box(root, "#slot")
	testing.expect(t, box.width > 0 && box.height > 0, "the placeholder has a box")

	testing.expect(t, sync_child(&child, box), "the first sync maps and moves it")
	x11.Flush(display)
	for _ in 0 ..< 10 {
		sciter_app.run_once()
	}

	attributes: x11.XWindowAttributes
	testing.expect(t, x11.GetWindowAttributes(display, child.window, &attributes) != 0)
	testing.expect_value(t, attributes.width, box.width)
	testing.expect_value(t, attributes.height, box.height)
	testing.expect_value(t, attributes.x, box.x)
	testing.expect_value(t, attributes.y, box.y)
	testing.expect_value(t, attributes.map_state, x11.WindowMapState.IsViewable)

	// **The engine does not disturb it.** Sciter paints its own window; the child is a separate one.
	sciter_app.update_window(window)
	for _ in 0 ..< 20 {
		sciter_app.run_once()
	}
	after: x11.XWindowAttributes
	testing.expect(t, x11.GetWindowAttributes(display, child.window, &after) != 0)
	testing.expect_value(t, after.map_state, x11.WindowMapState.IsViewable)

	// Syncing to the same box again changes nothing, which is what makes the per-frame check cheap.
	testing.expect(t, !sync_child(&child, box), "an unchanged box is not a move")
}

// The rule with the sharp edge: **CSS cannot hide a native window.** The host has to notice the box
// went away, which is what a zero rectangle means here.
@(test)
test_hiding_the_placeholder_is_the_hosts_problem :: proc(t: ^testing.T) {
	window, root, ok := test_window(t)
	if !ok {return}

	display := x11.OpenDisplay(nil)
	if display == nil {return}
	defer x11.CloseDisplay(display)

	child := make_native_child(display, x11.Window(uintptr(rawptr(window))))
	defer destroy_native_child(&child)

	sync_child(&child, placeholder_box(root, "#slot"))
	testing.expect(t, child.mapped, "mapped to start with")

	// `display:none` on the element: the document's box goes away...
	_, err := sciter_app.eval(window, `document.$("#slot").style.display = "none"; true`)
	testing.expect_value(t, err, nil)
	for _ in 0 ..< 10 {
		sciter_app.run_once()
	}
	hidden := placeholder_box(root, "#slot")
	testing.expect_value(t, hidden.width, i32(0))

	// ...and the native window is still mapped until the host takes it away.
	attributes: x11.XWindowAttributes
	x11.GetWindowAttributes(display, child.window, &attributes)
	testing.expect_value(t, attributes.map_state, x11.WindowMapState.IsViewable)

	testing.expect(t, sync_child(&child, hidden), "the host unmaps it")
	x11.Flush(display)
	for _ in 0 ..< 10 {
		sciter_app.run_once()
	}
	after: x11.XWindowAttributes
	x11.GetWindowAttributes(display, child.window, &after)
	testing.expect_value(t, after.map_state, x11.WindowMapState.IsUnmapped)
	testing.expect(t, !child.mapped)
}

// And it follows the element rather than a fixed rectangle, which is the whole reason to ask the DOM
// every frame.
@(test)
test_the_child_follows_the_element :: proc(t: ^testing.T) {
	window, root, ok := test_window(t)
	if !ok {return}

	display := x11.OpenDisplay(nil)
	if display == nil {return}
	defer x11.CloseDisplay(display)

	child := make_native_child(display, x11.Window(uintptr(rawptr(window))))
	defer destroy_native_child(&child)

	before := placeholder_box(root, "#slot")
	sync_child(&child, before)

	// Push the placeholder down the page and make it shorter.
	_, err := sciter_app.eval(
		window,
		`document.$("#page").style.paddingTop = "120px"; document.$("#slot").style.height = "80px"; true`,
	)
	testing.expect_value(t, err, nil)
	for _ in 0 ..< 10 {
		sciter_app.run_once()
	}

	moved := placeholder_box(root, "#slot")
	testing.expect(t, moved.y > before.y, "the element moved down")
	testing.expect(t, moved.height < before.height, "and got shorter")

	testing.expect(t, sync_child(&child, moved), "the host follows it")
	x11.Flush(display)
	for _ in 0 ..< 10 {
		sciter_app.run_once()
	}

	attributes: x11.XWindowAttributes
	x11.GetWindowAttributes(display, child.window, &attributes)
	testing.expect_value(t, attributes.y, moved.y)
	testing.expect_value(t, attributes.height, moved.height)
}
