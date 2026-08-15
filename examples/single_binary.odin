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
// The engine is vendored for Linux x64, Windows x64 and macOS (universal) in this repository, so this
// example compiles on all three.
package main

import sciter ".."
import "../sciter_app"
import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:testing"

// The engine itself. ~25 MB on Linux, ~18 MB on Windows, ~48 MB on macOS, straight into the
// executable's read-only data.
//
// One `when` per vendored binary, and the `else` is a compile-time error rather than a runtime one on
// purpose: an executable that embeds nothing is not a smaller version of this example, it is a broken
// one, and the failure belongs at the build rather than in front of a user.
//
// **macOS embeds both architectures, and that is not a mistake.** `lib/macosx/libsciter.dylib` is a
// universal binary, so an arm64 build of this example carries the x86_64 slice it will never use -
// ~24 MB of dead weight. Embedding one slice would mean splitting the vendored file with `lipo`, which
// means a second artifact and a second hash to pin, and the extracted copy would then be thinner than
// the thing `just fetch-engine --check` verified. Whole file, one pin; `lipo -thin` in your own build
// is the answer if the size matters to you.
when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	ENGINE :: #load("../lib/linux/x64/libsciter.so")
} else when ODIN_OS == .Windows && ODIN_ARCH == .amd64 {
	ENGINE :: #load("../lib/windows/x64/sciter.dll")
} else when ODIN_OS == .Darwin && (ODIN_ARCH == .arm64 || ODIN_ARCH == .amd64) {
	ENGINE :: #load("../lib/macosx/libsciter.dylib")
} else {
	#panic(
		"single_binary embeds the engine, and only lib/linux/x64/libsciter.so, " +
		"lib/windows/x64/sciter.dll and lib/macosx/libsciter.dylib are vendored here - " +
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

on_load_data :: proc(handler: ^sciter_app.Host_Handler, request: ^sciter_app.Load_Request) -> sciter_app.Load_Result {
	app := (^App)(handler.user_data)
	if result, handled := sciter_app.serve_archive(request, app.archive); handled {
		return result
	}
	return .OK
}

// ---------------------------------------------------------------------------------------------------
// Tests
//
//   odin test examples/single_binary.odin -file -define:ODIN_TEST_THREADS=1
//
// `load_embedded` is a cache with three rules, and each of them is invisible when it works:
//
//   - the directory is named by a hash of the blob, so a new engine build gets a new directory and an
//     unchanged one gets the same directory back
//   - a blob already extracted is not written again
//   - the write goes to a temporary and is renamed into place, so a reader never sees a partial file
//
// The first test loads the real embedded engine, which is the whole example end to end. Everything
// after it uses small synthetic blobs instead of writing 25 MB per case: with the engine already
// loaded, `sciter.load` inside `load_embedded` short-circuits to `.Already_Loaded`, so the extraction
// runs and the load is a no-op. That is also why every one of them starts with `engine_loaded` - out
// of order, a synthetic blob would be handed to the system loader as a library.
//
// They write into the same cache directory the engine was extracted to, under their own hashes, and
// remove what they wrote.

@(private = "file")
g_engine_path: string

@(private = "file")
engine_loaded :: proc(t: ^testing.T) -> bool {
	if sciter.loaded() {
		return true
	}

	// The engine is kept for the life of the process, so the path it was loaded from is allocated
	// outside the test runner's tracking allocator - otherwise every later test reports it as a leak.
	context.allocator = runtime.default_allocator()

	path, err := sciter_app.load_embedded(ENGINE)
	testing.expect_value(t, err, nil)
	if err != nil {
		// A cache directory that is missing, read-only or mounted noexec, which is the one failure
		// this example cannot work around.
		testing.fail_now(t, "the embedded engine could not be extracted and loaded")
	}
	g_engine_path = path
	return true
}

// The directory the engine was extracted into - `<cache>/odin-sciter`, whatever that is on this
// platform. Derived from where the engine actually landed rather than rebuilt from the environment,
// so these tests do not have their own copy of the platform rules.
@(private = "file")
cache_dir :: proc() -> string {
	// `filepath.dir` is `os.dir`, which **slices rather than allocates** - the result points into
	// `g_engine_path`, which outlives every test here. So there is nothing to free, nothing for the
	// runner's leak tracker to see, and no allocator to pin. The comment that used to sit here said the
	// opposite and switched `context.allocator` to guard against a leak that could not happen;
	// `sqlite_extension.odin` acted on the same wrong belief and paired it with a `delete`, which
	// aborted the process on macOS.
	return filepath.dir(filepath.dir(g_engine_path))
}

@(private = "file")
hash_name :: proc(blob: []u8) -> string {
	return fmt.tprintf("%016x", hash.fnv64a(blob))
}

@(private = "file")
blob_dir :: proc(blob: []u8) -> string {
	dir, err := filepath.join({cache_dir(), hash_name(blob)}, context.temp_allocator)
	return "" if err != nil else dir
}

@(private = "file")
blob_path :: proc(blob: []u8) -> string {
	full, err := filepath.join({blob_dir(blob), sciter.LIBRARY_NAME}, context.temp_allocator)
	return "" if err != nil else full
}

// Removes everything a synthetic blob left in the cache.
@(private = "file")
scrub :: proc(blob: []u8) {
	dir := blob_dir(blob)
	if entries, err := os.read_all_directory_by_path(dir, context.temp_allocator); err == nil {
		for entry in entries {
			os.remove(entry.fullpath)
		}
	}
	os.remove(dir)
}

// The example itself, as a test: the engine comes out of the executable, is written to the cache and
// is loaded from there.
@(test)
test_the_embedded_engine_is_extracted_and_loaded :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	testing.expect(t, sciter.loaded(), "the engine must be loaded from the extracted copy")

	v := sciter_app.version()
	testing.expect(t, v[0] != 0 || v[1] != 0, "a loaded engine reports a version")

	// The hash names the directory; the library keeps its canonical name inside it. `sciter.load`
	// treats a path whose basename is not LIBRARY_NAME as a directory to look inside, so naming the
	// file `libsciter-<hash>.so` would send it hunting for `libsciter-<hash>.so/libsciter.so`.
	testing.expect_value(t, filepath.base(g_engine_path), sciter.LIBRARY_NAME)
	testing.expect_value(t, g_engine_path, blob_path(ENGINE))

	// And what is on disk is the whole blob. A short read here would mean the rename let a partial
	// file be loaded, which is the failure the temporary-plus-rename exists to prevent.
	written, err := os.read_entire_file(g_engine_path, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(written), len(ENGINE))
	testing.expect(t, slice.equal(written, ENGINE), "the extracted file must be the embedded blob")
}

