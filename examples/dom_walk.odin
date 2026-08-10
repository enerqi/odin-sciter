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

	// --- building elements ----------------------------------------------------------------------
	//
	// The other way round from set_html: make the element, then put it where it goes. This is what
	// content coming from data wants, and the only way to *move* an element rather than re-create it.

	// The reference that comes back is yours and stays yours after the insert, so unuse it either way.
	extra, eerr := sciter_app.make_element("li", "written by Odin, not by markup")
	if eerr == nil {
		defer sciter_app.unuse_element(extra)
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
	if n, cerr := sciter_app.child_count(list); cerr == nil {
		for i in 0 ..< n {
			item, _ := sciter_app.child(list, i)
			line, _ := sciter_app.text(item, context.temp_allocator)
			fmt.printfln("  %d %s", i, line)
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
	// document, so these three disagree - a wrapper that ignored the origin would return one rect.
	testing.expect(t, from_root.y != from_container.y, "root and container origins must differ")
	testing.expect(t, from_view != from_root, "the view origin is not the root origin")
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

	item, merr := sciter_app.make_element("li", "fifth")
	testing.expect_value(t, merr, nil)
	testing.expect(t, item != nil)
	defer sciter_app.unuse_element(item)

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

	item, _ := sciter_app.make_element("li", "<b>not bold</b>")
	defer sciter_app.unuse_element(item)
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

	first, _ := sciter_app.make_element("li", "zeroth")
	defer sciter_app.unuse_element(first)
	testing.expect_value(t, sciter_app.insert_element(first, list, 0), nil)

	at_zero, _ := sciter_app.child(list, 0)
	testing.expect_value(t, at_zero, first)

	// Past the end is not an error - it lands at the end. `max(int)` is the interesting one: handed
	// to the engine as written it segfaults rather than appending, so `insert_element` clamps to the
	// child count and this is the regression test for that.
	tail, _ := sciter_app.make_element("li", "way past")
	defer sciter_app.unuse_element(tail)
	testing.expect_value(t, sciter_app.insert_element(tail, list, max(int)), nil)

	after, _ := sciter_app.child_count(list)
	testing.expect_value(t, after, before + 2)
	at_end, _ := sciter_app.child(list, after - 1)
	testing.expect_value(t, at_end, tail)

	// And a moderate over-run behaves the same way.
	spare, _ := sciter_app.make_element("li", "also past")
	defer sciter_app.unuse_element(spare)
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

	copy, cerr := sciter_app.clone_element(list)
	testing.expect_value(t, cerr, nil)
	defer sciter_app.unuse_element(copy)

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
	outer, _ := sciter_app.make_element("div", "")
	defer sciter_app.unuse_element(outer)
	inner, _ := sciter_app.make_element("span", "inner")
	defer sciter_app.unuse_element(inner)

	testing.expect_value(t, sciter_app.insert_element(inner, outer), nil)
	testing.expect_value(t, sciter_app.child_count(outer) or_else -1, 1)

	testing.expect_value(t, sciter_app.insert_element(outer, list), nil)
	html, _ := sciter_app.html(outer, true, context.temp_allocator)
	testing.expect_value(t, html, "<div><span>inner</span></div>")

	// Markup does not: `set_html` needs a document, and says so with INVALID_HWND rather than quietly
	// doing nothing. Insert first, then set the markup.
	orphan, _ := sciter_app.make_element("li", "")
	defer sciter_app.unuse_element(orphan)
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
	copy, _ := sciter_app.clone_element(list)
	defer sciter_app.unuse_element(copy)

	child, _ := sciter_app.child(copy, 0)
	readable, rerr := sciter_app.text(child, context.temp_allocator)
	testing.expect_value(t, rerr, nil)
	testing.expect(t, readable != "", "a detached element's children are readable")

	testing.expect_value(t, sciter_app.set_text(child, "nope"), sciter_app.Error(sciter.Scdom_Result.PASSIVE_HANDLE))
	testing.expect_value(t, sciter_app.use_element(child), nil)
	testing.expect_value(
		t,
		sciter_app.set_text(child, "still nope"),
		sciter_app.Error(sciter.Scdom_Result.PASSIVE_HANDLE),
	)
	testing.expect_value(t, sciter_app.unuse_element(child), nil)

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
	testing.expect_value(t, sciter_app.remove_element(doomed), nil)
	testing.expect_value(t, sciter_app.child_count(list) or_else -1, before - 1)

	// finalize = false: out of the document but still alive, holding the reference this call took on
	// the caller's behalf. Without that reference the handle would be dangling here, and reading it
	// would be a segfault rather than an error - which is why the wrapper takes it.
	detached, _ := sciter_app.child(list, 0)
	text_before, _ := sciter_app.text(detached, context.temp_allocator)
	testing.expect_value(t, sciter_app.remove_element(detached, finalize = false), nil)
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
	testing.expect_value(t, sciter_app.unuse_element(detached), nil)
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
}

// `SciterGetElementUID` works; `SciterGetElementByUID` does not resolve what it produces on the
// vendored 6.x engine. Every combination fails with OPERATION_FAILED - the element's own window handle
// and the root one, an element that has been `use_element`ed and one that has not, a freshly made
// element and the document root - and the UIDs themselves come back near the top of the u32 range
// (0xFFFFFC31 and neighbours), which suggests the two calls no longer share a numbering.
//
// So this test pins both halves. If the lookup ever starts working, the second half fails and that is
// the signal to delete this comment rather than a regression.
@(test)
test_element_uid_is_readable_but_not_resolvable :: proc(t: ^testing.T) {
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

	// The lookup, however, refuses a UID this engine just handed out.
	back, berr := sciter_app.element_by_uid(window, uid)
	testing.expect_value(t, berr, sciter_app.Error(sciter.Scdom_Result.OPERATION_FAILED))
	testing.expect_value(t, back, sciter_app.Element(nil))

	// And an invented one fails the same way, which is why the failure above is not a diagnosis.
	_, missing := sciter_app.element_by_uid(window, 0xFFFF_FFF0)
	testing.expect(t, missing != nil)
}
