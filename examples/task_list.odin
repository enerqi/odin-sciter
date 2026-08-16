// A whole application, small but complete: a task list.
//
//   just example task_list
//   odin test examples/task_list.odin -file      # needs a display; skips itself without one
//
// Every other example here shows one thing. This one shows how the things fit together, which is the
// question left over after reading them: where does the state live, who owns the truth, what happens
// when the user presses a key, and how does any of it survive being closed.
//
// The shape it argues for, and the reason the file is laid out in this order:
//
//  1. **The model is the truth and the DOM is a projection of it.** `App.tasks` is an ordinary Odin
//     slice. Nothing reads state back out of the document to decide anything; `render` walks the model
//     and writes the list, and every command mutates the model and re-renders. That is one direction of
//     data flow and it removes the entire class of bug where the two disagree.
//  2. **The document has no script in it at all.** Not a line. Every behaviour below - clicks, keys,
//     editing, selection - is Odin. That is the distinctive thing about these bindings: HTML and CSS
//     for the layout, a real systems language for the logic, and no JavaScript in between. (Mixing is
//     fine and `call_odin_from_js` shows it; this shows you do not have to.)
//  3. **User text is escaped on the way in.** `set_html` parses what it is given, so a task called
//     `<script>` is an injection, not a title. `escape_html` is four lines and is not optional.
//  4. **State is a Value, so persistence is nearly free.** The model converts to a Sciter Value, which
//     renders itself as JSON and parses back - no serializer to write and none to keep in step.
package main

import "../sciter_app"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// ---------------------------------------------------------------------------------------------------
// The document
//
// Layout and look only. The <ul> is empty: Odin fills it in, and keeps filling it in.

DOC :: `<html>
<head><style>
  html   { background: #1e1e2e; color: #cdd6f4; font: 16px system; }
  body   { margin: 0; padding: 0; height: *; flow: vertical; }
  header { padding: 1em 1.2em; flow: horizontal; border-bottom: 1px solid #313244; }
  header h1 { margin: 0; font-size: 1.2em; color: #89b4fa; width: *; }
  #entry { width: *; padding: .5em .7em; border-radius: 4px;
           background: #313244; color: #cdd6f4; border: 1px solid #45475a; }
  #list  { width: *; height: *; overflow-y: auto; margin: 0; padding: 0; list-style-type: none; }
  li     { flow: horizontal; padding: .55em 1.2em; border-bottom: 1px solid #313244; }
  li:current { background: #313244; }
  li .box   { width: 1.4em; color: #a6e3a1; }
  li .title { width: *; }
  .done .title { color: #6c7086; text-decoration: line-through; }
  footer { padding: .6em 1.2em; font-size: .85em; color: #6c7086; }
  footer b { color: #89b4fa; }
</style></head>
<body>
  <header>
    <h1>tasks</h1>
  </header>
  <header>
    <input id="entry" type="text" placeholder="what needs doing?">
  </header>
  <ul id="list"></ul>
  <footer id="status"></footer>
</body>
</html>`

// ---------------------------------------------------------------------------------------------------
// The model
//
// Plain Odin. It knows nothing about Sciter, which is what makes the commands below testable without a
// window and what keeps the rendering honest - there is nowhere for state to hide.

Task :: struct {
	id:    int,
	title: string, // owned by the App
	done:  bool,
}

App :: struct {
	// The window handler is embedded so `on_event` can cast the handler pointer straight back to the
	// application. The engine stores this address, so an App must not move once attached.
	using handler: sciter_app.Event_Handler,
	window:        sciter_app.Window,
	tasks:         [dynamic]Task,
	next_id:       int,
	selected:      int, // index into `tasks`; -1 when the list is empty
	path:          string, // where the state is saved
	allocator:     runtime.Allocator,
}

app_init :: proc(app: ^App, path: string, allocator := context.allocator) {
	app.tasks = make([dynamic]Task, allocator)
	app.selected = -1
	app.path = path
	app.allocator = allocator
}

app_destroy :: proc(app: ^App) {
	for task in app.tasks {
		delete(task.title, app.allocator)
	}
	delete(app.tasks)
}

// --- commands. Each one is a whole change to the model, and each one is the unit the tests drive.

