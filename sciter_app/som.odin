// SOM: exposing an Odin object to script.
//
// A native functor (see `value_from_function`) gives script a *function* implemented in Odin. This
// gives it an **object**: something with properties it can read and write and methods it can call,
// which is what a document written against an application's model needs.
//
//	class := sciter_app.make_asset_class("Backend", {{name = "count", get = get_count, set = set_count}}, {{name = "reload", call = reload}})
//	asset := sciter_app.make_asset(class, &state)
//	sciter_app.set_global_asset(asset)
//	// then, in the document loaded after that:
//	//   Backend.count += 1
//	//   Backend.reload()
//
// Three things about it are not in the header and cost an afternoon to find out:
//
//   - **A global asset appears at the next document load, not immediately.** `set_global_asset` on a
//     window with a document already in it changes nothing for that document. Publish before loading.
//   - **The "any property" interceptors in the passport are never called** by this engine. Only the
//     `properties` and `methods` tables are consulted, which is why a class here is a fixed list of
//     members rather than a dynamic one.
//   - **SOM properties are not enumerable.** `Object.keys(asset)` is empty even when every property
//     works. Script has to know the names, which is the normal case for an interface.
package sciter_app

import sciter ".."
import "base:runtime"
import "core:c"
import "core:mem"

// The most members one class can have, properties and methods counted separately.
//
// The C API wants a distinct function pointer per member - it passes no index to them and its
// "any property" interceptors are dead on this engine - so the thunks below are written out one per
// slot. Raising this means adding entries to the three tables at the bottom of this file.
MAX_ASSET_MEMBERS :: 32

// An Odin object script can see. Allocate with `make_asset`; its address is what the engine holds.
//
// The first field makes this a C `som_asset_t`, so `&asset.base` is the pointer the raw API takes and
// a `^Som_Asset_T` the engine hands back is a `^Asset` again.
Asset :: struct {
	using base: sciter.Som_Asset_T,
	class:      ^Asset_Class,

	// Yours: the state the getters, setters and methods work on.
	user_data:  rawptr,

	// Captured at `make_asset`. The engine calls back as `proc "system"`, where Odin's implicit context
	// does not exist.
	ctx:        runtime.Context,
	allocator:  mem.Allocator,
}

// Reads a property. The returned Value is handed to the engine, which takes ownership of the
// reference - do not clear it. Return `ok = false` to report the read as failed.
Asset_Getter :: proc(asset: ^Asset) -> (value: Value, ok: bool)

// Writes a property. `value` is borrowed for the call.
Asset_Setter :: proc(asset: ^Asset, value: ^Value) -> bool

// A method. `args` is borrowed; the returned Value is handed to the engine like a getter's.
Asset_Call :: proc(asset: ^Asset, args: []Value) -> (result: Value, ok: bool)

// One property. A nil `set` makes it read-only: script assigning to it gets a thrown
// "setting property" error rather than a silent no-op, and the value is unchanged.
//
// The C API also has constant property slots - an `int`, a `double` or a string stored in the passport
// with no code behind it. A getter that returns the constant does the same job, so this is the only
// form here.
Asset_Property :: struct {
	name: string,
	get:  Asset_Getter,
	set:  Asset_Setter,
}

// One method. **`params` is a cap on how many arguments script may pass**, not a hint: measured on
// 6.0.4.9, a method declared `params = 1` and called as `obj.method(a, b, c)` receives *only* `a`, and
// the rest are dropped with no error anywhere. Declaring more than a caller passes is harmless - `args`
// arrives at the length the caller actually used - so a variadic method should declare the most it will
// ever accept. `examples/sqlite_extension.odin` is where this was found, and it presented as every
// bound database parameter silently becoming NULL.
//
// The host-side call path is the other way round: `asset_call` requires *at least* `params` arguments,
// because the engine's own thunks segfault on a short list. See `asset_call`.
Asset_Method :: struct {
	name:   string,
	params: int,
	call:   Asset_Call,
}

// The shape shared by every asset of one kind: the class name script sees, and the members.
//
// **It has to outlive every asset built from it, and the engine.** The C header says the passport
// "should be statically allocated - at least survive last instance of the engine", and this holds the
// passport. One per kind, made once, is the intended shape.
Asset_Class :: struct {
	properties:    []Asset_Property,
	methods:       []Asset_Method,

	// The C side. `passport` and `class` are pointed at by every asset, so this record must not move -
	// which is why `make_asset_class` returns a pointer rather than a value.
	passport:      sciter.Som_Passport_T,
	class:         sciter.Som_Asset_Class_T,
	property_defs: []sciter.Som_Property_Def_T,
	method_defs:   []sciter.Som_Method_Def_T,
	allocator:     mem.Allocator,
}

