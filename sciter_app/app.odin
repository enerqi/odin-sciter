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
//
// **The advice is written for the reader's platform and for a program outside this repository**, which
// is where this message is actually read. It used to say
// `SCITER_LIB=/path/to/sdk/bin/linux/x64 just example hello_window` on all three: a Linux path, a shell
// idiom that does nothing in cmd or PowerShell, and a recipe from a checkout the reader does not have.
// It also skipped the answer a shipped application wants - the library beside the executable, which is
// already the first candidate in the list above it. See docs/using-in-your-project.md.
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
	fmt.eprintfln("\nEither put %s next to the executable - the first path above - or point", sciter.LIBRARY_NAME)
	fmt.eprintln("SCITER_LIB at the library file or the directory holding it:")
	when ODIN_OS == .Windows {
		fmt.eprintln("  set SCITER_LIB=C:\\path\\to\\sciter-js-sdk\\bin\\windows\\x64      (cmd)")
		fmt.eprintln("  $env:SCITER_LIB = 'C:\\path\\to\\sciter-js-sdk\\bin\\windows\\x64'  (PowerShell)")
	} else when ODIN_OS == .Darwin {
		fmt.eprintln("  export SCITER_LIB=/path/to/sciter-js-sdk/bin/macosx")
	} else {
		fmt.eprintln("  export SCITER_LIB=/path/to/sciter-js-sdk/bin/linux/x64")
	}
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

// Traps if a window is about to be created without `init` having run. Debug builds only, like the
// affinity guard in `affinity.odin`, and for the same reason: the failure this prevents lands nowhere
// near the mistake.
//
// **Measured on Windows, 6.0.4.9, and it is the worst shape a mistake can have.** Skipping `init`
// does not fail at `create_window`, which the documentation used to claim: the window is created, the
// document loads, the DOM answers, `hide`/`heartbeat`/`close` all succeed - and then the *process
// segfaults on the way out of `main`*, exit code 139, with nothing on the stack naming the omission.
// The same program with `init` exits 0. So there is no error to return that anybody would see in time,
// and nothing later in the run to trap on; the only moment the mistake is still visible is this one.
//
// A windowless program is not affected and never reaches here: `create_windowless` stands the engine
// up itself and `docs/gotchas.md` #11 is the rule about not mixing the two in one process.
@(private)
guard_initialized :: proc(loc := #caller_location) {
	when ODIN_DEBUG {
		if g_initialized {
			return
		}
		runtime.print_string(
			"\nsciter_app: create_window before init()\n" +
			"  `init` is SCITER_APP_INIT, and the engine wants argv before any window exists. Without it\n" +
			"  everything here works - the window opens, the document loads - and the process faults at\n" +
			"  exit instead, a long way from this call. Add `sciter_app.init()` after `load_engine`.\n" +
			"  See docs/getting-started.md and docs/rules.md.\n  at ",
		)
		runtime.print_caller_location(loc)
		runtime.print_string("\n")
		runtime.trap()
	}
}

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

	engine().SciterExec(.INIT, uintptr(len(g_argv)), uintptr(raw_data(g_argv)))
	g_initialized = true
	return nil
}

// Runs the message pump until `stop` is called or the last SW_MAIN window closes. Returns the
// engine's exit code.
//
// **It never returns to your code in between, so it is not a place to free anything.** Every call in
// this package that takes a string, a selector or a URL bumps `context.temp_allocator`, nothing here
// ever calls `free_all`, and a handler that does DOM work under `run` therefore grows the arena for as
// long as the application lives - which looks like a leak in the bindings and is not one. Either put
// the boundary inside your handlers, or drive the pump yourself:
//
//	for sciter_app.run_once() {
//		sciter_app.heartbeat()
//		free_all(context.temp_allocator)   // the boundary
//	}
//
// `docs/rules.md` §4 is the whole rule and the three boundaries worth choosing between.
run :: proc() -> int {
	return int(engine().SciterExec(.LOOP, 0, 0))
}

