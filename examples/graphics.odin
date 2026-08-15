// Drawing with the engine's own renderer: a custom-painted element, and an image rendered offscreen.
//
//   just example graphics
//   just example-test graphics
//
// Sciter's 2D API is a second function table reached through the main one, and it draws with the same
// renderer the engine paints documents with. Two things follow from that, and they are the whole
// example:
//
//   - **You never create a graphics context.** `gCreate`, which looks like it makes one from an image,
//     answers `.NOTSUPPORTED` on the vendored engine. The engine hands you one instead: through
//     `paint_image` for an offscreen image, or through the `.DRAW` event for an element on screen.
//   - **A `.DRAW` handler that returns true replaces that layer.** One repaint produces four events -
//     `.BACKGROUND`, `.CONTENT`, `.FOREGROUND`, `.OUTLINE` - and claiming one means the engine does not
//     paint it. Returning false draws over the engine's own painting instead. Measured both ways by
//     snapshotting the element with `image_from_element` and reading the pixels back.
//
// The dial below is drawn entirely in Odin, over a `<div>` that has nothing but a size in CSS. The
// swatch beside it was rendered offscreen into an image and handed to the document as a PNG through the
// host's resource callback - the same `SC_LOAD_DATA` hook `custom_loader` uses.
package main

import sciter ".."
import "../sciter_app"
// Used only by the macOS test bootstrap below, which lives inside a `when`. `-vet` sees an unused
// import on every other platform and `odin check -target:darwin_arm64` sees an undeclared name
// without it, so neither gate alone is enough - `@(require)` is what says "keep it". Same trap as
// `core:unicode/utf16` in api_map.odin.
@(require) import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"
import "core:time"

BASE_URL :: "res://app/"

DOC :: `<html>
<head><title>odin-sciter: graphics</title>
<style>
html { background:#1e1e2e; color:#cdd6f4; font:16px system; }
body { padding:2em; margin:0; }
h1 { color:#89b4fa; margin-top:0; }
#dial { width:200px; height:200px; }
img { width:120px; height:120px; vertical-align:top; }
.row { display:flex; gap:2em; align-items:flex-start; }
p { color:#a6adc8; }
</style></head>
<body>
  <h1>graphics</h1>
  <div class="row">
    <div id="dial"></div>
    <div>
      <img src="swatch.png" />
      <p>The dial is painted by Odin on every frame,<br/>through the element's DRAW events.</p>
      <p>The swatch was rendered offscreen into<br/>an image and served as a PNG.</p>
    </div>
  </div>
</body>
</html>`

App :: struct {
	host:    sciter_app.Host_Handler,
	handler: sciter_app.Event_Handler,
	swatch:  []u8, // the offscreen render, as PNG bytes
	angle:   f32,
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

	app: App
	app.started = time.now()

	// Offscreen first: no window is needed for this at all.
	swatch, serr := render_swatch(120)
	if serr != nil {
		fmt.eprintln("could not render the swatch:", serr)
		os.exit(1)
	}
	app.swatch = swatch
	defer delete(app.swatch)
	fmt.printfln("rendered a 120x120 swatch offscreen: %d bytes of PNG", len(app.swatch))

	window, werr := sciter_app.create_window({width = 720, height = 420})
	if werr != nil {
		fmt.eprintln("could not create a window:", werr)
		os.exit(1)
	}

	app.host = sciter_app.Host_Handler {
		on_load_data = on_load_data,
		user_data    = &app,
	}
	sciter_app.set_host_handler(window, &app.host)

	if err := sciter_app.load_html(window, DOC, BASE_URL); err != nil {
		fmt.eprintln("could not load the document:", err)
		os.exit(1)
	}

	root, _ := sciter_app.root(window)
	dial, derr := sciter_app.select_first(root, "#dial")
	if derr != nil {
		fmt.eprintln("no dial:", derr)
		os.exit(1)
	}

	app.handler = sciter_app.Event_Handler {
		subscription = {.DRAW},
		on_event     = on_event,
		user_data    = &app,
	}
	sciter_app.attach_handler(dial, &app.handler)

	sciter_app.show(window)

	// Animate by invalidating the element; each repaint delivers a fresh set of DRAW events.
	for sciter_app.run_once() {
		sciter_app.heartbeat()
		app.angle = f32(time.duration_seconds(time.since(app.started))) * 1.2
		sciter.api().SciterUpdateElement(sciter.Helement(dial), false)
	}

	sciter_app.shutdown()
}

