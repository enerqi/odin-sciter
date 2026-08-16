// Behavior methods: driving the engine's built-in widgets from Odin, and implementing methods of
// your own.
//
//   just example behavior
//   odin test examples/behavior.odin -file      # needs a display; skips itself without one
//
// A `<button>` is a `<button>` because of native code inside the engine - its *intrinsic behavior* -
// and that code is reachable neither through the DOM nor through script. `SciterCallBehaviorMethod` is
// the door to it, and `do_click` is the one call that matters in practice: it produces a real click,
// where `send_event(el, .BUTTON_CLICK)` only injects the event code and leaves the widget untouched.
//
// The same call runs the other way. A method arrives at the element's own handlers as a `.METHOD_CALL`
// event, so an `Event_Handler` can implement a method for native code to call - the native-to-native
// counterpart of a scripting method.
//
// Hit testing and the window's metrics ride along here because they answer the same kind of question:
// what is actually at this point, and how big does this window have to be.
package main

import sciter ".."
import "../sciter_app"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"
import "core:time"

DOC :: `<html>
<head><style>
  html     { background: #1e1e2e; color: #cdd6f4; font: 16px system; }
  body     { padding: 2em; margin: 0; }
  h1       { color: #89b4fa; margin-top: 0; }
  p        { margin: .4em 0; }
  #meter   { display: block; width: 220px; height: 40px; background: #313244; border-radius: 4px;
             padding: .4em .8em; }
  #out     { margin-top: 1em; padding: .6em 1em; background: #313244; border-radius: 4px;
             font: 14px monospace; white-space: pre-wrap; }
</style></head>
<body>
  <h1>behavior</h1>
  <p><input id="agree" type="checkbox"> <label>a checkbox Odin will tick</label></p>
  <p><button id="go">a button Odin will click</button></p>
  <p><input id="name" type="text" value="typed by hand"></p>
  <p><select id="pick"><option value="1">one</option><option value="2">two</option></select></p>
  <div id="meter">a plain div with a behavior method of its own</div>
  <div id="out">(Odin fills this in)</div>
  <!-- for the asset tests below: the *other* door into a behavior, see docs/BEHAVIORS.md -->
  <terminal id="term" style="size:*"></terminal>
</body>
</html>`

// A method id of our own. Everything below `.FIRST_APPLICATION_METHOD_ID` (256) belongs to the engine.
SET_LEVEL :: u32(sciter.Behavior_Method_Identifiers.FIRST_APPLICATION_METHOD_ID) + 0

// Its parameter block. The **first field must be the u32 method id**; the rest is between the caller
// and the handler, and the handler writes its answer back into the same struct.
Set_Level_Params :: struct {
	method_id: u32,
	level:     u32, // in
	clamped:   b32, // out - the handler says whether it had to clamp
}

// The handler that implements SET_LEVEL for #meter. It is an ordinary `Event_Handler`; the only thing
// special about it is the `.METHOD_CALL` subscription.
Meter :: struct {
	using handler: sciter_app.Event_Handler,
	element:       sciter_app.Element,
	level:         u32,
	calls:         int,
}

MAX_LEVEL :: 100

on_meter_event :: proc(h: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	meter := (^Meter)(h)

	mc, ok := sciter_app.method_call(event)
	if !ok {
		return false
	}
	meter.calls += 1

	switch mc.id {
	case SET_LEVEL:
		p := (^Set_Level_Params)(mc.params)
		p.clamped = b32(p.level > MAX_LEVEL)
		meter.level = min(p.level, MAX_LEVEL)
		sciter_app.set_text(meter.element, fmt.tprintf("level %d of %d", meter.level, MAX_LEVEL))
		return true // this is what makes the caller's `handled` true
	}

	// The engine's own value protocol, which nothing in a plain document implements - so implementing
	// it here is what makes `behavior_value(meter)` answer at all.
	switch args in sciter_app.method_args(mc) {
	case ^sciter.Value_Params:
		if mc.id == u32(sciter.Behavior_Method_Identifiers.GET_VALUE) {
			args.val = sciter_app.value_from(i32(meter.level))
			return true
		}
		v, err := sciter_app.value_to_int(&args.val)
		if err != nil {
			return false
		}
		meter.level = u32(min(max(v, 0), MAX_LEVEL))
		return true
	case ^sciter.Is_Empty_Params:
		args.is_empty = 1 if meter.level == 0 else 0
		return true
	}
	return false
}

// Counts the BUTTON_CLICKs the document produces, so the difference between `do_click` and
// `send_event` is visible rather than asserted.
Clicks :: struct {
	using handler: sciter_app.Event_Handler,
	count:         int,
	last:          sciter_app.Element,
}

