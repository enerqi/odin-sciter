// Shipping the engine inside your executable.
//
// Sciter is dynamic-link-only without a commercial licence: `libsciter.so` / `sciter.dll` /
// `libsciter.dylib` has to exist as a file for the system loader to open. That normally means shipping
// two artifacts - your program and a 25 MB library beside it - even after `archive` has put the whole
// UI inside the executable.
//
// This closes that gap the only way a dynamic-only engine allows: embed the library as data, write it
// out once to a cache directory, and load it from there.
//
//	ENGINE :: #load("../lib/linux/x64/libsciter.so")
//	sciter_app.load_embedded(ENGINE)
//
// What this is not: it is not static linking, and it does not avoid the disk. The file is written
// once per distinct build of the engine and reused afterwards, so the cost is paid on first run only.
// Trade-offs worth knowing before adopting it:
//
//   - the executable grows by the size of the engine, ~25 MB
//   - the first run writes to a cache directory, which needs to be writable and must not be mounted
//     `noexec` - which is why this uses the user's cache directory rather than /tmp, since /tmp is
//     `noexec` on a fair number of hardened systems
//   - on Windows, a freshly written DLL is exactly the pattern anti-malware heuristics look at
//   - the extracted file is a normal file: this hides nothing and protects nothing
//   - the cache path is a pure function of the shipped engine, so it is the same for every user of a
//     given build and predictable to anything else running as this user. The directory is created
//     owner-only and the extracted file is hashed against the embedded bytes before it is reused, so a
//     substituted library is rewritten rather than loaded - but a process running *as this user* can
//     still win a race against any such check, and nothing here changes that.
//
// On licensing: the Sciter EULA's grant is "You may utilize sciter.dll in any manner you see fit
// (subject to the limitations outlined in this license)", and the only limitation it states is the
// About-box attribution. It says nothing about embedding. That is a reading of the text, not legal
// advice - see external/sciter/SCITER-ENGINE-EULA.md, and ask Terra Informatica if it matters
// commercially.
package sciter_app

import sciter ".."
import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Writes an embedded copy of the engine to a cache directory and loads it.
//
// The directory name carries a hash of `blob`, so a different engine build gets a different file
// rather than silently reusing a stale one, and an unchanged one is written exactly once. An existing
// file is reused only if its contents hash to the same value - the name alone is not taken as proof.
// The write goes to a temporary name and is then renamed, so two copies of the program starting at the
// same time cannot see a half-written library.
//
// Returns the path it loaded from, allocated in `allocator`.
load_embedded :: proc(blob: []u8, allocator := context.allocator) -> (path: string, err: Error) {
	if len(blob) == 0 {
		return "", .Not_Loaded
	}

	base := engine_cache_dir(context.temp_allocator) or_return

	// The hash names the *directory*, and the library inside it keeps its canonical name.
	//
	// Naming the file `libsciter-<hash>.so` instead is the obvious thing and does not work: `load`
	// treats any path whose basename is not exactly LIBRARY_NAME as a directory to look inside, so it
	// would go hunting for `libsciter-<hash>.so/libsciter.so`. Keeping the real filename also matters
	// to anything that later inspects the process's loaded modules.
	want := hash.fnv64a(blob)
	dir, joinerr := filepath.join({base, fmt.tprintf("%016x", want)}, context.temp_allocator)
	if joinerr != nil {
		return "", .Not_Loaded
	}
	// Owner-only: this directory holds a library that every later run of the program will `dlopen`, so
	// nobody else should be able to write into it. That is a defence in depth, not the guarantee - the
	// guarantee is the content check below.
	OWNER_ONLY :: os.Permissions{.Read_User, .Write_User, .Execute_User}
	if mkerr := os.make_directory_all(dir, OWNER_ONLY); mkerr != nil && !os.exists(dir) {
		return "", .Not_Loaded
	}

	full, joinerr2 := filepath.join({dir, sciter.LIBRARY_NAME}, allocator)
	if joinerr2 != nil {
		return "", .Not_Loaded
	}

	// Already extracted by an earlier run, and its *contents* hash to the blob we are shipping. The
	// path is a pure function of the build, so it is predictable to anything else running as this
	// user; a size match is not evidence that the bytes about to be `dlopen`ed are ours.
	if !is_file_of_engine(full, blob, want) {
		if werr := write_engine(full, blob, want); werr != nil {
			// `full` came from the caller's allocator and a failed call returns "", so it goes back
			// here - exactly as on the load failure below.
			delete(full, allocator)
			return "", werr
		}
	}

	if lerr, _ := sciter.load(full); lerr != .None && lerr != .Already_Loaded {
		delete(full, allocator)
		return "", .Not_Loaded
	}
	return full, nil
}