// Builds a class. `name` is what script prints for the object (`[asset Backend]`) and what
// `element_asset` matches on; the members are copied, so the slices passed in need not outlive the
// call.
//
// Fails with `.Too_Many_Members` if either list is longer than `MAX_ASSET_MEMBERS`.
//
// Safe before `init`, which matters because the natural place to build a class is at the top of `main`
// alongside the rest of the configuration: this interns one atom per member name, and interning is
// measured to need only `load` - see the header of `atom.odin`.
make_asset_class :: proc(
	name: string,
	properties: []Asset_Property = nil,
	methods: []Asset_Method = nil,
	allocator := context.allocator,
) -> (
	class: ^Asset_Class,
	err: Error,
) {
	if len(properties) > MAX_ASSET_MEMBERS || len(methods) > MAX_ASSET_MEMBERS {
		return nil, .Too_Many_Members
	}

	class = new(Asset_Class, allocator)
	class.allocator = allocator
	class.properties = make([]Asset_Property, len(properties), allocator)
	class.methods = make([]Asset_Method, len(methods), allocator)
	class.property_defs = make([]sciter.Som_Property_Def_T, len(properties), allocator)
	class.method_defs = make([]sciter.Som_Method_Def_T, len(methods), allocator)

	for property, i in properties {
		class.properties[i] = property
		class.properties[i].name = clone_member_name(property.name, allocator)
		class.property_defs[i] = {
			type = int(sciter.Som_Prop_Type.ACCSESSOR),
			name = u64(atom(property.name)),
			u = {accs = {getter = asset_getters[i], setter = asset_setters[i]}},
		}
	}
	for method, i in methods {
		class.methods[i] = method
		class.methods[i].name = clone_member_name(method.name, allocator)
		class.method_defs[i] = {
			name   = u64(atom(method.name)),
			params = uint(method.params),
			func   = asset_methods[i],
		}
	}

	class.class = {
		asset_add_ref       = asset_add_ref,
		asset_release       = asset_release,
		asset_get_interface = asset_get_interface,
		asset_get_passport  = asset_get_passport,
	}
	class.passport = {
		name         = u64(atom(name)),
		properties   = raw_data(class.property_defs),
		n_properties = uint(len(class.property_defs)),
		methods      = raw_data(class.method_defs),
		n_methods    = uint(len(class.method_defs)),
	}
	return class, nil
}

// Frees a class. Every asset built from it is dead afterwards, and so is anything script still holds,
// so this belongs at shutdown or nowhere.
destroy_asset_class :: proc(class: ^Asset_Class) {
	if class == nil {
		return
	}
	allocator := class.allocator
	for property in class.properties {
		delete(property.name, allocator)
	}
	for method in class.methods {
		delete(method.name, allocator)
	}
	delete(class.properties, allocator)
	delete(class.methods, allocator)
	delete(class.property_defs, allocator)
	delete(class.method_defs, allocator)
	free(class, allocator)
}

// One object of that class. `user_data` is what its members are handed back.
//
// The engine stores the address, so the Asset must not move and must outlive script's use of it.
make_asset :: proc(class: ^Asset_Class, user_data: rawptr = nil, allocator := context.allocator) -> ^Asset {
	asset := new(Asset, allocator)
	asset.isa = &class.class
	asset.class = class
	asset.user_data = user_data
	asset.ctx = context
	asset.allocator = allocator
	return asset
}

destroy_asset :: proc(asset: ^Asset) {
	if asset != nil {
		free(asset, asset.allocator)
	}
}

// Publishes the asset as a global, under its class name.
//
// **The document that is already loaded does not see it.** The global appears in the next document
// loaded into any window, so this belongs before `load_html` / `load_file` rather than after.
// A nil asset is `.Asset_Failed` rather than a nil dereference on `&asset.base`: `destroy_asset` and
// every other proc taking an `^Asset` guards, and this is the one that did not.
set_global_asset :: proc(asset: ^Asset) -> Error {
	if asset == nil {
		return .Asset_Failed
	}
	if !engine().SciterSetGlobalAsset(&asset.base) {
		return .Asset_Failed
	}
	return nil
}

