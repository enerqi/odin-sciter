// A reference page for the 2D renderer: every shape, gradient, transform, clip, path and text call in
// `sciter_app/graphics.odin`, drawn once and asserted once.
//
//   just example graphics_gallery
//   just example-test graphics_gallery
//
// `examples/graphics.odin` teaches the two ways *into* the renderer - `paint_image` offscreen and the
// `.DRAW` event on screen. This one assumes you have read that and answers the next question, which is
// "what does each call actually do". Each panel below is one topic, painted by Odin into an element the
// stylesheet asked for by name, and each has a headless test that draws the same thing into an image
// and reads the pixels back.
//
// Nine things were measured on the vendored 6.0.4.9 engine while writing it. Five of them are the
// engine being wrong, and two were bugs in this package's own wrappers:
//
//  1. **`draw_rounded_rect` was passing four numbers where the engine reads eight.** `gRoundedRectangle`
//     takes `SC_DIM[8]` - an `rx` and an `ry` per corner - and the wrapper handed it a `[4]f32`, so the
//     engine read four floats of whatever was next on the stack and the corners came out square. Fixed:
//     the wrapper is now a proc group taking either `[4]f32` (one radius per corner) or `[4][2]f32`
//     (the engine's pairs). Corner order is clockwise from the top-left, confirmed one corner at a time.
//
//  2. **`Text_Anchor` was upside down.** The header says "position (1..9 on MUMPAD)", and a numeric
//     keypad puts 7/8/9 on the *top* row - so 1 is bottom-left, not top-left. Drawing at `.Top_Left`
//     put the text above the point. All nine were measured; the horizontal half had always been right,
//     which is why it survived.
//
//  3. **`set_fill_mode` answers `.NOTSUPPORTED` and the renderer is always even-odd.** Two nested
//     squares wound the same way come out with a hole in the middle whichever rule is asked for.
//
//  4. **`world_to_screen` and `screen_to_world` ignore the transform.** They answer `.OK` and hand the
//     point straight back under translate, scale, rotate, skew and a full matrix alike. Drawing *is*
//     transformed correctly - it is only these two accessors that lie.
//
//  5. **`draw_star` is broken.** `.OK`, and a scatter of disconnected fragments that never closes and
//     never fills: 63 lit pixels against 353 for the same star built by hand. Deterministic, so it is
//     the geometry and not uninitialised memory. Build the ten points yourself and use `draw_polygon`.
//
//  6. **`set_text_box` does nothing.** Every width from 200 down to 20 leaves `lines = 1` and the
//     metrics untouched on a string whose tightest wrap is 35 wide, and the drawn pixels are identical.
//     Text through this API is one line.
//
//  7. **`draw_arc` fills the segment, not the wedge.** The chord closes the shape, so the centre of the
//     ellipse stays unpainted. A pie slice needs a path.
//
//  8. **`value_to_image` and friends do not fail on the wrong type.** Unwrapping a `Value` holding an
//     integer answers `.OK` and a nil handle. Check the handle, not the error.
//
//  9. **`retain_*(nil)` is `.BAD_PARAM` but `release_*(nil)` is fine** - the wrappers guard release
//     because that is what a `defer` after a failed create does, and do not guard retain.
//
// Everything else behaved: gradients, caps, joins, clips, the transform stack, `draw_image`'s scaling
// and opacity, and all eight `value_from_*`/`value_to_*` round trips.
package main

import sciter ".."
import "../sciter_app"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"

// Every panel is a `<div class="cell">` whose `data-demo` picks the painter. The behavior name is what
// wires them to Odin - see `named_behavior.odin` for that mechanism on its own.
DOC :: `<html>
<head><title>odin-sciter: graphics gallery</title>
<style>
html  { background:#1e1e2e; color:#cdd6f4; font:14px system; }
body  { padding:1.2em; margin:0; }
h1    { color:#89b4fa; margin:0 0 .2em 0; font-size:20px; }
p.sub { color:#a6adc8; margin:0 0 1em 0; }
.grid { display:flex; flex-flow:row wrap; gap:14px; }
figure     { margin:0; width:150px; }
figcaption { color:#a6adc8; font-size:12px; margin-top:.3em; }
.cell { behavior: gallery-cell; display:block; width:150px; height:110px;
        background:#181825; border:1px solid #313244; border-radius:5px; }
.badge { font-size:32px; color:#f38ba8; }
</style></head>
<body>
  <h1>graphics gallery</h1>
  <p class="sub">every panel is painted by Odin through the element's DRAW events</p>
  <div class="grid">
    <figure><div class="cell" data-demo="gradients"/><figcaption>fill &amp; line gradients</figcaption></figure>
    <figure><div class="cell" data-demo="caps"/><figcaption>line caps and joins</figcaption></figure>
    <figure><div class="cell" data-demo="rounded"/><figcaption>rounded corners, rx/ry</figcaption></figure>
    <figure><div class="cell" data-demo="transforms"/><figcaption>scale, skew, matrix</figcaption></figure>
    <figure><div class="cell" data-demo="arcs"/><figcaption>arc: segment, not wedge</figcaption></figure>
    <figure><div class="cell" data-demo="stars"/><figcaption>draw_star vs a polygon</figcaption></figure>
    <figure><div class="cell" data-demo="curves"/><figcaption>quadratic vs cubic</figcaption></figure>
    <figure><div class="cell" data-demo="clip"/><figcaption>clipping to a path</figcaption></figure>
    <figure><div class="cell" data-demo="images"/><figcaption>draw_image: size, opacity</figcaption></figure>
    <figure><div class="cell" data-demo="text"/><figcaption>text anchors (numpad)</figcaption></figure>
  </div>
</body>
</html>`

Error :: sciter_app.Error
Gfx :: sciter_app.Graphics
Color :: sciter_app.Color

INK :: 0
PAPER :: 1

// ---------------------------------------------------------------------------------------------------
// The panels
//
// Each painter takes a context rather than a `Graphics` alone, because the offscreen tests draw the
// same panels into a plain image where there is no element and no `.DRAW` area. `element` is nil there,
// and the two panels that need one (`text`, and the snapshot half of `images`) say so.

Panel :: struct {
	gfx:        Gfx,
	x, y, w, h: f32,
	element:    sciter_app.Element, // nil offscreen
	sprite:     sciter_app.Image, // the 8x8 test image the `images` panel blits
}

Painter :: proc(p: Panel)

// The table the document's `data-demo` is looked up in, and the list the tests walk.
DEMOS := [?]struct {
	name:    string,
	painter: Painter,
} {
	{"gradients", paint_gradients},
	{"caps", paint_caps},
	{"rounded", paint_rounded},
	{"transforms", paint_transforms},
	{"arcs", paint_arcs},
	{"stars", paint_stars},
	{"curves", paint_curves},
	{"clip", paint_clip},
	{"images", paint_images},
	{"text", paint_text},
}

// Both gradient families, fill and line. A gradient replaces the flat colour until the colour is set
// again, which is why each block sets what it is about to use rather than relying on what came before.
paint_gradients :: proc(p: Panel) {
	stops := []sciter_app.Color_Stop {
		{color = sciter_app.rgb(0xf3, 0x8b, 0xa8), offset = 0},
		{color = sciter_app.rgb(0x89, 0xb4, 0xfa), offset = 1},
	}

	// A linear fill across the top strip. The gradient's coordinates are the same space the shape is
	// drawn in, so it runs edge to edge rather than being relative to the rectangle.
	sciter_app.set_fill_gradient_linear(p.gfx, p.x, p.y, p.x + p.w, p.y, stops)
	sciter_app.set_line_width(p.gfx, 0)
	sciter_app.draw_rect(p.gfx, p.x, p.y, p.x + p.w, p.y + p.h * 0.3)

	// A radial fill below it, centred in its own half.
	cx, cy := p.x + p.w * 0.28, p.y + p.h * 0.68
	sciter_app.set_fill_gradient_radial(p.gfx, cx, cy, p.h * 0.28, p.h * 0.28, stops)
	sciter_app.draw_ellipse(p.gfx, cx, cy, p.h * 0.28, p.h * 0.28)

	// The same two applied to the *line* instead: a thick stroke picks up the gradient along its run.
	// The gradient's own coordinates are the ones the shape is drawn in, so they have to span the
	// stroke to be visible - a gradient shorter than the line clamps to its end colours.
	sciter_app.set_fill_color(p.gfx, sciter_app.rgba(0, 0, 0, 0))
	sciter_app.set_line_width(p.gfx, 7)
	x0, x1 := p.x + p.w * 0.52, p.x + p.w - 6
	sciter_app.set_line_gradient_linear(p.gfx, x0, p.y, x1, p.y, stops)
	sciter_app.draw_line(p.gfx, x0, p.y + p.h * 0.55, x1, p.y + p.h * 0.55)

	sciter_app.set_line_gradient_radial(p.gfx, (x0 + x1) / 2, p.y + p.h * 0.82, (x1 - x0) / 2, 8, stops)
	sciter_app.draw_line(p.gfx, x0, p.y + p.h * 0.82, x1, p.y + p.h * 0.82)
}

// Caps decide what happens past the end of a stroke; joins decide what happens at a corner. Both are
// only visible on a thick line, which is why the widths here are absurd.
paint_caps :: proc(p: Panel) {
	sciter_app.set_line_width(p.gfx, 9)

	caps := [?]sciter.Sciter_Line_Cap_Type{.BUTT, .SQUARE, .ROUND}
	for cap, i in caps {
		sciter_app.set_line_color(p.gfx, sciter_app.rgb(0x89, 0xb4, 0xfa))
		sciter_app.set_line_cap(p.gfx, cap)
		y := p.y + 14 + f32(i) * 16
		sciter_app.draw_line(p.gfx, p.x + 18, y, p.x + 62, y)
	}

	joins := [?]sciter.Sciter_Line_Join_Type{.MITER, .ROUND, .BEVEL}
	for join, i in joins {
		sciter_app.set_line_color(p.gfx, sciter_app.rgb(0xa6, 0xe3, 0xa1))
		sciter_app.set_line_join(p.gfx, join)
		x := p.x + 84 + f32(i) * 20
		// A right angle: the join is the outside of the corner.
		sciter_app.draw_polyline(
			p.gfx,
			[][2]f32{{x, p.y + 76}, {x, p.y + 34 + f32(i) * 10}, {x + 14, p.y + 34 + f32(i) * 10}},
		)
	}

	// The reason `draw_polyline` is used above and not `draw_polygon`: it does not close, and it does
	// not fill. The outline below is the same three points drawn as a polygon, and it is solid.
	sciter_app.set_line_width(p.gfx, 1)
	sciter_app.set_line_color(p.gfx, sciter_app.rgb(0x58, 0x5b, 0x70))
	sciter_app.set_fill_color(p.gfx, sciter_app.rgb(0x45, 0x47, 0x5a))
	sciter_app.draw_polygon(p.gfx, [][2]f32{{p.x + 18, p.y + 96}, {p.x + 46, p.y + 96}, {p.x + 18, p.y + 76}})
}

// The corner radii, one corner at a time and then an elliptical pair. Index 0 is the top-left and they
// run clockwise - measured, because a wrong guess here is invisible until somebody looks closely.
paint_rounded :: proc(p: Panel) {
	sciter_app.set_line_width(p.gfx, 1)
	sciter_app.set_line_color(p.gfx, sciter_app.rgb(0x89, 0xb4, 0xfa))
	sciter_app.set_fill_color(p.gfx, sciter_app.rgb(0x31, 0x32, 0x44))

	// One radius per corner, expanded to rx = ry by the wrapper.
	sciter_app.draw_rounded_rect(p.gfx, p.x + 10, p.y + 10, p.x + 68, p.y + 52, [4]f32{16, 0, 16, 0})

	// The engine's own form: {rx, ry} per corner, so the corners can be elliptical.
	sciter_app.set_line_color(p.gfx, sciter_app.rgb(0xf9, 0xe2, 0xaf))
	sciter_app.draw_rounded_rect(
		p.gfx,
		p.x + 82,
		p.y + 10,
		p.x + 140,
		p.y + 52,
		[4][2]f32{{26, 8}, {26, 8}, {0, 0}, {0, 0}},
	)

	// A pill: a radius larger than half the side is clamped to it rather than refused.
	sciter_app.set_line_color(p.gfx, sciter_app.rgb(0xa6, 0xe3, 0xa1))
	sciter_app.draw_rounded_rect(p.gfx, p.x + 10, p.y + 66, p.x + 140, p.y + 96, [4]f32{40, 40, 40, 40})
}

