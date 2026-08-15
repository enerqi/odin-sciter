// Driving the UI as a user would: real mouse and keyboard input, from Odin.
//
//   just example input
//   odin test examples/input.odin -file      # needs a display; skips itself without one
//
// `send_event` announces that something happened. `do_click` makes one thing happen. `send_mouse` and
// `send_key` are the general case: they push the event through the element chain the way the window
// system's own input does, so the intrinsic behaviors run - the button presses and clicks, the text
// field takes the characters, the checkbox toggles.
//
// That makes this the file to read for three separate jobs:
//
//   - a test that wants to drive its own UI without a robot
//   - an automation or accessibility layer
//   - anything replaying recorded input
//
// It also collects the event groups that had no typed accessor until now - `.FOCUS`, `.SCROLL`,
// `.ATTRIBUTE_CHANGE`, `.DATA_ARRIVED` - because watching them is how you check that synthesised input
// did what real input would.
package main

import sciter ".."
import "../sciter_app"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

DOC :: `<html>
<head><style>
  html      { background: #1e1e2e; color: #cdd6f4; font: 16px system; }
  body      { padding: 2em; margin: 0; }
  h1        { color: #89b4fa; margin-top: 0; }
  p         { margin: .4em 0; }
  #go       { display: block; width: 220px; height: 40px; }
  #name     { display: block; width: 260px; height: 30px; }
  #scroller { display: block; width: 260px; height: 5em; overflow-y: scroll;
              background: #313244; border-radius: 4px; }
  #scroller p { margin: 0; padding: .1em .6em; }
  #bar      { display: block; width: 0px; height: 14px; background: #a6e3a1; border-radius: 7px; }
  #out      { margin-top: 1em; padding: .6em 1em; background: #313244; border-radius: 4px;
              font: 14px monospace; white-space: pre-wrap; }
</style>
<script type="module">
  globalThis.shout = function(s) { return s.toUpperCase() + "!"; };
</script>
</head>
<body>
  <p><button id="go">a button Odin will press</button></p>
  <p><input id="name" type="text" value="typed:"></p>
  <p><input id="agree" type="checkbox"> <label>a checkbox</label></p>
  <div id="scroller"><p>one</p><p>two</p><p>three</p><p>four</p><p>five</p><p>six</p><p>seven</p><p>eight</p></div>
  <div id="bar"></div>
  <div id="out">(Odin fills this in)</div>
</body>
</html>`

// An application event code of our own, for the animation frame to carry. Anything at or above
// `.FIRST_APPLICATION_EVENT_CODE` is free; the engine's own codes start at 0, and 0 is `.BUTTON_CLICK`.
TICK :: sciter.Behavior_Events(u32(sciter.Behavior_Events.FIRST_APPLICATION_EVENT_CODE) + 1)

Watch :: struct {
	using handler: sciter_app.Event_Handler,
	clicks:        int,
	value_changes: int,
	focus_gained:  int,
	scrolls:       int,
	attr_changes:  int,
	ticks:         int,
	last_attr:     string,
	data_bytes:    int,
	data_status:   u32,
	// Read by the handler: while true it keeps asking for the next frame.
	animating:     bool,
	element:       sciter_app.Element,
}

on_event :: proc(h: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	w := (^Watch)(h)

	if be, ok := sciter_app.behavior_event(event); ok && be.phase != .Sinking {
		#partial switch be.code {
		case .BUTTON_CLICK:
			w.clicks += 1
		case .VALUE_CHANGED:
			w.value_changes += 1
		case TICK:
			// An animation frame. The return value is what keeps it coming - true re-arms it for the
			// next frame, false is the last one. That is the `.TIMER` inversion, not the usual rule.
			w.ticks += 1
			return w.animating && w.ticks < 30
		}
		return false
	}

	// The groups that had no accessor until now.
	if fe, ok := sciter_app.focus_event(event); ok && fe.phase != .Sinking {
		if fe.code == .GOT {
			w.focus_gained += 1
		}
		return false
	}
	if se, ok := sciter_app.scroll_event(event); ok && se.phase != .Sinking {
		w.scrolls += 1
		return false
	}
	if ac, ok := sciter_app.attribute_change_event(event, context.temp_allocator); ok {
		w.attr_changes += 1
		delete(w.last_attr)
		w.last_attr = fmt.aprintf("%s=%s", ac.name, ac.value)
		return false
	}
	if da, ok := sciter_app.data_arrived_event(event, context.temp_allocator); ok {
		// `data` points into the engine and is valid for this call only.
		w.data_bytes = len(da.data)
		w.data_status = da.status
		return false
	}
	return false
}

