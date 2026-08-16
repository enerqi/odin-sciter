# Using these bindings in your own project

Everything else here is written from inside this repository, where the examples import `sciter_app` by
relative path and `just` fetches the engine for you. This page is the other case: your program, your
build, this repository as a dependency.

**You do not need `just` or `uv` to consume these bindings.** They are the repository's own tooling.
What your build needs is Odin, the two Odin packages, and the engine binary at runtime.

## 1. Get the code

There is no package manager for Odin and **no tagged release here yet**, so pin a commit rather than
tracking a branch:

```sh
# a submodule, if your project is a git repository
git submodule add https://github.com/enerqi/odin-sciter.git vendor/odin-sciter
git -C vendor/odin-sciter checkout <commit>

# or a plain copy
git clone --depth 1 https://github.com/enerqi/odin-sciter.git vendor/odin-sciter
```

**Vendor the repository root, not `sciter_app/` on its own.** `sciter_app` does `import sciter ".."`, so
the directory *above* it has to be the generated `package sciter`. Copying only the subdirectory gives
you a package that cannot resolve its own import.

If you would rather not carry the examples and the guides, the minimum that compiles is two entries —
measured at **560 KB**, built and run:

```
vendor/odin-sciter/
	sciter.odin        the generated bindings, `package sciter`
	sciter_app/        the ergonomic layer, 22 files
```

Everything else — `examples/`, `docs/`, `justfile`, `external/`, `src/` — is for working *on* the
bindings, not with them. Keep `external/sciter/VENDORED.md` if you want the engine's pinned version and
SHA-256 written down somewhere, and `LICENSE` plus `external/sciter/SCITER-ENGINE-EULA.md` if you are
redistributing (see [`deployment.md`](./deployment.md#licensing) — the engine's EULA wants an
attribution line in your About box).

## 2. Build against it

Point an Odin collection at whatever directory you vendored, and import through it:

```odin
package myapp

import sa "sciter:sciter_app"
import "core:fmt"

main :: proc() {
	if !sa.load_engine() {return}   // prints where it looked, and how to fix it, on failure
	sa.init()
	sa.set_default_debug_output()

	window, err := sa.create_window({width = 400, height = 300})
	if err != nil {
		fmt.eprintln("no window:", err)
		return
	}
	sa.load_html(window, "<html><body><h1>external project</h1></body></html>")
	sa.show(window)

	sa.run()
	sa.shutdown()
}
```

```sh
odin build . -collection:sciter=vendor/odin-sciter -out:myapp.exe
```

The raw bindings live at the collection's root, and reaching them wants the spelling with the dot —
measured, because the obvious one is a syntax error rather than a lookup failure:

```odin
import sciter "sciter:."      // package sciter, the generated C API
import sa "sciter:sciter_app" // the ergonomic layer
```

```
import sciter "sciter:"
^~~~~~~~~~~~~~~~~~~~~~^ Syntax Error: Invalid import path: ''
```

The two mix freely, which is the whole point of the split ([`architecture.md`](./architecture.md)).

`-collection:` is the only build flag involved. There is nothing to link: the engine is opened at
runtime with `dlopen`/`LoadLibrary`, so your program has no dependency on it at link time and will build
on a machine that has never seen it.

## 3. Get the engine to your users

Your program needs `libsciter.so` / `sciter.dll` / `libsciter.dylib` at run time, and
`sciter.load()` searches five places in order. Two of them are the answers worth knowing here — both
measured against a program outside this repository:

| | how |
| --- | --- |
| **beside the executable** | copy the library next to your `.exe` / binary. Candidate 3, no configuration, and the answer for anything you ship |
| **`SCITER_LIB`** | point it at the library file or the directory holding one. Candidate 2, and the answer while developing |
| an explicit path | `sa.load_engine("/usr/lib/myapp/libsciter.so")` — for an installed layout |

```sh
export SCITER_LIB=/path/to/engine/dir        # Linux, macOS
set SCITER_LIB=C:\path\to\engine\dir         # Windows, cmd
$env:SCITER_LIB = 'C:\path\to\engine\dir'    # Windows, PowerShell
```

When it is not found, `load_engine` prints every path it tried and the two spellings above for the
platform it was built for. That list is the whole diagnosis.

**Where to get the binary itself.** `just fetch-engine` inside a checkout of this repository downloads
the pinned engine into `lib/<platform>/`, verified against its SHA-256, and you can copy it out of
there. Without `just`, take it from the [Sciter SDK](https://gitlab.com/sciter-engine/sciter-js-sdk)'s
`bin/` — but match the version: **these bindings refuse to load an engine whose `ISciterAPI` version is
not the one they were generated against**, because every call would otherwise land in a different slot.
The pin is in [`external/sciter/VENDORED.md`](../external/sciter/VENDORED.md), and
[`getting-started.md`](./getting-started.md#when-it-does-not-work) covers `Version_Mismatch`.

Shipping — one artifact or two, packaging per platform, signing, and the attribution you owe — is
[`deployment.md`](./deployment.md). Embedding the engine *inside* your executable is `load_embedded`,
in [`resources.md`](./resources.md#the-engine-itself).

## 4. Then read

[`getting-started.md`](./getting-started.md) for the first program and what to do when the window does
not appear, and [`rules.md`](./rules.md) for the four contracts that decide whether your program is
correct — thread affinity, `Value` ownership, handle lifetimes, and which allocator a call uses. The
last of those matters more in your own program than in an example: nothing in this package ever calls
`free_all`, so **you** own the temp-allocator boundary.

## Upgrading

Move the submodule or the copy to a newer commit, and check two things: `CHANGELOG.md` for breaking
changes — there is no stable API yet and the recent history has several — and whether the engine pin
moved, in which case your users need the new binary too. The version check will refuse to load a
mismatched engine rather than crashing somewhere unrelated, so the failure mode is at least loud.
