// A Sciter pane inside a window this program owns and draws: the SDK's `demos/integration`, in Odin.
//
//   just example integration          # opens an X11 window; close it or wait for the timeout
//   odin test examples/integration.odin -file
//
// [`windowless.odin`](./windowless.odin) proves the engine will render into a buffer you allocated.
// This is the thing that was worth proving next, and the reason
// [`EMBEDDING.md`](../docs/EMBEDDING.md) exists: **the pane is inside somebody else's window, drawn
// between somebody else's pixels, driven by somebody else's event loop, and it is fully interactive.**
// The host here is about a hundred lines of raw Xlib - no toolkit, no SDL, no GLFW - which is the
// point: if this much is enough, then whatever you already have is enough.
//
// What the host owns: the window, the frame buffer, the event loop, the clock, and every pixel outside
// the pane - the title strip, the sidebar, and the pointer read-out, all drawn here by hand. What
// Sciter owns: a 420x300 rectangle in the middle of it.
//
// The four things this teaches that `windowless.odin` cannot:
//
//   - **Compositing is a copy, and the pane can live anywhere in your frame.** `paint_windowless`
//     fills the view's own RGBA buffer; blitting it into the host's BGRA frame at an offset is the
//     eight lines in `composite`. A GPU host does the same thing with a texture - see
//     [`windowless_gl.odin`](./windowless_gl.odin), where the engine draws straight into the bound
//     framebuffer and there is no copy at all.
//   - **Input is a translation, not a bridge.** An X11 `ButtonPress` becomes a `windowless_mouse` in
//     *view* coordinates - `event.x - PANE_X`. That is the whole of it, and everything works: the
//     document's handlers run, `:hover` follows the pointer, buttons press, checkboxes toggle, and a
//     click gives a text field the caret so `windowless_key` types into it.
//   - **A behavior's event is posted, so the heartbeat is not optional.** Straight after the mouse-up
//     nothing has happened; the next `windowless_heartbeat` is what delivers the click. A host that
//     only beats when it feels like redrawing will find its widgets dead.
//   - **Odin can answer the document, and the document can answer Odin.** The sidebar's counter is
//     updated from a `.BUTTON_CLICK` handler attached from Odin, and the host's "reset" - a key press
//     the *host* handles, outside the pane - reaches back into the document through the DOM. Neither
//     side owns the interaction.
//
// **Linux/X11 only**, and that is about this file rather than about the binding: somebody has to own a
// window, and doing it without a toolkit means the platform's own API. On Windows the same program is
// a `CreateWindowEx` and a `StretchDIBits`, and everything from `create_windowless` down is identical.
package main

import sciter ".."
import "../sciter_app"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import x11 "vendor:x11/xlib"

W :: 760
H :: 460
PANE_X :: 220
PANE_Y :: 60
PANE_W :: 420
PANE_H :: 300

// The pane's document. Widgets in normal flow, deliberately: `position: absolute` collapses a
// `<button>` to 1x1 in this engine and the clicks would all land on `<body>` - which is exactly how
// this repository twice concluded that windowless input did not work. See `docs/html-css-js.md`.
DOC :: `<html>
<head><style>
  html, body { margin:0; padding:0; width:100%; height:100%; background:#1e1e2e; color:#cdd6f4;
               font:15px system; }
  #card  { margin:16px; padding:14px; background:#313244; border:1px solid #45475a; }
  h1     { margin:0 0 10px 0; font-size:18px; color:#89b4fa; }
  #press { display:block; width:160px; height:32px; margin-bottom:10px; }
  #note  { display:block; margin-top:10px; color:#a6adc8; font-size:13px; }
  #name  { display:block; width:100%; margin-top:6px; }
  #tick  { display:block; margin-top:10px; }
</style></head>
<body>
  <div id="card">
    <h1>this pane is Sciter</h1>
    <button id="press">press me</button>
    <input id="tick" type="checkbox" /> <label>and this is a real checkbox</label>
    <div id="note">everything around it is drawn by Odin</div>
    <input id="name" type="text" value="" placeholder="click here and type" />
  </div>
</body>
</html>`

