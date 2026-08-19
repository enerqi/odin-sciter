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

## 3. A process with no debug-output handler can be killed by a CSS warning on Windows

With none installed the engine reports diagnostics through `OutputDebugStringW`, and Windows implements
that by **raising an exception** (`DBG_PRINTEXCEPTION_WIDE_C`, `0x4001000A`). In a normal run the OS
handles it and nothing notices. Under anything that treats first-chance exceptions as fatal — a test
runner, some crash reporters, some sandboxes — a single CSS warning takes the process down.

**`init` installs the default handler for this reason**, so an ordinary program no longer has to know
any of the above. The two ways back into the trap:

```odin
sciter_app.init(debug_output = false)   // you asked for the engine's own behaviour
sciter_app.set_debug_output(nil)        // detaching leaves nothing installed
```

`set_default_debug_output()` puts it back, and takes a window if you want one window's diagnostics
rather than the process's. Every test harness in `examples/` calls it directly, because a test binary
reaches the engine without going through an application's `init`.

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

## 11. A windowless view and a windowed application do not share a process

Both work. Both work in the same *program*, one after the other, as long as only one of them is what the
process is. What does not work is standing up the windowed application subsystem in a process that
already has a windowless view alive.

Measured on 6.0.4.9, converting `examples/workbench.odin`'s tests to a windowless view: its
second-window test creates another window with `create_window` and drives it with `sciter_app.heartbeat`.
Run on its own — nothing windowless in the process — it passes. Run after any other test in the file has
created a windowless view, the same test reports **zero** behavior attachments and its posted messages
never arrive. Not a crash, not an error code: the pump simply is not turning anything.

Which half is at fault was not chased down; `init` after `create_windowless` and `create_window`
alongside a live view are both candidates, and the useful rule is the same either way:

**Pick one per process.** A windowless embedding uses `create_windowless` and
`windowless_heartbeat`/`paint_windowless` and never calls `init`. An application uses `init`,
`create_window` and `run`/`heartbeat`. A test binary is a process too, which is why `workbench` and
`request_loader` keep windowed harnesses while eleven other examples moved to windowless ones.

The second half of that conversion is a smaller trap with the same shape: **a windowless view has no
pump of its own**, so anything asynchronous — a `.DELAYED` load, a request answered later — completes
only while you are calling `windowless_heartbeat`. `request_loader`'s tests became flaky (one run in
three) with a windowless harness for exactly that reason: the request had not finished by the time the
assertion read it. Beat the view until the thing you are waiting for has happened, or use a window.

And the sharp edge on macOS, which is a process-ending version of the same rule: **`run_once` is the
*application* pump, and on macOS it may only be called from the main thread.** It reaches
`xwing::application::heartbit` → `nextEventMatchingMask`, which AppKit answers with

```
*** Terminating app due to uncaught exception 'NSInternalInconsistencyException',
    reason: 'nextEventMatchingMask should only be called from the Main Thread!'
```

— not an error code, an abort of the whole process. A test is never on the main thread there, so code
that drives a windowless view from a test drives *the view*, with `windowless_heartbeat`, and never the
application. Measured: `examples/input.odin` aborted exactly this way after its harness moved to a
windowless view but its tests kept calling `run_once`.

**`heartbeat` is the exception, and it was not obvious.** `SciterExec(.LOOP_HEARTBIT)` reaches the same
`application::heartbit`, so the expectation was that it aborts too. It does not, measured on the same
runner: `examples/events.odin` drives its timer tests with `sciter_app.heartbeat` in a loop, on a
windowless view, on a test thread, and passes. The difference is presumably that a process which never
called `init` has no application to pump and the call falls through before it reaches AppKit — so treat
this as "measured, not explained", and do not read it as permission. `run_once` in the same position
ends the process.

One more, from the same run: **`set_debug_output` scoped to a windowless view's handle instantiates an
`NSWindow` on macOS**, and therefore aborts from a test. The same call on the same view is fine on Linux
and Windows. `examples/eval.odin`'s per-window handler test skips on Darwin because of it. The handle a
windowless view carries answers as a window on two platforms out of three.

