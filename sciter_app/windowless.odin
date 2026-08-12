// Windowless views: Sciter as a pane inside somebody else's renderer.
//
// The engine's second mode, and the one that is barely documented. There is no window: you hand Sciter a
// pixel buffer you allocated, it draws the document into it, and compositing the result is your problem.
// That makes it a component in an application whose frames belong to someone else - a game engine, a
// raylib or Dear ImGui tool, a headless renderer producing PNGs on a build machine.
//
// The whole API is one `ISciterAPI` slot, `SciterProcX`, plus the `SXM_*` message structs from
// `sciter-x-msg.h`. Everything here is a wrapper over one of those messages. The rest of this package -
// `load_html`, `root`, `select_first`, `eval`, `set_host_handler` - works on a windowless view
// unchanged, because they all take a `Window` and the view's `window` field is one.
//
// Everything below was measured against the vendored 6.0.4.9 on Linux x64 by
// `examples/windowless.odin` and `spike/windowless/main.odin`, not read off the headers, and
// `docs/EMBEDDING.md` is the long version.
//
// ## The shape of it
//
//	view, err := sciter_app.create_windowless({width = 320, height = 240})
//	defer sciter_app.destroy_windowless(&view)
//
//	sciter_app.load_html(view.window, DOC, "about:blank")
//	sciter_app.windowless_heartbeat(&view, 0)
//	sciter_app.paint_windowless(&view)
//	// view.pixels is now RGBA, width*height*4, yours to upload or write out
//
// ## Six rules the headers do not state
//
//   - **It still needs a display on Linux.** Measured: with `DISPLAY` and `WAYLAND_DISPLAY` both unset,
//     `create_windowless` segfaults inside `SXM_CREATE` - before a document, a surface or a paint.
//     "Windowless" means the engine makes no window of its own, not that it can run without a windowing
//     system. A headless machine needs `xvfb-run` or equivalent, which was not verified here.
//   - **`HWINDOW` is a key, not a handle.** There is no windowless constructor, so the engine has to be
//     given something to key its view map on, and it never dereferences it. This package allocates a
//     one-byte sentinel per view and uses its address, which is unique and stable for the view's life.
//     The SDK's own demo passes an `SDL_Window*`, which is not an OS handle either.
//   - **Do not call `init`.** It stands up the windowed application subsystem, which is the thing a
//     windowless view exists not to have. Measured: a view created *after* `init` works anyway, so a
//     process can hold both kinds - but nothing here needs it.
//   - **The pixels are RGBA on Linux and macOS, BGRA on Windows.** The header says only "RGBA or
//     BGRA"; the SDK's demo picks by platform and that is the rule. `PIXEL_ORDER` below says which.
//   - **Nothing repaints itself.** `paint_windowless` is the only thing that writes pixels. What tells
//     you *when* to call it is `Host_Handler.on_invalidate_rect`, which works on a windowless view -
//     `set_host_handler(view.window, &host)` and it arrives like any other notification.
//   - **After a destroy, no view can be created again in that process.** See `destroy_windowless`.
//
// ## The limits, measured
//
//   - **Input works, with one hole.** Mouse and keyboard messages both reach the document - handlers
//     run, `:hover` follows the pointer, a click is synthesised from a press and a release - but the
//     *intrinsic behaviors* do not act on the mouse: a click will not focus an `<input>`, press a
//     `<button>` or toggle a checkbox. Drive those through the element instead (`set_focus`,
//     `do_click`, `send_mouse`). See `windowless_mouse`.
//   - **Script timers run on the wall clock, not on the heartbeat's timestamp.** `setTimeout`,
//     `setInterval` and `requestAnimationFrame` do work - but only as real time passes, and passing a
//     made-up `time_ms` changes nothing. A host that renders frames faster than real time (a build
//     machine, a test) sees no timers at all. See `windowless_heartbeat`.
//   - **`SXM_RESOLUTION` crashes the process**, one message later than the call. There is deliberately
//     no wrapper for it here - see the note above `create_windowless`.
package sciter_app

import sciter ".."
import "base:runtime"

// The byte order the engine writes into the surface. The header says "RGBA or BGRA" and does not say
// which; the SDK's cross-platform demo selects `SDL_PIXELFORMAT_BGRA32` under `#ifdef WINDOWS` and
// `SDL_PIXELFORMAT_RGBA32` everywhere else, and the RGBA half is measured here - a page painted
// `#0000ff` comes back `00 00 ff ff`.
Pixel_Order :: enum {
	RGBA,
	BGRA,
}

