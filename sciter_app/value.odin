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
import "core:strings"

// The engine's variant. Same type as `sciter.Value`, so the two can be passed back and forth freely.
Value :: sciter.Value

// Zeroes a Value into the undefined state. A zeroed Value is already valid, so this matters mainly for
// reusing one that has been cleared.
value_init :: proc(v: ^Value) {
	sciter.api().ValueInit(v)
}

// Releases whatever the Value holds and returns it to undefined. Safe to call twice.
value_clear :: proc(v: ^Value) {
	sciter.api().ValueClear(v)
}

// Takes a second reference to `src`. Both `dst` and `src` then owe a clear.
value_copy :: proc(dst: ^Value, src: ^Value) -> Error {
	return value_err(sciter.api().ValueCopy(dst, src))
}

// Detaches the Value from anything sharing it, so writing to it cannot be observed elsewhere.
value_isolate :: proc(v: ^Value) -> Error {
	return value_err(sciter.api().ValueIsolate(v))
}

value_equal :: proc(a: ^Value, b: ^Value) -> bool {
	// ValueCompare reports equality as OK_TRUE, which is -1, not as OK.
	return sciter.api().ValueCompare(a, b) == .OK_TRUE
}

// What the Value holds. `units` further qualifies it and its meaning depends on the type - it is a
// VALUE_UNIT_TYPE for .LENGTH, a VALUE_UNIT_TYPE_OBJECT for .OBJECT, and so on, which is why it comes
// back as a bare integer.
value_type :: proc(v: ^Value) -> (type: sciter.Value_Type, units: u32) {
	sciter.api().ValueType(v, &type, &units)
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

// ---------------------------------------------------------------------------------------------------
// Construction
//
// Each returns a Value the caller owns and must `value_clear`.

value_from_bool :: proc(b: bool) -> (v: Value) {
	sciter.api().ValueIntDataSet(&v, 1 if b else 0, .BOOL, 0)
	return
}

value_from_int :: proc(i: i32) -> (v: Value) {
	sciter.api().ValueIntDataSet(&v, i, .INT, 0)
	return
}

value_from_i64 :: proc(i: i64) -> (v: Value) {
	sciter.api().ValueInt64DataSet(&v, i, .BIG_INT, 0)
	return
}

value_from_f64 :: proc(f: f64) -> (v: Value) {
	sciter.api().ValueFloatDataSet(&v, f, .FLOAT, 0)
	return
}

// The engine copies the string, so `s` does not have to outlive the call.
value_from_string :: proc(s: string) -> (v: Value) {
	w := utf16_from_string(s, context.temp_allocator)
	sciter.api().ValueStringDataSet(&v, raw_data(w), u32(len(w) - 1), 0)
	return
}

// A byte blob - image data, a file's contents. The engine copies it.
value_from_bytes :: proc(b: []u8) -> (v: Value) {
	sciter.api().ValueBinaryDataSet(&v, raw_data(b), u32(len(b)), .BYTES, 0)
	return
}

// An empty array of `length` undefined slots, ready for `value_set_at`.
value_make_array :: proc(length: int) -> (v: Value) {
	// Writing the last slot is what gives the array its length.
	if length > 0 {
		undefined: Value
		sciter.api().ValueNthElementValueSet(&v, sciter.Int(length - 1), &undefined)
	}
	return
}

value_from :: proc {
	value_from_bool,
	value_from_int,
	value_from_i64,
	value_from_f64,
	value_from_string,
	value_from_bytes,
}

// ---------------------------------------------------------------------------------------------------
// Extraction

value_to_bool :: proc(v: ^Value) -> (b: bool, err: Error) {
	i: sciter.Int
	value_err(sciter.api().ValueIntData(v, &i)) or_return
	return i != 0, nil
}

value_to_int :: proc(v: ^Value) -> (i: i32, err: Error) {
	value_err(sciter.api().ValueIntData(v, &i)) or_return
	return i, nil
}

value_to_i64 :: proc(v: ^Value) -> (i: i64, err: Error) {
	value_err(sciter.api().ValueInt64Data(v, &i)) or_return
	return i, nil
}

value_to_f64 :: proc(v: ^Value) -> (f: f64, err: Error) {
	value_err(sciter.api().ValueFloatData(v, &f)) or_return
	return f, nil
}

// The string the Value holds, copied into `allocator`. Fails with .INCOMPATIBLE_TYPE if the Value is
// not a string - use `value_to_display_string` to render any Value.
value_to_string :: proc(v: ^Value, allocator := context.allocator) -> (s: string, err: Error) {
	chars: [^]u16
	n: u32
	value_err(sciter.api().ValueStringData(v, &chars, &n)) or_return
	return string_from_utf16(chars, uint(n), allocator), nil
}

// The bytes the Value holds. Borrowed from the engine and only valid until the Value changes or is
// cleared, so copy them if they have to outlive it.
value_to_bytes :: proc(v: ^Value) -> (b: []u8, err: Error) {
	p: [^]u8
	n: u32
	value_err(sciter.api().ValueBinaryData(v, &p, &n)) or_return
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

	value_err(sciter.api().ValueToString(&tmp, how)) or_return
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
	value_err(sciter.api().ValueElementsCount(v, &count)) or_return
	return int(count), nil
}

// The nth element. The result owns a reference; `value_clear` it.
value_at :: proc(v: ^Value, n: int) -> (element: Value, err: Error) {
	value_err(sciter.api().ValueNthElementValue(v, sciter.Int(n), &element)) or_return
	return element, nil
}

// The nth key of a map. The result owns a reference; `value_clear` it.
value_key_at :: proc(v: ^Value, n: int) -> (key: Value, err: Error) {
	value_err(sciter.api().ValueNthElementKey(v, sciter.Int(n), &key)) or_return
	return key, nil
}

// Writes the nth element, growing the array if needed. `element` is copied, not consumed.
value_set_at :: proc(v: ^Value, n: int, element: ^Value) -> Error {
	return value_err(sciter.api().ValueNthElementValueSet(v, sciter.Int(n), element))
}

// The value stored under `key`, which may be a string, an integer, anything. The result owns a
// reference; `value_clear` it.
value_get_key :: proc(v: ^Value, key: ^Value) -> (result: Value, err: Error) {
	value_err(sciter.api().ValueGetValueOfKey(v, key, &result)) or_return
	return result, nil
}

// The value stored under a string key. The result owns a reference; `value_clear` it.
value_get :: proc(v: ^Value, key: string) -> (result: Value, err: Error) {
	k := value_from_string(key)
	defer value_clear(&k)
	return value_get_key(v, &k)
}

// Stores `element` under `key`. Neither is consumed.
value_set_key :: proc(v: ^Value, key: ^Value, element: ^Value) -> Error {
	return value_err(sciter.api().ValueSetValueToKey(v, key, element))
}

// Stores `element` under a string key. `element` is not consumed.
value_set :: proc(v: ^Value, key: string, element: ^Value) -> Error {
	k := value_from_string(key)
	defer value_clear(&k)
	return value_set_key(v, &k, element)
}

// ---------------------------------------------------------------------------------------------------

@(private)
to_cstring :: proc(s: string, allocator := context.allocator) -> cstring {
	return strings.clone_to_cstring(s, allocator)
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
	sciter.api().ValueNativeFunctorSet(&v, functor_invoke, functor_release, (^sciter.Void)(functor))
	return
}

// True if the Value holds a `value_from_function` procedure rather than a script function.
value_is_function :: proc(v: ^Value) -> bool {
	return bool(sciter.api().ValueIsNativeFunctor(v))
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
	value_err(sciter.api().ValueInvoke(fn, self, u32(len(args)), argv, &result, nil)) or_return
	return result, nil
}
