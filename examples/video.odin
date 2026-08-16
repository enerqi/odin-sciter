// Streaming video frames into a <video> element from Odin.
//
//   just example video
//   odin test examples/video.odin -file      # needs a display; skips itself without one
//
// This is the only part of Sciter's API that is not in `ISciterAPI`. `sciter::video_destination` is a
// C++ class of pure virtuals declared in `sciter-x-video-api.h`, with no C declaration anywhere, so
// there is no table slot to call and nothing for the binding generator to see. `sciter_app/video.odin`
// lays its virtual table out by hand; this example is what checks that the layout is right, because
// nothing else can - `just example api_map` resolves table slots by name and a C++ vtable is invisible
// to it.
//
// Two things about the engine had to be measured before any of this would run, and neither is in the
// SDK's documentation:
//
//   1. `behavior: video` is backed by **libVLC** on Linux (`libvlc.so` beside the engine, or the
//      distribution's `libvlc-dev`). Without it the behavior does not attach at all: the element gets
//      no behavior, `element_asset` answers `.OPERATION_FAILED`, and the `VIDEO_BIND_RQ` event the
//      SDK's C++ samples are built around is never sent. The SDK's own samples cannot run on a machine
//      without libvlc, which is why they were no help here.
//   2. `behavior: custom-video` needs no codec library and is the one to use for host-fed frames. It
//      publishes a SOM asset named `video` with a single method, `renderingSite`, which hands over the
//      destination. Neither the behavior nor the method appears in the SDK's `docs/md/`, and script
//      cannot call `renderingSite` - `document.$("video").renderingSite()` answers "not a function".
//      It is a native-side interface, reached through the passport.
//
// What runs below is a synthetic 30 FPS source: a filled rectangle bouncing around a frame, pushed in
// through `video_render_frame_part` so that only the changed rectangle crosses the boundary. That is
// the same shape as the SDK's `behavior_video_generator.cpp`, in Odin and with no C++ behavior class.
package main

import sciter ".."
import "../sciter_app"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

DOC :: `<html>
<head><style>
  html  { background: #1e1e2e; color: #cdd6f4; font: 16px system; }
  body  { padding: 1.5em; margin: 0; }
  h1    { color: #89b4fa; margin: 0 0 .4em 0; }
  p     { margin: .3em 0; color: #a6adc8; }
  video { behavior: custom-video; size: *; height: 320px; border: 1px solid #45475a;
          border-radius: 4px; foreground-size: contain; }
  #out  { margin-top: 1em; padding: .6em 1em; background: #313244; border-radius: 4px;
          font: 14px monospace; }
</style></head>
<body>
  <h1>video</h1>
  <p>frames generated in Odin, streamed into the element below</p>
  <video id="screen" />
  <div id="out">(Odin fills this in)</div>
</body>
</html>`

FRAME_WIDTH :: 480
FRAME_HEIGHT :: 320
PART_WIDTH :: 96
PART_HEIGHT :: 48

// One BGRA pixel. `.RGB32` is what the engine calls this layout and the name is wrong the same way
// `.RAW` image encoding's is: the bytes are blue, green, red, alpha.
Pixel :: [4]u8

bgra :: proc(r, g, b: u8) -> Pixel {
	return {b, g, r, 0xff}
}

// A bouncing rectangle, which is enough to prove frames are arriving and being composited in the right
// place. `part` is the only buffer that crosses into the engine.
Source :: struct {
	part:   [PART_WIDTH * PART_HEIGHT]Pixel,
	x, y:   int,
	dx, dy: int,
	colour: int,
	frames: int,
}

COLOURS :: [?]Pixel{{0xf3, 0x8b, 0xa8, 0xff}, {0x8b, 0xf3, 0xa6, 0xff}, {0xfa, 0xb3, 0x89, 0xff}}

source_init :: proc(s: ^Source) {
	s.dx, s.dy = 7, 5
	source_fill(s)
}

source_fill :: proc(s: ^Source) {
	colours := COLOURS
	c := colours[s.colour % len(colours)]
	for i in 0 ..< len(s.part) {
		s.part[i] = c
	}
}