PIXEL_ORDER :: Pixel_Order.BGRA when ODIN_OS == .Windows else Pixel_Order.RGBA

// A view with no window. `window` is the key every other call in this package takes.
Windowless_View :: struct {
	window:      Window,
	backend:     sciter.Sl_Target,
	width:       i32,
	height:      i32,
	stride:      int, // bytes per row; 0 for a GPU backend
	pixels:      []u8, // `.BITMAP` only: width*height*4 in PIXEL_ORDER, or the caller's own buffer
	owns_pixels: bool,
	allocator:   runtime.Allocator,

	// The sentinel whose address is `window`. It exists to be a unique pointer and holds nothing.
	key:         ^u8,
}

Windowless_Options :: struct {
	width, height: i32,

	// Where the engine draws. `.BITMAP` (the zero value) renders on the CPU into `pixels` below.
	//
	// **`.OPENGL` renders on the GPU into the framebuffer bound to the current context**, which is the
	// version a game engine or an immediate-mode tool wants - no readback, no copy. Three measured
	// rules come with it, all of them in `create_windowless`: the context must be *desktop* OpenGL,
	// `device` is mandatory, and the framebuffer binding is captured here rather than read at paint
	// time.
	//
	// `.OPENGLES` is refused by this engine build on Linux - `SXM_PAINT` answers false and draws
	// nothing, on a GLES context and on a desktop one alike. The DirectX targets are Windows-only and
	// untried here.
	backend:       sciter.Sl_Target,

	// For a GPU backend: the address of a `glGetProcAddress`-shaped function, so the engine loads GL
	// through the same implementation the host uses. **Not optional** - a nil `device` with a GL
	// backend segfaults inside the engine, so `create_windowless` refuses it. The engine's own
	// `SciterEGLGetProcAddress` works here too, and was measured to behave identically.
	device:        rawptr,

	// `.BITMAP` only. Leave nil to have a surface allocated - `width*height*4` - which is what most
	// callers want; pass one to render straight into a texture upload buffer, a game engine's staging
	// memory, or a sub-rectangle of a larger image.
	pixels:        []u8,
	stride:        int, // 0 means width*4
}

// True for the backends that draw on the GPU, where the host owns the target and there is no surface
// in the `SXM_SIZE` message.
@(private)
is_gpu_backend :: proc(backend: sciter.Sl_Target) -> bool {
	return backend != .BITMAP
}

// Creates a view and gives it its surface: `SXM_CREATE` then `SXM_SIZE`.
//
// ## The GPU backends
//
// `.OPENGL` draws with the engine's own Skia GPU pipeline instead of rasterising into your memory.
// Three rules, all measured on 6.0.4.9 / Linux / Mesa, none of them in the headers:
//
//   - **The context must be desktop OpenGL, not GLES.** On a GLES 3.2 context `SXM_PAINT` answers true
//     and draws nothing, because Skia compiles `#version 150` desktop shaders and the driver rejects
//     them ("GLSL 1.50 is not supported"). On a desktop GL 4.6 context - core *or* compatibility
//     profile, both measured - the document appears. `.OPENGLES` as a backend is refused outright:
//     `SXM_PAINT` answers false, on either kind of context.
//   - **`device` is mandatory.** It is a `glGetProcAddress`-shaped function pointer, as the SDK's own
//     `lite-sciter` demo passes `glfwGetProcAddress`. A nil one segfaults inside the engine on the
//     first paint, so this refuses it with `.Window_Failed` rather than letting that happen.
//   - **The framebuffer binding is captured here, at create time.** Measured both ways round: a view
//     created while an FBO was bound paints into that FBO even when the default framebuffer is bound
//     at paint time, and a view created against the default framebuffer keeps painting there with an
//     FBO bound. So: make the context current *and* bind the target framebuffer before this call.
//     That is how a host gets Sciter into its own texture.
//   - **The paint leaves the engine's framebuffer bound.** It does not restore what the host had
//     bound, so anything the host draws next lands in Sciter's target unless it rebinds. See
//     `paint_windowless`.
//
// The image comes out the GL way up - row 0 is the *bottom* of the document - so it can be sampled as
// a texture directly, and needs a flip only if it is being written into a top-down image format.
//
// There is no surface for a GPU backend: `pixels`, `stride` and `windowless_pixel` are `.BITMAP`-only,
// and reading the result back is the host's business (`glReadPixels`, or just draw the texture).
//
// **There is no wrapper for `SXM_RESOLUTION` anywhere in this package, and that is deliberate.** The
// call reports success and then kills the process on the next message that drains the posted queue -
// any heartbeat, any input - because setting the resolution posts a media-changed item and draining it
// makes the view reach for a native window frame it does not have. The backtrace names
// `html::iwindow::setup_window_frame`, several frames away from the call that caused it. A view
// therefore runs at the engine's default DPI. If a later engine fixes it, the raw call is
// `sciter.api().SciterProcX(rawptr(view.window), &msg.header)` with a `Sciter_X_Msg_Resolution`.
create_windowless :: proc(
	opts: Windowless_Options,
	allocator := context.allocator,
) -> (
	view: Windowless_View,
	err: Error,
) {
	if !sciter.loaded() {
		return {}, .Not_Loaded
	}
	if opts.width <= 0 || opts.height <= 0 {
		return {}, .Window_Failed
	}

	// Measured: a GPU backend with no proc-address function segfaults inside the engine on the first
	// paint, several calls away from the mistake. Refusing here turns that into an error return.
	if is_gpu_backend(opts.backend) && opts.device == nil {
		return {}, .Window_Failed
	}

	view.allocator = allocator
	view.backend = opts.backend
	view.key = new(u8, allocator)
	view.window = Window(view.key)

	create := sciter.Sciter_X_Msg_Create {
		header = {msg = u32(sciter.Sciter_X_Msg_Code.CREATE)},
		backend = opts.backend,
		device = opts.device,
	}
	if !bool(sciter.api().SciterProcX(rawptr(view.window), &create.header)) {
		free(view.key, allocator)
		return {}, .Window_Failed
	}

	if serr := resize_windowless(&view, opts.width, opts.height, opts.pixels, opts.stride); serr != nil {
		destroy_windowless(&view)
		return {}, serr
	}
	return view, nil
}

