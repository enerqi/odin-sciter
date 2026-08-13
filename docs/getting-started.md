# Getting started

Everything you need to get a window on screen, and what to do when it does not appear.

## What you need

- [Odin](https://odin-lang.org/docs/install/) — a recent nightly or release
- [just](https://just.systems/) — the task runner every command below uses
- a Linux x64 desktop, for now. Windows and macOS are not vendored or tested yet; see
  [`deployment.md`](./deployment.md).

The engine itself is vendored in `lib/linux/x64/libsciter.so`, so there is nothing to download and no
system package to install.

```sh
git clone --depth 1 https://github.com/enerqi/odin-sciter.git
cd odin-sciter
just example hello_window
```

A window opens, rendered by Sciter, with HTML and CSS in it. That example uses the raw generated
bindings and nothing else, so it is also the shortest complete description of what the wrapper does.

## The smallest program

```odin
package main

import "../sciter_app"

main :: proc() {
	if !sciter_app.load_engine() {return}   // opens libsciter.so, prints where it looked on failure
	sciter_app.init()                       // hands the engine argc/argv - required before any window
	sciter_app.set_default_debug_output()   // route CSS/script errors to stderr - see below

	window, err := sciter_app.create_window({width = 720, height = 480})
	if err != nil {return}

	sciter_app.load_html(window, "<html><body><h1>Hello from Odin</h1></body></html>")
	sciter_app.show(window)

	sciter_app.run()                        // message pump; returns when the last main window closes
	sciter_app.shutdown()
}
```

Five calls in a fixed order, and the order is not negotiable:

| Call | Why it must be there |
| --- | --- |
| `load_engine` | opens the shared library and fetches the API table. Nothing works before it. |
| `init` | `SCITER_APP_INIT`. The engine wants argv, as UTF-16. Skipping it crashes on window creation. |
| `create_window` | `.MAIN` is the default flag, and it is what makes closing the window end `run` |
| `show` | a window is created hidden |
| `run` | Sciter's own pump — no GTK, no Win32 loop, on any platform |

`shutdown` releases the engine's resources afterwards. `stop` asks `run` to return early, and is safe
to call from inside an event handler.

Put your files somewhere that can `import "path/to/sciter_app"`, or add the repository as an Odin
collection. The examples import it by relative path because they live inside the repository.

## Install the debug output, first

```odin
sciter_app.set_default_debug_output()
```

Without a debug output handler installed, **a CSS typo, a bad URL and a script exception are all
completely silent**. The document simply renders wrong, or renders empty, with nothing on stderr. This
is the single most confusing thing about a first Sciter document, and one line fixes it:

```
[sciter CSS Warning] unknown property 'flexx'
[sciter SCRIPT Error] ReferenceError: odin_reverse is not defined
```

`set_debug_output` takes your own `proc "system"` handler if you want the messages somewhere else.
Script's `console.log` arrives through the same channel.

## Where the engine is looked for

`load_engine` wraps `sciter.load()`, which searches in this order and stops at the first hit:

1. an explicit path you pass — a library file, or a directory containing one
2. `SCITER_LIB` — likewise a file or a directory
3. the directory containing the running executable
4. `lib/<platform>/` relative to the working directory — where this repository keeps its copy
5. the system loader's search path (`LD_LIBRARY_PATH`, `PATH`, `DYLD_LIBRARY_PATH`)

On failure it lists every candidate it tried, which is why `load_engine` prints them:

```
could not load the Sciter engine: Library_Not_Found
looked for libsciter.so in:
  /home/you/proj/libsciter.so
  lib/linux/x64/libsciter.so
  libsciter.so

Set SCITER_LIB to the library file or its directory, e.g.
  SCITER_LIB=/path/to/sciter-js-sdk/bin/linux/x64 just example hello_window
```

The file name per platform is `libsciter.so`, `sciter.dll`, `libsciter.dylib`.

## When it does not work

**"could not load the Sciter engine: Library_Not_Found"** — the candidate list above is the whole
diagnosis. Point `SCITER_LIB` at the directory holding the library.

**"Version_Mismatch"** — the library that was found implements a different `ISciterAPI` than these
bindings were generated from. This is refused rather than tolerated: the struct's field offsets would
differ, so every call would land in the wrong slot and crash somewhere unrelated. Either use the
vendored engine, or regenerate the bindings against the headers matching your library
(`just bindgen`). The pinned version is in
[`external/sciter/VENDORED.md`](../external/sciter/VENDORED.md).

**The window opens, then segfaults on X11.** Run with `XMODIFIERS=@im=none`. The crash is inside the
engine binary's X input-method handling (`XSetICFocus`), it fires when the window takes focus, and
disabling XIM avoids it — 3 crashes out of 3 without it here, 0 out of 3 with. It is not a fault in
the bindings.

**It segfaults *inside* `create_window`, before any window appears — and `XMODIFIERS=@im=none` makes no
difference.** Different crash, same engine code: when the engine cannot create a window it faults while
cleaning up the one it failed to build (`XDestroyIC`), instead of returning NULL. The usual cause on a
headless Linux box is no usable EGL/GLESv2 — and note that a passing `glxinfo` does not establish that,
since GLX and EGL are different Mesa paths and the engine uses EGL. Do not guess: run
`just window-canary` under Xvfb or Xephyr. It traces how far the engine gets (`XCreateWindow`,
`XOpenIM`, `eglGetDisplay`, …), prints a backtrace, and dumps `eglinfo`, `glxinfo` and the X server's
extension list, which between them name the missing package. Details in
[`ENGINE.md`](./ENGINE.md#the-other-x11-input-method-crash-a-window-that-fails-to-open).

**A blank window, or unstyled content.** Almost always a resource that did not load. Install the debug
output (above), and check whether relative URLs have a base to resolve against — `load_html` with no
`base_url` gives `<img src="logo.png">` nowhere to look. `load_file` sets the base for you.

**A crash with no obvious cause, after an SDK upgrade.** Run `just example api_map`. It walks all 189
`ISciterAPI` slots and resolves each function pointer back to the symbol and module it belongs to; the
expected result is 189 slots, 16 null (platform-padded), 0 mismatches. This is the check that catches
a header/binary mismatch, and it is how the abandoned GitHub mirror's broken table was found.

**`malloc(): unaligned tcache chunk detected` in tests.** Sciter is single-threaded — every
`ISciterAPI` call must come from the thread that ran `SCITER_APP_INIT` — while Odin's test runner is
parallel by default. Every test recipe here passes `-define:ODIN_TEST_THREADS=1` for that reason.

## Where to go next

| You want to | Read |
| --- | --- |
| understand why the bindings are shaped this way | [`architecture.md`](./architecture.md) |
| write the UI itself | [`html-css-js.md`](./html-css-js.md) |
| move data between Odin and script | [`calling-between-odin-and-js.md`](./calling-between-odin-and-js.md) |
| read and change the document from Odin | [`dom.md`](./dom.md) |
| react to clicks and keys in Odin | [`events.md`](./events.md) |
| ship HTML/CSS/images inside the binary | [`resources.md`](./resources.md) |
| ship the thing | [`deployment.md`](./deployment.md) |
| look a procedure up | [`api.md`](./api.md) |
| upgrade the engine, or cut a release | [`UPGRADING.md`](./UPGRADING.md) |

The examples are ordered by difficulty and each is a single self-contained file with the explanation
in its header comment. `just example NAME` runs one.