// Advances one frame, bouncing off the edges and changing colour when it does.
source_step :: proc(s: ^Source) {
	s.frames += 1
	s.x += s.dx
	s.y += s.dy
	if s.x < 0 || s.x > FRAME_WIDTH - PART_WIDTH {
		s.x = clamp(s.x, 0, FRAME_WIDTH - PART_WIDTH)
		s.dx = -s.dx
		s.colour += 1
		source_fill(s)
	}
	if s.y < 0 || s.y > FRAME_HEIGHT - PART_HEIGHT {
		s.y = clamp(s.y, 0, FRAME_HEIGHT - PART_HEIGHT)
		s.dy = -s.dy
		s.colour += 1
		source_fill(s)
	}
}

// The bytes of the part buffer, which is what the wrapper takes.
source_bytes :: proc(s: ^Source) -> []byte {
	return (([^]byte)(&s.part[0]))[:len(s.part) * size_of(Pixel)]
}

// A whole frame of one colour, for the initial fill - `render_frame_part` only ever touches its own
// rectangle, so without this the rest of the frame is whatever the engine allocated.
background_frame :: proc(allocator := context.allocator) -> []byte {
	pixels := make([]Pixel, FRAME_WIDTH * FRAME_HEIGHT, allocator)
	for i in 0 ..< len(pixels) {
		pixels[i] = bgra(0x18, 0x18, 0x25)
	}
	return (([^]byte)(raw_data(pixels)))[:len(pixels) * size_of(Pixel)]
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

	window, werr := sciter_app.create_window({width = 560, height = 520})
	if werr != nil {
		fmt.eprintln("could not create a window:", werr)
		os.exit(1)
	}
	if err := sciter_app.load_html(window, DOC); err != nil {
		fmt.eprintln("could not load the document:", err)
		os.exit(1)
	}
	sciter_app.show(window)

	root, _ := sciter_app.root(window)
	screen, serr := sciter_app.select_first(root, "#screen")
	if serr != nil {
		fmt.eprintln("no <video> element:", serr)
		os.exit(1)
	}

	// What the behavior publishes. Worth printing, because it is the whole of the native interface and
	// it is documented nowhere else.
	if asset, err := sciter_app.element_asset(screen, "video"); err == nil {
		props, methods := sciter_app.asset_members(asset, context.temp_allocator)
		fmt.printfln("the video asset: properties %v methods %v", props, methods)
	} else {
		fmt.println("the element has no video behavior:", err)
		fmt.println("(a plain `behavior: video` needs libVLC; this document asks for `custom-video`)")
		os.exit(1)
	}

	dest, derr := sciter_app.video_destination(screen)
	if derr != nil {
		fmt.eprintln("no rendering site:", derr)
		os.exit(1)
	}
	fmt.printfln("rendering site %p, alive = %v", dest, sciter_app.video_is_alive(dest))

	if !sciter_app.video_start_streaming(dest, FRAME_WIDTH, FRAME_HEIGHT, .RGB32) {
		fmt.eprintln("start_streaming refused")
		os.exit(1)
	}
	fmt.printfln("streaming %dx%d BGRA", FRAME_WIDTH, FRAME_HEIGHT)

	// One whole frame to establish the background, then only the moving rectangle after it.
	sciter_app.video_render_frame(dest, background_frame(context.temp_allocator))

	source := new(Source)
	source_init(source)

	// The frame clock. A real source has its own - a capture device, a decoder, a worker thread - and
	// hands frames over whenever it has one. This one is an element timer at 33ms, which is the honest
	// spelling of "30 FPS": `request_animation_frame` would pace it to the engine's own frame rate
	// instead, which on an unvsynced window is as fast as the loop will turn.
	//
	// Note the `.TIMER` inversion: the handler has to return true to be called again.
	Ticker :: struct {
		using handler: sciter_app.Event_Handler,
		dest:          ^sciter_app.Video_Destination,
		source:        ^Source,
		element:       sciter_app.Element,
		out:           sciter_app.Element,
	}

	ticker := new(Ticker)
	ticker.subscription = {.TIMER}
	ticker.dest = dest
	ticker.source = source
	ticker.element = screen
	ticker.out, _ = sciter_app.select_first(root, "#out")
	ticker.on_event = proc(h: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
		tk := (^Ticker)(h)
		if _, ok := sciter_app.timer_event(event); !ok {
			return false
		}

		if !sciter_app.video_is_alive(tk.dest) {
			return false // the site is gone; let the timer stop with it
		}

		source_step(tk.source)
		sciter_app.video_render_frame_part(
			tk.dest,
			source_bytes(tk.source),
			tk.source.x,
			tk.source.y,
			PART_WIDTH,
			PART_HEIGHT,
		)

		if tk.source.frames % 30 == 0 {
			line := fmt.tprintf("%d frames at (%d, %d)", tk.source.frames, tk.source.x, tk.source.y)
			sciter_app.set_text(tk.out, line)
			fmt.println(line)
		}

		return true // keep the timer running
	}
	sciter_app.attach_handler(screen, ticker)
	sciter_app.set_timer(screen, 33 * time.Millisecond)

	sciter_app.run()
	sciter_app.video_stop_streaming(dest)
	sciter_app.shutdown()
}