// Gives the view a new size and surface - `SXM_SIZE`, which is both the initial sizing and the resize.
//
// With `pixels` nil the view's own buffer is reallocated to fit; with one supplied the caller keeps
// ownership. It must hold `stride * (height - 1) + width * 4` bytes - the last row needs `width*4`, not
// a whole stride, so that a slice ending at the last pixel of a larger image is accepted. Measured:
// resizing a live view and painting again works, and the document reflows to the new size.
//
// **A GPU backend has no surface**: `pixels` and `stride` are ignored, the message carries a zeroed
// `SL_SURFACE`, and it is the host's business to resize whatever it is drawing into. The document still
// reflows to the size given here.
resize_windowless :: proc(view: ^Windowless_View, width, height: i32, pixels: []u8 = nil, stride := 0) -> Error {
	if !sciter.loaded() {
		return .Not_Loaded
	}
	if width <= 0 || height <= 0 {
		return .Window_Failed
	}

	if is_gpu_backend(view.backend) {
		message := sciter.Sciter_X_Msg_Size {
			header = {msg = u32(sciter.Sciter_X_Msg_Code.SIZE)},
			width = u32(width),
			height = u32(height),
		}
		if !bool(sciter.api().SciterProcX(rawptr(view.window), &message.header)) {
			return .Window_Failed
		}
		view.width, view.height = width, height
		return nil
	}

	row := stride if stride > 0 else int(width) * 4
	surface := pixels
	owns := false

	if surface == nil {
		if view.owns_pixels {
			delete(view.pixels, view.allocator)
		}
		surface = make([]u8, row * int(height), view.allocator)
		owns = true
	} else if len(surface) < row * (int(height) - 1) + int(width) * 4 {
		// The last row needs `width*4` bytes, not a whole stride: a caller compositing into a
		// sub-rectangle of a larger image hands over a slice that ends at the image's last pixel, and
		// requiring a full trailing stride would refuse the one arrangement this mode exists for.
		return .Window_Failed
	} else if view.owns_pixels {
		// Handed a buffer after owning one: let ours go rather than leak it behind the caller's.
		delete(view.pixels, view.allocator)
	}

	message := sciter.Sciter_X_Msg_Size {
		header = {msg = u32(sciter.Sciter_X_Msg_Code.SIZE)},
		width = u32(width),
		height = u32(height),
		surface = {bitmap = {pixels = raw_data(surface), stride = u32(row)}},
	}
	if !bool(sciter.api().SciterProcX(rawptr(view.window), &message.header)) {
		if owns {
			delete(surface, view.allocator)
		}
		return .Window_Failed
	}

	view.width, view.height, view.stride = width, height, row
	view.pixels, view.owns_pixels = surface, owns
	return nil
}