add_task :: proc(app: ^App, title: string) -> (index: int, ok: bool) {
	trimmed := strings.trim_space(title)
	if trimmed == "" {
		return -1, false // nothing to add, and not an error worth reporting
	}

	app.next_id += 1
	append(&app.tasks, Task{id = app.next_id, title = strings.clone(trimmed, app.allocator)})
	app.selected = len(app.tasks) - 1
	return app.selected, true
}

toggle_task :: proc(app: ^App, index: int) -> bool {
	if index < 0 || index >= len(app.tasks) {
		return false
	}
	app.tasks[index].done = !app.tasks[index].done
	return true
}

remove_task :: proc(app: ^App, index: int) -> bool {
	if index < 0 || index >= len(app.tasks) {
		return false
	}
	delete(app.tasks[index].title, app.allocator)
	ordered_remove(&app.tasks, index)

	// Keep the selection on something that exists, which is the whole of the "what is selected now"
	// question and the sort of thing worth doing in one place rather than at every call site.
	app.selected = clamp_selection(app, index)
	return true
}

move_selection :: proc(app: ^App, by: int) {
	if len(app.tasks) == 0 {
		app.selected = -1
		return
	}
	app.selected = clamp_selection(app, app.selected + by)
}

@(private = "file")
clamp_selection :: proc(app: ^App, index: int) -> int {
	if len(app.tasks) == 0 {
		return -1
	}
	return min(max(index, 0), len(app.tasks) - 1)
}

remaining :: proc(app: ^App) -> (n: int) {
	for task in app.tasks {
		if !task.done {
			n += 1
		}
	}
	return
}

// ---------------------------------------------------------------------------------------------------
// Rendering
//
// One procedure, called after every change. It is not a diff and does not try to be: rebuilding a few
// hundred rows of HTML is well under a frame, and the version that patches the DOM in place is the
// version with the state-drift bug in it. Reach for finer-grained updates when a profile says to.

render :: proc(app: ^App) -> sciter_app.Error {
	root := sciter_app.root(app.window) or_return
	list := sciter_app.select_first(root, "#list") or_return

	builder := strings.builder_make(context.temp_allocator)
	for task in app.tasks {
		fmt.sbprintf(
			&builder,
			`<li id="task-%d" class="%s"><span class="box">%s</span><span class="title">%s</span></li>`,
			task.id,
			"done" if task.done else "",
			"&#10003;" if task.done else "&#9633;",
			// Never interpolate user text into markup unescaped: `set_html` parses it, so a task
			// called `<b>x` would become markup and one called `<script>` would be worse.
			escape_html(task.title, context.temp_allocator),
		)
	}
	sciter_app.set_html(list, strings.to_string(builder)) or_return

	// The selection is a CSS state rather than a class, so the stylesheet can say `li:current` and
	// nothing has to remember to take the old one off.
	if app.selected >= 0 && app.selected < len(app.tasks) {
		// `selected` indexes `app.tasks`, not the DOM. The two line up only because `set_html` above
		// just wrote one `<li>` per task in order - hence the explicit conversion rather than one type
		// silently standing in for the other.
		if row, err := sciter_app.child(list, sciter_app.Child_Index(app.selected)); err == nil {
			sciter_app.set_element_state(row, {.CURRENT}) or_return
			sciter_app.scroll_to_view(row)
		}
	}

	status := sciter_app.select_first(root, "#status") or_return
	sciter_app.set_html(
		status,
		fmt.tprintf(
			"<b>%d</b> of <b>%d</b> left &middot; ↑↓ select &middot; space toggles &middot; del removes",
			remaining(app),
			len(app.tasks),
		),
	) or_return
	return nil
}

// The four characters that change the meaning of markup. Sciter's parser is a browser's, so the rules
// are a browser's.
escape_html :: proc(s: string, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	for r in s {
		switch r {
		case '&':
			strings.write_string(&builder, "&amp;")
		case '<':
			strings.write_string(&builder, "&lt;")
		case '>':
			strings.write_string(&builder, "&gt;")
		case '"':
			strings.write_string(&builder, "&quot;")
		case:
			strings.write_rune(&builder, r)
		}
	}
	return strings.to_string(builder)
}

// ---------------------------------------------------------------------------------------------------
// Input
//
// One handler on the window, subscribed to the three groups this application has opinions about. The
// engine delivers everything to it; the switch decides what is a command.