// Withdraws it. Same timing in reverse: a document that already has the global keeps it until it is
// replaced.
release_global_asset :: proc(asset: ^Asset) -> Error {
	if asset == nil {
		return .Asset_Failed
	}
	if !engine().SciterReleaseGlobalAsset(&asset.base) {
		return .Asset_Failed
	}
	return nil
}

// The asset an element's *behavior* publishes, by the behavior's name - `element_asset(input, "edit")`
// on an `<input type=text>`, which is the one this was measured against. `.OPERATION_FAILED` for an
// element with no such behavior, which includes every element with no behavior at all.
//
// This is the raw `^sciter.Som_Asset_T` rather than an `Asset`: it belongs to the engine, not to this
// package, and what it can do is whatever its own passport says. Reach it through `asset.isa`.
element_asset :: proc(element: Element, behavior: string) -> (asset: ^sciter.Som_Asset_T, err: Error) {
	dom_err(engine().SciterGetElementAsset(sciter.Helement(element), u64(atom(behavior)), &asset)) or_return
	return asset, nil
}

// ---------------------------------------------------------------------------------------------------
// Reading somebody else's asset
//
// `element_asset` hands back an asset the *engine* owns, and everything it can do is described by its
// passport. These read that description and use it. They work on any `^sciter.Som_Asset_T`,
// whoever made it - an intrinsic behavior's, another extension's, or one of this package's own.
//
// Worth knowing before reaching for them: what an intrinsic behavior publishes here is often *not*
// what script sees. `<input type=text>`'s `edit` asset carries `selectionStart` and `insertText`,
// which script does have; `<video>`'s `video` asset carries `renderingSite`, which script does not -
// calling it from script answers "not a function". A passport is the native interface, and the script
// interface is a separate decision the behavior makes.

// The passport an asset describes itself with, or nil if it has none. Borrowed from the asset.
asset_passport :: proc(asset: ^sciter.Som_Asset_T) -> ^sciter.Som_Passport_T {
	if asset == nil || asset.isa == nil || asset.isa.asset_get_passport == nil {
		return nil
	}
	return asset.isa.asset_get_passport(asset)
}

// The names a passport lists, for discovering an asset rather than assuming it. Both slices are
// allocated in `allocator`; the names inside them come from `atom_name` and are allocated there too.
//
// Names only - a method's argument count comes from `asset_method_arity`, and you need it before
// calling one. `docs/BEHAVIORS.md` is the same information for the engine's own behaviors, measured.
asset_members :: proc(
	asset: ^sciter.Som_Asset_T,
	allocator := context.allocator,
) -> (
	properties: []string,
	methods: []string,
) {
	p := asset_passport(asset)
	if p == nil {
		return nil, nil
	}
	if p.n_properties > 0 && p.properties != nil {
		properties = make([]string, p.n_properties, allocator)
		for def, i in ([^]sciter.Som_Property_Def_T)(p.properties)[:p.n_properties] {
			properties[i], _ = atom_name(Atom(def.name), allocator)
		}
	}
	if p.n_methods > 0 && p.methods != nil {
		methods = make([]string, p.n_methods, allocator)
		for def, i in ([^]sciter.Som_Method_Def_T)(p.methods)[:p.n_methods] {
			methods[i], _ = atom_name(Atom(def.name), allocator)
		}
	}
	return
}

// How many arguments a method the passport lists requires, and whether it lists one at all. This is
// `Som_Method_Def_T.params`, and it is not advisory - see `asset_call`.
asset_method_arity :: proc(asset: ^sciter.Som_Asset_T, method: string) -> (arity: int, found: bool) {
	p := asset_passport(asset)
	if p == nil || p.methods == nil {
		return 0, false
	}
	want := u64(atom(method))
	for def in ([^]sciter.Som_Method_Def_T)(p.methods)[:p.n_methods] {
		if def.name == want {
			return int(def.params), true
		}
	}
	return 0, false
}

