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
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

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
	// An error in the *document's* own <script> is otherwise completely silent. (An error in a script
	// passed to `eval` is not - it comes back as the returned Value, see `eval`.)
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

		// The same decode without being told the length. Sciter hands these back from the callbacks
		// that report no length - the debug output, and the request getters - so it has to agree with
		// the counted form on everything, including text with astral-plane characters in it where a
		// rune is two UTF-16 units.
		counted := sciter_app.string_from_utf16_cstring(raw_data(w), context.temp_allocator)
		testing.expect_value(t, counted, original)
	}

	// A nil pointer is the empty string rather than a crash, which is what a callback that reports
	// nothing looks like.
	testing.expect_value(t, sciter_app.string_from_utf16_cstring(nil, context.temp_allocator), "")

	// It stops at the NUL, and does not run on into whatever follows it.
	buf := [?]u16{'o', 'k', 0, 'x', 'x'}
	testing.expect_value(t, sciter_app.string_from_utf16_cstring(raw_data(buf[:]), context.temp_allocator), "ok")
}

@(test)
test_value_wrong_type_is_an_error :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	// The extraction calls are not converters: asking a number for its string fails rather than
	// rendering it. That distinction is the whole reason value_to_display_string exists.
	n := sciter_app.value_from(i32(42))
	defer sciter_app.value_clear(&n)

	_, err := sciter_app.value_to_string(&n, context.temp_allocator)
	testing.expect_value(t, err, sciter_app.Error(sciter.Value_Result.INCOMPATIBLE_TYPE))

	// And it fails for *every* non-string type rather than for some of them, which is what makes the
	// error worth checking instead of the result: the engine never hands back a partial string here,
	// so a caller that ignores `err` gets "" and not something misleading. Measured across the lot.
	undefined: sciter_app.Value // the zero Value is undefined
	f := sciter_app.value_from(3.5)
	b := sciter_app.value_from(true)
	array := sciter_app.value_make_array(3)
	bytes := sciter_app.value_from([]u8{1, 2, 3})
	defer {
		sciter_app.value_clear(&f)
		sciter_app.value_clear(&b)
		sciter_app.value_clear(&array)
		sciter_app.value_clear(&bytes)
	}

	map_value: sciter_app.Value
	one := sciter_app.value_from(i32(1))
	sciter_app.value_set(&map_value, "a", &one)
	sciter_app.value_clear(&one)
	defer sciter_app.value_clear(&map_value)

	incompatible := [?]struct {
		name:  string,
		value: ^sciter_app.Value,
	} {
		{"undefined", &undefined},
		{"float", &f},
		{"bool", &b},
		{"array", &array},
		{"map", &map_value},
		{"bytes", &bytes},
	}
	for entry in incompatible {
		s, e := sciter_app.value_to_string(entry.value, context.temp_allocator)
		testing.expectf(
			t,
			e == sciter_app.Error(sciter.Value_Result.INCOMPATIBLE_TYPE),
			"%s: expected INCOMPATIBLE_TYPE, got %v",
			entry.name,
			e,
		)
		testing.expectf(t, s == "", "%s: a failed extraction returns the empty string", entry.name)
	}

	// A string, of course, works - including an empty one, which is not confused with a failure.
	empty := sciter_app.value_from("")
	defer sciter_app.value_clear(&empty)
	s, serr := sciter_app.value_to_string(&empty, context.temp_allocator)
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, s, "")
}

@(test)
test_value_display_string :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	array := sciter_app.value_make_array(0)
	defer sciter_app.value_clear(&array)
	for i in 0 ..< 3 {
		element := sciter_app.value_from(i32(i))
		defer sciter_app.value_clear(&element)
		sciter_app.value_set_at(&array, i, &element)
	}

	json, err := sciter_app.value_to_display_string(&array, .JSON_LITERAL, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, json, "[0,1,2]")

	// ValueToString converts in place, so the wrapper copies first. If it did not, `array` would be a
	// string by now and this would be the test that noticed.
	type, _ := sciter_app.value_type(&array)
	testing.expect_value(t, type, sciter.Value_Type.ARRAY)
}

// A native functor is normally reached from script, which needs a document and a window. It does not
// have to be: a functor Value can be invoked directly, which exercises the whole path - the wrapper
// record, the engine's call into `proc "system"`, the restored context, and the release callback that
// frees the record when the last reference goes - with no display anywhere.
@(private = "file")
Functor_State :: struct {
	calls: int,
}

@(private = "file")
test_functor :: proc(args: []sciter_app.Value, user_data: rawptr) -> sciter_app.Value {
	state := (^Functor_State)(user_data)
	state.calls += 1

	if len(args) != 1 {
		return sciter_app.value_from(i32(-1))
	}
	// Allocating here is the point: it only works if the calling context was restored.
	s, err := sciter_app.value_to_string(&args[0], context.temp_allocator)
	if err != nil {
		return sciter_app.value_from(i32(-2))
	}
	return sciter_app.value_from(i32(len(s)))
}

@(test)
test_native_functor_round_trip :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	state := Functor_State{}

	fn := sciter_app.value_from_function(test_functor, &state)
	defer sciter_app.value_clear(&fn)
	testing.expect(t, sciter_app.value_is_function(&fn), "value_from_function must produce a functor")

	arg := sciter_app.value_from("four")
	defer sciter_app.value_clear(&arg)

	result, err := sciter_app.value_invoke(&fn, nil, {arg})
	testing.expect_value(t, err, nil)
	defer sciter_app.value_clear(&result)

	n, _ := sciter_app.value_to_int(&result)
	testing.expect_value(t, n, i32(4))
	testing.expect_value(t, state.calls, 1)

	// The argument is borrowed for the call, not consumed, so it is still usable afterwards.
	again, _ := sciter_app.value_to_string(&arg, context.temp_allocator)
	testing.expect_value(t, again, "four")
}

// ---------------------------------------------------------------------------------------------------
// Parsing, enumeration, and atoms
//
// Three more pieces of the Value machinery, all of which need the engine and none of which need a
// document: reading a Value out of text rather than storing text in one, walking a container without a
// call per element, and the engine's interned names.

@(test)
test_value_parse_json :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	v, err := sciter_app.value_parse(`{"name":"sciter","tags":[1,2,3]}`)
	testing.expect_value(t, err, nil)
	defer sciter_app.value_clear(&v)

	type, _ := sciter_app.value_type(&v)
	testing.expect_value(t, type, sciter.Value_Type.MAP)

	name, _ := sciter_app.value_get(&v, "name")
	defer sciter_app.value_clear(&name)
	s, _ := sciter_app.value_to_string(&name, context.temp_allocator)
	testing.expect_value(t, s, "sciter")

	tags, _ := sciter_app.value_get(&v, "tags")
	defer sciter_app.value_clear(&tags)
	n, _ := sciter_app.value_len(&tags)
	testing.expect_value(t, n, 3)

	// This is the whole distinction against `value_from_string`, which would have stored the document
	// as a string and left the type at STRING.
	stored := sciter_app.value_from(`{"name":"sciter"}`)
	defer sciter_app.value_clear(&stored)
	stored_type, _ := sciter_app.value_type(&stored)
	testing.expect_value(t, stored_type, sciter.Value_Type.STRING)
}

// **A `value_parse` that fails makes the engine throw a C++ exception and catch it itself**, which is
// ordinary control flow and which Odin's Windows test runner stops the test for - see the comment above
// the diagnostics tests in this file, and `docs/odin-test-runner-windows.patch`. That applies to every
// parse failure, so this whole test and the failing half of `test_value_parse_dialects` are guarded.
// With the patch applied, both run on Windows and pass.
when ODIN_OS != .Windows {

	@(test)
	test_value_parse_reports_the_message :: proc(t: ^testing.T) {
		if !engine_loaded(t) {return}

		// The engine reports a parse failure in the result rather than the return code, so the wrapper
		// has to look at what came back to know it failed at all.
		v, err := sciter_app.value_parse("[1,2")
		defer sciter_app.value_clear(&v)
		testing.expect_value(t, err, sciter_app.Error(sciter_app.Api_Error.Parse_Failed))

		testing.expect(t, sciter_app.value_is_error(&v), "the failure Value is a string carrying .ERROR")

		// And the Value that came back is the diagnosis, not a husk.
		message, merr := sciter_app.value_to_string(&v, context.temp_allocator)
		testing.expect_value(t, merr, nil)
		testing.expect(t, strings.contains(message, "JSON parsing error"), message)

		// An ordinary string is not an error string, so the check does not fire on everything.
		plain := sciter_app.value_from("no problem here")
		defer sciter_app.value_clear(&plain)
		testing.expect(t, !sciter_app.value_is_error(&plain))
	}

} // when ODIN_OS != .Windows - see above