// The document asks for res://app/swatch.png; the bytes were made in memory, so answer from memory.
on_load_data :: proc(handler: ^sciter_app.Host_Handler, request: ^sciter_app.Load_Request) -> sciter_app.Load_Result {
	app := (^App)(handler.user_data)
	if request.uri == BASE_URL + "swatch.png" {
		return sciter_app.serve_request(request, app.swatch, mime = "image/png")
	}
	return .OK
}

// ---------------------------------------------------------------------------------------------------
// The offscreen half

// Renders a colour wheel into a new image and encodes it as a PNG.
render_swatch :: proc(size: int) -> (png: []u8, err: Error) {
	img := sciter_app.create_image(size, size) or_return
	defer sciter_app.release_image(img)

	sciter_app.paint_image(img, paint_swatch) or_return
	return sciter_app.save_image(img, .PNG)
}

Error :: sciter_app.Error

paint_swatch :: proc(gfx: sciter_app.Graphics, width, height: u32, user: rawptr) {
	w, h := f32(width), f32(height)

	// A dark background, then twelve wedges around the centre.
	sciter_app.set_fill_color(gfx, sciter_app.rgb(0x31, 0x32, 0x44))
	sciter_app.set_line_color(gfx, sciter_app.rgb(0x31, 0x32, 0x44))
	sciter_app.draw_rect(gfx, 0, 0, w, h)

	cx, cy := w / 2, h / 2
	radius := min(w, h) / 2 - 4

	for i in 0 ..< 12 {
		t := f32(i) / 12
		hue := hue_color(t)

		sciter_app.set_fill_color(gfx, hue)
		sciter_app.set_line_color(gfx, hue)

		// Each wedge is a path: centre, out along one edge, round, and back.
		a0 := t * 2 * math.PI
		a1 := f32(i + 1) / 12 * 2 * math.PI

		path, perr := sciter_app.create_path()
		if perr != nil {
			continue
		}
		sciter_app.path_move_to(path, cx, cy)
		sciter_app.path_line_to(path, cx + radius * math.cos(a0), cy + radius * math.sin(a0))
		sciter_app.path_arc_to(path, cx + radius * math.cos(a1), cy + radius * math.sin(a1), 0, radius, radius)
		sciter_app.path_close(path)
		sciter_app.draw_path(gfx, path)
		sciter_app.release_path(path)
	}

	// A hole in the middle, in the document's background colour.
	sciter_app.set_fill_color(gfx, sciter_app.rgb(0x1e, 0x1e, 0x2e))
	sciter_app.set_line_color(gfx, sciter_app.rgb(0x1e, 0x1e, 0x2e))
	sciter_app.draw_ellipse(gfx, cx, cy, radius / 3, radius / 3)
}

// A cheap rainbow, good enough for a swatch.
hue_color :: proc(t: f32) -> sciter_app.Color {
	r := u8(clamp((math.sin(t * 2 * math.PI) * 0.5 + 0.5) * 255, 0, 255))
	g := u8(clamp((math.sin((t + 0.33) * 2 * math.PI) * 0.5 + 0.5) * 255, 0, 255))
	b := u8(clamp((math.sin((t + 0.66) * 2 * math.PI) * 0.5 + 0.5) * 255, 0, 255))
	return sciter_app.rgb(r, g, b)
}

