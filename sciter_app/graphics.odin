// Graphics: drawing with the engine's own 2D renderer.
//
// Sciter's graphics live in a second function table, `SciterGraphicsAPI`, reached through the main one.
// It is a small immediate-mode 2D API - colours, transforms, a state stack, paths, gradients, text and
// image blits - and it is the same renderer the engine paints documents with, so anything drawn here
// composites with the document rather than sitting on top of it.
//
// **You do not create a graphics context; the engine hands you one.** `gCreate`, the call that looks
// like it makes one from an image, answers `.NOTSUPPORTED` on the vendored 6.0.4.9 engine. The two ways
// in are:
//
//   - `paint_image(img, painter)` - the engine calls back with a `Graphics` for the whole image. This
//     is the offscreen path, and it works with no window and no display, which makes it testable.
//   - the `.DRAW` event on an element - `draw_event(event)` gives the `Graphics`, the layer being
//     painted and the element's area. This is the onscreen path: a custom-drawn control.
//
// Everything else - `Path`, `Text`, `Image` - is created directly and is independent of any context.
//
// **There is no pixel-readback slot to wrap.** `imageGetPixels` is declared in sciter-x-graphics.h and
// commented out there, so it is not in the table - `save_image(.RAW)` is the way to get pixels back out
// of an `Image`, and it is what the tests here use. See `docs/SDK-PARITY.md` for the rest of that
// accounting.
//
//	sciter_app.paint_image(img, proc(gfx: sciter_app.Graphics, width, height: u32, user: rawptr) {
//		sciter_app.set_fill_color(gfx, sciter_app.rgb(0x1e, 0x1e, 0x2e))
//		sciter_app.set_line_color(gfx, sciter_app.rgb(0x1e, 0x1e, 0x2e))
//		sciter_app.draw_rect(gfx, 0, 0, f32(width), f32(height))
//	})
package sciter_app

import sciter ".."
import "base:runtime"
import "core:fmt"

// The engine's HIMG, HGFX, HPATH and HTEXT. All four are reference counted; the `retain_*`/`release_*`
// pairs below are the engine's AddRef/Release.
//
// The two halves of each pair do not treat nil alike: `release_*(nil)` is `nil` here, because that is
// what a `defer` after a failed create does, but `retain_*(nil)` is the engine's `.BAD_PARAM`.
Image :: distinct sciter.Himg
Graphics :: distinct sciter.Hgfx
Path :: distinct sciter.Hpath
Text :: distinct sciter.Htext

// A colour, in the engine's own packed form. Build one with `rgba` or `rgb` rather than by hand: the
// packing is the engine's business and `RGBA` is a function in its table.
Color :: distinct sciter.Sc_Color

// A gradient stop. `offset` runs 0..1 along the gradient.
Color_Stop :: struct {
	color:  Color,
	offset: f32,
}

// Written on first use with a plain nil check and no synchronisation, which is correct only under
// this package's threading rule: **engine calls happen on the thread that runs the pump**
// (docs/architecture.md, and `post_callback` in host.odin is how a worker thread gets back onto
// it). A worker calling graphics_api() directly races here. The write is a single aligned pointer so
// it cannot tear on any target this builds for, and the worst outcome is fetching the table
// twice - but if the threading rule is ever relaxed, this is one of the two places to change.
@(private)
g_graphics_api: ^sciter.Sciter_Graphics_Api

// The raw `SciterGraphicsAPI` table, for anything this wrapper does not cover - `gGetNativeDC`, and the
// `vWrap*` family beyond the four wrappers below.
//
// Panics if `sciter.load()` has not been called, for the reason `sciter.api()` does: every consumer here
// calls straight through the returned table, so handing back nil only moves the fault to a
// function-pointer offset with nothing to say about the cause.
graphics_api :: proc(loc := #caller_location) -> ^sciter.Sciter_Graphics_Api {
	guard_engine_thread(loc)
	if g_graphics_api == nil && sciter.loaded() {
		g_graphics_api = sciter.api().GetSciterGraphicsAPI()
	}
	fmt.assertf(g_graphics_api != nil, "sciter.load() must be called before any graphics call", loc = loc)
	return g_graphics_api
}

// `GRAPHIN_OK` is 0 and `GRAPHIN_PANIC` is -1, so - unlike the DOM's - anything other than `.OK` here is
// a failure.
@(private)
gfx_err :: proc(r: sciter.Graphin_Result, loc := #caller_location) -> Error {
	guard_engine_thread(loc)
	return nil if r == .OK else r
}