// Calls a method the passport lists, by name. `.Not_Found` if the passport has no such method,
// `.Call_Failed` if the method itself refused.
//
// The engine's own thunks are `proc "system"` taking the asset back as their first argument, so this
// is a direct call rather than anything routed through script - which is what makes it work for
// members script cannot see.
//
// **That also means a failure here is not the error string `eval` and `call` produce.** Measured
// against `<input type=text>`'s `edit` asset: `insertText` answers a plain `BOOL` and
// `asset_get("selectionStart")` a plain `INT`, with `value_is_error` false on both. There is no script
// evaluation in this path to throw, so a failure is the thunk's `false` - which arrives here as
// `.Call_Failed` - and nothing richer. Do not reach for `value_is_error` on a SOM result the way you
// would on an `eval` one.
//
// **`.Wrong_Arity` is a guard against a segfault, not a nicety.** The *engine's* thunks read their
// arguments positionally with no check on `argc`: measured on 6.0.4.9, calling `edit`'s `insertText`
// - which the passport declares as one parameter - with none faults inside
// `sciter::om::member_function<...>::thunk`, in the engine, before any of this package's code runs
// again. Passing *more* than the declared count is harmless; the extras are ignored. So the passport's
// `params` is a minimum, `asset_method_arity` is how to ask for it up front, and `docs/BEHAVIORS.md`
// has it for every intrinsic behavior.
//
// `check_arity = false` turns the guard off, and there is one honest reason to: **an asset made by
// this package tolerates a short call.** `make_asset_class`'s thunk hands the method whatever slice it
// was given, so a `params = 2` method called with one argument sees one argument - the check belongs
// in the method, exactly as it does for a functor. Turn it off for an asset you made; leave it on for
// one the engine handed you, which is everything out of `element_asset`.
asset_call :: proc(
	asset: ^sciter.Som_Asset_T,
	method: string,
	args: []Value = nil,
	check_arity := true,
) -> (
	result: Value,
	err: Error,
) {
	p := asset_passport(asset)
	if p == nil || p.methods == nil {
		return {}, .Not_Found
	}
	want := u64(atom(method))
	for def in ([^]sciter.Som_Method_Def_T)(p.methods)[:p.n_methods] {
		if def.name != want || def.func == nil {
			continue
		}
		if check_arity && len(args) < int(def.params) {
			return {}, .Wrong_Arity
		}
		if !def.func(asset, u32(len(args)), raw_data(args), &result) {
			value_clear(&result)
			return {}, .Call_Failed
		}
		// The method wrote a Value the caller now owns - the `value_clear` on the failure path above is
		// the same claim - so it is recorded. See `behavior_value` for why this was missing.
		return tracked(result), nil
	}
	return {}, .Not_Found
}

// Reads a property the passport lists, by name. `.Not_Found` if there is no such property.
//
// Only accessor properties are read through their getter; a passport may also hold a constant, and
// those are returned from the definition itself.
asset_get :: proc(asset: ^sciter.Som_Asset_T, property: string) -> (result: Value, err: Error) {
	p := asset_passport(asset)
	if p == nil || p.properties == nil {
		return {}, .Not_Found
	}
	want := u64(atom(property))
	for def in ([^]sciter.Som_Property_Def_T)(p.properties)[:p.n_properties] {
		if def.name != want {
			continue
		}
		// `def.u` is a union discriminated by `def.type`. Only `.ACCSESSOR` makes `u.accs` the live
		// member; for a constant the same bytes are the constant itself, so calling through them is a
		// jump to whatever the constant happens to be.
		switch sciter.Som_Prop_Type(def.type) {
		case .ACCSESSOR:
			if def.u.accs.getter == nil {
				return {}, .Not_Found
			}
			if !def.u.accs.getter(asset, &result) {
				value_clear(&result)
				return {}, .Call_Failed
			}
			// Recorded for the same reason as `asset_call`. `check-invariants` does not catch this one
			// and cannot: its rule is per *procedure*, and the `.INT32`/`.STRING` arms below reach the
			// ledger through `value_from_*`, so `asset_get` as a whole already satisfied it while this
			// branch alone did not.
			return tracked(result), nil
		case .INT32:
			return value_from_int(def.u._i32), nil
		case .INT64:
			return value_from_i64(def.u._i64), nil
		case .FLOAT:
			return value_from_f64(def.u._f64), nil
		case .STRING:
			if def.u.str == nil {
				return {}, nil
			}
			return value_from_string(string(def.u.str)), nil
		case:
			// A type this binding does not know: the union layout is unknown, so nothing here is safe
			// to read.
			return {}, .Not_Found
		}
	}
	return {}, .Not_Found
}

