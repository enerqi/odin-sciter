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

import "../sciter_app"
import "core:fmt"
import "core:os"
import "core:strings"
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