// How the system's graphics rate for the engine's renderer.
//
// **Not a bitmask, despite the C name `pcaps` and the `UINT` it comes back in.** `sciter-x-def.h`
// documents it as an ordinal scale of exactly three values, which is what this enum is:
//
//	0 - no compatible graphics found;
//	1 - compatible graphics found but Direct2D will use WARP driver (software emulation);
//	2 - Direct2D will use hardware backend (best performance);
//
// Read that wording with its age in mind: it is written in terms of **Direct2D**, which predates this
// engine's Skia backend and does not exist on Linux or macOS at all. What the number means off Windows
// is not stated anywhere upstream. The vendored Linux build answers `.Software`, which is at least
// consistent with Sciter 6 defaulting to Skia's raster backend until a GPU layer is asked for - but
// that is a plausible reading of one measurement, not a documented guarantee.
//
// So: worth reading before assuming a feature exists, and worth printing in a bug report. Not worth
// branching on off Windows without checking what it actually reports there.
Graphics_Caps :: enum u32 {
	None     = 0, // no compatible graphics found
	Software = 1, // compatible, but rendering in software
	Hardware = 2, // hardware backend, best performance
}

// `ok` is the C call's own "was the pointer good" answer, false only if the engine could not report.
//
// A value outside the three documented ones is passed through as-is rather than being folded into
// `.None`: the engine is the authority on its own scale, and the SCROLL_EVENTS code the vendored header
// is missing (see `sciter_app/events.odin`) is the standing reminder that these lists can lag.
graphics_caps :: proc() -> (caps: Graphics_Caps, ok: bool) {
	raw: u32
	ok = bool(sciter.api().SciterGraphicsCaps(&raw))
	return Graphics_Caps(raw), ok
}

// ---------------------------------------------------------------------------------------------------
// Colours

// The packing is the engine's, and it is `r | g<<8 | b<<16 | a<<24` on this build - `rgba(1,2,3,4)`
// comes back as `0x04030201`. That is the *opposite* of the byte order `save_image(.RAW)` hands pixels
// back in, which is BGRA; a colour and a pixel are not interchangeable, so go through this call.
rgba :: proc(r, g, b, a: u8) -> Color {
	return Color(graphics_api().RGBA(u32(r), u32(g), u32(b), u32(a)))
}

rgb :: proc(r, g, b: u8) -> Color {
	return rgba(r, g, b, 255)
}

// ---------------------------------------------------------------------------------------------------
// Images

// An empty image, `width` x `height` pixels. `with_alpha` false makes it opaque.
create_image :: proc(width, height: int, with_alpha := true, loc := #caller_location) -> (image: Image, err: Error) {
	img: sciter.Himg
	gfx_err(graphics_api().imageCreate(&img, u32(width), u32(height), b32(with_alpha))) or_return
	track_acquire(.Image, rawptr(img), loc)
	return Image(img), nil
}

// An image built from pixels you already have.
//
// `.PREMUL_ALPHA` is what the engine composites with; `.IGNORE_ALPHA` treats the fourth byte as
// padding. The pixel layout is the engine's - see `save_image`'s note on `.RAW` for what that is.
image_from_pixels :: proc(
	pixels: []u8,
	width, height: int,
	format := sciter.Sciter_Pixmap_Format.PREMUL_ALPHA,
) -> (
	image: Image,
	err: Error,
) {
	if len(pixels) < width * height * 4 {
		return nil, sciter.Graphin_Result.BAD_PARAM
	}
	img: sciter.Himg
	gfx_err(graphics_api().imageCreateFromPixmap(&img, u32(width), u32(height), format, raw_data(pixels))) or_return
	track_acquire(.Image, rawptr(img))
	return Image(img), nil
}

// Decodes a PNG, JPEG or WEBP that is already in memory.
load_image :: proc(bytes: []u8) -> (image: Image, err: Error) {
	if len(bytes) == 0 {
		return nil, sciter.Graphin_Result.BAD_PARAM
	}
	img: sciter.Himg
	gfx_err(graphics_api().imageLoad(raw_data(bytes), u32(len(bytes)), &img)) or_return
	track_acquire(.Image, rawptr(img))
	return Image(img), nil
}

// A snapshot of how an element is currently painted, at its current size. The result carries an alpha
// channel, and the parts of the box the element does not paint are transparent in it.
//
// **Never call this from inside a `.DRAW` handler.** It produces the image by painting the element, so
// from within a paint it re-enters the paint that is already running and recurses until the stack is
// gone - measured at ~39,500 frames of the engine's own `do_draw` before the segfault. There is no
// error to check and nothing to catch. Take the snapshot between frames.
image_from_element :: proc(element: Element) -> (image: Image, err: Error) {
	img: sciter.Himg
	gfx_err(graphics_api().imageCreateFromElement(&img, sciter.Helement(element))) or_return
	track_acquire(.Image, rawptr(img))
	return Image(img), nil
}

image_size :: proc(image: Image) -> (width, height: int, has_alpha: bool, err: Error) {
	if image == nil {
		return 0, 0, false, sciter.Graphin_Result.BAD_PARAM
	}
	w, h: u32
	alpha: b32
	gfx_err(graphics_api().imageGetInfo(sciter.Himg(image), &w, &h, &alpha)) or_return
	return int(w), int(h), bool(alpha), nil
}

// Fills the whole image with one colour, discarding what was there.
clear_image :: proc(image: Image, color: Color) -> Error {
	if image == nil {
		return sciter.Graphin_Result.BAD_PARAM
	}
	return gfx_err(graphics_api().imageClear(sciter.Himg(image), sciter.Sc_Color(color)))
}