// Draws the document into the surface - `SXM_PAINT`. Nothing else writes pixels, and nothing schedules
// this: `Host_Handler.on_invalidate_rect` is what says a repaint is due.
//
// `rect` defaults to the whole surface. `element` paints one layer instead of the tree, with `fore`
// telling the engine whether that layer is in front.
//
// **On a GPU backend this changes GL state and does not put it back.** Measured: the engine's own
// framebuffer is still bound when the call returns, so a host that draws its own scene afterwards has
// to rebind its target first. Nothing else about the state was surveyed - treat the context as the
// engine left it and set what you need.
paint_windowless :: proc(
	view: ^Windowless_View,
	rect: Maybe(sciter.Rect) = nil,
	element: Element = nil,
	fore := true,
) -> Error {
	if !sciter.loaded() {
		return .Not_Loaded
	}
	area :=
		rect.? or_else sciter.Rect{left = 0, top = 0, right = sciter.Int(view.width), bottom = sciter.Int(view.height)}

	message := sciter.Sciter_X_Msg_Paint {
		header = {msg = u32(sciter.Sciter_X_Msg_Code.PAINT)},
		element = sciter.Helement(element),
		isFore = b32(fore),
		rcPaint = area,
	}
	ok := bool(sciter.api().SciterProcX(rawptr(view.window), &message.header))
	return nil if ok else Api_Error.Load_Failed
}

// One turn of the engine's clock - `SXM_HEARTBIT`. This is `heartbeat`'s counterpart for a view with no
// pump: it drains posted work, runs due timers, and lets a load settle.
//
// **`time_ms` is ignored, and the engine uses the wall clock instead.** Measured, which matters because
// the header's parameter invites the opposite belief and the SDK's demo dutifully passes
// `SDL_GetTicks`:
//
//	60 heartbeats as fast as possible, timestamps 0,16,32,...   (2 ms of real time)   no timer fired
//	60 heartbeats, 16 ms of real sleep between them             (978 ms)              setInterval(16) fired 59 times
//	60 heartbeats, timestamp passed as 0 every time, same sleep (978 ms)              fired 59 times
//	one second of sleep with no heartbeats at all               (960 ms)              nothing fired
//
// So the heartbeat is the *pump* and the wall clock is the *clock*: `setTimeout`, `setInterval` and
// `requestAnimationFrame` all work in a windowless view, and none of them can be driven faster or
// slower by lying about the timestamp. A host rendering frames off its own clock - a build machine
// producing an image, a test - gets no timers at all, and should drive animation itself by changing the
// DOM between frames.
windowless_heartbeat :: proc(view: ^Windowless_View, time_ms: u32) {
	message := sciter.Sciter_X_Msg_Heartbit {
		header = {msg = u32(sciter.Sciter_X_Msg_Code.HEARTBIT)},
		time = time_ms,
	}
	sciter.api().SciterProcX(rawptr(view.window), &message.header)
}


// Tells the view it has or has lost the keyboard focus - `SXM_FOCUS`. Send it before keys: a view that
// has never been told it is focused still delivers them here, but a document that styles `:focus` will
// not agree with what the user is looking at.
windowless_focus :: proc(view: ^Windowless_View, got := true) -> bool {
	message := sciter.Sciter_X_Msg_Focus {
		header = {msg = u32(sciter.Sciter_X_Msg_Code.FOCUS)},
		got = b32(got),
	}
	return bool(sciter.api().SciterProcX(rawptr(view.window), &message.header))
}

// A key event - `SXM_KEY`. `code` is a virtual key for `.DOWN` / `.UP` and a character for `.CHAR`.
//
// **This works, and that is worth saying because the mouse does not.** Measured: `.DOWN` on a focused
// `<input>` reaches a script `keydown` handler, and `.CHAR` inserts the character. So a windowless view
// can be typed into - text fields, shortcuts, a whole keyboard-driven UI - while `windowless_mouse` is
// dead. Set the focus first, with `set_focus` on the element and `windowless_focus` on the view.
//
// The return is the engine's "was it handled", and it is not a reliable success signal: a `.DOWN`
// measured as delivered (the script handler ran) still answered false.
windowless_key :: proc(
	view: ^Windowless_View,
	event: sciter.Key_Events,
	code: u32,
	modifiers: sciter.Keyboard_States = sciter.Keyboard_States(0),
) -> bool {
	message := sciter.Sciter_X_Msg_Key {
		header = {msg = u32(sciter.Sciter_X_Msg_Code.KEY)},
		event = event,
		code = code,
		modifiers = modifiers,
	}
	return bool(sciter.api().SciterProcX(rawptr(view.window), &message.header))
}