// `save_state`/`restore_state` is the only way back to the identity matrix, so every block here is
// wrapped in a pair. Note what is *not* here: `world_to_screen`, because it does not work.
paint_transforms :: proc(p: Panel) {
	sciter_app.set_line_width(p.gfx, 0)

	// scale: a 12x12 square drawn at the origin comes out 36x18.
	sciter_app.save_state(p.gfx)
	sciter_app.translate(p.gfx, p.x + 10, p.y + 12)
	sciter_app.scale(p.gfx, 3, 1.5)
	sciter_app.set_fill_color(p.gfx, sciter_app.rgb(0x89, 0xb4, 0xfa))
	sciter_app.draw_rect(p.gfx, 0, 0, 12, 12)
	sciter_app.restore_state(p.gfx)

	// skew: the same square, leaned over. `dx` slides x by y.
	sciter_app.save_state(p.gfx)
	sciter_app.translate(p.gfx, p.x + 62, p.y + 12)
	sciter_app.skew(p.gfx, 0.7, 0)
	sciter_app.set_fill_color(p.gfx, sciter_app.rgb(0xf9, 0xe2, 0xaf))
	sciter_app.draw_rect(p.gfx, 0, 0, 24, 24)
	sciter_app.restore_state(p.gfx)

	// The full matrix, applied on top of the current transform rather than replacing it - which is why
	// the translate before it still counts.
	sciter_app.save_state(p.gfx)
	sciter_app.translate(p.gfx, p.x + 16, p.y + 56)
	sciter_app.transform(p.gfx, 1, 0.35, -0.35, 1, 0, 0)
	sciter_app.set_fill_color(p.gfx, sciter_app.rgb(0xa6, 0xe3, 0xa1))
	sciter_app.draw_rect(p.gfx, 0, 0, 30, 30)
	sciter_app.restore_state(p.gfx)

	// rotate, about a centre this time rather than about the origin.
	sciter_app.save_state(p.gfx)
	sciter_app.set_fill_color(p.gfx, sciter_app.rgb(0xf3, 0x8b, 0xa8))
	sciter_app.rotate(p.gfx, math.PI / 6, [2]f32{p.x + 108, p.y + 74})
	sciter_app.draw_rect(p.gfx, p.x + 92, p.y + 58, p.x + 124, p.y + 90)
	sciter_app.restore_state(p.gfx)
}

// `draw_arc` closes with a chord, so what it fills is the segment. The wedge beside it is a path, which
// is the only way to get one.
paint_arcs :: proc(p: Panel) {
	cx, cy := p.x + 40, p.y + 55
	r := f32(34)

	sciter_app.set_fill_color(p.gfx, sciter_app.rgb(0x89, 0xb4, 0xfa))
	sciter_app.set_line_color(p.gfx, sciter_app.rgb(0xcd, 0xd6, 0xf4))
	sciter_app.set_line_width(p.gfx, 1)
	// Angles run from +x towards +y, and +y is down - so a positive sweep is clockwise on screen.
	sciter_app.draw_arc(p.gfx, cx, cy, r, r, -math.PI / 2, math.PI * 1.2)

	// The same span as a wedge: centre, out, round, close.
	wx, wy := p.x + 110, p.y + 55
	path, err := sciter_app.create_path()
	if err != nil {
		return
	}
	defer sciter_app.release_path(path)

	a0, a1 := f32(-math.PI / 2), f32(-math.PI / 2 + math.PI * 1.2)
	sciter_app.path_move_to(path, wx, wy)
	sciter_app.path_line_to(path, wx + r * math.cos(a0), wy + r * math.sin(a0))
	// `large_arc` picks which of the two arcs between the endpoints is meant - past a half turn it has
	// to be true or the short way round is drawn instead.
	sciter_app.path_arc_to(path, wx + r * math.cos(a1), wy + r * math.sin(a1), 0, r, r, large_arc = true)
	sciter_app.path_close(path)

	sciter_app.set_fill_color(p.gfx, sciter_app.rgb(0xa6, 0xe3, 0xa1))
	sciter_app.draw_path(p.gfx, path, .FILL_AND_STROKE)
}

// Left: what the engine's `draw_star` paints. Right: the same star, ten points and `draw_polygon`.
// This panel exists to be looked at - the difference is the whole point.
paint_stars :: proc(p: Panel) {
	sciter_app.set_fill_color(p.gfx, sciter_app.rgb(0xf3, 0x8b, 0xa8))
	sciter_app.set_line_color(p.gfx, sciter_app.rgb(0xf3, 0x8b, 0xa8))
	sciter_app.set_line_width(p.gfx, 1)
	sciter_app.draw_star(p.gfx, p.x + 40, p.y + 55, 36, 16, 0, 5)

	sciter_app.set_fill_color(p.gfx, sciter_app.rgb(0xa6, 0xe3, 0xa1))
	sciter_app.set_line_color(p.gfx, sciter_app.rgb(0xa6, 0xe3, 0xa1))
	pts := star_points(p.x + 110, p.y + 55, 36, 16, 5)
	sciter_app.draw_polygon(p.gfx, pts[:])
}

// The ten points of a five-pointed star, alternating the two radii, first point straight up.
//
// Note that this comes out right despite the engine only having the even-odd rule: the outline does not
// cross itself, so the two rules agree on it. A five-point star drawn as *five* crossing lines would
// need non-zero, and could not be filled correctly here at all.
star_points :: proc(cx, cy, outer, inner: f32, rays: int) -> [dynamic][2]f32 {
	pts := make([dynamic][2]f32, 0, rays * 2, context.temp_allocator)
	for i in 0 ..< rays * 2 {
		r := outer if i % 2 == 0 else inner
		a := f32(i) * math.PI / f32(rays) - math.PI / 2
		append(&pts, [2]f32{cx + r * math.cos(a), cy + r * math.sin(a)})
	}
	return pts
}

// A quadratic and the cubic that is meant to be identical to it, drawn on top of each other. The
// conversion is the standard one: each cubic control point is two thirds of the way from an endpoint
// to the quadratic's single control point.
paint_curves :: proc(p: Panel) {
	quad, e1 := sciter_app.create_path()
	if e1 != nil {
		return
	}
	defer sciter_app.release_path(quad)

	x0, y0 := p.x + 12, p.y + 92
	cxp, cyp := p.x + 75, p.y + 4
	x1, y1 := p.x + 138, p.y + 92

	sciter_app.path_move_to(quad, x0, y0)
	sciter_app.path_quad_to(quad, cxp, cyp, x1, y1)

	cubic, e2 := sciter_app.create_path()
	if e2 != nil {
		return
	}
	defer sciter_app.release_path(cubic)
	sciter_app.path_move_to(cubic, x0, y0)
	sciter_app.path_bezier_to(
		cubic,
		x0 + 2.0 / 3.0 * (cxp - x0),
		y0 + 2.0 / 3.0 * (cyp - y0),
		x1 + 2.0 / 3.0 * (cxp - x1),
		y1 + 2.0 / 3.0 * (cyp - y1),
		x1,
		y1,
	)

	// `.STROKE_ONLY` because an open path would otherwise be closed and filled.
	sciter_app.set_line_width(p.gfx, 5)
	sciter_app.set_line_color(p.gfx, sciter_app.rgb(0x89, 0xb4, 0xfa))
	sciter_app.draw_path(p.gfx, quad, .STROKE_ONLY)

	sciter_app.set_line_width(p.gfx, 1)
	sciter_app.set_line_color(p.gfx, sciter_app.rgb(0xf9, 0xe2, 0xaf))
	sciter_app.draw_path(p.gfx, cubic, .STROKE_ONLY)

	// The relative forms of the same segments, as a second, smaller curve: `relative` means "from where
	// the pen is" rather than "in path coordinates".
	rel, e3 := sciter_app.create_path()
	if e3 != nil {
		return
	}
	defer sciter_app.release_path(rel)
	sciter_app.path_move_to(rel, p.x + 12, p.y + 100)
	sciter_app.path_quad_to(rel, 30, -26, 60, 0, relative = true)
	sciter_app.path_quad_to(rel, 30, 26, 60, 0, relative = true)
	sciter_app.set_line_color(p.gfx, sciter_app.rgb(0xa6, 0xe3, 0xa1))
	sciter_app.draw_path(p.gfx, rel, .STROKE_ONLY)
}

// A clip is pushed and popped like the state stack, and it takes an opacity - everything inside the
// clip is drawn through it.
paint_clip :: proc(p: Panel) {
	path, err := sciter_app.create_path()
	if err != nil {
		return
	}
	defer sciter_app.release_path(path)

	// A diamond.
	sciter_app.path_move_to(path, p.x + 40, p.y + 12)
	sciter_app.path_line_to(path, p.x + 74, p.y + 55)
	sciter_app.path_line_to(path, p.x + 40, p.y + 98)
	sciter_app.path_line_to(path, p.x + 6, p.y + 55)
	sciter_app.path_close(path)

	sciter_app.push_clip_path(path = path, gfx = p.gfx)
	// Stripes that ask for the whole panel and get the diamond.
	sciter_app.set_line_width(p.gfx, 0)
	for i in 0 ..< 12 {
		sciter_app.set_fill_color(
			p.gfx,
			sciter_app.rgb(0x89, 0xb4, 0xfa) if i % 2 == 0 else sciter_app.rgb(0xf3, 0x8b, 0xa8),
		)
		y := p.y + f32(i) * 10
		sciter_app.draw_rect(p.gfx, p.x, y, p.x + p.w, y + 10)
	}
	sciter_app.pop_clip(p.gfx)

	// The rectangular form, with the opacity argument: half-transparent through the clip.
	sciter_app.push_clip_rect(p.gfx, p.x + 86, p.y + 20, p.x + 140, p.y + 90, 0.45)
	sciter_app.set_fill_color(p.gfx, sciter_app.rgb(0xa6, 0xe3, 0xa1))
	sciter_app.draw_rect(p.gfx, p.x + 80, p.y + 10, p.x + 148, p.y + 100)
	sciter_app.pop_clip(p.gfx)
}

// `draw_image` at its natural size, scaled, cropped to a sub-rectangle, and faded.
paint_images :: proc(p: Panel) {
	if p.sprite == nil {
		return
	}
	sciter_app.draw_image(p.gfx, p.sprite, p.x + 10, p.y + 12)
	sciter_app.draw_image(p.gfx, p.sprite, p.x + 30, p.y + 12, size = [2]f32{40, 40})
	// `source` is {x, y, w, h} in the image's own pixels - one quadrant of the sprite, blown up.
	sciter_app.draw_image(p.gfx, p.sprite, p.x + 82, p.y + 12, size = [2]f32{40, 40}, source = [4]int{0, 0, 4, 4})
	sciter_app.draw_image(p.gfx, p.sprite, p.x + 10, p.y + 62, size = [2]f32{40, 40}, opacity = f32(0.35))

	// What is deliberately *not* here: `image_from_element`. It renders the element by painting it, so
	// calling it from inside a `.DRAW` handler re-enters the paint that is already running and the
	// process dies of stack exhaustion - 39,500 frames of `html::element::do_draw` deep when it was
	// measured, which is a segfault rather than anything catchable. Snapshot between frames instead.
	// `test_an_element_can_be_snapshotted_at_the_size_it_is_laid_out` covers the call itself.
}