on_click_event :: proc(h: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	clicks := (^Clicks)(h)
	if be, ok := sciter_app.behavior_event(event); ok {
		// Every behavior event arrives twice, sinking then bubbling. Count one of the two.
		if be.code == .BUTTON_CLICK && be.phase != .Sinking {
			clicks.count += 1
			clicks.last = be.target
		}
	}
	return false
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

	window, werr := sciter_app.create_window({width = 720, height = 520})
	if werr != nil {
		fmt.eprintln("could not create a window:", werr)
		os.exit(1)
	}
	if err := sciter_app.load_html(window, DOC); err != nil {
		fmt.eprintln("could not load the document:", err)
		os.exit(1)
	}

	root, _ := sciter_app.root(window)

	// --- what is each element, really -----------------------------------------------------------

	// The tag says what the markup called it; this says what the engine made of it. A <div> with
	// `behavior: button` in its CSS would answer .BUTTON here.
	fmt.println("control types:")
	for selector in ([?]string{"#agree", "#go", "#name", "#pick", "#meter"}) {
		el, err := sciter_app.select_first(root, selector)
		if err != nil {
			continue
		}
		type, _ := sciter_app.control_type(el)
		fmt.printfln("  %-7s -> %v", selector, type)
	}

	// --- driving a widget -----------------------------------------------------------------------

	clicks := new(Clicks)
	clicks.subscription = {.BEHAVIOR_EVENT}
	clicks.on_event = on_click_event
	sciter_app.attach_window_handler(window, clicks)

	agree, _ := sciter_app.select_first(root, "#agree")
	button, _ := sciter_app.select_first(root, "#go")

	// A real click: the checkbox flips and raises the events a user's click would.
	handled, _ := sciter_app.do_click(agree)
	state, _ := sciter_app.state(agree)
	fmt.printfln("do_click(#agree)  handled=%v  now :checked = %v", handled, .CHECKED in state)

	handled, _ = sciter_app.do_click(button)
	// The state change is synchronous; the event the behavior raises is queued, so the pump has to turn
	// once before a handler has seen it.
	for _ in 0 ..< 10 {
		sciter_app.run_once()
	}
	fmt.printfln("do_click(#go)     handled=%v  BUTTON_CLICKs seen so far = %d", handled, clicks.count)

	// The contrast: this only injects the event code. Handlers hear a BUTTON_CLICK; the checkbox does
	// not move, because the behavior never ran.
	before, _ := sciter_app.state(agree)
	sciter_app.send_event(agree, .BUTTON_CLICK, agree)
	after, _ := sciter_app.state(agree)
	fmt.printfln(
		"send_event(#agree) :checked %v -> %v  (unchanged: the behavior was bypassed)",
		.CHECKED in before,
		.CHECKED in after,
	)

	// An element with no behavior has nothing to click.
	meter_el, _ := sciter_app.select_first(root, "#meter")
	handled, _ = sciter_app.do_click(meter_el)
	fmt.printfln("do_click(#meter)  handled=%v  (a <div> has no behavior)", handled)

	// --- a method of our own --------------------------------------------------------------------

	meter := new(Meter)
	meter.subscription = {.METHOD_CALL}
	meter.on_event = on_meter_event
	meter.element = meter_el
	// A method call reaches only handlers attached to the element itself: not the window's, not an
	// ancestor's. `attach_handler` on the element is the only attachment that receives one.
	sciter_app.attach_handler(meter_el, meter)

	p := Set_Level_Params {
		method_id = SET_LEVEL,
		level     = 42,
	}
	handled, _ = sciter_app.call_behavior_method(meter_el, &p)
	fmt.printfln("SET_LEVEL 42      handled=%v clamped=%v", handled, bool(p.clamped))

	p = Set_Level_Params {
		method_id = SET_LEVEL,
		level     = 9000,
	}
	sciter_app.call_behavior_method(meter_el, &p)
	fmt.printfln("SET_LEVEL 9000    clamped=%v level is now %d", bool(p.clamped), meter.level)

	// And the engine's own value protocol, answered by the same handler.
	value, got, _ := sciter_app.behavior_value(meter_el)
	defer sciter_app.value_clear(&value)
	n, _ := sciter_app.value_to_int(&value)
	fmt.printfln("behavior_value(#meter) handled=%v -> %d", got, n)

	// Whereas no *intrinsic* behavior implements it: this is the one thing about these methods that
	// has to be measured rather than read off the header.
	name, _ := sciter_app.select_first(root, "#name")
	_, got, _ = sciter_app.behavior_value(name)
	text, _ := sciter_app.element_value(name)
	defer sciter_app.value_clear(&text)
	s, _ := sciter_app.value_to_string(&text, context.temp_allocator)
	fmt.printfln("behavior_value(#name)  handled=%v   element_value -> %q", got, s)

	// --- hit testing and window metrics ---------------------------------------------------------

	// Where the button is, and then: what is at its middle? The point is in the window's client area,
	// the same space `location(el, .Border, .View)` reports.
	box, _ := sciter_app.location(button, .Border, .View)
	if hit, err := sciter_app.element_at(window, {box.x + box.width / 2, box.y + box.height / 2}); err == nil {
		tag, _ := sciter_app.tag(hit)
		id, _ := sciter_app.attribute(hit, "id", context.temp_allocator)
		fmt.printfln("element_at(centre of #go) -> <%s id=%q>", tag, id)
	}
	if _, err := sciter_app.element_at(window, {-10, -10}); err != nil {
		fmt.printfln("element_at(-10,-10)       -> %v", err)
	}

	dpi := sciter_app.ppi(window)
	body, _ := sciter_app.select_first(root, "body")
	content_min, content_max, _ := sciter_app.intrinsic_widths(body)
	fmt.printfln("ppi = %dx%d  (scale %.2f)", dpi.x, dpi.y, f32(dpi.x) / 96)
	fmt.printfln(
		"min_width = %d, min_height = %d  -- the *root's* intrinsic size, not the document's",
		sciter_app.min_width(window),
		sciter_app.min_height(window, 720),
	)
	fmt.printfln("<body> intrinsic widths = %d..%d  -- what the content actually wants", content_min, content_max)

	out, _ := sciter_app.select_first(root, "#out")
	sciter_app.set_html(
		out,
		fmt.tprintf(
			"do_click produced %d BUTTON_CLICK(s)<br>meter level = %d<br>ppi = %dx%d",
			clicks.count,
			meter.level,
			dpi.x,
			dpi.y,
		),
	)

	sciter_app.show(window)
	sciter_app.run()
	sciter_app.shutdown()
}

