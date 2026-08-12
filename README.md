# odin-sciter

[Odin](http://odin-lang.org/) bindings for [Sciter.JS](https://sciter.com/) — an embeddable HTML/CSS/JS
engine for building desktop application interfaces.

You write your UI in HTML and CSS, script it in JavaScript, and drive it from Odin. Sciter is not a
browser and not Electron: the whole engine is a single ~25 MB shared library with no Chromium, no
Node.js, and no separate process. A "hello world" application is one Odin file and one HTML string.

> **Status: early but usable.** The generated bindings are verified slot-by-slot against the shipped
> engine, there is an Odin-shaped layer on top of them, and twenty-five examples, 337 tests and eleven
> guides cover it. Linux x64 is the only platform vendored and tested so far; Windows type checks but has not
> been run. See [`docs/PLAN.md`](docs/PLAN.md) for exactly what is done and what is not, and
> [`CHANGELOG.md`](CHANGELOG.md) for what a release contains.

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

You need [Odin](https://odin-lang.org/docs/install/) and [just](https://just.systems/).

```sh
git clone --depth 1 https://github.com/enerqi/odin-sciter.git
cd odin-sciter
just example hello_window
```

A window opens with HTML and CSS rendered by Sciter. The engine is vendored in `lib/`, so this works
offline with nothing else installed.

If it does not load, the error lists every path it tried. Point it at a library explicitly with:

```sh
SCITER_LIB=/path/to/sciter-js-sdk/bin/linux/x64 just example hello_window
```

**If the window opens and then segfaults on X11**, run it with `XMODIFIERS=@im=none`. The crash is
inside the engine binary's X input-method handling (`XSetICFocus`), it fires when the window takes
focus, and disabling XIM avoids it — measured here at 3 crashes out of 3 without, 0 out of 3 with. It
is not a fault in the bindings: `just example api_map` is the check that catches a real mismatch.


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

`scapp` is not vendored here, hence `SCITER_SDK`.


## Finding the engine

`sciter.load()` searches, in order:

1. an explicit path passed to `load("...")` — a file or a directory
2. the `SCITER_LIB` environment variable — a file or a directory
3. the directory containing the running executable
4. `lib/<platform>/` relative to the working directory (where this repository keeps its copy)
5. the system library search path (`LD_LIBRARY_PATH`, `PATH`, `DYLD_LIBRARY_PATH`)

On failure it returns the full candidate list, so print it — that is the fastest way to see what went
wrong.

| Platform | File | Vendored here | Tested |
| --- | --- | --- | --- |
| Linux x64 | `libsciter.so` | yes, `lib/linux/x64/` | yes |
| Windows x64 | `sciter.dll` | not yet | no |
| macOS | `libsciter.dylib` | not yet | no |

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
| `spike/smoke/` | The minimal ABI handshake, written before any bindings existed |
| `docs/` | Plan, findings, and how the research was done |


## Development

Tasks run with [just](https://just.systems/).

- `just example NAME` — build and run `examples/NAME.odin`; defaults to `hello_window`
- `just check` — type check both packages and build every example
- `just bindgen` — regenerate `sciter.odin` from `external/sciter/include`
- `just format` — `odinfmt -w .`

The root package is a library with no `main`, so the usual build-profile recipes are pointed at
examples instead. Each takes an example name:

- `just run NAME` / `run_release NAME` / `run_release_debug NAME` … — the same profiles, on one example
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

Regenerating needs [odin-c-bindgen](https://github.com/karl-zylinski/odin-c-bindgen) built alongside
this repository (`../odin-c-bindgen/bindgen.bin`), or `ODIN_C_BINDGEN` pointing at it, plus
[uv](https://docs.astral.sh/uv/) for the two Python steps.


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

| Guide | |
| --- | --- |
| [`getting-started.md`](docs/getting-started.md) | install, the smallest program, and what to do when the window does not appear |
| [`architecture.md`](docs/architecture.md) | the vtable, dynamic-only loading, threading, and how the bindings are generated |
| [`ENGINE.md`](docs/ENGINE.md) | what the engine is built from — Skia, QuickJS, its own X11/Wayland layer — and what it loads at runtime |
| [`html-css-js.md`](docs/html-css-js.md) | what Sciter's HTML/CSS/JS is and is not — flow layout, behaviors, the runtime |
| [`reactor.md`](docs/reactor.md) | Reactor — JSX, `patch()` reconciliation, components, lifecycle and Signals, with the traps measured against the engine |
| [`calling-between-odin-and-js.md`](docs/calling-between-odin-and-js.md) | `eval`, `call`, native functors, and the `Value` lifetime rules |
| [`dom.md`](docs/dom.md) | element handles, selectors, traversal, text and attributes, state, geometry |
| [`events.md`](docs/events.md) | subscriptions, propagation phases, typed parameters, timers, synthesised events |
| [`graphics.md`](docs/graphics.md) | images, paths, text and the 2D renderer, and painting inside a `DRAW` event |
| [`resources.md`](docs/resources.md) | the `SC_LOAD_DATA` host callback, `packfolder` archives, one-binary shipping |
| [`deployment.md`](docs/deployment.md) | what to ship per platform, the attribution you owe, upgrading the engine |
| [`api.md`](docs/api.md) | the `sciter_app` API, area by area |
| [`EMBEDDING.md`](docs/EMBEDDING.md) | the windowless mode — rendering into a buffer or texture you own, so Sciter can be a pane inside someone else's frame loop |
| [`UPGRADING.md`](docs/UPGRADING.md) | version and tag policy, the engine upgrade procedure, and the repository-size budget |
| [`WINDOWS-CHECKLIST.md`](docs/WINDOWS-CHECKLIST.md) | what is already done for the Windows port, and the list to work through on the machine |

Every Odin code block in those guides lives in [`docs/snippets/`](docs/snippets/) as well, and is type
checked by `just check` — documentation drifts silently otherwise.


## Further reading

- [`CHANGELOG.md`](CHANGELOG.md) — what each release contains, and how releases are versioned
- [`docs/PLAN.md`](docs/PLAN.md) — findings, design decisions, and what is planned next
- [`docs/RESEARCH-METHOD.md`](docs/RESEARCH-METHOD.md) — how all of it was established, including the
  part that went wrong
- [`docs/ALTERNATIVES.md`](docs/ALTERNATIVES.md) — where Sciter sits among the other ways to build a
  desktop UI, what it gives up, and what to watch
- [`docs/SDK-PARITY.md`](docs/SDK-PARITY.md) — how these examples, tests and guides line up against
  everything the SDK ships, and which of its 64 script samples have no host API to bind at all
- [`docs/VDOM.md`](docs/VDOM.md) — a design note for a retained-diff layer over the DOM: what it would
  cost, when it would pay, and when not to build it. **Nothing built; a decision aid, not a plan**
- [`docs/FLEURY-UI.md`](docs/FLEURY-UI.md) — the immediate-mode-over-retained-cache architecture the
  above would be the retained half of
- [Sciter documentation](https://docs.sciter.com/docs/intro) and [tutorials](https://sciter.com/tutorials/)
