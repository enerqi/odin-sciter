// Prints the ISciterAPI function table slot by slot, resolving each pointer back to a symbol name with
// the dynamic linker. This is the tool that verifies the generated bindings actually line up with the
// shipped engine.
//
//   just run api_map
//
// Expected output, one line per slot:
//
//   001 off=0008 SciterClassName        -> SciterClassNameImp
//   002 off=0016 SciterVersion          -> SciterVersionImp
//   ...
//   189 off=1512 SciterRequestPaint     -> SciterRequestPaintImp
//
// Every non-null slot's symbol should be its field name plus the engine's `Imp` suffix. A slot that
// resolves to an unrelated name means the struct in sciter.odin does not match the loaded library:
// field offsets have drifted and calls are landing in the wrong function. That is exactly what a
// stale header/binary pairing looks like, and it is otherwise invisible until something segfaults
// deep inside the engine.
//
// The `<null>` entries are expected: Sciter keeps the same slots on every platform and fills the ones
// it cannot implement there with NULL (SciterProc and SciterProcND are Windows-only, SciterCreateNSView
// is macOS-only, the three DirectX entries are Windows-only), plus four `reserved` slots left over from
// the removed script-VM API.
package main

import sciter ".."
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strings"

foreign import dl "system:dl"

Dl_Info :: struct {
	dli_fname: cstring,
	dli_fbase: rawptr,
	dli_sname: cstring,
	dli_saddr: rawptr,
}

foreign dl {
	dladdr :: proc "c" (addr: rawptr, info: ^Dl_Info) -> i32 ---
}

main :: proc() {
	err, tried := sciter.load()
	if err != .None {
		fmt.eprintln("could not load the Sciter engine:", err)
		for candidate in tried {
			fmt.eprintfln("  tried %s", candidate)
		}
		os.exit(1)
	}
	api := sciter.api()

	fmt.printfln(
		"Sciter %d.%d.%d.%d, ISciterAPI version %d\n",
		api.SciterVersion(0),
		api.SciterVersion(1),
		api.SciterVersion(2),
		api.SciterVersion(3),
		api.version,
	)

	base := uintptr(api)
	null_slots := 0

	for f, i in reflect.struct_fields_zipped(sciter.Isciter_Api) {
		if f.name == "version" {
			continue
		}
		slot := (^rawptr)(base + f.offset)^
		if slot == nil {
			null_slots += 1
			fmt.printfln("%3d off=%4d %-34s -> <null>", i, f.offset, f.name)
			continue
		}

		info: Dl_Info
		name := "<unnamed>"
		if dladdr(slot, &info) != 0 && info.dli_sname != nil {
			name = string(info.dli_sname)
		}
		if len(name) > 90 {
			name = strings.concatenate({name[:87], "..."}, context.temp_allocator)
		}
		fmt.printfln("%3d off=%4d %-34s -> %s", i, f.offset, f.name, name)
	}

	fmt.printfln(
		"\n%d slots, %d null (platform-padded)",
		reflect.struct_field_count(sciter.Isciter_Api) - 1,
		null_slots,
	)
}
