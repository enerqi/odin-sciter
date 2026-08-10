// package sciter_app - the Odin-shaped layer over `package sciter`.
//
// `package sciter` is generated and stays 1-to-1 with the C API, so that sciter.com's documentation
// reads across to it directly. That makes it faithful and verbose: every string is UTF-16 that you
// have to encode yourself, every call returns a result code you have to check, and every VALUE is
// reference-counted with explicit init/clear pairs.
//
// This package is the other half of that trade. It is snake_case, takes and returns Odin `string`s,
// reports failure as an Odin error enum, and owns the conversions. Nothing here hides the engine - the
// raw table is always one `sciter.api()` away, and the two can be mixed freely.
//
//	sciter.load()
//	sciter_app.init()
//	w, _ := sciter_app.create_window({width = 720, height = 480})
//	sciter_app.load_html(w, "<html><body><h1>hi</h1></body></html>")
//	sciter_app.show(w)
//	sciter_app.run()
//
// The window's title comes from the document's <title>; Sciter 6 has no window-title API.
package sciter_app

import sciter ".."
import "core:unicode/utf16"

// Everything in this package that can fail reports it as one of these.
//
// `Dom` and `Value` carry the engine's own result code, because the distinction between, say,
// INVALID_HANDLE and PASSIVE_HANDLE is the whole diagnosis when a DOM call fails.
Error :: union #shared_nil {
	Api_Error,
	sciter.Scdom_Result,
	sciter.Value_Result,
	sciter.Request_Result,
	sciter.Graphin_Result,
}

// Failures that the engine reports as a bare "false" rather than a result code, plus the ones this
// layer detects itself.
Api_Error :: enum {
	None = 0,
	Not_Loaded, // sciter.load() has not been called, or it failed
	Window_Failed, // SciterCreateWindow returned NULL
	Load_Failed, // SciterLoadHtml / SciterLoadFile returned FALSE
	Eval_Failed, // SciterEval returned FALSE - a script error, reported through the debug output
	Call_Failed, // SciterCall returned FALSE - no such function, or it threw
	Not_Found, // a selector matched nothing
	Wrong_Type, // a Value held something other than what was asked for
}

// `sciter.Scdom_Result.OK_NOT_HANDLED` is -1 and is a success, so `!= .OK` is not the test.
@(private)
dom_err :: proc(r: sciter.Scdom_Result) -> Error {
	if r == .OK || r == .OK_NOT_HANDLED {
		return nil
	}
	return r
}

// Likewise `sciter.Value_Result.OK_TRUE` is -1 and is a success.
@(private)
value_err :: proc(r: sciter.Value_Result) -> Error {
	if r == .OK || r == .OK_TRUE {
		return nil
	}
	return r
}

// ---------------------------------------------------------------------------------------------------
// UTF-16
//
// Sciter takes and returns UTF-16 for every string that is not a DOM tag name or an attribute name, so
// converting is the single most common thing this package does. Both directions allocate; both take an
// allocator; the wrappers below use `context.temp_allocator` for the arguments they build and hand the
// caller's allocator to anything they return.

// Number of UTF-16 code units `s` encodes to, not counting a terminator.
utf16_len :: proc(s: string) -> (n: int) {
	for r in s {
		n += 1 if r < 0x1_0000 else 2
	}
	return
}

// Encodes `s` as NUL-terminated UTF-16. The result's `len` includes the terminator, so the length to
// pass to the engine is `len(result) - 1` and the pointer is `raw_data(result)`.
@(require_results)
utf16_from_string :: proc(s: string, allocator := context.allocator) -> []u16 {
	buf := make([]u16, utf16_len(s) + 1, allocator)
	n := utf16.encode_string(buf, s)
	buf[n] = 0
	return buf
}

// Decodes `n` UTF-16 code units at `p` into a fresh Odin string.
@(require_results)
string_from_utf16 :: proc(p: [^]u16, n: uint, allocator := context.allocator) -> string {
	if p == nil || n == 0 {
		return ""
	}
	units := p[:n]

	// Each UTF-16 unit is at most 3 UTF-8 bytes; a surrogate pair is 2 units and 4 bytes, so 3 per
	// unit covers that too.
	buf := make([]u8, n * 3, allocator)
	written := utf16.decode_to_utf8(buf, units)
	return string(buf[:written])
}

// Decodes a NUL-terminated UTF-16 run. Sciter hands these back from callbacks that report no length.
@(require_results)
string_from_utf16_cstring :: proc(p: [^]u16, allocator := context.allocator) -> string {
	if p == nil {
		return ""
	}
	n: uint
	for p[n] != 0 {
		n += 1
	}
	return string_from_utf16(p, n, allocator)
}

// ---------------------------------------------------------------------------------------------------
// Overload groups
//
// A window and an element both have a "state", and they are different things - a window is shown or
// minimized, an element is hovered or checked. The two are named apart so each can be called directly,
// and grouped here so `state(x)` picks the right one.

state :: proc {
	window_state,
	element_state,
}

set_state :: proc {
	set_window_state,
	set_element_state,
}
