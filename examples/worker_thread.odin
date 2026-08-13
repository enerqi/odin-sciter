// Getting work off the UI thread, and its results back on.
//
//   just example worker_thread
//   odin test examples/worker_thread.odin -file      # needs a display; skips itself without one
//
// Sciter is single-threaded: every call in this package has to come from the thread that ran `init`.
// So a background thread cannot touch the DOM, and the question every real application runs into is
// how it gets its answer back to the UI.
//
// `post_callback` is that channel, and it is the only one in the package that is safe to call from
// another thread. Two machine words go in from the worker; they come back out on the engine's thread
// as `Host_Handler.on_posted`, where the DOM is reachable again.
//
//	// on the worker
//	sciter_app.post_callback(window, PROGRESS, uintptr(percent))
//
//	// on the engine's thread, later
//	on_posted :: proc(handler: ^sciter_app.Host_Handler, posted: sciter_app.Posted) { ... }
//
// Two words is not much, which is the point: it is a wake-up, not a transport. Anything larger travels
// in a structure the two threads share - here, a slice the worker fills and a mutex around it - and
// the message just says "there is something to look at".
package main

import "../sciter_app"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

DOC :: `<html>
<head><style>
  html    { background: #1e1e2e; color: #cdd6f4; font: 16px system; }
  body    { padding: 2em; margin: 0; }
  h1      { color: #89b4fa; margin-top: 0; }
  #bar    { display: block; width: 400px; height: 22px; background: #313244; border-radius: 11px; }
  #fill   { display: block; width: 0px; height: 22px; background: #a6e3a1; border-radius: 11px; }
  #log    { margin-top: 1em; padding: .6em 1em; background: #313244; border-radius: 4px;
            font: 14px monospace; white-space: pre-wrap; height: 8em; overflow-y: scroll; }
</style></head>
<body>
  <h1>worker_thread</h1>
  <div id="bar"><div id="fill"></div></div>
  <div id="log">waiting for the worker...</div>
</body>
</html>`

// What the two words mean. The first word is the message kind; the second is its payload.
PROGRESS :: uintptr(1) // lparam = percent done
FOUND :: uintptr(2) // lparam = how many results are in `App.results` now
FINISHED :: uintptr(3) // lparam = unused

App :: struct {
	using host: sciter_app.Host_Handler,
	window:     sciter_app.Window,

	// Shared with the worker. `post_callback` says *that* something changed; the lock is what makes it
	// safe to read *what*.
	mutex:      sync.Mutex,
	results:    [dynamic]string,

	// Engine-thread only, so no lock.
	drawn:      int,
	percent:    int,
	finished:   bool,
}

// Runs on the worker thread. Nothing in here touches the engine except `post_callback`.
work :: proc(app: ^App) {
	for step in 1 ..= 10 {
		time.sleep(80 * time.Millisecond)

		if step % 3 == 0 {
			sync.lock(&app.mutex)
			append(&app.results, fmt.aprintf("result %d", len(app.results) + 1))
			n := len(app.results)
			sync.unlock(&app.mutex)

			sciter_app.post_callback(app.window, FOUND, uintptr(n))
		}
		sciter_app.post_callback(app.window, PROGRESS, uintptr(step * 10))
	}
	sciter_app.post_callback(app.window, FINISHED)
}

// Runs on the engine's thread, one call per posted message, in the order they were posted.
on_posted :: proc(handler: ^sciter_app.Host_Handler, posted: sciter_app.Posted) {
	app := (^App)(handler)

	switch posted.wparam {
	case PROGRESS:
		app.percent = int(posted.lparam)
		if fill, err := find(app, "#fill"); err == nil {
			sciter_app.set_style(fill, "width", fmt.tprintf("%dpx", 4 * app.percent))
		}

	case FOUND:
		// The message carries a count, not the data. The data comes out of the shared slice, under the
		// lock, on this thread - where it is safe to put into the DOM.
		sync.lock(&app.mutex)
		fresh := app.results[app.drawn:]
		lines := make([]string, len(fresh), context.temp_allocator)
		copy(lines, fresh)
		app.drawn = len(app.results)
		sync.unlock(&app.mutex)

		for line in lines {
			log(app, line)
		}

	case FINISHED:
		app.finished = true
		log(app, "worker finished")
		sciter_app.stop()
	}
}

