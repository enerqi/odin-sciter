// Walking the DOM: finding elements, reading and writing their text and attributes.
//
//   just example dom_walk
//   odin test examples/dom_walk.odin -file      # needs a display; skips itself without one
//
// Sciter's DOM is the one from the browser, with the same CSS selector engine behind
// `select_first` / `select_all`. The differences that matter here are about lifetime rather than
// shape: an element handle is a borrowed pointer into the engine's tree, valid while the element is in
// the document. Hold one past that and it dangles - `use_element` / `unuse_element` is the fix, and
// this example points at where it would be needed.
package main

import sciter ".."
import "../sciter_app"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

DOC :: `<html>
<head><style>
  html  { background: #1e1e2e; color: #cdd6f4; font: 16px system; }
  body  { padding: 2em; margin: 0; }
  h1    { color: #89b4fa; margin-top: 0; }
  li    { padding: .15em 0; }
  .done { color: #a6e3a1; }
  .todo { color: #f9e2af; }
  #summary { margin-top: 1em; padding: .6em 1em; background: #313244; border-radius: 4px; }
  #scroller { height: 4em; overflow-y: scroll; margin-top: 1em; background: #313244; }
  #scroller p { margin: 0; padding: .2em .6em; }
</style></head>
<body>
  <h1>dom_walk</h1>
  <ul id="tasks">
    <li class="done" data-id="1">vendor the headers</li>
    <li class="done" data-id="2">generate the bindings</li>
    <li class="todo" data-id="3">write the guides</li>
    <li class="todo" data-id="4">vendor the Windows binary</li>
  </ul>
  <div id="summary">(Odin fills this in)</div>

  <!-- Three elements the node tests need, and which say why they are shaped the way they are.
       #tight is written on one line: no whitespace between the spans, so its node children and its
       element children are the same two. #rich has an inline child, to tell "set the text of a text
       node" apart from "set the text of an element node". #commented carries a comment from the
       source. -->
  <div id="tight"><span>a</span><span>b</span></div>
  <div id="rich">beta <b>bold</b> tail</div>
  <div id="commented">before<!-- from the source -->after</div>

  <div id="scroller">
    <p>one</p><p>two</p><p>three</p><p>four</p>
    <p>five</p><p>six</p><p>seven</p><p>eight</p>
  </div>
</body>
</html>`

main :: proc() {
	if !sciter_app.load_engine() {
		os.exit(1)
	}
	sciter_app.set_default_debug_output()

	if err := sciter_app.init(); err != nil {
		fmt.eprintln("init failed:", err)
		os.exit(1)
	}

	window, werr := sciter_app.create_window({width = 720, height = 480})
	if werr != nil {
		fmt.eprintln("could not create a window:", werr)
		os.exit(1)
	}
	if err := sciter_app.load_html(window, DOC); err != nil {
		fmt.eprintln("could not load the document:", err)
		os.exit(1)
	}

	// Every traversal starts at the document element, <html>.
	root, err := sciter_app.root(window)
	if err != nil {
		fmt.eprintln("no root element:", err)
		os.exit(1)
	}

	// --- reading ------------------------------------------------------------------------------

	// select_all returns a slice the caller owns. The handles in it are borrowed: fine to use right
	// here, not fine to keep past the next time script touches the document.
	items, serr := sciter_app.select_all(root, "#tasks li")
	if serr != nil {
		fmt.eprintln("selector failed:", serr)
		os.exit(1)
	}
	defer delete(items)

	fmt.printfln("%d items:", len(items))

	done_count := 0
	for item in items {
		// Text and attributes both allocate - the engine hands text back as UTF-16 and this is the
		// UTF-8 copy.
		text, _ := sciter_app.text(item, context.temp_allocator)
		id, _ := sciter_app.attribute(item, "data-id", context.temp_allocator)
		class, _ := sciter_app.attribute(item, "class", context.temp_allocator)
		name, _ := sciter_app.tag(item) // borrowed, no allocation

		if class == "done" {
			done_count += 1
		}
		fmt.printfln("  <%s data-id=%q class=%-5q> %s", name, id, class, text)
	}

	// select_first is the same search, stopping at the first hit. `.Not_Found` is a normal answer.
	if _, missing := sciter_app.select_first(root, "#nothing-matches-this"); missing != nil {
		fmt.println("selector for a missing element returned:", missing)
	}

	// --- traversal by hand --------------------------------------------------------------------

	list, _ := sciter_app.select_first(root, "#tasks")
	n, _ := sciter_app.child_count(list)
	first, _ := sciter_app.child(list, 0)
	up, _ := sciter_app.parent(first)
	up_tag, _ := sciter_app.tag(up)
	fmt.printfln("#tasks has %d children; the first one's parent is <%s>", n, up_tag)

	// --- writing --------------------------------------------------------------------------------

	// set_text replaces an element's content with plain text, set_html with markup.
	summary, _ := sciter_app.select_first(root, "#summary")
	line := fmt.tprintf("%d of %d done", done_count, len(items))
	sciter_app.set_text(summary, line)

	// Attributes drive CSS, so writing one restyles the element. This marks the last item done.
	last := items[len(items) - 1]
	sciter_app.set_attribute(last, "class", "done")

	// And markup, to show the difference from set_text.
	sciter_app.set_html(
		summary,
		strings.concatenate({"<b>", line, "</b> &mdash; updated from Odin"}, context.temp_allocator),
	)

	html, _ := sciter_app.html(summary, true, context.temp_allocator)
	fmt.println("#summary is now:", html)

	// --- building elements ----------------------------------------------------------------------
	//
	// The other way round from set_html: make the element, then put it where it goes. This is what
	// content coming from data wants, and the only way to *move* an element rather than re-create it.

	// The reference that comes back is yours and stays yours after the insert, so unuse it either way.
	extra_owned, eerr := sciter_app.make_element("li", "written by Odin, not by markup")
	extra := sciter_app.borrow_element(extra_owned)
	if eerr == nil {
		defer sciter_app.unuse_element(extra_owned)
		sciter_app.set_attribute(extra, "class", "todo")
		sciter_app.insert_element(extra, list) // no index: appended
	}

	// Moving is an insert - the engine disconnects it from its old parent first. Re-creating it would
	// lose whatever state and behaviors it had.
	if moved, merr := sciter_app.child(list, 0); merr == nil {
		sciter_app.insert_element(moved, list, 2)
	}

	// And ordering is done in place, by a comparator that runs before this returns.
	sciter_app.sort_children(list, by_length)

	fmt.println("#tasks after building, moving and sorting:")
	if count, cerr := sciter_app.child_count(list); cerr == nil {
		for i in 0 ..< count {
			item, _ := sciter_app.child(list, i)
			text, _ := sciter_app.text(item, context.temp_allocator)
			fmt.printfln("  %d %s", i, text)
		}
	}

	// --- geometry -------------------------------------------------------------------------------
	//
	// Where layout put things. `location` takes a box and an origin because the C API packs both into
	// one flag word: `.Border` is the painted extent, `.Root` measures from the document.

	box, _ := sciter_app.location(summary, .Border, .Root)
	fmt.printfln("#summary is %dx%d at (%d, %d)", box.width, box.height, box.x, box.y)

	// What the content wants, as opposed to what it was given - the numbers CSS calls min-content and
	// max-content, and the ones a container needs before it can decide how much room to hand out.
	min, max, _ := sciter_app.intrinsic_widths(summary)
	tall, _ := sciter_app.intrinsic_height(summary, min)
	fmt.printfln("#summary wants %d..%dpx wide, and is %dpx tall at its narrowest", min, max, tall)

	// #scroller is 4em tall with eight paragraphs in it, so it is the one thing here that scrolls.
	scroller, _ := sciter_app.select_first(root, "#scroller")
	if info, ierr := sciter_app.scroll_info(scroller); ierr == nil {
		fmt.printfln("#scroller shows %dpx of %dpx, scrolled to %d", info.view.height, info.content.y, info.pos.y)
		sciter_app.set_scroll_pos(scroller, {0, info.content.y}) // clamped to the end
	}

	sciter_app.show(window)
	sciter_app.run()
	sciter_app.shutdown()
}

// Shortest first. The comparator returns the usual negative / zero / positive, and runs on the calling
// thread with the calling context - `sort_children` does not return until it is done.
by_length :: proc(a, b: sciter_app.Element, user_data: rawptr) -> int {
	first, _ := sciter_app.text(a, context.temp_allocator)
	second, _ := sciter_app.text(b, context.temp_allocator)
	return len(first) - len(second)
}

// ---------------------------------------------------------------------------------------------------
// Tests
//
//   odin test examples/dom_walk.odin -file -define:ODIN_TEST_THREADS=1
//
// The thread count is not optional. Sciter is single-threaded - every ISciterAPI call has to come from
// the thread that ran SCITER_APP_INIT - and Odin's test runner is parallel by default, so without it
// these tests corrupt the engine's heap rather than failing cleanly.
//
// A DOM also needs a window, and a window needs a display, so they skip themselves when there is
// neither. The window is created once and reloaded per test; it is never shown.

// **macOS: the engine's AppKit singleton has to be built on the main thread.** Odin's test runner runs
// every test on a `thread.Pool` worker, at any `ODIN_TEST_THREADS` count, and the first engine call
// from one aborts the process in `-[NSApplication setMainMenu:]`. `@(init)` procedures do run on the
// main thread, before the runner starts, so the singleton is built there and every later
// `sciter_app.init()` is a no-op (`g_initialized` in sciter_app/app.odin). Test binaries only: a normal
// build reaches the engine from `main`, which is the main thread by definition. See
// docs/MACOS-CHECKLIST.md section 2.
when ODIN_OS == .Darwin && ODIN_TEST {
	@(private = "file")
	@(init)
	darwin_main_thread_bootstrap :: proc "contextless" () {
		context = runtime.default_context()
		if !sciter_app.load_engine() {
			return
		}
		_ = sciter_app.init()

		// And forget the thread that just armed rule 1. That thread is `main`, every test runs on a
		// `thread.Pool` worker, and the guard would trap each one on its first engine call. The split is
		// real and unavoidable - AppKit wants main for the singleton, the runner wants a worker for the
		// tests - so what re-arming buys is the rest of the rule: the first test call arms the worker,
		// and a later call from anywhere else still traps. docs/MACOS-CHECKLIST.md section 2 has why.
		// The guard's *other* Darwin rule - that the engine's thread is the main thread - turns itself
		// off under `ODIN_TEST`, so it needs nothing here.
		sciter_app.check_thread_affinity()
	}
}

@(private = "file")
have_display :: proc() -> bool {
	when ODIN_OS == .Windows {
		// DISPLAY and WAYLAND_DISPLAY are X11/Wayland variables and are simply absent here, so testing
		// for them would skip every windowed test on this platform forever - silently, which is the
		// worst way for a test to not run. A desktop session is the normal case, and one that genuinely
		// cannot open a window fails visibly at create_window instead.
		return true
	} else when ODIN_OS == .Darwin {
		// **macOS has a display, and a test still cannot use it.** AppKit refuses to instantiate an
		// NSWindow anywhere but the main thread, and Odin's test runner always runs tests on a pool
		// worker - so create_window from a test aborts the whole process with
		//
		//	'NSWindow should only be instantiated on the main thread!'
		//
		// Nothing moves a test onto the main thread, so the windowed tests skip here and this example is
		// covered by being run as a *program* instead. Tests needing no window are unaffected - see
		// docs/MACOS-CHECKLIST.md section 2. `ODIN_TEST` keeps this out of a normal build, where `main`
		// is the main thread and windows are created correctly by construction.
		when ODIN_TEST {
			fmt.println("macOS: a test thread cannot create a window - see docs/MACOS-CHECKLIST.md")
			return false
		} else {
			return true
		}
	} else {
		if os.get_env("DISPLAY", context.temp_allocator) != "" ||
		   os.get_env("WAYLAND_DISPLAY", context.temp_allocator) != "" {
			return true
		}
		fmt.println("no DISPLAY or WAYLAND_DISPLAY")
		return false
	}
}

@(private = "file")
// Shared by every test in this file, and created on first use. That is deliberate - a view per test
// would be slow - but it makes the tests here order-coupled: **a test that changes the document must
// put it back**, usually by reloading `DOC`, or it breaks a later test and the failure points at the
// wrong one.
//
// **A windowless view, not a window, and that is what makes this file run on macOS.** Nothing in these
// tests needs a *window*; they need a laid-out *document*, and `sciter_app/windowless.odin` says the
// difference plainly - four procedures are windowless-specific "and everything else in the package
// works unchanged". A window is the one thing an Odin test on Darwin cannot have, because AppKit
// refuses `NSWindow` off the main thread and the runner never runs a test there. Measured: this file
// skipped 72 of its 74 tests on macOS and now skips none.
//
// It is not free on the other two platforms either - a windowless view needs no display server, so
// these tests no longer depend on `DISPLAY` under Xvfb, and they are faster.
g_view: sciter_app.Windowless_View

@(private = "file")
test_window :: proc(t: ^testing.T) -> (window: sciter_app.Window, ok: bool) {
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}

	// **Not optional on Windows, and the reason is not obvious.** With no host handler installed the
	// engine reports parse errors and script diagnostics through `OutputDebugStringW`, which Windows
	// implements by *raising an exception* (DBG_PRINTEXCEPTION_WIDE_C, 0x4001000A). Odin's test runner
	// installs a handler that treats any exception as fatal to the test, so a CSS warning killed the
	// test that provoked it and every test after it in the file - reported as `Signal caught: Unknown`,
	// which reads like a segfault and is not one. Routing diagnostics to a callback avoids the API
	// entirely. Harmless on Linux, where it just makes the engine's warnings visible.
	sciter_app.set_default_debug_output()

	if g_view.window == nil {
		// The view and its pixel buffer live for the whole process, so they are allocated outside the
		// test runner's tracking allocator - otherwise whichever test happened to create them reports
		// them as a leak. **No `destroy_windowless`** to match: one `SXM_DESTROY` ends windowless mode
		// for the entire process (defect 2 in docs/UPSTREAM-DEFECTS.md), so tearing this down would
		// break every test after it.
		context.allocator = runtime.default_allocator()

		// No `sciter_app.init()`: that stands up the windowed application subsystem, which is exactly
		// what this file no longer needs. On macOS the `@(init)` bootstrap above has already built the
		// engine's singleton on the main thread, which is the one part that cannot be skipped there.
		v, err := sciter_app.create_windowless({width = 400, height = 300})
		testing.expect_value(t, err, nil)
		if v.window == nil {
			return nil, false
		}
		g_view = v
	}

	// Reload, so each test sees the document unmodified by the one before it. `about:blank` for the
	// reason windowless.odin gives: relative references need something to resolve against.
	testing.expect_value(t, sciter_app.load_html(g_view.window, DOC, "about:blank"), nil)

	// **Layout happens on the heartbeat, not on the load.** `location`, `scroll_info` and the popup
	// tests all read geometry, and without this they read zeroes from a document that has never been
	// through a frame. Eight is what `examples/windowless.odin` settles in; a paint per beat is what
	// actually drives layout.
	for i in 0 ..< 8 {
		sciter_app.windowless_heartbeat(&g_view, time.Duration(i) * 16 * time.Millisecond)
		sciter_app.paint_windowless(&g_view)
	}
	return g_view.window, true
}

@(test)
test_select_all_finds_every_item :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, err := sciter_app.root(window)
	testing.expect_value(t, err, nil)

	items, serr := sciter_app.select_all(root, "#tasks li")
	testing.expect_value(t, serr, nil)
	defer delete(items)
	testing.expect_value(t, len(items), 4)

	done, derr := sciter_app.select_all(root, "#tasks li.done")
	testing.expect_value(t, derr, nil)
	defer delete(done)
	testing.expect_value(t, len(done), 2)
}

@(test)
test_select_first_reports_not_found :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)

	found, err := sciter_app.select_first(root, "#tasks li.done")
	testing.expect_value(t, err, nil)
	text, _ := sciter_app.text(found, context.temp_allocator)
	testing.expect_value(t, text, "vendor the headers")

	_, missing := sciter_app.select_first(root, "#no-such-element")
	testing.expect_value(t, missing, sciter_app.Error(sciter_app.Api_Error.Not_Found))
}

@(test)
test_text_and_attribute_round_trip :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	summary, err := sciter_app.select_first(root, "#summary")
	testing.expect_value(t, err, nil)

	testing.expect_value(t, sciter_app.set_text(summary, "written by the test"), nil)
	text, _ := sciter_app.text(summary, context.temp_allocator)
	testing.expect_value(t, text, "written by the test")

	testing.expect_value(t, sciter_app.set_attribute(summary, "data-note", "hello"), nil)
	note, _ := sciter_app.attribute(summary, "data-note", context.temp_allocator)
	testing.expect_value(t, note, "hello")

	// An attribute that was never set reads as "" rather than failing.
	absent, aerr := sciter_app.attribute(summary, "data-missing", context.temp_allocator)
	testing.expect_value(t, aerr, nil)
	testing.expect_value(t, absent, "")
}

@(test)
test_traversal :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	list, _ := sciter_app.select_first(root, "#tasks")

	n, err := sciter_app.child_count(list)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, n, 4)

	first, _ := sciter_app.child(list, 0)
	tag, _ := sciter_app.tag(first)
	testing.expect_value(t, tag, "li")

	up, _ := sciter_app.parent(first)
	up_tag, _ := sciter_app.tag(up)
	testing.expect_value(t, up_tag, "ul")
}

