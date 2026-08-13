// Sciter's compressed archives - the whole UI as one blob.
//
// The SDK's `packfolder` tool turns a directory tree into a single compressed file. The engine can
// index that blob and hand back the files inside it by path, which is how a Sciter application ships
// its HTML, CSS, scripts and images inside the executable rather than beside it.
//
// The archive is only half of it. Opening one gives you lookup by path; it does *not* teach the engine
// any new URL scheme. Serving `this://app/index.htm` out of an archive is a convention the **host**
// implements, in the same `SC_LOAD_DATA` callback as any other custom loading - see `serve_archive`
// below, and `examples/archive.odin` for the whole arrangement.
package sciter_app

import sciter ".."
import "core:strings"

// An opened archive. Sciter's HSARCHIVE.
Archive :: distinct sciter.Archive

// Opens an archive blob produced by `packfolder <folder> <out> -binary`.
//
// **The engine indexes the blob in place and does not copy it**, so `blob` has to stay valid, and
// unmoved, until `close_archive`. Data from Odin's `#load` is ideal: it lives in the executable's
// read-only data for the life of the process, so there is no lifetime question at all.
//
//	RESOURCES :: #load("assets/app.pak")
//	archive, err := sciter_app.open_archive(RESOURCES)
open_archive :: proc(blob: []u8) -> (archive: Archive, err: Error) {
	if len(blob) == 0 {
		return nil, .Not_Found
	}
	h := sciter.api().SciterOpenArchive(raw_data(blob), u32(len(blob)))
	if h == nil {
		return nil, .Archive_Failed
	}
	return Archive(h), nil
}

// `.Archive_Failed` if the engine refuses. `Load_Failed` used to stand in here, which sent anyone
// reading a log off to look at their HTML.
close_archive :: proc(archive: Archive) -> Error {
	if archive == nil {
		return nil
	}
	ok := sciter.api().SciterCloseArchive(sciter.Archive(archive))
	return nil if ok else Api_Error.Archive_Failed
}

// Looks a file up inside the archive by its path within the packed folder - "index.htm",
// "script/app.js". No leading slash.
//
// The returned bytes are borrowed from the archive and stay valid until it is closed.
archive_item :: proc(archive: Archive, path: string) -> (data: []u8, found: bool) {
	if archive == nil {
		return nil, false
	}
	w := utf16_from_string(path, context.temp_allocator)

	p: [^]u8
	n: u32
	if !sciter.api().SciterGetArchiveItem(sciter.Archive(archive), raw_data(w), &p, &n) {
		return nil, false
	}
	if p == nil {
		return nil, false
	}
	return p[:n], true
}

// The conventional base URL for an application's own resources. Nothing in the engine enforces it -
// it is what the SDK's C++ host callback uses (`sciter-x-host-callback.h`), so documents written for
// Sciter expect it, and matching it keeps them portable.
ARCHIVE_URL_PREFIX :: "this://app/"

// Answers a load request out of an archive, if its URL is under `prefix`.
//
//	result, handled := sciter_app.serve_archive(request, app.archive)
//	if handled {return result}
//
// `handled` is false when the URL is not ours, which is the signal to fall through - the engine asks
// for its own built-ins through the same callback (`sciter:window-frame.js` and friends), and those
// must be left alone.
//
// A URL that *is* under the prefix but is missing from the archive is answered `.DISCARD` rather than
// passed through: it is a genuine mistake - a typo in a `<link href>` - and letting the engine try to
// fetch `this://app/...` itself would only turn it into a more confusing failure.
serve_archive :: proc(
	request: ^Load_Request,
	archive: Archive,
	prefix := ARCHIVE_URL_PREFIX,
) -> (
	result: Load_Result,
	handled: bool,
) {
	if !strings.has_prefix(request.uri, prefix) {
		// **Read `handled` first: `result` means nothing when it is false.** There is no "no answer"
		// value to return here - `Sc_Load_Data_Return_Codes.OK` is 0, so a zeroed result *is* `.OK` and
		// no spelling of this return can make ignoring `handled` safe. `.OK` is at least the harmless
		// one if it is used anyway: it means "engine, load it yourself", which is what should happen to
		// a URL this archive does not own.
		return .OK, false
	}
	path := request.uri[len(prefix):]

	data, found := archive_item(archive, path)
	if !found {
		return .DISCARD, true
	}
	return serve(request, data), true
}