on_event :: proc(handler: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	app := (^App)(handler)

	// A click on a row selects it; a click on its checkbox toggles it. Which row is answered by the
	// DOM, not by hit-testing coordinates: `select_parent` walks up from whatever was actually hit.
	if be, ok := sciter_app.behavior_event(event); ok && be.phase != .Sinking {
		#partial switch be.code {
		case .BUTTON_CLICK:
			return false
		}
	}

	if me, ok := sciter_app.mouse_event(event); ok && me.phase != .Sinking {
		if me.code == .MOUSE_UP {
			if row, err := sciter_app.select_parent(me.target, "li"); err == nil {
				if index, found := index_of_row(app, row); found {
					app.selected = index
					// The checkbox column toggles; the rest of the row only selects.
					if tag, _ := sciter_app.tag(me.target); tag == "span" {
						if class, _ := sciter_app.attribute(me.target, "class", context.temp_allocator);
						   class == "box" {
							toggle_task(app, index)
						}
					}
					render(app)
					return true
				}
			}
		}
		return false
	}

	if ke, ok := sciter_app.key_event(event); ok && ke.phase != .Sinking && ke.code == .DOWN {
		// The entry field owns the keyboard while it has the focus, except for the two keys that mean
		// something to the application rather than to the text.
		focused, _ := sciter_app.focus_element(app.window)
		in_entry := false
		if focused != nil {
			if id, _ := sciter_app.attribute(focused, "id", context.temp_allocator); id == "entry" {
				in_entry = true
			}
		}

		switch ke.key_code {
		case KEY_ENTER:
			if in_entry {
				commit_entry(app)
				return true
			}
		case KEY_UP:
			if !in_entry {
				move_selection(app, -1)
				render(app)
				return true
			}
		case KEY_DOWN:
			if !in_entry {
				move_selection(app, +1)
				render(app)
				return true
			}
		case KEY_SPACE:
			if !in_entry {
				toggle_task(app, app.selected)
				render(app)
				return true
			}
		case KEY_DELETE:
			if !in_entry {
				remove_task(app, app.selected)
				render(app)
				return true
			}
		}
	}
	return false
}

// Virtual key codes, as the engine reports them in `Key_Event.key_code` for `.DOWN` and `.UP`. They are
// the platform-independent set in sciter-x-key-codes.h; only the five this application uses are named.
KEY_ENTER :: 13
KEY_SPACE :: 32
KEY_DELETE :: 46
KEY_UP :: 38
KEY_DOWN :: 40

// Takes what is in the entry field, adds it, and clears the field.
commit_entry :: proc(app: ^App) {
	root, err := sciter_app.root(app.window)
	if err != nil {
		return
	}
	entry, eerr := sciter_app.select_first(root, "#entry")
	if eerr != nil {
		return
	}

	value, verr := sciter_app.element_value(entry)
	defer sciter_app.value_clear(&value)
	if verr != nil {
		return
	}
	title, terr := sciter_app.value_to_string(&value, context.temp_allocator)
	if terr != nil {
		return
	}

	if _, added := add_task(app, title); added {
		empty := sciter_app.value_from("")
		defer sciter_app.value_clear(&empty)
		sciter_app.set_element_value(entry, &empty)
		render(app)
	}
}

// Which task a row stands for. The id is written into the markup and read back out of it, which is the
// one piece of state the DOM is allowed to hold - it is a name for a model row, not the row itself.
index_of_row :: proc(app: ^App, row: sciter_app.Element) -> (index: int, ok: bool) {
	id, err := sciter_app.attribute(row, "id", context.temp_allocator)
	if err != nil || !strings.has_prefix(id, "task-") {
		return -1, false
	}
	for task, i in app.tasks {
		if fmt.tprintf("task-%d", task.id) == id {
			return i, true
		}
	}
	return -1, false
}

// ---------------------------------------------------------------------------------------------------
// Persistence
//
// The model becomes a Sciter Value, and a Value renders itself as JSON and parses back. That is the
// whole serializer: no struct tags, no reflection, and nothing to keep in step with the model beyond
// these two procedures.

to_value :: proc(app: ^App) -> (out: sciter_app.Value) {
	out = sciter_app.value_make_array(len(app.tasks))
	for task, i in app.tasks {
		row: sciter_app.Value

		title := sciter_app.value_from(task.title)
		sciter_app.value_set(&row, "title", &title)
		sciter_app.value_clear(&title)

		done := sciter_app.value_from(task.done)
		sciter_app.value_set(&row, "done", &done)
		sciter_app.value_clear(&done)

		sciter_app.value_set_at(&out, i, &row)
		sciter_app.value_clear(&row)
	}
	return
}