@(test)
test_value_parse_dialects :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	// `.SIMPLE` parses one terminal value the way an attribute would, and never fails: a container is
	// not a container, it is the text of one.
	simple, serr := sciter_app.value_parse("[1,2,3]", .SIMPLE)
	testing.expect_value(t, serr, nil)
	defer sciter_app.value_clear(&simple)
	simple_type, _ := sciter_app.value_type(&simple)
	testing.expect_value(t, simple_type, sciter.Value_Type.STRING)

	// It does know the units an attribute can carry, which JSON has no notion of.
	length, lerr := sciter_app.value_parse("12.5%", .SIMPLE)
	testing.expect_value(t, lerr, nil)
	defer sciter_app.value_clear(&length)
	length_type, units := sciter_app.value_type(&length)
	testing.expect_value(t, length_type, sciter.Value_Type.LENGTH)
	testing.expect_value(t, units, u32(sciter.Value_Unit_Type.UT_PR))

	// The same text under `.JSON_LITERAL` is a plain number - the `%` is dropped, not honoured.
	number, nerr := sciter_app.value_parse("12.5%", .JSON_LITERAL)
	testing.expect_value(t, nerr, nil)
	defer sciter_app.value_clear(&number)
	number_type, _ := sciter_app.value_type(&number)
	testing.expect_value(t, number_type, sciter.Value_Type.FLOAT)

	// `.JSON_MAP` resumes parsing an object whose opening `{` has already been eaten - so it wants the
	// body *and* the closing brace, and keys need no quotes.
	body, berr := sciter_app.value_parse(`a:1}`, .JSON_MAP)
	testing.expect_value(t, berr, nil)
	defer sciter_app.value_clear(&body)
	body_type, _ := sciter_app.value_type(&body)
	testing.expect_value(t, body_type, sciter.Value_Type.MAP)

	// A whole document is therefore the failing case, not the obvious success: the `{` it starts with
	// is one the parser has already consumed as far as it is concerned.
	//
	// **Only the failing half is guarded on Windows.** Every `value_parse` failure makes the engine throw
	// - see `test_value_parse_reports_the_message` - and Odin's Windows test runner stops the test for
	// it. The successes above run on every platform, which is most of what this test is for.
	when ODIN_OS != .Windows {
		whole, werr := sciter_app.value_parse(`{"a":1}`, .JSON_MAP)
		defer sciter_app.value_clear(&whole)
		testing.expect_value(t, werr, sciter_app.Error(sciter_app.Api_Error.Parse_Failed))
	}
}

@(private = "file")
Walk :: struct {
	keys:       [dynamic]string,
	values:     [dynamic]i32,
	stop_after: int,
}

// Both lists and every key in them, given back. They are filled from inside an engine callback and
// read after it, so they cannot live in the temp arena - see `collect`.
@(private = "file")
walk_destroy :: proc(walk: ^Walk) {
	for key in walk.keys {
		// An array's keys arrive as the literal "" that `collect` substitutes, which is not an
		// allocation and must not be freed as one.
		if len(key) > 0 {
			delete(key)
		}
	}
	delete(walk.keys)
	delete(walk.values)
}

@(private = "file")
collect :: proc(key: ^sciter_app.Value, value: ^sciter_app.Value, user_data: rawptr) -> bool {
	walk := (^Walk)(user_data)

	// `value_to_string` allocates, so the key is the walk's own copy rather than a borrow of the
	// engine's storage. **The allocator is the other half of keeping it**: this runs inside an engine
	// callback, and the package restores `context.temp_allocator` to the mark it had on the way in - so
	// a temp copy dies with the callback that made it, and a `[dynamic]` grown here dies with it too.
	// Anything a callback keeps needs an allocator that outlives the callback; `walk_destroy` gives
	// these back. See `callback_temp_scope` in sciter_app/sciter_app.odin.
	if k, err := sciter_app.value_to_string(key); err == nil {
		append(&walk.keys, k)
	} else {
		// An array reports its keys as undefined rather than as indexes, and that is what lands here.
		append(&walk.keys, "")
	}

	n, _ := sciter_app.value_to_int(value)
	append(&walk.values, n)

	return walk.stop_after == 0 || len(walk.values) < walk.stop_after
}

@(test)
test_value_each_walks_maps_and_arrays :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	m: sciter_app.Value
	defer sciter_app.value_clear(&m)
	for key, i in ([]string{"a", "b", "c"}) {
		element := sciter_app.value_from(i32(i))
		defer sciter_app.value_clear(&element)
		sciter_app.value_set(&m, key, &element)
	}

	walk: Walk
	defer walk_destroy(&walk)
	testing.expect_value(t, sciter_app.value_each(&m, collect, &walk), nil)
	testing.expect_value(t, len(walk.keys), 3)
	testing.expect_value(t, walk.keys[0], "a")
	testing.expect_value(t, walk.keys[2], "c")
	testing.expect_value(t, walk.values[1], i32(1))

	// An array walks the same way, but its keys are undefined - the position is not reported, so a
	// caller that needs it counts.
	array := sciter_app.value_make_array(0)
	defer sciter_app.value_clear(&array)
	for i in 0 ..< 3 {
		element := sciter_app.value_from(i32(i * 7))
		defer sciter_app.value_clear(&element)
		sciter_app.value_set_at(&array, i, &element)
	}

	over_array: Walk
	defer walk_destroy(&over_array)
	testing.expect_value(t, sciter_app.value_each(&array, collect, &over_array), nil)
	testing.expect_value(t, len(over_array.values), 3)
	testing.expect_value(t, over_array.values[2], i32(14))
	testing.expect_value(t, over_array.keys[0], "")
}

@(test)
test_value_each_stops_and_refuses :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	array := sciter_app.value_make_array(0)
	defer sciter_app.value_clear(&array)
	for i in 0 ..< 5 {
		element := sciter_app.value_from(i32(i))
		defer sciter_app.value_clear(&element)
		sciter_app.value_set_at(&array, i, &element)
	}

	// Returning false ends the walk where it is.
	early := Walk {
		stop_after = 2,
	}
	defer walk_destroy(&early)
	testing.expect_value(t, sciter_app.value_each(&array, collect, &early), nil)
	testing.expect_value(t, len(early.values), 2)

	// Something that is not a container is a failure, not an empty walk.
	scalar := sciter_app.value_from(i32(9))
	defer sciter_app.value_clear(&scalar)

	untouched: Walk
	defer walk_destroy(&untouched)
	testing.expect_value(
		t,
		sciter_app.value_each(&scalar, collect, &untouched),
		sciter_app.Error(sciter.Value_Result.INCOMPATIBLE_TYPE),
	)
	testing.expect_value(t, len(untouched.values), 0)

	// A nil visitor is caught here rather than handed to the engine.
	testing.expect_value(t, sciter_app.value_each(&array, nil), sciter_app.Error(sciter.Value_Result.BAD_PARAMETER))
}

@(test)
test_atoms_round_trip :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	width := sciter_app.atom("width")
	testing.expect_value(t, width, sciter_app.atom("width"))
	testing.expect(t, width != sciter_app.atom("height"))

	name, ok := sciter_app.atom_name(width, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, name, "width")

	// A name the engine has never seen is interned rather than refused, so there is no failing case
	// on the way in - only an atom nobody else refers to.
	fresh := sciter_app.atom("odin_sciter_atom_that_nothing_else_uses")
	back, fok := sciter_app.atom_name(fresh, context.temp_allocator)
	testing.expect(t, fok)
	testing.expect_value(t, back, "odin_sciter_atom_that_nothing_else_uses")

	// `ok` is false when there is no name to report, and `atom("")` is the one atom that is really
	// like that. There is deliberately no test here for an *invented* integer: `atom_name` segfaults
	// on some of them before `init` has run, which is the reason the doc comment says to pass only
	// atoms `atom` handed out.
	empty, eok := sciter_app.atom_name(sciter_app.atom(""), context.temp_allocator)
	testing.expect(t, !eok)
	testing.expect_value(t, empty, "")

	// Names are bytes rather than text: anything outside ASCII comes back re-encoded, so atoms are
	// for identifiers only. Pinned here because it is silent corruption otherwise.
	mangled, _ := sciter_app.atom_name(sciter_app.atom("é"), context.temp_allocator)
	testing.expect(t, mangled != "é", "non-ASCII atom names do not round-trip")
}