## 12. A styled `<div>` is not a control, and the host hears nothing about it

**Symptom:** a list of rows, tabs or cards that look right, hover correctly if you gave them a `:hover`
rule, and are completely inert. A window handler subscribed to `.BEHAVIOR_EVENT` never fires, no error
appears in the debug output, and the DOM is exactly what you rendered.

**Cause:** `.BUTTON_CLICK` comes from a native **controller**, not from the pointer. `<button>` has one
because the engine gives it one; a `<div>` has none, so there is no click to deliver and nothing anywhere
says so. One line of CSS is the whole fix:

```css
.row { behavior: button; }   /* now it is a control, and the host's handler hears it */
```

**The diagnostic is `control_type`.** Measured on 6.0.4.9 in a windowless view: a plain `<div>` answers
`do_click` with `handled = false` and reports `.NO`; the same `<div>` with `behavior: button` answers
`true` and reports `.BUTTON`. Ask an unresponsive element what the engine thinks it *is* before suspecting
the event system — the same instinct as asking `location` about an element that receives no mouse events
(#11's neighbours in [`html-css-js.md`](./html-css-js.md)). For pointer events without a controller,
subscribe to `.MOUSE` and handle them yourself.

**The half that only bites in tests:** a behavior goes live when the element's style is **resolved**, not
when it is inserted. An element added by `set_html` reports its `control_type` immediately but answers
`do_click` with `handled = false` until the engine has run a pass — measured `false` before
`windowless_heartbeat` + `paint_windowless` and `true` after, on the same element. A windowed application
pumps continuously and never sees it. A test that renders rows and clicks one in the same breath sees it
every time, and the natural conclusion — "the CSS did not apply" — is wrong.

**And `do_click`'s event is delivered through the queue, not synchronously.** The behavior itself runs at
once (a checkbox is already ticked when the call returns) but the resulting `.BUTTON_CLICK` reaches
handlers later, so a handler-driven assertion needs a pump between the click and the check.
`examples/behavior.odin` calls `settle()` for exactly this; without it the model still holds its old value
and the test blames the handler.

Styling those controls is the other half of the subject, and it is authoring rather than host API:
[`html-css-js.md`](./html-css-js.md) has what the default cascade actually gives you — no `:hover` at all,
and painting a control silently deletes the `:active` flash it had.

---

## 13. A transform is ignored twice over, and the page just does not move

**Symptom:** a ported page whose sliding, centring or zooming does nothing. No error, no CSS warning, no
script exception; the DOM is right, the element is there, `getBoundingClientRect` reports exactly what it
reported before — and the pixels never move.

**Cause:** two independent silent rejections, both measured on 6.0.4.9 by reading the painted surface:

- **`translateX(200px)` is ignored; `translate(200px, 0)` paints.** A browser accepts both, so the
  single-axis form is what a ported stylesheet usually carries.
- **`element.style.transform = "…"` is ignored; `element.style.setProperty("transform", "…")` applies.**
  (`setAttribute("style", "transform: …")` does not apply either.) Assigning the property is the ordinary
  script idiom, so this is the second half of the same trap.

Get both right and the stylesheet's own `transition: transform` animates the move on the engine's frame
clock — no tween needed. Get either wrong and every element paints where layout left it.

**Why it survives a test suite:** a transform is paint-time. `getBoundingClientRect` in script and
`location` in the host report the UNTRANSFORMED rectangle, so a geometry assertion cannot tell a working
transform from an ignored one — it passes either way, or fails on a page that looks perfect. The
instrument that answers is `windowless_pixel`: colour a box, ask the surface where that colour is.

```odin
r, g, b, _ := sciter_app.windowless_pixel(&view, 220, 80) // 200px right of the box's layout position
```

**And a layout property does not animate to cover for it:** `transition: margin-left` reads back as an
empty computed `transition` and the element jumps in a frame or two. A fallback that moves something by
margin has to drive its own steps — `morphContent` or `requestAnimationFrame`, not `setInterval`.

The full measurement, the working pair, and the script-side animation APIs are in
[`html-css-js.md`](./html-css-js.md#animation-what-moves-and-the-two-ways-a-transform-is-silently-ignored).

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