// Replaces the model with what `value` holds. A row that is not shaped as expected is skipped rather
// than failing the load: a state file is not a protocol, and losing one row beats losing the lot.
from_value :: proc(app: ^App, value: ^sciter_app.Value) -> sciter_app.Error {
	n := sciter_app.value_len(value) or_return

	for task in app.tasks {
		delete(task.title, app.allocator)
	}
	clear(&app.tasks)
	app.next_id = 0

	for i in 0 ..< n {
		row, err := sciter_app.value_at(value, i)
		if err != nil {
			continue
		}
		defer sciter_app.value_clear(&row)

		title_value, terr := sciter_app.value_get(&row, "title")
		defer sciter_app.value_clear(&title_value)
		if terr != nil {
			continue
		}
		title, serr := sciter_app.value_to_string(&title_value, context.temp_allocator)
		if serr != nil {
			continue
		}

		index, added := add_task(app, title)
		if !added {
			continue
		}

		done_value, derr := sciter_app.value_get(&row, "done")
		defer sciter_app.value_clear(&done_value)
		if derr == nil {
			done, _ := sciter_app.value_to_bool(&done_value)
			app.tasks[index].done = done
		}
	}

	app.selected = -1 if len(app.tasks) == 0 else 0
	return nil
}

save :: proc(app: ^App) -> bool {
	value := to_value(app)
	defer sciter_app.value_clear(&value)

	json, err := sciter_app.value_to_display_string(&value, .JSON_LITERAL, context.temp_allocator)
	if err != nil {
		return false
	}
	return os.write_entire_file(app.path, transmute([]u8)json) == nil
}

// A missing file is not a failure - it is the first run.
load :: proc(app: ^App) -> bool {
	data, rerr := os.read_entire_file(app.path, context.temp_allocator)
	if rerr != nil {
		return false
	}
	value, err := sciter_app.value_parse(string(data), .JSON_LITERAL)
	defer sciter_app.value_clear(&value)
	if err != nil {
		fmt.eprintfln("%s is not readable as JSON, starting empty: %v", app.path, err)
		return false
	}
	return from_value(app, &value) == nil
}

// ---------------------------------------------------------------------------------------------------

STATE_FILE :: "target/task_list.json"

main :: proc() {
	if !sciter_app.load_engine() {
		os.exit(1)
	}
	sciter_app.set_default_debug_output()

	if err := sciter_app.init(); err != nil {
		fmt.eprintln("init failed:", err)
		os.exit(1)
	}

	// The App outlives the window and the engine holds its address, so it is heap-allocated and never
	// moved. Everything it owns is freed at the end, in one place.
	app := new(App)
	defer free(app)
	app_init(app, STATE_FILE)
	defer app_destroy(app)

	if !load(app) {
		// First run: something to look at beats an empty list.
		add_task(app, "read docs/getting-started.md")
		add_task(app, "write a <thing> with an & in it")
		add_task(app, "ship it")
		toggle_task(app, 0)
		app.selected = 0
	}

	window, werr := sciter_app.create_window({width = 560, height = 620})
	if werr != nil {
		fmt.eprintln("could not create a window:", werr)
		os.exit(1)
	}
	app.window = window

	if err := sciter_app.load_html(window, DOC); err != nil {
		fmt.eprintln("could not load the document:", err)
		os.exit(1)
	}

	app.subscription = {.MOUSE, .KEY, .BEHAVIOR_EVENT}
	app.on_event = on_event
	if err := sciter_app.attach_window_handler(window, app); err != nil {
		fmt.eprintln("could not attach the handler:", err)
		os.exit(1)
	}

	if err := render(app); err != nil {
		fmt.eprintln("could not render:", err)
		os.exit(1)
	}

	sciter_app.show(window)
	sciter_app.run()

	// `run` returns when the last window closes, which is the only "on exit" hook there is - and it is
	// enough, because the engine is still up and the model was never in the engine to begin with.
	if !save(app) {
		fmt.eprintfln("could not write %s", STATE_FILE)
	} else {
		fmt.printfln("%d tasks saved to %s", len(app.tasks), STATE_FILE)
	}
	sciter_app.shutdown()
}