// ---------------------------------------------------------------------------------------------------
// Tests
//
// These need a window, because a behavior has to exist before it can be called, and skip themselves
// where there is no display. `ODIN_TEST_THREADS=1` is required - see the `example-tests` recipe.

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

// The one test here that needs a **real** window rather than a document, kept separate so the other
// thirteen do not pay for it. `test_window_metrics` reads `ppi`, `min_width` and `min_height`, all of
// which are questions about a window; measured on a windowless view the content/root relationship it
// asserts does not hold. So this is the only test in the file that still skips on macOS, and the skip
// is now a statement about that test rather than about the whole file.
@(private = "file")
g_real_window: sciter_app.Window

@(private = "file")
test_real_window :: proc(t: ^testing.T) -> (window: sciter_app.Window, root: sciter_app.Element, ok: bool) {
	if !have_display() {
		fmt.println("skipping - this test needs a real window, not a windowless view")
		return nil, nil, false
	}
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}
	sciter_app.set_default_debug_output()

	if g_real_window == nil {
		context.allocator = runtime.default_allocator()
		sciter_app.init()
		w, err := sciter_app.create_window({width = 500, height = 400})
		testing.expect_value(t, err, nil)
		if w == nil {
			return nil, nil, false
		}
		g_real_window = w
	}

	testing.expect_value(t, sciter_app.load_html(g_real_window, DOC), nil)
	r, rerr := sciter_app.root(g_real_window)
	testing.expect_value(t, rerr, nil)
	return g_real_window, r, true
}

@(private = "file")
test_window :: proc(t: ^testing.T) -> (window: sciter_app.Window, root: sciter_app.Element, ok: bool) {
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

	if g_view.window == nil {
		// The engine holds the argv and the window for the life of the process, so both are allocated
		// outside the test runner's tracking allocator - otherwise every test reports them as a leak.
		context.allocator = runtime.default_allocator()


		v, err := sciter_app.create_windowless({width = 500, height = 400})
		testing.expect_value(t, err, nil)
		if v.window == nil {
			return nil, nil, false
		}
		g_view = v
	}

	// Reload, so each test sees the document unmodified by the one before it. That also drops every
	// handler attached to an element, which is what keeps the METHOD_CALL tests independent.
	testing.expect_value(t, sciter_app.load_html(g_view.window, DOC, "about:blank"), nil)

	// Layout happens on the heartbeat rather than on the load, so geometry - `location`,
	// `scroll_info`, anything measured - reads zeroes without this. Eight beats is what
	// `examples/windowless.odin` settles in, and the paint is what actually drives layout.
	for i in 0 ..< 8 {
		sciter_app.windowless_heartbeat(&g_view, time.Duration(i) * 16 * time.Millisecond)
		sciter_app.paint_windowless(&g_view)
	}
	r, rerr := sciter_app.root(g_view.window)
	testing.expect_value(t, rerr, nil)
	return g_view.window, r, true
}

