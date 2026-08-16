// Sciter with no window at all: the engine draws into a buffer you own.
//
//   just example windowless          # renders three documents and writes target/windowless-*.ppm
//   odin test examples/windowless.odin -file
//
// There is no window, no message pump, and nothing for a desktop to be involved in: the engine is a
// renderer you call, and the pixels are yours.
//
// **It still needs a display on Linux, which is the one thing everything about this mode suggests it
// should not.** Measured on 6.0.4.9: with `DISPLAY` and `WAYLAND_DISPLAY` both unset, the very first
// call - `SXM_CREATE`, before any document, any surface or any paint - segfaults. So "windowless" means
// "no window of its own", not "no windowing system"; the engine still stands enough of its platform
// layer up to need one. A headless build machine would need `xvfb-run` or equivalent (not verified
// here - there was no Xvfb on the machine this was measured on). These tests skip themselves without a
// display for that reason, like every other windowed example here.
//
// What it is for: a Sciter pane inside an application whose frames belong to someone else - a game
// engine, an immediate-mode tool UI, a raylib or SDL program - or a document rendered to an image on a
// build machine with no display at all. `docs/EMBEDDING.md` is the long version and
// `docs/ALTERNATIVES.md` is where this sits among the other ways to get a page into a native app.
//
// The five things it teaches:
//
//   - **The whole API is one slot.** `SciterProcX` plus the `SXM_*` message structs. `sciter_app`'s
//     `create_windowless` / `resize_windowless` / `paint_windowless` / `windowless_heartbeat` are each
//     one message, and *everything else in the package works unchanged* - `load_html`, `root`,
//     `select_first`, `eval`, `set_host_handler` - because they take a `Window` and the view's
//     `window` is one.
//   - **You allocate the surface, so you decide where it lives.** `test_a_view_renders_into_a
//     _sub_rectangle_of_a_larger_image` renders a view straight into the middle of a 640x480 image the
//     host owns, by handing it a slice and the big image's stride. That is compositing, and it costs
//     nothing.
//   - **`on_invalidate_rect` is the repaint signal.** Nothing paints itself and nothing schedules a
//     frame; the host handler's invalidate notification is what says a paint is due.
//   - **Input works, fully - and both notes saying it did not were the same stylesheet bug.** Both
//     `SXM_MOUSE` and `SXM_KEY` reach the document: handlers run, `:hover` follows the pointer, a click
//     is synthesised from a press and a release, and the *intrinsic behaviors respond too* - a button
//     presses, a checkbox toggles, and a click gives an `<input>` the caret so keys land in it. Both
//     earlier claims to the contrary came from test pages that positioned their widgets with
//     `position: absolute` - which collapses an inline-level `<button>` or `<input>` to **1x1** in this
//     engine, and a percentage height to **1px** - so every click landed on `<body>`. See
//     `docs/html-css-js.md`. The one real subtlety left: a behavior's event is *posted*, so it arrives
//     on the next heartbeat rather than inside the call.
//   - **The clock is the wall clock.** `SXM_HEARTBIT` carries a timestamp and the engine ignores it:
//     script timers fire as real time passes and cannot be driven faster by lying about it, so a host
//     rendering frames faster than real time gets none. One real engine defect is pinned below too -
//     a single `SXM_DESTROY` ends windowless mode for the whole process.
package main

import sciter ".."
import "../sciter_app"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

W :: 400
H :: 260

// Nothing here animates itself: the progress bar below is driven by the host between frames, which is
// what a renderer that does not run at wall-clock speed has to do. See the timer test for why.
DOC :: `<html>
<head><style>
  html, body { margin: 0; padding: 0; width: 100%; height: 100%; background: #1e1e2e; color: #cdd6f4;
               font: 16px system; }
  #card { margin: 20px; padding: 16px; background: #313244; border: 1px solid #45475a; }
  h1 { margin: 0 0 8px 0; font-size: 20px; color: #89b4fa; }
  #bar { height: 18px; width: 100%; background: #45475a; }
  #fill { height: 100%; width: 10%; background: #a6e3a1; }
  #note { margin-top: 10px; color: #a6adc8; font-size: 13px; }
  input { width: 100%; margin-top: 8px; }
</style></head>
<body>
  <div id="card">
    <h1>rendered with no window</h1>
    <div id="bar"><div id="fill"></div></div>
    <div id="note">the host drives this</div>
    <input id="field" type="text" value="" />
  </div>
  <script type="text/javascript">
    // The mouse log, which is how the tests below assert what the *document* sees rather than what
    // SciterProcX returns - the two disagree, and the document is the one that matters.
    globalThis.mouse = "";
    var card = document.getElementById("card");
    card.addEventListener("mousedown", function(){ globalThis.mouse += "d"; });
    card.addEventListener("mouseup",   function(){ globalThis.mouse += "u"; });
    card.addEventListener("click",     function(){ globalThis.mouse += "c"; });
    card.addEventListener("mousemove", function(){ globalThis.mouse += "m"; });
  </script>
</body>
</html>`

// ---------------------------------------------------------------------------------------------------
// The host side
//
// A windowless view has no pump, so the host owns the clock: beat, decide, paint. This is the loop an
// embedder writes, and it is eight lines.

Host :: struct {
	using handler: sciter_app.Host_Handler,
	invalidations: int, // how many times the engine asked for a repaint
	last_rect:     sciter.Rect,
}

on_invalidate_rect :: proc(handler: ^sciter_app.Host_Handler, window: sciter_app.Window, rect: sciter.Rect) {
	host := (^Host)(handler)
	host.invalidations += 1
	host.last_rect = rect
}

