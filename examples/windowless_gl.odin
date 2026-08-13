// Sciter rendering on the GPU, into a texture the host owns. No window, no rasteriser, no readback.
//
//   just example windowless_gl        # renders into an FBO texture, writes target/windowless-gl.ppm
//   odin test examples/windowless_gl.odin -file
//
// [`windowless.odin`](./windowless.odin) is the same idea on the CPU: the engine rasterises into a byte
// buffer you allocated. This is the version a game engine or an immediate-mode tool actually wants -
// Sciter draws with its own Skia GPU pipeline straight into **the framebuffer bound to your GL
// context**, so the UI ends up in your texture with nothing copied and nothing uploaded.
//
// **Linux only, and that is about this file rather than about the binding.** Somebody has to create a
// GL context, and doing it without pulling in GLFW or SDL means EGL, which is the Linux/Android API.
// The wrapper itself is platform-agnostic: on Windows you would make a WGL context (or use the
// `.DX11_TEXTURE` backend, untried here) and pass its `wglGetProcAddress` the same way. Everything
// below `create_windowless` is identical.
//
// Four measured rules, none of them in the headers, each with a test:
//
//   - **The context must be desktop OpenGL, not GLES.** On a GLES 3.2 context the engine's own shaders
//     do not compile - Skia emits `#version 150` desktop GLSL and the driver refuses it - and
//     `SXM_PAINT` cheerfully answers true having drawn nothing. Core and compatibility profiles both
//     work. `SL_TARGET_OPENGLES` as a backend is refused outright on this build.
//   - **`device` is a `glGetProcAddress` and is mandatory.** Nil segfaults the engine on the first
//     paint; `create_windowless` refuses it instead.
//   - **The framebuffer binding is captured at create time**, not read at paint time. Bind the FBO you
//     want *before* creating the view; a view made against the default framebuffer keeps painting
//     there however many FBOs you bind later.
//   - **Row 0 is the bottom of the document**, the GL way up, so the texture samples directly and only
//     a top-down image format needs the flip.
//   - **The engine leaves its own framebuffer bound when the paint returns.** It does not put back what
//     the host had bound, so the next thing the host draws lands in Sciter's target unless it rebinds.
//     This cost an hour: a test read "the default framebuffer" straight after a paint and was actually
//     reading the FBO the engine had left bound.
package main

import sciter ".."
import "../sciter_app"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

W :: 400
H :: 300

DOC :: `<html>
<head><style>
  html, body { margin: 0; padding: 0; width: 100%; height: 100%; background: #11111b; color: #cdd6f4;
               font: 16px system; }
  #top { height: 50%; background: #f38ba8; }
  #bottom { height: 50%; background: #a6e3a1; }
  #label { position: absolute; left: 20px; top: 20px; color: #11111b; font-size: 22px; }
</style></head>
<body>
  <div id="top"></div>
  <div id="bottom"></div>
  <div id="label">drawn by the GPU</div>
</body>
</html>`

// ---------------------------------------------------------------------------------------------------
// EGL and GL, declared here rather than imported
//
// `vendor:egl` exists but is missing `eglCreatePbufferSurface`, and pulling a package in for two
// declarations would make this example harder to read than the twenty lines it replaces. The `when` is
// what keeps the file compiling for Windows and macOS, where there is no libEGL to link against.

when ODIN_OS == .Linux {
	foreign import egl_lib "system:EGL"

	EGL_Display :: distinct rawptr
	EGL_Surface :: distinct rawptr
	EGL_Config :: distinct rawptr
	EGL_Context :: distinct rawptr

	@(default_calling_convention = "c", link_prefix = "egl")
	foreign egl_lib {
		GetDisplay :: proc(native: rawptr) -> EGL_Display ---
		Initialize :: proc(display: EGL_Display, major, minor: ^i32) -> b32 ---
		BindAPI :: proc(api: u32) -> b32 ---
		ChooseConfig :: proc(display: EGL_Display, attribs: [^]i32, configs: [^]EGL_Config, size: i32, count: ^i32) -> b32 ---
		CreatePbufferSurface :: proc(display: EGL_Display, config: EGL_Config, attribs: [^]i32) -> EGL_Surface ---
		CreateContext :: proc(display: EGL_Display, config: EGL_Config, share: EGL_Context, attribs: [^]i32) -> EGL_Context ---
		MakeCurrent :: proc(display: EGL_Display, draw, read: EGL_Surface, ctx: EGL_Context) -> b32 ---
		DestroyContext :: proc(display: EGL_Display, ctx: EGL_Context) -> b32 ---
		DestroySurface :: proc(display: EGL_Display, surface: EGL_Surface) -> b32 ---
		Terminate :: proc(display: EGL_Display) -> b32 ---
		GetProcAddress :: proc(name: cstring) -> rawptr ---
	}
}

