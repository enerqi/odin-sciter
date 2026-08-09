// Exposing an Odin procedure to JavaScript.
//
//   just example call_odin_from_js
//
// `eval` and `call` go one way: Odin drives script. This is the other direction. A VALUE can hold a
// pointer to an Odin procedure - a "native functor" - and script then calls it like any other
// function. Put one in the document's globals and it is reachable as `globalThis.name`.
//
// Two things to keep straight:
//
//   - the globals belong to the *document*, not the window, so this has to be redone after every load
//   - the procedure runs on the engine's thread, inside script's stack frame. Blocking here freezes
//     the UI, and panicking here unwinds through C++
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
</script>
</head>
<body>
  <h1>call_odin_from_js</h1>
  <input type="text" value="hello from script" />
  <p>
    <button id="reverse">odin_reverse(input)</button>
    <button id="stats">odin_stats()</button>
  </p>
  <div id="out">Click a button. Both handlers call into Odin.</div>
</body>
</html>`

// State the exposed procedures share. Its address is handed to `value_from_function` as user_data and
// comes back on every call, which is how a native functor gets at anything other than globals.
App :: struct {
	calls:   int,
	started: time.Time,
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
		started = time.now(),
	}

	window, werr := sciter_app.create_window({width = 720, height = 460})
	if werr != nil {
		fmt.eprintln("could not create a window:", werr)
		os.exit(1)
	}
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