// Writes one. `.Not_Found` if there is no such property, it is a constant, or it is read-only.
asset_set :: proc(asset: ^sciter.Som_Asset_T, property: string, value: ^Value) -> Error {
	p := asset_passport(asset)
	if p == nil || p.properties == nil {
		return .Not_Found
	}
	want := u64(atom(property))
	for def in ([^]sciter.Som_Property_Def_T)(p.properties)[:p.n_properties] {
		if def.name != want {
			continue
		}
		// Same union as `asset_get`: only an accessor has a setter to call. A constant has none, and
		// its bytes are not a function pointer.
		if sciter.Som_Prop_Type(def.type) != .ACCSESSOR {
			return .Not_Found
		}
		if def.u.accs.setter == nil {
			return .Not_Found
		}
		if !def.u.accs.setter(asset, value) {
			return .Call_Failed
		}
		return nil
	}
	return .Not_Found
}

// The C++ side's `dynamic_cast`: asks an asset for a named interface and hands back the pointer to it,
// or nil. The engine's own assets answer names like "destination.video.sciter.com"; assets this
// package makes answer nothing (`asset_get_interface` below returns 0).
//
// **The returned pointer is not the asset pointer.** An engine asset is a C++ object whose
// `som_asset_t` is a base subobject somewhere inside it, and the interface it hands back is a
// *different* base subobject at a different offset - measured at -24 bytes for `<video>`'s. That is
// exactly why this call exists rather than a cast: it is the only thing that knows the offset. Nothing
// in this package should ever compute one by hand. See `video.odin` for what to do with the result.
asset_interface :: proc(asset: ^sciter.Som_Asset_T, name: cstring) -> rawptr {
	if asset == nil || asset.isa == nil || asset.isa.asset_get_interface == nil {
		return nil
	}
	out: rawptr
	if asset.isa.asset_get_interface(asset, name, &out) == 0 {
		return nil
	}
	return out
}

// ---------------------------------------------------------------------------------------------------
// The C side
//
// Every callback below arrives as `proc "system"` with the asset pointer as its first argument, which
// is where the Odin context comes back from.

@(private = "file")
clone_member_name :: proc(name: string, allocator: mem.Allocator) -> string {
	buf := make([]u8, len(name), allocator)
	copy(buf, name)
	return string(buf)
}

// The engine reference counts assets. Nothing here is freed on the last release: an Asset belongs to
// whoever made it, and freeing it from under `destroy_asset` would be worse than holding it a moment
// too long.
@(private = "file")
asset_add_ref :: proc "system" (thing: ^sciter.Som_Asset_T) -> c.long {
	return 1
}

@(private = "file")
asset_release :: proc "system" (thing: ^sciter.Som_Asset_T) -> c.long {
	return 1
}

// `asset_get_interface` is the C++ side's dynamic_cast. Nothing here implements a named interface.
@(private = "file")
asset_get_interface :: proc "system" (thing: ^sciter.Som_Asset_T, name: cstring, out: ^rawptr) -> c.long {
	return 0
}

@(private = "file")
asset_get_passport :: proc "system" (thing: ^sciter.Som_Asset_T) -> ^sciter.Som_Passport_T {
	asset := (^Asset)(thing)
	return &asset.class.passport
}

// One thunk per member index, because the C API passes no index of its own. `$N` is a compile-time
// constant, so each instantiation is a distinct procedure with its own index baked in.
@(private = "file")
make_asset_getter :: proc "contextless" ($N: int) -> sciter.Som_Prop_Getter_T {
	thunk :: proc "system" (thing: ^sciter.Som_Asset_T, out: ^Value) -> b32 {
		asset := (^Asset)(thing)
		context = asset.ctx
		callback_temp_scope() // rule 4's boundary, taken here - see sciter_app.odin

		property := asset.class.properties[N]
		if property.get == nil {
			return false
		}
		value, ok := property.get(asset)
		if !ok {
			return false
		}
		out^ = value
		return true
	}
	return thunk
}

@(private = "file")
make_asset_setter :: proc "contextless" ($N: int) -> sciter.Som_Prop_Setter_T {
	thunk :: proc "system" (thing: ^sciter.Som_Asset_T, value: ^Value) -> b32 {
		asset := (^Asset)(thing)
		context = asset.ctx
		callback_temp_scope() // rule 4's boundary, taken here - see sciter_app.odin

		property := asset.class.properties[N]
		if property.set == nil {
			return false // read-only; the engine turns this into a script-level error
		}
		return b32(property.set(asset, value))
	}
	return thunk
}

