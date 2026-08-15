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
// engine, element and node references, taken requests and unanswered delayed ones, graphics objects,
// archives. Each block below
// does the thing an application does and then releases what it took, so a non-zero report at the end is
// a real defect in the wrapper - not in this file's discipline, which is deliberately strict.
//
// Add a block here when a new procedure starts owning something. That is the maintenance cost, and it
// is the same one `docs/parity-baseline.txt` carries for a different question.
package main

import sciter ".."
import "../sciter_app"
import "core:fmt"
import "core:os"
import "core:strings"

DOC :: `<html><head><style>
	#list li { color: #888; }
</style></head><body>
	<ul id="list"><li>one</li><li>two</li><li class="done">three</li></ul>
	<input id="field" type="text" value="typed" />
	<div id="box">boxed</div>
</body></html>`

// The same packed archive `examples/archive.odin` reads, embedded at compile time.
RESOURCES :: #load("assets/app.pak")

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
	sweep_graphics(view.window)
	sweep_scoped(view.window)
	sweep_value_scope(view.window)
	sweep_archive()
	sweep_requests(&view)

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

	when ODIN_DEBUG {
		// "nothing outstanding" is also what a kind nothing touched reports, so the count of *kinds*
		// meant nothing until this loop existed: three of the ten were instrumented and never driven.
		untouched := 0
		released := sciter_app.released_resources()
		for n, kind in released {
			if n == 0 {
				fmt.eprintfln("  ! %v: nothing was released, so this sweep never exercised it", kind)
				untouched += 1
			}
		}
		if untouched != 0 {
			fmt.eprintfln("\nleak sweep: %d resource kind(s) untested - add a block for each", untouched)
			os.exit(1)
		}
		fmt.printfln("leak sweep: clean - %d resource kinds exercised and balanced", len(released))
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
	// Inserting does **not** hand the reference to the document - measured, +400 MB over 2000 nodes if
	// this line is missing. This block used to end here, and the wrapper told the ledger the insert had
	// settled it, so the gate could not have caught that.
	check("node_release (after the insert)", sciter_app.node_release(text))

	comment, cerr := sciter_app.make_comment_node("held, then released")
	check("make_comment_node", cerr)
	check("node_release", sciter_app.node_release(comment))
}

// Images, paths and text are reference counted the same way, with their own release calls.
sweep_graphics :: proc(window: sciter_app.Window) {
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

	// A laid-out text object is the third reference-counted graphics resource, and it needs an element
	// because it is laid out in that element's style.
	root, rerr := sciter_app.root(window)
	check("root", rerr)
	box, berr2 := sciter_app.select_first(root, "#box")
	check("select_first(#box)", berr2)

	text, terr := sciter_app.create_text(box, "measured, then released")
	check("create_text", terr)
	check("retain_text", sciter_app.retain_text(text))
	check("release_text (the retain)", sciter_app.release_text(text))
	if _, merr := sciter_app.text_metrics(text); merr != nil {
		check("text_metrics", merr)
	}
	check("release_text", sciter_app.release_text(text))

	// The graphics state stack is the one obligation here that is not a handle: an unbalanced save
	// aborts the process on the way out of the painter, so the ledger counts the pair. A `Graphics`
	// only exists inside a painter, which is why this rides along on `paint_image`.
	surface, serr2 := sciter_app.create_image(32, 32)
	check("create_image (state stack)", serr2)
	check("paint_image", sciter_app.paint_image(surface, proc(gfx: sciter_app.Graphics, w, h: u32, user: rawptr) {
		if sciter_app.save_state(gfx) != nil {
			return
		}
		sciter_app.scale(gfx, 2, 2)
		sciter_app.restore_state(gfx)
	}, nil))
	check("release_image (state stack)", sciter_app.release_image(surface))
}

