# Graphics: drawing with the engine's renderer

Sciter's 2D API is a second function table, `SciterGraphicsAPI`, reached through the main one. It is
the same renderer the engine paints documents with, so anything you draw composites with the document
rather than sitting on top of it — and it is available offscreen, with no window and no display.

**Choosing the backend, which is a different subject from drawing with it.** `graphics_caps` reports how
the engine rates the machine, and `SET_GFX_LAYER` (one `set_option`, no window, before any window is
created) picks software Skia or a GPU layer — the lever to reach for when a document paints slowly rather
than draws wrongly. It is opt-in for a reason, and the measurements that say layout usually matters more
are in [`html-css-js.md`](./html-css-js.md#making-a-big-document-cheap-layout-is-the-cost-and-display-none-is-the-switch).

[`graphics`](../examples/graphics.odin) is the whole thing in one file: a dial painted on every frame
through an element's `DRAW` events, and a colour wheel rendered offscreen and handed to the document as
a PNG.

## You never create a context

This is the first thing to know, because the API looks like you do. `gCreate`, which takes an image and
gives back a graphics context, answers **`.NOTSUPPORTED`** on the vendored 6.0.4.9 engine.

The engine hands you a context instead, two ways:

```odin
// offscreen: no window needed
img, _ := sciter_app.create_image(120, 120)
sciter_app.paint_image(img, proc(gfx: sciter_app.Graphics, w, h: u32, user: rawptr) {
	sciter_app.set_fill_color(gfx, sciter_app.rgb(0x89, 0xb4, 0xfa))
	sciter_app.set_line_color(gfx, sciter_app.rgb(0x89, 0xb4, 0xfa))
	sciter_app.draw_rect(gfx, 0, 0, f32(w), f32(h))
})
png, _ := sciter_app.save_image(img, .PNG)
```

```odin
// onscreen: the DRAW event on an element
handler := sciter_app.Event_Handler {
	subscription = {.DRAW},
	on_event     = on_event,
}
sciter_app.attach_handler(element, &handler)
```

The context is the engine's, and it is valid for the duration of that one call. `Image`, `Path` and
`Text` are yours and outlive any context.

## The DRAW event

One repaint of an element delivers **four** events, in order: `.BACKGROUND`, `.CONTENT`, `.FOREGROUND`,
`.OUTLINE`.

```odin
on_event :: proc(handler: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	de, ok := sciter_app.draw_event(event)
	if !ok || de.layer != .CONTENT {
		return false
	}
	sciter_app.set_fill_color(de.gfx, sciter_app.rgb(0xf3, 0x8b, 0xa8))
	sciter_app.draw_ellipse(de.gfx, f32(de.area.x), f32(de.area.y), 20, 20)
	return true    // this layer is ours
}
```

**Returning true replaces that layer** — the engine does not paint its own version of it. Returning
false draws *over* the engine's painting instead. Measured by giving a `<div>` a red CSS background,
painting it blue on `.BACKGROUND`, and reading the element back with `image_from_element`: consumed, the
pixel is blue; not consumed, it is red with the blue drawn over.

`de.area` is the element's rectangle in the context's coordinates, so drawing at `de.area.x, de.area.y`
is drawing at the element's top-left. `DRAW` is high-frequency — subscribe on the elements you actually
draw, never on `root` out of habit.

To animate, invalidate rather than draw out of band:

```odin
sciter.api().SciterUpdateElement(sciter.Helement(dial), false)
```

## State, transforms and shapes

The state stack carries the transform, the colours, the line width and the clip. `save_state` /
`restore_state` is the only way to undo a transform — there is no "reset the matrix".

```odin
sciter_app.save_state(gfx)
sciter_app.translate(gfx, cx, cy)
for _ in 0 ..< 12 {
	sciter_app.draw_line(gfx, 0, -radius + 4, 0, -radius + 12)
	sciter_app.rotate(gfx, 2 * math.PI / 12)
}
sciter_app.restore_state(gfx)
```

**`world_to_screen` and `screen_to_world` do not work.** They answer `.OK` and hand the point straight
back under translate, scale, rotate, skew and a full matrix alike. Drawing *is* transformed correctly —
it is only these two accessors that lie — so a widget that has to turn a mouse position into shape
coordinates must keep and invert its own matrix rather than asking the engine.

Nor can the fill rule be changed: `set_fill_mode` answers `.NOTSUPPORTED` and the renderer is always
even-odd. A shape that needs non-zero has to be built so both rules agree on it.

Restoring more often than you saved answers `.OK` on this engine rather than `.FAILURE`, from an empty
stack included, so it will not tell you when the pairing is wrong that way round. **The other direction
is fatal: a painter that returns with the stack still pushed aborts the process** - no error code, no
chance to react. Pair them with `defer`.

**Every shape both fills and strokes.** `draw_rect`, `draw_ellipse`, `draw_arc`, `draw_star`,
`draw_polygon`, `draw_polyline`, `draw_rounded_rect` and `draw_path` all use the fill colour *and* the
line colour, so setting only one leaves the other at whatever the last drawing used. Set both, every
time — it is the most common way a drawing comes out wrong.

Two exceptions worth knowing before you reach for them. `draw_polyline` is open: it neither closes back
to the first point nor fills. And `draw_arc` closes with a *chord*, so what it fills is the circular
segment rather than the pie wedge — a wedge needs a path.

**`draw_star` is broken on this engine** and paints a scatter of disconnected fragments. Build the
points and use `draw_polygon`; `examples/graphics_gallery.odin` has the loop, and draws the two side by
side so the difference is visible.

Gradients replace the flat colour until a colour is set again: `set_fill_gradient_linear`,
`set_fill_gradient_radial` and the `set_line_*` pair, each taking `[]Color_Stop` with offsets 0..1.

Clipping is a stack too: `push_clip_rect` / `push_clip_path`, then `pop_clip`. Both take an `opacity`,
which makes everything drawn inside the clip translucent.

## Paths

Built once, drawn many times, independent of any context.

```odin
path, _ := sciter_app.create_path()
defer sciter_app.release_path(path)

sciter_app.path_move_to(path, 0, 0)
sciter_app.path_line_to(path, 16, 0)
sciter_app.path_bezier_to(path, 16, 8, 8, 16, 0, 16)
sciter_app.path_close(path)

sciter_app.draw_path(gfx, path, .FILL_AND_STROKE)
```

`path_arc_to` is SVG's elliptical arc: a destination, two radii, a rotation, and two flags that are
meant to pick which of the four possible arcs you want. **On this engine there are two, and one
combination draws nothing**: `clockwise` picks the arc, `large_arc` has to agree with it, and
`clockwise = true` with `large_arc = false` produces an empty path with no error. A path that silently
paints nothing is usually this. Every segment takes `relative`, which means "from where the
pen is" rather than "in path coordinates".

## Text

There is no font object. Text is laid out **against an element**, because that is where the font, size,
colour and direction come from — the element supplies the style only; nothing is added to the document.

```odin
text, _ := sciter_app.create_text(element, "42.7 °C")
defer sciter_app.release_text(text)

m, _ := sciter_app.text_metrics(text)          // min_width, max_width, height, ascent, descent, lines
sciter_app.draw_text(gfx, text, x, y, .Middle_Center)
```

`create_text_with_style(element, "…", "font-size: 24px; color: #f00")` takes a declaration instead of
the element's own style, and `create_text(element, "…", class_name)` takes a class. The two are the same
mechanism: equivalent CSS measures identically, down to the ascent. Neither complains about input it
cannot use — a class that matches no rule and a declaration that will not parse both come back laid out
in the element's own style, so a typo shows up as text of the wrong size and nowhere else.

**`set_text_box` does nothing on this engine**, which is why it is not in the snippet above: every width
from 200 down to 20 leaves `lines = 1` and the metrics untouched on a string whose tightest wrap is 35
wide, and the drawn pixels are identical with and without it. Text laid out through this API is one
line; anything that has to wrap has to be split into several `Text` objects and drawn a line at a time.

**`Text_Anchor`'s numbers are a numeric keypad, not reading order** — `sciter-x-graphics.h` says
"position (1..9 on MUMPAD)", so 7/8/9 is the *top* row and 1 is bottom-left. This package had the enum
upside down until each of the nine was measured by drawing at a known point and finding the ink.

## Images

| | |
| --- | --- |
| `create_image(width, height, with_alpha := true)` | an empty image |
| `image_from_pixels(pixels, width, height, format := .PREMUL_ALPHA)` | from bytes you already have |
| `load_image(bytes)` | decodes PNG / JPEG / WEBP |
| `image_from_element(element)` | a snapshot of how an element is painted right now |
| `image_size(image)` | `(width, height, has_alpha)` |
| `clear_image(image, color)` | fills, discarding what was there |
| `save_image(image, encoding := .PNG, quality := 90, allocator)` | encodes |

**`.RAW` is 4 bytes per pixel in blue, green, red, alpha order.** `sciter-x-graphics.h` says `[a,b,g,r]`
and does not match this engine: clearing an image to pure red and reading it back gives
`[0, 0, 255, 255]`. That makes `.RAW` the way to test drawing — no decoder, and one pixel is one
assertion:

```odin
raw, _ := sciter_app.save_image(img, .RAW)
i := (y * width + x) * 4
testing.expect_value(t, raw[i:i + 4], []u8{255, 0, 0, 255})   // pure blue
```

Every drawing test in `examples/graphics.odin` works exactly this way, and none of them needs a display.

## Handing graphics to script

`value_from_graphics`, `value_from_image`, `value_from_path` and `value_from_text` wrap a handle into a
`Value` — a `.RESOURCE` — which script receives as its own `Graphics`, `Image`, `Path` or `Text` object.
`value_to_graphics` and friends unwrap the other way, for a handle arriving from script. Combined with
`value_from_function`, that is an Odin procedure a document can call to draw with.

**Check the handle, not the error.** Unwrapping a `Value` holding something else — an integer, a string
— answers `.OK` and a nil handle, so code that only tests `err` walks off with nothing and finds out at
the next call. The other direction does fail properly: wrapping a nil handle is `.BAD_PARAM` and leaves
the `Value` undefined. The wrap takes a reference of its own, so clearing the `Value` leaves the
original handle usable.

## Reference counting

`Image`, `Graphics`, `Path` and `Text` are all reference counted. Each has a `retain_*` / `release_*`
pair, and releasing nil is not an error — which is what makes `defer release_path(path)` safe straight
after a create that may have failed. `retain_*(nil)` is not given the same treatment: it is the engine's
`.BAD_PARAM`.

One more trap on the image side: **`image_from_element` must not be called from inside a `.DRAW`
handler.** It produces the image by painting the element, so from within a paint it re-enters the paint
already running and recurses until the stack is gone — ~39,500 frames deep when it was measured, and a
segfault rather than anything catchable. Snapshot between frames.

You do not release the `Graphics` the engine hands you in `paint_image` or a `DRAW` event; it owns it.
