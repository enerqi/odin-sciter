// A harder application than `task_list`: ten thousand rows, live, editable, drawn in part by Odin.
//
//   just example workbench
//   odin test examples/workbench.odin -file      # needs a display; skips itself without one
//
// `task_list` is the gentle "how do the pieces fit" example and is deliberately small. This is the one
// that finds out what hurts. It exists for two reasons:
//
//   1. **It is the experiment [`VDOM.md`](../docs/VDOM.md) asks for.** That note argues that a
//      retained-diff layer might be worth 1,500 lines, and says the honest first move is to write a
//      hard example *without* one and see what actually breaks. This is that example, written entirely
//      with `set_html`, and the "what actually hurt" section of `VDOM.md` was written from it.
//   2. It reaches parts of the API the other examples do not: a virtualised list, a widget the
//      stylesheet asks for by name that paints itself, a worker thread feeding the UI, a theme
//      switched at runtime, and view state stored as a `Value` so it persists with no serializer.
//
// The four things it teaches, in the order they bite:
//
//   - **Virtualisation is a scroll handler and some arithmetic.** Ten thousand rows do not go in the
//     document. Only the ~30 that fit on screen do, inside a spacer tall enough to make the scrollbar
//     honest. `set_html` on 30 rows is cheap however many rows the model has.
//   - **`set_html` destroys focus, and there is no way around it from outside.** Editing a cell and
//     scrolling one line ends the edit. The workaround here is to keep the edit in the *model* and
//     restore it after every render - which works, and is exactly the bespoke patching `VDOM.md`'s
//     third row describes. Doing it twice is what tells you whether the general version is worth it.
//   - **A `behavior:` name is how a widget gets into a virtualised list at all.** The sparkline is
//     painted by Odin through `.DRAW`. Every re-render destroys and recreates every row, so anything
//     attached with `attach_handler` would have to be re-attached each frame; a stylesheet-driven
//     behavior is re-attached by the engine, for free, because it is a property of the CSS rule.
//   - **The worker never touches the DOM.** It produces rows and calls `post_callback`; the update
//     happens on the engine's thread in `on_posted`.
package main

import sciter ".."
import "../sciter_app"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// ---------------------------------------------------------------------------------------------------
// The document
//
// Layout only, and no script at all. `#viewport` is the scrolling box; `#spacer` inside it is stretched
// to the full height of the model so the scrollbar is the right size; `#rows` is absolutely positioned
// inside the spacer and holds only the visible window.

DOC :: `<html>
<head><style>
  html { background: var(--bg); color: var(--fg); font: 14px system; }

  /* Sciter's own layout model, not standard flexbox: flow: and flex units, which is what
     docs/html-css-js.md says to reach for. display:flex parses and then does not lay out the way a
     browser would - this document was written with it first, and the rows came out stacked in a
     column. There are no backticks in this comment on purpose: the whole document is an Odin raw
     string, and a backtick would end it. */
  body { padding: 0; margin: 0; flow: vertical; height: 100%; width: 100%; }

  :root { --bg:#1e1e2e; --fg:#cdd6f4; --dim:#a6adc8; --line:#313244; --panel:#181825;
          --accent:#89b4fa; --warn:#f38ba8; }
  :root.light { --bg:#eff1f5; --fg:#4c4f69; --dim:#6c6f85; --line:#ccd0da; --panel:#e6e9ef;
                --accent:#1e66f5; --warn:#d20f39; }

  #toolbar { flow: horizontal; padding: .6em 1em; background: var(--panel);
             border-bottom: 1px solid var(--line); }
  #toolbar > * { margin-right: 1em; }
  #toolbar input { width: 14em; }
  #toolbar #count { width: *; color: var(--dim); }
  #status { padding: .4em 1em; background: var(--panel); border-top: 1px solid var(--line);
            color: var(--dim); font-size: 12px; }

  #viewport { width: 100%; height: *; overflow-y: scroll; background: var(--bg); }
  #spacer   { position: relative; width: 100%; }
  #rows     { position: absolute; left: 0; top: 0; width: 100%; }

  .row  { flow: horizontal; height: 24px; border-bottom: 1px solid var(--line);
          vertical-align: middle; }
  .row.odd { background: var(--panel); }
  .row.sel { background: var(--accent); color: var(--bg); }
  .cell { padding: 0 .6em; overflow: hidden; }
  .c-id    { width: 5em; color: var(--dim); }
  .c-name  { width: 16em; }
  .c-value { width: 6em; text-align: right; }
  .c-spark { width: *; height: 18px; }
  .row.sel .c-id { color: var(--bg); }

  /* The whole reason the sparkline survives a re-render: the stylesheet asks for it by name, so the
     engine attaches it to every row the renderer creates, including the ones created a moment ago. */
  .c-spark { behavior: sparkline; }

  .editing input { width: 100%; height: 20px; }
</style></head>
<body>
  <div id="toolbar">
    <input id="filter" type="text" placeholder="filter by name" />
    <span id="count" class="grow"></span>
    <button id="theme">theme</button>
    <button id="feed">start feed</button>
  </div>
  <div id="viewport"><div id="spacer"><div id="rows"></div></div></div>
  <div id="status"></div>
</body>
</html>`

// ---------------------------------------------------------------------------------------------------
// The model
//
// Ten thousand of these. Nothing in the document holds any of it; the DOM is a projection of whatever
// `visible_rows` says is on screen right now.

ROW_HEIGHT :: 24 // must match `.row` in the stylesheet - the arithmetic below depends on it
SPARK_POINTS :: 24
TOTAL_ROWS :: 10_000

Row :: struct {
	id:     int,
	name:   string, // owned by the App's allocator
	value:  f64,
	spark:  [SPARK_POINTS]f32, // 0..1, oldest first
	pinned: bool,
}

// What survives a restart, and the reason it is a `Value` rather than a struct: a Value renders itself
// as JSON and parses back, so there is no serializer to write and none to keep in step. See
// `view_to_value` / `view_from_value`.
View :: struct {
	filter:   string, // owned by the App's allocator
	selected: int, // a row id, not an index - indices move when the filter changes
	scroll:   int, // pixels from the top of the spacer
	light:    bool,
}

App :: struct {
	using handler: sciter_app.Event_Handler,
	window:        sciter_app.Window,
	allocator:     runtime.Allocator,
	rows:          [dynamic]Row,
	view:          View,

	// The filtered index, rebuilt whenever the filter changes. Holding indices rather than copies is
	// what keeps a filter keystroke from touching ten thousand strings.
	matching:      [dynamic]int,

	// The cell being edited, as a row id, and the text so far. Kept in the *model* precisely because
	// the DOM cannot be trusted to hold it: every re-render destroys the `<input>` it lives in.
	editing:       int,
	edit_text:     string,

	// Set by the worker, read on the engine's thread.
	feed:          Feed,
	rendered:      int, // how many rows are in the document right now
	renders:       int, // how many times `render` has run, for the status line
}

