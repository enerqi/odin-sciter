// Application lifecycle: Sciter's own message pump, on every platform.
//
// Sciter 6 dropped GTK on Linux and renders through its own EGL/GLESv2 backend, so there is no Win32
// pump, no gtk_main() and no NSApplication here - `SciterExec` is the whole story. See docs/PLAN.md
// section 4.
package sciter_app

import sciter ".."
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:unicode/utf16"

// Opens the engine, or explains on stderr where it looked and why that failed.
//
// This is `sciter.load` plus the error message. "it did not load" is the most common first-run problem
// with Sciter and a bare dlopen error says nothing useful, so the candidate list is worth printing
// every time.
load_engine :: proc(path := "") -> bool {
	err, tried := sciter.load(path)

	// `sciter.load` hands the candidate list to the caller on every path, including success, because
	// it is the whole diagnostic when the library is not found. Nothing else owns it.
	defer {
		for candidate in tried {
			delete(candidate)
		}
		delete(tried)
	}

	if err == .None || err == .Already_Loaded {
		return true
	}

	fmt.eprintfln("could not load the Sciter engine: %v", err)
	fmt.eprintln("looked for", sciter.LIBRARY_NAME, "in:")
	for candidate in tried {
		fmt.eprintfln("  %s", candidate)
	}
	fmt.eprintln("\nSet SCITER_LIB to the library file or its directory, e.g.")
	fmt.eprintln("  SCITER_LIB=/path/to/sciter-js-sdk/bin/linux/x64 just example hello_window")
	return false
}

// SCITER_APP_INIT is handed pointers into these. The engine is not documented to copy them and
// `application::start()` in sciter-x-window.hpp keeps the vector it builds, so they are held for the
// life of the process rather than freed at the end of `init`.
@(private)
g_argv_storage: [][]u16

@(private)
g_argv: [][^]u16

// Remembered so `shutdown` can give the argv back to the allocator `init` took it from.
@(private)
g_argv_allocator: mem.Allocator

@(private)
g_initialized: bool

// Hands the engine argc/argv. Call once, after `sciter.load()` and before creating any window.
//
// `args` defaults to `os.args`. The engine wants UTF-16 here: the comment on SCITER_APP_INIT in
// sciter-x-def.h says "p2 - CHAR** argv" and is wrong - `application::start()` builds a
// `vector<const WCHAR*>`, and passing char** or NULL crashes.
init :: proc(args: []string = nil, allocator := context.allocator) -> Error {
	if !sciter.loaded() {
		return .Not_Loaded
	}
	if g_initialized {
		return nil
	}

	argv := args if args != nil else os.args

	g_argv_allocator = allocator
	g_argv_storage = make([][]u16, len(argv), allocator)
	g_argv = make([][^]u16, len(argv), allocator)
	for arg, i in argv {
		g_argv_storage[i] = utf16_from_string(arg, allocator)
		g_argv[i] = raw_data(g_argv_storage[i])
	}

	sciter.api().SciterExec(.INIT, uintptr(len(g_argv)), uintptr(raw_data(g_argv)))
	g_initialized = true
	return nil
}

// Runs the message pump until `stop` is called or the last SW_MAIN window closes. Returns the
// engine's exit code.
run :: proc() -> int {
	return int(sciter.api().SciterExec(.LOOP, 0, 0))
}

// Runs one iteration of the pump. Returns false when the pump is finished - `run` is a loop over this.
// Use it when Sciter has to share a thread with another event source.
run_once :: proc() -> bool {
	return sciter.api().SciterExec(.LOOP_ITERATION, 0, 0) != 0
}

// Services outstanding tasks and timers without processing input. Pair with `run_once`.
heartbeat :: proc() {
	sciter.api().SciterExec(.LOOP_HEARTBIT, 0, 0)
}

// Asks the pump to return. Safe to call from an event handler.
stop :: proc() {
	sciter.api().SciterExec(.STOP, 0, 0)
}

// Releases the engine's resources. Call after `run` returns.
//
// The argv `init` built is freed here, after SHUTDOWN rather than before: the engine holds those
// pointers for as long as it is running. Without this an `init` -> `shutdown` -> `init` cycle - a plugin
// host, or a test proving `shutdown` releases everything - leaks the previous set.
shutdown :: proc() {
	sciter.api().SciterExec(.SHUTDOWN, 0, 0)

	for arg in g_argv_storage {
		delete(arg, g_argv_allocator)
	}
	delete(g_argv_storage, g_argv_allocator)
	delete(g_argv, g_argv_allocator)
	g_argv_storage = nil
	g_argv = nil

	g_initialized = false
}

// The engine's version as [major, minor, revision, build].
version :: proc() -> [4]u32 {
	api := sciter.api()
	return {api.SciterVersion(0), api.SciterVersion(1), api.SciterVersion(2), api.SciterVersion(3)}
}

// An engine option. `window` is nil for the process-wide options, which is most of them - the ones
// that take a window say so in `Sciter_Rt_Options`.
//
// `value` is an untyped word on purpose: what it means is chosen by `option`, and it is a boolean for
// `.SMOOTH_SCROLL`, milliseconds for `.CONNECTION_TIMEOUT`, a `Script_Runtime_Features` mask for
// `.SET_SCRIPT_RUNTIME_FEATURES`, a UTF-8 string pointer for `.SET_INIT_SCRIPT`. Typing it would mean
// one wrapper per option; the two worth having are below.
set_option :: proc(option: sciter.Sciter_Rt_Options, value: uintptr, window: Window = nil) -> Error {
	ok := sciter.api().SciterSetOption(rawptr(window), option, value)
	return nil if ok else Api_Error.Option_Failed
}