// The events a behavior raises are queued, not delivered inside the call that caused them, so a test
// that watches for one has to let the pump turn first.
@(private = "file")
settle :: proc(n := 10) {
	for _ in 0 ..< n {
		sciter_app.run_once()
	}
}

@(test)
test_control_type_reports_the_behavior :: proc(t: ^testing.T) {
	_, root, ok := test_window(t)
	if !ok {return}

	for pair in ([?]struct {
			selector: string,
			type:     sciter.Ctl_Type,
		} {
			{"#agree", .CHECKBOX},
			{"#go", .BUTTON},
			{"#name", .EDIT},
			{"#pick", .DD_SELECT},
			{"#meter", .NO}, // a plain <div> has no behavior at all
		}) {
		el, err := sciter_app.select_first(root, pair.selector)
		testing.expect_value(t, err, nil)
		type, terr := sciter_app.control_type(el)
		testing.expect_value(t, terr, nil)
		testing.expectf(t, type == pair.type, "%s: got %v, want %v", pair.selector, type, pair.type)
	}

	// The document element too, which no selector reaches - see `select_first`.
	root_type, rerr := sciter_app.control_type(root)
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, root_type, sciter.Ctl_Type.NO)
}

@(test)
test_do_click_runs_the_behavior :: proc(t: ^testing.T) {
	window, root, ok := test_window(t)
	if !ok {return}

	clicks := Clicks {
		subscription = {.BEHAVIOR_EVENT},
		on_event     = on_click_event,
	}
	testing.expect_value(t, sciter_app.attach_window_handler(window, &clicks), nil)
	defer sciter_app.detach_window_handler(window, &clicks)

	agree, _ := sciter_app.select_first(root, "#agree")

	before, _ := sciter_app.element_state(agree)
	testing.expect(t, .CHECKED not_in before, "the checkbox starts unticked")

	handled, err := sciter_app.do_click(agree)
	testing.expect_value(t, err, nil)
	testing.expect(t, handled, "a checkbox has a behavior, so DO_CLICK is handled")

	after, _ := sciter_app.element_state(agree)
	testing.expect(t, .CHECKED in after, "do_click ticked it - synchronously, unlike the event")

	settle()
	testing.expect_value(t, clicks.count, 1)

	// It is a click, not a "set": clicking again toggles back.
	sciter_app.do_click(agree)
	settle()
	again, _ := sciter_app.element_state(agree)
	testing.expect(t, .CHECKED not_in again, "the second click unticked it")
	testing.expect_value(t, clicks.count, 2)
}

@(test)
test_send_event_does_not_run_the_behavior :: proc(t: ^testing.T) {
	window, root, ok := test_window(t)
	if !ok {return}

	clicks := Clicks {
		subscription = {.BEHAVIOR_EVENT},
		on_event     = on_click_event,
	}
	testing.expect_value(t, sciter_app.attach_window_handler(window, &clicks), nil)
	defer sciter_app.detach_window_handler(window, &clicks)

	agree, _ := sciter_app.select_first(root, "#agree")

	// The event code is delivered - a handler watching for clicks sees one - but the checkbox does not
	// move, because the intrinsic behavior is bypassed entirely. That is the whole reason `do_click`
	// exists next to `send_event`.
	_, err := sciter_app.send_event(agree, .BUTTON_CLICK, agree)
	testing.expect_value(t, err, nil)
	settle()
	testing.expect_value(t, clicks.count, 1)

	state, _ := sciter_app.element_state(agree)
	testing.expect(t, .CHECKED not_in state, "send_event left :checked alone")
}

@(test)
test_do_click_on_an_element_without_a_behavior :: proc(t: ^testing.T) {
	_, root, ok := test_window(t)
	if !ok {return}

	meter, _ := sciter_app.select_first(root, "#meter")
	handled, err := sciter_app.do_click(meter)
	testing.expect_value(t, err, nil) // OK_NOT_HANDLED is a success
	testing.expect(t, !handled, "a <div> has nothing to click")

	// A detached element is a real failure, not an unhandled call.
	orphan_owned, oerr := sciter_app.make_element("button", "x")
	orphan := sciter_app.borrow_element(orphan_owned)
	testing.expect_value(t, oerr, nil)
	defer sciter_app.unuse_element(orphan_owned)
	_, derr := sciter_app.do_click(orphan)
	testing.expect_value(t, derr, sciter_app.Error(sciter.Scdom_Result.PASSIVE_HANDLE))
}

