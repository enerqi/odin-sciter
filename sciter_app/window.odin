// Windows: creating one, putting a document in it, and running script against it.
package sciter_app

import sciter ".."

// An engine window. This is Sciter's HWINDOW - a HWND on Windows, an NSView* on macOS, and an opaque
// pointer to the engine's own X11/Wayland window on Linux, where Sciter 6 no longer uses GTK.
Window :: distinct rawptr

Window_Options :: struct {
	x, y:          i32, // position in ppx; ignored unless width and height are set
	width, height: i32, // 0,0 lets the engine pick
	flags:         sciter.Sciter_Create_Window_Flags, // {} means {.MAIN}
	parent:        Window,
}

// Creates a top-level window.
//
// `.MAIN` is what makes closing the window end the message pump, and is the default. `.ENABLE_DEBUG`
// additionally lets the SDK's `inspector` attach to it.
//
// Sciter 6 removed the SW_TITLEBAR / SW_RESIZEABLE / SW_CONTROLS / SW_GLASSY / SW_ALPHA / SW_TOOL flags
// that 4.x had: a plain top-level window is the default now, and window chrome is a CSS concern. The
// window's title comes from the document's <title>, not from here.
create_window :: proc(opts := Window_Options{}) -> (window: Window, err: Error) {
	if !sciter.loaded() {
		return nil, .Not_Loaded
	}

	flags := opts.flags
	if flags == {} {
		flags = {.MAIN}
	}

	frame := sciter.Tag_Rect {
		left   = sciter.Int(opts.x),
		top    = sciter.Int(opts.y),
		right  = sciter.Int(opts.x + opts.width),
		bottom = sciter.Int(opts.y + opts.height),
	}
	pframe := &frame
	if opts.width == 0 && opts.height == 0 {
		pframe = nil // let the engine choose
	}

	h := sciter.api().SciterCreateWindow(flags, pframe, nil, nil, rawptr(opts.parent))
	if h == nil {
		return nil, .Window_Failed
	}
	return Window(h), nil
}

// Loads a document from a UTF-8 HTML string. `base_url` resolves relative references in it - without
// one, `<img src="logo.png">` has nowhere to look.
load_html :: proc(window: Window, html: string, base_url := "") -> Error {
	base: [^]u16
	if base_url != "" {
		base = raw_data(utf16_from_string(base_url, context.temp_allocator))
	}
	ok := sciter.api().SciterLoadHtml(rawptr(window), raw_data(html), u32(len(html)), base)
	return nil if ok else Api_Error.Load_Failed
}

// Loads a document by URL. A bare path is taken relative to the current directory; `file://`,
// `http://` and the engine's own `this://app/` archive scheme all work.
load_file :: proc(window: Window, url: string) -> Error {
	w := utf16_from_string(url, context.temp_allocator)
	ok := sciter.api().SciterLoadFile(rawptr(window), raw_data(w))
	return nil if ok else Api_Error.Load_Failed
}

// Sets the base URL that relative references in the document resolve against.
set_home_url :: proc(window: Window, url: string) -> Error {
	w := utf16_from_string(url, context.temp_allocator)
	ok := sciter.api().SciterSetHomeURL(rawptr(window), raw_data(w))
	return nil if ok else Api_Error.Load_Failed
}

// Adds to the engine's master stylesheet, which sits under every document's own CSS.
set_css :: proc(window: Window, css: string, base_url := "", media_type := "") -> Error {
	base, media: [^]u16
	if base_url != "" {
		base = raw_data(utf16_from_string(base_url, context.temp_allocator))
	}
	if media_type != "" {
		media = raw_data(utf16_from_string(media_type, context.temp_allocator))
	}
	ok := sciter.api().SciterSetCSS(rawptr(window), raw_data(css), u32(len(css)), base, media)
	return nil if ok else Api_Error.Load_Failed
}

// ---------------------------------------------------------------------------------------------------
// State