// ---------------------------------------------------------------------------------------------------
// The onscreen half

on_event :: proc(handler: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	app := (^App)(handler.user_data)

	de, ok := sciter_app.draw_event(event)
	if !ok {
		return false
	}

	// One repaint is four events. This one draws the whole face on the content layer and leaves the
	// other three to the engine.
	if de.layer != .CONTENT {
		return false
	}

	x, y := f32(de.area.x), f32(de.area.y)
	w, h := f32(de.area.width), f32(de.area.height)
	cx, cy := x + w / 2, y + h / 2
	radius := min(w, h) / 2 - 6

	// The face: a radial gradient, then a rim.
	stops := []sciter_app.Color_Stop {
		{color = sciter_app.rgb(0x45, 0x47, 0x5a), offset = 0},
		{color = sciter_app.rgb(0x1e, 0x1e, 0x2e), offset = 1},
	}
	sciter_app.set_fill_gradient_radial(de.gfx, cx, cy, radius, radius, stops)
	sciter_app.set_line_color(de.gfx, sciter_app.rgb(0x58, 0x5b, 0x70))
	sciter_app.set_line_width(de.gfx, 2)
	sciter_app.draw_ellipse(de.gfx, cx, cy, radius, radius)

	// Ticks, drawn by rotating the world rather than doing the trigonometry twelve times.
	sciter_app.save_state(de.gfx)
	sciter_app.translate(de.gfx, cx, cy)
	sciter_app.set_line_color(de.gfx, sciter_app.rgb(0x6c, 0x70, 0x86))
	sciter_app.set_line_width(de.gfx, 2)
	for _ in 0 ..< 12 {
		sciter_app.draw_line(de.gfx, 0, -radius + 4, 0, -radius + 12)
		sciter_app.rotate(de.gfx, 2 * math.PI / 12)
	}
	sciter_app.restore_state(de.gfx)

	// The hand.
	sciter_app.save_state(de.gfx)
	sciter_app.translate(de.gfx, cx, cy)
	sciter_app.rotate(de.gfx, app.angle)
	sciter_app.set_fill_color(de.gfx, sciter_app.rgb(0xf3, 0x8b, 0xa8))
	sciter_app.set_line_color(de.gfx, sciter_app.rgb(0xf3, 0x8b, 0xa8))
	sciter_app.draw_polygon(de.gfx, [][2]f32{{-4, 0}, {0, -radius + 16}, {4, 0}})
	sciter_app.restore_state(de.gfx)

	// The hub.
	sciter_app.set_fill_color(de.gfx, sciter_app.rgb(0x89, 0xb4, 0xfa))
	sciter_app.set_line_color(de.gfx, sciter_app.rgb(0x89, 0xb4, 0xfa))
	sciter_app.draw_ellipse(de.gfx, cx, cy, 6, 6)

	// True: this layer is ours, the engine does not paint its own content underneath.
	return true
}

// ---------------------------------------------------------------------------------------------------
// Tests
//
// All of the drawing tests are headless. `paint_image` needs no window and no display, and `.RAW`
// encoding hands the pixels straight back, so a drawing test is "draw, save, read one pixel".

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

// RAW is 4 bytes per pixel. The order is the measurement in `save_image`'s doc comment, and this is
// where it is checked rather than assumed.
@(private = "file")
pixel :: proc(raw: []u8, width, x, y: int) -> [4]u8 {
	i := (y * width + x) * 4
	return {raw[i], raw[i + 1], raw[i + 2], raw[i + 3]}
}

@(private = "file")
BLUE :: [4]u8{255, 0, 0, 255} // pure blue, as RAW delivers it
@(private = "file")
RED :: [4]u8{0, 0, 255, 255}
@(private = "file")
GREEN :: [4]u8{0, 255, 0, 255}

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
	}
}

