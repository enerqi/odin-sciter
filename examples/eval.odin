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
