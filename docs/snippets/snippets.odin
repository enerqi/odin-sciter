// Every Odin code block in docs/*.md, wrapped just enough to compile.
//
//	odin check docs/snippets -no-entry-point       # or: just check
//
// Documentation drifts silently, and a guide that does not compile is worse than no guide. Each proc
// below is one code block from one guide, copied verbatim apart from the enclosing proc, stub
// declarations for things the surrounding prose supplies (`window`, `el`, `App`), and `_ =` on results
// the block does not use. When a snippet changes here, change it there, and vice versa.
//
// This already earned its keep: four listings redeclared `err` in one scope, which Odin rejects and a
// reader pasting the block would have hit immediately.
package docs_snippets

import sciter "../.."
import "../../sciter_app"
import "base:runtime"
import "core:fmt"

// ---------------------------------------------------------------------------------------------------
// getting-started.md, block 1

gs1 :: proc() {
	if !sciter_app.load_engine() {return}
	sciter_app.init()
	sciter_app.set_default_debug_output()

	window, err := sciter_app.create_window({width = 720, height = 480})
	if err != nil {return}

	sciter_app.load_html(window, "<html><body><h1>Hello from Odin</h1></body></html>")
	sciter_app.show(window)

	sciter_app.run()
	sciter_app.shutdown()
}

// ---------------------------------------------------------------------------------------------------
// architecture.md, block 1

arch1 :: proc() {
	frame: sciter.Tag_Rect
	argv: uintptr

	api := sciter.api()
	api.SciterExec(.INIT, 1, argv)
	api.SciterCreateWindow({.MAIN, .ENABLE_DEBUG}, &frame, nil, nil, nil)
}

// ---------------------------------------------------------------------------------------------------
// html-css-js.md, block 1

hcj1 :: proc() {
	sciter_app.set_script_features({.FILE_IO, .SOCKET_IO, .EVAL, .SYSINFO})
}

// ---------------------------------------------------------------------------------------------------
// calling-between-odin-and-js.md

cbj1 :: proc(window: sciter_app.Window) {
	result, err := sciter_app.eval(window, "1 + 1")
	if err != nil {return}
	defer sciter_app.value_clear(&result)

	n, _ := sciter_app.value_to_int(&result)
	_ = n
}

cbj2 :: proc() {
	b := sciter_app.value_from(true)
	i := sciter_app.value_from(i32(42))
	n := sciter_app.value_from(3.5)
	s := sciter_app.value_from("hello")
	d := sciter_app.value_from([]u8{1, 2, 3})
	a := sciter_app.value_make_array(3)
	_, _, _, _, _, _ = b, i, n, s, d, a
}

cbj3 :: proc(v: ^sciter_app.Value) {
	b, err := sciter_app.value_to_bool(v)
	i, _ := sciter_app.value_to_int(v)
	f, _ := sciter_app.value_to_f64(v)
	s, _ := sciter_app.value_to_string(v)
	p, _ := sciter_app.value_to_bytes(v)
	_, _, _, _, _, _ = b, i, f, s, p, err
}

cbj4 :: proc(v: ^sciter_app.Value) {
	text, _ := sciter_app.value_to_display_string(v, .JSON_LITERAL)
	defer delete(text)
}

cbj5 :: proc() {
	arr := sciter_app.value_make_array(0)
	defer sciter_app.value_clear(&arr)

	item := sciter_app.value_from("first")
	defer sciter_app.value_clear(&item)
	sciter_app.value_set_at(&arr, 0, &item)

	n, _ := sciter_app.value_len(&arr)
	for i in 0 ..< n {
		e, _ := sciter_app.value_at(&arr, i)
		defer sciter_app.value_clear(&e)
	}
}

cbj6 :: proc() {
	obj: sciter_app.Value
	defer sciter_app.value_clear(&obj)

	count := sciter_app.value_from(i32(3))
	defer sciter_app.value_clear(&count)
	sciter_app.value_set(&obj, "count", &count)
}

cbj7 :: proc(window: sciter_app.Window) {
	v, err := sciter_app.eval(window, "document.$('#count').innerText")
	defer sciter_app.value_clear(&v)
	_ = err
}

cbj8 :: proc(window: sciter_app.Window) {
	arg := sciter_app.value_from("world")
	defer sciter_app.value_clear(&arg)

	result, err := sciter_app.call(window, "greet", arg)
	defer sciter_app.value_clear(&result)
	_ = err
}

App :: struct {
	calls: int,
}

reverse :: proc(s: string) -> string {return s}