@(test)
test_intrinsic_behaviors_do_not_implement_the_value_methods :: proc(t: ^testing.T) {
	_, root, ok := test_window(t)
	if !ok {return}

	name, _ := sciter_app.select_first(root, "#name")

	// Measured on this engine, and the reason `behavior_value` carries a warning: the edit behavior
	// answers GET_VALUE with "not handled" and no value.
	value, handled, err := sciter_app.behavior_value(name)
	defer sciter_app.value_clear(&value)
	testing.expect_value(t, err, nil)
	testing.expect(t, !handled, "no intrinsic behavior implements GET_VALUE on Sciter 6")

	_, ihandled, ierr := sciter_app.behavior_is_empty(name)
	testing.expect_value(t, ierr, nil)
	testing.expect(t, !ihandled, "nor IS_EMPTY")

	// SciterGetValue is the call that does answer, and it is a different one.
	text, terr := sciter_app.element_value(name)
	defer sciter_app.value_clear(&text)
	testing.expect_value(t, terr, nil)
	s, _ := sciter_app.value_to_string(&text, context.temp_allocator)
	testing.expect_value(t, s, "typed by hand")

	// The writing half fails the same way, and is the more dangerous of the two: it reports no error,
	// so an `<input>` written this way is silently not written at all.
	replacement := sciter_app.value_from("written through SET_VALUE")
	defer sciter_app.value_clear(&replacement)

	shandled, serr := sciter_app.set_behavior_value(name, &replacement)
	testing.expect_value(t, serr, nil)
	testing.expect(t, !shandled, "no intrinsic behavior implements SET_VALUE either")

	unchanged, uerr := sciter_app.element_value(name)
	defer sciter_app.value_clear(&unchanged)
	testing.expect_value(t, uerr, nil)
	still, _ := sciter_app.value_to_string(&unchanged, context.temp_allocator)
	testing.expect_value(t, still, "typed by hand")

	// `set_element_value` is the call that does write, as `element_value` is the one that reads.
	testing.expect_value(t, sciter_app.set_element_value(name, &replacement), nil)
	written, _ := sciter_app.element_value(name)
	defer sciter_app.value_clear(&written)
	now, _ := sciter_app.value_to_string(&written, context.temp_allocator)
	testing.expect_value(t, now, "written through SET_VALUE")
}

@(test)
test_a_method_of_your_own_round_trips :: proc(t: ^testing.T) {
	_, root, ok := test_window(t)
	if !ok {return}

	meter_el, _ := sciter_app.select_first(root, "#meter")
	meter := Meter {
		subscription = {.METHOD_CALL},
		on_event     = on_meter_event,
		element      = meter_el,
	}
	testing.expect_value(t, sciter_app.attach_handler(meter_el, &meter), nil)
	defer sciter_app.detach_handler(meter_el, &meter)

	// In, and out: the parameter block is the caller's memory, written in place by the handler while
	// the call is still on the stack.
	p := Set_Level_Params {
		method_id = SET_LEVEL,
		level     = 42,
	}
	handled, err := sciter_app.call_behavior_method(meter_el, &p)
	testing.expect_value(t, err, nil)
	testing.expect(t, handled, "the handler returned true")
	testing.expect(t, !bool(p.clamped), "42 is in range")
	testing.expect_value(t, meter.level, 42)

	p = Set_Level_Params {
		method_id = SET_LEVEL,
		level     = 9000,
	}
	sciter_app.call_behavior_method(meter_el, &p)
	testing.expect(t, bool(p.clamped), "the handler reported the clamp back to the caller")
	testing.expect_value(t, meter.level, MAX_LEVEL)

	// An id nobody implements is not an error - it is a call nothing answered.
	unknown := Set_Level_Params {
		method_id = SET_LEVEL + 77,
	}
	uhandled, uerr := sciter_app.call_behavior_method(meter_el, &unknown)
	testing.expect_value(t, uerr, nil)
	testing.expect(t, !uhandled, "an unimplemented method id is unhandled, not failed")

	// The engine's own ids reach the same handler, so a document element can implement the value
	// protocol its behavior does not.
	value, vhandled, verr := sciter_app.behavior_value(meter_el)
	defer sciter_app.value_clear(&value)
	testing.expect_value(t, verr, nil)
	testing.expect(t, vhandled, "the handler answered GET_VALUE")
	n, _ := sciter_app.value_to_int(&value)
	testing.expect_value(t, n, i32(MAX_LEVEL))

	empty, ehandled, _ := sciter_app.behavior_is_empty(meter_el)
	testing.expect(t, ehandled, "the handler answered IS_EMPTY")
	testing.expect(t, !empty, "level is not zero")

	// The write half of the same protocol reaches the same handler, which is the whole point of
	// implementing it: generic code can set any element's value without knowing what it is.
	wanted := sciter_app.value_from(i32(7))
	defer sciter_app.value_clear(&wanted)
	whandled, werr := sciter_app.set_behavior_value(meter_el, &wanted)
	testing.expect_value(t, werr, nil)
	testing.expect(t, whandled, "the handler answered SET_VALUE")
	testing.expect_value(t, meter.level, u32(7))

	// And reading it back through the protocol agrees with the behavior's own state.
	after, ahandled, _ := sciter_app.behavior_value(meter_el)
	defer sciter_app.value_clear(&after)
	testing.expect(t, ahandled)
	back, _ := sciter_app.value_to_int(&after)
	testing.expect_value(t, back, i32(7))

	// A nil Value is passed straight through to the handler, which sees an undefined one and refuses
	// it - so this is "the behavior said no", not a crash in the wrapper.
	nil_handled, nil_err := sciter_app.set_behavior_value(meter_el, nil)
	testing.expect_value(t, nil_err, nil)
	testing.expect(t, !nil_handled, "an undefined value is not an integer, so the handler refuses it")
	testing.expect_value(t, meter.level, u32(7))
}

