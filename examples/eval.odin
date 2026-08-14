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
import "core:strings"
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

	for entry in ([?]struct {
			name:  string,
			value: ^sciter_app.Value,
		}{{"undefined", &undefined}, {"float", &f}, {"bool", &b}, {"array", &array}, {"map", &map_value}, {"bytes", &bytes}}) {
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
	whole, werr := sciter_app.value_parse(`{"a":1}`, .JSON_MAP)
	defer sciter_app.value_clear(&whole)
	testing.expect_value(t, werr, sciter_app.Error(sciter_app.Api_Error.Parse_Failed))
}

@(private = "file")
Walk :: struct {
	keys:       [dynamic]string,
	values:     [dynamic]i32,
	stop_after: int,
}

@(private = "file")
collect :: proc(key: ^sciter_app.Value, value: ^sciter_app.Value, user_data: rawptr) -> bool {
	walk := (^Walk)(user_data)

	// `value_to_string` allocates, so the key is the walk's own copy rather than a borrow of the
	// engine's storage - which is what makes it safe to keep past the callback.
	if k, err := sciter_app.value_to_string(key, context.temp_allocator); err == nil {
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

	walk := Walk {
		keys   = make([dynamic]string, context.temp_allocator),
		values = make([dynamic]i32, context.temp_allocator),
	}
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

	over_array := Walk {
		keys   = make([dynamic]string, context.temp_allocator),
		values = make([dynamic]i32, context.temp_allocator),
	}
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
		keys       = make([dynamic]string, context.temp_allocator),
		values     = make([dynamic]i32, context.temp_allocator),
		stop_after = 2,
	}
	testing.expect_value(t, sciter_app.value_each(&array, collect, &early), nil)
	testing.expect_value(t, len(early.values), 2)

	// Something that is not a container is a failure, not an empty walk.
	scalar := sciter_app.value_from(i32(9))
	defer sciter_app.value_clear(&scalar)

	untouched := Walk {
		keys   = make([dynamic]string, context.temp_allocator),
		values = make([dynamic]i32, context.temp_allocator),
	}
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

// The only tests in this file that need a window: a diagnostic has to come from somewhere, and script
// only runs in a document. One window for the suite, never shown - see `dom_walk` for why.
@(private = "file")
// Shared by every test in this file, and created on first use. That is deliberate - a window per test
// would be slow, and closing one is itself hazardous (see `close` in sciter_app/window.odin) - but it
// makes the tests here order-coupled: **a test that changes the document must put it back**, usually by
// reloading `DOC`, or it breaks a later test and the failure points at the wrong one.
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
	// The engine keeps the window for the life of the process.
	context.allocator = runtime.default_allocator()

	if g_window == nil {
		sciter_app.init()
		w, err := sciter_app.create_window({width = 300, height = 200})
		testing.expect_value(t, err, nil)
		if w == nil {return nil, false}
		g_window = w
	}
	testing.expect_value(t, sciter_app.load_html(g_window, `<html><body><p>x</p></body></html>`), nil)
	return g_window, true
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
@(test)
test_a_windowed_handler_hears_only_that_windows_diagnostics :: proc(t: ^testing.T) {
	window, ok := test_window(t)
	if !ok {return}

	BROKEN :: `<html><head><script type="module">this is not valid (((</script></head><body></body></html>`

	g_diagnostics = {}
	sciter_app.set_debug_output(collect_diagnostic, nil, window)
	defer sciter_app.set_debug_output(nil, nil, window)

	testing.expect_value(t, sciter_app.load_html(window, BROKEN), nil)
	testing.expect(t, g_diagnostics.count > 0, "its own window's error arrives")

	// A second window, with no handler of its own and none installed globally.
	context.allocator = runtime.default_allocator()
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
		testing.expect_value(t, sciter_app.insert_element(item, list), nil)
	} // the caller's reference goes here; the document's does not

	n, nerr := sciter_app.child_count(list)
	testing.expect_value(t, nerr, nil)
	testing.expect_value(t, n, sciter_app.Child_Index(1))

	first, ferr := sciter_app.child(list, 0)
	testing.expect_value(t, ferr, nil)
	text, terr := sciter_app.text(first, context.temp_allocator)
	testing.expect_value(t, terr, nil)
	testing.expect_value(t, text, "only")
}