// The node view. Elements are what an application walks; nodes are what the document is actually made
// of, and the two cross over with `node_from_element` / `node_to_element`.
@(test)
test_node_walk :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	item, _ := sciter_app.select_first(root, "li.todo")

	node, err := sciter_app.node_from_element(item)
	testing.expect_value(t, err, nil)

	type, terr := sciter_app.node_type(node)
	testing.expect_value(t, terr, nil)
	testing.expect_value(t, type, sciter.Node_Type.ELEMENT)

	// The <li>'s content is a text node, not an element - which is the whole reason this view exists.
	text_node, ferr := sciter_app.node_first_child(node)
	testing.expect_value(t, ferr, nil)

	text_type, _ := sciter_app.node_type(text_node)
	testing.expect_value(t, text_type, sciter.Node_Type.TEXT)

	content, cerr := sciter_app.node_text(text_node, context.temp_allocator)
	testing.expect_value(t, cerr, nil)
	testing.expect_value(t, content, "write the guides")

	// Back the other way: a text node is not an element, and says so rather than returning nil.
	_, eerr := sciter_app.node_to_element(text_node)
	testing.expect(t, eerr != nil, "a text node must not cast to an element")

	// The parent of a node is always an element.
	parent, perr := sciter_app.node_parent(text_node)
	testing.expect_value(t, perr, nil)
	parent_tag, _ := sciter_app.tag(parent)
	testing.expect_value(t, parent_tag, "li")
}

@(test)
test_node_insert :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	summary, _ := sciter_app.select_first(root, "#summary")

	// A node you made carries a reference, and inserting it does not hand that reference over -
	// measured, and the reason `make_text_node` returns an `Owned_Node`. Insert *and* release.
	created, err := sciter_app.make_text_node(" appended")
	testing.expect_value(t, err, nil)

	target, _ := sciter_app.node_from_element(summary)
	testing.expect_value(t, sciter_app.node_insert(target, .APPEND, created), nil)

	// The element's flattened text now includes what the node carries.
	after, terr := sciter_app.text(summary, context.temp_allocator)
	testing.expect_value(t, terr, nil)
	testing.expect(t, strings.has_suffix(after, " appended"), after)

	// Giving the reference back is not a removal: the document holds its own, so the node stays where
	// it was put. That is the whole shape of the correction - insert *and* release, and the document
	// is unharmed by the release.
	testing.expect_value(t, sciter_app.node_release(created), nil)
	still, serr := sciter_app.text(summary, context.temp_allocator)
	testing.expect_value(t, serr, nil)
	testing.expect(t, strings.has_suffix(still, " appended"), still)
}

// **The first thing the node view surprises people with.** `<ul id="tasks">` is written across five
// lines, so between every pair of `<li>`s there is a text node holding a newline and some indentation.
// The node count is five where the element count is four - and code that indexes `node_child` expecting
// elements picks up whitespace instead.
//
// Which is why the document has `#tight` in it: the same structure written on one line has no
// whitespace nodes at all, so this is a property of the *source text*, not of the DOM.
@(test)
test_node_children_include_the_whitespace_between_the_elements :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	list, _ := sciter_app.select_first(root, "#tasks")
	node, _ := sciter_app.node_from_element(list)

	elements, ecerr := sciter_app.child_count(list)
	testing.expect_value(t, ecerr, nil)
	testing.expect_value(t, elements, 4)

	nodes, ncerr := sciter_app.node_child_count(node)
	testing.expect_value(t, ncerr, nil)
	testing.expect_value(t, nodes, 9) // four <li>, and the newline before, between and after them

	// Odd indices are the elements, even ones the whitespace - but only for this document. Read the
	// type rather than relying on the arithmetic.
	kinds: [dynamic]sciter.Node_Type
	defer delete(kinds)
	for i in 0 ..< nodes {
		child, err := sciter_app.node_child(node, i)
		testing.expect_value(t, err, nil)
		kind, _ := sciter_app.node_type(child)
		append(&kinds, kind)
	}
	testing.expect_value(t, kinds[0], sciter.Node_Type.TEXT)
	testing.expect_value(t, kinds[1], sciter.Node_Type.ELEMENT)
	testing.expect_value(t, kinds[8], sciter.Node_Type.TEXT)

	// The same markup on one line: no whitespace, so the two counts agree.
	tight, terr := sciter_app.select_first(root, "#tight")
	testing.expect_value(t, terr, nil)
	tight_node, _ := sciter_app.node_from_element(tight)
	tight_nodes, _ := sciter_app.node_child_count(tight_node)
	tight_elements, _ := sciter_app.child_count(tight)
	testing.expect_value(t, tight_nodes, 2)
	testing.expect_value(t, tight_elements, 2)
}

// An index past the end is `.INVALID_PARAMETER`, not the `.Not_Found` the rest of the walk uses. The
// difference is deliberate: running off the end of a sibling chain is how a loop finishes, and asking
// for the ninth of three children is a mistake.
@(test)
test_asking_for_a_child_that_is_not_there_is_a_bad_parameter :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	tight, _ := sciter_app.select_first(root, "#tight")
	node, _ := sciter_app.node_from_element(tight)

	count, _ := sciter_app.node_child_count(node)
	_, err := sciter_app.node_child(node, count)
	testing.expect_value(t, err, sciter_app.Error(sciter.Scdom_Result.INVALID_PARAMETER))
}

// The walk terminates on `.Not_Found` at both ends, and a text node is a leaf: no children, and
// `node_last_child` says so rather than answering a nil handle.
@(test)
test_the_node_walk_ends_with_not_found_at_both_ends :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	tight, _ := sciter_app.select_first(root, "#tight")
	node, _ := sciter_app.node_from_element(tight)

	first, ferr := sciter_app.node_first_child(node)
	testing.expect_value(t, ferr, nil)
	last, lerr := sciter_app.node_last_child(node)
	testing.expect_value(t, lerr, nil)
	testing.expect(t, first != last, "#tight has two children, so these are different nodes")

	// Walking back from the end reaches the start, which is what `node_prev_sibling` is for.
	back, berr := sciter_app.node_prev_sibling(last)
	testing.expect_value(t, berr, nil)
	testing.expect_value(t, back, first)

	_, before_first := sciter_app.node_prev_sibling(first)
	testing.expect_value(t, before_first, sciter_app.Error(sciter_app.Api_Error.Not_Found))
	_, after_last := sciter_app.node_next_sibling(last)
	testing.expect_value(t, after_last, sciter_app.Error(sciter_app.Api_Error.Not_Found))

	// A text node is a leaf.
	span_text, _ := sciter_app.node_first_child(first)
	kind, _ := sciter_app.node_type(span_text)
	testing.expect_value(t, kind, sciter.Node_Type.TEXT)

	leaf_count, cerr := sciter_app.node_child_count(span_text)
	testing.expect_value(t, cerr, nil)
	testing.expect_value(t, leaf_count, 0)
	_, lferr := sciter_app.node_last_child(span_text)
	testing.expect_value(t, lferr, sciter_app.Error(sciter_app.Api_Error.Not_Found))
}

// Comments are nodes like any other: they survive being read out of the source, being built in Odin and
// inserted, and a `set_html` round trip. What they do *not* do is show up in the flattened text, which
// is the property that makes them usable as markers in a document.
@(test)
test_comments_are_nodes_that_survive_a_round_trip_but_never_appear_in_the_text :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	host, herr := sciter_app.select_first(root, "#commented")
	testing.expect_value(t, herr, nil)
	node, _ := sciter_app.node_from_element(host)

	// The one that came from the source.
	from_source, serr := sciter_app.node_child(node, 1)
	testing.expect_value(t, serr, nil)
	kind, _ := sciter_app.node_type(from_source)
	testing.expect_value(t, kind, sciter.Node_Type.COMMENT)
	body, _ := sciter_app.node_text(from_source, context.temp_allocator)
	testing.expect_value(t, body, " from the source ")

	// One built here. It is a `.COMMENT` before it is ever inserted - a detached node is a real node.
	made, merr := sciter_app.make_comment_node(" made in Odin ")
	testing.expect_value(t, merr, nil)
	defer testing.expect_value(t, sciter_app.node_release(made), nil)
	made_kind, _ := sciter_app.node_type(sciter_app.borrow_node(made))
	testing.expect_value(t, made_kind, sciter.Node_Type.COMMENT)
	made_text, _ := sciter_app.node_text(sciter_app.borrow_node(made), context.temp_allocator)
	testing.expect_value(t, made_text, " made in Odin ")

	testing.expect_value(t, sciter_app.node_insert(node, .APPEND, made), nil)

	// It is in the markup...
	markup, _ := sciter_app.html(host, false, context.temp_allocator)
	testing.expect(t, strings.contains(markup, "<!-- made in Odin -->"), markup)

	// ...and not in the text, which is the whole point of a comment.
	flat, _ := sciter_app.text(host, context.temp_allocator)
	testing.expect_value(t, flat, "beforeafter")

	// And a comment written into `set_html` comes back as a node rather than being eaten.
	testing.expect_value(t, sciter_app.set_html(host, "x<!--kept-->y"), nil)
	after, _ := sciter_app.node_child_count(node)
	testing.expect_value(t, after, 3)
	middle, _ := sciter_app.node_child(node, 1)
	middle_kind, _ := sciter_app.node_type(middle)
	testing.expect_value(t, middle_kind, sciter.Node_Type.COMMENT)
	middle_text, _ := sciter_app.node_text(middle, context.temp_allocator)
	testing.expect_value(t, middle_text, "kept")
}

// Setting the text of a *text* node edits the words around an inline child and leaves the child alone,
// which is the one thing `set_text(element)` cannot do - it would throw the `<b>` away.
//
// **And on an element node the same call does nothing at all**, silently: `.OK`, and the markup, the
// children and the text all unchanged. It pairs with `node_text`, which reports `""` for an element.
// Both work on the node's own text, and an element has none - so a `node_set_text` that appears to be
// ignored is usually aimed one node too high.
@(test)
test_setting_text_on_a_text_node_spares_its_siblings_and_on_an_element_node_does_nothing :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	rich, rerr := sciter_app.select_first(root, "#rich")
	testing.expect_value(t, rerr, nil)
	node, _ := sciter_app.node_from_element(rich)

	// The text node in front of the <b>.
	leading, lerr := sciter_app.node_first_child(node)
	testing.expect_value(t, lerr, nil)
	testing.expect_value(t, sciter_app.node_set_text(leading, "CHANGED "), nil)

	markup, _ := sciter_app.html(rich, false, context.temp_allocator)
	testing.expectf(t, strings.contains(markup, "<b>"), "the inline child should have survived: %s", markup)
	testing.expect(t, strings.has_prefix(markup, "CHANGED "), markup)

	// The same call on the element's own node: accepted, and ignored.
	before_count, _ := sciter_app.node_child_count(node)
	testing.expect_value(t, sciter_app.node_set_text(node, "flattened"), nil)

	after, _ := sciter_app.html(rich, false, context.temp_allocator)
	testing.expect_value(t, after, markup)
	after_count, _ := sciter_app.node_child_count(node)
	testing.expect_value(t, after_count, before_count)

	// An element node reports no text of its own, which is the same rule read the other way.
	own, oerr := sciter_app.node_text(node, context.temp_allocator)
	testing.expect_value(t, oerr, nil)
	testing.expect_value(t, own, "")

	// `set_text` on the *element* is the call that does replace the content, markup and all.
	testing.expect_value(t, sciter_app.set_text(rich, "via set_text"), nil)
	replaced, _ := sciter_app.html(rich, false, context.temp_allocator)
	testing.expect_value(t, replaced, "via set_text")
}

// **The one that contradicts both the name and the header.** `finalize = false` reads like a detach, and
// a detach ought to be half of a move. It is not: the node comes out of the document and can never go
// back in. Every route was measured - into the old parent, into a new one, relative to a sibling, with
// and without a `node_add_ref` taken beforehand - and every one is `.INVALID_HANDLE`.
//
// The handle is not *dead*, which is what makes this easy to miss: it still reports its type and its
// text. It is only unusable as something to insert.
@(test)
test_a_node_removed_without_finalizing_can_be_read_but_never_reinserted :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	tight, _ := sciter_app.select_first(root, "#tight")
	summary, _ := sciter_app.select_first(root, "#summary")
	parent, _ := sciter_app.node_from_element(tight)
	elsewhere, _ := sciter_app.node_from_element(summary)

	before, _ := sciter_app.node_child_count(parent)
	victim, _ := sciter_app.node_child(parent, 0)
	first_text, _ := sciter_app.node_text(victim, context.temp_allocator)

	// Take a reference first, which is the thing that ought to make this safe. `node_add_ref` is also
	// the only way to get an `Owned_Node` out of a borrowed one, which is what the insertions below
	// need to be spelled at all.
	held, aerr := sciter_app.node_add_ref(victim)
	testing.expect_value(t, aerr, nil)
	testing.expect_value(t, sciter_app.node_remove(victim, finalize = false), nil)

	after, _ := sciter_app.node_child_count(parent)
	testing.expect_value(t, after, before - 1)

	// Still readable.
	kind, kerr := sciter_app.node_type(victim)
	testing.expect_value(t, kerr, nil)
	testing.expect_value(t, kind, sciter.Node_Type.ELEMENT)
	still, terr := sciter_app.node_text(victim, context.temp_allocator)
	testing.expect_value(t, terr, nil)
	testing.expect_value(t, still, first_text)

	// And with no parent, which is the only part that behaves as the name suggests.
	_, perr := sciter_app.node_parent(victim)
	testing.expect_value(t, perr, sciter_app.Error(sciter_app.Api_Error.Not_Found))

	// But not insertable, by any route.
	invalid := sciter_app.Error(sciter.Scdom_Result.INVALID_HANDLE)
	testing.expect_value(t, sciter_app.node_insert(parent, .APPEND, held), invalid)
	testing.expect_value(t, sciter_app.node_insert(elsewhere, .APPEND, held), invalid)
	remaining, _ := sciter_app.node_child(parent, 0)
	testing.expect_value(t, sciter_app.node_insert(remaining, .BEFORE, held), invalid)
	testing.expect_value(t, sciter_app.node_insert(remaining, .AFTER, held), invalid)

	testing.expect_value(t, sciter_app.node_release(held), nil)
}

// The same rule from the other side: a node built here goes into the document once. There is no
// "insert this everywhere" and no implicit clone.
@(test)
test_a_node_can_be_inserted_once_and_never_again :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	tight, _ := sciter_app.select_first(root, "#tight")
	summary, _ := sciter_app.select_first(root, "#summary")
	first, _ := sciter_app.node_from_element(tight)
	second, _ := sciter_app.node_from_element(summary)

	made, err := sciter_app.make_text_node("once")
	testing.expect_value(t, err, nil)
	defer testing.expect_value(t, sciter_app.node_release(made), nil)

	testing.expect_value(t, sciter_app.node_insert(first, .APPEND, made), nil)
	testing.expect_value(
		t,
		sciter_app.node_insert(second, .APPEND, made),
		sciter_app.Error(sciter.Scdom_Result.INVALID_HANDLE),
	)

	// It went to the first one and stayed there.
	a, _ := sciter_app.text(tight, context.temp_allocator)
	b, _ := sciter_app.text(summary, context.temp_allocator)
	testing.expect(t, strings.has_suffix(a, "once"), a)
	testing.expect(t, !strings.contains(b, "once"), b)
}

// `finalize = true` destroys the node, so the handle is gone rather than merely uninsertable. Nothing
// here touches it afterwards, deliberately: that is the free-out-from-under hazard `remove_element` has
// as well, and reading it back would be the bug rather than the test.
@(test)
test_finalizing_a_removed_node_takes_it_out_of_the_document :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	list, _ := sciter_app.select_first(root, "#tasks")
	node, _ := sciter_app.node_from_element(list)

	before, _ := sciter_app.node_child_count(node)
	elements_before, _ := sciter_app.child_count(list)

	victim, _ := sciter_app.node_child(node, 1) // the first <li>
	testing.expect_value(t, sciter_app.node_remove(victim, finalize = true), nil)

	after, _ := sciter_app.node_child_count(node)
	elements_after, _ := sciter_app.child_count(list)
	testing.expect_value(t, after, before - 1)
	testing.expect_value(t, elements_after, elements_before - 1)

	// The document really lost it: the first task's text is not in there any more.
	markup, _ := sciter_app.html(list, false, context.temp_allocator)
	testing.expect(t, !strings.contains(markup, "vendor the headers"), markup)
}

// The reference counting pair, and the one asymmetry in it: a nil handle is `.INVALID_HANDLE` here
// where the rest of the node API answers `.INVALID_PARAMETER`. A detached node - one this code owns
// outright - takes and drops references the same way one in the document does.
@(test)
test_node_references_can_be_taken_and_dropped_on_both_kinds_of_node :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	list, _ := sciter_app.select_first(root, "#tasks")
	node, _ := sciter_app.node_from_element(list)

	// A node in the document. The handle was not AddRef'ed on the way out, so this is what makes it
	// safe to keep past the moment the document might drop it.
	held, aerr := sciter_app.node_add_ref(node)
	testing.expect_value(t, aerr, nil)
	testing.expect_value(t, sciter_app.node_release(held), nil)

	// One this code made and has not inserted. It arrives owing one release; the `node_add_ref` adds a
	// second, so two are owed - and the type says which handle each one is for.
	detached, err := sciter_app.make_text_node("mine")
	testing.expect_value(t, err, nil)
	again, aerr2 := sciter_app.node_add_ref(sciter_app.borrow_node(detached))
	testing.expect_value(t, aerr2, nil)
	testing.expect_value(t, sciter_app.node_release(again), nil)
	testing.expect_value(t, sciter_app.node_release(detached), nil)

	_, nilerr := sciter_app.node_add_ref(nil)
	testing.expect_value(t, nilerr, sciter_app.Error(sciter.Scdom_Result.INVALID_HANDLE))
	testing.expect_value(t, sciter_app.node_release(nil), sciter_app.Error(sciter.Scdom_Result.INVALID_HANDLE))
}