@(test)
test_a_method_call_reaches_only_the_element :: proc(t: ^testing.T) {
	window, root, ok := test_window(t)
	if !ok {return}

	meter_el, _ := sciter_app.select_first(root, "#meter")
	button, _ := sciter_app.select_first(root, "#go")

	// The same handler, attached to the whole document rather than to one element.
	watcher := Meter {
		subscription = {.METHOD_CALL},
		on_event     = on_meter_event,
		element      = meter_el,
	}
	testing.expect_value(t, sciter_app.attach_window_handler(window, &watcher), nil)
	defer sciter_app.detach_window_handler(window, &watcher)

	p := Set_Level_Params {
		method_id = SET_LEVEL,
		level     = 5,
	}
	handled, err := sciter_app.call_behavior_method(button, &p)
	testing.expect_value(t, err, nil)
	testing.expect(t, !handled, "a window handler does not receive method calls")
	testing.expect_value(t, watcher.calls, 0)
}

@(test)
test_element_at_hit_tests_a_point :: proc(t: ^testing.T) {
	window, root, ok := test_window(t)
	if !ok {return}

	button, _ := sciter_app.select_first(root, "#go")
	box, err := sciter_app.location(button, .Border, .View)
	testing.expect_value(t, err, nil)
	testing.expect(t, box.width > 0 && box.height > 0, "the button was laid out")

	hit, herr := sciter_app.element_at(window, {box.x + box.width / 2, box.y + box.height / 2})
	testing.expect_value(t, herr, nil)
	// The innermost element painted there - a <button> paints its own label, so it is the button.
	tag, _ := sciter_app.tag(hit)
	testing.expect_value(t, tag, "button")

	// Off the document is Not_Found rather than an error.
	_, merr := sciter_app.element_at(window, {-10, -10})
	testing.expect_value(t, merr, sciter_app.Error(sciter_app.Api_Error.Not_Found))

	_, ferr := sciter_app.element_at(window, {30_000, 30_000})
	testing.expect_value(t, ferr, sciter_app.Error(sciter_app.Api_Error.Not_Found))

	// And a nil window is a real failure, not an empty answer.
	_, nerr := sciter_app.element_at(nil, {1, 1})
	testing.expect_value(t, nerr, sciter_app.Error(sciter.Scdom_Result.INVALID_HWND))
}

@(test)
test_window_metrics :: proc(t: ^testing.T) {
	window, root, ok := test_real_window(t)
	if !ok {return}

	// Let layout settle: these read the result of it, and are unstable before it has run.
	for _ in 0 ..< 10 {
		sciter_app.run_once()
	}

	dpi := sciter_app.ppi(window)
	testing.expect(t, dpi.x > 0 && dpi.y > 0, "a window always has a resolution")

	// The measured identity that the doc comment on `min_width` is about: these report the *root
	// element's* intrinsic size. They are not "how big does this document want to be" - `<html>` fills
	// the view, so its min-content width is a small constant whatever is inside it.
	rmin, _, ierr := sciter_app.intrinsic_widths(root)
	testing.expect_value(t, ierr, nil)
	testing.expect_value(t, sciter_app.min_width(window), rmin)

	rheight, herr := sciter_app.intrinsic_height(root, 400)
	testing.expect_value(t, herr, nil)
	testing.expect_value(t, sciter_app.min_height(window, 400), rheight)

	// The width argument is ignored by this engine - the same number comes back for any of them.
	testing.expect_value(t, sciter_app.min_height(window, 100), sciter_app.min_height(window, 800))

	// The content's own width, which is the number a "size the window to its document" wants, comes
	// from the element that holds the content.
	body, _ := sciter_app.select_first(root, "body")
	_, content_max, _ := sciter_app.intrinsic_widths(body)
	testing.expect(t, content_max > sciter_app.min_width(window), "the content is wider than the root's minimum")
}

