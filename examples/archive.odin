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

import sciter ".."
import "../sciter_app"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

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

	fmt.printfln("archive opened: %d bytes embedded, header %q", len(resources), string(resources[:4]))

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

	fmt.printfln("%d resources requested, %d missing from the archive", len(app.requested), app.missing)

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

on_load_data :: proc(handler: ^sciter_app.Host_Handler, request: ^sciter_app.Load_Request) -> sciter_app.Load_Result {
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

// ---------------------------------------------------------------------------------------------------
// Tests
//
//   just test1 archive
//
// All headless: an archive is indexed and read with no window, no display and no message pump, so
// these are the part of the resource path that can be checked anywhere - including on a machine that
// has just been handed a new engine binary and has not opened a window on it yet.
//
// `serve_archive` gets its own tests because its three outcomes are a decision the host makes, not the
// engine: served, refused, or not ours. Getting the third one wrong breaks the engine's own built-ins
// (`sciter:window-frame.js` and friends) in a way that is invisible until a document uses one.

@(private = "file")
engine_loaded :: proc(t: ^testing.T) -> bool {
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}

	// **Not optional on Windows, and the reason is not obvious.** With no host handler installed the
	// engine reports parse errors and script diagnostics through `OutputDebugStringW`, which Windows
	// implements by *raising an exception* (DBG_PRINTEXCEPTION_WIDE_C, 0x4001000A). Odin's test runner
	// installs a handler that treats any exception as fatal to the test, so a CSS warning killed the
	// test that provoked it and every test after it in the file - reported as `Signal caught: Unknown`,
	// which reads like a segfault and is not one. Routing diagnostics to a callback avoids the API
	// entirely. Harmless on Linux, where it just makes the engine's warnings visible.
	sciter_app.set_default_debug_output()
	return true
}

@(test)
test_archive_open_and_read :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	archive, err := sciter_app.open_archive(RESOURCES)
	testing.expect_value(t, err, nil)
	defer sciter_app.close_archive(archive)

	index, found := sciter_app.archive_item(archive, "index.htm")
	testing.expect(t, found, "index.htm should be in the archive")
	testing.expect(t, strings.contains(string(index), "<html"), "index.htm should be HTML")

	// A nested path, because a flat lookup that happens to work on the root would hide a broken one.
	script, script_found := sciter_app.archive_item(archive, "script/app.js")
	testing.expect(t, script_found, "script/app.js should be in the archive")
	testing.expect(t, len(script) > 0)
}

@(test)
test_archive_missing_item :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	archive, err := sciter_app.open_archive(RESOURCES)
	testing.expect_value(t, err, nil)
	defer sciter_app.close_archive(archive)

	_, found := sciter_app.archive_item(archive, "nope.htm")
	testing.expect(t, !found, "a missing path must report not-found, not empty data")

	// A leading slash is the easy mistake: paths are relative to the packed folder.
	_, slashed := sciter_app.archive_item(archive, "/index.htm")
	testing.expect(t, !slashed, "paths are relative to the packed folder, with no leading slash")
}

@(test)
test_archive_open_empty_blob :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	archive, err := sciter_app.open_archive(nil)
	testing.expect_value(t, err, sciter_app.Error(sciter_app.Api_Error.Not_Found))
	testing.expect_value(t, archive, sciter_app.Archive(nil))
}

// The three outcomes of serve_archive, built by hand rather than by loading a document: a Load_Request
// is a URL, a type and the engine's own struct, and the engine only ever reads `outData` back out.
@(private = "file")
fake_request :: proc(uri: string, raw: ^sciter.Scn_Load_Data) -> sciter_app.Load_Request {
	raw^ = {}
	return sciter_app.Load_Request{uri = uri, type = .RAW, raw = raw}
}

@(test)
test_serve_archive_serves_a_matching_url :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	archive, _ := sciter_app.open_archive(RESOURCES)
	defer sciter_app.close_archive(archive)

	raw: sciter.Scn_Load_Data
	request := fake_request(sciter_app.ARCHIVE_URL_PREFIX + "index.htm", &raw)

	result, handled := sciter_app.serve_archive(&request, archive)
	testing.expect(t, handled)
	testing.expect_value(t, result, sciter_app.Load_Result.OK)

	// `.OK` alone means "engine, load it yourself" - the data pointer is what makes it an answer.
	testing.expect(t, raw.outData != nil, "a served request must carry the data")
	testing.expect(t, raw.outDataSize > 0)
}

@(test)
test_serve_archive_discards_a_missing_url :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	archive, _ := sciter_app.open_archive(RESOURCES)
	defer sciter_app.close_archive(archive)

	raw: sciter.Scn_Load_Data
	request := fake_request(sciter_app.ARCHIVE_URL_PREFIX + "typo.css", &raw)

	result, handled := sciter_app.serve_archive(&request, archive)
	testing.expect(t, handled, "a URL under our prefix is ours even when it is missing")
	testing.expect_value(t, result, sciter_app.Load_Result.DISCARD)
	testing.expect(t, raw.outData == nil)
}

@(test)
test_serve_archive_ignores_other_urls :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	archive, _ := sciter_app.open_archive(RESOURCES)
	defer sciter_app.close_archive(archive)

	// The engine asks for its own built-ins through the same callback. Claiming them breaks them.
	for uri in ([]string{"sciter:window-frame.js", "file:///tmp/x.css", "https://example.com/a.png"}) {
		raw: sciter.Scn_Load_Data
		request := fake_request(uri, &raw)

		result, handled := sciter_app.serve_archive(&request, archive)
		testing.expect(t, !handled, uri)
		testing.expect_value(t, result, sciter_app.Load_Result.OK)
		testing.expect(t, raw.outData == nil)
	}
}

// **An item's bytes are engine memory, not a view into the blob you passed in** - which is the first
// thing to know about their lifetime, because "it lives as long as my blob does" is the natural guess
// and it is wrong. Measured on 6.0.4.9: the pointer lands nowhere near `RESOURCES`, and its length is
// the file's real length (975 bytes for `index.htm`), so the engine is handing back its own decoded
// copy rather than a slice of what it was given.
//
// Two more things measured with a probe rather than asserted here, because a test that reads the memory
// after its owner is gone is a use-after-free whether or not it happens to work, and `just
// test_sanitize` exists to catch exactly that:
//
//   - after `close_archive` the bytes still read correctly, through 12 MB of heap churn and 200 further
//     open/read/close cycles. Closing does not appear to free them on this build.
//   - and it does not leak either: those 200 cycles cost 8 kB of RSS.
//
// Neither is a promise. The rule stays what the doc comment says - copy anything that has to outlive the
// archive - because both of those are observations of one engine build, and the second one is the sort
// of thing an upstream release note would never mention.
@(test)
test_an_archive_item_is_engine_memory_rather_than_a_view_of_your_blob :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	blob := RESOURCES
	archive, err := sciter_app.open_archive(blob)
	testing.expect_value(t, err, nil)
	defer sciter_app.close_archive(archive)

	index, found := sciter_app.archive_item(archive, "index.htm")
	testing.expect(t, found)
	testing.expect(t, len(index) > 0)

	start := uintptr(raw_data(blob))
	end := start + uintptr(len(blob))
	at := uintptr(raw_data(index))
	testing.expect(
		t,
		at < start || at >= end,
		"the item points into engine memory, so the blob's lifetime is not the item's",
	)

	// And the length is the file's own, not the blob's - a slice that ran to the end of the archive
	// would read past every other entry and still pass a `contains` test.
	testing.expect(t, len(index) < len(blob), "an item is smaller than the archive that holds it")
}