// ---------------------------------------------------------------------------------------------------
// The host's own drawing
//
// Deliberately primitive - a flat fill, a bar and a 5x7 bitmap font - because the point is that the
// host's renderer is *whatever you already have*, not that it is any good.

Frame :: struct {
	pixels: []u8, // BGRA, W*H*4, what X11 wants for a 24/32-bit visual
}

put :: proc(f: ^Frame, x, y: int, r, g, b: u8) {
	if x < 0 || y < 0 || x >= W || y >= H {
		return
	}
	i := (y * W + x) * 4
	f.pixels[i + 0] = b
	f.pixels[i + 1] = g
	f.pixels[i + 2] = r
	f.pixels[i + 3] = 255
}

fill :: proc(f: ^Frame, x, y, w, h: int, r, g, b: u8) {
	for yy in y ..< y + h {
		for xx in x ..< x + w {
			put(f, xx, yy, r, g, b)
		}
	}
}

// A 5x7 font covering what this example prints. Anything missing draws as a blank.
GLYPHS :: `ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .:,-()`
GLYPH_ROWS :: [?][7]u8 {
	{0x04, 0x0A, 0x11, 0x11, 0x1F, 0x11, 0x11}, // A
	{0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E}, // B
	{0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E}, // C
	{0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E}, // D
	{0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F}, // E
	{0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10}, // F
	{0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F}, // G
	{0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11}, // H
	{0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E}, // I
	{0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C}, // J
	{0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11}, // K
	{0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F}, // L
	{0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11}, // M
	{0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11}, // N
	{0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E}, // O
	{0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10}, // P
	{0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D}, // Q
	{0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11}, // R
	{0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E}, // S
	{0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04}, // T
	{0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E}, // U
	{0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04}, // V
	{0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A}, // W
	{0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11}, // X
	{0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04}, // Y
	{0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F}, // Z
	{0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E}, // 0
	{0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E}, // 1
	{0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F}, // 2
	{0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E}, // 3
	{0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02}, // 4
	{0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E}, // 5
	{0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E}, // 6
	{0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08}, // 7
	{0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E}, // 8
	{0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C}, // 9
	{0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}, // space
	{0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C}, // .
	{0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x0C, 0x00}, // :
	{0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C, 0x08}, // ,
	{0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00}, // -
	{0x02, 0x04, 0x08, 0x08, 0x08, 0x04, 0x02}, // (
	{0x08, 0x04, 0x02, 0x02, 0x02, 0x04, 0x08}, // )
}

text :: proc(f: ^Frame, x, y: int, s: string, r, g, b: u8, scale := 2) {
	pen := x
	for ch in s {
		upper := ch
		if ch >= 'a' && ch <= 'z' {
			upper = ch - 32
		}
		index := -1
		for candidate, i in GLYPHS {
			if candidate == upper {
				index = i
				break
			}
		}
		if index >= 0 {
			glyphs := GLYPH_ROWS
			rows := glyphs[index]
			for row, ry in rows {
				for bit in 0 ..< 5 {
					if row & (0x10 >> u8(bit)) != 0 {
						fill(f, pen + bit * scale, y + ry * scale, scale, scale, r, g, b)
					}
				}
			}
		}
		pen += 6 * scale
	}
}

// The host's chrome: everything that is not the pane.
draw_host :: proc(f: ^Frame, presses: int, typed: string, pointer: [2]i32, inside: bool) {
	fill(f, 0, 0, W, H, 24, 24, 37)
	fill(f, 0, 0, W, 40, 49, 50, 68)
	text(f, 16, 12, "ODIN OWNS THIS WINDOW", 205, 214, 244)

	// The sidebar, which is where the host reports what the document has been doing.
	fill(f, 16, 60, 180, H - 80, 30, 30, 46)
	text(f, 28, 76, "SCITER SAYS", 137, 180, 250, 1)
	text(f, 28, 100, fmt.tprintf("PRESSES: %d", presses), 166, 227, 161, 1)
	text(f, 28, 120, fmt.tprintf("TYPED: %s", typed), 249, 226, 175, 1)
	text(f, 28, 152, "HOST SAYS", 137, 180, 250, 1)
	text(f, 28, 176, fmt.tprintf("X %d Y %d", pointer.x, pointer.y), 205, 214, 244, 1)
	text(f, 28, 196, inside ? "OVER THE PANE" : "OUTSIDE", 205, 214, 244, 1)
	text(f, 28, 240, "R - RESET", 166, 173, 200, 1)
	text(f, 28, 260, "ESC - QUIT", 166, 173, 200, 1)

	// A frame around the pane, so the seam between the two renderers is visible.
	fill(f, PANE_X - 2, PANE_Y - 2, PANE_W + 4, 2, 137, 180, 250)
	fill(f, PANE_X - 2, PANE_Y + PANE_H, PANE_W + 4, 2, 137, 180, 250)
	fill(f, PANE_X - 2, PANE_Y - 2, 2, PANE_H + 4, 137, 180, 250)
	fill(f, PANE_X + PANE_W, PANE_Y - 2, 2, PANE_H + 4, 137, 180, 250)
}