// Everything else in the node API refuses a nil handle rather than dereferencing it. Table-driven
// because the interesting thing is that the whole surface agrees.
@(test)
test_every_node_call_refuses_a_nil_handle :: proc(t: ^testing.T) {
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}

	// **Not optional on Windows, and the reason is not obvious.** With no host handler installed the
	// engine reports parse errors and script diagnostics through `OutputDebugStringW`, which Windows
	// implements by *raising an exception* (DBG_PRINTEXCEPTION_WIDE_C, 0x4001000A). Odin's test runner
	// installs a handler that treats any exception as fatal to the test, so a CSS warning killed the
	// test that provoked it and every test after it in the file - reported as `Signal caught: Unknown`,
	// which reads like a segfault and is not one. Routing diagnostics to a callback avoids the API
	// entirely. Harmless on Linux, where it just makes the engine's warnings visible.
	sciter_app.set_default_debug_output()
	bad := sciter_app.Error(sciter.Scdom_Result.INVALID_PARAMETER)

	_, count_err := sciter_app.node_child_count(nil)
	testing.expect_value(t, count_err, bad)
	_, child_err := sciter_app.node_child(nil, 0)
	testing.expect_value(t, child_err, bad)
	_, first_err := sciter_app.node_first_child(nil)
	testing.expect_value(t, first_err, bad)
	_, last_err := sciter_app.node_last_child(nil)
	testing.expect_value(t, last_err, bad)
	_, next_err := sciter_app.node_next_sibling(nil)
	testing.expect_value(t, next_err, bad)
	_, prev_err := sciter_app.node_prev_sibling(nil)
	testing.expect_value(t, prev_err, bad)
	_, type_err := sciter_app.node_type(nil)
	testing.expect_value(t, type_err, bad)

	testing.expect_value(t, sciter_app.node_set_text(nil, "x"), bad)
	testing.expect_value(t, sciter_app.node_remove(nil), bad)
}

// ---------------------------------------------------------------------------------------------------
// Geometry
//
// These read the result of layout rather than the document, so they need the same window the tests
// above do. `#scroller` is in the document for their benefit: it is 4em tall with eight paragraphs in
// it, so it is the one element here that actually scrolls.

@(test)
test_location_boxes_nest_outwards :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	summary, _ := sciter_app.select_first(root, "#summary")

	content, cerr := sciter_app.location(summary, .Content)
	testing.expect_value(t, cerr, nil)
	padding, _ := sciter_app.location(summary, .Padding)
	border, _ := sciter_app.location(summary, .Border)
	margin, _ := sciter_app.location(summary, .Margin)

	testing.expect(t, content.width > 0 && content.height > 0, "a laid-out element has a box")

	// Each box contains the one before it, which is the whole reason there are four of them.
	nests :: proc(t: ^testing.T, outer, inner: sciter_app.Rect, name: string) {
		testing.expectf(t, outer.x <= inner.x, "%s: left", name)
		testing.expectf(t, outer.y <= inner.y, "%s: top", name)
		testing.expectf(t, outer.x + outer.width >= inner.x + inner.width, "%s: right", name)
		testing.expectf(t, outer.y + outer.height >= inner.y + inner.height, "%s: bottom", name)
	}
	nests(t, padding, content, "padding/content")
	nests(t, border, padding, "border/padding")
	nests(t, margin, border, "margin/border")

	// `#summary` has padding and a margin but no border width, so those two boxes coincide - which is
	// the check that `.Border` is not silently returning the padding box for everything.
	testing.expect_value(t, border, padding)
	testing.expect(t, padding.width > content.width, "padding widens the box")
	testing.expect(t, margin.height > border.height, "the margin is outside the border")
}

@(test)
test_location_origins :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	summary, _ := sciter_app.select_first(root, "#summary")

	from_root, _ := sciter_app.location(summary, .Content, .Root)
	from_self, _ := sciter_app.location(summary, .Content, .Self)
	from_container, _ := sciter_app.location(summary, .Content, .Container)
	from_view, _ := sciter_app.location(summary, .Content, .View)

	// The origin moves the rectangle and never resizes it.
	for other in ([]sciter_app.Rect{from_self, from_container, from_view}) {
		testing.expect_value(t, other.width, from_root.width)
		testing.expect_value(t, other.height, from_root.height)
	}

	// `.Self` is measured from the element's own content origin, so the content box starts at zero
	// there - and an outer box comes back negative, which is how to read a padding or border width.
	testing.expect_value(t, from_self.x, i32(0))
	testing.expect_value(t, from_self.y, i32(0))

	padding_self, _ := sciter_app.location(summary, .Padding, .Self)
	testing.expect(t, padding_self.x < 0 && padding_self.y < 0, "padding extends behind the content origin")

	// `#summary` is not at the top of its container, and the container is not at the top of the
	// document, so these two disagree - a wrapper that ignored the origin would return one rect.
	testing.expect(t, from_root.y != from_container.y, "root and container origins must differ")

	// **`.View` and `.Root` coincide here, and the reason is the interesting part.** `.Root` is the
	// document's root element and `.View` is the client area, so whether anything sits between them is a
	// windowing-system question rather than a DOM one - and these tests now run against a *windowless*
	// view, where there is no window and therefore nothing to sit between.
	//
	// Measured: windowed, the two agree on Windows and differ on Linux (which is what this assertion
	// used to say, and it cost a CI run to find out that it had stopped being true). Windowless, they
	// agree on both - the surface *is* the client area. So the distinction the `.View` origin exists to
	// express is one only a real window can make, which is worth knowing before designing around it.
	testing.expect_value(t, from_view, from_root)
}

// Two collapse rules for out-of-flow elements, both of which have cost this repository a false engine
// defect - because an element with no box is not under the pointer, and every click lands on `<body>`.
// `docs/html-css-js.md` carries them in full; this pins them, so an engine that starts honouring the
// CSS shows up as a failure here rather than as a mystery in the input code.
//
//  1. a percentage *height* on an absolutely positioned element resolves to 1px (the width is fine);
//  2. an inline-level widget - `<button>`, `<input>` - positioned absolutely collapses to 1x1 entirely,
//     and `display: block` is the fix.
@(test)
test_out_of_flow_elements_collapse :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	POSITIONED :: `<html><head><style>
	  html, body { margin:0; padding:0; width:100%; height:100%; }
	  #pct    { position:absolute; left:0; top:0; width:100%; height:100%; }
	  #px     { position:absolute; left:0; top:0; width:100%; height:30px; }
	  #btn    { position:absolute; left:20px; top:80px; width:120px; height:30px; }
	  #btn2   { display:block; position:absolute; left:20px; top:80px; width:120px; height:30px; }
	  #stage  { flow:stack; width:*; height:*; }
	  #over   { width:*; height:*; }
	</style></head><body>
	  <div id="pct">percentage height</div>
	  <div id="px">pixel height</div>
	  <button id="btn">collapsed</button>
	  <button id="btn2">block</button>
	  <div id="stage"><div id="over">stacked overlay</div></div>
	</body></html>`

	testing.expect_value(t, sciter_app.load_html(window, POSITIONED), nil)
	for _ in 0 ..< 10 {
		sciter_app.windowless_heartbeat(&g_view, 16 * time.Millisecond)
	}
	root, rerr := sciter_app.root(window)
	testing.expect_value(t, rerr, nil)

	box :: proc(root: sciter_app.Element, selector: string) -> sciter_app.Rect {
		el, err := sciter_app.select_first(root, selector)
		if err != nil {return {}}
		r, _ := sciter_app.location(el, .Border, .View)
		return r
	}

	// Rule 1: the percentage width resolves and the percentage height does not.
	pct := box(root, "#pct")
	testing.expect(t, pct.width > 100, "a percentage width resolves")
	testing.expectf(t, pct.height == 1, "a percentage height should collapse to 1, got %d", pct.height)

	// A pixel height in the same position is honoured, so it is the percentage that fails.
	px := box(root, "#px")
	testing.expect(t, px.width > 100 && px.height > 20, "a pixel height on the same element is fine")

	// Rule 2: the widget has no box at all until `display: block` puts it back.
	collapsed := box(root, "#btn")
	testing.expectf(
		t,
		collapsed.width == 1 && collapsed.height == 1,
		"a positioned <button> should collapse to 1x1, got %dx%d",
		collapsed.width,
		collapsed.height,
	)
	blocked := box(root, "#btn2")
	testing.expect(t, blocked.width > 100 && blocked.height > 20, "display:block restores the box")

	// And `flow: stack` is the substitute that produces a full-size overlay with neither rule in play.
	overlay := box(root, "#over")
	testing.expect(t, overlay.width > 100 && overlay.height > 100, "a stacked child fills its container")
}

@(test)
test_intrinsic_widths_bracket_the_wrapping :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	summary, _ := sciter_app.select_first(root, "#summary")

	min, max, err := sciter_app.intrinsic_widths(summary)
	testing.expect_value(t, err, nil)
	testing.expect(t, min > 0, "min-content is a real width")
	testing.expect(t, min < max, "text that can wrap has a narrower min than max")

	// Narrower means taller: at min-content the text wraps as hard as it can, at max-content it is on
	// one line. This is the measurement a container makes before deciding what width to hand out.
	tall, terr := sciter_app.intrinsic_height(summary, min)
	testing.expect_value(t, terr, nil)
	short, serr := sciter_app.intrinsic_height(summary, max)
	testing.expect_value(t, serr, nil)

	testing.expect(t, short > 0)
	testing.expectf(t, tall > short, "height at min-content (%d) must exceed height at max-content (%d)", tall, short)
}

@(test)
test_visible_and_enabled :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	summary, _ := sciter_app.select_first(root, "#summary")

	shown, verr := sciter_app.visible(summary)
	testing.expect_value(t, verr, nil)
	testing.expect(t, shown)

	on, eerr := sciter_app.enabled(summary)
	testing.expect_value(t, eerr, nil)
	testing.expect(t, on, "nothing here is disabled")

	// `display: none` removes the box, and that is what `visible` reports. `location` is not the way
	// to ask: it keeps answering with the last box the element had.
	testing.expect_value(t, sciter_app.set_attribute(summary, "style", "display: none"), nil)
	hidden, herr := sciter_app.visible(summary)
	testing.expect_value(t, herr, nil)
	testing.expect(t, !hidden, "display:none has no box")

	// Hidden is not disabled - they are separate questions about the same element.
	still_on, _ := sciter_app.enabled(summary)
	testing.expect(t, still_on)
}

@(test)
test_scroll_info_describes_the_overflow :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	scroller, _ := sciter_app.select_first(root, "#scroller")
	tasks, _ := sciter_app.select_first(root, "#tasks")

	info, err := sciter_app.scroll_info(scroller)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, info.pos, [2]i32{0, 0})
	testing.expect(t, info.view.height > 0)
	testing.expectf(
		t,
		info.content.y > info.view.height,
		"#scroller must overflow: content %v, view %v",
		info.content,
		info.view,
	)

	// A list that fits needs no scrolling, and says so the same way: nothing sticking out of the view.
	fits, ferr := sciter_app.scroll_info(tasks)
	testing.expect_value(t, ferr, nil)
	testing.expect_value(t, fits.pos, [2]i32{0, 0})
	testing.expect(t, fits.content.y <= fits.view.height)
}

@(test)
test_set_scroll_pos_moves_and_clamps :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	scroller, _ := sciter_app.select_first(root, "#scroller")

	testing.expect_value(t, sciter_app.set_scroll_pos(scroller, {0, 30}), nil)
	moved, err := sciter_app.scroll_info(scroller)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, moved.pos, [2]i32{0, 30})

	// Past the end is clamped rather than refused, and clamping twice lands in the same place.
	testing.expect_value(t, sciter_app.set_scroll_pos(scroller, {0, 100_000}), nil)
	clamped, _ := sciter_app.scroll_info(scroller)
	testing.expect_value(t, sciter_app.set_scroll_pos(scroller, {0, 100_000}), nil)
	again, _ := sciter_app.scroll_info(scroller)
	testing.expect_value(t, again.pos, clamped.pos)

	testing.expect(t, clamped.pos.y > 30, "clamped to the end, not to where it already was")
	testing.expectf(
		t,
		clamped.pos.y < clamped.content.y,
		"clamped %v must be inside the content %v",
		clamped.pos,
		clamped.content,
	)
	testing.expect(t, clamped.pos.y >= clamped.content.y - clamped.view.height)

	testing.expect_value(t, sciter_app.set_scroll_pos(scroller, {0, 0}), nil)
	back, _ := sciter_app.scroll_info(scroller)
	testing.expect_value(t, back.pos, [2]i32{0, 0})

	// Scrolling moves what is inside, and which origins notice is the whole point of `Origin`:
	// `.View` and `.Root` are both anchored outside the scrolling element and see it move, while
	// `.Container` is measured from the container's own content origin and does not.
	last, _ := sciter_app.select_first(scroller, "p:last-child")
	view_before := sciter_app.location(last, .Border, .View) or_else {}
	root_before := sciter_app.location(last, .Border, .Root) or_else {}
	container_before := sciter_app.location(last, .Border, .Container) or_else {}

	testing.expect_value(t, sciter_app.set_scroll_pos(scroller, {0, 100_000}), nil)

	view_after := sciter_app.location(last, .Border, .View) or_else {}
	root_after := sciter_app.location(last, .Border, .Root) or_else {}
	container_after := sciter_app.location(last, .Border, .Container) or_else {}

	testing.expectf(t, view_after.y < view_before.y, "view: %v -> %v", view_before, view_after)
	testing.expectf(t, root_after.y < root_before.y, "root: %v -> %v", root_before, root_after)
	testing.expect_value(t, container_after, container_before)

	// The two window origins differ by a fixed offset - where the root element sits in the window -
	// so scrolling moves them by exactly the same amount.
	testing.expect_value(t, view_before.y - view_after.y, root_before.y - root_after.y)
}

// `scroll_to_view` is accepted here but does nothing: measured against this engine, it only moves the
// content once the window has been shown and rendered at least once, and these tests deliberately
// never show a window. What scrolling *does* work headlessly is `set_scroll_pos`, which the test above
// covers - so this one pins down the call and the flags rather than the movement.
//
// With a shown window, `to_top = true` puts the element at the top of the view and the new position is
// readable immediately; the default form asks for the shortest scroll that makes the element visible
// and applies it on the engine's own schedule, so reading the position straight back can still show
// the old one.
@(test)
test_scroll_to_view_is_accepted :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	scroller, _ := sciter_app.select_first(root, "#scroller")
	last, lerr := sciter_app.select_first(scroller, "p:last-child")
	testing.expect_value(t, lerr, nil)

	testing.expect_value(t, sciter_app.scroll_to_view(last), nil)
	testing.expect_value(t, sciter_app.scroll_to_view(last, to_top = true), nil)
	testing.expect_value(t, sciter_app.scroll_to_view(last, smooth = true), nil)
	testing.expect_value(t, sciter_app.scroll_to_view(last, to_top = true, smooth = true), nil)

	// The document element scrolls too, and asking it to scroll itself into view is not an error.
	testing.expect_value(t, sciter_app.scroll_to_view(root), nil)
}

// ---------------------------------------------------------------------------------------------------
// Building and moving elements
//
// `set_html` replaces a subtree with markup; this is the other way round - build the element, then put
// it where it goes. The ownership rule is the one thing to get right and the one thing nothing else
// checks: `make_element` and `clone_element` hand back a reference that stays the caller's even after
// the element is inserted, so every test below unuses what it made.

@(test)
test_make_element_and_insert :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	list, _ := sciter_app.select_first(root, "#tasks")

	before, cerr := sciter_app.child_count(list)
	testing.expect_value(t, cerr, nil)

	item_owned, merr := sciter_app.make_element("li", "fifth")
	item := sciter_app.borrow_element(item_owned)
	testing.expect_value(t, merr, nil)
	testing.expect(t, item != nil)
	defer sciter_app.unuse_element(item_owned)

	// Made, but nowhere: the document does not know about it until it is inserted.
	testing.expect_value(t, sciter_app.child_count(list) or_else -1, before)

	testing.expect_value(t, sciter_app.insert_element(item, list), nil)

	after, _ := sciter_app.child_count(list)
	testing.expect_value(t, after, before + 1)

	// The default index appends, and what came back is the element that was made.
	appended, _ := sciter_app.child(list, after - 1)
	testing.expect_value(t, appended, item)

	tag, _ := sciter_app.tag(item)
	testing.expect_value(t, tag, "li")

	// And it is genuinely in the document, not merely reachable through the handle.
	found, ferr := sciter_app.select_first(root, "#tasks li:last-child")
	testing.expect_value(t, ferr, nil)
	text, _ := sciter_app.text(found, context.temp_allocator)
	testing.expect_value(t, text, "fifth")
}

// The text of a new element is plain text. The C API says the call does no parsing, and it is worth
// pinning: markup arriving from data would otherwise be a way into the document.
@(test)
test_make_element_does_not_parse_its_text :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	list, _ := sciter_app.select_first(root, "#tasks")

	item_owned, _ := sciter_app.make_element("li", "<b>not bold</b>")
	item := sciter_app.borrow_element(item_owned)
	defer sciter_app.unuse_element(item_owned)
	testing.expect_value(t, sciter_app.insert_element(item, list), nil)

	text, _ := sciter_app.text(item, context.temp_allocator)
	testing.expect_value(t, text, "<b>not bold</b>")

	// Nothing was created from it.
	_, berr := sciter_app.select_first(item, "b")
	testing.expect_value(t, berr, sciter_app.Error(sciter_app.Api_Error.Not_Found))
}

