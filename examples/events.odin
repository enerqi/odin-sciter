// Handling DOM events in Odin: button clicks, typing, and the mouse.
//
//   just example events
//
// `call_odin_from_js` went through script - the document had a JS handler that called into Odin. This
// skips script entirely. `attach_handler` registers an ELEMENT_EVENT_PROC, and the engine calls it for
// everything in the element's subtree.
//
// Three things about the protocol that are easy to get wrong, all handled by `sciter_app`:
//
//   - right after attaching, the engine calls the handler with SUBSCRIPTIONS_REQUEST to ask what to
//     send. A handler that ignores it receives nothing at all. `Event_Handler.subscription` is the
//     answer, and the wrapper replies for you.
//   - the `cmd` in every parameter struct has the propagation phase OR'ed into it, so `cmd == .CLICK`
//     is false during the sinking phase. `event_code` and `event_phase` split them.
//   - the handler runs as `proc "system"`, where Odin's implicit context does not exist. The wrapper
//     captures the context at attach time and restores it.
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
  html    { background: #1e1e2e; color: #cdd6f4; font: 16px system; }
  body    { padding: 2em; margin: 0; }
  h1      { color: #89b4fa; margin-top: 0; }
  button  { padding: .5em 1em; margin-right: .5em; }
  input   { padding: .4em; width: 20em; }
  #log    { background: #313244; padding: 1em; border-radius: 4px; font: 13px monospace;
            white-space: pre-wrap; margin-top: 1em; height: 12em; overflow-y: scroll; }
  .count  { color: #a6e3a1; }
</style></head>
<body>
  <h1>events</h1>
  <p>
    <button id="tick">count up</button>
    <button id="reset">reset</button>
    <span class="count" id="count">0</span>
  </p>
  <p><input id="name" type="text" placeholder="type here" /></p>
  <p>timer: <span class="count" id="uptime">0.0s</span></p>
  <div id="log">No script in this document. Every line below was written by Odin.</div>
</body>
</html>`

// State the handler needs. `Event_Handler` is embedded rather than allocated separately because the
// engine stores its *address* as the handler tag - it must not move while attached, and it must
// outlive the message pump.
App :: struct {
	handler: sciter_app.Event_Handler,
	window:  sciter_app.Window,
	count:   int,
	ticks:   int,
	lines:   [dynamic]string,
}

// Timers are told apart by an id, so give the one this example uses a name rather than a bare 1.
UPTIME_TIMER :: 1
TICK :: 100 * time.Millisecond

main :: proc() {
	if !sciter_app.load_engine() {
		os.exit(1)
	}
	sciter_app.set_default_debug_output()

	if err := sciter_app.init(); err != nil {
		fmt.eprintln("init failed:", err)
		os.exit(1)
	}

	app: App
	defer {
		for line in app.lines {delete(line)}
		delete(app.lines)
	}

	window, werr := sciter_app.create_window({width = 760, height = 560})
	if werr != nil {
		fmt.eprintln("could not create a window:", werr)
		os.exit(1)
	}
	app.window = window

	if err := sciter_app.load_html(window, DOC); err != nil {
		fmt.eprintln("could not load the document:", err)
		os.exit(1)
	}

	root, rerr := sciter_app.root(window)
	if rerr != nil {
		fmt.eprintln("no root element:", rerr)
		os.exit(1)
	}

	app.handler = sciter_app.Event_Handler {
		// BEHAVIOR_EVENT carries the synthetic, meaningful events - a button click, a value change.
		// KEY is the raw input underneath them; subscribing to both shows the same interaction
		// arriving at two levels. TIMER is the engine's own clock, below.
		subscription = {.BEHAVIOR_EVENT, .KEY, .TIMER},
		on_event     = on_event,
		user_data    = &app,
	}
	if err := sciter_app.attach_handler(root, &app.handler); err != nil {
		fmt.eprintln("could not attach the handler:", err)
		os.exit(1)
	}
	defer sciter_app.detach_handler(root, &app.handler)

	// A timer belongs to an element and is delivered to the handlers on *that* element - it does not
	// bubble, so this one is set on the same `root` the handler is attached to.
	if err := sciter_app.set_timer(root, TICK, UPTIME_TIMER); err != nil {
		fmt.eprintln("could not start the timer:", err)
		os.exit(1)
	}
	defer sciter_app.stop_timer(root, UPTIME_TIMER)

	fmt.println("click the buttons and type in the box; every event is logged to stdout too")

	sciter_app.show(window)
	sciter_app.run()
	sciter_app.shutdown()
}

on_event :: proc(handler: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	app := (^App)(handler.user_data)

	// A behaviour event: a click on a button, a changed <input>, a submitted form.
	if be, ok := sciter_app.behavior_event(event); ok {
		// Events arrive twice - once sinking towards the target, once bubbling back up. Acting on
		// both would count every click twice.
		if be.phase != .Bubbling {
			return false
		}

		id, _ := sciter_app.attribute(be.target, "id", context.temp_allocator)

		#partial switch be.code {
		case .DOCUMENT_READY:
			// The document now has its DOM, its styles and - the part that matters here - the
			// behaviors attached to its elements. A <button> only produces BUTTON_CLICK once its
			// button behavior exists, so this is the earliest point at which a synthesised click
			// does the same thing a real one would.
			//
			// Proving the handler is wired up without needing anyone to click. Asking script to
			// click the button produces exactly what a real click produces, behavior and all -
			// unlike SciterSendEvent, which delivers the raw event code to the element chain and
			// bypasses the <button> behavior that turns a press into a BUTTON_CLICK.
			r, err := sciter_app.eval(app.window, `document.$("#tick").click()`)
			if err != nil {
				log(app, fmt.aprintf("could not synthesise a click: %v", err))
			} else {
				sciter_app.value_clear(&r)
			}
			return false

		case .BUTTON_CLICK:
			switch id {
			case "tick":
				app.count += 1
				log(app, fmt.aprintf("BUTTON_CLICK on #%s, count is now %d", id, app.count))
			case "reset":
				app.count = 0
				log(app, fmt.aprintf("BUTTON_CLICK on #%s, count reset", id))
			}
			update_count(app)
			return true // handled; stop it propagating further

		case .VALUE_CHANGED:
			// The element's `value` is what script sees as `element.value`.
			v, err := sciter_app.element_value(be.target)
			if err == nil {
				defer sciter_app.value_clear(&v)
				text, _ := sciter_app.value_to_string(&v, context.temp_allocator)
				log(app, fmt.aprintf("VALUE_CHANGED on #%s -> %q", id, text))
			}
			return true
		}
		return false
	}

	// The timer. Note the return value: everywhere else in this file `true` means "handled, and I have
	// dealt with it", but for a timer it means "keep running" - returning false here stops the clock
	// after one tick, which is the trap this group carries.
	if te, ok := sciter_app.timer_event(event); ok {
		if te.id == UPTIME_TIMER {
			app.ticks += 1
			update_uptime(app)
		}
		return true
	}

	// A raw key event. `key_code` is a virtual key for KEY_DOWN/KEY_UP and a character for KEY_CHAR.
	if ke, ok := sciter_app.key_event(event); ok {
		if ke.phase == .Bubbling && ke.code == .DOWN {
			log(app, fmt.aprintf("KEY.DOWN key_code=%d modifiers=%v", ke.key_code, ke.modifiers))
		}
		return false
	}

	return false
}

// Appends a line to the in-document log and to stdout. `line` is taken over by `app.lines`.
log :: proc(app: ^App, line: string) {
	fmt.println(line)
	append(&app.lines, line)

	// Keep the last 12, so the box does not grow without bound.
	if len(app.lines) > 12 {
		delete(app.lines[0])
		ordered_remove(&app.lines, 0)
	}

	root, err := sciter_app.root(app.window)
	if err != nil {
		return
	}
	box, serr := sciter_app.select_first(root, "#log")
	if serr != nil {
		return
	}

	joined := join_lines(app.lines[:], context.temp_allocator)
	sciter_app.set_text(box, joined)
}

update_uptime :: proc(app: ^App) {
	root, err := sciter_app.root(app.window)
	if err != nil {
		return
	}
	if label, serr := sciter_app.select_first(root, "#uptime"); serr == nil {
		seconds := f64(app.ticks) * time.duration_seconds(TICK)
		sciter_app.set_text(label, fmt.tprintf("%.1fs", seconds))
	}
}

update_count :: proc(app: ^App) {
	root, err := sciter_app.root(app.window)
	if err != nil {
		return
	}
	if label, serr := sciter_app.select_first(root, "#count"); serr == nil {
		sciter_app.set_text(label, fmt.tprintf("%d", app.count))
	}
}

join_lines :: proc(lines: []string, allocator := context.allocator) -> string {
	total := 0
	for line in lines {
		total += len(line) + 1
	}
	buf := make([]u8, total, allocator)
	n := 0
	for line in lines {
		copy(buf[n:], line)
		n += len(line)
		buf[n] = '\n'
		n += 1
	}
	return string(buf[:n])
}

// ---------------------------------------------------------------------------------------------------
// Tests
//
//   odin test examples/events.odin -file -define:ODIN_TEST_THREADS=1
//
// The thread count is not optional. Sciter is single-threaded - every ISciterAPI call has to come from
// the thread that ran SCITER_APP_INIT - and Odin's test runner is parallel by default, so without it
// these tests corrupt the engine's heap rather than failing cleanly.
//
// Two halves. The first needs neither engine nor display: splitting a `cmd` into a code and a phase,
// and reading a parameter struct as the right type, are pure arithmetic over structs this file can
// build by hand. The second needs a window, because there is no way to reach the trampoline without
// the engine calling it - it is private to `sciter_app`, and rightly so. Those tests drive it through
// `send_event`, which delivers synchronously, so they need no message pump and never show a window.
//
// What the windowed half is actually pinning down, since none of it is visible from the outside:
//
//   - the trampoline finds the handler through the tag the engine hands back, and restores the
//     context that was current at attach time
//   - it answers SUBSCRIPTIONS_REQUEST from `Event_Handler.subscription`. There is no way to observe
//     the reply directly - the trampoline consumes it - so this is tested by its consequence: a
//     handler that did not answer, or answered with the wrong mask, stops receiving.
//   - the phase bits are split off the code rather than compared as part of it

@(private = "file")
fake_element :: proc(address: uintptr) -> sciter_app.Element {
	return sciter_app.Element(sciter.Helement(rawptr(address)))
}

@(test)
test_event_code_strips_the_phase_bits :: proc(t: ^testing.T) {
	// Untyped, so that `click | SINKING` is an `Event_Cmd` at the call sites below - which is the
	// point of the type: a `cmd` word carries the phase bits and a code does not.
	SINKING :: sciter_app.Event_Cmd(sciter.Phase_Mask.SINKING)
	HANDLED :: sciter_app.Event_Cmd(sciter.Phase_Mask.HANDLED)

	// The mask has to stop exactly where the phase bits start. If it were wider it would carry
	// SINKING into the code; narrower and it would truncate an application code.
	testing.expect_value(t, sciter_app.Event_Cmd(sciter_app.EVENT_CODE_MASK) + 1, SINKING)

	code := u32(sciter.Behavior_Events.BUTTON_CLICK)
	click := sciter_app.Event_Cmd(code)
	testing.expect_value(t, sciter_app.event_code(click), code)
	testing.expect_value(t, sciter_app.event_phase(click), sciter_app.Event_Phase.Bubbling)

	testing.expect_value(t, sciter_app.event_code(click | SINKING), code)
	testing.expect_value(t, sciter_app.event_phase(click | SINKING), sciter_app.Event_Phase.Sinking)

	// HANDLED is an independent bit, not a third phase: it says something claimed the event, and says
	// nothing about which way it is travelling. A handled event on the bubbling pass is still bubbling.
	testing.expect_value(t, sciter_app.event_code(click | HANDLED), code)
	testing.expect_value(t, sciter_app.event_phase(click | HANDLED), sciter_app.Event_Phase.Bubbling)
	testing.expect(t, sciter_app.event_handled(click | HANDLED))
	testing.expect(t, !sciter_app.event_handled(click))

	// Both bits at once, which is the case one enum could not express: sinking *and* already claimed.
	testing.expect_value(t, sciter_app.event_phase(click | SINKING | HANDLED), sciter_app.Event_Phase.Sinking)
	testing.expect(t, sciter_app.event_handled(click | SINKING | HANDLED))

	// `Behavior_Events` is a named set *and* an open number space above FIRST_APPLICATION_EVENT_CODE.
	// `app_event` is the spelling that cannot collide with an engine code - which matters most for 0,
	// `.BUTTON_CLICK`, the value you get by forgetting to add the base.
	mine := sciter_app.app_event(u32(sciter.Behavior_Events.FIRST_APPLICATION_EVENT_CODE) + 7)
	testing.expect_value(t, u32(mine), u32(sciter.Behavior_Events.FIRST_APPLICATION_EVENT_CODE) + 7)
	testing.expect(t, u32(mine) > u32(sciter.Behavior_Events.BUTTON_CLICK))

	// BUTTON_CLICK is 0, so a naive `cmd == .BUTTON_CLICK` looks right until an event sinks. Codes
	// that are not zero go through the same split, up to the largest one the mask can carry.
	app_code := u32(sciter.Behavior_Events.FIRST_APPLICATION_EVENT_CODE) + 7
	testing.expect_value(t, sciter_app.event_code(sciter_app.Event_Cmd(app_code) | SINKING), app_code)
	testing.expect_value(t, sciter_app.event_code(0x7FFF | HANDLED), 0x7FFF)
}

@(test)
test_behavior_event_maps_the_params :: proc(t: ^testing.T) {
	target := fake_element(0x1000)
	source := fake_element(0x2000)

	params := sciter.Behavior_Event_Params {
		cmd      = u32(sciter.Behavior_Events.VALUE_CHANGED) | u32(sciter.Phase_Mask.SINKING),
		heTarget = sciter.Helement(target),
		he       = sciter.Helement(source),
		reason   = uintptr(sciter.Click_Reason.BY_KEY_CLICK),
	}

	be, ok := sciter_app.behavior_event({group = {.BEHAVIOR_EVENT}, params = &params})
	testing.expect(t, ok)
	testing.expect_value(t, be.code, sciter.Behavior_Events.VALUE_CHANGED)
	testing.expect_value(t, be.phase, sciter_app.Event_Phase.Sinking)

	// `heTarget` and `he` are the wrong way round from what the names suggest: the *target* is the
	// element the behavior belongs to, and `he` is where the event came from.
	testing.expect_value(t, be.target, target)
	testing.expect_value(t, be.source, source)
	testing.expect_value(t, be.reason, uintptr(sciter.Click_Reason.BY_KEY_CLICK))

	// `data` points into the engine's own struct rather than being a copy - clearing it would clear
	// the engine's Value, which is why it is documented as borrowed.
	testing.expect(t, be.data == &params.data, "data must be borrowed, not copied")
	testing.expect(t, be.raw == &params)
}

@(test)
test_mouse_event_maps_the_params :: proc(t: ^testing.T) {
	target := fake_element(0x3000)

	params := sciter.Mouse_Params {
		cmd = u32(sciter.Mouse_Events.MOUSE_DOWN),
		target = sciter.Helement(target),
		pos = {x = 12, y = 34},
		pos_view = {x = 512, y = 534}, // view-relative; `pos` is the element-relative one
		button_state = {.PROP_MOUSE_BUTTON},
	}

	me, ok := sciter_app.mouse_event({group = {.MOUSE}, params = &params})
	testing.expect(t, ok)
	testing.expect_value(t, me.code, sciter.Mouse_Events.MOUSE_DOWN)
	testing.expect_value(t, me.phase, sciter_app.Event_Phase.Bubbling)
	testing.expect_value(t, me.target, target)

	// The element-relative position, not the view-relative one that sits next to it in the struct.
	testing.expect_value(t, me.pos, [2]i32{12, 34})
	testing.expect_value(t, me.buttons, sciter.Mouse_Buttons{.PROP_MOUSE_BUTTON})
	testing.expect(t, me.raw == &params)
}

// The two things a mask can do that the header's enum shape could not represent at all: hold nothing,
// and hold more than one. Both used to decode to an invalid enum value - `%!(BAD ENUM VALUE=0)` for an
// ordinary move with no button held, which is the common case rather than a corner of it.
@(test)
test_mouse_buttons_is_a_set :: proc(t: ^testing.T) {
	target := fake_element(0x3100)

	none := sciter.Mouse_Params {
		cmd    = u32(sciter.Mouse_Events.MOUSE_MOVE),
		target = sciter.Helement(target),
	}
	me, _ := sciter_app.mouse_event({group = {.MOUSE}, params = &none})
	testing.expect_value(t, me.buttons, sciter.Mouse_Buttons{})
	testing.expect(t, .MAIN_MOUSE_BUTTON not_in me.buttons, "nothing held")

	both := sciter.Mouse_Params {
		cmd          = u32(sciter.Mouse_Events.MOUSE_DOWN),
		target       = sciter.Helement(target),
		button_state = {.MAIN_MOUSE_BUTTON, .PROP_MOUSE_BUTTON}, // the engine reports 3 for this
	}
	me2, _ := sciter_app.mouse_event({group = {.MOUSE}, params = &both})
	testing.expect(t, .MAIN_MOUSE_BUTTON in me2.buttons, "left is down")
	testing.expect(t, .PROP_MOUSE_BUTTON in me2.buttons, "and so is right")
	testing.expect(t, .MIDDLE_MOUSE_BUTTON not_in me2.buttons)
	testing.expect_value(t, transmute(u32)me2.buttons, u32(3))
}

// `DRAGGING` is 0x100, OR'ed into the code rather than being one of its own, and it sits below
// `EVENT_CODE_MASK` - so it used to survive into `code` and leave a drag's move reading as 258.
@(test)
test_dragging_flag_is_split_off_the_code :: proc(t: ^testing.T) {
	target := fake_element(0x3200)
	over := fake_element(0x3201)

	params := sciter.Mouse_Params {
		cmd      = u32(sciter.Mouse_Events.MOUSE_MOVE) | u32(sciter.Mouse_Events.DRAGGING),
		target   = sciter.Helement(target),
		dragging = sciter.Helement(over),
	}
	me, ok := sciter_app.mouse_event({group = {.MOUSE}, params = &params})
	testing.expect(t, ok)
	testing.expect_value(t, me.code, sciter.Mouse_Events.MOUSE_MOVE)
	testing.expect(t, me.dragging, "the DRAGGING flag was set")
	testing.expect_value(t, me.dragged, over)

	// An ordinary move carries neither.
	plain := sciter.Mouse_Params {
		cmd    = u32(sciter.Mouse_Events.MOUSE_MOVE),
		target = sciter.Helement(target),
	}
	pe, _ := sciter_app.mouse_event({group = {.MOUSE}, params = &plain})
	testing.expect_value(t, pe.code, sciter.Mouse_Events.MOUSE_MOVE)
	testing.expect(t, !pe.dragging)
	testing.expect_value(t, pe.dragged, nil)
}

@(test)
test_key_event_maps_the_params :: proc(t: ^testing.T) {
	target := fake_element(0x4000)

	params := sciter.Key_Params {
		cmd       = u32(sciter.Key_Events.CHAR) | u32(sciter.Phase_Mask.HANDLED),
		target    = sciter.Helement(target),
		key_code  = 'A', // a character for KEY_CHAR, a virtual key for DOWN / UP
		alt_state = sciter.KEYBOARD_STATE_SHIFT, // both shifts, which is what the header's composite SHIFT meant
	}

	ke, ok := sciter_app.key_event({group = {.KEY}, params = &params})
	testing.expect(t, ok)
	testing.expect_value(t, ke.code, sciter.Key_Events.CHAR)
	// HANDLED with no SINKING bit: claimed, and still on the bubbling pass.
	testing.expect_value(t, ke.phase, sciter_app.Event_Phase.Bubbling)
	testing.expect(t, ke.handled)
	testing.expect_value(t, ke.target, target)
	testing.expect_value(t, ke.key_code, u32('A'))
	testing.expect_value(t, ke.modifiers, sciter.KEYBOARD_STATE_SHIFT)
	testing.expect(t, ke.raw == &params)

	// The combination the header's enum had no value for: one shift and one control, 0x41.
	mixed := sciter.Key_Params {
		cmd       = u32(sciter.Key_Events.DOWN),
		target    = sciter.Helement(target),
		key_code  = 'Z',
		alt_state = {.LSHIFT, .LCONTROL},
	}
	mk, _ := sciter_app.key_event({group = {.KEY}, params = &mixed})
	testing.expect(t, .LSHIFT in mk.modifiers)
	testing.expect(t, .LCONTROL in mk.modifiers)
	testing.expect(t, sciter.KEYBOARD_STATE_CONTROL & mk.modifiers != {}, "either control counts as control")
	testing.expect(t, sciter.KEYBOARD_STATE_ALT & mk.modifiers == {}, "no alt")
	testing.expect_value(t, transmute(u32)mk.modifiers, u32(0x41))
}

@(test)
test_timer_event_maps_the_params :: proc(t: ^testing.T) {
	params := sciter.Timer_Params {
		timerId = 42,
	}

	te, ok := sciter_app.timer_event({group = {.TIMER}, params = &params})
	testing.expect(t, ok)
	testing.expect_value(t, te.id, sciter_app.Timer_Id(42))
	testing.expect(t, te.raw == &params)

	// Zero is the element's unnamed timer, not a missing one - `set_timer` defaults to it.
	zero: sciter.Timer_Params
	unnamed, uok := sciter_app.timer_event({group = {.TIMER}, params = &zero})
	testing.expect(t, uok)
	testing.expect_value(t, unnamed.id, sciter_app.Timer_Id(0))
}

// The group is the only thing that says which struct `params` points at, so an accessor that cast
// first and asked later would read past the end of a smaller struct - Key_Params is four fields,
// Mouse_Params is ten.
@(test)
test_typed_params_refuse_the_wrong_group :: proc(t: ^testing.T) {
	behavior: sciter.Behavior_Event_Params
	mouse: sciter.Mouse_Params
	key: sciter.Key_Params

	_, from_mouse := sciter_app.behavior_event({group = {.MOUSE}, params = &mouse})
	testing.expect(t, !from_mouse, "behavior_event must refuse a MOUSE event")

	_, from_key := sciter_app.mouse_event({group = {.KEY}, params = &key})
	testing.expect(t, !from_key, "mouse_event must refuse a KEY event")

	_, from_behavior := sciter_app.key_event({group = {.BEHAVIOR_EVENT}, params = &behavior})
	testing.expect(t, !from_behavior, "key_event must refuse a BEHAVIOR_EVENT")

	timer: sciter.Timer_Params
	_, from_timer := sciter_app.behavior_event({group = {.TIMER}, params = &timer})
	testing.expect(t, !from_timer, "behavior_event must refuse a TIMER event")
	_, timer_from_key := sciter_app.timer_event({group = {.KEY}, params = &key})
	testing.expect(t, !timer_from_key, "timer_event must refuse a KEY event")

	// The engine names exactly one group per call. A set with two in it is not a struct anything can
	// point at, so it is not a BEHAVIOR_EVENT either.
	_, two_groups := sciter_app.behavior_event({group = {.BEHAVIOR_EVENT, .MOUSE}, params = &behavior})
	testing.expect(t, !two_groups)

	// HANDLE_INITIALIZATION is group zero - the empty set - and carries Initialization_Params.
	_, initialization := sciter_app.behavior_event({group = {}, params = &behavior})
	testing.expect(t, !initialization)

	// And nil parameters, which is what a group with nothing to say looks like.
	_, no_params := sciter_app.behavior_event({group = {.BEHAVIOR_EVENT}, params = nil})
	testing.expect(t, !no_params)
	_, no_mouse_params := sciter_app.mouse_event({group = {.MOUSE}, params = nil})
	testing.expect(t, !no_mouse_params)
	_, no_key_params := sciter_app.key_event({group = {.KEY}, params = nil})
	testing.expect(t, !no_key_params)
	_, no_timer_params := sciter_app.timer_event({group = {.TIMER}, params = nil})
	testing.expect(t, !no_timer_params)
}

// ---------------------------------------------------------------------------------------------------
// The trampoline, driven by the engine
//
// A window is needed for the DOM, and a display for the window, so these skip themselves when there is
// neither. The window is created once and never shown; the document is reloaded per test.

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
g_window: sciter_app.Window

@(private = "file")
test_window :: proc(t: ^testing.T) -> (window: sciter_app.Window, ok: bool) {
	if !have_display() {
		fmt.println("skipping - this test needs a window")
		return nil, false
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
		// The engine keeps the argv it is given and the window for the life of the process, so both
		// are allocated outside the test runner's tracking allocator - otherwise every test after
		// this one reports them as a leak.
		context.allocator = runtime.default_allocator()

		sciter_app.init()

		w, err := sciter_app.create_window({width = 400, height = 300})
		testing.expect_value(t, err, nil)
		if w == nil {
			return nil, false
		}
		g_window = w
	}

	// Reload, so each test sees the document with no handler left over from the one before it.
	testing.expect_value(t, sciter_app.load_html(g_window, DOC), nil)
	return g_window, true
}

// What one call into the handler carried. Recorded rather than acted on, so a test can assert about
// the order and the phases rather than about a side effect.
@(private = "file")
Seen :: struct {
	group:   sciter.Event_Groups,
	code:    u32, // phase bits already removed
	phase:   sciter_app.Event_Phase,
	handled: bool,
	target:  sciter_app.Element,
	source:  sciter_app.Element,
	reason:  uintptr,
}

// `Event_Handler` is embedded, not pointed at: the engine stores the handler's address as the tag it
// hands back, so it must not move while attached.
@(private = "file")
Recorder :: struct {
	handler:        sciter_app.Event_Handler,
	seen:           [64]Seen,
	count:          int, // every call, including ones with nothing to decode
	claim:          bool, // what on_event returns
	tag_ok:         bool, // the handler came back as the one that was attached
	ctx_user_index: int, // context.user_index as seen from inside the callback
}

// How many of the events this recorder saw are the one the test sent. Counting every delivery instead
// would make these tests depend on what else the engine happens to deliver - once anything runs the
// message pump, queued events from an earlier test arrive in the middle of a later one.
@(private = "file")
sent_count :: proc(r: ^Recorder) -> (n: int) {
	for entry in r.seen[:min(r.count, len(r.seen))] {
		if entry.group == {.BEHAVIOR_EVENT} && entry.code == u32(sciter.Behavior_Events.FIRST_APPLICATION_EVENT_CODE) {
			n += 1
		}
	}
	return
}

@(private = "file")
sent :: proc(r: ^Recorder, i: int) -> (entry: Seen, ok: bool) {
	n := 0
	for candidate in r.seen[:min(r.count, len(r.seen))] {
		if candidate.group == {.BEHAVIOR_EVENT} &&
		   candidate.code == u32(sciter.Behavior_Events.FIRST_APPLICATION_EVENT_CODE) {
			if n == i {
				return candidate, true
			}
			n += 1
		}
	}
	return {}, false
}

@(private = "file")
record :: proc(handler: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	r := (^Recorder)(handler.user_data)

	r.tag_ok = handler == &r.handler
	r.ctx_user_index = context.user_index

	entry := Seen {
		group  = event.group,
		target = event.element,
	}
	if event.group == {} {
		// HANDLE_INITIALIZATION is group zero, and carries ATTACH or DETACH.
		if event.params != nil {
			entry.code = (^sciter.Initialization_Params)(event.params).cmd
		}
	} else if be, ok := sciter_app.behavior_event(event); ok {
		entry.code = u32(be.code)
		entry.phase = be.phase
		entry.handled = be.handled
		entry.target = be.target
		entry.source = be.source
		entry.reason = be.reason
	}

	if r.count < len(r.seen) {
		r.seen[r.count] = entry
	}
	r.count += 1
	return r.claim
}

// Attaches a recorder to `element` and forgets everything that arrived during the attach itself, so a
// test asserts about what it sends rather than about initialization.
@(private = "file")
attach_recorder :: proc(
	t: ^testing.T,
	element: sciter_app.Element,
	r: ^Recorder,
	subscription := sciter.Event_Groups{.BEHAVIOR_EVENT},
) {
	r.handler = sciter_app.Event_Handler {
		subscription = subscription,
		on_event     = record,
		user_data    = r,
	}
	testing.expect_value(t, sciter_app.attach_handler(element, &r.handler), nil)
	r.count = 0
}

// The root to attach to, and two elements under it. Sending to a descendant rather than to the element
// the handler is attached to is what makes both phases visible - an event sent to the handler's own
// element arrives once.
@(private = "file")
test_elements :: proc(t: ^testing.T) -> (root, tick, reset: sciter_app.Element, ok: bool) {
	window := test_window(t) or_return

	document, rerr := sciter_app.root(window)
	testing.expect_value(t, rerr, nil)
	if rerr != nil {return nil, nil, nil, false}

	first, berr := sciter_app.select_first(document, "#tick")
	testing.expect_value(t, berr, nil)
	if berr != nil {return nil, nil, nil, false}

	second, serr := sciter_app.select_first(document, "#reset")
	testing.expect_value(t, serr, nil)
	if serr != nil {return nil, nil, nil, false}

	return document, first, second, true
}

// Attaching is itself an event: the engine delivers HANDLE_INITIALIZATION / ATTACH, and DETACH on the
// way out. A handler subscribed to nothing still gets both - which is what "initialization events are
// delivered regardless" means.
@(test)
test_attach_and_detach_are_delivered :: proc(t: ^testing.T) {
	root, _, _, ok := test_elements(t)
	if !ok {return}

	r: Recorder
	r.handler = sciter_app.Event_Handler {
		subscription = {},
		on_event     = record,
		user_data    = &r,
	}

	testing.expect_value(t, sciter_app.attach_handler(root, &r.handler), nil)
	testing.expect(t, r.count > 0, "attaching must deliver an initialization event")
	testing.expect_value(t, r.seen[0].group, sciter.Event_Groups{})
	testing.expect_value(t, r.seen[0].code, u32(sciter.Initialization_Events.ATTACH))
	testing.expect(t, r.tag_ok, "the handler must come back as the one that was attached")

	r.count = 0
	testing.expect_value(t, sciter_app.detach_handler(root, &r.handler), nil)
	testing.expect(t, r.count > 0, "detaching must deliver an initialization event")
	testing.expect_value(t, r.seen[0].group, sciter.Event_Groups{})
	testing.expect_value(t, r.seen[0].code, u32(sciter.Initialization_Events.DETACH))
}


// `send_event`'s `source` defaults to nil, and an event sent with a nil source is not delivered at
// all - not to the target, not to anything on the chain. It is not an error either: the call succeeds
// and reports "not handled", which is indistinguishable from an event nobody wanted.
//
// This is the engine's behaviour, pinned here because the default argument makes it easy to hit:
// `send_event(element, code)` is the natural spelling and does nothing. Every other test below names
// a source for that reason.
@(test)
test_send_event_without_a_source_delivers_nothing :: proc(t: ^testing.T) {
	root, tick, reset, ok := test_elements(t)
	if !ok {return}

	r: Recorder
	attach_recorder(t, root, &r)
	defer sciter_app.detach_handler(root, &r.handler)

	handled, err := sciter_app.send_event(tick, sciter.Behavior_Events.FIRST_APPLICATION_EVENT_CODE)
	testing.expect_value(t, err, nil)
	testing.expect(t, !handled)
	testing.expect_value(t, r.count, 0)

	// The same call with a source arrives, so this is about the source and not about the code, the
	// element or the handler.
	testing.expect(t, send(t, tick, reset) == false)
	testing.expect(t, r.count > 0)
}

// Sends the application event code to `to`, attributed to `source`, and returns whether a handler
// claimed it.
@(private = "file")
send :: proc(t: ^testing.T, to, source: sciter_app.Element) -> bool {
	handled, err := sciter_app.send_event(to, sciter.Behavior_Events.FIRST_APPLICATION_EVENT_CODE, source = source)
	testing.expect_value(t, err, nil)
	return handled
}

// The whole round trip: the engine calls the trampoline, it finds the handler through the tag, and the
// event arrives twice - once sinking towards the target, once bubbling back up. An `on_event` that
// ignores the phase acts on every event twice, which is the bug this pins down.
@(test)
test_send_event_arrives_in_both_phases :: proc(t: ^testing.T) {
	root, tick, reset, ok := test_elements(t)
	if !ok {return}

	r: Recorder
	attach_recorder(t, root, &r)
	defer sciter_app.detach_handler(root, &r.handler)

	CODE :: sciter.Behavior_Events.FIRST_APPLICATION_EVENT_CODE
	REASON :: uintptr(42)

	// Three distinct elements, so a mix-up between them cannot pass: the handler is on `root`, the
	// event is sent to `tick`, and `reset` stands in for whatever caused it.
	handled, err := sciter_app.send_event(tick, CODE, source = reset, reason = REASON)
	testing.expect_value(t, err, nil)
	testing.expect(t, !handled, "nothing claimed it, so it is not handled")

	testing.expect_value(t, sent_count(&r), 2)
	sinking, has_sinking := sent(&r, 0)
	bubbling, has_bubbling := sent(&r, 1)
	if !has_sinking || !has_bubbling {return}

	testing.expect_value(t, sinking.phase, sciter_app.Event_Phase.Sinking)
	testing.expect_value(t, bubbling.phase, sciter_app.Event_Phase.Bubbling)

	for entry, i in ([]Seen{sinking, bubbling}) {
		testing.expectf(t, entry.group == {.BEHAVIOR_EVENT}, "event %d: group %v", i, entry.group)

		// The code with the phase bits already off. `cmd` itself differs between the two.
		testing.expect_value(t, entry.code, u32(CODE))
		testing.expect_value(t, entry.reason, REASON)

		// Which handle lands in which field, for a synthesised event, is the opposite of what the
		// argument names suggest: SciterSendEvent's `heSource` becomes BEHAVIOR_EVENT_PARAMS.heTarget
		// (`be.target`), and the element it was sent to becomes `he` (`be.source`). Real events from
		// intrinsic behaviors put the acting element in `be.target`, which is why `send_event`
		// documents itself as not being the same thing as the user doing it.
		testing.expect_value(t, entry.target, reset)
		testing.expect_value(t, entry.source, tick)
	}
}

// Returning true marks the event handled: `send_event` reports it to whoever sent it, and the engine
// sets the HANDLED bit for the rest of the trip. It does not cancel delivery - the bubbling pass still
// arrives, which is what `handled` is for and why a handler that acts on every phase acts twice even
// when something upstream already dealt with the event. The phase stays readable either way, which is
// what lets `phase == .Bubbling` remain a correct way to act exactly once.
@(test)
test_claiming_an_event_marks_it_handled :: proc(t: ^testing.T) {
	root, tick, reset, ok := test_elements(t)
	if !ok {return}

	r: Recorder
	attach_recorder(t, root, &r)
	defer sciter_app.detach_handler(root, &r.handler)
	r.claim = true

	testing.expect(t, send(t, tick, reset), "a handler returning true must be reported as handled")

	testing.expect_value(t, sent_count(&r), 2)
	sinking, has_sinking := sent(&r, 0)
	claimed, has_claimed := sent(&r, 1)
	if !has_sinking || !has_claimed {return}
	testing.expect_value(t, sinking.phase, sciter_app.Event_Phase.Sinking)
	testing.expect(t, !sinking.handled, "nothing has claimed it on the way down")

	// The claimed one is the bubbling pass, and it is still readable as bubbling - which is the whole
	// point of keeping HANDLED off the phase.
	testing.expect_value(t, claimed.phase, sciter_app.Event_Phase.Bubbling)
	testing.expect(t, claimed.handled, "the handler above claimed it")
}

// The engine calls back as `proc "system"`, where Odin's implicit context does not exist. Without the
// capture at attach time the callback would run on a zeroed context - no allocator, no logger - and
// the first allocation inside a handler would be the crash that finds it.
@(test)
test_the_attach_time_context_is_restored :: proc(t: ^testing.T) {
	root, tick, reset, ok := test_elements(t)
	if !ok {return}

	SENTINEL :: 0xC0FFEE

	r: Recorder
	{
		context.user_index = SENTINEL
		attach_recorder(t, root, &r)
	}
	defer sciter_app.detach_handler(root, &r.handler)

	// The ATTACH event ran under the sentinel context too, so clear what it recorded - otherwise this
	// would pass without a single event being delivered.
	r.ctx_user_index = 0

	// And this call is made from a context that knows nothing about the sentinel: what the callback
	// sees has to come from the copy taken at attach time.
	testing.expect(t, context.user_index != SENTINEL)

	send(t, tick, reset)
	testing.expect(t, sent_count(&r) > 0, "nothing was delivered, so the context was never restored")
	testing.expect_value(t, r.ctx_user_index, SENTINEL)
	testing.expect(t, r.tag_ok, "the handler must come back as the one that was attached")
}

// The subscription reply, tested by its consequence. The engine asks once, right after attaching, and
// only sends the groups it was told about - so a handler asking for MOUSE hears no behavior events.
// If the trampoline stopped answering SUBSCRIPTIONS_REQUEST this is the test that would notice.
@(test)
test_unsubscribed_groups_are_not_delivered :: proc(t: ^testing.T) {
	root, tick, reset, ok := test_elements(t)
	if !ok {return}

	r: Recorder
	attach_recorder(t, root, &r, {.MOUSE})

	send(t, tick, reset)
	testing.expect_value(t, sent_count(&r), 0)

	testing.expect_value(t, sciter_app.detach_handler(root, &r.handler), nil)

	// The same handler, subscribed this time, does hear it - without this the test would pass just as
	// well against a trampoline that delivered nothing at all.
	subscribed: Recorder
	attach_recorder(t, root, &subscribed, {.BEHAVIOR_EVENT})
	defer sciter_app.detach_handler(root, &subscribed.handler)

	send(t, tick, reset)
	testing.expect(t, sent_count(&subscribed) > 0, "a subscribed handler must receive the event")
}

@(test)
test_a_detached_handler_stops_hearing :: proc(t: ^testing.T) {
	root, tick, reset, ok := test_elements(t)
	if !ok {return}

	r: Recorder
	attach_recorder(t, root, &r)
	send(t, tick, reset)
	testing.expect(t, sent_count(&r) > 0, "attached, so it hears the event")

	testing.expect_value(t, sciter_app.detach_handler(root, &r.handler), nil)
	r.count = 0

	send(t, tick, reset)
	testing.expect_value(t, sent_count(&r), 0)
}

// A handler with no `on_event` is a legitimate thing to attach - it is how you subscribe to a group
// and decide what to do with it later. The trampoline still has to answer SUBSCRIPTIONS_REQUEST for
// it rather than calling through a nil pointer.
@(test)
test_a_nil_on_event_is_not_a_crash :: proc(t: ^testing.T) {
	root, tick, reset, ok := test_elements(t)
	if !ok {return}

	handler := sciter_app.Event_Handler {
		subscription = {.BEHAVIOR_EVENT},
	}
	testing.expect_value(t, sciter_app.attach_handler(root, &handler), nil)
	defer sciter_app.detach_handler(root, &handler)

	testing.expect(t, !send(t, tick, reset), "a handler that does nothing cannot claim the event")
}

// The window handler covers the whole document, including elements that did not exist when it was
// attached - a different engine entry point, and one that is handed the subscription up front rather
// than being asked for it.
@(test)
test_window_handler_hears_the_document :: proc(t: ^testing.T) {
	_, tick, reset, ok := test_elements(t)
	if !ok {return}
	window := g_window

	r: Recorder
	r.handler = sciter_app.Event_Handler {
		subscription = {.BEHAVIOR_EVENT},
		on_event     = record,
		user_data    = &r,
	}
	testing.expect_value(t, sciter_app.attach_window_handler(window, &r.handler), nil)

	r.count = 0
	send(t, tick, reset)
	testing.expect(t, sent_count(&r) > 0, "a window handler must hear an element inside the document")

	testing.expect_value(t, sciter_app.detach_window_handler(window, &r.handler), nil)
	r.count = 0

	send(t, tick, reset)
	testing.expect_value(t, sent_count(&r), 0)
}

// `post_event` queues rather than delivers. Nothing runs the queue here, which is the point: the call
// returns before any handler has seen it.
@(test)
test_post_event_does_not_deliver_synchronously :: proc(t: ^testing.T) {
	root, tick, reset, ok := test_elements(t)
	if !ok {return}

	r: Recorder
	attach_recorder(t, root, &r)
	defer sciter_app.detach_handler(root, &r.handler)

	err := sciter_app.post_event(tick, sciter.Behavior_Events.FIRST_APPLICATION_EVENT_CODE, source = reset)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, sent_count(&r), 0)
}

// ---------------------------------------------------------------------------------------------------
// Timers
//
// A timer is the engine's own clock rather than a thread: it delivers a `.TIMER` event on the engine's
// thread, inside the message pump, which is why these tests drive `heartbeat` rather than sleeping.
//
// The return value means the opposite of everywhere else - true keeps the timer running, false stops
// it - so the tests below pin that down in both directions.

@(private = "file")
Ticks :: struct {
	handler: sciter_app.Event_Handler,
	ids:     [64]sciter_app.Timer_Id,
	count:   int,
	keep:    bool, // what on_event returns: true to let the timer carry on
}

@(private = "file")
count_ticks :: proc(handler: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	tk := (^Ticks)(handler.user_data)
	te, ok := sciter_app.timer_event(event)
	if !ok {
		return false
	}
	if tk.count < len(tk.ids) {
		tk.ids[tk.count] = te.id
	}
	tk.count += 1
	return tk.keep
}

@(private = "file")
attach_ticks :: proc(t: ^testing.T, element: sciter_app.Element, tk: ^Ticks, keep := true) {
	tk.keep = keep
	tk.handler = sciter_app.Event_Handler {
		subscription = {.TIMER},
		on_event     = count_ticks,
		user_data    = tk,
	}
	testing.expect_value(t, sciter_app.attach_handler(element, &tk.handler), nil)
}

// Timer events are delivered from the pump, so nothing arrives unless the pump runs. `heartbeat`
// services timers without touching input, which is exactly what is wanted with no window shown.
@(private = "file")
pump :: proc(d: time.Duration) {
	start := time.now()
	for time.since(start) < d {
		sciter_app.heartbeat()
	}
}

// How many ticks a PUMP-long run should produce at INTERVAL. Asserted loosely - this is a real clock
// and the test machine is not the only thing running.
@(private = "file")
INTERVAL :: 10 * time.Millisecond
@(private = "file")
PUMP :: 150 * time.Millisecond

// **A tick count is not a deadline.** Pumping for a fixed 150 ms and then asserting how many ticks
// arrived is a race against whatever else the machine is doing: it passes on an idle desktop and fails
// on a loaded CI runner, which is exactly what `test_a_sub_millisecond_interval_still_runs` did. The
// claim each test makes is "the timer runs", not "the timer runs within 150 ms", so the wait is until
// the ticks arrive, with a budget so a genuinely stopped timer still fails rather than hanging.
//
// The negative half - "and then nothing more arrives" - keeps its fixed window, because for that one
// the passage of time *is* the assertion.
@(private = "file")
TICK_BUDGET :: 3 * time.Second

@(private = "file")
pump_until :: proc(done: proc(_: rawptr) -> bool, data: rawptr, budget := TICK_BUDGET) {
	start := time.now()
	for time.since(start) < budget {
		if done(data) {
			return
		}
		sciter_app.heartbeat()
	}
}

@(test)
test_a_timer_ticks_until_it_is_stopped :: proc(t: ^testing.T) {
	root, _, _, ok := test_elements(t)
	if !ok {return}

	tk: Ticks
	attach_ticks(t, root, &tk)
	defer sciter_app.detach_handler(root, &tk.handler)

	testing.expect_value(t, sciter_app.set_timer(root, INTERVAL, 7), nil)
	pump_until(proc(data: rawptr) -> bool {return (^Ticks)(data).count >= 3}, &tk)

	testing.expectf(t, tk.count >= 3, "expected several ticks within the budget, got %d", tk.count)
	for id in tk.ids[:min(tk.count, len(tk.ids))] {
		testing.expect_value(t, id, sciter_app.Timer_Id(7))
	}

	// Stopping is a real stop, not a pause: nothing more arrives.
	testing.expect_value(t, sciter_app.stop_timer(root, 7), nil)
	stopped_at := tk.count
	pump(PUMP)
	testing.expect_value(t, tk.count, stopped_at)

	// Stopping one that is not running is not an error.
	testing.expect_value(t, sciter_app.stop_timer(root, 7), nil)
}

// The one place in this package where `return false` is not the safe default. Everywhere else it means
// "I only looked at this"; here it means "stop", and a handler written to the usual advice gets exactly
// one tick.
@(test)
test_returning_false_from_a_timer_stops_it :: proc(t: ^testing.T) {
	root, _, _, ok := test_elements(t)
	if !ok {return}

	tk: Ticks
	attach_ticks(t, root, &tk, keep = false)
	defer sciter_app.detach_handler(root, &tk.handler)
	defer sciter_app.stop_timer(root, 7)

	testing.expect_value(t, sciter_app.set_timer(root, INTERVAL, 7), nil)
	pump_until(proc(data: rawptr) -> bool {return (^Ticks)(data).count >= 1}, &tk)

	// And then it stays at one, which is the actual claim - so this half waits out a fixed window.
	pump(PUMP)
	testing.expect_value(t, tk.count, 1)
}

// The id is what separates several timers on one element, and it comes back on the event so a handler
// can tell them apart. Stopping one leaves the others running.
@(test)
test_several_timers_on_one_element :: proc(t: ^testing.T) {
	root, _, _, ok := test_elements(t)
	if !ok {return}

	tk: Ticks
	attach_ticks(t, root, &tk)
	defer sciter_app.detach_handler(root, &tk.handler)
	defer sciter_app.stop_timer(root, 1)
	defer sciter_app.stop_timer(root, 2)

	testing.expect_value(t, sciter_app.set_timer(root, INTERVAL, 1), nil)
	testing.expect_value(t, sciter_app.set_timer(root, INTERVAL, 2), nil)
	pump_until(proc(data: rawptr) -> bool {
			tk := (^Ticks)(data)
			return count_id(tk, 1) >= 2 && count_id(tk, 2) >= 2
		}, &tk)

	first, second := count_id(&tk, 1), count_id(&tk, 2)
	testing.expect(t, first >= 2, "the first timer must tick")
	testing.expect(t, second >= 2, "the second timer must tick")

	testing.expect_value(t, sciter_app.stop_timer(root, 1), nil)
	tk.count = 0
	pump_until(proc(data: rawptr) -> bool {return count_id((^Ticks)(data), 2) >= 2}, &tk)

	testing.expect_value(t, count_id(&tk, 1), 0)
	testing.expect(t, count_id(&tk, 2) >= 2, "stopping one timer must not stop the other")
}

@(private = "file")
count_id :: proc(tk: ^Ticks, id: sciter_app.Timer_Id) -> (n: int) {
	for seen in tk.ids[:min(tk.count, len(tk.ids))] {
		if seen == id {
			n += 1
		}
	}
	return
}

// A timer belongs to one element and is delivered to the handlers on *that* element. It does not
// bubble, so a handler on `root` hears nothing about a timer set on a button inside it - which is the
// opposite of how every other group in this file behaves, and looks exactly like a timer that never
// started.
@(test)
test_a_timer_does_not_bubble :: proc(t: ^testing.T) {
	root, tick, _, ok := test_elements(t)
	if !ok {return}

	on_root: Ticks
	attach_ticks(t, root, &on_root)
	defer sciter_app.detach_handler(root, &on_root.handler)

	on_button: Ticks
	attach_ticks(t, tick, &on_button)
	defer sciter_app.detach_handler(tick, &on_button.handler)
	defer sciter_app.stop_timer(tick, 9)

	testing.expect_value(t, sciter_app.set_timer(tick, INTERVAL, 9), nil)
	pump_until(proc(data: rawptr) -> bool {return (^Ticks)(data).count >= 3}, &on_button)

	testing.expect(t, on_button.count >= 3, "the element the timer was set on hears it")
	testing.expect_value(t, on_root.count, 0)
}

// The engine counts whole milliseconds, and zero means stop - so a sub-millisecond interval that was
// rounded down would silently be a stop. `set_timer` raises it to one millisecond instead.
@(test)
test_a_sub_millisecond_interval_still_runs :: proc(t: ^testing.T) {
	root, _, _, ok := test_elements(t)
	if !ok {return}

	tk: Ticks
	attach_ticks(t, root, &tk)
	defer sciter_app.detach_handler(root, &tk.handler)
	defer sciter_app.stop_timer(root, 3)

	testing.expect_value(t, sciter_app.set_timer(root, 100 * time.Microsecond, 3), nil)
	pump_until(proc(data: rawptr) -> bool {return (^Ticks)(data).count > 0}, &tk)

	// One tick is the whole claim: rounding the interval down to zero would have stopped the timer
	// before it ever ran. How many arrive after that is the engine's business, and under a sanitizer
	// it is a good deal fewer.
	testing.expect(t, tk.count > 0, "a sub-millisecond interval must run, not stop")
}

// The gesture accessor, decoded from a hand-built parameter struct.
//
// **The engine never sends `.GESTURE` here**, so there is nothing to drive it with: it needs touch
// hardware, and `GESTURE_CMD` is commented out in `sciter-x-behavior.h` on this SDK, which is why
// `Gesture_Event.code` is a bare number rather than an enum. What can be pinned is the decode - that
// the accessor reads the right fields out of the right struct, refuses an event from another group,
// and splits `cmd` into a code and a phase the way every other accessor here does.
@(test)
test_the_gesture_accessor_decodes_its_parameters :: proc(t: ^testing.T) {
	params := sciter.Gesture_Params {
		cmd = 3 | u32(sciter.Phase_Mask.SINKING),
		target = sciter.Helement(uintptr(0x4000)),
		pos = {x = 11, y = 22},
		pos_view = {x = 33, y = 44},
	}

	ge, ok := sciter_app.gesture_event({group = {.GESTURE}, params = &params})
	testing.expect(t, ok)
	testing.expect_value(t, ge.code, u32(3))
	testing.expect_value(t, ge.phase, sciter_app.Event_Phase.Sinking)
	testing.expect_value(t, ge.target, sciter_app.Element(uintptr(0x4000)))

	// `pos` is element-relative; the view-relative one is only on `raw`.
	testing.expect_value(t, ge.pos, [2]i32{11, 22})
	testing.expect(t, ge.raw == &params)
	testing.expect_value(t, ge.raw.pos_view.x, i32(33))

	// The phase bits come out of `cmd` and do not leak into the code.
	bubbling := sciter.Gesture_Params {
		cmd = 3,
	}
	bg, _ := sciter_app.gesture_event({group = {.GESTURE}, params = &bubbling})
	testing.expect_value(t, bg.code, u32(3))
	testing.expect_value(t, bg.phase, sciter_app.Event_Phase.Bubbling)

	// Another group's parameters are refused rather than reinterpreted, which is the whole reason
	// these accessors return an `ok` at all.
	mouse: sciter.Mouse_Params
	_, from_mouse := sciter_app.gesture_event({group = {.MOUSE}, params = &mouse})
	testing.expect(t, !from_mouse, "gesture_event must refuse a MOUSE event")

	_, no_params := sciter_app.gesture_event({group = {.GESTURE}, params = nil})
	testing.expect(t, !no_params)
}