// ---------------------------------------------------------------------------------------------------
// Tests
//
// These need a window: the behavior has to attach before there is a destination at all, and a
// destination is a live C++ object rather than anything that can be faked. They skip themselves where
// there is no display. `ODIN_TEST_THREADS=1` is required - see the `example-tests` recipe.

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

@(private = "file")
// Shared by every test in this file, and created on first use. That is deliberate - a window per test
// would be slow, and closing one is itself hazardous (see `close` in sciter_app/window.odin) - but it
// makes the tests here order-coupled: **a test that changes the document must put it back**, usually by
// reloading `DOC`, or it breaks a later test and the failure points at the wrong one.
g_window: sciter_app.Window

@(private = "file")
test_window :: proc(t: ^testing.T) -> (window: sciter_app.Window, root: sciter_app.Element, ok: bool) {
	if !have_display() {
		fmt.println("skipping - this test needs a window")
		return nil, nil, false
	}
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

	if g_window == nil {
		// The engine holds the window for the life of the process, so it is allocated outside the test
		// runner's tracking allocator - otherwise every test reports it as a leak.
		context.allocator = runtime.default_allocator()

		sciter_app.init()

		w, err := sciter_app.create_window({width = 500, height = 400})
		testing.expect_value(t, err, nil)
		if w == nil {
			return nil, nil, false
		}
		g_window = w
	}

	testing.expect_value(t, sciter_app.load_html(g_window, DOC), nil)
	r, rerr := sciter_app.root(g_window)
	testing.expect_value(t, rerr, nil)
	return g_window, r, true
}

@(private = "file")
test_destination :: proc(t: ^testing.T) -> (dest: ^sciter_app.Video_Destination, ok: bool) {
	_, root, have := test_window(t)
	if !have {return nil, false}

	screen, serr := sciter_app.select_first(root, "#screen")
	testing.expect_value(t, serr, nil)

	d, derr := sciter_app.video_destination(screen)
	testing.expect_value(t, derr, nil)
	if d == nil {
		return nil, false
	}
	return d, true
}

// `behavior: custom-video` attaches with no codec library present, and publishes exactly one method.
// If a future engine renames it, `video_destination` breaks and this says so first.
@(test)
test_the_video_behavior_publishes_rendering_site :: proc(t: ^testing.T) {
	_, root, ok := test_window(t)
	if !ok {return}

	screen, _ := sciter_app.select_first(root, "#screen")
	asset, err := sciter_app.element_asset(screen, "video")
	testing.expect_value(t, err, nil)

	props, methods := sciter_app.asset_members(asset, context.temp_allocator)
	testing.expect_value(t, len(props), 0)
	testing.expect_value(t, len(methods), 1)
	if len(methods) == 1 {
		testing.expect_value(t, methods[0], "renderingSite")
	}
}

// The measured fact that motivates `asset_call`: the passport is a native interface, and script does
// not see this member at all.
@(test)
test_rendering_site_is_invisible_to_script :: proc(t: ^testing.T) {
	window, _, ok := test_window(t)
	if !ok {return}

	v, err := sciter_app.eval(window, `typeof document.$("#screen").renderingSite`)
	defer sciter_app.value_clear(&v)
	testing.expect_value(t, err, nil)

	s, serr := sciter_app.value_to_string(&v, context.temp_allocator)
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, s, "undefined")
}

