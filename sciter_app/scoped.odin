// Scoped resources: the release the language performs for you.
//
// `docs/rules.md` §2 is a page of prose because a `Value` is one type carrying four different
// contracts - the receiver owes a clear, owes nothing, gives ownership away, or must not clear - and
// nothing in the signature says which. The cost of that is a leak that no tool reports: a `Value`
// dropped on the floor keeps its reference inside the engine, where Odin's allocator tracking cannot
// see it. Measured on the vendored engine, 2000 discarded `eval`s of a 100 kB string grow the process
// by 390 MB; the same loop with `value_clear` grows it by 76 kB.
//
// Every procedure here is the ordinary one wrapped in `@(deferred_out)`, which hands the results to a
// cleanup procedure at the end of the calling scope. That covers the overwhelmingly common shape - read
// a value, use it here, done - and it covers it *whatever the caller does with the results*:
//
//	v, err := sciter_app.scoped_eval(window, "getRows()")   // released at the end of this scope
//	_, _ = sciter_app.scoped_eval(window, "refresh()")      // released too, discarded or not
//
// That second line is the point. `@(require_results)` - the attribute this package uses on
// `utf16_from_string` and friends - does **not** catch it: measured, it rejects a bare `producer()` and
// accepts `_, _ = producer()`, which is exactly the form that leaked in `examples/native_child.odin`.
// `@(deferred_out)` fires on both.
//
// **Use the unscoped procedure when the resource has to outlive the scope**, which is the whole reason
// both exist: anything stored in a struct, returned upwards, or handed to the engine to keep. These are
// for the local read, and they are the ones to reach for by default.
//
// Nothing here changes what the engine does - `scoped_eval` *is* `eval`. The only difference is who
// remembers to let go.
package sciter_app

import sciter ".."

// ---------------------------------------------------------------------------------------------------
// Values

// `eval`, released at the end of the calling scope.
//
// Worth knowing before deciding this is unnecessary for a script that "returns nothing": an assignment
// expression evaluates to the assigned value, so `x = "hi"` hands back a STRING, and `el.on("click", f)`
// hands back a RESOURCE. Both own a reference. Measured - the shape of the script does not tell you.
@(deferred_out = release_scoped_value)
scoped_eval :: proc(window: Window, script: string) -> (result: Value, err: Error) {
	return eval(window, script)
}

// `eval_element`, released at the end of the calling scope.
@(deferred_out = release_scoped_value)
scoped_eval_element :: proc(element: Element, script: string) -> (result: Value, err: Error) {
	return eval_element(element, script)
}

// `call`, released at the end of the calling scope. The arguments are untouched, as ever.
@(deferred_out = release_scoped_value)
scoped_call :: proc(window: Window, function: string, args: ..Value) -> (result: Value, err: Error) {
	return call(window, function, ..args)
}

// `call_method`, released at the end of the calling scope.
@(deferred_out = release_scoped_value)
scoped_call_method :: proc(element: Element, method: string, args: ..Value) -> (result: Value, err: Error) {
	return call_method(element, method, ..args)
}

// `call_function`, released at the end of the calling scope.
@(deferred_out = release_scoped_value)
scoped_call_function :: proc(element: Element, function: string, args: ..Value) -> (result: Value, err: Error) {
	return call_function(element, function, ..args)
}

// `element_value`, released at the end of the calling scope.
@(deferred_out = release_scoped_value)
scoped_element_value :: proc(element: Element) -> (result: Value, err: Error) {
	return element_value(element)
}

// `expando`, released at the end of the calling scope.
@(deferred_out = release_scoped_value)
scoped_expando :: proc(element: Element) -> (result: Value, err: Error) {
	return expando(element)
}

// `global`, released at the end of the calling scope.
@(deferred_out = release_scoped_value)
scoped_global :: proc(window: Window, name: string) -> (result: Value, err: Error) {
	return global(window, name)
}

