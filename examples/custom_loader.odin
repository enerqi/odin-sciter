// Serving a document's resources from memory instead of from disk.
//
//   just example custom_loader
//
// Every resource a document refers to - stylesheet, image, script, font - goes past the host first, as
// an `SC_LOAD_DATA` notification. Answering it is how an application ships its UI *inside* the
// executable, and it is the same hook the `archive` approach and any custom URL scheme are built on.
//
// This example invents a scheme, `res://app/`, that the engine has no idea how to fetch, and answers
// every request for it out of a map compiled into the binary. Nothing is read from disk: delete
// `examples/assets/` and this still runs.
//
// Two things worth knowing:
//
//   - install the handler BEFORE loading the document. The document's own load goes through the same
//     callback, and so do the stylesheets it pulls in.
//   - `.OK` with no data means "engine, load it yourself". `.OK` *with* data means "here it is". They
//     are the same return code, distinguished only by whether the request was filled in - which is why
//     `serve` exists rather than a bare return.
package main

import sciter ".."
import "../sciter_app"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// The whole UI, compiled in. The base URL passed to `load_html` is what makes the relative references
// below resolve to `res://app/...`, which is what the engine then asks the host for.
BASE_URL :: "res://app/"

INDEX :: `<html>
<head>
  <title>odin-sciter: custom_loader</title>
  <link rel="stylesheet" href="style.css" />
</head>
<body>
  <h1>custom_loader</h1>
  <p>
    This document, its stylesheet and the image below were all served from a
    <code>map[string][]u8</code> inside the executable. The engine asked; Odin answered.
  </p>
  <img src="logo.svg" />
  <p class="muted">Every URL the engine requested is listed on stdout.</p>
  <div id="served"></div>
</body>
</html>`

STYLE :: `
html { background: #1e1e2e; color: #cdd6f4; font: 16px system; }
body { padding: 2em; margin: 0; }
h1   { color: #89b4fa; margin-top: 0; }
code { background: #313244; padding: 0 .3em; border-radius: 3px; }
img  { width: 96px; height: 96px; }
.muted { color: #6c7086; font-size: 14px; }

/* Two rules with nothing else in the file selecting them, so the tests can tell "this stylesheet
   arrived" from "the document was styled by something". */
#h { color: #00ff00; }
#p { color: #0000ff; }
#served { background: #313244; padding: 1em; border-radius: 4px; font: 13px monospace;
          white-space: pre-wrap; margin-top: 1em; }
`

LOGO :: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">
  <rect x="4" y="4" width="56" height="56" rx="10" fill="#89b4fa"/>
  <path d="M20 40 L32 18 L44 40 Z" fill="#1e1e2e"/>
