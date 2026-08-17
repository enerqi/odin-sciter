// The smallest complete application: a model, one render, one handler, and the four rules.
//
//   just example app_skeleton
//   odin test examples/app_skeleton.odin -file      # needs a display; skips itself without one
//
// `getting-started.md` ends with five calls and a window. `task_list` is a whole application at a
// thousand lines. This is the step between them: about two hundred lines that do nothing clever, laid
// out the way an application should be, so that the shape is visible without an application on top of
// it. Copy it and start deleting.
//
// The four rules it exists to demonstrate, each one a place a first program goes wrong:
//
//  1. **The model is the truth; the document is a projection of it.** `App.items` is an ordinary Odin
//     slice. Nothing reads state back out of the DOM to decide anything - every command mutates the
//     model and calls `render`, which walks the model and writes the list. One direction of data flow,
//     and the entire class of bug where the two disagree does not exist. `task_list` argues the same
//     thing at length; this is the two-page version.
//
//  2. **User text is escaped on the way in.** `set_html` parses what it is given, so an item called
//     `<script>` is an injection rather than a title. `escape_html` is four lines and is not optional.
//
//  3. **Temp memory does not outlive the callback that allocated it.** Every callback that runs your
//     code unwinds `context.temp_allocator` to the mark it had when the engine called in - that is what
//     gives an application driven by `run` a temp boundary at all, since `run` never returns to your
//     code in between. So a handler may allocate scratch as freely as it likes and pay nothing, and
//     **anything it keeps has to be cloned**: `add_item` clones the entry text into `app.allocator`.
//     Storing the temp string instead is a use-after-free that reads back as garbage, and it is the
//     mistake this file's `test_a_kept_title_survives_the_handler_that_read_it` exists to catch.
//     `docs/rules.md` rule 4 is the whole rule.
//
//  4. **Every `Value` the engine hands you owes a release, so reach for `scoped_` first.** `read_entry`
//     uses `scoped_element_value`, which is `element_value` plus the release at the end of the scope.
//     The unscoped procedures are for a Value that has to outlive the scope; for the local read - which
//     is nearly all of them - the scoped twin is the one to reach for and the leak cannot happen. A
//     batch whose size is decided at run time is a `Value_Scope` (`docs/rules.md` rule 2).
//
// Two smaller things worth copying, both of which used to be a line every program had to know:
//
//  - **`init` installs the debug output.** Without one, a CSS typo and a script error are silent, and on
//    Windows the engine's fallback can be fatal. It is on by default; `init(debug_output = false)` opts
//    out.
//  - **The `App` lives in `main`'s frame and does not move.** The engine stores the handler's address,
//    so a handler that moves is a dangling pointer inside the engine. A local in `main`, a `new`, or a
//    global all work; a handler in a slice that reallocates does not.
//
// Nothing here needs a script tag, and there is not one in the document: HTML and CSS for the layout,
// Odin for every behaviour. Mixing is fine and `call_odin_from_js` shows it - this shows you do not
// have to.
package main

import "../sciter_app"
import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"

// ---------------------------------------------------------------------------------------------------
// The document
//
// Layout and look only, and no script. `#list` is empty: Odin fills it in, and keeps filling it in.

DOC :: `<html>
<head><style>
  html    { background: #1e1e2e; color: #cdd6f4; font: 15px system; }
  body    { margin: 0; height: *; flow: vertical; }
  header  { padding: .8em 1em; flow: horizontal; border-bottom: 1px solid #313244; }
  #entry  { width: *; padding: .45em .6em; margin-right: .5em; border-radius: 4px;
            background: #313244; color: #cdd6f4; border: 1px solid #45475a; }
  #add    { padding: .45em 1em; border-radius: 4px; background: #89b4fa; color: #11111b; }
  #list   { width: *; height: *; overflow-y: auto; margin: 0; padding: 0; list-style-type: none; }
  li      { flow: horizontal; padding: .5em 1em; border-bottom: 1px solid #313244; }
  li .box { width: 2em; background: transparent; color: #a6e3a1; border: none; }
  li .title { width: *; }
  li.done .title { color: #6c7086; text-decoration: line-through; }
  footer  { padding: .5em 1em; font-size: .85em; color: #6c7086; }
</style></head>
<body>
  <header>
    <input id="entry" type="text" placeholder="what needs doing?">
    <button id="add">add</button>
  </header>
  <ul id="list"></ul>
  <footer id="status"></footer>
</body>
</html>`

// ---------------------------------------------------------------------------------------------------
// The model
//
// Rule 1: this is the truth. The document is what it looks like.

Item :: struct {
	title: string,
	done:  bool,
}