@(test)
test_graphics_api_table_resolves :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}
	testing.expect(t, sciter_app.graphics_api() != nil, "GetSciterGraphicsAPI must return a table")
}

// The claim in `save_image`: `.RAW` is blue, green, red, alpha - not the `[a,b,g,r]` the header says.
@(test)
test_raw_encoding_is_bgra :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	img, err := sciter_app.create_image(2, 2)
	testing.expect_value(t, err, nil)
	defer sciter_app.release_image(img)

	testing.expect_value(t, sciter_app.clear_image(img, sciter_app.rgb(255, 0, 0)), nil)

	raw, serr := sciter_app.save_image(img, .RAW)
	testing.expect_value(t, serr, nil)
	defer delete(raw)

	testing.expect_value(t, len(raw), 2 * 2 * 4)
	testing.expect_value(t, pixel(raw, 2, 0, 0), RED)
	testing.expect_value(t, pixel(raw, 2, 1, 1), RED)
}

@(test)
test_paint_image_draws_where_it_is_told :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	img, err := sciter_app.create_image(8, 8)
	testing.expect_value(t, err, nil)
	defer sciter_app.release_image(img)

	sciter_app.clear_image(img, sciter_app.rgb(0, 0, 0))

	// Fill the left half blue, and let the right half stay black.
	perr := sciter_app.paint_image(img, proc(gfx: sciter_app.Graphics, w, h: u32, user: rawptr) {
		sciter_app.set_fill_color(gfx, sciter_app.rgb(0, 0, 255))
		sciter_app.set_line_color(gfx, sciter_app.rgb(0, 0, 255))
		sciter_app.draw_rect(gfx, 0, 0, f32(w) / 2, f32(h))
		sciter_app.flush(gfx)
	})
	testing.expect_value(t, perr, nil)

	raw, serr := sciter_app.save_image(img, .RAW)
	testing.expect_value(t, serr, nil)
	defer delete(raw)

	testing.expect_value(t, pixel(raw, 8, 1, 4), BLUE)
	testing.expect_value(t, pixel(raw, 8, 6, 4), [4]u8{0, 0, 0, 255})
}

// The painter's `user` pointer is how a paint procedure gets anything other than the size.
@(test)
test_paint_image_passes_user_data :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	img, _ := sciter_app.create_image(4, 4)
	defer sciter_app.release_image(img)

	seen: struct {
		width, height: u32,
		called:        int,
	}
	err := sciter_app.paint_image(img, proc(gfx: sciter_app.Graphics, w, h: u32, user: rawptr) {
			s := (^struct {
					width, height: u32,
					called:        int,
				})(user)
			s.width, s.height = w, h
			s.called += 1
		}, &seen)

	testing.expect_value(t, err, nil)
	testing.expect_value(t, seen.called, 1)
	testing.expect_value(t, seen.width, u32(4))
	testing.expect_value(t, seen.height, u32(4))
}

// A path is built once and drawn into whatever context is current.
@(test)
test_path_fills_its_interior :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	img, _ := sciter_app.create_image(16, 16)
	defer sciter_app.release_image(img)
	sciter_app.clear_image(img, sciter_app.rgb(0, 0, 0))

	err := sciter_app.paint_image(
	img,
	proc(gfx: sciter_app.Graphics, w, h: u32, user: rawptr) {
		path, perr := sciter_app.create_path()
		if perr != nil {return}
		defer sciter_app.release_path(path)

		// A triangle over the top-left half.
		sciter_app.path_move_to(path, 0, 0)
		sciter_app.path_line_to(path, 16, 0)
		sciter_app.path_line_to(path, 0, 16)
		sciter_app.path_close(path)

		sciter_app.set_fill_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.set_line_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.draw_path(gfx, path)
		sciter_app.flush(gfx)
	},
	)
	testing.expect_value(t, err, nil)

	raw, _ := sciter_app.save_image(img, .RAW)
	defer delete(raw)

	testing.expect_value(t, pixel(raw, 16, 2, 2), GREEN) // inside
	testing.expect_value(t, pixel(raw, 16, 14, 14), [4]u8{0, 0, 0, 255}) // outside
}

