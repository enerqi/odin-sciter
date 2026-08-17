// VALUE - the engine's variant type, and the thing most likely to leak.
//
// A Value is 16 bytes of plain data that may own a reference to something inside the engine (a string,
// an array, a map, a script object). The rules are the C API's, and this package does not hide them:
//
//   - a Value must be `value_init`ed before first use, or zeroed, which is the same thing
//   - a Value that came out of the engine (from `eval`, `call`, `value_at`, `element_value`, ...) owns
//     a reference, and the receiver must `value_clear` it
//   - `value_copy` takes a second reference; two clears are then owed
//   - a Value handed *to* the engine as an argument is not consumed - it is still yours to clear
//
// The convenience is in construction and extraction, not in lifetime. `defer value_clear(&v)` next to
// every Value that came from the engine is the whole discipline.
package sciter_app

import sciter ".."
import "base:runtime"
import "core:mem"

// The engine's variant. Same type as `sciter.Value`, so the two can be passed back and forth freely.
Value :: sciter.Value

// Zeroes a Value into the undefined state. A zeroed Value is already valid, so this matters mainly for
// reusing one that has been cleared.
value_init :: proc(v: ^Value) {
	engine().ValueInit(v)
}

// Releases whatever the Value holds and returns it to undefined. Safe to call twice.
value_clear :: proc(v: ^Value) {
	when ODIN_DEBUG {
		// Counted before the clear, because afterwards it owns nothing and there is nothing to see.
		if value_owns_reference(v) {
			track_release_counted(.Value)
		}
	}
	engine().ValueClear(v)
}

// Takes a second reference to `src`. Both `dst` and `src` then owe a clear.
value_copy :: proc(dst: ^Value, src: ^Value, loc := #caller_location) -> Error {
	err := value_err(engine().ValueCopy(dst, src))
	when ODIN_DEBUG {
		// A second reference, so a second clear is owed.
		if err == nil && value_owns_reference(dst) {
			track_acquire_counted(.Value, loc)
		}
	}
	return err
}

// Meant to detach the Value from anything sharing it, so a write to it cannot be observed elsewhere -
// the copy-on-write break, and the only reason the call exists.
//
// **It does not work on the vendored 6.0.4.9 engine.** `.OK`, and the sharing survives: after
// `value_copy` and then `value_isolate` on either side (or both), writing a key through the copy is
// still visible through the original, for maps and for arrays, at the top level and on a nested Value
// pulled out with `value_get`. Measured every way round.
//
// So there is no cheap detach. A Value that must not be written through by somebody else has to be
// rebuilt - walk it with `value_each` and construct a new one - or kept from being shared in the first
// place. `value_copy` shares; `value_parse` of the same text does not.
value_isolate :: proc(v: ^Value) -> Error {
	return value_err(engine().ValueIsolate(v))
}

value_equal :: proc(a: ^Value, b: ^Value) -> bool {
	// ValueCompare reports equality as OK_TRUE, which is -1, not as OK.
	return engine().ValueCompare(a, b) == .OK_TRUE
}

// What the Value holds. `units` further qualifies it and its meaning depends on the type - it is a
// VALUE_UNIT_TYPE for .LENGTH, a VALUE_UNIT_TYPE_OBJECT for .OBJECT, and so on, which is why it comes
// back as a bare integer.
value_type :: proc(v: ^Value) -> (type: sciter.Value_Type, units: u32) {
	engine().ValueType(v, &type, &units)
	return
}

value_is_undefined :: proc(v: ^Value) -> bool {
	type, _ := value_type(v)
	return type == .UNDEFINED
}

value_is_null :: proc(v: ^Value) -> bool {
	type, _ := value_type(v)
	return type == .NULL
}

// True if the Value is one of the engine's *error strings*: a string carrying the `.ERROR` unit rather
// than the `.STRING` one. That is how `value_parse` reports a bad document - the parse "succeeds" and
// hands back a string reading "JSON parsing error in line 0 at 4 position" - and it is worth checking
// on anything that came back from script.
value_is_error :: proc(v: ^Value) -> bool {
	type, units := value_type(v)
	return type == .STRING && units == u32(sciter.Value_Unit_Type_String.ERROR)
}

// ---------------------------------------------------------------------------------------------------
// Construction
//
// Each returns a Value the caller owns and must `value_clear`.

value_from_bool :: proc(b: bool) -> (v: Value) {
	engine().ValueIntDataSet(&v, 1 if b else 0, .BOOL, 0)
	return
}

value_from_int :: proc(i: i32) -> (v: Value) {
	engine().ValueIntDataSet(&v, i, .INT, 0)
	return
}