@(test)
test_an_empty_blob_is_refused :: proc(t: ^testing.T) {
	path, err := sciter_app.load_embedded(nil)
	testing.expect_value(t, err, sciter_app.Error(sciter_app.Api_Error.Not_Loaded))
	testing.expect_value(t, path, "")
}

// The point of hashing: two engine builds cannot collide, and the same build always comes back to the
// same file rather than being extracted again under a new name.
@(test)
test_the_directory_is_named_by_the_hash :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	one := transmute([]u8)string("odin-sciter test blob: hash naming, one")
	two := transmute([]u8)string("odin-sciter test blob: hash naming, two")
	defer scrub(one)
	defer scrub(two)

	first, err := sciter_app.load_embedded(one)
	testing.expect_value(t, err, nil)
	defer delete(first)
	testing.expect_value(t, first, blob_path(one))

	second, serr := sciter_app.load_embedded(two)
	testing.expect_value(t, serr, nil)
	defer delete(second)
	testing.expect_value(t, second, blob_path(two))

	testing.expect(t, first != second, "a different blob must not reuse the same file")
	testing.expect_value(t, filepath.base(first), sciter.LIBRARY_NAME)

	// The same blob a second time is the same path, which is what makes the cache a cache.
	again, aerr := sciter_app.load_embedded(one)
	testing.expect_value(t, aerr, nil)
	defer delete(again)
	testing.expect_value(t, again, first)
}

// **`os.stat(...).inode` is 0 for every file on Windows**, so an inode comparison there is not a weak
// test, it is a vacuous one: `0 != 0` never holds and `0 == 0` always does. Measured, not assumed.
// Where the file identity is real it is the sharpest available signal for "this file was replaced
// rather than written over", so the assertions below keep it and gate it, rather than dropping to
// timestamps everywhere for the sake of one platform.
//
// What is *not* platform-specific, and was the open question on this file before a Windows machine
// existed: `os.rename` over an existing destination succeeds here. POSIX `rename(2)` replaces silently,
// Win32 `MoveFile` refuses - but Odin's `core:os` uses the replacing variant, so `write_engine`'s
// rename-into-place works identically on both. The content assertions below are what prove it, and they
// run everywhere.
@(private = "file")
INODE_IS_MEANINGFUL :: ODIN_OS != .Windows

// Write-once. The file is replaced by a rename, so a second write would show up as a new inode even
// though the bytes are identical - which is a sharper test than comparing timestamps.
@(test)
test_an_already_extracted_blob_is_not_written_again :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	blob := transmute([]u8)string("odin-sciter test blob: written exactly once")
	defer scrub(blob)

	first, err := sciter_app.load_embedded(blob)
	testing.expect_value(t, err, nil)
	defer delete(first)

	before, serr := os.stat(first, context.temp_allocator)
	testing.expect_value(t, serr, nil)

	second, err2 := sciter_app.load_embedded(blob)
	testing.expect_value(t, err2, nil)
	defer delete(second)
	testing.expect_value(t, second, first)

	after, serr2 := os.stat(second, context.temp_allocator)
	testing.expect_value(t, serr2, nil)
	when INODE_IS_MEANINGFUL {
		testing.expect_value(t, after.inode, before.inode)
	}
	testing.expect_value(t, after.modification_time, before.modification_time)
}

