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
import "core:math"
import vmem "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:time"

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

// getting-started.md's second block is the temp-allocator boundary, which is the same listing rules.md
// carries - `pump_with_a_boundary_block` below is that block, compiled once for both.

// ---------------------------------------------------------------------------------------------------
// using-in-your-project.md, the external-project main
//
// The body only. That page's block imports through a *collection* - `import sa "sciter:sciter_app"` -
// which is the one line that cannot be reproduced here, since this file is inside the repository and
// imports by relative path. The calls are what this checks; the import spelling is measured on the page
// itself, against a project built outside the tree.

use_in_your_project :: proc() {
	if !sciter_app.load_engine() {return}
	sciter_app.init()
	sciter_app.set_default_debug_output()

	window, err := sciter_app.create_window({width = 400, height = 300})
	if err != nil {
		fmt.eprintln("no window:", err)
		return
	}
	sciter_app.load_html(window, "<html><body><h1>external project</h1></body></html>")
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

hcj2 :: proc(window: sciter_app.Window) {
	sciter_app.set_media_type(window, "print") // before loading the document that needs it
}

hcj3 :: proc(window: sciter_app.Window) {
	vars: sciter_app.Value
	defer sciter_app.value_clear(&vars)
	on := sciter_app.value_from(true)
	defer sciter_app.value_clear(&on)
	sciter_app.value_set(&vars, "dark", &on)
	sciter_app.set_media_vars(window, &vars)
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

// The `root` the "passing elements" blocks reach for is the document root the surrounding prose has
// already fetched.
@(private = "file")
g_root: sciter_app.Element

cbj12 :: proc(obj: ^sciter_app.Value) {
	sciter_app.value_each(
		obj,
		proc(k, v: ^sciter_app.Value, _: rawptr) -> bool {
			name, _ := sciter_app.value_to_string(k, context.temp_allocator)
			fmt.println(name)
			return true // false stops the walk
		},
	)
}

@(private = "file")
Backend :: struct {
	count:   i32,
	reloads: int,
}

cbj_get_count :: proc(asset: ^sciter_app.Asset) -> (sciter_app.Value, bool) {
	state := (^Backend)(asset.user_data)
	return sciter_app.value_from(state.count), true // the engine takes the reference
}

cbj_set_count :: proc(asset: ^sciter_app.Asset, value: ^sciter_app.Value) -> bool {
	state := (^Backend)(asset.user_data)
	n, err := sciter_app.value_to_int(value) // borrowed for the call
	if err != nil {return false}
	state.count = n
	return true
}

cbj_reload :: proc(asset: ^sciter_app.Asset, args: []sciter_app.Value) -> (sciter_app.Value, bool) {
	state := (^Backend)(asset.user_data)
	state.reloads += 1
	return sciter_app.value_from(i32(state.reloads)), true
}

cbj_som :: proc(window: sciter_app.Window, state: ^Backend, DOC: string) {
	class, cerr := sciter_app.make_asset_class(
		"Backend",
		{{name = "count", get = cbj_get_count, set = cbj_set_count}},
		{{name = "reload", params = 0, call = cbj_reload}},
	)
	asset := sciter_app.make_asset(class, state)
	sciter_app.set_global_asset(asset)
	sciter_app.load_html(window, DOC) // the asset appears in *this* document, not the last one
	_ = cerr
}

cbj_global :: proc(window: sciter_app.Window) {
	v, err := sciter_app.global(window, "some_setting")
	defer sciter_app.value_clear(&v)
	if sciter_app.value_is_undefined(&v) {}
	_ = err
}

cbj13 :: proc() {
	v, err := sciter_app.value_parse(`{"name":"sciter","tags":[1,2,3]}`) // a MAP holding an ARRAY
	defer sciter_app.value_clear(&v)
	_ = err
}

odin_took :: proc(args: []sciter_app.Value, user_data: rawptr) -> sciter_app.Value {
	el, err := sciter_app.element_from_value(&args[0]) // script called odin_took(document.$("#row"))
	if err != nil { 	// .OPERATION_FAILED: not an element
		return sciter_app.value_from(false)
	}
	sciter_app.set_style(el, "color", "red")
	return sciter_app.value_from(true)
}

odin_gave :: proc(args: []sciter_app.Value, user_data: rawptr) -> sciter_app.Value {
	el, _ := sciter_app.select_first(g_root, "#tasks")
	v, err := sciter_app.element_to_value(el)
	if err != nil {return sciter_app.value_from(false)}
	return v // script gets a real Element
}

// ---------------------------------------------------------------------------------------------------
// dom.md

dom1 :: proc(el: sciter_app.Element) {
	held, _ := sciter_app.use_element(el)
	defer sciter_app.unuse_element(held)
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

dom9b :: proc(list: sciter_app.Element) {
	item, _ := sciter_app.make_element("li", "third")
	defer sciter_app.unuse_element(item)
	el := sciter_app.borrow_element(item)
	sciter_app.insert_element(el, list)
}

dom9c :: proc(el, parent, other_parent, a, b, list: sciter_app.Element) {
	sciter_app.insert_element(el, parent, 0)
	sciter_app.insert_element(el, other_parent)
	sciter_app.swap_elements(a, b)
	sciter_app.remove_element(el)
	sciter_app.remove_element(el, finalize = false)
	sciter_app.sort_children(list, by_length)
}

by_length :: proc(a, b: sciter_app.Element, user_data: rawptr) -> int {
	first, _ := sciter_app.text(a, context.temp_allocator)
	second, _ := sciter_app.text(b, context.temp_allocator)
	return len(first) - len(second)
}

dom10 :: proc(el: sciter_app.Element) {
	box, _ := sciter_app.location(el)
	size, _ := sciter_app.location(el, .Border, .Self)
	onscreen, _ := sciter_app.location(el, .Border, .View)
	_, _, _ = box, size, onscreen
}

dom11 :: proc(el: sciter_app.Element) {
	shown, _ := sciter_app.visible(el)
	on, _ := sciter_app.enabled(el)
	_, _ = shown, on
}

dom12 :: proc(el: sciter_app.Element) {
	min, max, _ := sciter_app.intrinsic_widths(el)
	tall, _ := sciter_app.intrinsic_height(el, min)
	_, _ = max, tall
}

dom13 :: proc(el, child: sciter_app.Element) {
	info, _ := sciter_app.scroll_info(el)

	sciter_app.set_scroll_pos(el, {0, info.content.y})
	sciter_app.scroll_to_view(child, to_top = true)
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

dom_attrs :: proc(el: sciter_app.Element) {
	attrs, err := sciter_app.attributes(el, context.temp_allocator) // markup order
	defer sciter_app.delete_attributes(attrs, context.temp_allocator)
	for a in attrs {
		fmt.printfln("%s = %q", a.name, a.value)
	}
	_ = err
}

dom_style :: proc(el: sciter_app.Element) {
	c, _ := sciter_app.style(el, "color", context.temp_allocator) // "#A6E3A1" - the used value
	sciter_app.set_style(el, "color", "blue") // inline, beats the stylesheet
	sciter_app.set_style(el, "color", "") // removes it again
	_ = c
}

dom_element_value :: proc(el: sciter_app.Element) {
	v, err := sciter_app.element_to_value(el) // script sees a real Element
	defer sciter_app.value_clear(&v)

	back, _ := sciter_app.element_from_value(&v) // and out again
	_, _ = back, err
}

on_pick :: proc(args: []sciter_app.Value, user_data: rawptr) -> sciter_app.Value {
	el, err := sciter_app.element_from_value(&args[0])
	if err != nil { 	// a number, a string, a text node
		return sciter_app.value_from(false)
	}
	id, _ := sciter_app.attribute(el, "id", context.temp_allocator)
	_ = id
	return sciter_app.value_from(true)
}

dom_closest :: proc(clicked: sciter_app.Element) {
	row, err := sciter_app.select_parent(clicked, "tr") // script's closest()
	_, _ = row, err
}

dom_traverse2 :: proc(el: sciter_app.Element) {
	n, _ := sciter_app.child_count(el)
	first, _ := sciter_app.child(el, 0)
	up, err := sciter_app.parent(el) // .Not_Found at the root
	name, _ := sciter_app.tag(el) // "div", "button" - borrowed, valid for the element's life
	i, _ := sciter_app.element_index(el) // position among the parent's elements
	_, _, _, _, _, _ = n, first, up, err, name, i
}

dom_redraw :: proc(el: sciter_app.Element, area: sciter_app.Rect, window: sciter_app.Window) {
	sciter_app.update_element(el, render = true) // re-run style and layout, repaint now
	sciter_app.refresh_element_area(el, area) // repaint a rectangle in the element's own coordinates
	sciter_app.request_paint(el) // repaint all of it at the next frame
	sciter_app.update_window(window)
}

dom_popup :: proc(root: sciter_app.Element, button: sciter_app.Element, x, y: i32) {
	menu, _ := sciter_app.select_first(root, "#context-menu")
	sciter_app.show_popup(menu, button, .Bottom) // against an anchor
	sciter_app.show_popup_at(menu, {x, y}, .Top_Left) // at a point in window coordinates
	sciter_app.hide_popup(menu)
}

dom_focus :: proc(window: sciter_app.Window, input: sciter_app.Element) {
	sciter_app.set_focus(input) // == set_element_state(input, {.FOCUS})
	who, err := sciter_app.focus_element(window) // .Not_Found when nothing has it
	_, _ = who, err
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
	handled, err := sciter_app.send_event(el, .BUTTON_CLICK, source = el)
	_, _ = handled, err
}

ev5b :: proc(el: sciter_app.Element) {
	err := sciter_app.post_event(el, .BUTTON_CLICK, source = el)
	_ = err
}

ev6 :: proc(window: sciter_app.Window) {
	sciter_app.eval(window, "document.$('#ok').click()")
}

MY_TIMER :: 1

ev7 :: proc(el: sciter_app.Element) {
	sciter_app.set_timer(el, 100 * time.Millisecond, MY_TIMER)
	sciter_app.stop_timer(el, MY_TIMER)
}

ev8 :: proc(event: sciter_app.Event) -> bool {
	if te, ok := sciter_app.timer_event(event); ok {
		if te.id == MY_TIMER {
			// tick()
		}
		return true
	}
	return false
}

ev_capture :: proc(event: sciter_app.Event) {
	if me, ok := sciter_app.mouse_event(event); ok {
		#partial switch me.code {
		case .MOUSE_DOWN:
			sciter_app.set_capture(me.target)
		case .MOUSE_MOVE:
		// arrives even outside the element, because of the capture
		case .MOUSE_UP:
			sciter_app.release_capture(me.target)
		}
	}
}

ev_fire :: proc(chart: sciter_app.Element, json: string) -> (err: sciter_app.Error) {
	value := sciter_app.value_parse(json) or_return
	defer sciter_app.value_clear(&value)

	handled, ferr := sciter_app.fire_event({code = .CUSTOM, name = "data-arrived", target = chart, data = &value})
	_, _ = handled, ferr
	return nil
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

res4_on_load_data :: proc(h: ^sciter_app.Host_Handler, r: ^sciter_app.Load_Request) -> sciter_app.Load_Result {
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
// api.md, the three ways of giving engine resources back

api_scoped_twin :: proc(window: sciter_app.Window) {
	v, err := sciter_app.scoped_eval(window, "getRows()") // released at the end of this scope
	_ = v
	_ = err
}

api_value_scope :: proc(window: sciter_app.Window) -> sciter_app.Error {
	scope: sciter_app.Value_Scope
	defer sciter_app.scope_release(&scope)

	rows := sciter_app.scope_add(&scope, sciter_app.eval(window, "getRows()")) or_return
	_ = rows
	return nil
}

api_tracking :: proc() {
	sciter_app.track_resources(true)
	defer sciter_app.report_leaked_resources() // prints what was never released, with its call site
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

// ---------------------------------------------------------------------------------------------------
// dom.md / api.md, the element's script object

dom_expando :: proc(el: sciter_app.Element) {
	expando, _ := sciter_app.expando(el)
	defer sciter_app.value_clear(&expando)

	rank, _ := sciter_app.value_get(&expando, "rowIndex") // read what script put there
	_ = rank
}

dom_expando_string :: proc(el: sciter_app.Element) {
	sciter_app.eval_element(el, `this.note = "hello"`) // not value_set(&expando, "note", &s)
}

// ---------------------------------------------------------------------------------------------------
// dom.md, URLs

dom_combine_url :: proc(el: sciter_app.Element) {
	full, _ := sciter_app.combine_url(el, "images/logo.png", context.temp_allocator)
	// -> "file:///home/me/app/assets/images/logo.png"
	_ = full
}

// ---------------------------------------------------------------------------------------------------
// events.md, animation frames

TICK :: sciter.Behavior_Events(u32(sciter.Behavior_Events.FIRST_APPLICATION_EVENT_CODE) + 1)

events_raf :: proc(el: sciter_app.Element) {
	sciter_app.request_animation_frame(el, TICK) // TICK >= .FIRST_APPLICATION_EVENT_CODE
}

// ---------------------------------------------------------------------------------------------------
// events.md, synthesising input

events_send_input :: proc(button: sciter_app.Element, field: sciter_app.Element, at: [2]i32) {
	sciter_app.send_mouse(button, .MOUSE_DOWN, at, {.MAIN_MOUSE_BUTTON})
	sciter_app.send_mouse(button, .MOUSE_UP, at, {.MAIN_MOUSE_BUTTON}) // BUTTON_CLICK follows

	sciter_app.set_focus(field)
	sciter_app.send_text(field, "hello") // .DOWN/.CHAR/.UP per rune
}

// ---------------------------------------------------------------------------------------------------
// dom.md, hit testing and window metrics

dom_hit :: proc(window: sciter_app.Window, x, y: i32) {
	el, err := sciter_app.element_at(window, {x, y}) // .Not_Found off the document
	_, _ = el, err
}

dom_metrics :: proc(window: sciter_app.Window) {
	dpi := sciter_app.ppi(window) // 96 is unscaled; dpi.x / 96 is the scale factor
	narrowest := sciter_app.min_width(window)
	_, _ = dpi, narrowest
}

// ---------------------------------------------------------------------------------------------------
// events.md, driving a behavior

events_do_click :: proc(checkbox: sciter_app.Element) {
	handled, err := sciter_app.do_click(checkbox) // :checked flips, VALUE_CHANGED then BUTTON_CLICK
	_, _ = handled, err
}

// ---------------------------------------------------------------------------------------------------
// api.md, a behavior method of your own

SET_ZOOM :: u32(sciter.Behavior_Method_Identifiers.FIRST_APPLICATION_METHOD_ID)

Set_Zoom_Params :: struct {
	method_id: u32,
	factor:    f32,
	applied:   b32,
} // id must be first

api_call_method :: proc(chart: sciter_app.Element) {
	p := Set_Zoom_Params {
		method_id = SET_ZOOM,
		factor    = 1.5,
	}
	handled, err := sciter_app.call_behavior_method(chart, &p)
	_, _ = handled, err
}

api_answer_method :: proc(event: sciter_app.Event) -> bool {
	mc := sciter_app.method_call(event) or_return
	switch args in sciter_app.method_args(mc) {
	case ^sciter.Value_Params:
		args.val = sciter_app.value_from(i32(42)); return true
	case ^sciter.Is_Empty_Params:
		args.is_empty = 1; return true
	}
	return false
}

// ---------------------------------------------------------------------------------------------------
// api.md, posting to the engine's thread

api_post :: proc(window: sciter_app.Window) {
	ROWS_READY :: uintptr(1)
	sciter_app.post_callback(window, ROWS_READY, uintptr(3))
}

api_on_posted :: proc(handler: ^sciter_app.Host_Handler, posted: sciter_app.Posted) {
	ROWS_READY :: uintptr(1)
	if posted.wparam == ROWS_READY {
		// redraw(...)
	}
}

// ---------------------------------------------------------------------------------------------------
// dom.md, Nodes

dom_nodes :: proc(el: sciter_app.Element) {
	node, err := sciter_app.node_from_element(el)
	type, _ := sciter_app.node_type(node)

	child, cerr := sciter_app.node_first_child(node)
	if cerr == nil {
		content, _ := sciter_app.node_text(child)
		defer delete(content)
	}
	_, _ = err, type
}

dom_node_walk :: proc(node: sciter_app.Node) {
	for child, err := sciter_app.node_first_child(node); err == nil; child, err = sciter_app.node_next_sibling(child) {
		_ = child
	}
}

dom_node_insert :: proc(summary: sciter_app.Element) {
	created, _ := sciter_app.make_text_node(" appended")
	// The insert does not take the reference over, so the release is owed either way.
	defer sciter_app.node_release(created)
	target, _ := sciter_app.node_from_element(summary)
	sciter_app.node_insert(target, .APPEND, created)
}

// ---------------------------------------------------------------------------------------------------
// resources.md, the .DELAYED answer

Delayed_App :: struct {
	pending: sciter.Hrequest,
}

delayed_on_load_data :: proc(
	handler: ^sciter_app.Host_Handler,
	request: ^sciter_app.Load_Request,
) -> sciter_app.Load_Result {
	app := (^Delayed_App)(handler.user_data)

	app.pending = request.raw.requestId
	return .DELAYED
}

delayed_answer :: proc(window: sciter_app.Window, uri: string, bytes: []u8, app: ^Delayed_App) {
	sciter_app.data_ready_async(window, uri, bytes, app.pending)
}

// ---------------------------------------------------------------------------------------------------
// resources.md and api.md, taking a request over

Request_App :: struct {
	// `take_request` hands back an `Owned_Request` - the type that owes an `unuse_request`.
	pending: sciter_app.Owned_Request,
}

request_serve_now :: proc(request: ^sciter_app.Load_Request, css: []u8) -> sciter_app.Load_Result {
	return sciter_app.serve_request(request, css, mime = "text/css")
}

request_fail :: proc(request: ^sciter_app.Load_Request) -> sciter_app.Load_Result {
	sciter_app.fail_request(sciter_app.request_of(request), 404)
	return .MYSELF
}

request_take :: proc(request: ^sciter_app.Load_Request, app: ^Request_App) -> sciter_app.Load_Result {
	rq, result := sciter_app.take_request(request)
	app.pending = rq
	return result
}

request_answer_later :: proc(app: ^Request_App, bytes: []u8) {
	sciter_app.succeed_request(sciter_app.borrow_request(app.pending), bytes)
	sciter_app.unuse_request(app.pending)
}

// ---------------------------------------------------------------------------------------------------
// events.md, drag and drop

dnd_attach :: proc(
	drop_zone: sciter_app.Element,
	on_event: proc(_: ^sciter_app.Event_Handler, _: sciter_app.Event) -> bool,
) {
	handler := sciter_app.Event_Handler {
		subscription = {.EXCHANGE},
		on_event     = on_event,
	}
	sciter_app.attach_handler(drop_zone, &handler)
}

dnd_accessor :: proc(event: sciter_app.Event) {
	if xe, ok := sciter_app.exchange_event(event); ok {
		_ = xe.code
		_ = xe.pos
		_ = xe.source
		_ = xe.mode
		_ = xe.data
	}
}

dnd_switch :: proc(xe: sciter_app.Exchange_Event, take: proc(_: ^sciter_app.Value)) -> bool {
	switch xe.code {
	case .WILL_ACCEPT_DROP:
		return true
	case .DRAG:
		return true
	case .DROP:
		take(xe.data)
		return true
	case .DRAG_ENTER, .DRAG_LEAVE, .DRAG_CANCEL, .PASTE, .DRAG_REQUEST:
	}
	return false
}

// ---------------------------------------------------------------------------------------------------
// graphics.md

gfx_offscreen :: proc() {
	img, _ := sciter_app.create_image(120, 120)
	sciter_app.paint_image(img, proc(gfx: sciter_app.Graphics, w, h: u32, user: rawptr) {
		sciter_app.set_fill_color(gfx, sciter_app.rgb(0x89, 0xb4, 0xfa))
		sciter_app.set_line_color(gfx, sciter_app.rgb(0x89, 0xb4, 0xfa))
		sciter_app.draw_rect(gfx, 0, 0, f32(w), f32(h))
	})
	png, _ := sciter_app.save_image(img, .PNG)
	_ = png
}

gfx_attach :: proc(
	element: sciter_app.Element,
	on_event: proc(_: ^sciter_app.Event_Handler, _: sciter_app.Event) -> bool,
) {
	handler := sciter_app.Event_Handler {
		subscription = {.DRAW},
		on_event     = on_event,
	}
	sciter_app.attach_handler(element, &handler)
}

gfx_on_event :: proc(handler: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	de, ok := sciter_app.draw_event(event)
	if !ok || de.layer != .CONTENT {
		return false
	}
	sciter_app.set_fill_color(de.gfx, sciter_app.rgb(0xf3, 0x8b, 0xa8))
	sciter_app.draw_ellipse(de.gfx, f32(de.area.x), f32(de.area.y), 20, 20)
	return true
}

gfx_invalidate :: proc(dial: sciter_app.Element) {
	sciter.api().SciterUpdateElement(sciter.Helement(dial), false)
}

gfx_ticks :: proc(gfx: sciter_app.Graphics, cx, cy, radius: f32) {
	sciter_app.save_state(gfx)
	sciter_app.translate(gfx, cx, cy)
	for _ in 0 ..< 12 {
		sciter_app.draw_line(gfx, 0, -radius + 4, 0, -radius + 12)
		sciter_app.rotate(gfx, 2 * math.PI / 12)
	}
	sciter_app.restore_state(gfx)
}

gfx_path :: proc(gfx: sciter_app.Graphics) {
	path, _ := sciter_app.create_path()
	defer sciter_app.release_path(path)

	sciter_app.path_move_to(path, 0, 0)
	sciter_app.path_line_to(path, 16, 0)
	sciter_app.path_bezier_to(path, 16, 8, 8, 16, 0, 16)
	sciter_app.path_close(path)

	sciter_app.draw_path(gfx, path, .FILL_AND_STROKE)
}

gfx_text :: proc(gfx: sciter_app.Graphics, element: sciter_app.Element, x, y: f32) {
	text, _ := sciter_app.create_text(element, "42.7 °C")
	defer sciter_app.release_text(text)

	m, _ := sciter_app.text_metrics(text)
	sciter_app.set_text_box(text, 200, 100)
	sciter_app.draw_text(gfx, text, x, y, .Middle_Center)
	_ = m
}

// ---------------------------------------------------------------------------------------------------
// ENGINE.md, block 1 — choosing the graphics layer, before any window exists

eng1 :: proc() {
	sciter_app.set_option(.SET_GFX_LAYER, uintptr(sciter.Gfx_Layer.SKIA_OPENGL))
}

// ---------------------------------------------------------------------------------------------------
// ENGINE.md, block 2 — asking a running window which backend it got

eng2 :: proc(window: sciter_app.Window) {
	v, _ := sciter_app.eval(window, "Window.this.graphicsBackend") // expect x11-opengl-skia on Linux
	_ = v
}

// ---------------------------------------------------------------------------------------------------
// api.md, reading somebody else's asset

asset_members_block :: proc(input: sciter_app.Element) {
	edit, _ := sciter_app.element_asset(input, "edit")
	props, methods := sciter_app.asset_members(edit, context.temp_allocator)
	// props   -> ["selectionStart", "selectionEnd", "selectionText", "isStandalone"]
	// methods -> ["selectAll", "selectRange", "removeText", "insertText", "appendText"]
	_, _ = props, methods
}

// ---------------------------------------------------------------------------------------------------
// api.md, streaming video frames

video_block :: proc(element: sciter_app.Element, frame: []byte) {
	dest, _ := sciter_app.video_destination(element)
	sciter_app.video_start_streaming(dest, 640, 480) // .RGB32 by default
	sciter_app.video_render_frame(dest, frame) // BGRA, top-down
	sciter_app.video_stop_streaming(dest)
}

// ---------------------------------------------------------------------------------------------------
// api.md, a named behavior factory

Gauge_Snippet :: struct {
	using handler: sciter_app.Event_Handler,
}

on_gauge_event_snippet :: proc(h: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	return false
}

// div.gauge { behavior: my-gauge; }

on_attach_behavior_snippet :: proc(
	h: ^sciter_app.Host_Handler,
	r: ^sciter_app.Behavior_Request,
) -> ^sciter_app.Event_Handler {
	if r.name != "my-gauge" {
		return nil // not ours; the element just gets no behavior
	}
	gauge := new(Gauge_Snippet)
	gauge.subscription = {.MOUSE}
	gauge.on_event = on_gauge_event_snippet
	return gauge // attached immediately, before this returns
}

// ---------------------------------------------------------------------------------------------------
// api.md, freeing a behavior handler on DETACH

behavior_detach_block :: proc(event: sciter_app.Event, widget: rawptr) {
	if event.group == {} && event.params != nil {
		if sciter.Initialization_Events((^sciter.Initialization_Params)(event.params).cmd) == .DETACH {
			free(widget)
		}
	}
}


// ---------------------------------------------------------------------------------------------------
// rules.md, the temp-allocator boundary

pump_with_a_boundary_block :: proc() {
	for sciter_app.run_once() {
		sciter_app.heartbeat()
		// ... your per-turn work, DOM reads, whatever ...
		free_all(context.temp_allocator)
	}
}

// ---------------------------------------------------------------------------------------------------
// rules.md, what a callback may and may not keep
//
// `App` there is an application struct with a `log`; this one is local to the snippet because the file's
// shared `App` stub is the one `calling-between-odin-and-js.md` uses.

Logging_App :: struct {
	log: [dynamic]string,
}

callback_temp_lifetime_block :: proc(handler: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	app := (^Logging_App)(handler.user_data)

	name, _ := sciter_app.text(event.element, context.temp_allocator)
	if name == "quit" {sciter_app.stop()} 	// fine: used and dropped inside the callback

	append(&app.log, name) // WRONG: that memory is gone when this returns
	append(&app.log, strings.clone(name)) // right: an allocator that outlives the callback
	return false
}

// ---------------------------------------------------------------------------------------------------
// rules.md, one arena for a batch that shares a lifetime

batch_arena_block :: proc(root: sciter_app.Element) -> sciter_app.Error {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	batch := vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena) // one call frees the lot

	rows := sciter_app.select_all(root, "tr", batch) or_return
	for row in rows {
		text := sciter_app.text(row, batch) or_return
		_ = text // ... no individual delete anywhere ...
	}
	return nil
}

// ---------------------------------------------------------------------------------------------------
// threading.md, the doorbell and its shared structure

Threading_App :: struct {
	using host: sciter_app.Host_Handler,
	window:     sciter_app.Window,
	mutex:      sync.Mutex,
	results:    [dynamic]string, // written by the worker, read on the engine's thread
	cancel:     bool,
}

// threading.md, every path ends in exactly one terminal message

threading_work :: proc(app: ^Threading_App) {
	PROGRESS :: uintptr(1)
	FINISHED :: uintptr(3)
	FAILED :: uintptr(4)

	failed := false
	for step in 1 ..= 10 {
		if sync.atomic_load(&app.cancel) {
			sciter_app.post_callback(app.window, FINISHED, 1) // cancelled
			return
		}
		if failed {
			sciter_app.post_callback(app.window, FAILED, uintptr(step))
			return
		}
		sciter_app.post_callback(app.window, PROGRESS, uintptr(step * 10))
	}
	sciter_app.post_callback(app.window, FINISHED, 0) // ran to the end
}

// ---------------------------------------------------------------------------------------------------
// EMBEDDING.md, block 1 — the whole windowless loop

embedding_windowless :: proc() {
	DOC :: "<html><body>windowless</body></html>"

	view, _ := sciter_app.create_windowless({width = 320, height = 240})
	sciter_app.load_html(view.window, DOC, "about:blank")
	sciter_app.windowless_heartbeat(&view)
	sciter_app.paint_windowless(&view) // view.pixels is now RGBA
}

// EMBEDDING.md's second block is raw Xlib and is deliberately not here: `just cross-check` type checks
// this file for windows_amd64 and darwin, and `vendor:x11/xlib` declares nothing off Linux. It is the
// same exclusion `integration` and `native_child` get, for the same reason.

// ---------------------------------------------------------------------------------------------------
// BEHAVIORS.md, blocks 1 and 2 — driving an intrinsic behavior's asset, and asking its arity first

behaviors_asset :: proc(input: sciter_app.Element) {
	asset, _ := sciter_app.element_asset(input, "edit") // interface name, not tag name
	mode, _ := sciter_app.asset_get(asset, "selectionEnd") // a property
	n := sciter_app.value_from_string("hello")
	_, _ = sciter_app.asset_call(asset, "insertText", {n})

	arity, ok := sciter_app.asset_method_arity(asset, "showPopup") // 1, true

	_, _, _ = mode, arity, ok
}

// ---------------------------------------------------------------------------------------------------
// gotchas.md, blocks 1 and 2 — the teardown order that survives, and the one line that makes the
// engine's diagnostics visible

gotchas_teardown :: proc(window: sciter_app.Window) {
	sciter_app.hide(window)
	sciter_app.heartbeat() // the pump is what takes it off the paint list
	sciter_app.close(window)
	sciter_app.heartbeat()
}

gotchas_debug_output :: proc() {
	sciter_app.set_default_debug_output() // before loading any document
}

// ---------------------------------------------------------------------------------------------------
// html-css-js.md and gotchas.md #13 — a transform is paint-time, so the surface is what you ask

transform_pixel :: proc(view: sciter_app.Windowless_View) {
	view := view
	// Did the engine actually PAINT the element where the transform asked? Ask the surface, not the DOM.
	r, g, b, _ := sciter_app.windowless_pixel(&view, 220, 80)
	moved := r == 0x00 && g == 0xff && b == 0x00 // the box's own colour, 200px right of its layout position

	_ = moved
}