// ---------------------------------------------------------------------------------------------------
// The worker
//
// The only cross-thread call that is safe is `post_callback`. The worker mutates nothing the engine can
// see: it picks a row, computes a new sample, and posts an integer. The update itself happens in
// `on_posted`, on the engine's thread, where the DOM is reachable again.

FEED_TICK :: 0x_F33D

Feed :: struct {
	thread:  ^thread.Thread,
	running: bool,
	stop:    bool,
	mutex:   sync.Mutex,
	posted:  int,
	seed:    u64,
}

feed_start :: proc(app: ^App) {
	if app.feed.running {
		return
	}
	app.feed.stop = false
	app.feed.running = true
	app.feed.thread = thread.create_and_start_with_data(
	app,
	proc(raw: rawptr) {
		app := (^App)(raw)
		for {
			sync.mutex_lock(&app.feed.mutex)
			stop := app.feed.stop
			sync.mutex_unlock(&app.feed.mutex)
			if stop {
				break
			}

			// Post, do not touch. Everything the engine owns is off limits from here.
			sciter_app.post_callback(app.window, FEED_TICK, 0)
			app.feed.posted += 1
			time.sleep(80 * time.Millisecond)
		}
	},
	)
}

feed_stop :: proc(app: ^App) {
	if !app.feed.running {
		return
	}
	sync.mutex_lock(&app.feed.mutex)
	app.feed.stop = true
	sync.mutex_unlock(&app.feed.mutex)
	thread.join(app.feed.thread)
	thread.destroy(app.feed.thread)
	app.feed = {}
}

// ---------------------------------------------------------------------------------------------------
// Building and filtering the model

app_init :: proc(app: ^App, allocator := context.allocator) {
	app.allocator = allocator
	app.rows = make([dynamic]Row, 0, TOTAL_ROWS, allocator)
	app.matching = make([dynamic]int, 0, TOTAL_ROWS, allocator)
	app.editing = -1
	app.view.selected = -1

	NOUNS := [?]string{"sensor", "pump", "valve", "boiler", "chiller", "fan", "motor", "heater", "gauge", "relay"}
	PLACES := [?]string{"north", "south", "east", "west", "roof", "cellar", "annex", "yard"}

	// A generator of its own rather than `core:math/rand`, for one reason: the tests below assert
	// counts against this data, so it has to be identical on every machine and every Odin version.
	seed: u64 = 20260812

	for i in 0 ..< TOTAL_ROWS {
		row := Row {
			id    = i + 1,
			name  = fmt.aprintf(
				"%s-%s-%03d",
				NOUNS[next_below(&seed, len(NOUNS))],
				PLACES[next_below(&seed, len(PLACES))],
				i % 1000,
				allocator = allocator,
			),
			value = next_unit(&seed) * 100,
		}
		for j in 0 ..< SPARK_POINTS {
			row.spark[j] = f32(0.1 + next_unit(&seed) * 0.8)
		}
		append(&app.rows, row)
	}
	refilter(app)
}

// xorshift64*, so the sample data is the same everywhere without pinning a `core:math/rand` version.
next :: proc(state: ^u64) -> u64 {
	x := state^
	x ~= x >> 12
	x ~= x << 25
	x ~= x >> 27
	state^ = x
	return x * 0x2545F4914F6CDD1D
}

next_below :: proc(state: ^u64, n: int) -> int {
	return int(next(state) >> 33) % n
}

next_unit :: proc(state: ^u64) -> f64 {
	return f64(next(state) >> 11) / f64(1 << 53)
}

app_destroy :: proc(app: ^App) {
	feed_stop(app)
	for row in app.rows {
		delete(row.name, app.allocator)
	}
	delete(app.rows)
	delete(app.matching)
	delete(app.view.filter, app.allocator)
	delete(app.edit_text, app.allocator)
}

// Rebuilds the filtered index. Pinned rows always match, which is what makes "pin a row, then filter it
// away" a case worth having.
refilter :: proc(app: ^App) {
	clear(&app.matching)
	for row, i in app.rows {
		if row.pinned || app.view.filter == "" || strings.contains(row.name, app.view.filter) {
			append(&app.matching, i)
		}
	}
}

set_filter :: proc(app: ^App, text: string) {
	if app.view.filter == text {
		return
	}
	delete(app.view.filter, app.allocator)
	app.view.filter = strings.clone(text, app.allocator)
	refilter(app)
	// A filter change invalidates the scroll: the list is a different length now.
	app.view.scroll = 0
}

// ---------------------------------------------------------------------------------------------------
// Virtualisation
//
// The whole technique, in one struct. `first` and `count` are the window of `matching` that is in the
// document; `offset` is where that window has to be drawn so it lines up under the scrollbar.

Window_Of_Rows :: struct {
	first:  int,
	count:  int,
	offset: int, // pixels
	total:  int, // pixels - the height the spacer is stretched to
}

// `overscan` rows above and below the visible band, so that a scroll of one or two rows does not
// have to re-render at all. It is the cheapest half of the optimisation and the easiest to forget.
OVERSCAN :: 4

visible_rows :: proc(app: ^App, viewport_height: int) -> Window_Of_Rows {
	total := len(app.matching) * ROW_HEIGHT

	first := app.view.scroll / ROW_HEIGHT - OVERSCAN
	first = max(first, 0)

	// Clamp to the model as well as to zero. A scroll position can outrun the list - a filter that
	// just shortened it, a fling, a restored position from a longer run - and an unclamped `first`
	// leaves the window pointing past the end. That is the bug every virtualised list has once.
	first = min(first, len(app.matching))

	visible := (viewport_height + ROW_HEIGHT - 1) / ROW_HEIGHT + OVERSCAN * 2
	count := min(visible, len(app.matching) - first)
	count = max(count, 0)

	return {first = first, count = count, offset = first * ROW_HEIGHT, total = total}
}

// ---------------------------------------------------------------------------------------------------
// Rendering
//
// One `set_html` per frame, over the visible window only. Everything `VDOM.md` lists as a cost of this
// approach is here, and the comments say which line pays for which.

