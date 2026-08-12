// Requests: answering the engine's resource loads yourself, with a status code and headers.
//
// `host.odin` covers the simple half of `SC_LOAD_DATA` - `serve` hands the engine bytes and it is done
// with. This is the other half. Every load notification also carries an `HREQUEST`, the engine's own
// request object, and returning `.MYSELF` from the callback hands that object to the host: from then on
// the resource is whatever the host says it is, delivered whenever the host says so.
//
// That buys three things `serve` cannot do:
//
//   - a **status code and a MIME type**. `serve` is always "200, engine guess the type"; a request can
//     be failed with 404, or served as "image/svg+xml" when the URL has no useful extension.
//   - **answering later**. `take_request` keeps the handle alive past the callback, and the answer can
//     come from a worker's result, a database read or an HTTP response minutes later. `.DELAYED` plus
//     `data_ready_async` also defers, but only for whole-buffer answers on the engine's thread.
//   - **streaming**. `append_request_data` pushes chunk after chunk into the same request.
//
// The handle also reads: URL, method, requested type, parameters, request and response headers, timing,
// completion status, and the element that asked - see the getters below.
//
// Measured on the vendored 6.0.4.9 engine (`docs/RESEARCH-METHOD.md`): every slot in this table answers
// `.OK` for a request that arrives through `SC_LOAD_DATA`, including the ones that look network-shaped
// (proxy host, proxy port, times) - they answer with empty or zero rather than `.NOTSUPPORTED`.
package sciter_app

import sciter ".."
import "base:runtime"
import "core:mem"

// The engine's HREQUEST. Distinct so it cannot be passed where a `Window` or an `Element` belongs.
//
// A handle is only valid while the engine holds a reference to it, which for a request arriving through
// `SC_LOAD_DATA` is the duration of the callback. Keeping one past that means `use_request` first - see
// `take_request`. This was measured, not assumed: the probe saw the engine hand out the *same* pointer
// for a later, unrelated request once the first was finished with.
Request :: distinct sciter.Hrequest

// The request API is a second function table, reached through the main one. `sciter.api()` is cheap but
// this is one more indirection on every call, so it is fetched once.
@(private)
g_request_api: ^sciter.Sciter_Request_Api

// The raw `SciterRequestAPI` table, for anything this wrapper does not cover. Nil only if the engine is
// not loaded.
request_api :: proc() -> ^sciter.Sciter_Request_Api {
	if g_request_api == nil && sciter.loaded() {
		g_request_api = sciter.api().GetSciterRequestAPI()
	}
	return g_request_api
}

// Unlike `Scdom_Result` and `Value_Result`, nothing here is a negative success: `REQUEST_OK` is 0 and
// `REQUEST_PANIC` is -1, so anything other than `.OK` is a failure.
@(private)
request_err :: proc(r: sciter.Request_Result) -> Error {
	return nil if r == .OK else r
}

// A request parameter or a header. Both are name/value pairs of engine-owned UTF-16, copied out into
// the caller's allocator.
Name_Value :: struct {
	name:  string,
	value: string,
}

// Frees a slice returned by `request_parameters`, `request_headers` or `response_headers`.
delete_name_values :: proc(pairs: []Name_Value, allocator := context.allocator) {
	for pair in pairs {
		delete(pair.name, allocator)
		delete(pair.value, allocator)
	}
	delete(pairs, allocator)
}

// ---------------------------------------------------------------------------------------------------
// Getting a handle out of a load callback

// The request behind a load notification.
//
// Valid for the duration of the callback and no longer, unless `use_request` is called on it. Returning
// anything other than `.MYSELF` leaves the request to the engine, and the handle must not be touched
// after the callback returns.
request_of :: proc(request: ^Load_Request) -> Request {
	return Request(request.raw.requestId)
}

// Takes the request over and keeps it alive past the callback.
//
//	// inside on_load_data:
//	app.pending, result = sciter_app.take_request(request)
//	return result   // .MYSELF - the engine will not load this URL itself
//
//	// later, on the engine's thread:
//	sciter_app.succeed_request(app.pending, bytes)
//	sciter_app.unuse_request(app.pending)
//
// The reference this takes is the whole point: without it the handle is the engine's to recycle the
// moment the callback returns. **Every `take_request` needs a matching `unuse_request`**, and a request
// that is never answered is a resource the document waits on forever.
//
// Answering late works - measured with an image, whose `.INCOMPLETE` and `.BUSY` element state both
// cleared once the answer arrived. What it does **not** do is rewind the document: a `<script src>`
// answered after parsing has moved on is fetched but never executed. Defer resources that the document
// consumes when they arrive (images, fonts, media), not ones it consumes in order.
take_request :: proc(request: ^Load_Request) -> (rq: Request, result: Load_Result) {
	rq = request_of(request)
	if rq == nil {
		return nil, .OK
	}
	if use_request(rq) != nil {
		return nil, .OK
	}
	return rq, .MYSELF
}