// A mouse event - `SXM_MOUSE`. Position in the view's coordinates.
//
// **This works, and the note in `docs/EMBEDDING.md` saying it does not was wrong.** That finding came
// from a page whose click target was `position: absolute` with a percentage height, which Sciter lays
// out **one pixel tall** - so every event landed on `<body>`, which had no handler, and the engine was
// blamed for a stylesheet bug. `docs/html-css-js.md` now records the layout rule. It is worth carrying
// the general lesson: when an element does not receive events, ask `location` what shape the engine
// thinks it is before concluding anything about the event system.
//
// What is measured on 6.0.4.9, against elements that have a real box:
//
//   - **`.MOUSE_MOVE`, `.MOUSE_DOWN` and `.MOUSE_UP` are delivered** to the element under the point,
//     and script's `mousemove` / `mousedown` / `mouseup` handlers run.
//   - **The click is synthesised for you.** A down followed by an up produces a `click` on the element
//     without `.MOUSE_CLICK` being sent, exactly as a windowed view does; sending `.MOUSE_CLICK` as
//     well adds nothing.
//   - **`:hover` follows the pointer**, and moves off the old element onto the new one, so hover
//     styling works.
//   - **The return value is always false**, including for events that were delivered and handled. It is
//     not a success signal; ignore it.
//
// **What does not respond is the intrinsic behaviors.** Measured: clicking an `<input>` does not give
// it the caret, clicking a `<button>` fires no `click` on the button, and clicking a checkbox does not
// toggle it - while a plain `<div>` in the same document hears everything. So the DOM event path is
// live and the native widgets' own input handling is not. For those, drive the element directly:
// `set_focus` before `windowless_key` for a text field (measured working - see `windowless_key`),
// `do_click` for a button, `send_mouse` on the element for anything else. Those go through the element
// chain rather than through the view.
windowless_mouse :: proc(
	view: ^Windowless_View,
	event: sciter.Mouse_Events,
	pos: [2]i32,
	button: sciter.Mouse_Buttons = sciter.Mouse_Buttons.MAIN_MOUSE_BUTTON,
	modifiers: sciter.Keyboard_States = sciter.Keyboard_States(0),
) -> bool {
	message := sciter.Sciter_X_Msg_Mouse {
		header = {msg = u32(sciter.Sciter_X_Msg_Code.MOUSE)},
		event = event,
		button = button,
		modifiers = modifiers,
		pos = {x = sciter.Int(pos.x), y = sciter.Int(pos.y)},
	}
	return bool(sciter.api().SciterProcX(rawptr(view.window), &message.header))
}

// Tears the view down - `SXM_DESTROY` - and frees the surface if this package allocated it.
//
// **One destroy ends windowless mode for the whole process.** Measured on 6.0.4.9: after any
// `SXM_DESTROY`, the next `SXM_CREATE` segfaults *inside the create call* - with the same key or a
// fresh one, and whether or not other views are still alive. Two views created before any destroy
// coexist happily, and a second destroy of the same view is a harmless false.
//
// So the shape that works is: create every view you need, use them, destroy them at the end. If a
// long-running host wants a view to come and go, keep one and swap its document with `load_html`
// rather than destroying it - that is measured working, and it is cheaper anyway.
destroy_windowless :: proc(view: ^Windowless_View) {
	if view.window == nil {
		return
	}
	message := sciter.Sciter_X_Msg_Destroy {
		header = {msg = u32(sciter.Sciter_X_Msg_Code.DESTROY)},
	}
	sciter.api().SciterProcX(rawptr(view.window), &message.header)

	if view.owns_pixels {
		delete(view.pixels, view.allocator)
	}
	free(view.key, view.allocator)
	view^ = {}
}

// The pixel at (x, y) as r, g, b, a, whatever order the surface is in. Small, but every host that reads
// one back gets the channel order wrong once, and `PIXEL_ORDER` is easy to forget.
//
// `.BITMAP` only, and zeroes for anything else: a GPU backend's pixels are in the framebuffer the host
// bound, and reading them is the host's own `glReadPixels`.
windowless_pixel :: proc(view: ^Windowless_View, x, y: i32) -> (r, g, b, a: u8) {
	if view.pixels == nil || x < 0 || y < 0 || x >= view.width || y >= view.height {
		return 0, 0, 0, 0
	}
	i := int(y) * view.stride + int(x) * 4
	when PIXEL_ORDER == .BGRA {
		return view.pixels[i + 2], view.pixels[i + 1], view.pixels[i], view.pixels[i + 3]
	} else {
		return view.pixels[i], view.pixels[i + 1], view.pixels[i + 2], view.pixels[i + 3]
	}
}
