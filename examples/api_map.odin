// Prints the ISciterAPI function table slot by slot, resolving each pointer back to the module and
// symbol it belongs to. This is the tool that verifies the generated bindings actually line up with
// the shipped engine.
//
//   just run api_map
//
// Expected output on Linux, one line per slot:
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
// The `<null>` entries are expected, and **which** ones are null is platform-specific: Sciter keeps the
// same slots everywhere and fills the ones it cannot implement on a platform with NULL. So the null
// list is part of what this tool reports, and it is expected to change across platforms while the
// offsets do not.
//
//   Linux    16 null, measured: SciterProc, SciterProcND, SciterTranslateMessage,
//            SciterGetViewExpando, SciterRenderD2D, SciterD2DFactory, SciterDWFactory,
//            SciterCreateNSView, SciterCreateWidget, reserved1..4, and the three DirectX entries.
//            Note SciterCreateWidget is null here too - Sciter 6 dropped GTK on Linux, so there is no
//            host widget to create.
//   Windows   expected to fill SciterProc, SciterProcND, SciterTranslateMessage and the D2D/DirectX
//            entries, and to leave SciterCreateWidget and SciterCreateNSView null. Not yet verified -
//            record what this prints when it is.
//   macOS     expected to fill SciterCreateNSView. Likewise unverified.
//
// `SciterGetViewExpando` and the four `reserved` slots are null on every platform: leftovers from the
// removed script-VM API. The first of those is why `sciter_app.set_global` evaluates an assignment
// function rather than writing into globalThis directly.
//
// ---------------------------------------------------------------------------------------------------
// How a pointer is resolved back to a name, per platform. This is the only part of the repository that
// is genuinely three implementations of one idea:
//
//   Linux, macOS  `dladdr` reports the nearest exported symbol. libsciter.so exports ~17,000 dynamic
//                 symbols (its vendored QuickJS, libjpeg and Skia internals), so every slot resolves to
//                 its own `...Imp` name and the check is exact.
//
//   Windows       sciter.dll exports exactly one symbol, `SciterAPI` - the `Imp` functions are internal
//                 and have no export entry - so there is usually no name to find without a PDB.
//                 dbghelp is still asked (it resolves them when symbols happen to be available), and
//                 the fallback is what can always be checked: `VirtualQuery` reports which module the
//                 address belongs to, so every slot must land inside sciter.dll at a sane offset.
//                 That catches a table pointing at the wrong module, a partially-filled table and an
//                 offset shift into padding - just not a swap of two neighbouring engine functions.
//
// So on Windows this is a weaker check than on Linux, and it is worth knowing that rather than reading
// a wall of `sciter.dll+0x...` as a failure. Generating the bindings on Linux and verifying there
// remains the authoritative pass; `SCITER_API_VERSION` plus the module/offset check is what the other
// platforms add on top.
package main

import sciter ".."
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strings"

// ---------------------------------------------------------------------------------------------------
// Symbol resolution