// Answers a load request through the request API, inside the callback, and returns `.MYSELF`.
//
//	return sciter_app.serve_request(request, png, mime = "image/png")
//
// This is `serve` with a status code and a MIME type. Prefer plain `serve` when neither matters - it is
// one field assignment and no reference counting. `mime` and `encoding` are passed only when non-empty,
// leaving the engine to sniff as it otherwise would.
//
// Failure to hand the data over is reported as `.DISCARD`: the request has already been taken over at
// that point, so returning `.OK` would leave the engine waiting on an answer that is not coming.
serve_request :: proc(
	request: ^Load_Request,
	data: []u8,
	mime := "",
	encoding := "",
	status: u32 = 200,
) -> Load_Result {
	rq := request_of(request)
	if rq == nil {
		return .OK
	}
	if mime != "" {
		set_request_mime(rq, mime)
	}
	if encoding != "" {
		set_request_encoding(rq, encoding)
	}
	if succeed_request(rq, data, status) != nil {
		return .DISCARD
	}
	return .MYSELF
}

// ---------------------------------------------------------------------------------------------------
// Lifetime

// Takes a reference - the engine's `RequestUse`, an AddRef. Needed before a handle outlives the callback
// it arrived in.
use_request :: proc(request: Request) -> Error {
	if request == nil {
		return sciter.Request_Result.BAD_PARAM
	}
	return request_err(request_api().RequestUse(sciter.Hrequest(request)))
}

// Releases a reference taken by `use_request` or `take_request`.
unuse_request :: proc(request: Request) -> Error {
	if request == nil {
		return sciter.Request_Result.BAD_PARAM
	}
	return request_err(request_api().RequestUnUse(sciter.Hrequest(request)))
}

// ---------------------------------------------------------------------------------------------------
// Answering

// Completes the request successfully with `data` and an HTTP-shaped status code.
//
// The engine copies the data, so the buffer does not have to outlive the call. Pass nil `data` after
// `append_request_data` has already streamed the body in.
//
// Answering an already-answered request returns `.OK` on the vendored engine rather than complaining,
// so a double answer is silent - it is still a bug, and the second one is ignored.
succeed_request :: proc(request: Request, data: []u8, status: u32 = 200) -> Error {
	if request == nil {
		return sciter.Request_Result.BAD_PARAM
	}
	return request_err(
		request_api().RequestSetSucceeded(sciter.Hrequest(request), status, raw_data(data), u32(len(data))),
	)
}

// Completes the request as a failure. `data` is an optional body - an error document, say.
//
// The engine reacts to the status the way it would to a real one: a failed image request is followed by
// a request for `sciter:no-image.png`, which is the engine's own built-in and must be left alone (return
// `.OK` for it).
fail_request :: proc(request: Request, status: u32 = 404, data: []u8 = nil) -> Error {
	if request == nil {
		return sciter.Request_Result.BAD_PARAM
	}
	return request_err(
		request_api().RequestSetFailed(sciter.Hrequest(request), status, raw_data(data), u32(len(data))),
	)
}

// Appends a chunk to the response body, for a body assembled in pieces - a decompressor, a socket read,
// a file streamed rather than slurped.
//
// Chunks accumulate; `succeed_request(rq, nil)` then completes the request with what has been pushed.
append_request_data :: proc(request: Request, chunk: []u8) -> Error {
	if request == nil {
		return sciter.Request_Result.BAD_PARAM
	}
	return request_err(
		request_api().RequestAppendDataChunk(sciter.Hrequest(request), raw_data(chunk), u32(len(chunk))),
	)
}

// Sets a request header. Adds to the request's own header list, which `request_headers` then reads back.
set_request_header :: proc(request: Request, name, value: string) -> Error {
	if request == nil {
		return sciter.Request_Result.BAD_PARAM
	}
	n := utf16_from_string(name, context.temp_allocator)
	v := utf16_from_string(value, context.temp_allocator)
	return request_err(request_api().RequestSetRqHeader(sciter.Hrequest(request), raw_data(n), raw_data(v)))
}