@(test)
test_insert_at_an_index :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	list, _ := sciter_app.select_first(root, "#tasks")
	before, _ := sciter_app.child_count(list)

	first_owned, _ := sciter_app.make_element("li", "zeroth")
	first := sciter_app.borrow_element(first_owned)
	defer sciter_app.unuse_element(first_owned)
	testing.expect_value(t, sciter_app.insert_element(first, list, 0), nil)

	at_zero, _ := sciter_app.child(list, 0)
	testing.expect_value(t, at_zero, first)

	// Past the end is not an error - it lands at the end. The largest possible index is the interesting
	// one: handed to the engine as written it segfaults rather than appending, so `insert_element`
	// clamps to the child count and this is the regression test for that. Note that "append" is now
	// spelled `nil` rather than `-1`; an out-of-range *number* still clamps, because the engine's
	// segfault does not care how the caller arrived at it.
	tail_owned, _ := sciter_app.make_element("li", "way past")
	tail := sciter_app.borrow_element(tail_owned)
	defer sciter_app.unuse_element(tail_owned)
	testing.expect_value(t, sciter_app.insert_element(tail, list, max(sciter_app.Child_Index)), nil)

	after, _ := sciter_app.child_count(list)
	testing.expect_value(t, after, before + 2)
	at_end, _ := sciter_app.child(list, after - 1)
	testing.expect_value(t, at_end, tail)

	// A negative index clamps up rather than arriving as `max(u32)`, which is the same segfault from
	// the other end.
	low_owned, _ := sciter_app.make_element("li", "clamped up")
	low := sciter_app.borrow_element(low_owned)
	defer sciter_app.unuse_element(low_owned)
	testing.expect_value(t, sciter_app.insert_element(low, list, -3), nil)
	first_now, _ := sciter_app.child(list, 0)
	testing.expect_value(t, first_now, low)

	// And a moderate over-run behaves the same way.
	spare_owned, _ := sciter_app.make_element("li", "also past")
	spare := sciter_app.borrow_element(spare_owned)
	defer sciter_app.unuse_element(spare_owned)
	testing.expect_value(t, sciter_app.insert_element(spare, list, 9999), nil)
	count, _ := sciter_app.child_count(list)
	last_now, _ := sciter_app.child(list, count - 1)
	testing.expect_value(t, last_now, spare)
}

// Inserting an element that already has a parent moves it. Re-creating it instead would lose whatever
// state and behaviors it had picked up, so this is the operation to reach for.
@(test)
test_insert_moves_an_element_that_already_has_a_parent :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	list, _ := sciter_app.select_first(root, "#tasks")
	summary, _ := sciter_app.select_first(root, "#summary")

	moving, _ := sciter_app.child(list, 0)
	text_before, _ := sciter_app.text(moving, context.temp_allocator)
	list_before, _ := sciter_app.child_count(list)
	summary_before, _ := sciter_app.child_count(summary)

	testing.expect_value(t, sciter_app.insert_element(moving, summary), nil)

	list_after, _ := sciter_app.child_count(list)
	summary_after, _ := sciter_app.child_count(summary)
	testing.expect_value(t, list_after, list_before - 1)
	testing.expect_value(t, summary_after, summary_before + 1)

	// The same element, not a copy of it: same handle, same content, new parent.
	parent, perr := sciter_app.parent(moving)
	testing.expect_value(t, perr, nil)
	testing.expect_value(t, parent, summary)

	text_after, _ := sciter_app.text(moving, context.temp_allocator)
	testing.expect_value(t, text_after, text_before)
}

@(test)
test_clone_is_a_detached_deep_copy :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	list, _ := sciter_app.select_first(root, "#tasks")
	original_count, _ := sciter_app.child_count(list)

	copy_owned, cerr := sciter_app.clone_element(list)
	copy := sciter_app.borrow_element(copy_owned)
	testing.expect_value(t, cerr, nil)
	defer sciter_app.unuse_element(copy_owned)

	testing.expect(t, copy != list, "a clone is a different element")

	// Deep: the children came with it, and they read the same.
	copy_count, _ := sciter_app.child_count(copy)
	testing.expect_value(t, copy_count, original_count)

	copy_first, _ := sciter_app.child(copy, 0)
	copied_text, _ := sciter_app.text(copy_first, context.temp_allocator)
	testing.expect_value(t, copied_text, "vendor the headers")

	// In no document until it is put in one, and then it is a second list.
	body, _ := sciter_app.select_first(root, "body")
	testing.expect_value(t, sciter_app.insert_element(copy, body), nil)

	lists, lerr := sciter_app.select_all(root, "ul")
	testing.expect_value(t, lerr, nil)
	defer delete(lists)
	testing.expect_value(t, len(lists), 2)

	// Independent: writing to the copy leaves the original alone, which is the whole point of a copy
	// rather than a second handle to the same element.
	testing.expect_value(t, sciter_app.set_text(copy_first, "changed in the copy"), nil)

	original_first, _ := sciter_app.child(list, 0)
	original_text, _ := sciter_app.text(original_first, context.temp_allocator)
	testing.expect_value(t, original_text, "vendor the headers")
}

// What a detached element can and cannot do, all of it measured. The short version: build a subtree
// out of elements you made, and do the markup and the editing once it is in the document.
@(test)
test_what_a_detached_element_allows :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	list, _ := sciter_app.select_first(root, "#tasks")

	// Assembling a subtree offline works: `insert_element` is happy with two detached elements, and
	// inserting the outer one brings the whole thing in.
	outer_owned, _ := sciter_app.make_element("div", "")
	outer := sciter_app.borrow_element(outer_owned)
	defer sciter_app.unuse_element(outer_owned)
	inner_owned, _ := sciter_app.make_element("span", "inner")
	inner := sciter_app.borrow_element(inner_owned)
	defer sciter_app.unuse_element(inner_owned)

	testing.expect_value(t, sciter_app.insert_element(inner, outer), nil)
	testing.expect_value(t, sciter_app.child_count(outer) or_else -1, 1)

	testing.expect_value(t, sciter_app.insert_element(outer, list), nil)
	html, _ := sciter_app.html(outer, true, context.temp_allocator)
	testing.expect_value(t, html, "<div><span>inner</span></div>")

	// Markup does not: `set_html` needs a document, and says so with INVALID_HWND rather than quietly
	// doing nothing. Insert first, then set the markup.
	orphan_owned, _ := sciter_app.make_element("li", "")
	orphan := sciter_app.borrow_element(orphan_owned)
	defer sciter_app.unuse_element(orphan_owned)
	testing.expect_value(
		t,
		sciter_app.set_html(orphan, "<b>bold</b>"),
		sciter_app.Error(sciter.Scdom_Result.INVALID_HWND),
	)
	testing.expect_value(t, sciter_app.child_count(orphan) or_else -1, 0)

	testing.expect_value(t, sciter_app.insert_element(orphan, list), nil)
	testing.expect_value(t, sciter_app.set_html(orphan, "<b>bold</b>"), nil)
	testing.expect_value(t, sciter_app.child_count(orphan) or_else -1, 1)

	// And a detached element's *descendants* are passive handles: readable, not writable, and
	// `use_element` does not change that. The element you hold a reference to is writable - it is the
	// tree underneath it that is not.
	copy_owned, _ := sciter_app.clone_element(list)
	copy := sciter_app.borrow_element(copy_owned)
	defer sciter_app.unuse_element(copy_owned)

	child, _ := sciter_app.child(copy, 0)
	readable, rerr := sciter_app.text(child, context.temp_allocator)
	testing.expect_value(t, rerr, nil)
	testing.expect(t, readable != "", "a detached element's children are readable")

	testing.expect_value(t, sciter_app.set_text(child, "nope"), sciter_app.Error(sciter.Scdom_Result.PASSIVE_HANDLE))
	held, uerr := sciter_app.use_element(child)
	testing.expect_value(t, uerr, nil)
	testing.expect_value(
		t,
		sciter_app.set_text(child, "still nope"),
		sciter_app.Error(sciter.Scdom_Result.PASSIVE_HANDLE),
	)
	testing.expect_value(t, sciter_app.unuse_element(held), nil)

	// The clone itself, though, takes an attribute while detached.
	testing.expect_value(t, sciter_app.set_attribute(copy, "id", "clone"), nil)
}

@(test)
test_remove_element_destroys_or_detaches :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	list, _ := sciter_app.select_first(root, "#tasks")
	summary, _ := sciter_app.select_first(root, "#summary")
	before, _ := sciter_app.child_count(list)

	// finalize = true: gone, and the handle with it.
	doomed, _ := sciter_app.child(list, 0)
	// `finalize = true` hands back no handle - there is nothing left to hold.
	gone, derr := sciter_app.remove_element(doomed)
	testing.expect_value(t, derr, nil)
	testing.expect_value(t, gone, nil)
	testing.expect_value(t, sciter_app.child_count(list) or_else -1, before - 1)

	// finalize = false: out of the document but still alive, holding the reference this call took on
	// the caller's behalf. Without that reference the handle would be dangling here, and reading it
	// would be a segfault rather than an error - which is why the wrapper takes it.
	found, _ := sciter_app.child(list, 0)
	text_before, _ := sciter_app.text(found, context.temp_allocator)
	// The reference this call takes comes back as the result, which is what makes the release below
	// type-check: `unuse_element` accepts only a handle somebody was given ownership of.
	detached_owned, rmerr := sciter_app.remove_element(found, finalize = false)
	testing.expect_value(t, rmerr, nil)
	detached := sciter_app.borrow_element(detached_owned)
	testing.expect_value(t, sciter_app.child_count(list) or_else -1, before - 2)

	still_there, rerr := sciter_app.text(detached, context.temp_allocator)
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, still_there, text_before)

	// And it goes back into the document somewhere else, content intact. That is the move.
	testing.expect_value(t, sciter_app.insert_element(detached, summary), nil)
	parent, _ := sciter_app.parent(detached)
	testing.expect_value(t, parent, summary)

	text_after, _ := sciter_app.text(detached, context.temp_allocator)
	testing.expect_value(t, text_after, text_before)

	// The reference is the caller's either way.
	testing.expect_value(t, sciter_app.unuse_element(detached_owned), nil)
}

@(test)
test_swap_elements :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	list, _ := sciter_app.select_first(root, "#tasks")

	first, _ := sciter_app.child(list, 0)
	last, _ := sciter_app.child(list, 3)
	first_text, _ := sciter_app.text(first, context.temp_allocator)
	last_text, _ := sciter_app.text(last, context.temp_allocator)

	testing.expect_value(t, sciter_app.swap_elements(first, last), nil)

	now_first, _ := sciter_app.child(list, 0)
	now_last, _ := sciter_app.child(list, 3)
	testing.expect_value(t, now_first, last)
	testing.expect_value(t, now_last, first)

	// The elements moved, not their contents.
	a, _ := sciter_app.text(now_first, context.temp_allocator)
	b, _ := sciter_app.text(now_last, context.temp_allocator)
	testing.expect_value(t, a, last_text)
	testing.expect_value(t, b, first_text)
}

@(private = "file")
Sort_State :: struct {
	calls:      int,
	user_index: int, // context.user_index as seen from inside the comparator
}

@(private = "file")
by_text_descending :: proc(a, b: sciter_app.Element, user_data: rawptr) -> int {
	state := (^Sort_State)(user_data)
	state.calls += 1
	state.user_index = context.user_index

	first, _ := sciter_app.text(a, context.temp_allocator)
	second, _ := sciter_app.text(b, context.temp_allocator)
	return strings.compare(second, first)
}

@(test)
test_sort_children :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	SENTINEL :: 0x5027

	root, _ := sciter_app.root(window)
	list, _ := sciter_app.select_first(root, "#tasks")

	state: Sort_State
	{
		// The comparator runs on this thread before `sort_children` returns, so it runs on this
		// context - the sentinel is how that is checked rather than assumed.
		context.user_index = SENTINEL
		testing.expect_value(t, sciter_app.sort_children(list, by_text_descending, &state), nil)
	}

	testing.expect(t, state.calls > 0, "the comparator must be called")
	testing.expect_value(t, state.user_index, SENTINEL)

	texts := make([dynamic]string, 0, 4, context.temp_allocator)
	n, _ := sciter_app.child_count(list)
	for i in 0 ..< n {
		item, _ := sciter_app.child(list, i)
		text, _ := sciter_app.text(item, context.temp_allocator)
		append(&texts, text)
	}

	testing.expect_value(t, len(texts), 4)
	for i in 1 ..< len(texts) {
		testing.expectf(t, texts[i - 1] >= texts[i], "not descending: %v", texts[:])
	}

	// A range sorts only that range: `last` is one past the end, so this leaves the tail alone. The
	// reload starts from the document's own order again - and every handle from before it, `root`
	// included, is dead the moment it happens.
	testing.expect_value(t, sciter_app.load_html(window, DOC), nil)
	reloaded_root, rerr := sciter_app.root(window)
	testing.expect_value(t, rerr, nil)
	list2, _ := sciter_app.select_first(reloaded_root, "#tasks")
	untouched_before, _ := sciter_app.child(list2, 3)
	tail_text_before, _ := sciter_app.text(untouched_before, context.temp_allocator)

	partial: Sort_State
	testing.expect_value(t, sciter_app.sort_children(list2, by_text_descending, &partial, 0, 3), nil)

	untouched_after, _ := sciter_app.child(list2, 3)
	tail_text_after, _ := sciter_app.text(untouched_after, context.temp_allocator)
	testing.expect_value(t, tail_text_after, tail_text_before)

	// An empty range is not a failure, and the comparator is never called for it.
	empty: Sort_State
	testing.expect_value(t, sciter_app.sort_children(list2, by_text_descending, &empty, 2, 2), nil)
	testing.expect_value(t, empty.calls, 0)

	// A nil comparator is refused rather than crashing in the engine.
	testing.expect_value(
		t,
		sciter_app.sort_children(list, nil),
		sciter_app.Error(sciter.Scdom_Result.INVALID_PARAMETER),
	)

	// A negative `first` is clamped, not passed on. `Child_Index` is signed and the engine's parameter
	// is not, so an unclamped -1 arrives as max(u32) - which `insert_element` documents as a segfault
	// inside the engine. `-1` is not exotic: it is `element_index - 1` on a first child, and it is what
	// `insert_element` itself takes as "at the end".
	from_negative: Sort_State
	testing.expect_value(t, sciter_app.sort_children(list2, by_text_descending, &from_negative, -1), nil)
	testing.expect(t, from_negative.calls > 0, "a clamped -1 sorts from the first child")

	// The same on the other end: `last` past the end is the count, not an out-of-range read.
	past_end: Sort_State
	testing.expect_value(t, sciter_app.sort_children(list2, by_text_descending, &past_end, 0, 999), nil)
	testing.expect(t, past_end.calls > 0, "a clamped `last` sorts to the last child")
}

// `SciterGetElementUID` works everywhere. **`SciterGetElementByUID` resolves what it produces on
// Windows and does not on Linux**, and that asymmetry is the whole of this test.
//
// On the vendored Linux build every combination fails with OPERATION_FAILED - the element's own window
// handle and the root one, an element that has been `use_element`ed and one that has not, a freshly made
// element and the document root. On Windows, measured on the same engine version, the round trip is
// exact: `element_by_uid(element_uid(e))` is `e`, for each of two elements, while an invented UID still
// fails. The UIDs are the same shape on both - near the top of the u32 range, 0xFFFFFC11 and neighbours -
// so this is the lookup being broken on one platform rather than two numbering schemes.
//
// Practically: **a UID is a within-process handle you can round-trip on Windows and cannot on Linux.**
// Do not build anything portable on it. If the Linux half ever starts working, this test fails and the
// signal is to delete the guard, not to hunt a regression.
@(test)
test_element_uid_is_readable_and_resolvable_only_on_windows :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	summary, _ := sciter_app.select_first(root, "#summary")

	uid, uerr := sciter_app.element_uid(summary)
	testing.expect_value(t, uerr, nil)
	testing.expect(t, uid != 0, "a UID identifies the element")

	// Two elements are two UIDs, so the numbers do mean something.
	other, _ := sciter_app.select_first(root, "#tasks")
	other_uid, oerr := sciter_app.element_uid(other)
	testing.expect_value(t, oerr, nil)
	testing.expect(t, other_uid != uid)

	back, berr := sciter_app.element_by_uid(window, uid)
	when ODIN_OS == .Windows {
		testing.expect_value(t, berr, nil)
		testing.expect_value(t, back, summary)

		back_other, boerr := sciter_app.element_by_uid(window, other_uid)
		testing.expect_value(t, boerr, nil)
		testing.expect_value(t, back_other, other)
	} else {
		// The lookup refuses a UID this engine just handed out.
		testing.expect_value(t, berr, sciter_app.Error(sciter.Scdom_Result.OPERATION_FAILED))
		testing.expect_value(t, back, sciter_app.Element(nil))
	}

	// An invented one fails on both, which is why the Linux failure above is not a diagnosis.
	_, missing := sciter_app.element_by_uid(window, 0xFFFF_FFF0)
	testing.expect(t, missing != nil)
}

// ---------------------------------------------------------------------------------------------------
// Attributes, style, and elements as Values
//
// The three that cross a boundary the rest of this file stays inside: enumerating what is written on an
// element rather than asking for a name you already knew, reaching the style store rather than the
// attribute store, and putting an element into a Value so script can be handed it.

@(test)
test_attributes_enumerate_in_markup_order :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	first, _ := sciter_app.select_first(root, "#tasks li")

	n, nerr := sciter_app.attribute_count(first)
	testing.expect_value(t, nerr, nil)
	testing.expect_value(t, n, 2)

	attrs, err := sciter_app.attributes(first, context.temp_allocator)
	testing.expect_value(t, err, nil)
	defer sciter_app.delete_attributes(attrs, context.temp_allocator)
	testing.expect_value(t, len(attrs), 2)

	// Markup order, not alphabetical and not the order the engine happens to store them in.
	testing.expect_value(t, attrs[0].name, "class")
	testing.expect_value(t, attrs[0].value, "done")
	testing.expect_value(t, attrs[1].name, "data-id")
	testing.expect_value(t, attrs[1].value, "1")

	// Whatever the enumeration says, the by-name lookup must agree with it.
	for a in attrs {
		by_name, aerr := sciter_app.attribute(first, a.name, context.temp_allocator)
		testing.expect_value(t, aerr, nil)
		testing.expect_value(t, by_name, a.value)
	}

	// One past the end is an error rather than an empty attribute, which is the difference between
	// "there is nothing there" and "you asked wrongly".
	_, oob := sciter_app.attribute_at(first, n, context.temp_allocator)
	testing.expect_value(t, oob, sciter_app.Error(sciter.Scdom_Result.INVALID_PARAMETER))
}