// `renderingSite` returns a `.ASSET` Value, which is the type `value_to_asset` exists for.
@(test)
test_rendering_site_returns_an_asset_value :: proc(t: ^testing.T) {
	_, root, ok := test_window(t)
	if !ok {return}

	screen, _ := sciter_app.select_first(root, "#screen")
	asset, _ := sciter_app.element_asset(screen, "video")

	site, err := sciter_app.asset_call(asset, "renderingSite")
	defer sciter_app.value_clear(&site)
	testing.expect_value(t, err, nil)

	type, _ := sciter_app.value_type(&site)
	testing.expect_value(t, type, sciter.Value_Type.ASSET)

	inner, aerr := sciter_app.value_to_asset(&site)
	testing.expect_value(t, aerr, nil)
	testing.expect(t, inner != nil, "an asset Value carries a som_asset_t")
}

// A Value of the wrong type is a `.Wrong_Type`, not a garbage pointer.
@(test)
test_value_to_asset_refuses_other_types :: proc(t: ^testing.T) {
	v := sciter_app.value_from(i32(7))
	defer sciter_app.value_clear(&v)

	_, err := sciter_app.value_to_asset(&v)
	testing.expect_value(t, err, sciter_app.Api_Error.Wrong_Type)
}

// A method or property the passport does not list is `.Not_Found` rather than a call into nothing.
@(test)
test_asset_call_reports_an_unknown_member :: proc(t: ^testing.T) {
	_, root, ok := test_window(t)
	if !ok {return}

	screen, _ := sciter_app.select_first(root, "#screen")
	asset, _ := sciter_app.element_asset(screen, "video")

	_, err := sciter_app.asset_call(asset, "noSuchMethod")
	testing.expect_value(t, err, sciter_app.Api_Error.Not_Found)

	_, gerr := sciter_app.asset_get(asset, "noSuchProperty")
	testing.expect_value(t, gerr, sciter_app.Api_Error.Not_Found)
}

// The same machinery against a behavior that is not video's, so a failure here separates "the asset
// helpers are wrong" from "the video behavior changed".
@(test)
test_asset_helpers_work_on_the_edit_behavior :: proc(t: ^testing.T) {
	window, _, ok := test_window(t)
	if !ok {return}

	testing.expect_value(
		t,
		sciter_app.load_html(window, `<html><body><input id="e" type="text" value="abcdef"></body></html>`),
		nil,
	)
	root, _ := sciter_app.root(window)
	input, _ := sciter_app.select_first(root, "#e")

	asset, err := sciter_app.element_asset(input, "edit")
	testing.expect_value(t, err, nil)

	props, methods := sciter_app.asset_members(asset, context.temp_allocator)
	testing.expect(t, len(props) > 0, "the edit behavior publishes properties")
	testing.expect(t, len(methods) > 0, "and methods")

	start, gerr := sciter_app.asset_get(asset, "selectionStart")
	defer sciter_app.value_clear(&start)
	testing.expect_value(t, gerr, nil)
	n, nerr := sciter_app.value_to_int(&start)
	testing.expect_value(t, nerr, nil)
	testing.expect(t, n >= 0, "selectionStart is a number")
}

// The pointer `renderingSite` hands back is the behavior's `som_asset_t`, and the `video_destination`
// base subobject is at a *different* address. This pins that: if the two were ever equal, every call
// below would be going through the wrong vtable.
@(test)
test_the_destination_is_not_the_asset_pointer :: proc(t: ^testing.T) {
	_, root, ok := test_window(t)
	if !ok {return}

	screen, _ := sciter_app.select_first(root, "#screen")
	asset, _ := sciter_app.element_asset(screen, "video")
	site, _ := sciter_app.asset_call(asset, "renderingSite")
	defer sciter_app.value_clear(&site)
	inner, _ := sciter_app.value_to_asset(&site)

	p := sciter_app.asset_interface(inner, sciter_app.FRAGMENTED_VIDEO_DESTINATION_INAME)
	testing.expect(t, p != nil, "the engine's destination implements the fragmented interface")
	testing.expect(t, p != rawptr(inner), "and it is a different subobject from the som_asset_t")
}