// The anchors, on a numeric keypad. Each label is drawn at the same point as the dot beside it, so
// where it lands *is* the documentation.
paint_text :: proc(p: Panel) {
	if p.element == nil {
		return // create_text needs an element to take its style from
	}

	// A cross through the anchor point, so the offsets are visible.
	ax, ay := p.x + p.w / 2, p.y + p.h / 2
	sciter_app.set_line_width(p.gfx, 1)
	sciter_app.set_line_color(p.gfx, sciter_app.rgb(0x45, 0x47, 0x5a))
	sciter_app.draw_line(p.gfx, p.x + 4, ay, p.x + p.w - 4, ay)
	sciter_app.draw_line(p.gfx, ax, p.y + 4, ax, p.y + p.h - 4)

	// Three of the nine, one per row of the keypad, in the element's own style.
	corners := [?]struct {
		anchor: sciter_app.Text_Anchor,
		label:  string,
	}{{.Top_Left, "7 TL"}, {.Middle_Center, "5 C"}, {.Bottom_Right, "3 BR"}}

	for c in corners {
		text, err := sciter_app.create_text(p.element, c.label)
		if err != nil {
			continue
		}
		sciter_app.draw_text(p.gfx, text, ax, ay, c.anchor)
		sciter_app.release_text(text)
	}

	// The style form, for the size the panel's own CSS does not have. An `.badge` class rule would do
	// the same thing - the two are equivalent, measured down to the ascent.
	if big, err := sciter_app.create_text_with_style(p.element, "Ag", "font-size:30px; color:#f9e2af"); err == nil {
		defer sciter_app.release_text(big)
		sciter_app.draw_text(p.gfx, big, p.x + 8, p.y + p.h - 6, .Bottom_Left)
	}
}

// ---------------------------------------------------------------------------------------------------
// The application
//
// One `Cell` per panel, attached by the engine because the stylesheet said `behavior: gallery-cell`.
// The sprite is shared: it is created once and every cell borrows it, so it is retained per cell and
// released on `.DETACH` - which is what the reference counting is for.

App :: struct {
	using host: sciter_app.Host_Handler,
	allocator:  runtime.Allocator,
	sprite:     sciter_app.Image,
	attached:   int,
	painted:    int,
}

Cell :: struct {
	using handler: sciter_app.Event_Handler,
	app:           ^App,
	painter:       Painter,
	name:          string,
	sprite:        sciter_app.Image, // a reference of its own
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

	app := App {
		allocator          = context.allocator,
		on_attach_behavior = on_attach_behavior,
	}

	sprite, serr := make_sprite()
	if serr != nil {
		fmt.eprintln("could not build the sprite:", serr)
		os.exit(1)
	}
	app.sprite = sprite
	defer sciter_app.release_image(app.sprite)

	window, werr := sciter_app.create_window({width = 860, height = 640})
	if werr != nil {
		fmt.eprintln("could not create a window:", werr)
		os.exit(1)
	}

	// Before `load_html`: the behavior requests arrive inside it.
	sciter_app.set_host_handler(window, &app)

	if err := sciter_app.load_html(window, DOC); err != nil {
		fmt.eprintln("could not load the document:", err)
		os.exit(1)
	}

	fmt.printfln("%d panels attached", app.attached)
	sciter_app.show(window)
	sciter_app.run()
	sciter_app.shutdown()
}

on_attach_behavior :: proc(
	handler: ^sciter_app.Host_Handler,
	request: ^sciter_app.Behavior_Request,
) -> ^sciter_app.Event_Handler {
	app := (^App)(handler)
	if request.name != "gallery-cell" {
		return nil
	}

	// Which panel is a document decision, read off the element rather than baked into the host.
	demo, _ := sciter_app.attribute(request.element, "data-demo", context.temp_allocator)

	cell := new(Cell, app.allocator)
	cell.app = app
	cell.subscription = {.DRAW}
	cell.on_event = on_cell_event

	for d in DEMOS {
		if d.name == demo {
			cell.painter = d.painter
			// `demo` is temporary; `d.name` is a string literal and outlives everything.
			cell.name = d.name
			break
		}
	}

	// The cell holds the sprite for as long as it is attached, so the App's own release cannot pull it
	// out from under a repaint.
	if app.sprite != nil && sciter_app.retain_image(app.sprite) == nil {
		cell.sprite = app.sprite
	}

	app.attached += 1
	return cell
}

on_cell_event :: proc(h: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	cell := (^Cell)(h)

	// The teardown hook. There is no other one - see `named_behavior.odin`.
	if event.group == {} && event.params != nil {
		if sciter.Initialization_Events((^sciter.Initialization_Params)(event.params).cmd) == .DETACH {
			sciter_app.release_image(cell.sprite)
			free(cell, cell.app.allocator)
		}
		return false
	}

	de, ok := sciter_app.draw_event(event)
	if !ok || de.layer != .CONTENT || cell.painter == nil {
		return false
	}

	cell.app.painted += 1
	cell.painter(
		Panel {
			gfx = de.gfx,
			x = f32(de.area.x),
			y = f32(de.area.y),
			w = f32(de.area.width),
			h = f32(de.area.height),
			element = event.element,
			sprite = cell.sprite,
		},
	)
	// True: this layer is ours.
	return true
}

// An 8x8 sprite, four coloured quadrants, built from pixels so the tests know exactly what is in it.
// The bytes are BGRA - the order `save_image(.RAW)` hands pixels back in, which is also the order
// `image_from_pixels` takes them.
make_sprite :: proc() -> (sciter_app.Image, Error) {
	pixels: [8 * 8 * 4]u8
	for y in 0 ..< 8 {
		for x in 0 ..< 8 {
			i := (y * 8 + x) * 4
			b, g, r: u8
			switch {
			case x < 4 && y < 4:
				b, g, r = 255, 0, 0 // blue
			case x >= 4 && y < 4:
				b, g, r = 0, 255, 0 // green
			case x < 4 && y >= 4:
				b, g, r = 0, 0, 255 // red
			case:
				b, g, r = 0, 255, 255 // yellow
			}
			pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3] = b, g, r, 255
		}
	}
	return sciter_app.image_from_pixels(pixels[:], 8, 8)
}

// ---------------------------------------------------------------------------------------------------
// Tests
//
// The drawing tests are headless: `paint_image` needs no window and no display, and `.RAW` hands the
// pixels straight back, so an assertion is "draw, save, read one pixel". Only the text and element
// snapshot tests need a window, and those gate themselves.

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

// `.RAW` is blue, green, red, alpha - four bytes a pixel. `examples/graphics.odin` pins that; this file
// relies on it.
@(private = "file")
px :: proc(raw: []u8, width, x, y: int) -> [4]u8 {
	i := (y * width + x) * 4
	return {raw[i], raw[i + 1], raw[i + 2], raw[i + 3]}
}

@(private = "file")
BLACK :: [4]u8{0, 0, 0, 255}

@(private = "file")
lit :: proc(raw: []u8, width, x, y: int) -> bool {
	p := px(raw, width, x, y)
	return p[0] > 24 || p[1] > 24 || p[2] > 24
}

// Draws into a fresh `size` x `size` image cleared to black and hands back the raw pixels. Every
// drawing test below is a call to this and a handful of `px` assertions.
@(private = "file")
render :: proc(size: int, user: rawptr, painter: sciter_app.Painter) -> []u8 {
	img, err := sciter_app.create_image(size, size)
	if err != nil {
		return nil
	}
	defer sciter_app.release_image(img)
	sciter_app.clear_image(img, sciter_app.rgb(0, 0, 0))
	sciter_app.paint_image(img, painter, user)
	raw, _ := sciter_app.save_image(img, .RAW)
	return raw
}

// How many pixels in the image are not background. The shape tests that care about area rather than a
// particular pixel use this.
@(private = "file")
lit_count :: proc(raw: []u8, size: int) -> (n: int) {
	for y in 0 ..< size {
		for x in 0 ..< size {
			if lit(raw, size, x, y) {n += 1}
		}
	}
	return
}

// ---------------------------------------------------------------------------------------------------
// Colours

// `rgba` packs r, g, b, a into a u32 low byte first - which is the opposite of the order the same
// engine hands pixels back in. Getting this backwards produces a picture that is merely the wrong
// colour, so it is worth pinning rather than assuming.
@(test)
test_rgba_packs_red_in_the_low_byte :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	testing.expect_value(t, u32(sciter_app.rgba(1, 2, 3, 4)), u32(0x04030201))
	testing.expect_value(t, u32(sciter_app.rgba(255, 0, 0, 255)), u32(0xff0000ff))
	testing.expect_value(t, u32(sciter_app.rgba(0, 0, 255, 128)), u32(0x80ff0000))

	// `rgb` is `rgba` with a full alpha, and nothing else.
	testing.expect_value(t, sciter_app.rgb(9, 8, 7), sciter_app.rgba(9, 8, 7, 255))
}

// An alpha below 255 really is composited, rather than being dropped on the way in.
@(test)
test_a_translucent_colour_blends_with_what_is_under_it :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	raw := render(
	8,
	nil,
	proc(gfx: Gfx, w, h: u32, user: rawptr) {
		sciter_app.set_line_width(gfx, 0)
		sciter_app.set_fill_color(gfx, sciter_app.rgb(0, 0, 255)) // opaque blue
		sciter_app.draw_rect(gfx, 0, 0, 8, 8)
		sciter_app.set_fill_color(gfx, sciter_app.rgba(0, 255, 0, 128)) // half green
		sciter_app.draw_rect(gfx, 0, 0, 8, 8)
		sciter_app.flush(gfx)
	},
	)
	testing.expect(t, raw != nil)
	defer delete(raw)

	// BGRA on the way out, so index 0 is the blue that was underneath and 1 the green over it.
	p := px(raw, 8, 4, 4)
	testing.expect(t, p[1] > 100 && p[1] < 160, "green should be about half")
	testing.expect(t, p[0] > 100 && p[0] < 160, "and the blue underneath should be what is left")
}

// ---------------------------------------------------------------------------------------------------
// Gradients

@(test)
test_a_linear_fill_gradient_runs_between_its_two_points :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	raw := render(32, nil, proc(gfx: Gfx, w, h: u32, user: rawptr) {
		stops := []sciter_app.Color_Stop {
			{color = sciter_app.rgb(255, 0, 0), offset = 0},
			{color = sciter_app.rgb(0, 0, 255), offset = 1},
		}
		testing_ignore(sciter_app.set_fill_gradient_linear(gfx, 0, 0, 32, 0, stops))
		sciter_app.set_line_width(gfx, 0)
		sciter_app.draw_rect(gfx, 0, 0, 32, 32)
		sciter_app.flush(gfx)
	})
	defer delete(raw)

	left, right := px(raw, 32, 1, 16), px(raw, 32, 30, 16)
	testing.expect(t, left[2] > 200 && left[0] < 60, "the 0 stop end is red")
	testing.expect(t, right[0] > 200 && right[2] < 60, "the 1 stop end is blue")

	// And the gradient is along x only: the same column is the same colour all the way down.
	testing.expect_value(t, px(raw, 32, 1, 2), px(raw, 32, 1, 30))
}

@(test)
test_a_radial_fill_gradient_runs_out_from_its_centre :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	raw := render(32, nil, proc(gfx: Gfx, w, h: u32, user: rawptr) {
		stops := []sciter_app.Color_Stop {
			{color = sciter_app.rgb(255, 0, 0), offset = 0},
			{color = sciter_app.rgb(0, 0, 255), offset = 1},
		}
		testing_ignore(sciter_app.set_fill_gradient_radial(gfx, 16, 16, 15, 15, stops))
		sciter_app.set_line_width(gfx, 0)
		sciter_app.draw_ellipse(gfx, 16, 16, 15, 15)
		sciter_app.flush(gfx)
	})
	defer delete(raw)

	centre, edge := px(raw, 32, 16, 16), px(raw, 32, 16, 3)
	testing.expect(t, centre[2] > 200, "red at the centre")
	testing.expect(t, edge[0] > centre[0], "and bluer towards the rim")
}

// The line gradients are the same idea applied to the stroke. They are worth their own test because
// setting one does *not* set the fill, and a shape that fills and strokes will show it.
@(test)
test_line_gradients_colour_the_stroke_and_not_the_fill :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	raw := render(32, nil, proc(gfx: Gfx, w, h: u32, user: rawptr) {
		stops := []sciter_app.Color_Stop {
			{color = sciter_app.rgb(255, 0, 0), offset = 0},
			{color = sciter_app.rgb(0, 0, 255), offset = 1},
		}
		testing_ignore(sciter_app.set_line_gradient_linear(gfx, 0, 0, 32, 0, stops))
		sciter_app.set_line_width(gfx, 6)
		sciter_app.draw_line(gfx, 0, 16, 32, 16)
		sciter_app.flush(gfx)
	})
	defer delete(raw)

	testing.expect(t, px(raw, 32, 1, 16)[2] > 180, "the stroke starts red")
	testing.expect(t, px(raw, 32, 30, 16)[0] > 180, "and ends blue")
	testing.expect_value(t, px(raw, 32, 16, 1), BLACK) // nothing outside the stroke
}

