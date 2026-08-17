// Loading a document from disk, so that its relative URLs resolve.
//
//   just example load_file
//
// `hello_window` hands the engine a string of HTML, which has no location, so `<link href="x.css">`
// inside it has nowhere to look. A document needs a base URL before relative references mean anything,
// and there are two ways to give it one:
//
//   - load it by URL with `load_file`, and the URL it came from *is* the base
//   - keep loading from a string, and pass `load_html` a `base_url`
//
// **Not `set_home_url`**, which is the obvious-looking third option and does not do this - it sets the
// base for `sciter:` URLs only. That was written here as fact, went unchecked because no example ever
// called it, and is now pinned by the `@(test)` at the bottom of this file.
//
// This example does the first. The document it loads pulls in a stylesheet and an SVG next to it, so a
// wrong base URL shows up as unstyled text and a missing image rather than as an error.
package main

import "../sciter_app"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

main :: proc() {
	if !sciter_app.load_engine() {
		os.exit(1)
	}
	// Without this, a mistake in hello.css is silent.
	sciter_app.set_default_debug_output()

	if err := sciter_app.init(); err != nil {
		fmt.eprintln("init failed:", err)
		os.exit(1)
	}

	window, err := sciter_app.create_window({width = 760, height = 520})
	if err != nil {
		fmt.eprintln("could not create a window:", err)
		os.exit(1)
	}

	// SciterLoadFile takes a URL, not a path. A bare relative path happens to work from the current
	// directory, but an absolute file:// URL is what makes this independent of where it was started.
	url := file_url("examples/assets/hello.htm")
	defer delete(url)

	fmt.println("loading", url)
	if lerr := sciter_app.load_file(window, url); lerr != nil {
		fmt.eprintln("could not load the document:", lerr)
		fmt.eprintln("(run this from the repository root - the path above is resolved against $PWD)")
		os.exit(1)
	}

	// The equivalent when the HTML is a string rather than a file: hand `load_html` the base URL
	// alongside it. Note the trailing slash - a base URL names a directory.
	//
	//	sciter_app.load_html(window, some_html_string, file_url("examples/assets/"))
	//
	// The `@(test)` at the bottom of this file runs that windowlessly, and also runs the version with
	// `set_home_url` instead - which does not work, and is why the test exists.

	sciter_app.show(window)
	sciter_app.run()
	sciter_app.shutdown()
}

// **The second route, measured - and it is not what this file used to say it was.**
//
// `set_home_url` does not give a string document a base for its relative references. It sets the base
// that **`sciter:` URLs** resolve against, which is what `SciterSetHomeURL`'s own header in
// sciter-x-def.h says and nothing here had checked. `load_html`'s `base_url` parameter is the one that
// resolves `<link href="hello.css">`. Both halves are asserted below so the wrong claim cannot come
// back.
//
// How the wrong claim survived: `set_home_url` was the one exported procedure of `sciter_app` that no
// example ever called. `just stats` reported it as covered anyway, because the commented-out line
// further up this file mentions it and the text search behind that count could not tell a comment from
// code. Rewriting `stats` to read the parsed source dropped the mention, the coverage number fell by
// one, and this is the test written to close the gap - which is how the documentation error was found.
//
// Windowless, so it needs no display and runs in the ordinary CI test job: the stylesheet either
// resolves or it does not, and neither answer needs a window on screen.
// **macOS: the engine's AppKit singleton has to be built on the main thread, and a *windowless* view
// builds it too.** `create_windowless` reaches the same singleton the windowed path does -
// `lite::application::factory` is in the abort trace either way - and AppKit aborts the whole process
// when that happens off the main thread. Odin's test runner runs every test on a `thread.Pool` worker,
// so the first engine call from one killed this file with
//
//	libc++abi: terminating due to uncaught exception of type NSException
//	  ... lite::application::factory ... sciter_app::create_windowless ... thread_start
//
// `@(init)` procedures do run on the main thread, before the runner starts, so the singleton is built
// there and every later `sciter_app.init()` is a no-op (`g_initialized` in sciter_app/app.odin). Test
// binaries only: a normal build reaches the engine from `main`, which is the main thread by definition.
//
// The same block is in `examples/windowless.odin` and `examples/custom_loader.odin` for the same
// reason. See docs/MACOS-CHECKLIST.md section 2.
when ODIN_OS == .Darwin && ODIN_TEST {
	@(private = "file")
	@(init)
	darwin_main_thread_bootstrap :: proc "contextless" () {
		context = runtime.default_context()
		if !sciter_app.load_engine() {
			return
		}
		_ = sciter_app.init()

		// And forget the thread that just armed rule 1. That thread is `main`, every test runs on a
		// `thread.Pool` worker, and the guard would trap each one on its first engine call. The split is
		// real and unavoidable - AppKit wants main for the singleton, the runner wants a worker for the
		// tests - so what re-arming buys is the rest of the rule: the first test call arms the worker,
		// and a later call from anywhere else still traps.
		sciter_app.check_thread_affinity()
	}
}

