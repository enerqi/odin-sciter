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