// ---------------------------------------------------------------------------------------------------
// Tests
//
// Two kinds, and the split is the point of the architecture above. The model tests need no window at
// all, because the model is plain Odin. The rendering and input tests need one.

@(test)
test_add_and_remove :: proc(t: ^testing.T) {
	app: App
	app_init(&app, "")
	defer app_destroy(&app)

	i, ok := add_task(&app, "first")
	testing.expect(t, ok)
	testing.expect_value(t, i, 0)
	testing.expect_value(t, app.selected, 0)

	add_task(&app, "second")
	add_task(&app, "third")
	testing.expect_value(t, len(app.tasks), 3)

	// Ids are handed out once and never reused, so a row's identity survives its neighbours going.
	testing.expect_value(t, app.tasks[0].id, 1)
	testing.expect_value(t, app.tasks[2].id, 3)

	// Blank input is not a task, and does not disturb the selection.
	app.selected = 1
	_, blank := add_task(&app, "   ")
	testing.expect(t, !blank)
	testing.expect_value(t, len(app.tasks), 3)
	testing.expect_value(t, app.selected, 1)

	// Titles are trimmed on the way in, so the model never holds the user's stray spaces.
	add_task(&app, "  padded  ")
	testing.expect_value(t, app.tasks[3].title, "padded")

	testing.expect(t, remove_task(&app, 3))
	testing.expect_value(t, len(app.tasks), 3)
	testing.expect(t, !remove_task(&app, 99), "an index past the end is refused, not clamped")
}

@(test)
test_selection_follows_removal :: proc(t: ^testing.T) {
	app: App
	app_init(&app, "")
	defer app_destroy(&app)

	add_task(&app, "a")
	add_task(&app, "b")
	add_task(&app, "c")

	// Removing the middle leaves the selection where the next row now is.
	app.selected = 1
	remove_task(&app, 1)
	testing.expect_value(t, app.selected, 1)
	testing.expect_value(t, app.tasks[1].title, "c")

	// Removing the last row pulls the selection back rather than leaving it past the end.
	app.selected = 1
	remove_task(&app, 1)
	testing.expect_value(t, len(app.tasks), 1)
	testing.expect_value(t, app.selected, 0)

	// And emptying the list means nothing is selected, which is what -1 says.
	remove_task(&app, 0)
	testing.expect_value(t, app.selected, -1)
	testing.expect_value(t, len(app.tasks), 0)
}

@(test)
test_move_selection_clamps :: proc(t: ^testing.T) {
	app: App
	app_init(&app, "")
	defer app_destroy(&app)

	move_selection(&app, +1)
	testing.expect_value(t, app.selected, -1) // nothing to select

	add_task(&app, "a")
	add_task(&app, "b")
	app.selected = 0

	move_selection(&app, -1)
	testing.expect_value(t, app.selected, 0) // stops at the top rather than wrapping

	move_selection(&app, +1)
	move_selection(&app, +1)
	testing.expect_value(t, app.selected, 1) // and at the bottom
}

@(test)
test_remaining_counts_undone :: proc(t: ^testing.T) {
	app: App
	app_init(&app, "")
	defer app_destroy(&app)

	add_task(&app, "a")
	add_task(&app, "b")
	testing.expect_value(t, remaining(&app), 2)

	testing.expect(t, toggle_task(&app, 0))
	testing.expect_value(t, remaining(&app), 1)

	testing.expect(t, toggle_task(&app, 0)) // it toggles rather than sets
	testing.expect_value(t, remaining(&app), 2)

	testing.expect(t, !toggle_task(&app, -1), "no selection is not a task")
}

@(test)
test_escape_html :: proc(t: ^testing.T) {
	testing.expect_value(t, escape_html("plain", context.temp_allocator), "plain")
	testing.expect_value(
		t,
		escape_html(`<script>alert("x")</script> & co`, context.temp_allocator),
		`&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; co`,
	)
	// Non-ASCII passes through: this escapes markup, it does not transliterate.
	testing.expect_value(t, escape_html("café ✓", context.temp_allocator), "café ✓")
}