// ---------------------------------------------------------------------------------------------------
// The *other* door: the behavior's SOM asset
//
// `SciterCallBehaviorMethod` above has a fixed set of method ids, and only `DO_CLICK` is implemented by
// any intrinsic behavior. The per-behavior surface - `edit`'s selection, `terminal`'s screen,
// `select`'s popup - lives in the asset each behavior publishes. `docs/BEHAVIORS.md` is the measured
// map of all of them; these tests hold the parts of it that would be expensive to get wrong.

@(test)
test_an_intrinsic_behavior_publishes_an_asset :: proc(t: ^testing.T) {
	_, root, ok := test_window(t)
	if !ok {return}

	// The interface name is the *behavior* name, not the tag name.
	name, _ := sciter_app.select_first(root, "#name")
	asset, err := sciter_app.element_asset(name, "edit")
	testing.expect_value(t, err, nil)
	testing.expect(t, asset != nil, "an <input type=text> carries an `edit` asset")

	props, methods := sciter_app.asset_members(asset, context.temp_allocator)
	testing.expect(t, slice.contains(props, "selectionStart"), "edit publishes selectionStart")
	testing.expect(t, slice.contains(methods, "insertText"), "edit publishes insertText")

	// And a name the element does not carry is a refusal, not a nil asset.
	_, werr := sciter_app.element_asset(name, "terminal")
	testing.expect(t, werr != nil, "an <input> has no `terminal` interface")
}

@(test)
test_asset_call_refuses_a_call_with_too_few_arguments :: proc(t: ^testing.T) {
	_, root, ok := test_window(t)
	if !ok {return}

	name, _ := sciter_app.select_first(root, "#name")
	asset, aerr := sciter_app.element_asset(name, "edit")
	testing.expect_value(t, aerr, nil)

	// The passport carries the required count, and it is not advisory: the engine's thunk reads argv[0]
	// whatever `argc` says, so the call below would segfault *inside the engine* if it were made.
	arity, found := sciter_app.asset_method_arity(asset, "insertText")
	testing.expect(t, found, "insertText is in the passport")
	testing.expect_value(t, arity, 1)

	_, err := sciter_app.asset_call(asset, "insertText")
	testing.expect_value(t, err, sciter_app.Error(sciter_app.Api_Error.Wrong_Arity))

	// Too many is fine - the extras are ignored - so over-supplying is the safe direction.
	a := sciter_app.value_from_string("ab")
	defer sciter_app.value_clear(&a)
	spare := sciter_app.value_from_int(0)
	defer sciter_app.value_clear(&spare)
	_, cerr := sciter_app.asset_call(asset, "insertText", {a, spare})
	testing.expect_value(t, cerr, nil)

	// A name no passport lists is `.Not_Found`, and `asset_method_arity` says so first.
	_, absent := sciter_app.asset_method_arity(asset, "noSuchMethod")
	testing.expect(t, !absent, "a method that is not in the passport is not found")
	_, nerr := sciter_app.asset_call(asset, "noSuchMethod")
	testing.expect_value(t, nerr, sciter_app.Error(sciter_app.Api_Error.Not_Found))
}

@(test)
test_a_behavior_asset_reads_writes_and_acts :: proc(t: ^testing.T) {
	_, root, ok := test_window(t)
	if !ok {return}
	settle()

	term, terr := sciter_app.select_first(root, "#term")
	testing.expect_value(t, terr, nil)
	asset, aerr := sciter_app.element_asset(term, "terminal")
	testing.expect_value(t, aerr, nil)

	// A property the passport lists reads through its getter.
	columns, gerr := sciter_app.asset_get(asset, "columns")
	testing.expect_value(t, gerr, nil)
	defer sciter_app.value_clear(&columns)
	n, _ := sciter_app.value_to_int(&columns)
	testing.expect(t, n > 0, "a terminal has a width")

	// A read-only one refuses the write rather than pretending - there is no setter to call.
	ro := sciter_app.value_from_int(1)
	defer sciter_app.value_clear(&ro)
	testing.expect_value(
		t,
		sciter_app.asset_set(asset, "columns", &ro),
		sciter_app.Error(sciter_app.Api_Error.Not_Found),
	)

	// And a method with its arguments does the work: this one moves the caret, which is observable
	// through the properties next to it.
	text := sciter_app.value_from_string("hello")
	defer sciter_app.value_clear(&text)
	_, werr := sciter_app.asset_call(asset, "write", {text})
	testing.expect_value(t, werr, nil)

	col, cerr := sciter_app.asset_get(asset, "caretColumn")
	testing.expect_value(t, cerr, nil)
	defer sciter_app.value_clear(&col)
	after, _ := sciter_app.value_to_int(&col)
	testing.expect_value(t, after, 5) // one column per character written
}