</svg>`

App :: struct {
	handler:   sciter_app.Host_Handler,
	resources: map[string][]u8,
	requested: [dynamic]string,
	misses:    int,
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
	app.resources["res://app/style.css"] = transmute([]u8)string(STYLE)
	app.resources["res://app/logo.svg"] = transmute([]u8)string(LOGO)
	defer {
		delete(app.resources)
		for uri in app.requested {delete(uri)}
		delete(app.requested)
	}

	window, werr := sciter_app.create_window({width = 720, height = 560})
	if werr != nil {
		fmt.eprintln("could not create a window:", werr)
		os.exit(1)
	}

	// Before the load, not after.
	app.handler = sciter_app.Host_Handler {
		on_load_data = on_load_data,
		user_data    = &app,
	}
	sciter_app.set_host_handler(window, &app.handler)

	if err := sciter_app.load_html(window, INDEX, BASE_URL); err != nil {
		fmt.eprintln("could not load the document:", err)
		os.exit(1)
	}

	fmt.printfln(
		"%d resources requested, %d served from memory, %d passed through to the engine",
		len(app.requested),
		len(app.requested) - app.misses,
		app.misses,
	)

	// Report back into the document, so the window shows what happened too.
	if root, err := sciter_app.root(window); err == nil {
		if box, serr := sciter_app.select_first(root, "#served"); serr == nil {
			sciter_app.set_text(box, strings.join(app.requested[:], "\n", context.temp_allocator))
		}
	}

	sciter_app.show(window)
	sciter_app.run()
	sciter_app.shutdown()
}

on_load_data :: proc(handler: ^sciter_app.Host_Handler, request: ^sciter_app.Load_Request) -> sciter_app.Load_Result {
	app := (^App)(handler.user_data)

	// `request.uri` lives in the temp allocator and is gone after this returns, so the log keeps a copy.
	append(&app.requested, strings.clone(request.uri))
	fmt.printfln("  %-24v %s", request.type, request.uri)

	if data, found := app.resources[request.uri]; found {
		return sciter_app.serve(request, data)
	}

	// Not ours: pass it through. `.OK` without data tells the engine to load it the ordinary way.
	//
	// There is always at least one of these, and it is not a mistake - the engine asks for its own
	// built-ins through the same callback (`sciter:window-frame.js` is the window chrome), and those
	// have to be left alone. A host that answered .DISCARD to everything it did not recognise would
	// break the engine's own resources along with the unknown ones.
	app.misses += 1
	return .OK
}

// ---------------------------------------------------------------------------------------------------
// Tests
//
// A load callback only happens because a document is loading, so these need a window and skip
// themselves without a display. They never show one - see `dom_walk` for why.
//
// The handler's address is stored by the engine, so it cannot live on a test's stack: there is one at
// file scope, reset between tests, and everything it keeps comes from the default allocator because the
// engine goes on calling back while later tests run.

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

// The document the tests load. `#gone` asks for something the loader does not have, which is what makes
// the `.DISCARD` path observable.
@(private = "file")
TEST_DOC :: `<html><head><link rel="stylesheet" href="style.css" /></head>
<body>
  <h1 id="h">served</h1>
  <p id="p">also served</p>
  <img id="logo" src="logo.svg" />
  <img id="gone" src="nothere.png" />
</body></html>`

// How the test handler should answer a URL it does not have.
@(private = "file")
Miss_Policy :: enum {
	Pass_Through, // `.OK` with no data - the engine loads it itself
	Discard, // refuse it
	Discard_Everything, // refuse it, including the engine's own `sciter:` resources
}

@(private = "file")
Loader :: struct {
	handler:     sciter_app.Host_Handler,
	window:      sciter_app.Window,
	policy:      Miss_Policy,
	seen:        [dynamic]string,
	types:       [dynamic]sciter.Sciter_Resource_Type,
	served:      int,
	missed:      int,

	// When set, `style.css` is answered with `data_ready` from inside the callback rather than with
	// `serve`, and the result is recorded here.
	push_inside: bool,
	push_result: sciter_app.Error,

	// When set, `style.css` is not answered at all: the callback returns `.DELAYED` and leaves the
	// request id here for the test to discharge afterwards with `data_ready_async`. The id is the whole
	// point - it is the only thing that identifies the request once the callback has returned.
	delay_style: bool,
	delayed_id:  sciter.Hrequest,
	delayed_uri: string,
}

@(private = "file")
g_loader: Loader

@(private = "file")
// Shared by every test in this file, and created on first use. That is deliberate - a window per test
// would be slow, and closing one is itself hazardous (see `close` in sciter_app/window.odin) - but it
// makes the tests here order-coupled: **a test that changes the document must put it back**, usually by
// reloading `DOC`, or it breaks a later test and the failure points at the wrong one.
g_window: sciter_app.Window