// ---------------------------------------------------------------------------------------------------
// The rest of the Value surface
//
// Lifetime, the null/undefined distinction, the 64-bit half of the integer API, and keys that are not
// strings. Two of these are defects, and both are silent ones.

// A zeroed Value is already valid - which is why nothing in this package calls `value_init` before
// first use. It earns its keep on a Value being *reused*, where it is the reset.
//
// It is not a `value_clear`, though: it overwrites rather than releasing, so calling it on a Value that
// still holds a reference loses that reference. Clear first, then init - or just clear, which leaves
// the Value undefined anyway.
@(test)
test_a_zeroed_value_is_already_valid_and_undefined :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	var: sciter_app.Value
	testing.expect(t, sciter_app.value_is_undefined(&var), "a zeroed Value needs no initialisation")

	sciter_app.value_init(&var)
	kind, _ := sciter_app.value_type(&var)
	testing.expect_value(t, kind, sciter.Value_Type.UNDEFINED)
	testing.expect(t, sciter_app.value_is_undefined(&var))

	// Reusing a slot: init returns it to undefined whatever it held.
	held := sciter_app.value_from("something")
	sciter_app.value_clear(&held) // release first - init does not
	sciter_app.value_init(&held)
	reused, _ := sciter_app.value_type(&held)
	testing.expect_value(t, reused, sciter.Value_Type.UNDEFINED)
}

// `null` and `undefined` are different types, exactly as they are in script - so "the key is not there"
// and "the key is there and holds null" are distinguishable, and `value_is_null` is not `!value_is_...`
// anything.
@(test)
test_null_and_undefined_are_different_types :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	var: sciter_app.Value
	testing.expect(t, sciter_app.value_is_undefined(&var))
	testing.expect(t, !sciter_app.value_is_null(&var), "an undefined Value is not a null one")

	null, err := sciter_app.value_parse("null")
	testing.expect_value(t, err, nil)
	defer sciter_app.value_clear(&null)

	kind, _ := sciter_app.value_type(&null)
	testing.expect_value(t, kind, sciter.Value_Type.NULL)
	testing.expect(t, sciter_app.value_is_null(&null))
	testing.expect(t, !sciter_app.value_is_undefined(&null), "a null Value is not an undefined one")

	// Which is what makes the distinction useful: a map can hold a null on purpose, and a missing key
	// comes back undefined.
	m: sciter_app.Value
	defer sciter_app.value_clear(&m)
	testing.expect_value(t, sciter_app.value_set(&m, "present", &null), nil)

	stored, gerr := sciter_app.value_get(&m, "present")
	testing.expect_value(t, gerr, nil)
	defer sciter_app.value_clear(&stored)
	testing.expect(t, sciter_app.value_is_null(&stored), "the null survived being stored")

	absent, aerr := sciter_app.value_get(&m, "absent")
	testing.expect_value(t, aerr, nil) // not an error, note
	defer sciter_app.value_clear(&absent)
	testing.expect(t, sciter_app.value_is_undefined(&absent))
}

// **A trap, and a silent one.** `value_from(i64(...))` makes a `.BIG_INT`, and `value_to_int` does not
// read those: it answers 0 and no error, even for a 5. Anything that has been through an `i64` reads
// back as zero through the 32-bit accessor.
@(test)
test_a_64_bit_integer_reads_back_as_zero_through_the_32_bit_accessor :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	small := sciter_app.value_from(i64(5))
	defer sciter_app.value_clear(&small)

	kind, _ := sciter_app.value_type(&small)
	testing.expect_value(t, kind, sciter.Value_Type.BIG_INT) // even though 5 fits an i32 easily

	truncated, terr := sciter_app.value_to_int(&small)
	testing.expect_value(t, terr, nil) // no complaint...
	testing.expect_value(t, truncated, i32(0)) // ...and no value either

	correct, cerr := sciter_app.value_to_i64(&small)
	testing.expect_value(t, cerr, nil)
	testing.expect_value(t, correct, i64(5))

	// An .INT, on the other hand, reads through both.
	plain := sciter_app.value_from(i32(7))
	defer sciter_app.value_clear(&plain)
	as_32, _ := sciter_app.value_to_int(&plain)
	as_64, err := sciter_app.value_to_i64(&plain)
	testing.expect_value(t, as_32, i32(7))
	testing.expect_value(t, err, nil)
	testing.expect_value(t, as_64, i64(7))
}

// The full range survives, and unlike some of the string conversions there is no coercion: a float or
// a numeric string is refused rather than rounded or parsed.
@(test)
test_the_whole_i64_range_round_trips_and_nothing_else_is_coerced_into_it :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	for n in ([]i64{0, -1, 1 << 40, min(i64), max(i64)}) {
		v := sciter_app.value_from(n)
		defer sciter_app.value_clear(&v)
		back, err := sciter_app.value_to_i64(&v)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, back, n)
	}

	incompatible := sciter_app.Error(sciter.Value_Result.INCOMPATIBLE_TYPE)

	f := sciter_app.value_from(3.9)
	defer sciter_app.value_clear(&f)
	_, ferr := sciter_app.value_to_i64(&f)
	testing.expect_value(t, ferr, incompatible)

	s := sciter_app.value_from("12")
	defer sciter_app.value_clear(&s)
	_, serr := sciter_app.value_to_i64(&s)
	testing.expect_value(t, serr, incompatible)
}

// A key does not have to be a string. Integers work, and so does a whole map - which is worth knowing
// because it means `value_key_at` can hand back something that is not text, and code that assumes
// otherwise gets an empty string rather than an error.
@(test)
test_a_map_key_can_be_an_integer_or_another_map :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	m: sciter_app.Value
	defer sciter_app.value_clear(&m)

	int_key := sciter_app.value_from(i32(42))
	defer sciter_app.value_clear(&int_key)
	int_value := sciter_app.value_from("by int")
	defer sciter_app.value_clear(&int_value)
	testing.expect_value(t, sciter_app.value_set_key(&m, &int_key, &int_value), nil)

	map_key, perr := sciter_app.value_parse(`{"k":1}`)
	testing.expect_value(t, perr, nil)
	defer sciter_app.value_clear(&map_key)
	map_value := sciter_app.value_from("by map")
	defer sciter_app.value_clear(&map_value)
	testing.expect_value(t, sciter_app.value_set_key(&m, &map_key, &map_value), nil)

	kind, _ := sciter_app.value_type(&m)
	testing.expect_value(t, kind, sciter.Value_Type.MAP)
	n, _ := sciter_app.value_len(&m)
	testing.expect_value(t, n, 2)

	// Both read back by the same key they went in under.
	by_int, ierr := sciter_app.value_get_key(&m, &int_key)
	testing.expect_value(t, ierr, nil)
	defer sciter_app.value_clear(&by_int)
	is, _ := sciter_app.value_to_string(&by_int, context.temp_allocator)
	testing.expect_value(t, is, "by int")

	by_map, merr := sciter_app.value_get_key(&m, &map_key)
	testing.expect_value(t, merr, nil)
	defer sciter_app.value_clear(&by_map)
	ms, _ := sciter_app.value_to_string(&by_map, context.temp_allocator)
	testing.expect_value(t, ms, "by map")

	// And the keys come back with their own types intact.
	first, kerr := sciter_app.value_key_at(&m, 0)
	testing.expect_value(t, kerr, nil)
	defer sciter_app.value_clear(&first)
	first_kind, _ := sciter_app.value_type(&first)
	testing.expect_value(t, first_kind, sciter.Value_Type.INT)

	second, serr := sciter_app.value_key_at(&m, 1)
	testing.expect_value(t, serr, nil)
	defer sciter_app.value_clear(&second)
	second_kind, _ := sciter_app.value_type(&second)
	testing.expect_value(t, second_kind, sciter.Value_Type.MAP)
}