// The centre of an element, in the coordinates `send_mouse` and `element_at` take.
centre :: proc(element: sciter_app.Element) -> [2]i32 {
	box, _ := sciter_app.location(element, .Border, .View)
	return {box.x + box.width / 2, box.y + box.height / 2}
}

// A press and a release at one point - what a click is made of.
click_at :: proc(element: sciter_app.Element, pos: [2]i32) -> sciter_app.Error {
	// The button has to be in the set or the behavior ignores the press entirely.
	sciter_app.send_mouse(element, .MOUSE_DOWN, pos, {.MAIN_MOUSE_BUTTON}) or_return
	sciter_app.send_mouse(element, .MOUSE_UP, pos, {.MAIN_MOUSE_BUTTON}) or_return
	return nil
}

pump :: proc(n := 15) {
	for _ in 0 ..< n {
		sciter_app.run_once()
	}
}

main :: proc() {
	if !sciter_app.load_engine() {
		os.exit(1)
	}
	sciter_app.set_default_debug_output()

	if err := sciter_app.init(); err != nil {
		fmt.eprintln("init failed:", err)
		os.exit(1)
	}

	window, werr := sciter_app.create_window({width = 620, height = 560})
	if werr != nil {
		fmt.eprintln("could not create a window:", werr)
		os.exit(1)
	}
	if err := sciter_app.load_html(window, DOC, "file://./examples/assets/"); err != nil {
		fmt.eprintln("could not load the document:", err)
		os.exit(1)
	}
	sciter_app.show(window)
	pump(30) // let the first frame happen, so layout is real before anything is aimed at it

	root, _ := sciter_app.root(window)
	button, _ := sciter_app.select_first(root, "#go")
	name, _ := sciter_app.select_first(root, "#name")
	agree, _ := sciter_app.select_first(root, "#agree")
	scroller, _ := sciter_app.select_first(root, "#scroller")
	bar, _ := sciter_app.select_first(root, "#bar")

	watch := new(Watch)
	watch.subscription = {.BEHAVIOR_EVENT, .FOCUS}
	watch.on_event = on_event
	watch.element = bar
	sciter_app.attach_window_handler(window, watch)

	// `.SCROLL` and `.ATTRIBUTE_CHANGE` are delivered only to handlers on the element itself, so they
	// need their own attachment rather than the window one.
	on_scroller := new(Watch)
	on_scroller.subscription = {.SCROLL, .ATTRIBUTE_CHANGE, .DATA_ARRIVED}
	on_scroller.on_event = on_event
	sciter_app.attach_handler(scroller, on_scroller)

	// --- the mouse ------------------------------------------------------------------------------

	at := centre(button)
	fmt.printfln("pressing #go at %v (the window's client coordinates)", at)
	click_at(button, at)
	pump()
	fmt.printfln("  BUTTON_CLICKs seen: %d", watch.clicks)

	// The point could equally have come from a hit test, which is the automation shape: find what is
	// at a coordinate, then aim at it.
	if hit, err := sciter_app.element_at(window, at); err == nil {
		tag, _ := sciter_app.tag(hit)
		fmt.printfln("  element_at(%v) -> <%s>", at, tag)
	}

	before, _ := sciter_app.state(agree)
	click_at(agree, centre(agree))
	pump()
	after, _ := sciter_app.state(agree)
	fmt.printfln("checkbox :checked %v -> %v", .CHECKED in before, .CHECKED in after)

	// Without a button in the set the event is delivered and the behavior ignores it.
	was, _ := sciter_app.send_mouse(agree, .MOUSE_DOWN, centre(agree), {})
	sciter_app.send_mouse(agree, .MOUSE_UP, centre(agree), {})
	pump()
	unchanged, _ := sciter_app.state(agree)
	fmt.printfln("  no button in the set: processed=%v, :checked still %v", was, .CHECKED in unchanged)

	// --- the keyboard ---------------------------------------------------------------------------

	sciter_app.set_focus(name)
	pump()
	sciter_app.send_text(name, " hello")
	pump()

	typed, _ := sciter_app.element_value(name)
	defer sciter_app.value_clear(&typed)
	s, _ := sciter_app.value_to_string(&typed, context.temp_allocator)
	fmt.printfln(
		"typed into #name -> %q (%d VALUE_CHANGEDs, %d focus gains)",
		s,
		watch.value_changes,
		watch.focus_gained,
	)

	// --- the element's script object ------------------------------------------------------------

	expando, eerr := sciter_app.expando(name)
	defer sciter_app.value_clear(&expando)
	if eerr == nil {
		// A number written from Odin, read by script.
		mark := sciter_app.value_from(i32(7))
		defer sciter_app.value_clear(&mark)
		sciter_app.value_set(&expando, "odin_rank", &mark)

		back, _ := sciter_app.eval(window, "String(document.$('#name').odin_rank)")
		bs, _ := sciter_app.value_to_string(&back, context.temp_allocator)
		sciter_app.value_clear(&back)
		fmt.printfln("wrote #name.odin_rank = 7 through the expando; script reads %q", bs)

		// A *string* has to go the other way round: `value_set` of one into an element's object does
		// not survive on this engine - see the note on `expando`. One line of script does it properly.
		sciter_app.eval_element(name, `this.odin_note = "set by Odin"`)
		note, _ := sciter_app.value_get(&expando, "odin_note")
		ns, _ := sciter_app.value_to_string(&note, context.temp_allocator)
		sciter_app.value_clear(&note)
		fmt.printfln("set #name.odin_note through script; Odin reads it back as %q", ns)
	}

	// A function the document defined, reached from an element rather than the window.
	shout, serr := sciter_app.call_function(name, "shout", sciter_app.value_from("quiet"))
	defer sciter_app.value_clear(&shout)
	ss, _ := sciter_app.value_to_string(&shout, context.temp_allocator)
	fmt.printfln("call_function(el, \"shout\", \"quiet\") -> %q (%v)", ss, serr)

	// --- scrolling and attributes ---------------------------------------------------------------

	sciter_app.set_scroll_pos(scroller, {0, 40})
	pump()
	sciter_app.set_attribute(scroller, "data-scrolled", "yes")
	pump()
	fmt.printfln(
		"scroll events: %d, attribute changes: %d (last %s)",
		on_scroller.scrolls,
		on_scroller.attr_changes,
		on_scroller.last_attr,
	)

	// --- animation frames -----------------------------------------------------------------------

	// One request starts it; the handler returning true keeps it going, frame by frame, until it says
	// otherwise. This grows the bar to 240px over 30 frames and then stops on its own.
	//
	// The frame event reaches handlers on the element only, so the animation needs its own attachment
	// rather than the window one.
	frames := new(Watch)
	frames.subscription = {.BEHAVIOR_EVENT}
	frames.on_event = on_event
	frames.element = bar
	frames.animating = true
	sciter_app.attach_handler(bar, frames)

	sciter_app.request_animation_frame(bar, TICK)
	deadline := time.now()
	for frames.ticks < 30 && time.since(deadline) < 3 * time.Second {
		sciter_app.set_style(bar, "width", fmt.tprintf("%dpx", 8 * frames.ticks))
		sciter_app.run_once()
	}
	fmt.printfln("animation frames delivered: %d (the handler stopped it by returning false)", frames.ticks)

	// --- URLs and loading -----------------------------------------------------------------------

	full, _ := sciter_app.combine_url(scroller, "hello.htm", context.temp_allocator)
	fmt.printfln("combine_url(el, \"hello.htm\") -> %q", full)

	if err := sciter_app.request_element_data(scroller, full, .HTML, button); err == nil {
		waited := time.now()
		for on_scroller.data_bytes == 0 && time.since(waited) < 2 * time.Second {
			sciter_app.run_once()
			sciter_app.heartbeat()
		}
		fmt.printfln("request_element_data -> %d bytes, status %d", on_scroller.data_bytes, on_scroller.data_status)
	}

	caps, _ := sciter_app.graphics_caps()
	out, _ := sciter_app.select_first(root, "#out")
	sciter_app.set_html(
		out,
		fmt.tprintf(
			"clicks %d &middot; value changes %d &middot; scrolls %d<br>frames %d &middot; graphics caps 0x%X",
			watch.clicks,
			watch.value_changes,
			on_scroller.scrolls,
			frames.ticks,
			caps,
		),
	)

	sciter_app.run()
	sciter_app.shutdown()
}

