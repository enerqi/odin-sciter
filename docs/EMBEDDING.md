# Embedding Sciter in someone else's renderer

Sciter is usually described as a way to *build* a window. It also has a second mode, barely documented,
in which it builds nothing: you hand it a pixel buffer or a GPU texture, it draws the document into that,
and you composite the result yourself. That makes it a component inside an application whose frames
somebody else owns — a game engine, a Dear ImGui or raylib tool UI, anything already running its own
draw loop. See [`ALTERNATIVES.md`](./ALTERNATIVES.md#immediate-mode-in-detail) for where that sits among
the other ways to get a page into a native app.

**The mode is supported by this package**: `sciter_app/windowless.odin` wraps every `SXM_*` message, and
[`examples/windowless.odin`](../examples/windowless.odin) is a worked embedding with eleven tests -
including one that renders a view straight into a rectangle of a larger image the host owns. Everything
else in the package works on a view unchanged, because the view's `window` field is an ordinary
`Window`:

```odin
view, _ := sciter_app.create_windowless({width = 320, height = 240})
sciter_app.load_html(view.window, DOC, "about:blank")
sciter_app.windowless_heartbeat(&view, 0)
sciter_app.paint_windowless(&view)   // view.pixels is now RGBA
```

Everything below was measured against the vendored `libsciter.so` 6.0.4.9 on Linux x64 - first by
[`spike/windowless/main.odin`](../spike/windowless/main.odin) and then, in more detail, by the example
and its tests. Not read off the headers.

**One earlier finding on this page has been retracted**: the mouse works, and the section that said it
did not is kept below with the reason it was wrong, because the mistake is more instructive than the
correction.

```sh
just example windowless              # the wrapped version, writes three PPMs
odin run spike/windowless            # the original spike
odin run spike/windowless -- res     # reproduces the SXM_RESOLUTION crash
```

## The API

`SciterProcX(hwnd, msg)` plus the `SXM_*` messages in `sciter-x-msg.h`. It is a real `ISciterAPI` slot
(`sciter-x-api.h:263`) and is already bound — `sciter.odin:2725`, with every message struct beside it.

| Message | Carries |
| --- | --- |
| `SXM_CREATE` | `Sl_Target` — `BITMAP`, `OPENGL`, `OPENGLES`, `DX9_TEXTURE`, `DX11_TEXTURE` — plus a `device`. For GPU targets that is an `ID3D11Device*` or, per the header's own comment, a `glGetProcAddress` "like SDL_GL_GetProcAddress". `BITMAP` takes `nil` |
| `SXM_SIZE` | width, height, and an `Sl_Surface`: either a `texture` pointer or `bitmap{pixels, stride}`. **You allocate it.** The engine never owns a surface |
| `SXM_PAINT` | `rcPaint`, plus an optional layer `element` + `isFore` |
| `SXM_HEARTBIT` | a timestamp. Drives timers, transitions, animations and the posted-work queue |
| `SXM_MOUSE` / `SXM_KEY` / `SXM_FOCUS` | synthetic input, in document coordinates |
| `SXM_RESOLUTION` | pixels per inch |
| `SXM_DESTROY` | teardown |

## What HWINDOW is when there is no window

The one thing the headers never say. **It is an opaque key, not a handle.** The engine keys its view map
on the pointer value and never dereferences it as a window.

Confirmed twice: the SDK's own cross-platform windowless demo (`demos.lite/lite-sdl/raster/main.cpp` in
`sciter-js-sdk`) passes an `SDL_Window*`, which is not an OS window handle either; and the spike here
passes a literal `rawptr(uintptr(0xBEEF))`, which works end to end.

The Windows-only `demos.lite/lite-bitmap` demo passes a real `HWND`, which is what makes this look
ambiguous — but that demo needs the `HWND` for its own Win32 message loop, not for Sciter.

## The working sequence

Order matters, and it is not the order a windowed app uses.

