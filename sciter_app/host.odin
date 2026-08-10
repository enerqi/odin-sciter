// The host callback: intercepting the engine's resource loading.
//
// Every time the engine needs something a document referred to - a stylesheet, an image, a script, a
// font - it asks the host first. That is one notification, `SC_LOAD_DATA`, and answering it is how an
// application serves its UI from somewhere other than the filesystem: from memory, from an archive,
// from a database, from an HTTP cache of its own.
//
// It is also the only hook that sees a URL *before* the engine tries to fetch it, so it doubles as the
// place to implement a custom scheme.
package sciter_app

import sciter ".."
import "base:runtime"

// What the host does about a request. These are the engine's own SC_LOAD_DATA_RETURN_CODES:
//
//   .OK       - carry on. If the handler filled the request in (see `serve`) that data is used;
//               otherwise the engine loads the URL itself, as it would have anyway.
//   .DISCARD  - refuse the request. The resource is simply never loaded.
//   .DELAYED  - the host will answer later, out of band, via SciterDataReadyAsync with the request's
//               `raw.requestId`. Every DELAYED request must eventually be answered or it leaks.
//   .MYSELF   - the host takes over the underlying HREQUEST entirely and drives it through the
//               sciter-x-request API.
Load_Result :: sciter.Sc_Load_Data_Return_Codes

// A resource the engine wants.
Load_Request :: struct {
	// The fully qualified URL, e.g. "res://app/style.css". Allocated in the callback's
	// `context.temp_allocator`, so it is valid for the duration of the handler and no longer - clone
	// it if it has to outlive the call.
	uri:  string,

	// What the engine intends to do with it: .STYLE, .IMAGE, .SCRIPT, .FONT, ... Worth checking, since
	// the same URL can legitimately be requested as more than one kind.
	type: sciter.Sciter_Resource_Type,

	// The engine's own struct, for the fields this wrapper does not surface - `requestId` for a
	// .DELAYED answer, `principal` and `initiator` for which element asked.
	raw:  ^sciter.Scn_Load_Data,
}

// Answers a request with bytes the host already has, and returns the result code to hand back.
//
//	return sciter_app.serve(request, my_bytes)
//
// The engine consumes the data during the callback - "Sciter does not store pointer to this data", per
// sciter-x-def.h - so a buffer that is valid for the duration of the handler is enough. The alternative
// for data that is awkward to keep alive even that long is `SciterDataReady`, which copies immediately.
serve :: proc(request: ^Load_Request, data: []u8) -> Load_Result {
	if len(data) == 0 {
		return .DISCARD
	}
	request.raw.outData = raw_data(data)
	request.raw.outDataSize = u32(len(data))
	return .OK
}

// Answers a request the handler returned `.DELAYED` for.
//
// `.DELAYED` is what makes a loader that cannot answer immediately possible - one reading from a
// database, a network cache, a decompressor - without blocking the message pump inside the callback.
// The bargain is strict: **every delayed request must eventually be answered or it leaks**, per
// sciter-x-def.h, and the answer has to carry the `request_id` the callback was given.
//
//	// inside on_load_data:
//	app.pending = request.raw.requestId
//	return .DELAYED
//
//	// later, back on the engine's thread:
//	sciter_app.data_ready_async(window, uri, bytes, app.pending)
//
// Unlike `serve`, the engine copies the data here, so the buffer does not have to outlive the call.
// Still call it from the engine's thread - see docs/architecture.md on threading.
data_ready_async :: proc(window: Window, uri: string, data: []u8, request_id: sciter.Hrequest) -> Error {
	w := utf16_from_string(uri, context.temp_allocator)
	ok := sciter.api().SciterDataReadyAsync(
		rawptr(window),
		raw_data(w),
		raw_data(data),
		u32(len(data)),
		rawptr(request_id),
	)
	return nil if ok else Api_Error.Load_Failed
}

// Hands the engine data for a URL outside of a load callback, copying it immediately.
//
// This is the "push" half of the loader: it answers a request that is in flight, and is the safe way
// to supply bytes whose lifetime you cannot guarantee for the duration of a `serve`.
data_ready :: proc(window: Window, uri: string, data: []u8) -> Error {
	w := utf16_from_string(uri, context.temp_allocator)
	ok := sciter.api().SciterDataReady(rawptr(window), raw_data(w), raw_data(data), u32(len(data)))
	return nil if ok else Api_Error.Load_Failed
}

// A host callback. Like `Event_Handler`, the engine stores its address, so it must not move and must
// outlive the window it is attached to.
Host_Handler :: struct {
	// Called for every resource the document refers to. Return `.OK` to let the engine load it
	// normally, or call `serve` to answer it yourself.
	on_load_data: proc(handler: ^Host_Handler, request: ^Load_Request) -> Load_Result,

	// Yours; passed back on every call.
	user_data:    rawptr,

	// Captured by `set_host_handler` - the engine calls back as `proc "system"`, where Odin's implicit
	// context does not exist.
	ctx:          runtime.Context,
}

// Installs the host callback on a window.
//
// Do this **before** loading a document: the callback has to be in place for the load of the document
// itself, or its stylesheets and images will have been fetched the ordinary way before the handler
// exists.
set_host_handler :: proc(window: Window, handler: ^Host_Handler) {
	handler.ctx = context
	sciter.api().SciterSetCallback(rawptr(window), host_trampoline, handler)
}

@(private)
host_trampoline :: proc "system" (pns: ^sciter.Sciter_Callback_Notification, param: rawptr) -> u32 {
	handler := (^Host_Handler)(param)
	context = handler.ctx

	// SCITER_CALLBACK_NOTIFICATION is the common head of a family of structs; `code` says which one
	// this really is. The notification codes are plain `#define`s upstream, so they are constants here
	// rather than an enum.
	switch pns.code {
	case sciter.SC_LOAD_DATA:
		if handler.on_load_data == nil {
			return u32(Load_Result.OK)
		}
		ld := (^sciter.Scn_Load_Data)(pns)
		request := Load_Request {
			uri  = string_from_utf16_cstring(ld.uri, context.temp_allocator),
			type = sciter.Sciter_Resource_Type(ld.dataType),
			raw  = ld,
		}
		return u32(handler.on_load_data(handler, &request))
	}

	return u32(Load_Result.OK)
}
