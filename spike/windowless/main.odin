// Spike: can Sciter render into a buffer we own, with no window of its own?
//
// The question this answers is "can Sciter be a pane inside somebody else's renderer" - an immediate-mode
// UI, a game engine, anything already drawing its own frames. If it can, the engine is not just a way to
// build a window; it is a component you composite.
//
// `SciterProcX` plus the SXM_* messages in sciter-x-msg.h are the windowless API. The headers describe
// every message but never say where the HWINDOW comes from when there is no window, which is the one
// thing this spike is here to settle empirically.
//
//   odin run spike/windowless                    # the configuration that works
//   odin run spike/windowless -- res             # reproduces the SXM_RESOLUTION crash
//   odin run spike/windowless -- nobeat          # no heartbits
//   SCITER_LIB=/path/to/libsciter.so odin run spike/windowless
//
// Writes target/windowless.ppm on success.
//
// Result against 6.0.4.9 on Linux x64 - see docs/EMBEDDING.md:
//   works  - SXM_CREATE with a fabricated HWINDOW, SXM_SIZE into our own buffer, SciterLoadHtml,
//            heartbits, SXM_PAINT, CSS, QuickJS at load, the DOM API, hit-testing, SciterEval, repaint
//   broken - SXM_RESOLUTION (crashes on the next idle)
//
// **This spike is superseded, and one of its conclusions was wrong.** The mode is wrapped in
// `sciter_app/windowless.odin` now, with `examples/windowless.odin` as the worked version.
//
// The wrong conclusion was "SXM_MOUSE is never handled". The mouse works; the *page below* does not.
// `#hit` is `position:absolute` with `height:100%`, and Sciter lays that out **one pixel tall**, so
// every click here lands on <body> rather than on the overlay that was meant to catch it. The engine
// was blamed for a stylesheet bug. Kept as it was, because the mistake is instructive: when an element
// does not receive events, ask `location(el, .Border, .View)` what shape the engine thinks it is.
//
// Two other things this spike never tried, both measured later: one SXM_DESTROY makes the next
// SXM_CREATE segfault, and script timers never fire in a windowless view.

package windowless

import sciter "../.."
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:unicode/utf16"

W :: 320
H :: 240

// Three-state page, so a single pixel tells us which layer worked:
//   red   - CSS rendered, script never ran
//   blue  - QuickJS ran at load
//   green - the synthetic mouse event reached the handler
HTML :: `<html>
<head><style>
  body { margin: 0; padding: 0; width: 100%; height: 100%; background: #ff0000; }
  #hit { position: absolute; left: 0; top: 0; width: 100%; height: 100%; }
</style></head>
<body>
  <div id="hit"></div>
  <script type="text/javascript">
    document.body.style["background-color"] = "#0000ff";
    document.getElementById("hit").addEventListener("click", function() {
      document.body.style["background-color"] = "#00ff00";
    });
  </script>
</body>
</html>`

// Every step is a "did this actually work" checkpoint, so failures name themselves rather than showing up
// later as a blank buffer.
step :: proc(ok: bool, what: string) {
	fmt.printfln("%-34s %s", what, ok ? "ok" : "FAILED")
	if !ok {os.exit(1)}
}

// Bottom-left-origin, 24-bit binary PPM. Chosen over PNG because it needs no encoder - the point here is
// to prove the pixels exist, not to ship an image pipeline.
write_ppm :: proc(path: string, px: []u8) -> bool {
	buf := make([dynamic]u8, 0, W * H * 3 + 32)
	defer delete(buf)
	append(&buf, fmt.tprintf("P6\n%d %d\n255\n", W, H))
	for i in 0 ..< W * H {
		// The surface is documented as "RGBA or BGRA" without saying which. Report both orders and let
		// the sampled pixels below disambiguate.
		append(&buf, px[i * 4 + 0], px[i * 4 + 1], px[i * 4 + 2])
	}
	return os.write_entire_file(path, buf[:]) == nil
}

sample :: proc(px: []u8, x, y: int) -> (b, g, r, a: u8) {
	i := (y * W + x) * 4
	return px[i], px[i + 1], px[i + 2], px[i + 3]
}

