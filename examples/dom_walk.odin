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

DOC :: `<html>
<head><style>
  html  { background: #1e1e2e; color: #cdd6f4; font: 16px system; }
  body  { padding: 2em; margin: 0; }
  h1    { color: #89b4fa; margin-top: 0; }
  li    { padding: .15em 0; }
  .done { color: #a6e3a1; }
  .todo { color: #f9e2af; }
  #summary { margin-top: 1em; padding: .6em 1em; background: #313244; border-radius: 4px; }
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
	if _, err := sciter_app.select_first(root, "#nothing-matches-this"); err != nil {
		fmt.println("selector for a missing element returned:", err)
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

	sciter_app.show(window)
	sciter_app.run()
	sciter_app.shutdown()
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

@(private = "file")
have_display :: proc() -> bool {
	when ODIN_OS == .Windows || ODIN_OS == .Darwin {
		// DISPLAY and WAYLAND_DISPLAY are X11/Wayland variables and are simply absent here, so testing
		// for them would skip every windowed test on those platforms forever - silently, which is the
		// worst way for a test to not run. A desktop session is the normal case on both, and a session
		// that genuinely cannot open a window fails visibly at create_window instead.
		return true
	} else {
		return(
			os.get_env("DISPLAY", context.temp_allocator) != "" ||
			os.get_env("WAYLAND_DISPLAY", context.temp_allocator) != "" \
		)
	}
}

@(private = "file")
g_window: sciter_app.Window

@(private = "file")
test_window :: proc(t: ^testing.T) -> (window: sciter_app.Window, ok: bool) {
	if !have_display() {
		fmt.println("no DISPLAY or WAYLAND_DISPLAY - skipping, this test needs a window")
		return nil, false
	}
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}

	if g_window == nil {
		// The engine holds onto the argv it is given and the window for the life of the process, so
		// both are allocated outside the test runner's tracking allocator - otherwise every test
		// reports them as a leak.
		context.allocator = runtime.default_allocator()

		sciter_app.init()

		w, err := sciter_app.create_window({width = 400, height = 300})
		testing.expect_value(t, err, nil)
		if w == nil {
			return nil, false
		}
		g_window = w
	}

	// Reload, so each test sees the document unmodified by the one before it.
	testing.expect_value(t, sciter_app.load_html(g_window, DOC), nil)
	return g_window, true
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

	// A detached node belongs to the caller until it is inserted.
	created, err := sciter_app.make_text_node(" appended")
	testing.expect_value(t, err, nil)

	target, _ := sciter_app.node_from_element(summary)
	testing.expect_value(t, sciter_app.node_insert(target, .APPEND, created), nil)

	// The element's flattened text now includes what the node carries.
	after, terr := sciter_app.text(summary, context.temp_allocator)
	testing.expect_value(t, terr, nil)
	testing.expect(t, strings.has_suffix(after, " appended"), after)
}
