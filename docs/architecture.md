# Architecture

Why these bindings look the way they do. Everything here follows from one fact about Sciter, and it is
worth understanding before writing much against it.

## One entry point

The Sciter shared library exports **exactly one symbol you can use**:

```
$ nm -D --defined-only lib/linux/x64/libsciter.so | grep -w SciterAPI
00000000007e4a19 T SciterAPI
```

It exports 52,051 dynamic symbols in total — Skia, QuickJS and zlib are compiled in and visible — and
none of the rest is API. [`ENGINE.md`](./ENGINE.md) is what the engine is actually built from.

`SciterAPI()` returns a pointer to `ISciterAPI` — a plain C struct of 189 function pointers with a
leading `version` field. Every call in these bindings is a field of that struct.

```odin
api := sciter.api()
api.SciterExec(.INIT, 1, argv)
api.SciterCreateWindow({.MAIN, .ENABLE_DEBUG}, &frame, nil, nil, nil)
```

Three consequences run through the whole project:

**There is no `foreign import`.** Nothing links against Sciter at build time. `sciter.load()` opens
the library with `core:dynlib` at runtime and stores the table; `sciter.api()` returns it and panics
if `load` has not run, because calling through a nil table would fault deep inside the bindings with
no indication of the real cause.

**The library must be found at runtime.** Static linking requires a commercial licence, so the search
order and its error message are a feature rather than an afterthought — see
[`getting-started.md`](./getting-started.md#where-the-engine-is-looked-for).

**A version mismatch is checked, not tolerated.** If `table.version != SCITER_API_VERSION`, `load`
refuses. A mismatched table means every call reads a *different* field offset than intended: you would
call `SciterEval` and land in `SciterSetValue`. The failure appears somewhere unrelated, with a
plausible-looking backtrace, and nothing points at the cause.

## The table is verified, not assumed

`examples/api_map.odin` walks the generated struct field by field and resolves each pointer back to the
symbol and module it belongs to — `dladdr` on Linux and macOS, dbghelp plus `VirtualQuery` on Windows:

```
001 off=0008 SciterClassName                    -> SciterClassNameImp
002 off=0016 SciterVersion                      -> SciterVersionImp
...
189 off=1512 SciterRequestPaint                 -> SciterRequestPaintImp

189 slots, 16 null (platform-padded)
```

Every non-null slot resolves to its own name plus the engine's `Imp` suffix — 189 checked, 0
mismatches. Run `just example api_map` after any SDK upgrade. This is not paranoia: the abandoned
GitHub mirror of the SDK ships a header declaring two functions its own committed binary does not
implement, and calling them reads past the end of the real table and jumps into whatever data follows.

## The layout is identical on every platform

Sciter keeps every slot on every platform and fills the ones it cannot implement with NULL, rather
than `#ifdef`-ing them out:

```c
#if defined(WINDOWS)
  LRESULT SCFN( SciterProc )(HWINDOW hwnd, UINT msg, WPARAM wParam, LPARAM lParam);
  LRESULT SCFN( SciterProcND )(...);
#else
  LPVOID   SciterProc;   // NULL
  LPVOID   SciterProcND; // NULL
#endif
```

Every padded slot is pointer-sized, so **one Odin struct definition serves Windows, Linux and macOS**,
and the bindings can be generated on whichever platform is most convenient. 16 of the 189 slots are
NULL on Linux: 12 platform-padded, plus 4 `reserved` left over from the removed script-VM API. One of
those NULLs is load-bearing for this library — `SciterGetViewExpando` is gone, so there is no
`globalThis` object to assign into and `set_global` publishes through `SciterSetVariable` instead.

## Sciter 6 owns the application lifecycle

Sciter 4 on Linux was `libsciter-gtk.so`: a GTK3 library whose window handle *was* a `GtkWidget*` and
whose pump was `gtk_main()`. Binding it properly meant binding GTK too. Most material online still
describes that.

Sciter 6 is `libsciter.so` and renders through its own EGL/GLESv2 backend. `ldd` lists sixteen
entries — libuuid, fontconfig, freetype, GLESv2, EGL, libstdc++, expat, zlib, bz2, png16, brotli — and
no GTK, no X11 or Wayland client libraries. `HWINDOW` is a plain `void*`.

The lifecycle is the engine's own, on all three platforms:

```c
typedef enum SCITER_APP_CMD {
  SCITER_APP_STOP     = 0,  // request to quit the message pump
  SCITER_APP_LOOP     = 1,  // run pump until STOP or the main window closes
  SCITER_APP_INIT     = 2,  // p1 = argc, p2 = argv
  SCITER_APP_SHUTDOWN = 3,
} SCITER_APP_CMD;
```

So `sciter_app.run()` is `SciterExec(.LOOP, 0, 0)` and there are no Win32, GTK or Cocoa symbols
anywhere in the bindings. odin-sciter is a single-dependency library.

Two traps found the hard way:

- **`SCITER_APP_INIT` wants UTF-16 argv.** The comment on it in `sciter-x-def.h` says `p2 - CHAR** argv`
  and is wrong; `application::start()` in `sciter-x-window.hpp` builds a `vector<const WCHAR*>`.
  Passing `char**` — or NULL — crashes. `sciter_app.init()` does the conversion, and keeps the storage
  alive for the life of the process because the engine is not documented to copy it.
- **`SciterVersion(n)` takes an index 0..3**, one component of the version vector each. In 4.x it took
  a boolean and packed two components into the result, and old code still does that.

## Threading

Sciter is single-threaded. Every `ISciterAPI` call has to come from the thread that ran
`SCITER_APP_INIT`. There is no locking to opt into and no "call from any thread" mode.

To drive the UI from a worker, get back onto the engine's thread first.
[`post_callback(window, wparam, lparam)`](./api.md#posting-work-to-the-engines-thread) is the way, and
the only call in `sciter_app` that is safe from another thread: it returns immediately and the two
words come back out on the engine's thread as `Host_Handler.on_posted`. The other options are
`run_once` + `heartbeat` instead of `run`, so your own event source can share the thread, and a queued
[`post_event`](./events.md#synthesising-events) once you are already on the right thread.

Odin's test runner is parallel by default, which is why every test recipe passes
`-define:ODIN_TEST_THREADS=1`. Without it the engine's heap gets corrupted instead of the tests
failing cleanly.

## Two packages

| | `package sciter` | `package sciter_app` |
| --- | --- | --- |
| Origin | generated by odin-c-bindgen | hand-written |
| Shape | 1-to-1 with the C API | snake_case, Odin-shaped |
| Strings | UTF-16, you encode them | Odin `string` |
| Errors | result codes and `b32` | `Error` union |
| Docs | sciter.com reads across directly | [`api.md`](./api.md) |

They are not layers you have to choose between: `sciter_app.Value` *is* `sciter.Value`,
`sciter_app.Element` is a distinct `sciter.Helement`, and `sciter.api()` is always one call away. Mix
them freely — the wrapper covers the common paths, and the raw table covers everything else. Nothing
in `sciter_app` holds state that the raw table would invalidate, apart from the argv storage `init`
owns.

## How the generated half is produced

`just bindgen` runs four steps, all reproducible from a clean checkout — and idempotent, so running it
twice produces a byte-identical `sciter.odin`:

```
uv run python src/flatten_headers.py      # 13 headers -> build/sciter.h
../odin-c-bindgen/bindgen.bin .           # -> sciter.odin, per bindgen.sjson
uv run python src/postprocess_bindings.py sciter.odin
odin check . -no-entry-point
odinfmt -w sciter.odin                    # then check again
```

The formatting pass belongs to generation, not to `just format`: bindgen's line breaking is not
odinfmt's, so leaving it out means every regeneration carries a few thousand lines of formatting noise
alongside the API change that actually matters.

**The flatten step exists because odin-c-bindgen only emits declarations physically located in the
input file.** Feeding it `sciter-x-api.h` alone yields `ISciterAPI` and none of the types it refers
to; feeding it all ten headers yields ten `.odin` files that re-emit inline copies of each other's
types and collide inside one package. Sciter's headers are also not individually self-contained —
`sciter-x-dom.h` uses `UINT` and `LPCWSTR` without including the header that defines them, because in
practice it is only ever reached through `sciter-x-api.h`.

The flattener also strips the 163 flat `SCAPI` prototypes (`UINT SCAPI ValueInit(VALUE*)` and
friends). **None of them are exported by the library** — in C they resolve to inline wrappers that
forward to `SAPI()->ValueInit(...)`. As Odin `foreign` procedures they would be dead weight that
cannot link. It applies five documented patches where the headers are not valid C, and a patch that
stops matching is a hard error rather than a silent skip, so an SDK upgrade cannot quietly drop one.

**The post-process step rewrites the calling convention.** On Linux `SCFN(name)` expands to `(*name)`,
so bindgen emits `proc "c"`; on Windows it is `(__stdcall *name)`. Odin spells "the platform's system
ABI" `proc "system"`, so all 299 occurrences are rewritten — the bindings are generated once on Linux
and compiled everywhere. Generating on Windows instead is not an option: those headers pull in
`windows.h`, `HWND`, `MSG` and `IUnknown`, which libclang on Linux cannot resolve.

The idiomatic-types pass — `bit_set`s for flag enums, real enums for parameters typed `UINT`,
`Scdom_Result` on all 101 DOM slots — is entirely declarative in `bindgen.sjson`, so it survives
regeneration. `docs/PLAN.md` §7 lists what was applied and, more usefully, the three conversions that
would have compiled and been wrong.

`src/prelude.odin` is the hand-written half of `package sciter`: the loader, `api()`, `adopt()`, and
`Scdom_Result`. bindgen pastes it into `sciter.odin` verbatim at generation time, which is why editing
`sciter.odin` is pointless — edit the prelude.

## Three ways to combine Odin and Sciter

| | Who owns `main` | Your code is | Built with |
| --- | --- | --- | --- |
| **Embedding** | your Odin executable | Odin, hosting the engine | `just example NAME` |
| **scapp / Quark** | the SDK's prebuilt `scapp` | JavaScript only | the SDK's own tooling |
| **Native extension** | `scapp`, or any Sciter host | an Odin shared library | `just extension` |

Most of this documentation is about embedding. The third is the escape hatch from the second: a native
extension is a shared library the engine loads on demand, in response to script.

```js
import * as sciter from "@sciter";
const ext = sciter.loadLibrary("odin-ext");   // loads odin-ext.so beside the executable
ext.greet("world");
```

The whole contract is one exported symbol:

```c
SBOOL SCAPI SciterLibraryInit(ISciterAPI* psapi, SCITER_VALUE* plibobject);
```

The host **hands over the API table**, so `load()` is wrong here — it would open a second copy of a
library that is already loaded. `sciter.adopt()` takes the supplied table instead, applying the same
version check, after which every wrapper in `sciter_app` works unchanged. `unload()` skips the
`dlclose` when the table was adopted, because the host owns the library.

[`examples/extension.odin`](../examples/extension.odin) is a complete one in about 40 lines of actual
code, verified end to end under the SDK's `scapp`.

## Licensing, in one paragraph

Two licences cover different things. The SDK repository's **contents** — headers, samples,
documentation — are BSD 3-Clause, which is what these bindings are generated from and why generating
them is unencumbered. The **engine binary** is covered by the Sciter Engine EULA: free use in
commercial and non-commercial applications, with one concrete obligation, an attribution line in your
About box. There is no engine source in the repository, and static linking is a paid tier. See
[`deployment.md`](./deployment.md#licensing) for the exact wording you owe.