render :: proc(app: ^App) -> sciter_app.Error {
	root := sciter_app.root(app.window) or_return
	viewport := sciter_app.select_first(root, "#viewport") or_return
	spacer := sciter_app.select_first(root, "#spacer") or_return
	rows_el := sciter_app.select_first(root, "#rows") or_return

	box, _ := sciter_app.location(viewport, .Content, .Self)
	window := visible_rows(app, int(box.height))

	// The scrollbar is a function of the *model*, not of what is in the document. This is the line that
	// makes ten thousand rows scrollable while thirty exist.
	sciter_app.set_style(spacer, "height", fmt.tprintf("%dpx", window.total)) or_return
	sciter_app.set_style(rows_el, "top", fmt.tprintf("%dpx", window.offset)) or_return

	builder := strings.builder_make(context.temp_allocator)
	for n in 0 ..< window.count {
		index := app.matching[window.first + n]
		row := &app.rows[index]

		classes := strings.builder_make(context.temp_allocator)
		strings.write_string(&classes, "row")
		if (window.first + n) % 2 == 1 {
			strings.write_string(&classes, " odd")
		}
		if row.id == app.view.selected {
			strings.write_string(&classes, " sel")
		}
		if row.id == app.editing {
			strings.write_string(&classes, " editing")
		}

		fmt.sbprintf(&builder, `<div id="r%d" class="%s">`, row.id, strings.to_string(classes))
		fmt.sbprintf(&builder, `<span class="cell c-id">%d</span>`, row.id)

		if row.id == app.editing {
			// The edit lives in the model, so it can be put back after the re-render that just
			// destroyed it. `value=` is an attribute, so it needs escaping like any other text.
			fmt.sbprintf(
				&builder,
				`<span class="cell c-name"><input type="text" value="%s" /></span>`,
				escape_html(app.edit_text, context.temp_allocator),
			)
		} else {
			// `set_html` parses what it is given, so a row called `<script>` is an injection and not a
			// name. This is not optional and it is on the caller every time - one of `VDOM.md`'s costs.
			fmt.sbprintf(
				&builder,
				`<span class="cell c-name">%s</span>`,
				escape_html(row.name, context.temp_allocator),
			)
		}

		fmt.sbprintf(&builder, `<span class="cell c-value">%.1f</span>`, row.value)

		// The sparkline's data goes into an attribute rather than into a handler, because the handler
		// does not exist yet: the engine attaches the behavior while this markup is being parsed.
		fmt.sbprintf(&builder, `<span class="cell c-spark" data-spark="%s"></span>`, spark_attribute(row))
		strings.write_string(&builder, "</div>")
	}

	sciter_app.set_html(rows_el, strings.to_string(builder)) or_return
	app.rendered = window.count
	app.renders += 1

	// And now put back what the re-render destroyed. See `restore_focus`.
	restore_focus(app)
	update_status(app)
	return nil
}

// The `set_html` above threw away the `<input>` that had the caret in it. If a cell is being edited,
// find its replacement and focus it again.
//
// **This is the workaround, and it is worth reading as evidence rather than as a technique.** It works,
// it is nine lines, and it has to be right on every path that re-renders - which is every path. That is
// what `VDOM.md`'s "targeted patching by hand" row costs in practice.
restore_focus :: proc(app: ^App) {
	if app.editing < 0 {
		return
	}
	root, err := sciter_app.root(app.window)
	if err != nil {
		return
	}
	cell, ferr := sciter_app.select_first(root, fmt.tprintf("#r%d input", app.editing))
	if ferr != nil {
		return // the edited row is scrolled out of the window - the edit survives in the model
	}
	sciter_app.set_focus(cell)
}

update_status :: proc(app: ^App) {
	root, err := sciter_app.root(app.window)
	if err != nil {
		return
	}
	if status, serr := sciter_app.select_first(root, "#status"); serr == nil {
		sciter_app.set_text(
			status,
			fmt.tprintf(
				"%d of %d rows match  ·  %d in the document  ·  %d renders  ·  %d ticks",
				len(app.matching),
				len(app.rows),
				app.rendered,
				app.renders,
				app.feed.posted,
			),
		)
	}
	if count, cerr := sciter_app.select_first(root, "#count"); cerr == nil {
		sciter_app.set_text(count, fmt.tprintf("%d rows", len(app.matching)))
	}
}

// The sparkline samples, as a compact attribute: two hex digits per point. An attribute rather than a
// Value because the behavior reads it during `.ATTACH`, before anything in Odin has a handle to the
// element it is on.
spark_attribute :: proc(row: ^Row) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for v in row.spark {
		fmt.sbprintf(&builder, "%02x", u8(clamp(v, 0, 1) * 255))
	}
	return strings.to_string(builder)
}

// `set_html` parses what it is given. Four lines, and not optional.
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
// The sparkline
//
// A widget the *stylesheet* asks for, painted by Odin. This is the piece that would be painful without
// `named_behavior`: every render destroys and recreates every row, so a handler attached by hand would
// have to be re-attached thirty times a frame. A `behavior:` name is attached by the engine as it
// parses the markup, so it costs the renderer nothing and knows nothing about it.

Sparkline :: struct {
	using handler: sciter_app.Event_Handler,
	app:           ^App,
	detached:      ^int, // the Host's counter, so a freed sparkline can still report itself
	points:        [SPARK_POINTS]f32,
	count:         int,
}

// One per element, freed on `.DETACH` - which fires for every row the next `set_html` throws away.
on_attach_behavior :: proc(
	handler: ^sciter_app.Host_Handler,
	request: ^sciter_app.Behavior_Request,
) -> ^sciter_app.Event_Handler {
	host := (^Host)(handler)
	if request.name != "sparkline" {
		return nil
	}

	spark := new(Sparkline, host.app.allocator)
	spark.app = host.app
	spark.detached = &host.detached
	spark.subscription = {.DRAW}
	spark.on_event = on_sparkline_event

	// The samples come off the element, because there is no other channel: this runs inside
	// `set_html`, before the renderer has a handle to the element it just described.
	if raw, err := sciter_app.attribute(request.element, "data-spark", context.temp_allocator); err == nil {
		spark.count = decode_spark(raw, spark.points[:])
	}

	host.attached += 1
	return spark
}

on_sparkline_event :: proc(h: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	spark := (^Sparkline)(h)

	// The only teardown hook there is - see `named_behavior`. Every re-render sends one of these per
	// row, which is the cost of `set_html` measured in allocations rather than in milliseconds.
	if event.group == {} && event.params != nil {
		if sciter.Initialization_Events((^sciter.Initialization_Params)(event.params).cmd) == .DETACH {
			spark.detached^ += 1
			free(spark, spark.app.allocator)
		}
		return false
	}

	de, ok := sciter_app.draw_event(event)
	if !ok || de.layer != .CONTENT || spark.count < 2 {
		return false
	}

	x, y := f32(de.area.x), f32(de.area.y)
	w, h := f32(de.area.width), f32(de.area.height)
	if w <= 2 || h <= 2 {
		return false
	}

	// A polyline, not a polygon: an open run of segments, which is what a sparkline is. `draw_polygon`
	// would close it back to the first point and fill it.
	points := make([][2]f32, spark.count, context.temp_allocator)
	step := (w - 2) / f32(spark.count - 1)
	for i in 0 ..< spark.count {
		points[i] = {x + 1 + f32(i) * step, y + h - 1 - spark.points[i] * (h - 2)}
	}

	sciter_app.set_line_color(de.gfx, sciter_app.rgb(0x89, 0xb4, 0xfa))
	sciter_app.set_line_width(de.gfx, 1)
	sciter_app.set_line_join(de.gfx, .ROUND)
	sciter_app.draw_polyline(de.gfx, points)

	// A dot on the newest sample, in the warning colour when it is high.
	last := points[len(points) - 1]
	hot := spark.points[spark.count - 1] > 0.8
	colour := sciter_app.rgb(0xf3, 0x8b, 0xa8) if hot else sciter_app.rgb(0xa6, 0xe3, 0xa1)
	sciter_app.set_fill_color(de.gfx, colour)
	sciter_app.set_line_color(de.gfx, colour)
	sciter_app.draw_ellipse(de.gfx, last.x, last.y, 1.5, 1.5)

	return true // this layer is ours
}

