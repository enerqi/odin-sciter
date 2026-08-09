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

import "../sciter_app"
import "core:fmt"
import "core:os"

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
	lines:   [dynamic]string,
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
		// arriving at two levels.
		subscription = {.BEHAVIOR_EVENT, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	if err := sciter_app.attach_handler(root, &app.handler); err != nil {
		fmt.eprintln("could not attach the handler:", err)
		os.exit(1)
	}
	defer sciter_app.detach_handler(root, &app.handler)

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