when ODIN_OS == .Windows {
	// Declared here rather than imported from core:sys/windows, which has everything needed: an example
	// is built with `odin build -file`, so it is one file, and Odin does not allow `import` inside a
	// `when` - only `foreign import`. Six procedures and two structs is a cheaper price than splitting
	// the examples into multi-file packages for this one case.
	foreign import kernel32 "system:Kernel32.lib"
	foreign import dbghelp "system:Dbghelp.lib"

	@(private = "file")
	SYMBOL_INFOW :: struct {
		SizeOfStruct: u32,
		TypeIndex:    u32,
		Reserved:     [2]u64,
		Index:        u32,
		Size:         u32,
		ModBase:      u64,
		Flags:        u32,
		Value:        u64,
		Address:      u64,
		Register:     u32,
		Scope:        u32,
		Tag:          u32,
		NameLen:      u32,
		MaxNameLen:   u32,
		Name:         [1]u16, // written past its end, see Sym_Buffer
	}

	@(private = "file")
	MEMORY_BASIC_INFORMATION :: struct {
		BaseAddress:       rawptr,
		AllocationBase:    rawptr,
		AllocationProtect: u32,
		PartitionId:       u16,
		RegionSize:        uint,
		State:             u32,
		Protect:           u32,
		Type:              u32,
	}

	SYMOPT_DEFERRED_LOADS :: 0x00000004
	MAX_PATH :: 260

	@(default_calling_convention = "system")
	foreign kernel32 {
		GetCurrentProcess :: proc() -> rawptr ---
		GetModuleFileNameW :: proc(hModule: rawptr, lpFilename: [^]u16, nSize: u32) -> u32 ---
		VirtualQuery :: proc(lpAddress: rawptr, lpBuffer: ^MEMORY_BASIC_INFORMATION, dwLength: uint) -> uint ---
	}

	@(default_calling_convention = "system")
	foreign dbghelp {
		SymSetOptions :: proc(SymOptions: u32) -> u32 ---
		SymInitialize :: proc(hProcess: rawptr, UserSearchPath: cstring, fInvadeProcess: b32) -> b32 ---
		SymFromAddrW :: proc(hProcess: rawptr, Address: u64, Displacement: ^u64, Symbol: ^SYMBOL_INFOW) -> b32 ---
	}

	// dbghelp writes the name into the tail of SYMBOL_INFOW, past its declared [1]WCHAR, so the buffer
	// has to be bigger than the struct. It is an array of u64 to get 8-byte alignment - dbghelp writes
	// ULONG64 fields into it, and a [N]u8 is only byte-aligned.
	MAX_SYM_NAME :: 512

	@(private = "file")
	Sym_Buffer :: [(size_of(SYMBOL_INFOW) + MAX_SYM_NAME * size_of(u16)) / size_of(u64) + 1]u64

	@(private = "file")
	g_symbols_ready: bool

	// Cache of the last module a slot resolved to. Every slot comes from the same DLL, so this is a
	// one-entry cache with a 100% hit rate after the first call.
	@(private = "file")
	g_last_base: rawptr

	@(private = "file")
	g_last_name: string

	symbols_init :: proc() {
		SymSetOptions(SYMOPT_DEFERRED_LOADS)
		g_symbols_ready = bool(SymInitialize(GetCurrentProcess(), nil, true))
		if !g_symbols_ready {
			fmt.eprintln("note: SymInitialize failed; falling back to module+offset only")
		}
	}

	resolve :: proc(slot: rawptr, allocator := context.allocator) -> string {
		if g_symbols_ready {
			buf: Sym_Buffer
			info := (^SYMBOL_INFOW)(&buf[0])
			info.SizeOfStruct = size_of(SYMBOL_INFOW)
			info.MaxNameLen = MAX_SYM_NAME

			displacement: u64
			if SymFromAddrW(GetCurrentProcess(), u64(uintptr(slot)), &displacement, info) {
				name := wide_to_string(([^]u16)(&info.Name[0])[:info.NameLen], allocator)
				if name != "" {
					if displacement == 0 {
						return name
					}
					// A non-zero displacement means the nearest known symbol is some distance back,
					// which for an unexported function is the norm rather than a match.
					defer delete(name, allocator)
					return fmt.aprintf("%s+0x%x", name, displacement, allocator = allocator)
				}
			}
		}
		return module_of(slot, allocator)
	}

	// Which loaded module the address belongs to, plus its offset within it.
	@(private = "file")
	module_of :: proc(slot: rawptr, allocator := context.allocator) -> string {
		mbi: MEMORY_BASIC_INFORMATION
		if VirtualQuery(slot, &mbi, size_of(mbi)) == 0 || mbi.AllocationBase == nil {
			return strings.clone("<unmapped>", allocator)
		}

		if mbi.AllocationBase != g_last_base {
			g_last_base = mbi.AllocationBase
			delete(g_last_name)

			path: [MAX_PATH]u16
			n := GetModuleFileNameW(mbi.AllocationBase, &path[0], len(path))
			if n == 0 {
				g_last_name = strings.clone("<unknown module>")
			} else {
				full := wide_to_string(path[:n])
				defer delete(full)
				// Basename only: the full path is the same on every line and swamps the output.
				slash := strings.last_index_any(full, "\\/")
				g_last_name = strings.clone(full[slash + 1:])
			}
		}

		return fmt.aprintf("%s+0x%x", g_last_name, uintptr(slot) - uintptr(mbi.AllocationBase), allocator = allocator)
	}

	@(private = "file")
	wide_to_string :: proc(units: []u16, allocator := context.allocator) -> string {
		if len(units) == 0 {
			return ""
		}
		buf := make([]u8, len(units) * 3, allocator)
		return string(buf[:utf16.decode_to_utf8(buf, units)])
	}
} else {
	// dladdr lives in libdl on Linux and in libSystem on macOS, which is always linked.
	when ODIN_OS == .Darwin {
		foreign import dl "system:System"
	} else {
		foreign import dl "system:dl"
	}

	@(private = "file")
	Dl_Info :: struct {
		dli_fname: cstring,
		dli_fbase: rawptr,
		dli_sname: cstring,
		dli_saddr: rawptr,
	}

	foreign dl {
		dladdr :: proc "c" (addr: rawptr, info: ^Dl_Info) -> i32 ---
	}

	symbols_init :: proc() {}

	resolve :: proc(slot: rawptr, allocator := context.allocator) -> string {
		info: Dl_Info
		if dladdr(slot, &info) != 0 && info.dli_sname != nil {
			return strings.clone_from_cstring(info.dli_sname, allocator)
		}
		return strings.clone("<unnamed>", allocator)
	}
}

// ---------------------------------------------------------------------------------------------------

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
		"Sciter %d.%d.%d.%d, ISciterAPI version %d, on %v/%v\n",
		api.SciterVersion(0),
		api.SciterVersion(1),
		api.SciterVersion(2),
		api.SciterVersion(3),
		api.version,
		ODIN_OS,
		ODIN_ARCH,
	)

	symbols_init()

	base := uintptr(api)
	null_slots := make([dynamic]string, context.temp_allocator)

	for f, i in reflect.struct_fields_zipped(sciter.Isciter_Api) {
		if f.name == "version" {
			continue
		}
		slot := (^rawptr)(base + f.offset)^
		if slot == nil {
			append(&null_slots, f.name)
			fmt.printfln("%3d off=%4d %-34s -> <null>", i, f.offset, f.name)
			continue
		}

		name := resolve(slot, context.temp_allocator)
		if len(name) > 90 {
			name = strings.concatenate({name[:87], "..."}, context.temp_allocator)
		}
		fmt.printfln("%3d off=%4d %-34s -> %s", i, f.offset, f.name, name)
	}

	fmt.printfln(
		"\n%d slots, %d null (platform-padded)",
		reflect.struct_field_count(sciter.Isciter_Api) - 1,
		len(null_slots),
	)

	// Listed together as well as inline: which slots a platform leaves empty is the thing to compare
	// against the previous engine version, and against the other platforms.
	if len(null_slots) > 0 {
		fmt.println("null:", strings.join(null_slots[:], ", ", context.temp_allocator))
	}
}
