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
//      stylesheet asks for by name that paints itself, two worker threads feeding the UI (one pushing
//      live samples, one answering type-ahead searches), a second window with its own host handler, a
//      theme switched at runtime, and view state stored as a `Value` so it persists with no serializer.
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
//   - **Type-ahead belongs on a worker, and the answer needs a generation number.** Filtering ten
//     thousand rows per keystroke is fast enough to be tempting and slow enough to be felt. The search
//     thread scans and posts; the UI thread applies the answer only if a newer query has not been typed
//     since - see `search_apply`, which is nine lines and the whole of the correctness argument.
//   - **Undo is what the "model is the truth" claim costs, and it is cheap only if the claim is true.**
//     Renaming, reordering and pinning all go through one action stack, and no Sciter call appears in
//     that section: the DOM holds nothing that has to be read back.
//   - **An in-application drag is the mouse group, not `.EXCHANGE`.** There is no drag *source* on
//     Linux - `performDrag` returns null and no exchange event follows - so reordering rows is press,
//     move, release, with the three drag states in the model because the rows themselves are destroyed
//     and rebuilt mid-drag.
//   - **A second window is a second host handler, and there is only one safe way to close it.**
//     Measured here: `hide`, then *at least one turn of the pump*, then `close`. Closing a secondary
//     window that still has a document segfaults the engine on the next pump, and so does closing it in
//     the same turn it was hidden. See `details_destroy`.
package main

import sciter ".."
import "../sciter_app"
import "base:runtime"
import "core:fmt"
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
  #hint { padding: .4em 1em; background: var(--panel); border-top: 1px solid var(--line);
          color: var(--dim); font-size: 12px; }

  #viewport { width: 100%; height: *; overflow-y: scroll; background: var(--bg); }
  #spacer   { position: relative; width: 100%; }
  #rows     { position: absolute; left: 0; top: 0; width: 100%; }

  .row  { flow: horizontal; height: 24px; border-bottom: 1px solid var(--line);
          vertical-align: middle; }
  .row.odd { background: var(--panel); }
  .row.sel { background: var(--accent); color: var(--bg); }
  /* The whole of the drag feedback: the row being dragged fades, the row it would land on gets a
     line above it. Both are classes the renderer writes from model state, because the elements
     themselves do not survive the drag. */
  .row.dragging { opacity: 0.4; }
  .row.dropzone { border-top: 2px solid var(--accent); }
  .row.pin .c-id:before { content: "*"; color: var(--warn); }
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
    <button id="details">details</button>
  </div>
  <div id="viewport"><div id="spacer"><div id="rows"></div></div></div>
  <div id="hint">enter: edit · double click: details window · drag: reorder · p: pin · ctrl+z / ctrl+y: undo, redo</div>
  <div id="status"></div>
</body>
</html>`

// The second window's document. Its own document, in its own window, with its own host handler - the
// engine keeps one per window and posts to whichever the poster named. The sparkline here is the same
// `behavior:` name as in the list, claimed by the details window's host rather than the main one, which
// is the point worth taking from this: a behavior name is answered by the *window's* host.
DETAILS_DOC :: `<html>
<head><style>
  html { background: #181825; color: #cdd6f4; font: 14px system; }
  body { padding: 0; margin: 0; flow: vertical; height: 100%; width: 100%; }
  #head { padding: .8em 1em; border-bottom: 1px solid #313244; }
  #head #name { font-size: 20px; }
  #head #id { color: #a6adc8; font-size: 12px; }
  #bigwrap { height: 120px; margin: 1em; border: 1px solid #313244; }
  /* Replaced wholesale on every tick: a Sparkline reads its samples once, at attach, so new samples
     mean a new element. That is the same "the widget is the markup" rule the row list lives by. */
  #big { width: 100%; height: 100%; behavior: sparkline; }
  #facts { padding: 0 1em; flow: vertical; }
  #facts div { flow: horizontal; padding: .2em 0; border-bottom: 1px dotted #313244; }
  #facts .k { width: 10em; color: #a6adc8; }
  #foot { padding: .6em 1em; color: #a6adc8; font-size: 12px; border-top: 1px solid #313244; }
  #foot button { margin-right: 1em; }
</style></head>
<body>
  <div id="head"><div id="name">-</div><div id="id">-</div></div>
  <div id="bigwrap"><div id="big" data-spark=""></div></div>
  <div id="facts"></div>
  <div id="foot"><button id="hide">hide</button><span id="ticks"></span></div>
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

	// Undo/redo over the model - see "Edits, and undoing them".
	history:       History,

	// The row being dragged and the row it is over, both by id and both -1 when there is no drag. Like
	// the edit, this is model state rather than DOM state: the rows it refers to are destroyed and
	// rebuilt several times during a single drag.
	drag_id:       int,
	drag_over:     int,
	dragging:      bool, // the pointer has actually moved with the button down

	// Set by the worker, read on the engine's thread.
	feed:          Feed,
	search:        Search,
	details:       Details,
	rendered:      int, // how many rows are in the document right now
	renders:       int, // how many times `render` has run, for the status line
	render_ms:     f64, // the last `render`, and the reason the status bar reports it: see VDOM.md

	// **The whole of the threading contract, in one lock.** Two threads read `rows`; only the engine's
	// thread writes it, and it takes this exclusively when it does. The search worker holds it shared
	// for the length of a scan. It is a read-write lock rather than a mutex because the readers are the
	// expensive side - a scan is milliseconds, a write is a name or one pass of samples.
	//
	// It is smaller than it looks: exactly three procedures write the model (`advance_feed`,
	// `commit_edit`, and the test that renames a row), and none of them is on a hot path.
	model:         sync.RW_Mutex,
}

// ---------------------------------------------------------------------------------------------------
// The worker
//
// The only cross-thread call that is safe is `post_callback`. The worker mutates nothing the engine can
// see: it picks a row, computes a new sample, and posts an integer. The update itself happens in
// `on_posted`, on the engine's thread, where the DOM is reachable again.

FEED_TICK :: 0x_F33D // to the main window: the model has moved on
DETAILS_TICK :: 0x_DEA1 // to the details window: refresh the row it is showing
SEARCH_DONE :: 0x_5EA2 // to the main window: a scan finished, generation in `lparam`