// No window is opened, but the view still needs a display: `SXM_CREATE` segfaults without one, measured
// in `examples/windowless.odin`. macOS and Windows always have one; the `@(init)` above is what makes
// macOS survive it.
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
test_relative_links_resolve_through_load_html_not_set_home_url :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}
	if !have_display() {
		fmt.println("no display - skipping, `SXM_CREATE` segfaults without one")
		return
	}

	// The engine outlives the test: `sciter_app.init()` builds process-wide state on first call, and the
	// runner hands each test a tracking allocator it tears down afterwards. Anything the engine path
	// allocates through the context would be reported as a leak by the test that happened to be first.
	// `examples/windowless.odin` and `examples/custom_loader.odin` do the same, for the same reason.
	context.allocator = runtime.default_allocator()

	view, err := sciter_app.create_windowless({width = 400, height = 300})
	testing.expect_value(t, err, nil)
	if view.window == nil {return}
	defer sciter_app.destroy_windowless(&view)

	// `filepath.abs` normalises the trailing separator away, so the slash a base URL needs is put back
	// by hand: a base URL names a directory.
	dir := file_url("examples/assets", context.temp_allocator)
	base := strings.concatenate({dir, "/"}, context.temp_allocator)

	// The call succeeds - which is exactly why the wrong claim survived. Nothing about the return
	// value says the home URL is not doing what the caller thinks.
	testing.expect_value(t, sciter_app.set_home_url(view.window, base), nil)

	HTML :: `<html><head><link rel="stylesheet" href="hello.css"/></head><body><h1 id="h">x</h1></body></html>`

	// Home URL set, no base on the load. The engine asks for `//hello.css`, fails with error 2, and
	// `#h` keeps its default colour.
	testing.expect_value(t, sciter_app.load_html(view.window, HTML), nil)
	settle(&view)
	testing.expect_value(t, element_color(view.window), "#000000")

	// The same document with `load_html`'s own base URL. `h1 { color: #89b4fa }` is hello.css and
	// nothing else - the inline document sets no colour - so this value can only have come from the
	// file on disk that the base URL pointed at.
	testing.expect_value(t, sciter_app.load_html(view.window, HTML, base), nil)
	settle(&view)
	testing.expect_value(t, element_color(view.window), "#89B4FA")
}

// Layout and resource loading happen on the heartbeat, not on the load, so a style read straight after
// `load_html` reads the default. Eight beats is what `examples/windowless.odin` settles in.
@(private = "file")
settle :: proc(view: ^sciter_app.Windowless_View) {
	for _ in 0 ..< 8 {
		sciter_app.windowless_heartbeat(view, 16 * time.Millisecond)
	}
}

@(private = "file")
element_color :: proc(window: sciter_app.Window) -> string {
	root, _ := sciter_app.root(window)
	h, err := sciter_app.select_first(root, "#h")
	if err != nil {return "<no #h>"}
	c, _ := sciter_app.style(h, "color", context.temp_allocator)
	return c
}

@(private = "file")
engine_loaded :: proc(t: ^testing.T) -> bool {
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}

	// **Not optional on Windows, and the reason is not obvious.** With no host handler installed the
	// engine reports parse errors and script diagnostics through `OutputDebugStringW`, which Windows
	// implements by *raising an exception* (DBG_PRINTEXCEPTION_WIDE_C, 0x4001000A). Odin's test runner
	// installs a handler that treats any exception as fatal to the test, so a CSS warning killed the
	// test that provoked it and every test after it in the file. See the same comment in
	// examples/custom_loader.odin.
	sciter_app.set_default_debug_output()
	return true
}

// Turns a path relative to the current directory into an absolute `file://` URL.
file_url :: proc(path: string, allocator := context.allocator) -> string {
	abs, abs_err := filepath.abs(path, context.temp_allocator)
	if abs_err != nil {
		abs = path
	}
	// Windows paths are `C:\x\y`; a file:// URL wants forward slashes and a leading one.
	slashed, _ := strings.replace_all(abs, "\\", "/", context.temp_allocator)
	if !strings.has_prefix(slashed, "/") {
		return strings.concatenate({"file:///", slashed}, allocator)
	}
	return strings.concatenate({"file://", slashed}, allocator)
}
