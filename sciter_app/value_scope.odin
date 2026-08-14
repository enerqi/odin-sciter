// A batch of engine references with one lifetime.
//
// `docs/rules.md` rule 4 already tells you what to do with a batch of *allocations* that die together:
// give them an arena and reset it once. This is the same move for the other half - a batch of `Value`s
// that die together - and the two are meant to be used side by side:
//
//	arena: vmem.Arena
//	_ = vmem.arena_init_growing(&arena)
//	defer vmem.arena_destroy(&arena)          // the Odin memory
//
//	scope: sciter_app.Value_Scope
//	defer sciter_app.scope_release(&scope)    // the engine references
//
// Where `scoped_eval` and its siblings cover the Value that dies at the end of *this* scope,
// this covers the pile that accumulates in a loop, or in a handler that reads a document, or anywhere
// the count is decided at run time rather than written out. `@(deferred_out)` cannot help there: it
// releases at the end of the calling scope, which for a value produced inside a loop body is one
// iteration, not the batch.
//
//	rows := sciter_app.scope_add(&scope, sciter_app.eval(window, "getRows()")) or_return
//	n := sciter_app.value_len(&rows) or_return
//	for i in 0 ..< n {
//		row := sciter_app.scope_add(&scope, sciter_app.value_at(&rows, i)) or_return
//		name := sciter_app.scope_add(&scope, sciter_app.value_get(&row, "name")) or_return
//		// ... no value_clear anywhere ...
//	}
//
// The tracking in `tracking.odin` is the thing that tells you whether you got this right; a scope is
// the thing that makes getting it right cheap.
package sciter_app

import "core:mem"

// Holds Values until the whole batch is released together.
//
// The zero value is ready to use and allocates nothing until the first `scope_add`. It is an ordinary
// struct: put one in a handler, in an application struct, or on the stack.
Value_Scope :: struct {
	values:    [dynamic]Value,

	// Where the *list* comes from - not where the Values' engine memory comes from, which is the
	// engine's business. Left nil to mean `context.allocator` at the first add.
	allocator: mem.Allocator,
}

// Adds a Value to the scope and hands it straight back, so it wraps a producer without changing the
// shape of the call:
//
//	v := sciter_app.scope_add(&scope, sciter_app.eval(window, script)) or_return
//
// The two-result form matches every producer in this package, so `or_return` still works and the error
// is still the caller's to handle. A Value that arrives with an error is added anyway - a failed `eval`
// hands back an error *string* that owns a reference exactly like a successful one (see `eval`), and
// forgetting that is the leak this whole file exists to prevent.
scope_add :: proc(scope: ^Value_Scope, value: Value, err: Error = nil) -> (Value, Error) {
	if scope.values == nil {
		alloc := scope.allocator if scope.allocator.procedure != nil else context.allocator
		scope.values = make([dynamic]Value, alloc)
	}
	append(&scope.values, value)
	return value, err
}

// Clears every Value the scope holds and empties it. The scope stays usable afterwards.
//
// Released in reverse order, for the same reason `defer` unwinds that way: a Value pulled out of a
// container is released before the container it came from.
scope_release :: proc(scope: ^Value_Scope) {
	#reverse for &v in scope.values {
		value_clear(&v)
	}
	clear(&scope.values)
}

// Releases everything and gives the list's own memory back. The scope is a zero value afterwards.
scope_destroy :: proc(scope: ^Value_Scope) {
	scope_release(scope)
	delete(scope.values)
	scope^ = {}
}

// How many Values the scope is holding. Mostly for a test or an assertion.
scope_len :: proc(scope: ^Value_Scope) -> int {
	return len(scope.values)
}