// One frame: give the engine its turn of the clock, then draw. A real embedder paints only when
// `host.invalidations` has moved; this example paints every frame because it renders so few.
frame :: proc(view: ^sciter_app.Windowless_View, elapsed: time.Duration = 0) -> sciter_app.Error {
	sciter_app.windowless_heartbeat(view, elapsed)
	return paint(view)
}

paint :: proc(view: ^sciter_app.Windowless_View) -> sciter_app.Error {
	return sciter_app.paint_windowless(view)
}

// ---------------------------------------------------------------------------------------------------
// Writing the result out
//
// A binary PPM, because it needs no encoder and the point is to prove the pixels exist rather than to
// ship an image pipeline. Any viewer opens one; `magick target/windowless.ppm out.png` converts it.

write_ppm :: proc(path: string, view: ^sciter_app.Windowless_View) -> bool {
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&builder, "P6\n%d %d\n255\n", view.width, view.height)
	for y in 0 ..< view.height {
		for x in 0 ..< view.width {
			r, g, b, _ := sciter_app.windowless_pixel(view, x, y)
			strings.write_byte(&builder, r)
			strings.write_byte(&builder, g)
			strings.write_byte(&builder, b)
		}
	}
	return os.write_entire_file(path, transmute([]u8)strings.to_string(builder)) == nil
}

// ---------------------------------------------------------------------------------------------------

main :: proc() {
	if !sciter_app.load_engine() {
		os.exit(1)
	}
	sciter_app.set_default_debug_output()

	// **No `sciter_app.init()`.** Every windowed example calls it; this one must not - it stands up the
	// windowed application subsystem, which is the thing a windowless view exists not to have.

	view, err := sciter_app.create_windowless({width = W, height = H})
	if err != nil {
		fmt.eprintln("could not create a windowless view:", err)
		os.exit(1)
	}
	defer sciter_app.destroy_windowless(&view)

	host := Host{}
	host.on_invalidate_rect = on_invalidate_rect
	sciter_app.set_host_handler(view.window, &host)

	// `about:blank` as the base URL, as the SDK's own demo does: relative references in the document
	// need something to resolve against even when nothing is on disk.
	if lerr := sciter_app.load_html(view.window, DOC, "about:blank"); lerr != nil {
		fmt.eprintln("could not load the document:", lerr)
		os.exit(1)
	}

	// Let the load settle, then draw the first frame.
	for i in 0 ..< 8 {
		frame(&view, time.Duration(i) * 16 * time.Millisecond)
	}
	fmt.printfln(
		"%dx%d surface, %d bytes, %v order",
		view.width,
		view.height,
		len(view.pixels),
		sciter_app.PIXEL_ORDER,
	)
	fmt.printfln("the engine asked for %d repaints while loading", host.invalidations)
	write_ppm("target/windowless-1.ppm", &view)

	// **Host-driven animation.** Script timers work but run on the wall clock, so a loop that renders
	// faster than real time - this one, and any offline renderer - sees none of them. The version that
	// always works is this: change the DOM, beat, paint. Ten frames of a progress bar filling.
	root, _ := sciter_app.root(view.window)
	fill, ferr := sciter_app.select_first(root, "#fill")
	if ferr == nil {
		for step in 1 ..= 10 {
			sciter_app.set_style(fill, "width", fmt.tprintf("%d%%", step * 10))
			frame(&view, time.Duration(200 + step * 16) * time.Millisecond)
		}
	}
	if note, nerr := sciter_app.select_first(root, "#note"); nerr == nil {
		sciter_app.set_text(note, "ten frames later, driven entirely from Odin")
	}
	frame(&view, 400 * time.Millisecond)
	write_ppm("target/windowless-2.ppm", &view)

	// **Typing works, clicking does not.** Focus the field, send a few characters, and read back what
	// the DOM holds - all with no window and no pump.
	if field, fielderr := sciter_app.select_first(root, "#field"); fielderr == nil {
		sciter_app.set_focus(field)
		sciter_app.windowless_focus(&view)
		for c in "typed with no window" {
			sciter_app.windowless_key(&view, .CHAR, u32(c))
		}
		frame(&view, 500 * time.Millisecond)

		value, verr := sciter_app.element_value(field)
		if verr == nil {
			defer sciter_app.value_clear(&value)
			text, _ := sciter_app.value_to_string(&value, context.temp_allocator)
			fmt.printfln("the field now holds %q", text)
		}
	}

	// And the mouse. Note what is reported: not `SciterProcX`'s return value, which is false even for
	// events it delivered, but what the *document* saw - the page logs every mouse event it receives
	// into `globalThis.mouse`. A press and a release; the `click` is the engine's own synthesis.
	sciter_app.windowless_mouse(&view, .MOUSE_MOVE, {W / 2, 40})
	sciter_app.windowless_mouse(&view, .MOUSE_DOWN, {W / 2, 40})
	sciter_app.windowless_mouse(&view, .MOUSE_UP, {W / 2, 40})
	frame(&view, 600 * time.Millisecond)
	if seen, merr := sciter_app.eval(view.window, "globalThis.mouse"); merr == nil {
		defer sciter_app.value_clear(&seen)
		text, _ := sciter_app.value_to_string(&seen, context.temp_allocator)
		fmt.printfln("the document saw %q - m(ove), d(own), u(p), c(lick synthesised by the engine)", text)
	}

	write_ppm("target/windowless-3.ppm", &view)
	fmt.println("wrote target/windowless-1.ppm, -2.ppm and -3.ppm")
}

// ---------------------------------------------------------------------------------------------------
// Tests
//
// These share one view, and none of them destroys it - see `test_the_view_is_never_destroyed_here` for
// why that is a rule rather than laziness.
//
// They skip themselves without a display, like the windowed examples, because **`SXM_CREATE` segfaults
// when there is none** - measured, and the surprise of the whole exercise.