value_from_i64 :: proc(i: i64) -> (v: Value) {
	engine().ValueInt64DataSet(&v, i, .BIG_INT, 0)
	return
}

value_from_f64 :: proc(f: f64) -> (v: Value) {
	engine().ValueFloatDataSet(&v, f, .FLOAT, 0)
	return
}

// The engine copies the string, so `s` does not have to outlive the call.
value_from_string :: proc(s: string, loc := #caller_location) -> (v: Value) {
	w := utf16_from_string(s, context.temp_allocator)
	engine().ValueStringDataSet(&v, raw_data(w), u32(len(w) - 1), 0)
	// A constructed string owns engine memory exactly as a returned one does, and `value_clear`
	// releases it either way - so the ledger has to see both halves or it drifts negative.
	return tracked(v, loc)
}

// A byte blob - image data, a file's contents. The engine copies it.
value_from_bytes :: proc(b: []u8, loc := #caller_location) -> (v: Value) {
	engine().ValueBinaryDataSet(&v, raw_data(b), u32(len(b)), .BYTES, 0)
	return tracked(v, loc)
}

// An empty array of `length` undefined slots, ready for `value_set_at`. A zero length is a real empty
// array - `value_len` on it is 0, not `.INCOMPATIBLE_TYPE`.
value_make_array :: proc(length: int) -> (v: Value) {
	// Writing the last slot is what gives the array its length, and there is no last slot to write at
	// zero. Parsing `[]` is how the type gets set in that case - measured: the result reports a length
	// of 0 and no error, where a zeroed Value is `.UNDEFINED` and reports `.INCOMPATIBLE_TYPE`. The
	// difference is invisible to the append pattern (`value_set_at` on an `.UNDEFINED` makes it a
	// one-element array by the header's own fallback rule) and not invisible to anything that inspects
	// the value first, so an array whose length is computed must not change type when the count is 0.
	if length <= 0 {
		empty, err := value_parse("[]")
		if err != nil {
			// `value_parse` reports a bad document by handing back an error *string*, which owns a
			// reference like any other Value - so the failure path has something to give back, not
			// nothing. Dropping it here leaked one reference per call and read as a leak in whatever
			// built the array.
			value_clear(&empty)
			return v
		}
		return empty
	}
	undefined: Value
	engine().ValueNthElementValueSet(&v, sciter.Int(length - 1), &undefined)
	return tracked(v)
}

value_from :: proc {
	value_from_bool,
	value_from_int,
	value_from_i64,
	value_from_f64,
	value_from_string,
	value_from_bytes,
}

// Parses text into a Value, rather than storing it as one.
//
// `value_from_string` puts the characters in the Value and the type is STRING afterwards. This reads
// the characters as a *literal* and produces whatever they describe, which is what you want for JSON
// arriving over a socket, a config file, or a length written as text:
//
//	v := sciter_app.value_parse(`{"a":[1,2]}`) // a MAP holding an ARRAY
//	defer sciter_app.value_clear(&v)
//
// `how` picks the dialect, and they differ more than the names suggest:
//
//   - `.JSON_LITERAL` (the default) is JSON. `"hello"` unquoted parses as a symbol, `12.5%` as the
//     number 12.5.
//   - `.XJSON_LITERAL` is JSON plus Sciter's extensions - the same results as `.JSON_LITERAL` for
//     everything ordinary, and dates and currency as literals.
//   - `.SIMPLE` parses one terminal value the way an *attribute* would: `42` is an INT, `12.5%` a
//     LENGTH with percent units, `1976-02-03` a DATE, and anything it does not recognise - including
//     `[1,2,3]` - stays a plain string. It never fails.
//   - `.JSON_MAP` resumes parsing an object whose opening `{` has already been consumed - so it wants
//     the body *and* the closing brace, `a:1}`, and keys need no quotes. Handing it a whole document,
//     braces and all, is a parse error rather than the obvious success.
//
// The engine reports a parse failure in the result rather than in the return code: the call reports OK
// and hands back a string carrying the `.ERROR` unit, whose text is the message. So on `.Parse_Failed`
// the returned Value is that message - `value_to_string` it for the diagnosis - and it still owes a
// `value_clear` like any other.
value_parse :: proc(s: string, how := sciter.Value_String_Cvt_Type.JSON_LITERAL) -> (v: Value, err: Error) {
	w := utf16_from_string(s, context.temp_allocator)
	value_err(engine().ValueFromString(&v, raw_data(w), u32(len(w) - 1), how)) or_return
	if value_is_error(&v) {
		return tracked(v), .Parse_Failed
	}
	return tracked(v), nil
}