// Setting the same key twice replaces rather than appending, so a map built in a loop cannot grow past
// the number of distinct keys. `value_set` is the string-key shorthand for the same call.
@(test)
test_setting_a_key_that_is_already_there_replaces_it :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	m: sciter_app.Value
	defer sciter_app.value_clear(&m)

	key := sciter_app.value_from("name")
	defer sciter_app.value_clear(&key)

	for word in ([]string{"first", "second", "third"}) {
		v := sciter_app.value_from(word)
		defer sciter_app.value_clear(&v)
		testing.expect_value(t, sciter_app.value_set_key(&m, &key, &v), nil)
	}

	n, _ := sciter_app.value_len(&m)
	testing.expect_value(t, n, 1)

	last, err := sciter_app.value_get_key(&m, &key)
	testing.expect_value(t, err, nil)
	defer sciter_app.value_clear(&last)
	s, _ := sciter_app.value_to_string(&last, context.temp_allocator)
	testing.expect_value(t, s, "third")
}

// Reading past the end is not an error - it is an `.UNDEFINED` Value. So a loop bounded by anything but
// `value_len` runs off the end silently, and the check is the type rather than the error.
//
// The other half: `value_key_at` refuses an *array* outright, though this package describes an array as
// a map keyed by 0..n and `value_at` works on both.
@(test)
test_reading_past_the_end_of_a_map_gives_undefined_and_an_array_has_no_keys :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	m: sciter_app.Value
	defer sciter_app.value_clear(&m)
	one := sciter_app.value_from("v")
	defer sciter_app.value_clear(&one)
	testing.expect_value(t, sciter_app.value_set(&m, "k", &one), nil)

	for index in ([]int{1, 5}) {
		key, kerr := sciter_app.value_key_at(&m, index)
		defer sciter_app.value_clear(&key)
		testing.expect_value(t, kerr, nil)
		testing.expect(t, sciter_app.value_is_undefined(&key), "past the end is undefined, not an error")

		element, eerr := sciter_app.value_at(&m, index)
		defer sciter_app.value_clear(&element)
		testing.expect_value(t, eerr, nil)
		testing.expect(t, sciter_app.value_is_undefined(&element))
	}

	// An array's elements are readable by index; its "keys" are not.
	array, perr := sciter_app.value_parse(`["a","b"]`)
	testing.expect_value(t, perr, nil)
	defer sciter_app.value_clear(&array)

	element, eerr := sciter_app.value_at(&array, 1)
	testing.expect_value(t, eerr, nil)
	defer sciter_app.value_clear(&element)
	s, _ := sciter_app.value_to_string(&element, context.temp_allocator)
	testing.expect_value(t, s, "b")

	_, kerr := sciter_app.value_key_at(&array, 1)
	testing.expect_value(t, kerr, sciter_app.Error(sciter.Value_Result.INCOMPATIBLE_TYPE))
}

// **A defect, and the one most likely to cost somebody a day.** `value_copy` shares the underlying map,
// and `value_isolate` is the call that is supposed to break the sharing before a write. It does not:
// `.OK`, and the write is still visible through the original.
//
// Measured on the copy, on the original, on both, and on a nested Value pulled out with `value_get`.
// This test fails loudly if a future engine implements it, which is what should happen - code written
// around "isolate does nothing" would then be doing something else.
@(test)
test_isolating_a_copy_does_not_stop_it_sharing_with_the_original :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	read_a :: proc(v: ^sciter_app.Value) -> i32 {
		field, _ := sciter_app.value_get(v, "a")
		defer sciter_app.value_clear(&field)
		n, _ := sciter_app.value_to_int(&field)
		return n
	}
	write_a :: proc(v: ^sciter_app.Value, n: i32) {
		field := sciter_app.value_from(n)
		defer sciter_app.value_clear(&field)
		sciter_app.value_set(v, "a", &field)
	}

	// First, the sharing itself, which is real and is the reason isolate exists.
	original, err := sciter_app.value_parse(`{"a":1}`)
	testing.expect_value(t, err, nil)
	defer sciter_app.value_clear(&original)

	shared: sciter_app.Value
	testing.expect_value(t, sciter_app.value_copy(&shared, &original), nil)
	defer sciter_app.value_clear(&shared)

	write_a(&shared, 2)
	testing.expect_value(t, read_a(&original), i32(2)) // one map, two handles

	// Now the same thing with the isolate that should have prevented it.
	source, serr := sciter_app.value_parse(`{"a":1}`)
	testing.expect_value(t, serr, nil)
	defer sciter_app.value_clear(&source)

	isolated: sciter_app.Value
	testing.expect_value(t, sciter_app.value_copy(&isolated, &source), nil)
	defer sciter_app.value_clear(&isolated)

	testing.expect_value(t, sciter_app.value_isolate(&isolated), nil)
	write_a(&isolated, 3)

	testing.expect_value(t, read_a(&isolated), i32(3))
	testing.expect_value(t, read_a(&source), i32(3)) // and here is the defect

	// Isolating the other side instead makes no difference either.
	other, oerr := sciter_app.value_parse(`{"a":1}`)
	testing.expect_value(t, oerr, nil)
	defer sciter_app.value_clear(&other)
	other_copy: sciter_app.Value
	sciter_app.value_copy(&other_copy, &other)
	defer sciter_app.value_clear(&other_copy)

	testing.expect_value(t, sciter_app.value_isolate(&other), nil)
	write_a(&other_copy, 4)
	testing.expect_value(t, read_a(&other), i32(4))
}

// What to do instead, since isolate cannot be relied on: build a new Value. `value_parse` of the same
// text produces an independent map, and so does walking one and writing the pairs into another.
@(test)
test_an_independent_copy_has_to_be_rebuilt_rather_than_isolated :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	source, err := sciter_app.value_parse(`{"a":1,"b":2}`)
	testing.expect_value(t, err, nil)
	defer sciter_app.value_clear(&source)

	// Walk it into a fresh map. `value_each` borrows its arguments, so the pairs are copied in.
	rebuilt: sciter_app.Value
	defer sciter_app.value_clear(&rebuilt)
	sciter_app.value_each(&source, proc(key, value: ^sciter_app.Value, user: rawptr) -> bool {
			sciter_app.value_set_key((^sciter_app.Value)(user), key, value)
			return true
		}, &rebuilt)

	n, _ := sciter_app.value_len(&rebuilt)
	testing.expect_value(t, n, 2)

	// Writing through the rebuilt one leaves the source alone, which is what isolate promised.
	replacement := sciter_app.value_from(i32(99))
	defer sciter_app.value_clear(&replacement)
	testing.expect_value(t, sciter_app.value_set(&rebuilt, "a", &replacement), nil)

	from_source, _ := sciter_app.value_get(&source, "a")
	defer sciter_app.value_clear(&from_source)
	original_a, _ := sciter_app.value_to_int(&from_source)
	testing.expect_value(t, original_a, i32(1))

	from_rebuilt, _ := sciter_app.value_get(&rebuilt, "a")
	defer sciter_app.value_clear(&from_rebuilt)
	new_a, _ := sciter_app.value_to_int(&from_rebuilt)
	testing.expect_value(t, new_a, i32(99))
}

// ---------------------------------------------------------------------------------------------------
// The engine's diagnostics
//
// Without a debug output handler a CSS typo, a bad URL and an exception in the document's own
// `<script>` are all completely silent, and nothing anywhere says why. `set_default_debug_output`
// prints them to stderr; this is the call underneath it, for routing them into a log or a panel.
//
// A script handed to `eval` is the exception: its errors arrive as the returned Value, with the message
// and a stack trace, whether or not any of this is installed - see `eval`.
//
// **These three cannot run under `-sanitize:address`**, and it is the sanitiser rather than the code:
// they load a document whose script will not parse, the engine's QuickJS throws a C++ exception to
// report it, and ASan aborts with `CHECK failed: "((real___cxa_throw)) != (0)"` because its interceptor
// cannot find a `__cxa_throw` to forward to in a binary that links no C++ runtime. Nothing is wrong
// with the memory. `just test_sanitize eval` therefore needs `-define:ODIN_TEST_NAMES=` naming the
// Value tests, which are what the sanitiser is here for and which are clean.

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
		// The guard's *other* Darwin rule - that the engine's thread is the main thread - turns itself
		// off under `ODIN_TEST`, so it needs nothing here.
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

// The only tests in this file that need a window: a diagnostic has to come from somewhere, and script
// only runs in a document. One window for the suite, never shown - see `dom_walk` for why.
@(private = "file")
// Shared by every test in this file, and created on first use. That is deliberate - a window per test
// would be slow, and closing one is itself hazardous (see `close` in sciter_app/window.odin) - but it
// makes the tests here order-coupled: **a test that changes the document must put it back**, usually by
// reloading `DOC`, or it breaks a later test and the failure points at the wrong one.
g_view: sciter_app.Windowless_View

