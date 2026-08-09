// Running JavaScript from Odin and reading the result back.
//
//   just example eval
//   odin test examples/eval.odin -file -define:ODIN_TEST_THREADS=1
//
// `eval` hands a string to the document's QuickJS runtime and returns whatever it evaluated to, as a
// VALUE. VALUE is the engine's variant type and the one thing in these bindings with a lifetime rule:
// anything that comes out of the engine owns a reference, and the receiver has to `value_clear` it.
// `defer value_clear(&v)` on the line after you get one is the whole discipline.
//
// The `@(test)` procs at the bottom exercise the conversions with no window and no display, which is
// most of what there is to test in a bindings library.
package main

import sciter ".."
import "../sciter_app"
import "core:fmt"
import "core:os"
import "core:testing"

DOC :: `<html>
<head><style>
  html { background: #1e1e2e; color: #cdd6f4; font: 16px system; }
  body { padding: 2em; margin: 0; }
  h1   { color: #89b4fa; margin-top: 0; }
  pre  { background: #313244; padding: 1em; border-radius: 4px; font: 14px monospace; }
</style>
<script type="module">
  // Anything defined here is reachable from Odin through eval() and call().
  globalThis.answer = 42;
  globalThis.greet  = function(who) { return "hello, " + who; }
  globalThis.report = function(lines) { document.$("pre").innerText = lines.join("\n"); }
</script>
</head>
<body>
  <h1>eval</h1>
  <p>Odin evaluated these, read the results back, and sent them here with <code>call</code>:</p>
  <pre>...</pre>
</body>
</html>`

main :: proc() {
	if !sciter_app.load_engine() {
		os.exit(1)
	}
	// A script error is otherwise completely silent - eval just returns .Eval_Failed.
	sciter_app.set_default_debug_output()

	if err := sciter_app.init(); err != nil {
		fmt.eprintln("init failed:", err)
		os.exit(1)
	}

	window, werr := sciter_app.create_window({width = 720, height = 520})
	if werr != nil {
		fmt.eprintln("could not create a window:", werr)
		os.exit(1)
	}
	if err := sciter_app.load_html(window, DOC); err != nil {
		fmt.eprintln("could not load the document:", err)
		os.exit(1)
	}

	// Each of these gets a fresh Value out of the engine, so each one owes a clear.
	lines: [dynamic]string
	defer {
		for line in lines {delete(line)}
		delete(lines)
	}

	// A number.
	{
		v, err := sciter_app.eval(window, "answer * 2")
		if err != nil {
			fmt.eprintln("eval failed:", err)
			os.exit(1)
		}
		defer sciter_app.value_clear(&v)

		n, _ := sciter_app.value_to_int(&v)
		append(&lines, fmt.aprintf("%-22s -> %d", "answer * 2", n))
	}

	// A string. Note that the engine hands strings back as UTF-16; `value_to_string` allocates the
	// UTF-8 copy, so the result is the caller's to delete.
	{
		v, _ := sciter_app.eval(window, `greet("odin")`)
		defer sciter_app.value_clear(&v)

		s, err := sciter_app.value_to_string(&v, context.temp_allocator)
		if err != nil {
			fmt.eprintln("not a string:", err)
			os.exit(1)
		}
		append(&lines, fmt.aprintf(`%-22s -> %q`, `greet("odin")`, s))
	}

	// An array. In Sciter an array and a map are the same machinery, so `value_len` and `value_at`
	// work on both.
	{
		v, _ := sciter_app.eval(window, "[1, 2, 3].map(x => x * x)")
		defer sciter_app.value_clear(&v)

		n, _ := sciter_app.value_len(&v)
		total: i32
		for i in 0 ..< n {
			element, _ := sciter_app.value_at(&v, i)
			defer sciter_app.value_clear(&element)

			x, _ := sciter_app.value_to_int(&element)
			total += x
		}
		append(&lines, fmt.aprintf("%-22s -> %d (%d elements)", "sum of [1,2,3] squared", total, n))
	}

	// An object, rendered as JSON. `value_to_display_string` is the "just show me what is in there"
	// escape hatch, and the one to reach for when a result is not the type you expected.
	{
		v, _ := sciter_app.eval(window, `({name: "sciter", major: 6})`)
		defer sciter_app.value_clear(&v)

		json, _ := sciter_app.value_to_display_string(&v, .JSON_LITERAL, context.temp_allocator)
		append(&lines, fmt.aprintf("%-22s -> %s", "an object as JSON", json))

		// Reading one field by name rather than rendering the whole thing.
		major, _ := sciter_app.value_get(&v, "major")
		defer sciter_app.value_clear(&major)
		m, _ := sciter_app.value_to_int(&major)
		append(&lines, fmt.aprintf("%-22s -> %d", "  .major", m))
	}

	for line in lines {
		fmt.println(line)
	}

	// The other direction: build a Value in Odin and call a script function with it. Arguments are not
	// consumed by the call, so this one still has to be cleared here.
	{
		arg := sciter_app.value_make_array(len(lines))
		defer sciter_app.value_clear(&arg)

		for line, i in lines {
			element := sciter_app.value_from(line)
			defer sciter_app.value_clear(&element)
			sciter_app.value_set_at(&arg, i, &element)
		}

		result, err := sciter_app.call(window, "report", arg)
		if err != nil {
			fmt.eprintln("call failed:", err)
		} else {
			sciter_app.value_clear(&result)
		}
	}

	sciter_app.show(window)
	sciter_app.run()
	sciter_app.shutdown()
}