// ---------------------------------------------------------------------------------------------------
// Extraction

// True for any non-zero integer, at either width. Both slots are needed and neither is enough on its
// own, measured on 6.0.4.9: `ValueIntData` answers 0 with no error on a `.BIG_INT` - so a boolean that
// made the round trip through an `i64` would read `false` - and `ValueInt64Data` refuses a `.BOOL`
// outright with `.INCOMPATIBLE_TYPE`. So the type decides which one is asked.
value_to_bool :: proc(v: ^Value) -> (b: bool, err: Error) {
	if type, _ := value_type(v); type == .BIG_INT {
		i := value_to_i64(v) or_return
		return i != 0, nil
	}
	i: sciter.Int
	value_err(engine().ValueIntData(v, &i)) or_return
	return i != 0, nil
}

// **This reads `.INT` and `.BOOL` only. On a `.BIG_INT` it answers 0 and no error** - including one
// holding 5, which would fit in an `i32` with room to spare. `value_from(i64(5))` makes a `.BIG_INT`,
// so a number that made the round trip through an `i64` anywhere in its life reads back as zero here.
// Use `value_to_i64`, which handles both, unless the type is known to be `.INT`.
value_to_int :: proc(v: ^Value) -> (i: i32, err: Error) {
	value_err(engine().ValueIntData(v, &i)) or_return
	return i, nil
}

// Reads `.INT` and `.BIG_INT` alike, and the full `i64` range round-trips - `min(i64)` and `max(i64)`
// included. A `.FLOAT` or a `.STRING` is `.INCOMPATIBLE_TYPE` rather than being coerced, so this never
// silently rounds or parses.
value_to_i64 :: proc(v: ^Value) -> (i: i64, err: Error) {
	value_err(engine().ValueInt64Data(v, &i)) or_return
	return i, nil
}

value_to_f64 :: proc(v: ^Value) -> (f: f64, err: Error) {
	value_err(engine().ValueFloatData(v, &f)) or_return
	return f, nil
}

// The string the Value holds, copied into `allocator`. Fails with .INCOMPATIBLE_TYPE if the Value is
// not a string - use `value_to_display_string` to render any Value.
value_to_string :: proc(v: ^Value, allocator := context.allocator) -> (s: string, err: Error) {
	chars: [^]u16
	n: u32
	value_err(engine().ValueStringData(v, &chars, &n)) or_return
	return string_from_utf16(chars, uint(n), allocator), nil
}

// The `som_asset_t` a `.ASSET` Value holds. `.INCOMPATIBLE_TYPE` for any other type of Value.
//
// The pointer is borrowed: the Value owns the reference the engine add_ref'd when it wrapped it, so it
// stays alive exactly as long as the Value does. To keep it longer, keep the Value - or take a
// reference of your own through `asset.isa.asset_add_ref`.
value_to_asset :: proc(v: ^Value) -> (asset: ^sciter.Som_Asset_T, err: Error) {
	type, _ := value_type(v)
	if type != .ASSET {
		return nil, Api_Error.Wrong_Type
	}
	i: i64
	value_err(engine().ValueInt64Data(v, &i)) or_return
	return (^sciter.Som_Asset_T)(uintptr(i)), nil
}

// Wraps an asset as a Value, which is how one crosses into script or into a SOM method's arguments.
//
// The engine does *not* add_ref here - `value.hpp`'s `wrap_asset` is a bare `ValueInt64DataSet` - so
// the asset has to outlive the Value.
value_from_asset :: proc(asset: ^sciter.Som_Asset_T) -> (v: Value) {
	engine().ValueInt64DataSet(&v, i64(uintptr(asset)), .ASSET, 0)
	return
}

// The bytes the Value holds. Borrowed from the engine and only valid until the Value changes or is
// cleared, so copy them if they have to outlive it.
//
// **Both halves of that were measured, and both fail quietly.** After `value_clear` the slice reads
// correctly at first and becomes whatever the allocator handed out next after about 1.6 MB of churn -
// so "read it straight after and it looked fine" proves nothing. After a `value_copy` over the same
// Value the buffer is corrupt immediately. Nothing allocates per call: asking twice returns the same
// pointer, which is the other way of saying there is nothing here to free.
value_to_bytes :: proc(v: ^Value) -> (b: []u8, err: Error) {
	p: [^]u8
	n: u32
	value_err(engine().ValueBinaryData(v, &p, &n)) or_return
	if p == nil {
		return nil, nil
	}
	return p[:n], nil
}