// Encodes the image, allocating the result in `allocator`.
//
// `quality` is 10..100 and applies to `.JPG` and `.WEBP` only.
//
// **`.RAW` is 4 bytes per pixel in blue, green, red, alpha order** - measured by clearing an image to
// pure red and reading the bytes back as `[0, 0, 255, 255]`. `sciter-x-graphics.h` says `[a,b,g,r]`,
// which does not match this engine. That makes `.RAW` the way to check drawing in a test: no decoder
// needed, and one pixel is one assertion.
save_image :: proc(
	image: Image,
	encoding := sciter.Sciter_Image_Encoding.PNG,
	quality: int = 90,
	allocator := context.allocator,
) -> (
	bytes: []u8,
	err: Error,
) {
	if image == nil {
		return nil, sciter.Graphin_Result.BAD_PARAM
	}
	// The scratch accumulates from the temp allocator, not the caller's: the engine delivers in chunks,
	// so this grows by doubling, and only the exact-size result below belongs to `allocator`. Growing
	// in the caller's allocator means peak memory of twice the encoded image - tens of megabytes for a
	// 4K PNG.
	//
	// **The allocator has to be on the dynamic array itself, not beside it.** A zero-valued `[dynamic]`
	// adopts `context.allocator` at its first `append` and never consults anything else, so a sink that
	// merely *carried* an allocator field left the doubling in the caller's allocator - measured - which
	// is the behaviour this comment is here to rule out.
	sink := Byte_Sink {
		ctx = context,
		out = make([dynamic]u8, 0, 0, context.temp_allocator),
	}
	defer delete(sink.out)

	gfx_err(graphics_api().imageSave(sciter.Himg(image), image_writer, &sink, u32(encoding), u32(quality))) or_return

	// The engine delivers in chunks, so the sink grows; hand back exactly what arrived.
	out := make([]u8, len(sink.out), allocator)
	copy(out, sink.out[:])
	return out, nil
}

// What `paint_image` calls. `user` is whatever was passed alongside it.
Painter :: proc(gfx: Graphics, width, height: u32, user: rawptr)

// Draws into an image, through a `Graphics` the engine creates for the call.
//
// This is the offscreen renderer, and the only way to get a context without a window: `gCreate` - the
// call that would make one from an image directly - answers `.NOTSUPPORTED` on this engine.
//
// The context is the engine's and is gone when the painter returns; the drawing stays in the image.
paint_image :: proc(image: Image, painter: Painter, user: rawptr = nil) -> Error {
	if image == nil || painter == nil {
		return sciter.Graphin_Result.BAD_PARAM
	}
	call := Paint_Call {
		ctx     = context,
		painter = painter,
		user    = user,
	}
	return gfx_err(graphics_api().imagePaint(sciter.Himg(image), paint_trampoline, &call))
}

retain_image :: proc(image: Image, loc := #caller_location) -> Error {
	err := gfx_err(graphics_api().imageAddRef(sciter.Himg(image)))
	if err == nil {
		track_acquire(.Image, rawptr(image), loc)
	}
	return err
}

release_image :: proc(image: Image) -> Error {
	if image == nil {
		return nil
	}
	err := gfx_err(graphics_api().imageRelease(sciter.Himg(image)))
	if err == nil {
		track_release(.Image, rawptr(image))
	}
	return err
}

// ---------------------------------------------------------------------------------------------------
// Graphics state
//
// The state stack holds the transform, the colours, the line width and the clip. `save_state` and
// `restore_state` are the only way to undo a transform - there is no "set the matrix to identity".
//
// **Pair them with `defer`. An unbalanced save kills the process.** A painter that returns with the
// stack still pushed aborts on the way out - `terminate called without an active exception` - with no
// error code anywhere to react to. The other direction is harmless: see `restore_state`.

save_state :: proc(gfx: Graphics, loc := #caller_location) -> Error {
	err := gfx_err(graphics_api().gStateSave(sciter.Hgfx(gfx)))
	if err == nil {
		track_acquire(.Graphics_State, rawptr(gfx), loc)
	}
	return err
}

// Pops the state stack.
//
// Restoring more often than you saved is answered `.OK` by this engine rather than `.FAILURE`, from an
// empty stack as well as past a matched pair, so it will never tell you the pairing is wrong that way
// round. Getting it wrong the other way is fatal - see `save_state`.
restore_state :: proc(gfx: Graphics) -> Error {
	err := gfx_err(graphics_api().gStateRestore(sciter.Hgfx(gfx)))
	if err == nil {
		track_release(.Graphics_State, rawptr(gfx))
	}
	return err
}

set_line_color :: proc(gfx: Graphics, color: Color) -> Error {
	return gfx_err(graphics_api().gLineColor(sciter.Hgfx(gfx), sciter.Sc_Color(color)))
}

set_fill_color :: proc(gfx: Graphics, color: Color) -> Error {
	return gfx_err(graphics_api().gFillColor(sciter.Hgfx(gfx), sciter.Sc_Color(color)))
}

set_line_width :: proc(gfx: Graphics, width: f32) -> Error {
	return gfx_err(graphics_api().gLineWidth(sciter.Hgfx(gfx), width))
}