@(private = "file")
make_asset_method :: proc "contextless" ($N: int) -> sciter.Som_Method_T {
	thunk :: proc "system" (thing: ^sciter.Som_Asset_T, argc: u32, argv: ^Value, out: ^Value) -> b32 {
		asset := (^Asset)(thing)
		context = asset.ctx
		callback_temp_scope() // rule 4's boundary, taken here - see sciter_app.odin

		method := asset.class.methods[N]
		if method.call == nil {
			return false
		}

		args: []Value
		if argc > 0 && argv != nil {
			args = ([^]Value)(argv)[:argc]
		}
		result, ok := method.call(asset, args)
		if !ok {
			return false
		}
		out^ = result
		return true
	}
	return thunk
}

// The three tables. Written out because a polymorphic instantiation needs a constant, and `#unroll for`
// does not provide one - `MAX_ASSET_MEMBERS` is the length of these, not the other way round.
@(private = "file")
asset_getters := [MAX_ASSET_MEMBERS]sciter.Som_Prop_Getter_T {
	make_asset_getter(0),
	make_asset_getter(1),
	make_asset_getter(2),
	make_asset_getter(3),
	make_asset_getter(4),
	make_asset_getter(5),
	make_asset_getter(6),
	make_asset_getter(7),
	make_asset_getter(8),
	make_asset_getter(9),
	make_asset_getter(10),
	make_asset_getter(11),
	make_asset_getter(12),
	make_asset_getter(13),
	make_asset_getter(14),
	make_asset_getter(15),
	make_asset_getter(16),
	make_asset_getter(17),
	make_asset_getter(18),
	make_asset_getter(19),
	make_asset_getter(20),
	make_asset_getter(21),
	make_asset_getter(22),
	make_asset_getter(23),
	make_asset_getter(24),
	make_asset_getter(25),
	make_asset_getter(26),
	make_asset_getter(27),
	make_asset_getter(28),
	make_asset_getter(29),
	make_asset_getter(30),
	make_asset_getter(31),
}

@(private = "file")
asset_setters := [MAX_ASSET_MEMBERS]sciter.Som_Prop_Setter_T {
	make_asset_setter(0),
	make_asset_setter(1),
	make_asset_setter(2),
	make_asset_setter(3),
	make_asset_setter(4),
	make_asset_setter(5),
	make_asset_setter(6),
	make_asset_setter(7),
	make_asset_setter(8),
	make_asset_setter(9),
	make_asset_setter(10),
	make_asset_setter(11),
	make_asset_setter(12),
	make_asset_setter(13),
	make_asset_setter(14),
	make_asset_setter(15),
	make_asset_setter(16),
	make_asset_setter(17),
	make_asset_setter(18),
	make_asset_setter(19),
	make_asset_setter(20),
	make_asset_setter(21),
	make_asset_setter(22),
	make_asset_setter(23),
	make_asset_setter(24),
	make_asset_setter(25),
	make_asset_setter(26),
	make_asset_setter(27),
	make_asset_setter(28),
	make_asset_setter(29),
	make_asset_setter(30),
	make_asset_setter(31),
}

@(private = "file")
asset_methods := [MAX_ASSET_MEMBERS]sciter.Som_Method_T {
	make_asset_method(0),
	make_asset_method(1),
	make_asset_method(2),
	make_asset_method(3),
	make_asset_method(4),
	make_asset_method(5),
	make_asset_method(6),
	make_asset_method(7),
	make_asset_method(8),
	make_asset_method(9),
	make_asset_method(10),
	make_asset_method(11),
	make_asset_method(12),
	make_asset_method(13),
	make_asset_method(14),
	make_asset_method(15),
	make_asset_method(16),
	make_asset_method(17),
	make_asset_method(18),
	make_asset_method(19),
	make_asset_method(20),
	make_asset_method(21),
	make_asset_method(22),
	make_asset_method(23),
	make_asset_method(24),
	make_asset_method(25),
	make_asset_method(26),
	make_asset_method(27),
	make_asset_method(28),
	make_asset_method(29),
	make_asset_method(30),
	make_asset_method(31),
}
