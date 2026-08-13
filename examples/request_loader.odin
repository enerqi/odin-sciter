// Answering the engine's resource loads through the request API: status codes, MIME types, and an
// answer that arrives a second after the question.
//
//   just example request_loader
//   just example-test request_loader
//
// `custom_loader` is the simple half of `SC_LOAD_DATA`: `serve` hands the engine a buffer and the
// callback is over. Every load notification also carries an `HREQUEST` though, and returning `.MYSELF`
// takes that request over completely. Three things follow from it, and this example does all three:
//
//   - `serve_request` answers with a **status code and a MIME type**, which matters for an invented
//     scheme like `res://app/...` where there is no extension to sniff.
//   - `fail_request` answers **404**. The engine reacts as it would to a real one - the broken image
//     below is the engine's own `sciter:no-image.png`, requested through this same callback.
//   - `take_request` keeps the handle alive **past the callback**, so the answer can come from anywhere
//     later. Here a timer stands in for the slow thing; the logo appears about a second after the rest
//     of the document.
//
// What deferring does not do is rewind the document. A `<script src>` answered after parsing has moved
// past it is fetched and never executed - measured, not assumed. Defer what the document consumes when
// it arrives (images, fonts, media), not what it consumes in order.
package main

import sciter ".."
import "../sciter_app"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

BASE_URL :: "res://app/"

// How long the deferred answer is held back for. Long enough to see the document without it.
LATE_BY :: 900 * time.Millisecond

INDEX :: `<html>
<head>
  <title>odin-sciter: request_loader</title>
  <link rel="stylesheet" href="style.css" />
</head>
<body>
  <h1>request_loader</h1>
  <p>
    The stylesheet was served with an explicit MIME type. The first image was answered
    <b>404</b>, so what you see is the engine's own broken-image placeholder. The second was
    <i>deferred</i>: the request was taken over, held past the callback, and answered
    <span id="late-by"></span> later.
  </p>
  <p>
    <img src="broken.svg" /><img id="logo" src="logo.svg" />
  </p>
  <div id="log"></div>
</body>
</html>`

STYLE :: `
html { background: #1e1e2e; color: #cdd6f4; font: 16px system; }
body { padding: 2em; margin: 0; }
h1   { color: #89b4fa; margin-top: 0; }
img  { width: 96px; height: 96px; margin-right: 1em; }
#log { background: #313244; padding: 1em; border-radius: 4px; font: 13px monospace;
       white-space: pre-wrap; margin-top: 1em; }
`

LOGO :: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">
  <rect x="4" y="4" width="56" height="56" rx="10" fill="#a6e3a1"/>
  <path d="M20 40 L32 18 L44 40 Z" fill="#1e1e2e"/>