// An interface the destination does not implement is nil, not a pointer to something else. The base
// "asset.sciter.com" name is in the list deliberately: `iasset`'s own default answers it, and the
// engine's override does *not* fall through to that default.
@(test)
test_unknown_interfaces_are_refused :: proc(t: ^testing.T) {
	_, root, ok := test_window(t)
	if !ok {return}

	screen, _ := sciter_app.select_first(root, "#screen")
	asset, _ := sciter_app.element_asset(screen, "video")
	site, _ := sciter_app.asset_call(asset, "renderingSite")
	defer sciter_app.value_clear(&site)
	inner, _ := sciter_app.value_to_asset(&site)

	for name in ([?]cstring{"source.video.sciter.com", "asset.sciter.com", "nope.sciter.com"}) {
		testing.expectf(t, sciter_app.asset_interface(inner, name) == nil, "%s is refused", name)
	}
	// and the two that are not
	testing.expect(t, sciter_app.asset_interface(inner, sciter_app.VIDEO_DESTINATION_INAME) != nil, "")
	testing.expect(t, sciter_app.asset_interface(inner, sciter_app.FRAGMENTED_VIDEO_DESTINATION_INAME) != nil, "")
}

// The whole chain, and the call that proves the vtable is laid out right: a wrong slot order would
// land `is_alive` on some other function and this would answer false, or crash.
@(test)
test_a_fresh_destination_is_alive :: proc(t: ^testing.T) {
	dest, ok := test_destination(t)
	if !ok {return}

	testing.expect(t, sciter_app.video_is_alive(dest), "a destination on a live element is alive")
}

// Streaming, start to finish. Each of these is a separate vtable slot, so a call answering false is
// the first sign of a layout that has drifted.
@(test)
test_frames_are_accepted :: proc(t: ^testing.T) {
	dest, ok := test_destination(t)
	if !ok {return}

	testing.expect(t, sciter_app.video_start_streaming(dest, FRAME_WIDTH, FRAME_HEIGHT, .RGB32), "start_streaming")
	testing.expect(t, sciter_app.video_is_alive(dest), "still alive once streaming")

	frame := background_frame(context.temp_allocator)
	testing.expect(t, sciter_app.video_render_frame(dest, frame), "a whole frame")

	stride := FRAME_WIDTH * size_of(Pixel)
	testing.expect(t, sciter_app.video_render_frame_with_stride(dest, frame, stride), "the same frame with its stride")

	source: Source
	source_init(&source)
	testing.expect(
		t,
		sciter_app.video_render_frame_part(dest, source_bytes(&source), 8, 8, PART_WIDTH, PART_HEIGHT),
		"and a part of one",
	)

	sciter_app.heartbeat()
	testing.expect(t, sciter_app.video_stop_streaming(dest), "stop_streaming")

	// Stopping does not kill the site - the element is still there, ready for another stream.
	testing.expect(t, sciter_app.video_is_alive(dest), "the site outlives the stream")
}

// An empty buffer is refused by the wrapper rather than handed to the engine, and a nil destination is
// false everywhere rather than a nil dereference.
@(test)
test_the_wrappers_refuse_nothing_to_render :: proc(t: ^testing.T) {
	testing.expect(t, !sciter_app.video_is_alive(nil), "nil is not alive")
	testing.expect(t, !sciter_app.video_start_streaming(nil, 1, 1), "nil cannot stream")
	testing.expect(t, !sciter_app.video_stop_streaming(nil), "nor stop")
	testing.expect(t, !sciter_app.video_render_frame(nil, []byte{1}), "nor render")
	testing.expect(t, !sciter_app.video_render_frame_part(nil, []byte{1}, 0, 0, 1, 1), "nor part-render")

	dest, ok := test_destination(t)
	if !ok {return}
	sciter_app.video_start_streaming(dest, FRAME_WIDTH, FRAME_HEIGHT, .RGB32)
	defer sciter_app.video_stop_streaming(dest)

	testing.expect(t, !sciter_app.video_render_frame(dest, nil), "an empty frame is refused here")
	testing.expect(t, !sciter_app.video_render_frame_part(dest, nil, 0, 0, 1, 1), "and an empty part")
}