// Two hex digits per sample, as `spark_attribute` wrote them.
decode_spark :: proc(text: string, out: []f32) -> int {
	n := 0
	for i := 0; i + 1 < len(text) && n < len(out); i += 2 {
		hi, lo := hex_value(text[i]), hex_value(text[i + 1])
		if hi < 0 || lo < 0 {
			break
		}
		out[n] = f32(hi * 16 + lo) / 255
		n += 1
	}
	return n
}

hex_value :: proc(c: u8) -> int {
	switch c {
	case '0' ..= '9':
		return int(c - '0')
	case 'a' ..= 'f':
		return int(c - 'a') + 10
	case 'A' ..= 'F':
		return int(c - 'A') + 10
	}
	return -1
}

// ---------------------------------------------------------------------------------------------------
// View state as a Value
//
// The whole of `View` in and out of a Sciter `Value`, which renders itself as JSON and parses back.
// There is no serializer here and none to keep in step with the struct - `task_list` makes the same
// argument for its model, and this is the same trick applied to the parts that are *not* the model.

view_to_value :: proc(view: View) -> sciter_app.Value {
	v: sciter_app.Value

	filter := sciter_app.value_from(view.filter)
	defer sciter_app.value_clear(&filter)
	sciter_app.value_set(&v, "filter", &filter)

	// `value_from(int)` is ambiguous between the 32- and 64-bit members of the group, and the two are
	// not interchangeable on the way back: a `.BIG_INT` reads as 0 through `value_to_int`. Pick one,
	// deliberately, and read it back with its own accessor.
	selected := sciter_app.value_from(i32(view.selected))
	defer sciter_app.value_clear(&selected)
	sciter_app.value_set(&v, "selected", &selected)

	scroll := sciter_app.value_from(i32(view.scroll))
	defer sciter_app.value_clear(&scroll)
	sciter_app.value_set(&v, "scroll", &scroll)

	light := sciter_app.value_from(view.light)
	defer sciter_app.value_clear(&light)
	sciter_app.value_set(&v, "light", &light)

	return v
}

view_from_value :: proc(v: ^sciter_app.Value, allocator := context.allocator) -> (view: View) {
	view.selected = -1

	if filter, err := sciter_app.value_get(v, "filter"); err == nil {
		defer sciter_app.value_clear(&filter)
		if s, serr := sciter_app.value_to_string(&filter, context.temp_allocator); serr == nil {
			view.filter = strings.clone(s, allocator)
		}
	}
	if selected, err := sciter_app.value_get(v, "selected"); err == nil {
		defer sciter_app.value_clear(&selected)
		if n, nerr := sciter_app.value_to_int(&selected); nerr == nil {
			view.selected = int(n)
		}
	}
	if scroll, err := sciter_app.value_get(v, "scroll"); err == nil {
		defer sciter_app.value_clear(&scroll)
		if n, nerr := sciter_app.value_to_int(&scroll); nerr == nil {
			view.scroll = int(n)
		}
	}
	if light, err := sciter_app.value_get(v, "light"); err == nil {
		defer sciter_app.value_clear(&light)
		if b, berr := sciter_app.value_to_bool(&light); berr == nil {
			view.light = b
		}
	}
	if view.filter == "" {
		view.filter = strings.clone("", allocator)
	}
	return
}

// ---------------------------------------------------------------------------------------------------
// The host handler
//
// Separate from `App` because the two answer different callbacks and the engine stores both addresses:
// `Host` is what the engine asks for behaviors and posts messages to, `App` is the window's event
// handler. Keeping them apart means neither struct has to be the other's `using` parent.

Host :: struct {
	using handler: sciter_app.Host_Handler,
	app:           ^App,
	attached:      int, // sparklines created, for the tests and the "cost of set_html" argument
	detached:      int, // and destroyed
}

on_posted :: proc(handler: ^sciter_app.Host_Handler, posted: sciter_app.Posted) {
	host := (^Host)(handler)
	app := host.app
	if posted.wparam != FEED_TICK {
		return
	}

	// On the engine's thread again, so the model and the DOM are both reachable. The worker only ever
	// said "something changed"; deciding what changed is done here.
	advance_feed(app)

	// Only the rows on screen are worth redrawing - the rest are not in the document.
	render(app)
}

// Slides every sparkline along by one sample and moves the value with it. This is the "live updating"
// half: it runs at 12 Hz against ten thousand rows and only ever redraws thirty.
advance_feed :: proc(app: ^App) {
	for &row in app.rows {
		next_sample := clamp(row.spark[SPARK_POINTS - 1] + f32(next_unit(&app.feed.seed) - 0.5) * 0.3, 0.02, 0.98)
		copy(row.spark[:SPARK_POINTS - 1], row.spark[1:])
		row.spark[SPARK_POINTS - 1] = next_sample
		row.value = f64(next_sample) * 100
	}
}

// ---------------------------------------------------------------------------------------------------
// Input
//
// Every behaviour in the application, and no script anywhere in the document.

on_event :: proc(h: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	app := (^App)(h)

	if se, ok := sciter_app.scroll_event(event); ok {
		// The virtualisation trigger. `pos` is where the viewport has been scrolled to; the window of
		// rows follows from it and nothing else.
		if se.vertical && app.view.scroll != int(se.pos) {
			app.view.scroll = int(se.pos)
			render(app)
		}
		return false
	}

	if be, ok := sciter_app.behavior_event(event); ok {
		#partial switch be.code {
		case .BUTTON_CLICK:
			id, _ := sciter_app.attribute(be.target, "id", context.temp_allocator)
			switch id {
			case "theme":
				toggle_theme(app)
			case "feed":
				toggle_feed(app)
			}
			return true

		case .VALUE_CHANGED:
			id, _ := sciter_app.attribute(be.target, "id", context.temp_allocator)
			if id == "filter" {
				value, verr := sciter_app.element_value(be.target)
				if verr == nil {
					defer sciter_app.value_clear(&value)
					if text, terr := sciter_app.value_to_string(&value, context.temp_allocator); terr == nil {
						set_filter(app, text)
						render(app)
					}
				}
			} else if app.editing >= 0 {
				// The cell being edited. Its text goes into the model on every keystroke, because the
				// element holding it will not survive the next render.
				value, verr := sciter_app.element_value(be.target)
				if verr == nil {
					defer sciter_app.value_clear(&value)
					if text, terr := sciter_app.value_to_string(&value, context.temp_allocator); terr == nil {
						delete(app.edit_text, app.allocator)
						app.edit_text = strings.clone(text, app.allocator)
					}
				}
			}
			return false
		}
		return false
	}

	if me, ok := sciter_app.mouse_event(event); ok && me.code == .MOUSE_DOWN {
		if row_id, found := row_id_of(me.target); found {
			select_row(app, row_id)
			render(app)
			return true
		}
		return false
	}

	if ke, ok := sciter_app.key_event(event); ok && ke.code == .DOWN {
		switch ke.key_code {
		case 13:
			// Enter starts an edit on the selected row, or commits the one in progress.
			if app.editing >= 0 {
				commit_edit(app)
			} else if app.view.selected >= 0 {
				begin_edit(app)
			}
			render(app)
			return true
		case 27:
			if app.editing >= 0 {
				cancel_edit(app)
				render(app)
				return true
			}
		case 38:
			move_selection(app, -1); render(app); return true
		case 40:
			move_selection(app, +1); render(app); return true
		}
	}
	return false
}