@(private = "file")
test_loader :: proc(t: ^testing.T, policy := Miss_Policy.Pass_Through) -> (ok: bool) {
	if !have_display() {
		fmt.println("skipping - this test needs a window")
		return false
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

	if g_window == nil {
		sciter_app.init()
		w, err := sciter_app.create_window({width = 400, height = 300})
		testing.expect_value(t, err, nil)
		if w == nil {return false}
		g_window = w

		g_loader.handler = sciter_app.Host_Handler {
			on_load_data = test_load_data,
			user_data    = &g_loader,
		}
		sciter_app.set_host_handler(g_window, &g_loader.handler)
	}

	for uri in g_loader.seen {delete(uri)}
	clear(&g_loader.seen)
	clear(&g_loader.types)
	g_loader.served = 0
	g_loader.missed = 0
	g_loader.policy = policy
	g_loader.window = g_window
	g_loader.push_result = nil
	delete(g_loader.delayed_uri)
	g_loader.delayed_uri = ""
	g_loader.delayed_id = nil

	// Before the load, always: the document's own resources go through this callback.
	testing.expect_value(t, sciter_app.load_html(g_window, TEST_DOC, BASE_URL), nil)
	return true
}

@(private = "file")
test_load_data :: proc(
	handler: ^sciter_app.Host_Handler,
	request: ^sciter_app.Load_Request,
) -> sciter_app.Load_Result {
	// `request.uri` is temp-allocated and gone when this returns; the log outlives the test.
	context.allocator = runtime.default_allocator()
	loader := (^Loader)(handler.user_data)
	append(&loader.seen, strings.clone(request.uri))
	append(&loader.types, request.type)

	switch request.uri {
	case BASE_URL + "style.css":
		loader.served += 1
		if loader.delay_style {
			// The promise: the engine goes on without this resource, and whoever returned `.DELAYED`
			// owes it an answer carrying this id - see `data_ready_async`.
			loader.delayed_id = request.raw.requestId
			loader.delayed_uri = strings.clone(request.uri)
			return .DELAYED
		}
		if loader.push_inside {
			// The copying push, from inside the callback - the only place it works.
			loader.push_result = sciter_app.data_ready(loader.window, request.uri, transmute([]u8)string(STYLE))
			return .DELAYED
		}
		return sciter_app.serve(request, transmute([]u8)string(STYLE))

	case BASE_URL + "logo.svg":
		loader.served += 1
		return sciter_app.serve(request, transmute([]u8)string(LOGO))
	}

	loader.missed += 1
	switch loader.policy {
	case .Discard_Everything:
		return .DISCARD
	case .Discard:
		// Ours to refuse; anything else - the engine's own `sciter:` URLs - is passed through.
		if strings.has_prefix(request.uri, BASE_URL) {
			return .DISCARD
		}
		return .OK
	case .Pass_Through:
		return .OK
	}
	return .OK
}

@(private = "file")
requested :: proc(uri: string) -> bool {
	for seen in g_loader.seen {
		if seen == uri {return true}
	}
	return false
}

@(private = "file")
element_style :: proc(selector: string, property: string) -> string {
	root, _ := sciter_app.root(g_window)
	el, err := sciter_app.select_first(root, selector)
	if err != nil {return ""}
	s, _ := sciter_app.style(el, property, context.temp_allocator)
	return s
}

// The claim the example makes, checked: a stylesheet that exists only as a string in the binary is
// fetched through the host and really styles the document. Nothing was read from disk.
@(test)
test_a_stylesheet_served_from_memory_actually_styles_the_document :: proc(t: ^testing.T) {
	if !test_loader(t) {return}

	testing.expect(t, requested(BASE_URL + "style.css"), "the engine should have asked for the stylesheet")
	testing.expect_value(t, element_style("#h", "color"), "#00FF00")
	testing.expect_value(t, element_style("#p", "color"), "#0000FF")
}

// An image, which is the other half: the bytes are decoded by the engine, so a wrong answer here shows
// up as a layout size rather than as an error. The SVG declares 64x64 and lays out at that plus its
// border.
@(test)
test_an_image_served_from_memory_is_decoded_and_laid_out :: proc(t: ^testing.T) {
	if !test_loader(t) {return}

	testing.expect(t, requested(BASE_URL + "logo.svg"))

	root, _ := sciter_app.root(g_window)
	logo, err := sciter_app.select_first(root, "#logo")
	testing.expect_value(t, err, nil)

	box, berr := sciter_app.location(logo, .Border, .View)
	testing.expect_value(t, berr, nil)
	testing.expect(t, box.width >= 64, "an image the engine could not decode would not be 64 wide")
	testing.expect(t, box.height >= 64)

	// Both resources were served from the map, and only the unknown one was not.
	testing.expect_value(t, g_loader.served, 2)
}

// The type is the engine telling the host what it intends the bytes for, before a single byte has been
// handed over. A loader that serves several kinds of thing can dispatch on it rather than on the file
// extension - which is the only option for a URL that has none.
@(test)
test_the_engine_says_what_each_resource_is_for :: proc(t: ^testing.T) {
	if !test_loader(t) {return}

	kinds: map[string]sciter.Sciter_Resource_Type
	defer delete(kinds)
	for uri, i in g_loader.seen {
		kinds[uri] = g_loader.types[i]
	}

	testing.expect_value(t, kinds[BASE_URL + "style.css"], sciter.Sciter_Resource_Type.STYLE)
	testing.expect_value(t, kinds[BASE_URL + "logo.svg"], sciter.Sciter_Resource_Type.IMAGE)
	testing.expect_value(t, kinds[BASE_URL + "nothere.png"], sciter.Sciter_Resource_Type.IMAGE)
}

// **The rule the header does not state.** The engine asks for its own built-in resources through the
// very same callback - `sciter:no-image.png` for a broken image, `sciter:window-frame.js` for the
// window chrome. A host that treats "not in my map" as "refuse it" is refusing the engine's own
// resources along with the unknown ones, which is why the example passes those through.
@(test)
test_the_engine_asks_for_its_own_resources_through_the_same_callback :: proc(t: ^testing.T) {
	if !test_loader(t) {return}

	engine_urls := 0
	for uri in g_loader.seen {
		if strings.has_prefix(uri, "sciter:") {engine_urls += 1}
	}
	testing.expect(t, engine_urls > 0, "the engine loads its own resources through the host too")

	// And they are not in the host's scheme, which is what makes them easy to recognise.
	for uri in g_loader.seen {
		if strings.has_prefix(uri, "sciter:") {
			testing.expect(t, !strings.has_prefix(uri, BASE_URL))
		}
	}
}

// `.DISCARD` on a URL the loader does not have. The engine treats it as a failed load and goes looking
// for its own placeholder - which arrives as another request, through the same callback. So refusing
// one resource produces a second request rather than silence.
@(test)
test_discarding_a_resource_sends_the_engine_looking_for_its_placeholder :: proc(t: ^testing.T) {
	if !test_loader(t, .Discard) {return}

	testing.expect(t, requested(BASE_URL + "nothere.png"), "the missing image was asked for")
	testing.expect(t, requested("sciter:no-image.png"), "and refusing it sent the engine to its placeholder")

	// The element is still laid out - at the placeholder's size, not at nothing.
	root, _ := sciter_app.root(g_window)
	gone, _ := sciter_app.select_first(root, "#gone")
	box, err := sciter_app.location(gone, .Border, .View)
	testing.expect_value(t, err, nil)
	testing.expect(t, box.width > 0 && box.height > 0)

	// The served resources are unaffected by the policy for the ones that miss.
	testing.expect_value(t, element_style("#h", "color"), "#00FF00")
}

// The blunt version of the same policy: discard everything not in the map, the engine's own resources
// included. This is a characterization test - it pins what was measured rather than recommending it.
// The document here survives it, because nothing it needs comes from `sciter:`; a window with the
// engine's own chrome is the case that would not.
@(test)
test_discarding_the_engines_own_resources_is_accepted_but_is_not_a_policy_to_copy :: proc(t: ^testing.T) {
	if !test_loader(t, .Discard_Everything) {return}

	refused := 0
	for uri in g_loader.seen {
		if strings.has_prefix(uri, "sciter:") {refused += 1}
	}
	testing.expect(t, refused > 0, "the engine's own requests were among the ones refused")

	// The host's own resources still arrived, so this is a test of the miss path only.
	testing.expect_value(t, element_style("#h", "color"), "#00FF00")
}

// `serve` of an empty slice is `.DISCARD`, not "an empty resource". That is the wrapper's decision and
// it is the useful one: an empty answer is almost always a lookup that failed, and handing the engine a
// zero-length buffer makes it wait rather than fall back.
@(test)
test_serving_nothing_is_a_discard :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	// `Load_Request.raw` points at the engine's own struct, so a hand-built request needs one to
	// point at - `serve` writes the answer through it.
	raw: sciter.Scn_Load_Data
	request := sciter_app.Load_Request {
		raw = &raw,
	}

	testing.expect_value(t, sciter_app.serve(&request, nil), sciter_app.Load_Result.DISCARD)
	testing.expect_value(t, sciter_app.serve(&request, {}), sciter_app.Load_Result.DISCARD)

	// And the request was left alone rather than half-filled.
	testing.expect(t, raw.outData == nil)
	testing.expect_value(t, raw.outDataSize, u32(0))

	// A non-empty answer fills it in and reports `.OK`.
	body := transmute([]u8)string("x")
	testing.expect_value(t, sciter_app.serve(&request, body), sciter_app.Load_Result.OK)
	testing.expect(t, raw.outData == raw_data(body))
	testing.expect_value(t, raw.outDataSize, u32(1))

	// An empty *but present* resource is `.OK` with a zero size, not a discard - an empty stylesheet
	// and a missing one are different answers, and a document can tell them apart. `nil` above is the
	// spelling of "I have nothing"; a zero-length slice of a real buffer is "the resource is empty".
	present_but_empty := body[:0]
	testing.expect_value(t, sciter_app.serve(&request, present_but_empty), sciter_app.Load_Result.OK)
	testing.expect_value(t, raw.outDataSize, u32(0))
}

