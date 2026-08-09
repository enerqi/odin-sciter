// Serving a document's resources from memory instead of from disk.
//
//   just example custom_loader
//
// Every resource a document refers to - stylesheet, image, script, font - goes past the host first, as
// an `SC_LOAD_DATA` notification. Answering it is how an application ships its UI *inside* the
// executable, and it is the same hook the `archive` approach and any custom URL scheme are built on.
//
// This example invents a scheme, `res://app/`, that the engine has no idea how to fetch, and answers
// every request for it out of a map compiled into the binary. Nothing is read from disk: delete
// `examples/assets/` and this still runs.
//
// Two things worth knowing:
//
//   - install the handler BEFORE loading the document. The document's own load goes through the same
//     callback, and so do the stylesheets it pulls in.
//   - `.OK` with no data means "engine, load it yourself". `.OK` *with* data means "here it is". They
//     are the same return code, distinguished only by whether the request was filled in - which is why
//     `serve` exists rather than a bare return.
package main

import "../sciter_app"
import "core:fmt"
import "core:os"
import "core:strings"

// The whole UI, compiled in. The base URL passed to `load_html` is what makes the relative references
// below resolve to `res://app/...`, which is what the engine then asks the host for.
BASE_URL :: "res://app/"

INDEX :: `<html>
<head>
  <title>odin-sciter: custom_loader</title>
  <link rel="stylesheet" href="style.css" />
</head>
<body>
  <h1>custom_loader</h1>
  <p>
    This document, its stylesheet and the image below were all served from a
    <code>map[string][]u8</code> inside the executable. The engine asked; Odin answered.
  </p>
  <img src="logo.svg" />
  <p class="muted">Every URL the engine requested is listed on stdout.</p>
  <div id="served"></div>
</body>
</html>`

STYLE :: `
html { background: #1e1e2e; color: #cdd6f4; font: 16px system; }
body { padding: 2em; margin: 0; }
h1   { color: #89b4fa; margin-top: 0; }
code { background: #313244; padding: 0 .3em; border-radius: 3px; }
img  { width: 96px; height: 96px; }
.muted { color: #6c7086; font-size: 14px; }
#served { background: #313244; padding: 1em; border-radius: 4px; font: 13px monospace;
          white-space: pre-wrap; margin-top: 1em; }
`

LOGO :: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">
  <rect x="4" y="4" width="56" height="56" rx="10" fill="#89b4fa"/>
  <path d="M20 40 L32 18 L44 40 Z" fill="#1e1e2e"/>
</svg>`

App :: struct {
	handler:  sciter_app.Host_Handler,
	resources: map[string][]u8,
	requested: [dynamic]string,
	misses:    int,
}

main :: proc() {
	if !sciter_app.load_engine() {
		os.exit(1)
	}
	sciter_app.set_default_debug_output()

	if err := sciter_app.init(); err != nil {
		fmt.eprintln("init failed:", err)
		os.exit(1)
	}

	app: App
	app.resources["res://app/style.css"] = transmute([]u8)string(STYLE)
	app.resources["res://app/logo.svg"] = transmute([]u8)string(LOGO)
	defer {
		delete(app.resources)
		for uri in app.requested {delete(uri)}
		delete(app.requested)
	}

	window, werr := sciter_app.create_window({width = 720, height = 560})
	if werr != nil {
		fmt.eprintln("could not create a window:", werr)
		os.exit(1)
	}

	// Before the load, not after.
	app.handler = sciter_app.Host_Handler {
		on_load_data = on_load_data,
		user_data    = &app,
	}
	sciter_app.set_host_handler(window, &app.handler)

	if err := sciter_app.load_html(window, INDEX, BASE_URL); err != nil {
		fmt.eprintln("could not load the document:", err)
		os.exit(1)
	}

	fmt.printfln(
		"%d resources requested, %d served from memory, %d passed through to the engine",
		len(app.requested),
		len(app.requested) - app.misses,
		app.misses,
	)

	// Report back into the document, so the window shows what happened too.
	if root, err := sciter_app.root(window); err == nil {
		if box, serr := sciter_app.select_first(root, "#served"); serr == nil {
			sciter_app.set_text(box, strings.join(app.requested[:], "\n", context.temp_allocator))
		}
	}

	sciter_app.show(window)
	sciter_app.run()
	sciter_app.shutdown()
}

on_load_data :: proc(
	handler: ^sciter_app.Host_Handler,
	request: ^sciter_app.Load_Request,
) -> sciter_app.Load_Result {
	app := (^App)(handler.user_data)

	// `request.uri` lives in the temp allocator and is gone after this returns, so the log keeps a copy.
	append(&app.requested, strings.clone(request.uri))
	fmt.printfln("  %-24v %s", request.type, request.uri)

	if data, found := app.resources[request.uri]; found {
		return sciter_app.serve(request, data)
	}

	// Not ours: pass it through. `.OK` without data tells the engine to load it the ordinary way.
	//
	// There is always at least one of these, and it is not a mistake - the engine asks for its own
	// built-ins through the same callback (`sciter:window-frame.js` is the window chrome), and those
	// have to be left alone. A host that answered .DISCARD to everything it did not recognise would
	// break the engine's own resources along with the unknown ones.
	app.misses += 1
	return .OK
}