</svg>`

App :: struct {
	handler:  sciter_app.Host_Handler,

	// The deferred request, kept alive by `take_request` until it is answered.
	deferred: sciter_app.Request,
	log:      [dynamic]string,
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
		for line in app.log {delete(line)}
		delete(app.log)
	}

	window, werr := sciter_app.create_window({width = 720, height = 520})
	if werr != nil {
		fmt.eprintln("could not create a window:", werr)
		os.exit(1)
	}

	// Before the load, as always: the document's own resources go through this callback too.
	app.handler = sciter_app.Host_Handler {
		on_load_data = on_load_data,
		user_data    = &app,
	}
	sciter_app.set_host_handler(window, &app.handler)

	if err := sciter_app.load_html(window, INDEX, BASE_URL); err != nil {
		fmt.eprintln("could not load the document:", err)
		os.exit(1)
	}

	report(window, app.log[:])
	sciter_app.show(window)

	// The pump, one iteration at a time, so the deferred request can be answered from out here. A real
	// application would answer from wherever the data actually came from - a worker's result queue, a
	// socket callback, a database read - on this thread.
	started := time.now()
	for sciter_app.run_once() {
		sciter_app.heartbeat()

		if app.deferred != nil && time.since(started) > LATE_BY {
			data := transmute([]u8)string(LOGO)

			// The answer: status, bytes, and the reference `take_request` took, given back.
			if err := sciter_app.succeed_request(app.deferred, data, 200); err != nil {
				fmt.eprintln("could not answer the deferred request:", err)
			}
			sciter_app.unuse_request(app.deferred)
			app.deferred = nil

			fmt.printfln("answered res://app/logo.svg after %v", time.since(started))
		}
	}

	sciter_app.shutdown()
}

on_load_data :: proc(handler: ^sciter_app.Host_Handler, request: ^sciter_app.Load_Request) -> sciter_app.Load_Result {
	app := (^App)(handler.user_data)

	// Everything the request knows about itself, read off the handle rather than the notification.
	rq := sciter_app.request_of(request)
	method, _ := sciter_app.request_method(rq)
	append(&app.log, fmt.aprintf("%-4s %-8v %s", method, request.type, request.uri))

	switch request.uri {
	case "res://app/style.css":
		// A URL with no extension worth sniffing, so the type is stated outright.
		return sciter_app.serve_request(request, transmute([]u8)string(STYLE), mime = "text/css")

	case "res://app/broken.svg":
		// A real 404, not a silent discard. The engine will ask for `sciter:no-image.png` next - its
		// own built-in placeholder, which has to be left to the engine.
		sciter_app.fail_request(rq, 404)
		return .MYSELF

	case "res://app/logo.svg":
		// Taken over and held. `.MYSELF` is what stops the engine from loading it; the reference is
		// what stops the handle from being recycled the moment this returns.
		rq, result := sciter_app.take_request(request)
		app.deferred = rq
		return result
	}

	// Not ours - the engine's own resources come through here too.
	return .OK
}

// Puts the log into the document, so the window shows what the callback saw.
report :: proc(window: sciter_app.Window, lines: []string) {
	root, err := sciter_app.root(window)
	if err != nil {return}

	if box, berr := sciter_app.select_first(root, "#log"); berr == nil {
		text: string
		for line in lines {
			text = fmt.tprintf("%s%s\n", text, line)
		}
		sciter_app.set_text(box, text)
	}
	if span, serr := sciter_app.select_first(root, "#late-by"); serr == nil {
		sciter_app.set_text(span, fmt.tprintf("%v", LATE_BY))
	}
}

// ---------------------------------------------------------------------------------------------------
// Tests

@(private = "file")
engine_loaded :: proc(t: ^testing.T) -> bool {
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}
	return true
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


@(test)
test_request_api_table_resolves :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	// One table reached through another: ISciterAPI.GetSciterRequestAPI. A nil here would make every
	// call in request.odin a nil dereference, so it is worth its own test.
	testing.expect(t, sciter_app.request_api() != nil, "GetSciterRequestAPI must return a table")
}

// A nil handle is the shape of "the notification carried no request". Every wrapper has to answer it
// rather than dereference it, and the answer is the engine's own BAD_PARAM.
@(test)
test_nil_request_is_bad_param :: proc(t: ^testing.T) {
	bad := sciter_app.Error(sciter.Request_Result.BAD_PARAM)

	testing.expect_value(t, sciter_app.use_request(nil), bad)
	testing.expect_value(t, sciter_app.unuse_request(nil), bad)
	testing.expect_value(t, sciter_app.succeed_request(nil, nil), bad)
	testing.expect_value(t, sciter_app.fail_request(nil), bad)
	testing.expect_value(t, sciter_app.append_request_data(nil, nil), bad)
	testing.expect_value(t, sciter_app.set_request_header(nil, "a", "b"), bad)
	testing.expect_value(t, sciter_app.set_response_header(nil, "a", "b"), bad)
	testing.expect_value(t, sciter_app.set_request_mime(nil, "text/css"), bad)
	testing.expect_value(t, sciter_app.set_request_encoding(nil, "utf-8"), bad)

	_, url_err := sciter_app.request_url(nil)
	testing.expect_value(t, url_err, bad)
	_, method_err := sciter_app.request_method(nil)
	testing.expect_value(t, method_err, bad)
	_, type_err := sciter_app.request_data_type(nil)
	testing.expect_value(t, type_err, bad)
	_, _, times_err := sciter_app.request_times(nil)
	testing.expect_value(t, times_err, bad)
	_, _, time_err := sciter_app.request_time(nil)
	testing.expect_value(t, time_err, bad)
	_, _, status_err := sciter_app.request_status(nil)
	testing.expect_value(t, status_err, bad)
	_, data_err := sciter_app.request_data(nil)
	testing.expect_value(t, data_err, bad)
	_, headers_err := sciter_app.request_headers(nil)
	testing.expect_value(t, headers_err, bad)
	_, params_err := sciter_app.request_parameters(nil)
	testing.expect_value(t, params_err, bad)
	_, requestor_err := sciter_app.request_requestor(nil)
	testing.expect_value(t, requestor_err, bad)
}

// ---------------------------------------------------------------------------------------------------
// Against the engine
//
// A request handle exists only because the engine made one, so these need a window and a document, and
// skip themselves when there is no display.
//
// Two rules the engine imposes, both learned the hard way here:
//
//   - the host handler's address is stored by the engine, so the handler cannot live on a test's stack.
//     There is one, at file scope, reset between tests.
//   - anything the handler keeps outlives the test that installed it - the engine goes on calling back
//     while later tests run - so the handler's own allocations use the default allocator rather than
//     the test runner's tracking one.

@(private = "file")
TEST_DOC :: `<html><head><link rel="stylesheet" href="t.css?theme=dark&size=14" /></head>
<body><img id="img" src="t.svg" /></body></html>`

@(private = "file")
TEST_CSS :: "h1 { color: #ff0000; }"

// What the stylesheet request knew about itself, recorded inside the callback.
@(private = "file")
Snapshot :: struct {
	url:            string,
	method:         string, // borrowed from the engine
	type:           sciter.Sciter_Resource_Type,
	state_before:   sciter.Request_State,
	status_before:  u32,
	state_after:    sciter.Request_State,
	status_after:   u32,
	data_after:     string,
	header_count:   sciter_app.Request_Header_Index,
	requestor_tag:  string, // borrowed from the engine

	// The rest of the getters, read at the same two moments.
	content_url:    string,
	mime_before:    string,
	mime_after:     string,
	proxy_host:     string,
	proxy_port:     u32,
	param_count:    sciter_app.Parameter_Index,
	response_count: sciter_app.Response_Header_Index,
	responses:      []Name_Value,
}

// `sciter_app.Name_Value` under a shorter name, since half this file is pairs.
@(private = "file")
Name_Value :: sciter_app.Name_Value

// What the `http_request` route saw. Its parameters are the point: a URL served by the host has no
// query string to parse, so this is the only way anything reaches `request_parameter`.
@(private = "file")
Api_Call :: struct {
	seen:         bool,
	url:          string,
	method:       string, // borrowed
	params:       []Name_Value,
	param_count:  sciter_app.Parameter_Index,
	out_of_range: sciter_app.Error,
}

@(private = "file")
Probe :: struct {
	handler:    sciter_app.Host_Handler,
	seen:       [dynamic]string, // every uri, in order
	css:        Snapshot,
	deferred:   sciter_app.Request, // the image, held past the callback
	fail_image: bool, // 404 the image instead of deferring it
	api:        Api_Call,
}

// One handler, at a fixed address, for the life of the test binary.
@(private = "file")
g_probe: Probe

@(private = "file")
probe_reset :: proc() {
	context.allocator = runtime.default_allocator()

	for uri in g_probe.seen {delete(uri)}
	clear(&g_probe.seen)

	delete(g_probe.css.url)
	delete(g_probe.css.data_after)
	delete(g_probe.css.content_url)
	delete(g_probe.css.mime_before)
	delete(g_probe.css.mime_after)
	delete(g_probe.css.proxy_host)
	sciter_app.delete_name_values(g_probe.css.responses)
	g_probe.css = {}

	delete(g_probe.api.url)
	sciter_app.delete_name_values(g_probe.api.params)
	g_probe.api = {}

	g_probe.deferred = nil
	g_probe.fail_image = false
}

@(private = "file")
probe_load_data :: proc(
	handler: ^sciter_app.Host_Handler,
	request: ^sciter_app.Load_Request,
) -> sciter_app.Load_Result {
	// `request.uri` is temp-allocated and gone when this returns, and everything kept here outlives
	// the test that installed the handler.
	context.allocator = runtime.default_allocator()
	append(&g_probe.seen, strings.clone(request.uri))

	rq := sciter_app.request_of(request)

	switch request.uri {
	case "res://test/t.css?theme=dark&size=14":
		s := &g_probe.css
		s.url, _ = sciter_app.request_url(rq)
		s.method, _ = sciter_app.request_method(rq)
		s.type, _ = sciter_app.request_data_type(rq)
		s.state_before, s.status_before, _ = sciter_app.request_status(rq)
		s.content_url, _ = sciter_app.request_content_url(rq)
		s.mime_before, _ = sciter_app.request_mime(rq)
		s.proxy_host, _ = sciter_app.request_proxy_host(rq)
		s.proxy_port, _ = sciter_app.request_proxy_port(rq)
		s.param_count, _ = sciter_app.request_parameter_count(rq)

		if el, err := sciter_app.request_requestor(rq); err == nil {
			s.requestor_tag, _ = sciter_app.tag(el)
		}

		// A header set on the request reads back out of it, which is the round trip worth testing:
		// the engine owns the list and the strings cross the UTF-16 boundary twice.
		sciter_app.set_request_header(rq, "X-Odin", "1")
		s.header_count, _ = sciter_app.request_header_count(rq)

		// The same round trip on the response side, which is a separate list.
		sciter_app.set_response_header(rq, "X-Answer", "42")
		sciter_app.set_response_header(rq, "Content-Language", "en")

		result := sciter_app.serve_request(request, transmute([]u8)string(TEST_CSS), mime = "text/css")
		s.state_after, s.status_after, _ = sciter_app.request_status(rq)
		if data, err := sciter_app.request_data(rq); err == nil {
			s.data_after = string(data)
		}
		s.mime_after, _ = sciter_app.request_mime(rq)
		s.response_count, _ = sciter_app.response_header_count(rq)
		s.responses, _ = sciter_app.response_headers(rq)
		return result

	case "res://test/api":
		// Driven by `http_request`, not by the document - see `test_http_request_parameters...`.
		a := &g_probe.api
		a.seen = true
		a.url, _ = sciter_app.request_url(rq)
		a.method, _ = sciter_app.request_method(rq)
		a.param_count, _ = sciter_app.request_parameter_count(rq)
		a.params, _ = sciter_app.request_parameters(rq)
		_, a.out_of_range = sciter_app.request_parameter(rq, a.param_count)
		sciter_app.succeed_request(rq, transmute([]u8)string("ok"))
		return .MYSELF

	case "res://test/t.svg":
		if g_probe.fail_image {
			sciter_app.fail_request(rq, 404)
			return .MYSELF
		}
		held, result := sciter_app.take_request(request)
		g_probe.deferred = held
		return result
	}
	return .OK
}

@(private = "file")
// Shared by every test in this file, and created on first use. That is deliberate - a window per test
// would be slow, and closing one is itself hazardous (see `close` in sciter_app/window.odin) - but it
// makes the tests here order-coupled: **a test that changes the document must put it back**, usually by
// reloading `DOC`, or it breaks a later test and the failure points at the wrong one.
g_window: sciter_app.Window

// Creates the window once, installs the one handler once, and reloads the document per test so each
// one sees a fresh set of requests.
@(private = "file")
test_document :: proc(t: ^testing.T, fail_image := false) -> bool {
	if !have_display() {
		fmt.println("no DISPLAY or WAYLAND_DISPLAY - skipping, this test needs a window")
		return false
	}
	if !engine_loaded(t) {return false}

	if g_window == nil {
		// The engine keeps the argv it is given and the window for the life of the process, so both
		// are allocated outside the test runner's tracking allocator - otherwise every test after
		// this one reports them as a leak.
		context.allocator = runtime.default_allocator()

		sciter_app.init()

		w, err := sciter_app.create_window({width = 400, height = 300})
		testing.expect_value(t, err, nil)
		if w == nil {return false}
		g_window = w

		g_probe.handler = {
			on_load_data = probe_load_data,
			user_data    = &g_probe,
		}
		sciter_app.set_host_handler(g_window, &g_probe.handler)
	}

	probe_reset()
	g_probe.fail_image = fail_image
	testing.expect_value(t, sciter_app.load_html(g_window, TEST_DOC, "res://test/"), nil)
	return true
}

// Answers whatever the document is still waiting on, so the next test starts clean.
@(private = "file")
answer_deferred :: proc() {
	if g_probe.deferred == nil {return}
	sciter_app.succeed_request(g_probe.deferred, transmute([]u8)string(LOGO))
	sciter_app.unuse_request(g_probe.deferred)
	g_probe.deferred = nil
}

@(test)
test_request_reads_and_answers :: proc(t: ^testing.T) {
	if !test_document(t) {return}
	defer answer_deferred()

	s := g_probe.css
	// The query string is part of the URL and stays there - see
	// `test_a_query_string_stays_in_the_url_and_is_not_a_parameter`.
	testing.expect_value(t, s.url, "res://test/t.css?theme=dark&size=14")
	testing.expect_value(t, s.method, "GET")
	testing.expect_value(t, s.type, sciter.Sciter_Resource_Type.STYLE)

	// Before the answer the request is pending with no status at all; afterwards it carries the one
	// `serve_request` was given, and the body reads back out of the engine.
	testing.expect_value(t, s.state_before, sciter.Request_State.PENDING)
	testing.expect_value(t, s.status_before, u32(0))
	testing.expect_value(t, s.state_after, sciter.Request_State.SUCCESS)
	testing.expect_value(t, s.status_after, u32(200))
	testing.expect_value(t, s.data_after, TEST_CSS)

	testing.expect_value(t, s.header_count, 1)

	// Not the <link> that named the stylesheet: the element the resource is *for*.
	testing.expect_value(t, s.requestor_tag, "html")
}

// A 404 is answered as a 404, and the engine reacts to it as it would to a real one.
@(test)
test_failed_request_falls_back_to_the_engines_placeholder :: proc(t: ^testing.T) {
	if !test_document(t, fail_image = true) {return}
	defer answer_deferred()

	asked_for_placeholder := false
	for uri in g_probe.seen {
		if uri == "sciter:no-image.png" {asked_for_placeholder = true}
	}
	testing.expect(t, asked_for_placeholder, "a 404'd image should send the engine looking for sciter:no-image.png")
}

// The point of `take_request`: a handle that is still good after the callback that produced it returned.
@(test)
test_deferred_request_survives_the_callback :: proc(t: ^testing.T) {
	if !test_document(t) {return}

	if !testing.expect(t, g_probe.deferred != nil, "the image request should have been taken over") {
		return
	}

	// Still readable out here, after the callback is long over.
	url, err := sciter_app.request_url(g_probe.deferred, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, url, "res://test/t.svg")

	state, status, _ := sciter_app.request_status(g_probe.deferred)
	testing.expect_value(t, state, sciter.Request_State.PENDING)
	testing.expect_value(t, status, u32(0))

	testing.expect_value(t, sciter_app.succeed_request(g_probe.deferred, transmute([]u8)string(LOGO)), nil)

	state, status, _ = sciter_app.request_status(g_probe.deferred)
	testing.expect_value(t, state, sciter.Request_State.SUCCESS)
	testing.expect_value(t, status, u32(200))

	testing.expect_value(t, sciter_app.unuse_request(g_probe.deferred), nil)
	g_probe.deferred = nil
}

// The getters that describe a request rather than answer it. Most of them are network-shaped and this
// engine is not doing any networking here, so what they answer is the interesting part - and "empty" is
// a fine thing to assert as long as it is written down rather than assumed.
@(test)
test_the_network_shaped_getters_answer_empty_for_a_request_the_host_serves :: proc(t: ^testing.T) {
	if !test_document(t) {return}
	defer answer_deferred()

	s := g_probe.css

	// There is no proxy, and the engine says so with a value rather than with `.NOTSUPPORTED`. Code
	// that reads these has to tell "no proxy" apart from "not supported", and here there is only one.
	testing.expect_value(t, s.proxy_host, "")
	testing.expect_value(t, s.proxy_port, u32(0))

	// `request_content_url` is the URL the content finally came from, after any redirect. Nothing is
	// redirecting a `res://` URL the host answers, so it is empty - not a copy of the request URL.
	testing.expect_value(t, s.content_url, "")
}

