// The leak gate: exercise the resource-owning paths, then fail if anything is still held.
//
//   just leak-check
//
// **Why this is a program and not a test.** The question "did the whole run leak" can only be asked
// after everything has finished, and an Odin test binary has no hook there: measured, `@(fini)` does
// not run in one, and neither does a libc `atexit` handler, because the runner leaves through
// `os.exit`, which is a direct `exit_group` syscall. A per-test check cannot ask it either - every test
// file shares a process-lifetime window whose document legitimately holds references across tests. So
// the sweep is an ordinary `main`, which controls its own exit and can therefore be a gate.
//
// What it covers is the *resource-owning* half of the API rather than every path: Values out of the
// engine, element and node references, taken requests, graphics objects, archives. Each block below
// does the thing an application does and then releases what it took, so a non-zero report at the end is
// a real defect in the wrapper - not in this file's discipline, which is deliberately strict.
//
// Add a block here when a new procedure starts owning something. That is the maintenance cost, and it
// is the same one `docs/parity-baseline.txt` carries for a different question.
package main

import "../sciter_app"
import "core:fmt"
import "core:os"

DOC :: `<html><head><style>
	#list li { color: #888; }
</style></head><body>
	<ul id="list"><li>one</li><li>two</li><li class="done">three</li></ul>
	<input id="field" type="text" value="typed" />
	<div id="box">boxed</div>
</body></html>`

failures: int

check :: proc(what: string, err: sciter_app.Error, loc := #caller_location) {
	if err != nil {
		fmt.eprintfln("  ! %s: %v  (%v)", what, err, loc)
		failures += 1
	}
}

main :: proc() {
	if !sciter_app.load_engine() {
		fmt.eprintln("the Sciter engine is not loadable - set SCITER_LIB")
		os.exit(1)
	}

	// The ledger has to outlive every scope below, so it is pinned to the default allocator inside
	// `track_resources`. Strict, so an under-flow traps here rather than segfaulting later.
	sciter_app.track_resources(true)

	view, verr := sciter_app.create_windowless({width = 320, height = 240})
	if verr != nil {
		fmt.eprintln("windowless view:", verr)
		os.exit(1)
	}
	check("load_html", sciter_app.load_html(view.window, DOC, "about:blank"))
	sciter_app.windowless_heartbeat(&view)

	sweep_values(view.window)
	sweep_elements(view.window)
	sweep_nodes(view.window)
	sweep_graphics()
	sweep_scoped(view.window)

	// The view's own surface is Odin memory, not an engine resource, but tearing it down here keeps the
	// report about the engine alone.
	sciter_app.destroy_windowless(&view)

	outstanding := sciter_app.report_leaked_resources()
	if outstanding != 0 {
		fmt.eprintfln("\nleak sweep: %d engine resource(s) outstanding - see the list above", outstanding)
		os.exit(1)
	}
	if failures != 0 {
		fmt.eprintfln("\nleak sweep: %d call(s) failed; the leak result above is not trustworthy", failures)
		os.exit(1)
	}

	counts := sciter_app.outstanding_resources()
	when ODIN_DEBUG {
		fmt.printfln("leak sweep: clean - nothing outstanding across %d resource kinds", len(counts))
	} else {
		fmt.println("leak sweep: built without -debug, so the tracker is compiled out and this proved nothing")
		os.exit(1)
	}
}

// Every Value producer that owns a reference, taken and released.
sweep_values :: proc(window: sciter_app.Window) {
	v, err := sciter_app.eval(window, `"a string, which owns engine memory"`)
	check("eval", err)
	sciter_app.value_clear(&v)

	// A failing script hands back an error *string*, which owns a reference just like any other - the
	// case the review found leaking on every script error.
	bad, berr := sciter_app.eval(window, `this is not valid (((`)
	check("eval of a bad script", berr)
	sciter_app.value_clear(&bad)

	doc, perr := sciter_app.value_parse(`{"rows":[1,2,3]}`)
	check("value_parse", perr)
	rows, gerr := sciter_app.value_get(&doc, "rows")
	check("value_get", gerr)
	first, aerr := sciter_app.value_at(&rows, 0)
	check("value_at", aerr)
	sciter_app.value_clear(&first)
	sciter_app.value_clear(&rows)

	// A second reference owes a second clear.
	copy: sciter_app.Value
	check("value_copy", sciter_app.value_copy(&copy, &doc))
	sciter_app.value_clear(&copy)
	sciter_app.value_clear(&doc)

	root, rerr := sciter_app.root(window)
	check("root", rerr)
	field, ferr := sciter_app.select_first(root, "#field")
	check("select_first(#field)", ferr)

	val, verr := sciter_app.element_value(field)
	check("element_value", verr)
	sciter_app.value_clear(&val)

	ex, xerr := sciter_app.expando(field)
	check("expando", xerr)
	sciter_app.value_clear(&ex)

	wrapped, werr := sciter_app.element_to_value(field)
	check("element_to_value", werr)
	sciter_app.value_clear(&wrapped)

	fn := sciter_app.value_from_function(proc(args: []sciter_app.Value, user: rawptr) -> sciter_app.Value {
		return sciter_app.value_from(i32(len(args)))
	})
	sciter_app.value_clear(&fn)
}