@(test)
test_save_and_load_round_trip :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	path := "target/task_list_test.json"
	defer os.remove(path)

	saved: App
	app_init(&saved, path)
	defer app_destroy(&saved)

	add_task(&saved, "first")
	add_task(&saved, `a <tricky> "title" & co`)
	add_task(&saved, "third")
	toggle_task(&saved, 1)
	testing.expect(t, save(&saved), "the state file was written")

	loaded: App
	app_init(&loaded, path)
	defer app_destroy(&loaded)

	testing.expect(t, load(&loaded), "and read back")
	testing.expect_value(t, len(loaded.tasks), 3)
	testing.expect_value(t, loaded.tasks[0].title, "first")
	// JSON round-trips the characters that matter in markup untouched: escaping is a rendering
	// concern, not a storage one, and doing it twice would be a bug.
	testing.expect_value(t, loaded.tasks[1].title, `a <tricky> "title" & co`)
	testing.expect(t, loaded.tasks[1].done)
	testing.expect(t, !loaded.tasks[0].done)
	testing.expect_value(t, loaded.selected, 0)
}

// **Guarded on Windows for the same reason as the three diagnostics tests in `eval.odin`** - read the
// long comment there, and `docs/odin-test-runner-windows.patch`. The short version: parsing the broken
// JSON below makes the engine throw a C++ exception and catch it itself, which is ordinary control
// flow; Odin's Windows test runner stops a test for *any* first-chance exception, and then hangs
// waiting for a test that recovered and finished. With the patch applied this file is 11/11 green with
// no guard, so this comes off in one line once the fix is in a released Odin.
when ODIN_OS != .Windows {

	@(test)
	test_load_of_a_missing_or_broken_file :: proc(t: ^testing.T) {
		if !engine_loaded(t) {return}

		missing: App
		app_init(&missing, "target/task_list_no_such_file.json")
		defer app_destroy(&missing)
		testing.expect(t, !load(&missing), "a missing file is a first run, not a failure")
		testing.expect_value(t, len(missing.tasks), 0)

		path := "target/task_list_broken.json"
		defer os.remove(path)
		testing.expect_value(t, os.write_entire_file(path, transmute([]u8)string("{ this is not json")), nil)

		broken: App
		app_init(&broken, path)
		defer app_destroy(&broken)
		testing.expect(t, !load(&broken), "and neither is an unreadable one")
		testing.expect_value(t, len(broken.tasks), 0)
	}

} // when ODIN_OS != .Windows - see above

// --- the windowed half

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
engine_loaded :: proc(t: ^testing.T) -> bool {
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
	return true
}

@(private = "file")
// Shared by every test in this file, and created on first use. That is deliberate - a window per test
// would be slow, and closing one is itself hazardous (see `close` in sciter_app/window.odin) - but it
// makes the tests here order-coupled: **a test that changes the document must put it back**, usually by
// reloading `DOC`, or it breaks a later test and the failure points at the wrong one.
g_window: sciter_app.Window

@(private = "file")
test_window :: proc(t: ^testing.T) -> (window: sciter_app.Window, ok: bool) {
	if !have_display() {
		fmt.println("skipping - this test needs a window")
		return nil, false
	}
	engine_loaded(t)

	if g_window == nil {
		// The engine keeps the argv and the window for the life of the process; allocating them outside
		// the test runner's tracking allocator keeps them from being reported as leaks.
		context.allocator = runtime.default_allocator()

		sciter_app.init()

		w, err := sciter_app.create_window({width = 480, height = 520})
		testing.expect_value(t, err, nil)
		if w == nil {
			return nil, false
		}
		g_window = w
		sciter_app.show(w)
	}

	testing.expect_value(t, sciter_app.load_html(g_window, DOC), nil)
	for _ in 0 ..< 20 {
		sciter_app.run_once()
	}
	return g_window, true
}

@(test)
test_render_projects_the_model :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	app: App
	app_init(&app, "")
	defer app_destroy(&app)
	app.window = window

	add_task(&app, "alpha")
	add_task(&app, "beta")
	toggle_task(&app, 1)
	app.selected = 1

	testing.expect_value(t, render(&app), nil)

	root, _ := sciter_app.root(window)
	rows, err := sciter_app.select_all(root, "#list li", context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(rows), 2)

	first, _ := sciter_app.text(rows[0], context.temp_allocator)
	testing.expect(t, strings.contains(first, "alpha"), "the title is in the row")

	// The done row carries the class the stylesheet strikes through, and the selected row carries the
	// :current state rather than a class.
	class, _ := sciter_app.attribute(rows[1], "class", context.temp_allocator)
	testing.expect_value(t, class, "done")
	state, _ := sciter_app.element_state(rows[1])
	testing.expect(t, .CURRENT in state, "the selection is a CSS state")

	// Re-rendering after a change replaces the projection wholesale; nothing is left over.
	remove_task(&app, 0)
	testing.expect_value(t, render(&app), nil)
	after, _ := sciter_app.select_all(root, "#list li", context.temp_allocator)
	testing.expect_value(t, len(after), 1)
	only, _ := sciter_app.text(after[0], context.temp_allocator)
	testing.expect(t, strings.contains(only, "beta"))
}