set_line_join :: proc(gfx: Graphics, join: sciter.Sciter_Line_Join_Type) -> Error {
	return gfx_err(graphics_api().gLineJoin(sciter.Hgfx(gfx), join))
}

set_line_cap :: proc(gfx: Graphics, cap: sciter.Sciter_Line_Cap_Type) -> Error {
	return gfx_err(graphics_api().gLineCap(sciter.Hgfx(gfx), cap))
}

// `even_odd` false asks for the non-zero winding rule.
//
// **The vendored 6.0.4.9 engine answers `.NOTSUPPORTED` to both arguments and always fills even-odd.**
// Measured on a path of two nested squares wound the same way: non-zero would fill the pair solid,
// even-odd holes the inner one out, and the hole is there whatever this is set to. A shape that needs
// non-zero has to be built so that even-odd gives the same answer - which for the common case of a
// self-intersecting outline means winding the subpaths in opposite directions yourself.
set_fill_mode :: proc(gfx: Graphics, even_odd: bool) -> Error {
	return gfx_err(graphics_api().gFillMode(sciter.Hgfx(gfx), b32(even_odd)))
}

// A gradient replaces the flat fill colour until the colour is set again.
set_fill_gradient_linear :: proc(gfx: Graphics, x1, y1, x2, y2: f32, stops: []Color_Stop) -> Error {
	return gfx_err(
		graphics_api().gFillGradientLinear(
			sciter.Hgfx(gfx),
			x1,
			y1,
			x2,
			y2,
			(^sciter.Sc_Color_Stop)(raw_data(stops)),
			u32(len(stops)),
		),
	)
}

set_fill_gradient_radial :: proc(gfx: Graphics, x, y, rx, ry: f32, stops: []Color_Stop) -> Error {
	return gfx_err(
		graphics_api().gFillGradientRadial(
			sciter.Hgfx(gfx),
			x,
			y,
			rx,
			ry,
			(^sciter.Sc_Color_Stop)(raw_data(stops)),
			u32(len(stops)),
		),
	)
}

set_line_gradient_linear :: proc(gfx: Graphics, x1, y1, x2, y2: f32, stops: []Color_Stop) -> Error {
	return gfx_err(
		graphics_api().gLineGradientLinear(
			sciter.Hgfx(gfx),
			x1,
			y1,
			x2,
			y2,
			(^sciter.Sc_Color_Stop)(raw_data(stops)),
			u32(len(stops)),
		),
	)
}

set_line_gradient_radial :: proc(gfx: Graphics, x, y, rx, ry: f32, stops: []Color_Stop) -> Error {
	return gfx_err(
		graphics_api().gLineGradientRadial(
			sciter.Hgfx(gfx),
			x,
			y,
			rx,
			ry,
			(^sciter.Sc_Color_Stop)(raw_data(stops)),
			u32(len(stops)),
		),
	)
}

// ---------------------------------------------------------------------------------------------------
// Transforms

translate :: proc(gfx: Graphics, dx, dy: f32) -> Error {
	return gfx_err(graphics_api().gTranslate(sciter.Hgfx(gfx), dx, dy))
}

scale :: proc(gfx: Graphics, sx, sy: f32) -> Error {
	return gfx_err(graphics_api().gScale(sciter.Hgfx(gfx), sx, sy))
}

skew :: proc(gfx: Graphics, dx, dy: f32) -> Error {
	return gfx_err(graphics_api().gSkew(sciter.Hgfx(gfx), dx, dy))
}

// Rotates by `radians`, about the origin unless a centre is given.
rotate :: proc(gfx: Graphics, radians: f32, center: Maybe([2]f32) = nil) -> Error {
	if c, has := center.?; has {
		cx, cy := c.x, c.y
		return gfx_err(graphics_api().gRotate(sciter.Hgfx(gfx), radians, &cx, &cy))
	}
	return gfx_err(graphics_api().gRotate(sciter.Hgfx(gfx), radians, nil, nil))
}

// The full affine matrix, applied on top of the current transform.
transform :: proc(gfx: Graphics, m11, m12, m21, m22, dx, dy: f32) -> Error {
	return gfx_err(graphics_api().gTransform(sciter.Hgfx(gfx), m11, m12, m21, m22, dx, dy))
}

// Maps a point through the current transform, and back.
//
// **Both are no-ops on the vendored 6.0.4.9 engine.** They answer `.OK` and hand back the point
// unchanged under `translate`, `scale`, `rotate`, `skew` and `transform` alike - measured for each.
// Drawing *is* transformed correctly; only these two accessors ignore the matrix. So a widget that
// needs to hit-test a mouse position against a transformed shape has to keep its own matrix and invert
// it in Odin rather than asking the engine.
world_to_screen :: proc(gfx: Graphics, p: [2]f32) -> (out: [2]f32, err: Error) {
	x, y := p.x, p.y
	gfx_err(graphics_api().gWorldToScreen(sciter.Hgfx(gfx), &x, &y)) or_return
	return {x, y}, nil
}