@(test)
test_attributes_track_writes :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	summary, _ := sciter_app.select_first(root, "#summary")

	before, _ := sciter_app.attribute_count(summary)
	testing.expect_value(t, before, 1) // id="summary"

	testing.expect_value(t, sciter_app.set_attribute(summary, "data-added", "yes"), nil)
	after, _ := sciter_app.attribute_count(summary)
	testing.expect_value(t, after, 2)

	// `set_attribute(el, name, "")` removes, so the count goes back down rather than gaining an
	// empty one.
	testing.expect_value(t, sciter_app.set_attribute(summary, "data-added", ""), nil)
	removed, _ := sciter_app.attribute_count(summary)
	testing.expect_value(t, removed, before)

	// An element with nothing on it reports no attributes and an empty slice, not a failure.
	bare_owned, berr := sciter_app.make_element("span", "bare")
	bare := sciter_app.borrow_element(bare_owned)
	testing.expect_value(t, berr, nil)
	defer sciter_app.unuse_element(bare_owned)

	none, cerr := sciter_app.attribute_count(bare)
	testing.expect_value(t, cerr, nil)
	testing.expect_value(t, none, 0)

	empty, eerr := sciter_app.attributes(bare, context.temp_allocator)
	testing.expect_value(t, eerr, nil)
	testing.expect_value(t, len(empty), 0)
}

@(test)
test_clear_attributes_takes_the_styling_with_it :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	first, _ := sciter_app.select_first(root, "#tasks li")

	// `.done` is what colours it, and `class` is what matches that rule.
	coloured, _ := sciter_app.style(first, "color", context.temp_allocator)
	testing.expect_value(t, coloured, "#A6E3A1")

	testing.expect_value(t, sciter_app.clear_attributes(first), nil)

	n, err := sciter_app.attribute_count(first)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, n, 0)

	gone, _ := sciter_app.attribute(first, "class", context.temp_allocator)
	testing.expect_value(t, gone, "")

	// The element is still there and still an `li`; it is the cascade that changed.
	tag, terr := sciter_app.tag(first)
	testing.expect_value(t, terr, nil)
	testing.expect_value(t, tag, "li")

	// ...but the *style* is still the old one, because the cascade has not been re-run. Reading style
	// reads a stored answer, and clearing attributes does not by itself invalidate it.
	stale, _ := sciter_app.style(first, "color", context.temp_allocator)
	testing.expect_value(t, stale, coloured)

	// Forcing the update is what re-resolves it - down to what `html` gives every element, since
	// nothing matches this `li` any more. There is no wrapper for it; the raw table is the way, and
	// mixing the two is expected.
	sciter.api().SciterUpdateElement(sciter.Helement(first), true)
	restyled, _ := sciter_app.style(first, "color", context.temp_allocator)
	testing.expect_value(t, restyled, "#CDD6F4")

	// Writing an attribute, on the other hand, re-runs the cascade on its own.
	testing.expect_value(t, sciter_app.set_attribute(first, "class", "todo"), nil)
	rematched, _ := sciter_app.style(first, "color", context.temp_allocator)
	testing.expect_value(t, rematched, "#F9E2AF")
}

@(test)
test_style_reads_the_used_value :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	first, _ := sciter_app.select_first(root, "#tasks li")

	// Nothing is inline here: this comes from `.done { color: #a6e3a1; }` in the stylesheet, resolved
	// and upper-cased by the engine. Reading style is reading the cascade's answer, not the markup.
	from_sheet, err := sciter_app.style(first, "color", context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, from_sheet, "#A6E3A1")

	// A property nothing set, and a property that does not exist, read the same: "".
	unset, uerr := sciter_app.style(first, "width", context.temp_allocator)
	testing.expect_value(t, uerr, nil)
	testing.expect_value(t, unset, "")

	nonsense, nerr := sciter_app.style(first, "no-such-property", context.temp_allocator)
	testing.expect_value(t, nerr, nil)
	testing.expect_value(t, nonsense, "")
}

@(test)
test_set_style_overrides_and_reverts :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	first, _ := sciter_app.select_first(root, "#tasks li")

	testing.expect_value(t, sciter_app.set_style(first, "color", "blue"), nil)

	// Inline beats the stylesheet, and comes back as it was written rather than resolved - the
	// resolution above was the stylesheet's, not the reader's.
	//
	// (Named `inline_value` rather than `inline`: `inline` is a keyword, and while the compiler accepts
	// it as an identifier here, `odinfmt` does not - it failed to parse this file, so `just format`
	// exited non-zero on a repository that was otherwise clean.)
	inline_value, err := sciter_app.style(first, "color", context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, inline_value, "blue")

	// The style store and the `style` *attribute* are two different places. Writing one does not
	// show up in the other, which is the trap this test exists to pin.
	attr, aerr := sciter_app.attribute(first, "style", context.temp_allocator)
	testing.expect_value(t, aerr, nil)
	testing.expect_value(t, attr, "")

	// "" removes the inline property, and the cascade's answer comes back.
	testing.expect_value(t, sciter_app.set_style(first, "color", ""), nil)
	reverted, _ := sciter_app.style(first, "color", context.temp_allocator)
	testing.expect_value(t, reverted, "#A6E3A1")

	// An unknown property is accepted and ignored - the engine has no way to say "no such rule".
	testing.expect_value(t, sciter_app.set_style(first, "no-such-property", "1"), nil)
}

@(test)
test_element_value_round_trip :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	summary, _ := sciter_app.select_first(root, "#summary")

	v, err := sciter_app.element_to_value(summary)
	testing.expect_value(t, err, nil)
	defer sciter_app.value_clear(&v)

	// A wrapped element is a RESOURCE, and renders as nothing - so this is one of the few Values that
	// `value_to_display_string` cannot be used to look at.
	type, _ := sciter_app.value_type(&v)
	testing.expect_value(t, type, sciter.Value_Type.RESOURCE)

	back, berr := sciter_app.element_from_value(&v)
	testing.expect_value(t, berr, nil)
	testing.expect_value(t, back, summary)

	// A Value holding anything else is a failure rather than a null handle.
	n := sciter_app.value_from(i32(3))
	defer sciter_app.value_clear(&n)
	_, wrong := sciter_app.element_from_value(&n)
	testing.expect_value(t, wrong, sciter_app.Error(sciter.Scdom_Result.OPERATION_FAILED))
}

// The Value's reference is its own: the element outlives the caller's `use_element` reference for as
// long as a Value wraps it. Made rather than found, because a found element is kept alive by its
// document and would prove nothing.
@(test)
test_element_value_holds_a_reference :: proc(t: ^testing.T) {
	_, ok := test_window(t)
	if !ok {return}

	made_owned, merr := sciter_app.make_element("p", "made")
	made := sciter_app.borrow_element(made_owned)
	testing.expect_value(t, merr, nil)

	v, err := sciter_app.element_to_value(made)
	testing.expect_value(t, err, nil)
	defer sciter_app.value_clear(&v)

	// The only reference the caller had, given back. The handle is dead from here - touching it is a
	// use-after-free, not an error code - so everything below goes through the Value.
	testing.expect_value(t, sciter_app.unuse_element(made_owned), nil)

	// Churn the engine's allocator, so a surviving element is a surviving element rather than memory
	// that has not been reused yet.
	for _ in 0 ..< 500 {
		junk_owned, _ := sciter_app.make_element("span", "junk junk junk junk junk")
		sciter_app.unuse_element(junk_owned)
	}

	alive, aerr := sciter_app.element_from_value(&v)
	testing.expect_value(t, aerr, nil)

	tag, terr := sciter_app.tag(alive)
	testing.expect_value(t, terr, nil)
	testing.expect_value(t, tag, "p")
}

// Both directions across the script boundary: script hands Odin an element as an argument, and Odin
// hands one back as a return value. This is what `element_to_value` is for - without it neither
// signature can mention an element at all.
@(private = "file")
Boundary_State :: struct {
	root:     sciter_app.Element,
	seen_tag: string,
	seen_id:  string,
}

@(private = "file")
took_an_element :: proc(args: []sciter_app.Value, user_data: rawptr) -> sciter_app.Value {
	state := (^Boundary_State)(user_data)
	if len(args) != 1 {
		return sciter_app.value_from(false)
	}

	el, err := sciter_app.element_from_value(&args[0])
	if err != nil {
		return sciter_app.value_from(false)
	}
	// `tag` is a borrow of the engine's own storage. The attribute is a copy, and **it must not be a
	// temp one**: this runs inside an engine callback, and the package restores
	// `context.temp_allocator` to the mark it had on the way in - so a temp string read after the
	// callback is whatever landed in that memory next. The test frees this one.
	state.seen_tag, _ = sciter_app.tag(el)
	state.seen_id, _ = sciter_app.attribute(el, "id")
	return sciter_app.value_from(true)
}

@(private = "file")
returns_an_element :: proc(args: []sciter_app.Value, user_data: rawptr) -> sciter_app.Value {
	state := (^Boundary_State)(user_data)
	el, err := sciter_app.select_first(state.root, "#tasks")
	if err != nil {
		return sciter_app.value_from(false)
	}
	// The engine takes ownership of the returned Value's reference, so this one is not cleared here.
	v, verr := sciter_app.element_to_value(el)
	if verr != nil {
		return sciter_app.value_from(false)
	}
	return v
}

@(test)
test_elements_cross_the_script_boundary :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	state := Boundary_State {
		root = root,
	}
	defer delete(state.seen_id) // `took_an_element` allocates it; see the note there

	// Globals belong to the document, so publishing has to happen after the load `test_window` did.
	// The engine releases a functor when the document that holds it goes away - which is the *next*
	// test's reload, long after this test's tracking allocator has finished counting. Allocating them
	// outside it is what keeps that from reading as a leak here and a bad free there.
	took := sciter_app.value_from_function(took_an_element, &state, runtime.default_allocator())
	defer sciter_app.value_clear(&took)
	testing.expect_value(t, sciter_app.set_global(window, "odin_took", &took), nil)

	gave := sciter_app.value_from_function(returns_an_element, &state, runtime.default_allocator())
	defer sciter_app.value_clear(&gave)
	testing.expect_value(t, sciter_app.set_global(window, "odin_gave", &gave), nil)

	// In: script's element arrives as an argument and unwraps to the handle it stands for.
	taken, terr := sciter_app.eval(window, `odin_took(document.$("#summary"))`)
	testing.expect_value(t, terr, nil)
	defer sciter_app.value_clear(&taken)

	got, _ := sciter_app.value_to_bool(&taken)
	testing.expect(t, got, "the argument must unwrap to an element")
	testing.expect_value(t, state.seen_tag, "div")
	testing.expect_value(t, state.seen_id, "summary")

	// Out: what Odin returned is a real Element to script, not an opaque handle.
	answer, aerr := sciter_app.eval(
		window,
		`(function(){ var el = odin_gave(); return [el instanceof Element, el.tag, el.id].join("|"); })()`,
	)
	testing.expect_value(t, aerr, nil)
	defer sciter_app.value_clear(&answer)

	described, _ := sciter_app.value_to_string(&answer, context.temp_allocator)
	testing.expect_value(t, described, "true|ul|tasks")
}

@(test)
test_node_value_round_trip :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	first, _ := sciter_app.select_first(root, "#tasks li")

	li, _ := sciter_app.node_from_element(first)
	text, terr := sciter_app.node_first_child(li)
	testing.expect_value(t, terr, nil)

	type, _ := sciter_app.node_type(text)
	testing.expect_value(t, type, sciter.Node_Type.TEXT)

	v, err := sciter_app.node_to_value(text)
	testing.expect_value(t, err, nil)
	defer sciter_app.value_clear(&v)

	back, berr := sciter_app.node_from_value(&v)
	testing.expect_value(t, berr, nil)
	testing.expect_value(t, back, text)

	// A text node is not an element, and unwrapping it as one fails rather than answering nil.
	_, not_an_element := sciter_app.element_from_value(&v)
	testing.expect_value(t, not_an_element, sciter_app.Error(sciter.Scdom_Result.OPERATION_FAILED))

	// The other asymmetry: an element *is* a node, so an element's Value unwraps both ways.
	ev, everr := sciter_app.element_to_value(first)
	testing.expect_value(t, everr, nil)
	defer sciter_app.value_clear(&ev)

	as_node, nerr := sciter_app.node_from_value(&ev)
	testing.expect_value(t, nerr, nil)

	as_element, aerr := sciter_app.node_to_element(as_node)
	testing.expect_value(t, aerr, nil)
	testing.expect_value(t, as_element, first)
}

// ---------------------------------------------------------------------------------------------------
// Ancestors, indexes, redrawing and globals

@(test)
test_select_parent_is_closest :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	item, _ := sciter_app.select_first(root, "#tasks li")

	list, err := sciter_app.select_parent(item, "ul")
	testing.expect_value(t, err, nil)
	tasks, _ := sciter_app.select_first(root, "#tasks")
	testing.expect_value(t, list, tasks)

	// Any selector, not just a tag.
	by_id, ierr := sciter_app.select_parent(item, "#tasks")
	testing.expect_value(t, ierr, nil)
	testing.expect_value(t, by_id, tasks)

	// The element counts as its own first candidate - this is `closest`, not `parent`.
	self, serr := sciter_app.select_parent(item, "li")
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, self, item)

	// `depth` counts from the element itself: 1 looks only at it, 2 adds the parent.
	_, too_shallow := sciter_app.select_parent(item, "ul", 1)
	testing.expect_value(t, too_shallow, sciter_app.Error(sciter_app.Api_Error.Not_Found))

	at_two, derr := sciter_app.select_parent(item, "ul", 2)
	testing.expect_value(t, derr, nil)
	testing.expect_value(t, at_two, tasks)

	// The default, 0, is unlimited - `body` is three levels up from the item.
	body, berr := sciter_app.select_parent(item, "body")
	testing.expect_value(t, berr, nil)
	testing.expect(t, body != nil)

	_, missing := sciter_app.select_parent(item, "table")
	testing.expect_value(t, missing, sciter_app.Error(sciter_app.Api_Error.Not_Found))

	// Pinned because it is surprising and silent: <html> is an ancestor of everything and matches
	// nothing here, at any depth. `root` is how to reach it.
	_, no_html := sciter_app.select_parent(item, "html", 0)
	testing.expect_value(t, no_html, sciter_app.Error(sciter_app.Api_Error.Not_Found))
}

@(test)
test_element_index_counts_elements_only :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	items, _ := sciter_app.select_all(root, "#tasks li", context.temp_allocator)
	defer delete(items, context.temp_allocator)
	testing.expect_value(t, len(items), 4)

	for item, i in items {
		index, err := sciter_app.element_index(item)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, index, sciter_app.Child_Index(i))
	}

	// A text node in front of them does not shift the numbering, which is what makes the index safe
	// to hand back to `child` and `insert_element`.
	tasks, _ := sciter_app.select_first(root, "#tasks")
	list_node, _ := sciter_app.node_from_element(tasks)
	text, terr := sciter_app.make_text_node("loose text")
	testing.expect_value(t, terr, nil)
	defer testing.expect_value(t, sciter_app.node_release(text), nil)
	testing.expect_value(t, sciter_app.node_insert(list_node, .PREPEND, text), nil)

	after, aerr := sciter_app.element_index(items[0])
	testing.expect_value(t, aerr, nil)
	testing.expect_value(t, after, 0)

	// Inserting an element does shift it.
	extra_owned, _ := sciter_app.make_element("li", "first")
	extra := sciter_app.borrow_element(extra_owned)
	defer sciter_app.unuse_element(extra_owned)
	testing.expect_value(t, sciter_app.insert_element(extra, tasks, 0), nil)

	moved, _ := sciter_app.element_index(items[0])
	testing.expect_value(t, moved, 1)
	testing.expect_value(t, sciter_app.element_index(extra) or_else -1, 0)
}

@(test)
test_redraw_calls_reach_the_engine :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	summary, _ := sciter_app.select_first(root, "#summary")

	testing.expect_value(t, sciter_app.update_element(summary), nil)
	testing.expect_value(t, sciter_app.update_element(summary, render = true), nil)
	testing.expect_value(t, sciter_app.request_paint(summary), nil)

	// The area is in the element's own coordinates, so this is its whole box.
	box, berr := sciter_app.location(summary, .Border, .Self)
	testing.expect_value(t, berr, nil)
	testing.expect_value(t, sciter_app.refresh_element_area(summary, box), nil)

	// A degenerate rectangle is not an error either - nothing to repaint is not a failure.
	testing.expect_value(t, sciter_app.refresh_element_area(summary, {}), nil)

	// The behaviour that makes `update_element` worth having rather than the engine doing it: it is
	// what re-resolves style the cascade has not been re-run for.
	first, _ := sciter_app.select_first(root, "#tasks li")
	before, _ := sciter_app.style(first, "color", context.temp_allocator)
	testing.expect_value(t, sciter_app.clear_attributes(first), nil)
	testing.expect_value(t, sciter_app.style(first, "color", context.temp_allocator) or_else "", before)

	testing.expect_value(t, sciter_app.update_element(first, render = true), nil)
	restyled, _ := sciter_app.style(first, "color", context.temp_allocator)
	testing.expect(t, restyled != before, "the update must re-run the cascade")

	sciter_app.update_window(window)
}

