# Gotchas

The things that cost a day each. Every one is measured, every one is surprising, and none of them is
guessable from the C headers — which is the whole reason this file exists. The engine is a binary blob
with no source and the published documentation covers HTML/CSS/JS for *script* authors, not the host
API; what a host has to know lives in header comments, in a 2019 forum post, or nowhere.

Ordered by how much time they cost, worst first. Each links to the full measurement.

---

## 1. Close every window before you exit — on Windows it is not optional

**Symptom:** the process faults at exit with an access violation inside `sciter.dll`, *after* the
application's work has finished successfully. Exit code non-zero, nothing to show for it.

```odin
sciter_app.hide(window)
sciter_app.heartbeat()   // the pump is what takes it off the paint list
sciter_app.close(window)
sciter_app.heartbeat()
```

**Why it is not obvious:** the fault only fires when the window's document laid out no text, so a
realistic UI hides it completely and a minimal test document exposes it. It is a real engine bug —
[UPSTREAM-DEFECTS.md #11](./UPSTREAM-DEFECTS.md) has the reproduction and the matrix — but closing the
window avoids it outright whatever the document contains.

**On Linux** the same order is required for a different reason: closing a secondary window that still
has a document loaded segfaults on the next pump unless you hide and pump first. See `close` in
`sciter_app/window.odin` for the five teardown orders measured there.

One order is correct on both. Write it.

## 2. Two entry points take untyped words, and the headers under-document both

`SciterExec` and `SciterWindowExec` are ioctl-style dispatchers — one function, many commands, and the
arguments mean whatever the command says they mean:

```c
INT_PTR SciterExec      (UINT appCmd    /*SCITER_APP_CMD*/,    UINT_PTR p1, UINT_PTR p2);
INT_PTR SciterWindowExec(HWINDOW, UINT windowCmd /*SCITER_WINDOW_CMD*/, UINT_PTR p1, UINT_PTR p2);
```

The enums exist — `SCITER_WINDOW_CMD`, `SCITER_WINDOW_STATE`, `SCITER_APP_CMD` — but **nothing is typed
as one**: the command is a bare `UINT` with the type name demoted to a comment, and in `sciter-x-api.h`,
the vtable file these bindings are generated from, even that comment is stripped to `/**/`.

**Two parameters were found hiding there, both by reading the C++ layer:**

| call | what the C header says | what it really is |
| --- | --- | --- |
| `SET_STATE` + `.CLOSED` | `p2 - N/A` | `p2` is the force flag |
| `APP_STOP` | *"reuest to quit message pump loop"* | `p1` is the value `run` returns |

```cpp
void request_close() { SciterWindowExec(_hwnd, SET_STATE, STATE_CLOSED, FALSE); }
void close()         { SciterWindowExec(_hwnd, SET_STATE, STATE_CLOSED, TRUE);  }
bool request_quit(int rv) { return SciterExec(SCITER_APP_STOP, rv, 0) == 0; }
```

This wrapper passed `0` for both. So `close` was really `request_close` — script could refuse it, and on
Windows the window was never destroyed, which is #1 above — and `stop` could not set an exit code. Both
fixed: `close(window, force := true)`, `request_close`, and `stop(exit_code := 0)`. Measured: `stop(42)`
from inside the pump makes `run` return 42.

**The force flag itself is not portable.** Windows honours it; **Linux ignores it and closes either
way**. So `request_close` cannot be used to mean "let script veto this" in portable code — on Linux
there is no veto. An application that needs one has to ask the document and decide in Odin.

**Why the API is shaped this way.** `ISciterAPI` is 189 offset-addressed slots, so adding a *function* is
an ABI event while adding a *command* to an existing dispatcher is free. Command dispatch is how this API
grows without breaking the table — the same trade as `ioctl` or `SendMessage`. The cost is that
per-command parameter meanings live only in comments, and comments rot: `p2 - N/A` was presumably true
before `close` gained its flag.

**So when the C header and `include/*.hpp` disagree, the C++ layer is right.** It is the code Terra
Informatica actually ships applications with; the C header is a machine boundary they do not read. Those
two dispatchers are the only places a parameter can hide like this, which at least makes it a finite
list — every command this wrapper sends has now been checked against the C++ layer, and the rest match.

## 3. Install a debug-output handler on Windows, or a CSS warning can kill your process

```odin
sciter_app.set_default_debug_output()   // before loading any document
```

With none installed the engine reports diagnostics through `OutputDebugStringW`, and Windows implements
that by **raising an exception** (`DBG_PRINTEXCEPTION_WIDE_C`, `0x4001000A`). In a normal run the OS
handles it and nothing notices. Under anything that treats first-chance exceptions as fatal — a test
runner, some crash reporters, some sandboxes — a single CSS warning takes the process down.

Every test harness in `examples/` calls it for exactly this reason, not because the messages are wanted.

## 4. The engine throws C++ exceptions in ordinary operation

A document whose script will not parse, a `value_parse` on bad input — each throws and catches
internally. That is normal control flow, and on Windows every throw is an SEH exception (`0xE06D7363`).

It matters because Odin's test runner stops a test for *any* first-chance exception, so provoking one
kills the test and then hangs the binary. That is an Odin bug, with a written and verified patch in
[`odin-test-runner-windows.patch`](./odin-test-runner-windows.patch); four tests carry a
`when ODIN_OS != .Windows` guard until it lands. If you write your own harness, filter by exception code.

## 5. A test that reads freed memory is a landmine, not a demonstration

`behavior.odin` had a test that deliberately released a `Value` the caller still owned, then read it
back to prove the reference really was given away. It documented a genuine hazard, and it worked on
Linux for a long time — then segfaulted the Windows CI runner at exactly that read, took every later
test in the binary with it, and timed the job out at 420 seconds.

Reading freed memory is entitled to do that. The surprise was that it ever worked, not that it stopped;
a different allocator is all it takes. The read is now Linux-only, where it is measured, with a note to
delete rather than chase it if it ever faults there too.

The general point for anything written against this engine: **a use-after-free that "works" is a
platform accident**, and in a shared-process test binary one of them takes the whole suite down rather
than failing alone.

## 6. Sciter is single-threaded, and the test runner is not

Every `ISciterAPI` call must come from the thread that ran `SCITER_APP_INIT`. Odin's test runner is
parallel by default, so every test recipe passes `-define:ODIN_TEST_THREADS=1`. Without it the engine's
heap is corrupted rather than the tests failing cleanly — it presents as
`malloc(): unaligned tcache chunk detected`. See [`threading.md`](./threading.md).

## 7. An asset is published *before* the load; a functor *after*

Globals belong to the document, so a native functor has to be republished after every `load_html`. A SOM
asset is the other way round — `set_global_asset` has to happen **before** the load, and it appears in
the next document rather than the current one. Getting either backwards produces "undefined", not an
error. `examples/call_odin_from_js.odin` pins both directions.

## 8. Platform differences that are real, and run the way round you would not guess

| | Linux | Windows |
| --- | --- | --- |
| `window_state` after `set_window_state` | only ever `.SHOWN` or `.CLOSED` | reflects the request faithfully |
| a window created and never shown | reports `.CLOSED` | reports `.HIDDEN` |
| `element_by_uid(element_uid(e))` | fails — **broken on this build** | exact round trip |
| `file:` URLs from `combine_url` | three slashes | two — the engine's canonical form there |
| clipboard text flavour | NUL-terminated | clean |
| `.CONNECTION_TIMEOUT`, `.HTTPS_ERROR` | refused | accepted |
| ASan | catches heap errors | catches **no** heap errors — `HeapAlloc` is not intercepted |

The portable rule is usually the Linux one: code written against the Windows answer compiles on Linux
and silently never fires. Keep your own flag rather than asking the engine what state a window is in.

## 9. The inspector needs `.SOCKET_IO`, and says so nowhere obvious

Three things are required, and the third is the one everyone misses:

1. the window created with `.ENABLE_DEBUG`
2. `set_debug_mode()` before the window exists
3. **`set_script_features({.FILE_IO, .SOCKET_IO, .EVAL, .SYSINFO})`** — the connection is a socket opened
   by the *document's* script runtime

With 1 and 2 and not 3 the inspector waits forever on "Waiting for a connection with Sciter's view",
which reads as a problem with 1 or 2. `examples/inspector.odin` had this bug and it had never worked.

## 10. A `switch` on an event code needs a default arm, or it drops every application event

`sciter.Behavior_Events` is an enum, and it is a **partial** naming of a `UINT` space rather than a
closed set. `FIRST_APPLICATION_EVENT_CODE` is the floor above which an application defines its own
codes, and the docs tell you to use it — so your own events reach a handler as
`sciter.Behavior_Events(MY_CODE)`, a legal value with no enum member behind it.

```odin
switch be.code {
case .BUTTON_CLICK: ...
case .SELECT_VALUE_CHANGED: ...
case:               // <- without this arm, every application-defined event is silently ignored
}
```

The enum is still the right binding — it names what upstream names and stays open where upstream is
open — but nothing in the type says the set is partial, and a `switch` that looks exhaustive is not.
`-vet` may also object to the conversion.

---

## Where the knowledge actually lives

- **`external/sciter/include/*.h`** — the C ABI. Comments are the only C-API documentation there is, and
  they are wrong in at least one place (see #2).
- **the SDK's `include/*.hpp`** — deliberately not vendored here, and worth reading anyway.
  `sciter-x-window.hpp` is the authority on both the start-up and the teardown sequence.
- **the SDK's `demos/`, `samples.*`** — `demos/sciter-mfc` shows the intended
  `SCITER_APP_INIT` → … → `SCITER_APP_SHUTDOWN` lifecycle.
- **[docs.sciter.com](https://docs.sciter.com/docs/intro)** — a Docusaurus render of
  `sciter-js-sdk/docs/md`, which you already have in an SDK checkout. Script-side only: DOM, CSS, JS,
  behaviours. Nothing about the host API.
- **[sciter.com/forums](https://sciter.com/forums/)** — where host lifecycle knowledge is written down
  and nowhere else. "Close all windows and free all resources before exiting" is a 2019 forum post.
- **the GitLab wiki** — empty. Do not bother.