// **`request_mime` is the *response* type, not a hint from the requestor.** It is empty while the
// request is pending and carries whatever the answer set once there is one - so it reads back what
// `serve_request` was told, which makes it the way to check what a request was actually answered as.
@(test)
test_the_request_mime_is_empty_until_the_request_is_answered :: proc(t: ^testing.T) {
	if !test_document(t) {return}
	defer answer_deferred()

	testing.expect_value(t, g_probe.css.mime_before, "")
	testing.expect_value(t, g_probe.css.mime_after, "text/css")
}

// Response headers are a separate list from request headers, and both round-trip through the engine's
// UTF-16. **The engine adds one of its own** when the request is answered - an empty
// `Content-Encoding` - so the count is not just what the host set.
@(test)
test_response_headers_round_trip_and_the_engine_adds_one_of_its_own :: proc(t: ^testing.T) {
	if !test_document(t) {return}
	defer answer_deferred()

	s := g_probe.css

	// One on the request side, two set here on the response side, plus the engine's.
	testing.expect_value(t, s.header_count, 1)
	testing.expect_value(t, s.response_count, 3)
	testing.expect_value(t, len(s.responses), 3)

	found: map[string]string
	defer delete(found)
	for pair in s.responses {
		found[pair.name] = pair.value
	}
	testing.expect_value(t, found["X-Answer"], "42")
	testing.expect_value(t, found["Content-Language"], "en")

	// The engine's own, which is there whether or not anything asked for it.
	_, engines := found["Content-Encoding"]
	testing.expect(t, engines, "the engine appends a Content-Encoding header when the request is answered")
}