@(test)
test_globals_round_trip :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	published := sciter_app.value_from(i32(42))
	defer sciter_app.value_clear(&published)
	testing.expect_value(t, sciter_app.set_global(window, "odin_answer", &published), nil)

	// Out again through the API...
	back, err := sciter_app.global(window, "odin_answer")
	testing.expect_value(t, err, nil)
	defer sciter_app.value_clear(&back)
	n, _ := sciter_app.value_to_int(&back)
	testing.expect_value(t, n, i32(42))

	// ...and visible to script as a real global, which is the point of publishing one.
	seen, serr := sciter_app.eval(window, "typeof odin_answer + ':' + globalThis.odin_answer")
	testing.expect_value(t, serr, nil)
	defer sciter_app.value_clear(&seen)
	described, _ := sciter_app.value_to_string(&seen, context.temp_allocator)
	testing.expect_value(t, described, "number:42")

	// A name nobody published is undefined rather than an error - the same answer script gives.
	missing, merr := sciter_app.global(window, "odin_nothing_here")
	testing.expect_value(t, merr, nil)
	defer sciter_app.value_clear(&missing)
	testing.expect(t, sciter_app.value_is_undefined(&missing))

	// Script's own globals come back the same way.
	defined, derr := sciter_app.eval(window, "globalThis.from_script = 'yes'")
	testing.expect_value(t, derr, nil)
	sciter_app.value_clear(&defined)

	from_script, ferr := sciter_app.global(window, "from_script")
	testing.expect_value(t, ferr, nil)
	defer sciter_app.value_clear(&from_script)
	s, _ := sciter_app.value_to_string(&from_script, context.temp_allocator)
	testing.expect_value(t, s, "yes")

	// Globals belong to the document, so a reload takes them with it. This is the mistake the guide
	// warns about, pinned.
	testing.expect_value(t, sciter_app.load_html(window, DOC), nil)
	gone, gerr := sciter_app.global(window, "odin_answer")
	testing.expect_value(t, gerr, nil)
	defer sciter_app.value_clear(&gone)
	testing.expect(t, sciter_app.value_is_undefined(&gone), "a reload clears the document's globals")
}

// ---------------------------------------------------------------------------------------------------
// Media queries and the master stylesheet
//
// These need a window of their own. The media *type* can only be set once per window (see
// `set_media_type`), and the master stylesheet is the whole engine's, so a test that used the shared
// window above would leave every test after it looking at a different document than it wrote.

@(private = "file")
STYLED :: `<html><head><style>
  #target  { color: #222222; }
  @media screen { #target { color: #00FF00; } }
  @media print  { #target { color: #FF0000; } }
  @media dark   { #target { background-color: #000001; } }
  @media compact{ #target { padding-top: 5px; } }
</style></head><body><p id="target">styled</p></body></html>`

// A second window, made fresh for each of these tests. `create_window` is not cheap, but a window that
// has already had its media type set is no use to the next test.
@(private = "file")
styled_window :: proc(t: ^testing.T) -> (window: sciter_app.Window, target: sciter_app.Element, ok: bool) {
	if !have_display() {
		fmt.println("skipping - this test needs a window")
		return nil, nil, false
	}
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}

	// **Not optional on Windows, and the reason is not obvious.** With no host handler installed the
	// engine reports parse errors and script diagnostics through `OutputDebugStringW`, which Windows
	// implements by *raising an exception* (DBG_PRINTEXCEPTION_WIDE_C, 0x4001000A). Odin's test runner
	// installs a handler that treats any exception as fatal to the test, so a CSS warning killed the
	// test that provoked it and every test after it in the file - reported as `Signal caught: Unknown`,
	// which reads like a segfault and is not one. Routing diagnostics to a callback avoids the API
	// entirely. Harmless on Linux, where it just makes the engine's warnings visible.
	sciter_app.set_default_debug_output()
	// The engine keeps the window for the life of the process, so it is not the test's to account for.
	context.allocator = runtime.default_allocator()

	sciter_app.init()
	w, err := sciter_app.create_window({width = 300, height = 200})
	testing.expect_value(t, err, nil)
	if w == nil {
		return nil, nil, false
	}
	return w, nil, true
}

@(private = "file")
styled_target :: proc(window: sciter_app.Window) -> sciter_app.Element {
	root, _ := sciter_app.root(window)
	el, _ := sciter_app.select_first(root, "#target")
	return el
}

@(private = "file")
styled_color :: proc(window: sciter_app.Window, property := "color") -> string {
	s, _ := sciter_app.style(styled_target(window), property, context.temp_allocator)
	return s
}

@(test)
test_media_type_is_set_once :: proc(t: ^testing.T) {
	window, _, ok := styled_window(t)
	if !ok {return}

	// Set before the document is loaded, which is the only order that is reliable.
	testing.expect_value(t, sciter_app.set_media_type(window, "print"), nil)
	testing.expect_value(t, sciter_app.load_html(window, STYLED), nil)
	testing.expect_value(t, styled_color(window), "#FF0000")

	// The second call reports success and changes nothing. This is the engine's behaviour, not this
	// package's: pinned so that a future engine fixing it fails here rather than silently.
	testing.expect_value(t, sciter_app.set_media_type(window, "screen"), nil)
	sciter_app.update_element(styled_target(window), render = true)
	testing.expect_value(t, styled_color(window), "#FF0000")

	// Not even a reload takes it back.
	testing.expect_value(t, sciter_app.load_html(window, STYLED), nil)
	testing.expect_value(t, styled_color(window), "#FF0000")
}

@(test)
test_media_type_defaults_to_screen :: proc(t: ^testing.T) {
	window, _, ok := styled_window(t)
	if !ok {return}

	testing.expect_value(t, sciter_app.load_html(window, STYLED), nil)
	testing.expect_value(t, styled_color(window), "#00FF00")
}

// Media *variables* are flags rather than name/value pairs: every name set truthy becomes a query the
// CSS can match by bare name. `@media (name: "value")` looks like the obvious spelling and matches
// unconditionally instead, so the flag model is what this pins.
@(private = "file")
set_flags :: proc(window: sciter_app.Window, names: []string, on := true) -> sciter_app.Error {
	vars: sciter_app.Value
	defer sciter_app.value_clear(&vars)

	for name in names {
		v := sciter_app.value_from(on)
		defer sciter_app.value_clear(&v)
		sciter_app.value_set(&vars, name, &v)
	}
	return sciter_app.set_media_vars(window, &vars)
}

@(test)
test_media_vars_are_flags :: proc(t: ^testing.T) {
	window, _, ok := styled_window(t)
	if !ok {return}
	testing.expect_value(t, sciter_app.load_html(window, STYLED), nil)

	// `screen` is on by default; nothing else is.
	testing.expect_value(t, styled_color(window), "#00FF00")
	testing.expect_value(t, styled_color(window, "background-color"), "")

	testing.expect_value(t, set_flags(window, {"dark"}), nil)
	sciter_app.update_element(styled_target(window), render = true)
	testing.expect_value(t, styled_color(window, "background-color"), "#000001")

	// Setting another flag merges rather than replaces: `dark` is still on, and so is the default
	// `screen`. There is no way to hand over the whole set at once.
	testing.expect_value(t, set_flags(window, {"compact"}), nil)
	sciter_app.update_element(styled_target(window), render = true)
	testing.expect_value(t, styled_color(window, "background-color"), "#000001")
	testing.expect_value(t, styled_color(window, "padding-top"), "5px")
	testing.expect_value(t, styled_color(window), "#00FF00")

	// Off is a name set false, not a name left out.
	testing.expect_value(t, set_flags(window, {"dark"}, on = false), nil)
	sciter_app.update_element(styled_target(window), render = true)
	testing.expect_value(t, styled_color(window, "background-color"), "")
	testing.expect_value(t, styled_color(window, "padding-top"), "5px")

	// The flags survive a reload, where the document's globals do not.
	testing.expect_value(t, sciter_app.load_html(window, STYLED), nil)
	testing.expect_value(t, styled_color(window, "padding-top"), "5px")

	// An empty map is accepted and changes nothing.
	empty: sciter_app.Value
	defer sciter_app.value_clear(&empty)
	testing.expect_value(t, sciter_app.set_media_vars(window, &empty), nil)
	sciter_app.update_element(styled_target(window), render = true)
	testing.expect_value(t, styled_color(window, "padding-top"), "5px")
}

@(test)
test_master_css_replaces_and_appends :: proc(t: ^testing.T) {
	window, _, ok := styled_window(t)
	if !ok {return}
	testing.expect_value(t, sciter_app.load_html(window, STYLED), nil)

	// Nothing else in this file asserts letter-spacing or text-indent, which is what makes them safe
	// to use here: the master stylesheet is the whole engine's, for the rest of the process.
	testing.expect_value(t, styled_color(window, "letter-spacing"), "")

	testing.expect_value(t, sciter_app.set_master_css("p { letter-spacing: 3px; }"), nil)
	sciter_app.update_element(styled_target(window), render = true)
	testing.expect_value(t, styled_color(window, "letter-spacing"), "2.25pt")

	testing.expect_value(t, sciter_app.append_master_css("p { text-indent: 7px; }"), nil)
	sciter_app.update_element(styled_target(window), render = true)
	testing.expect_value(t, styled_color(window, "letter-spacing"), "2.25pt")
	testing.expect_value(t, styled_color(window, "text-indent"), "7px")

	// Both survive a reload - the sheet belongs to the engine, not to the document.
	testing.expect_value(t, sciter_app.load_html(window, STYLED), nil)
	testing.expect_value(t, styled_color(window, "letter-spacing"), "2.25pt")

	// `set_master_css` replaces rather than adds, so this drops both of the above. It is also how the
	// test puts the engine back: "" is refused, so a sheet that matches nothing is the way.
	testing.expect_value(t, sciter_app.set_master_css("no-such-element {}"), nil)
	testing.expect_value(t, sciter_app.load_html(window, STYLED), nil)
	testing.expect_value(t, styled_color(window, "letter-spacing"), "")
	testing.expect_value(t, styled_color(window, "text-indent"), "")

	testing.expect_value(t, sciter_app.set_master_css(""), sciter_app.Error(sciter_app.Api_Error.Option_Failed))
}

// ---------------------------------------------------------------------------------------------------
// Popups and mouse capture
//
// Both are interaction machinery, and neither can be driven for real without a user - what is testable
// is the state the engine puts the DOM in, and which handles it refuses. The popup half additionally
// needs a *shown* window to complete, and these tests never show one (a shown window on X11 here
// segfaults inside the engine's input-method handling), so what they pin is the half that does work
// headless plus the boundary where it stops.

@(private = "file")
POPUP_DOC :: `<html><head><style>
  #menu { position: absolute; width: 100px; height: 60px; }
</style></head><body>
  <button id="anchor">open</button>
  <div id="menu"><p>one</p><p>two</p></div>
  <div id="elsewhere">elsewhere</div>
</body></html>`

@(test)
test_show_popup_puts_the_element_out_of_flow :: proc(t: ^testing.T) {
	window, _, ok := styled_window(t)
	if !ok {return}
	testing.expect_value(t, sciter_app.load_html(window, POPUP_DOC), nil)

	root, _ := sciter_app.root(window)
	anchor, _ := sciter_app.select_first(root, "#anchor")
	menu, _ := sciter_app.select_first(root, "#menu")

	before, berr := sciter_app.element_state(menu)
	testing.expect_value(t, berr, nil)
	testing.expect(t, .POPUP not_in before)

	in_flow, _ := sciter_app.location(menu, .Border, .Root)
	testing.expect_value(t, sciter_app.show_popup(menu, anchor, .Bottom), nil)

	// The state bit is the engine's own record that the element is being shown out of flow.
	shown, serr := sciter_app.element_state(menu)
	testing.expect_value(t, serr, nil)
	testing.expect(t, .POPUP in shown, "showing a popup marks the element :popup")

	// And it is placed against the anchor rather than left where the document put it.
	placed, _ := sciter_app.location(menu, .Border, .Root)
	testing.expect(t, placed != in_flow, "the popup must move to its anchor")

	// The element has not moved in the *tree*, which is what makes a popup an ordinary part of the
	// document the rest of the time.
	still_there, perr := sciter_app.parent(menu)
	testing.expect_value(t, perr, nil)
	body, _ := sciter_app.select_first(root, "body")
	testing.expect_value(t, still_there, body)

	testing.expect_value(t, sciter_app.hide_popup(menu), nil)
}

@(test)
test_show_popup_at_and_placement :: proc(t: ^testing.T) {
	window, _, ok := styled_window(t)
	if !ok {return}
	testing.expect_value(t, sciter_app.load_html(window, POPUP_DOC), nil)

	root, _ := sciter_app.root(window)
	anchor, _ := sciter_app.select_first(root, "#anchor")
	menu, _ := sciter_app.select_first(root, "#menu")

	testing.expect_value(t, sciter_app.show_popup_at(menu, {50, 60}, .Top_Left), nil)
	state, _ := sciter_app.element_state(menu)
	testing.expect(t, .POPUP in state)

	at_point, _ := sciter_app.location(menu, .Border, .Root)
	testing.expect_value(t, sciter_app.hide_popup(menu), nil)

	// A different point is a different place - the position argument is honoured rather than ignored.
	testing.expect_value(t, sciter_app.show_popup_at(menu, {200, 180}, .Top_Left), nil)
	elsewhere, _ := sciter_app.location(menu, .Border, .Root)
	testing.expect(t, elsewhere.x > at_point.x && elsewhere.y > at_point.y)
	testing.expect_value(t, sciter_app.hide_popup(menu), nil)

	// Placement against an anchor: below and above are not the same place, and every keypad value is
	// accepted.
	testing.expect_value(t, sciter_app.show_popup(menu, anchor, .Bottom), nil)
	below, _ := sciter_app.location(menu, .Border, .Root)
	testing.expect_value(t, sciter_app.hide_popup(menu), nil)

	testing.expect_value(t, sciter_app.show_popup(menu, anchor, .Top), nil)
	above, _ := sciter_app.location(menu, .Border, .Root)
	testing.expect(t, above.y < below.y, "`.Top` must place it higher than `.Bottom`")
	testing.expect_value(t, sciter_app.hide_popup(menu), nil)

	placements := []sciter_app.Popup_Placement {
		.Bottom_Left,
		.Bottom,
		.Bottom_Right,
		.Left,
		.Center,
		.Right,
		.Top_Left,
		.Top,
		.Top_Right,
	}
	for placement in placements {
		testing.expect_value(t, sciter_app.show_popup(menu, anchor, placement), nil)
		testing.expect_value(t, sciter_app.hide_popup(menu), nil)
	}
}

@(test)
test_popup_refuses_a_detached_element :: proc(t: ^testing.T) {
	window, _, ok := styled_window(t)
	if !ok {return}
	testing.expect_value(t, sciter_app.load_html(window, POPUP_DOC), nil)

	root, _ := sciter_app.root(window)
	anchor, _ := sciter_app.select_first(root, "#anchor")

	// A popup is shown by the window the element is in, so an element in no document has no window to
	// be shown by. The code says `PASSIVE_HANDLE` rather than anything about popups.
	detached_owned, derr := sciter_app.make_element("div", "detached")
	detached := sciter_app.borrow_element(detached_owned)
	testing.expect_value(t, derr, nil)
	defer sciter_app.unuse_element(detached_owned)

	testing.expect_value(
		t,
		sciter_app.show_popup(detached, anchor, .Bottom),
		sciter_app.Error(sciter.Scdom_Result.PASSIVE_HANDLE),
	)

	// Hiding one that was never shown is not an error.
	menu, _ := sciter_app.select_first(root, "#menu")
	testing.expect_value(t, sciter_app.hide_popup(menu), nil)
}

// Pinned because it is the boundary, not the behaviour: on a window that has never been shown the
// engine takes the call and half-does it. If a future engine completes the job here, this test fails
// and the caveat in `show_popup`'s comment can go.
@(test)
test_popup_state_needs_a_shown_window :: proc(t: ^testing.T) {
	window, _, ok := styled_window(t)
	if !ok {return}
	testing.expect_value(t, sciter_app.load_html(window, POPUP_DOC), nil)

	root, _ := sciter_app.root(window)
	anchor, _ := sciter_app.select_first(root, "#anchor")
	menu, _ := sciter_app.select_first(root, "#menu")

	testing.expect_value(t, sciter_app.show_popup(menu, anchor, .Bottom), nil)

	// On a shown window the anchor gains `:owns-popup` here. It does not on this one.
	anchor_state, _ := sciter_app.element_state(anchor)
	testing.expect(t, .OWNS_POPUP not_in anchor_state, "a never-shown window does not mark the anchor")

	// And the popup keeps `:popup` after being hidden, where a shown window clears it.
	testing.expect_value(t, sciter_app.hide_popup(menu), nil)
	sciter_app.update_element(menu, render = true)

	after, _ := sciter_app.element_state(menu)
	testing.expect(t, .POPUP in after, "a never-shown window does not clear :popup on hide")

	// `hide_popup` takes the popup, not the anchor. The anchor is a no-op the engine reports as
	// OK_NOT_HANDLED - which `dom_err` treats as success, so this reads as nil rather than an error.
	testing.expect_value(t, sciter_app.hide_popup(anchor), nil)
}