@(test)
test_a_radial_line_gradient_is_accepted :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	raw := render(32, nil, proc(gfx: Gfx, w, h: u32, user: rawptr) {
		stops := []sciter_app.Color_Stop {
			{color = sciter_app.rgb(255, 0, 0), offset = 0},
			{color = sciter_app.rgb(0, 0, 255), offset = 1},
		}
		testing_ignore(sciter_app.set_line_gradient_radial(gfx, 16, 16, 14, 14, stops))
		sciter_app.set_line_width(gfx, 5)
		sciter_app.draw_line(gfx, 2, 16, 30, 16)
		sciter_app.flush(gfx)
	})
	defer delete(raw)

	// Red at the centre of the radius, bluer at the ends.
	testing.expect(t, px(raw, 32, 16, 16)[2] > px(raw, 32, 3, 16)[2], "reddest at the gradient centre")
}

// ---------------------------------------------------------------------------------------------------
// Caps, joins and the fill rule

// A butt cap stops at the endpoint, square and round both run past it - by half the line width. This is
// the difference that makes a dashed border look wrong when it is set to the other one.
@(test)
test_a_square_cap_runs_past_the_end_of_the_line_and_a_butt_cap_does_not :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	for cap in ([]sciter.Sciter_Line_Cap_Type{.BUTT, .SQUARE, .ROUND}) {
		c := cap
		raw := render(24, &c, proc(gfx: Gfx, w, h: u32, user: rawptr) {
			sciter_app.set_line_color(gfx, sciter_app.rgb(0, 255, 0))
			sciter_app.set_line_width(gfx, 6)
			testing_ignore(sciter_app.set_line_cap(gfx, (^sciter.Sciter_Line_Cap_Type)(user)^))
			sciter_app.draw_line(gfx, 8, 12, 16, 12)
			sciter_app.flush(gfx)
		})
		defer delete(raw)

		past_the_end := lit(raw, 24, 18, 12) // 2px beyond, half the 6px width is 3
		switch cap {
		case .BUTT:
			testing.expect(t, !past_the_end, "BUTT must stop exactly at the endpoint")
		case .SQUARE, .ROUND:
			testing.expect(t, past_the_end, "SQUARE and ROUND overhang by half the line width")
		}
	}
}

// A miter join fills the outside of the corner right out to the point; bevel cuts it off and round
// curves it. The pixel at the very tip of the corner is where they differ.
@(test)
test_a_miter_join_fills_the_corner_that_bevel_and_round_cut_away :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	corner: [3]bool
	for join, i in ([]sciter.Sciter_Line_Join_Type{.MITER, .ROUND, .BEVEL}) {
		j := join
		raw := render(24, &j, proc(gfx: Gfx, w, h: u32, user: rawptr) {
			sciter_app.set_line_color(gfx, sciter_app.rgb(0, 255, 0))
			sciter_app.set_line_width(gfx, 6)
			testing_ignore(sciter_app.set_line_join(gfx, (^sciter.Sciter_Line_Join_Type)(user)^))
			sciter_app.draw_polyline(gfx, [][2]f32{{4, 4}, {18, 4}, {18, 18}})
			sciter_app.flush(gfx)
		})
		defer delete(raw)
		corner[i] = px(raw, 24, 20, 2)[1] > 200
	}

	testing.expect(t, corner[0], "MITER reaches the outside corner")
	testing.expect(t, !corner[1], "ROUND does not")
	testing.expect(t, !corner[2], "BEVEL does not")
}

// A polyline is an open run of segments. A polygon closes and fills. Confusing them is the difference
// between an outline and a blob.
@(test)
test_a_polyline_neither_closes_nor_fills_but_a_polygon_does_both :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	for polyline in ([]bool{true, false}) {
		p := polyline
		raw := render(24, &p, proc(gfx: Gfx, w, h: u32, user: rawptr) {
			pts := [][2]f32{{4, 4}, {20, 4}, {20, 20}}
			sciter_app.set_line_color(gfx, sciter_app.rgb(0, 255, 0))
			sciter_app.set_fill_color(gfx, sciter_app.rgb(0, 255, 0))
			sciter_app.set_line_width(gfx, 1)
			if (^bool)(user)^ {
				sciter_app.draw_polyline(gfx, pts)
			} else {
				sciter_app.draw_polygon(gfx, pts)
			}
			sciter_app.flush(gfx)
		})
		defer delete(raw)

		interior := lit(raw, 24, 16, 10)
		hypotenuse := lit(raw, 24, 12, 12) // the closing edge, which only the polygon has
		if polyline {
			testing.expect(t, !interior, "a polyline must not fill")
			testing.expect(t, !hypotenuse, "and must not close")
		} else {
			testing.expect(t, interior, "a polygon fills")
			testing.expect(t, hypotenuse, "and closes")
		}
	}
}

// An empty point list is rejected by the wrapper rather than handed to the engine, which would read
// through a nil pointer.
@(test)
test_a_polygon_with_no_points_is_refused :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	// Results come back through `user` rather than being asserted in place: the painter runs inside an
	// engine callback, and a failed `testing.expect` there would unwind through a C frame.
	results: [2]Error
	raw := render(8, &results, proc(gfx: Gfx, w, h: u32, user: rawptr) {
		r := (^[2]Error)(user)
		empty: [][2]f32
		r[0] = sciter_app.draw_polygon(gfx, empty)
		r[1] = sciter_app.draw_polyline(gfx, empty)
	})
	delete(raw)

	bad := sciter_app.Error(sciter.Graphin_Result.BAD_PARAM)
	testing.expect_value(t, results[0], bad)
	testing.expect_value(t, results[1], bad)
}

// **A defect.** `gFillMode` answers `.NOTSUPPORTED` and the renderer fills even-odd whatever is asked
// for. The shape here is two squares wound the same way: non-zero would fill the pair solid, even-odd
// holes the inner one out. The hole is there both times.
//
// This test fails loudly if a future engine implements the call, which is exactly what should happen -
// code written against "always even-odd" would start drawing differently.
@(test)
test_the_fill_rule_cannot_be_changed_and_is_always_even_odd :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	for even_odd in ([]bool{false, true}) {
		Ask :: struct {
			even_odd: bool,
			answer:   Error,
		}
		ask := Ask{even_odd, nil}
		raw := render(32, &ask, proc(gfx: Gfx, w, h: u32, user: rawptr) {
			Ask :: struct {
				even_odd: bool,
				answer:   Error,
			}
			ask := (^Ask)(user)
			ask.answer = sciter_app.set_fill_mode(gfx, ask.even_odd)

			path, _ := sciter_app.create_path()
			defer sciter_app.release_path(path)
			for r in ([][4]f32{{2, 2, 30, 30}, {10, 10, 22, 22}}) {
				sciter_app.path_move_to(path, r[0], r[1])
				sciter_app.path_line_to(path, r[2], r[1])
				sciter_app.path_line_to(path, r[2], r[3])
				sciter_app.path_line_to(path, r[0], r[3])
				sciter_app.path_close(path)
			}
			sciter_app.set_fill_color(gfx, sciter_app.rgb(0, 255, 0))
			sciter_app.draw_path(gfx, path, .FILL_ONLY)
			sciter_app.flush(gfx)
		})
		defer delete(raw)

		testing.expect_value(t, ask.answer, sciter_app.Error(sciter.Graphin_Result.NOTSUPPORTED))
		testing.expect(t, lit(raw, 32, 5, 16), "the outer ring is filled")
		testing.expect(t, !lit(raw, 32, 16, 16), "and the inner square is a hole - the even-odd answer")
	}
}

// ---------------------------------------------------------------------------------------------------
// Rounded rectangles
//
// This is where the eight-versus-four bug lived. The corner order is the assertion.

@(test)
test_each_rounded_corner_radius_rounds_its_own_corner_clockwise_from_the_top_left :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	// The pixel just inside each corner of a rect drawn from (1,1) to (30,30), in the same order the
	// radii are given: top-left, top-right, bottom-right, bottom-left.
	probes := [4][2]int{{2, 2}, {28, 2}, {28, 28}, {2, 28}}

	for corner in 0 ..< 4 {
		c := corner
		raw := render(32, &c, proc(gfx: Gfx, w, h: u32, user: rawptr) {
			radii: [4]f32
			radii[(^int)(user)^] = 12
			sciter_app.set_fill_color(gfx, sciter_app.rgb(0, 255, 0))
			sciter_app.set_line_color(gfx, sciter_app.rgb(0, 255, 0))
			sciter_app.draw_rounded_rect(gfx, 1, 1, 30, 30, radii)
			sciter_app.flush(gfx)
		})
		defer delete(raw)

		for probe, i in probes {
			cut := !lit(raw, 32, probe.x, probe.y)
			if i == corner {
				testing.expectf(t, cut, "radii[%d] should have cut corner %d away", corner, i)
			} else {
				testing.expectf(t, !cut, "radii[%d] must not touch corner %d", corner, i)
			}
		}
	}
}

// The `[4][2]f32` form is the engine's own: an rx and an ry per corner, so a corner can be elliptical.
// A wide-but-shallow top-left corner cuts far along the top edge and barely at all down the side.
@(test)
test_a_corner_can_be_elliptical_with_separate_x_and_y_radii :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	raw := render(32, nil, proc(gfx: Gfx, w, h: u32, user: rawptr) {
		sciter_app.set_fill_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.set_line_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.draw_rounded_rect(gfx, 1, 1, 30, 30, [4][2]f32{{16, 4}, {0, 0}, {0, 0}, {0, 0}})
		sciter_app.flush(gfx)
	})
	defer delete(raw)

	testing.expect(t, !lit(raw, 32, 3, 1), "16 across: the top edge is cut well in")
	testing.expect(t, lit(raw, 32, 2, 8), "4 down: the left edge is barely cut at all")
}

// The regression test for the wrapper bug: four numbers where the engine reads eight used to leave the
// rectangle square. If the corners are cut, the pairs are being built.
@(test)
test_a_uniform_radius_reaches_the_engine_as_eight_numbers :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	raw := render(32, nil, proc(gfx: Gfx, w, h: u32, user: rawptr) {
		sciter_app.set_fill_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.set_line_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.draw_rounded_rect(gfx, 1, 1, 30, 30, [4]f32{10, 10, 10, 10})
		sciter_app.flush(gfx)
	})
	defer delete(raw)

	for corner in ([][2]int{{2, 2}, {28, 2}, {28, 28}, {2, 28}}) {
		testing.expectf(t, !lit(raw, 32, corner.x, corner.y), "corner %v should be rounded away", corner)
	}
	testing.expect(t, lit(raw, 32, 16, 16), "and the middle is still filled")
}

// The two members of the group, called by name, against the group itself. `draw_rounded_rect` is what
// the examples call; `draw_rounded_rect_uniform` and `draw_rounded_rect_xy` are what it resolves to,
// and neither is reachable through the group under a name of its own.
//
// What this pins is the expansion: `[4]f32{10, 8, 6, 4}` and `[4][2]f32{{10,10},{8,8},{6,6},{4,4}}`
// must reach the engine as the same eight numbers, so their images are byte-identical. Different radii
// per corner, because four equal ones would pass even if the expansion transposed them.
@(test)
test_the_uniform_form_expands_to_the_pair_form_and_the_group_picks_both :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	paint_uniform :: proc(gfx: Gfx, w, h: u32, user: rawptr) {
		sciter_app.set_fill_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.set_line_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.draw_rounded_rect_uniform(gfx, 1, 1, 30, 30, [4]f32{10, 8, 6, 4})
		sciter_app.flush(gfx)
	}
	paint_xy :: proc(gfx: Gfx, w, h: u32, user: rawptr) {
		sciter_app.set_fill_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.set_line_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.draw_rounded_rect_xy(gfx, 1, 1, 30, 30, [4][2]f32{{10, 10}, {8, 8}, {6, 6}, {4, 4}})
		sciter_app.flush(gfx)
	}
	paint_group :: proc(gfx: Gfx, w, h: u32, user: rawptr) {
		sciter_app.set_fill_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.set_line_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.draw_rounded_rect(gfx, 1, 1, 30, 30, [4]f32{10, 8, 6, 4})
		sciter_app.flush(gfx)
	}

	uniform := render(32, nil, paint_uniform)
	defer delete(uniform)
	xy := render(32, nil, paint_xy)
	defer delete(xy)
	group := render(32, nil, paint_group)
	defer delete(group)

	testing.expect(t, len(uniform) > 0 && len(uniform) == len(xy) && len(uniform) == len(group))

	same_as_xy, same_as_group := true, true
	for b, i in uniform {
		if b != xy[i] {same_as_xy = false}
		if b != group[i] {same_as_group = false}
	}
	testing.expect(t, same_as_xy, "one radius per corner must expand to that radius as both rx and ry")
	testing.expect(t, same_as_group, "the group must resolve [4]f32 to the uniform member")

	// And the corners really were cut, so "identical" is not two identical failures.
	testing.expect(t, !lit(uniform, 32, 2, 2), "the 10px top-left corner is rounded away")
	testing.expect(t, lit(uniform, 32, 16, 16), "and the middle is filled")
}