@(test)
test_render_escapes_user_text :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	app: App
	app_init(&app, "")
	defer app_destroy(&app)
	app.window = window

	// The whole point of `escape_html`: this must become one row of text, not markup.
	add_task(&app, `<b>bold</b> & <i>x`)
	testing.expect_value(t, render(&app), nil)

	root, _ := sciter_app.root(window)
	rows, _ := sciter_app.select_all(root, "#list li", context.temp_allocator)
	testing.expect_value(t, len(rows), 1)

	// No <b> was created anywhere in the list...
	bold, berr := sciter_app.select_first(rows[0], "b")
	testing.expect_value(t, berr, sciter_app.Error(sciter_app.Api_Error.Not_Found))
	_ = bold

	// ...and the characters survive as text.
	text, _ := sciter_app.text(rows[0], context.temp_allocator)
	testing.expect(t, strings.contains(text, "<b>bold</b> & <i>x"), "the title reads back verbatim")
}

@(test)
test_keyboard_drives_the_model :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	app := new(App) // the engine holds its address, so it must not move
	defer free(app)
	app_init(app, "")
	defer app_destroy(app)
	app.window = window

	add_task(app, "alpha")
	add_task(app, "beta")
	add_task(app, "gamma")
	app.selected = 0
	render(app)

	app.subscription = {.MOUSE, .KEY, .BEHAVIOR_EVENT}
	app.on_event = on_event
	testing.expect_value(t, sciter_app.attach_window_handler(window, app), nil)
	defer sciter_app.detach_window_handler(window, app)

	root, _ := sciter_app.root(window)
	list, _ := sciter_app.select_first(root, "#list")

	// Real key events, through the behaviors, the way `input.odin` does it - so this exercises the
	// handler the application actually installs rather than calling `move_selection` directly.
	press :: proc(el: sciter_app.Element, key: u32) {
		sciter_app.send_key(el, .DOWN, key)
		for _ in 0 ..< 10 {
			sciter_app.run_once()
		}
	}

	press(list, KEY_DOWN)
	testing.expect_value(t, app.selected, 1)

	press(list, KEY_SPACE)
	testing.expect(t, app.tasks[1].done, "space toggled the selected task")
	testing.expect_value(t, remaining(app), 2)

	press(list, KEY_DELETE)
	testing.expect_value(t, len(app.tasks), 2)
	testing.expect_value(t, app.tasks[1].title, "gamma")
	testing.expect_value(t, app.selected, 1)

	press(list, KEY_UP)
	testing.expect_value(t, app.selected, 0)

	// And the document agrees with the model, which is the invariant the whole design exists to keep.
	rows, _ := sciter_app.select_all(root, "#list li", context.temp_allocator)
	testing.expect_value(t, len(rows), len(app.tasks))
}

@(test)
test_entry_field_adds_a_task :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	app := new(App)
	defer free(app)
	app_init(app, "")
	defer app_destroy(app)
	app.window = window
	render(app)

	root, _ := sciter_app.root(window)
	entry, _ := sciter_app.select_first(root, "#entry")

	testing.expect_value(t, sciter_app.set_focus(entry), nil)
	for _ in 0 ..< 10 {
		sciter_app.run_once()
	}
	testing.expect_value(t, sciter_app.send_text(entry, "typed in"), nil)
	for _ in 0 ..< 10 {
		sciter_app.run_once()
	}

	commit_entry(app)
	testing.expect_value(t, len(app.tasks), 1)
	testing.expect_value(t, app.tasks[0].title, "typed in")

	// And the field is cleared, so the next task does not start with the last one.
	value, _ := sciter_app.element_value(entry)
	defer sciter_app.value_clear(&value)
	s, _ := sciter_app.value_to_string(&value, context.temp_allocator)
	testing.expect_value(t, s, "")

	// Committing an empty field adds nothing.
	commit_entry(app)
	testing.expect_value(t, len(app.tasks), 1)
}
