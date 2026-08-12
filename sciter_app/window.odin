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

// Sets this window's own stylesheet.
//
// **It replaces the document's own `<style>`, it does not layer under it.** Measured: against a
// document whose sheet says `p { color: #00ff00 }`, a `set_css` mentioning only `div` leaves the `p`
// black - the document's rule is gone, not merely outranked. A `!important` in the document loses to a
// plain rule here for the same reason. Only inline styles (`set_style`, `style=`) still win.
//
// Two more measured rules:
//
//   - **A reload discards it.** `load_html` restores the document's own sheet and drops this one, so a
//     window sheet has to be re-applied after every load.
//   - **Each call replaces the last.** There is one window sheet, not a stack of them.
//
// Empty CSS is refused with `.Load_Failed`. CSS the parser cannot make sense of is *accepted* - and
// still replaces the document's sheet, so the document ends up with no styling at all rather than an
// error. `media_type` was measured not to restrict anything on this engine: a sheet declared for
// `print` applied on screen.
//
// For a sheet that applies to every window, see `set_master_css` in `app.odin`.
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

// Repaints whatever the window has marked dirty, now, instead of at the next turn of the message loop.
// Only needed when something is driving the engine other than `run` - a custom loop, or a long
// operation on this thread that has to show progress.
update_window :: proc(window: Window) {
	sciter.api().SciterUpdateWindow(rawptr(window))
}

// The media type the window's `@media` rules are matched against: "screen" (the default), "print",
// "handheld", or any name the document's CSS uses.
//
// **Measured, and the reason to call this exactly once:** only the *first* call on a window has any
// effect. Later calls report success and change nothing, including after loading a new document - a
// window switched to "print" stays there. Set it before the document that needs it is loaded, and
// treat it as a property of the window rather than as a switch.
set_media_type :: proc(window: Window, media_type: string) -> Error {
	w := utf16_from_string(media_type, context.temp_allocator)
	ok := sciter.api().SciterSetMediaType(rawptr(window), raw_data(w))
	return nil if ok else Api_Error.Load_Failed
}

// The window's media *flags* - the switchable half of `@media`, and the mechanism behind theming an
// application without rewriting its CSS or reloading it.
//
// `vars` is a map of name to truthy/falsy, and every name in it becomes a media query the document's
// CSS can match by bare name:
//
//	vars: sciter_app.Value
//	defer sciter_app.value_clear(&vars)
//	on := sciter_app.value_from(true)
//	defer sciter_app.value_clear(&on)
//	sciter_app.value_set(&vars, "dark", &on)
//	sciter_app.set_media_vars(window, &vars)   // now `@media dark { … }` applies
//
// It is not consumed. Four measured properties, none of them in the header:
//
//   - **flags merge, they do not replace.** A call naming only `dark` leaves every flag already set -
//     `screen`, which is on by default, included. To turn one off, name it with `false` (or an
//     undefined Value); an empty map changes nothing.
//   - **it takes effect immediately**, unlike `set_media_type`, and as often as it is called.
//   - **it survives a reload**, where a document's globals do not.
//   - **the syntax is a bare name.** `@media (theme: "dark")` parses and then matches *unconditionally*
//     - it is not an error and not a flag test, which makes it an expensive mistake to make. Name the
//     state itself: `@media dark`.
//
// A document already laid out keeps the style it resolved, so `update_element(el, true)` on what
// should change, or a reload, is what makes the switch visible.
set_media_vars :: proc(window: Window, vars: ^Value) -> Error {
	ok := sciter.api().SciterSetMediaVars(rawptr(window), vars)
	return nil if ok else Api_Error.Load_Failed
}

// ---------------------------------------------------------------------------------------------------
// Focus and highlight
//
// Both are properties of the *window* rather than of an element - one element per window has the focus,
// one has the debug highlight - which is why they live here and take a `Window`.

// The element with the keyboard focus, or `.Not_Found` when nothing has it. Right after a load that is
// the usual answer: focus arrives with the first interaction.
focus_element :: proc(window: Window) -> (element: Element, err: Error) {
	he: sciter.Helement
	dom_err(sciter.api().SciterGetFocusElement(rawptr(window), &he)) or_return
	if he == nil {
		return nil, .Not_Found
	}
	return Element(he), nil
}

// Gives the element the keyboard focus.
//
// There is no `SciterSetFocus`: the focus is the `:focus` state, and setting it is what moves it. This
// is that call, named for what it does.
//
// There is no way back, either - **clearing `.FOCUS` does not leave the window with nothing focused**,
// it just stops the element matching `:focus` while `focus_element` keeps reporting it. Move the focus
// somewhere else instead.
set_focus :: proc(element: Element) -> Error {
	return set_element_state(element, {.FOCUS})
}

// The element the engine is drawing its debug highlight over - the outline the SDK's inspector puts
// around what you hover in its tree. `.Not_Found` when there is none, which is the normal state.
highlighted_element :: proc(window: Window) -> (element: Element, err: Error) {
	he: sciter.Helement
	dom_err(sciter.api().SciterGetHighlightedElement(rawptr(window), &he)) or_return
	if he == nil {
		return nil, .Not_Found
	}
	return Element(he), nil
}