screen_to_world :: proc(gfx: Graphics, p: [2]f32) -> (out: [2]f32, err: Error) {
	x, y := p.x, p.y
	gfx_err(graphics_api().gScreenToWorld(sciter.Hgfx(gfx), &x, &y)) or_return
	return {x, y}, nil
}

// ---------------------------------------------------------------------------------------------------
// Shapes
//
// Every one of these both fills with the fill colour and strokes with the line colour, so setting only
// one of the two leaves the other at whatever the previous drawing used. Set both.

draw_line :: proc(gfx: Graphics, x1, y1, x2, y2: f32) -> Error {
	return gfx_err(graphics_api().gLine(sciter.Hgfx(gfx), x1, y1, x2, y2))
}

draw_rect :: proc(gfx: Graphics, x1, y1, x2, y2: f32) -> Error {
	return gfx_err(graphics_api().gRectangle(sciter.Hgfx(gfx), x1, y1, x2, y2))
}

// Draws a rectangle with rounded corners.
//
// **The engine reads eight numbers, not four**: an `rx` and an `ry` for each corner, clockwise from the
// top-left. `gRoundedRectangle`'s parameter is named `radii8` in `sciter-x-graphics.h` and the header
// comment spells out `SC_DIM[8] - four rx/ry pairs`. Passing four - one per corner - hands the engine a
// pointer to four floats and it reads eight, so the last two corners come out of whatever was next on
// the stack. Measured: the radii were simply ignored and the rectangle came back square.
//
// The two forms below are the two things a caller means. `[4]f32` is one radius per corner and is
// expanded here; `[4][2]f32` is the engine's own `rx`/`ry` pairs, for elliptical corners.
draw_rounded_rect_uniform :: proc(gfx: Graphics, x1, y1, x2, y2: f32, radii: [4]f32) -> Error {
	pairs: [4][2]f32
	for r, i in radii {
		pairs[i] = {r, r}
	}
	return draw_rounded_rect_xy(gfx, x1, y1, x2, y2, pairs)
}

// `radii` is `{rx, ry}` per corner, clockwise from the top-left.
draw_rounded_rect_xy :: proc(gfx: Graphics, x1, y1, x2, y2: f32, radii: [4][2]f32) -> Error {
	r := radii
	return gfx_err(graphics_api().gRoundedRectangle(sciter.Hgfx(gfx), x1, y1, x2, y2, &r[0][0]))
}

draw_rounded_rect :: proc {
	draw_rounded_rect_uniform,
	draw_rounded_rect_xy,
}

draw_ellipse :: proc(gfx: Graphics, x, y, rx, ry: f32) -> Error {
	return gfx_err(graphics_api().gEllipse(sciter.Hgfx(gfx), x, y, rx, ry))
}

// Angles are radians, measured from the +x axis and sweeping towards +y - which is *down* on screen, so
// a positive sweep goes clockwise.
//
// Like every other shape here it fills as well as strokes, and **what it fills is the circular segment
// between the arc and its chord, not the pie wedge**: the centre of the ellipse stays unpainted.
// Measured with a quarter arc - the pixel at the centre is background, the one just inside the arc is
// filled. For a wedge, build a path: centre, line out, `path_arc_to`, close.
draw_arc :: proc(gfx: Graphics, x, y, rx, ry, start, sweep: f32) -> Error {
	return gfx_err(graphics_api().gArc(sciter.Hgfx(gfx), x, y, rx, ry, start, sweep))
}

// A star of `rays` points, alternating between radius `r1` and `r2`, the first point at `start` radians.
//
// **Broken on the vendored 6.0.4.9 engine: do not use it.** It answers `.OK` and paints a scatter of
// disconnected line fragments - never a closed outline, and never a fill, whatever the fill colour and
// line width are. Measured against the same star built by hand: 63 lit pixels out of 1024 against 353.
// It is deterministic, so it is the engine's geometry that is wrong rather than uninitialised memory.
// Any `rays` count, including 0, 1 and 2, is accepted without complaint.
//
// Build the outline yourself and hand it to `draw_polygon` - ten points for a five-pointed star,
// alternating the two radii. `graphics_gallery` has the loop.
draw_star :: proc(gfx: Graphics, x, y, r1, r2, start: f32, rays: int) -> Error {
	return gfx_err(graphics_api().gStar(sciter.Hgfx(gfx), x, y, r1, r2, start, u32(rays)))
}

draw_polygon :: proc(gfx: Graphics, points: [][2]f32) -> Error {
	if len(points) == 0 {
		return sciter.Graphin_Result.BAD_PARAM
	}
	return gfx_err(graphics_api().gPolygon(sciter.Hgfx(gfx), (^f32)(raw_data(points)), u32(len(points))))
}

// An *open* run of line segments: unlike `draw_polygon` it neither closes the last point back to the
// first nor fills the interior, whatever the fill colour is. Measured on a right angle - the polygon
// form paints the triangle solid, this one paints two strokes.
draw_polyline :: proc(gfx: Graphics, points: [][2]f32) -> Error {
	if len(points) == 0 {
		return sciter.Graphin_Result.BAD_PARAM
	}
	return gfx_err(graphics_api().gPolyline(sciter.Hgfx(gfx), (^f32)(raw_data(points)), u32(len(points))))
}