// **On macOS a windowless view stands up AppKit anyway, and the header's claim above it does not hold
// there.** `main` says this example must not call `sciter_app.init()` because that builds the windowed
// application subsystem - true on Linux and Windows, false here. Measured from the abort trace:
//
//	lite::application::factory -> xskia::application -> xwing::application -> wing::init
//	  -> wing::internal::InitCocoa -> initMenuBar -> -[NSApplication setMainMenu:]
//
// `create_windowless` reaches the same singleton the windowed path does, so the engine constructs
// `NSApplication` either way and AppKit aborts when that happens off the main thread. Odin's test
// runner never runs a test on the main thread, so this `@(init)` - which does - builds the singleton
// before the runner starts. `sciter_app.init()` is what does the building; calling it costs this
// example nothing on macOS that the engine has not already taken.
//
// An experiment until CI says otherwise, and the best case for it: nothing here needs a *window*, so if
// the thread is the whole problem, these tests are the ones that come back. See
// docs/MACOS-CHECKLIST.md section 2.
when ODIN_OS == .Darwin && ODIN_TEST {
	@(private = "file")
	@(init)
	darwin_main_thread_bootstrap :: proc "contextless" () {
		context = runtime.default_context()
		if !sciter_app.load_engine() {
			return
		}
		_ = sciter_app.init()

		// And forget the thread that just armed rule 1. That thread is `main`, every test runs on a
		// `thread.Pool` worker, and the guard would trap each one on its first engine call. The split is
		// real and unavoidable - AppKit wants main for the singleton, the runner wants a worker for the
		// tests - so what re-arming buys is the rest of the rule: the first test call arms the worker,
		// and a later call from anywhere else still traps. docs/MACOS-CHECKLIST.md section 2 has why.
		sciter_app.check_thread_affinity()
	}
}

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
g_view: sciter_app.Windowless_View

@(private = "file")
g_host: ^Host

@(private = "file")
test_view :: proc(t: ^testing.T) -> (^sciter_app.Windowless_View, ^Host, bool) {
	if !have_display() {
		fmt.println("skipping - a windowless view still needs a display here, see the header")
		return nil, nil, false
	}
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}

	// **Not optional on Windows, and the reason is not obvious.** With no host handler installed the
	// engine reports parse errors and script diagnostics through `OutputDebugStringW`, which Windows
	// implements by *raising an exception* (DBG_PRINTEXCEPTION_WIDE_C, 0x4001000A). Odin's test runner
	// installs a handler that treats any exception as fatal to the test, so a CSS warning killed the
	// test that provoked it and every test after it in the file - reported as `Signal caught: Unknown`,
	// which reads like a segfault and is not one. Routing diagnostics to a callback avoids the API
	// entirely. Harmless on Linux, where it just makes the engine's warnings visible.
	sciter_app.set_default_debug_output()
	context.allocator = runtime.default_allocator()

	if g_view.window == nil {
		view, err := sciter_app.create_windowless({width = W, height = H})
		testing.expect_value(t, err, nil)
		if err != nil {
			return nil, nil, false
		}
		g_view = view

		g_host = new(Host)
		g_host.on_invalidate_rect = on_invalidate_rect
		sciter_app.set_host_handler(g_view.window, g_host)
	}

	// A fresh document for every test, which is also the measured answer to "how does a long-running
	// host swap what a view shows": load another one. There is no destroy in it.
	testing.expect_value(t, sciter_app.load_html(g_view.window, DOC, "about:blank"), nil)
	for i in 0 ..< 8 {
		frame(&g_view, time.Duration(i) * 16 * time.Millisecond)
	}
	return &g_view, g_host, true
}

// The claim the whole example rests on: a document, rendered, in memory the host allocated, with no
// window anywhere in the process.
@(test)
test_a_view_renders_its_document_into_a_buffer_the_host_owns :: proc(t: ^testing.T) {
	view, _, ok := test_view(t)
	if !ok {return}

	testing.expect_value(t, len(view.pixels), W * H * 4)
	testing.expect_value(t, view.stride, W * 4)

	// The page's background, sampled away from the card. `#1e1e2e` is what the stylesheet says, and
	// reading it back is what pins the channel order: a BGRA misread would answer 2e 1e 1e.
	r, g, b, a := sciter_app.windowless_pixel(view, 4, H - 4)
	testing.expect_value(t, r, 0x1e)
	testing.expect_value(t, g, 0x1e)
	testing.expect_value(t, b, 0x2e)
	testing.expect_value(t, a, 0xff)

	// The card, which is a different colour - so this is a laid-out document rather than a cleared
	// buffer.
	cr, cg, cb, _ := sciter_app.windowless_pixel(view, W / 2, 30)
	testing.expect_value(t, cr, 0x31)
	testing.expect_value(t, cg, 0x32)
	testing.expect_value(t, cb, 0x44)

	// And something was drawn nearly everywhere - a partial paint would leave most of it zero.
	painted := 0
	for y in 0 ..< view.height {
		for x in 0 ..< view.width {
			if pr, pg, pb, _ := sciter_app.windowless_pixel(view, x, y); pr != 0 || pg != 0 || pb != 0 {
				painted += 1
			}
		}
	}
	testing.expectf(t, painted > int(W * H) * 9 / 10, "only %d of %d pixels were painted", painted, W * H)
}