odin_reverse :: proc(args: []sciter_app.Value, user_data: rawptr) -> sciter_app.Value {
	app := (^App)(user_data)
	app.calls += 1

	if len(args) < 1 {
		return sciter_app.value_from("expected one argument")
	}
	s, err := sciter_app.value_to_string(&args[0], context.temp_allocator)
	if err != nil {
		return sciter_app.value_from("not a string")
	}
	return sciter_app.value_from(reverse(s))
}

cbj10 :: proc(window: sciter_app.Window) {
	app := App{}

	fn := sciter_app.value_from_function(odin_reverse, &app)
	defer sciter_app.value_clear(&fn)
	sciter_app.set_global(window, "odin_reverse", &fn)
}

cbj11 :: proc(args: []sciter_app.Value) -> sciter_app.Value {
	cb := args[0]
	if !sciter_app.value_is_function(&cb) {return {}}

	arg := sciter_app.value_from(i32(1))
	defer sciter_app.value_clear(&arg)

	r, err := sciter_app.value_invoke(&cb, nil, {arg})
	defer sciter_app.value_clear(&r)
	_ = err
	return {}
}

// ---------------------------------------------------------------------------------------------------
// dom.md

dom1 :: proc(el: sciter_app.Element) {
	sciter_app.use_element(el)
	defer sciter_app.unuse_element(el)
}

dom2 :: proc(window: sciter_app.Window) {
	root, err := sciter_app.root(window)
	_, _ = root, err
}

dom3 :: proc(root: sciter_app.Element) {
	button, err := sciter_app.select_first(root, "button#ok")
	if err != nil {return}
	_ = button
}

dom3b :: proc(root: sciter_app.Element) {
	items, err := sciter_app.select_all(root, "li.item")
	if err != nil {return}
	defer delete(items)

	for item in items {
		text, _ := sciter_app.text(item)
		defer delete(text)
		fmt.println(text)
	}
}

dom4 :: proc(el: sciter_app.Element) {
	n, _ := sciter_app.child_count(el)
	first, _ := sciter_app.child(el, 0)
	up, err := sciter_app.parent(el)
	name, _ := sciter_app.tag(el)
	_, _, _, _, _ = n, first, up, err, name
}

dom5 :: proc(el: sciter_app.Element) {
	t, err := sciter_app.text(el)
	defer delete(t)
	sciter_app.set_text(el, "42")

	h, _ := sciter_app.html(el, outer = true)
	defer delete(h)
	sciter_app.set_html(el, "<b>bold</b>")

	v, _ := sciter_app.attribute(el, "href")
	defer delete(v)
	sciter_app.set_attribute(el, "href", "https://…")
	sciter_app.set_attribute(el, "href", "")
	_ = err
}

dom6 :: proc(el: sciter_app.Element) {
	state, _ := sciter_app.element_state(el)
	if .HOVER in state {
	}

	sciter_app.set_element_state(el, set = {.DISABLED}, clear = {.ACTIVE})
}

dom7 :: proc(input: sciter_app.Element) {
	v, err := sciter_app.element_value(input)
	defer sciter_app.value_clear(&v)
	text, _ := sciter_app.value_to_string(&v)

	nv := sciter_app.value_from("new text")
	defer sciter_app.value_clear(&nv)
	sciter_app.set_element_value(input, &nv)
	_, _ = err, text
}

dom8 :: proc(el: sciter_app.Element, a, b: sciter_app.Value) {
	r, err := sciter_app.eval_element(el, "this.innerText")
	defer sciter_app.value_clear(&r)

	r2, _ := sciter_app.call_method(el, "edit.setRange", a, b)
	defer sciter_app.value_clear(&r2)
	_ = err
}

dom9 :: proc(window: sciter_app.Window) {
	v, _ := sciter_app.eval(window, "JSON.stringify(document.form.value)")
	_ = v
}

Sink :: struct {
	ctx: runtime.Context,
	out: string,
}

my_receiver :: proc "system" (str: [^]u16, str_length: u32, param: rawptr) {
	sink := (^Sink)(param)
	context = sink.ctx
	sink.out = sciter_app.string_from_utf16(str, uint(str_length))
}

// ---------------------------------------------------------------------------------------------------
// events.md

Counter :: struct {
	handler: sciter_app.Event_Handler,
	count:   int,
}

on_event :: proc(handler: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	counter := (^Counter)(handler.user_data)

	be, ok := sciter_app.behavior_event(event)
	if !ok || be.code != .BUTTON_CLICK || be.phase != .Bubbling {
		return false
	}

	counter.count += 1
	return true
}