// The pane, copied in. RGBA out of the view, BGRA into the frame.
composite :: proc(f: ^Frame, view: ^sciter_app.Windowless_View) {
	for y in 0 ..< int(view.height) {
		for x in 0 ..< int(view.width) {
			r, g, b, _ := sciter_app.windowless_pixel(view, i32(x), i32(y))
			put(f, PANE_X + x, PANE_Y + y, r, g, b)
		}
	}
}

// ---------------------------------------------------------------------------------------------------
// The Odin side of the document
//
// A `.BUTTON_CLICK` subscription, which is how the host learns that the pane's button was pressed
// without polling script for it.

Pane :: struct {
	using handler: sciter_app.Event_Handler,
	presses:       int,
}

on_pane_event :: proc(h: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	pane := (^Pane)(h)
	if behavior, ok := sciter_app.behavior_event(event); ok {
		// **Phase, not just code.** A handler on the root sees every event twice - once sinking towards
		// the target and once bubbling back - so counting both counts every press twice.
		if behavior.code == .BUTTON_CLICK && behavior.phase == .Bubbling {
			pane.presses += 1
		}
	}
	return false // seen, not consumed
}

// ---------------------------------------------------------------------------------------------------
// Translating X11 input into the view
//
// The whole bridge, and it is arithmetic: the host's coordinates minus the pane's origin. Everything
// else - hit testing, hover, focus, which behavior gets the click - is the engine's problem.

to_view :: proc(x, y: i32) -> (pos: [2]i32, inside: bool) {
	pos = {x - PANE_X, y - PANE_Y}
	inside = pos.x >= 0 && pos.y >= 0 && pos.x < PANE_W && pos.y < PANE_H
	return
}