// ---------------------------------------------------------------------------------------------------
// Tests
//
// VALUE conversions need the engine loaded but no window and no display, so they run anywhere:
//
//   odin test examples/eval.odin -file -define:ODIN_TEST_THREADS=1
//
// The thread count is not optional. Sciter is single-threaded, and Odin's test runner is parallel by
// default; sharing one engine across test threads corrupts its heap rather than failing cleanly.
//
// Run these under ASan on Linux when touching the Value code - reference counting is exactly what
// benefits.

@(private = "file")
engine_loaded :: proc(t: ^testing.T) -> bool {
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}
	return true
}

@(test)
test_value_string_round_trip :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	for original in ([]string{"", "ascii", "unicode: é中文", "emoji: \U0001F600"}) {
		v := sciter_app.value_from(original)
		defer sciter_app.value_clear(&v)

		type, _ := sciter_app.value_type(&v)
		testing.expect_value(t, type, sciter.Value_Type.STRING)

		got, err := sciter_app.value_to_string(&v, context.temp_allocator)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, got, original)
	}
}

@(test)
test_value_scalars :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	i := sciter_app.value_from(i32(-7))
	defer sciter_app.value_clear(&i)
	n, _ := sciter_app.value_to_int(&i)
	testing.expect_value(t, n, i32(-7))

	f := sciter_app.value_from(0.5)
	defer sciter_app.value_clear(&f)
	x, _ := sciter_app.value_to_f64(&f)
	testing.expect_value(t, x, 0.5)

	b := sciter_app.value_from(true)
	defer sciter_app.value_clear(&b)
	flag, _ := sciter_app.value_to_bool(&b)
	testing.expect(t, flag)

	// A fresh Value is undefined, and that is a valid state rather than an error.
	empty: sciter_app.Value
	testing.expect(t, sciter_app.value_is_undefined(&empty))
}

@(test)
test_value_array :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	array := sciter_app.value_make_array(3)
	defer sciter_app.value_clear(&array)

	for i in 0 ..< 3 {
		element := sciter_app.value_from(i32(i * 10))
		defer sciter_app.value_clear(&element)
		testing.expect_value(t, sciter_app.value_set_at(&array, i, &element), nil)
	}

	n, err := sciter_app.value_len(&array)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, n, 3)

	for i in 0 ..< n {
		element, _ := sciter_app.value_at(&array, i)
		defer sciter_app.value_clear(&element)

		got, _ := sciter_app.value_to_int(&element)
		testing.expect_value(t, got, i32(i * 10))
	}
}

@(test)
test_value_map :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	m: sciter_app.Value
	defer sciter_app.value_clear(&m)

	name := sciter_app.value_from("sciter")
	defer sciter_app.value_clear(&name)
	testing.expect_value(t, sciter_app.value_set(&m, "engine", &name), nil)

	got, err := sciter_app.value_get(&m, "engine")
	testing.expect_value(t, err, nil)
	defer sciter_app.value_clear(&got)

	s, _ := sciter_app.value_to_string(&got, context.temp_allocator)
	testing.expect_value(t, s, "sciter")

	// A key that is not there reads as undefined, not as an error.
	missing, _ := sciter_app.value_get(&m, "nope")
	defer sciter_app.value_clear(&missing)
	testing.expect(t, sciter_app.value_is_undefined(&missing))
}

@(test)
test_value_copy_is_a_second_reference :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	original := sciter_app.value_from("shared")
	defer sciter_app.value_clear(&original)

	copy: sciter_app.Value
	testing.expect_value(t, sciter_app.value_copy(&copy, &original), nil)
	defer sciter_app.value_clear(&copy)

	testing.expect(t, sciter_app.value_equal(&original, &copy))

	// Clearing one must leave the other intact - that is the point of the reference count.
	sciter_app.value_clear(&copy)
	s, err := sciter_app.value_to_string(&original, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, s, "shared")
}

@(test)
test_utf16_helpers :: proc(t: ^testing.T) {
	for original in ([]string{"", "plain", "é中\U0001F600"}) {
		w := sciter_app.utf16_from_string(original, context.temp_allocator)

		// The result is NUL-terminated, and its len counts the terminator.
		testing.expect_value(t, len(w), sciter_app.utf16_len(original) + 1)
		testing.expect_value(t, w[len(w) - 1], u16(0))

		back := sciter_app.string_from_utf16(raw_data(w), uint(len(w) - 1), context.temp_allocator)
		testing.expect_value(t, back, original)
	}
}