// ---------------------------------------------------------------------------------------------------
// Transforms
//
// Drawing is transformed. The two accessors that report the transform are not - which is the trap.

@(test)
test_scale_multiplies_the_size_of_what_is_drawn_after_it :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	raw := render(
	32,
	nil,
	proc(gfx: Gfx, w, h: u32, user: rawptr) {
		sciter_app.set_fill_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.set_line_width(gfx, 0)
		sciter_app.save_state(gfx)
		testing_ignore(sciter_app.scale(gfx, 4, 2))
		sciter_app.draw_rect(gfx, 0, 0, 4, 4) // 16 x 8 once scaled
		sciter_app.restore_state(gfx)
		sciter_app.flush(gfx)
	},
	)
	defer delete(raw)

	testing.expect(t, lit(raw, 32, 14, 6), "inside the scaled rectangle")
	testing.expect(t, !lit(raw, 32, 17, 6), "past its scaled width")
	testing.expect(t, !lit(raw, 32, 14, 9), "and past its scaled height")
}

@(test)
test_skew_slides_one_axis_along_the_other :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	raw := render(
	32,
	nil,
	proc(gfx: Gfx, w, h: u32, user: rawptr) {
		sciter_app.set_fill_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.set_line_width(gfx, 0)
		sciter_app.save_state(gfx)
		testing_ignore(sciter_app.skew(gfx, 1, 0))
		sciter_app.draw_rect(gfx, 0, 0, 8, 16) // leans right as y grows
		sciter_app.restore_state(gfx)
		sciter_app.flush(gfx)
	},
	)
	defer delete(raw)

	testing.expect(t, lit(raw, 32, 2, 1), "the top edge is where it was drawn")
	testing.expect(t, lit(raw, 32, 16, 15), "the bottom edge has slid right by its own y")
	testing.expect(t, !lit(raw, 32, 2, 15), "and left the place it came from")
}

// `transform` is applied *on top of* what is already there rather than replacing it - so the translate
// before it still counts. That is the difference between this and "set the matrix".
@(test)
test_a_matrix_composes_with_the_transform_already_in_effect :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	raw := render(
	32,
	nil,
	proc(gfx: Gfx, w, h: u32, user: rawptr) {
		sciter_app.set_fill_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.set_line_width(gfx, 0)
		sciter_app.save_state(gfx)
		sciter_app.translate(gfx, 8, 8)
		testing_ignore(sciter_app.transform(gfx, 2, 0, 0, 2, 0, 0)) // doubles, about the moved origin
		sciter_app.draw_rect(gfx, 0, 0, 4, 4) // -> (8,8)..(16,16)
		sciter_app.restore_state(gfx)
		sciter_app.flush(gfx)
	},
	)
	defer delete(raw)

	testing.expect(t, lit(raw, 32, 12, 12), "inside the doubled rectangle at the translated origin")
	testing.expect(t, !lit(raw, 32, 6, 6), "the translate was not discarded")
	testing.expect(t, !lit(raw, 32, 17, 12), "and the scale was applied")
}

// **A defect.** `gWorldToScreen` and `gScreenToWorld` answer `.OK` and hand the point straight back,
// under every transform there is. A widget that has to turn a mouse position into shape coordinates
// cannot use them - it has to keep and invert its own matrix.
@(test)
test_world_and_screen_coordinates_ignore_the_transform_entirely :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	failures := 0
	raw := render(16, &failures, proc(gfx: Gfx, w, h: u32, user: rawptr) {
		bad := (^int)(user)

		check :: proc(gfx: Gfx, bad: ^int, label: string) {
			out, err := sciter_app.world_to_screen(gfx, {10, 20})
			back, err2 := sciter_app.screen_to_world(gfx, {10, 20})
			if err != nil || err2 != nil || out != {10, 20} || back != {10, 20} {
				fmt.printfln("world_to_screen now honours %s: %v / %v", label, out, back)
				bad^ += 1
			}
		}

		check(gfx, bad, "the identity")
		sciter_app.save_state(gfx)
		sciter_app.translate(gfx, 5, 7); check(gfx, bad, "translate")
		sciter_app.scale(gfx, 2, 3); check(gfx, bad, "scale")
		sciter_app.rotate(gfx, math.PI / 4); check(gfx, bad, "rotate")
		sciter_app.skew(gfx, 0.5, 0); check(gfx, bad, "skew")
		sciter_app.transform(gfx, 2, 0, 0, 2, 1, 1); check(gfx, bad, "a matrix")
		sciter_app.restore_state(gfx)
	})
	delete(raw)

	testing.expect_value(t, failures, 0)
}

// The state stack is the only way back to the identity matrix, and it is unforgiving in one direction
// only. Restoring more often than you saved is answered `.OK` - both from an empty stack and after a
// matched pair - so the engine will never tell you the pairing is wrong that way round.
//
// **Saving more often than you restore is fatal.** A painter that returns with the stack still pushed
// aborts the process: `terminate called without an active exception`, no error code, no chance to
// react. That direction cannot be asserted here for the obvious reason - it would take the test runner
// with it - so it is measured out of process and written down instead. Pair them with `defer`.
@(test)
test_restoring_more_often_than_you_saved_is_harmless :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	results: [3]Error
	raw := render(
	8,
	&results,
	proc(gfx: Gfx, w, h: u32, user: rawptr) {
		r := (^[3]Error)(user)
		r[0] = sciter_app.restore_state(gfx) // nothing has been saved at all
		r[1] = sciter_app.save_state(gfx)
		r[2] = sciter_app.restore_state(gfx)
		// A fourth call here would be one restore past the pair, and is also `.OK`. What must not
		// happen is leaving this procedure with a save outstanding.
		_ = sciter_app.restore_state(gfx)
	},
	)
	delete(raw)

	testing.expect_value(t, results[0], nil)
	testing.expect_value(t, results[1], nil)
	testing.expect_value(t, results[2], nil)
}

// ---------------------------------------------------------------------------------------------------
// Arcs, stars and curves

// `draw_arc` closes the shape with a chord, so it fills the circular segment between the arc and that
// chord - not the pie wedge a reader of the name expects. The centre of the ellipse stays empty.
@(test)
test_an_arc_fills_the_segment_under_its_chord_and_not_the_wedge :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	raw := render(
	32,
	nil,
	proc(gfx: Gfx, w, h: u32, user: rawptr) {
		sciter_app.set_fill_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.set_line_width(gfx, 0)
		// A quarter turn: from +x round towards +y, which is downwards.
		sciter_app.draw_arc(gfx, 16, 16, 12, 12, 0, math.PI / 2)
		sciter_app.flush(gfx)
	},
	)
	defer delete(raw)

	testing.expect(t, !lit(raw, 32, 16, 16), "the centre is not part of the shape")
	testing.expect(t, !lit(raw, 32, 20, 20), "nor is the middle of the wedge")
	testing.expect(t, lit(raw, 32, 23, 23), "but the segment between the chord and the arc is")

	// The sweep really did go clockwise: nothing was painted in the quadrant above the centre.
	testing.expect(t, !lit(raw, 32, 23, 9), "a positive sweep runs from +x towards +y, which is down")
}

// A wedge, for comparison, because `draw_arc` cannot make one: centre, out along a radius, round with
// `path_arc_to`, close.
//
// **It is `clockwise` that picks which of the two arcs is drawn here, not `large_arc`.** The endpoints
// are straight up and straight left, so one arc is a quarter turn and the other three quarters, and the
// two flags between them ought to name four possibilities. Measured, there are two - and one
// combination draws nothing at all. See the test below for that.
@(test)
test_a_pie_wedge_is_built_from_a_path_and_the_direction_picks_the_arc :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	Ask :: struct {
		large, clockwise: bool,
	}

	wedge :: proc(gfx: Gfx, w, h: u32, user: rawptr) {
		Ask :: struct {
			large, clockwise: bool,
		}
		ask := (^Ask)(user)^
		path, _ := sciter_app.create_path()
		defer sciter_app.release_path(path)

		r := f32(13)
		a0, a1 := f32(-math.PI / 2), f32(math.PI) // straight up, and straight left
		sciter_app.path_move_to(path, 16, 16)
		sciter_app.path_line_to(path, 16 + r * math.cos(a0), 16 + r * math.sin(a0))
		sciter_app.path_arc_to(
			path,
			16 + r * math.cos(a1),
			16 + r * math.sin(a1),
			0,
			r,
			r,
			large_arc = ask.large,
			clockwise = ask.clockwise,
		)
		sciter_app.path_close(path)

		sciter_app.set_fill_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.set_line_width(gfx, 0)
		sciter_app.draw_path(gfx, path, .FILL_ONLY)
		sciter_app.flush(gfx)
	}

	// Clockwise the long way: up, right, down, left. Everything but the upper-left quadrant.
	long := Ask {
		large     = true,
		clockwise = true,
	}
	raw := render(32, &long, wedge)
	defer delete(raw)
	testing.expect(t, lit(raw, 32, 16, 16), "the centre of a wedge is filled, unlike an arc's")
	testing.expect(t, lit(raw, 32, 22, 10), "the upper-right quadrant is inside three quarters of a turn")
	testing.expect(t, lit(raw, 32, 22, 22) && lit(raw, 32, 10, 22), "so are the two below it")
	testing.expect(t, !lit(raw, 32, 10, 10), "and the quarter it skipped is not")

	// Anticlockwise, the short way: only the upper-left quadrant.
	short := Ask {
		large     = false,
		clockwise = false,
	}
	raw2 := render(32, &short, wedge)
	defer delete(raw2)
	testing.expect(t, lit(raw2, 32, 10, 10), "the quarter turn covers the upper-left quadrant")
	testing.expect(t, !lit(raw2, 32, 22, 10), "and nothing else")
	testing.expect(t, !lit(raw2, 32, 22, 22) && !lit(raw2, 32, 10, 22))

	// `large_arc` does not get a say in the anticlockwise direction: the short arc either way.
	long_anticlockwise := Ask {
		large     = true,
		clockwise = false,
	}
	raw3 := render(32, &long_anticlockwise, wedge)
	defer delete(raw3)
	testing.expect(t, lit(raw3, 32, 10, 10), "still the quarter turn")
	testing.expect(t, !lit(raw3, 32, 22, 10), "large_arc is ignored when clockwise is false")
}

// **A defect.** The fourth combination - clockwise, and not the long way - produces no arc at all. Not
// an error, and not the short arc: the segment collapses, and what is left is the two straight edges of
// the wedge lying on top of each other. So `large_arc` is not a choice between two clockwise arcs here,
// it is the only clockwise arc there is.
@(test)
test_a_clockwise_arc_that_is_not_the_long_way_round_collapses_to_nothing :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	reported: Error
	raw := render(32, &reported, proc(gfx: Gfx, w, h: u32, user: rawptr) {
		path, _ := sciter_app.create_path()
		defer sciter_app.release_path(path)
		r := f32(13)
		sciter_app.path_move_to(path, 16, 16)
		sciter_app.path_line_to(path, 16, 16 - r)
		(^Error)(user)^ = sciter_app.path_arc_to(path, 16 - r, 16, 0, r, r, large_arc = false, clockwise = true)
		sciter_app.path_close(path)
		sciter_app.set_fill_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.set_line_width(gfx, 0)
		sciter_app.draw_path(gfx, path, .FILL_ONLY)
		sciter_app.flush(gfx)
	})
	defer delete(raw)

	testing.expect_value(t, reported, nil) // it does not complain
	// What is left is the two straight edges collapsed onto each other - a sliver, not an arc. Neither
	// quadrant the arc could have swept is covered.
	testing.expect(t, !lit(raw, 32, 10, 10), "not the short way round")
	testing.expect(t, !lit(raw, 32, 22, 10), "not the long way round either")
	testing.expect(t, !lit(raw, 32, 22, 22) && !lit(raw, 32, 10, 22))
	testing.expectf(t, lit_count(raw, 32) < 80, "a whole wedge is hundreds of pixels; this is %d", lit_count(raw, 32))
}