// Nothing repaints itself, so the host has to be told when to. `on_invalidate_rect` is that signal, and
// it works on a view with no window - which is the notification the whole mode is built on.
@(test)
test_the_host_is_told_when_a_repaint_is_due :: proc(t: ^testing.T) {
	view, host, ok := test_view(t)
	if !ok {return}

	testing.expect(t, host.invalidations > 0, "loading a document should have asked for a repaint")
	testing.expect(t, host.last_rect.right > 0 && host.last_rect.bottom > 0)

	// A change the host makes asks for another one.
	before := host.invalidations
	root, _ := sciter_app.root(view.window)
	note, err := sciter_app.select_first(root, "#note")
	testing.expect_value(t, err, nil)
	sciter_app.set_text(note, "changed")
	sciter_app.windowless_heartbeat(view, 100 * time.Millisecond)

	testing.expect(t, host.invalidations > before, "a DOM change should have invalidated something")
}

// The DOM, selectors and script all work on a view with no window - and a host-driven change reaches
// the pixels, which is the whole embedder round trip: Odin -> the DOM or QuickJS -> style -> our buffer.
@(test)
test_the_dom_and_eval_reach_the_pixels_with_no_window :: proc(t: ^testing.T) {
	view, _, ok := test_view(t)
	if !ok {return}

	before_r, before_g, before_b, _ := sciter_app.windowless_pixel(view, W / 2, 30)

	value, err := sciter_app.eval(
		view.window,
		`document.getElementById("card").style["background-color"] = "#ff00ff"; 1`,
	)
	testing.expect_value(t, err, nil)
	sciter_app.value_clear(&value)

	testing.expect_value(t, frame(view, 300 * time.Millisecond), nil)

	r, g, b, _ := sciter_app.windowless_pixel(view, W / 2, 30)
	testing.expect_value(t, r, 0xff)
	testing.expect_value(t, g, 0x00)
	testing.expect_value(t, b, 0xff)
	testing.expect(t, r != before_r || g != before_g || b != before_b)

	// The DOM half, through this package's ordinary calls rather than through script.
	root, rerr := sciter_app.root(view.window)
	testing.expect_value(t, rerr, nil)
	heading, herr := sciter_app.select_first(root, "h1")
	testing.expect_value(t, herr, nil)
	text, _ := sciter_app.text(heading, context.temp_allocator)
	testing.expect_value(t, text, "rendered with no window")

	// Hit testing works too, which is what makes the mouse finding below a delivery problem rather than
	// a geometry one.
	hit, hiterr := sciter_app.element_at(view.window, {W / 2, 30})
	testing.expect_value(t, hiterr, nil)
	testing.expect(t, hit != nil)
}

// Keys reach the document: focus an element, send characters, read the value back - with no window and
// no pump anywhere in the process.
@(test)
test_a_view_can_be_typed_into :: proc(t: ^testing.T) {
	view, _, ok := test_view(t)
	if !ok {return}

	root, _ := sciter_app.root(view.window)
	field, err := sciter_app.select_first(root, "#field")
	testing.expect_value(t, err, nil)

	testing.expect_value(t, sciter_app.set_focus(field), nil)
	testing.expect(t, sciter_app.windowless_focus(view), "SXM_FOCUS is accepted")

	for c in "abc" {
		sciter_app.windowless_key(view, .CHAR, u32(c))
	}
	sciter_app.windowless_heartbeat(view, 200 * time.Millisecond)

	value, verr := sciter_app.element_value(field)
	testing.expect_value(t, verr, nil)
	defer sciter_app.value_clear(&value)
	text, _ := sciter_app.value_to_string(&value, context.temp_allocator)
	testing.expect_value(t, text, "abc")

}

// **The mouse, which the earlier note in `EMBEDDING.md` had wrong.** It works: a press and a release on
// an element with a real box produce `mousedown`, `mouseup` and a synthesised `click`, and `:hover`
// follows the pointer.
//
// The test asserts what the *document* saw rather than what `SciterProcX` returned, because the two
// disagree - the return is false even for events that were delivered. What the document saw is also
// the only thing an application cares about.
@(test)
test_the_mouse_reaches_the_document :: proc(t: ^testing.T) {
	view, _, ok := test_view(t)
	if !ok {return}

	// The card is in normal flow with a real height. **That matters**: the page this was first tested
	// with caught clicks on an absolutely positioned overlay with a percentage height, which Sciter
	// lays out one pixel tall, so every event went to `<body>` and the engine looked broken. The box is
	// asserted here so that a layout change cannot quietly turn this test into a lie.
	root, _ := sciter_app.root(view.window)
	card, cerr := sciter_app.select_first(root, "#card")
	testing.expect_value(t, cerr, nil)
	box, berr := sciter_app.location(card, .Border, .View)
	testing.expect_value(t, berr, nil)
	testing.expectf(
		t,
		box.height > 10,
		"the click target is %vx%v - a collapsed box receives nothing",
		box.width,
		box.height,
	)

	at := [2]i32{box.x + box.width / 2, box.y + 10}

	// Move, then press and release. `.MOUSE_CLICK` is deliberately not sent: the engine synthesises the
	// click from the pair, exactly as it does for a windowed view.
	sciter_app.windowless_mouse(view, .MOUSE_MOVE, at)
	sciter_app.windowless_mouse(view, .MOUSE_DOWN, at)
	sciter_app.windowless_mouse(view, .MOUSE_UP, at)
	sciter_app.windowless_heartbeat(view, 250 * time.Millisecond)

	seen, serr := sciter_app.eval(view.window, "globalThis.mouse")
	testing.expect_value(t, serr, nil)
	defer sciter_app.value_clear(&seen)
	log, _ := sciter_app.value_to_string(&seen, context.temp_allocator)

	testing.expectf(t, strings.contains(log, "m"), "no mousemove reached the document; log is %q", log)
	testing.expectf(t, strings.contains(log, "d"), "no mousedown reached the document; log is %q", log)
	testing.expectf(t, strings.contains(log, "u"), "no mouseup reached the document; log is %q", log)
	testing.expectf(t, strings.contains(log, "c"), "the click was not synthesised; log is %q", log)

	// And the pointer position becomes a hover state, so stylesheets can see it too.
	under, uerr := sciter_app.element_at(view.window, at)
	testing.expect_value(t, uerr, nil)
	state, sterr := sciter_app.element_state(under)
	testing.expect_value(t, sterr, nil)
	testing.expect(t, .HOVER in state, "the element under the pointer should be hovered")
}