// **A query string in the URL is not parsed into parameters.** The document asks for
// `t.css?theme=dark&size=14`; `request_url` hands back the whole thing, query and all, and
// `request_parameter_count` is zero. Anything that wants the fields has to split the URL itself.
@(test)
test_a_query_string_stays_in_the_url_and_is_not_a_parameter :: proc(t: ^testing.T) {
	if !test_document(t) {return}
	defer answer_deferred()

	testing.expect_value(t, g_probe.css.url, "res://test/t.css?theme=dark&size=14")
	testing.expect_value(t, g_probe.css.param_count, 0)
}

// So where do parameters come from? `http_request`, which is the only thing here that has any. It works
// against a `res://` URL the host answers, so this needs no network and no `.SOCKET_IO`.
//
// Note what the engine does *not* do: for a host-served URL it leaves the URL alone and keeps the
// parameters as parameters, for `.Get` as well as `.Post` - the query-string encoding described on
// `http_request` is what happens on the way out to a real server.
@(test)
test_http_request_parameters_arrive_as_request_parameters_with_no_network :: proc(t: ^testing.T) {
	for method in ([]sciter_app.Http_Method{.Get, .Post}) {
		if !test_document(t) {return}
		defer answer_deferred()

		root, rerr := sciter_app.root(g_window)
		testing.expect_value(t, rerr, nil)
		target, terr := sciter_app.select_first(root, "#img")
		testing.expect_value(t, terr, nil)

		err := sciter_app.http_request(target, "res://test/api", method, {{"page", "2"}, {"q", "two words"}})
		testing.expect_value(t, err, nil)

		// The request is delivered on the engine's thread, so pump until the callback has run.
		for _ in 0 ..< 40 {
			if g_probe.api.seen {break}
			sciter_app.run_once()
			sciter_app.heartbeat()
		}

		if !testing.expectf(t, g_probe.api.seen, "%v: the request never reached the host", method) {
			continue
		}

		a := g_probe.api
		testing.expectf(t, a.url == "res://test/api", "%v: the URL should be untouched, got %q", method, a.url)
		testing.expect_value(t, a.param_count, 2)
		testing.expect_value(t, len(a.params), 2)
		testing.expect_value(t, a.params[0].name, "page")
		testing.expect_value(t, a.params[0].value, "2")
		testing.expect_value(t, a.params[1].name, "q")

		// Unescaped on the way in - the space is a space, not `%20`.
		testing.expect_value(t, a.params[1].value, "two words")

		// Past the end is `.FAILURE` rather than `.BAD_PARAM`: the handle was fine, the index was not.
		testing.expect_value(t, a.out_of_range, sciter_app.Error(sciter.Request_Result.FAILURE))
	}
}