@(test)
test_capture_accepts_document_elements_only :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	summary, _ := sciter_app.select_first(root, "#summary")
	tasks, _ := sciter_app.select_first(root, "#tasks")

	testing.expect_value(t, sciter_app.set_capture(summary), nil)

	// Taking it twice, and taking it away from another element, both succeed - the capture moves
	// rather than being contested.
	testing.expect_value(t, sciter_app.set_capture(summary), nil)
	testing.expect_value(t, sciter_app.set_capture(tasks), nil)

	// Releasing from an element that no longer holds it is not an error either, which is what makes
	// an unconditional release on the way out of a drag safe.
	testing.expect_value(t, sciter_app.release_capture(summary), nil)
	testing.expect_value(t, sciter_app.release_capture(tasks), nil)
	testing.expect_value(t, sciter_app.release_capture(tasks), nil)

	// The capture belongs to the window, so an element in no document cannot have it.
	detached_owned, derr := sciter_app.make_element("div", "detached")
	detached := sciter_app.borrow_element(detached_owned)
	testing.expect_value(t, derr, nil)
	defer sciter_app.unuse_element(detached_owned)

	testing.expect_value(t, sciter_app.set_capture(detached), sciter_app.Error(sciter.Scdom_Result.INVALID_HWND))
	testing.expect_value(t, sciter_app.release_capture(detached), sciter_app.Error(sciter.Scdom_Result.INVALID_HWND))
}

// ---------------------------------------------------------------------------------------------------
// Focus, highlight, and named events

@(private = "file")
FOCUS_DOC :: `<html><body>
  <button id="first">first</button>
  <input id="second" type="text" />
  <div id="box"><p id="inner">inner</p></div>
</body></html>`

@(test)
test_focus_follows_the_state :: proc(t: ^testing.T) {
	window, _, ok := styled_window(t)
	if !ok {return}
	testing.expect_value(t, sciter_app.load_html(window, FOCUS_DOC), nil)

	root, _ := sciter_app.root(window)
	first, _ := sciter_app.select_first(root, "#first")
	second, _ := sciter_app.select_first(root, "#second")

	// Nothing has the focus until something takes it.
	_, none := sciter_app.focus_element(window)
	testing.expect_value(t, none, sciter_app.Error(sciter_app.Api_Error.Not_Found))

	testing.expect_value(t, sciter_app.set_focus(first), nil)
	focused, err := sciter_app.focus_element(window)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, focused, first)

	state, _ := sciter_app.element_state(first)
	testing.expect(t, .FOCUS in state, ":focus is what the focus *is*")

	// Focusing another element moves it, and takes the state off the first.
	testing.expect_value(t, sciter_app.set_focus(second), nil)
	moved, merr := sciter_app.focus_element(window)
	testing.expect_value(t, merr, nil)
	testing.expect_value(t, moved, second)

	was, _ := sciter_app.element_state(first)
	testing.expect(t, .FOCUS not_in was)

	// Clearing the state does *not* leave the window unfocused - it only stops the element matching
	// `:focus`. Pinned because it is the obvious way to try to clear the focus and it does not work.
	testing.expect_value(t, sciter_app.set_element_state(second, {}, {.FOCUS}), nil)
	cleared, cerr := sciter_app.element_state(second)
	testing.expect_value(t, cerr, nil)
	testing.expect(t, .FOCUS not_in cleared)

	still, serr := sciter_app.focus_element(window)
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, still, second)
}

@(test)
test_highlight_round_trips :: proc(t: ^testing.T) {
	window, _, ok := styled_window(t)
	if !ok {return}
	testing.expect_value(t, sciter_app.load_html(window, FOCUS_DOC), nil)

	root, _ := sciter_app.root(window)
	box, _ := sciter_app.select_first(root, "#box")

	_, none := sciter_app.highlighted_element(window)
	testing.expect_value(t, none, sciter_app.Error(sciter_app.Api_Error.Not_Found))

	before, berr := sciter_app.element_state(box)
	testing.expect_value(t, berr, nil)

	testing.expect_value(t, sciter_app.set_highlighted_element(window, box), nil)
	got, err := sciter_app.highlighted_element(window)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, got, box)

	// It is an overlay, not a state: nothing about the element changes, so no CSS can match on it.
	state, serr := sciter_app.element_state(box)
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, state, before)

	// A nil element clears it.
	testing.expect_value(t, sciter_app.set_highlighted_element(window, nil), nil)
	_, gone := sciter_app.highlighted_element(window)
	testing.expect_value(t, gone, sciter_app.Error(sciter_app.Api_Error.Not_Found))
}

// The handler these use records every `.CUSTOM` event it is given, which is what makes the delivery
// rules - both phases, broadcast reaching only window handlers, posted events copying their payload -
// observable at all.
@(private = "file")
Fired_Log :: struct {
	handler: sciter_app.Event_Handler,
	names:   [dynamic]string,
	data:    [dynamic]string,
	claim:   bool, // return true from the handler, so `fire_event` reports it handled
}

@(private = "file")
record_custom :: proc(handler: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	log := (^Fired_Log)(handler.user_data)

	be, ok := sciter_app.behavior_event(event)
	if !ok || be.code != .CUSTOM {
		return false
	}
	// The log outlives this callback and so must what goes in it - `new_log` explains why the whole
	// thing is on the default allocator, and the package's callback boundary is why the temp arena is
	// not an option: it is restored to the mark it had on the way in. See `callback_temp_scope`.
	append(&log.names, sciter_app.event_name(be, runtime.default_allocator()))

	rendered, _ := sciter_app.value_to_display_string(be.data, .JSON_LITERAL, runtime.default_allocator())
	append(&log.data, rendered)
	return log.claim
}

@(private = "file")
new_log :: proc(claim := false) -> ^Fired_Log {
	// The engine holds the handler's address for as long as it is attached, and these tests attach for
	// the life of the window, so none of this belongs to the test's tracking allocator.
	context.allocator = runtime.default_allocator()

	log := new(Fired_Log)
	log.names = make([dynamic]string)
	log.data = make([dynamic]string)
	log.claim = claim
	log.handler = sciter_app.Event_Handler {
		subscription = {.BEHAVIOR_EVENT},
		on_event     = record_custom,
		user_data    = log,
	}
	return log
}

@(test)
test_fire_event_carries_a_name_and_a_payload :: proc(t: ^testing.T) {
	window, _, ok := styled_window(t)
	if !ok {return}
	testing.expect_value(t, sciter_app.load_html(window, FOCUS_DOC), nil)

	root, _ := sciter_app.root(window)
	inner, _ := sciter_app.select_first(root, "#inner")

	log := new_log()
	testing.expect_value(t, sciter_app.attach_handler(root, &log.handler), nil)
	defer sciter_app.detach_handler(root, &log.handler)

	payload := sciter_app.value_from("cargo")
	defer sciter_app.value_clear(&payload)

	handled, err := sciter_app.fire_event(
		{code = .CUSTOM, name = "my-event", target = inner, source = inner, data = &payload},
	)
	testing.expect_value(t, err, nil)
	testing.expect(t, !handled, "nothing claimed it")

	// Down and back up, like every other event: two deliveries, not one.
	testing.expect_value(t, len(log.names), 2)
	testing.expect_value(t, log.names[0], "my-event")
	testing.expect_value(t, log.names[1], "my-event")
	testing.expect_value(t, log.data[0], `"cargo"`)

	// The payload is borrowed, not consumed - it is still usable here.
	still, serr := sciter_app.value_to_string(&payload, context.temp_allocator)
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, still, "cargo")
}

@(test)
test_fire_event_reports_handled :: proc(t: ^testing.T) {
	window, _, ok := styled_window(t)
	if !ok {return}
	testing.expect_value(t, sciter_app.load_html(window, FOCUS_DOC), nil)

	root, _ := sciter_app.root(window)
	inner, _ := sciter_app.select_first(root, "#inner")

	log := new_log(claim = true)
	testing.expect_value(t, sciter_app.attach_handler(root, &log.handler), nil)
	defer sciter_app.detach_handler(root, &log.handler)

	handled, err := sciter_app.fire_event({code = .CUSTOM, name = "claimed", target = inner})
	testing.expect_value(t, err, nil)
	testing.expect(t, handled, "a handler returning true is reported back to the sender")

	// An application code needs no name, and is delivered the same way.
	clear(&log.names)
	app_handled, aerr := sciter_app.fire_event(
		{code = sciter.Behavior_Events(u32(sciter.Behavior_Events.FIRST_APPLICATION_EVENT_CODE) + 3), target = inner},
	)
	testing.expect_value(t, aerr, nil)
	testing.expect(t, !app_handled, "the recorder only claims .CUSTOM")
}

@(test)
test_fire_event_broadcast_reaches_window_handlers_only :: proc(t: ^testing.T) {
	window, _, ok := styled_window(t)
	if !ok {return}
	testing.expect_value(t, sciter_app.load_html(window, FOCUS_DOC), nil)

	root, _ := sciter_app.root(window)

	on_element := new_log()
	testing.expect_value(t, sciter_app.attach_handler(root, &on_element.handler), nil)
	defer sciter_app.detach_handler(root, &on_element.handler)

	on_window := new_log()
	testing.expect_value(t, sciter_app.attach_window_handler(window, &on_window.handler), nil)
	defer sciter_app.detach_window_handler(window, &on_window.handler)

	// A nil target broadcasts. It reaches the window handler and not the one on `root`, which is the
	// whole reason to know the difference between the two attachments.
	handled, err := sciter_app.fire_event({code = .CUSTOM, name = "everyone"})
	testing.expect_value(t, err, nil)
	testing.expect(t, !handled)

	testing.expect_value(t, len(on_window.names), 2)
	testing.expect_value(t, on_window.names[0], "everyone")
	testing.expect_value(t, len(on_element.names), 0)
}

@(test)
test_posted_event_copies_its_payload :: proc(t: ^testing.T) {
	window, _, ok := styled_window(t)
	if !ok {return}
	testing.expect_value(t, sciter_app.load_html(window, FOCUS_DOC), nil)

	root, _ := sciter_app.root(window)
	inner, _ := sciter_app.select_first(root, "#inner")

	log := new_log()
	testing.expect_value(t, sciter_app.attach_handler(root, &log.handler), nil)
	defer sciter_app.detach_handler(root, &log.handler)

	{
		// Both the name and the payload go out of scope before the event is delivered. The engine
		// copies them at the call, which is what makes `context.temp_allocator` safe for the name
		// inside `fire_event`.
		payload := sciter_app.value_from("copied")
		name := strings.clone("later", context.temp_allocator)

		handled, err := sciter_app.fire_event(
			{code = .CUSTOM, name = name, target = inner, data = &payload},
			post = true,
		)
		testing.expect_value(t, err, nil)
		testing.expect(t, !handled, "a posted event has not been seen by anything yet")
		testing.expect_value(t, len(log.names), 0)

		sciter_app.value_clear(&payload)
		free_all(context.temp_allocator)
	}

	for _ in 0 ..< 20 {
		sciter_app.run_once()
	}

	testing.expect_value(t, len(log.names), 2)
	testing.expect_value(t, log.names[0], "later")
	testing.expect_value(t, log.data[0], `"copied"`)
}

// ---------------------------------------------------------------------------------------------------
// SOM: an Odin object script can see
//
// A native functor gives script a function; an asset gives it an object with properties and methods.
// These need a window of their own because a global asset only appears in the *next* document loaded,
// so the shared window - already carrying a document - would never see it.

@(private = "file")
SOM_DOC :: `<html><body><button id="b">b</button><input id="e" type="text"/></body></html>`

@(private = "file")
Backend :: struct {
	count:   i32,
	reloads: int,
}

@(private = "file")
get_count :: proc(asset: ^sciter_app.Asset) -> (sciter_app.Value, bool) {
	backend := (^Backend)(asset.user_data)
	return sciter_app.value_from(backend.count), true
}

@(private = "file")
set_count :: proc(asset: ^sciter_app.Asset, value: ^sciter_app.Value) -> bool {
	backend := (^Backend)(asset.user_data)
	n, err := sciter_app.value_to_int(value)
	if err != nil {
		return false
	}
	backend.count = n
	return true
}

@(private = "file")
get_version :: proc(asset: ^sciter_app.Asset) -> (sciter_app.Value, bool) {
	return sciter_app.value_from("6.0.4.9"), true
}

@(private = "file")
reload :: proc(asset: ^sciter_app.Asset, args: []sciter_app.Value) -> (sciter_app.Value, bool) {
	backend := (^Backend)(asset.user_data)
	backend.reloads += 1

	sum := backend.count
	for &arg in args {
		n, _ := sciter_app.value_to_int(&arg)
		sum += n
	}
	return sciter_app.value_from(sum), true
}

// The class, the asset and the state all outlive the test - the engine holds the asset's address for
// as long as any document can reach it - so none of them belong to the test's tracking allocator.
@(private = "file")
backend_asset :: proc(t: ^testing.T) -> (^sciter_app.Asset, ^Backend) {
	context.allocator = runtime.default_allocator()

	state := new(Backend)
	class, err := sciter_app.make_asset_class(
		"Backend",
		{{name = "count", get = get_count, set = set_count}, {name = "version", get = get_version}},
		{{name = "reload", params = 1, call = reload}},
	)
	testing.expect_value(t, err, nil)
	return sciter_app.make_asset(class, state), state
}

@(test)
test_global_asset_is_an_object_in_script :: proc(t: ^testing.T) {
	window, _, ok := styled_window(t)
	if !ok {return}

	asset, state := backend_asset(t)
	state.count = 5

	// The document loaded *before* publishing does not see it, which is the trap this pins.
	testing.expect_value(t, sciter_app.load_html(window, SOM_DOC), nil)
	testing.expect_value(t, sciter_app.set_global_asset(asset), nil)

	before, berr := sciter_app.eval(window, "typeof Backend")
	testing.expect_value(t, berr, nil)
	defer sciter_app.value_clear(&before)
	kind, _ := sciter_app.value_to_string(&before, context.temp_allocator)
	testing.expect_value(t, kind, "undefined")

	// The next load is where it appears.
	testing.expect_value(t, sciter_app.load_html(window, SOM_DOC), nil)

	described, derr := sciter_app.eval(window, "[typeof Backend, String(Backend)].join('/')")
	testing.expect_value(t, derr, nil)
	defer sciter_app.value_clear(&described)
	text, _ := sciter_app.value_to_string(&described, context.temp_allocator)
	testing.expect_value(t, text, "object/[asset Backend]")

	// A property read reaches the getter...
	read, rerr := sciter_app.eval(window, "Backend.count")
	testing.expect_value(t, rerr, nil)
	defer sciter_app.value_clear(&read)
	n, _ := sciter_app.value_to_int(&read)
	testing.expect_value(t, n, i32(5))

	// ...and a write reaches the setter, which is what makes this an object rather than a snapshot.
	written, werr := sciter_app.eval(window, "(Backend.count = 42, Backend.count)")
	testing.expect_value(t, werr, nil)
	defer sciter_app.value_clear(&written)
	back, _ := sciter_app.value_to_int(&written)
	testing.expect_value(t, back, i32(42))
	testing.expect_value(t, state.count, i32(42))

	// A method, with its arguments.
	called, cerr := sciter_app.eval(window, "Backend.reload(8)")
	testing.expect_value(t, cerr, nil)
	defer sciter_app.value_clear(&called)
	total, _ := sciter_app.value_to_int(&called)
	testing.expect_value(t, total, i32(50))
	testing.expect_value(t, state.reloads, 1)

	// A property with no setter is read-only, and the assignment throws rather than being dropped.
	version, verr := sciter_app.eval(window, "Backend.version")
	testing.expect_value(t, verr, nil)
	defer sciter_app.value_clear(&version)
	v, _ := sciter_app.value_to_string(&version, context.temp_allocator)
	testing.expect_value(t, v, "6.0.4.9")

	refused, assigned := sciter_app.eval(window, "Backend.version = 'nope'")
	testing.expect_value(t, assigned, nil)
	defer sciter_app.value_clear(&refused)

	// The refusal comes back as a Value rather than as an error from `eval`: an error *string*, which
	// is exactly what `value_is_error` is for.
	testing.expect(t, sciter_app.value_is_error(&refused), "assigning to a read-only property throws")
	message, _ := sciter_app.value_to_string(&refused, context.temp_allocator)
	testing.expect(t, strings.contains(message, "setting property"), message)

	// And the value is unchanged.
	still, serr := sciter_app.eval(window, "Backend.version")
	testing.expect_value(t, serr, nil)
	defer sciter_app.value_clear(&still)
	unchanged, _ := sciter_app.value_to_string(&still, context.temp_allocator)
	testing.expect_value(t, unchanged, "6.0.4.9")

	// SOM members are not enumerable: script has to know the names.
	keys, kerr := sciter_app.eval(window, "Object.keys(Backend).length")
	testing.expect_value(t, kerr, nil)
	defer sciter_app.value_clear(&keys)
	count, _ := sciter_app.value_to_int(&keys)
	testing.expect_value(t, count, i32(0))

	// Withdrawing it works on the same schedule: the loaded document keeps it, the next one does not.
	testing.expect_value(t, sciter_app.release_global_asset(asset), nil)
	testing.expect_value(t, sciter_app.load_html(window, SOM_DOC), nil)

	after, aerr := sciter_app.eval(window, "typeof Backend")
	testing.expect_value(t, aerr, nil)
	defer sciter_app.value_clear(&after)
	gone, _ := sciter_app.value_to_string(&after, context.temp_allocator)
	testing.expect_value(t, gone, "undefined")
}

@(test)
test_asset_class_refuses_too_many_members :: proc(t: ^testing.T) {
	if !sciter_app.load_engine() {return}

	// One thunk per member index exists, and there are `MAX_ASSET_MEMBERS` of them - so the limit is
	// reported rather than run past.
	too_many := make([]sciter_app.Asset_Property, sciter_app.MAX_ASSET_MEMBERS + 1, context.temp_allocator)
	for &property, i in too_many {
		property = {
			name = fmt.tprintf("p%d", i),
			get  = get_version,
		}
	}

	_, err := sciter_app.make_asset_class("TooBig", too_many, nil, context.temp_allocator)
	testing.expect_value(t, err, sciter_app.Error(sciter_app.Api_Error.Too_Many_Members))

	// The limit itself is fine.
	class, ok := sciter_app.make_asset_class(
		"JustFits",
		too_many[:sciter_app.MAX_ASSET_MEMBERS],
		nil,
		context.temp_allocator,
	)
	testing.expect_value(t, ok, nil)
	defer sciter_app.destroy_asset_class(class)
	testing.expect_value(t, len(class.properties), sciter_app.MAX_ASSET_MEMBERS)
}