// `value_at`, released at the end of the calling scope.
@(deferred_out = release_scoped_value)
scoped_value_at :: proc(v: ^Value, n: int) -> (result: Value, err: Error) {
	return value_at(v, n)
}

// `value_get`, released at the end of the calling scope.
@(deferred_out = release_scoped_value)
scoped_value_get :: proc(v: ^Value, key: string) -> (result: Value, err: Error) {
	return value_get(v, key)
}

// `value_parse`, released at the end of the calling scope.
//
// The `.Parse_Failed` result is a Value too - the engine reports a bad document as an error string - so
// this releases it on that path as well, which is the one people forget.
@(deferred_out = release_scoped_value)
scoped_value_parse :: proc(
	s: string,
	how := sciter.Value_String_Cvt_Type.JSON_LITERAL,
) -> (
	result: Value,
	err: Error,
) {
	return value_parse(s, how)
}

// `behavior_value`, released at the end of the calling scope. Three results, so it needs its own
// cleanup procedure - `@(deferred_out)` hands over the whole tuple.
@(deferred_out = release_scoped_behavior_value)
scoped_behavior_value :: proc(element: Element) -> (value: Value, handled: bool, err: Error) {
	return behavior_value(element)
}

// ---------------------------------------------------------------------------------------------------
// Elements
//
// `make_element` and `clone_element` hand back a reference that is already yours, and an element that
// is created and never unused leaks inside the engine. Inserting it does not consume that reference -
// the document takes its own - so the scoped forms are correct for the build-and-insert shape as well
// as for the element that is thrown away:
//
//	item := sciter_app.scoped_make_element("li", "third") or_return
//	sciter_app.insert_element(item, list) or_return    // the document holds its own reference
//	// the reference that came back here is given up at the end of the scope

// `make_element`, with the reference it hands back released at the end of the calling scope.
@(deferred_out = release_scoped_element)
scoped_make_element :: proc(tag: string, text := "") -> (element: Owned_Element, err: Error) {
	return make_element(tag, text)
}

// `clone_element`, with the reference it hands back released at the end of the calling scope.
@(deferred_out = release_scoped_element)
scoped_clone_element :: proc(element: Element) -> (copy: Owned_Element, err: Error) {
	return clone_element(element)
}

// ---------------------------------------------------------------------------------------------------
// The cleanups. Each takes the whole result tuple of the procedure it is attached to, which is what
// `@(deferred_out)` passes, and each is a no-op on the failure path because a failed call leaves the
// out-value zeroed - and a zeroed Value is a valid undefined one that `value_clear` accepts.

@(private = "file")
release_scoped_value :: proc(result: Value, err: Error) {
	result := result
	value_clear(&result)
}

@(private = "file")
release_scoped_behavior_value :: proc(value: Value, handled: bool, err: Error) {
	value := value
	value_clear(&value)
}

@(private = "file")
release_scoped_element :: proc(element: Owned_Element, err: Error) {
	if err == nil && element != nil {
		unuse_element(element)
	}
}

// ---------------------------------------------------------------------------------------------------
// Constructors
//
// The twins above wrap procedures that *read* a Value out of the engine. These wrap the ones that
// **make** one, which leak in exactly the same way and in a shape that reads even more innocently:
//
//	v := sciter_app.value_from_string("hello")
//	sciter_app.set_global(window, "greeting", &v)     // the engine copies it
//	// ... and the reference `v` still holds is never given back
//
// Every call that hands a Value to the engine - `set_global`, `set_element_value`, an argument to
// `call`, a member of an array being built - copies what it is given, so the caller's Value is still
// the caller's afterwards. `scoped_` is the shape that says so:
//
//	v := sciter_app.scoped_value_from_string("hello")
//	sciter_app.set_global(window, "greeting", &v)     // released at the end of this scope
//
// Only the constructors that own a reference are here. `value_from_bool` and `value_from_int` carry
// their value inline and own nothing, and `value_from_asset` is deliberately absent: the engine does
// not add a reference there - see its doc comment - so there is nothing for a scope to give back.

