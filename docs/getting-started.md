# Getting started

Everything you need to get a window on screen, and what to do when it does not appear.

## What you need

- [Odin](https://odin-lang.org/docs/install/) — **`dev-2026-08`** is what CI builds with and what these
  recipes are tested against. There is no stable release line and `core:` changes between nightlies, so
  a much newer or older one may not compile the tree. The pin lives in
  [`.github/actions/toolchain/action.yml`](../.github/actions/toolchain/action.yml)
- [just](https://just.systems/) — the task runner every command below uses; CI pins `1.55.1`
- [uv](https://docs.astral.sh/uv/getting-started/installation/) — **not optional, and needed before the
  first build**: every Python step here runs through it, and fetching the engine is one of them. The
  recipes check for it and print the install command rather than failing as "os error 2"
- Linux x64, Windows x64 or macOS. The first two have been run on real machines; macOS is exercised in
  CI only. The platform table in [`README.md`](../README.md#finding-the-engine) says exactly what that
  does and does not prove, and [`deployment.md`](./deployment.md) covers shipping.

```sh
git clone --depth 1 https://github.com/enerqi/odin-sciter.git
cd odin-sciter
just example hello_window
```

A window opens, rendered by Sciter, with HTML and CSS in it. That example uses the raw generated
bindings and nothing else, so it is also the shortest complete description of what the wrapper does.

**The first command downloads the engine** — 24 MB on Linux, 19 on Windows, 50 on macOS. No engine is
committed to this repository, so `just fetch-engine` installs one, verified against a SHA-256 recorded
in [`external/sciter/VENDORED.md`](../external/sciter/VENDORED.md). Every recipe that builds or runs
anything depends on `just ensure-engine`, so the first build fetches once and later ones do not. There
is no system package to install.

## Before you write anything: the two pages that are not optional

Skip these and the cost is a debugging session, not a compile error.

- [`rules.md`](./rules.md) — the four contracts that decide whether your program is correct: thread
  affinity, `Value` ownership, handle lifetimes, and which allocator a call uses. Short, and the one
  page here that is not optional.
- [`gotchas.md`](./gotchas.md) — the things that cost a day each. Close every window before you exit,
  publish assets before the load and functors after, and do not `switch` on an event code without a
  default arm.

## The smallest program

```odin
package main

import "../sciter_app"

main :: proc() {
	if !sciter_app.load_engine() {return}   // opens libsciter.so, prints where it looked on failure
	sciter_app.init()                       // argc/argv, and the debug output - required before any window

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
| `init` | `SCITER_APP_INIT`. The engine wants argv, as UTF-16. Skipping it faults **at process exit**, not here — see below. It also installs the debug output, unless you pass `debug_output = false`. |
| `create_window` | `.MAIN` is the default flag, and it is what makes closing the window end `run` |
| `show` | a window is created hidden |
| `run` | Sciter's own pump — no GTK, no Win32 loop, on any platform |

`shutdown` releases the engine's resources afterwards. `stop` asks `run` to return early, and is safe
to call from inside an event handler.

**Leaving `init` out is the one omission the engine does not report, and it was documented wrongly here
until it was measured.** On Windows, 6.0.4.9: without `init` the window is created, the document loads,
the DOM answers, and `hide` / `heartbeat` / `close` all succeed — and then the process segfaults on the
way out of `main`, exit code 139, with nothing on the stack naming the omission. The same program with
`init` exits 0. A debug build now traps inside `create_window` instead, where the call is still on the
stack; a release build gets the exit fault, so this is a line to write rather than a check to rely on.

**`run` never comes back to your code, and your handlers are where the scratch memory is spent.** Every
call that takes a string, a selector or a URL builds its argument in `context.temp_allocator`, and `run`
is the engine's own loop — so there was nowhere for an application to put `free_all`. The package takes
that boundary itself now: **every callback that runs your code unwinds the temp arena to where it was
when the engine called in.** A handler can read text, walk selectors and build strings for the life of
the program without the arena growing.

The cost is the other side of the same rule: **temp memory does not outlive the callback that made it.**
Anything a handler keeps — a label appended to application state, a string stashed for a `.DELAYED`
request — needs `context.allocator`, a clone, or an arena of its own.

Your own main-line code is untouched, and nothing in this package ever calls `free_all`, so if you drive
the pump yourself the boundary there is still yours to choose:

```odin
for sciter_app.run_once() {
	sciter_app.heartbeat()
	free_all(context.temp_allocator)   // your boundary; the handlers already have theirs
}
```

[`rules.md`](./rules.md#a-callback-is-a-temp-allocator-boundary-and-the-package-takes-it) is the whole
rule.

The examples import `sciter_app` by relative path because they live inside this repository. For your
own program, vendor the repository and point an Odin collection at it —
[`using-in-your-project.md`](./using-in-your-project.md) is that page, with the flag, what the minimum
checkout is, and how the engine reaches your users.

## The debug output, which `init` installs for you

Without a debug output handler installed, **a CSS typo, a bad URL and a script exception are all
completely silent**. The document simply renders wrong, or renders empty, with nothing on stderr. That
is the single most confusing thing about a first Sciter document — and on Windows it is worse than
confusing, because the engine's fallback is `OutputDebugStringW`, which raises an exception that can be
fatal to any process treating first-chance exceptions as errors.

So `init` installs the default handler unless you tell it not to (`init(debug_output = false)`), and
`set_default_debug_output()` is the same call if you want it somewhere else — on one window, or after
having installed your own. What arrives looks like this:

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

Either put libsciter.so next to the executable - the first path above - or point
SCITER_LIB at the library file or the directory holding it:
  export SCITER_LIB=/path/to/sciter-js-sdk/bin/linux/x64
```

The last two lines are written for the platform the program was built for: `set SCITER_LIB=…` and the
PowerShell spelling on Windows, `export` on Linux and macOS. The file name per platform is
`libsciter.so`, `sciter.dll`, `libsciter.dylib`.

Inside this repository the answer is usually neither: `just fetch-engine` puts the pinned engine in
`lib/<platform>/`, which is candidate 4, and every recipe that builds anything does it for you. The two
that matter are for a program *outside* the repository — see
[`using-in-your-project.md`](./using-in-your-project.md).

## When it does not work

**"could not load the Sciter engine: Library_Not_Found"** — the candidate list above is the whole
diagnosis. Point `SCITER_LIB` at the directory holding the library.

**"Version_Mismatch"** — the library that was found implements a different `ISciterAPI` than these
bindings were generated from. This is refused rather than tolerated: the struct's field offsets would
differ, so every call would land in the wrong slot and crash somewhere unrelated. Either use the
pinned engine `just fetch-engine` installs, or regenerate the bindings against the headers matching
your library (`just bindgen`). The pinned version is in
[`external/sciter/VENDORED.md`](../external/sciter/VENDORED.md).

**The window opens, then segfaults on X11.** Run with `XMODIFIERS=@im=none`. The crash is inside the
engine binary's X input-method handling (`XSetICFocus`), it fires when the window takes focus, and
disabling XIM avoids it — 3 crashes out of 3 without it here, 0 out of 3 with. It is not a fault in
the bindings.

**It segfaults on a CI runner, in a container, or over ssh — before any window appears.** Set
`XDG_SESSION_TYPE=x11`. The engine picks its windowing backend from that variable and only the literal
`x11` selects X11; unset — the normal state in all three of those places — selects a GTK4 path that
calls a NULL function pointer inside `SciterExec(.INIT)`. It has nothing to do with your renderer, and
`XMODIFIERS` does not affect it. Details in
[`ENGINE.md`](./ENGINE.md#xdg_session_type-decides-the-windowing-backend-and-gets-it-wrong-unset).

**It segfaults *inside* `create_window`, and `XDG_SESSION_TYPE` is already `x11`.** A different crash:
when the engine cannot create a window it faults while cleaning up the one it failed to build
(`XDestroyIC`), instead of returning NULL. The usual cause on a
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
expected result is 189 slots, **0 mismatches**, and the null count for your platform — 16 on Linux and
macOS, 15 on Windows, which nulls that same list minus `SciterProcND`. The nulls are platform padding
and are not a fault; the mismatches are. `examples/api_map.odin`'s header comment has the measured list
per platform. This is the check that catches a header/binary mismatch, and it is how the abandoned
GitHub mirror's broken table was found.

**`malloc(): unaligned tcache chunk detected` in tests.** Sciter is single-threaded — every
`ISciterAPI` call must come from the thread that ran `SCITER_APP_INIT` — while Odin's test runner is
parallel by default. Every test recipe here passes `-define:ODIN_TEST_THREADS=1` for that reason.

## Where to go next

| You want to | Read |
| --- | --- |
| **see the shape of a whole program** | [`examples/app_skeleton.odin`](../examples/app_skeleton.odin) — a model, one render, one handler, ~200 lines |
| **use this from your own project** | [`using-in-your-project.md`](./using-in-your-project.md) |
| **get the four contracts right** | [`rules.md`](./rules.md) |
| **avoid the footguns that cost a day each** | [`gotchas.md`](./gotchas.md) |
| understand why the bindings are shaped this way | [`architecture.md`](./architecture.md) |
| write the UI itself | [`html-css-js.md`](./html-css-js.md) |
| move data between Odin and script | [`calling-between-odin-and-js.md`](./calling-between-odin-and-js.md) |
| read and change the document from Odin | [`dom.md`](./dom.md) |
| react to clicks and keys in Odin | [`events.md`](./events.md) |
| get work off the UI thread | [`threading.md`](./threading.md) |
| ship HTML/CSS/images inside the binary | [`resources.md`](./resources.md) |
| ship the thing | [`deployment.md`](./deployment.md) |
| look a procedure up | [`api.md`](./api.md) |
| upgrade the engine, or cut a release | [`UPGRADING.md`](./UPGRADING.md) |

[`README.md`](./README.md) is the full index — every guide, split by audience, with the maintainer
notes marked as such.

The examples are ordered by difficulty and each is a single self-contained file with the explanation
in its header comment. `just example NAME` runs one.

**The one to read after this page is [`app_skeleton`](../examples/app_skeleton.odin).** The program above
is five calls and a window; an application is a model, a render, a handler and the four contracts in
[`rules.md`](./rules.md), and that example is the smallest thing that has all of them —
about 200 lines, no cleverness, meant to be copied and cut down. `task_list` is the same shape once it
has grown a keyboard, persistence and a real UI, and `workbench` is what it looks like under load.