// **`data_ready` works from inside the callback and nowhere else.** It is `serve` with a copy rather
// than a borrow - the bytes do not have to outlive the call - and it is *not* the way to answer later,
// which is what its name suggests and what `data_ready_async` is actually for.
@(test)
test_the_copying_push_works_from_inside_the_callback :: proc(t: ^testing.T) {
	if !have_display() {
		fmt.println("skipping - this test needs a window")
		return
	}

	g_loader.push_inside = true
	defer g_loader.push_inside = false

	if !test_loader(t) {return}

	testing.expect_value(t, g_loader.push_result, nil)

	// And the stylesheet it pushed is the one in effect, so the bytes really were taken.
	testing.expect_value(t, element_style("#h", "color"), "#00FF00")
}

// The other half of the same rule: outside a load callback it fails, whether or not there is a request
// in flight for that URL.
@(test)
test_the_copying_push_fails_outside_a_load_callback :: proc(t: ^testing.T) {
	if !test_loader(t) {return}

	// A URL nothing has asked for.
	testing.expect_value(
		t,
		sciter_app.data_ready(g_window, BASE_URL + "never-requested.css", transmute([]u8)string(STYLE)),
		sciter_app.Error(sciter_app.Api_Error.Load_Failed),
	)

	// And one the document really did ask for, moments ago.
	testing.expect_value(
		t,
		sciter_app.data_ready(g_window, BASE_URL + "style.css", transmute([]u8)string(STYLE)),
		sciter_app.Error(sciter_app.Api_Error.Load_Failed),
	)
}