@(test)
test_element_asset_finds_a_behavior :: proc(t: ^testing.T) {
	window, _, ok := styled_window(t)
	if !ok {return}
	testing.expect_value(t, sciter_app.load_html(window, SOM_DOC), nil)

	root, _ := sciter_app.root(window)
	edit, _ := sciter_app.select_first(root, "#e")
	button, _ := sciter_app.select_first(root, "#b")

	// `<input type=text>` carries the `edit` behavior, and the behavior publishes an asset under that
	// name. This is what atoms are the currency of.
	asset, err := sciter_app.element_asset(edit, "edit")
	testing.expect_value(t, err, nil)
	testing.expect(t, asset != nil)
	testing.expect(t, asset.isa != nil, "an asset carries its class")

	// Anything else is `.OPERATION_FAILED` - including a real element with a different behavior, and
	// a name no behavior has.
	_, wrong_behavior := sciter_app.element_asset(button, "edit")
	testing.expect_value(t, wrong_behavior, sciter_app.Error(sciter.Scdom_Result.OPERATION_FAILED))

	_, no_such := sciter_app.element_asset(edit, "no-such-behavior")
	testing.expect_value(t, no_such, sciter_app.Error(sciter.Scdom_Result.OPERATION_FAILED))
}

// ---------------------------------------------------------------------------------------------------
// The window's own stylesheet, and its state
//
// `set_css` is the third stylesheet in the picture, after the document's `<style>` and the engine-wide
// master sheet the tests above cover. It behaves like neither of them.
//
// None of these show a window. That is not squeamishness: a shown window on X11 here segfaults inside
// the engine's input-method handling unless `XMODIFIERS=@im=none` is set, and the test recipe does not
// set it. So what is pinned is everything that can be reached without one.

// **`set_css` replaces the document's own stylesheet - it does not layer under it.** The document says
// `#target { color: #222222 }` and a `set_css` that never mentions `#target` leaves it at the inherited
// default, which it could not do if the document's rule were still in play.
//
// That makes the name misleading: this is not "the window's contribution to the cascade", it is "the
// stylesheet, instead of the document's".
@(test)
test_a_window_stylesheet_replaces_the_documents_own :: proc(t: ^testing.T) {
	window, _, ok := styled_window(t)
	if !ok {return}
	testing.expect_value(t, sciter_app.load_html(window, STYLED), nil)

	// The document's rule, before anything else happens. (`@media screen` wins over the bare rule.)
	testing.expect_value(t, styled_color(window), "#00FF00")

	// A window sheet that says nothing at all about #target.
	testing.expect_value(t, sciter_app.set_css(window, "div { color: #123456; }"), nil)
	sciter_app.update_element(styled_target(window), render = true)

	// If the document's sheet still applied, this would be #00FF00.
	testing.expect_value(t, styled_color(window), "#000000")

	// And a rule here does apply, so the sheet is not simply being ignored.
	testing.expect_value(t, sciter_app.set_css(window, "#target { color: #0000FF; }"), nil)
	sciter_app.update_element(styled_target(window), render = true)
	testing.expect_value(t, styled_color(window), "#0000FF")
}

// The corollary, and the reason the layering matters: `!important` in the document does not save it.
// A plain rule in the window sheet beats it, because the document's sheet is not in the cascade at all
// any more. An inline style still wins - that is the only thing that does.
@(test)
test_an_important_document_rule_loses_to_a_plain_window_rule :: proc(t: ^testing.T) {
	window, _, ok := styled_window(t)
	if !ok {return}

	IMPORTANT :: `<html><head><style>
	  #target { color: #00FF00 !important; }
	</style></head><body><p id="target">styled</p></body></html>`

	testing.expect_value(t, sciter_app.load_html(window, IMPORTANT), nil)
	testing.expect_value(t, styled_color(window), "#00FF00")

	testing.expect_value(t, sciter_app.set_css(window, "#target { color: #0000FF; }"), nil)
	sciter_app.update_element(styled_target(window), render = true)
	testing.expect_value(t, styled_color(window), "#0000FF")

	// An inline style outranks the window sheet, as it outranks everything.
	testing.expect_value(t, sciter_app.set_style(styled_target(window), "color", "#FF00FF"), nil)
	testing.expect_value(t, styled_color(window), "#FF00FF")
}

// There is one window sheet, not a stack: each call replaces the last. And a reload drops it - unlike
// the master sheet, which belongs to the engine and survives. So a window sheet has to be re-applied
// after every `load_html`, which is the same rule the document's globals have.
@(test)
test_a_window_stylesheet_is_replaced_by_the_next_one_and_dropped_by_a_reload :: proc(t: ^testing.T) {
	window, _, ok := styled_window(t)
	if !ok {return}
	testing.expect_value(t, sciter_app.load_html(window, STYLED), nil)

	testing.expect_value(t, sciter_app.set_css(window, "#target { color: #0000FF; }"), nil)
	sciter_app.update_element(styled_target(window), render = true)
	testing.expect_value(t, styled_color(window), "#0000FF")

	// Replaced, not merged: the first rule is gone rather than being overridden.
	testing.expect_value(t, sciter_app.set_css(window, "p { letter-spacing: 1px; }"), nil)
	sciter_app.update_element(styled_target(window), render = true)
	testing.expect_value(t, styled_color(window), "#000000")

	// And a reload puts the document back in charge.
	testing.expect_value(t, sciter_app.load_html(window, STYLED), nil)
	testing.expect_value(t, styled_color(window), "#00FF00")
}

// Empty CSS is refused, the same way `set_master_css("")` is. **Unparseable CSS is not** - it is
// accepted, and it still replaces the document's sheet, so the document ends up with no styling and
// nothing anywhere says why.
@(test)
test_empty_css_is_refused_but_nonsense_css_is_accepted_and_still_replaces :: proc(t: ^testing.T) {
	window, _, ok := styled_window(t)
	if !ok {return}
	testing.expect_value(t, sciter_app.load_html(window, STYLED), nil)

	testing.expect_value(t, sciter_app.set_css(window, ""), sciter_app.Error(sciter_app.Api_Error.Load_Failed))
	testing.expect_value(t, styled_color(window), "#00FF00") // unchanged

	testing.expect_value(t, sciter_app.set_css(window, "this is not css {{{"), nil)
	sciter_app.update_element(styled_target(window), render = true)
	testing.expect_value(t, styled_color(window), "#000000")
}

// **A window that has been created and never shown does not report the same thing on both platforms**,
// and the Linux answer is the surprising one: `.CLOSED`, for a window that is alive and about to load a
// document. Windows reports `.HIDDEN`, which is what the state means.
//
// So `if window_state(w) == .CLOSED { ... }` meaning "gone" is wrong on Linux and right on Windows,
// which is the worst shape a difference can have. Do not use the state to decide whether a window is
// alive - ask the DOM, as the second half of this test does; that answers the same way on both.
@(test)
test_what_a_window_that_was_never_shown_reports :: proc(t: ^testing.T) {
	window, _, ok := styled_window(t)
	if !ok {return}

	when ODIN_OS == .Windows {
		NEVER_SHOWN :: sciter.Sciter_Window_State.HIDDEN
	} else {
		NEVER_SHOWN :: sciter.Sciter_Window_State.CLOSED
	}

	before, before_ok := sciter_app.window_state(window)
	testing.expect(t, before_ok)
	testing.expect_value(t, before, NEVER_SHOWN)

	// It is perfectly usable in that state - a document loads, and the DOM answers.
	testing.expect_value(t, sciter_app.load_html(window, STYLED), nil)
	testing.expect(t, styled_target(window) != nil)
	after, after_ok := sciter_app.window_state(window)
	testing.expect(t, after_ok)
	testing.expect_value(t, after, NEVER_SHOWN)
}

// **`window_state` reports almost nothing on Linux, and reports the truth on Windows.** This is the
// sharpest platform difference in the wrapper's surface, and it runs the way round you would not guess:
//
//   Linux    `.MINIMIZED`, `.MAXIMIZED` and `.HIDDEN` are accepted and not reflected. The window
//            answers `.SHOWN` or `.CLOSED` and nothing else, whatever it was asked for; what a window
//            manager did about the request is its own business and the engine will not tell you.
//   Windows  every one of them comes back. Ask for `.MINIMIZED` and the window reports `.MINIMIZED`.
//
// So an application that needs to know whether it is minimised **must keep its own flag on Linux**, and
// may read the engine on Windows. Writing the Windows-shaped code and testing it there produces
// something that silently never fires on Linux.
//
// What holds on both, and is what this test is really for, is the weaker claim: the calls are harmless
// and the window is still usable afterwards.
//
// **`.FULL_SCREEN` is deliberately not in the list below, and must never be put back.** It is not a
// window state on X11, it is a display mode change: asking a 300x200 window for it took a 1920x1200
// laptop panel down to 320x180, and the panel stayed there after the process exited - so running this
// file's tests wrecked the display of whoever ran them, twice, before the call was taken out. Nothing
// in this package puts the mode back; `xrandr --output <name> --mode <preferred>` does. The behaviour
// is recorded on `set_window_state` in `window.odin`, which is the right place for it: a comment costs
// nothing, and this test costs a display.
@(test)
test_asking_for_a_window_state_never_breaks_the_window :: proc(t: ^testing.T) {
	window, _, ok := styled_window(t)
	if !ok {return}
	testing.expect_value(t, sciter_app.load_html(window, STYLED), nil)

	for state in ([]sciter.Sciter_Window_State{.MINIMIZED, .MAXIMIZED, .HIDDEN, .SHOWN}) {
		sciter_app.set_window_state(window, state)
		sciter_app.heartbeat()

		reported, reported_ok := sciter_app.window_state(window)
		testing.expect(t, reported_ok, "a live window always reports a state the enum has")
		when ODIN_OS == .Windows {
			testing.expectf(
				t,
				reported == state,
				"after asking for %v the window reported %v; Windows reflects the request",
				state,
				reported,
			)
		} else {
			testing.expectf(
				t,
				reported == .SHOWN || reported == .CLOSED,
				"after asking for %v the window reported %v, which this engine was not measured to do",
				state,
				reported,
			)
		}
	}

	// `hide` and `activate` are the same call under other names, and equally harmless.
	sciter_app.hide(window)
	sciter_app.activate(window)
	sciter_app.activate(window, false)
	sciter_app.heartbeat()

	// The document came through all of it untouched, which is the part that actually matters.
	testing.expect_value(t, styled_color(window), "#00FF00")
}

// **`close` is not tested here, and cannot be.** Closing a secondary window that has a document loaded
// crashes the engine on the next turn of the pump - the segfault is inside its own `check_paint`,
// walking down to `GetWindowSizeX11` on a window it has destroyed but left on the paint list. It is not
// merely that the closing test dies: the closed window stays on that list for the rest of the process,
// so *every later test in the binary* segfaults too, whether or not it has anything to do with windows.
//
// Reproduced in four lines - `create_window`, `load_html`, `close`, `heartbeat` - and written up on
// `close` in `window.odin`, along with what to do instead. A window that never had a document closes
// cleanly, which is the only reason `close` is reachable at all.
//
// Measured on the way to that: `close` does nothing until the pump runs. Immediately after the call the
// handle still answers and `root` still succeeds.
//
// **There is one order that survives, found later**: `hide`, then a turn of the pump, then `close`.
// `examples/workbench.odin` has that test - it is the only place a secondary window is closed on
// purpose - and the full table of what was tried is on `close` in `window.odin`.

// **`state` and `set_state` are overload groups over two unrelated things**, and this is the test that
// the group resolves - `element_state`/`set_element_state` for an element, `window_state`/
// `set_window_state` for a window. The members are exercised all over this file by name; what is pinned
// here is that reaching them through the shared name calls the same code and not something adjacent.
//
// The asymmetry is deliberate and shows up at the call site: the element half returns an `Error`, the
// window half returns nothing at all, because the engine reports no failure for a window state - see
// `set_window_state` in `window.odin`.
@(test)
test_the_state_overload_group_reaches_both_an_element_and_a_window :: proc(t: ^testing.T) {
	window, _, ok := styled_window(t)
	if !ok {return}
	testing.expect_value(t, sciter_app.load_html(window, STYLED), nil)

	target := styled_target(window)
	testing.expect(t, target != nil)

	// The element half, set and cleared through the group. **The bit set has to be spelled out**:
	// overload resolution runs before a compound literal's type is inferred, so the `{.CHECKED}` that
	// `set_element_state` takes is a compile error here - "Missing type in compound literal". That is
	// the cost of the group and the reason both members are still exported under their own names.
	testing.expect_value(t, sciter_app.set_state(target, sciter.Element_State_Bits{.CHECKED}), nil)
	set, serr := sciter_app.state(target)
	testing.expect_value(t, serr, nil)
	testing.expect(t, .CHECKED in set, "the group should have reached set_element_state")

	testing.expect_value(
		t,
		sciter_app.set_state(target, sciter.Element_State_Bits{}, sciter.Element_State_Bits{.CHECKED}),
		nil,
	)
	cleared, cerr := sciter_app.state(target)
	testing.expect_value(t, cerr, nil)
	testing.expect(t, .CHECKED not_in cleared)

	// And the window half, from the same two names. `.SHOWN` because it is one of the two states this
	// engine ever reports - and `.FULL_SCREEN` must never appear here, for the reason written above
	// `test_asking_for_a_window_state_never_breaks_the_window`.
	sciter_app.set_state(window, sciter.Sciter_Window_State.SHOWN)
	sciter_app.heartbeat()
	reported, reported_ok := sciter_app.state(window)
	testing.expect(t, reported_ok, "a live window reports a state the enum has")
	testing.expect_value(t, reported, sciter.Sciter_Window_State.SHOWN)

	// The document is untouched by any of it.
	testing.expect_value(t, styled_color(window), "#00FF00")
}

// **`tag` is a borrowed pointer into an interned table, not into the element**, which is a stronger
// guarantee than its doc comment used to claim ("valid for the element's lifetime") and worth pinning
// because the weaker claim would send a caller copying strings it does not need to copy.
//
// Measured on 6.0.4.9: two calls for the same element answer the *same pointer*, two elements with the
// same tag share it, and the string still reads correctly after the element it came from has been
// removed and finalized - and after the whole document has been replaced. That is a table keyed by tag
// name, filled as names are seen, and it is what "borrowed from the engine" means here.
//
// The rule for callers does not change: it is borrowed, so copy it if it has to outlive the engine.
@(test)
test_a_tag_is_interned_and_outlives_the_element_it_came_from :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	first, ferr := sciter_app.select_first(root, "li")
	testing.expect_value(t, ferr, nil)

	name, terr := sciter_app.tag(first)
	testing.expect_value(t, terr, nil)
	testing.expect_value(t, name, "li")

	// Asked twice, the same pointer comes back: nothing is allocated per call, so nothing is owed.
	again, aerr := sciter_app.tag(first)
	testing.expect_value(t, aerr, nil)
	testing.expect(t, raw_data(name) == raw_data(again), "a tag is interned, not built per call")

	// And two different elements with the same tag share it.
	items, ierr := sciter_app.select_all(root, "li", context.temp_allocator)
	testing.expect_value(t, ierr, nil)
	if len(items) >= 2 {
		second, _ := sciter_app.tag(items[1])
		testing.expect(t, raw_data(name) == raw_data(second), "the table is keyed by name, not element")
	}

	// Remove the element the string came from, finalizing it, and the string is still there.
	_, rerr := sciter_app.remove_element(first, true)
	testing.expect_value(t, rerr, nil)
	sciter_app.windowless_heartbeat(&g_view, 16 * time.Millisecond)
	testing.expect_value(t, name, "li")

	// Put the document back: this file's tests share one window.
	testing.expect_value(t, sciter_app.load_html(window, DOC), nil)
	testing.expect_value(t, name, "li")
}

// The DOM half of the scoped constructors: wrapping an element or a node for script hands back a Value
// that owns a reference, and the wrap is exactly the shape that gets dropped - it is written to be
// passed somewhere, not to be kept.
@(test)
test_the_scoped_dom_wraps_release_the_value_and_not_the_element :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	root, _ := sciter_app.root(window)
	target, terr := sciter_app.select_first(root, "#summary")
	testing.expect_value(t, terr, nil)

	sciter_app.track_resources(true)
	defer sciter_app.track_resources(true)
	before := sciter_app.outstanding_resources()

	{
		wrapped, werr := sciter_app.scoped_element_to_value(target)
		testing.expect_value(t, werr, nil)
		back, berr := sciter_app.element_from_value(&wrapped)
		testing.expect_value(t, berr, nil)
		testing.expect_value(t, back, target)

		node, nerr := sciter_app.node_from_element(target)
		testing.expect_value(t, nerr, nil)
		as_value, verr := sciter_app.scoped_node_to_value(node)
		testing.expect_value(t, verr, nil)
		kind, _ := sciter_app.value_type(&as_value)
		testing.expect(t, kind != .UNDEFINED, "a wrapped node is a real Value")
	}

	after := sciter_app.outstanding_resources()
	testing.expect_value(t, after[.Value], before[.Value])

	// The element is untouched by any of it: the Value held its own reference, not the caller's.
	tag_name, gerr := sciter_app.tag(target)
	testing.expect_value(t, gerr, nil)
	testing.expect(t, tag_name != "", "the element outlives the Value that wrapped it")
}
