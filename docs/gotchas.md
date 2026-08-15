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

## 2. `close` used to be `request_close`, and the header says the difference does not exist

`sciter-x-def.h` annotates `SCITER_WINDOW_SET_STATE` as `p1 - SCITER_WINDOW_STATE, p2 - N/A`. **`p2` is
not N/A.** For `.CLOSED` it is the force flag, and the SDK's own C++ layer is where you find that out:

```cpp
void request_close() { SciterWindowExec(_hwnd, SET_STATE, STATE_CLOSED, FALSE); }
void close()         { SciterWindowExec(_hwnd, SET_STATE, STATE_CLOSED, TRUE);  }
```

This wrapper passed `0` until it was measured, so `close` was really `request_close` — script could
refuse it, and on Windows the window was simply never destroyed. `close(window, force := true)` is now
the default and `request_close` is the other one, spelled out.

**The lesson generalises: when the header and `include/*.hpp` disagree, the C++ layer is right.** It is
the code Terra Informatica actually ships applications with.

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

## 5. Sciter is single-threaded, and the test runner is not

Every `ISciterAPI` call must come from the thread that ran `SCITER_APP_INIT`. Odin's test runner is
parallel by default, so every test recipe passes `-define:ODIN_TEST_THREADS=1`. Without it the engine's
heap is corrupted rather than the tests failing cleanly — it presents as
`malloc(): unaligned tcache chunk detected`. See [`threading.md`](./threading.md).

## 6. An asset is published *before* the load; a functor *after*

Globals belong to the document, so a native functor has to be republished after every `load_html`. A SOM
asset is the other way round — `set_global_asset` has to happen **before** the load, and it appears in
the next document rather than the current one. Getting either backwards produces "undefined", not an
error. `examples/call_odin_from_js.odin` pins both directions.

## 7. Platform differences that are real, and run the way round you would not guess

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

## 8. The inspector needs `.SOCKET_IO`, and says so nowhere obvious

Three things are required, and the third is the one everyone misses:

1. the window created with `.ENABLE_DEBUG`
2. `set_debug_mode()` before the window exists
3. **`set_script_features({.FILE_IO, .SOCKET_IO, .EVAL, .SYSINFO})`** — the connection is a socket opened
   by the *document's* script runtime

With 1 and 2 and not 3 the inspector waits forever on "Waiting for a connection with Sciter's view",
which reads as a problem with 1 or 2. `examples/inspector.odin` had this bug and it had never worked.

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