App :: struct {
	window:    sciter_app.Window,
	items:     [dynamic]Item,

	// The engine keeps this address for as long as the handler is attached, so the `App` it is embedded
	// in must not move. See the header.
	handler:   sciter_app.Event_Handler,

	// Where anything the application keeps comes from - the item titles, in this file. Named rather
	// than implied, because rule 3 is exactly the question "which allocator does this outlive".
	allocator: runtime.Allocator,
}

app_init :: proc(app: ^App, window: sciter_app.Window, allocator := context.allocator) {
	app.window = window
	app.allocator = allocator
	app.items = make([dynamic]Item, allocator)
	app.handler = sciter_app.Event_Handler {
		subscription = {.BEHAVIOR_EVENT},
		on_event     = on_event,
		user_data    = app,
	}
}

app_destroy :: proc(app: ^App) {
	for item in app.items {
		delete(item.title, app.allocator)
	}
	delete(app.items)
	app^ = {}
}

// Rule 3, and the only line in this file that has to be a clone: `title` arrives as scratch owned by
// the callback that read it, and the model outlives that callback.
add_item :: proc(app: ^App, title: string) {
	append(&app.items, Item{title = strings.clone(title, app.allocator)})
}

toggle_item :: proc(app: ^App, index: int) {
	if 0 <= index && index < len(app.items) {
		app.items[index].done = !app.items[index].done
	}
}

done_count :: proc(app: ^App) -> (n: int) {
	for item in app.items {
		if item.done {n += 1}
	}
	return
}

// ---------------------------------------------------------------------------------------------------
// The render
//
// The whole list, from the model, every time. That is not a performance strategy - `workbench` is the
// example about not doing this to ten thousand rows - it is the simplest thing that cannot go out of
// step, and for a list a person will read it is also fast enough.

render :: proc(app: ^App) -> sciter_app.Error {
	root := sciter_app.root(app.window) or_return
	list := sciter_app.select_first(root, "#list") or_return

	// Scratch, in a callback: the arena is unwound when the handler that called this returns, so a
	// render costs nothing over the life of the program however often it runs.
	b := strings.builder_make(context.temp_allocator)
	for item, i in app.items {
		fmt.sbprintf(
			&b,
			`<li class="%s"><button class="box" data-index="%d">%s</button><span class="title">%s</span></li>`,
			"done" if item.done else "",
			i,
			"x" if item.done else "&#183;",
			escape_html(item.title, context.temp_allocator), // rule 2
		)
	}
	sciter_app.set_html(list, strings.to_string(b)) or_return

	status := sciter_app.select_first(root, "#status") or_return
	return sciter_app.set_text(status, fmt.tprintf("%d of %d done", done_count(app), len(app.items)))
}