// Writes `blob` to `full` via a temporary file in the same directory, then renames it into place.
// Rename is atomic within a filesystem, so a concurrent reader sees either no file or the whole one.
@(private)
write_engine :: proc(full: string, blob: []u8, want: u64) -> Error {
	// The pid keeps two simultaneous first runs from writing to the same temporary.
	temp := fmt.tprintf("%s.%d.tmp", full, os.get_pid())

	// Executable: the loader has to be able to map the file with PROT_EXEC.
	perm := os.Permissions_Read_All + os.Permissions_Execute_All + os.Permissions{.Write_User}
	if werr := os.write_entire_file(temp, blob, perm); werr != nil {
		return .Not_Loaded
	}

	// Some platforms ignore the mode on create; setting it again is cheap and makes the intent plain.
	os.chmod(temp, perm)

	if rerr := os.rename(temp, full); rerr != nil {
		// Losing the race is fine - the other process wrote the identical bytes. Anything else is not.
		os.remove(temp)
		if !is_file_of_engine(full, blob, want) {
			return .Not_Loaded
		}
	}
	return nil
}

// Whether the file at `path` is the engine in `blob`, by content. `want` is `hash.fnv64a(blob)`, passed
// in because the caller has already computed it to name the directory.
//
// The size test first is only a cheap rejection; the hash is what decides. FNV-1a over 25 MB is a few
// milliseconds, once per process start, against the 25 MB write it avoids - and the alternative is
// trusting a file whose path anything running as this user can predict.
@(private)
is_file_of_engine :: proc(path: string, blob: []u8, want: u64) -> bool {
	if !os.exists(path) {
		return false
	}
	info, serr := os.stat(path, context.temp_allocator)
	if serr != nil || info.size != i64(len(blob)) {
		return false
	}
	// Not the temp allocator: 25 MB would sit in the arena until whoever owns it decides otherwise.
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		return false
	}
	defer delete(data)
	return hash.fnv64a(data) == want
}

// Where the extracted engine lives. The user's cache directory rather than the system temp directory:
// temp is routinely mounted `noexec`, cleaned mid-session, or shared between users.
//
// A `<hash>/` directory is created under it, holding one file named exactly LIBRARY_NAME.
//
//	Linux    $XDG_CACHE_HOME/odin-sciter  or  ~/.cache/odin-sciter
//	macOS    ~/Library/Caches/odin-sciter
//	Windows  %LOCALAPPDATA%\odin-sciter
@(private)
engine_cache_dir :: proc(allocator := context.allocator) -> (dir: string, err: Error) {
	APP :: "odin-sciter"

	when ODIN_OS == .Windows {
		if base, ok := os.lookup_env("LOCALAPPDATA", context.temp_allocator); ok && base != "" {
			joined, jerr := filepath.join({base, APP}, allocator)
			if jerr == nil {
				return joined, nil
			}
		}
	} else when ODIN_OS == .Darwin {
		if home, ok := os.lookup_env("HOME", context.temp_allocator); ok && home != "" {
			joined, jerr := filepath.join({home, "Library", "Caches", APP}, allocator)
			if jerr == nil {
				return joined, nil
			}
		}
	} else {
		if base, ok := os.lookup_env("XDG_CACHE_HOME", context.temp_allocator); ok && base != "" {
			joined, jerr := filepath.join({base, APP}, allocator)
			if jerr == nil {
				return joined, nil
			}
		}
		if home, ok := os.lookup_env("HOME", context.temp_allocator); ok && home != "" {
			joined, jerr := filepath.join({home, ".cache", APP}, allocator)
			if jerr == nil {
				return joined, nil
			}
		}
	}

	// No home directory at all - a daemon, or a very bare container. Fall back to the working
	// directory, which at least fails visibly rather than writing somewhere surprising.
	return strings.clone("./" + APP, allocator), nil
}