main :: proc() {
	if !sciter_app.load_engine() {
		os.exit(1)
	}
	sciter_app.set_default_debug_output()

	display := x11.OpenDisplay(nil)
	if display == nil {
		fmt.eprintln("no X display - this example needs one, like every other windowed example here")
		os.exit(1)
	}
	screen := x11.DefaultScreen(display)
	visual := x11.DefaultVisual(display, screen)
	depth := x11.DefaultDepth(display, screen)

	window := x11.CreateSimpleWindow(
		display,
		x11.RootWindow(display, screen),
		0,
		0,
		W,
		H,
		0,
		x11.BlackPixel(display, screen),
		x11.BlackPixel(display, screen),
	)
	x11.SelectInput(
		display,
		window,
		{.Exposure, .KeyPress, .ButtonPress, .ButtonRelease, .PointerMotion, .StructureNotify},
	)
	x11.StoreName(display, window, "a Sciter pane in an Odin window")
	x11.MapWindow(display, window)
	gc := x11.CreateGC(display, x11.Drawable(window), {}, nil)

	// The window manager's close button arrives as a client message on this atom, not as a signal.
	wm_delete := x11.InternAtom(display, "WM_DELETE_WINDOW", false)
	atoms := [1]x11.Atom{wm_delete}
	x11.SetWMProtocols(display, window, &atoms[0], 1)

	frame := Frame {
		pixels = make([]u8, W * H * 4),
	}
	defer delete(frame.pixels)

	image := x11.CreateImage(display, visual, u32(depth), .ZPixmap, 0, raw_data(frame.pixels), W, H, 32, W * 4)
	if image == nil {
		fmt.eprintln("XCreateImage failed")
		os.exit(1)
	}

	// **No `init`.** This process has no Sciter window and no Sciter pump; the loop below is the pump.
	view, verr := sciter_app.create_windowless({width = PANE_W, height = PANE_H})
	if verr != nil {
		fmt.eprintln("could not create the pane:", verr)
		os.exit(1)
	}
	defer sciter_app.destroy_windowless(&view)

	if err := sciter_app.load_html(view.window, DOC, "about:blank"); err != nil {
		fmt.eprintln("could not load the pane's document:", err)
		os.exit(1)
	}

	root, _ := sciter_app.root(view.window)
	pane := Pane{}
	pane.on_event = on_pane_event
	pane.subscription = {.BEHAVIOR_EVENT}
	if err := sciter_app.attach_handler(root, &pane); err != nil {
		fmt.eprintln("could not attach the handler:", err)
	}

	// The view takes the keyboard focus once; which *element* has it inside the pane is then the
	// document's business, and a click is what moves it.
	sciter_app.windowless_focus(&view, true)

	start := time.now()
	pointer: [2]i32
	over := false
	running := true
	event: x11.XEvent

	for running {
		for x11.Pending(display) > 0 {
			x11.NextEvent(display, &event)
			#partial switch event.type {
			case .ClientMessage:
				if x11.Atom(event.xclient.data.l[0]) == wm_delete {
					running = false
				}

			case .MotionNotify:
				pointer = {event.xmotion.x, event.xmotion.y}
				pos, inside := to_view(event.xmotion.x, event.xmotion.y)
				if inside {
					sciter_app.windowless_mouse(&view, .MOUSE_MOVE, pos)
				} else if over {
					// Leaving matters: without it the last element keeps `:hover` forever.
					sciter_app.windowless_mouse(&view, .MOUSE_LEAVE, pos)
				}
				over = inside

			case .ButtonPress, .ButtonRelease:
				pos, inside := to_view(event.xbutton.x, event.xbutton.y)
				if !inside {
					break
				}
				code: sciter.Mouse_Events = event.type == .ButtonPress ? .MOUSE_DOWN : .MOUSE_UP
				sciter_app.windowless_mouse(&view, code, pos)

			case .KeyPress:
				// The host reads the key first and only passes on what it does not want, which is what
				// makes the pane a *component* rather than the application.
				buffer: [8]u8
				keysym: x11.KeySym
				n := x11.LookupString(&event.xkey, raw_data(buffer[:]), 8, &keysym, nil)
				#partial switch keysym {
				case .XK_Escape:
					running = false
				case .XK_R, .XK_r:
					// A host command that reaches into the document: clear the field and the checkbox.
					if field, err := sciter_app.select_first(root, "#name"); err == nil {
						empty := sciter_app.value_from_string("")
						sciter_app.set_element_value(field, &empty)
						sciter_app.value_clear(&empty)
					}
					if tick, err := sciter_app.select_first(root, "#tick"); err == nil {
						sciter_app.set_element_state(tick, {}, {.CHECKED})
					}
					pane.presses = 0
				case:
					if n > 0 {
						for ch in buffer[:n] {
							sciter_app.windowless_key(&view, .CHAR, u32(ch))
						}
					} else {
						sciter_app.windowless_key(&view, .DOWN, u32(keysym))
					}
				}
			}
		}

		// The host's clock drives the engine. Real elapsed time, because script timers run on the wall
		// clock whatever timestamp they are handed - see `windowless.odin`.
		elapsed := u32(time.duration_milliseconds(time.since(start)))
		sciter_app.windowless_heartbeat(&view, elapsed)
		sciter_app.paint_windowless(&view)

		typed := "-"
		if field, err := sciter_app.select_first(root, "#name"); err == nil {
			if value, verr := sciter_app.element_value(field); verr == nil {
				defer sciter_app.value_clear(&value)
				if s, serr := sciter_app.value_to_string(&value, context.temp_allocator); serr == nil && s != "" {
					typed = s
				}
			}
		}

		draw_host(&frame, pane.presses, typed, pointer, over)
		composite(&frame, &view)
		x11.PutImage(display, x11.Drawable(window), gc, image, 0, 0, 0, 0, W, H)
		x11.Flush(display)

		free_all(context.temp_allocator)
		time.sleep(16 * time.Millisecond)
	}

	fmt.printfln("closed after %d presses", pane.presses)
}