// ---------------------------------------------------------------------------------------------------
// Tests

// **macOS: the engine's AppKit singleton has to be built on the main thread.** Odin's test runner runs
// every test on a `thread.Pool` worker, at any `ODIN_TEST_THREADS` count, and the first engine call
// from one aborts the process in `-[NSApplication setMainMenu:]`. `@(init)` procedures do run on the
// main thread, before the runner starts, so the singleton is built there and every later
// `sciter_app.init()` is a no-op (`g_initialized` in sciter_app/app.odin). Test binaries only: a normal
// build reaches the engine from `main`, which is the main thread by definition. See
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
	}
}

@(private = "file")
have_display :: proc() -> bool {
	when ODIN_OS == .Windows {
		// DISPLAY and WAYLAND_DISPLAY are X11/Wayland variables and are simply absent here, so testing
		// for them would skip every windowed test on this platform forever - silently, which is the
		// worst way for a test to not run. A desktop session is the normal case, and one that genuinely
		// cannot open a window fails visibly at create_window instead.
		return true
	} else when ODIN_OS == .Darwin {
		// **macOS has a display, and a test still cannot use it.** AppKit refuses to instantiate an
		// NSWindow anywhere but the main thread, and Odin's test runner always runs tests on a pool
		// worker - so create_window from a test aborts the whole process with
		//
		//	'NSWindow should only be instantiated on the main thread!'
		//
		// Nothing moves a test onto the main thread, so the windowed tests skip here and this example is
		// covered by being run as a *program* instead. Tests needing no window are unaffected - see
		// docs/MACOS-CHECKLIST.md section 2. `ODIN_TEST` keeps this out of a normal build, where `main`
		// is the main thread and windows are created correctly by construction.
		when ODIN_TEST {
			fmt.println("macOS: a test thread cannot create a window - see docs/MACOS-CHECKLIST.md")
			return false
		} else {
			return true
		}
	} else {
		if os.get_env("DISPLAY", context.temp_allocator) != "" ||
		   os.get_env("WAYLAND_DISPLAY", context.temp_allocator) != "" {
			return true
		}
		fmt.println("no DISPLAY or WAYLAND_DISPLAY")
		return false
	}
}

