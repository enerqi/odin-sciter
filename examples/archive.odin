// Shipping the whole UI inside the executable.
//
//   just example archive
//   just pack                 # regenerate assets/app.pak from assets/app/ (needs SCITER_SDK)
//
// `custom_loader` served resources from a `map[string][]u8` written out by hand. That does not scale
// past a few files: a real application has dozens, in nested folders, and wants them compressed.
//
// Sciter's answer is an archive. The SDK's `packfolder` tool compresses a directory tree into one
// blob, the engine indexes it, and `SciterGetArchiveItem` looks files up by their path within it. Here
// the blob is `examples/assets/app.pak`, 2 KB covering four files including a nested one.
//
// Three pieces make this work, and the middle one is the surprise:
//
//  1. `#load` embeds the blob at compile time. Odin needs no code generator for this - `packfolder`
//     can emit C, C#, D and Go source, but for Odin a plain `-binary` blob plus `#load` is simpler,
//     keeps a hex dump out of version control, and puts the data in the executable's read-only
//     section, which conveniently satisfies (2).
//
//  2. `SciterOpenArchive` indexes the blob **in place and does not copy it**, so the bytes have to
//     outlive the archive. `#load` data lives as long as the process, so there is nothing to manage.
//
//  3. `this://app/...` is **not an engine feature**. The engine has never heard of it. It is a
//     convention that the host implements in its `SC_LOAD_DATA` callback - the SDK's C++ reference
//     host does exactly this in `sciter-x-host-callback.h`, matching `this://app/*` and looking the
//     rest up in the archive. So this example is `custom_loader` with an archive behind it, and the
//     documents inside the archive are portable to any other Sciter host that follows the same
//     convention.
//
// Delete `examples/assets/app/` after building and this still runs: nothing is read from disk.
package main

import "../sciter_app"
import "core:fmt"
import "core:os"
import "core:strings"

// The archive, embedded at compile time. Relative to *this source file*, not to the working directory.
RESOURCES :: #load("assets/app.pak")

// Where the document starts. The base URL is what turns `<link href="style.css">` inside index.htm
// into `this://app/style.css`, which is what the engine then asks the host for.
START_URL :: sciter_app.ARCHIVE_URL_PREFIX + "index.htm"

App :: struct {
	handler:   sciter_app.Host_Handler,
	archive:   sciter_app.Archive,
	requested: [dynamic]string,
	missing:   int,
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
	defer {
		for uri in app.requested {delete(uri)}
		delete(app.requested)
	}

	// Open the blob. `#load` gives a constant, so bind it to a slice to pass it around. The bytes
	// live in the executable's read-only data and stay there for the life of the process.
	resources := RESOURCES
	archive, aerr := sciter_app.open_archive(resources)
	if aerr != nil {
		fmt.eprintln("could not open the archive:", aerr)
		os.exit(1)
	}
	defer sciter_app.close_archive(archive)
	app.archive = archive

	fmt.printfln(
		"archive opened: %d bytes embedded, header %q",
		len(resources),
		string(resources[:4]),
	)

	// Lookup works straight away, before any window exists - the archive is just an index.
	if index, found := sciter_app.archive_item(archive, "index.htm"); found {
		fmt.printfln("index.htm is %d bytes inside the archive", len(index))
	}

	window, werr := sciter_app.create_window({width = 760, height = 620})
	if werr != nil {
		fmt.eprintln("could not create a window:", werr)
		os.exit(1)
	}

	// Before the load: the document itself arrives through this callback too.
	app.handler = sciter_app.Host_Handler {
		on_load_data = on_load_data,
		user_data    = &app,
	}
	sciter_app.set_host_handler(window, &app.handler)

	// Loading by URL rather than by string, so the engine resolves the document's own relative
	// references against `this://app/` without being told a base URL separately.
	if err := sciter_app.load_file(window, START_URL); err != nil {
		fmt.eprintln("could not load", START_URL, "-", err)
		os.exit(1)
	}

	fmt.printfln(
		"%d resources requested, %d missing from the archive",
		len(app.requested),
		app.missing,
	)

	// Report the list back into the document - which is itself a file out of the archive.
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

	// One call does the whole job: match the prefix, look the path up, fill the request in.
	result, handled := sciter_app.serve_archive(request, app.archive)
	if handled {
		append(&app.requested, strings.clone(request.uri))
		if result == .DISCARD {
			app.missing += 1
			fmt.eprintfln("  MISSING from archive: %s", request.uri)
		} else {
			fmt.printfln("  %-8v %s", request.type, request.uri)
		}
		return result
	}

	// Not ours - the engine's own built-ins come through here too, and have to be left alone.
	return .OK
}