// The three ways to come to own an element reference.
sweep_elements :: proc(window: sciter_app.Window) {
	root, rerr := sciter_app.root(window)
	check("root", rerr)
	list, lerr := sciter_app.select_first(root, "#list")
	check("select_first(#list)", lerr)

	// Borrowed handles: nothing is owed for these, and the sweep would notice if the wrapper started
	// taking references behind the caller's back.
	found, serr := sciter_app.select_all(root, "#list li", context.temp_allocator)
	check("select_all", serr)
	if len(found) != 3 {
		fmt.eprintfln("  ! select_all found %d items, expected 3", len(found))
		failures += 1
	}

	// Made, inserted, released - the document keeps its own reference.
	made, merr := sciter_app.make_element("li", "four")
	check("make_element", merr)
	check("insert_element", sciter_app.insert_element(sciter_app.borrow_element(made), list))
	check("unuse_element(made)", sciter_app.unuse_element(made))

	// Cloned and thrown away without ever being inserted.
	cloned, cerr := sciter_app.clone_element(list)
	check("clone_element", cerr)
	check("unuse_element(cloned)", sciter_app.unuse_element(cloned))

	// Explicitly held across a scope, the `use_element` case.
	box, berr := sciter_app.select_first(root, "#box")
	check("select_first(#box)", berr)
	held, uerr := sciter_app.use_element(box)
	check("use_element", uerr)
	check("unuse_element(held)", sciter_app.unuse_element(held))

	// Detached rather than destroyed, which hands back the reference it took.
	victim, verr := sciter_app.child(list, 0)
	check("child", verr)
	detached, rmerr := sciter_app.remove_element(victim, finalize = false)
	check("remove_element(finalize = false)", rmerr)
	check("unuse_element(detached)", sciter_app.unuse_element(detached))
}

// A created node belongs to the caller until it is inserted.
sweep_nodes :: proc(window: sciter_app.Window) {
	root, rerr := sciter_app.root(window)
	check("root", rerr)
	box, berr := sciter_app.select_first(root, "#box")
	check("select_first(#box)", berr)

	target, nerr := sciter_app.node_from_element(box)
	check("node_from_element", nerr)

	text, terr := sciter_app.make_text_node(" appended")
	check("make_text_node", terr)
	check("node_insert", sciter_app.node_insert(target, .APPEND, text))

	// A node the document took over is no longer the caller's to release, so nothing is owed here.
	comment, cerr := sciter_app.make_comment_node("held, then released")
	check("make_comment_node", cerr)
	check("node_release", sciter_app.node_release(comment))
}

// Images, paths and text are reference counted the same way, with their own release calls.
sweep_graphics :: proc() {
	img, ierr := sciter_app.create_image(64, 64)
	check("create_image", ierr)
	check("clear_image", sciter_app.clear_image(img, sciter_app.rgb(0x20, 0x40, 0x80)))

	// A retain owes a second release.
	check("retain_image", sciter_app.retain_image(img))
	check("release_image (the retain)", sciter_app.release_image(img))

	png, serr := sciter_app.save_image(img, .PNG)
	check("save_image", serr)
	delete(png)

	decoded, derr := sciter_app.load_image(png[:0] if len(png) == 0 else png)
	if derr == nil {
		check("release_image (decoded)", sciter_app.release_image(decoded))
	}
	check("release_image", sciter_app.release_image(img))

	path, perr := sciter_app.create_path()
	check("create_path", perr)
	check("path_move_to", sciter_app.path_move_to(path, 0, 0))
	check("path_line_to", sciter_app.path_line_to(path, 10, 10))
	check("release_path", sciter_app.release_path(path))
}

// The scoped forms release on the way out of the scope, so the sweep should see nothing left even
// though nothing here clears anything by hand.
sweep_scoped :: proc(window: sciter_app.Window) {
	{
		v, err := sciter_app.scoped_eval(window, `"scoped"`)
		check("scoped_eval", err)
		_ = v

		// The discarding form, which is the one that leaked before `scoped_` existed.
		_, _ = sciter_app.scoped_eval(window, `"discarded"`)

		doc, perr := sciter_app.scoped_value_parse(`[1,2]`)
		check("scoped_value_parse", perr)
		_ = doc

		item, ierr := sciter_app.scoped_make_element("li", "scoped")
		check("scoped_make_element", ierr)
		_ = item
	}
}