// Sets a response header, for a host answering as a server would.
set_response_header :: proc(request: Request, name, value: string) -> Error {
	if request == nil {
		return sciter.Request_Result.BAD_PARAM
	}
	n := utf16_from_string(name, context.temp_allocator)
	v := utf16_from_string(value, context.temp_allocator)
	return request_err(request_api().RequestSetRspHeader(sciter.Hrequest(request), raw_data(n), raw_data(v)))
}

// Declares the MIME type of the data being returned - "text/css", "image/svg+xml".
//
// Worth setting when the URL carries no usable extension, which is exactly the case for the invented
// schemes a custom loader exists to serve.
set_request_mime :: proc(request: Request, mime: string) -> Error {
	if request == nil {
		return sciter.Request_Result.BAD_PARAM
	}
	return request_err(
		request_api().RequestSetReceivedDataType(sciter.Hrequest(request), to_cstring(mime, context.temp_allocator)),
	)
}

// Declares the character encoding of the data being returned - "utf-8".
set_request_encoding :: proc(request: Request, encoding: string) -> Error {
	if request == nil {
		return sciter.Request_Result.BAD_PARAM
	}
	return request_err(
		request_api().RequestSetReceivedDataEncoding(
			sciter.Hrequest(request),
			to_cstring(encoding, context.temp_allocator),
		),
	)
}

// ---------------------------------------------------------------------------------------------------
// Reading the request

// The URL asked for, as the document spelled it (fully qualified against the base URL).
request_url :: proc(request: Request, allocator := context.allocator) -> (url: string, err: Error) {
	return utf8_string_of(request, request_api().RequestUrl, allocator)
}

// The URL the content actually came from, after any redirection. Empty for a request the host is
// answering itself, which has not been anywhere - not a copy of `request_url`, so do not reach for it
// as one.
request_content_url :: proc(request: Request, allocator := context.allocator) -> (url: string, err: Error) {
	return utf8_string_of(request, request_api().RequestContentUrl, allocator)
}

// The method - "GET", "POST". Borrowed from the engine and valid for the request's lifetime.
request_method :: proc(request: Request) -> (method: string, err: Error) {
	if request == nil {
		return "", sciter.Request_Result.BAD_PARAM
	}
	p: cstring
	request_err(request_api().RequestGetRequestType(sciter.Hrequest(request), &p)) or_return
	return string(p), nil
}

// What the engine intends the bytes for: `.STYLE`, `.IMAGE`, `.SCRIPT`, `.FONT`, ... The same value as
// `Load_Request.type`, read from the request instead of the notification.
request_data_type :: proc(request: Request) -> (type: sciter.Sciter_Resource_Type, err: Error) {
	if request == nil {
		return {}, sciter.Request_Result.BAD_PARAM
	}
	request_err(request_api().RequestGetRequestedDataType(sciter.Hrequest(request), &type)) or_return
	return type, nil
}

// The MIME type of the data received so far, or "" before anything has been delivered.
//
// It is the *response* type, not a hint from whatever asked - so it is empty for the whole of a
// pending request and carries what the answer set once there is one. That makes it the way to read
// back what a request was actually served as: after `serve_request(..., mime = "text/css")` it is
// "text/css".
request_mime :: proc(request: Request, allocator := context.allocator) -> (mime: string, err: Error) {
	return utf8_string_of(request, request_api().RequestGetReceivedDataType, allocator)
}

// The proxy host, and "" when there is none - which on this engine is every request measured,
// including ones the host serves itself. There is no "not supported" answer to tell apart from "no
// proxy"; the pair below behaves the same way.
request_proxy_host :: proc(request: Request, allocator := context.allocator) -> (host: string, err: Error) {
	return utf8_string_of(request, request_api().RequestGetProxyHost, allocator)
}

// The proxy port, and 0 when there is none.
request_proxy_port :: proc(request: Request) -> (port: u32, err: Error) {
	if request == nil {
		return 0, sciter.Request_Result.BAD_PARAM
	}
	request_err(request_api().RequestGetProxyPort(sciter.Hrequest(request), &port)) or_return
	return port, nil
}

// When the request started and ended, in engine milliseconds. `ended` is 0 until it completes, so
// `ended - started` is only a duration once `request_status` reports something other than `.PENDING`.
request_times :: proc(request: Request) -> (started, ended: u32, err: Error) {
	if request == nil {
		return 0, 0, sciter.Request_Result.BAD_PARAM
	}
	request_err(request_api().RequestGetTimes(sciter.Hrequest(request), &started, &ended)) or_return
	return started, ended, nil
}

