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
@(test)
test_relative_links_resolve_through_load_html_not_set_home_url :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

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