@(private = "file")
// Shared by every test in this file, and created on first use. That is deliberate - a window per test
// would be slow, and closing one is itself hazardous (see `close` in sciter_app/window.odin) - but it
// makes the tests here order-coupled: **a test that changes the document must put it back**, usually by
// reloading `DOC`, or it breaks a later test and the failure points at the wrong one.
g_window: sciter_app.Window

// Input needs a laid-out document to aim at, so unlike the other examples' helpers this one shows the
// window and lets a few frames happen before handing it over.
@(private = "file")
test_window :: proc(t: ^testing.T) -> (window: sciter_app.Window, root: sciter_app.Element, ok: bool) {
	if !have_display() {
		fmt.println("skipping - this test needs a window")
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

	if g_window == nil {
		// The engine keeps the argv and the window for the life of the process; allocating them outside
		// the test runner's tracking allocator keeps them from being reported as leaks.
		context.allocator = runtime.default_allocator()

		sciter_app.init()

		w, err := sciter_app.create_window({width = 500, height = 460})
		testing.expect_value(t, err, nil)
		if w == nil {
			return nil, nil, false
		}
		g_window = w
		sciter_app.show(w)
	}

	testing.expect_value(t, sciter_app.load_html(g_window, DOC), nil)
	pump(20)
	r, rerr := sciter_app.root(g_window)
	testing.expect_value(t, rerr, nil)
	return g_window, r, true
}

@(test)
test_send_mouse_presses_a_button :: proc(t: ^testing.T) {
	window, root, ok := test_window(t)
	if !ok {return}

	watch := Watch {
		subscription = {.BEHAVIOR_EVENT},
		on_event     = on_event,
	}
	testing.expect_value(t, sciter_app.attach_window_handler(window, &watch), nil)
	defer sciter_app.detach_window_handler(window, &watch)

	button, _ := sciter_app.select_first(root, "#go")
	at := centre(button)

	processed, err := sciter_app.send_mouse(button, .MOUSE_DOWN, at, {.MAIN_MOUSE_BUTTON})
	testing.expect_value(t, err, nil)
	testing.expect(t, processed, "the button behavior acted on the press")

	state, _ := sciter_app.element_state(button)
	testing.expect(t, .ACTIVE in state, "the button is :active while held")

	up, uerr := sciter_app.send_mouse(button, .MOUSE_UP, at, {.MAIN_MOUSE_BUTTON})
	testing.expect_value(t, uerr, nil)
	testing.expect(t, up, "the release was acted on too")

	pump()
	testing.expect_value(t, watch.clicks, 1)
}

@(test)
test_a_press_without_a_button_does_nothing :: proc(t: ^testing.T) {
	window, root, ok := test_window(t)
	if !ok {return}

	watch := Watch {
		subscription = {.BEHAVIOR_EVENT},
		on_event     = on_event,
	}
	sciter_app.attach_window_handler(window, &watch)
	defer sciter_app.detach_window_handler(window, &watch)

	agree, _ := sciter_app.select_first(root, "#agree")
	at := centre(agree)

	// Measured: the event is delivered - handlers see a MOUSE_DOWN - and the behavior ignores it,
	// which is why `buttons` is not optional in practice.
	processed, err := sciter_app.send_mouse(agree, .MOUSE_DOWN, at, {})
	testing.expect_value(t, err, nil)
	testing.expect(t, !processed, "no button in the set, so nothing acted")
	sciter_app.send_mouse(agree, .MOUSE_UP, at, {})
	pump()

	state, _ := sciter_app.element_state(agree)
	testing.expect(t, .CHECKED not_in state, ":checked is untouched")
	testing.expect_value(t, watch.clicks, 0)
}

@(test)
test_send_mouse_toggles_a_checkbox :: proc(t: ^testing.T) {
	_, root, ok := test_window(t)
	if !ok {return}

	agree, _ := sciter_app.select_first(root, "#agree")
	before, _ := sciter_app.element_state(agree)
	testing.expect(t, .CHECKED not_in before, "starts unticked")

	testing.expect_value(t, click_at(agree, centre(agree)), nil)
	pump()

	after, _ := sciter_app.element_state(agree)
	testing.expect(t, .CHECKED in after, "a synthesised click ticked it, behavior and all")
}

@(test)
test_send_mouse_needs_a_target :: proc(t: ^testing.T) {
	_, _, ok := test_window(t)
	if !ok {return}

	// There is no hit testing inside the call: the element is named, not found. `element_at` is the
	// way from a point to an element.
	_, err := sciter_app.send_mouse(nil, .MOUSE_DOWN, {10, 10}, {.MAIN_MOUSE_BUTTON})
	testing.expect_value(t, err, sciter_app.Error(sciter.Scdom_Result.INVALID_HANDLE))

	_, kerr := sciter_app.send_key(nil, .CHAR, 'x')
	testing.expect_value(t, kerr, sciter_app.Error(sciter.Scdom_Result.INVALID_HANDLE))
}

@(test)
test_send_text_types_into_an_input :: proc(t: ^testing.T) {
	window, root, ok := test_window(t)
	if !ok {return}

	watch := Watch {
		subscription = {.BEHAVIOR_EVENT},
		on_event     = on_event,
	}
	sciter_app.attach_window_handler(window, &watch)
	defer sciter_app.detach_window_handler(window, &watch)

	name, _ := sciter_app.select_first(root, "#name")
	testing.expect_value(t, sciter_app.set_focus(name), nil)
	pump()

	testing.expect_value(t, sciter_app.send_text(name, "XY"), nil)
	pump()

	value, err := sciter_app.element_value(name)
	defer sciter_app.value_clear(&value)
	testing.expect_value(t, err, nil)
	s, _ := sciter_app.value_to_string(&value, context.temp_allocator)

	// The caret starts at the beginning of an unfocused-until-now field, so the characters land in
	// front of what was there. What matters is that they landed at all, through the edit behavior.
	testing.expectf(t, len(s) == len("typed:") + 2, "expected two more characters, got %q", s)
	testing.expect(t, watch.value_changes >= 2, "the edit behavior raised VALUE_CHANGED per character")
}

@(test)
test_focus_events :: proc(t: ^testing.T) {
	window, root, ok := test_window(t)
	if !ok {return}

	watch := Watch {
		subscription = {.FOCUS},
		on_event     = on_event,
	}
	sciter_app.attach_window_handler(window, &watch)
	defer sciter_app.detach_window_handler(window, &watch)

	name, _ := sciter_app.select_first(root, "#name")
	button, _ := sciter_app.select_first(root, "#go")

	sciter_app.set_focus(name)
	pump()
	sciter_app.set_focus(button)
	pump()

	testing.expect(t, watch.focus_gained >= 2, "two moves, two .GOT events")

	holder, err := sciter_app.focus_element(window)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, rawptr(holder), rawptr(button))
}