// **The intrinsic behaviors respond to the windowless mouse**, and this test used to assert the exact
// opposite. It was wrong for the same reason the "the mouse never works" note was wrong: its widgets
// were `position: absolute`, and an inline-level `<button>` or `<input>` taken out of flow lays out
// **1x1** in this engine, so every click landed on `<body>`. Same call, same engine, boxes with a real
// size - and a click presses the button, toggles the checkbox, and gives the field the caret.
//
// The second trap is in here too: a behavior's event is **posted**, so it has not been delivered when
// `windowless_mouse` returns. One heartbeat is what makes it observable.
@(test)
test_the_windowless_mouse_drives_the_intrinsic_behaviors :: proc(t: ^testing.T) {
	if !have_display() {
		fmt.println("skipping - a windowless view still needs a display here, see the header")
		return
	}
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}

	// **Not optional on Windows, and the reason is not obvious.** With no host handler installed the
	// engine reports parse errors and script diagnostics through `OutputDebugStringW`, which Windows
	// implements by *raising an exception* (DBG_PRINTEXCEPTION_WIDE_C, 0x4001000A). Odin's test runner
	// installs a handler that treats any exception as fatal to the test, so a CSS warning killed the
	// test that provoked it and every test after it in the file - reported as `Signal caught: Unknown`,
	// which reads like a segfault and is not one. Routing diagnostics to a callback avoids the API
	// entirely. Harmless on Linux, where it just makes the engine's warnings visible.
	sciter_app.set_default_debug_output()
	context.allocator = runtime.default_allocator()

	view, err := sciter_app.create_windowless({width = 300, height = 200})
	testing.expect_value(t, err, nil)
	if err != nil {return}

	// In normal flow with real sizes. `position: absolute` here is what made the original version of
	// this test measure the opposite of the truth.
	WIDGETS :: `<html><head><style>
	  html, body { margin:0; padding:0; width:100%; height:100%; background:#1e1e2e; }
	  #field { display:block; width:200px; height:30px; }
	  #btn { display:block; width:120px; height:30px; margin-top:20px; }
	  #check { display:block; margin-top:20px; }
	</style></head><body>
	  <input id="field" type="text" value="" />
	  <button id="btn">press me</button>
	  <input id="check" type="checkbox" />
	  <script type="text/javascript">
	    globalThis.presses = 0;
	    document.getElementById("btn").addEventListener("click", function(){ globalThis.presses += 1; });
	  </script>
	</body></html>`

	testing.expect_value(t, sciter_app.load_html(view.window, WIDGETS, "about:blank"), nil)
	for i in 0 ..< 10 {
		testing.expect_value(t, frame(&view, time.Duration(i) * 16 * time.Millisecond), nil)
	}
	root, _ := sciter_app.root(view.window)

	click :: proc(view: ^sciter_app.Windowless_View, at: [2]i32, elapsed: time.Duration) {
		sciter_app.windowless_mouse(view, .MOUSE_MOVE, at)
		sciter_app.windowless_mouse(view, .MOUSE_DOWN, at)
		sciter_app.windowless_mouse(view, .MOUSE_UP, at)
		frame(view, elapsed)
	}

	// Ask the engine where things are rather than assuming the CSS was honoured - which is the lesson
	// the original version of this test failed to apply to itself.
	center :: proc(root: sciter_app.Element, selector: string) -> [2]i32 {
		el, err := sciter_app.select_first(root, selector)
		if err != nil {return {-1, -1}}
		r, lerr := sciter_app.location(el, .Border, .View)
		if lerr != nil {return {-1, -1}}
		return {r.x + r.width / 2, r.y + r.height / 2}
	}

	// The button fires its own click...
	click(&view, center(root, "#btn"), 100 * time.Millisecond)
	presses, perr := sciter_app.eval(view.window, "globalThis.presses")
	testing.expect_value(t, perr, nil)
	defer sciter_app.value_clear(&presses)
	n, _ := sciter_app.value_to_int(&presses)
	testing.expect_value(t, n, i32(1))

	// ...the checkbox toggles...
	check, cerr := sciter_app.select_first(root, "#check")
	testing.expect_value(t, cerr, nil)
	before, _ := sciter_app.element_state(check)
	testing.expect(t, .CHECKED not_in before, "it starts unchecked")
	click(&view, center(root, "#check"), 200 * time.Millisecond)
	checked, kerr := sciter_app.element_state(check)
	testing.expect_value(t, kerr, nil)
	testing.expect(t, .CHECKED in checked, "a click through the view should toggle a checkbox")

	// ...and a click gives the field the caret, so it takes keys with no `set_focus` at all.
	field, ferr := sciter_app.select_first(root, "#field")
	testing.expect_value(t, ferr, nil)
	testing.expect(t, sciter_app.windowless_focus(&view))
	click(&view, center(root, "#field"), 300 * time.Millisecond)
	state, serr := sciter_app.element_state(field)
	testing.expect_value(t, serr, nil)
	testing.expect(t, .FOCUS in state, "a click should focus an intrinsic edit")

	for c in "typed" {
		sciter_app.windowless_key(&view, .CHAR, u32(c))
	}
	frame(&view, 400 * time.Millisecond)

	value, verr := sciter_app.element_value(field)
	testing.expect_value(t, verr, nil)
	defer sciter_app.value_clear(&value)
	text, _ := sciter_app.value_to_string(&value, context.temp_allocator)
	testing.expect_value(t, text, "typed")

	// Driving the element directly still works, and is what a host with no pointer uses.
	button, berr := sciter_app.select_first(root, "#btn")
	testing.expect_value(t, berr, nil)
	_, clickerr := sciter_app.do_click(button)
	testing.expect_value(t, clickerr, nil)
	frame(&view, 500 * time.Millisecond)

	after, aerr := sciter_app.eval(view.window, "globalThis.presses")
	testing.expect_value(t, aerr, nil)
	defer sciter_app.value_clear(&after)
	m, _ := sciter_app.value_to_int(&after)
	testing.expect_value(t, m, i32(2))
}