draw_path :: proc(gfx: Graphics, path: Path, mode := sciter.Draw_Path_Mode.FILL_AND_STROKE) -> Error {
	return gfx_err(graphics_api().gDrawPath(sciter.Hgfx(gfx), sciter.Hpath(path), mode))
}

// Blits an image. Without `size` it draws at its natural size; `source` takes a sub-rectangle of it,
// and `opacity` runs 0..1.
draw_image :: proc(
	gfx: Graphics,
	image: Image,
	x, y: f32,
	size: Maybe([2]f32) = nil,
	source: Maybe([4]int) = nil,
	opacity: Maybe(f32) = nil,
) -> Error {
	w, h: f32
	pw, ph: ^f32
	if s, has := size.?; has {
		w, h = s.x, s.y
		pw, ph = &w, &h
	}

	ix, iy, iw, ih: u32
	pix, piy, piw, pih: ^u32
	if s, has := source.?; has {
		ix, iy, iw, ih = u32(s[0]), u32(s[1]), u32(s[2]), u32(s[3])
		pix, piy, piw, pih = &ix, &iy, &iw, &ih
	}

	o: f32
	po: ^f32
	if v, has := opacity.?; has {
		o = v
		po = &o
	}

	return gfx_err(
		graphics_api().gDrawImage(sciter.Hgfx(gfx), sciter.Himg(image), x, y, pw, ph, pix, piy, piw, pih, po),
	)
}

// ---------------------------------------------------------------------------------------------------
// Clipping

// Clips to a rectangle until the matching `pop_clip`. `opacity` below 1 makes everything drawn inside
// the clip translucent.
push_clip_rect :: proc(gfx: Graphics, x1, y1, x2, y2: f32, opacity: f32 = 1) -> Error {
	return gfx_err(graphics_api().gPushClipBox(sciter.Hgfx(gfx), x1, y1, x2, y2, opacity))
}

push_clip_path :: proc(gfx: Graphics, path: Path, opacity: f32 = 1) -> Error {
	return gfx_err(graphics_api().gPushClipPath(sciter.Hgfx(gfx), sciter.Hpath(path), opacity))
}

pop_clip :: proc(gfx: Graphics) -> Error {
	return gfx_err(graphics_api().gPopClip(sciter.Hgfx(gfx)))
}

// Makes sure everything issued so far has reached the surface. The engine flushes when it needs to;
// this matters when you are about to read the image back.
flush :: proc(gfx: Graphics) -> Error {
	return gfx_err(graphics_api().gFlush(sciter.Hgfx(gfx)))
}

retain_graphics :: proc(gfx: Graphics) -> Error {
	return gfx_err(graphics_api().gAddRef(sciter.Hgfx(gfx)))
}

release_graphics :: proc(gfx: Graphics) -> Error {
	if gfx == nil {
		return nil
	}
	return gfx_err(graphics_api().gRelease(sciter.Hgfx(gfx)))
}

// ---------------------------------------------------------------------------------------------------
// Paths
//
// A path is built once and drawn many times, and it outlives any one context. `relative` on each
// segment means "from where the pen is" rather than "in path coordinates".

create_path :: proc(loc := #caller_location) -> (path: Path, err: Error) {
	p: sciter.Hpath
	gfx_err(graphics_api().pathCreate(&p)) or_return
	track_acquire(.Path, rawptr(p), loc)
	return Path(p), nil
}

path_move_to :: proc(path: Path, x, y: f32, relative := false) -> Error {
	return gfx_err(graphics_api().pathMoveTo(sciter.Hpath(path), x, y, b32(relative)))
}

path_line_to :: proc(path: Path, x, y: f32, relative := false) -> Error {
	return gfx_err(graphics_api().pathLineTo(sciter.Hpath(path), x, y, b32(relative)))
}

// An SVG-style elliptical arc to (x, y): the ellipse is `rx` by `ry`, rotated by `angle` radians, and
// the two flags are meant to pick which of the four possible arcs is intended.
//
// **On this engine there are two, not four, and one combination draws nothing.** Measured between two
// endpoints a quarter turn apart one way and three quarters the other:
//
//   - `clockwise = true,  large_arc = true`  - the long way round. Works.
//   - `clockwise = false, large_arc = false` - the short way round. Works.
//   - `clockwise = false, large_arc = true`  - the short way round again; `large_arc` is ignored.
//   - `clockwise = true,  large_arc = false` - **an empty path**. `.OK`, and nothing is drawn.
//
// So `clockwise` is what picks the arc, and `large_arc` has to agree with it. A path that silently
// paints nothing is usually this.
path_arc_to :: proc(
	path: Path,
	x, y, angle, rx, ry: f32,
	large_arc := false,
	clockwise := true,
	relative := false,
) -> Error {
	return gfx_err(
		graphics_api().pathArcTo(
			sciter.Hpath(path),
			x,
			y,
			angle,
			rx,
			ry,
			b32(large_arc),
			b32(clockwise),
			b32(relative),
		),
	)
}