// A reference of the caller's own, which is what a worker thread producing frames needs. The counter is
// the engine's; all this checks is that both slots are callable and the destination survives the pair.
@(test)
test_a_reference_can_be_taken_and_dropped :: proc(t: ^testing.T) {
	dest, ok := test_destination(t)
	if !ok {return}

	sciter_app.video_add_ref(dest)
	testing.expect(t, sciter_app.video_is_alive(dest), "alive while referenced")
	sciter_app.video_release(dest)
	testing.expect(t, sciter_app.video_is_alive(dest), "and after the reference is dropped")
}

// The zero-copy path, and the leak-or-not question that comes with it.
//
// `video_render_external_frame` does not copy: the buffer goes into a queue for upload to the GPU and
// the engine calls `release` when it is finished with it. If that callback never runs, a producer that
// allocates per frame leaks one buffer per frame - so **whether it is called at all is the thing worth
// pinning**, not the pixels.
//
// Measured: it is called, and by the time `video_stop_streaming` has returned every frame handed over
// has been released. The buffer here is `@(static)` rather than allocated, so that a release that
// never came would show up as a failed count rather than as a leak the test runner blames on something
// else.
@(private = "file")
Release_Log :: struct {
	count: int,
	data:  [^]byte,
	user:  rawptr,
}

@(private = "file")
g_released: Release_Log

@(private = "file")
on_frame_released :: proc "c" (data: [^]byte, user_data: rawptr) {
	// `proc "c"`, so no context - which is why this writes to a file-scope record rather than
	// allocating anything. It runs on the engine's thread and must not block.
	g_released.count += 1
	g_released.data = data
	g_released.user = user_data
}

@(test)
test_an_external_frame_is_released_when_the_engine_is_done_with_it :: proc(t: ^testing.T) {
	dest, ok := test_destination(t)
	if !ok {return}

	@(static) frame: [FRAME_WIDTH * FRAME_HEIGHT]Pixel
	for i in 0 ..< len(frame) {
		frame[i] = bgra(0x18, 0x18, 0x25)
	}
	bytes := ([^]byte)(&frame[0])[:len(frame) * size_of(Pixel)]

	g_released = {}
	marker := rawptr(uintptr(0xC0DE))

	testing.expect(t, sciter_app.video_start_streaming(dest, FRAME_WIDTH, FRAME_HEIGHT, .RGB32))

	stride := FRAME_WIDTH * size_of(Pixel)
	testing.expect(
		t,
		sciter_app.video_render_external_frame(dest, bytes, stride, on_frame_released, marker),
		"the engine accepted a frame it does not own",
	)

	// The release may be immediate or may wait for the upload, so give the engine a turn either way.
	sciter_app.heartbeat()
	testing.expect(t, sciter_app.video_stop_streaming(dest))
	sciter_app.heartbeat()

	testing.expect(t, g_released.count > 0, "the release callback must run or every frame leaks")
	testing.expect(t, g_released.data == raw_data(bytes), "and it hands back the buffer it was given")
	testing.expect_value(t, g_released.user, marker) // passed straight through, untouched

	testing.expect(t, sciter_app.video_is_alive(dest), "the site outlives the stream")
}

// The wrapper's own guards, which is where a nil `release` has to be caught: handing the engine a
// buffer with no way to say it is finished with it is the one mistake that cannot be undone.
@(test)
test_an_external_frame_without_a_release_callback_is_refused :: proc(t: ^testing.T) {
	testing.expect(
		t,
		!sciter_app.video_render_external_frame(nil, []byte{1}, 4, on_frame_released),
		"a nil destination is refused",
	)

	dest, ok := test_destination(t)
	if !ok {return}
	sciter_app.video_start_streaming(dest, FRAME_WIDTH, FRAME_HEIGHT, .RGB32)
	defer sciter_app.video_stop_streaming(dest)

	frame := background_frame(context.temp_allocator)
	stride := FRAME_WIDTH * size_of(Pixel)

	testing.expect(
		t,
		!sciter_app.video_render_external_frame(dest, frame, stride, nil),
		"without a release callback the buffer could never be reclaimed, so the wrapper refuses it",
	)
	testing.expect(
		t,
		!sciter_app.video_render_external_frame(dest, nil, stride, on_frame_released),
		"and an empty frame is refused the same way the copying calls refuse one",
	)
}
