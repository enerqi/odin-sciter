// Odin as a Sciter *native extension* - the third way to combine the two.
//
//   just extension                 # builds target/debug/odin-ext.so
//   just extension-run             # builds it, then runs it under the SDK's scapp
//
// The other examples all embed the engine: your Odin program owns `main`, opens libsciter, and drives
// it. This inverts that. Here the *engine* owns the process - either `scapp`, or a single-file
// application assembled from it by Quark - and your Odin code is a shared library it loads on demand:
//
//	import * as sciter from "@sciter";
//	const ext = sciter.loadLibrary("odin-ext");   // finds odin-ext.so next to the executable
//	ext.greet("world");
//
// That matters because the scapp/Quark path is otherwise JavaScript-only. This is the escape hatch:
// a Quark application that needs to do something JS cannot can call into Odin for it.
//
// The whole contract is one exported symbol, from sciter-x-api.h:
//
//	SBOOL SCAPI SciterLibraryInit(ISciterAPI* psapi, SCITER_VALUE* plibobject)
//
// The host passes in the API table - the engine is already loaded, so `sciter.load()` would be wrong
// here, and `sciter.adopt()` takes the table instead. Whatever is written into `plibobject` becomes
// the value `loadLibrary` returns to script.
package odin_extension

import sciter ".."
import "../sciter_app"
import "base:runtime"
import "core:fmt"
import "core:strings"

// Kept alive for the life of the library: the functors in the returned object hold pointers to it.
@(private)
g_state: struct {
	calls: int,
}

// The entry point. `@(export)` is what puts the symbol in the .so's dynamic table, and the name must be
// exactly this - it is what the engine looks up.
//
// `proc "system"` for the same reason as everything in `package sciter`: SCAPI is empty on Linux and
// macOS and `__stdcall` on 32-bit Windows, which is what Odin spells "system".
@(export)
SciterLibraryInit :: proc "system" (
	psapi: ^sciter.Isciter_Api,
	plibobject: ^sciter.Value,
) -> b32 {
	// The engine calls in with no Odin context - there is no runtime set up on this thread as far as
	// Odin is concerned, so one has to be established before anything allocates.
	context = runtime.default_context()

	// Not `load`: the host already has the library open and is handing us its table. `adopt` still
	// checks the version, which matters more here than when embedding - the host chose the engine, so
	// it may not be the one these bindings were generated against.
	if err := sciter.adopt(psapi); err != .None {
		return false
	}

	// Build the object script will see. A zeroed Value becomes a map on first assignment.
	lib: sciter.Value

	greet := sciter_app.value_from_function(ext_greet, &g_state)
	defer sciter_app.value_clear(&greet)
	sciter_app.value_set(&lib, "greet", &greet)

	engine_version := sciter_app.value_from_function(ext_version, &g_state)
	defer sciter_app.value_clear(&engine_version)
	sciter_app.value_set(&lib, "version", &engine_version)

	calls := sciter_app.value_from_function(ext_calls, &g_state)
	defer sciter_app.value_clear(&calls)
	sciter_app.value_set(&lib, "calls", &calls)

	// Hand our reference over: the host owns it from here, and clears it when the library is released.
	plibobject^ = lib
	return true
}

// ---------------------------------------------------------------------------------------------------
// The procedures script can call. Same `Native_Function` shape as `call_odin_from_js` - nothing about
// them knows they are in an extension rather than in a host application.

ext_greet :: proc(args: []sciter_app.Value, user_data: rawptr) -> sciter_app.Value {
	g_state.calls += 1

	who := "world"
	if len(args) > 0 {
		if s, err := sciter_app.value_to_string(&args[0], context.temp_allocator); err == nil {
			who = s
		}
	}
	return sciter_app.value_from(
		strings.concatenate({"hello, ", who, " - from Odin, inside a Sciter extension"}, context.temp_allocator),
	)
}

// Proof that the adopted table is a working engine and not just a pointer we accepted.
ext_version :: proc(args: []sciter_app.Value, user_data: rawptr) -> sciter_app.Value {
	g_state.calls += 1

	v := sciter_app.version()
	return sciter_app.value_from(
		fmt.tprintf("%d.%d.%d.%d", v[0], v[1], v[2], v[3]),
	)
}

// State survives across calls, which is most of the reason to write an extension at all.
ext_calls :: proc(args: []sciter_app.Value, user_data: rawptr) -> sciter_app.Value {
	g_state.calls += 1
	return sciter_app.value_from(i32(g_state.calls))
}