// **A defect.** `gStar` answers `.OK` and paints a scatter of disconnected fragments: no closed
// outline, and no fill at any line width. It is deterministic, so this is the engine's geometry rather
// than uninitialised memory. Build the points and use `draw_polygon`.
@(test)
test_draw_star_paints_fragments_rather_than_a_star :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	reported: Error
	engine := render(32, &reported, proc(gfx: Gfx, w, h: u32, user: rawptr) {
		sciter_app.set_fill_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.set_line_color(gfx, sciter_app.rgb(0, 255, 0))
		(^Error)(user)^ = sciter_app.draw_star(gfx, 16, 16, 15, 7, 0, 5)
		sciter_app.flush(gfx)
	})
	defer delete(engine)

	// It does not even have the decency to fail.
	testing.expect_value(t, reported, nil)

	by_hand := render(32, nil, proc(gfx: Gfx, w, h: u32, user: rawptr) {
		sciter_app.set_fill_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.set_line_color(gfx, sciter_app.rgb(0, 255, 0))
		pts := star_points(16, 16, 15, 7, 5)
		sciter_app.draw_polygon(gfx, pts[:])
		sciter_app.flush(gfx)
	})
	defer delete(by_hand)

	engine_area, hand_area := lit_count(engine, 32), lit_count(by_hand, 32)
	testing.expect(t, hand_area > 250, "a hand-built star covers most of its bounding circle")
	testing.expect(t, engine_area < hand_area / 3, "the engine's covers a fraction of it - it is not filling")
	testing.expect(t, !lit(engine, 32, 16, 16), "and its centre, which is inside any star, is empty")
}

// Two renders of the same broken star are byte-identical, which rules out reading uninitialised memory
// and pins this as a geometry bug worth reporting upstream.
@(test)
test_the_broken_star_is_at_least_deterministic :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	star :: proc(gfx: Gfx, w, h: u32, user: rawptr) {
		sciter_app.set_fill_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.set_line_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.draw_star(gfx, 16, 16, 15, 7, 0, 5)
		sciter_app.flush(gfx)
	}
	a := render(32, nil, star); defer delete(a)
	b := render(32, nil, star); defer delete(b)

	testing.expect(t, len(a) > 0 && len(a) == len(b))
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			testing.fail_now(t, "the star differs between renders - it may be reading uninitialised memory")
		}
	}
}

// Any ray count is accepted, including the ones that cannot describe a star.
@(test)
test_draw_star_accepts_ray_counts_that_cannot_be_a_star :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	for rays in ([]int{0, 1, 2}) {
		Ask :: struct {
			rays:   int,
			answer: Error,
		}
		ask := Ask{rays, nil}
		raw := render(16, &ask, proc(gfx: Gfx, w, h: u32, user: rawptr) {
			Ask :: struct {
				rays:   int,
				answer: Error,
			}
			ask := (^Ask)(user)
			sciter_app.set_line_color(gfx, sciter_app.rgb(0, 255, 0))
			ask.answer = sciter_app.draw_star(gfx, 8, 8, 7, 3, 0, ask.rays)
		})
		delete(raw)
		testing.expectf(t, ask.answer == nil, "draw_star started validating its ray count at %d", rays)
	}
}

// A quadratic and the cubic it converts to draw the same curve. They are not bit-identical - the
// rasteriser flattens them differently - but they agree everywhere except the antialiased fringe.
@(test)
test_a_quadratic_and_its_equivalent_cubic_draw_the_same_curve :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	curve :: proc(gfx: Gfx, w, h: u32, user: rawptr) {
		quad := (^bool)(user)^
		path, _ := sciter_app.create_path()
		defer sciter_app.release_path(path)

		x0, y0 := f32(2), f32(30)
		cx, cy := f32(16), f32(0)
		x1, y1 := f32(30), f32(30)

		sciter_app.path_move_to(path, x0, y0)
		if quad {
			sciter_app.path_quad_to(path, cx, cy, x1, y1)
		} else {
			// The standard degree elevation: each cubic control point is two thirds of the way from an
			// endpoint towards the quadratic's control point.
			sciter_app.path_bezier_to(
				path,
				x0 + 2.0 / 3.0 * (cx - x0),
				y0 + 2.0 / 3.0 * (cy - y0),
				x1 + 2.0 / 3.0 * (cx - x1),
				y1 + 2.0 / 3.0 * (cy - y1),
				x1,
				y1,
			)
		}
		sciter_app.set_line_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.set_line_width(gfx, 1)
		sciter_app.draw_path(gfx, path, .STROKE_ONLY)
		sciter_app.flush(gfx)
	}

	yes, no := true, false
	q := render(32, &yes, curve); defer delete(q)
	c := render(32, &no, curve); defer delete(c)

	differing := 0
	for i in 0 ..< len(q) {
		if q[i] != c[i] {differing += 1}
	}
	testing.expect(t, differing > 0, "identical output would mean one of them is not being drawn")
	testing.expectf(
		t,
		differing < len(q) / 20,
		"the two curves should differ only at the antialiased fringe, not %d bytes of %d",
		differing,
		len(q),
	)
}

// `relative` on a path segment means "from where the pen is". Two relative curves in a row make an S
// without any of the arithmetic that the absolute form needs.
@(test)
test_a_relative_segment_starts_from_where_the_pen_already_is :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	raw := render(
		32,
		nil,
		proc(gfx: Gfx, w, h: u32, user: rawptr) {
			absolute, _ := sciter_app.create_path()
			defer sciter_app.release_path(absolute)
			sciter_app.path_move_to(absolute, 4, 16)
			sciter_app.path_quad_to(absolute, 12, 4, 20, 16)

			relative, _ := sciter_app.create_path()
			defer sciter_app.release_path(relative)
			sciter_app.path_move_to(relative, 4, 16)
			sciter_app.path_quad_to(relative, 8, -12, 16, 0, relative = true)

			// Drawn one over the other: if `relative` meant anything else they would not coincide.
			sciter_app.set_line_color(gfx, sciter_app.rgb(0, 255, 0))
			sciter_app.set_line_width(gfx, 3)
			sciter_app.draw_path(gfx, absolute, .STROKE_ONLY)
			sciter_app.set_line_color(gfx, sciter_app.rgb(255, 0, 0))
			sciter_app.set_line_width(gfx, 1)
			sciter_app.draw_path(gfx, relative, .STROKE_ONLY)
			sciter_app.flush(gfx)
		},
	)
	defer delete(raw)

	// The thin red line lands on the thick green one, so the apex of the curve is red rather than
	// green. Index 2 is red on the way out - `.RAW` is BGRA.
	apex := px(raw, 32, 12, 10)
	testing.expect(t, apex[2] > apex[1], "the relative curve should sit on top of the absolute one")
}

// ---------------------------------------------------------------------------------------------------
// Clipping

@(test)
test_a_path_clip_limits_drawing_to_the_shape_and_not_its_bounding_box :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	raw := render(
	32,
	nil,
	proc(gfx: Gfx, w, h: u32, user: rawptr) {
		path, _ := sciter_app.create_path()
		defer sciter_app.release_path(path)
		sciter_app.path_move_to(path, 0, 0)
		sciter_app.path_line_to(path, 30, 0)
		sciter_app.path_line_to(path, 0, 30)
		sciter_app.path_close(path)

		testing_ignore(sciter_app.push_clip_path(gfx, path))
		sciter_app.set_fill_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.set_line_width(gfx, 0)
		sciter_app.draw_rect(gfx, 0, 0, 32, 32) // asks for everything
		sciter_app.pop_clip(gfx)
		sciter_app.flush(gfx)
	},
	)
	defer delete(raw)

	testing.expect(t, lit(raw, 32, 4, 4), "inside the triangle")
	testing.expect(t, !lit(raw, 32, 26, 26), "outside it, but inside its bounding box")
}

// The opacity argument makes everything drawn inside the clip translucent, which is how a whole group
// of shapes is faded without touching any of their colours.
@(test)
test_a_clip_opacity_fades_everything_drawn_inside_it :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	raw := render(
	32,
	nil,
	proc(gfx: Gfx, w, h: u32, user: rawptr) {
		sciter_app.set_line_width(gfx, 0)
		sciter_app.push_clip_rect(gfx, 0, 0, 32, 16, 0.5)
		sciter_app.set_fill_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.draw_rect(gfx, 0, 0, 32, 16)
		sciter_app.pop_clip(gfx)

		// The same colour outside the clip, at full strength.
		sciter_app.draw_rect(gfx, 0, 16, 32, 32)
		sciter_app.flush(gfx)
	},
	)
	defer delete(raw)

	faded, full := px(raw, 32, 16, 8)[1], px(raw, 32, 16, 24)[1]
	testing.expect_value(t, full, u8(255))
	testing.expect(t, faded > 100 && faded < 160, "the clipped half should be about half strength")
}

// ---------------------------------------------------------------------------------------------------
// Images

@(test)
test_draw_image_blits_at_its_natural_size_unless_given_one :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	sprite, err := make_sprite()
	testing.expect_value(t, err, nil)
	defer sciter_app.release_image(sprite)

	raw := render(
	32,
	&sprite,
	proc(gfx: Gfx, w, h: u32, user: rawptr) {
		s := (^sciter_app.Image)(user)^
		sciter_app.draw_image(gfx, s, 0, 0) // 8x8, its own size
		sciter_app.draw_image(gfx, s, 12, 0, size = [2]f32{16, 16}) // stretched
		sciter_app.flush(gfx)
	},
	)
	defer delete(raw)

	testing.expect_value(t, px(raw, 32, 1, 1), [4]u8{255, 0, 0, 255}) // the blue quadrant
	testing.expect(t, !lit(raw, 32, 9, 1), "the natural blit stops at 8 pixels")
	testing.expect_value(t, px(raw, 32, 14, 2), [4]u8{255, 0, 0, 255}) // still blue, twice as big
	testing.expect(t, lit(raw, 32, 26, 14), "and the stretched one reaches 16 pixels")
}

// `source` crops in the *image's* pixels, so it pairs with `size` to blow one quadrant up.
@(test)
test_a_source_rectangle_crops_the_image_before_it_is_scaled :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	sprite, _ := make_sprite()
	defer sciter_app.release_image(sprite)

	raw := render(
	32,
	&sprite,
	proc(gfx: Gfx, w, h: u32, user: rawptr) {
		s := (^sciter_app.Image)(user)^
		// The bottom-right quadrant only - yellow - filling a 24x24 square.
		sciter_app.draw_image(gfx, s, 0, 0, size = [2]f32{24, 24}, source = [4]int{4, 4, 4, 4})
		sciter_app.flush(gfx)
	},
	)
	defer delete(raw)

	testing.expect_value(t, px(raw, 32, 2, 2), [4]u8{0, 255, 255, 255}) // yellow in the top-left now
	testing.expect_value(t, px(raw, 32, 20, 20), [4]u8{0, 255, 255, 255}) // and all the way across
}

@(test)
test_image_opacity_blends_the_blit_with_what_is_under_it :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	sprite, _ := make_sprite()
	defer sciter_app.release_image(sprite)

	raw := render(16, &sprite, proc(gfx: Gfx, w, h: u32, user: rawptr) {
		s := (^sciter_app.Image)(user)^
		sciter_app.draw_image(gfx, s, 0, 0, opacity = f32(0.5))
		sciter_app.flush(gfx)
	})
	defer delete(raw)

	// The sprite's blue quadrant is (255,0,0) in BGRA; over black at half strength it is about half.
	blue := px(raw, 16, 1, 1)[0]
	testing.expect(t, blue > 100 && blue < 160, "half opacity over black is about half the channel")
}