// `value_from_string`, released at the end of the calling scope.
@(deferred_out = release_scoped_bare_value)
scoped_value_from_string :: proc(s: string, loc := #caller_location) -> (v: Value) {
	return value_from_string(s, loc)
}

// `value_from_bytes`, released at the end of the calling scope. The engine copies the bytes in, so the
// caller's buffer is free to go at once; what the scope gives back is the engine's copy.
@(deferred_out = release_scoped_bare_value)
scoped_value_from_bytes :: proc(b: []u8, loc := #caller_location) -> (v: Value) {
	return value_from_bytes(b, loc)
}

// `value_make_array`, released at the end of the calling scope - and with it every element written into
// it, because clearing a container clears what it holds.
@(deferred_out = release_scoped_bare_value)
scoped_value_make_array :: proc(length: int) -> (v: Value) {
	return value_make_array(length)
}

// `value_from_function`, released at the end of the calling scope.
//
// **Read this one before reaching for it.** The functor's record is freed by the *engine*, once, when
// it drops the Value - so a functor published with `set_global` must outlive the scope that made it,
// and this twin is wrong for that. It is right for the functor handed straight to a call that copies
// it, and for the one built and then abandoned on an error path.
@(deferred_out = release_scoped_bare_value)
scoped_value_from_function :: proc(
	fn: Native_Function,
	user_data: rawptr = nil,
	allocator := context.allocator,
) -> (
	v: Value,
) {
	return value_from_function(fn, user_data, allocator)
}

// `element_to_value`, released at the end of the calling scope. The Value holds its own reference to
// the element, so giving it back is not the same as giving the element back.
@(deferred_out = release_scoped_value)
scoped_element_to_value :: proc(element: Element) -> (v: Value, err: Error) {
	return element_to_value(element)
}

// `node_to_value`, released at the end of the calling scope.
@(deferred_out = release_scoped_value)
scoped_node_to_value :: proc(node: Node) -> (v: Value, err: Error) {
	return node_to_value(node)
}

// `asset_get`, released at the end of the calling scope. A property read off an engine asset owns a
// reference exactly as `value_get` does.
@(deferred_out = release_scoped_value)
scoped_asset_get :: proc(asset: ^sciter.Som_Asset_T, property: string) -> (result: Value, err: Error) {
	return asset_get(asset, property)
}

// `asset_call`, released at the end of the calling scope.
@(deferred_out = release_scoped_value)
scoped_asset_call :: proc(
	asset: ^sciter.Som_Asset_T,
	method: string,
	args: []Value = nil,
	check_arity := true,
) -> (
	result: Value,
	err: Error,
) {
	return asset_call(asset, method, args, check_arity)
}

// The graphics wraps. Each adds a reference to the object it wraps, so clearing the Value leaves the
// `Image` / `Path` / `Text` / `Graphics` usable - these give back the Value's reference and nothing
// else, and the object still needs its own `release_*`.

// `value_from_image`, released at the end of the calling scope.
@(deferred_out = release_scoped_value)
scoped_value_from_image :: proc(image: Image) -> (v: Value, err: Error) {
	return value_from_image(image)
}

// `value_from_path`, released at the end of the calling scope.
@(deferred_out = release_scoped_value)
scoped_value_from_path :: proc(path: Path) -> (v: Value, err: Error) {
	return value_from_path(path)
}

// `value_from_text`, released at the end of the calling scope.
@(deferred_out = release_scoped_value)
scoped_value_from_text :: proc(text: Text) -> (v: Value, err: Error) {
	return value_from_text(text)
}

// `value_from_graphics`, released at the end of the calling scope.
@(deferred_out = release_scoped_value)
scoped_value_from_graphics :: proc(gfx: Graphics) -> (v: Value, err: Error) {
	return value_from_graphics(gfx)
}

@(private = "file")
release_scoped_bare_value :: proc(v: Value) {
	v := v
	value_clear(&v)
}