// The EGL and GL constants used below, so the attribute lists read as themselves.
EGL_NONE :: 0x3038
EGL_SURFACE_TYPE :: 0x3033
EGL_PBUFFER_BIT :: 0x0001
EGL_RENDERABLE_TYPE :: 0x3040
EGL_OPENGL_BIT :: 0x0008
EGL_RED_SIZE :: 0x3024
EGL_GREEN_SIZE :: 0x3023
EGL_BLUE_SIZE :: 0x3022
EGL_ALPHA_SIZE :: 0x3021
EGL_DEPTH_SIZE :: 0x3025
EGL_STENCIL_SIZE :: 0x3026
EGL_WIDTH :: 0x3057
EGL_HEIGHT :: 0x3056
EGL_OPENGL_API :: 0x30A2
EGL_CONTEXT_MAJOR_VERSION :: 0x3098
EGL_CONTEXT_MINOR_VERSION :: 0x30FB

GL_COLOR_BUFFER_BIT :: 0x00004000
GL_RGBA :: 0x1908
GL_UNSIGNED_BYTE :: 0x1401
GL_VERSION :: 0x1F02
GL_TEXTURE_2D :: 0x0DE1
GL_FRAMEBUFFER :: 0x8D40
GL_COLOR_ATTACHMENT0 :: 0x8CE0
GL_FRAMEBUFFER_COMPLETE :: 0x8CD5
GL_TEXTURE_MIN_FILTER :: 0x2801
GL_TEXTURE_MAG_FILTER :: 0x2800
GL_LINEAR :: 0x2601
GL_FRAMEBUFFER_BINDING :: 0x8CA6

// The handful of GL entry points this example needs, loaded through EGL.
Gl :: struct {
	clear_color:         proc "c" (r, g, b, a: f32),
	clear:               proc "c" (mask: u32),
	viewport:            proc "c" (x, y, w, h: i32),
	finish:              proc "c" (),
	read_pixels:         proc "c" (x, y, w, h: i32, format, type: u32, pixels: rawptr),
	get_string:          proc "c" (name: u32) -> cstring,
	gen_textures:        proc "c" (n: i32, ids: [^]u32),
	bind_texture:        proc "c" (target: u32, id: u32),
	tex_image_2d:        proc "c" (target: u32, level, internal, w, h, border: i32, format, type: u32, pixels: rawptr),
	tex_parameter_i:     proc "c" (target, name: u32, value: i32),
	gen_framebuffers:    proc "c" (n: i32, ids: [^]u32),
	bind_framebuffer:    proc "c" (target, id: u32),
	framebuffer_texture: proc "c" (target, attachment, textarget: u32, texture: u32, level: i32),
	check_framebuffer:   proc "c" (target: u32) -> u32,
	get_integer:         proc "c" (name: u32, data: ^i32),
}

// A GL context with no window: an EGL pbuffer, which is as close to "offscreen" as a driver gets.
Context :: struct {
	display: rawptr,
	surface: rawptr,
	ctx:     rawptr,
	gl:      Gl,
	texture: u32,
	fbo:     u32,
}

// The `device` the engine is given. It must be `proc "c"`, and it must outlive the view: the engine
// calls it while loading its GL implementation.
gl_get_proc :: proc "c" (name: cstring) -> sciter.Gl_Function_Pointer {
	when ODIN_OS == .Linux {
		return auto_cast GetProcAddress(name)
	} else {
		return nil
	}
}