// Which script capabilities the engine grants. Sciter denies file and socket access by default, so a
// document that needs either has to be granted it here, before the window is created.
set_script_features :: proc(features: sciter.Script_Runtime_Features) -> Error {
	return set_option(.SET_SCRIPT_RUNTIME_FEATURES, uintptr(transmute(u32)features))
}

// Lets the SDK's `inspector` attach to a window created with `.ENABLE_DEBUG`. Both halves are needed:
// the flag makes the window inspectable, this makes the engine listen.
set_debug_mode :: proc(enabled := true, window: Window = nil) -> Error {
	return set_option(.SET_DEBUG_MODE, uintptr(1 if enabled else 0), window)
}

// Routes the engine's script diagnostics somewhere. Without this, an error in a document's `<script>`
// is silent - which is the single most confusing thing about a first Sciter document.
//
// **What arrives is the *document's* script errors, not `eval`'s.** Measured: a `<script>` that will
// not parse produces a `.SCRIPT` diagnostic at `.ERROR`, an unhandled throw produces one at `.WARNING`
// - and a failing `eval` produces nothing at all. A handler that only logs `.ERROR` therefore drops
// every unhandled rejection; `eval`'s own failure is reported by its return value and nowhere else.
//
// With a `window` the handler hears only that window's diagnostics; without one it is global. The
// message is counted UTF-16, so `string_from_utf16` decodes it - not the cstring form.
//
// `handler` is called from the engine, so it must be `proc "system"` and has no `context`: copy what
// you need and decode it later. Pass nil to detach, and do detach before the handler's memory goes.
set_debug_output :: proc(handler: sciter.Debug_Output_Proc, param: rawptr = nil, window: Window = nil) {
	sciter.api().SciterSetupDebugOutput(rawptr(window), param, handler)
}

// Installs a handler that prints the engine's diagnostics to stderr.
//
// Call this before loading a document. Without some debug output installed, a CSS typo, a bad URL and
// a script exception are all completely silent, which is the most confusing thing about a first Sciter
// document.
//
// The context captured here is only used for `fmt`'s own needs - the message itself is decoded into a
// fixed buffer, so a diagnostic emitted from a thread other than this one does not touch a per-thread
// arena. See `default_debug_output`.
set_default_debug_output :: proc(window: Window = nil) {
	g_debug_ctx = context
	set_debug_output(default_debug_output, nil, window)
}

@(private)
g_debug_ctx: runtime.Context

// A fixed buffer rather than an allocator, for two reasons that only show up late. The engine gives no
// promise about which thread emits a diagnostic and `worker_thread.odin` establishes that there are
// other threads, so `context.temp_allocator` - a per-thread arena - would be bumped from two threads
// with no synchronisation. And nothing here would ever free it: a process that runs the pump forever
// grows that arena by one allocation per diagnostic. Truncation is the price, and it is the right price
// for a default logger; a handler that needs whole messages writes its own.
@(private)
DEBUG_MESSAGE_MAX :: 4096

@(private)
default_debug_output :: proc "system" (
	param: rawptr,
	subsystem: sciter.Output_Subsytems,
	severity: sciter.Output_Severity,
	text: [^]u16,
	text_length: u32,
) {
	context = g_debug_ctx

	buf: [DEBUG_MESSAGE_MAX]u8
	msg := ""
	if text != nil && text_length > 0 {
		written := utf16.decode_to_utf8(buf[:], text[:text_length])
		msg = string(buf[:written])
	}
	fmt.eprintfln("[sciter %v %v] %s", subsystem, severity, strings.trim_right_space(msg))
}

// ---------------------------------------------------------------------------------------------------
// The master stylesheet
//
// The sheet under every document in the process, and the only styling that is not per window: it is
// where an application's default look goes - the one the SDK ships as `master.css` and a document's
// own CSS then overrides. There is no window argument because there is one of these for the engine.
//
// Two measured properties worth knowing before reaching for it:
//
//   - **it applies to documents that are already loaded**, not only to the next one - but the cascade
//     has to be re-run for that to show, so `update_element(el, true)` or a reload is what makes it
//     visible. It survives the reload.
//   - **`set_master_css` replaces, it does not add.** A second call drops everything the first one and
//     any `append_master_css` put there. Set the base sheet once, then append.

// Replaces the master stylesheet.
//
// `""` is refused rather than treated as "clear it" - the engine answers false and keeps what it has -
// so a sheet that matches nothing, `no-such-element {}`, is how to get back to no master styling.
set_master_css :: proc(css: string) -> Error {
	ok := sciter.api().SciterSetMasterCSS(raw_data(css), u32(len(css)))
	return nil if ok else Api_Error.Option_Failed
}

// Adds to the master stylesheet, keeping what is already there.
append_master_css :: proc(css: string) -> Error {
	ok := sciter.api().SciterAppendMasterCSS(raw_data(css), u32(len(css)))
	return nil if ok else Api_Error.Option_Failed
}