// The delivery rule underneath the test above: a behavior's event is **posted**, so nothing has
// happened when `windowless_mouse` returns and one heartbeat is what makes it observable. A host that
// checks inside the same turn concludes the click was ignored - which is half of how this file came to
// document the opposite of the truth.
@(test)
test_a_behaviors_event_arrives_on_the_next_heartbeat :: proc(t: ^testing.T) {
	if !have_display() {
		fmt.println("skipping - a windowless view still needs a display here, see the header")
		return
	}
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}

	// **Not optional on Windows, and the reason is not obvious.** With no host handler installed the
	// engine reports parse errors and script diagnostics through `OutputDebugStringW`, which Windows
	// implements by *raising an exception* (DBG_PRINTEXCEPTION_WIDE_C, 0x4001000A). Odin's test runner
	// installs a handler that treats any exception as fatal to the test, so a CSS warning killed the
	// test that provoked it and every test after it in the file - reported as `Signal caught: Unknown`,
	// which reads like a segfault and is not one. Routing diagnostics to a callback avoids the API
	// entirely. Harmless on Linux, where it just makes the engine's warnings visible.
	sciter_app.set_default_debug_output()
	context.allocator = runtime.default_allocator()

	view, err := sciter_app.create_windowless({width = 300, height = 200})
	testing.expect_value(t, err, nil)
	if err != nil {return}

	DOC_BTN :: `<html><head><style>
	  html, body { margin:0; padding:0; width:100%; height:100%; background:#1e1e2e; }
	  #btn { display:block; width:120px; height:30px; }
	</style></head><body>
	  <button id="btn">press me</button>
	  <script type="text/javascript">
	    globalThis.presses = 0;
	    document.getElementById("btn").addEventListener("click", function(){ globalThis.presses += 1; });
	  </script>
	</body></html>`

	testing.expect_value(t, sciter_app.load_html(view.window, DOC_BTN, "about:blank"), nil)
	for i in 0 ..< 10 {
		testing.expect_value(t, frame(&view, time.Duration(i) * 16 * time.Millisecond), nil)
	}
	root, _ := sciter_app.root(view.window)
	btn, _ := sciter_app.select_first(root, "#btn")
	box, _ := sciter_app.location(btn, .Border, .View)
	at := [2]i32{box.x + box.width / 2, box.y + box.height / 2}

	presses :: proc(view: ^sciter_app.Windowless_View) -> i32 {
		v, err := sciter_app.eval(view.window, "globalThis.presses")
		if err != nil {return -1}
		defer sciter_app.value_clear(&v)
		n, _ := sciter_app.value_to_int(&v)
		return n
	}

	sciter_app.windowless_mouse(&view, .MOUSE_DOWN, at)
	sciter_app.windowless_mouse(&view, .MOUSE_UP, at)
	testing.expect_value(t, presses(&view), i32(0)) // posted, not delivered

	sciter_app.windowless_heartbeat(&view, 100 * time.Millisecond)
	testing.expect_value(t, presses(&view), i32(1)) // one beat is enough
}

// **Script timers run on the wall clock, and `SXM_HEARTBIT`'s timestamp is ignored.** This test was
// first written the other way round - "timers never fire" - because sixty heartbeats with timestamps
// stepping 16ms apart fired nothing. They also took two milliseconds of real time between them. Under
// ASan, where everything is slower, the same test failed by *succeeding*: a 16ms interval fired.
//
// So the heartbeat is the pump and the clock is the clock, and lying to the engine about the time
// changes nothing. What that costs an embedder is worth knowing: a host rendering frames faster than
// real time - a build machine writing out an image, a test - gets no timers, and has to drive anything
// animated itself. `main` above does that in three lines.
@(test)
test_script_timers_run_on_the_wall_clock_not_the_heartbeat_timestamp :: proc(t: ^testing.T) {
	view, _, ok := test_view(t)
	if !ok {return}

	arm :: proc(t: ^testing.T, view: ^sciter_app.Windowless_View) {
		setup, err := sciter_app.eval(
			view.window,
			`globalThis.interval = 0; globalThis.timeout = 0; globalThis.frames = 0;
			 setInterval(function(){ globalThis.interval += 1; }, 16);
			 setTimeout(function(){ globalThis.timeout = 1; }, 30);
			 function tick() { globalThis.frames += 1; requestAnimationFrame(tick); }
			 requestAnimationFrame(tick);
			 1`,
		)
		testing.expect_value(t, err, nil)
		sciter_app.value_clear(&setup)
	}

	count :: proc(view: ^sciter_app.Windowless_View, name: string) -> int {
		value, err := sciter_app.eval(view.window, name)
		if err != nil {return -1}
		defer sciter_app.value_clear(&value)
		n, _ := sciter_app.value_to_int(&value)
		return int(n)
	}

	// **Real time passing, with the timestamp deliberately nailed to zero.** If the engine took its
	// clock from the message, nothing here could fire.
	arm(t, view)
	for _ in 0 ..< 20 {
		testing.expect_value(t, frame(view, 0 * time.Millisecond), nil)
		time.sleep(16 * time.Millisecond)
	}
	testing.expect(t, count(view, "globalThis.interval") > 0, "setInterval should have fired as real time passed")
	testing.expect(t, count(view, "globalThis.frames") > 0, "requestAnimationFrame should have run")
	testing.expect_value(t, count(view, "globalThis.timeout"), 1)

	// And the heartbeat is still required: real time on its own does nothing, because nothing is
	// draining the engine's queue.
	arm(t, view)
	time.sleep(320 * time.Millisecond)
	testing.expect_value(t, count(view, "globalThis.interval"), 0)
	testing.expect_value(t, count(view, "globalThis.timeout"), 0)

	// One heartbeat afterwards delivers what came due while nothing was pumping.
	testing.expect_value(t, frame(view, 0 * time.Millisecond), nil)
	testing.expect(t, count(view, "globalThis.timeout") == 1, "the due timeout should arrive on the next beat")
}

