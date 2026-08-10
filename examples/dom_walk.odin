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