// The row an element belongs to, by walking up to the `#rN` container. The DOM is read here rather than
// the model because the click arrives on whichever cell was under the pointer.
row_id_of :: proc(element: sciter_app.Element) -> (id: int, ok: bool) {
	row, err := sciter_app.select_parent(element, "div[id^=r]")
	if err != nil {
		return 0, false
	}
	text, terr := sciter_app.attribute(row, "id", context.temp_allocator)
	if terr != nil || len(text) < 2 || text[0] != 'r' {
		return 0, false
	}
	n := 0
	for c in text[1:] {
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n * 10 + int(c - '0')
	}
	return n, true
}

select_row :: proc(app: ^App, id: int) {
	if app.editing >= 0 && app.editing != id {
		commit_edit(app)
	}
	app.view.selected = id
}

move_selection :: proc(app: ^App, delta: int) {
	if len(app.matching) == 0 {
		return
	}
	current := -1
	for index, n in app.matching {
		if app.rows[index].id == app.view.selected {
			current = n
			break
		}
	}
	next := clamp(current + delta, 0, len(app.matching) - 1)
	app.view.selected = app.rows[app.matching[next]].id

	// Keep the selection on screen. This is the scroll arithmetic again, in the other direction.
	top := next * ROW_HEIGHT
	if top < app.view.scroll {
		app.view.scroll = top
	}
}

begin_edit :: proc(app: ^App) {
	for index in app.matching {
		if app.rows[index].id == app.view.selected {
			app.editing = app.view.selected
			delete(app.edit_text, app.allocator)
			app.edit_text = strings.clone(app.rows[index].name, app.allocator)
			return
		}
	}
}

commit_edit :: proc(app: ^App) {
	if app.editing < 0 {
		return
	}
	for &row in app.rows {
		if row.id == app.editing {
			delete(row.name, app.allocator)
			row.name = strings.clone(app.edit_text, app.allocator)
			break
		}
	}
	app.editing = -1
	refilter(app)
}

cancel_edit :: proc(app: ^App) {
	app.editing = -1
}

// The theme, at runtime. A class on the root element rather than `set_css`, deliberately: **`set_css`
// replaces the document's own stylesheet** rather than layering under it, so a window sheet here would
// throw away every rule above. CSS variables plus one class is the way to restyle a live document.
toggle_theme :: proc(app: ^App) {
	app.view.light = !app.view.light
	root, err := sciter_app.root(app.window)
	if err != nil {
		return
	}
	if app.view.light {
		sciter_app.set_attribute(root, "class", "light")
	} else {
		sciter_app.set_attribute(root, "class", "")
	}
}

toggle_feed :: proc(app: ^App) {
	root, err := sciter_app.root(app.window)
	if err != nil {
		return
	}
	button, berr := sciter_app.select_first(root, "#feed")
	if app.feed.running {
		feed_stop(app)
		if berr == nil {sciter_app.set_text(button, "start feed")}
	} else {
		feed_start(app)
		if berr == nil {sciter_app.set_text(button, "stop feed")}
	}
}

// ---------------------------------------------------------------------------------------------------
// The application

STATE_PATH :: "workbench-view.json"

main :: proc() {
	if !sciter_app.load_engine() {
		os.exit(1)
	}
	sciter_app.set_default_debug_output()

	if err := sciter_app.init(); err != nil {
		fmt.eprintln("init failed:", err)
		os.exit(1)
	}

	app: App
	app_init(&app)
	defer app_destroy(&app)

	// View state from the last run, if there is any. A Value parses JSON back into itself, so the
	// whole of the persistence layer is this and `save_view` below.
	load_view(&app, STATE_PATH)

	window, werr := sciter_app.create_window({width = 900, height = 620})
	if werr != nil {
		fmt.eprintln("could not create a window:", werr)
		os.exit(1)
	}
	app.window = window

	host := Host {
		app = &app,
	}
	host.on_attach_behavior = on_attach_behavior
	host.on_posted = on_posted
	// Before the load: the behavior requests arrive inside it.
	sciter_app.set_host_handler(window, &host)

	if err := sciter_app.load_html(window, DOC); err != nil {
		fmt.eprintln("could not load the document:", err)
		os.exit(1)
	}

	app.subscription = {.MOUSE, .KEY, .BEHAVIOR_EVENT, .SCROLL}
	app.on_event = on_event
	root, _ := sciter_app.root(window)
	sciter_app.attach_handler(root, &app)

	// Put the restored filter back in the box, then draw once.
	if filter, err := sciter_app.select_first(root, "#filter"); err == nil && app.view.filter != "" {
		text := sciter_app.value_from(app.view.filter)
		defer sciter_app.value_clear(&text)
		sciter_app.set_element_value(filter, &text)
	}
	if app.view.light {
		sciter_app.set_attribute(root, "class", "light")
	}
	render(&app)

	// **The behaviors are not attached yet.** `named_behavior` measures that a `behavior:` request for
	// an element in the *document being loaded* arrives inside `load_html`, before it returns. For an
	// element created later by `set_html` it does not: the request arrives on the engine's own
	// schedule, at the next turn of the pump. Counting them here reports zero; one `heartbeat` later it
	// reports one per row.
	attached_immediately := host.attached
	sciter_app.heartbeat()

	fmt.printfln(
		"%d rows in the model, %d in the document; %d sparklines attached during render, %d after one heartbeat",
		len(app.rows),
		app.rendered,
		attached_immediately,
		host.attached,
	)

	sciter_app.show(window)
	sciter_app.run()

	save_view(&app, STATE_PATH)
	sciter_app.shutdown()
}

