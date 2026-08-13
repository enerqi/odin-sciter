// Atoms: the engine's interned names.
//
// An atom is a 64-bit integer standing for a string the engine has seen before. Interning is what makes
// a property lookup a comparison of two integers rather than of two strings, and the engine's own
// tables are keyed that way - which is why the API asks for one where a name would read more naturally:
//
//	SCDOM_RESULT SciterGetElementAsset(HELEMENT el, UINT64 nameAtom, som_asset_t** ppass);
//
// That is the whole reason this file exists. Nothing else in `package sciter_app` takes an atom today;
// the SOM side of the API - assets, native properties exposed to script - is where they are the
// currency, and this is the piece that has to be in place first.
//
// Five measured properties, none of them documented upstream:
//
//   - **interning works before `init`, and `load` is the only prerequisite.** Measured on 6.0.4.9:
//     `atom("name")` after `load` but before `init` answers a stable atom, and `atom_name` on *that
//     atom* reads it back. This is what makes `make_asset_class` safe to call at the top of `main`,
//     which is the natural place for it - see its doc comment. It does not extend to atoms nobody
//     interned; see the last point.
//
//   - **`atom` never fails.** A name the engine has not seen is interned there and then, so there is
//     no such thing as an unknown name, only an atom nobody else refers to yet.
//   - **the mapping is stable within a process and meaningless outside one.** `atom("width")` answers
//     280 in one run of this machine's engine build - a small number, and one that is a function of
//     how many names the engine happened to intern before it. Never persist an atom, send one to
//     another process, or hard-code one.
//   - **names are bytes, not text.** The engine widens each byte of the name on the way in and emits
//     UTF-8 of that on the way out, so a non-ASCII name does not round-trip: `atom_name(atom("é"))`
//     answers with mojibake rather than `é`. Atoms are for identifiers - keep them ASCII.
//   - **only hand `atom_name` an atom `atom` gave you.** An invented integer is not merely unknown:
//     `atom_name(Atom(12345))` **segfaults** inside the engine before `init` has run, and answers with
//     an empty name after it. The number space is shared with an encoding of immediates besides -
//     1, 2 and 3 decode to `"null"`, `"false"` and `"true"` - so a fabricated value can just as well
//     come back with a name nothing ever interned. There is no way to ask whether an integer is an
//     atom; the answer is to only use the ones you were given.
package sciter_app

import sciter ".."
import "base:runtime"
import "core:mem"

// An interned name. Sciter's `UINT64` atom, kept distinct so it cannot be confused with a length or an
// index at a call site that takes both.
Atom :: distinct u64

// The atom for `name`, interning it if the engine has not seen it before. Two calls with the same name
// answer the same atom; two different names answer different atoms.
atom :: proc(name: string) -> Atom {
	return Atom(sciter.api().SciterAtomValue(to_cstring(name, context.temp_allocator)))
}

// The name an atom stands for, allocated in `allocator`.
//
// `ok` is false when the engine reports no name, which is what `atom("")` - a real atom whose name is
// empty - comes back as. **Pass only atoms `atom` returned**: the engine has no way to reject an
// integer that is not one and will crash on some of them. See the note at the top of this file.
atom_name :: proc(a: Atom, allocator := context.allocator) -> (name: string, ok: bool) {
	sink := Atom_Sink {
		ctx       = context,
		allocator = allocator,
	}
	if !sciter.api().SciterAtomNameCB(u64(a), atom_receiver, &sink) {
		return "", false
	}
	return sink.out, sink.out != ""
}

@(private = "file")
Atom_Sink :: struct {
	ctx:       runtime.Context,
	allocator: mem.Allocator,
	out:       string,
}

// The name arrives as UTF-8 rather than UTF-16 - atoms are the one string in this API that does.
@(private = "file")
atom_receiver :: proc "system" (str: [^]u8, str_length: u32, param: rawptr) {
	sink := (^Atom_Sink)(param)
	context = sink.ctx
	if str == nil || str_length == 0 {
		sink.out = ""
		return
	}
	buf := make([]u8, str_length, sink.allocator)
	copy(buf, str[:str_length])
	sink.out = string(buf)
}