@(test)
test_a_select_opens_through_its_asset_not_through_do_click :: proc(t: ^testing.T) {
	_, root, ok := test_window(t)
	if !ok {return}

	pick, _ := sciter_app.select_first(root, "#pick")

	// Measured, and the reason this pair is a test: the behavior-method door does nothing for a
	// dropdown, and the asset door is what opens it.
	handled, err := sciter_app.do_click(pick)
	testing.expect_value(t, err, nil)
	testing.expect(t, !handled, "do_click is not how a <select> opens")

	asset, aerr := sciter_app.element_asset(pick, "select")
	testing.expect_value(t, aerr, nil)
	arity, _ := sciter_app.asset_method_arity(asset, "showPopup")
	testing.expect_value(t, arity, 1) // and calling it with none would take the process down

	mode := sciter_app.value_from_int(0)
	defer sciter_app.value_clear(&mode)
	_, serr := sciter_app.asset_call(asset, "showPopup", {mode})
	testing.expect_value(t, serr, nil)
	settle()

	_, herr := sciter_app.asset_call(asset, "hidePopup")
	testing.expect_value(t, herr, nil)
	settle()
}

// ---------------------------------------------------------------------------------------------------
// The one borrowed Value whose warning is literally true
//
// `docs/rules.md` 2 says clearing `SET_VALUE`'s `args.val` is a use-after-free in the caller. Two other
// shapes of "borrowed Value" were measured and are not - a functor's arguments belong to the script
// that passed them, and a visitor's values silently empty the container (`call_odin_from_js.odin` and
// `eval.odin` hold those). This one is, and it is the worst kind: **the caller's Value reads correctly
// right after the call and stops reading correctly later**, when the freed payload is reused. A test
// that checked it the obvious way would report the bug as safe.

@(private = "file")
Value_Clearer :: struct {
	using handler: sciter_app.Event_Handler,
	saw:           bool,
}

@(private = "file")
on_clearing_set_value :: proc(h: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	clearer := (^Value_Clearer)(h)
	mc, ok := sciter_app.method_call(event)
	if !ok || mc.id != u32(sciter.Behavior_Method_Identifiers.SET_VALUE) {
		return false
	}
	params := (^sciter.Value_Params)(mc.params)
	clearer.saw = true
	// The thing under test, and the thing never to write in real code.
	sciter_app.value_clear(&params.val)
	return true
}

@(test)
test_clearing_set_values_argument_frees_the_callers_value_under_it :: proc(t: ^testing.T) {
	window, root, ok := test_window(t)
	if !ok {return}

	meter_el, _ := sciter_app.select_first(root, "#meter")
	clearer := Value_Clearer {
		subscription = {.METHOD_CALL},
		on_event     = on_clearing_set_value,
	}
	testing.expect_value(t, sciter_app.attach_handler(meter_el, &clearer), nil)
	defer sciter_app.detach_handler(meter_el, &clearer)

	payload := sciter_app.value_from_string("the caller still owns this")
	// No `defer value_clear` here on purpose: the handler below releases this reference, so clearing it
	// again would be the double free that follows a use-after-free.

	handled, err := sciter_app.set_behavior_value(meter_el, &payload)
	testing.expect_value(t, err, nil)
	testing.expect(t, handled, "the handler claimed the method")
	testing.expect(t, clearer.saw, "the handler saw SET_VALUE")

	// **Everything below this line reads a Value the handler has already released, which is undefined
	// behaviour on purpose - and it is only survivable on some allocators.** It demonstrated the hazard
	// on Linux for a long time and then segfaulted the Windows CI runner at exactly this test, taking
	// every later test in the binary with it and timing the job out. That is what reading freed memory
	// is entitled to do; the surprise was that it ever worked, not that it stopped.
	//
	// Kept on Linux, where it is measured and where it is the only thing that *proves* the reference was
	// given away rather than merely asserting it. Not run on Windows, where the same code faults. If it
	// ever starts faulting on Linux too, delete it rather than chasing it - the rule it demonstrates is
	// in the comment above `on_clearing_set_value` and in `docs/rules.md`, which is where a reader
	// should be learning it anyway.
	when ODIN_OS != .Windows {
		// The trap: immediately afterwards the caller's Value still reads correctly, because nothing has
		// reused the freed payload yet.
		right_after, rerr := sciter_app.value_to_string(&payload, context.temp_allocator)
		testing.expect_value(t, rerr, nil)
		testing.expect_value(t, right_after, "the caller still owns this")

		// Churn the engine's heap, and the same Value now reads as something else - measured, empty.
		for _ in 0 ..< 200 {
			junk, _ := sciter_app.eval(window, `"z".repeat(5000)`)
			sciter_app.value_clear(&junk)
		}
		after, _ := sciter_app.value_to_string(&payload, context.temp_allocator)
		testing.expect(
			t,
			after != "the caller still owns this",
			"the payload should be gone once the engine has reused the memory under it",
		)
	} else {
		_ = window // only the heap-churn loop above needs it, and that is Linux-only
	}
}