// **`data_ready_async` is the answer-later half, and the request id is what makes it possible.** The
// callback returned `.DELAYED` and kept the id; the load has long since returned; the stylesheet still
// arrives and still styles the document.
//
// Two things this pins that nothing else does. The engine copies the bytes, so `STYLE` does not have to
// outlive the call - unlike `serve`, which borrows. And the resource is applied without a reload: the
// document was laid out without the stylesheet and re-styles itself when it turns up.
//
// **Answer each delayed request exactly once.** Measured on 6.0.4.9: a second `data_ready_async` with
// an id already discharged does not return an error, it segfaults - the same shape as over-releasing a
// borrowed handle. There is no test for that here for the obvious reason.
@(test)
test_a_delayed_request_is_answered_after_the_fact_with_data_ready_async :: proc(t: ^testing.T) {
	if !have_display() {
		fmt.println("skipping - this test needs a window")
		return
	}

	g_loader.delay_style = true
	defer g_loader.delay_style = false

	if !test_loader(t) {return}

	testing.expect(t, g_loader.delayed_id != nil, "the callback should have been handed a request id")
	testing.expect_value(t, g_loader.delayed_uri, BASE_URL + "style.css")

	// Nothing has answered it, so the one rule only this stylesheet carries is not in effect.
	testing.expect(
		t,
		element_style("#h", "color") != "#00FF00",
		"the delayed stylesheet must not be applied before it is answered",
	)

	testing.expect_value(
		t,
		sciter_app.data_ready_async(g_window, g_loader.delayed_uri, transmute([]u8)string(STYLE), g_loader.delayed_id),
		nil,
	)
	sciter_app.heartbeat()

	testing.expect_value(t, element_style("#h", "color"), "#00FF00")
	testing.expect_value(t, element_style("#p", "color"), "#0000FF")
}

@(private = "file")
engine_loaded :: proc(t: ^testing.T) -> bool {
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
	return true
}