// Runs one iteration of the pump. Returns false when the pump is finished - `run` is a loop over this.
// Use it when Sciter has to share a thread with another event source.
run_once :: proc() -> bool {
	return engine().SciterExec(.LOOP_ITERATION, 0, 0) != 0
}

// Services outstanding tasks and timers without processing input. Pair with `run_once`.
heartbeat :: proc() {
	engine().SciterExec(.LOOP_HEARTBIT, 0, 0)
}

// Asks the pump to return, with the value `run` should hand back. Safe to call from an event handler,
// and **only** useful from one: called before `run`, it does not pre-arm anything and `run` still
// blocks.
//
// **`exit_code` is a parameter the C header does not mention.** `SCITER_APP_STOP` is documented as
// `reuest to quit message pump loop` and nothing else; the SDK's C++ layer is where it surfaces, as
// `request_quit(int rv)`. Measured on 6.0.4.9: `stop(42)` from inside the pump makes `run` return 42,
// and the underlying call answers 0 to mean the request was accepted.
//
// This is the second parameter found hiding behind the two `*Exec` dispatchers - see `close` in
// `window.odin` for the first, and `docs/gotchas.md` for why this API shape keeps producing them.
stop :: proc(exit_code := 0) {
	engine().SciterExec(.STOP, uintptr(exit_code), 0)
}

// Releases the engine's resources. Call after `run` returns.
//
// The argv `init` built is freed here, after SHUTDOWN rather than before: the engine holds those
// pointers for as long as it is running. Without this an `init` -> `shutdown` -> `init` cycle - a plugin
// host, or a test proving `shutdown` releases everything - leaks the previous set.
shutdown :: proc() {
	engine().SciterExec(.SHUTDOWN, 0, 0)

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
	api := engine()
	return {api.SciterVersion(0), api.SciterVersion(1), api.SciterVersion(2), api.SciterVersion(3)}
}

// An engine option. `window` is nil for the process-wide options, which is most of them.
//
// **`Sciter_Rt_Options`'s `hWnd` comments do not tell you which ones need a window, and the return
// value is the only thing that does.** Measured on 6.0.4.9, on Linux and on Windows, with
// `examples/script_bridge.odin` holding the test:
//
//   - Accepted with no window, both platforms: `.SET_SCRIPT_RUNTIME_FEATURES`, `.SET_GFX_LAYER`,
//     `.SET_DEBUG_MODE`, `.SET_UX_THEMING`, `.SET_MAX_HTTP_DATA_LENGTH`, `.SET_PX_AS_DIP`,
//     `.SET_INIT_SCRIPT`, `.USE_INTERNAL_HTTP_CLIENT`, `.EXTENDED_TOUCHPAD_SUPPORT`.
//   - **Needs a window**, both platforms: `.SMOOTH_SCROLL`, whose header comment says only
//     "value:TRUE - enable" and reads like a global preference. It fails with nil and succeeds with a
//     window.
//   - Refused either way, both platforms: `.FONT_SMOOTHING` and `.ENABLE_UIAUTOMATION`. The option
//     exists in the header and is implemented on neither - `.ENABLE_UIAUTOMATION` notably so, since UI
//     Automation is a Windows API.
//   - **Platform-specific**: `.CONNECTION_TIMEOUT` and `.HTTPS_ERROR` are refused either way on Linux
//     and accepted either way on Windows. Both configure the HTTP client, and the split follows it -
//     Linux uses the system client and has nothing to set.
//   - **Windows only, and all three need a window**: `.TRANSPARENT_WINDOW`, `.ALPHA_WINDOW` and
//     `.SET_MAIN_WINDOW`. Not measured on Linux, where the features they name do not exist.
//
// An unknown option code is refused rather than ignored, so a failure really is a failure. Check the
// error; the only way to find out that an option did not take is to look.
//
// `value` is an untyped word on purpose: what it means is chosen by `option`, and it is a boolean for
// `.SMOOTH_SCROLL`, milliseconds for `.CONNECTION_TIMEOUT`, a `Script_Runtime_Features` mask for
// `.SET_SCRIPT_RUNTIME_FEATURES`, a UTF-8 string pointer for `.SET_INIT_SCRIPT`. Typing it would mean
// one wrapper per option; the two worth having are below.
//
// `.SET_INIT_SCRIPT` is the one with a lifetime question, and the header's answer holds: the engine
// copies the source inside the call, measured by freeing the string and overwriting its bytes before
// loading the document that runs it. Setting it again *replaces* the script rather than adding to it,
// and it runs at every `load_html` - into that document's `globalThis`, before the document's own
// scripts. It is the one way to publish a global that does not go through `set_global`.
set_option :: proc(option: sciter.Sciter_Rt_Options, value: uintptr, window: Window = nil) -> Error {
	ok := engine().SciterSetOption(rawptr(window), option, value)
	return nil if ok else Api_Error.Option_Failed
}