// The whole of persistence: a Value renders itself as JSON, and parses back.
save_view :: proc(app: ^App, path: string) {
	v := view_to_value(app.view)
	defer sciter_app.value_clear(&v)

	json, err := sciter_app.value_to_display_string(&v, .JSON_LITERAL, context.temp_allocator)
	if err != nil {
		return
	}
	_ = os.write_entire_file(path, transmute([]u8)json)
}

load_view :: proc(app: ^App, path: string) {
	bytes, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return
	}
	v, err := sciter_app.value_parse(string(bytes))
	if err != nil {
		return
	}
	defer sciter_app.value_clear(&v)

	restored := view_from_value(&v, app.allocator)
	delete(app.view.filter, app.allocator)
	app.view = restored
	refilter(app)
}

// ---------------------------------------------------------------------------------------------------
// Tests
//
// The arithmetic half is headless. The rest needs a document, so it needs a window, and skips itself
// without a display. The window is never shown - see `dom_walk` for why.

@(private = "file")
have_display :: proc() -> bool {
	when ODIN_OS == .Windows || ODIN_OS == .Darwin {
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

// A fresh App and a freshly loaded document. The App and the Host are deliberately not freed: the
// engine holds both addresses for the life of the window.
@(private = "file")
test_app :: proc(t: ^testing.T) -> (app: ^App, host: ^Host, ok: bool) {
	if !have_display() {
		fmt.println("no DISPLAY or WAYLAND_DISPLAY - skipping, this test needs a window")
		return nil, nil, false
	}
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}
	context.allocator = runtime.default_allocator()

	if g_window == nil {
		sciter_app.init()
		w, err := sciter_app.create_window({width = 900, height = 620})
		testing.expect_value(t, err, nil)
		if w == nil {return nil, nil, false}
		g_window = w
	}

	app = new(App)
	app_init(app)
	app.window = g_window

	host = new(Host)
	host.app = app
	host.on_attach_behavior = on_attach_behavior
	host.on_posted = on_posted
	sciter_app.set_host_handler(g_window, host)

	testing.expect_value(t, sciter_app.load_html(g_window, DOC), nil)

	app.subscription = {.MOUSE, .KEY, .BEHAVIOR_EVENT, .SCROLL}
	app.on_event = on_event
	root, rerr := sciter_app.root(g_window)
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, sciter_app.attach_handler(root, app), nil)

	return app, host, true
}

@(private = "file")
rows_in_document :: proc(app: ^App) -> int {
	root, err := sciter_app.root(app.window)
	if err != nil {return -1}
	rows, rerr := sciter_app.select_first(root, "#rows")
	if rerr != nil {return -1}
	n, cerr := sciter_app.child_count(rows)
	if cerr != nil {return -1}
	return n
}

// ---------------------------------------------------------------------------------------------------
// The arithmetic
//
// No engine involved: this is the whole of virtualisation, and it is worth testing on its own because
// every visual bug in a virtualised list is a bug in these four numbers.

@(test)
test_the_visible_window_follows_the_scroll_position :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app_init(app)
	defer app_destroy(app)

	VIEWPORT :: 600

	// At the top: the first screenful, plus overscan below but none above.
	top := visible_rows(app, VIEWPORT)
	testing.expect_value(t, top.first, 0)
	testing.expect_value(t, top.offset, 0)
	testing.expect_value(t, top.total, TOTAL_ROWS * ROW_HEIGHT)
	testing.expect(t, top.count >= VIEWPORT / ROW_HEIGHT, "at least a screenful is rendered")
	testing.expect(t, top.count < 100, "and nowhere near ten thousand of them")

	// Scrolled by exactly one row: the window moves by one, not by a screenful.
	app.view.scroll = ROW_HEIGHT
	one := visible_rows(app, VIEWPORT)
	testing.expect_value(t, one.first, 0) // still 0, because of the overscan above
	app.view.scroll = ROW_HEIGHT * (OVERSCAN + 1)
	shifted := visible_rows(app, VIEWPORT)
	testing.expect_value(t, shifted.first, 1)
	testing.expect_value(t, shifted.offset, ROW_HEIGHT)

	// Halfway down.
	app.view.scroll = TOTAL_ROWS * ROW_HEIGHT / 2
	middle := visible_rows(app, VIEWPORT)
	testing.expect_value(t, middle.first, TOTAL_ROWS / 2 - OVERSCAN)
	testing.expect_value(t, middle.offset, middle.first * ROW_HEIGHT)
	testing.expect_value(t, middle.count, top.count)

	// **The end is where a virtualised list goes wrong.** Scrolled to the bottom, the window has to
	// stop at the last row rather than running off the end of the model.
	app.view.scroll = TOTAL_ROWS * ROW_HEIGHT
	end := visible_rows(app, VIEWPORT)
	testing.expect(t, end.first + end.count <= len(app.matching), "the window must not run past the model")
	testing.expect(t, end.count >= 0)

	// And past the end, which a fast scroll or a stale position can produce.
	app.view.scroll = TOTAL_ROWS * ROW_HEIGHT * 2
	past := visible_rows(app, VIEWPORT)
	testing.expect_value(t, past.count, 0)
	testing.expect(t, past.first + past.count <= len(app.matching))
}

// The spacer's height is a function of the model, not of the document. That is the line that makes the
// scrollbar honest while thirty rows exist.
@(test)
test_the_spacer_is_as_tall_as_the_whole_model :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app_init(app)
	defer app_destroy(app)

	full := visible_rows(app, 600)
	testing.expect_value(t, full.total, TOTAL_ROWS * ROW_HEIGHT)

	// Filtering shortens it, because the scrollbar tracks what is *shown*.
	set_filter(app, "pump-north")
	filtered := visible_rows(app, 600)
	testing.expect(t, len(app.matching) > 0, "the sample data should contain some of these")
	testing.expect(t, len(app.matching) < TOTAL_ROWS)
	testing.expect_value(t, filtered.total, len(app.matching) * ROW_HEIGHT)

	// And an empty result is a zero-height spacer with nothing in the window.
	set_filter(app, "no-such-row-anywhere")
	empty := visible_rows(app, 600)
	testing.expect_value(t, len(app.matching), 0)
	testing.expect_value(t, empty.total, 0)
	testing.expect_value(t, empty.count, 0)
}

// Filtering is over an index, not over the rows: nothing is copied and nothing is destroyed, so a
// filter keystroke costs one pass over ten thousand strings and no allocation per row.
@(test)
test_filtering_rebuilds_an_index_and_never_touches_the_rows :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app_init(app)
	defer app_destroy(app)

	before := len(app.rows)
	first_name := app.rows[0].name

	set_filter(app, "valve")
	testing.expect(t, len(app.matching) < len(app.rows))
	for index in app.matching {
		testing.expect(t, strings.contains(app.rows[index].name, "valve"))
	}

	// The model is untouched - same count, same strings, same addresses.
	testing.expect_value(t, len(app.rows), before)
	testing.expect_value(t, app.rows[0].name, first_name)

	// Clearing it brings everything back.
	set_filter(app, "")
	testing.expect_value(t, len(app.matching), before)

	// A pinned row matches whatever the filter says, which is the case that makes `refilter` more than
	// a one-liner.
	app.rows[0].pinned = true
	set_filter(app, "no-such-row-anywhere")
	testing.expect_value(t, len(app.matching), 1)
	testing.expect_value(t, app.matching[0], 0)
}

