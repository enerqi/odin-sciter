# odin-sciter

[Odin](http://odin-lang.org/) bindings for [Sciter.JS](https://sciter.com/) — an embeddable HTML/CSS/JS
engine for building desktop application interfaces.

You write your UI in HTML and CSS, script it in JavaScript, and drive it from Odin. Sciter is not a
browser and not Electron: the whole engine is a single ~25 MB shared library with no Chromium, no
Node.js, and no separate process. A "hello world" application is one Odin file and one HTML string.

There are two packages, and you can mix them freely.

**`sciter_app`** is the one to write against. Snake_case, Odin `string`s, error enums:

```odin
package main

import "../sciter_app"

main :: proc() {
	if !sciter_app.load_engine() {return}
	sciter_app.init()

	window, _ := sciter_app.create_window({width = 720, height = 480})
	sciter_app.load_html(window, "<html><body><h1>Hello from Odin</h1></body></html>")

	sciter_app.show(window)
	sciter_app.run()
	sciter_app.shutdown()
}
```

**`sciter`** is generated, and stays 1-to-1 with the C API so that
[sciter.com's documentation](https://docs.sciter.com/) reads across to it directly. The raw function
table is always one `sciter.api()` away:

```odin
api := sciter.api()
api.SciterExec(.INIT, 1, argv)
api.SciterCreateWindow({.MAIN, .ENABLE_DEBUG}, &frame, nil, nil, nil)
```

[`examples/hello_window.odin`](examples/hello_window.odin) does the whole thing in the raw bindings and
nothing else, if you want to see what the wrapper is doing.


## Quick start

You need [Odin](https://odin-lang.org/docs/install/), [just](https://just.systems/) and
[uv](https://docs.astral.sh/uv/getting-started/installation/). uv is not optional and not only for
regenerating: every Python step here runs through it — fetching the engine included — so a clean clone
needs it before the first build. `just fetch-engine` checks for it and prints the install command
rather than failing as "os error 2".

```sh
git clone https://github.com/enerqi/odin-sciter.git
cd odin-sciter
just example hello_window
```

A window opens with HTML and CSS rendered by Sciter. **The first command downloads the engine** — 24 MB
on Linux, 19 on Windows, 50 on macOS — because no engine is committed to this repository. There is
nothing to install and nothing to remember: `just fetch-engine` verifies the download against a recorded
SHA-256, and every recipe that builds or runs anything *against the engine* depends on
`just ensure-engine`, so the first build fetches once and later ones do not. The clone itself is ~2 MB.

That is a deliberate trade against "works offline from a clean clone": a binary does not
delta-compress, so committing three engines meant ~40 MB of permanent history per engine bump, forever.
The arithmetic, and why not git-lfs, is in [`docs/UPGRADING.md`](docs/UPGRADING.md). If you need an
offline or air-gapped checkout, fetch once and copy `lib/` across, or point `SCITER_ENGINE_URL` at your
own mirror — the hash check is what makes an untrusted mirror safe. If upstream's URL is unreachable or
its tag has moved, the fetch falls back to this repository's own release assets without being asked to.

If it does not load, the error lists every path it tried. Point it at a library explicitly with:

```sh
SCITER_LIB=/path/to/sciter-js-sdk/bin/linux/x64 just example hello_window
```

**If the window opens and then segfaults on X11**, run it with `XMODIFIERS=@im=none`. The crash is
inside the engine binary's X input-method handling (`XSetICFocus`), it fires when the window takes
focus, and disabling XIM avoids it — measured here at 3 crashes out of 3 without, 0 out of 3 with. It
is not a fault in the bindings: `just example api_map` is the check that catches a real mismatch.

**If it segfaults before any window appears** — on CI, in a container, or over ssh — set
`XDG_SESSION_TYPE=x11`. The engine picks its windowing backend from that variable, and unset it takes a
GTK4 path that calls a NULL pointer inside `SciterExec(.INIT)`. `XMODIFIERS` does not affect it.
`just window-canary` under Xvfb names this and the other pre-window failure — see
[`docs/getting-started.md`](docs/getting-started.md#when-it-does-not-work).


## How it works, in one section

This is worth reading before anything else, because Sciter's shape drives every design decision here.

Sciter's shared library has **exactly one entry point you can use**: `SciterAPI()`. It returns a pointer
to `ISciterAPI`, a C struct of 189 function pointers. Every call in these bindings is a field of that
struct. There is nothing else to link against.

```
$ nm -D --defined-only lib/linux/x64/libsciter.so | grep -w SciterAPI
00000000007e4a19 T SciterAPI
```

The library does export plenty else — 52,051 dynamic symbols, because Skia, QuickJS and zlib are
compiled into it and visible — but none of it is API. [`ENGINE.md`](docs/ENGINE.md) is the tour of
what is in there.

Three consequences:

1. **`sciter.load()` must be called once, before anything else.** It opens the library and fetches the
   table. `sciter.api()` returns it.
2. **The library is found at runtime, not at link time.** There is no static linking without a
   commercial licence, so the search order matters — see [Finding the engine](#finding-the-engine).
3. **Version mismatches are dangerous, so they are checked.** If the engine's `version` field does not
   match the headers these bindings were generated from, `load` refuses. A mismatch would mean every
   call lands in a *different* function than intended, which crashes somewhere unrelated and looks like
   anything but the real cause.

You can see the whole table for yourself:

```sh
just example api_map
```

That walks every slot and resolves each pointer back to the symbol and module it belongs to — `dladdr`
on Linux and macOS, dbghelp plus `VirtualQuery` on Windows. It is also the regression test for a Sciter
upgrade: 189 slots, 0 mismatches expected.


## Examples

Each is a single self-contained file with the explanation in its header comment, ordered by difficulty.
Run one with `just example NAME`.

| Example | What it shows |
| --- | --- |
| `hello_window` | A window, HTML and CSS, and the app loop — raw bindings only, no wrapper |
| `api_map` | Walks all 189 `ISciterAPI` slots and resolves each to its symbol. The upgrade check. |
| `load_file` | Loading a document from disk, and why relative URLs need a base URL |
| `eval` | Running JavaScript from Odin and reading results back as `Value`s |
| `call_odin_from_js` | The other direction: exposing an Odin procedure — and an Odin object — to script |
| `dom_walk` | CSS selectors, traversal, and reading and writing text and attributes |
| `events` | Handling DOM events in Odin, without any script in the document |
| `behavior` | Driving the built-in widgets — a real click, hit testing, and a behavior method of your own |
| `input` | Real mouse and keyboard input from Odin, animation frames, and an element's script object |
| `task_list` | **A whole small application** — an Odin model, one render, keyboard commands, saved state, no script |
| `workbench` | **A harder one** — 10,000 rows virtualised, editable, live-updating, with an Odin-painted widget per row, type-ahead search on a worker thread, drag-to-reorder with undo/redo, and a second window with its own host handler. The evidence behind [`VDOM.md`](docs/VDOM.md) |
| `worker_thread` | Getting work off the UI thread and its results back on, with `post_callback` |
| `graphics` | Drawing with the engine's renderer: a custom-painted element, and an offscreen image |
| `graphics_gallery` | Every shape, gradient, transform, clip, path and text call, drawn once and asserted once — and the five places the renderer is wrong |
| `video` | Frames generated in Odin, streamed into a `<video>` — the one C++ vtable in the whole API |
| `named_behavior` | `behavior: my-gauge` in CSS — the stylesheet, not a call site, choosing which elements get Odin |
| `drag_and_drop` | Accepting a system drop through the `.EXCHANGE` event group |
| `custom_loader` | Serving a document's CSS and images from memory via the `SC_LOAD_DATA` host callback |
| `request_loader` | The same callback taken further: status codes, MIME types, and an answer that arrives a second late |
| `archive` | The whole UI in one compressed blob inside the executable, via `packfolder` and `#load` |
| `single_binary` | `archive` plus the engine itself embedded — one self-contained 25 MB executable |
| `inspector` | Attaching the SDK's DevTools-style inspector to a running window |
| `windowless` | **No window at all** — the engine renders into a buffer you own, for a pane inside someone else's renderer. See [`EMBEDDING.md`](docs/EMBEDDING.md) |
| `windowless_gl` | The same on the **GPU** — Sciter's Skia pipeline drawing straight into your OpenGL texture (Linux/EGL) |
| `integration` | **A Sciter pane inside a window this program owns** — raw Xlib, the host's own frame and event loop, the pane composited in and fully interactive. The SDK's `demos/integration`, in Odin |
| `native_child` | **The inverse of `integration`** — a native X11 window living *inside* a Sciter window, tracking an element's box. Sciter's `HWINDOW` is an X11 window id, which is what makes it possible |
| `sqlite_extension` | **A real library bound and published to script** — `SQLite`, `DB` and `Recordset` over the system `libsqlite3`, as a loadable extension. `just extension sqlite_extension odin-sqlite` |
| `script_bridge` | **Capabilities Odin cannot bind, driven anyway** — clipboard, dialogs, `@sys`, `@env`: ask the document. See [`calling-between-odin-and-js.md`](docs/calling-between-odin-and-js.md#capabilities-that-only-script-can-reach) |
| `extension` | The inverse arrangement — Odin as a native extension the *engine* loads. See below. |

Tests live inside the examples, next to the code they cover:

```sh
just example-tests         # every example's tests
just example-test eval     # one example's tests
just test1 eval test_value_array
just test_sanitize eval    # the Value refcounting tests under ASan
```

Tests that need a window skip themselves when there is no display.

`archive` uses a committed 2 KB `examples/assets/app.pak`, so it builds from a clean checkout with no
SDK. Re-pack it after editing anything under `examples/assets/app/`:

```sh
SCITER_SDK=/path/to/sciter-js-sdk just pack
```

`packfolder` is one of four SDK tools these recipes can use — see
[The SDK is optional](#the-sdk-is-optional) for the full list and what each is worth.


## Shipping one file

Sciter is dynamic-link-only without a commercial licence, so the engine has to exist as a file for the
system loader to open — normally a ~25 MB library shipped beside your program. `single_binary` embeds
it anyway:

```odin
ENGINE    :: #load("../lib/linux/x64/libsciter.so")   // the engine
RESOURCES :: #load("assets/app.pak")                  // the UI

sciter_app.load_embedded(ENGINE)                      // extract once, then load
```

`load_embedded` writes the engine to a hash-named directory under the user's cache
(`~/.cache/odin-sciter/<hash>/libsciter.so`) and loads it from there. The hash means a different engine
build gets a different directory instead of silently reusing a stale one, and an unchanged one is
written exactly once — later runs reuse it untouched. The write is via a temporary file plus rename, so
two copies starting at once cannot see a half-written library.

This is **not** static linking and it does not avoid the disk; there is no portable way to hand the
system loader a library from memory. What it buys is a single artifact. The trade-offs are listed in
[`sciter_app/embed.odin`](sciter_app/embed.odin) — notably that the cache directory must not be
mounted `noexec`, and that a freshly written DLL is what Windows anti-malware heuristics look for.

On licensing: the EULA's grant is "You may utilize sciter.dll in any manner you see fit (subject to the
limitations outlined in this license)", and the only limitation it states is the About-box attribution.
It says nothing about embedding. That is a reading of the text and not legal advice.


## Three ways to combine Odin and Sciter

Most of this README is about the first one, but the engine supports all three and they are genuinely
different architectures.

| | Who owns `main` | Your code is | Built with |
| --- | --- | --- | --- |
| **Embedding** | your Odin executable | Odin, hosting the engine | `just example NAME` |
| **scapp / Quark** | the SDK's prebuilt `scapp` | JavaScript only | the SDK's own tooling |
| **Native extension** | `scapp`, or any Sciter host | an Odin shared library | `just extension` |

`scapp` is the Sciter engine packaged as a standalone executable, and
[Quark](https://quark.sciter.com/) assembles your HTML/CSS/JS onto a copy of it to produce a single
monolithic binary. That path has no native code of your own in it — which is where extensions come in.

A **native extension** is a shared library the engine loads on demand, in response to script:

```js
import * as sciter from "@sciter";
const ext = sciter.loadLibrary("odin-ext");   // loads odin-ext.so beside the executable
ext.greet("world");
```

The whole contract is one exported symbol, `SciterLibraryInit`, which is handed the `ISciterAPI` table
and returns the object script sees. `sciter.adopt()` takes that table instead of opening the library,
and everything else in these bindings then works unchanged.
[`examples/extension.odin`](examples/extension.odin) is a complete one, in about 40 lines of actual
code:

```sh
just extension                                   # -> target/debug/odin-ext.so
SCITER_SDK=/path/to/sciter-js-sdk just extension-run   # runs it under scapp
```

`scapp` is not vendored here, hence `SCITER_SDK` — see [The SDK is optional](#the-sdk-is-optional).


## The SDK is optional

**You do not need a Sciter SDK checkout to use these bindings.** The engine is fetched by hash, the
headers are vendored here, and every core recipe — `just example`, `check`, `build-examples`, `lint`,
`cross-check`, `test`, `example-tests`, `bindgen` — works without one. That is the point of
`just fetch-engine`.

Four recipes want the SDK's own **tools**, which are separate executables that are deliberately not
vendored (they are not part of the C ABI these bindings target, and they are large). Point
`SCITER_SDK` at a checkout to use them:

| Recipe | SDK tool | What you get, and whether you need it |
| --- | --- | --- |
| `just inspector` | `inspector` | The DevTools-style DOM tree, style viewer, console and debugger, attached to a running window over a socket. **The most useful of the four** — this is how you debug a document. See [`examples/inspector.odin`](examples/inspector.odin) |
| `just pack` | `packfolder` | Re-packs `examples/assets/app/` into `app.pak`. Only needed if you *edit* those assets: the 2 KB `.pak` is committed, so `just example archive` builds from a clean checkout without it |
| `just extension-run` | `scapp` | Runs [`examples/extension.odin`](examples/extension.odin) the way the engine actually loads an extension — `scapp` owns `main`, your Odin is the shared library. Building the extension (`just extension`) needs no SDK; only *running it this way* does |
| `just extension-sqlite` | `scapp` | The same for the SQLite extension |

```sh
SCITER_SDK=/path/to/sciter-js-sdk just inspector
```

Without it those four exit with a message naming the variable rather than a confusing failure. Get a
checkout with `git clone --depth 1 https://gitlab.com/sciter-engine/sciter-js-sdk` — use `--depth 1`,
because the full history is ~4 GB of committed platform binaries. What is and is not vendored here, and
why, is in [`external/sciter/VENDORED.md`](external/sciter/VENDORED.md).


## Finding the engine

`sciter.load()` searches five places in order — an explicit path, `SCITER_LIB`, the executable's own
directory, `lib/<platform>/` relative to the working directory, then the system library search path —
and on failure returns the full candidate list, so print it. That is the fastest way to see what went
wrong. The list, and what to do with it,
is in [`docs/getting-started.md`](docs/getting-started.md#where-the-engine-is-looked-for).

| Platform | File | Fetched into | Green in CI | Looked at by a human |
| --- | --- | --- | --- | --- |
| Linux x64 | `libsciter.so` | `lib/linux/x64/` | yes | yes |
| Windows x64 | `sciter.dll` | `lib/windows/x64/` | yes | yes, with caveats — see below |
| macOS (universal) | `libsciter.dylib` | `lib/macosx/` | see below | **no** |

**No engine is in the tree**, on any platform. Each is pinned by SHA-256 in
[`external/sciter/VENDORED.md`](external/sciter/VENDORED.md) and installed by `just fetch-engine`, which
`ensure-engine` runs for you before the first build. macOS has no architecture subdirectory because that
build is one universal file carrying both x86_64 and arm64 — 50 MB, and `lipo -thin arm64` halves it in
an application's own bundle.

**The last column is not padding.** CI can prove the engine loads, that the ISciterAPI table is the one
these bindings were generated against, that the suite passes and that nothing leaks. It cannot tell you
a window renders correctly rather than blank. Nobody working on this repository owns a Mac, so macOS is
brought up on GitHub's `macos-14` runners and that is the ceiling of what is claimed for it.
[`docs/MACOS-CHECKLIST.md`](docs/MACOS-CHECKLIST.md) is the record: what was established from the
binary itself, what CI is expected to establish, and the predictions it will confirm or contradict.

Windows x64 was brought up on a real desktop on 2026-08-15: the whole example suite passes, the
ISciterAPI table is verified and gated in CI, and the leak sweep is clean.
[`docs/WINDOWS-CHECKLIST.md`](docs/WINDOWS-CHECKLIST.md) is the measurement record. Two bugs found along
the way are in other people's code, and both have reproductions written down there:

- **the engine faults at process exit if a window's document never renders any text** — an unhandled
  null dereference, reproduced in fifteen lines. Worked around by giving three test documents one
  character to lay out
- Odin's Windows test runner stops a test for *any* first-chance exception, and Sciter throws C++
  exceptions in ordinary operation. A patch is written, verified and ready to submit upstream:
  [`docs/odin-test-runner-windows.patch`](docs/odin-test-runner-windows.patch)

**One thing every Windows application here must do: call `set_default_debug_output()` (or install your
own handler).** With none installed the engine reports diagnostics through `OutputDebugStringW`, which
Windows implements by raising an exception — harmless in a normal run, fatal under anything that treats
first-chance exceptions as errors.

Linux runtime dependencies are modest and satisfied by a stock desktop install: fontconfig, freetype,
EGL, GLESv2, expat, zlib, libpng, brotli, libstdc++. **Sciter 6 does not use GTK** — 4.x did, and much
of the material online still says so.


## Licensing — read this before shipping

Two separate licences apply, and they cover different things.

- **These bindings** are under [`LICENSE`](LICENSE).
- **The Sciter SDK's headers, samples and documentation** are BSD 3-Clause — see
  [`external/sciter/LICENSE`](external/sciter/LICENSE).
- **The Sciter engine binary** (`libsciter.so` / `sciter.dll` / `libsciter.dylib`) is **not** BSD. It is
  covered by [`external/sciter/SCITER-ENGINE-EULA.md`](external/sciter/SCITER-ENGINE-EULA.md). Terra
  Informatica retains copyright and grants free use in commercial and non-commercial applications, with
  one requirement:

  > Your application shall include link to Terra Informatica site in "About" dialog or similar place in
  > your application. Text of the link: This Application (or Component) uses Sciter Engine
  > (http://sciter.com/), copyright Terra Informatica Software, Inc.

So Sciter is free to use, including commercially, and you owe that attribution line. Access to the
engine's *source code*, and the right to link it statically, are the paid tiers at
<https://sciter.com/prices/>.


## Layout

| Path | What it is |
| --- | --- |
| `sciter.odin` | **Generated.** The whole binding — `package sciter`. Do not edit; run `just bindgen`. |
| `sciter_app/` | Hand-written `package sciter_app`: the Odin-shaped layer — windows, `Value`s, the DOM, events |
| `src/prelude.odin` | Hand-written: the loader, `api()`, `Scdom_Result`. Pasted into `sciter.odin` at generation time. |
| `bindgen.sjson` | odin-c-bindgen configuration, heavily commented |
| `src/flatten_headers.py` | Concatenates the SDK headers into one file for bindgen, and explains why that is necessary |
| `src/postprocess_bindings.py` | Rewrites the calling convention, and drops the `-> Void` returns bindgen emits for C `void` |
| `external/sciter/` | Vendored SDK headers, both licences, and `VENDORED.md` (pinned version) |
| `lib/` | The engine binaries |
| `examples/` | Runnable examples, one file each, plus `assets/`. `extension.odin` is a shared library, not an application. |
| `tools/xdnd_source.py` | A minimal X11 drag source, to measure a real system drop against `examples/drag_and_drop.odin` |
| `docs/` | Plan, findings, and how the research was done |


## Development

Tasks run with [just](https://just.systems/).

- `just example NAME` — build and run `examples/NAME.odin`; defaults to `hello_window`
- `just check` — type check both packages, the guides' snippets and every example
- `just build-examples` — build and link every example; the coverage `odin check` cannot give you
- `just bindgen` — regenerate `sciter.odin` from `external/sciter/include`
- `just format` — `odinfmt -w .`

The root package is a library with no `main`, so the usual build-profile recipes are pointed at
examples instead. Each takes an example name:

- `just run NAME` / `run_release NAME` / `run_release_debug NAME` … — the same profiles, on one example.
  `just example` and `just run` are two names for the debug one, so `rerun` works after either
- `just rerun NAME` — re-run the last build without recompiling
- `just sanitize NAME` — run one example under ASan
- `just test` / `just test1 EXAMPLE TEST` / `just test_sanitize EXAMPLE` — the tests

`just test_sanitize` preloads the system `libstdc++` on Linux, and that is not optional either: the
engine throws C++ exceptions in ordinary operation — loading a document with a `<script>`, parsing text
that will not parse — and ASan's `__cxa_throw` interceptor has no real one to forward to in a binary
that links no C++ runtime, so it aborts on the first throw with a `CHECK failed … real___cxa_throw`
that says nothing about your code. The recipe's comment has the detail.

Every test recipe passes `-define:ODIN_TEST_THREADS=1`, and that is not optional: Sciter is
single-threaded — every `ISciterAPI` call has to come from the thread that ran `SCITER_APP_INIT` —
while Odin's test runner is parallel by default. Without it the engine's heap gets corrupted instead of
the tests failing cleanly, which shows up as `malloc(): unaligned tcache chunk detected`.

Regenerating additionally needs [odin-c-bindgen](https://github.com/karl-zylinski/odin-c-bindgen) built
alongside this repository (`../odin-c-bindgen/bindgen.bin`), or `ODIN_C_BINDGEN` pointing at it. Its two
Python steps run through uv like every other one.

Two recipes exist for what CI runs, and are worth running by hand after an engine change:

- `just api-map-verify` — `api_map`, with its table asserted rather than read: 189 slots, API version
  10, every non-null slot resolving to its own `…Imp`, and the platform's null list unchanged
- `just cross-check` — `odin check -target:` for `windows_amd64`, `darwin_amd64` and `darwin_arm64` over
  both packages, the doc snippets and every portable example. `darwin_arm64` is there because that is
  what CI's macOS runner is. Two examples are excluded for a stated reason: `integration` and
  `native_child` are raw Xlib

CI itself is three workflows in `.github/workflows/`: `ci` (the above plus the tests, under Xvfb),
`bindgen` (regeneration is byte-identical to what is committed), and `canary` — a weekly probe that
runs the whole upgrade procedure against upstream's newest tag on a scratch tree without moving the
pin, so a breaking engine release is news before it is a problem. See
[`docs/UPGRADING.md`](docs/UPGRADING.md#what-ci-does-for-you).


## Sciter version

| | |
| --- | --- |
| SDK | [gitlab.com/sciter-engine/sciter-js-sdk](https://gitlab.com/sciter-engine/sciter-js-sdk) tag `6.0.4.9-bis` |
| Engine | 6.0.4.9 |
| `SCITER_API_VERSION` | 10 |

> **Use the GitLab repository.** The `c-smile/sciter-js-sdk` mirror on GitHub is abandoned — last commit
> 2022, engine 4.4.8.33 — and its headers do not match the binaries committed beside them. Details in
> [`external/sciter/VENDORED.md`](external/sciter/VENDORED.md).


## Guides

**[`docs/README.md`](docs/README.md) is the index** — every guide, split by audience, in reading order,
with the maintainer working notes marked as such. It is the one page to open if you do not yet know
which page you want.

The five that make up the reading order, in order:

| Guide | |
| --- | --- |
| [`getting-started.md`](docs/getting-started.md) | install, the smallest program, and what to do when the window does not appear |
| [`architecture.md`](docs/architecture.md) | the two packages, the vtable, dynamic-only loading, and how the bindings are generated |
| [`rules.md`](docs/rules.md) | **the four contracts that decide whether your program is correct** — thread affinity, `Value` ownership, handle lifetimes, allocators. The one page that is not optional |
| [`gotchas.md`](docs/gotchas.md) | **the things that cost a day each** — measured, and none of it derivable from the headers |
| [`api.md`](docs/api.md) | the `sciter_app` API, area by area |

Every Odin code block in the guides that teach the API lives in [`docs/snippets/`](docs/snippets/) as
well, and is type checked by `just check` — documentation drifts silently otherwise. Two kinds of block
are deliberately absent and say so where they are: raw-Xlib listings, which do not type check off Linux
and would break `just cross-check`, and the code in the maintainer notes and the essays
(`RESEARCH-METHOD.md`, `WINDOWS-CHECKLIST.md`, `VDOM.md`, `ALTERNATIVES.md` and the like), which is
illustrative rather than something to paste. The correspondence is maintained by hand;
`docs/snippets/snippets.odin` names the guide each block came from.


## Further reading

Beyond the reading order — the topic guides (`dom.md`, `events.md`, `threading.md`, `graphics.md`,
`resources.md`, and the rest), the material about Sciter itself, and the maintainer notes are all
listed and described in [`docs/README.md`](docs/README.md). A few worth naming here:

- [`CHANGELOG.md`](CHANGELOG.md) — what each release contains, and how releases are versioned
- [`docs/PLAN.md`](docs/PLAN.md) — findings, design decisions, and what is planned next
- [`docs/RESEARCH-METHOD.md`](docs/RESEARCH-METHOD.md) — how all of it was established, including the
  part that went wrong
- [`docs/ALTERNATIVES.md`](docs/ALTERNATIVES.md) — where Sciter sits among the other ways to build a
  desktop UI, what it gives up, and what to watch
- [`docs/UPSTREAM-DEFECTS.md`](docs/UPSTREAM-DEFECTS.md) — 12 engine defects written up ready to file,
  and the three that turned out to be this repository's own mistakes
- [`docs/SDK-PARITY.md`](docs/SDK-PARITY.md) — how these examples, tests and guides line up against
  everything the SDK ships, and which of its 64 script samples have no host API to bind at all
- [Sciter documentation](https://docs.sciter.com/docs/intro) and [tutorials](https://sciter.com/tutorials/)
