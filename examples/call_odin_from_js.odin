// Exposing Odin to JavaScript, both ways round: a procedure, and an object.
//
//   just example call_odin_from_js
//
// `eval` and `call` go one way: Odin drives script. This is the other direction, and there are two
// shapes of it.
//
// A **native functor** is a VALUE holding a pointer to an Odin procedure. Script calls it like any
// other function; put one in the document's globals and it is `globalThis.name`. That is
// `odin_reverse` and `odin_stats` below.
//
// A **SOM asset** is an Odin *object*: properties script can read and write, and methods it can call,
// under one name. That is `Backend` below. It is the shape to reach for when the document is written
// against an application model rather than against a handful of loose functions - `Backend.calls`
// reads a getter in Odin, `Backend.calls = 0` runs a setter, `Backend.reset()` runs a method.
//
// Three things to keep straight:
//
//   - the globals belong to the *document*, not the window, so a functor has to be republished after
//     every load. An asset is the other way round: **it has to be published *before* the load**, and
//     appears in the next document rather than the current one.
//   - both run on the engine's thread, inside script's stack frame. Blocking there freezes the UI, and
//     panicking there unwinds through C++
//   - SOM properties are not enumerable: `Object.keys(Backend)` is empty even though every property
//     works. Script has to know the names, which is the normal case for an interface.
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
  html   { background: #1e1e2e; color: #cdd6f4; font: 16px system; }
  body   { padding: 2em; margin: 0; }
  h1     { color: #89b4fa; margin-top: 0; }
  button { padding: .5em 1em; margin-right: .5em; }
  #out   { background: #313244; padding: 1em; border-radius: 4px; font: 14px monospace;
           white-space: pre-wrap; margin-top: 1em; }
</style>
<script type="module">
  document.on("click", "button#reverse", function() {
    // odin_reverse is not defined anywhere in this document. Odin put it there.
    document.$("#out").innerText = odin_reverse(document.$("input").value);
  });
  document.on("click", "button#stats", function() {
    var s = odin_stats();
    document.$("#out").innerText =
      "odin_stats() returned an object:\n" +
      "  calls   = " + s.calls + "\n" +
      "  uptime  = " + s.uptime.toFixed(3) + "s\n" +
      "  message = " + s.message;
  });
  // Backend is not defined in this document either. Odin published it as a SOM asset, before the
  // document was loaded - which is the one thing an asset needs that a functor does not.
  document.on("click", "button#asset", function() {
    Backend.greeting = "set from script";
    document.$("#out").innerText =
      "Backend is " + Backend + "\n" +
      "  Backend.calls    = " + Backend.calls + "   (a getter, in Odin)\n" +
      "  Backend.greeting = " + Backend.greeting + "   (just written by a setter, in Odin)\n" +
      "  Backend.sum(2,3) = " + Backend.sum(2, 3) + "   (a method, in Odin)\n" +
      "  Object.keys()    = [" + Object.keys(Backend) + "]   (SOM members are not enumerable)";
  });
</script>
</head>
<body>
  <h1>call_odin_from_js</h1>
  <input type="text" value="hello from script" />
  <p>
    <button id="reverse">odin_reverse(input)</button>
    <button id="stats">odin_stats()</button>
    <button id="asset">Backend (a SOM asset)</button>
  </p>
  <div id="out">Click a button. Both handlers call into Odin.</div>
</body>
</html>`

// State the exposed procedures share. Its address is handed to `value_from_function` as user_data and
// comes back on every call, which is how a native functor gets at anything other than globals. An
// asset carries the same pointer, as `Asset.user_data`.
App :: struct {
	calls:    int,
	started:  time.Time,
	greeting: string,
}

main :: proc() {
	if !sciter_app.load_engine() {
		os.exit(1)
	}
	sciter_app.set_default_debug_output()

	if err := sciter_app.init(); err != nil {
		fmt.eprintln("init failed:", err)
		os.exit(1)
	}

	app := App {
		started  = time.now(),
		// Cloned rather than assigned from the literal: the setter below frees what is there before
		// replacing it, and a string literal lives in static memory and cannot be freed.
		greeting = strings.clone("built in Odin"),
	}
	defer delete(app.greeting)

	// The asset's class - the shape script sees. It has to outlive every asset built from it *and* the
	// engine, per the C header, so one made here and destroyed at shutdown is the intended lifetime.
	class, cerr := sciter_app.make_asset_class(
		"Backend",
		{
			{name = "calls", get = get_calls, set = set_calls},
			{name = "greeting", get = get_greeting, set = set_greeting},
		},
		{{name = "sum", params = 2, call = backend_sum}, {name = "reset", call = backend_reset}},
	)
	if cerr != nil {
		fmt.eprintln("could not build the asset class:", cerr)
		os.exit(1)
	}
	defer sciter_app.destroy_asset_class(class)

	backend := sciter_app.make_asset(class, &app)
	defer sciter_app.destroy_asset(backend)

	window, werr := sciter_app.create_window({width = 720, height = 460})
	if werr != nil {
		fmt.eprintln("could not create a window:", werr)
		os.exit(1)
	}
	// Before the load, not after: a global asset appears in the *next* document, and publishing it
	// after this line would leave `Backend` undefined for the document that uses it.
	if err := sciter_app.set_global_asset(backend); err != nil {
		fmt.eprintln("could not publish the Backend asset:", err)
		os.exit(1)
	}
	defer sciter_app.release_global_asset(backend)

	if err := sciter_app.load_html(window, DOC); err != nil {
		fmt.eprintln("could not load the document:", err)
		os.exit(1)
	}

	// Publish the two procedures. This must happen after the document is loaded - the globals belong to
	// the document, and loading a new one replaces them.
	{
		reverse := sciter_app.value_from_function(odin_reverse, &app)
		defer sciter_app.value_clear(&reverse)
		if err := sciter_app.set_global(window, "odin_reverse", &reverse); err != nil {
			fmt.eprintln("could not publish odin_reverse:", err)
			os.exit(1)
		}

		stats := sciter_app.value_from_function(odin_stats, &app)
		defer sciter_app.value_clear(&stats)
		if err := sciter_app.set_global(window, "odin_stats", &stats); err != nil {
			fmt.eprintln("could not publish odin_stats:", err)
			os.exit(1)
		}
	}

	// Proof that it works before the window is even shown: call it from script, from Odin.
	{
		v, err := sciter_app.eval(window, `odin_reverse("stressed")`)
		if err != nil {
			fmt.eprintln("eval failed:", err)
			os.exit(1)
		}
		defer sciter_app.value_clear(&v)

		s, _ := sciter_app.value_to_string(&v, context.temp_allocator)
		fmt.printfln(`script called odin_reverse("stressed") -> %q`, s)
	}

	// The same proof for the asset: script reaching an Odin object by name - a method, a setter and a
	// getter in one line.
	{
		v, err := sciter_app.eval(
			window,
			`Backend.greeting = "set by script"; Backend.sum(20, 22) + ":" + Backend.greeting`,
		)
		if err != nil {
			fmt.eprintln("eval failed:", err)
			os.exit(1)
		}
		defer sciter_app.value_clear(&v)

		s, _ := sciter_app.value_to_string(&v, context.temp_allocator)
		fmt.printfln("script evaluated a Backend expression -> %q", s)
		fmt.printfln("Odin now holds greeting = %q", app.greeting) // the setter ran in Odin
	}

	sciter_app.show(window)
	sciter_app.run()
	sciter_app.shutdown()

	fmt.printfln("script called into Odin %d times", app.calls)
}

// Reverses a string. `args` is borrowed for the duration of the call; the returned Value is handed to
// the engine, which takes ownership, so it is not cleared here.
odin_reverse :: proc(args: []sciter_app.Value, user_data: rawptr) -> sciter_app.Value {
	app := (^App)(user_data)
	app.calls += 1

	if len(args) != 1 {
		// Returning a string is the simplest way to report a problem. Throwing into script from a
		// native functor means writing an error Value into retval, which is more machinery than this
		// example needs.
		return sciter_app.value_from("odin_reverse expects exactly one argument")
	}

	s, err := sciter_app.value_to_string(&args[0], context.temp_allocator)
	if err != nil {
		return sciter_app.value_from("odin_reverse expects a string")
	}

	// Reverse by rune, not by byte, so this survives the input being non-ASCII.
	runes := utf8_runes(s, context.temp_allocator)
	for i, j := 0, len(runes) - 1; i < j; i, j = i + 1, j - 1 {
		runes[i], runes[j] = runes[j], runes[i]
	}
	return sciter_app.value_from(utf8_string(runes, context.temp_allocator))
}

// Returns an object, to show that the result does not have to be a scalar.
odin_stats :: proc(args: []sciter_app.Value, user_data: rawptr) -> sciter_app.Value {
	app := (^App)(user_data)
	app.calls += 1

	result: sciter_app.Value

	calls := sciter_app.value_from(i32(app.calls))
	defer sciter_app.value_clear(&calls)
	sciter_app.value_set(&result, "calls", &calls)

	uptime := sciter_app.value_from(time.duration_seconds(time.since(app.started)))
	defer sciter_app.value_clear(&uptime)
	sciter_app.value_set(&result, "uptime", &uptime)

	message := sciter_app.value_from("built in Odin")
	defer sciter_app.value_clear(&message)
	sciter_app.value_set(&result, "message", &message)

	return result
}

// ---------------------------------------------------------------------------------------------------
// The Backend asset
//
// A getter hands the engine a Value and gives up its reference - do not clear it. A setter borrows the
// one it is given. Both, and every method, get the asset back, so `asset.user_data` is the way to the
// application's state.

get_calls :: proc(asset: ^sciter_app.Asset) -> (sciter_app.Value, bool) {
	app := (^App)(asset.user_data)
	return sciter_app.value_from(i32(app.calls)), true
}

set_calls :: proc(asset: ^sciter_app.Asset, value: ^sciter_app.Value) -> bool {
	app := (^App)(asset.user_data)
	n, err := sciter_app.value_to_int(value)
	if err != nil {
		return false // reported to script as a failed assignment
	}
	app.calls = int(n)
	return true
}

get_greeting :: proc(asset: ^sciter_app.Asset) -> (sciter_app.Value, bool) {
	app := (^App)(asset.user_data)
	return sciter_app.value_from(app.greeting), true
}

set_greeting :: proc(asset: ^sciter_app.Asset, value: ^sciter_app.Value) -> bool {
	app := (^App)(asset.user_data)
	s, err := sciter_app.value_to_string(value, context.temp_allocator)
	if err != nil {
		return false
	}
	// The Value is borrowed for the call, so anything kept has to be copied out of it.
	delete(app.greeting)
	app.greeting = strings.clone(s)
	return true
}

// A method. `args` is borrowed; the result is handed to the engine like a getter's.
backend_sum :: proc(asset: ^sciter_app.Asset, args: []sciter_app.Value) -> (sciter_app.Value, bool) {
	app := (^App)(asset.user_data)
	app.calls += 1

	// The engine reports a method's arity but does not enforce it, so the count is worth checking.
	total: i32
	for &arg in args {
		n, err := sciter_app.value_to_int(&arg)
		if err != nil {
			return sciter_app.value_from("sum takes numbers"), true
		}
		total += n
	}
	return sciter_app.value_from(total), true
}

backend_reset :: proc(asset: ^sciter_app.Asset, args: []sciter_app.Value) -> (sciter_app.Value, bool) {
	app := (^App)(asset.user_data)
	app.calls = 0
	return {}, true // an undefined Value, which is script's `undefined`
}

utf8_runes :: proc(s: string, allocator := context.allocator) -> []rune {
	runes := make([dynamic]rune, 0, len(s), allocator)
	for r in s {
		append(&runes, r)
	}
	return runes[:]
}

utf8_string :: proc(runes: []rune, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for r in runes {
		strings.write_rune(&b, r)
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------------------------------
// Tests
//
// Both halves need a window: a native functor is published into a *document's* globals, and an asset is
// only reachable from script. So these skip themselves where there is no display, and share one window
// across the suite. `ODIN_TEST_THREADS=1` is required - see the `example-test` recipe.
//
// The asset is published once, before the first `load_html`, and deliberately never released: that
// ordering is the rule the tests below pin, and re-publishing per test would hide it.

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
@(private = "file")
g_app: App
@(private = "file")
g_asset: ^sciter_app.Asset

// The window, the class, the asset and a freshly loaded document. Everything the engine keeps is
// allocated from the default allocator - the test runner's tracking allocator is per test, and the
// engine outlives every one of them.
@(private = "file")
test_window :: proc(t: ^testing.T) -> (window: sciter_app.Window, ok: bool) {
	if !have_display() {
		fmt.println("no DISPLAY or WAYLAND_DISPLAY - skipping, this test needs a window")
		return nil, false
	}
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}
	context.allocator = runtime.default_allocator()

	if g_window == nil {
		sciter_app.init()

		g_app = App {
			started  = time.now(),
			greeting = strings.clone("built in Odin"),
		}

		class, cerr := sciter_app.make_asset_class(
			"Backend",
			{
				{name = "calls", get = get_calls, set = set_calls},
				{name = "greeting", get = get_greeting, set = set_greeting},
			},
			{{name = "sum", params = 2, call = backend_sum}, {name = "reset", call = backend_reset}},
		)
		testing.expect_value(t, cerr, nil)
		if cerr != nil {
			return nil, false
		}
		g_asset = sciter_app.make_asset(class, &g_app)

		w, werr := sciter_app.create_window({width = 400, height = 300})
		testing.expect_value(t, werr, nil)
		if w == nil {
			return nil, false
		}
		g_window = w

		// Before the first load. This is the ordering rule, and it is tested from the other side by
		// `test_a_global_asset_outlives_a_reload_where_a_functor_does_not`.
		testing.expect_value(t, sciter_app.set_global_asset(g_asset), nil)
	}

	g_app.calls = 0
	testing.expect_value(t, sciter_app.load_html(g_window, TEST_DOC), nil)
	return g_window, true
}

// A document with no script of its own: everything reachable in these tests was put there from Odin.
TEST_DOC :: `<html><body><p id="out"></p></body></html>`

// Publishes the example's two functors into the document that is loaded now. Globals belong to the
// document, so this has to happen after every load - which is the rule the last test here pins.
@(private = "file")
publish_functors :: proc(window: sciter_app.Window) {
	reverse := publish(window, "odin_reverse", odin_reverse)
	defer sciter_app.value_clear(&reverse)

	stats := publish(window, "odin_stats", odin_stats)
	defer sciter_app.value_clear(&stats)
}

// Wraps `fn` and puts it in the document's globals.
//
// The allocator is not an afterthought: `value_from_function` allocates a thunk that the *engine* frees
// when it drops the functor, which happens at the next `load_html` - in a later test, under a different
// tracking allocator. Taking it from the test runner's arena is reported as a leak in one test and a
// bad free in the next, which is exactly what it would be.
@(private = "file")
publish :: proc(window: sciter_app.Window, name: string, fn: sciter_app.Native_Function) -> sciter_app.Value {
	v := sciter_app.value_from_function(fn, &g_app, runtime.default_allocator())
	sciter_app.set_global(window, name, &v)
	return v
}

// Evaluates and renders the result the way script's `String()` would, which keeps the assertions
// readable when what comes back is an object.
@(private = "file")
eval_string :: proc(t: ^testing.T, window: sciter_app.Window, source: string) -> string {
	v, err := sciter_app.eval(window, source)
	testing.expect_value(t, err, nil)
	defer sciter_app.value_clear(&v)
	s, serr := sciter_app.value_to_display_string(&v, allocator = context.temp_allocator)
	testing.expect_value(t, serr, nil)
	return s
}

// ---------------------------------------------------------------------------------------------------
// Native functors

// The whole point of the mechanism, in one assertion: a name the document never defined, called from
// script, running Odin, and the answer crossing back.
@(test)
test_script_can_call_a_procedure_the_document_never_defined :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}
	publish_functors(window)

	testing.expect_value(t, eval_string(t, window, `typeof odin_reverse`), "function")
	testing.expect_value(t, eval_string(t, window, `odin_reverse("stressed")`), "desserts")

	// It ran in Odin, and the user_data pointer is how it knew where the state was.
	testing.expect_value(t, g_app.calls, 1)
}

// Reversal is by rune rather than by byte, which is the part that breaks silently if it is wrong - and
// only for input nobody tests with.
@(test)
test_a_functor_reverses_multi_byte_text_by_rune :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}
	publish_functors(window)

	testing.expect_value(t, eval_string(t, window, `odin_reverse("héllo")`), "olléh")
	testing.expect_value(t, eval_string(t, window, `odin_reverse("日本語")`), "語本日")
	testing.expect_value(t, eval_string(t, window, `odin_reverse("")`), "")
}

// Every script type arrives as itself. `units` is what separates the three things that are all
// `.OBJECT`: an array, a plain object and a function.
@(test)
test_every_script_type_arrives_at_a_functor_as_the_matching_value_type :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	// A functor that reports what it was handed, rather than doing anything with it.
	echo := publish(window, "echo_types", echo_arg_types)
	defer sciter_app.value_clear(&echo)

	testing.expect_value(t, eval_string(t, window, `echo_types(1).join("|")`), "INT/0")
	testing.expect_value(t, eval_string(t, window, `echo_types("s").join("|")`), "STRING/0")
	testing.expect_value(t, eval_string(t, window, `echo_types(2.5).join("|")`), "FLOAT/0")
	testing.expect_value(t, eval_string(t, window, `echo_types(true).join("|")`), "BOOL/0")
	testing.expect_value(t, eval_string(t, window, `echo_types(null).join("|")`), "NULL/0")
	testing.expect_value(t, eval_string(t, window, `echo_types(undefined).join("|")`), "UNDEFINED/0")

	// The three OBJECT flavours, told apart by their units.
	testing.expect_value(t, eval_string(t, window, `echo_types([1,2]).join("|")`), "OBJECT/0")
	testing.expect_value(t, eval_string(t, window, `echo_types({a:1}).join("|")`), "OBJECT/1")
	testing.expect_value(t, eval_string(t, window, `echo_types(function(){}).join("|")`), "OBJECT/4")

	// And a date is its own type rather than a number.
	testing.expect_value(t, eval_string(t, window, `echo_types(new Date()).join("|")`), "DATE/16")

	// Several at once, in order.
	testing.expect_value(
		t,
		eval_string(t, window, `echo_types(1, "s", 2.5, true).join("|")`),
		"INT/0|STRING/0|FLOAT/0|BOOL/0",
	)
}

// **A functor has no arity.** Script may call it with any number of arguments, including none, and the
// slice is simply that long - so a functor that indexes `args` without checking `len` reads off the end
// on the first caller who forgets one. `odin_reverse` returns a message rather than crashing, which is
// the pattern worth copying.
@(test)
test_a_functor_is_called_with_whatever_arguments_script_passes :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}
	publish_functors(window)

	count := publish(window, "count_args", count_args)
	defer sciter_app.value_clear(&count)

	testing.expect_value(t, eval_string(t, window, `count_args()`), "0")
	testing.expect_value(t, eval_string(t, window, `count_args(1)`), "1")
	testing.expect_value(t, eval_string(t, window, `count_args(1,2,3,4,5)`), "5")

	// The example's own guard, seen from script.
	testing.expect_value(t, eval_string(t, window, `odin_reverse()`), "odin_reverse expects exactly one argument")
	testing.expect_value(t, eval_string(t, window, `odin_reverse(1, 2)`), "odin_reverse expects exactly one argument")
}

// The result does not have to be a scalar: a map built in Odin arrives as a script object with the same
// keys, and the numbers keep their types across the boundary.
@(test)
test_a_functor_can_return_an_object_and_script_reads_its_fields :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}
	publish_functors(window)

	testing.expect_value(t, eval_string(t, window, `typeof odin_stats()`), "object")
	testing.expect_value(t, eval_string(t, window, `odin_stats().message`), "built in Odin")

	// `calls` counts this call itself, so it is at least one by the time script reads it.
	testing.expect_value(t, eval_string(t, window, `odin_stats().calls >= 1`), "true")
	testing.expect_value(t, eval_string(t, window, `typeof odin_stats().uptime`), "number")

	// The keys are the ones Odin set, and only those.
	testing.expect_value(
		t,
		eval_string(t, window, `Object.keys(odin_stats()).sort().join(",")`),
		"calls,message,uptime",
	)
}

// A functor that returns nothing hands script `undefined` rather than null or an empty object - the
// zero Value already is that, so `return {}` is the idiomatic "no result".
@(test)
test_a_functor_that_returns_nothing_gives_script_undefined :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	nothing := publish(window, "returns_nothing", returns_nothing)
	defer sciter_app.value_clear(&nothing)

	testing.expect_value(t, eval_string(t, window, `typeof returns_nothing()`), "undefined")
	testing.expect_value(t, eval_string(t, window, `returns_nothing() === undefined`), "true")
}

// **There is no way to throw from a functor by returning.** An error-flavoured Value - the thing
// `value_parse` produces on bad input, and the only "error" a Value can be - arrives in script as an
// ordinary string. Script sees a value, not an exception, so a functor that fails has to say so in its
// return value and the caller has to look.
@(test)
test_returning_an_error_value_from_a_functor_does_not_throw_in_script :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	failing := publish(window, "returns_error", returns_an_error_value)
	defer sciter_app.value_clear(&failing)

	// It does not throw: the catch arm is never reached.
	caught := eval_string(t, window, `try { returns_error(); "did not throw" } catch (e) { "threw" }`)
	testing.expect_value(t, caught, "did not throw")
	testing.expect_value(t, eval_string(t, window, `typeof returns_error()`), "string")
}

// ---------------------------------------------------------------------------------------------------
// SOM assets, from script

// The asset's three shapes at once: a getter, a setter and a method, all running Odin, reached under
// the class name.
@(test)
test_script_reads_writes_and_calls_an_odin_object_by_name :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	testing.expect_value(t, eval_string(t, window, `typeof Backend`), "object")

	// A getter: Odin's state, read from script.
	g_app.calls = 7
	testing.expect_value(t, eval_string(t, window, `Backend.calls`), "7")

	// A setter: script's value, written into Odin.
	testing.expect_value(t, eval_string(t, window, `Backend.calls = 99; Backend.calls`), "99")
	testing.expect_value(t, g_app.calls, 99)

	// A method, with its arguments and its result crossing.
	testing.expect_value(t, eval_string(t, window, `Backend.sum(20, 22)`), "42")

	// `sum` counts itself, so `reset` has something to do.
	testing.expect_value(t, eval_string(t, window, `Backend.reset(); Backend.calls`), "0")
	testing.expect_value(t, g_app.calls, 0)

	// A string setter, and the copy it has to make - the Value is borrowed for the call.
	testing.expect_value(
		t,
		eval_string(t, window, `Backend.greeting = "set from script"; Backend.greeting`),
		"set from script",
	)
	testing.expect_value(t, g_app.greeting, "set from script")
}

// **SOM members are not enumerable.** Every property works and none of them is listed, so script has to
// know the names - which is normal for an interface and startling if you expected a plain object.
@(test)
test_an_assets_members_do_not_show_up_in_object_keys :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	testing.expect_value(t, eval_string(t, window, `Object.keys(Backend).length`), "0")
	testing.expect_value(t, eval_string(t, window, `Backend.calls >= 0`), "true") // and yet
	testing.expect_value(t, eval_string(t, window, `typeof Backend.sum`), "function")

	// It renders as what it is, rather than as `[object Object]`.
	testing.expect_value(t, eval_string(t, window, `String(Backend)`), "[asset Backend]")
}

// A getter or setter that answers false, and a method that does, all become a `TypeError` in script.
// That is the only way to throw from Odin into script, and it costs the return value.
@(test)
test_refusing_a_property_or_a_method_throws_a_type_error_in_script :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	// `set_calls` returns false when the Value is not a number.
	refused := eval_string(t, window, `try { Backend.calls = "not a number"; "assigned" } catch (e) { "threw" }`)
	testing.expect_value(t, refused, "threw")

	// And the assignment did not happen.
	g_app.calls = 3
	bad := eval_string(t, window, `try { Backend.calls = "nope" } catch (e) {} Backend.calls`)
	testing.expect_value(t, bad, "3")

	// A property the class does not declare is undefined rather than an error.
	testing.expect_value(t, eval_string(t, window, `typeof Backend.nosuchproperty`), "undefined")
}

// **The ordering rule, from both sides.** A functor lives in the document's globals and is gone when the
// document is replaced; an asset is published on the engine and survives. That asymmetry is why
// `set_global_asset` goes before `load_html` and `set_global` after it - and it is silent, because a
// missing global is `undefined` rather than an error.
@(test)
test_a_global_asset_outlives_a_reload_where_a_functor_does_not :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}
	publish_functors(window)

	testing.expect_value(t, eval_string(t, window, `typeof odin_reverse`), "function")
	testing.expect_value(t, eval_string(t, window, `typeof Backend`), "object")

	testing.expect_value(t, sciter_app.load_html(window, TEST_DOC), nil)

	testing.expect_value(t, eval_string(t, window, `typeof odin_reverse`), "undefined")
	testing.expect_value(t, eval_string(t, window, `typeof Backend`), "object")

	// Republishing is all it takes, and it has to happen for every document.
	publish_functors(window)
	testing.expect_value(t, eval_string(t, window, `typeof odin_reverse`), "function")
}

// ---------------------------------------------------------------------------------------------------
// SOM assets, from Odin
//
// The same object without script in the way. This is how a host reads a *built-in* asset - the one on
// `<input>`, or `<video>`'s `renderingSite` - and the passport is how it finds out what is there.

// The passport is the asset describing itself, and it is readable before any window exists: it is a
// property of the class, not of a document.
@(test)
test_an_asset_lists_its_own_properties_and_methods :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}
	_ = window

	passport := sciter_app.asset_passport(g_asset)
	testing.expect(t, passport != nil, "an asset built here always has a passport")
	testing.expect_value(t, int(passport.n_properties), 2)
	testing.expect_value(t, int(passport.n_methods), 2)

	properties, methods := sciter_app.asset_members(g_asset, context.temp_allocator)
	testing.expect_value(t, len(properties), 2)
	testing.expect_value(t, properties[0], "calls")
	testing.expect_value(t, properties[1], "greeting")
	testing.expect_value(t, len(methods), 2)
	testing.expect_value(t, methods[0], "sum")
	testing.expect_value(t, methods[1], "reset")

	// Nothing to describe, rather than a crash.
	testing.expect(t, sciter_app.asset_passport(nil) == nil)
	no_properties, no_methods := sciter_app.asset_members(nil, context.temp_allocator)
	testing.expect(t, no_properties == nil && no_methods == nil)
}

// Reading and writing through the passport, with no document involved. `asset_set` is the writer, and
// the one call in this pair that had no test until now.
@(test)
test_an_assets_properties_can_be_read_and_written_without_script :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}
	_ = window

	g_app.calls = 11
	current, gerr := sciter_app.asset_get(g_asset, "calls")
	testing.expect_value(t, gerr, nil)
	defer sciter_app.value_clear(&current)
	n, _ := sciter_app.value_to_int(&current)
	testing.expect_value(t, n, i32(11))

	replacement := sciter_app.value_from(i32(5))
	defer sciter_app.value_clear(&replacement)
	testing.expect_value(t, sciter_app.asset_set(g_asset, "calls", &replacement), nil)
	testing.expect_value(t, g_app.calls, 5) // the setter ran, in Odin

	// A name the passport does not list is `.Not_Found`, in both directions...
	_, missing := sciter_app.asset_get(g_asset, "nosuch")
	testing.expect_value(t, missing, sciter_app.Error(sciter_app.Api_Error.Not_Found))
	testing.expect_value(
		t,
		sciter_app.asset_set(g_asset, "nosuch", &replacement),
		sciter_app.Error(sciter_app.Api_Error.Not_Found),
	)

	// ...and a setter that refuses the value is `.Call_Failed`, which is a different thing: the name
	// was there, the write was rejected.
	wrong := sciter_app.value_from("not a number")
	defer sciter_app.value_clear(&wrong)
	testing.expect_value(
		t,
		sciter_app.asset_set(g_asset, "calls", &wrong),
		sciter_app.Error(sciter_app.Api_Error.Call_Failed),
	)
	testing.expect_value(t, g_app.calls, 5) // unchanged
}

// Calling a method directly. **The engine records a method's arity and does not enforce it**, so a
// `params = 2` method is called with one argument without complaint - the check has to be in the
// method, exactly as it does for a functor.
@(test)
test_an_assets_methods_can_be_called_without_script_and_arity_is_not_enforced :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}
	_ = window

	two := []sciter_app.Value{sciter_app.value_from(i32(20)), sciter_app.value_from(i32(22))}
	defer for &v in two {sciter_app.value_clear(&v)}

	result, err := sciter_app.asset_call(g_asset, "sum", two)
	testing.expect_value(t, err, nil)
	defer sciter_app.value_clear(&result)
	total, _ := sciter_app.value_to_int(&result)
	testing.expect_value(t, total, i32(42))

	// One argument to a two-parameter method: accepted.
	one := []sciter_app.Value{sciter_app.value_from(i32(3))}
	defer for &v in one {sciter_app.value_clear(&v)}
	short, serr := sciter_app.asset_call(g_asset, "sum", one)
	testing.expect_value(t, serr, nil)
	defer sciter_app.value_clear(&short)
	partial, _ := sciter_app.value_to_int(&short)
	testing.expect_value(t, partial, i32(3))

	// None at all: also accepted, and `sum` of nothing is zero.
	empty, eerr := sciter_app.asset_call(g_asset, "sum", nil)
	testing.expect_value(t, eerr, nil)
	defer sciter_app.value_clear(&empty)
	zero, _ := sciter_app.value_to_int(&empty)
	testing.expect_value(t, zero, i32(0))

	_, nerr := sciter_app.asset_call(g_asset, "nosuchmethod", nil)
	testing.expect_value(t, nerr, sciter_app.Error(sciter_app.Api_Error.Not_Found))
}

// An asset in a Value, which is how one is handed to script as an argument or a return rather than
// published under a name. The Value carries the pointer and **does not take a reference** - the C
// header says so and nothing here changes it - so the asset has to outlive every Value made from it.
@(test)
test_an_asset_round_trips_through_a_value_without_taking_a_reference :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}
	_ = window

	v := sciter_app.value_from_asset(&g_asset.base)
	defer sciter_app.value_clear(&v)

	kind, _ := sciter_app.value_type(&v)
	testing.expect_value(t, kind, sciter.Value_Type.ASSET)

	back, err := sciter_app.value_to_asset(&v)
	testing.expect_value(t, err, nil)
	testing.expect(t, back == &g_asset.base, "the same asset comes back out")

	// Clearing the Value leaves the asset alone, which is the other half of "no reference was taken":
	// it is still readable, and still answers its passport.
	sciter_app.value_clear(&v)
	testing.expect(t, sciter_app.asset_passport(g_asset) != nil)

	// Anything else is refused rather than reinterpreted as a pointer, which is the one thing that
	// would be fatal here.
	other := sciter_app.value_from(i32(1))
	defer sciter_app.value_clear(&other)
	_, werr := sciter_app.value_to_asset(&other)
	testing.expect_value(t, werr, sciter_app.Error(sciter_app.Api_Error.Wrong_Type))

	text := sciter_app.value_from("not an asset")
	defer sciter_app.value_clear(&text)
	_, terr := sciter_app.value_to_asset(&text)
	testing.expect_value(t, terr, sciter_app.Error(sciter_app.Api_Error.Wrong_Type))
}

// ---------------------------------------------------------------------------------------------------
// Functors the tests above publish, and nothing else uses.

// Reports the `Value_Type` and units of each argument, as "TYPE/units" strings.
@(private = "file")
echo_arg_types :: proc(args: []sciter_app.Value, user_data: rawptr) -> sciter_app.Value {
	result: sciter_app.Value
	for &arg, i in args {
		kind, units := sciter_app.value_type(&arg)
		described := sciter_app.value_from(fmt.tprintf("%v/%v", kind, units))
		defer sciter_app.value_clear(&described)
		sciter_app.value_set_at(&result, i, &described)
	}
	return result
}

@(private = "file")
count_args :: proc(args: []sciter_app.Value, user_data: rawptr) -> sciter_app.Value {
	return sciter_app.value_from(i32(len(args)))
}

@(private = "file")
returns_nothing :: proc(args: []sciter_app.Value, user_data: rawptr) -> sciter_app.Value {
	return {}
}

// `value_parse` on text the dialect rejects hands back a string carrying the `.ERROR` unit, which is
// the only "error value" this API has. Script does not treat it as one.
@(private = "file")
returns_an_error_value :: proc(args: []sciter_app.Value, user_data: rawptr) -> sciter_app.Value {
	v, _ := sciter_app.value_parse("nonsense json {")
	return v
}