find :: proc(app: ^App, selector: string) -> (element: sciter_app.Element, err: sciter_app.Error) {
	root := sciter_app.root(app.window) or_return
	return sciter_app.select_first(root, selector)
}

log :: proc(app: ^App, line: string) {
	fmt.println(line)
	if el, err := find(app, "#log"); err == nil {
		sciter_app.set_html(el, fmt.tprintf("%s<br>", line), .SIH_APPEND_AFTER_LAST)
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

	window, werr := sciter_app.create_window({width = 620, height = 420})
	if werr != nil {
		fmt.eprintln("could not create a window:", werr)
		os.exit(1)
	}

	// The handler's address is what the engine stores, so it has to outlive the window - hence the heap
	// rather than a local. Install it before loading, as `set_host_handler` asks.
	app := new(App)
	app.window = window
	app.on_posted = on_posted
	app.results = make([dynamic]string)
	sciter_app.set_host_handler(window, app)

	if err := sciter_app.load_html(window, DOC); err != nil {
		fmt.eprintln("could not load the document:", err)
		os.exit(1)
	}

	worker := thread.create_and_start_with_poly_data(app, work)
	defer thread.destroy(worker)

	sciter_app.show(window)
	sciter_app.run() // on_posted runs from inside here; FINISHED stops it
	sciter_app.shutdown()

	fmt.printfln("%d results, %d%% done", len(app.results), app.percent)
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
// Shared by every test in this file, and created on first use. That is deliberate - a window per test
// would be slow, and closing one is itself hazardous (see `close` in sciter_app/window.odin) - but it
// makes the tests here order-coupled: **a test that changes the document must put it back**, usually by
// reloading `DOC`, or it breaks a later test and the failure points at the wrong one.
g_window: sciter_app.Window

@(private = "file")
test_window :: proc(t: ^testing.T) -> (window: sciter_app.Window, ok: bool) {
	if !have_display() {
		fmt.println("no DISPLAY or WAYLAND_DISPLAY - skipping, this test needs a window")
		return nil, false
	}
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}

	if g_window == nil {
		// The engine keeps the argv and the window for the life of the process; allocating them outside
		// the test runner's tracking allocator keeps them from being reported as leaks.
		context.allocator = runtime.default_allocator()

		sciter_app.init()

		w, err := sciter_app.create_window({width = 400, height = 300})
		testing.expect_value(t, err, nil)
		if w == nil {
			return nil, false
		}
		g_window = w
	}
	testing.expect_value(t, sciter_app.load_html(g_window, DOC), nil)
	return g_window, true
}

// A minimal handler that only records what arrived.
@(private = "file")
Recorder :: struct {
	using host: sciter_app.Host_Handler,
	got:        [dynamic][2]uintptr,
}

@(private = "file")
record :: proc(handler: ^sciter_app.Host_Handler, posted: sciter_app.Posted) {
	r := (^Recorder)(handler)
	append(&r.got, [2]uintptr{posted.wparam, posted.lparam})
}

// Pumps until `done` or the budget runs out, so a test never hangs waiting for a message that will
// not come.
@(private = "file")
pump_until :: proc(done: proc(_: rawptr) -> bool, data: rawptr, budget := 2 * time.Second) -> bool {
	start := time.now()
	for time.since(start) < budget {
		if done(data) {
			return true
		}
		sciter_app.run_once()
		sciter_app.heartbeat()
	}
	return done(data)
}

@(test)
test_post_from_this_thread :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	r := Recorder {
		got = make([dynamic][2]uintptr, context.temp_allocator),
	}
	r.on_posted = record
	sciter_app.set_host_handler(window, &r)
	defer sciter_app.set_host_handler(window, nil)

	for i in 1 ..= 3 {
		sciter_app.post_callback(window, uintptr(i), uintptr(i * 100))
	}

	// Nothing is delivered inside the call: it is a post, and the pump is what delivers it.
	testing.expect_value(t, len(r.got), 0)

	pump_until(proc(data: rawptr) -> bool {return len((^Recorder)(data).got) >= 3}, &r)

	testing.expect_value(t, len(r.got), 3)
	if len(r.got) == 3 {
		// And they arrive in the order they were posted.
		testing.expect_value(t, r.got[0], [2]uintptr{1, 100})
		testing.expect_value(t, r.got[1], [2]uintptr{2, 200})
		testing.expect_value(t, r.got[2], [2]uintptr{3, 300})
	}
}

