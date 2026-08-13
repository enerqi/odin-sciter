// Accepting a drop from another application - the engine's EXCHANGE event group.
//
//   just example drag_and_drop        # then drag a file onto the box
//   just example-test drag_and_drop
//
// Drag-and-drop has no API table of its own: it is one event group on an ordinary handler, and the
// whole protocol is which events you consume. Attach a handler to the element that should accept
// drops, subscribe to `{.EXCHANGE}`, and answer `.WILL_ACCEPT_DROP` with `true`.
//
// That answer is not optional, and it is not sufficient either. Measured against an X11 drag source on
// 6.0.4.9, by consuming every combination of the three events that arrive before a drop: the engine
// tells the source "yes" only when **both `.WILL_ACCEPT_DROP` and `.DRAG`** are consumed. Consuming
// `.WILL_ACCEPT_DROP` alone - which is all `sciter-x-behavior.h` asks for - leaves the source told no
// and no `.DROP` arriving. `.DRAG_ENTER` makes no difference either way. With both consumed the
// sequence completes:
//
//   WILL_ACCEPT_DROP -> DRAG_ENTER -> DRAG -> WILL_ACCEPT_DROP -> DROP
//
// each delivered twice, sinking then bubbling.
//
// Two Linux caveats, both measured on the vendored engine and both about the engine rather than these
// bindings:
//
//   - the *drop* side works, but `Exchange_Event.data` came back an empty map, so what was dragged is
//     not readable through this path. `docs/events.md` has the detail.
//   - there is no drag *source*. Script's `Window.this.performDrag(...)` - the only way to start one,
//     there being no native slot for it - returns null immediately, and no EXCHANGE events follow.
//
// `.MOUSE_DRAG_REQUEST` in the `.MOUSE` group is delivered normally, so the "the user has begun
// dragging this element" notification does arrive; it is only starting the system drag that does not.
//
// **So an in-application drag - reordering a list, moving a card between columns - cannot be built on
// this group here.** It is press, move with the button down, release, in the `.MOUSE` group.
// `examples/workbench.odin` reorders its rows that way, and says why in "Reordering by dragging".
package main

import sciter ".."
import "../sciter_app"
import "core:fmt"
import "core:os"
import "core:testing"

DOC :: `<html>
<head><title>odin-sciter: drag_and_drop</title>
<style>
html { background:#1e1e2e; color:#cdd6f4; font:16px system; }
body { padding:2em; margin:0; }
h1 { color:#89b4fa; margin-top:0; }
#drop { border:2px dashed #6c7086; border-radius:8px; padding:3em; text-align:center; color:#a6adc8; }
#drop.over { border-color:#a6e3a1; color:#a6e3a1; background:#313244; }
#log { background:#313244; padding:1em; border-radius:4px; font:13px monospace;
       white-space:pre-wrap; margin-top:1em; min-height:6em; }
</style></head>
<body>
  <h1>drag_and_drop</h1>
  <div id="drop">drag something from another application onto this box</div>
  <div id="log">waiting</div>
</body>
</html>`

App :: struct {
	handler: sciter_app.Event_Handler,
	drop:    sciter_app.Element,
	log:     sciter_app.Element,
	drops:   int,
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

	window, werr := sciter_app.create_window({width = 720, height = 480})
	if werr != nil {
		fmt.eprintln("could not create a window:", werr)
		os.exit(1)
	}
	if err := sciter_app.load_html(window, DOC); err != nil {
		fmt.eprintln("could not load the document:", err)
		os.exit(1)
	}

	app: App
	root, _ := sciter_app.root(window)
	app.drop, _ = sciter_app.select_first(root, "#drop")
	app.log, _ = sciter_app.select_first(root, "#log")

	// Attached to the drop target itself rather than to the root: the handler then hears only about its
	// own subtree, and `pos` arrives relative to that element instead of to the document.
	app.handler = sciter_app.Event_Handler {
		subscription = {.EXCHANGE},
		on_event     = on_event,
		user_data    = &app,
	}
	sciter_app.attach_handler(app.drop, &app.handler)

	sciter_app.show(window)
	sciter_app.run()
	sciter_app.shutdown()
}