// Creates the offscreen context and the texture the UI will land in. `false` means this platform or
// this machine cannot do it, which is a skip rather than a failure.
gl_context_create :: proc(gc: ^Context, width, height: i32) -> bool {
	when ODIN_OS != .Linux {
		return false
	} else {
		display := GetDisplay(nil)
		if display == nil {
			return false
		}
		major, minor: i32
		if !Initialize(display, &major, &minor) {
			return false
		}

		// **`EGL_OPENGL_BIT`, not `EGL_OPENGL_ES2_BIT`.** This is the line the whole example turns on:
		// against a GLES context the engine's shaders do not compile and the paint is silently empty.
		config_attribs := [?]i32 {
			EGL_SURFACE_TYPE,
			EGL_PBUFFER_BIT,
			EGL_RENDERABLE_TYPE,
			EGL_OPENGL_BIT,
			EGL_RED_SIZE,
			8,
			EGL_GREEN_SIZE,
			8,
			EGL_BLUE_SIZE,
			8,
			EGL_ALPHA_SIZE,
			8,
			EGL_DEPTH_SIZE,
			8,
			EGL_STENCIL_SIZE,
			8,
			EGL_NONE,
		}
		config: EGL_Config
		count: i32
		if !ChooseConfig(display, raw_data(config_attribs[:]), &config, 1, &count) || count == 0 {
			return false
		}

		surface_attribs := [?]i32{EGL_WIDTH, width, EGL_HEIGHT, height, EGL_NONE}
		surface := CreatePbufferSurface(display, config, raw_data(surface_attribs[:]))
		if surface == nil {
			return false
		}

		if !BindAPI(EGL_OPENGL_API) {
			return false
		}
		context_attribs := [?]i32{EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 2, EGL_NONE}
		ctx := CreateContext(display, config, nil, raw_data(context_attribs[:]))
		if ctx == nil {
			return false
		}
		if !MakeCurrent(display, surface, surface, ctx) {
			return false
		}

		gc.display, gc.surface, gc.ctx = rawptr(display), rawptr(surface), rawptr(ctx)
		if !gl_load(&gc.gl) {
			return false
		}

		// The host's own render target: a texture with a framebuffer over it. This is the thing a game
		// engine would already have, and the thing it wants the UI inside.
		gl := &gc.gl
		gl.gen_textures(1, &gc.texture)
		gl.bind_texture(GL_TEXTURE_2D, gc.texture)
		gl.tex_image_2d(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
		gl.tex_parameter_i(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
		gl.tex_parameter_i(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)

		gl.gen_framebuffers(1, &gc.fbo)
		gl.bind_framebuffer(GL_FRAMEBUFFER, gc.fbo)
		gl.framebuffer_texture(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, gc.texture, 0)
		if gl.check_framebuffer(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE {
			return false
		}
		gl.viewport(0, 0, width, height)
		return true
	}
}

gl_load :: proc(gl: ^Gl) -> bool {
	when ODIN_OS != .Linux {
		return false
	} else {
		gl.clear_color = auto_cast GetProcAddress("glClearColor")
		gl.clear = auto_cast GetProcAddress("glClear")
		gl.viewport = auto_cast GetProcAddress("glViewport")
		gl.finish = auto_cast GetProcAddress("glFinish")
		gl.read_pixels = auto_cast GetProcAddress("glReadPixels")
		gl.get_string = auto_cast GetProcAddress("glGetString")
		gl.gen_textures = auto_cast GetProcAddress("glGenTextures")
		gl.bind_texture = auto_cast GetProcAddress("glBindTexture")
		gl.tex_image_2d = auto_cast GetProcAddress("glTexImage2D")
		gl.tex_parameter_i = auto_cast GetProcAddress("glTexParameteri")
		gl.gen_framebuffers = auto_cast GetProcAddress("glGenFramebuffers")
		gl.bind_framebuffer = auto_cast GetProcAddress("glBindFramebuffer")
		gl.framebuffer_texture = auto_cast GetProcAddress("glFramebufferTexture2D")
		gl.check_framebuffer = auto_cast GetProcAddress("glCheckFramebufferStatus")
		gl.get_integer = auto_cast GetProcAddress("glGetIntegerv")
		return gl.clear != nil && gl.read_pixels != nil && gl.check_framebuffer != nil
	}
}

gl_context_destroy :: proc(gc: ^Context) {
	when ODIN_OS == .Linux {
		if gc.ctx != nil {
			MakeCurrent(EGL_Display(gc.display), nil, nil, nil)
			DestroyContext(EGL_Display(gc.display), EGL_Context(gc.ctx))
		}
		if gc.surface != nil {
			DestroySurface(EGL_Display(gc.display), EGL_Surface(gc.surface))
		}
		if gc.display != nil {
			Terminate(EGL_Display(gc.display))
		}
	}
	gc^ = {}
}

// One pixel out of the *current* framebuffer, in GL's coordinates - y = 0 is the bottom row.
gl_pixel :: proc(gc: ^Context, x, y: i32) -> [4]u8 {
	px: [4]u8
	gc.gl.finish()
	gc.gl.read_pixels(x, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, &px)
	return px
}

// ---------------------------------------------------------------------------------------------------

main :: proc() {
	when ODIN_OS != .Linux {
		fmt.println("windowless_gl needs EGL and is Linux-only; see the header comment")
		return
	} else {
		if !sciter_app.load_engine() {
			os.exit(1)
		}
		sciter_app.set_default_debug_output()

		gc: Context
		if !gl_context_create(&gc, W, H) {
			fmt.eprintln("could not create an offscreen GL context - is there a display and a GL driver?")
			os.exit(1)
		}
		defer gl_context_destroy(&gc)
		fmt.println("GL context:", gc.gl.get_string(GL_VERSION))

		// The host's frame, drawn first: everything the UI will sit on top of. Here it is one clear.
		gc.gl.clear_color(0.05, 0.05, 0.1, 1)
		gc.gl.clear(GL_COLOR_BUFFER_BIT)

		// **The FBO is bound before the view is created**, because that binding is what the engine
		// captures. Bind it afterwards and the UI goes to the default framebuffer instead.
		gc.gl.bind_framebuffer(GL_FRAMEBUFFER, gc.fbo)

		view, err := sciter_app.create_windowless(
			{width = W, height = H, backend = .OPENGL, device = rawptr(gl_get_proc)},
		)
		if err != nil {
			fmt.eprintln("could not create a GPU-backed view:", err)
			os.exit(1)
		}
		defer sciter_app.destroy_windowless(&view)

		if err := sciter_app.load_html(view.window, DOC, "about:blank"); err != nil {
			fmt.eprintln("could not load the document:", err)
			os.exit(1)
		}

		for i in 0 ..< 10 {
			sciter_app.windowless_heartbeat(&view, time.Duration(i) * 16 * time.Millisecond)
			sciter_app.paint_windowless(&view)
		}

		fmt.println("bottom row (GL y=0):", gl_pixel(&gc, W / 2, 4), "- the document's lower half, #a6e3a1")
		fmt.println("top row    (GL y=H):", gl_pixel(&gc, W / 2, H - 4), "- the document's upper half, #f38ba8")

		// The host drives the document, exactly as in the CPU version: no timers here either.
		root, _ := sciter_app.root(view.window)
		if label, lerr := sciter_app.select_first(root, "#label"); lerr == nil {
			sciter_app.set_text(label, "the host changed this between frames")
			sciter_app.windowless_heartbeat(&view, 200 * time.Millisecond)
			sciter_app.paint_windowless(&view)
		}

		write_ppm("target/windowless-gl.ppm", &gc)
		fmt.println("wrote target/windowless-gl.ppm - the texture the UI was rendered into")
	}
}

// The texture read back and written out, flipped: PPM is top-down and GL is bottom-up.
write_ppm :: proc(path: string, gc: ^Context) -> bool {
	pixels := make([]u8, W * H * 4, context.temp_allocator)
	gc.gl.finish()
	gc.gl.read_pixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, raw_data(pixels))

	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&builder, "P6\n%d %d\n255\n", W, H)
	for y := H - 1; y >= 0; y -= 1 {
		for x in 0 ..< W {
			i := (int(y) * W + int(x)) * 4
			strings.write_byte(&builder, pixels[i])
			strings.write_byte(&builder, pixels[i + 1])
			strings.write_byte(&builder, pixels[i + 2])
		}
	}
	return os.write_entire_file(path, transmute([]u8)strings.to_string(builder)) == nil
}

// ---------------------------------------------------------------------------------------------------
// Tests
//
// One context and one view for all of them, and neither is destroyed - `windowless.odin` records why a
// destroy would take every later test with it. They skip when there is no display, no GL driver, or no
// EGL at all, which is every platform that is not Linux.

@(private = "file")
have_display :: proc() -> bool {
	when ODIN_OS != .Linux {
		return false
	} else {
		return(
			os.get_env("DISPLAY", context.temp_allocator) != "" ||
			os.get_env("WAYLAND_DISPLAY", context.temp_allocator) != "" \
		)
	}
}

@(private = "file")
g_gc: Context

@(private = "file")
g_view: sciter_app.Windowless_View

@(private = "file")
test_gl_view :: proc(t: ^testing.T) -> (^Context, ^sciter_app.Windowless_View, bool) {
	when ODIN_OS != .Linux {
		fmt.println("not Linux - skipping; this example's GL context is EGL, see the header")
		return nil, nil, false
	} else {
		if !have_display() {
			fmt.println("no DISPLAY or WAYLAND_DISPLAY - skipping")
			return nil, nil, false
		}
		if !sciter_app.load_engine() {
			testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
		}
		context.allocator = runtime.default_allocator()

		if g_view.window == nil {
			if !gl_context_create(&g_gc, W, H) {
				fmt.println("no offscreen GL context available - skipping")
				return nil, nil, false
			}
			g_gc.gl.bind_framebuffer(GL_FRAMEBUFFER, g_gc.fbo)

			view, err := sciter_app.create_windowless(
				{width = W, height = H, backend = .OPENGL, device = rawptr(gl_get_proc)},
			)
			testing.expect_value(t, err, nil)
			if err != nil {
				return nil, nil, false
			}
			g_view = view
		}

		testing.expect_value(t, sciter_app.load_html(g_view.window, DOC, "about:blank"), nil)
		for i in 0 ..< 10 {
			sciter_app.windowless_heartbeat(&g_view, time.Duration(i) * 16 * time.Millisecond)
			testing.expect_value(t, sciter_app.paint_windowless(&g_view), nil)
		}
		return &g_gc, &g_view, true
	}
}

// The whole claim: the document is in the host's texture, drawn by the GPU, with nothing copied.
@(test)
test_the_document_is_rendered_into_the_hosts_texture :: proc(t: ^testing.T) {
	gc, view, ok := test_gl_view(t)
	if !ok {return}

	testing.expect_value(t, view.backend, sciter.Sl_Target.OPENGL)
	testing.expect(t, view.pixels == nil, "a GPU backend has no CPU surface")

	// The document is red on top and green below. GL row 0 is the bottom of the framebuffer, so the
	// low row must be the *green* one: the image comes out the GL way up and needs no flip to be
	// sampled as a texture.
	low := gl_pixel(gc, W / 2, 4)
	high := gl_pixel(gc, W / 2, H - 4)

	testing.expect_value(t, [3]u8{low.r, low.g, low.b}, [3]u8{0xa6, 0xe3, 0xa1})
	testing.expect_value(t, [3]u8{high.r, high.g, high.b}, [3]u8{0xf3, 0x8b, 0xa8})
}

// A host-driven change reaches the texture, which is the GPU version of the round trip the CPU example
// makes: Odin -> the DOM -> style -> Skia -> our framebuffer.
@(test)
test_a_host_driven_change_reaches_the_texture :: proc(t: ^testing.T) {
	gc, view, ok := test_gl_view(t)
	if !ok {return}

	before := gl_pixel(gc, W / 2, 4)

	value, err := sciter_app.eval(
		view.window,
		`document.getElementById("bottom").style["background-color"] = "#89b4fa"; 1`,
	)
	testing.expect_value(t, err, nil)
	sciter_app.value_clear(&value)

	sciter_app.windowless_heartbeat(view, 300 * time.Millisecond)
	testing.expect_value(t, sciter_app.paint_windowless(view), nil)

	after := gl_pixel(gc, W / 2, 4)
	testing.expect(t, after != before, "the change should have reached the framebuffer")
	testing.expect_value(t, [3]u8{after.r, after.g, after.b}, [3]u8{0x89, 0xb4, 0xfa})
}

// **The binding is captured at create time, and this is the test that says so.** The view was created
// with the FBO bound; binding the default framebuffer now and painting must leave the default one
// alone and go on filling the texture.
@(test)
test_the_framebuffer_binding_is_captured_when_the_view_is_created :: proc(t: ^testing.T) {
	gc, view, ok := test_gl_view(t)
	if !ok {return}

	// Paint the default framebuffer a colour of our own, then paint the view while *it* is bound.
	gc.gl.bind_framebuffer(GL_FRAMEBUFFER, 0)
	gc.gl.viewport(0, 0, W, H)
	gc.gl.clear_color(1, 0, 1, 1) // magenta appears nowhere in the document
	gc.gl.clear(GL_COLOR_BUFFER_BIT)

	testing.expect_value(t, sciter_app.paint_windowless(view), nil)

	// **Rebinding before reading is not a formality.** The engine leaves its own framebuffer bound when
	// the paint returns, so a read here without this line samples the FBO and looks like the opposite
	// result - which is exactly the mistake this test was written with the first time.
	bound: i32
	gc.gl.get_integer(GL_FRAMEBUFFER_BINDING, &bound)
	testing.expectf(t, u32(bound) == gc.fbo, "the engine should have left its own framebuffer bound, got %d", bound)

	gc.gl.bind_framebuffer(GL_FRAMEBUFFER, 0)
	on_default := gl_pixel(gc, W / 2, H / 2)
	testing.expect_value(t, [3]u8{on_default.r, on_default.g, on_default.b}, [3]u8{0xff, 0x00, 0xff})

	// And the texture - the target this view was created against - has the document in it.
	gc.gl.bind_framebuffer(GL_FRAMEBUFFER, gc.fbo)
	in_texture := gl_pixel(gc, W / 2, H - 4)
	testing.expect_value(t, [3]u8{in_texture.r, in_texture.g, in_texture.b}, [3]u8{0xf3, 0x8b, 0xa8})
}

// A GPU backend with no `glGetProcAddress` segfaults inside the engine on the first paint. The wrapper
// refuses it instead, which is the only reason that is a test rather than a crash.
@(test)
test_a_gpu_backend_without_a_proc_address_is_refused :: proc(t: ^testing.T) {
	if !have_display() || !sciter_app.load_engine() {
		fmt.println("no display or no engine - skipping")
		return
	}
	context.allocator = runtime.default_allocator()

	_, err := sciter_app.create_windowless({width = 64, height = 64, backend = .OPENGL, device = nil})
	testing.expect_value(t, err, sciter_app.Error(sciter_app.Api_Error.Window_Failed))
}

// `.BITMAP` keeps working in the same process, which is what a host with both a GPU pane and an
// offscreen render would do. It also pins that the two backends do not share state.
@(test)
test_a_bitmap_view_still_works_alongside_a_gpu_one :: proc(t: ^testing.T) {
	_, _, ok := test_gl_view(t)
	if !ok {return}

	// The engine holds this for the life of the process - it is never destroyed, because one destroy
	// ends windowless mode for everything - so it is not the test runner's to account for.
	context.allocator = runtime.default_allocator()

	bitmap, err := sciter_app.create_windowless({width = 64, height = 64})
	testing.expect_value(t, err, nil)
	if err != nil {return}

	testing.expect(t, bitmap.pixels != nil, "a bitmap view allocates a surface")
	testing.expect_value(
		t,
		sciter_app.load_html(
			bitmap.window,
			`<html><body style="margin:0;background:#f9e2af"></body></html>`,
			"about:blank",
		),
		nil,
	)
	for i in 0 ..< 8 {
		sciter_app.windowless_heartbeat(&bitmap, time.Duration(i) * 16 * time.Millisecond)
		testing.expect_value(t, sciter_app.paint_windowless(&bitmap), nil)
	}

	r, g, b, _ := sciter_app.windowless_pixel(&bitmap, 32, 32)
	testing.expect_value(t, [3]u8{r, g, b}, [3]u8{0xf9, 0xe2, 0xaf})
}