// The sparkline's samples cross into the behavior as an attribute, so the encoding has to round-trip.
@(test)
test_sparkline_samples_survive_the_attribute_encoding :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app_init(app)
	defer app_destroy(app)

	row := &app.rows[0]
	text := spark_attribute(row)
	testing.expect_value(t, len(text), SPARK_POINTS * 2)

	out: [SPARK_POINTS]f32
	n := decode_spark(text, out[:])
	testing.expect_value(t, n, SPARK_POINTS)

	// One byte per sample, so the round trip is exact to about 1/255.
	for i in 0 ..< SPARK_POINTS {
		testing.expectf(
			t,
			abs(out[i] - row.spark[i]) < 0.005,
			"sample %d: %v came back as %v",
			i,
			row.spark[i],
			out[i],
		)
	}

	// Nonsense is refused rather than decoded into garbage - the attribute is under the renderer's
	// control today, but a behavior reads whatever the document says.
	testing.expect_value(t, decode_spark("", out[:]), 0)
	testing.expect_value(t, decode_spark("zz", out[:]), 0)
	testing.expect_value(t, decode_spark("ff", out[:]), 1)
	testing.expect_value(t, decode_spark("ffzz", out[:]), 1) // stops at the first bad pair
	testing.expect_value(t, out[0], f32(1))
}

// ---------------------------------------------------------------------------------------------------
// Against the engine

// The claim the whole example rests on: ten thousand rows in the model, a few dozen in the document.
@(test)
test_only_the_visible_rows_reach_the_document :: proc(t: ^testing.T) {
	app, _, ok := test_app(t)
	if !ok {return}

	testing.expect_value(t, render(app), nil)

	testing.expect_value(t, len(app.rows), TOTAL_ROWS)
	in_document := rows_in_document(app)
	testing.expect(t, in_document > 0, "something should have been rendered")
	testing.expect(t, in_document < 100, "but not ten thousand of them")
	testing.expect_value(t, in_document, app.rendered)
}

// Scrolling renders a different window of the same model, and the ids in the document move with it.
// This is virtualisation working end to end rather than in the arithmetic alone.
@(test)
test_scrolling_replaces_the_rows_rather_than_adding_to_them :: proc(t: ^testing.T) {
	app, _, ok := test_app(t)
	if !ok {return}
	testing.expect_value(t, render(app), nil)

	first_id :: proc(app: ^App) -> string {
		root, _ := sciter_app.root(app.window)
		rows, err := sciter_app.select_first(root, "#rows")
		if err != nil {return ""}
		child, cerr := sciter_app.child(rows, 0)
		if cerr != nil {return ""}
		id, _ := sciter_app.attribute(child, "id", context.temp_allocator)
		return id
	}

	at_top := first_id(app)
	testing.expect_value(t, at_top, "r1")
	count_at_top := rows_in_document(app)

	app.view.scroll = 5_000 * ROW_HEIGHT
	testing.expect_value(t, render(app), nil)

	moved := first_id(app)
	testing.expect(t, moved != at_top, "a different part of the model should be on screen")
	testing.expect_value(t, moved, fmt.tprintf("r%d", 5_000 - OVERSCAN + 1))

	// Replaced, not appended: the document holds the same number of rows as before.
	testing.expect_value(t, rows_in_document(app), count_at_top)
}

// **The measured rule this example turns on, and it is not `named_behavior`'s.** There, a `behavior:`
// request for an element in the document being loaded arrives *inside* `load_html`. For an element
// created afterwards by `set_html` it does not: nothing is attached when `render` returns, and one
// `heartbeat` later there is one behavior per row.
//
// It matters because it is the difference between "the widget is ready to be talked to" and "the widget
// exists". Code that renders and then immediately reaches for a row's behavior finds nothing.
@(test)
test_a_behavior_is_attached_to_every_row_but_only_after_a_pump :: proc(t: ^testing.T) {
	app, host, ok := test_app(t)
	if !ok {return}

	before := host.attached
	testing.expect_value(t, render(app), nil)
	testing.expect_value(t, host.attached, before) // nothing yet

	sciter_app.heartbeat()
	testing.expect_value(t, host.attached, before + app.rendered) // one per row, now

	// And a second render throws them all away again, which is the cost of `set_html` measured in
	// widget lifetimes rather than in milliseconds.
	detached_before := host.detached
	app.view.scroll = 2_000 * ROW_HEIGHT
	testing.expect_value(t, render(app), nil)
	sciter_app.heartbeat()

	testing.expect(t, host.detached > detached_before, "every row's behavior was destroyed and rebuilt")
}

// **The `set_html` cost `VDOM.md` is about, demonstrated rather than asserted from the headers.** An
// `<input>` with the caret in it does not survive the re-render, so the edit has to live in the model
// and be restored afterwards - which is what `restore_focus` does, and what a diff layer would make
// unnecessary.
@(test)
test_an_edit_survives_a_re_render_only_because_the_model_holds_it :: proc(t: ^testing.T) {
	app, _, ok := test_app(t)
	if !ok {return}
	testing.expect_value(t, render(app), nil)

	app.view.selected = app.rows[2].id
	begin_edit(app)
	testing.expect_value(t, app.editing, app.rows[2].id)
	testing.expect_value(t, app.edit_text, app.rows[2].name)

	testing.expect_value(t, render(app), nil)

	// The `<input>` exists because the *model* says a cell is being edited. Nothing in the DOM carried
	// that across - the element it was in was destroyed by this very render.
	root, _ := sciter_app.root(app.window)
	input, ierr := sciter_app.select_first(root, fmt.tprintf("#r%d input", app.editing))
	testing.expect_value(t, ierr, nil)
	testing.expect(t, input != nil)

	// And it is a *different element* from the one before, which is the whole problem: any state the
	// engine kept on it - the caret, the selection, a running transition - went with the old one.
	value, verr := sciter_app.element_value(input)
	testing.expect_value(t, verr, nil)
	defer sciter_app.value_clear(&value)
	text, _ := sciter_app.value_to_string(&value, context.temp_allocator)
	testing.expect_value(t, text, app.edit_text)

	// Committing writes the model and re-filters, because the name may no longer match.
	delete(app.edit_text, app.allocator)
	app.edit_text = strings.clone("renamed-by-the-test", app.allocator)
	commit_edit(app)
	testing.expect_value(t, app.editing, -1)
	testing.expect_value(t, app.rows[2].name, "renamed-by-the-test")
}