// Rule 2. Four characters, and `set_html` is a parser: without this an item called `<b>hi` changes the
// document's structure, and one called `<script>` is worse than that.
escape_html :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for r in s {
		switch r {
		case '&':
			strings.write_string(&b, "&amp;")
		case '<':
			strings.write_string(&b, "&lt;")
		case '>':
			strings.write_string(&b, "&gt;")
		case '"':
			strings.write_string(&b, "&quot;")
		case:
			strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------------------------------
// The handler
//
// One handler for the whole window, because `render` replaces the rows on every change and a handler
// attached to a row would go with them. `attach_window_handler` hears elements that do not exist yet.

on_event :: proc(handler: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	app := (^App)(handler.user_data)

	be, ok := sciter_app.behavior_event(event)
	if !ok || be.code != .BUTTON_CLICK || be.phase != .Bubbling {
		return false
	}

	// Scratch again, and note there is no `defer delete` anywhere in this procedure: everything below
	// is temp memory, and the package gives the arena back when this returns.
	id, _ := sciter_app.attribute(be.target, "id", context.temp_allocator)
	if id == "add" {
		if title, has := read_entry(app); has {
			add_item(app, title)
			clear_entry(app)
			render(app)
		}
		return true
	}

	if index, is_row := row_index(be.target); is_row {
		toggle_item(app, index)
		render(app)
		return true
	}
	return false
}

// Rule 4: `scoped_element_value` is `element_value` with the release attached to this scope, so the
// Value is gone by the time this returns and the string handed back is the caller's temp copy of it.
read_entry :: proc(app: ^App) -> (title: string, ok: bool) {
	root := sciter_app.root(app.window) or_else nil
	entry := sciter_app.select_first(root, "#entry") or_else nil
	if entry == nil {
		return "", false
	}

	value, err := sciter_app.scoped_element_value(entry)
	if err != nil {
		return "", false
	}
	text, terr := sciter_app.value_to_string(&value, context.temp_allocator)
	if terr != nil {
		return "", false
	}

	trimmed := strings.trim_space(text)
	return trimmed, trimmed != ""
}

clear_entry :: proc(app: ^App) {
	root := sciter_app.root(app.window) or_else nil
	entry := sciter_app.select_first(root, "#entry") or_else nil
	if entry == nil {
		return
	}
	empty := sciter_app.value_from("")
	defer sciter_app.value_clear(&empty) // a Value this code made, so this code releases it
	sciter_app.set_element_value(entry, &empty)
}

// The row a button belongs to, from the attribute `render` wrote. Reading the index out of the document
// is not a violation of rule 1: the attribute is part of the projection this code emitted, not state
// the document is keeping on the application's behalf.
row_index :: proc(element: sciter_app.Element) -> (index: int, ok: bool) {
	raw, err := sciter_app.attribute(element, "data-index", context.temp_allocator)
	if err != nil || raw == "" {
		return 0, false
	}
	return strconv.parse_int(raw)
}

// ---------------------------------------------------------------------------------------------------

main :: proc() {
	if !sciter_app.load_engine() {return}
	sciter_app.init() // argc/argv, and the debug output
	defer sciter_app.shutdown()

	window, err := sciter_app.create_window({width = 460, height = 420})
	if err != nil {
		fmt.eprintln("could not create a window:", err)
		return
	}
	if lerr := sciter_app.load_html(window, DOC, "about:blank"); lerr != nil {
		fmt.eprintln("could not load the document:", lerr)
		return
	}

	// In `main`'s frame, so its address is stable for as long as the engine holds it.
	app: App
	app_init(&app, window)
	defer app_destroy(&app)

	add_item(&app, "read docs/rules.md")
	add_item(&app, "write something with <angle brackets> in it")

	sciter_app.attach_window_handler(window, &app.handler)
	if rerr := render(&app); rerr != nil {
		fmt.eprintln("could not render:", rerr)
		return
	}

	sciter_app.show(window)
	sciter_app.run() // returns when the window closes
}

// ---------------------------------------------------------------------------------------------------
// Tests
//
// A windowless view rather than a window: it needs no visible desktop and it is what the rest of the
// suite uses for document-level tests. The rules above are what these pin.

@(private = "file")
g_view: sciter_app.Windowless_View

@(private = "file")
have_display :: proc() -> bool {
	when ODIN_OS == .Darwin {
		when ODIN_TEST {
			fmt.println("macOS: a test thread cannot create a window - see docs/MACOS-CHECKLIST.md")
			return false
		} else {
			return true
		}
	} else {
		return true
	}
}

@(private = "file")
test_app :: proc(t: ^testing.T, app: ^App) -> (ok: bool) {
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}
	if !have_display() {return false}

	// A test binary reaches the engine without going through an application's `init`, so it installs
	// the handler itself. On Windows this is not about visibility: with none installed a CSS warning
	// arrives as an exception and Odin's test runner treats that as fatal.
	sciter_app.set_default_debug_output()

	if g_view.window == nil {
		// The engine keeps the view for the life of the process, so it is not the test runner's
		// tracking allocator's business - otherwise every test after this reports it as a leak.
		context.allocator = runtime.default_allocator()

		v, err := sciter_app.create_windowless({width = 460, height = 420})
		testing.expect_value(t, err, nil)
		if v.window == nil {
			return false
		}
		g_view = v
	}

	testing.expect_value(t, sciter_app.load_html(g_view.window, DOC, "about:blank"), nil)
	for i in 0 ..< 8 {
		sciter_app.windowless_heartbeat(&g_view, time.Duration(i) * 16 * time.Millisecond)
		sciter_app.paint_windowless(&g_view)
	}

	app_init(app, g_view.window)
	sciter_app.attach_window_handler(g_view.window, &app.handler)
	return true
}

@(private = "file")
rows :: proc(app: ^App) -> []sciter_app.Element {
	root, _ := sciter_app.root(app.window)
	list, _ := sciter_app.select_first(root, "#list")
	found, _ := sciter_app.select_all(list, "li", context.temp_allocator)
	return found
}

// Rule 1, in the direction that matters: the document has exactly what the model has, and it got there
// by rendering rather than by anyone editing the DOM in place.
@(test)
test_the_document_is_a_projection_of_the_model :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer app_destroy(&app)

	testing.expect_value(t, len(rows(&app)), 0)

	add_item(&app, "one")
	add_item(&app, "two")
	testing.expect_value(t, render(&app), nil)
	testing.expect_value(t, len(rows(&app)), 2)

	root, _ := sciter_app.root(app.window)
	status, _ := sciter_app.select_first(root, "#status")
	text, _ := sciter_app.text(status, context.temp_allocator)
	testing.expect_value(t, text, "0 of 2 done")
}