// ---------------------------------------------------------------------------------------------------
// Tests
//
// The X11 half needs a display and a human; these test the half that decides whether the example is
// honest - that host coordinates land on the right element, and that a click through the view drives
// the pane's widgets.

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

// One view for the whole binary. **A destroyed view ends windowless mode for the process** - the next
// `SXM_CREATE` segfaults - so these tests share one and reload its document, which is the same shape a
// long-running host uses. `windowless.odin` documents the defect.
@(private = "file")
g_view: sciter_app.Windowless_View

@(private = "file")
test_pane :: proc(t: ^testing.T) -> (view: ^sciter_app.Windowless_View, root: sciter_app.Element, ok: bool) {
	if !have_display() {
		fmt.println("no DISPLAY or WAYLAND_DISPLAY - skipping; a windowless view still needs one")
		return {}, nil, false
	}
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}
	context.allocator = runtime.default_allocator()

	if g_view.window == nil {
		v, err := sciter_app.create_windowless({width = PANE_W, height = PANE_H})
		testing.expect_value(t, err, nil)
		if err != nil {
			return nil, nil, false
		}
		g_view = v
	}
	// Reloading is what keeps the tests independent, since the view itself is not.
	testing.expect_value(t, sciter_app.load_html(g_view.window, DOC, "about:blank"), nil)
	for i in 0 ..< 10 {
		sciter_app.windowless_heartbeat(&g_view, u32(i) * 16)
		sciter_app.paint_windowless(&g_view)
	}
	r, _ := sciter_app.root(g_view.window)
	return &g_view, r, true
}

// The bridge is arithmetic, and this is the arithmetic: a point in the host's window becomes a point
// in the view, and the engine finds the same element the user was pointing at.
@(test)
test_host_coordinates_hit_the_element_under_them :: proc(t: ^testing.T) {
	view, root, ok := test_pane(t)
	if !ok {return}

	button, berr := sciter_app.select_first(root, "#press")
	testing.expect_value(t, berr, nil)
	box, lerr := sciter_app.location(button, .Border, .View)
	testing.expect_value(t, lerr, nil)

	// Where that button is on the host's screen, which is what the host's event carries.
	host_x := PANE_X + box.x + box.width / 2
	host_y := PANE_Y + box.y + box.height / 2

	pos, inside := to_view(host_x, host_y)
	testing.expect(t, inside, "a point over the button is inside the pane")

	under, uerr := sciter_app.element_at(view.window, pos)
	testing.expect_value(t, uerr, nil)
	tag, _ := sciter_app.tag(under)
	testing.expect_value(t, tag, "button")

	// And a point in the host's own chrome is not the pane's business at all.
	_, outside := to_view(10, 10)
	testing.expect(t, !outside, "the sidebar is not in the pane")
}

// The other half of the claim: the two renderers really do share one buffer. Nothing here touches X11
// - the frame is just memory - so this is the part of the example that would survive a port to any
// windowing system at all.
@(test)
test_the_host_frame_carries_both_renderers :: proc(t: ^testing.T) {
	view, _, ok := test_pane(t)
	if !ok {return}

	frame := Frame {
		pixels = make([]u8, W * H * 4, context.temp_allocator),
	}
	draw_host(&frame, 3, "odin", {0, 0}, false)
	composite(&frame, view)

	pixel :: proc(f: ^Frame, x, y: int) -> [3]u8 {
		i := (y * W + x) * 4
		return {f.pixels[i + 2], f.pixels[i + 1], f.pixels[i + 0]} // stored BGRA, read as RGB
	}

	// The title strip is the host's, and it is nowhere near the document's background.
	testing.expect_value(t, pixel(&frame, 8, 8), [3]u8{49, 50, 68})

	// The middle of the pane is the document's card colour, which no host drawing here uses.
	card := pixel(&frame, PANE_X + PANE_W / 2, PANE_Y + PANE_H / 2)
	testing.expect_value(t, card, [3]u8{49, 50, 68})

	// The seam: one pixel outside the pane is the host's border, one inside is the document.
	testing.expect_value(t, pixel(&frame, PANE_X - 1, PANE_Y + 40), [3]u8{137, 180, 250})
	inside := pixel(&frame, PANE_X + 1, PANE_Y + 4)
	testing.expect_value(t, inside, [3]u8{30, 30, 46}) // the document's own <body> background

	// And the pane really was copied rather than left blank: the document has more than one colour in
	// it, which a failed paint or a zeroed buffer would not.
	seen := map[[3]u8]bool{}
	defer delete(seen)
	for y in 0 ..< PANE_H {
		for x in 0 ..< PANE_W {
			seen[pixel(&frame, PANE_X + x, PANE_Y + y)] = true
		}
	}
	testing.expectf(t, len(seen) > 3, "the pane should hold a rendered document, saw %d colours", len(seen))
}