```
SciterProcX(SXM_CREATE{BITMAP, nil})
SciterSetCallback(...)          // SC_INVALIDATE_RECT is how the view asks to be repainted
SciterSetupDebugOutput(...)     // no window means no console; script errors are otherwise silent
SciterProcX(SXM_SIZE{w, h, {pixels, stride}})
SciterLoadHtml(..., "about:blank")
loop:
  SciterProcX(SXM_HEARTBIT{t})
  SciterProcX(SXM_PAINT{rc})    // when SC_INVALIDATE_RECT says to
SciterProcX(SXM_DESTROY)
```

**Do not call `SciterExec(.INIT, argc, argv)`.** Every windowed example in this repository does, and the
SDK's windowless demo does not — it stands up the windowed application subsystem, which is the thing a
windowless view is trying not to have.

## Pixel format

`sciter-x-msg.h` says only "RGBA or BGRA". Measured on Linux x64, with three different page colours to
rule out coincidence: **RGBA**. The SDK demo agrees and states the rule the header omits —
`SDL_PIXELFORMAT_BGRA32` under `#ifdef WINDOWS`, `SDL_PIXELFORMAT_RGBA32` everywhere else.

## What works

Against 6.0.4.9 on Linux x64, with no window anywhere in the process:

- Rendering the whole document into a buffer we allocated — verified as a full 320×240 surface, not a
  partial paint.
- CSS.
- QuickJS at load. A `<script>` that rewrites `document.body.style` runs and the change reaches the
  pixels.
- The DOM API on a windowless view: `SciterGetRootElement`, `SciterFindElement` — hit-testing resolves a
  point to the right element.
- `SciterEval` from the host, and the repaint that follows it. This is the whole embedder round trip:
  Odin → QuickJS → style → paint into our buffer.
- `SXM_FOCUS`.
- **Mouse and keyboard input** to the document's own handlers, and `:hover` — see the retraction below.
- **Resizing a live view**: a second `SXM_SIZE` with a new surface reflows the document into it.
- **Several views at once**, each with its own key, document and surface.
- **The host's own memory as the surface**, at the host's own stride — so a view can render directly
  into a rectangle of a larger image with no intermediate buffer and no copy.
- **`Host_Handler.on_invalidate_rect`**, which is how the view says a repaint is due. It works on a
  fabricated key like every other host notification.

## What is broken

Engine defects in this build, not binding problems.

### `SXM_RESOLUTION` crashes

The call itself returns `TRUE`. The crash happens **later**, the next time anything drains the posted
queue — any heartbit, any mouse message:

```
wing::window::setAttribute(int, int)
html::iwindow::setup_window_frame(gool::WINDOW_STATE)
html::view::on_media_changed()
qjs::xview::on_media_changed()
html::view::process_posted_things(bool)
html::view::handle_on_idle()
html::view::on_idle()
lite::view::proc_x(void*, SCITER_X_MSG*)
```

Setting the resolution posts a media-changed item; draining it makes the view reach for a native window
frame it does not have. Because the fault surfaces one message later than its cause, it reads as "heartbit
crashes" until you bisect. Omit `SXM_RESOLUTION` and everything above works — at the cost of no DPI
control.

### One `SXM_DESTROY` ends windowless mode for the process

Measured: after any destroy, the next `SXM_CREATE` segfaults **inside the create call** — with the same
key or a fresh one, and whether or not other views are still alive. A second destroy of an
already-destroyed view is harmless (it answers `FALSE`), and views created *before* any destroy coexist
happily.

So the shape that works is: create the views you need, keep them, and destroy them on the way out. A
long-running host that wants a view to come and go should swap its document with `SciterLoadHtml`
instead — measured working, as often as you like, and cheaper anyway.

### ~~`SXM_MOUSE` is never handled~~ — **retracted 2026-08-12. It was this page's own test document.**

This section used to say that no mouse event ever reaches a windowless document, and concluded that the
mode was display-only. **That was wrong, and the cause is worth more than the correction.**

The spike caught clicks with a full-size transparent overlay, the way a browser page would:

```css
#hit { position: absolute; left: 0; top: 0; width: 100%; height: 100%; }
```