// Rule 2. `set_html` is a parser, so the escape is the difference between a title and a document
// change. Without `escape_html` the `<b>` below becomes an element and the assertion on the row's text
// reads "bold" with the tag gone.
@(test)
test_user_text_is_escaped_rather_than_parsed :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer app_destroy(&app)

	add_item(&app, "<b>bold</b> & <sharp>")
	testing.expect_value(t, render(&app), nil)

	list := rows(&app)
	testing.expect_value(t, len(list), 1)
	if len(list) != 1 {return}

	title, _ := sciter_app.select_first(list[0], ".title")
	text, _ := sciter_app.text(title, context.temp_allocator)
	testing.expect_value(t, text, "<b>bold</b> & <sharp>")

	// And no element came out of it: the row has the two the renderer wrote and nothing else.
	inner, _ := sciter_app.select_all(list[0], "*", context.temp_allocator)
	testing.expect_value(t, len(inner), 2)
}

// Rule 3, and this is the test that would have caught the bug in three of this repository's own
// examples. `add_item` clones; if it kept the temp string the handler read instead, the title reads
// back as whatever landed in that memory afterwards - which is not a crash, and not a leak, but wrong
// text on screen some time later.
@(test)
test_a_kept_title_survives_the_handler_that_read_it :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer app_destroy(&app)

	root, _ := sciter_app.root(app.window)
	entry, _ := sciter_app.select_first(root, "#entry")
	add, _ := sciter_app.select_first(root, "#add")

	TITLE :: "a title long enough to be a real allocation rather than anything the compiler folds away"
	typed := sciter_app.value_from(TITLE)
	defer sciter_app.value_clear(&typed)
	testing.expect_value(t, sciter_app.set_element_value(entry, &typed), nil)

	// Through the handler, which is where the temp arena is unwound.
	_, err := sciter_app.send_event(add, .BUTTON_CLICK, source = add)
	testing.expect_value(t, err, nil)

	// Churn the arena the handler was using. A title that was still pointing into it reads as
	// something else from here on; a cloned one does not care.
	for _ in 0 ..< 64 {
		scratch := make([]u8, 8 * 1024, context.temp_allocator)
		scratch[0] = 0xAA
	}

	testing.expect_value(t, len(app.items), 1)
	if len(app.items) != 1 {return}
	testing.expect_value(t, app.items[0].title, TITLE)

	// The entry is cleared on the way out, so the next add is not the same item again.
	value, verr := sciter_app.scoped_element_value(entry)
	testing.expect_value(t, verr, nil)
	left, _ := sciter_app.value_to_string(&value, context.temp_allocator)
	testing.expect_value(t, left, "")
}

// The command path end to end: a click on a row's button reaches the model and comes back out as a
// class on the row. Rule 1 again - the handler changed the model, and the row is different because
// `render` ran, not because anything set a class.
@(test)
test_a_click_goes_model_first_and_comes_back_as_a_render :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer app_destroy(&app)

	add_item(&app, "first")
	add_item(&app, "second")
	testing.expect_value(t, render(&app), nil)

	list := rows(&app)
	testing.expect_value(t, len(list), 2)
	if len(list) != 2 {return}

	box, _ := sciter_app.select_first(list[1], ".box")
	_, err := sciter_app.send_event(box, .BUTTON_CLICK, source = box)
	testing.expect_value(t, err, nil)

	testing.expect(t, !app.items[0].done, "the click must reach one item, not both")
	testing.expect(t, app.items[1].done, "the second item is the one that was clicked")

	// The rows were rebuilt, so re-read them rather than reusing the handles above.
	after := rows(&app)
	testing.expect_value(t, len(after), 2)
	if len(after) != 2 {return}
	class, _ := sciter_app.attribute(after[1], "class", context.temp_allocator)
	testing.expect_value(t, class, "done")

	root, _ := sciter_app.root(app.window)
	status, _ := sciter_app.select_first(root, "#status")
	text, _ := sciter_app.text(status, context.temp_allocator)
	testing.expect_value(t, text, "1 of 2 done")
}

// Rule 4: the scoped read leaves nothing behind. The engine's own resource ledger is what says so -
// `track_resources` counts references the Odin allocator cannot see.
@(test)
test_the_scoped_read_releases_what_it_read :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer app_destroy(&app)

	root, _ := sciter_app.root(app.window)
	entry, _ := sciter_app.select_first(root, "#entry")
	typed := sciter_app.value_from("something to read back")
	defer sciter_app.value_clear(&typed)
	testing.expect_value(t, sciter_app.set_element_value(entry, &typed), nil)

	sciter_app.track_resources(true)
	defer sciter_app.track_resources(false)
	before := sciter_app.outstanding_resources()

	for _ in 0 ..< 32 {
		title, has := read_entry(&app)
		testing.expect(t, has, "the entry has text in it")
		testing.expect_value(t, title, "something to read back")
	}

	testing.expect_value(t, sciter_app.outstanding_resources(), before)
}
