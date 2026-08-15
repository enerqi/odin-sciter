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
import "core:strconv"
import "core:strings"
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
  #cancel { margin-top: .8em; }
  #log    { margin-top: 1em; padding: .6em 1em; background: #313244; border-radius: 4px;
            font: 14px monospace; white-space: pre-wrap; height: 8em; overflow-y: scroll; }
</style></head>
<body>
  <h1>worker_thread</h1>
  <div id="bar"><div id="fill"></div></div>
  <button id="cancel">cancel</button>
  <div id="log">waiting for the worker...</div>
</body>
</html>`

// What the two words mean. The first word is the message kind; the second is its payload.
PROGRESS :: uintptr(1) // lparam = percent done
FOUND :: uintptr(2) // lparam = how many results are in `App.results` now
FINISHED :: uintptr(3) // lparam = 1 if the work was cancelled, 0 if it ran to the end
FAILED :: uintptr(4) // lparam = the step it failed on; the message is in `App.failure`

// **Failure and cancellation are the two halves nothing else in this package demonstrates**, and both
// are shaped by the same limit: two machine words. A failure has a *message*, which does not fit, so the
// word says "look at the shared struct" exactly as `FOUND` does. Cancellation runs the other way -
// engine thread to worker - and `post_callback` has no reverse, so it is a flag the worker reads.
//
// Neither is optional in a real application. A worker that can only succeed is a worker whose failures
// become silence, and a job with no cancel is a window that cannot be closed while it runs.

App :: struct {
	using host: sciter_app.Host_Handler,
	window:     sciter_app.Window,

	// Shared with the worker. `post_callback` says *that* something changed; the lock is what makes it
	// safe to read *what*.
	mutex:      sync.Mutex,
	results:    [dynamic]string,

	// Written by the worker under `mutex`, read on the engine's thread when `FAILED` arrives.
	failure:    string,

	// Which step should fail, so the demo can show the failing ending. 0 means "do not fail".
	fail_at:    int,

	// The one flag that travels the other way. Atomic rather than mutex-guarded because the worker
	// reads it between steps in a loop and the UI writes it once: a lock here would be a lock taken
	// thousands of times to answer a question that changes at most once.
	cancel:     bool,

	// Engine-thread only, so no lock.
	drawn:      int,
	percent:    int,
	finished:   bool,
	cancelled:  bool,
	failed_at:  int,
}

// Runs on the worker thread. Nothing in here touches the engine except `post_callback`.
//
// The shape to copy is the loop: check for cancellation at the top of each step, and leave through one
// terminal message on every path. A worker that returns without posting anything leaves the UI showing
// a progress bar forever, which is the same bug as a `.DELAYED` request that is never answered.
work :: proc(app: ^App) {
	for step in 1 ..= 10 {
		if sync.atomic_load(&app.cancel) {
			// Cancellation is cooperative: the flag is only read between steps, so the granularity of a
			// cancel is the length of one step. Long steps need the check inside them too.
			sciter_app.post_callback(app.window, FINISHED, 1)
			return
		}

		time.sleep(80 * time.Millisecond)

		// The failure path, driven from the document so the example can show both endings. Anything a
		// real worker does - a file that will not open, a parse that fails, a socket that refuses - lands
		// here, and the message has to travel in the struct because two words cannot carry a string.
		if step == app.fail_at {
			sync.lock(&app.mutex)
			app.failure = fmt.aprintf("step %d could not read the input", step)
			sync.unlock(&app.mutex)

			sciter_app.post_callback(app.window, FAILED, uintptr(step))
			return
		}

		if step % 3 == 0 {
			sync.lock(&app.mutex)
			// The string is made here and read on the engine's thread, so both sides have to agree on
			// the allocator. They do here because a plain `main` leaves `context.allocator` as the
			// default heap on every thread; under a test runner, or an arena installed on one side,
			// they would not - name the allocator when memory crosses.
			append(&app.results, fmt.aprintf("result %d", len(app.results) + 1))
			n := len(app.results)
			sync.unlock(&app.mutex)

			sciter_app.post_callback(app.window, FOUND, uintptr(n))
		}
		sciter_app.post_callback(app.window, PROGRESS, uintptr(step * 10))
	}
	sciter_app.post_callback(app.window, FINISHED, 0)
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

	case FAILED:
		// The word said which step; the message is in the struct, under the same lock the worker wrote
		// it with. Reporting it is DOM work, so it happens here and could not have happened there.
		sync.lock(&app.mutex)
		message := strings.clone(app.failure, context.temp_allocator)
		sync.unlock(&app.mutex)

		app.failed_at = int(posted.lparam)
		app.finished = true
		log(app, fmt.tprintf("worker failed: %s", message))
		sciter_app.stop()

	case FINISHED:
		app.finished = true
		app.cancelled = posted.lparam == 1
		log(app, "worker cancelled" if app.cancelled else "worker finished")
		sciter_app.stop()
	}
}

// Called on the engine's thread - from a button, a window-close handler, whatever the UI offers. It
// does not stop the worker, it *asks*: the worker notices at its next step boundary, and the UI finds
// out when `FINISHED` arrives with a 1. Waiting for that message rather than for the thread is what
// keeps the pump running while the job winds down.
request_cancel :: proc(app: ^App) {
	sync.atomic_store(&app.cancel, true)
	log(app, "cancel requested")
}

// The cancel button. It is an ordinary element handler - the point is only that the click arrives on
// the engine's thread, which is where `request_cancel` has to be called from anyway.
Cancel_Button :: struct {
	using handler: sciter_app.Event_Handler,
	app:           ^App,
}

on_cancel_click :: proc(h: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	button := (^Cancel_Button)(h)
	be, ok := sciter_app.behavior_event(event)
	if !ok || be.code != .BUTTON_CLICK {
		return false
	}
	request_cancel(button.app)
	return true
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

	// `WORKER_FAIL_AT=4 just example worker_thread` shows the failing ending instead of the happy one.
	if at := os.get_env("WORKER_FAIL_AT", context.temp_allocator); at != "" {
		app.fail_at, _ = strconv.parse_int(at)
	}

	button := new(Cancel_Button)
	button.subscription = {.BEHAVIOR_EVENT}
	button.on_event = on_cancel_click
	button.app = app
	if cancel_el, err := find(app, "#cancel"); err == nil {
		sciter_app.attach_handler(cancel_el, button)
	}

	worker := thread.create_and_start_with_poly_data(app, work)
	defer thread.destroy(worker)

	sciter_app.show(window)
	sciter_app.run() // on_posted runs from inside here; FINISHED and FAILED both stop it

	// The pump has stopped, so nothing more can arrive and this join is instant. Joining *before* the
	// terminal message would not deadlock - `post_callback` never blocks - but it would block the
	// engine's thread, which is the one that delivers messages and draws: the UI would freeze for the
	// rest of the job with the terminal message sitting in a queue nobody is pumping.
	thread.join(worker)
	sciter_app.shutdown()

	outcome := "finished"
	if app.cancelled {
		outcome = "cancelled"
	} else if app.failed_at != 0 {
		outcome = fmt.tprintf("failed at step %d", app.failed_at)
	}
	fmt.printfln("%s: %d results, %d%% done", outcome, len(app.results), app.percent)
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
	for _ in 0 ..< 200 {
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

// ---------------------------------------------------------------------------------------------------
// Failure, cancellation, and what ordering really guarantees

@(private = "file")
Job_State :: struct {
	using host: sciter_app.Host_Handler,
	mutex:      sync.Mutex,
	window:     sciter_app.Window,
	failure:    string, // written by the worker under `mutex`
	cancel:     bool, // read by the worker, written here
	steps:      int, // how many steps the worker actually ran
	fail_at:    int,
	got:        [dynamic][2]uintptr,
}

@(private = "file")
job_record :: proc(handler: ^sciter_app.Host_Handler, posted: sciter_app.Posted) {
	job := (^Job_State)(handler)
	append(&job.got, [2]uintptr{posted.wparam, posted.lparam})
}

@(private = "file")
job_worker :: proc(job: ^Job_State) {
	for step in 1 ..= 10 {
		if sync.atomic_load(&job.cancel) {
			sciter_app.post_callback(job.window, FINISHED, 1)
			return
		}
		time.sleep(5 * time.Millisecond)
		sync.atomic_store(&job.steps, step)

		if step == job.fail_at {
			sync.lock(&job.mutex)
			// **Explicitly the default allocator, because the two threads do not share one.** A worker
			// gets a fresh context, and in a test binary the reader's `context.allocator` is the
			// runner's per-test tracking allocator - so a string allocated here and freed there is a
			// bad free, which is what this line was until the tracker said so. Memory that crosses a
			// thread boundary names its allocator on both sides.
			job.failure = fmt.aprintf(
				"step %d could not read the input",
				step,
				allocator = runtime.default_allocator(),
			)
			sync.unlock(&job.mutex)
			sciter_app.post_callback(job.window, FAILED, uintptr(step))
			return
		}
	}
	sciter_app.post_callback(job.window, FINISHED, 0)
}

@(private = "file")
job_terminal :: proc(data: rawptr) -> bool {
	job := (^Job_State)(data)
	for message in job.got {
		if message[0] == FINISHED || message[0] == FAILED {
			return true
		}
	}
	return false
}

// **A worker that can only succeed turns its failures into silence.** The failing path is a message
// like any other, and the only thing that makes it different is that the interesting part - why - does
// not fit in two words, so it travels in the shared struct exactly as a result does.
@(test)
test_a_worker_reports_a_failure_and_the_message_crosses_in_the_shared_struct :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	job := new(Job_State) // the worker outlives this scope on any path that goes wrong
	defer free(job)
	job.window = window
	job.fail_at = 3
	job.on_posted = job_record
	job.got = make([dynamic][2]uintptr, runtime.default_allocator())
	defer delete(job.got)

	sciter_app.set_host_handler(window, job)
	defer sciter_app.set_host_handler(window, nil)

	worker := thread.create_and_start_with_poly_data(job, job_worker)
	defer {thread.join(worker);thread.destroy(worker)}

	testing.expect(t, pump_until(job_terminal, job), "the terminal message should arrive")

	// The word says which step; the message says what happened, read under the same lock.
	last := job.got[len(job.got) - 1]
	testing.expect_value(t, last[0], FAILED)
	testing.expect_value(t, last[1], uintptr(3))

	sync.lock(&job.mutex)
	message := strings.clone(job.failure, context.temp_allocator)
	sync.unlock(&job.mutex)
	testing.expect_value(t, message, "step 3 could not read the input")
	delete(job.failure, runtime.default_allocator())

	// And it stopped there rather than running the remaining seven steps.
	testing.expect_value(t, sync.atomic_load(&job.steps), 3)
}

// **Cancellation runs the other way, and `post_callback` has no other way.** There is no reverse
// channel, so the request is a flag the worker reads between steps - which makes the granularity of a
// cancel exactly one step, and makes "cancelled" an outcome the worker reports rather than something
// the UI decides.
@(test)
test_cancelling_stops_the_worker_between_steps_and_it_says_so :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	job := new(Job_State)
	defer free(job)
	job.window = window
	job.on_posted = job_record
	job.got = make([dynamic][2]uintptr, runtime.default_allocator())
	defer delete(job.got)

	sciter_app.set_host_handler(window, job)
	defer sciter_app.set_host_handler(window, nil)

	worker := thread.create_and_start_with_poly_data(job, job_worker)
	defer {thread.join(worker);thread.destroy(worker)}

	// Let it get going, then ask it to stop. The UI thread never waits for the thread here: it waits
	// for the message, so the pump keeps running while the job winds down.
	time.sleep(20 * time.Millisecond)
	sync.atomic_store(&job.cancel, true)

	testing.expect(t, pump_until(job_terminal, job), "the terminal message should arrive")

	last := job.got[len(job.got) - 1]
	testing.expect_value(t, last[0], FINISHED)
	testing.expect_value(t, last[1], uintptr(1)) // 1 = cancelled, which is not the same as done
	testing.expect(
		t,
		sync.atomic_load(&job.steps) < 10,
		"a cancel that arrives after every step has run has not been measured",
	)
}

@(private = "file")
Poster :: struct {
	window: sciter_app.Window,
	tag:    uintptr,
	count:  int,
}

@(private = "file")
post_many :: proc(p: ^Poster) {
	for i in 1 ..= p.count {
		sciter_app.post_callback(p.window, p.tag, uintptr(i))
	}
}

// **What "in order" means with two workers, measured.** `docs/rules.md` 1 says messages arrive in the
// order they were posted, which was measured from one thread. With two posting concurrently, each
// poster's own messages stay in order - the queue does not shuffle a sender's sequence - and the two
// sequences interleave in no particular way. Nothing serialises the senders, so a design that needs
// "A's message before B's" needs its own sequence number, exactly as `workbench.odin`'s search does.
@(test)
test_two_workers_keep_their_own_order_and_nothing_orders_them_against_each_other :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	PER_WORKER :: 25

	r := Recorder {
		got = make([dynamic][2]uintptr, runtime.default_allocator()),
	}
	defer delete(r.got)
	r.on_posted = record
	sciter_app.set_host_handler(window, &r)
	defer sciter_app.set_host_handler(window, nil)

	one := Poster{window, 100, PER_WORKER}
	two := Poster{window, 200, PER_WORKER}
	a := thread.create_and_start_with_poly_data(&one, post_many)
	b := thread.create_and_start_with_poly_data(&two, post_many)
	thread.join(a);thread.join(b)
	thread.destroy(a);thread.destroy(b)

	pump_until(proc(data: rawptr) -> bool {
			return len((^Recorder)(data).got) >= 2 * PER_WORKER
		}, &r)
	testing.expect_value(t, len(r.got), 2 * PER_WORKER)

	// Per sender, the sequence is intact and complete.
	seen_one, seen_two := 0, 0
	for message in r.got {
		switch message[0] {
		case 100:
			seen_one += 1
			testing.expect_value(t, message[1], uintptr(seen_one))
		case 200:
			seen_two += 1
			testing.expect_value(t, message[1], uintptr(seen_two))
		}
	}
	testing.expect_value(t, seen_one, PER_WORKER)
	testing.expect_value(t, seen_two, PER_WORKER)
}

// ---------------------------------------------------------------------------------------------------
// The affinity guard

@(private = "file")
Off_Thread :: struct {
	done: bool,
}

@(private = "file")
call_from_the_wrong_thread :: proc(state: ^Off_Thread) {
	// `assert_engine_thread` runs the same check the wrapper runs, and touches nothing - which is the
	// point of testing it this way. Calling a real DOM procedure here would prove the same thing by
	// doing the exact damage rule 1 exists to prevent, in a process that has 380 tests left to run.
	sciter_app.assert_engine_thread()
	sync.atomic_store(&state.done, true)
}

// **Rule 1 is the only one of the five with a check, now.** `docs/rules.md` §1 says every call belongs
// on the thread that first used the engine, and until this existed nothing said so at runtime: the
// failure is engine-state corruption that surfaces later, somewhere unrelated, with nothing on the
// stack that did anything wrong.
//
// The guard is on and strict by default in a debug build. A test cannot let it trap, so this switches
// it to counting for the duration - which is what `strict = false` is for - and puts it back.
@(test)
test_a_call_from_another_thread_is_caught :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	when !ODIN_DEBUG {
		// Compiled out entirely: no state, no branch, nothing to check.
		testing.expect_value(t, sciter_app.engine_thread_id(), 0)
		return
	}

	sciter_app.check_thread_affinity(on = true, strict = false)
	defer sciter_app.check_thread_affinity(on = true, strict = true)

	// **The wrapper arms it, not `init`** - a windowless program never calls `init`, so arming on first
	// use is what makes the guard work there too. An ordinary DOM call is all it takes.
	testing.expect_value(t, sciter_app.engine_thread_id(), 0) // forgotten by the call above
	_, rerr := sciter_app.root(window)
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, sciter_app.engine_thread_id(), sync.current_thread_id())
	testing.expect_value(t, sciter_app.thread_affinity_violations(), 0)

	state := new(Off_Thread)
	defer free(state)
	worker := thread.create_and_start_with_poly_data(state, call_from_the_wrong_thread)
	thread.join(worker)
	thread.destroy(worker)

	testing.expect(t, sync.atomic_load(&state.done), "the worker ran")
	testing.expect_value(t, sciter_app.thread_affinity_violations(), 1)

	// And calls from the right thread still cost nothing and count nothing.
	sciter_app.assert_engine_thread()
	testing.expect_value(t, sciter_app.thread_affinity_violations(), 1)
}

// Turning it off is a real off switch - for a test runner told to use several threads, which is the
// one situation where the violations are the runner's and not the application's.
@(test)
test_the_affinity_guard_can_be_turned_off :: proc(t: ^testing.T) {
	when !ODIN_DEBUG {
		return
	}

	sciter_app.check_thread_affinity(on = false)
	defer sciter_app.check_thread_affinity(on = true, strict = true)

	testing.expect_value(t, sciter_app.engine_thread_id(), 0) // forgotten, and not re-armed
	sciter_app.assert_engine_thread() // would arm it if the check were on
	testing.expect_value(t, sciter_app.engine_thread_id(), 0)
	testing.expect_value(t, sciter_app.thread_affinity_violations(), 0)
}