// How far the request has got, and the status code it carries - `.PENDING` and 0 for one that has not
// been answered, `.SUCCESS` and 200 after `succeed_request`, `.FAILURE` and 404 after `fail_request`.
request_status :: proc(request: Request) -> (state: sciter.Request_State, status: u32, err: Error) {
	if request == nil {
		return {}, 0, sciter.Request_Result.BAD_PARAM
	}
	request_err(request_api().RequestGetCompletionStatus(sciter.Hrequest(request), &state, &status)) or_return
	return state, status, nil
}

// The bytes delivered so far, copied into `allocator`. Empty before the request is answered.
request_data :: proc(request: Request, allocator := context.allocator) -> (data: []u8, err: Error) {
	if request == nil {
		return nil, sciter.Request_Result.BAD_PARAM
	}
	sink := Bytes_Sink {
		ctx       = context,
		allocator = allocator,
	}
	request_err(request_api().RequestGetData(sciter.Hrequest(request), data_receiver, &sink)) or_return
	return sink.out, nil
}

// The element the request was issued for.
//
// Not what one might expect: this is the element that *owns* the resource, not the one that named it. A
// stylesheet pulled in by `<link>` in the head reports `html`, because that is what the style is being
// applied to. The reference is not addrefed - do not `unuse_element` it.
request_requestor :: proc(request: Request) -> (element: Element, err: Error) {
	if request == nil {
		return nil, sciter.Request_Result.BAD_PARAM
	}
	he: sciter.Helement
	request_err(request_api().RequestGetRequestor(sciter.Hrequest(request), &he)) or_return
	if he == nil {
		return nil, .Not_Found
	}
	return Element(he), nil
}

// ---------------------------------------------------------------------------------------------------
// Parameters and headers
//
// Three lists with identical shapes - a count, then a name and a value per index. The plural forms
// below read the whole list in one call and are what you want; the counts and the indexed reads are
// there for a host that only wants one of them. The two views agree.
//
// An index past the end is `.FAILURE`, not `.BAD_PARAM` - the handle was fine, the index was not.
//
// The response list is not only what the host put in it: **the engine appends a `Content-Encoding`
// header of its own** once the request is answered, so a count taken after `serve_request` is one more
// than the number of `set_response_header` calls.

// How many parameters the request carries.
//
// **A query string in the URL is not one of them.** A document asking for `t.css?theme=dark` produces
// one request whose `request_url` is the whole string, query included, and whose parameter count is
// zero - splitting it is the host's job. What does arrive here is what `http_request` was given, and
// for a URL the host answers the engine leaves the URL alone and passes the parameters through as
// parameters, for `.Get` as well as `.Post`. Values are unescaped on the way in.
request_parameter_count :: proc(request: Request) -> (n: int, err: Error) {
	return count_of(request, request_api().RequestGetNumberOfParameters)
}

request_parameter :: proc(
	request: Request,
	index: int,
	allocator := context.allocator,
) -> (
	pair: Name_Value,
	err: Error,
) {
	api := request_api()
	return pair_of(request, index, api.RequestGetNthParameterName, api.RequestGetNthParameterValue, allocator)
}

// The request's parameters - what a `POST` or a URL query carried. Free with `delete_name_values`.
request_parameters :: proc(request: Request, allocator := context.allocator) -> (params: []Name_Value, err: Error) {
	api := request_api()
	return list_of(
		request,
		api.RequestGetNumberOfParameters,
		api.RequestGetNthParameterName,
		api.RequestGetNthParameterValue,
		allocator,
	)
}

request_header_count :: proc(request: Request) -> (n: int, err: Error) {
	return count_of(request, request_api().RequestGetNumberOfRqHeaders)
}

request_header :: proc(
	request: Request,
	index: int,
	allocator := context.allocator,
) -> (
	pair: Name_Value,
	err: Error,
) {
	api := request_api()
	return pair_of(request, index, api.RequestGetNthRqHeaderName, api.RequestGetNthRqHeaderValue, allocator)
}

// The request headers. A load request the host is answering starts with none of its own; anything set
// with `set_request_header` reads back here. Free with `delete_name_values`.
request_headers :: proc(request: Request, allocator := context.allocator) -> (headers: []Name_Value, err: Error) {
	api := request_api()
	return list_of(
		request,
		api.RequestGetNumberOfRqHeaders,
		api.RequestGetNthRqHeaderName,
		api.RequestGetNthRqHeaderValue,
		allocator,
	)
}

response_header_count :: proc(request: Request) -> (n: int, err: Error) {
	return count_of(request, request_api().RequestGetNumberOfRspHeaders)
}

