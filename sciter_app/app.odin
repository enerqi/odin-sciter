// Application lifecycle: Sciter's own message pump, on every platform.
//
// Sciter 6 dropped GTK on Linux and renders through its own EGL/GLESv2 backend, so there is no Win32
// pump, no gtk_main() and no NSApplication here - `SciterExec` is the whole story. See docs/PLAN.md
// section 4.
package sciter_app

import sciter ".."
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"

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
shutdown :: proc() {
	sciter.api().SciterExec(.SHUTDOWN, 0, 0)
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
	return nil if ok else Api_Error.Load_Failed
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

// Routes the engine's HTML/CSS/script diagnostics somewhere. Without this, a CSS typo or a script error
// is silent - which is the single most confusing thing about a first Sciter document.
//
// `handler` is called from the engine, so it must be `proc "system"`. Pass nil to detach.
set_debug_output :: proc(handler: sciter.Debug_Output_Proc, param: rawptr = nil, window: Window = nil) {
	sciter.api().SciterSetupDebugOutput(rawptr(window), param, handler)
}

// Installs a handler that prints the engine's diagnostics to stderr.
//
// Call this before loading a document. Without some debug output installed, a CSS typo, a bad URL and
// a script exception are all completely silent, which is the most confusing thing about a first Sciter
// document.
set_default_debug_output :: proc(window: Window = nil) {
	g_debug_ctx = context
	set_debug_output(default_debug_output, nil, window)
}

@(private)
g_debug_ctx: runtime.Context

@(private)
default_debug_output :: proc "system" (
	param: rawptr,
	subsystem: sciter.Output_Subsytems,
	severity: sciter.Output_Severity,
	text: [^]u16,
	text_length: u32,
) {
	context = g_debug_ctx
	msg := string_from_utf16(text, uint(text_length), context.temp_allocator)
	fmt.eprintfln("[sciter %v %v] %s", subsystem, severity, strings.trim_right_space(msg))
}