// A batch with one lifetime: nothing here is cleared by hand, and the scope gives the lot back.
sweep_value_scope :: proc(window: sciter_app.Window) {
	scope: sciter_app.Value_Scope
	defer sciter_app.scope_destroy(&scope)

	doc, perr := sciter_app.scope_add(&scope, sciter_app.value_parse(`{"a":"one","b":"two"}`))
	check("scope_add(value_parse)", perr)

	for key in ([]string{"a", "b"}) {
		_, gerr := sciter_app.scope_add(&scope, sciter_app.value_get(&doc, key))
		check("scope_add(value_get)", gerr)
	}

	// `scope_release` empties it without giving the list's own memory back, which is what a handler
	// reusing one scope per turn of the pump wants.
	sciter_app.scope_release(&scope)
	if n := sciter_app.scope_len(&scope); n != 0 {
		fmt.eprintfln("  ! scope_release left %d value(s)", n)
		failures += 1
	}

	// And it is usable again afterwards.
	again, aerr := sciter_app.scope_add(&scope, sciter_app.eval(window, `"reused"`))
	check("scope_add after release", aerr)
	_ = again
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

// ---------------------------------------------------------------------------------------------------
// The three kinds the ledger counts that nothing above drives
//
// `Request`, `Archive` and `Delayed_Request` were instrumented in `tracking.odin` and then never
// exercised here, so an imbalance in any of them passed this gate. All three need a load callback or a
// blob rather than a plain call, which is why they were skipped; none of it is hard.

// An archive is the simplest of the three: a blob in, a handle out, one close.
sweep_archive :: proc() {
	resources := RESOURCES
	archive, aerr := sciter_app.open_archive(resources)
	check("open_archive", aerr)

	if _, found := sciter_app.archive_item(archive, "index.htm"); !found {
		fmt.eprintln("  ! archive_item(index.htm): not found - the sweep read nothing")
		failures += 1
	}
	check("close_archive", sciter_app.close_archive(archive))
}

// Requests and delayed answers both live inside `on_load_data`, so they share one handler and one
// document load. The two obligations are opposite in shape:
//
//   - `take_request` keeps a request alive past the callback and owes an `unuse_request`
//   - `.DELAYED` owes a `data_ready_async` carrying the request id
//
// Both are counted by the ledger and neither is visible to the allocator, which is the whole reason
// `tracking.odin` exists.
Sweep_Loader :: struct {
	handler:     sciter_app.Host_Handler,
	window:      sciter_app.Window,
	taken:       sciter_app.Owned_Request,
	delayed_id:  sciter.Hrequest,
	delayed_uri: string,
}

g_sweep_loader: Sweep_Loader

SWEEP_DOC :: `<html><head>
	<link rel="stylesheet" href="sweep://taken.css" />
	<link rel="stylesheet" href="sweep://delayed.css" />
</head><body><p id="t">sweep</p></body></html>`

SWEEP_STYLE :: `#t { color: #00ff00; }`

sweep_requests :: proc(view: ^sciter_app.Windowless_View) {
	g_sweep_loader.window = view.window
	g_sweep_loader.handler = sciter_app.Host_Handler {
		on_load_data = sweep_load_data,
		user_data    = &g_sweep_loader,
	}
	sciter_app.set_host_handler(view.window, &g_sweep_loader.handler)
	defer sciter_app.set_host_handler(view.window, nil)

	check("load_html(sweep)", sciter_app.load_html(view.window, SWEEP_DOC, "sweep://index.htm"))
	sciter_app.windowless_heartbeat(view)

	// The taken request: released here, after the callback that took it has long returned, which is the
	// point of taking it.
	if g_sweep_loader.taken != nil {
		check("unuse_request", sciter_app.unuse_request(g_sweep_loader.taken))
		g_sweep_loader.taken = nil
	} else {
		fmt.eprintln("  ! take_request: nothing was taken, so the request kind was not exercised")
		failures += 1
	}

	// The delayed one: answered exactly once. A second answer on a discharged id segfaults - see
	// `data_ready_async` - so this is the only call there is.
	if g_sweep_loader.delayed_id != nil {
		check(
			"data_ready_async",
			sciter_app.data_ready_async(
				view.window,
				g_sweep_loader.delayed_uri,
				transmute([]u8)string(SWEEP_STYLE),
				g_sweep_loader.delayed_id,
			),
		)
		delete(g_sweep_loader.delayed_uri)
		g_sweep_loader.delayed_uri = ""
		g_sweep_loader.delayed_id = nil
	} else {
		fmt.eprintln("  ! .DELAYED: nothing was delayed, so that kind was not exercised")
		failures += 1
	}

	sciter_app.windowless_heartbeat(view)
}

sweep_load_data :: proc(
	handler: ^sciter_app.Host_Handler,
	request: ^sciter_app.Load_Request,
) -> sciter_app.Load_Result {
	l := (^Sweep_Loader)(handler.user_data)

	switch request.uri {
	case "sweep://taken.css":
		// Taken *and* served: the take is about the handle outliving the callback, not about refusing
		// to answer.
		rq, result := sciter_app.take_request(request)
		l.taken = rq
		if result != .OK {
			return result
		}
		return sciter_app.serve(request, transmute([]u8)string(SWEEP_STYLE))

	case "sweep://delayed.css":
		l.delayed_id = request.raw.requestId
		l.delayed_uri = strings.clone(request.uri)
		return .DELAYED
	}
	return .OK
}