ev1 :: proc(window: sciter_app.Window) {
	counter := Counter {
		handler = {subscription = {.BEHAVIOR_EVENT}, on_event = on_event},
	}
	counter.handler.user_data = &counter

	root, _ := sciter_app.root(window)
	sciter_app.attach_handler(root, &counter.handler)
}

ev2 :: proc(h: ^sciter_app.Event_Handler) {
	h.subscription = {.BEHAVIOR_EVENT}
	h.subscription = {.MOUSE, .KEY, .FOCUS}
	h.subscription = sciter.HANDLE_ALL
}

ev3 :: proc(event: sciter_app.Event) {
	if be, ok := sciter_app.behavior_event(event); ok {
		_, _, _, _, _ = be.code, be.target, be.source, be.reason, be.data
		_ = be.raw
	}

	if me, ok := sciter_app.mouse_event(event); ok {
		_, _, _ = me.code, me.pos, me.buttons
	}

	if ke, ok := sciter_app.key_event(event); ok {
		_, _, _ = ke.code, ke.key_code, ke.modifiers
	}
}

ev4 :: proc(el: sciter_app.Element, window: sciter_app.Window, handler: ^sciter_app.Event_Handler) {
	sciter_app.detach_handler(el, handler)
	sciter_app.detach_window_handler(window, handler)
}

ev5a :: proc(el: sciter_app.Element) {
	handled, err := sciter_app.send_event(el, .BUTTON_CLICK)
	_, _ = handled, err
}

ev5b :: proc(el: sciter_app.Element) {
	err := sciter_app.post_event(el, .BUTTON_CLICK)
	_ = err
}

ev6 :: proc(window: sciter_app.Window) {
	sciter_app.eval(window, "document.$('#ok').click()")
}

// ---------------------------------------------------------------------------------------------------
// resources.md

Res_App :: struct {
	files:   map[string][]u8,
	archive: sciter_app.Archive,
}

res_on_load_data :: proc(
	handler: ^sciter_app.Host_Handler,
	request: ^sciter_app.Load_Request,
) -> sciter_app.Load_Result {
	app := (^Res_App)(handler.user_data)

	if data, found := app.files[request.uri]; found {
		return sciter_app.serve(request, data)
	}
	return .OK
}

res1 :: proc(window: sciter_app.Window, app: ^Res_App) {
	INDEX :: "<html></html>"

	handler := sciter_app.Host_Handler {
		on_load_data = res_on_load_data,
		user_data    = app,
	}
	sciter_app.set_host_handler(window, &handler)
	sciter_app.load_html(window, INDEX, "res://app/")
}

RESOURCES :: #load("../../examples/assets/app.pak")

res3 :: proc() {
	archive, err := sciter_app.open_archive(RESOURCES)
	defer sciter_app.close_archive(archive)

	data, found := sciter_app.archive_item(archive, "index.htm")
	_, _, _ = err, data, found
}

res4_on_load_data :: proc(
	h: ^sciter_app.Host_Handler,
	r: ^sciter_app.Load_Request,
) -> sciter_app.Load_Result {
	app := (^Res_App)(h.user_data)
	if result, handled := sciter_app.serve_archive(r, app.archive); handled {
		return result
	}
	return .OK
}

res5 :: proc(window: sciter_app.Window) {
	sciter_app.load_file(window, "this://app/index.htm")
}

// The real snippet is `#load("../lib/linux/x64/libsciter.so")`; embedding 25 MB into this check is
// pointless, so only the call shape is verified.
res6 :: proc(engine: []u8) {
	path, err := sciter_app.load_embedded(engine)
	_, _ = path, err
}

// ---------------------------------------------------------------------------------------------------
// deployment.md

dep1 :: proc() {
	sciter_app.load_engine("/usr/lib/myapp/libsciter.so")
}

// ---------------------------------------------------------------------------------------------------
// api.md, block 2

do_thing :: proc(window: sciter_app.Window) -> sciter_app.Error {
	root := sciter_app.root(window) or_return
	el := sciter_app.select_first(root, "#count") or_return
	return sciter_app.set_text(el, "0")
}

api6 :: proc() {
	frame: sciter.Tag_Rect

	api := sciter.api()
	api.SciterSetOption(nil, .SET_DEBUG_MODE, 1)
	api.SciterCreateWindow({.MAIN, .ENABLE_DEBUG}, &frame, nil, nil, nil)
}
