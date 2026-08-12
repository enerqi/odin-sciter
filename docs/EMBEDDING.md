# Embedding Sciter in someone else's renderer

Sciter is usually described as a way to *build* a window. It also has a second mode, barely documented,
in which it builds nothing: you hand it a pixel buffer or a GPU texture, it draws the document into that,
and you composite the result yourself. That makes it a component inside an application whose frames
somebody else owns — a game engine, a Dear ImGui or raylib tool UI, anything already running its own
draw loop. See [`ALTERNATIVES.md`](./ALTERNATIVES.md#immediate-mode-in-detail) for where that sits among
the other ways to get a page into a native app.

Everything below was measured against the vendored `libsciter.so` 6.0.4.9 on Linux x64 by
[`spike/windowless/main.odin`](../spike/windowless/main.odin), not read off the headers. Two of the
findings are engine defects, and neither is visible from the headers at all.

```sh
odin run spike/windowless            # the configuration that works
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

## What is broken

Both are engine defects in this build, not binding problems.

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

### `SXM_MOUSE` is never handled

`MOUSE_ENTER`, `MOUSE_MOVE`, `MOUSE_DOWN`, `MOUSE_UP` and `MOUSE_CLICK` all return `FALSE`, and no
handler in the page fires. Ruled out as causes:

- Not geometry — `SciterFindElement` resolves the same coordinate to the right element.
- Not a script error — `SciterSetupDebugOutput` is attached and prints nothing.
- Not focus — `SXM_FOCUS` returns `TRUE`, and sending it first changes nothing.
- Not the event sequence — enter/move/down/up/click, with heartbits interleaved, behaves identically.

Plausibly downstream of the resolution defect (an unset device resolution leaving the input transform
unusable), since the two cannot be tested together — sending `SXM_RESOLUTION` crashes on the first mouse
message. Stated as a hypothesis; it is not proven.

**Consequence.** Today this is a *display* embedding, not an *interactive* one. A Sciter pane inside an
immediate-mode app can render and can be driven from the host through `SciterEval` and the DOM API — which
covers overlays, HUDs, documentation panes, rich text, charts and anything host-driven. It cannot yet
receive the user's mouse.

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