Feed :: struct {
	thread:  ^thread.Thread,
	running: bool,
	stop:    bool,
	mutex:   sync.Mutex,
	posted:  int,

	// The details window, if it is open, so the feed can post to it as well. Written by the engine's
	// thread and read by the worker, both under `mutex` - a window handle is a pointer and a torn read
	// of one is a crash rather than a wrong number.
	details: sciter_app.Window,
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
			details := app.feed.details
			sync.mutex_unlock(&app.feed.mutex)
			if stop {
				break
			}

			// Post, do not touch. Everything the engine owns is off limits from here.
			sciter_app.post_callback(app.window, FEED_TICK, 0)

			// **A post is addressed to a window, not to the application.** The second window has its own
			// host handler, so this arrives at `on_details_posted` rather than at `on_posted`, and the
			// two windows update independently from one worker.
			if details != nil {
				sciter_app.post_callback(details, DETAILS_TICK, 0)
			}
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
// Type-ahead, off the UI thread
//
// Filtering ten thousand rows on every keystroke is the classic case for a worker: fast enough that
// doing it inline looks fine on the machine it was written on, slow enough to be felt on a slower one or
// a longer list. `set_filter` below is still there and still synchronous - it is what the tests and the
// restored-state path use - but the keystroke path goes through here.
//
// **The interesting part is not the thread, it is the generation number.** An answer that arrives after
// the user has typed another character is *wrong*, and nothing about it looks wrong: it is a correct
// index for a query nobody is asking any more. Every request bumps `requested`; the worker carries that
// number through the scan and posts it back; `search_apply` drops anything that is not the current one.
// Nine lines, and they are the whole of the correctness argument for an asynchronous list.
Search :: struct {
	thread:     ^thread.Thread,
	running:    bool,
	stop:       bool,
	mutex:      sync.Mutex,
	wake:       sync.Cond,

	// Guarded by `mutex`. `query` is the latest request, `requested` its generation; `scanned` is the
	// generation `results` holds; `applied` is the newest generation the UI has taken.
	query:      string,
	requested:  int,
	scanned:    int,
	applied:    int,
	results:    [dynamic]int,

	// Statistics, for the status bar and for the tests. `scan_ms` is the worker's time in the model,
	// which is the number that says whether any of this was worth it.
	scans:      int,
	dropped:    int, // answers thrown away because a newer query was already pending
	scan_ms:    f64,
	latency:    time.Tick, // when the current generation was requested, for end-to-end time
	latency_ms: f64,
}

search_start :: proc(app: ^App) {
	if app.search.running {
		return
	}
	app.search.running = true
	app.search.stop = false
	app.search.results = make([dynamic]int, 0, TOTAL_ROWS, app.allocator)
	app.search.thread = thread.create_and_start_with_data(app, search_worker)
}

search_stop :: proc(app: ^App) {
	if !app.search.running {
		return
	}
	sync.mutex_lock(&app.search.mutex)
	app.search.stop = true
	sync.cond_signal(&app.search.wake)
	sync.mutex_unlock(&app.search.mutex)

	thread.join(app.search.thread)
	thread.destroy(app.search.thread)
	delete(app.search.results)
	delete(app.search.query, app.allocator)
	app.search = {}
}

// The worker: wait, scan, post. It never touches the DOM and never allocates anything the engine's
// thread will free - `results` belongs to the search and is read under the same lock that writes it.
search_worker :: proc(raw: rawptr) {
	app := (^App)(raw)
	s := &app.search

	for {
		sync.mutex_lock(&s.mutex)
		for !s.stop && s.requested == s.scanned {
			sync.cond_wait(&s.wake, &s.mutex)
		}
		if s.stop {
			sync.mutex_unlock(&s.mutex)
			return
		}
		generation := s.requested
		query := strings.clone(s.query, app.allocator)
		sync.mutex_unlock(&s.mutex)
		defer delete(query, app.allocator)

		// The scan itself, holding the model shared. Anything on the engine's thread that *writes* the
		// model blocks here - which is the trade this design makes: a scan can stall one frame of the
		// feed, and in exchange the keystroke never stalls at all.
		started := time.tick_now()
		matched := make([dynamic]int, 0, TOTAL_ROWS, app.allocator)
		sync.rw_mutex_shared_lock(&app.model)
		search_scan(app.rows[:], query, &matched)
		sync.rw_mutex_shared_unlock(&app.model)
		elapsed := time.duration_milliseconds(time.tick_since(started))

		sync.mutex_lock(&s.mutex)
		delete(s.results)
		s.results = matched
		s.scanned = generation
		s.scans += 1
		s.scan_ms = elapsed
		sync.mutex_unlock(&s.mutex)

		// Two words across the thread boundary, and the generation is one of them. The index itself
		// stays where it is - `search_apply` reads it on the engine's thread, under the same lock.
		sciter_app.post_callback(app.window, SEARCH_DONE, uintptr(generation))
	}
}

// The predicate, in one place, because the synchronous path and the worker have to agree about what a
// match is. A divergence here is the kind of bug that only shows up as "the list flickers".
row_matches :: proc(row: Row, filter: string) -> bool {
	return row.pinned || filter == "" || strings.contains(row.name, filter)
}

search_scan :: proc(rows: []Row, filter: string, out: ^[dynamic]int) {
	clear(out)
	for row, i in rows {
		if row_matches(row, filter) {
			append(out, i)
		}
	}
}

// Called on the engine's thread, from the keystroke. It copies the query and wakes the worker; it does
// no work of its own, which is the entire point.
request_search :: proc(app: ^App, text: string) {
	if !app.search.running {
		// No worker (the tests that do not need one, and the very first paint): fall back to scanning
		// here. The application is correct either way - the worker is a latency decision, not a
		// behavioural one.
		set_filter(app, text)
		render(app)
		return
	}

	s := &app.search
	sync.mutex_lock(&s.mutex)
	if s.query == text {
		sync.mutex_unlock(&s.mutex)
		return
	}
	delete(s.query, app.allocator)
	s.query = strings.clone(text, app.allocator)
	s.requested += 1
	s.latency = time.tick_now()
	sync.cond_signal(&s.wake)
	sync.mutex_unlock(&s.mutex)
}

// The other half, on the engine's thread again: take the answer if it is still the answer to the
// question being asked. Returns whether it was taken, which is what the tests assert on.
search_apply :: proc(app: ^App, generation: int) -> bool {
	s := &app.search

	sync.mutex_lock(&s.mutex)
	// **Stale.** A newer query was typed while this scan was running, so this index describes a filter
	// nobody asked for. Dropping it is not an optimisation: applying it shows the wrong rows until the
	// next answer arrives, and if the user stopped typing, forever.
	if generation != s.requested || generation <= s.applied {
		s.dropped += 1
		sync.mutex_unlock(&s.mutex)
		return false
	}
	s.applied = generation
	s.latency_ms = time.duration_milliseconds(time.tick_since(s.latency))

	clear(&app.matching)
	append(&app.matching, ..s.results[:])

	// The filter text moves into the view state here rather than at the keystroke, so what persists is
	// what is actually on screen.
	delete(app.view.filter, app.allocator)
	app.view.filter = strings.clone(s.query, app.allocator)
	sync.mutex_unlock(&s.mutex)

	// A new list is a new length: the old scroll position means nothing in it.
	app.view.scroll = 0
	return true
}

// ---------------------------------------------------------------------------------------------------
// Building and filtering the model

app_init :: proc(app: ^App, allocator := context.allocator) {
	app.allocator = allocator
	app.rows = make([dynamic]Row, 0, TOTAL_ROWS, allocator)
	app.matching = make([dynamic]int, 0, TOTAL_ROWS, allocator)

	// Made here rather than grown from nil, so that the history's allocations belong to the App's
	// allocator like everything else it owns - `append` to a nil array would take whichever allocator
	// the calling context happened to have.
	app.history.done = make([dynamic]Action, 0, 32, allocator)
	app.history.undone = make([dynamic]Action, 0, 32, allocator)
	app.editing = -1
	app.view.selected = -1
	app.drag_id = -1
	app.drag_over = -1

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
	// Both workers first: they read `rows`, so nothing here may free one while a scan is in flight.
	feed_stop(app)
	search_stop(app)

	// `search_stop` zeroes the search when there was a thread to stop; these are for the case where
	// there was not - the tests that drive `search_apply` directly still allocate an index and a query.
	delete(app.search.results)
	delete(app.search.query, app.allocator)
	for row in app.rows {
		delete(row.name, app.allocator)
	}
	delete(app.rows)
	delete(app.matching)
	delete(app.view.filter, app.allocator)
	delete(app.edit_text, app.allocator)
	history_destroy(app)
}

// Rebuilds the filtered index. Pinned rows always match, which is what makes "pin a row, then filter it
// away" a case worth having.
refilter :: proc(app: ^App) {
	search_scan(app.rows[:], app.view.filter, &app.matching)
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
// Edits, and undoing them
//
// **No Sciter API appears in this section, and that is the point of it.** `task_list`'s thesis is that
// the model is the truth and the document is a projection of it; undo is the claim's bill. If any state
// lives only in the DOM - a name in an `<input>`, an order in the child list - then undo has to read it
// back out of the engine, and every re-render is a chance to lose it.
//
// Here it costs three procedures and a stack, because every edit already goes through the model:
//
//   - a **rename** remembers the old and the new name
//   - a **move** remembers the two indices
//   - a **pin** remembers the state it produced
//
// Each is its own inverse with the fields swapped, so `undo` and `redo` are the same procedure with a
// direction. The stack holds actions rather than snapshots: a copy of ten thousand rows per keystroke
// would work and would be indefensible.

Action_Kind :: enum {
	RENAME,
	MOVE,
	PIN,
}

Action :: struct {
	kind:   Action_Kind,
	id:     int, // the row, by id - indices move, ids do not
	from:   int, // MOVE: the index it came from...
	to:     int, // ...and the one it went to
	before: string, // RENAME: owned by the App's allocator
	after:  string,
	pinned: bool, // PIN: the state this action produced
}

History :: struct {
	done:   [dynamic]Action,
	undone: [dynamic]Action,
}

history_destroy :: proc(app: ^App) {
	for action in app.history.done {action_destroy(app, action)}
	for action in app.history.undone {action_destroy(app, action)}
	delete(app.history.done)
	delete(app.history.undone)
}

action_destroy :: proc(app: ^App, action: Action) {
	delete(action.before, app.allocator)
	delete(action.after, app.allocator)
}

// Where a row is now. Everything here works in ids and looks the index up when it needs one, because a
// move invalidates every index after it and a filter re-orders nothing but does renumber `matching`.
row_index :: proc(app: ^App, id: int) -> (index: int, ok: bool) {
	for row, i in app.rows {
		if row.id == id {
			return i, true
		}
	}
	return -1, false
}

// Applies an action in the given direction. The three writes to the model are all here, and all three
// take the write lock - the search worker is reading these rows.
action_apply :: proc(app: ^App, action: Action, forward: bool) {
	sync.rw_mutex_lock(&app.model)
	switch action.kind {
	case .RENAME:
		if index, ok := row_index(app, action.id); ok {
			delete(app.rows[index].name, app.allocator)
			app.rows[index].name = strings.clone(forward ? action.after : action.before, app.allocator)
		}
	case .MOVE:
		from, to := action.from, action.to
		if !forward {
			from, to = to, from
		}
		if from >= 0 && from < len(app.rows) && to >= 0 && to < len(app.rows) {
			row := app.rows[from]
			ordered_remove(&app.rows, from)
			inject_at(&app.rows, to, row)
		}
	case .PIN:
		if index, ok := row_index(app, action.id); ok {
			app.rows[index].pinned = forward ? action.pinned : !action.pinned
		}
	}
	sync.rw_mutex_unlock(&app.model)

	// Every action can change what matches: a rename, a pin directly, and a move because `matching`
	// holds indices into `rows` and those have just moved.
	refilter(app)
}

// Does an action for the first time. The redo stack dies here, which is what makes a history a line
// rather than a tree - the same choice every editor makes.
perform :: proc(app: ^App, action: Action) {
	action_apply(app, action, forward = true)
	append(&app.history.done, action)

	for undone in app.history.undone {action_destroy(app, undone)}
	clear(&app.history.undone)
}

undo :: proc(app: ^App) -> bool {
	if len(app.history.done) == 0 {
		return false
	}
	action := pop(&app.history.done)
	action_apply(app, action, forward = false)
	append(&app.history.undone, action)
	return true
}

redo :: proc(app: ^App) -> bool {
	if len(app.history.undone) == 0 {
		return false
	}
	action := pop(&app.history.undone)
	action_apply(app, action, forward = true)
	append(&app.history.done, action)
	return true
}

// The three edits, as the UI asks for them.
rename_row :: proc(app: ^App, id: int, name: string) {
	index, ok := row_index(app, id)
	if !ok || app.rows[index].name == name {
		return
	}
	perform(
		app,
		Action {
			kind = .RENAME,
			id = id,
			before = strings.clone(app.rows[index].name, app.allocator),
			after = strings.clone(name, app.allocator),
		},
	)
}

move_row :: proc(app: ^App, id: int, before_id: int) {
	from, ok := row_index(app, id)
	to, ok2 := row_index(app, before_id)
	if !ok || !ok2 || from == to {
		return
	}
	perform(app, Action{kind = .MOVE, id = id, from = from, to = to})
}

toggle_pin :: proc(app: ^App, id: int) {
	index, ok := row_index(app, id)
	if !ok {
		return
	}
	perform(app, Action{kind = .PIN, id = id, pinned = !app.rows[index].pinned})
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
	// Timed, and reported in the status bar, because "what does a re-render actually cost" is the
	// question `VDOM.md` turns on and it is cheap to answer honestly.
	started := time.tick_now()
	defer app.render_ms = time.duration_milliseconds(time.tick_since(started))

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
		if app.dragging && row.id == app.drag_id {
			strings.write_string(&classes, " dragging")
		}
		if app.dragging && row.id == app.drag_over {
			strings.write_string(&classes, " dropzone")
		}
		if row.pinned {
			strings.write_string(&classes, " pin")
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

	// The search statistics are written by the worker, so they are read the same way everything else it
	// writes is read: under its lock. Numbers on a status bar are still shared state.
	sync.mutex_lock(&app.search.mutex)
	scans, dropped, scan_ms, latency_ms :=
		app.search.scans, app.search.dropped, app.search.scan_ms, app.search.latency_ms
	sync.mutex_unlock(&app.search.mutex)
	if status, serr := sciter_app.select_first(root, "#status"); serr == nil {
		sciter_app.set_text(
			status,
			fmt.tprintf(
				"%d of %d rows match  ·  %d in the document  ·  %d renders, last %.1fms  ·  %d ticks  ·  %d searches (%.1fms scan, %.1fms to screen, %d dropped)",
				len(app.matching),
				len(app.rows),
				app.rendered,
				app.renders,
				app.render_ms,
				app.feed.posted,
				scans,
				scan_ms,
				latency_ms,
				dropped,
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
	host.attached += 1
	return make_sparkline(host.app, &host.detached, request)
}

// The constructor both hosts share. **A `behavior:` name is answered by the window's own host**, so the
// details window claims "sparkline" for itself with its own counters; nothing is registered globally and
// the two windows could answer the same name differently if they wanted to.
make_sparkline :: proc(app: ^App, detached: ^int, request: ^sciter_app.Behavior_Request) -> ^sciter_app.Event_Handler {
	spark := new(Sparkline, app.allocator)
	spark.app = app
	spark.detached = detached
	spark.subscription = {.DRAW}
	spark.on_event = on_sparkline_event

	// The samples come off the element, because there is no other channel: this runs inside
	// `set_html`, before the renderer has a handle to the element it just described.
	if raw, err := sciter_app.attribute(request.element, "data-spark", context.temp_allocator); err == nil {
		spark.count = decode_spark(raw, spark.points[:])
	}
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

	switch posted.wparam {
	case FEED_TICK:
		// On the engine's thread again, so the model and the DOM are both reachable. The worker only
		// ever said "something changed"; deciding what changed is done here.
		advance_feed(app)

		// Only the rows on screen are worth redrawing - the rest are not in the document.
		render(app)

	case SEARCH_DONE:
		// The generation travelled as the second word. `search_apply` decides whether it is still the
		// answer to the question being asked; a stale one costs a render that never happens.
		if search_apply(app, int(posted.lparam)) {
			render(app)
		}
	}
}

// Slides every sparkline along by one sample and moves the value with it. This is the "live updating"
// half: it runs at 12 Hz against ten thousand rows and only ever redraws thirty.
advance_feed :: proc(app: ^App) {
	// A write, so it is exclusive: a scan running on the search thread is reading these very rows. This
	// is the only place in the application where the engine's thread waits for a worker, and it waits
	// for at most one scan.
	sync.rw_mutex_lock(&app.model)
	defer sync.rw_mutex_unlock(&app.model)

	for &row in app.rows {
		next_sample := clamp(row.spark[SPARK_POINTS - 1] + f32(next_unit(&app.feed.seed) - 0.5) * 0.3, 0.02, 0.98)
		copy(row.spark[:SPARK_POINTS - 1], row.spark[1:])
		row.spark[SPARK_POINTS - 1] = next_sample
		row.value = f64(next_sample) * 100
	}
}

// ---------------------------------------------------------------------------------------------------
// The second window
//
// A details window, opened by double-clicking a row. Three things about it are worth more than the
// window itself:
//
//   - **It has its own host handler.** `set_host_handler` is per window, so this window answers its own
//     `behavior:` requests and receives its own posted messages. The feed thread posts `FEED_TICK` to
//     the main window and `DETAILS_TICK` to this one, and neither handler hears the other's.
//   - **It must not be a `.MAIN` window.** Closing a `.MAIN` window ends the pump and takes the
//     application with it. `.POPUP` is the flag Sciter 6 leaves for "another top-level window".
//   - **Closing it has exactly one safe order, and it is not the obvious one.** Measured on the
//     vendored engine, X11, 6.0.4.9:
//
//     | teardown | result |
//     | --- | --- |
//     | `close` with a document loaded | segfault on the next pump |
//     | `load_html("<html></html>")` then `close` | segfault on the next pump |
//     | `hide` then `close` in the same turn | segfault on the next pump |
//     | **`hide`, pump, `close`** | **survives; the handle then answers `.INVALID_HWND`** |
//     | never closed at all | survives |
//
//     The crash is the engine's own `check_paint` walking to `GetWindowSizeX11` on a window whose X11
//     window is gone but which is still on the paint list; hiding it and letting one turn of the pump
//     run is what takes it off. `window.odin`'s advice to unload the document first was wrong and has
//     been corrected. In an application the practical answer is the one below: **hide it and keep it**,
//     and only really close it on the way out.

Details :: struct {
	using handler: sciter_app.Host_Handler,
	events:        Details_Events,
	app:           ^App,
	window:        sciter_app.Window,
	row_id:        int,
	open:          bool,
	attached:      int, // sparklines this window's host has made, kept apart from the main window's
	detached:      int,
	posted:        int, // `DETAILS_TICK`s this window's handler received, and not the main one's
}

// The details window's own event handler, for the one button in it. Separate from `App` because it is
// attached to a different document, in a different window.
Details_Events :: struct {
	using handler: sciter_app.Event_Handler,
	app:           ^App,
}

// Creates the window on first use and loads its document, without showing it. Split out from
// `details_show` because the tests want the window and the document and emphatically do not want a
// window mapped on the screen of whoever is running them.
details_ensure :: proc(app: ^App) -> sciter_app.Error {
	details := &app.details
	if details.window != nil {
		return nil
	}

	// `.POPUP`, not the `{.MAIN}` default: this window closing must not end the application.
	window := sciter_app.create_window({width = 520, height = 420, flags = {.POPUP}}) or_return
	details.app = app
	details.window = window
	details.on_attach_behavior = on_details_attach_behavior
	details.on_posted = on_details_posted

	// Before the load, as always: the behavior requests arrive inside it.
	sciter_app.set_host_handler(window, details)
	sciter_app.load_html(window, DETAILS_DOC) or_return

	details.events.app = app
	details.events.subscription = {.BEHAVIOR_EVENT}
	details.events.on_event = on_details_event
	root := sciter_app.root(window) or_return
	sciter_app.attach_handler(root, &details.events) or_return
	return nil
}

// Opens the window on a row, or brings it forward if it is already open on another.
details_show :: proc(app: ^App, row_id: int) -> sciter_app.Error {
	details_ensure(app) or_return
	app.details.row_id = row_id
	app.details.open = true
	details_render(app)

	sciter_app.show(app.details.window)
	sciter_app.activate(app.details.window)

	// Publish the handle to the feed thread, which posts to it only while it is open.
	sync.mutex_lock(&app.feed.mutex)
	app.feed.details = app.details.window
	sync.mutex_unlock(&app.feed.mutex)
	return nil
}

// Hides it and keeps it. See the table above for why this is not `close`.
details_hide :: proc(app: ^App) {
	if !app.details.open {
		return
	}
	sync.mutex_lock(&app.feed.mutex)
	app.feed.details = nil
	sync.mutex_unlock(&app.feed.mutex)

	app.details.open = false
	sciter_app.hide(app.details.window)
}

// The only safe teardown, in the only order that survives: hide, **pump**, close. Called on the way out
// of `main`, where a leaked window would not matter - and done anyway, because the order is the thing
// this example is here to record.
details_destroy :: proc(app: ^App) {
	if app.details.window == nil {
		return
	}
	details_hide(app)
	sciter_app.heartbeat() // not optional: without this turn the close segfaults
	sciter_app.close(app.details.window)
	sciter_app.heartbeat()
	app.details.window = nil
}

// The row the window is showing, or nil if it has gone away under it.
details_row :: proc(app: ^App) -> ^Row {
	for &row in app.rows {
		if row.id == app.details.row_id {
			return &row
		}
	}
	return nil
}

// Fills the window from the model. The whole document is rewritten every tick except the header, which
// is the same `set_html`-per-frame trade the row list makes, at 1/30th the size.
details_render :: proc(app: ^App) -> sciter_app.Error {
	if app.details.window == nil {
		return nil
	}
	row := details_row(app)
	if row == nil {
		return nil
	}
	root := sciter_app.root(app.details.window) or_return

	if name, err := sciter_app.select_first(root, "#name"); err == nil {
		sciter_app.set_text(name, row.name)
	}
	if id, err := sciter_app.select_first(root, "#id"); err == nil {
		sciter_app.set_text(id, fmt.tprintf("row %d of %d", row.id, len(app.rows)))
	}

	// The sparkline is replaced rather than updated: its samples were read at attach time and there is
	// no channel to push new ones down. A new element is a new behavior with new data.
	if wrap, err := sciter_app.select_first(root, "#bigwrap"); err == nil {
		sciter_app.set_html(wrap, fmt.tprintf(`<div id="big" data-spark="%s"></div>`, spark_attribute(row)))
	}

	if facts, err := sciter_app.select_first(root, "#facts"); err == nil {
		builder := strings.builder_make(context.temp_allocator)
		fact :: proc(b: ^strings.Builder, key: string, value: string) {
			fmt.sbprintf(
				b,
				`<div><span class="k">%s</span><span>%s</span></div>`,
				key,
				escape_html(value, context.temp_allocator),
			)
		}
		fact(&builder, "value", fmt.tprintf("%.2f", row.value))
		fact(&builder, "latest sample", fmt.tprintf("%.3f", row.spark[SPARK_POINTS - 1]))
		fact(&builder, "pinned", "yes" if row.pinned else "no")
		fact(&builder, "matches filter", "yes" if row_matches(row^, app.view.filter) else "no")
		sciter_app.set_html(facts, strings.to_string(builder))
	}

	if ticks, err := sciter_app.select_first(root, "#ticks"); err == nil {
		sciter_app.set_text(ticks, fmt.tprintf("%d updates posted to this window", app.details.posted))
	}
	return nil
}

// This window's host claims "sparkline" for itself. The main window's host never sees the request.
on_details_attach_behavior :: proc(
	handler: ^sciter_app.Host_Handler,
	request: ^sciter_app.Behavior_Request,
) -> ^sciter_app.Event_Handler {
	details := (^Details)(handler)
	if request.name != "sparkline" {
		return nil
	}
	details.attached += 1
	return make_sparkline(details.app, &details.detached, request)
}

// And this window's `on_posted`. The feed thread posts to both windows; each handler hears only its own.
on_details_posted :: proc(handler: ^sciter_app.Host_Handler, posted: sciter_app.Posted) {
	details := (^Details)(handler)
	if posted.wparam != DETAILS_TICK {
		return
	}
	details.posted += 1
	details_render(details.app)
}

on_details_event :: proc(h: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	events := (^Details_Events)(h)
	if be, ok := sciter_app.behavior_event(event); ok && be.code == .BUTTON_CLICK {
		if id, _ := sciter_app.attribute(be.target, "id", context.temp_allocator); id == "hide" {
			details_hide(events.app)
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------------------------------
// Input
//
// Every behaviour in the application, and no script anywhere in the document.
//
// ### Reordering by dragging, and why it is not the `.EXCHANGE` group
//
// `.EXCHANGE` is Sciter's drag-and-drop, and it is the obvious place to look for "drag a row onto
// another row". It is the wrong place, for a measured reason recorded by
// [`drag_and_drop.odin`](./drag_and_drop.odin): **on Linux the engine has no drag *source*.** Script's
// `Window.this.performDrag(...)` - the only way to begin a drag, there being no native slot for it -
// returns null immediately and no exchange events follow. `.EXCHANGE` here can *receive* a drag from
// another application and nothing else, and even then the payload arrives empty.
//
// So an in-application reorder is done with the mouse group, which is what a list would want anyway:
// press, move with the button down, release. Three states, all of them in the model
// (`drag_id` / `drag_over` / `dragging`) rather than on the elements - because every one of the rows
// involved is destroyed and rebuilt by `set_html` several times during a single drag, and a handle to
// the row the drag started on would be dangling by the time it ended.
//
// Two limits worth naming rather than hiding:
//
//   - **no auto-scroll at the edges.** Dragging to the top of the viewport does not scroll the list, so
//     a row can only be moved as far as the visible window. Adding it is a timer and some arithmetic;
//     it is left out because it teaches nothing new.
//   - **the drop lands *on* a row, not between two.** The indicator is a line above the row under the
//     pointer, and the move puts the dragged row at that row's index.

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
			case "details":
				if app.view.selected >= 0 {
					details_show(app, app.view.selected)
				}
			}
			return true

		case .VALUE_CHANGED:
			id, _ := sciter_app.attribute(be.target, "id", context.temp_allocator)
			if id == "filter" {
				value, verr := sciter_app.element_value(be.target)
				if verr == nil {
					defer sciter_app.value_clear(&value)
					if text, terr := sciter_app.value_to_string(&value, context.temp_allocator); terr == nil {
						// The keystroke ends here: the scan happens on the search thread and comes back
						// as `SEARCH_DONE`. Nothing on this path touches ten thousand rows.
						request_search(app, text)
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

			// Arm a drag. It is not a drag until the pointer moves with the button down - a press that
			// never moves is a click, and treating it as a zero-distance reorder would make every click
			// an undoable action.
			app.drag_id = row_id
			app.drag_over = -1
			app.dragging = false

			render(app)
			return true
		}
		return false
	}

	// The drag itself. See "Reordering by dragging" for why this is the mouse group and not `.EXCHANGE`.
	if me, ok := sciter_app.mouse_event(event); ok && me.code == .MOUSE_MOVE {
		if app.drag_id < 0 {
			return false
		}
		if .MAIN_MOUSE_BUTTON not_in me.buttons {
			// The button came up somewhere this handler never saw - over another window, or outside the
			// list. Nothing was dropped, so nothing is moved.
			drag_reset(app)
			render(app)
			return false
		}

		over, found := row_id_of(me.target)
		if !found || over == app.drag_id {
			return false
		}
		app.dragging = true
		if app.drag_over != over {
			app.drag_over = over
			render(app) // the drop indicator is a class on a row, so it costs one re-render
		}
		return true
	}

	if me, ok := sciter_app.mouse_event(event); ok && me.code == .MOUSE_UP {
		if app.drag_id < 0 {
			return false
		}
		id, over, moved := app.drag_id, app.drag_over, app.dragging
		drag_reset(app)

		if moved && over >= 0 {
			// One undoable action, at the end of the drag rather than per pointer move. The rows were
			// only ever *drawn* in the new order; the model changes here.
			move_row(app, id, over)
		}
		render(app)
		return moved
	}

	// Double click opens the second window on that row. The `.MOUSE_DOWN` above has already selected it.
	if me, ok := sciter_app.mouse_event(event); ok && me.code == .MOUSE_DCLICK {
		if row_id, found := row_id_of(me.target); found {
			details_show(app, row_id)
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
		case 80:
			// P pins the selected row: a pinned row matches every filter, and it is the third undoable
			// action, so the history is exercised by something other than typing.
			if app.editing < 0 && app.view.selected >= 0 {
				toggle_pin(app, app.view.selected)
				render(app)
				return true
			}
		case 90:
			// Ctrl+Z. `sciter.KEYBOARD_STATE_CONTROL` is both control keys, so intersecting with it is "either one is
			// down"; `.LCONTROL in ke.modifiers` would be the left key specifically.
			if app.editing < 0 && sciter.KEYBOARD_STATE_CONTROL & ke.modifiers != {} {
				undo(app)
				render(app)
				return true
			}
		case 89:
			if app.editing < 0 && sciter.KEYBOARD_STATE_CONTROL & ke.modifiers != {} {
				redo(app)
				render(app)
				return true
			}
		}
	}
	return false
}

drag_reset :: proc(app: ^App) {
	app.drag_id = -1
	app.drag_over = -1
	app.dragging = false
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

// The commit goes through the history rather than writing the row directly, which is what makes an edit
// undoable at all. `rename_row` takes the model's write lock - the search thread reads these names.
commit_edit :: proc(app: ^App) {
	if app.editing < 0 {
		return
	}
	rename_row(app, app.editing, app.edit_text)
	app.editing = -1
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

	// **Inspector-friendly mode**, off by default and worth having on a real application:
	//
	//	WORKBENCH_INSPECT=1 just example workbench          # terminal one
	//	SCITER_SDK=~/dev/sciter-js-sdk just inspector       # terminal two
	//
	// Both halves are required and neither can be turned on after the window exists - the engine has to
	// be listening (`set_debug_mode`) *and* the window has to be created `.ENABLE_DEBUG`. See
	// `examples/inspector.odin`. It is off by default because it opens a socket, and an application
	// this size is exactly the one where poking at the live DOM is worth the trouble: the rows in the
	// inspector's tree are the ~31 the renderer put there, which is the clearest possible view of what
	// virtualisation actually does.
	flags := sciter.Sciter_Create_Window_Flags{.MAIN}
	if os.get_env("WORKBENCH_INSPECT", context.temp_allocator) != "" {
		if err := sciter_app.set_debug_mode(); err != nil {
			fmt.eprintln("could not enable debug mode:", err)
		} else {
			flags += {.ENABLE_DEBUG}
			fmt.println("inspector mode: run `just inspector` in another terminal to attach")
		}
	}

	window, werr := sciter_app.create_window({width = 900, height = 620, flags = flags})
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

	// The type-ahead worker. It waits until there is a query, so starting it costs a thread and nothing
	// else. Without it the application still works - `request_search` scans inline - which is worth
	// knowing when reading it: the thread is a latency decision, not a behavioural one.
	search_start(&app)

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

	fmt.println("double click a row for the details window; type in the box to search off the UI thread")

	sciter_app.show(window)
	sciter_app.run()

	// The second window goes first, in the one order that survives - see `details_destroy`.
	details_destroy(&app)
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
// Shared by every test in this file, and created on first use. That is deliberate - a window per test
// would be slow, and closing one is itself hazardous (see `close` in sciter_app/window.odin) - but it
// makes the tests here order-coupled: **a test that changes the document must put it back**, usually by
// reloading `DOC`, or it breaks a later test and the failure points at the wrong one.
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

	// **Not optional on Windows, and the reason is not obvious.** With no host handler installed the
	// engine reports parse errors and script diagnostics through `OutputDebugStringW`, which Windows
	// implements by *raising an exception* (DBG_PRINTEXCEPTION_WIDE_C, 0x4001000A). Odin's test runner
	// installs a handler that treats any exception as fatal to the test, so a CSS warning killed the
	// test that provoked it and every test after it in the file - reported as `Signal caught: Unknown`,
	// which reads like a segfault and is not one. Routing diagnostics to a callback avoids the API
	// entirely. Harmless on Linux, where it just makes the engine's warnings visible.
	sciter_app.set_default_debug_output()
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
rows_in_document :: proc(app: ^App) -> sciter_app.Child_Index {
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
	testing.expect_value(t, in_document, sciter_app.Child_Index(app.rendered))
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

	// **Not optional on Windows, and the reason is not obvious.** With no host handler installed the
	// engine reports parse errors and script diagnostics through `OutputDebugStringW`, which Windows
	// implements by *raising an exception* (DBG_PRINTEXCEPTION_WIDE_C, 0x4001000A). Odin's test runner
	// installs a handler that treats any exception as fatal to the test, so a CSS warning killed the
	// test that provoked it and every test after it in the file - reported as `Signal caught: Unknown`,
	// which reads like a segfault and is not one. Routing diagnostics to a callback avoids the API
	// entirely. Harmless on Linux, where it just makes the engine's warnings visible.
	sciter_app.set_default_debug_output()

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

	// **Not optional on Windows, and the reason is not obvious.** With no host handler installed the
	// engine reports parse errors and script diagnostics through `OutputDebugStringW`, which Windows
	// implements by *raising an exception* (DBG_PRINTEXCEPTION_WIDE_C, 0x4001000A). Odin's test runner
	// installs a handler that treats any exception as fatal to the test, so a CSS warning killed the
	// test that provoked it and every test after it in the file - reported as `Signal caught: Unknown`,
	// which reads like a segfault and is not one. Routing diagnostics to a callback avoids the API
	// entirely. Harmless on Linux, where it just makes the engine's warnings visible.
	sciter_app.set_default_debug_output()

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

// ---------------------------------------------------------------------------------------------------
// Edits and undo
//
// All headless: the history is model code, which is the argument it exists to make.

// A move takes a row out at one index and puts it in at another, and its inverse is the same move with
// the indices swapped. The ids are what travel; the indices are read fresh each time, because every
// move renumbers everything after it.
@(test)
test_a_move_reorders_the_model_and_undo_puts_it_back :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app_init(app)
	defer app_destroy(app)

	first, fourth := app.rows[0].id, app.rows[3].id
	original := make([]int, 8, context.temp_allocator)
	for i in 0 ..< 8 {original[i] = app.rows[i].id}

	move_row(app, first, fourth)

	// The dragged row is where the target was, and the rows between have shuffled up by one.
	testing.expect_value(t, app.rows[3].id, first)
	testing.expect_value(t, app.rows[0].id, original[1])
	testing.expect_value(t, app.rows[2].id, original[3])
	testing.expect_value(t, len(app.rows), TOTAL_ROWS) // nothing was lost or copied

	// The filter index was rebuilt: it holds *indices*, so a move invalidates it even though nothing
	// about what matches has changed.
	testing.expect_value(t, len(app.matching), TOTAL_ROWS)
	testing.expect_value(t, app.rows[app.matching[3]].id, first)

	testing.expect(t, undo(app))
	for i in 0 ..< 8 {
		testing.expectf(t, app.rows[i].id == original[i], "row %d is %d, expected %d", i, app.rows[i].id, original[i])
	}

	testing.expect(t, redo(app))
	testing.expect_value(t, app.rows[3].id, first)

	// And the stack bottoms out rather than running off the end.
	testing.expect(t, undo(app))
	testing.expect(t, !undo(app))
	testing.expect(t, redo(app))
	testing.expect(t, !redo(app))
}

// A rename is the edit path the `<input>` feeds, and it is undoable for the same reason the edit
// survives a re-render at all: the model holds it, not the DOM.
@(test)
test_undo_restores_a_name_and_redo_puts_the_new_one_back :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app_init(app)
	defer app_destroy(app)

	id := app.rows[5].id
	original := strings.clone(app.rows[5].name, context.temp_allocator)

	app.view.selected = id
	begin_edit(app)
	delete(app.edit_text, app.allocator)
	app.edit_text = strings.clone("renamed-by-the-test", app.allocator)
	commit_edit(app)

	testing.expect_value(t, app.rows[5].name, "renamed-by-the-test")
	testing.expect_value(t, app.editing, -1)
	testing.expect_value(t, len(app.history.done), 1)

	testing.expect(t, undo(app))
	testing.expect_value(t, app.rows[5].name, original)
	testing.expect(t, redo(app))
	testing.expect_value(t, app.rows[5].name, "renamed-by-the-test")

	// A commit that changes nothing is not an action. Otherwise every Enter on an unedited cell would
	// push a no-op onto the history and undo would appear to do nothing.
	before := len(app.history.done)
	rename_row(app, id, "renamed-by-the-test")
	testing.expect_value(t, len(app.history.done), before)
}

// Pinning is the third action, and the one that changes what *matches* rather than what a row says.
@(test)
test_pinning_is_undoable_and_a_pinned_row_survives_a_filter :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app_init(app)
	defer app_destroy(app)

	id := app.rows[9].id
	toggle_pin(app, id)
	testing.expect(t, app.rows[9].pinned)

	set_filter(app, "no-such-row-anywhere")
	testing.expect_value(t, len(app.matching), 1)
	testing.expect_value(t, app.rows[app.matching[0]].id, id)

	// Undoing the pin takes it out of a filter it only matched because it was pinned.
	testing.expect(t, undo(app))
	testing.expect(t, !app.rows[9].pinned)
	testing.expect_value(t, len(app.matching), 0)
}

// The history is a line, not a tree: doing something new after an undo throws the redo away. Worth a
// test because the alternative - leaving it there - produces a redo that reapplies an edit to a model
// it no longer fits.
@(test)
test_a_new_action_throws_away_the_redo_stack :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app_init(app)
	defer app_destroy(app)

	first := app.rows[0].id
	move_row(app, first, app.rows[3].id)
	testing.expect(t, undo(app))
	testing.expect_value(t, len(app.history.undone), 1)

	toggle_pin(app, app.rows[7].id)
	testing.expect_value(t, len(app.history.undone), 0)
	testing.expect(t, !redo(app), "the move is not redoable any more")

	// The pin is, and undoing it leaves the move where undo left it.
	testing.expect(t, undo(app))
	testing.expect_value(t, app.rows[0].id, first)
}

// ---------------------------------------------------------------------------------------------------
// Dragging, driven by synthesised input
//
// The drag is three mouse events, so a test can perform one exactly the way a user does - `send_mouse`
// pushes them through the element chain and this application's own handler answers them. That is worth
// more than calling `move_row` directly: it covers `row_id_of`, the arming rule, and the fact that the
// rows the drag started on are destroyed and rebuilt in between.

@(private = "file")
row_element :: proc(app: ^App, n: sciter_app.Child_Index) -> sciter_app.Element {
	root, _ := sciter_app.root(app.window)
	rows, err := sciter_app.select_first(root, "#rows")
	if err != nil {return nil}
	child, cerr := sciter_app.child(rows, n)
	if cerr != nil {return nil}
	cell, serr := sciter_app.select_first(child, ".c-name")
	if serr != nil {return child}
	return cell
}

@(private = "file")
element_centre :: proc(element: sciter_app.Element) -> [2]i32 {
	box, _ := sciter_app.location(element, .Border, .View)
	return {box.x + box.width / 2, box.y + box.height / 2}
}

@(test)
test_dragging_a_row_onto_another_reorders_the_model :: proc(t: ^testing.T) {
	app, _, ok := test_app(t)
	if !ok {return}
	testing.expect_value(t, render(app), nil)

	dragged, target := app.rows[0].id, app.rows[4].id
	source_el, target_el := row_element(app, 0), row_element(app, 4)
	testing.expect(t, source_el != nil && target_el != nil)

	// Press: selects the row and *arms* a drag without starting one.
	sciter_app.send_mouse(source_el, .MOUSE_DOWN, element_centre(source_el), {.MAIN_MOUSE_BUTTON})
	testing.expect_value(t, app.view.selected, dragged)
	testing.expect_value(t, app.drag_id, dragged)
	testing.expect(t, !app.dragging, "a press that has not moved is not a drag")

	// Move, with the button held. The elements were destroyed and rebuilt by the render the press
	// caused, so the position is taken again rather than reused.
	target_el = row_element(app, 4)
	sciter_app.send_mouse(target_el, .MOUSE_MOVE, element_centre(target_el), {.MAIN_MOUSE_BUTTON})
	testing.expect(t, app.dragging, "moving with the button down is a drag")
	testing.expect_value(t, app.drag_over, target)

	// Release: one undoable move, and the drag state is cleared whatever happened.
	target_el = row_element(app, 4)
	sciter_app.send_mouse(target_el, .MOUSE_UP, element_centre(target_el), {.MAIN_MOUSE_BUTTON})
	testing.expect_value(t, app.drag_id, -1)
	testing.expect(t, !app.dragging)

	testing.expect_value(t, app.rows[4].id, dragged)
	testing.expect_value(t, len(app.history.done), 1)
	testing.expect(t, undo(app))
	testing.expect_value(t, app.rows[0].id, dragged)

	// And the document caught up with the model, which is the half `move_row` on its own would not show.
	testing.expect_value(t, render(app), nil)
	first, _ := sciter_app.child(must_select(app, "#rows"), 0)
	id, _ := sciter_app.attribute(first, "id", context.temp_allocator)
	testing.expect_value(t, id, fmt.tprintf("r%d", dragged))
}

// A press with no movement must not reorder anything - otherwise every click on a row would be an
// undoable no-op, and the history would fill with them.
@(test)
test_a_click_without_movement_is_not_a_drag :: proc(t: ^testing.T) {
	app, _, ok := test_app(t)
	if !ok {return}
	testing.expect_value(t, render(app), nil)

	before := app.rows[0].id
	element := row_element(app, 0)
	at := element_centre(element)

	sciter_app.send_mouse(element, .MOUSE_DOWN, at, {.MAIN_MOUSE_BUTTON})
	sciter_app.send_mouse(row_element(app, 0), .MOUSE_UP, at, {.MAIN_MOUSE_BUTTON})

	testing.expect_value(t, app.rows[0].id, before)
	testing.expect_value(t, len(app.history.done), 0)
	testing.expect_value(t, app.drag_id, -1)

	// Nor does a move whose button has come up - a drag that ended outside the window drops nothing.
	sciter_app.send_mouse(row_element(app, 0), .MOUSE_DOWN, at, {.MAIN_MOUSE_BUTTON})
	sciter_app.send_mouse(row_element(app, 3), .MOUSE_MOVE, element_centre(row_element(app, 3)), {})
	sciter_app.send_mouse(row_element(app, 3), .MOUSE_UP, element_centre(row_element(app, 3)), {})
	testing.expect_value(t, app.rows[0].id, before)
	testing.expect_value(t, len(app.history.done), 0)
}

@(private = "file")
must_select :: proc(app: ^App, selector: string) -> sciter_app.Element {
	root, _ := sciter_app.root(app.window)
	element, _ := sciter_app.select_first(root, selector)
	return element
}

// ---------------------------------------------------------------------------------------------------
// Type-ahead off the UI thread

// The worker and the synchronous path have to agree about what a match is, or the list flickers between
// two answers depending on which one got there first. They share `row_matches`, and this is the test
// that says so.
@(test)
test_the_worker_scan_and_the_synchronous_filter_produce_the_same_index :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app_init(app)
	defer app_destroy(app)

	for query in ([]string{"", "valve", "pump-north", "no-such-row-anywhere", "-00"}) {
		set_filter(app, query)

		scanned := make([dynamic]int, 0, TOTAL_ROWS, context.temp_allocator)
		search_scan(app.rows[:], query, &scanned)

		testing.expectf(t, len(scanned) == len(app.matching), "%q: %d vs %d", query, len(scanned), len(app.matching))
		for index, i in scanned {
			if index != app.matching[i] {
				testing.expectf(t, false, "%q: index %d differs", query, i)
				break
			}
		}
	}

	// A pinned row matches everything, on both paths, because the predicate is one procedure.
	app.rows[7].pinned = true
	pinned := make([dynamic]int, 0, TOTAL_ROWS, context.temp_allocator)
	search_scan(app.rows[:], "no-such-row-anywhere", &pinned)
	testing.expect_value(t, len(pinned), 1)
	testing.expect_value(t, pinned[0], 7)
}

// **The reason the generation number exists.** A scan that finishes after the next keystroke is a
// correct answer to a question nobody is asking, and showing it is a bug that looks like a race and
// reads like a caching problem. `search_apply` compares the generation it was posted with against the
// one the user is on, and drops the stale one.
//
// No thread here: the states a real race produces are set up directly, which is the only way to test
// the *unlucky* interleaving rather than the one the machine happens to give you.
@(test)
test_a_search_answer_is_dropped_when_a_newer_query_is_already_pending :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app_init(app)
	defer app_destroy(app)

	s := &app.search
	s.results = make([dynamic]int, 0, 16, app.allocator)

	// Generation 1: the user typed "valve" and the scan came back before anything else happened.
	s.query = strings.clone("valve", app.allocator)
	s.requested = 1
	search_scan(app.rows[:], "valve", &s.results)
	first_count := len(s.results)
	testing.expect(t, first_count > 0)

	testing.expect(t, search_apply(app, 1), "the current generation is applied")
	testing.expect_value(t, len(app.matching), first_count)
	testing.expect_value(t, app.view.filter, "valve")

	// Now the unlucky order: the user types another character (generation 2) while the worker is still
	// scanning generation 2's predecessor... and generation 1's answer turns up late.
	delete(s.query, app.allocator)
	s.query = strings.clone("valve-roof", app.allocator)
	s.requested = 2

	dropped_before := s.dropped
	testing.expect(t, !search_apply(app, 1), "a stale generation must be refused")
	testing.expect_value(t, s.dropped, dropped_before + 1)

	// The list still shows generation 1's rows, which is right: it is the newest answer that exists.
	// What must not happen is the *filter* changing to a query whose rows are not on screen.
	testing.expect_value(t, len(app.matching), first_count)
	testing.expect_value(t, app.view.filter, "valve")

	// And the same answer applied twice is refused too - `post_callback` delivers once, but the guard
	// is against generations rather than against deliveries.
	search_scan(app.rows[:], "valve-roof", &s.results)
	testing.expect(t, search_apply(app, 2))
	testing.expect(t, !search_apply(app, 2), "an already-applied generation is not applied again")
	testing.expect_value(t, app.view.filter, "valve-roof")
}

// End to end, with the real thread and the real `post_callback`: type, wait for the pump to deliver the
// answer, and check the list is the one the query asks for. This is the piece that could not be tested
// without a window - the message only comes back on the engine's thread.
@(test)
test_the_search_worker_delivers_its_answer_through_post_callback :: proc(t: ^testing.T) {
	app, _, ok := test_app(t)
	if !ok {return}
	testing.expect_value(t, render(app), nil)

	search_start(app)
	defer search_stop(app)

	request_search(app, "valve-roof")

	// The worker is a thread, so this is a wait with a deadline rather than an assertion. Two seconds is
	// about a thousand times what the scan costs.
	deadline := time.tick_now()
	applied := 0
	for time.duration_seconds(time.tick_since(deadline)) < 2 {
		sciter_app.heartbeat()

		sync.mutex_lock(&app.search.mutex)
		applied = app.search.applied
		sync.mutex_unlock(&app.search.mutex)
		if applied > 0 {
			break
		}
		time.sleep(2 * time.Millisecond)
	}
	testing.expectf(t, applied > 0, "the worker's answer never arrived; %d scans ran", app.search.scans)
	if applied == 0 {return}

	// The index the UI ended up with is the one a synchronous scan would have produced.
	expected := make([dynamic]int, 0, TOTAL_ROWS, context.temp_allocator)
	search_scan(app.rows[:], "valve-roof", &expected)
	testing.expect_value(t, len(app.matching), len(expected))
	testing.expect(t, len(expected) > 0, "the sample data should contain some of these")
	testing.expect_value(t, app.view.filter, "valve-roof")

	// And the document followed it: `render` ran on the same turn the answer was applied.
	// A DOM child count against a model count - equal by construction, so the conversion is
	// explicit rather than implied.
	testing.expect_value(t, rows_in_document(app), sciter_app.Child_Index(app.rendered))
	testing.expect(t, app.rendered <= len(expected) + OVERSCAN * 2)

	// The scan was measured, which is the number the status bar reports and the one `VDOM.md` wanted.
	sync.mutex_lock(&app.search.mutex)
	scan_ms := app.search.scan_ms
	sync.mutex_unlock(&app.search.mutex)
	testing.expect(t, scan_ms >= 0)
	// Printed rather than asserted: it is a measurement, and the machine it runs on decides it. These
	// are the two numbers `VDOM.md`'s "what actually hurt" section argues from.
	fmt.printfln(
		"  search: %d rows scanned in %.2fms; the %d-row re-render that showed the result took %.2fms",
		len(app.rows),
		scan_ms,
		app.rendered,
		app.render_ms,
	)
}

// ---------------------------------------------------------------------------------------------------
// The second window
//
// None of these show a window. A `show` here would map a window on the screen of whoever is running the
// tests, and on X11 a window the engine mode-sets can take the display with it - see the note on
// `.FULL_SCREEN` in `window.odin`. Everything below is true of an unshown window: the document loads,
// the DOM answers, behaviors attach, and posted messages arrive.

@(test)
test_the_details_window_answers_its_own_behaviors_and_its_own_posted_messages :: proc(t: ^testing.T) {
	app, host, ok := test_app(t)
	if !ok {return}
	testing.expect_value(t, render(app), nil)
	sciter_app.heartbeat()

	testing.expect_value(t, details_ensure(app), nil)
	defer details_destroy(app)

	// Two windows, two documents. The handles differ and so do the roots.
	testing.expect(t, app.details.window != app.window)
	main_root, _ := sciter_app.root(app.window)
	details_root, derr := sciter_app.root(app.details.window)
	testing.expect_value(t, derr, nil)
	testing.expect(t, details_root != main_root)

	// **The behavior request went to this window's host, not the application's.** `#big` is in the
	// document being loaded, so - unlike the rows, which are created afterwards by `set_html` - it was
	// attached inside `load_html` and is already counted here.
	testing.expect_value(t, app.details.attached, 1)
	main_attached := host.attached

	// A post is addressed to a window. This one arrives at the details handler; the main window's
	// handler hears nothing.
	sciter_app.post_callback(app.details.window, DETAILS_TICK, 0)
	sciter_app.heartbeat()
	sciter_app.heartbeat()
	testing.expect_value(t, app.details.posted, 1)

	// ...and the other direction: a `FEED_TICK` to the main window renders the list and leaves the
	// details window's counter where it was.
	renders_before := app.renders
	sciter_app.post_callback(app.window, FEED_TICK, 0)
	sciter_app.heartbeat()
	sciter_app.heartbeat()
	testing.expect(t, app.renders > renders_before, "the main window rendered")
	testing.expect_value(t, app.details.posted, 1)
	testing.expect_value(t, host.attached, main_attached + app.rendered) // the list's own sparklines
}

// The window shows the row it was opened on, and the tick replaces its sparkline - because a Sparkline
// reads its samples once, at attach, so new samples mean a new element rather than a new attribute.
@(test)
test_the_details_window_shows_the_row_it_was_opened_on :: proc(t: ^testing.T) {
	app, _, ok := test_app(t)
	if !ok {return}
	testing.expect_value(t, details_ensure(app), nil)
	defer details_destroy(app)

	app.details.row_id = app.rows[42].id
	app.details.open = true
	testing.expect_value(t, details_render(app), nil)

	root, _ := sciter_app.root(app.details.window)
	name, nerr := sciter_app.select_first(root, "#name")
	testing.expect_value(t, nerr, nil)
	text, _ := sciter_app.text(name, context.temp_allocator)
	testing.expect_value(t, text, app.rows[42].name)

	// Four facts, built by `set_html` the same way the rows are.
	facts, ferr := sciter_app.select_first(root, "#facts")
	testing.expect_value(t, ferr, nil)
	count, cerr := sciter_app.child_count(facts)
	testing.expect_value(t, cerr, nil)
	testing.expect_value(t, count, 4)

	// A tick replaces the sparkline element, so the behavior count goes up and the old one is detached.
	sciter_app.heartbeat()
	attached_before, detached_before := app.details.attached, app.details.detached
	advance_feed(app)
	sciter_app.post_callback(app.details.window, DETAILS_TICK, 0)
	sciter_app.heartbeat()
	sciter_app.heartbeat()

	testing.expect(t, app.details.attached > attached_before, "the replacement element got a new behavior")
	testing.expect(t, app.details.detached > detached_before, "and the old one was destroyed")

	// A row that has gone away leaves the window alone rather than crashing it.
	app.details.row_id = -1
	testing.expect_value(t, details_render(app), nil)
	still_there, _ := sciter_app.text(name, context.temp_allocator)
	testing.expect_value(t, still_there, app.rows[42].name)
}

// **The measured rule, and the reason this test is worth the risk of running it.** On Linux, closing a
// secondary window that has a document loaded segfaults the engine on the next turn of the pump - inside
// its own `check_paint`, on a window whose X11 window is gone but which is still on the paint list.
// Hiding it and letting one turn of the pump run takes it off that list, and then the close is clean.
//
// Four teardowns were measured on 6.0.4.9 under X11; only `hide` + pump + `close` and "never close it"
// survived. In particular `load_html("<html></html>")` before the close - which `window.odin` used to
// recommend - still crashes.
//
// If this rule ever stops holding, this test does not fail: **the whole test binary dies here**, and
// every test after it in the file goes with it. That is the same hazard `dom_walk` records for the
// unhidden close, and it is why the safe order is pinned by a test rather than by a comment.
//
// **On Windows this same order also destroys the window, and must** - a process that exits with a live
// Sciter window faults inside the engine there. That was not obvious for a while, because `close` was
// passing 0 for `SET_STATE`'s force parameter and so never destroyed anything; see the note on `close`
// in `window.odin` and `docs/gotchas.md`. Whether the X11 crash hazard the order exists for also
// applies with the force parameter on has not been re-measured.
@(test)
test_a_secondary_window_is_closed_by_hiding_it_and_pumping_first :: proc(t: ^testing.T) {
	app, _, ok := test_app(t)
	if !ok {return}

	window, werr := sciter_app.create_window({width = 520, height = 420, flags = {.POPUP}})
	testing.expect_value(t, werr, nil)
	testing.expect_value(t, sciter_app.load_html(window, DETAILS_DOC), nil)

	// A window that was created and never shown reports `.CLOSED` on Linux and `.HIDDEN` on Windows -
	// see `dom_walk`. The document in it is perfectly live either way.
	when ODIN_OS == .Windows {
		NEVER_SHOWN :: sciter.Sciter_Window_State.HIDDEN
	} else {
		NEVER_SHOWN :: sciter.Sciter_Window_State.CLOSED
	}
	never_shown, never_shown_ok := sciter_app.window_state(window)
	testing.expect(t, never_shown_ok, "a live window reports a state the enum has")
	testing.expect_value(t, never_shown, NEVER_SHOWN)
	root, rerr := sciter_app.root(window)
	testing.expect_value(t, rerr, nil)
	testing.expect(t, root != nil)

	sciter_app.hide(window)
	sciter_app.heartbeat() // the turn that takes it off the paint list

	// **`request_close` does not close it**, which is the whole difference between the two calls and the
	// reason `close` takes a `force` parameter at all. Measured on 6.0.4.9/Windows: the window survives
	// five turns of the pump afterwards, with a document that refuses the closure *and* with one that
	// says nothing about it. So `request_close` is the polite ask - it lets script have an opinion, and
	// on a window nobody is looking at, nothing comes of it.
	sciter_app.request_close(window)
	for _ in 0 ..< 5 {
		sciter_app.heartbeat()
	}
	_, still_there := sciter_app.root(window)
	testing.expect_value(t, still_there, nil)

	sciter_app.close(window)
	sciter_app.heartbeat()

	// Now the handle is dead, and says so in the two ways `window.odin` records: an invalid handle
	// from the DOM, and a state that is not in the enum at all. **The same on both platforms** - this
	// was guarded as a Windows difference for a while, and it was not one: `close` was passing 0 for
	// `SET_STATE`'s force parameter, so it was really `request_close` and the window was never
	// destroyed. See the note on `close` in `window.odin`.
	_, after := sciter_app.root(window)
	testing.expect_value(t, after, sciter_app.Error(sciter.Scdom_Result.INVALID_HWND))
	// `ok` false is the whole point of the pair: the engine answers 0xFFFFFFFE, which is not a member
	// of SCITER_WINDOW_STATE, so there is no state to report and the wrapper says so instead of
	// handing back an out-of-range enum value.
	_, state_ok := sciter_app.window_state(window)
	testing.expect(t, !state_ok, "a destroyed window reports 0xFFFFFFFE, which is not a state")

	// And the application's own window came through it untouched, which is the part that would not
	// survive the unsafe order: there, the next pump takes the process down whatever it is doing.
	testing.expect_value(t, render(app), nil)
	testing.expect(t, rows_in_document(app) > 0)
}