// Which script capabilities the engine grants. Sciter denies file and socket access by default, so a
// document that needs either has to be granted it here, before the window is created.
set_script_features :: proc(features: sciter.Script_Runtime_Features) -> Error {
	return set_option(.SET_SCRIPT_RUNTIME_FEATURES, uintptr(transmute(u32)features))
}

// Lets the SDK's `inspector` attach to a window created with `.ENABLE_DEBUG`. The flag makes the window
// inspectable, this makes the engine listen.
//
// **A third thing is needed and neither of these is it: `set_script_features` must include
// `.SOCKET_IO`.** The inspector connects over a socket opened by the *document's* script runtime, so
// without that permission the window is inspectable, the engine is listening, and the inspector waits
// forever on "Waiting for a connection with Sciter's view" - which reads as one of the other two halves
// being wrong. Measured on Windows; the inspector's own start screen says so if you read it.
// `examples/inspector.odin` sets `{.FILE_IO, .SOCKET_IO, .EVAL, .SYSINFO}`, which is what its notice
// asks for.
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
	engine().SciterSetupDebugOutput(rawptr(window), param, handler)
}

// Installs a handler that prints the engine's diagnostics to stderr.
//
// Call this before loading a document. Without some debug output installed, a CSS typo, a bad URL and
// a script exception are all completely silent, which is the most confusing thing about a first Sciter
// document.
//
// **On Windows it is not only about visibility, and it is close to mandatory.** With no handler
// installed the engine falls back to `OutputDebugStringW`, and Windows implements that by *raising an
// exception* - `DBG_PRINTEXCEPTION_WIDE_C`, `0x4001000A`. Ordinarily nothing notices: with no debugger
// attached the OS handles it and execution continues. But any process that installs a vectored or
// unhandled-exception filter and treats what it catches as fatal will be taken down by a CSS warning.
//
// Odin's own test runner is exactly such a process. Measured: `set_css(window, "this is not css")` in a
// test killed the test and every test after it in the binary, reported as `Signal caught: Unknown`,
// which reads like a segfault and is not one. Installing a handler routes the diagnostic to the
// callback and the `OutputDebugStringW` path is never taken. That is why every test harness in
// `examples/` calls this, not only the ones that want to read the messages.
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

	// A fixed buffer is safe here because `utf16.decode_to_utf8` bounds-checks its destination: a
	// message longer than DEBUG_MESSAGE_MAX truncates rather than overflowing, and `written` is the
	// count that actually fit. Measured, not assumed. This runs on the engine's own callback with no
	// allocator worth trusting, which is why it is a stack buffer rather than a make().
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
	ok := engine().SciterSetMasterCSS(raw_data(css), u32(len(css)))
	return nil if ok else Api_Error.Option_Failed
}

// Adds to the master stylesheet, keeping what is already there.
append_master_css :: proc(css: string) -> Error {
	ok := engine().SciterAppendMasterCSS(raw_data(css), u32(len(css)))
	return nil if ok else Api_Error.Option_Failed
}