// Resizing a live view: a new surface and a reflow, with the document intact across it.
@(test)
test_resizing_a_view_reflows_the_document_into_the_new_surface :: proc(t: ^testing.T) {
	view, _, ok := test_view(t)
	if !ok {return}

	old_pixels := raw_data(view.pixels)
	testing.expect_value(t, sciter_app.resize_windowless(view, W * 2, H * 2), nil)
	testing.expect_value(t, view.width, i32(W * 2))
	testing.expect_value(t, view.stride, W * 2 * 4)
	testing.expect_value(t, len(view.pixels), W * 2 * H * 2 * 4)
	testing.expect(t, raw_data(view.pixels) != old_pixels, "a bigger surface is a new allocation")

	testing.expect_value(t, frame(view, 400 * time.Millisecond), nil)

	// The far corner of the *new* surface is painted, so the document really did reflow rather than
	// being letterboxed into the old size.
	r, g, b, _ := sciter_app.windowless_pixel(view, W * 2 - 4, H * 2 - 4)
	testing.expect_value(t, r, 0x1e)
	testing.expect_value(t, g, 0x1e)
	testing.expect_value(t, b, 0x2e)

	// Put it back for whatever runs next: these tests share one view.
	testing.expect_value(t, sciter_app.resize_windowless(view, W, H), nil)
	testing.expect_value(t, frame(view, 500 * time.Millisecond), nil)
}

// **The compositing case, which is the reason the mode exists.** The host owns a 640x480 image; the
// view renders into a 200x150 rectangle in the middle of it, in place, by being handed a slice and the
// *big* image's stride. No copy, no intermediate surface.
@(test)
test_a_view_renders_into_a_sub_rectangle_of_a_larger_image :: proc(t: ^testing.T) {
	if !have_display() {
		fmt.println("skipping - a windowless view still needs a display here, see the header")
		return
	}
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}

	// **Not optional on Windows, and the reason is not obvious.** With no host handler installed the
	// engine reports parse errors and script diagnostics through `OutputDebugStringW`, which Windows
	// implements by *raising an exception* (DBG_PRINTEXCEPTION_WIDE_C, 0x4001000A). Odin's test runner
	// installs a handler that treats any exception as fatal to the test, so a CSS warning killed the
	// test that provoked it and every test after it in the file - reported as `Signal caught: Unknown`,
	// which reads like a segfault and is not one. Routing diagnostics to a callback avoids the API
	// entirely. Harmless on Linux, where it just makes the engine's warnings visible.
	sciter_app.set_default_debug_output()
	context.allocator = runtime.default_allocator()

	IMAGE_W :: 640
	IMAGE_H :: 480
	VIEW_W :: 200
	VIEW_H :: 150
	AT_X :: 120
	AT_Y :: 90

	image := make([]u8, IMAGE_W * IMAGE_H * 4)
	for i in 0 ..< IMAGE_W * IMAGE_H {
		image[i * 4 + 0] = 0xff // the host's own content: opaque red everywhere
		image[i * 4 + 3] = 0xff
	}

	offset := (AT_Y * IMAGE_W + AT_X) * 4
	view, err := sciter_app.create_windowless(
		{width = VIEW_W, height = VIEW_H, pixels = image[offset:], stride = IMAGE_W * 4},
	)
	testing.expect_value(t, err, nil)
	if err != nil {return}
	testing.expect(t, !view.owns_pixels, "the caller's buffer is used as it is")

	// Deliberately not destroyed - see `test_the_view_is_never_destroyed_here`.
	testing.expect_value(
		t,
		sciter_app.load_html(
			view.window,
			`<html><body style="margin:0;background:#00ff00"></body></html>`,
			"about:blank",
		),
		nil,
	)
	for i in 0 ..< 8 {
		testing.expect_value(t, frame(&view, time.Duration(i) * 16 * time.Millisecond), nil)
	}

	pixel :: proc(image: []u8, x, y: int) -> (r, g, b: u8) {
		i := (y * IMAGE_W + x) * 4
		return image[i], image[i + 1], image[i + 2]
	}

	// Inside the rectangle: the document. Outside it: the host's own red, untouched on every side.
	ir, ig, ib := pixel(image, AT_X + VIEW_W / 2, AT_Y + VIEW_H / 2)
	testing.expect_value(t, ir, 0x00)
	testing.expect_value(t, ig, 0xff)
	testing.expect_value(t, ib, 0x00)

	outside := [][2]int {
		{0, 0},
		{AT_X - 1, AT_Y + 10},
		{AT_X + VIEW_W, AT_Y + 10},
		{AT_X + 10, AT_Y - 1},
		{AT_X + 10, AT_Y + VIEW_H},
		{IMAGE_W - 1, IMAGE_H - 1},
	}
	for point in outside {
		r, g, b := pixel(image, point.x, point.y)
		testing.expectf(
			t,
			r == 0xff && g == 0 && b == 0,
			"the host's image was overwritten at %v: %02x %02x %02x",
			point,
			r,
			g,
			b,
		)
	}

	// The last row of the rectangle is inside the image, which is the arithmetic a stride-aware
	// embedder gets wrong once: the surface ends `width*4` into the final row, not a whole stride.
	lr, lg, lb := pixel(image, AT_X + VIEW_W - 1, AT_Y + VIEW_H - 1)
	testing.expect_value(t, lr, 0x00)
	testing.expect_value(t, lg, 0xff)
	testing.expect_value(t, lb, 0x00)
}