// Renders any Value as text, the way script's `String(v)` would. `.JSON_LITERAL` produces JSON, which
// is what you want for printing an array or a map.
//
// This converts the Value in place - it is a string afterwards - so it takes a copy first.
value_to_display_string :: proc(
	v: ^Value,
	how := sciter.Value_String_Cvt_Type.SIMPLE,
	allocator := context.allocator,
) -> (
	s: string,
	err: Error,
) {
	tmp: Value
	value_copy(&tmp, v) or_return
	defer value_clear(&tmp)

	value_err(engine().ValueToString(&tmp, how)) or_return
	return value_to_string(&tmp, allocator)
}

// ---------------------------------------------------------------------------------------------------
// Arrays and maps
//
// In Sciter an array and a map are the same machinery: an array is a Value whose keys are the integers
// 0..n. `value_len` and `value_at` work on both.

// Number of elements in an array, or key/value pairs in a map.
value_len :: proc(v: ^Value) -> (n: int, err: Error) {
	count: sciter.Int
	value_err(engine().ValueElementsCount(v, &count)) or_return
	return int(count), nil
}

// The nth element. The result owns a reference; `value_clear` it.
value_at :: proc(v: ^Value, n: int) -> (element: Value, err: Error) {
	value_err(engine().ValueNthElementValue(v, sciter.Int(n), &element)) or_return
	return tracked(element), nil
}

// The nth key of a map. The result owns a reference; `value_clear` it.
//
// A key is whatever was used as one - an integer, or a whole map - not necessarily a string, so read
// `value_type` on it rather than assuming.
//
// Two things it does not do: an index past the end is `.OK` and an `.UNDEFINED` Value rather than an
// error (as `value_at` also is - check the type, not the error), and on an *array* it is
// `.INCOMPATIBLE_TYPE`. Arrays are described here as maps keyed by 0..n, and for this one call they
// are not.
value_key_at :: proc(v: ^Value, n: int) -> (key: Value, err: Error) {
	value_err(engine().ValueNthElementKey(v, sciter.Int(n), &key)) or_return
	return tracked(key), nil
}

// Writes the nth element, growing the array if needed. `element` is copied, not consumed.
value_set_at :: proc(v: ^Value, n: int, element: ^Value) -> Error {
	return value_err(engine().ValueNthElementValueSet(v, sciter.Int(n), element))
}

// The value stored under `key`, which may be a string, an integer, anything. The result owns a
// reference; `value_clear` it.
value_get_key :: proc(v: ^Value, key: ^Value) -> (result: Value, err: Error) {
	value_err(engine().ValueGetValueOfKey(v, key, &result)) or_return
	return tracked(result), nil
}

// The value stored under a string key. The result owns a reference; `value_clear` it.
value_get :: proc(v: ^Value, key: string) -> (result: Value, err: Error) {
	k := value_from_string(key)
	defer value_clear(&k)
	return value_get_key(v, &k)
}

// Stores `element` under `key`. Neither is consumed.
value_set_key :: proc(v: ^Value, key: ^Value, element: ^Value) -> Error {
	return value_err(engine().ValueSetValueToKey(v, key, element))
}

// Stores `element` under a string key. `element` is not consumed.
value_set :: proc(v: ^Value, key: string, element: ^Value) -> Error {
	k := value_from_string(key)
	defer value_clear(&k)
	return value_set_key(v, &k, element)
}

// Called once per element by `value_each`. Return false to stop the walk.
//
// `key` and `value` are borrowed for the duration of the call - the engine still owns them, so do not
// clear them, and `value_copy` anything that has to outlive the call.
Value_Visitor :: proc(key: ^Value, value: ^Value, user_data: rawptr) -> bool

// Walks a map's pairs or an array's elements, calling `visit` for each.
//
// This is the engine's own enumeration rather than a loop over `value_len` / `value_at`, so it costs
// one call instead of one per element and it does not hand you a reference to clear per element.
//
//	sciter_app.value_each(&map, proc(k, v: ^sciter_app.Value, _: rawptr) -> bool {
//		name, _ := sciter_app.value_to_string(k, context.temp_allocator)
//		fmt.println(name)
//		return true
//	})
//
// **An array's keys are undefined, not indexes.** The engine reports the key as `T_UNDEFINED` for
// every element of an array; count in `user_data` if the position matters, or use `value_at`.
//
// Anything that is not a container - a number, a string - fails with `.INCOMPATIBLE_TYPE` rather than
// visiting nothing.
//
// **The key and the value are borrowed, and clearing one edits the container.** Measured: a visitor
// that clears what it is handed leaves the array its original length with every visited element
// `.UNDEFINED`, and neither the call nor the engine reports anything. `value_copy` whatever has to
// outlive the walk. `examples/eval.odin` pins it, and `docs/rules.md` 2 has the same test for the two
// other shapes of borrowed Value.
value_each :: proc(v: ^Value, visit: Value_Visitor, user_data: rawptr = nil) -> Error {
	if visit == nil {
		return sciter.Value_Result.BAD_PARAMETER
	}
	sink := Each_Sink {
		ctx       = context,
		visit     = visit,
		user_data = user_data,
	}
	return value_err(engine().ValueEnumElements(v, each_callback, &sink))
}