@(test)
test_post_from_a_worker_thread :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	r := Recorder {
		got = make([dynamic][2]uintptr, context.temp_allocator),
	}
	r.on_posted = record
	sciter_app.set_host_handler(window, &r)
	defer sciter_app.set_host_handler(window, nil)

	Job :: struct {
		window: sciter_app.Window,
		posted: bool,
	}
	job := Job {
		window = window,
	}

	worker := thread.create_and_start_with_poly_data(&job, proc(job: ^Job) {
		for i in 1 ..= 4 {
			sciter_app.post_callback(job.window, 7, uintptr(i))
		}
		job.posted = true
	})
	defer thread.destroy(worker)

	pump_until(proc(data: rawptr) -> bool {return len((^Recorder)(data).got) >= 4}, &r)

	testing.expect_value(t, len(r.got), 4)
	for entry, i in r.got {
		testing.expect_value(t, entry, [2]uintptr{7, uintptr(i + 1)})
	}
	testing.expect(t, job.posted, "the worker was never blocked - post_callback returns immediately")
}

@(test)
test_heartbeat_alone_delivers :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	r := Recorder {
		got = make([dynamic][2]uintptr, context.temp_allocator),
	}
	r.on_posted = record
	sciter_app.set_host_handler(window, &r)
	defer sciter_app.set_host_handler(window, nil)

	sciter_app.post_callback(window, 99)

	// `heartbeat` services tasks without processing input, and posted messages are among them - so a
	// thread that is driving the engine without a real message loop still gets them.
	for i in 0 ..< 200 {
		if len(r.got) > 0 {
			break
		}
		sciter_app.heartbeat()
	}
	testing.expect_value(t, len(r.got), 1)
	if len(r.got) == 1 {
		testing.expect_value(t, r.got[0], [2]uintptr{99, 0})
	}
}

@(test)
test_a_window_without_a_handler_drops_the_message :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	// No host handler on this window: the message goes nowhere, silently, and nothing fails.
	sciter_app.set_host_handler(window, nil)
	sciter_app.post_callback(window, 1)
	for _ in 0 ..< 20 {
		sciter_app.run_once()
	}

	// A nil window is the same - dropped rather than refused.
	sciter_app.post_callback(nil, 1)
	for _ in 0 ..< 20 {
		sciter_app.run_once()
	}
}

@(test)
test_callback_param_finds_the_handler :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	state := 1234
	r := Recorder{}
	r.user_data = &state
	sciter_app.set_host_handler(window, &r)
	defer sciter_app.set_host_handler(window, nil)

	// This is how a `proc "system"` callback holding only an HWINDOW gets back to its own state.
	back := (^sciter_app.Host_Handler)(sciter_app.callback_param(window))
	testing.expect_value(t, rawptr(back), rawptr(&r))
	testing.expect_value(t, (^int)(back.user_data)^, 1234)
}