@(test)
test_scroll_and_attribute_events_reach_the_element_only :: proc(t: ^testing.T) {
	window, root, ok := test_window(t)
	if !ok {return}

	scroller, _ := sciter_app.select_first(root, "#scroller")

	on_element := Watch {
		subscription = {.SCROLL, .ATTRIBUTE_CHANGE},
		on_event     = on_event,
	}
	on_window := Watch {
		subscription = {.SCROLL, .ATTRIBUTE_CHANGE},
		on_event     = on_event,
	}
	testing.expect_value(t, sciter_app.attach_handler(scroller, &on_element), nil)
	defer sciter_app.detach_handler(scroller, &on_element)
	testing.expect_value(t, sciter_app.attach_window_handler(window, &on_window), nil)
	defer sciter_app.detach_window_handler(window, &on_window)

	testing.expect_value(t, sciter_app.set_scroll_pos(scroller, {0, 40}), nil)
	pump()
	testing.expect_value(t, sciter_app.set_attribute(scroller, "data-x", "1"), nil)
	pump()

	testing.expect(t, on_element.scrolls > 0, "the scrolling element heard about it")
	testing.expect_value(t, on_element.attr_changes, 1)
	testing.expect_value(t, on_element.last_attr, "data-x=1")

	// Measured, and the reason both accessors say so: neither group bubbles to a window handler.
	testing.expect_value(t, on_window.scrolls, 0)
	testing.expect_value(t, on_window.attr_changes, 0)

	// Removing an attribute arrives as an empty value rather than a separate code.
	testing.expect_value(t, sciter_app.set_attribute(scroller, "data-x", ""), nil)
	pump()
	testing.expect_value(t, on_element.attr_changes, 2)
	testing.expect_value(t, on_element.last_attr, "data-x=")
	delete(on_element.last_attr)
}