main :: proc() {
	err, tried := sciter.load()
	if err != .None {
		fmt.eprintfln("could not load the Sciter engine: %v", err)
		for candidate in tried {fmt.eprintfln("  %s", candidate)}
		os.exit(1)
	}
	api := sciter.api()
	fmt.printfln(
		"Sciter %d.%d.%d.%d\n",
		api.SciterVersion(0),
		api.SciterVersion(1),
		api.SciterVersion(2),
		api.SciterVersion(3),
	)

	// NOTE: no SciterExec(.INIT) here, deliberately. Every windowed example in this repo calls it, and the
	// SDK's windowless demo does not - it stands up the windowed application subsystem, which is exactly
	// what a windowless view must not have.

	has :: proc(flag: string) -> bool {
		for a in os.args[1:] {if a == flag {return true}}
		return false
	}
	// THE UNKNOWN, settled. The headers have no windowless constructor, so the question was whether
	// HWINDOW must be a real native window or is just a key. The SDK's own cross-platform windowless demo
	// (demos.lite/lite-sdl) passes an `SDL_Window*`, which is not an OS handle either - it is a pointer
	// the engine keys its view map on. Any distinct non-null value works, including this one.
	//
	// Do NOT try the other hypothesis by handing this an HWINDOW from SciterCreateWindow. On Linux a
	// SW_MAIN window sized 320x240 makes the engine mode-set the X display down to 320x180, which is a
	// display-wide change, not a window one.
	hwnd := rawptr(uintptr(0xBEEF))

	create := sciter.Sciter_X_Msg_Create {
		header = {msg = u32(sciter.Sciter_X_Msg_Code.CREATE)},
		backend = .BITMAP,
		device = nil, // GPU targets want a device here; BITMAP does not
	}
	step(bool(api.SciterProcX(hwnd, &create.header)), "SXM_CREATE (invented HWINDOW)")

	// The demo sets this immediately after SXM_CREATE. SC_INVALIDATE_RECT is how a windowless view asks
	// to be repainted - without it you have no idea when to call SXM_PAINT.
	on_notify :: proc "system" (pns: sciter.Lpsciter_Callback_Notification, param: rawptr) -> u32 {
		if pns.code == sciter.SC_INVALIDATE_RECT {
			(^int)(param)^ += 1
		}
		return 0
	}
	invalidations := 0
	api.SciterSetCallback(hwnd, on_notify, &invalidations)

	// Script errors are otherwise invisible here - there is no window, so there is no console. Without
	// this an exception in the page looks identical to "the engine ignored the event".
	on_debug :: proc "system" (
		param: rawptr,
		subsystem: sciter.Output_Subsytems,
		severity: sciter.Output_Severity,
		text: sciter.Wide_String,
		length: u32,
	) {
		context = runtime.default_context()
		buf := make([]u8, int(length) * 4 + 8, context.temp_allocator)
		n := utf16.decode_to_utf8(buf, text[:length])
		fmt.printfln("  [%v/%v] %s", subsystem, severity, string(buf[:n]))
	}
	api.SciterSetupDebugOutput(hwnd, nil, on_debug)

	// We own the pixels. Sciter is handed a pointer and a stride and never allocates a surface itself -
	// which is exactly what makes it compositable into someone else's frame.
	pixels := make([]u8, W * H * 4)
	defer delete(pixels)

	size := sciter.Sciter_X_Msg_Size {
		header = {msg = u32(sciter.Sciter_X_Msg_Code.SIZE)},
		width = W,
		height = H,
		surface = {bitmap = {pixels = raw_data(pixels), stride = W * 4}},
	}
	step(bool(api.SciterProcX(hwnd, &size.header)), "SXM_SIZE (our buffer)")

	res := sciter.Sciter_X_Msg_Resolution {
		header = {msg = u32(sciter.Sciter_X_Msg_Code.RESOLUTION)},
		pixelsPerInch = 96,
	}
	// OFF BY DEFAULT because it crashes this build. SXM_RESOLUTION posts a media-changed item; the next
	// time anything drains the posted queue (any heartbit, any mouse message) the engine walks
	//   html::view::on_media_changed -> html::iwindow::setup_window_frame -> wing::window::setAttribute
	// and dereferences a native window this view does not have. The crash therefore surfaces later than
	// the call that caused it. Pass `res` to reproduce it.
	if has("res") {step(bool(api.SciterProcX(hwnd, &res.header)), "SXM_RESOLUTION")}

	// Base URL matters: the SDK demo passes "about:blank" rather than NULL.
	base: [16]u16
	utf16.encode_string(base[:], "about:blank")
	html := HTML
	step(
		bool(api.SciterLoadHtml(hwnd, raw_data(html), u32(len(html)), raw_data(base[:]))),
		"SciterLoadHtml (no window)",
	)

	// Timers, transitions and script tasks all hang off the heartbit. Without pumping it the document
	// loads but never settles.
	beat :: proc(api: ^sciter.Isciter_Api, hwnd: rawptr, t: u32) {
		hb := sciter.Sciter_X_Msg_Heartbit {
			header = {msg = u32(sciter.Sciter_X_Msg_Code.HEARTBIT)},
			time = t,
		}
		api.SciterProcX(hwnd, &hb.header)
	}
	beats := !has("nobeat")
	if beats {for i in 0 ..< 10 {beat(api, hwnd, u32(i) * 16)}}

	paint :: proc(api: ^sciter.Isciter_Api, hwnd: rawptr) -> bool {
		p := sciter.Sciter_X_Msg_Paint {
			header = {msg = u32(sciter.Sciter_X_Msg_Code.PAINT)},
			element = nil, // whole document
			isFore = true,
			rcPaint = {left = 0, top = 0, right = W, bottom = H},
		}
		return bool(api.SciterProcX(hwnd, &p.header))
	}
	step(paint(api, hwnd), "SXM_PAINT #1")

	b0, g0, r0, a0 := sample(pixels, W / 2, H / 2)
	fmt.printfln("  centre pixel after load  = %02x %02x %02x %02x", b0, g0, r0, a0)

	// Synthetic click at the centre. Down, up, then the synthesised MOUSE_CLICK - the engine's own
	// windowed backends send all three, and the script handler is bound to `click`.
	click :: proc(api: ^sciter.Isciter_Api, hwnd: rawptr, ev: sciter.Mouse_Events) -> bool {
		m := sciter.Sciter_X_Msg_Mouse {
			header = {msg = u32(sciter.Sciter_X_Msg_Code.MOUSE)},
			event = ev,
			button = {.MAIN_MOUSE_BUTTON},
			modifiers = {},
			pos = {x = W / 2, y = H / 2},
		}
		return bool(api.SciterProcX(hwnd, &m.header))
	}
	// `SciterProcX` returns "was it handled", and an unhandled mouse move over inert content is a
	// legitimate false - so these are reported, not asserted.
	// Discriminator: is the engine's hit-test working at all in this configuration? If SciterFindElement
	// resolves the centre point to an element, the DOM and layout are addressable and any mouse failure is
	// in the event path, not in geometry.
	{
		root, hit: sciter.Helement
		fmt.printfln("  SciterGetRootElement     = %v", api.SciterGetRootElement(hwnd, &root))
		r := api.SciterFindElement(hwnd, {x = W / 2, y = H / 2}, &hit)
		fmt.printfln("  SciterFindElement        = %v, element %v", r, hit != nil)
	}

	// Host-driven change. If this repaints, the whole embedder round trip (Odin -> QuickJS -> style ->
	// paint into our buffer) is intact, and any mouse failure is confined to SXM_MOUSE delivery.
	{
		src := `document.body.style["background-color"] = "#ffff00";`
		w: [128]u16
		n := utf16.encode_string(w[:], src)
		rv: sciter.Sciter_Value
		ok := api.SciterEval(hwnd, raw_data(w[:]), u32(n), &rv)
		if beats {for i in 0 ..< 4 {beat(api, hwnd, 300 + u32(i) * 16)}}
		paint(api, hwnd)
		b, g, r, _ := sample(pixels, W / 2, H / 2)
		fmt.printfln("  SciterEval               = %v -> pixel %02x %02x %02x", bool(ok), b, g, r)
	}

	focus := sciter.Sciter_X_Msg_Focus {
		header = {msg = u32(sciter.Sciter_X_Msg_Code.FOCUS)},
		got = true,
	}
	fmt.printfln("  SXM_FOCUS handled        = %v", bool(api.SciterProcX(hwnd, &focus.header)))

	for ev in ([]sciter.Mouse_Events{.MOUSE_ENTER, .MOUSE_MOVE, .MOUSE_DOWN, .MOUSE_UP, .MOUSE_CLICK}) {
		handled := click(api, hwnd, ev)
		if beats {for i in 0 ..< 4 {beat(api, hwnd, 200 + u32(i) * 16)}}
		fmt.printfln("  %-24v = %v", ev, handled)
	}
	if beats {for i in 0 ..< 10 {beat(api, hwnd, 160 + u32(i) * 16)}}

	step(paint(api, hwnd), "SXM_PAINT #2")
	b1, g1, r1, a1 := sample(pixels, W / 2, H / 2)
	fmt.printfln("  centre pixel after click = %02x %02x %02x %02x", b1, g1, r1, a1)

	nonzero := 0
	for i in 0 ..< W * H {
		if pixels[i * 4 + 0] != 0 || pixels[i * 4 + 1] != 0 || pixels[i * 4 + 2] != 0 {nonzero += 1}
	}
	fmt.printfln("  non-black pixels         = %d / %d", nonzero, W * H)

	// target/ is gitignored; writing into the repo root would dirty the tree on every run.
	os.make_directory("target")
	step(write_ppm("target/windowless.ppm", pixels), "wrote target/windowless.ppm")

	destroy := sciter.Sciter_X_Msg_Destroy {
		header = {msg = u32(sciter.Sciter_X_Msg_Code.DESTROY)},
	}
	step(bool(api.SciterProcX(hwnd, &destroy.header)), "SXM_DESTROY")

	fmt.println("\nverdict:")
	fmt.printfln("  rendered into our own buffer : %v", nonzero > 0)
	fmt.printfln("  script + input changed it    : %v", (b0 != b1 || g0 != g1 || r0 != r1))
}
