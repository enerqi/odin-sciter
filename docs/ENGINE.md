# What the engine is made of

Everything below was measured against the vendored `lib/linux/x64/libsciter.so` (Sciter.JS 6.0.4.9,
`SCITER_API_VERSION` 10) with `readelf`, `nm`, `strings` and the engine's own runtime reporting. Nothing
here is quoted from sciter.com. The commands are given so the same page can be filled in for Windows
when that machine is available — see [Windows, when it is vendored](#windows-when-it-is-vendored).

It matters for three practical reasons: what has to be installed on a user's machine, what the engine
will and will not do at runtime, and which failures are the engine's rather than the bindings'.

## The one-line answer

```
Window.this.graphicsBackend  ->  "x11-opengl-skia"
navigator.userAgent          ->  "Sciter.JS/6.0.4.9 (Linux;Ubuntu 25.04;en)"
```

A **Skia** renderer on a **GPU** surface, in a window the engine opens itself through its own
**X11/Wayland** layer, scripted by **QuickJS**. No Chromium, no GTK/Qt widget toolkit, no browser
engine — and no toolkit dependency to install.

## The pieces

| Part | What it is | How that was established |
| --- | --- | --- |
| Rendering | **Skia** (milestone m137), Ganesh GPU backend | `skgpu::ganesh` (561 exported symbols), `sktext::gpu`, string `Skia/PDF m137` |
| Text layout | `skia::textlayout` | 373 exported symbols |
| Text shaping | **HarfBuzz**, statically linked | `hb_shape*` defined in the binary; `SkShaper::PurgeHarfBuzzCache`, `ShaperHarfBuzz` |
| Fonts | **FreeType** + **Fontconfig**, dynamically linked to the system's | `readelf -d` NEEDED |
| Vector animation | **Skottie** — Skia's Lottie player | 653 `skottie::` symbols |
| Script | **QuickJS**, with libbf for bignums | string `QuickJS memory usage -- BigNum 2024-01-13 version`; `bf_*`, `JS_NewRuntime` |
| Images | **libwebp** (192 symbols) and **libjpeg** built in; **libpng16** and **zlib** linked to the system's | `nm -D`, `readelf -d` |
| Windowing | the engine's own layer, `wing::` | `wing::internal::PollEventsX11` and friends, 501 symbols |
| Object model | `sciter::om` — the SOM layer behind `som_asset_t` | 164 symbols |
| DOM / layout | `html::view`, `html::element`, `html::behavior` (2417 symbols — the built-in behaviors are most of the engine) | `nm -D` + `c++filt` |

### How big each part is

`libsciter.so` is 25 015 296 bytes, of which `.text` is 10 604 400. Summing the sizes of the dynamic
symbols by owner gives a floor for each component — a floor, not a total, because everything with
internal linkage is invisible here:

| | |
| --- | --- |
| Skia (`Sk*`, `skgpu`, `sktext`, `Gr*`) | 2.52 MB |
| `html::` — DOM, layout, the built-in behaviors | 1.83 MB |
| `tool::` — the engine's own containers, strings and async | 0.52 MB |
| `wing::` — windowing, all platforms | 0.15 MB |
| skottie | 0.14 MB |
| libjpeg / HarfBuzz / libwebp | 0.13 / 0.11 / 0.09 MB |

```sh
nm -D -C -S --defined-only lib/linux/x64/libsciter.so
```

The interesting number is the small one: **windowing is 0.15 MB**. Whatever a Sciter port to a new
platform costs, it is not the size of the engine — which is the context for the mobile question below.

## What it links, and what it only looks for

Two different lists, and the difference is the deployment story.

**Linked at load time** (`readelf -d lib/linux/x64/libsciter.so | grep NEEDED`) — these must be present
or the library does not open at all:

```
libuuid.so.1  libfontconfig.so.1  libfreetype.so.6  libGLESv2.so.2  libEGL.so.1
libstdc++.so.6  libm.so.6  libgcc_s.so.1  libc.so.6
```

**Looked for at runtime**, by name, and simply not used if missing
(`strings -a libsciter.so | grep -E '^lib.*\.so'`):

| Group | Libraries |
| --- | --- |
| X11 | `libX11.so.6`, `libX11-xcb.so.1`, `libXcursor`, `libXext`, `libXi`, `libXinerama`, `libXrandr`, `libXrender`, `libXxf86vm` |
| Wayland | `libwayland-client`, `libwayland-cursor`, `libwayland-egl`, `libdecor-0`, `libxkbcommon` |
| GPU | `libvulkan.so.1`, `libGL`, `libGLX`, `libOpenGL`, `libGLESv1_CM`, `libOSMesa` |
| Audio | `libasound`, `libpulse`, `libjack` |
| Network | `libcurl.so.4` |
| Dialogs | `libgtk-4.so` |
| Text | `libicui18n` |
| Video | `libvlc`, `libvlc/libvlc.so` |

So the engine runs on X11 **or** Wayland, with Vulkan **or** OpenGL **or** software, with PulseAudio
**or** ALSA **or** JACK, and needs none of them installed to start.

**`<video>` is the one feature that is silently missing rather than degraded.** `behavior: video` is
implemented by `html::behavior::vlc_video_ctl` — the mangled name is right there in the dynamic symbol
table, alongside `libvlc_media_player_*` thunks — and it needs libVLC found at runtime. The SDK's
CHANGELOG says the same in one line: "`<video>` is (optionally) baked by libVLC. If you need `<video>`
in your application place `libvlc.so|dll|dylib` in the same folder as `sciter.dll` or install vlc
player (or `libvlc-dev` on Linux) on target machine."

Without it the behavior does not attach at all. The element stays a `<video>` in the DOM, `style
.behavior` still reads `"video"`, and everything downstream is quietly absent: no control type, no
`element_asset`, no `VIDEO_BIND_RQ`, and `video.load` / `video.play` undefined in script. There is no
error anywhere. This machine has no libvlc, so that is the measured state, not the inferred one.

**`behavior: custom-video` is unaffected** — it is `html::behavior::custom_video_ctl` and falls through
to `zero_video_ctl` for the rendering site, which touches no codec library. That is the behavior
[`video.odin`](../sciter_app/video.odin) is built on, and why streaming host-generated frames works on
a machine where `<video src="...">` cannot play anything.

GTK4 is loaded for the parts that have to look native — dialogs (`Window.this.selectFile`), popovers and
monitor enumeration; the mangled names in the binary are `func_proxy<void(_GtkWidget*, cairo_rectangle_int*)>`
and friends, GDK types rather than a Cairo renderer. The document's own UI is not built on it, which is
why no GTK dependency shows up in `ldd`.

TLS for the built-in HTTP client is **mbedTLS**, compiled in — hence `SciterSetOption(.SET_ROOT_CA, …)`
taking certificates "in format acceptable by `mbedtls_x509_crt_parse()`". libcurl is the other path,
selected with `.USE_INTERNAL_HTTP_CLIENT`.

## How the pieces stack

Skia, X11, Vulkan and OSMesa get named together often enough that it is worth saying plainly: they are
four different layers, not four alternatives. **Skia never hears about X11.**

```
 your Odin code  ->  ISciterAPI
 engine: html::view / html::element / html::behavior, layout, QuickJS
        | draw calls (SkCanvas)
 Skia - geometry, text, images. Knows nothing about windows.
        | one Skia backend
   +--------------------------+----------------------+
   | Ganesh (GPU)             | raster (CPU)         |
   | targets GL / GLES / VK   | writes a pixel buffer|
   +------------+-------------+----------+-----------+
   EGL: a GL context on a native surface  | blit
        |                                 |
 wing:: windowing - X11 (Xlib) or Wayland
        |
 Mesa/driver -> GPU        or        OSMesa - OpenGL in software, no GPU
```

- **X11 / Wayland** — windowing: a surface, input, the clipboard. Interchangeable, chosen at runtime by
  which libraries dlopen successfully. This is the first field of the backend id.
- **Vulkan / OpenGL / GLES** — the GPU API Skia's Ganesh backend renders through. Interchangeable,
  chosen by `.SET_GFX_LAYER`. Second field of the id.
- **EGL** is the glue between those two: it makes a GL context *on* an X11 or Wayland surface. It is
  hard-linked along with GLESv2, which is why OpenGL is the path you get by default.
- **OSMesa** is not an alternative to Skia — it is an implementation of OpenGL in software. Same
  `-opengl-` path, no GPU underneath. Different from Skia's own raster backend, which skips GL entirely
  and blits pixels to the window.
- **ANGLE**, in the `-dx11-angle-skia` ids, is OpenGL translated onto Direct3D — a Windows concern.

Which is what the backend id says out loud: `x11-opengl-skia` is an X11 surface, an OpenGL context, and
Skia doing the drawing.

## Choosing the graphics layer

The backend id is `<windowing>-<gpu>-skia`. Every variant the binary can print:

```
%s-raster-skia   %s-opengl-skia   %s-opengl-angle-skia   %s-vulkan-skia   %s-vulkan-angle-skia
%s-dx9-angle-skia   %s-dx11-angle-skia   %s-dx12-skia   %s-metal-skia   %s-metal-angle-skia
```

`SciterSetOption(.SET_GFX_LAYER, …)` picks one, before any window is created:

```odin
sciter_app.set_option(.SET_GFX_LAYER, uintptr(sciter.Gfx_Layer.SKIA_OPENGL))
```

`sciter.Gfx_Layer.SKIA_GPU` is "the best one for this platform", and the header states the preference
order: **Windows** DX12 → Vulkan → OpenGL → Raster, **macOS** Metal → Vulkan → OpenGL → Raster,
**Linux** Vulkan → OpenGL → Raster.

Measured on this machine (X11, Mesa), reading `Window.this.graphicsBackend` back afterwards:

| `SET_GFX_LAYER` | Reported backend |
| --- | --- |
| not set (default) | `x11-opengl-skia` |
| `.SKIA_OPENGL` (5) | `x11-opengl-skia` |
| `.SKIA_GPU` (9) | `x11-opengl-skia` |
| `.SKIA_RASTER` (4) | `x11-unknown` |
| `.SKIA_VULKAN` (6) | `x11-unknown` |

So the "best GPU layer" resolves to OpenGL here rather than Vulkan, and the two layers that report
`x11-unknown` do not report themselves — which is worth knowing before treating that string as a health
check.

## What the dead slots tell you

`ISciterAPI` never shrinks. A call the engine no longer implements keeps its place in the struct as an
`LPVOID`, because removing it would shift every slot after it — which is exactly the failure mode
`api_map` exists to catch. The upshot is that the table is a record of what Sciter used to be, and the
vendored headers annotate it themselves:

```c
LPVOID   SciterProc;              // NULL     sciter-x-api.h:61
LPVOID   SciterProcND;            // NULL
LPVOID   SciterTranslateMessage;  // NULL
LPVOID   SciterRenderD2D;         // N/A
LPVOID   SciterD2DFactory;        // N/A
LPVOID   SciterDWFactory;         // N/A
LPVOID   SciterCreateNSView;      // NULL
LPVOID   SciterCreateWidget;      // NULL
```

| Gone | What it was | What replaced it |
| --- | --- | --- |
| `SciterProc` / `SciterProcND` / `SciterTranslateMessage` | the Win32 message-proc API — you pumped Sciter inside *your* window procedure | the engine owns its windows and its pump: `SciterExec` |
| `SciterRenderD2D` / `SciterD2DFactory` / `SciterDWFactory` | Direct2D + DirectWrite rendering on Windows | Skia everywhere |
| `SciterCreateNSView` | embedding into a Cocoa `NSView` | `SciterCreateWindow` only |
| `SciterCreateWidget` | embedding into a GTK widget | `SciterCreateWindow` only |

So Sciter stopped being *a widget you drop into someone else's toolkit* and became *a window that opens
itself*. Everything about `app.odin` — no GTK main loop, no Win32 pump, `SciterExec` as the whole story —
follows from that one change.

`Gfx_Layer` records the rendering history in a single enum, three eras deep:

```
GDI   = 1, /*Mac OS*/     // Windows GDI
CG    = 1, /*Mac OS*/     // macOS CoreGraphics
CAIRO = 1, /*GTK*/        // Linux Cairo
SKIA  = 4,                // ... and now one renderer, everywhere
```

Native toolkit renderer per platform, then D2D / CoreGraphics / Cairo, then Skia with a choice of GPU
backend. The old names still occupy value 1, which is why they read as aliases of each other.

### TIScript, and what is left of it

Sciter's own scripting language is gone — the engine is QuickJS — but the headers are full of its
fingerprints:

| Where | What is left |
| --- | --- |
| `sciter-x-value.h:21`, `sciter-x-def.h:26` | `#define HAS_TISCRIPT`, still defined |
| `sciter-x-api.h:382` | `//tiscript::ni( _api->TIScriptAPI() );` — the slot is gone, the call is commented out |
| `sciter-x-behavior.h:831` | `//OBSOLETE: case HANDLE_TISCRIPT_METHOD_CALL:` |
| `value.h`, `sciter-x-dom.h` | doc comments about `tiscript::value` and `tiscript::pinned` |
| `sciter-x-def.h:722` | `<script src="sciter:lib/root-extender.tis">` in an example |

`strings` finds exactly **one** `tiscript` in the binary, and there is no `TIScriptAPI` slot in the
table these bindings generate from.

What survived the swap is `VALUE` — the same tagged struct is the Odin↔script bridge that it was for
TIScript, which is why `value.h` still describes fields as "Sciter or TIScript specific" and why native
functors (`ValueNativeFunctorSet`) are still how a host procedure becomes callable from script. See
[`calling-between-odin-and-js.md`](./calling-between-odin-and-js.md).

The practical rule when reading anything found online: **API-level material from the TIScript era mostly
still applies; script-level material does not.** `view.`, `self.`, `$(...)` as syntax and `.tis` modules
are all gone; `document`, `Window.this`, `element.on(...)` and ES modules are what 6.x runs.

### What 6.x removed, measured here

- GTK is no longer the Linux backend — the engine's own `wing::` layer plus EGL is
  ([`PLAN.md`](./PLAN.md) §4). GTK4 is still dlopened, for dialogs and popovers only.
- The `SW_TITLEBAR` / `SW_RESIZEABLE` / `SW_CONTROLS` / `SW_GLASSY` / `SW_ALPHA` / `SW_TOOL` window flags
  are gone; a plain top-level window is the default and chrome is a CSS concern.
- There is no window-title API: the title comes from the document's `<title>`.
- `SciterGetViewExpando` returns NULL on every platform, so there is no `globalThis` Value to assign
  into; `SciterSetVariable` is the route that works, and is what `set_global` uses.

The window changes are described where they bite, in [`api.md`](./api.md#windows--windowodin); the
`SciterGetViewExpando` one is a known issue in [`CHANGELOG.md`](../CHANGELOG.md), with what the wrapper
does instead.

## Direction the source hints at

There is no roadmap in the vendored tree, and nothing below is quoted from the vendor. It is what the
API surface implies, which is a weaker claim than a plan but a stronger one than a guess.

### Sciter inside someone else's renderer

`sciter-x-vulkan.h` is the piece that does not serve the same use case as the rest of the table.
`SciterWindowExec(hwnd, .SET_VULKAN_BRIDGE, …)` takes **your** Vulkan objects:

```c
typedef struct SciterVulkanContext {
  VkInstance vkInstance;  VkPhysicalDevice vkPhysicalDevice;  VkDevice vkDevice;
  VkSurfaceKHR vkSurface; VkSwapchainKHR vkSwapchain;
  VkImage *vkImages;      uint32_t vkCurrentBackbufferIndex;  ...
} SciterVulkanContext;
```

with a callback interface documented as *"draw to the SkSurface which holds the underlying image"*. That
is Sciter rendering into a host application's swapchain: a UI layer inside a game engine, a CAD tool, a
simulator — rather than an application window of its own. Everything else in `ISciterAPI` assumes the
engine owns the window; this assumes it does not.

It is a C++ class with virtual methods, not a C struct, so it is **not reachable through `ISciterAPI`**
and not wrappable from Odin without a small C++ shim that implements the vtable. Worth knowing before
anyone plans on it.

Smaller signals, all in the current headers: `.ENABLE_DIRECT_COMPOSITION` (Windows 11),
`.ENABLE_UIAUTOMATION` (accessibility), `.SET_ROOT_CA` (mbedTLS), ANGLE variants of every GPU backend,
`.EXTENDED_TOUCHPAD_SUPPORT`. Consolidation on one rendering stack, and catching up per platform.

### Mobile

The platforms are already in the platform-detection chain that every build compiles through — not
leftovers in a comment:

```c
// sciter-x-primitives.h
#if TARGET_IPHONE_SIMULATOR || TARGET_OS_IPHONE
  #define IOS
#elif TARGET_OS_MAC
  #define OSX
...
#elif defined(__ANDROID__)
  #define ANDROID
```

```c
// sciter-x-types.h, the ANDROID branch
#define HWINDOW LPVOID
#define HDC LPVOID    // not used anyway, draws on OpenGLESv2
```

`sciter-x-api.h` carries an `#elif defined(ANDROID)` branch for obtaining the table through `dlfcn`. So
the API surface is portable to both, and Android has been built at some point.

What fits with no redesign: Skia over GLES2 **is** the mobile rendering stack; QuickJS is the engine a
size-constrained project would choose anyway; there is no widget toolkit to port; `HWINDOW` is already
opaque; and `run_once` / `heartbeat` are the right shape for a host-driven frame loop.

What is missing:

- **A `wing::` backend per platform** — `ANativeWindow` plus an Activity and an IME on Android, `UIView`
  and `CADisplayLink` on iOS. 0.15 MB of symbols on Linux, and all of the input, clipboard and lifecycle
  plumbing.
- **Touch is declared, not finished.** `HANDLE_GESTURE` is a live event group, but the `GESTURE_CMD`
  enum next to it — pan, zoom, rotate, tap — is commented out in `sciter-x-behavior.h`.
- **No application lifecycle in the table**: suspend, resume and low-memory have no slots.
- **No mobile binary here.** This checkout vendors Linux x64 only, and that binary contains no Android
  code — the `android` strings in it are EGL extension names (`EGL_ANDROID_blob_cache` and friends).
  Whether upstream ships one is an `ls bin*` away in a `sciter-js-sdk` checkout.
- **Dynamic linking only** without a commercial licence: workable as an embedded iOS framework or an
  Android `.so`, but static linking is not an option on either.

For these bindings, a mobile port would mostly land in the two places that already exist for it:
`SCITER_DLL_NAME` and the library search order (per-platform already), and window creation, which would
become attach-to-a-view rather than `SciterCreateWindow`.

## Consequences for a host application

- **Fonts come from the system**, through Fontconfig. A font a document names has to be installed, or
  bundled and loaded by the document; there is no engine font cache to ship.
- **The GPU path is the default**, and it is EGL/GLESv2 at link time. A machine with no working GL —
  some VMs, some CI containers — is where `.SKIA_RASTER` matters.
- **There are two HTTP clients**: the built-in one, TLS by compiled-in mbedTLS, and libcurl if
  `libcurl.so.4` is there to dlopen. `.USE_INTERNAL_HTTP_CLIENT`, `.CONNECTION_TIMEOUT` and
  `.SET_ROOT_CA` are the options over them. Missing libcurl fails `http://` URLs while everything local
  keeps working.
- **The engine spawns threads of its own** — three besides the main one in a plain `hello_window` — but
  the API stays single-threaded: every `ISciterAPI` call has to come from the thread that ran
  `SCITER_APP_INIT`. See [`architecture.md`](./architecture.md#threading).
- **`libsciter.so` exports 52,051 dynamic symbols**, not one: its C++ internals, Skia, QuickJS and zlib
  are all visible. `SciterAPI` is the only *documented* entry point and the only one these bindings use,
  but a symbol clash with a program that also links Skia or zlib is a real possibility rather than a
  theoretical one.

## The X11 input-method crash

Documented in the README as a workaround; this is what it actually is.

```
#0  XSetICFocus () from /lib/x86_64-linux-gnu/libX11.so.6      $rdi = 0x19700000193
#1  wing::internal::PollEventsX11 ()   from libsciter.so
#2  wing::internal::WaitEventsTimeoutX11 (double)
#3  xwing::application::heartbit (bool)
#4  SciterExecImp
```

The engine hands `XSetICFocus` a pointer that is not one — `0x19700000193` looks like two X ids packed
into a word, not an `XIC`. Measured behaviour, with the crash reproduced in a nested X server:

| `XMODIFIERS` | Result |
| --- | --- |
| unset | runs |
| `@im=none` | runs |
| `@im=ibus` | **SIGSEGV** |
| `@im=nope` (an input method that does not exist) | **SIGSEGV** |

It is not about ibus, and **it is not about the window manager**: it reproduces under Xephyr with no
window manager running at all. Any `XMODIFIERS` value naming an input method is enough. Until the engine
is fixed, run with `XMODIFIERS=@im=none`, and expect users with an IME configured to hit it.

## The other X11 input-method crash: a window that fails to open

A second, unrelated fault in the same X input-method code, and the reason it is worth stating
separately is that **`XMODIFIERS=@im=none` does not prevent it** — the crash is on the teardown side, so
turning the input method off does not keep the engine out of it.

```
#0  XDestroyIC ()                          from libX11.so.6
#1  wing::internal::DestroyWindowX11 ()      from libsciter.so
#2  wing::window::destroy ()
#3  wing::window::create ()
#4  xwing::application::create_frame ()
#5  xskia::application::create_frame ()
#6  SciterCreateWindowImp ()
```

`wing::window::create` fails, unwinds by calling `destroy()` on the half-built window, and that walks
into `XDestroyIC` with an `XIC` field that was never set. So *any* reason a window cannot be created
presents as a SIGSEGV inside `SciterCreateWindow` rather than the NULL return the API documents.

Tracing the calls the engine makes on the way there — `dprintf` on each, which is what
`window-canary.sh` does — shows why the field is never set:

```
[x11] XCreateWindow
[x11] XOpenIM
[egl] eglGetDisplay          <- the last call that returns; creation fails from here
                                (no XCreateIC, so window->ic is whatever the allocation held)
```

`XOpenIM` is called unconditionally; `XCreateIC` is not reached, because the GL setup that follows it
fails first. `destroy()` then frees the input context that was never created. Worth noticing that
`XMODIFIERS=@im=none` — the workaround for the *other* crash — makes `XCreateIC` less likely to have
run, so it does nothing for this one and may make it more reliable rather than less.

Measured 2026-08-13, reproduced by hiding the EGL vendor ICD from libglvnd
(`__EGL_VENDOR_LIBRARY_DIRS=/an/empty/dir`) so that `eglInitialize` has nothing to dispatch to:

| `SET_GFX_LAYER` | EGL ICD present | Result |
| --- | --- | --- |
| default | yes | window created |
| `.SKIA_RASTER` | yes | window created |
| default | **no** | **SIGSEGV in `XDestroyIC`** (not every run — the field is garbage, not reliably a fault) |
| `.SKIA_RASTER` | **no** | `SciterCreateWindow` returns NULL, exit code 1 |

Two things follow. **`.SKIA_RASTER` is not an escape from EGL**: Skia's raster backend still cannot get
a window on a machine with no working EGL, it only fails politely instead of faulting. And a host that
wants a diagnosable failure rather than a crash on a GL-less machine should set `.SKIA_RASTER` before
creating its first window, get the NULL, and report it.

For a test suite this is the difference between one legible failure and twenty identical segfaults: the
Odin test runner catches the signal and then hangs rather than reaping the thread, so every windowed
example burns its whole timeout. `.github/scripts/window-canary.sh` (`just window-canary`) asks the
question once, before the suite, and prints the renderer diagnosis when the answer is no.

## Windows, when it is vendored

Nothing here has been run on Windows. The same page can be filled in with:

```bat
dumpbin /dependents sciter.dll          :: the NEEDED list above
dumpbin /exports sciter.dll | find "SciterAPI"
```

and, from a running window, the same one-line answer as at the top of this page:

```odin
sciter_app.eval(window, "Window.this.graphicsBackend")   // expect windows-dx12-skia, or an ANGLE variant
```

Worth checking specifically, because they are the parts that differ rather than the parts that are
shared (Skia, QuickJS, HarfBuzz and the codecs are compiled in and will be the same):

- which GPU layer `.SKIA_GPU` resolves to — DX12 by the header's ordering, and whether ANGLE is in play
- whether the ANGLE DLLs (`libEGL.dll` / `libGLESv2.dll`) have to ship beside `sciter.dll`
- which system DLLs are load-time dependencies rather than dlopened, since that is the deployment list
- whether the input-method crash above has any equivalent (it is X11-specific by construction)

Add the results to [`WINDOWS-CHECKLIST.md`](./WINDOWS-CHECKLIST.md).