// Two views, two documents, two surfaces, one process - which is what a host with several panes needs.
@(test)
test_two_views_render_independently :: proc(t: ^testing.T) {
	if !have_display() {
		fmt.println("skipping - a windowless view still needs a display here, see the header")
		return
	}
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}

	// **Not optional on Windows, and the reason is not obvious.** With no host handler installed the
	// engine reports parse errors and script diagnostics through `OutputDebugStringW`, which Windows
	// implements by *raising an exception* (DBG_PRINTEXCEPTION_WIDE_C, 0x4001000A). Odin's test runner
	// installs a handler that treats any exception as fatal to the test, so a CSS warning killed the
	// test that provoked it and every test after it in the file - reported as `Signal caught: Unknown`,
	// which reads like a segfault and is not one. Routing diagnostics to a callback avoids the API
	// entirely. Harmless on Linux, where it just makes the engine's warnings visible.
	sciter_app.set_default_debug_output()
	context.allocator = runtime.default_allocator()

	first, err1 := sciter_app.create_windowless({width = 64, height = 64})
	testing.expect_value(t, err1, nil)
	second, err2 := sciter_app.create_windowless({width = 64, height = 64})
	testing.expect_value(t, err2, nil)
	if err1 != nil || err2 != nil {return}

	testing.expect(t, first.window != second.window, "each view gets its own key")

	sciter_app.load_html(first.window, `<html><body style="margin:0;background:#ff0000"></body></html>`, "about:blank")
	sciter_app.load_html(
		second.window,
		`<html><body style="margin:0;background:#0000ff"></body></html>`,
		"about:blank",
	)
	for i in 0 ..< 8 {
		frame(&first, time.Duration(i) * 16 * time.Millisecond)
		frame(&second, time.Duration(i) * 16 * time.Millisecond)
	}

	r1, g1, b1, _ := sciter_app.windowless_pixel(&first, 32, 32)
	r2, g2, b2, _ := sciter_app.windowless_pixel(&second, 32, 32)
	testing.expect_value(t, [3]u8{r1, g1, b1}, [3]u8{0xff, 0x00, 0x00})
	testing.expect_value(t, [3]u8{r2, g2, b2}, [3]u8{0x00, 0x00, 0xff})
}

// **Why nothing here calls `destroy_windowless`, and why there is no test that does.**
//
// Measured on 6.0.4.9: after any `SXM_DESTROY`, the next `SXM_CREATE` segfaults *inside the create
// call* - with the same key or a fresh one, whether or not other views are still alive. So a test that
// destroyed a view would not fail; it would take every test after it in this binary with it, and the
// failure would name whichever test happened to be next.
//
// A second destroy of an already-destroyed view is harmless (it answers false), and two views created
// before any destroy coexist - `test_two_views_render_independently` is that case.
//
// The shape that works in an application: create the views you need, swap their documents with
// `load_html` when what they show changes, and destroy them on the way out. `main` above does exactly
// that. This test asserts only the part that can be asserted safely.
@(test)
test_the_view_is_never_destroyed_here :: proc(t: ^testing.T) {
	view, _, ok := test_view(t)
	if !ok {return}

	// Swapping the document is the supported alternative to destroying and recreating, and it works as
	// often as you like.
	for colour in ([]string{"#ff0000", "#00ff00", "#0000ff"}) {
		html := fmt.tprintf(`<html><body style="margin:0;background:%s"></body></html>`, colour)
		testing.expect_value(t, sciter_app.load_html(view.window, html, "about:blank"), nil)
		for i in 0 ..< 6 {
			testing.expect_value(t, frame(view, time.Duration(i) * 16 * time.Millisecond), nil)
		}

		r, g, b, _ := sciter_app.windowless_pixel(view, W / 2, H / 2)
		expected := [3]u8 {
			u8(hex_pair(colour[1], colour[2])),
			u8(hex_pair(colour[3], colour[4])),
			u8(hex_pair(colour[5], colour[6])),
		}
		testing.expect_value(t, [3]u8{r, g, b}, expected)
	}
}

@(private = "file")
hex_pair :: proc(hi, lo: u8) -> int {
	digit :: proc(c: u8) -> int {
		switch c {
		case '0' ..= '9':
			return int(c - '0')
		case 'a' ..= 'f':
			return int(c - 'a') + 10
		case 'A' ..= 'F':
			return int(c - 'A') + 10
		}
		return 0
	}
	return digit(hi) * 16 + digit(lo)
}