@(private)
Each_Sink :: struct {
	ctx:       runtime.Context,
	visit:     Value_Visitor,
	user_data: rawptr,
}

@(private)
each_callback :: proc "system" (param: rawptr, key: ^Value, value: ^Value) -> b32 {
	sink := (^Each_Sink)(param)
	context = sink.ctx
	callback_temp_scope() // rule 4's boundary, taken here - see sciter_app.odin
	return b32(sink.visit(key, value, sink.user_data))
}

// ---------------------------------------------------------------------------------------------------
// Native functions
//
// A Value can hold a pointer to an Odin procedure, and script then calls it like any other function.
// This is the way *into* Odin from JavaScript: put one in the document's globals (see `globals`) or
// hand it to script as an argument, and script calls it.

// An Odin procedure script can call.
//
// `args` is borrowed for the duration of the call - copy anything that has to outlive it. The returned
// Value is handed to the engine, which takes ownership of the reference, so do not clear it.
Native_Function :: proc(args: []Value, user_data: rawptr) -> Value

// Wraps an Odin procedure in a Value.
//
// The wrapper allocates a small record to hold `fn`, `user_data` and the calling context; the engine
// frees it when the last reference to the Value goes away. `allocator` must therefore outlive the
// Value, which for the usual case of a function living in the document's globals means it outlives the
// window.
//
// Measured, because "the engine frees it" was the header's word and nothing had checked: with a
// `mem.Tracking_Allocator` as `allocator`, `value_from_function` leaves exactly one live allocation and
// `value_clear` leaves **zero live and zero bad frees**. So `functor_release` runs once, and the record
// is neither leaked nor double-freed. Clean under ASan too.
value_from_function :: proc(
	fn: Native_Function,
	user_data: rawptr = nil,
	allocator := context.allocator,
) -> (
	v: Value,
) {
	functor := new(Functor, allocator)
	functor^ = {
		fn        = fn,
		user_data = user_data,
		ctx       = context,
		allocator = allocator,
	}
	engine().ValueNativeFunctorSet(&v, functor_invoke, functor_release, (^sciter.Void)(functor))
	return tracked(v)
}

// True if the Value holds a `value_from_function` procedure rather than a script function.
value_is_function :: proc(v: ^Value) -> bool {
	return bool(engine().ValueIsNativeFunctor(v))
}

@(private)
Functor :: struct {
	fn:        Native_Function,
	user_data: rawptr,
	ctx:       runtime.Context,
	allocator: mem.Allocator,
}

@(private)
functor_invoke :: proc "system" (tag: ^sciter.Void, argc: u32, argv: ^Value, retval: ^Value) {
	functor := (^Functor)(tag)
	context = functor.ctx
	callback_temp_scope() // rule 4's boundary, taken here - see sciter_app.odin

	args: []Value
	if argc > 0 && argv != nil {
		args = ([^]Value)(argv)[:argc]
	}

	// The engine owns `retval` after this returns, so the reference is transferred rather than copied.
	retval^ = functor.fn(args, functor.user_data)
}

@(private)
functor_release :: proc "system" (tag: ^sciter.Void) {
	functor := (^Functor)(tag)
	context = functor.ctx
	free(functor, functor.allocator)
}

// Calls a script function that is held in a Value - what `eval` returns for a function expression, or
// what script passed you as a callback.
//
// `this` may be nil, in which case the function is called unbound. The result owns a reference;
// `value_clear` it. The arguments are not consumed.
value_invoke :: proc(fn: ^Value, this: ^Value = nil, args: []Value = nil) -> (result: Value, err: Error) {
	undefined: Value
	self := this if this != nil else &undefined

	argv: ^Value
	if len(args) > 0 {
		argv = &args[0]
	}

	// The trailing URL is what script sees as the call site in a stack trace.
	value_err(engine().ValueInvoke(fn, self, u32(len(args)), argv, &result, nil)) or_return
	return tracked(result), nil
}