// An edit whose row scrolls out of the window survives anyway, because it was never in the document to
// begin with. That is the payoff for keeping it in the model rather than reading it back out.
@(test)
test_an_edit_survives_its_row_scrolling_out_of_view :: proc(t: ^testing.T) {
	app, _, ok := test_app(t)
	if !ok {return}
	testing.expect_value(t, render(app), nil)

	app.view.selected = app.rows[1].id
	begin_edit(app)
	delete(app.edit_text, app.allocator)
	app.edit_text = strings.clone("still here", app.allocator)

	app.view.scroll = 4_000 * ROW_HEIGHT
	testing.expect_value(t, render(app), nil)

	// Not in the document any more...
	root, _ := sciter_app.root(app.window)
	_, gone := sciter_app.select_first(root, fmt.tprintf("#r%d", app.editing))
	testing.expect(t, gone != nil, "the edited row is scrolled out of the window")

	// ...and completely intact.
	testing.expect_value(t, app.editing, app.rows[1].id)
	testing.expect_value(t, app.edit_text, "still here")

	// Scrolling back brings the `<input>` with it.
	app.view.scroll = 0
	testing.expect_value(t, render(app), nil)
	input, ierr := sciter_app.select_first(root, fmt.tprintf("#r%d input", app.editing))
	testing.expect_value(t, ierr, nil)
	testing.expect(t, input != nil)
}

// User text is parsed by `set_html`, so a row named `<script>` is an injection unless it is escaped.
// The check is that the markup arrives as *text* - one child, no element.
@(test)
test_a_row_named_like_markup_is_text_and_not_markup :: proc(t: ^testing.T) {
	app, _, ok := test_app(t)
	if !ok {return}

	delete(app.rows[0].name, app.allocator)
	app.rows[0].name = strings.clone(`<b onclick="boom()">not bold</b>`, app.allocator)
	refilter(app)
	testing.expect_value(t, render(app), nil)

	root, _ := sciter_app.root(app.window)
	cell, err := sciter_app.select_first(root, "#r1 .c-name")
	testing.expect_value(t, err, nil)

	// No `<b>` was created...
	_, bold := sciter_app.select_first(cell, "b")
	testing.expect(t, bold != nil, "the markup should not have been parsed as markup")

	// ...and the text is the literal characters.
	text, terr := sciter_app.text(cell, context.temp_allocator)
	testing.expect_value(t, terr, nil)
	testing.expect_value(t, text, `<b onclick="boom()">not bold</b>`)
}

// The view state, which is the part that persists. A `Value` renders itself as JSON and parses back, so
// there is no serializer here and none to fall out of step with the struct.
@(test)
test_the_view_state_round_trips_through_a_value_as_json :: proc(t: ^testing.T) {
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}

	original := View {
		filter   = "pump",
		selected = 4321,
		scroll   = 9600,
		light    = true,
	}

	v := view_to_value(original)
	defer sciter_app.value_clear(&v)

	json, jerr := sciter_app.value_to_display_string(&v, .JSON_LITERAL, context.temp_allocator)
	testing.expect_value(t, jerr, nil)
	testing.expect(t, strings.contains(json, "pump"), json)

	// Back through the text, which is what a restart really does.
	parsed, perr := sciter_app.value_parse(json)
	testing.expect_value(t, perr, nil)
	defer sciter_app.value_clear(&parsed)

	restored := view_from_value(&parsed, context.temp_allocator)
	testing.expect_value(t, restored.filter, original.filter)
	testing.expect_value(t, restored.selected, original.selected)
	testing.expect_value(t, restored.scroll, original.scroll)
	testing.expect_value(t, restored.light, original.light)
}

// A missing or corrupt state file must not stop the application starting, which is the only thing that
// matters about persistence that nobody tests until it bites.
@(test)
test_a_missing_or_broken_state_file_leaves_a_usable_view :: proc(t: ^testing.T) {
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}

	empty: sciter_app.Value
	defer sciter_app.value_clear(&empty)
	from_nothing := view_from_value(&empty, context.temp_allocator)
	testing.expect_value(t, from_nothing.selected, -1)
	testing.expect_value(t, from_nothing.scroll, 0)
	testing.expect_value(t, from_nothing.filter, "")

	// A Value of the wrong shape entirely.
	wrong, err := sciter_app.value_parse(`[1,2,3]`)
	testing.expect_value(t, err, nil)
	defer sciter_app.value_clear(&wrong)
	from_wrong := view_from_value(&wrong, context.temp_allocator)
	testing.expect_value(t, from_wrong.selected, -1)
	testing.expect_value(t, from_wrong.filter, "")
}

// The theme is a class on the root, not a `set_css` call - because `set_css` *replaces* the document's
// stylesheet rather than layering under it, which here would throw away every rule the application has.
// CSS variables plus one class is the way to restyle a live document.
@(test)
test_the_theme_is_a_class_because_a_window_stylesheet_would_replace_everything :: proc(t: ^testing.T) {
	app, _, ok := test_app(t)
	if !ok {return}
	testing.expect_value(t, render(app), nil)

	root, _ := sciter_app.root(app.window)
	dark, derr := sciter_app.style(root, "background-color", context.temp_allocator)
	testing.expect_value(t, derr, nil)

	toggle_theme(app)
	testing.expect(t, app.view.light)

	light, lerr := sciter_app.style(root, "background-color", context.temp_allocator)
	testing.expect_value(t, lerr, nil)
	testing.expect(t, light != dark, "the variables should have been re-resolved")

	toggle_theme(app)
	back, _ := sciter_app.style(root, "background-color", context.temp_allocator)
	testing.expect_value(t, back, dark)
}

// The selection moves over the *filtered* list, not the model, and stops at both ends rather than
// running off. Off-by-one here is the bug a user finds in the first minute.
@(test)
test_the_selection_moves_over_the_filtered_rows_and_stops_at_the_ends :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app_init(app)
	defer app_destroy(app)

	set_filter(app, "valve-roof")
	testing.expect(t, len(app.matching) > 2, "the sample data should have a few of these")

	app.view.selected = app.rows[app.matching[0]].id
	move_selection(app, +1)
	testing.expect_value(t, app.view.selected, app.rows[app.matching[1]].id)

	// Up from the first stays on the first.
	app.view.selected = app.rows[app.matching[0]].id
	move_selection(app, -1)
	testing.expect_value(t, app.view.selected, app.rows[app.matching[0]].id)

	// Down from the last stays on the last.
	last := len(app.matching) - 1
	app.view.selected = app.rows[app.matching[last]].id
	move_selection(app, +1)
	testing.expect_value(t, app.view.selected, app.rows[app.matching[last]].id)

	// And moving down scrolls the selection into view rather than leaving it off screen.
	app.view.scroll = 10_000
	app.view.selected = app.rows[app.matching[0]].id
	move_selection(app, +1)
	testing.expect(t, app.view.scroll <= ROW_HEIGHT, "the selection should have pulled the scroll back")
}
