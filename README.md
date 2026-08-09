# odin-sciter

[Odin](http://odin-lang.org/) bindings for [Sciter.JS](https://sciter.com/) — an embeddable HTML/CSS/JS
engine for building desktop application interfaces.

You write your UI in HTML and CSS, script it in JavaScript, and drive it from Odin. Sciter is not a
browser and not Electron: the whole engine is a single ~25 MB shared library with no Chromium, no
Node.js, and no separate process. A "hello world" application is one Odin file and one HTML string.

> **Status: early.** The generated bindings work and are verified against the shipped engine — see
> [`docs/PLAN.md`](docs/PLAN.md) for exactly what is done and what is not. The friendly wrapper API is
> not written yet, so today you call the engine's C-shaped functions directly. Linux x64 is the only
> platform vendored and tested so far.

```odin
package main

import "core:fmt"
import sciter ".."

main :: proc() {
	err, _ := sciter.load()
	if err != .None {
		fmt.eprintln("could not load the Sciter engine:", err)
		return
	}
	api := sciter.api()
	fmt.println("Sciter", api.SciterVersion(0), api.SciterVersion(1))
}
```

A complete window is [`examples/hello_window.odin`](examples/hello_window.odin) — about 60 lines,
including the HTML.


## Quick start

You need [Odin](https://odin-lang.org/docs/install/) and [just](https://just.systems/).

```sh
git clone <this repository>
cd odin-sciter
just example hello_window
```

A window opens with HTML and CSS rendered by Sciter. The engine is vendored in `lib/`, so this works
offline with nothing else installed.

If it does not load, the error lists every path it tried. Point it at a library explicitly with:

```sh
SCITER_LIB=/path/to/sciter-js-sdk/bin/linux/x64 just example hello_window
```


## How it works, in one section

This is worth reading before anything else, because Sciter's shape drives every design decision here.

Sciter's shared library exports **exactly one symbol**: `SciterAPI()`. It returns a pointer to
`ISciterAPI`, a C struct of 189 function pointers. Every call in these bindings is a field of that
struct. There is nothing else to link against.

```
$ nm -D --defined-only lib/linux/x64/libsciter.so | grep -w SciterAPI
00000000007e4a19 T SciterAPI
```

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

That walks every slot and resolves each pointer back to its symbol name with the dynamic linker. It is
also the regression test for a Sciter upgrade — 189 slots, 0 mismatches expected.


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
| `src/prelude.odin` | Hand-written: the loader, `api()`, and the doc comments explaining them. Pasted into `sciter.odin` at generation time. |
| `bindgen.sjson` | odin-c-bindgen configuration, heavily commented |
| `src/flatten_headers.py` | Concatenates the SDK headers into one file for bindgen, and explains why that is necessary |
| `src/postprocess_bindings.py` | Rewrites the calling convention for 32-bit Windows |
| `external/sciter/` | Vendored SDK headers, both licences, and `VENDORED.md` (pinned version) |
| `lib/` | The engine binaries |
| `examples/` | Runnable examples, one file each |
| `spike/smoke/` | The minimal ABI handshake, written before any bindings existed |
| `docs/` | Plan, findings, and how the research was done |


## Development

Tasks run with [just](https://just.systems/).

- `just example NAME` — build and run `examples/NAME.odin`; defaults to `hello_window`
- `just check` — type check the bindings package
- `just bindgen` — regenerate `sciter.odin` from `external/sciter/include`
- `just format` — `odinfmt -w .`

Regenerating needs [odin-c-bindgen](https://github.com/karl-zylinski/odin-c-bindgen) built alongside
this repository (`../odin-c-bindgen/bindgen.bin`), or `ODIN_C_BINDGEN` pointing at it, plus
[uv](https://docs.astral.sh/uv/) for the two Python steps.

> The skeleton's `run_*`, `rerun_*`, `sanitize` and `test` recipes still assume the root package has a
> `main`, which it does not. They are not wired up yet.


## Sciter version

| | |
| --- | --- |
| SDK | [gitlab.com/sciter-engine/sciter-js-sdk](https://gitlab.com/sciter-engine/sciter-js-sdk) tag `6.0.4.9-bis` |
| Engine | 6.0.4.9 |
| `SCITER_API_VERSION` | 10 |

> **Use the GitLab repository.** The `c-smile/sciter-js-sdk` mirror on GitHub is abandoned — last commit
> 2022, engine 4.4.8.33 — and its headers do not match the binaries committed beside them. Details in
> [`external/sciter/VENDORED.md`](external/sciter/VENDORED.md).


## Further reading

- [`docs/PLAN.md`](docs/PLAN.md) — findings, design decisions, and what is planned next
- [`docs/RESEARCH-METHOD.md`](docs/RESEARCH-METHOD.md) — how all of it was established, including the
  part that went wrong
- [Sciter documentation](https://docs.sciter.com/docs/intro) and [tutorials](https://sciter.com/tutorials/)