@(private = "file")
test_window :: proc(t: ^testing.T) -> (window: sciter_app.Window, ok: bool) {
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
	// The engine keeps the window for the life of the process.
	context.allocator = runtime.default_allocator()

	if g_view.window == nil {
		v, err := sciter_app.create_windowless({width = 300, height = 200})
		testing.expect_value(t, err, nil)
		if v.window == nil {return nil, false}
		g_view = v
	}
	testing.expect_value(t, sciter_app.load_html(g_view.window, `<html><body><p>x</p></body></html>`), nil)

	// Layout happens on the heartbeat rather than on the load. Nothing here measures geometry, but
	// a document that has never been through a frame is a different thing to evaluate script
	// against, and the cost is microseconds.
	for i in 0 ..< 8 {
		sciter_app.windowless_heartbeat(&g_view, time.Duration(i) * 16 * time.Millisecond)
		sciter_app.paint_windowless(&g_view)
	}
	return g_view.window, true
}

@(private = "file")
Diagnostics :: struct {
	count:      int,
	last:       [256]u16, // the message, as the engine hands it over
	last_len:   u32,
	subsystem:  sciter.Output_Subsytems,
	severity:   sciter.Output_Severity,
	saw_script: bool,
	param:      rawptr,
}

@(private = "file")
g_diagnostics: Diagnostics

// `proc "system"`, because the engine calls it - so there is no context here and nothing may allocate.
// The message is copied into a fixed buffer and decoded later, on a thread that has one.
@(private = "file")
collect_diagnostic :: proc "system" (
	param: rawptr,
	subsystem: sciter.Output_Subsytems,
	severity: sciter.Output_Severity,
	text: [^]u16,
	text_length: u32,
) {
	g_diagnostics.count += 1
	g_diagnostics.subsystem = subsystem
	g_diagnostics.severity = severity
	g_diagnostics.param = param
	if subsystem == .SCRIPT {
		g_diagnostics.saw_script = true
	}

	n := min(text_length, u32(len(g_diagnostics.last)))
	for i in 0 ..< n {
		g_diagnostics.last[i] = text[i]
	}
	g_diagnostics.last_len = n
}

// **What reaches the handler is a script error in a *document*, not one from `eval`.** Measured: a
// `<script>` that will not parse produces a `.SCRIPT` diagnostic at `.ERROR`, and an unhandled throw
// produces one at `.WARNING` - while a bad `eval` produces nothing at all, whatever it returns. So this
// is the channel for the document's own code; `eval`'s own failures are reported by its return value
// and nowhere else.
//
// The message crosses as counted UTF-16 rather than as a NUL-terminated run, so `string_from_utf16` is
// the decoder for it, not `string_from_utf16_cstring`.
// **This test cannot run on Windows, and the reason is Odin's test runner rather than either the engine
// or this wrapper.** Loading a document whose script will not parse makes the engine throw a C++
// exception and catch it itself - ordinary operation, and the justfile's ASan notes already record that
// Sciter throws in normal use. On Windows every C++ throw is an SEH exception, and
// `core/testing/signal_handler_windows.odin` registers a vectored handler that stops the test on *any*
// exception code it sees, without filtering: `stop_test_callback` records the code and reports the test
// as signalled. Measured code `0xE06D7363`, which is MSVC's C++ exception marker.
//
// So the test dies at the `load_html` below and takes the rest of the binary's tests with it, reported
// as `Signal caught: Unknown` - which reads like a segfault and is not one. Nothing here can prevent it:
// `testing.expect_signal` only whitelists SIGILL, SIGSEGV and SIGFPE, none of which this is, and the
// runner's handler cannot be removed without its registration handle.
//
// **The fix belongs upstream, and it has been written and verified** - see docs/WINDOWS-CHECKLIST.md for
// the patch. `stop_test_callback` needs one early return for exception codes that do not mean "this
// thread cannot continue"; with it, all 38 tests in this file pass on Windows with no guard at all, a
// genuine null dereference is still caught and still reported as `Segmentation_Fault`, and `task_list`
// goes from hanging to green.
//
// The guard stays until that lands in a released Odin, because CI builds with the stock toolchain and
// an unguarded run there does not fail - it *hangs*, for the whole 45-minute job timeout. Take the guard
// off in one line once the runner is fixed. The behaviour it pins is not platform-specific; it is simply
// unobservable on a stock Windows toolchain.
//
// **The guard covers all three diagnostics tests**, not just this one: each of them loads a document
// whose script will not parse, because that is the only way to make the engine produce a diagnostic on
// demand, and so each of them throws. Do not add a fourth outside the `when`.
when ODIN_OS != .Windows {

	@(test)
	test_a_script_error_in_a_document_reaches_the_installed_handler :: proc(t: ^testing.T) {
		window, ok := test_window(t)
		if !ok {return}

		marker := rawptr(uintptr(0xD1A6))
		g_diagnostics = {}
		sciter_app.set_debug_output(collect_diagnostic, marker, window)
		// Detach before leaving: the engine keeps the pointer, and the tests after this one would go on
		// filling in a record they know nothing about.
		defer sciter_app.set_debug_output(nil, nil, window)

		BROKEN :: `<html><head><script type="module">this is not valid (((</script></head><body></body></html>`
		testing.expect_value(t, sciter_app.load_html(window, BROKEN), nil) // the *load* succeeds

		testing.expect(t, g_diagnostics.count > 0, "the engine had something to say about that script")
		testing.expect_value(t, g_diagnostics.subsystem, sciter.Output_Subsytems.SCRIPT)
		testing.expect_value(t, g_diagnostics.severity, sciter.Output_Severity.ERROR)
		testing.expect_value(t, g_diagnostics.param, marker) // passed straight through

		message := sciter_app.string_from_utf16(
			raw_data(g_diagnostics.last[:]),
			uint(g_diagnostics.last_len),
			context.temp_allocator,
		)
		testing.expect(t, strings.contains(message, "SyntaxError"), message)

		// An exception that nothing catches is the same channel at a lower severity - which matters,
		// because a handler that only logs `.ERROR` drops every unhandled rejection on the floor.
		g_diagnostics = {}
		THROWS :: `<html><head><script type="module">throw new Error("from a module")</script></head><body></body></html>`
		testing.expect_value(t, sciter_app.load_html(window, THROWS), nil)

		testing.expect(t, g_diagnostics.count > 0)
		testing.expect_value(t, g_diagnostics.subsystem, sciter.Output_Subsytems.SCRIPT)
		testing.expect_value(t, g_diagnostics.severity, sciter.Output_Severity.WARNING)

		thrown := sciter_app.string_from_utf16(
			raw_data(g_diagnostics.last[:]),
			uint(g_diagnostics.last_len),
			context.temp_allocator,
		)
		testing.expect(t, strings.contains(thrown, "from a module"), thrown)
	}

	// The handler is per window when it is given one, and global when it is not - so an application can
	// route one window's diagnostics into that window's own log panel.
	//
	// **Skipped on macOS, and the reason is a measurement.** Every other test in this file runs against a
	// windowless view. This one hands that view's handle to `set_debug_output` as the *window* to scope
	// the handler to, and on Darwin that instantiates an `NSWindow` - which a test thread may not do, so
	// the process aborts rather than the test failing. The same call on the same windowless view is fine
	// on Linux and on Windows. So "the handle a windowless view carries is a window" holds one platform
	// less than it appears to, and `have_display` is what keeps the difference from taking the suite
	// down with it.
	@(test)
	test_a_windowed_handler_hears_only_that_windows_diagnostics :: proc(t: ^testing.T) {
		if !have_display() {
			fmt.println("skipping - scoping a handler to this view's handle needs a real window here")
			return
		}
		window, ok := test_window(t)
		if !ok {return}

		BROKEN :: `<html><head><script type="module">this is not valid (((</script></head><body></body></html>`

		g_diagnostics = {}
		sciter_app.set_debug_output(collect_diagnostic, nil, window)
		defer sciter_app.set_debug_output(nil, nil, window)

		testing.expect_value(t, sciter_app.load_html(window, BROKEN), nil)
		testing.expect(t, g_diagnostics.count > 0, "its own window's error arrives")

		// A second window, with no handler of its own and none installed globally.
		//
		// `init` first, and it is not ceremony: this file's harness is windowless and never calls it, so
		// this is the one test here that stands up the windowed application subsystem. Without it the
		// window still opens and this test still passes - and the *process* faults on the way out, which
		// is what `create_window`'s debug guard now traps. `dom_walk`'s windowed helper does the same.
		context.allocator = runtime.default_allocator()
		sciter_app.init()
		other, oerr := sciter_app.create_window({width = 200, height = 150})
		testing.expect_value(t, oerr, nil)
		if other == nil {return}

		g_diagnostics = {}
		testing.expect_value(t, sciter_app.load_html(other, BROKEN), nil)
		testing.expect_value(t, g_diagnostics.count, 0)
	}

	// Passing nil detaches it. Worth its own assertion because the alternative - a stale handler pointing
	// at memory that has gone - is a crash rather than a missed message.
	@(test)
	test_the_diagnostics_handler_can_be_detached :: proc(t: ^testing.T) {
		window, ok := test_window(t)
		if !ok {return}

		BROKEN :: `<html><head><script type="module">this is not valid (((</script></head><body></body></html>`

		g_diagnostics = {}
		sciter_app.set_debug_output(collect_diagnostic, nil, window)
		testing.expect_value(t, sciter_app.load_html(window, BROKEN), nil)
		testing.expect(t, g_diagnostics.count > 0)

		before := g_diagnostics.count
		sciter_app.set_debug_output(nil, nil, window)

		testing.expect_value(t, sciter_app.load_html(window, BROKEN), nil)
		testing.expect_value(t, g_diagnostics.count, before)
	}

} // when ODIN_OS != .Windows - see the comment above the first of these three