path_quad_to :: proc(path: Path, cx, cy, x, y: f32, relative := false) -> Error {
	return gfx_err(graphics_api().pathQuadraticCurveTo(sciter.Hpath(path), cx, cy, x, y, b32(relative)))
}

path_bezier_to :: proc(path: Path, c1x, c1y, c2x, c2y, x, y: f32, relative := false) -> Error {
	return gfx_err(graphics_api().pathBezierCurveTo(sciter.Hpath(path), c1x, c1y, c2x, c2y, x, y, b32(relative)))
}

path_close :: proc(path: Path) -> Error {
	return gfx_err(graphics_api().pathClosePath(sciter.Hpath(path)))
}

retain_path :: proc(path: Path, loc := #caller_location) -> Error {
	err := gfx_err(graphics_api().pathAddRef(sciter.Hpath(path)))
	if err == nil {
		track_acquire(.Path, rawptr(path), loc)
	}
	return err
}

release_path :: proc(path: Path) -> Error {
	if path == nil {
		return nil
	}
	err := gfx_err(graphics_api().pathRelease(sciter.Hpath(path)))
	if err == nil {
		track_release(.Path, rawptr(path))
	}
	return err
}

// ---------------------------------------------------------------------------------------------------
// Text
//
// Text is laid out against an element, because that is where the font, size, colour and direction come
// from - there is no free-standing font object. The element only supplies the style; the text is not
// added to the document and the element is not modified.

// Lays `text` out with `element`'s own style, or with the style of `class_name` as it would apply to
// that element.
//
// A `class_name` that matches no rule is not an error - the text comes back in the element's own style.
// So is a nil element `.BAD_PARAM`, which is the only failure worth checking for.
create_text :: proc(element: Element, text: string, class_name := "") -> (out: Text, err: Error) {
	w := utf16_from_string(text, context.temp_allocator)
	class: [^]u16
	if class_name != "" {
		class = raw_data(utf16_from_string(class_name, context.temp_allocator))
	}
	t: sciter.Htext
	gfx_err(
		graphics_api().textCreateForElement(&t, raw_data(w), u32(len(w) - 1), sciter.Helement(element), class),
	) or_return
	track_acquire(.Text, rawptr(t))
	return Text(t), nil
}

// The same, with a style declaration instead of a class - "font-size: 24px; color: #f00".
//
// It is the same layout the class form gives for equivalent CSS: `create_text(el, s, "big")` against a
// `.big { font-size: 32px }` rule and `create_text_with_style(el, s, "font-size: 32px")` measure
// identically, down to the ascent.
//
// **Nonsense in the declaration is swallowed.** `"this is not css ;;;"` answers `.OK` with a usable
// handle laid out in the element's own style, so a typo in a style string shows up as text that is
// simply the wrong size rather than as an error.
create_text_with_style :: proc(element: Element, text: string, style: string) -> (out: Text, err: Error) {
	w := utf16_from_string(text, context.temp_allocator)
	s := utf16_from_string(style, context.temp_allocator)
	t: sciter.Htext
	gfx_err(
		graphics_api().textCreateForElementAndStyle(
			&t,
			raw_data(w),
			u32(len(w) - 1),
			sciter.Helement(element),
			raw_data(s),
			u32(len(s) - 1),
		),
	) or_return
	track_acquire(.Text, rawptr(t))
	return Text(t), nil
}

Text_Metrics :: struct {
	min_width: f32, // width if wrapped as tightly as it can be
	max_width: f32, // width if not wrapped at all
	height:    f32,
	ascent:    f32,
	descent:   f32,
	lines:     int,
}

text_metrics :: proc(text: Text) -> (metrics: Text_Metrics, err: Error) {
	if text == nil {
		return {}, sciter.Graphin_Result.BAD_PARAM
	}
	lines: u32
	gfx_err(
		graphics_api().textGetMetrics(
			sciter.Htext(text),
			&metrics.min_width,
			&metrics.max_width,
			&metrics.height,
			&metrics.ascent,
			&metrics.descent,
			&lines,
		),
	) or_return
	metrics.lines = int(lines)
	return metrics, nil
}

// Asks for the text to be wrapped into a box.
//
// **A no-op on the vendored 6.0.4.9 engine.** It answers `.OK` and nothing moves: `text_metrics`
// reports the same `min_width`, `max_width` and `lines = 1` for every width from 200 down to 20 on a
// string whose tightest wrap is 35 wide, and the pixels `draw_text` puts down are identical with and
// without it. Text laid out through this API is one line, so anything that has to wrap has to be split
// into several `Text` objects and drawn a line at a time.
set_text_box :: proc(text: Text, width, height: f32) -> Error {
	return gfx_err(graphics_api().textSetBox(sciter.Htext(text), width, height))
}