@(test)
test_animation_frame_is_one_shot :: proc(t: ^testing.T) {
	_, root, ok := test_window(t)
	if !ok {return}

	bar, _ := sciter_app.select_first(root, "#bar")
	watch := Watch {
		subscription = {.BEHAVIOR_EVENT},
		on_event     = on_event,
		element      = bar,
	}
	testing.expect_value(t, sciter_app.attach_handler(bar, &watch), nil)
	defer sciter_app.detach_handler(bar, &watch)

	testing.expect_value(t, sciter_app.request_animation_frame(bar, TICK), nil)

	deadline := time.now()
	for watch.ticks == 0 && time.since(deadline) < 2 * time.Second {
		sciter_app.run_once()
	}
	testing.expect_value(t, watch.ticks, 1)

	// `animating` is false, so the handler returned false, so that was the last frame. The return
	// value is the whole mechanism - it does not re-arm on its own.
	pump(60)
	testing.expect_value(t, watch.ticks, 1)

	// And it needs an element.
	testing.expect_value(
		t,
		sciter_app.request_animation_frame(nil, TICK),
		sciter_app.Error(sciter.Scdom_Result.INVALID_HANDLE),
	)
}

@(test)
test_expando_crosses_both_ways :: proc(t: ^testing.T) {
	window, root, ok := test_window(t)
	if !ok {return}

	name, _ := sciter_app.select_first(root, "#name")

	expando, err := sciter_app.expando(name)
	defer sciter_app.value_clear(&expando)
	testing.expect_value(t, err, nil)

	// Odin writes a number, script reads it. (A *string* does not survive `value_set` here - see the
	// note on `expando`; the test below covers the route that works.)
	rank := sciter_app.value_from(i32(7))
	defer sciter_app.value_clear(&rank)
	testing.expect_value(t, sciter_app.value_set(&expando, "odin_rank", &rank), nil)

	seen, eerr := sciter_app.eval(window, "String(document.$('#name').odin_rank)")
	defer sciter_app.value_clear(&seen)
	testing.expect_value(t, eerr, nil)
	s, _ := sciter_app.value_to_string(&seen, context.temp_allocator)
	testing.expect_value(t, s, "7")

	// Script writes, Odin reads - a number and a string, both intact.
	sciter_app.eval(window, `document.$("#name").script_note = 41 + 1`)
	back, berr := sciter_app.value_get(&expando, "script_note")
	defer sciter_app.value_clear(&back)
	testing.expect_value(t, berr, nil)
	n, _ := sciter_app.value_to_int(&back)
	testing.expect_value(t, n, 42)

	// The supported way to put a string there, and it reads back through the same expando.
	//
	// The result is cleared rather than dropped: an assignment expression evaluates to the assigned
	// value, so this `eval_element` hands back a STRING that owns a reference like any other.
	assigned, serr := sciter_app.eval_element(name, `this.odin_note = "set by Odin"`)
	defer sciter_app.value_clear(&assigned)
	testing.expect_value(t, serr, nil)
	note, nerr := sciter_app.value_get(&expando, "odin_note")
	defer sciter_app.value_clear(&note)
	testing.expect_value(t, nerr, nil)
	ns, nserr := sciter_app.value_to_string(&note, context.temp_allocator)
	testing.expect_value(t, nserr, nil)
	testing.expect_value(t, ns, "set by Odin")

	// A detached element has no document and so no object.
	orphan_owned, _ := sciter_app.make_element("div")
	orphan := sciter_app.borrow_element(orphan_owned)
	defer sciter_app.unuse_element(orphan_owned)
	_, oerr := sciter_app.expando(orphan)
	testing.expect_value(t, oerr, sciter_app.Error(sciter.Scdom_Result.INVALID_HANDLE))
}