// ---------------------------------------------------------------------------------------------------
// The scoped forms
//
// `scoped_eval` and its siblings are `eval` with the release attached to the scope by
// `@(deferred_out)`. The tests are here rather than beside the wrappers because this is the file
// `just test_sanitize eval` runs under ASan, which is what proves the reference counting.

// The value is live for the whole of the scope it was taken in - the release happens on the way out,
// not at the next statement - so a scoped Value reads exactly like an unscoped one while it is in use.
@(test)
test_a_scoped_value_is_usable_for_the_whole_scope :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	v, err := sciter_app.scoped_eval(window, `"hello " + "world"`)
	testing.expect_value(t, err, nil)

	s, serr := sciter_app.value_to_string(&v, context.temp_allocator)
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, s, "hello world")

	// still live, several statements later
	again, aerr := sciter_app.value_to_string(&v, context.temp_allocator)
	testing.expect_value(t, aerr, nil)
	testing.expect_value(t, again, "hello world")
}

// The whole point: the discarding call form is released too. `@(require_results)` does not reject
// `_, _ =` - measured - so this is the shape that leaked in the examples, and it is the shape the
// deferred release has to cover. Under ASan this test is the assertion.
@(test)
test_a_discarded_scoped_value_is_still_released :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	for _ in 0 ..< 200 {
		_, _ = sciter_app.scoped_eval(window, `"x".repeat(1000)`)
	}
	testing.expect(t, true) // reaching here with nothing leaked is the result
}

// **A failing `eval` does not report `.Eval_Failed`, and its result is not empty.** Measured on
// 6.0.4.9, identically in a window and in a windowless view, for a syntax error, an unhandled `throw`
// and an undefined name alike: the call answers `err = nil` and hands back an *error string* - the same
// `.ERROR`-unit Value `value_parse` uses to report a bad document, carrying the engine's message and a
// stack trace.
//
// Two consequences, and the second is why this test lives in a file about ownership: `value_is_error`
// is the way to detect a failed eval and `value_to_string` on the result is the diagnosis (no debug
// output handler needed, contrary to what this file's header used to say) - and a caller that checks
// only `err` and drops the Value leaks a reference on *every* script error. The scoped form releases it
// either way, which is exactly the path this test covers.
@(test)
test_a_failing_eval_returns_an_error_string_and_is_still_released :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	v, err := sciter_app.scoped_eval(window, `this is not valid (((`)
	testing.expect_value(t, err, nil)
	testing.expect(t, sciter_app.value_is_error(&v))

	message, merr := sciter_app.value_to_string(&v, context.temp_allocator)
	testing.expect_value(t, merr, nil)
	testing.expect(t, strings.contains(message, "expecting"))

	// The same for a thrown exception rather than a parse failure.
	thrown, terr := sciter_app.scoped_eval(window, `throw new Error("boom")`)
	testing.expect_value(t, terr, nil)
	testing.expect(t, sciter_app.value_is_error(&thrown))
	text, xerr := sciter_app.value_to_string(&thrown, context.temp_allocator)
	testing.expect_value(t, xerr, nil)
	testing.expect(t, strings.contains(text, "boom"))
}

// **The same split holds for all three calling procedures, and it is the whole failure model:**
//
//	the error code answers "could I call it?"   - a name nothing defines is a real error
//	the returned Value answers "did it work?"   - a function that ran and threw is an error string
//
// Measured on 6.0.4.9 for `call`, `call_function` and `call_method` alike. The two halves never
// overlap: a thrown exception is `err = nil` with an `.ERROR`-unit result, and a missing name is an
// error code with an `.UNDEFINED` result. Which also settles the ownership question on each path - the
// not-found result holds no reference and is safe to drop, and the *threw* result is a live string that
// leaks if the caller only checks the code.
@(test)
test_a_script_call_reports_a_throw_in_the_value_and_a_missing_name_in_the_error :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	DOC :: `<html><head><script type="module">
	globalThis.ok    = function(){ return 42; }
	globalThis.boom  = function(){ throw new Error("call-boom"); }
	document.$("#d").mboom = function(){ throw new Error("method-boom"); }
	</script></head><body><div id=d>hi</div></body></html>`

	testing.expect_value(t, sciter_app.load_html(window, DOC), nil)
	root, rerr := sciter_app.root(window)
	testing.expect_value(t, rerr, nil)
	d, derr := sciter_app.select_first(root, "#d")
	testing.expect_value(t, derr, nil)

	// A call that works is an ordinary value.
	good, gerr := sciter_app.scoped_call(window, "ok")
	testing.expect_value(t, gerr, nil)
	testing.expect(t, !sciter_app.value_is_error(&good))
	n, nerr := sciter_app.value_to_int(&good)
	testing.expect_value(t, nerr, nil)
	testing.expect_value(t, n, 42)

	// A function that throws: no error code, an error string in hand.
	threw, terr := sciter_app.scoped_call(window, "boom")
	testing.expect_value(t, terr, nil)
	testing.expect(t, sciter_app.value_is_error(&threw))
	msg, merr := sciter_app.value_to_string(&threw, context.temp_allocator)
	testing.expect_value(t, merr, nil)
	testing.expect(t, strings.contains(msg, "call-boom"))

	// `call_function` reaches the same globals from an element, and reports the same way.
	fthrew, ferr := sciter_app.scoped_call_function(d, "boom")
	testing.expect_value(t, ferr, nil)
	testing.expect(t, sciter_app.value_is_error(&fthrew))

	// So does a method on the element's own script object.
	mthrew, mmerr := sciter_app.scoped_call_method(d, "mboom")
	testing.expect_value(t, mmerr, nil)
	testing.expect(t, sciter_app.value_is_error(&mthrew))

	// The other half: a name nothing defines *is* an error, and the result is undefined rather than a
	// message. The codes differ per entry point - `call` goes through SciterCall, which reports a bare
	// false, and the two element forms carry the DOM result through.
	missing, cerr := sciter_app.scoped_call(window, "noSuchFunction")
	testing.expect_value(t, cerr, sciter_app.Error(sciter_app.Api_Error.Call_Failed))
	testing.expect(t, sciter_app.value_is_undefined(&missing))

	_, fmerr := sciter_app.scoped_call_function(d, "noSuchFunction")
	testing.expect_value(t, fmerr, sciter_app.Error(sciter.Scdom_Result.OPERATION_FAILED))

	_, mmiss := sciter_app.scoped_call_method(d, "noSuchMethod")
	testing.expect_value(t, mmiss, sciter_app.Error(sciter.Scdom_Result.OPERATION_FAILED))
}