// The reference count is the engine's, and the pair really is a pair: retain, release, release leaves
// the handle gone and does not fault. Note the asymmetry over nil.
@(test)
test_retain_and_release_are_a_matched_pair_but_only_release_tolerates_nil :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	bad := sciter_app.Error(sciter.Graphin_Result.BAD_PARAM)

	img, err := sciter_app.create_image(4, 4)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, sciter_app.retain_image(img), nil)
	testing.expect_value(t, sciter_app.release_image(img), nil) // back to one reference
	testing.expect_value(t, sciter_app.release_image(img), nil) // and gone

	path, perr := sciter_app.create_path()
	testing.expect_value(t, perr, nil)
	testing.expect_value(t, sciter_app.retain_path(path), nil)
	testing.expect_value(t, sciter_app.release_path(path), nil)
	testing.expect_value(t, sciter_app.release_path(path), nil)

	// `release_*(nil)` is what a `defer` after a failed create does, so the wrappers allow it. `retain`
	// has no such excuse and is left as the engine answers it.
	testing.expect_value(t, sciter_app.retain_image(nil), bad)
	testing.expect_value(t, sciter_app.retain_path(nil), bad)
	testing.expect_value(t, sciter_app.retain_text(nil), bad)
	testing.expect_value(t, sciter_app.retain_graphics(nil), bad)

	testing.expect_value(t, sciter_app.release_image(nil), nil)
	testing.expect_value(t, sciter_app.release_path(nil), nil)
	testing.expect_value(t, sciter_app.release_text(nil), nil)
	testing.expect_value(t, sciter_app.release_graphics(nil), nil)
}

// A retained `Graphics` outlives nothing useful - the engine's context is gone when the painter returns
// whatever the count says - but the call is part of the pair and should not fail on a live handle.
@(test)
test_a_graphics_context_can_be_retained_while_it_is_alive :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	results: [2]Error
	raw := render(8, &results, proc(gfx: Gfx, w, h: u32, user: rawptr) {
		r := (^[2]Error)(user)
		r[0] = sciter_app.retain_graphics(gfx)
		r[1] = sciter_app.release_graphics(gfx)
	})
	delete(raw)

	testing.expect_value(t, results[0], nil)
	testing.expect_value(t, results[1], nil)
}

// ---------------------------------------------------------------------------------------------------
// Handing handles to script
//
// All eight conversions round-trip. The trap is what happens on the wrong type.

@(test)
test_every_graphics_handle_survives_a_round_trip_through_a_value :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	img, _ := sciter_app.create_image(4, 4)
	defer sciter_app.release_image(img)

	vi, ierr := sciter_app.value_from_image(img)
	testing.expect_value(t, ierr, nil)
	defer sciter_app.value_clear(&vi)
	kind, _ := sciter_app.value_type(&vi)
	testing.expect_value(t, kind, sciter.Value_Type.RESOURCE)

	back_img, berr := sciter_app.value_to_image(&vi)
	testing.expect_value(t, berr, nil)
	testing.expect_value(t, back_img, img)

	path, _ := sciter_app.create_path()
	defer sciter_app.release_path(path)
	vp, perr := sciter_app.value_from_path(path)
	testing.expect_value(t, perr, nil)
	defer sciter_app.value_clear(&vp)
	back_path, bperr := sciter_app.value_to_path(&vp)
	testing.expect_value(t, bperr, nil)
	testing.expect_value(t, back_path, path)

	// The graphics context only exists inside a painter, so its round trip has to happen there.
	ok := false
	raw := render(4, &ok, proc(gfx: Gfx, w, h: u32, user: rawptr) {
		v, err := sciter_app.value_from_graphics(gfx)
		if err != nil {return}
		defer sciter_app.value_clear(&v)
		back, berr := sciter_app.value_to_graphics(&v)
		(^bool)(user)^ = berr == nil && back == gfx
	})
	delete(raw)
	testing.expect(t, ok, "a Graphics should round-trip through a Value like the others")
}

// **The trap.** Unwrapping a `Value` that holds something else answers `.OK` and a nil handle, so code
// that only tests the error walks off with nothing and finds out at the next call. Check the handle.
@(test)
test_unwrapping_the_wrong_kind_of_value_yields_a_nil_handle_and_no_error :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	v := sciter_app.value_from(i32(42))
	defer sciter_app.value_clear(&v)

	img, ierr := sciter_app.value_to_image(&v)
	testing.expect_value(t, ierr, nil)
	testing.expect_value(t, img, nil)

	path, perr := sciter_app.value_to_path(&v)
	testing.expect_value(t, perr, nil)
	testing.expect_value(t, path, nil)

	gfx, gerr := sciter_app.value_to_graphics(&v)
	testing.expect_value(t, gerr, nil)
	testing.expect_value(t, gfx, nil)

	text, terr := sciter_app.value_to_text(&v)
	testing.expect_value(t, terr, nil)
	testing.expect_value(t, text, nil)
}

// The other direction does fail properly, and leaves the Value untouched rather than half-built.
@(test)
test_wrapping_a_nil_handle_fails_and_leaves_the_value_undefined :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	bad := sciter_app.Error(sciter.Graphin_Result.BAD_PARAM)

	vi, ierr := sciter_app.value_from_image(nil)
	testing.expect_value(t, ierr, bad)
	ik, _ := sciter_app.value_type(&vi)
	testing.expect_value(t, ik, sciter.Value_Type.UNDEFINED)

	vp, perr := sciter_app.value_from_path(nil)
	testing.expect_value(t, perr, bad)
	pk, _ := sciter_app.value_type(&vp)
	testing.expect_value(t, pk, sciter.Value_Type.UNDEFINED)

	vg, gerr := sciter_app.value_from_graphics(nil)
	testing.expect_value(t, gerr, bad)
	gk, _ := sciter_app.value_type(&vg)
	testing.expect_value(t, gk, sciter.Value_Type.UNDEFINED)

	vt, terr := sciter_app.value_from_text(nil)
	testing.expect_value(t, terr, bad)
	tk, _ := sciter_app.value_type(&vt)
	testing.expect_value(t, tk, sciter.Value_Type.UNDEFINED)
}

// The wrap takes a reference of its own, so clearing the Value does not take the handle with it. This
// is the difference between handing a path to script and losing it.
@(test)
test_clearing_a_wrapped_value_leaves_the_original_handle_usable :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	img, _ := sciter_app.create_image(6, 4)
	defer sciter_app.release_image(img)

	v, err := sciter_app.value_from_image(img)
	testing.expect_value(t, err, nil)
	sciter_app.value_clear(&v)

	w, h, _, serr := sciter_app.image_size(img)
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, w, 6)
	testing.expect_value(t, h, 4)
}

// ---------------------------------------------------------------------------------------------------
// The panels themselves
//
// Every painter is run offscreen and has to put *something* down. This is the test that would catch a
// panel that silently draws nothing because a call started failing.

@(test)
test_every_panel_paints_something_when_run_offscreen :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	sprite, serr := make_sprite()
	testing.expect_value(t, serr, nil)
	defer sciter_app.release_image(sprite)

	Run :: struct {
		panel:   Panel,
		painter: Painter,
	}

	for demo in DEMOS {
		// `text` is the one panel that needs an element, and has none here - it is covered below.
		if demo.name == "text" {
			continue
		}

		run := Run {
			panel = {w = 150, h = 110, sprite = sprite},
			painter = demo.painter,
		}

		raw := render(150, &run, proc(gfx: Gfx, w, h: u32, user: rawptr) {
			Run :: struct {
				panel:   Panel,
				painter: Painter,
			}
			run := (^Run)(user)
			run.panel.gfx = gfx
			run.painter(run.panel)
			sciter_app.flush(gfx)
		})
		testing.expectf(t, raw != nil, "%s: the image could not be rendered", demo.name)
		if raw == nil {
			continue
		}
		defer delete(raw)

		testing.expectf(t, lit_count(raw, 150) > 40, "%s painted nothing", demo.name)
	}
}

// ---------------------------------------------------------------------------------------------------
// Text
//
// `create_text` takes its font, size and colour from an element, and there is no way to get an element
// without a document - so these need a window and skip themselves without a display.

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

// One window for the whole suite: creating and destroying them per test is slow and the engine keeps
// the host handler's address, so it has to outlive the test that made it.
@(private = "file")
// Shared by every test in this file, and created on first use. That is deliberate - a window per test
// would be slow, and closing one is itself hazardous (see `close` in sciter_app/window.odin) - but it
// makes the tests here order-coupled: **a test that changes the document must put it back**, usually by
// reloading `DOC`, or it breaks a later test and the failure points at the wrong one.
g_window: sciter_app.Window

TEXT_DOC :: `<html><head><style>
  body { font: 16px system; color: #cdd6f4; }
  .big { font-size: 32px; }
</style></head><body><p id="p">hello</p></body></html>`