// `save_state` / `restore_state` is the only way to undo a transform.
@(test)
test_transform_stack_restores :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	img, _ := sciter_app.create_image(16, 16)
	defer sciter_app.release_image(img)
	sciter_app.clear_image(img, sciter_app.rgb(0, 0, 0))

	err := sciter_app.paint_image(
	img,
	proc(gfx: sciter_app.Graphics, w, h: u32, user: rawptr) {
		// Translated: a blue square at (8,0) despite being drawn at the origin.
		sciter_app.save_state(gfx)
		sciter_app.translate(gfx, 8, 0)
		sciter_app.set_fill_color(gfx, sciter_app.rgb(0, 0, 255))
		sciter_app.set_line_color(gfx, sciter_app.rgb(0, 0, 255))
		sciter_app.draw_rect(gfx, 0, 0, 4, 4)
		sciter_app.restore_state(gfx)

		// Restored: a red square really at the origin.
		sciter_app.set_fill_color(gfx, sciter_app.rgb(255, 0, 0))
		sciter_app.set_line_color(gfx, sciter_app.rgb(255, 0, 0))
		sciter_app.draw_rect(gfx, 0, 0, 4, 4)
		sciter_app.flush(gfx)
	},
	)
	testing.expect_value(t, err, nil)

	raw, _ := sciter_app.save_image(img, .RAW)
	defer delete(raw)

	testing.expect_value(t, pixel(raw, 16, 1, 1), RED)
	testing.expect_value(t, pixel(raw, 16, 9, 1), BLUE)
}

@(test)
test_clip_limits_drawing :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	img, _ := sciter_app.create_image(16, 16)
	defer sciter_app.release_image(img)
	sciter_app.clear_image(img, sciter_app.rgb(0, 0, 0))

	err := sciter_app.paint_image(
	img,
	proc(gfx: sciter_app.Graphics, w, h: u32, user: rawptr) {
		sciter_app.push_clip_rect(gfx, 0, 0, 8, 8)
		sciter_app.set_fill_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.set_line_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.draw_rect(gfx, 0, 0, 16, 16) // asks for everything
		sciter_app.pop_clip(gfx)
		sciter_app.flush(gfx)
	},
	)
	testing.expect_value(t, err, nil)

	raw, _ := sciter_app.save_image(img, .RAW)
	defer delete(raw)

	testing.expect_value(t, pixel(raw, 16, 2, 2), GREEN) // inside the clip
	testing.expect_value(t, pixel(raw, 16, 12, 12), [4]u8{0, 0, 0, 255}) // outside it
}

// PNG out, PNG in: the encoder and the decoder agree, and the decoder is what a document uses when the
// bytes are served to it.
@(test)
test_png_round_trip :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	img, _ := sciter_app.create_image(6, 3)
	defer sciter_app.release_image(img)
	sciter_app.clear_image(img, sciter_app.rgb(0, 255, 0))

	png, err := sciter_app.save_image(img, .PNG)
	testing.expect_value(t, err, nil)
	defer delete(png)

	testing.expect(t, len(png) > 8)
	testing.expect_value(t, png[0], u8(0x89))
	testing.expect_value(t, string(png[1:4]), "PNG")

	back, lerr := sciter_app.load_image(png)
	testing.expect_value(t, lerr, nil)
	defer sciter_app.release_image(back)

	w, h, _, ierr := sciter_app.image_size(back)
	testing.expect_value(t, ierr, nil)
	testing.expect_value(t, w, 6)
	testing.expect_value(t, h, 3)

	raw, _ := sciter_app.save_image(back, .RAW)
	defer delete(raw)
	testing.expect_value(t, pixel(raw, 6, 3, 1), GREEN)
}