@(test)
test_call_function_finds_what_call_method_cannot :: proc(t: ^testing.T) {
	_, root, ok := test_window(t)
	if !ok {return}

	name, _ := sciter_app.select_first(root, "#name")

	result, err := sciter_app.call_function(name, "shout", sciter_app.value_from("quiet"))
	defer sciter_app.value_clear(&result)
	testing.expect_value(t, err, nil)
	s, _ := sciter_app.value_to_string(&result, context.temp_allocator)
	testing.expect_value(t, s, "QUIET!")

	// The same name through `call_method`, which looks for a method *on the element*, does not resolve.
	bad, berr := sciter_app.call_method(name, "shout", sciter_app.value_from("quiet"))
	sciter_app.value_clear(&bad)
	testing.expect(t, berr != nil, "a document function is not an element method")
}

@(test)
test_combine_url_resolves_against_the_document :: proc(t: ^testing.T) {
	window, ok := g_window, true
	_, root, ok2 := test_window(t)
	if !ok2 {return}
	_, _ = window, ok

	// A base is needed for a relative reference to resolve to anything, and `load_html` above was
	// given none - so this test loads its own document with one.
	testing.expect_value(t, sciter_app.load_html(g_window, DOC, "file:///base/dir/"), nil)
	pump(10)
	root, _ = sciter_app.root(g_window)
	el, _ := sciter_app.select_first(root, "#scroller")

	// **`file:` URLs come back with two slashes on Windows and three on Linux**, and the engine is
	// consistent about it rather than random: measured with `file:///C:/tmp/dir/` and `file://C:/tmp/dir/`
	// as bases, Windows normalises both to `file://C:/tmp/dir/...`. Its canonical `file:` form has no
	// empty authority. Nothing in the wrapper touches the string - `combine_url` is a straight
	// `SciterCombineURL` - so this is the engine's own resolution and the right thing to record rather
	// than to correct.
	//
	// The `/abs.css` row is where that consistency stops, and it is the same on both platforms: a
	// root-relative reference against a `file:` base produces three slashes even where the relative rows
	// produce two, and loses the drive letter doing it (`file:///C:/tmp/dir/` + `/abs.css` ->
	// `file:///abs.css`). Worth knowing before handing that result to the filesystem. `https:` bases are
	// unaffected throughout - the whole difference is the `file:` scheme.
	when ODIN_OS == .Windows {
		FILE_BASE :: "file://base/dir/"
		FILE_UP :: "file://base/up.css"
	} else {
		FILE_BASE :: "file:///base/dir/"
		FILE_UP :: "file:///base/up.css"
	}

	for pair in ([?][2]string {
			{"style.css", FILE_BASE + "style.css"},
			{"sub/a.png", FILE_BASE + "sub/a.png"},
			{"../up.css", FILE_UP},
			{"/abs.css", "file:///abs.css"}, // three slashes on both, and the drive letter is gone
			{"http://example.com/a.css", "http://example.com/a.css"}, // already absolute, untouched
			{"", FILE_BASE}, // the base itself
		}) {
		got, err := sciter_app.combine_url(el, pair[0], context.temp_allocator)
		testing.expect_value(t, err, nil)
		testing.expectf(t, got == pair[1], "combine_url(%q) = %q, want %q", pair[0], got, pair[1])
	}

	orphan_owned, _ := sciter_app.make_element("div")
	orphan := sciter_app.borrow_element(orphan_owned)
	defer sciter_app.unuse_element(orphan_owned)
	_, oerr := sciter_app.combine_url(orphan, "x.css", context.temp_allocator)
	testing.expect_value(t, oerr, sciter_app.Error(sciter.Scdom_Result.PASSIVE_HANDLE))
}