response_header :: proc(
	request: Request,
	index: int,
	allocator := context.allocator,
) -> (
	pair: Name_Value,
	err: Error,
) {
	api := request_api()
	return pair_of(request, index, api.RequestGetNthRspHeaderName, api.RequestGetNthRspHeaderValue, allocator)
}

// The response headers, including any set with `set_response_header`. Free with `delete_name_values`.
response_headers :: proc(request: Request, allocator := context.allocator) -> (headers: []Name_Value, err: Error) {
	api := request_api()
	return list_of(
		request,
		api.RequestGetNumberOfRspHeaders,
		api.RequestGetNthRspHeaderName,
		api.RequestGetNthRspHeaderValue,
		allocator,
	)
}

// ---------------------------------------------------------------------------------------------------
// The plumbing behind the above.
//
// The request table repeats four call shapes, so the wrappers are written once against a function
// pointer and named once per slot.

@(private = "file")
Utf8_Getter :: proc "system" (rq: sciter.Hrequest, rcv: sciter.Utf8_Receiver, param: rawptr) -> sciter.Request_Result

@(private = "file")
Count_Getter :: proc "system" (rq: sciter.Hrequest, n: ^u32) -> sciter.Request_Result

@(private = "file")
Nth_Getter :: proc "system" (
	rq: sciter.Hrequest,
	n: u32,
	rcv: sciter.Wide_String_Receiver,
	param: rawptr,
) -> sciter.Request_Result

@(private = "file")
utf8_string_of :: proc(request: Request, get: Utf8_Getter, allocator: mem.Allocator) -> (out: string, err: Error) {
	if request == nil {
		return "", sciter.Request_Result.BAD_PARAM
	}
	sink := String_Sink {
		ctx       = context,
		allocator = allocator,
	}
	request_err(get(sciter.Hrequest(request), bytes_receiver, &sink)) or_return
	return sink.out, nil
}

@(private = "file")
count_of :: proc(request: Request, get: Count_Getter) -> (n: int, err: Error) {
	if request == nil {
		return 0, sciter.Request_Result.BAD_PARAM
	}
	count: u32
	request_err(get(sciter.Hrequest(request), &count)) or_return
	return int(count), nil
}

@(private = "file")
pair_of :: proc(
	request: Request,
	index: int,
	get_name, get_value: Nth_Getter,
	allocator: mem.Allocator,
) -> (
	pair: Name_Value,
	err: Error,
) {
	if request == nil {
		return {}, sciter.Request_Result.BAD_PARAM
	}
	if index < 0 {
		return {}, sciter.Request_Result.BAD_PARAM
	}

	name := String_Sink {
		ctx       = context,
		allocator = allocator,
	}
	request_err(get_name(sciter.Hrequest(request), u32(index), wide_receiver, &name)) or_return

	value := String_Sink {
		ctx       = context,
		allocator = allocator,
	}
	if verr := request_err(get_value(sciter.Hrequest(request), u32(index), wide_receiver, &value)); verr != nil {
		delete(name.out, allocator)
		return {}, verr
	}
	return Name_Value{name = name.out, value = value.out}, nil
}

@(private = "file")
list_of :: proc(
	request: Request,
	count: Count_Getter,
	get_name, get_value: Nth_Getter,
	allocator: mem.Allocator,
) -> (
	pairs: []Name_Value,
	err: Error,
) {
	n := count_of(request, count) or_return
	if n == 0 {
		return nil, nil
	}

	out := make([]Name_Value, n, allocator)
	for i in 0 ..< n {
		pair, perr := pair_of(request, i, get_name, get_value, allocator)
		if perr != nil {
			for done in out[:i] {
				delete(done.name, allocator)
				delete(done.value, allocator)
			}
			delete(out, allocator)
			return nil, perr
		}
		out[i] = pair
	}
	return out, nil
}

// `bytes_receiver` in dom.odin builds a string; the request's body is bytes and stays bytes.
@(private = "file")
Bytes_Sink :: struct {
	ctx:       runtime.Context,
	allocator: mem.Allocator,
	out:       []u8,
}

@(private = "file")
data_receiver :: proc "system" (bytes: [^]u8, num_bytes: u32, param: rawptr) {
	sink := (^Bytes_Sink)(param)
	context = sink.ctx
	if bytes == nil || num_bytes == 0 {
		sink.out = nil
		return
	}
	buf := make([]u8, num_bytes, sink.allocator)
	copy(buf, bytes[:num_bytes])
	sink.out = buf
}
