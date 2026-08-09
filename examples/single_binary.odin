// One file. No libsciter.so beside it, no assets folder, nothing to install.
//
//   just example single_binary
//
// This is `archive` plus one more step. `archive` put the UI inside the executable but still needed
// the engine as a separate ~25 MB shared library next to it, because Sciter is dynamic-link-only
// without a commercial licence. So the engine goes in too:
//
//   - `#load` embeds both blobs at compile time
//   - `load_embedded` writes the engine out to the user's cache directory, once, and loads it
//   - `open_archive` serves every resource the document asks for from the other blob
//
// The result is a single self-contained executable. Copy it anywhere and run it.
//
// Be clear about what this is not. It is not static linking, and the engine does briefly touch the
// disk - there is no supported way to hand the system loader a library from memory on all three
// platforms. What it buys is a single artifact to ship; see `sciter_app/embed.odin` for the full list
// of trade-offs, including the Windows anti-malware one.
//
// The engine is only vendored for Linux x64 in this repository, so that is the only platform this
// example compiles on today.
package main

import "../sciter_app"
import "core:fmt"
import "core:os"

// The engine itself. ~25 MB, straight into the executable's read-only data.
when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	ENGINE :: #load("../lib/linux/x64/libsciter.so")
} else {
	#panic(
		"single_binary embeds the engine, and only lib/linux/x64/libsciter.so is vendored here - " +
		"see external/sciter/VENDORED.md",
	)
}

// The UI: the same archive the `archive` example uses.
RESOURCES :: #load("assets/app.pak")

START_URL :: sciter_app.ARCHIVE_URL_PREFIX + "index.htm"

App :: struct {
	handler: sciter_app.Host_Handler,
	archive: sciter_app.Archive,
}

main :: proc() {
	engine := ENGINE
	resources := RESOURCES

	// Instead of sciter_app.load_engine(), which searches the filesystem for a library. Nothing is
	// searched for here - the engine came out of this executable.
	path, err := sciter_app.load_embedded(engine)
	if err != nil {
		fmt.eprintln("could not load the embedded engine:", err)
		fmt.eprintln("(the cache directory has to be writable and not mounted noexec)")
		os.exit(1)
	}
	defer delete(path)

	v := sciter_app.version()
	fmt.printfln("engine %d.%d.%d.%d, %d MB embedded", v[0], v[1], v[2], v[3], len(engine) / 1024 / 1024)
	fmt.printfln("extracted to %s", path)

	sciter_app.set_default_debug_output()
	if ierr := sciter_app.init(); ierr != nil {
		fmt.eprintln("init failed:", ierr)
		os.exit(1)
	}

	app: App
	archive, aerr := sciter_app.open_archive(resources)
	if aerr != nil {
		fmt.eprintln("could not open the archive:", aerr)
		os.exit(1)
	}
	defer sciter_app.close_archive(archive)
	app.archive = archive

	window, werr := sciter_app.create_window({width = 760, height = 620})
	if werr != nil {
		fmt.eprintln("could not create a window:", werr)
		os.exit(1)
	}

	app.handler = sciter_app.Host_Handler {
		on_load_data = on_load_data,
		user_data    = &app,
	}
	sciter_app.set_host_handler(window, &app.handler)

	if lerr := sciter_app.load_file(window, START_URL); lerr != nil {
		fmt.eprintln("could not load", START_URL, "-", lerr)
		os.exit(1)
	}

	if root, rerr := sciter_app.root(window); rerr == nil {
		if box, serr := sciter_app.select_first(root, "#served"); serr == nil {
			sciter_app.set_text(
				box,
				fmt.tprintf(
					"engine:    %d bytes, embedded and extracted to\n           %s\nresources: %d bytes, embedded and never written out",
					len(engine),
					path,
					len(resources),
				),
			)
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
	if result, handled := sciter_app.serve_archive(request, app.archive); handled {
		return result
	}
	return .OK
}