@(test)
test_request_element_data_delivers_to_the_element :: proc(t: ^testing.T) {
	_, root, ok := test_window(t)
	if !ok {return}

	scroller, _ := sciter_app.select_first(root, "#scroller")
	button, _ := sciter_app.select_first(root, "#go")

	watch := Watch {
		subscription = {.DATA_ARRIVED},
		on_event     = on_event,
	}
	testing.expect_value(t, sciter_app.attach_handler(scroller, &watch), nil)
	defer sciter_app.detach_handler(scroller, &watch)

	// This example's own source, which is certainly there and certainly not empty.
	testing.expect_value(t, sciter_app.request_element_data(scroller, "file://examples/input.odin", .RAW, button), nil)

	deadline := time.now()
	for watch.data_bytes == 0 && time.since(deadline) < 3 * time.Second {
		sciter_app.run_once()
		sciter_app.heartbeat()
	}
	testing.expect(t, watch.data_bytes > 0, "the bytes arrived as a .DATA_ARRIVED event")
	// Measured: a `file://` load that worked answers 0, not 200 - `status` is the HTTP code only when
	// there was an HTTP response. `len(data)` is the success test.
	testing.expect_value(t, watch.data_status, 0)

	// A failure is reported through the event too, not through the call.
	watch.data_bytes = 0
	testing.expect_value(t, sciter_app.request_element_data(scroller, "file:///no/such/file", .RAW), nil)
	fail_deadline := time.now()
	for watch.data_status == 0 && time.since(fail_deadline) < 3 * time.Second {
		sciter_app.run_once()
		sciter_app.heartbeat()
	}
	testing.expect_value(t, watch.data_bytes, 0)
	testing.expect(t, watch.data_status != 0, "a missing file arrives with a non-zero status")
}

@(test)
test_http_request_delivers_the_same_way :: proc(t: ^testing.T) {
	_, root, ok := test_window(t)
	if !ok {return}

	scroller, _ := sciter_app.select_first(root, "#scroller")

	watch := Watch {
		subscription = {.DATA_ARRIVED},
		on_event     = on_event,
	}
	testing.expect_value(t, sciter_app.attach_handler(scroller, &watch), nil)
	defer sciter_app.detach_handler(scroller, &watch)

	// A `file://` URL goes through `http_request` too, which is what makes it a superset of
	// `request_element_data`. No server is needed for that, so this test stays hermetic; the HTTP
	// behaviour itself - the query string a `.Get` builds, the `.Post` body, the status codes - was
	// measured against a real server and is written up on `http_request`.
	testing.expect_value(t, sciter_app.http_request(scroller, "file://examples/input.odin"), nil)

	deadline := time.now()
	for watch.data_bytes == 0 && time.since(deadline) < 3 * time.Second {
		sciter_app.run_once()
		sciter_app.heartbeat()
	}
	testing.expect(t, watch.data_bytes > 0, "the body arrived as a .DATA_ARRIVED event")

	// Parameters are accepted and encoded whether or not the scheme has anywhere to put them.
	watch.data_bytes = 0
	testing.expect_value(
		t,
		sciter_app.http_request(scroller, "file://examples/input.odin", .Get, {{"a", "1"}, {"b", "two words"}}),
		nil,
	)
	params_deadline := time.now()
	for watch.data_bytes == 0 && time.since(params_deadline) < 3 * time.Second {
		sciter_app.run_once()
		sciter_app.heartbeat()
	}

	// The same handle rules as everything else that takes an element.
	testing.expect_value(
		t,
		sciter_app.http_request(nil, "file://examples/input.odin"),
		sciter_app.Error(sciter.Scdom_Result.INVALID_HANDLE),
	)

	orphan_owned, _ := sciter_app.make_element("div")
	orphan := sciter_app.borrow_element(orphan_owned)
	defer sciter_app.unuse_element(orphan_owned)
	testing.expect_value(
		t,
		sciter_app.http_request(orphan, "file://examples/input.odin"),
		sciter_app.Error(sciter.Scdom_Result.PASSIVE_HANDLE),
	)
}

@(test)
test_graphics_caps :: proc(t: ^testing.T) {
	if !have_display() {
		fmt.println("skipping - this test needs the engine")
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
	caps, ok := sciter_app.graphics_caps()
	testing.expect(t, ok, "the engine reported its graphics capabilities")
	// Documented as an ordinal scale, not a bitmask - see `Graphics_Caps`. The vendored Linux build
	// answers `.Software`, which is the middle of the three.
	testing.expect_value(t, caps, sciter_app.Graphics_Caps.Software)
}