// The indexed getters and the whole-list ones are two views of the same thing, and they agree. The list
// forms allocate, and `delete_name_values` is what frees them - including the strings inside, which a
// plain `delete` on the slice would leak.
@(test)
test_the_indexed_and_whole_list_header_getters_agree :: proc(t: ^testing.T) {
	if !test_document(t) {return}
	defer answer_deferred()

	if !testing.expect(t, g_probe.deferred != nil, "the image request should have been taken over") {
		return
	}
	rq := g_probe.deferred

	testing.expect_value(t, sciter_app.set_request_header(rq, "X-One", "1"), nil)
	testing.expect_value(t, sciter_app.set_request_header(rq, "X-Two", "2"), nil)
	testing.expect_value(t, sciter_app.set_response_header(rq, "X-Three", "3"), nil)

	request_count, rcerr := sciter_app.request_header_count(rq)
	testing.expect_value(t, rcerr, nil)
	testing.expect_value(t, request_count, 2)

	// The indexed form, one at a time.
	for i in 0 ..< request_count {
		pair, err := sciter_app.request_header(rq, i, context.temp_allocator)
		testing.expect_value(t, err, nil)
		testing.expect(t, pair.name != "" && pair.value != "")
	}

	// And the same list in one call.
	all, aerr := sciter_app.request_headers(rq)
	testing.expect_value(t, aerr, nil)
	defer sciter_app.delete_name_values(all)
	testing.expect_value(t, sciter_app.Request_Header_Index(len(all)), request_count)

	first, ferr := sciter_app.request_header(rq, 0, context.temp_allocator)
	testing.expect_value(t, ferr, nil)
	testing.expect_value(t, all[0].name, first.name)
	testing.expect_value(t, all[0].value, first.value)

	// The response side, the same way round.
	response_count, rperr := sciter_app.response_header_count(rq)
	testing.expect_value(t, rperr, nil)
	testing.expect_value(t, response_count, 1)

	one, oerr := sciter_app.response_header(rq, 0, context.temp_allocator)
	testing.expect_value(t, oerr, nil)
	testing.expect_value(t, one.name, "X-Three")
	testing.expect_value(t, one.value, "3")

	// Timing. The request is still open here - `answer_deferred` runs on the way out - so `ended` is 0
	// and `request_time` says so rather than underflowing the subtraction.
	started, ended, terr := sciter_app.request_times(rq)
	testing.expect_value(t, terr, nil)
	testing.expect_value(t, ended, u32(0))
	_ = started

	elapsed, done, eerr := sciter_app.request_time(rq)
	testing.expect_value(t, eerr, nil)
	testing.expect(t, !done, "still pending, so there is no duration yet")
	testing.expect_value(t, elapsed, time.Duration(0))

	responses, rserr := sciter_app.response_headers(rq)
	testing.expect_value(t, rserr, nil)
	defer sciter_app.delete_name_values(responses)
	testing.expect_value(t, len(responses), 1)
	testing.expect_value(t, responses[0].name, "X-Three")

	// Freeing an empty or nil list is what a `defer` after a failed call does, so it has to be safe.
	sciter_app.delete_name_values(nil)
	sciter_app.delete_name_values({})
}