on_event :: proc(handler: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	app := (^App)(handler.user_data)

	xe, ok := sciter_app.exchange_event(event)
	if !ok {
		return false
	}

	// Both passes arrive for every event. Acting on one keeps the log readable - and consuming a drop
	// in both passes counts it twice, which was measured rather than guessed.
	if xe.phase != .Sinking {
		return false
	}

	switch xe.code {
	case .WILL_ACCEPT_DROP:
		// Half of the answer that matters; the other half is `.DRAG` below. Without both, the drag
		// source is told no and `.DROP` never comes.
		return true

	case .DRAG_ENTER:
		sciter_app.set_attribute(app.drop, "class", "over")
		log(app, fmt.tprintf("drag entered at %v", xe.pos))

	case .DRAG:
		// The other half. Continuous while the cursor is over the target - fine for a hit test, too
		// noisy to log - but it has to be claimed or the drop is refused.
		return true

	case .DRAG_LEAVE, .DRAG_CANCEL:
		sciter_app.set_attribute(app.drop, "class", "")
		log(app, "drag left")

	case .DROP:
		app.drops += 1
		sciter_app.set_attribute(app.drop, "class", "")

		// What was dropped. On Linux this came back an empty map for a real X11 drop, so the report
		// says what the payload actually was rather than pretending it carried something.
		kind, _ := sciter_app.value_type(xe.data)
		n, _ := sciter_app.value_len(xe.data)
		text, _ := sciter_app.value_to_string(xe.data, context.temp_allocator)
		log(
			app,
			fmt.tprintf(
				"drop #%d at %v, mode %v, data %v with %d entries %q",
				app.drops,
				xe.pos,
				xe.mode,
				kind,
				n,
				text,
			),
		)
		return true

	case .PASTE, .DRAG_REQUEST:
	// Documented N/A upstream.
	}

	return false
}

log :: proc(app: ^App, line: string) {
	fmt.println(line)
	if app.log != nil {
		sciter_app.set_text(app.log, line)
	}
}

// ---------------------------------------------------------------------------------------------------
// Tests
//
// The engine only produces EXCHANGE events during a real system drag, which no test can stage. What is
// testable without one is the decoding: the parameter struct is the engine's, and `exchange_event` has
// to read the right field into the right place and refuse everything that is not an exchange event.

@(test)
test_exchange_event_decodes_its_parameters :: proc(t: ^testing.T) {
	params := sciter.Exchange_Params {
		cmd = u32(sciter.Exchange_Cmd.DROP) | u32(sciter.Phase_Mask.SINKING),
		target = sciter.Helement(uintptr(0x1000)),
		source = sciter.Helement(uintptr(0x2000)),
		pos = {x = 12, y = 34},
		pos_view = {x = 112, y = 134},
		mode = .COPY,
	}

	xe, ok := sciter_app.exchange_event({group = {.EXCHANGE}, params = &params})
	testing.expect(t, ok)
	testing.expect_value(t, xe.code, sciter.Exchange_Cmd.DROP)
	testing.expect_value(t, xe.phase, sciter_app.Event_Phase.Sinking)
	testing.expect_value(t, xe.target, sciter_app.Element(uintptr(0x1000)))
	testing.expect_value(t, xe.source, sciter_app.Element(uintptr(0x2000)))
	testing.expect_value(t, xe.pos, [2]i32{12, 34})
	testing.expect_value(t, xe.view, [2]i32{112, 134})
	testing.expect_value(t, xe.mode, sciter.Dd_Modes.COPY)
	testing.expect(t, xe.data == &params.data, "data must point into the engine's own struct")
	testing.expect(t, xe.raw == &params)
}

// A drop from another application has no source element, and the phase bits have to come off the code
// before it is compared - `DROP | SINKING` is not `DROP`.
@(test)
test_exchange_event_external_drag_has_no_source :: proc(t: ^testing.T) {
	params := sciter.Exchange_Params {
		cmd    = u32(sciter.Exchange_Cmd.WILL_ACCEPT_DROP),
		target = sciter.Helement(uintptr(0x1000)),
		source = nil,
	}

	xe, ok := sciter_app.exchange_event({group = {.EXCHANGE}, params = &params})
	testing.expect(t, ok)
	testing.expect_value(t, xe.code, sciter.Exchange_Cmd.WILL_ACCEPT_DROP)
	testing.expect_value(t, xe.phase, sciter_app.Event_Phase.Bubbling)
	testing.expect_value(t, xe.source, sciter_app.Element(nil))
}

@(test)
test_exchange_event_refuses_other_groups :: proc(t: ^testing.T) {
	mouse: sciter.Mouse_Params
	_, from_mouse := sciter_app.exchange_event({group = {.MOUSE}, params = &mouse})
	testing.expect(t, !from_mouse, "exchange_event must refuse a MOUSE event")

	params: sciter.Exchange_Params
	_, two_groups := sciter_app.exchange_event({group = {.EXCHANGE, .MOUSE}, params = &params})
	testing.expect(t, !two_groups, "the engine names exactly one group per call")

	_, no_params := sciter_app.exchange_event({group = {.EXCHANGE}, params = nil})
	testing.expect(t, !no_params)
}