// Where (x, y) sits relative to the text block.
//
// **The numbers are a numeric keypad, not reading order** - `sciter-x-graphics.h` says "position (1..9
// on MUMPAD)", so 7/8/9 is the *top* row and 1/2/3 the bottom, the way the keys are arranged. This
// package had them upside down until it was measured: drawing at `1` put the text above the point, not
// below it. The horizontal half was right either way, which is what let it go unnoticed.
Text_Anchor :: enum u32 {
	Bottom_Left   = 1,
	Bottom_Center = 2,
	Bottom_Right  = 3,
	Middle_Left   = 4,
	Middle_Center = 5,
	Middle_Right  = 6,
	Top_Left      = 7,
	Top_Center    = 8,
	Top_Right     = 9,
}

draw_text :: proc(gfx: Graphics, text: Text, x, y: f32, anchor := Text_Anchor.Top_Left) -> Error {
	return gfx_err(graphics_api().gDrawText(sciter.Hgfx(gfx), sciter.Htext(text), x, y, u32(anchor)))
}

retain_text :: proc(text: Text, loc := #caller_location) -> Error {
	err := gfx_err(graphics_api().textAddRef(sciter.Htext(text)))
	if err == nil {
		track_acquire(.Text, rawptr(text), loc)
	}
	return err
}

release_text :: proc(text: Text) -> Error {
	if text == nil {
		return nil
	}
	err := gfx_err(graphics_api().textRelease(sciter.Htext(text)))
	if err == nil {
		track_release(.Text, rawptr(text))
	}
	return err
}

// ---------------------------------------------------------------------------------------------------
// Handing graphics to script
//
// Wrapped handles arrive in script as `Graphics`, `Image`, `Path` and `Text` objects, so an Odin
// procedure exposed with `value_from_function` can take or return them. The wrapped `Value` is a
// `.RESOURCE`, and clearing it releases the reference it holds.
//
// Two measured rules apply to all eight:
//
//   - **`value_to_*` does not fail on the wrong type. Check the handle, not the error.** Unwrapping a
//     `Value` holding an integer answers `.OK` and a nil handle - so code that only tests `err` walks
//     off with nothing and finds out at the next call. Every `value_to_*` here can hand back
//     `nil, nil`.
//   - `value_from_*` of a nil handle is `.BAD_PARAM` and leaves the `Value` `.UNDEFINED`.
//
// The wrap does add a reference: clearing the `Value` leaves the original handle usable.

value_from_graphics :: proc(gfx: Graphics) -> (v: Value, err: Error) {
	value_init(&v)
	gfx_err(graphics_api().vWrapGfx(sciter.Hgfx(gfx), &v)) or_return
	return tracked(v), nil
}

value_from_image :: proc(image: Image) -> (v: Value, err: Error) {
	value_init(&v)
	gfx_err(graphics_api().vWrapImage(sciter.Himg(image), &v)) or_return
	return tracked(v), nil
}

value_from_path :: proc(path: Path) -> (v: Value, err: Error) {
	value_init(&v)
	gfx_err(graphics_api().vWrapPath(sciter.Hpath(path), &v)) or_return
	return tracked(v), nil
}

value_from_text :: proc(text: Text) -> (v: Value, err: Error) {
	value_init(&v)
	gfx_err(graphics_api().vWrapText(sciter.Htext(text), &v)) or_return
	return tracked(v), nil
}

value_to_graphics :: proc(v: ^Value) -> (gfx: Graphics, err: Error) {
	h: sciter.Hgfx
	gfx_err(graphics_api().vUnWrapGfx(v, &h)) or_return
	return Graphics(h), nil
}

value_to_image :: proc(v: ^Value) -> (image: Image, err: Error) {
	h: sciter.Himg
	gfx_err(graphics_api().vUnWrapImage(v, &h)) or_return
	return Image(h), nil
}

value_to_path :: proc(v: ^Value) -> (path: Path, err: Error) {
	h: sciter.Hpath
	gfx_err(graphics_api().vUnWrapPath(v, &h)) or_return
	return Path(h), nil
}

value_to_text :: proc(v: ^Value) -> (text: Text, err: Error) {
	h: sciter.Htext
	gfx_err(graphics_api().vUnWrapText(v, &h)) or_return
	return Text(h), nil
}

// ---------------------------------------------------------------------------------------------------
// The callbacks the engine makes into this package.

@(private = "file")
Paint_Call :: struct {
	ctx:     runtime.Context,
	painter: Painter,
	user:    rawptr,
}

@(private = "file")
paint_trampoline :: proc "system" (prm: rawptr, gfx: sciter.Hgfx, width, height: u32) {
	call := (^Paint_Call)(prm)
	context = call.ctx
	call.painter(Graphics(gfx), width, height, call.user)
}

// No `allocator` field: `out` carries its own, set by `save_image`. One beside it would be read by
// nothing - see the note there.
@(private = "file")
Byte_Sink :: struct {
	ctx: runtime.Context,
	out: [dynamic]u8,
}

@(private = "file")
image_writer :: proc "system" (prm: rawptr, data: [^]u8, n: u32) -> b32 {
	sink := (^Byte_Sink)(prm)
	context = sink.ctx
	if data == nil || n == 0 {
		return true
	}
	append(&sink.out, ..data[:n])
	return true
}