// Pixels in, pixels out, in the same order.
@(test)
test_image_from_pixels_round_trips :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	// 2x1, blue then red, in the BGRA order the engine hands back.
	pixels := []u8{255, 0, 0, 255, 0, 0, 255, 255}

	img, err := sciter_app.image_from_pixels(pixels, 2, 1)
	testing.expect_value(t, err, nil)
	defer sciter_app.release_image(img)

	raw, _ := sciter_app.save_image(img, .RAW)
	defer delete(raw)

	testing.expect_value(t, pixel(raw, 2, 0, 0), BLUE)
	testing.expect_value(t, pixel(raw, 2, 1, 0), RED)
}

// Nil handles are what an unchecked engine call would crash on.
@(test)
test_graphics_nil_handles_are_bad_param :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	bad := sciter_app.Error(sciter.Graphin_Result.BAD_PARAM)

	testing.expect_value(t, sciter_app.clear_image(nil, sciter_app.rgb(0, 0, 0)), bad)
	testing.expect_value(t, sciter_app.paint_image(nil, paint_swatch), bad)
	testing.expect_value(t, sciter_app.paint_image(sciter_app.Image(uintptr(1)), nil), bad)

	_, _, _, size_err := sciter_app.image_size(nil)
	testing.expect_value(t, size_err, bad)
	_, save_err := sciter_app.save_image(nil)
	testing.expect_value(t, save_err, bad)
	_, metrics_err := sciter_app.text_metrics(nil)
	testing.expect_value(t, metrics_err, bad)

	// Releasing nothing is not an error - it is what a `defer` does after a failed create.
	testing.expect_value(t, sciter_app.release_image(nil), nil)
	testing.expect_value(t, sciter_app.release_path(nil), nil)
	testing.expect_value(t, sciter_app.release_text(nil), nil)
	testing.expect_value(t, sciter_app.release_graphics(nil), nil)
}

// The DRAW accessor, decoded from a hand-built parameter struct - no window needed for this part.
@(test)
test_draw_event_decodes_its_parameters :: proc(t: ^testing.T) {
	params := sciter.Draw_Params {
		cmd = u32(sciter.Draw_Events.CONTENT),
		gfx = sciter.Hgfx(uintptr(0x3000)),
		area = {left = 5, top = 6, right = 25, bottom = 36},
	}

	de, ok := sciter_app.draw_event({group = {.DRAW}, params = &params})
	testing.expect(t, ok)
	testing.expect_value(t, de.layer, sciter.Draw_Events.CONTENT)
	testing.expect_value(t, de.gfx, sciter_app.Graphics(uintptr(0x3000)))
	testing.expect_value(t, de.area, sciter_app.Rect{x = 5, y = 6, width = 20, height = 30})
	testing.expect(t, de.raw == &params)

	mouse: sciter.Mouse_Params
	_, from_mouse := sciter_app.draw_event({group = {.MOUSE}, params = &mouse})
	testing.expect(t, !from_mouse, "draw_event must refuse a MOUSE event")

	_, no_params := sciter_app.draw_event({group = {.DRAW}, params = nil})
	testing.expect(t, !no_params)
}

// The example's own offscreen render, end to end: it has to produce a PNG a document could load.
@(test)
test_render_swatch_produces_a_png :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	png, err := render_swatch(32)
	testing.expect_value(t, err, nil)
	defer delete(png)

	testing.expect(t, len(png) > 100, "a 32x32 colour wheel should not encode to nothing")
	testing.expect_value(t, string(png[1:4]), "PNG")

	img, lerr := sciter_app.load_image(png)
	testing.expect_value(t, lerr, nil)
	defer sciter_app.release_image(img)

	w, h, _, _ := sciter_app.image_size(img)
	testing.expect_value(t, w, 32)
	testing.expect_value(t, h, 32)
}