// `scoped_make_element` gives up the reference the engine handed back, and inserting does not consume
// it - the document takes its own - so the element is still in the tree after the scope ends.
@(test)
test_a_scoped_element_stays_in_the_document_after_insertion :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	testing.expect_value(t, sciter_app.load_html(window, `<html><body><ul id=list></ul></body></html>`), nil)
	root, rerr := sciter_app.root(window)
	testing.expect_value(t, rerr, nil)
	list, lerr := sciter_app.select_first(root, "#list")
	testing.expect_value(t, lerr, nil)

	{
		item, ierr := sciter_app.scoped_make_element("li", "only")
		testing.expect_value(t, ierr, nil)
		testing.expect_value(t, sciter_app.insert_element(sciter_app.borrow_element(item), list), nil)
	} // the caller's reference goes here; the document's does not

	n, nerr := sciter_app.child_count(list)
	testing.expect_value(t, nerr, nil)
	testing.expect_value(t, n, sciter_app.Child_Index(1))

	first, ferr := sciter_app.child(list, 0)
	testing.expect_value(t, ferr, nil)
	text, terr := sciter_app.text(first, context.temp_allocator)
	testing.expect_value(t, terr, nil)
	testing.expect_value(t, text, "only")

	// `scoped_clone_element` owns its copy the same way, and the copy is independent of the original.
	//
	// The write comes *after* the insertion, and it has to: measured, `set_text` on a detached clone is
	// `.PASSIVE_HANDLE` even though the clone carries a reference of its own. Building an element's
	// content before putting it in the document works through `make_element`'s `text` argument and
	// through `set_attribute`, but not through `set_text`.
	{
		copy, cerr := sciter_app.scoped_clone_element(first)
		testing.expect_value(t, cerr, nil)
		borrowed := sciter_app.borrow_element(copy)
		testing.expect_value(t, sciter_app.insert_element(borrowed, list), nil)
		testing.expect_value(t, sciter_app.set_text(borrowed, "second"), nil)
	}

	after, aerr := sciter_app.child_count(list)
	testing.expect_value(t, aerr, nil)
	testing.expect_value(t, after, sciter_app.Child_Index(2))

	original, oerr := sciter_app.child(list, 0)
	testing.expect_value(t, oerr, nil)
	original_text, oterr := sciter_app.text(original, context.temp_allocator)
	testing.expect_value(t, oterr, nil)
	testing.expect_value(t, original_text, "only") // the clone's edit did not reach it
}

// The debug tracker, which is the other half of the ownership story: `scoped_` covers the Value that
// dies with its scope, and this covers the one that does not.
//
// Only meaningful in a debug build - every entry point compiles to nothing otherwise - so the test
// asserts the release-build behaviour too rather than being skipped.
@(test)
test_the_resource_tracker_sees_a_leaked_value_and_a_leaked_element :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	// Restarted rather than turned off on the way out: anything else sharing this ledger - the sweep in
	// `examples/leak_sweep.odin`, or a later test - would otherwise be silently blinded by whichever
	// order the runner happened to pick.
	sciter_app.track_resources(true)
	defer sciter_app.track_resources(true)

	when !ODIN_DEBUG {
		// Compiled out: no map, no branch, nothing to report.
		testing.expect_value(t, sciter_app.report_leaked_resources(), 0)
		return
	}

	before := sciter_app.outstanding_resources()

	// A Value that owns engine memory, dropped on the floor - the shape measured at 195 kB a call.
	leaked, err := sciter_app.eval(window, `"x".repeat(100)`)
	testing.expect_value(t, err, nil)
	_ = leaked

	// And an element reference that is never given back.
	orphan_owned, oerr := sciter_app.make_element("li", "never inserted")
	testing.expect_value(t, oerr, nil)

	during := sciter_app.outstanding_resources()
	testing.expect_value(t, during[.Value] - before[.Value], 1)
	testing.expect_value(t, during[.Element] - before[.Element], 1)

	// A scalar Value owns nothing, so it must *not* be counted - otherwise a real leak drowns in noise.
	scalar := sciter_app.value_from(i32(42))
	after_scalar := sciter_app.outstanding_resources()
	testing.expect_value(t, after_scalar[.Value] - during[.Value], 0)
	sciter_app.value_clear(&scalar)

	// Now settle both, and the ledger comes back to where it started.
	sciter_app.value_clear(&leaked)
	testing.expect_value(t, sciter_app.unuse_element(orphan_owned), nil)

	settled := sciter_app.outstanding_resources()
	testing.expect_value(t, settled[.Value], before[.Value])
	testing.expect_value(t, settled[.Element], before[.Element])
}

// The rest of the scoped producers, exercised once each so that every one of them is on a path the
// test suite runs - the release happens on the way out of this procedure, and under ASan that is the
// assertion. Grouped rather than one test apiece because what is being checked is the wrapper, not the
// underlying call: each of these has its own test elsewhere in this file or in another example.
@(test)
test_every_scoped_value_producer_releases :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	DOC :: `<html><head><script type="module">
	globalThis.tally = 7;
	</script></head><body>
	<input id="field" type="text" value="typed" />
	<div id="d">hi</div>
	</body></html>`

	testing.expect_value(t, sciter_app.load_html(window, DOC), nil)
	root, rerr := sciter_app.root(window)
	testing.expect_value(t, rerr, nil)
	field, ferr := sciter_app.select_first(root, "#field")
	testing.expect_value(t, ferr, nil)
	d, derr := sciter_app.select_first(root, "#d")
	testing.expect_value(t, derr, nil)

	// A container built by parsing, then read two levels down - three producers, one expression each.
	doc, perr := sciter_app.scoped_value_parse(`{"rows":[10,20]}`)
	testing.expect_value(t, perr, nil)
	rows, gerr := sciter_app.scoped_value_get(&doc, "rows")
	testing.expect_value(t, gerr, nil)
	first, aerr := sciter_app.scoped_value_at(&rows, 0)
	testing.expect_value(t, aerr, nil)
	n, nerr := sciter_app.value_to_i64(&first)
	testing.expect_value(t, nerr, nil)
	testing.expect_value(t, n, i64(10))

	// A global the document defined.
	tally, terr := sciter_app.scoped_global(window, "tally")
	testing.expect_value(t, terr, nil)
	tally_n, tnerr := sciter_app.value_to_i64(&tally)
	testing.expect_value(t, tnerr, nil)
	testing.expect_value(t, tally_n, i64(7))

	// An <input>'s value, which is `SciterGetValue` rather than the behavior's GET_VALUE.
	typed, verr := sciter_app.scoped_element_value(field)
	testing.expect_value(t, verr, nil)
	typed_s, tserr := sciter_app.value_to_string(&typed, context.temp_allocator)
	testing.expect_value(t, tserr, nil)
	testing.expect_value(t, typed_s, "typed")

	// The element's script object, and a script evaluated against it.
	expando, xerr := sciter_app.scoped_expando(d)
	testing.expect_value(t, xerr, nil)
	testing.expect(t, !sciter_app.value_is_undefined(&expando))

	tag, eerr := sciter_app.scoped_eval_element(d, `this.tag`)
	testing.expect_value(t, eerr, nil)
	tag_s, tagerr := sciter_app.value_to_string(&tag, context.temp_allocator)
	testing.expect_value(t, tagerr, nil)
	testing.expect_value(t, tag_s, "div")

	// `behavior_value` asks the *behavior*, and no intrinsic behavior implements GET_VALUE on Sciter 6 -
	// so `handled` is false and the Value is undefined. The scoped form still has to release it.
	_, handled, berr := sciter_app.scoped_behavior_value(field)
	testing.expect_value(t, berr, nil)
	testing.expect_value(t, handled, false)
}