@(private = "file")
styled_element :: proc(t: ^testing.T) -> (element: sciter_app.Element, ok: bool) {
	if !have_display() {
		fmt.println("skipping - this test needs a window")
		return nil, false
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

	// Anything the engine keeps has to outlive the test runner's per-test arena.
	context.allocator = runtime.default_allocator()

	if g_window == nil {
		sciter_app.init()
		w, err := sciter_app.create_window({width = 400, height = 300})
		testing.expect_value(t, err, nil)
		if w == nil {
			return nil, false
		}
		g_window = w
	}

	testing.expect_value(t, sciter_app.load_html(g_window, TEXT_DOC), nil)
	root, rerr := sciter_app.root(g_window)
	testing.expect_value(t, rerr, nil)
	el, eerr := sciter_app.select_first(root, "#p")
	testing.expect_value(t, eerr, nil)
	return el, el != nil
}

// The element is not decoration: it is the whole font stack. A class picks a different rule as it would
// apply to that element, so a 32px class comes back twice the height.
@(test)
test_text_takes_its_size_from_the_element_or_the_class_it_is_given :: proc(t: ^testing.T) {
	el, ok := styled_element(t)
	if !ok {return}

	plain, err := sciter_app.create_text(el, "hello world")
	testing.expect_value(t, err, nil)
	defer sciter_app.release_text(plain)
	pm, perr := sciter_app.text_metrics(plain)
	testing.expect_value(t, perr, nil)

	big, berr := sciter_app.create_text(el, "hello world", "big")
	testing.expect_value(t, berr, nil)
	defer sciter_app.release_text(big)
	bm, _ := sciter_app.text_metrics(big)

	testing.expect(t, bm.height > pm.height * 1.8, "a 32px class against a 16px element")
	testing.expect(t, bm.ascent > pm.ascent)
	testing.expect_value(t, pm.lines, 1)

	// `min_width` is the tightest wrap, `max_width` the unwrapped run - so for two words the second is
	// the wider of the two.
	testing.expect(t, pm.max_width > pm.min_width, "two words can wrap narrower than they lay out")
}

// A class that matches nothing is not an error - the text comes back in the element's own style. So a
// typo in a class name is invisible except as text of the wrong size.
@(test)
test_a_class_that_matches_no_rule_falls_back_to_the_elements_own_style :: proc(t: ^testing.T) {
	el, ok := styled_element(t)
	if !ok {return}

	plain, _ := sciter_app.create_text(el, "hello world")
	defer sciter_app.release_text(plain)
	missing, err := sciter_app.create_text(el, "hello world", "no-such-class")
	testing.expect_value(t, err, nil)
	defer sciter_app.release_text(missing)

	pm, _ := sciter_app.text_metrics(plain)
	mm, _ := sciter_app.text_metrics(missing)
	testing.expect_value(t, mm, pm)
}

// The style form and the class form are the same mechanism: equivalent CSS measures identically, down
// to the ascent. Use whichever the caller has to hand.
@(test)
test_a_style_declaration_lays_text_out_exactly_as_the_equivalent_class_does :: proc(t: ^testing.T) {
	el, ok := styled_element(t)
	if !ok {return}

	by_class, cerr := sciter_app.create_text(el, "hello world", "big")
	testing.expect_value(t, cerr, nil)
	defer sciter_app.release_text(by_class)

	by_style, serr := sciter_app.create_text_with_style(el, "hello world", "font-size: 32px")
	testing.expect_value(t, serr, nil)
	defer sciter_app.release_text(by_style)

	cm, _ := sciter_app.text_metrics(by_class)
	sm, _ := sciter_app.text_metrics(by_style)
	testing.expect_value(t, sm, cm)
}

// Nonsense in a style declaration is swallowed: `.OK`, a usable handle, and the element's own style. A
// mistyped style shows up as text that is the wrong size rather than as an error, so nothing will tell
// you about it but a screenshot.
@(test)
test_an_unparseable_style_declaration_is_silently_ignored :: proc(t: ^testing.T) {
	el, ok := styled_element(t)
	if !ok {return}

	plain, _ := sciter_app.create_text(el, "hello world")
	defer sciter_app.release_text(plain)

	junk, err := sciter_app.create_text_with_style(el, "hello world", "this is not css ;;;")
	testing.expect_value(t, err, nil)
	testing.expect(t, junk != nil, "a bad declaration still produces a handle")
	defer sciter_app.release_text(junk)

	pm, _ := sciter_app.text_metrics(plain)
	jm, jerr := sciter_app.text_metrics(junk)
	testing.expect_value(t, jerr, nil)
	testing.expect_value(t, jm, pm)
}

// **A defect.** `textSetBox` answers `.OK` and changes nothing: not the line count, not the metrics,
// not the pixels. Text through this API is one line, so anything that has to wrap has to be split into
// several `Text` objects by the caller.
@(test)
test_setting_a_text_box_never_wraps_the_text :: proc(t: ^testing.T) {
	el, ok := styled_element(t)
	if !ok {return}

	baseline, _ := sciter_app.create_text(el, "hello world")
	defer sciter_app.release_text(baseline)
	before, _ := sciter_app.text_metrics(baseline)
	testing.expect_value(t, before.lines, 1)

	// Every width, including well under the tightest wrap the metrics themselves report.
	for width in ([]f32{200, 68, 50, 40, 36, 20, before.min_width / 2}) {
		text, _ := sciter_app.create_text(el, "hello world")
		defer sciter_app.release_text(text)

		testing.expect_value(t, sciter_app.set_text_box(text, width, 200), nil)
		after, err := sciter_app.text_metrics(text)
		testing.expect_value(t, err, nil)
		testing.expectf(t, after.lines == 1, "a box %v wide should have wrapped, and did not", width)
		testing.expect_value(t, after, before)
	}
}

// **The anchor bug.** The numbers are a numeric keypad: 7/8/9 is the top row, 1/2/3 the bottom. This
// package had the enum upside down until each of the nine was measured by drawing at a known point and
// finding the ink.
@(test)
test_the_text_anchor_numbers_are_laid_out_like_a_numeric_keypad :: proc(t: ^testing.T) {
	el, ok := styled_element(t)
	if !ok {return}

	Case :: struct {
		anchor: sciter_app.Text_Anchor,
		el:     sciter_app.Element,
		hard_x: int, // -1 the ink is left of the point, +1 right of it, 0 straddling
		hard_y: int, // -1 above, +1 below
	}

	cases := [?]Case {
		{anchor = .Top_Left, hard_x = +1, hard_y = +1},
		{anchor = .Top_Center, hard_x = 0, hard_y = +1},
		{anchor = .Top_Right, hard_x = -1, hard_y = +1},
		{anchor = .Middle_Left, hard_x = +1, hard_y = 0},
		{anchor = .Middle_Center, hard_x = 0, hard_y = 0},
		{anchor = .Middle_Right, hard_x = -1, hard_y = 0},
		{anchor = .Bottom_Left, hard_x = +1, hard_y = -1},
		{anchor = .Bottom_Center, hard_x = 0, hard_y = -1},
		{anchor = .Bottom_Right, hard_x = -1, hard_y = -1},
	}

	SIZE :: 80
	POINT :: 40

	for c in cases {
		test_case := c
		test_case.el = el

		raw := render(SIZE, &test_case, proc(gfx: Gfx, w, h: u32, user: rawptr) {
			Case :: struct {
				anchor: sciter_app.Text_Anchor,
				el:     sciter_app.Element,
				hard_x: int,
				hard_y: int,
			}
			c := (^Case)(user)^
			text, err := sciter_app.create_text(c.el, "Wg")
			if err != nil {return}
			defer sciter_app.release_text(text)
			sciter_app.draw_text(gfx, text, POINT, POINT, c.anchor)
			sciter_app.flush(gfx)
		})
		testing.expect(t, raw != nil)
		if raw == nil {continue}
		defer delete(raw)

		minx, miny, maxx, maxy := SIZE, SIZE, -1, -1
		for y in 0 ..< SIZE {
			for x in 0 ..< SIZE {
				if lit(raw, SIZE, x, y) {
					minx = min(minx, x); miny = min(miny, y)
					maxx = max(maxx, x); maxy = max(maxy, y)
				}
			}
		}
		testing.expectf(t, maxx >= 0, "%v drew nothing", c.anchor)
		if maxx < 0 {continue}

		switch c.hard_x {
		case +1:
			testing.expectf(t, minx >= POINT, "%v: the point should be the text's left edge", c.anchor)
		case -1:
			testing.expectf(t, maxx <= POINT, "%v: the point should be the text's right edge", c.anchor)
		case:
			testing.expectf(t, minx < POINT && maxx > POINT, "%v: the text should straddle the point", c.anchor)
		}
		switch c.hard_y {
		case +1:
			testing.expectf(t, miny >= POINT - 2, "%v: the text should sit below the point", c.anchor)
		case -1:
			testing.expectf(t, maxy <= POINT + 2, "%v: the text should sit above the point", c.anchor)
		case:
			testing.expectf(t, miny < POINT && maxy > POINT, "%v: the text should straddle the point", c.anchor)
		}
	}
}

@(test)
test_text_handles_are_reference_counted_like_the_others :: proc(t: ^testing.T) {
	el, ok := styled_element(t)
	if !ok {return}

	text, err := sciter_app.create_text(el, "counted")
	testing.expect_value(t, err, nil)
	testing.expect_value(t, sciter_app.retain_text(text), nil)
	testing.expect_value(t, sciter_app.release_text(text), nil)

	// Still alive on the first reference.
	m, merr := sciter_app.text_metrics(text)
	testing.expect_value(t, merr, nil)
	testing.expect(t, m.height > 0)

	testing.expect_value(t, sciter_app.release_text(text), nil)
}

@(test)
test_a_text_object_survives_a_round_trip_through_a_value :: proc(t: ^testing.T) {
	el, ok := styled_element(t)
	if !ok {return}

	text, _ := sciter_app.create_text(el, "wrapped")
	defer sciter_app.release_text(text)

	v, err := sciter_app.value_from_text(text)
	testing.expect_value(t, err, nil)
	kind, _ := sciter_app.value_type(&v)
	testing.expect_value(t, kind, sciter.Value_Type.RESOURCE)

	back, berr := sciter_app.value_to_text(&v)
	testing.expect_value(t, berr, nil)
	testing.expect_value(t, back, text)

	// And the wrap held its own reference: clearing it leaves the original alone.
	sciter_app.value_clear(&v)
	m, merr := sciter_app.text_metrics(text)
	testing.expect_value(t, merr, nil)
	testing.expect(t, m.height > 0)
}

// A nil element is the one failure `create_text` reports, and it is worth checking because everything
// else about the call is silently forgiving.
@(test)
test_creating_text_without_an_element_is_a_bad_parameter :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	bad := sciter_app.Error(sciter.Graphin_Result.BAD_PARAM)

	text, err := sciter_app.create_text(nil, "no element")
	testing.expect_value(t, err, bad)
	testing.expect_value(t, text, nil)

	styled, serr := sciter_app.create_text_with_style(nil, "no element", "font-size: 12px")
	testing.expect_value(t, serr, bad)
	testing.expect_value(t, styled, nil)
}

// ---------------------------------------------------------------------------------------------------
// Snapshots of live elements

// `image_from_element` renders an element as it is painted now, at its current size - which is how a
// test gets at what the engine drew, and how an app gets a thumbnail of a pane.
@(test)
test_an_element_can_be_snapshotted_at_the_size_it_is_laid_out :: proc(t: ^testing.T) {
	el, ok := styled_element(t)
	if !ok {return}

	img, err := sciter_app.image_from_element(el)
	testing.expect_value(t, err, nil)
	testing.expect(t, img != nil)
	defer sciter_app.release_image(img)

	w, h, has_alpha, serr := sciter_app.image_size(img)
	testing.expect_value(t, serr, nil)
	testing.expect(t, w > 0 && h > 0, "the snapshot has the element's laid-out size")
	testing.expect(t, has_alpha, "and an alpha channel - the parts the element does not paint")

	// It is a real image: it encodes, and it decodes back to the same size.
	png, perr := sciter_app.save_image(img, .PNG)
	testing.expect_value(t, perr, nil)
	defer delete(png)
	testing.expect_value(t, string(png[1:4]), "PNG")
}

@(test)
test_snapshotting_nothing_is_a_bad_parameter :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	img, err := sciter_app.image_from_element(nil)
	testing.expect_value(t, err, sciter_app.Error(sciter.Graphin_Result.BAD_PARAM))
	testing.expect_value(t, img, nil)
}

// ---------------------------------------------------------------------------------------------------

// Swallows a result deliberately, where the assertion is the pixel rather than the return code and the
// bare call would otherwise read as an oversight.
@(private = "file")
testing_ignore :: proc(err: Error) {
	_ = err
}

// The graphics half of the scoped constructors. Wrapping an image, a path, a text object or a
// `Graphics` for script adds a reference to the Value - the object keeps its own, which is why the
// `release_*` calls below are still needed and are not what the scope gives back.
@(test)
test_the_scoped_graphics_wraps_give_back_the_values_reference_only :: proc(t: ^testing.T) {
	el, ok := styled_element(t)
	if !ok {return}

	sciter_app.track_resources(true)
	defer sciter_app.track_resources(true)
	before := sciter_app.outstanding_resources()

	image, ierr := sciter_app.create_image(8, 8)
	testing.expect_value(t, ierr, nil)
	path, perr := sciter_app.create_path()
	testing.expect_value(t, perr, nil)
	text, terr := sciter_app.create_text(el, "wrapped")
	testing.expect_value(t, terr, nil)

	{
		as_image, e1 := sciter_app.scoped_value_from_image(image)
		testing.expect_value(t, e1, nil)
		kind, _ := sciter_app.value_type(&as_image)
		testing.expect(t, kind != .UNDEFINED)

		_, e2 := sciter_app.scoped_value_from_path(path)
		testing.expect_value(t, e2, nil)
		_, e3 := sciter_app.scoped_value_from_text(text)
		testing.expect_value(t, e3, nil)
	}

	// The Values are gone and all three objects are still usable, which is the claim the wrap makes.
	w, h, _, serr := sciter_app.image_size(image)
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, w, 8)
	testing.expect_value(t, h, 8)
	testing.expect_value(t, sciter_app.path_move_to(path, 1, 1), nil)
	_, merr := sciter_app.text_metrics(text)
	testing.expect_value(t, merr, nil)

	testing.expect_value(t, sciter_app.release_text(text), nil)
	testing.expect_value(t, sciter_app.release_path(path), nil)
	testing.expect_value(t, sciter_app.release_image(image), nil)

	after := sciter_app.outstanding_resources()
	testing.expect_value(t, after[.Value], before[.Value])
}

// `Graphics` only exists inside a painter, so its wrap is tested where one is: the Value is made and
// released inside the callback, and the painter goes on drawing afterwards.
@(test)
test_a_graphics_can_be_wrapped_and_released_inside_the_painter :: proc(t: ^testing.T) {
	if !engine_loaded(t) {return}

	raw := render(
	16,
	nil,
	proc(gfx: Gfx, w, h: u32, user: rawptr) {
		{
			wrapped, err := sciter_app.scoped_value_from_graphics(gfx)
			if err != nil {
				return
			}
			kind, _ := sciter_app.value_type(&wrapped)
			if kind == .UNDEFINED {
				return
			}
		}
		// The wrap took a reference and the scope gave it back; the Graphics is the engine's either way.
		sciter_app.set_fill_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.set_line_color(gfx, sciter_app.rgb(0, 255, 0))
		sciter_app.draw_rect(gfx, 2, 2, 14, 14)
		sciter_app.flush(gfx)
	},
	)
	defer delete(raw)

	testing.expect(t, lit(raw, 16, 8, 8), "the painter still worked after wrapping its Graphics")
}