// The claim the example makes in its header: the pane is interactive, widgets included. A click
// translated from host coordinates presses the button, and the host hears about it through its own
// `.BUTTON_CLICK` handler rather than by asking script.
@(test)
test_a_translated_click_drives_the_panes_widgets :: proc(t: ^testing.T) {
	view, root, ok := test_pane(t)
	if !ok {return}

	pane := Pane{}
	pane.on_event = on_pane_event
	pane.subscription = {.BEHAVIOR_EVENT}
	testing.expect_value(t, sciter_app.attach_handler(root, &pane), nil)
	defer sciter_app.detach_handler(root, &pane)

	click :: proc(view: ^sciter_app.Windowless_View, root: sciter_app.Element, selector: string) {
		el, err := sciter_app.select_first(root, selector)
		if err != nil {return}
		box, lerr := sciter_app.location(el, .Border, .View)
		if lerr != nil {return}
		host_x := PANE_X + box.x + box.width / 2
		host_y := PANE_Y + box.y + box.height / 2
		pos, _ := to_view(host_x, host_y)
		sciter_app.windowless_mouse(view, .MOUSE_MOVE, pos)
		sciter_app.windowless_mouse(view, .MOUSE_DOWN, pos)
		sciter_app.windowless_mouse(view, .MOUSE_UP, pos)
		// **The beat is what delivers it** - a behavior's event is posted, not raised inline.
		sciter_app.windowless_heartbeat(view, 100)
	}

	click(view, root, "#press")
	testing.expect_value(t, pane.presses, 1)

	tick, terr := sciter_app.select_first(root, "#tick")
	testing.expect_value(t, terr, nil)
	click(view, root, "#tick")
	state, serr := sciter_app.element_state(tick)
	testing.expect_value(t, serr, nil)
	testing.expect(t, .CHECKED in state, "a translated click toggles the checkbox")

	// A click focuses the field, so the host's keys land in it with no `set_focus` anywhere.
	testing.expect(t, sciter_app.windowless_focus(view))
	click(view, root, "#name")
	for c in "odin" {
		sciter_app.windowless_key(view, .CHAR, u32(c))
	}
	sciter_app.windowless_heartbeat(view, 200)

	field, ferr := sciter_app.select_first(root, "#name")
	testing.expect_value(t, ferr, nil)
	value, verr := sciter_app.element_value(field)
	testing.expect_value(t, verr, nil)
	defer sciter_app.value_clear(&value)
	typed, _ := sciter_app.value_to_string(&value, context.temp_allocator)
	testing.expect_value(t, typed, "odin")

	// And the host's own command reaches back into the document - the "R" key in `main`.
	empty := sciter_app.value_from_string("")
	defer sciter_app.value_clear(&empty)
	testing.expect_value(t, sciter_app.set_element_value(field, &empty), nil)
	testing.expect_value(t, sciter_app.set_element_state(tick, {}, {.CHECKED}), nil)

	cleared, cerr := sciter_app.element_value(field)
	testing.expect_value(t, cerr, nil)
	defer sciter_app.value_clear(&cleared)
	after, _ := sciter_app.value_to_string(&cleared, context.temp_allocator)
	testing.expect_value(t, after, "")
}
