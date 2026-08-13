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
import "core:strings"

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
//
// **`nil` and an empty-but-present slice are different answers.** `nil` means "I have nothing for this
// request" and is `.DISCARD`, i.e. the resource is never loaded. A zero-length non-nil slice means "the
// resource is empty", which is an ordinary thing to serve - an empty stylesheet, an empty JS module, a
// generated `[]` - and answers `.OK` with a zero size. Collapsing the two made an empty archive entry
// indistinguishable from a missing one.
serve :: proc(request: ^Load_Request, data: []u8) -> Load_Result {
	if data == nil {
		return .DISCARD
	}
	if len(data) == 0 {
		request.raw.outData = nil
		request.raw.outDataSize = 0
		return .OK
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

// Hands the engine data for a URL, copying it immediately.
//
// **It works from inside a load callback and nowhere else.** Measured: called from within
// `on_load_data` - alongside a `.DELAYED` return - it answers `nil` and the resource is used. Called
// after the callback has returned it answers `.Load_Failed`, both for a request left in flight by
// `.DELAYED` and for a URL nothing has asked for. So this is not the way to answer later; it is `serve`
// with a copy instead of a borrow, which is what to reach for when the bytes are about to go out of
// scope.
//
// `data_ready_async`, which carries the request id, is the one that answers a `.DELAYED` request after
// the fact.
data_ready :: proc(window: Window, uri: string, data: []u8) -> Error {
	w := utf16_from_string(uri, context.temp_allocator)
	ok := sciter.api().SciterDataReady(rawptr(window), raw_data(w), raw_data(data), u32(len(data)))
	return nil if ok else Api_Error.Load_Failed
}

// ---------------------------------------------------------------------------------------------------
// Posting work to the engine's thread
//
// Everything in this package has to be called from the thread that ran `init` - see
// docs/architecture.md. That is the constraint every application with a background thread runs into
// first: the worker has an answer, and it cannot touch the DOM to show it.
//
// `post_callback` is the way across. It is safe to call from any thread, it returns immediately, and
// the message comes back out on the engine's thread as `Host_Handler.on_posted`, where the DOM is
// reachable again.
//
//	// on a worker thread
//	sciter_app.post_callback(window, ROWS_READY, uintptr(len(rows)))
//
//	// on_posted, on the engine's thread
//	on_posted :: proc(handler: ^Host_Handler, posted: Posted) {
//		if posted.wparam == ROWS_READY { redraw(...) }
//	}
//
// Two words is all it carries, so anything bigger travels as a pointer to something the worker owns
// and the handler takes - or as an index into a queue the two share.
//
// Measured, and worth knowing before designing around it:
//
//   - **it is delivery, not a call.** The C API's `timeoutms` parameter is not surfaced because it did
//     nothing: with a timeout of 3 seconds, from a worker thread, against an engine thread deliberately
//     stalled for 300ms, the call still returned in microseconds. There is no "wait for the answer"
//     mode and the notification's `lreturn` does not come back to the poster.
//   - **the messages arrive in the order they were posted**, one per turn of the pump.
//   - **`heartbeat` delivers them**, not only `run_once` - so a thread that is pumping the engine
//     without processing input still gets them.
//   - **a window with no host handler drops them**, silently. So does a nil window.

// A message that came back from `post_callback`.
Posted :: struct {
	// The two words the poster passed. What they mean is between the two ends.
	wparam: uintptr,
	lparam: uintptr,

	// The engine's own struct, for `lreturn` - which this engine does not deliver back to the poster,
	// but which is the field the C API defines for it.
	raw:    ^sciter.Scn_Posted_Notification,
}

// Posts two words to `window`'s host handler, from any thread. Returns immediately.
//
// The message is dropped if `window` has no host handler - `set_host_handler` with an `on_posted` is
// what receives it.
post_callback :: proc(window: Window, wparam: uintptr, lparam: uintptr = 0) {
	sciter.api().SciterPostCallback(rawptr(window), wparam, lparam, 0)
}

// The `user_data` of the host handler attached to `window`, straight from the engine - nil for a
// window that has none.
//
// This is the way a `proc "system"` callback that was handed only an HWINDOW finds its way back to the
// application's own state without a global. Note it is the *handler* pointer that comes back, since
// that is what `set_host_handler` gives the engine, so the shape is
// `(^Host_Handler)(callback_param(window)).user_data`.
callback_param :: proc(window: Window) -> rawptr {
	return sciter.api().SciterGetCallbackParam(rawptr(window))
}

// ---------------------------------------------------------------------------------------------------
// Named behaviors
//
// The third way to attach Odin code to an element, and the only one the *document* asks for by name.
// `attach_handler` and `attach_window_handler` are the host reaching into the document; this is the
// document reaching out:
//
//	div.gauge { behavior: my-gauge; }
//
// The engine hits a `behavior:` name it does not implement, asks the host who that is, and the host
// answers with an `Event_Handler`. It is the same mechanism the SDK's C++ `behavior_factory` uses, and
// it is what lets a stylesheet decide which elements get a widget - so a new gauge is a CSS class, not
// a call site.
//
// Measured against the vendored 6.0.4.9 engine:
//
//   - **The notification arrives inside `load_html`**, before it returns. `set_host_handler` has to be
//     in place first, which is the same rule `on_load_data` already has.
//   - **One request per name per element.** `behavior: my-gauge my-tooltip` produces two, both for the
//     same element, and both handlers attach to it.
//   - **An intrinsic name never reaches the host.** `behavior: button` produces no request at all and
//     the element becomes a real button, so this cannot override a behavior the engine implements. The
//     names it does implement are not enumerable; the answer is to pick names of your own.
//   - **Elements created later are asked about too**, so a handler built this way covers a document
//     that grows.
//   - **The notification's return value is ignored.** Handing back a handler is what attaches it -
//     answering 0 with the fields set attached it anyway. This wrapper still returns the documented
//     value.
//   - **Ownership comes back through `.DETACH`.** There is no "behavior destroyed" notification. The
//     handler hears `Initialization_Events.DETACH` in the `{}` group when its element is removed or
//     the document is replaced, and that is the only place it can free itself.

// An element asking for a behavior by name.
Behavior_Request :: struct {
	// The name as it appears in `behavior: ???`. Allocated in the callback's `context.temp_allocator`,
	// so clone it if it has to outlive the call.
	name:    string,

	// The element that asked. Valid for the call; to keep it, keep it the way any handler does - the
	// handler is about to be attached to it, and `Event.element` reports it on every event after that.
	element: Element,

	// The window the document is in.
	window:  Window,

	// The engine's own struct, for the fields this wrapper does not surface.
	raw:     ^sciter.Scn_Attach_Behavior,
}

// A resource the engine finished fetching by itself, reported after the fact.
//
// This is not a chance to intervene - that is `on_load_data`, which runs first and can answer the
// request. This says what happened, which is where a failed image or a 404 stylesheet becomes visible.
Data_Loaded :: struct {
	uri:    string, // in `context.temp_allocator`
	type:   sciter.Sciter_Resource_Type,
	data:   []u8, // borrowed from the engine, valid for the call
	status: u32, // 0 with no data is an unknown error; 100..505 is an HTTP status, 200 being OK
	raw:    ^sciter.Scn_Data_Loaded,
}

// A host callback. Like `Event_Handler`, the engine stores its address, so it must not move and must
// outlive the window it is attached to.
Host_Handler :: struct {
	// Called for every resource the document refers to. Return `.OK` to let the engine load it
	// normally, or call `serve` to answer it yourself.
	on_load_data:        proc(handler: ^Host_Handler, request: ^Load_Request) -> Load_Result,

	// Called after a resource the engine fetched itself has arrived - or failed to.
	on_data_loaded:      proc(handler: ^Host_Handler, loaded: ^Data_Loaded),

	// Called when the document asks for a `behavior:` name the engine does not implement. Return an
	// `Event_Handler` to claim the name, or nil to pass - an unclaimed name is not an error, the
	// element simply gets no behavior.
	//
	// The returned handler is attached to the element immediately: it is asked for its `subscription`
	// and then sent `Initialization_Events.ATTACH`, both before this notification returns. It must
	// outlive the attachment and must not move, exactly like one passed to `attach_handler` - so it is
	// allocated here, one per element, and freed when it hears `.DETACH`.
	on_attach_behavior:  proc(handler: ^Host_Handler, request: ^Behavior_Request) -> ^Event_Handler,

	// Called on the engine's thread for each `post_callback`, in the order they were posted. See
	// "Posting work to the engine's thread" above.
	on_posted:           proc(handler: ^Host_Handler, posted: Posted),

	// The engine has repainted an area and is telling the host which one, in window coordinates.
	//
	// **This fires constantly in an ordinary embedded window** - 49 times in a short measured run that
	// only focused a field, moved the mouse and clicked a button - so it is not the windowless-mode-only
	// notification the header's placement suggests. The engine has already drawn; nothing has to be done
	// about it. It is here for a host that wants to know, and it is the hook a windowless embedding
	// would be built on. Keep the handler cheap or leave it nil.
	on_invalidate_rect:  proc(handler: ^Host_Handler, window: Window, rect: sciter.Rect),

	// The engine wants an on-screen keyboard - sent when a text field takes focus. `keyboard_type` is
	// Android's `inputType` vocabulary, per the header. Measured firing once on `set_focus` of an
	// `<input type=text>` here; on a desktop with a real keyboard there is nothing to do about it.
	on_keyboard_request: proc(handler: ^Host_Handler, window: Window, keyboard_type: string),

	// The engine wants a different mouse cursor. Either `cursor_id` (a `CURSOR_TYPE`) or `cursor_url`,
	// never both. **Not sent by this engine in windowed mode** - measured zero times - because the
	// engine owns the window and sets the cursor itself. It is here for completeness and for the
	// windowless path.
	on_set_cursor:       proc(handler: ^Host_Handler, window: Window, cursor_id: u32, cursor_url: string),

	// The renderer failed and drew nothing - bad drivers, per the header. Also never seen here.
	on_graphics_failure: proc(handler: ^Host_Handler, window: Window),

	// The engine is going away. Final notification; nothing in the API is callable after it.
	on_engine_destroyed: proc(handler: ^Host_Handler),

	// Yours; passed back on every call.
	user_data:           rawptr,

	// Captured by `set_host_handler` - the engine calls back as `proc "system"`, where Odin's implicit
	// context does not exist.
	ctx:                 runtime.Context,
}

// Installs the host callback on a window.
//
// Do this **before** loading a document: the callback has to be in place for the load of the document
// itself, or its stylesheets and images will have been fetched the ordinary way before the handler
// exists.
// A nil handler detaches whatever was there, which is also what makes `callback_param` nil again.
//
// Detaching leaves the trampoline in place with a null parameter rather than clearing the callback
// itself: a window whose callback pointer is NULL **segfaults inside the engine** at the next
// notification - the next `load_html` is enough - because it calls the pointer without checking it.
set_host_handler :: proc(window: Window, handler: ^Host_Handler) {
	if handler == nil {
		sciter.api().SciterSetCallback(rawptr(window), host_trampoline, nil)
		return
	}
	handler.ctx = context
	sciter.api().SciterSetCallback(rawptr(window), host_trampoline, handler)
}

@(private)
host_trampoline :: proc "system" (pns: ^sciter.Sciter_Callback_Notification, param: rawptr) -> u32 {
	if param == nil {
		return u32(Load_Result.OK) // detached - see set_host_handler
	}
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
			type = ld.dataType,
			raw  = ld,
		}
		return u32(handler.on_load_data(handler, &request))

	case sciter.SC_DATA_LOADED:
		if handler.on_data_loaded == nil {
			return 0
		}
		dl := (^sciter.Scn_Data_Loaded)(pns)
		loaded := Data_Loaded {
			uri    = string_from_utf16_cstring(dl.uri, context.temp_allocator),
			type   = dl.dataType,
			status = u32(dl.status),
			raw    = dl,
		}
		if dl.data != nil && dl.dataSize > 0 {
			loaded.data = dl.data[:dl.dataSize]
		}
		handler.on_data_loaded(handler, &loaded)
		return 0

	case sciter.SC_ATTACH_BEHAVIOR:
		if handler.on_attach_behavior == nil {
			return 0
		}
		ab := (^sciter.Scn_Attach_Behavior)(pns)
		request := Behavior_Request {
			name    = behavior_name(ab.behaviorName),
			element = Element(ab.element),
			window  = Window(ab.hwnd),
			raw     = ab,
		}

		element_handler := handler.on_attach_behavior(handler, &request)
		if element_handler == nil {
			return 0 // not ours; the element gets no behavior, which is not an error
		}

		// Same trampoline `attach_handler` uses, so a behavior handler is an ordinary `Event_Handler`
		// and every typed accessor in `events.odin` works on it unchanged.
		element_handler.ctx = context
		ab.elementTag = element_handler
		ab.elementProc = event_trampoline
		return 1

	case sciter.SC_POSTED_NOTIFICATION:
		if handler.on_posted == nil {
			return 0
		}
		pn := (^sciter.Scn_Posted_Notification)(pns)
		handler.on_posted(handler, Posted{wparam = pn.wparam, lparam = pn.lparam, raw = pn})
		return 0

	case sciter.SC_INVALIDATE_RECT:
		if handler.on_invalidate_rect != nil {
			ir := (^sciter.Scn_Invalidate_Rect)(pns)
			handler.on_invalidate_rect(handler, Window(ir.hwnd), ir.invalidRect)
		}
		return 0

	case sciter.SC_KEYBOARD_REQUEST:
		if handler.on_keyboard_request != nil {
			kr := (^sciter.Scn_Keyboard_Request)(pns)
			// Borrowed for the call, not cloned: this is engine memory and the handler is synchronous.
			// The clone that used to be here went into `context.temp_allocator` from inside an engine
			// callback that nothing frees - the same unbounded-arena shape as the debug output in
			// app.odin. A handler that wants to keep the name copies it.
			kind := kr.keyboardType == nil ? "" : string(kr.keyboardType)
			handler.on_keyboard_request(handler, Window(kr.hwnd), kind)
		}
		return 0

	case sciter.SC_SET_CURSOR:
		if handler.on_set_cursor != nil {
			sc := (^sciter.Scn_Set_Cursor)(pns)
			url := sc.cursorUrl == nil ? "" : string(sc.cursorUrl) // borrowed, as above
			handler.on_set_cursor(handler, Window(sc.hwnd), u32(sc.cursorId), url)
		}
		return 0

	case sciter.SC_GRAPHICS_CRITICAL_FAILURE:
		if handler.on_graphics_failure != nil {
			handler.on_graphics_failure(handler, Window(pns.hwnd))
		}
		return 0

	case sciter.SC_ENGINE_DESTROYED:
		if handler.on_engine_destroyed != nil {
			handler.on_engine_destroyed(handler)
		}
		return 0
	}

	return u32(Load_Result.OK)
}

// The `behavior:` name, copied out of the engine's `char*` into the temp allocator. The pointer
// survived the call when measured, but nothing documents that it must, so the copy is not optional.
@(private = "file")
behavior_name :: proc(name: cstring) -> string {
	if name == nil {
		return ""
	}
	return strings.clone(string(name), context.temp_allocator)
}