// The remaining getters against a nil handle, extending the table in `test_nil_request_is_bad_param`.
// The whole surface has to agree, or one unchecked notification is a crash rather than an error.
@(test)
test_the_rest_of_the_request_getters_also_refuse_a_nil_handle :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	bad := sciter_app.Error(sciter.Request_Result.BAD_PARAM)

	_, content_err := sciter_app.request_content_url(nil)
	testing.expect_value(t, content_err, bad)
	_, mime_err := sciter_app.request_mime(nil)
	testing.expect_value(t, mime_err, bad)
	_, proxy_host_err := sciter_app.request_proxy_host(nil)
	testing.expect_value(t, proxy_host_err, bad)
	_, proxy_port_err := sciter_app.request_proxy_port(nil)
	testing.expect_value(t, proxy_port_err, bad)

	_, param_count_err := sciter_app.request_parameter_count(nil)
	testing.expect_value(t, param_count_err, bad)
	_, param_err := sciter_app.request_parameter(nil, 0)
	testing.expect_value(t, param_err, bad)

	_, header_count_err := sciter_app.request_header_count(nil)
	testing.expect_value(t, header_count_err, bad)
	_, header_err := sciter_app.request_header(nil, 0)
	testing.expect_value(t, header_err, bad)

	_, response_count_err := sciter_app.response_header_count(nil)
	testing.expect_value(t, response_count_err, bad)
	_, response_err := sciter_app.response_header(nil, 0)
	testing.expect_value(t, response_err, bad)
	_, responses_err := sciter_app.response_headers(nil)
	testing.expect_value(t, responses_err, bad)
}