// ---------------------------------------------------------------------------------------------------
// Value_Scope: a batch of references with one lifetime
//
// `scoped_eval` covers the Value that dies at the end of the scope it was taken in. It cannot cover a
// pile produced in a loop - `@(deferred_out)` releases at the end of the *calling* scope, which for a
// loop body is one iteration. That is what a scope is for, and the tracker is what proves it works.
@(test)
test_a_value_scope_releases_the_whole_batch :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	DOC :: `<html><head><script type="module">
	globalThis.getRows = function(){ return [{name:"a"},{name:"b"},{name:"c"}]; }
	</script></head><body></body></html>`
	testing.expect_value(t, sciter_app.load_html(window, DOC), nil)

	sciter_app.track_resources(true)
	defer sciter_app.track_resources(true)
	before := sciter_app.outstanding_resources()

	scope: sciter_app.Value_Scope
	names: [dynamic]string
	defer delete(names)

	{
		rows, rerr := sciter_app.scope_add(&scope, sciter_app.call(window, "getRows"))
		testing.expect_value(t, rerr, nil)

		n, nerr := sciter_app.value_len(&rows)
		testing.expect_value(t, nerr, nil)
		testing.expect_value(t, n, 3)

		for i in 0 ..< n {
			row, err := sciter_app.scope_add(&scope, sciter_app.value_at(&rows, i))
			testing.expect_value(t, err, nil)
			name, gerr := sciter_app.scope_add(&scope, sciter_app.value_get(&row, "name"))
			testing.expect_value(t, gerr, nil)
			s, serr := sciter_app.value_to_string(&name, context.temp_allocator)
			testing.expect_value(t, serr, nil)
			append(&names, s)
		}
	}

	testing.expect_value(t, len(names), 3)
	testing.expect_value(t, names[0], "a")
	testing.expect_value(t, names[2], "c")

	// Seven references are outstanding at this point: the array, and a row plus a name for each of three
	// rows. Nothing has been cleared by hand.
	when ODIN_DEBUG {
		during := sciter_app.outstanding_resources()
		testing.expect_value(t, sciter_app.scope_len(&scope), 7)
		testing.expect(t, during[.Value] > before[.Value], "the batch should be outstanding before release")
	}

	sciter_app.scope_destroy(&scope)

	after := sciter_app.outstanding_resources()
	testing.expect_value(t, after[.Value], before[.Value])
	testing.expect_value(t, sciter_app.scope_len(&scope), 0)
}

// The visitor half of what a borrowed Value is - the functor half is in `call_odin_from_js.odin` and
// the one that really is a use-after-free is in `behavior.odin`.
//
// **A visitor's key and value point into the container the caller still owns, and clearing one empties
// that slot.** Measured on 6.0.4.9: no crash, no error, no complaint from the engine - the array keeps
// its length and every element it visited is left `.UNDEFINED`. That is worse than a crash in the way that
// matters for finding it: nothing at all reports the loss, and the array is still a valid array.
//
// So the rule is right and its reason is not "the process dies". `value_copy` anything a visitor needs
// to keep; never clear what it is handed.
@(private = "file")
clear_each_element :: proc(key, value: ^sciter_app.Value, user: rawptr) -> bool {
	cleared := (^int)(user)
	cleared^ += 1
	sciter_app.value_clear(value)
	return true
}

@(test)
test_clearing_a_visited_value_empties_the_container_the_caller_still_owns :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	array, perr := sciter_app.value_parse(`["alpha","beta","gamma"]`)
	testing.expect_value(t, perr, nil)
	defer sciter_app.value_clear(&array)

	cleared := 0
	testing.expect_value(t, sciter_app.value_each(&array, clear_each_element, &cleared), nil)
	testing.expect_value(t, cleared, 3)

	// Still an array, still three long - and empty all the way across.
	n, lerr := sciter_app.value_len(&array)
	testing.expect_value(t, lerr, nil)
	testing.expect_value(t, n, 3)

	for i in 0 ..< n {
		element, eerr := sciter_app.value_at(&array, i)
		testing.expect_value(t, eerr, nil)
		defer sciter_app.value_clear(&element)

		kind, _ := sciter_app.value_type(&element)
		testing.expectf(t, kind == .UNDEFINED, "element %d should have been emptied, is %v", i, kind)

		// And it does not even read as a string any more, which is how this shows up in real code: a
		// container that still has the right shape and answers `.INCOMPATIBLE_TYPE` for its contents.
		_, terr := sciter_app.value_to_string(&element, context.temp_allocator)
		testing.expect_value(t, terr, sciter_app.Error(sciter.Value_Result.INCOMPATIBLE_TYPE))
	}
}

// **`value_to_bytes` borrows the engine's buffer**, so what it hands back is a window into the Value
// rather than a copy - which is worth a test because the difference is invisible until the Value goes
// away, and then it is invisible for a while longer.
//
// What is asserted here is the safe half: the slice is the engine's memory rather than the caller's,
// the length is exact, and a copy taken while the Value is alive is a copy. The unsafe half was
// measured with a throwaway probe instead of a test, deliberately - `just test_sanitize eval` runs this
// file under ASan, and a test that reads the buffer after the Value is cleared is a use-after-free that
// the sanitizer is there to catch. What the probe found:
//
//   - after `value_clear`, the slice reads correctly at first and turns into whatever the allocator
//     handed out next after ~1.6 MB of churn. The obvious check ("read it right after") says it is fine.
//   - after `value_copy` writes a different value over the same Value, the buffer is corrupted
//     immediately - the first bytes were already overwritten with allocator bookkeeping.
//
// So the doc comment's "only valid until the Value changes or is cleared" is exactly right, and both
// halves of it fail quietly.
@(test)
test_value_to_bytes_borrows_the_engines_buffer_rather_than_copying :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	payload := make([]u8, 4096, context.temp_allocator)
	for &b, i in payload {b = u8('A' + i % 26)}

	v := sciter_app.value_from_bytes(payload)
	defer sciter_app.value_clear(&v)

	borrowed, err := sciter_app.value_to_bytes(&v)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(borrowed), len(payload))

	// Not the caller's buffer: the engine copied it in, and this is a view of *its* copy.
	testing.expect(
		t,
		raw_data(borrowed) != raw_data(payload),
		"the engine holds its own copy; this slice is a view of that",
	)
	testing.expect_value(t, borrowed[0], u8('A'))
	testing.expect_value(t, borrowed[25], u8('Z'))

	// Asked twice, the same buffer comes back - nothing is allocated per call, which is the other way
	// of saying there is nothing here to free.
	second, serr := sciter_app.value_to_bytes(&v)
	testing.expect_value(t, serr, nil)
	testing.expect(t, raw_data(second) == raw_data(borrowed), "no allocation per call, so nothing owed")

	// The way to keep them: copy while the Value is alive.
	kept := make([]u8, len(borrowed), context.temp_allocator)
	copy(kept, borrowed)
	testing.expect(t, slice.equal(kept, payload), "a copy taken in time is a real copy")
}

// **The `scoped_` family covers the constructors too, and they leak in the more innocent shape.**
// `value_from_string` reads like a conversion, not like an acquisition - but the Value it hands back
// owns a reference to an engine allocation, and every call that passes one to the engine (`set_global`,
// `set_element_value`, an argument to `call`) *copies* it, so the caller's reference is still the
// caller's afterwards.
//
// The tracker is the assertion here: four constructors inside a scope, nothing cleared by hand, and the
// outstanding count back where it started at the end.
@(test)
test_the_scoped_constructors_give_back_what_they_took :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	// The ledger is shared, so it is restarted rather than turned off - see the note on the tracking
	// test above.
	sciter_app.track_resources(true)
	defer sciter_app.track_resources(true)

	before := sciter_app.outstanding_resources()

	{
		text := sciter_app.scoped_value_from_string("hello")
		s, serr := sciter_app.value_to_string(&text, context.temp_allocator)
		testing.expect_value(t, serr, nil)
		testing.expect_value(t, s, "hello")

		payload := []u8{1, 2, 3, 4}
		bytes := sciter_app.scoped_value_from_bytes(payload)
		back, berr := sciter_app.value_to_bytes(&bytes)
		testing.expect_value(t, berr, nil)
		testing.expect_value(t, len(back), 4)

		array := sciter_app.scoped_value_make_array(2)
		n, lerr := sciter_app.value_len(&array)
		testing.expect_value(t, lerr, nil)
		testing.expect_value(t, n, 2)

		// Writing into the array copies, so the element's own reference is given back by *its* scope and
		// the array still holds a live element afterwards.
		testing.expect_value(t, sciter_app.value_set_at(&array, 0, &text), nil)

		fn := sciter_app.scoped_value_from_function(proc(args: []sciter_app.Value, user: rawptr) -> sciter_app.Value {
				return sciter_app.value_from_int(1)
			}, nil, runtime.default_allocator())
		// A native functor reports `.RESOURCE`, not `.FUNCTION` - measured; `.FUNCTION` is a script
		// function. Either way it owns a reference, which is what this test is about.
		kind, _ := sciter_app.value_type(&fn)
		testing.expect_value(t, kind, sciter.Value_Type.RESOURCE)

		when ODIN_DEBUG {
			during := sciter_app.outstanding_resources()
			testing.expect(t, during[.Value] > before[.Value], "four references are held inside the scope")
		}
	}

	// Every one of them released at the closing brace, with nothing written to do it.
	after := sciter_app.outstanding_resources()
	testing.expect_value(t, after[.Value], before[.Value])
}
