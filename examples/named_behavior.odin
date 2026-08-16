// Named behaviors: letting the *document* ask for Odin code by name.
//
//   just example named_behavior
//   odin test examples/named_behavior.odin -file      # needs a display; skips itself without one
//
// The other examples attach handlers the other way round - the host picks an element and calls
// `attach_handler` on it. This is the document doing the asking:
//
//	div.gauge { behavior: my-gauge; }
//
// The engine meets a `behavior:` name it does not implement, sends the host `SC_ATTACH_BEHAVIOR`, and
// the host answers with an `Event_Handler`. It is the mechanism behind the SDK's C++ `behavior_factory`,
// and the reason it matters is that **a stylesheet decides which elements get a widget**. Adding a
// third gauge is a CSS selector, not a call site; a document loaded from an archive can wire itself up
// to native code it has never been introduced to.
//
// Six things were measured on the vendored 6.0.4.9 engine before this was written, and the tests below
// pin all of them:
//
//   1. The request arrives *inside* `load_html`, before it returns - so `set_host_handler` has to be in
//      place first, the same rule `on_load_data` already has.
//   2. One request per name per element. `behavior: my-gauge my-logger` produces two, both for the same
//      element, and both handlers attach.
//   3. An intrinsic name never reaches the host. `behavior: button` produces no request at all and the
//      element becomes a real button - this cannot override what the engine already implements.
//   4. Elements created after the load are asked about too.
//   5. The notification's return value is ignored; handing back a handler is what attaches it.
//   6. There is no "behavior destroyed" notification. `Initialization_Events.DETACH` is the only place
//      a handler can free itself, and it arrives both when the element is removed and when the document
//      is replaced.
//
// The two widgets here are deliberately different in kind: `my-gauge` draws itself and owns state,
// `my-logger` only watches. Both are ordinary `Event_Handler`s, so every accessor in `events.odin`
// works on them unchanged.
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
  html   { background: #1e1e2e; color: #cdd6f4; font: 16px system; }
  body   { padding: 1.5em; margin: 0; }
  h1     { color: #89b4fa; margin: 0 0 .6em 0; }
  p      { margin: .3em 0; color: #a6adc8; }

  /* The whole point: which elements are widgets is a stylesheet decision. */
  .gauge   { behavior: my-gauge; display: block; height: 34px; margin: .5em 0;
             background: #313244; border-radius: 4px; }
  .watched { behavior: my-logger; }
  .both    { behavior: my-gauge my-logger; }

  #plain   { behavior: button; }          /* intrinsic - never reaches the host */
  #nobody  { behavior: nobody-claims-me; }/* reaches the host, host passes */

  #out   { margin-top: 1em; padding: .6em 1em; background: #313244; border-radius: 4px;
           font: 14px monospace; white-space: pre-wrap; }
</style></head>
<body>
  <h1>named behaviors</h1>
  <p>every element below is wired to Odin by its CSS, not by a call site</p>

  <div class="gauge"   id="g1"></div>
  <div class="gauge"   id="g2"></div>
  <div class="both"    id="g3"></div>
  <div class="watched" id="w1">a plain div the logger is watching</div>
  <button id="plain">an intrinsic button</button>
  <div id="nobody">nobody claims this behavior</div>

  <div id="out">(Odin fills this in)</div>
</body>
</html>`

// ---------------------------------------------------------------------------------------------------
// Two widgets
//
// A behavior handler is an ordinary `Event_Handler` with one extra obligation: it was allocated by the
// factory, so it has to free itself when the engine lets go of it.

// Draws a bar whose fill follows the mouse, and remembers where it was left.
Gauge :: struct {
	using handler: sciter_app.Event_Handler,
	app:           ^App,
	element:       sciter_app.Element,
	level:         int, // 0..100
	attached:      bool,
	detached:      bool,
}

on_gauge_event :: proc(h: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	gauge := (^Gauge)(h)

	// `HANDLE_INITIALIZATION` is 0x0000 upstream, so the group is the *empty* bit_set - not a bit of
	// its own. That is easy to read past in the header and is why this test is not `.INITIALIZATION`.
	if event.group == {} && event.params != nil {
		switch sciter.Initialization_Events((^sciter.Initialization_Params)(event.params).cmd) {
		case .ATTACH:
			gauge.attached = true
			gauge.element = event.element
			gauge.app.live += 1
			gauge_draw(gauge)
		case .DETACH:
			// The only hook there is. Nothing else tells a behavior it is finished.
			gauge.detached = true
			gauge.app.live -= 1
			gauge.app.freed += 1
			free(gauge, gauge.app.allocator)
		}
		return false
	}

	if me, ok := sciter_app.mouse_event(event); ok && me.code == .MOUSE_MOVE {
		// `Mouse_Event.pos` is already relative to the element the handler is on, so the gauge needs
		// only its own width to turn it into a percentage.
		box, err := sciter_app.location(gauge.element, .Border, .View)
		if err != nil || box.width == 0 {
			return false
		}
		gauge.level = clamp(int(me.pos.x * 100 / box.width), 0, 100)
		gauge_draw(gauge)
		return false
	}
	return false
}

gauge_draw :: proc(gauge: ^Gauge) {
	// A widget that owns its own presentation. Inline style rather than markup, so nothing it does can
	// be an injection and the element keeps its identity across updates.
	sciter_app.set_style(
		gauge.element,
		"background-image",
		fmt.tprintf("linear-gradient(to right, #89b4fa %d%%, #313244 %d%%)", gauge.level, gauge.level),
	)
	sciter_app.set_text(gauge.element, fmt.tprintf("  %d%%", gauge.level))
}

// Counts what passes through, and nothing else - the "watch an element the document chose" case.
Logger :: struct {
	using handler: sciter_app.Event_Handler,
	app:           ^App,
	seen:          int,
	detached:      bool,
}

on_logger_event :: proc(h: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	logger := (^Logger)(h)
	if event.group == {} && event.params != nil {
		if sciter.Initialization_Events((^sciter.Initialization_Params)(event.params).cmd) == .DETACH {
			logger.detached = true
			logger.app.live -= 1
			logger.app.freed += 1
			free(logger, logger.app.allocator)
		} else {
			logger.app.live += 1
		}
		return false
	}
	logger.seen += 1
	return false
}

// ---------------------------------------------------------------------------------------------------
// The factory

App :: struct {
	using host:    sciter_app.Host_Handler,
	allocator:     runtime.Allocator,

	// Book-keeping the tests read. `live` is what proves the .DETACH path actually runs: it goes back
	// to zero when the document is replaced.
	requested:     [dynamic]string, // every name the engine asked about, in order
	claimed:       int,
	passed:        int,
	live:          int,
	freed:         int,

	// The rest of the notification family, for the tests at the bottom.
	invalidations: int,
	last_invalid:  sciter.Rect,
	keyboard_rqs:  int,
	keyboard_kind: string,
	cursor_rqs:    int,
}

// The one procedure that matters. The engine asks "who is `my-gauge`?" and this answers.
on_attach_behavior :: proc(
	h: ^sciter_app.Host_Handler,
	request: ^sciter_app.Behavior_Request,
) -> ^sciter_app.Event_Handler {
	app := (^App)(h)
	// `request.name` lives in the callback's temp allocator, so anything kept has to be cloned.
	append(&app.requested, fmt.aprint(request.name, allocator = app.allocator))

	switch request.name {
	case "my-gauge":
		app.claimed += 1
		gauge := new(Gauge, app.allocator)
		gauge.app = app
		gauge.subscription = {.MOUSE}
		gauge.on_event = on_gauge_event
		return gauge

	case "my-logger":
		app.claimed += 1
		logger := new(Logger, app.allocator)
		logger.app = app
		logger.subscription = {.MOUSE, .BEHAVIOR_EVENT}
		logger.on_event = on_logger_event
		return logger
	}

	// Not ours. The element simply gets no behavior; this is not an error.
	app.passed += 1
	return nil
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

	window, werr := sciter_app.create_window({width = 620, height = 520})
	if werr != nil {
		fmt.eprintln("could not create a window:", werr)
		os.exit(1)
	}

	app := new(App)
	app.allocator = context.allocator
	app.on_attach_behavior = on_attach_behavior
	app.on_invalidate_rect = proc(h: ^sciter_app.Host_Handler, w: sciter_app.Window, rect: sciter.Rect) {
		a := (^App)(h)
		a.invalidations += 1
		a.last_invalid = rect
	}
	app.on_keyboard_request = proc(h: ^sciter_app.Host_Handler, w: sciter_app.Window, kind: string) {
		a := (^App)(h)
		a.keyboard_rqs += 1
		a.keyboard_kind = fmt.aprint(kind, allocator = a.allocator)
	}
	app.on_set_cursor = proc(h: ^sciter_app.Host_Handler, w: sciter_app.Window, id: u32, url: string) {
		(^App)(h).cursor_rqs += 1
	}

	// Before the load, not after: the requests arrive while `load_html` is still running.
	sciter_app.set_host_handler(window, app)

	if err := sciter_app.load_html(window, DOC); err != nil {
		fmt.eprintln("could not load the document:", err)
		os.exit(1)
	}

	fmt.println("names the engine asked about, in order:")
	for name in app.requested {
		fmt.printfln("  %q", name)
	}
	fmt.printfln("claimed %d, passed %d, live %d", app.claimed, app.passed, app.live)

	// The intrinsic one never came past, and is a real button regardless.
	root, _ := sciter_app.root(window)
	plain, _ := sciter_app.select_first(root, "#plain")
	type, _ := sciter_app.control_type(plain)
	fmt.printfln("#plain control_type = %v (the host was never asked about `button`)", type)

	out, _ := sciter_app.select_first(root, "#out")
	sciter_app.set_text(
		out,
		fmt.tprintf(
			"%d behaviors requested, %d claimed by Odin, %d passed on.\nmove the mouse across a bar.",
			len(app.requested),
			app.claimed,
			app.passed,
		),
	)

	sciter_app.show(window)

	// Let the window get on screen and paint, then report the rest of the notification family - which
	// the App above also wired up. Printed rather than asserted; the note at the bottom says why.
	for _ in 0 ..< 50 {
		sciter_app.run_once()
	}
	fmt.printfln(
		"notifications so far: %d invalidate_rect (last %v), %d keyboard_request %q, %d set_cursor",
		app.invalidations,
		app.last_invalid,
		app.keyboard_rqs,
		app.keyboard_kind,
		app.cursor_rqs,
	)

	sciter_app.run()
	sciter_app.shutdown()
}

// ---------------------------------------------------------------------------------------------------
// Tests
//
// These need a window: a behavior is attached by the engine while a document loads, and there is no
// way to produce one without a document. They skip themselves where there is no display.
// `ODIN_TEST_THREADS=1` is required - see the `example-tests` recipe.

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

		// And forget the thread that just armed rule 1. That thread is `main`, every test runs on a
		// `thread.Pool` worker, and the guard would trap each one on its first engine call. The split is
		// real and unavoidable - AppKit wants main for the singleton, the runner wants a worker for the
		// tests - so what re-arming buys is the rest of the rule: the first test call arms the worker,
		// and a later call from anywhere else still traps. docs/MACOS-CHECKLIST.md section 2 has why.
		// The guard's *other* Darwin rule - that the engine's thread is the main thread - turns itself
		// off under `ODIN_TEST`, so it needs nothing here.
		sciter_app.check_thread_affinity()
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
g_view: sciter_app.Windowless_View

// A fresh App per test, with the document loaded under it. The App is deliberately *not* freed: the
// engine holds its address as the callback parameter for the life of the window.
@(private = "file")
test_app :: proc(t: ^testing.T, doc := DOC) -> (app: ^App, root: sciter_app.Element, ok: bool) {
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
		v, err := sciter_app.create_windowless({width = 500, height = 400})
		testing.expect_value(t, err, nil)
		if v.window == nil {
			return nil, nil, false
		}
		g_view = v
	}

	app = new(App)
	app.allocator = context.allocator
	app.on_attach_behavior = on_attach_behavior
	sciter_app.set_host_handler(g_view.window, app)

	testing.expect_value(t, sciter_app.load_html(g_view.window, doc), nil)
	r, rerr := sciter_app.root(g_view.window)
	testing.expect_value(t, rerr, nil)
	return app, r, true
}

// Rule 1: the requests land during `load_html`, not on some later turn of the pump. A handler
// installed after the load would see nothing at all, which is the mistake this pins.
@(test)
test_requests_arrive_during_load :: proc(t: ^testing.T) {
	app, _, ok := test_app(t)
	if !ok {return}

	// No pumping between `load_html` returning and this line.
	testing.expect(t, len(app.requested) > 0, "the engine asked before load_html returned")
	testing.expect(t, app.claimed > 0, "and handlers were attached by then")
}

// Rule 2: one request per name per element, and `behavior: a b` gives both.
@(test)
test_one_request_per_name_per_element :: proc(t: ^testing.T) {
	app, _, ok := test_app(t)
	if !ok {return}

	gauges, loggers, unclaimed := 0, 0, 0
	for name in app.requested {
		switch name {
		case "my-gauge":
			gauges += 1
		case "my-logger":
			loggers += 1
		case "nobody-claims-me":
			unclaimed += 1
		}
	}
	// #g1, #g2 and #g3 (.both) carry my-gauge; #w1 and #g3 carry my-logger.
	testing.expect_value(t, gauges, 3)
	testing.expect_value(t, loggers, 2)
	testing.expect_value(t, unclaimed, 1)
	testing.expect_value(t, app.claimed, 5)
	testing.expect_value(t, app.passed, 1)
}

// Rule 3: the engine keeps its own names. This is the one that decides whether a `behavior:` name of
// your own can shadow a built-in - it cannot.
@(test)
test_intrinsic_names_never_reach_the_host :: proc(t: ^testing.T) {
	app, root, ok := test_app(t)
	if !ok {return}

	for name in app.requested {
		testing.expectf(t, name != "button", "the host was not asked about `button`, got %q", name)
	}

	plain, err := sciter_app.select_first(root, "#plain")
	testing.expect_value(t, err, nil)
	type, terr := sciter_app.control_type(plain)
	testing.expect_value(t, terr, nil)
	testing.expect_value(t, type, sciter.Ctl_Type.BUTTON)
}

// Passing on a name is not an error: the element loads, it simply has no behavior.
@(test)
test_an_unclaimed_name_is_not_an_error :: proc(t: ^testing.T) {
	app, root, ok := test_app(t)
	if !ok {return}

	testing.expect_value(t, app.passed, 1)

	nobody, err := sciter_app.select_first(root, "#nobody")
	testing.expect_value(t, err, nil)
	type, _ := sciter_app.control_type(nobody)
	testing.expect_value(t, type, sciter.Ctl_Type.NO)

	text, terr := sciter_app.text(nobody, context.temp_allocator)
	testing.expect_value(t, terr, nil)
	testing.expect_value(t, text, "nobody claims this behavior")
}

// The handler really is attached, not merely constructed: it received `.ATTACH` and knows its element.
@(test)
test_the_handler_is_attached_to_its_element :: proc(t: ^testing.T) {
	app, root, ok := test_app(t)
	if !ok {return}

	testing.expect_value(t, app.live, 5)

	// The gauge drew itself from `.ATTACH`, so the element already carries its work.
	g1, err := sciter_app.select_first(root, "#g1")
	testing.expect_value(t, err, nil)
	text, terr := sciter_app.text(g1, context.temp_allocator)
	testing.expect_value(t, terr, nil)
	testing.expect_value(t, text, "  0%")
}

// Rule 4: a document that grows is covered too.
@(test)
test_elements_created_later_are_asked_about :: proc(t: ^testing.T) {
	app, root, ok := test_app(t)
	if !ok {return}

	before := len(app.requested)
	body, _ := sciter_app.select_first(root, "body")

	el_owned, err := sciter_app.make_element("div", "")
	el := sciter_app.borrow_element(el_owned)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, sciter_app.set_attribute(el, "style", "behavior: my-gauge"), nil)
	testing.expect_value(t, sciter_app.insert_element(el, body), nil) // nil index: append
	sciter_app.windowless_heartbeat(&g_view, 16 * time.Millisecond)

	testing.expectf(t, len(app.requested) == before + 1, "one more request, got %d", len(app.requested) - before)
	testing.expect_value(t, app.requested[len(app.requested) - 1], "my-gauge")
}

// Rule 6, half one: removing the element detaches its behavior, and that is where the handler is freed.
@(test)
test_removing_the_element_detaches_the_behavior :: proc(t: ^testing.T) {
	app, root, ok := test_app(t)
	if !ok {return}

	freed_before := app.freed
	live_before := app.live

	g2, err := sciter_app.select_first(root, "#g2")
	testing.expect_value(t, err, nil)
	_, g2_rmerr := sciter_app.remove_element(g2)
	testing.expect_value(t, g2_rmerr, nil)
	sciter_app.windowless_heartbeat(&g_view, 16 * time.Millisecond)

	testing.expect_value(t, app.freed, freed_before + 1)
	testing.expect_value(t, app.live, live_before - 1)
}

// Rule 6, half two: replacing the document detaches every one of them. If this ever regresses, a
// long-running application leaks one handler per behavior per document load.
@(test)
test_replacing_the_document_detaches_everything :: proc(t: ^testing.T) {
	app, _, ok := test_app(t)
	if !ok {return}

	testing.expect_value(t, app.live, 5)

	// A second document with no behaviors at all, so nothing new attaches to confuse the count.
	testing.expect_value(t, sciter_app.load_html(g_view.window, `<html><body><p>nothing here</p></body></html>`), nil)
	sciter_app.windowless_heartbeat(&g_view, 16 * time.Millisecond)

	testing.expect_value(t, app.live, 0)
	testing.expect_value(t, app.freed, 5)
}

// A behavior handler is an ordinary `Event_Handler`, so its `subscription` is honoured the same way -
// which is what lets the gauge hear the mouse without anyone calling `attach_handler`.
@(test)
test_a_behavior_handler_receives_its_subscription :: proc(t: ^testing.T) {
	app, root, ok := test_app(t)
	if !ok {return}
	_ = app

	g1, _ := sciter_app.select_first(root, "#g1")
	box, err := sciter_app.location(g1, .Border, .View)
	testing.expect_value(t, err, nil)
	if box.width == 0 {
		return // never laid out; nothing to aim at
	}

	// Three quarters of the way across the bar, in the element's own coordinates.
	_, serr := sciter_app.send_mouse(g1, .MOUSE_MOVE, {(box.width * 3) / 4, box.height / 2})
	testing.expect_value(t, serr, nil)
	sciter_app.windowless_heartbeat(&g_view, 16 * time.Millisecond)

	text, terr := sciter_app.text(g1, context.temp_allocator)
	testing.expect_value(t, terr, nil)
	testing.expectf(t, text != "  0%", "the gauge moved with the mouse, got %q", text)
}

// ---------------------------------------------------------------------------------------------------
// The rest of the notification family
//
// `Host_Handler` covers all nine `SCITER_CALLBACK_NOTIFICATION` codes, and the App above wires four of
// them up so that running this example exercises them. They are deliberately **not** asserted on:
//
//   - `SC_INVALIDATE_RECT` and `SC_KEYBOARD_REQUEST` are really sent by an ordinary embedded window -
//     49 and 1 times respectively in a standalone run that showed a window, focused a text field, moved
//     the mouse and clicked. That contradicts the header's grouping, which reads as though both belong
//     to windowless mode only.
//   - Neither reproduces in the harness above. Those tests share one window that is never shown until
//     late, and both notifications need a window that is on screen and actually rendering. Forcing it
//     produced a test that passed or failed depending on when the compositor got around to the window,
//     which is worth less than no test.
//   - `SC_SET_CURSOR` and `SC_GRAPHICS_CRITICAL_FAILURE` were never seen at all in windowed mode.
//
// So the wrappers are exercised by `just example named_behavior` and the counts are printed there,
// while the assertions here stay on the parts that are deterministic.