Sciter lays that out **401 × 1** — the width resolves, the percentage height does not. So the overlay was
one pixel tall, every click landed on `<body>`, which had no handler, and the engine took the blame. The
layout rule is now in [`html-css-js.md`](./html-css-js.md); the general lesson is to ask
`location(el, .Border, .View)` what shape the engine thinks an element is *before* concluding anything
about the event system.

What is measured now, against elements with a real box (`examples/windowless.odin` pins all of it):

- `MOUSE_MOVE`, `MOUSE_DOWN` and `MOUSE_UP` are delivered to the element under the point, and script's
  `mousemove` / `mousedown` / `mouseup` handlers run.
- **The click is synthesised for you** from a press and a release, as in a windowed view. Sending
  `MOUSE_CLICK` as well adds nothing.
- `:hover` follows the pointer, moving off the old element onto the new one.
- **The return value is always `FALSE`**, including for events that were delivered and handled. It is
  not a success signal.
- `SXM_KEY` works too: `.DOWN` reaches a script `keydown` handler and `.CHAR` inserts the character into
  a focused field.

### The remaining input hole: intrinsic behaviors ignore the mouse

Real, and much narrower than the retracted claim. In the same document, with the same clicks:

- clicking an `<input>` does **not** give it the caret,
- clicking a `<button>` fires **no** `click` on the button,
- clicking a checkbox does **not** toggle it,

while a plain `<div>` beside them hears everything. The DOM event path is live; the native widgets' own
input handling is not. Drive those through the element instead — `set_focus` before sending keys,
`do_click` for a button, `send_mouse` on the element for anything else. All three are measured working
on a windowless view.

**Consequence.** This is an interactive embedding for anything whose behaviour you write yourself, and a
display embedding for anything that leans on Sciter's built-in widgets.

### It still needs a display

The surprise of the exercise, and the thing the name argues against. With `DISPLAY` and
`WAYLAND_DISPLAY` both unset on Linux, **`SXM_CREATE` segfaults** — before a document, a surface or a
paint. "Windowless" means the engine creates no window of its own, not that it can run without a
windowing system. A headless build machine would need `xvfb-run` or equivalent; that was not verified
here, because the machine this was measured on has no Xvfb.

### The clock is the wall clock, and `SXM_HEARTBIT`'s timestamp is ignored

Not a defect, but it decides how an embedder animates anything. Measured four ways:

| | real time | result |
| --- | --- | --- |
| 60 heartbeats as fast as possible, timestamps 0, 16, 32, … | 2 ms | nothing fired |
| 60 heartbeats, 16 ms of real sleep between them | 978 ms | `setInterval(16)` fired 59 times |
| 60 heartbeats, timestamp passed as **0** every time, same sleep | 978 ms | fired 59 times |
| one second of sleep, no heartbeats at all | 960 ms | nothing fired |

So the heartbeat is the *pump* and the wall clock is the *clock*: timers work, and no timestamp you pass
can make them run faster or slower. The consequence for a host that renders faster than real time — a
build machine writing out an image, a test — is that it gets no timers, and has to drive anything
animated itself by changing the DOM between frames. `examples/windowless.odin` does that for its
progress bar.

This was first written up here as "script timers never fire", from a loop of sixty heartbeats that took
two milliseconds. The test that pinned it then failed under ASan by *succeeding* — everything was slow
enough for a 16 ms interval to fire.

## Do not size a window to test this

Unrelated to windowless mode, found while testing it, and destructive enough to write down:
`SciterCreateWindow` with `SW_MAIN` and a 320×240 frame **changes the X display mode** to the nearest
match — the desktop drops to 320×180. It is a display-wide mode-set, not a window resize. Recover with:

```sh
xrandr --output eDP-1 --mode 1920x1200 --rate 60
```

## Related: Sciter hosting a real webview

The inverse arrangement, and the SDK ships it: `sciter-webview/behavior_webview.cpp` is a native behavior
that embeds the OS webview as an element inside a Sciter document. Not measured here — noted because
"put a real browser pane in the app" and "put the app's UI in a Sciter pane" are different questions with
different answers.
