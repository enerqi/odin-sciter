// Spike: prove the Sciter C ABI handshake from Odin before any bindings exist.
//
// Sciter exports exactly one symbol, `SciterAPI`, which returns a pointer to a 189-member struct of
// function pointers. Everything else in the engine is reached through that struct. This program loads the
// shared library, calls `SciterAPI`, and reads the first few slots. If the numbers below come out right,
// the calling convention, the struct layout and the string encoding are all correct, and the rest of the
// bindings are mechanical.
//
//   odin run spike/smoke -- lib/linux/x64/libsciter.so
//   SCITER_LIB=/path/to/libsciter.so odin run spike/smoke
//
// Expected output against sciter-js-sdk 6.0.4.9:
//
//   api.version          = 10
//   SciterClassName()    = sciter-view
//   engine version       = 6.0.4.9

package smoke

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:unicode/utf16"

// The leading members of ISciterAPI, in declaration order. Truncating the struct is safe: we only ever
// read fields at the front, and the engine owns the memory. `proc "system"` is Odin's equivalent of Rust's
// `extern "system"` - it maps to __stdcall on 32-bit Windows (which is what Sciter's SCAPI expands to
// there) and to the platform default everywhere else.
//
// SciterProc and SciterProcND are Windows-only, but Sciter keeps the slots on every platform and fills
// them with NULL, so the layout is identical cross-platform and they are just rawptr here.
Sciter_API_Head :: struct {
	version:              u32,
	SciterClassName:      proc "system" () -> [^]u16,
	SciterVersion:        proc "system" (n: u32) -> u32, // component n of the [v0,v1,v2,v3] version vector
	SciterDataReady:      rawptr,
	SciterDataReadyAsync: rawptr,
	SciterProc:           rawptr, // Windows only, NULL elsewhere
	SciterProcND:         rawptr, // Windows only, NULL elsewhere
	SciterLoadFile:       proc "system" (hwnd: rawptr, filename: [^]u16) -> b32,
}

Sciter_API_Ptr :: proc "system" () -> ^Sciter_API_Head

// Sciter's WCHAR is char16_t on every platform, Linux and macOS included - not wchar_t. Decoding as UTF-16
// here is what confirms that; a wchar_t engine would produce interleaved zero bytes and garbage.
utf16_to_string :: proc(p: [^]u16, buf: []u8) -> string {
	n := 0
	for p[n] != 0 {n += 1}
	return string(buf[:utf16.decode_to_utf8(buf, p[:n])])
}

main :: proc() {
	path := "libsciter.so"
	if len(os.args) > 1 {
		path = os.args[1]
	} else if env, ok := os.lookup_env("SCITER_LIB", context.temp_allocator); ok {
		path = env
	}

	lib, loaded := dynlib.load_library(path)
	if !loaded {
		fmt.eprintfln("could not load %q: %s", path, dynlib.last_error())
		os.exit(1)
	}

	sym, found := dynlib.symbol_address(lib, "SciterAPI")
	if !found {
		fmt.eprintfln("%q has no SciterAPI symbol - wrong library?", path)
		os.exit(1)
	}

	api := (cast(Sciter_API_Ptr)sym)()

	buf: [256]u8

	fmt.printfln("library              = %s", path)
	fmt.printfln("ISciterAPI ptr       = %p", api)
	fmt.printfln("api.version          = %d (SCITER_API_VERSION, expect 10)", api.version)
	fmt.printfln("SciterClassName()    = %s", utf16_to_string(api.SciterClassName(), buf[:]))
	fmt.printfln(
		"engine version       = %d.%d.%d.%d",
		api.SciterVersion(0),
		api.SciterVersion(1),
		api.SciterVersion(2),
		api.SciterVersion(3),
	)
}