set_window_state :: proc(window: Window, state: sciter.Sciter_Window_State) {
	sciter.api().SciterWindowExec(rawptr(window), .SET_STATE, uintptr(state), 0)
}

window_state :: proc(window: Window) -> sciter.Sciter_Window_State {
	return sciter.Sciter_Window_State(sciter.api().SciterWindowExec(rawptr(window), .GET_STATE, 0, 0))
}

show :: proc(window: Window) {
	set_window_state(window, .SHOWN)
}

hide :: proc(window: Window) {
	set_window_state(window, .HIDDEN)
}

// Closing the last `.MAIN` window is what ends `run`.
close :: proc(window: Window) {
	set_window_state(window, .CLOSED)
}

// Brings the window forward and gives it focus.
activate :: proc(window: Window, bring_to_front := true) {
	sciter.api().SciterWindowExec(rawptr(window), .ACTIVATE, uintptr(1 if bring_to_front else 0), 0)
}

// ---------------------------------------------------------------------------------------------------
// Script

// Runs a script in the window's global scope and returns its result.
//
// The returned Value owns a reference; `clear` it when done. A script *error* is reported through
// `set_debug_output` and comes back here as `.Eval_Failed` - without a debug output handler installed
// there is nothing else to see.
eval :: proc(window: Window, script: string) -> (result: Value, err: Error) {
	w := utf16_from_string(script, context.temp_allocator)
	value_init(&result)
	ok := sciter.api().SciterEval(rawptr(window), raw_data(w), u32(len(w) - 1), &result)
	if !ok {
		value_clear(&result)
		return {}, .Eval_Failed
	}
	return result, nil
}

// Calls a function defined in the document's global scope.
//
//	v, err := sciter_app.call(w, "greet", sciter_app.value_from("world"))
//
// The returned Value owns a reference; `clear` it when done. The arguments do not - they are still the
// caller's to clear.
call :: proc(window: Window, function: string, args: ..Value) -> (result: Value, err: Error) {
	name := to_cstring(function, context.temp_allocator)
	value_init(&result)

	argv: ^sciter.Value
	if len(args) > 0 {
		argv = &args[0]
	}

	ok := sciter.api().SciterCall(rawptr(window), name, u32(len(args)), argv, &result)
	if !ok {
		value_clear(&result)
		return {}, .Call_Failed
	}
	return result, nil
}

// Publishes a value into the document's global scope, where script sees it as `globalThis.name`.
//
// This is how an Odin procedure is exposed to script:
//
//	fn := sciter_app.value_from_function(my_proc, &my_state)
//	defer sciter_app.value_clear(&fn)
//	sciter_app.set_global(window, "my_proc", &fn)
//
// `value` is copied, not consumed. Globals belong to the *document*, so this has to be redone after
// every load.
//
// Implementation note, because the obvious route does not work: ISciterAPI has `SciterGetViewExpando`,
// which would hand back `globalThis` as a Value to assign into, but on Sciter 6 that slot is NULL on
// every platform - `just example api_map` lists it among the 16 unimplemented ones, left behind by the
// removed TIScript VM. So instead a one-line assignment function is evaluated and then invoked with
// the name and the value as arguments, which needs no cooperation from the document.
set_global :: proc(window: Window, name: string, value: ^Value) -> Error {
	setter := eval(window, "(function(n, v) { globalThis[n] = v; })") or_return
	defer value_clear(&setter)

	key := value_from_string(name)
	defer value_clear(&key)

	args := [2]Value{key, value^}
	result := value_invoke(&setter, nil, args[:]) or_return
	value_clear(&result)
	return nil
}

// The DOM's document element - `<html>`. Every traversal starts here.
root :: proc(window: Window) -> (element: Element, err: Error) {
	he: sciter.Helement
	dom_err(sciter.api().SciterGetRootElement(rawptr(window), &he)) or_return
	if he == nil {
		return nil, .Not_Found
	}
	return Element(he), nil
}