// The cache is keyed on the hash, and reuse is decided by hashing what is on disk. A file that is
// there but the wrong length - a run killed mid-write by something that did not go through the rename,
// a truncated copy - is rejected by the cheap size test before the hash is reached.
@(test)
test_a_file_of_the_wrong_size_is_replaced :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	blob := transmute([]u8)string("odin-sciter test blob: replaced when truncated")
	defer scrub(blob)

	first, err := sciter_app.load_embedded(blob)
	testing.expect_value(t, err, nil)
	defer delete(first)

	original, serr := os.stat(first, context.temp_allocator)
	testing.expect_value(t, serr, nil)

	testing.expect_value(t, os.write_entire_file(first, blob[:4]), nil)

	second, err2 := sciter_app.load_embedded(blob)
	testing.expect_value(t, err2, nil)
	defer delete(second)
	testing.expect_value(t, second, first)

	after, serr2 := os.stat(second, context.temp_allocator)
	testing.expect_value(t, serr2, nil)
	testing.expect_value(t, after.size, i64(len(blob)))
	when INODE_IS_MEANINGFUL {
		testing.expect(t, after.inode != original.inode, "a replacement is a rename, not an overwrite")
	} else {
		_ = original // still stat'ed above, to prove the file was there before the replacement
	}

	written, rerr := os.read_entire_file(second, context.temp_allocator)
	testing.expect_value(t, rerr, nil)
	testing.expect(t, slice.equal(written, blob))
}

// The one the size test cannot catch, and the reason reuse hashes the file rather than measuring it:
// the cache path is a pure function of the shipped engine, so it is the same for every user of a given
// build and predictable to anything else running as this user. Substituted bytes of the right length
// must be rewritten, not `dlopen`ed.
@(test)
test_a_file_of_the_right_size_but_the_wrong_content_is_replaced :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	blob := transmute([]u8)string("odin-sciter test blob: replaced when substituted")
	defer scrub(blob)

	first, err := sciter_app.load_embedded(blob)
	testing.expect_value(t, err, nil)
	defer delete(first)

	original, serr := os.stat(first, context.temp_allocator)
	testing.expect_value(t, serr, nil)

	// Same length, different bytes - exactly what a size check calls "already extracted".
	impostor := make([]u8, len(blob), context.temp_allocator)
	for &b in impostor {
		b = 'x'
	}
	testing.expect_value(t, os.write_entire_file(first, impostor), nil)

	second, err2 := sciter_app.load_embedded(blob)
	testing.expect_value(t, err2, nil)
	defer delete(second)
	testing.expect_value(t, second, first)

	after, serr2 := os.stat(second, context.temp_allocator)
	testing.expect_value(t, serr2, nil)
	when INODE_IS_MEANINGFUL {
		testing.expect(t, after.inode != original.inode, "a replacement is a rename, not an overwrite")
	} else {
		_, _ = original, after // both still stat'ed above, and both checked for an error
	}

	written, rerr := os.read_entire_file(second, context.temp_allocator)
	testing.expect_value(t, rerr, nil)
	testing.expect(t, slice.equal(written, blob), "the substituted bytes must not survive")
}

// The temporary is an implementation detail and has to stay one: a `.tmp` left in the cache directory
// would be found by the next run, and by anything else that looks in there.
@(test)
test_no_temporary_is_left_behind :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	blob := transmute([]u8)string("odin-sciter test blob: no leftovers")
	defer scrub(blob)

	path, err := sciter_app.load_embedded(blob)
	testing.expect_value(t, err, nil)
	defer delete(path)

	entries, derr := os.read_all_directory_by_path(blob_dir(blob), context.temp_allocator)
	testing.expect_value(t, derr, nil)
	testing.expect_value(t, len(entries), 1)
	if len(entries) == 1 {
		testing.expect_value(t, entries[0].name, sciter.LIBRARY_NAME)
	}
}

// Losing the rename race to another process is fine - it wrote the identical bytes, and the size check
// says so. A rename that fails for any other reason is not, and has to be reported rather than
// leaving the caller with a path to a library that is not there.
//
// A directory sitting where the library should go is the reachable version of that: the temporary is
// written, the rename cannot possibly succeed, and the size check finds no file of the right length.
// The genuine two-process race is not reproducible in one process, which is why this stands in for it.
@(test)
test_a_rename_that_cannot_succeed_is_reported :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	blob := transmute([]u8)string("odin-sciter test blob: blocked rename")
	defer scrub(blob)

	testing.expect_value(t, os.make_directory_all(blob_path(blob)), nil)

	path, err := sciter_app.load_embedded(blob)
	testing.expect_value(t, err, sciter_app.Error(sciter_app.Api_Error.Not_Loaded))
	testing.expect_value(t, path, "")

	// And the temporary it wrote on the way is gone - only the directory that is in the way is left.
	entries, derr := os.read_all_directory_by_path(blob_dir(blob), context.temp_allocator)
	testing.expect_value(t, derr, nil)
	testing.expect_value(t, len(entries), 1)
}