// Highlights an element, or clears the highlight with a nil one. This is a debugging aid - "which
// element is this, on screen" - and not a selection: it draws an overlay and leaves no state on the
// element, so nothing in the document can match on it.
set_highlighted_element :: proc(window: Window, element: Element) -> Error {
	return dom_err(sciter.api().SciterSetHighlightedElement(rawptr(window), sciter.Helement(element)))
}

// ---------------------------------------------------------------------------------------------------
// State

// Asks the window to change state.
//
// **Only `.SHOWN` and `.CLOSED` are reflected back by `window_state` on the vendored engine under X11.**
// `.MINIMIZED`, `.MAXIMIZED`, `.FULL_SCREEN` and `.HIDDEN` are all accepted without complaint and the
// window goes on reporting `.SHOWN`. Whether the window manager acts on them is its own business; what
// is measured here is that the engine will not tell you. So this is not a state machine to drive an
// application from - keep your own flag if you need to know.
//
// **`.FULL_SCREEN` changes the display mode, and nothing puts it back.** Asking a small window to go
// full screen on X11 made the window manager switch the monitor to the nearest mode - a 300x200 window
// took a 1920x1200 laptop panel down to 320x180 - and it stayed there after the process exited. Nothing
// in this package restores it; `xrandr --output <name> --mode <preferred>` does. Do not call it from a
// test, and size the window before asking.
set_window_state :: proc(window: Window, state: sciter.Sciter_Window_State) {
	sciter.api().SciterWindowExec(rawptr(window), .SET_STATE, uintptr(state), 0)
}

// The window's state - but see `set_window_state` for how little of it is reported.
//
// Two values outside the obvious ones:
//
//   - a window that has been created and never shown reports `.CLOSED`, not `.HIDDEN`
//   - **a closed window reports `0xFFFFFFFE`, which is not in the enum at all.** Odin will not stop you
//     comparing against it, so a `switch` on this needs a default arm. Everything else about the handle
//     is dead too: `root` answers `.INVALID_HWND`.
window_state :: proc(window: Window) -> sciter.Sciter_Window_State {
	return sciter.Sciter_Window_State(sciter.api().SciterWindowExec(rawptr(window), .GET_STATE, 0, 0))
}

show :: proc(window: Window) {
	set_window_state(window, .SHOWN)
}

// Asks the window to hide. Measured: the window goes on reporting `.SHOWN` afterwards - see
// `set_window_state`. The document is untouched either way, so a later `show` finds it as it was.
hide :: proc(window: Window) {
	set_window_state(window, .HIDDEN)
}

// Closing the last `.MAIN` window is what ends `run`.
//
// **Closing a secondary window that has a document loaded crashes the engine on the next turn of the
// pump.** Measured, and reproducible in three lines: `create_window`, `load_html`, `close`, then a
// single `heartbeat` - the segfault is inside the engine's own `check_paint`, walking down to
// `GetWindowSizeX11` on a window whose X11 window is gone. It has been left on the paint list. A
// window that never had a document closes cleanly, and so does one that is never pumped again.
//
// **`hide`, then at least one turn of the pump, then `close`, is the order that works.** Hiding takes
// the window off the paint list, and it is the pump that does the taking - hiding and closing in the
// same turn crashes exactly like closing outright. Five teardowns were measured on 6.0.4.9 under X11,
// on windows that had been shown and on windows that never were:
//
//	close, with a document loaded             segfault on the next pump
//	load_html("<html></html>") then close     segfault on the next pump
//	hide then close, same turn                segfault on the next pump
//	hide, heartbeat, close                    survives; the handle is then dead
//	never closed                              survives
//
// The second line is the one to notice: unloading the document first was the advice here until it was
// measured, and it does not work. In an application the practical answer is to **hide a secondary
// window and keep it** - reopening is a `show` - and to do the hide/pump/close only on the way out.
// `examples/workbench.odin` does both, and pins the order with a test; `dom_walk`'s close test asserts
// what it can before pumping and stops there.
//
// After a successful close the handle is dead in the two ways `window_state` describes below: `root`
// answers `.INVALID_HWND`, and the state is `0xFFFFFFFE`.
//
// Nothing about the close is signalled, either: immediately afterwards the handle still answers - even
// `root` succeeds - because the close has not happened yet. It happens on the pump.
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
// The route that looks right in the header is `SciterGetViewExpando`, which would hand back
// `globalThis` as a Value to assign into - but that slot is NULL on every platform on Sciter 6, left
// behind by the removed TIScript VM, and `just example api_map` lists it among the 16 unimplemented
// ones. `SciterSetVariable` is the one that works, and `window` is required despite the C parameter
// being named `hwndOrNull`: passing NULL reports success and publishes nothing.
set_global :: proc(window: Window, name: string, value: ^Value) -> Error {
	return dom_err(
		sciter.Scdom_Result(
			sciter.api().SciterSetVariable(rawptr(window), to_cstring(name, context.temp_allocator), value),
		),
	)
}

// Reads a global back out of the document - one this published, or one script defined.
//
// A name that is not there is not an error: the Value comes back undefined, which is what script would
// say too. The result owns a reference; `value_clear` it.
global :: proc(window: Window, name: string) -> (value: Value, err: Error) {
	dom_err(
		sciter.Scdom_Result(
			sciter.api().SciterGetVariable(rawptr(window), to_cstring(name, context.temp_allocator), &value),
		),
	) or_return
	return value, nil
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
