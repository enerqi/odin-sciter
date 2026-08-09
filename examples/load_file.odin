// Loading a document from disk, so that its relative URLs resolve.
//
//   just example load_file
//
// `hello_window` hands the engine a string of HTML, which has no location, so `<link href="x.css">`
// inside it has nowhere to look. A document needs a base URL before relative references mean anything,
// and there are two ways to give it one:
//
//   - load it by URL with `load_file`, and the URL it came from *is* the base
//   - keep loading from a string, but call `set_home_url` first
//
// This example does the first and shows what the second would look like. The document it loads pulls
// in a stylesheet and an SVG next to it, so a wrong base URL shows up as unstyled text and a missing
// image rather than as an error.
package main

import "../sciter_app"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

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
	if err := sciter_app.load_file(window, url); err != nil {
		fmt.eprintln("could not load the document:", err)
		fmt.eprintln("(run this from the repository root - the path above is resolved against $PWD)")
		os.exit(1)
	}

	// The equivalent when the HTML is a string rather than a file: give the engine the base URL
	// separately, then load the string. Note the trailing slash - a base URL names a directory.
	//
	//	sciter_app.set_home_url(window, file_url("examples/assets/"))
	//	sciter_app.load_html(window, some_html_string)

	sciter_app.show(window)
	sciter_app.run()
	sciter_app.shutdown()
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
