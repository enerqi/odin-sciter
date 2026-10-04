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

Get both right and the element moves. It still will not ANIMATE, which is the third half of this gotcha: a
`transition` animates a transform that changes through the cascade (a class) but not one set inline from
script — measured, the inline change arrives within two frames whatever the declared duration is. Script-
driven movement needs `element.morphContent(step, {duration, ease})`, the runtime's own frame-paced tween.

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

## 14. An inline `<style>` over 32 KiB is discarded ENTIRE, and says nothing

**Symptom:** a document with NO styling at all, from a sheet that worked yesterday — and the CSS diagnostics
that used to appear have gone quiet, which reads as "my last edit fixed the warnings" rather than "the parser
threw the sheet away". Adding a COMMENT can trigger it. On a page with a desktop override block at the bottom
it looks exactly as if that block alone had gone, which sends the search to the wrong end of the file.

**Cause:** one inline `<style>` element's contents are capped at 32,768 bytes. Re-bisected on 6.0.4.9 with
markers at the start, the middle and the end of one sheet: **32,741 bytes apply in full and 32,769 apply
NOTHING AT ALL** — its first rule dies with its last. This is not truncation at the cap, and the earlier
reading ("everything past the cut") was wrong: the parser abandons the whole block. No warning, no error,
no exception, and the CSS diagnostics for that sheet go quiet at the same moment.

**The scope is one `<style>` element.** Two blocks of 20 KB both apply, and a `<link>`ed sheet has no cap
in reach (100 KB measured, every rule live).

**Why it is so confusing:** the failure is not in the rule that stops working, and the diagnostics go silent
at the same moment, so the two obvious hypotheses — "my selector is wrong" and "the engine dislikes this
property" — are both wrong. The measurement that answers it is the byte count of the sheet, which nobody
thinks to take.

```odin
// The check that would have saved the afternoon.
assert(len(stylesheet) < 32 * 1024, "over Sciter's 32 KiB cap on one inline <style>; the WHOLE block goes")
```

**A SECOND SYMPTOM, AND IT DOES NOT LOOK LIKE CSS AT ALL** (2026-08-31, a desktop app whose own stylesheet
crossed the cap at 35,781 bytes): `behavior: button` is a CSS PROPERTY, so when the sheet goes, every
element that was clickable *because* of it stops attaching the behavior. List rows and palette entries then
answer `do_click` with `handled = false`, no `BUTTON_CLICK` reaches the host, and three unrelated tests fail
as though the event routing had broken. Nothing in that picture points at a stylesheet. If clicks stop
arriving from elements that get `behavior:` from CSS, **measure the sheet before debugging the events**.

**The fix that keeps the documentation:** strip CSS comments when the page is EMITTED rather than deleting
them from the template — a browser has no use for them either. One card-page template went from 33.3 KB to
18.4 KB that way. But comment-stripping only buys headroom and leaves the cliff one sentence away: emitting
the CSS as **several `<style>` blocks**, cut at top-level rule boundaries, removes it and keeps the page
single-file, which a `<link>` would not for a page that gets copied around or handed to a `<frame>`.

**Cut it automatically, not with a marker.** A hand-placed split marker plus a test saying "move the marker"
was tried and rejected: it fails just as late and still needs whoever trips it to understand the trap. A
~40-line cutter that walks the sheet and closes a block at a top-level rule boundary whenever the next rule
would exceed a budget (24 KiB leaves room) ends the question. Two rules make it safe, and both are load-
bearing: **skip block comments whole** — documented stylesheets quote `@set x { … }` and `@media` blocks in
prose, and a brace count alone will cut mid-sentence — and **track depth**, so a nested `@media` or `@set` is
never halved. A single rule bigger than the budget goes out whole; splitting it would be worse.

[`html-css-js.md`](./html-css-js.md#a-stylesheet-is-capped-at-32-kib-and-the-whole-block-is-dropped-in-silence) has
the table and the emit-time fix.

---

## 15. A width media query in someone else's page kills the process

**Symptom:** loading an ordinary responsive web page into a `<frame>` ends the process. No error return,
no CSS diagnostic, nothing in the log — and if it happens under a test runner, the runner *hangs* rather
than reporting (see #16).

**Cause:** a `@media` condition with a width feature. Bisected on 6.0.4.9: `(max-width: 699px)`,
`all and (max-width: 699px)` and `(min-width: 900px) and (max-width: 1045px)` each crash; bare
`@media all` and `@media screen` are fine and their rules apply. It is the feature, not the at-rule.

**Why it is confusing:** the page is not wrong. It works in every browser, and the responsive block is
usually nowhere near whatever was being changed when the crash started. The measurement that answers it is
loading the sheet one rule at a time, which nobody does to a page that "just needs displaying".

**The fix:** strip `@media` blocks whose condition mentions a width, brace-matched, before the document
reaches the engine. What is left is the base rule — the page's wide-window look.

[`html-css-js.md`](./html-css-js.md#a-media-query-with-a-width-feature-crashes-the-engine) has the cases.

---

## 16. A windowless probe cannot touch a loaded `<frame>`, and the runner hangs rather than fails

**Symptom:** a test that reaches into a framed document stops dead. Not a failure — no output, no exit; the
binary sits there until something kills it.

**Cause:** two calls that take the process down in a windowless view.

* `location` on a `<frame>` **element** once a document is loaded into it. An *empty* frame measures fine,
  which is the trap — the same call worked five lines earlier.
* Reaching into the frame's document **at all while the frame is displayed** — `element_asset(frame,
  "frame")`, its `document` property, then anything.

The hang is the second half: the Odin test runner's crash handler touches the engine from another thread
and trips [rule 1](./rules.md#1-thread-affinity-one-thread-and-one-way-across), so a crash becomes a
deadlock and the useful signal is lost.

**Why it is misleading:** a real window does neither of these things wrong. An application that focuses an
element inside a visible framed page, or evaluates script in it, works — so this is a property of the
windowless view and it limits the PROBE, not the application. Compare #11.

**What to do instead**, in the order to reach for it:

1. measure the frame **before** loading it — the box does not change when a document arrives;
2. load into a **hidden** frame and read it there (a hidden frame is 1x1, so everything inside measures 0);
3. for anything about the page's own layout, load the page as the **view's own document** — that measures
   the real question, a page of that shape in a viewport of that size.

Also measured: `eval_element` on a frame's document root works, but a computed style comes back as a
non-string value — wrap it, `String(getComputedStyle(el).backgroundColor)`.

---

## 17. A `disabled` button still does its job, and the test that "proves" otherwise proved nothing

**Symptom:** a UI path that is supposed to be closed opens anyway — and the test asserting that it is
closed passes.

**Cause:** three separate facts, each measured on 6.0.4.9, that stack into one wrong conclusion.

* **`do_click` runs a DISABLED button's behavior.** The activation happens and the click is delivered to
  an attached handler like any other. `disabled` is what the button LOOKS like, not what it refuses;
  see [`BEHAVIORS.md`](./BEHAVIORS.md#what-do_click-is-worth).
* **A presence-only `disabled` in the markup reads back as an EMPTY attribute value**, so
  `attribute(el, "disabled") != ""` is FALSE for a button that really is disabled — and it is equally
  false for one that has no such attribute at all. `element_state` and its `.DISABLED` bit is what the
  engine matches `:disabled` on, and it answers for the attribute and a host-set bit alike; see
  [`dom.md`](./dom.md#state).
* **A test that clicks anything needs the handler ATTACHED.** A test that builds a view, loads a
  document and never calls `attach_handler` / `attach_window_handler` delivers its clicks NOWHERE, so
  every assertion of the form "nothing happened" passes VACUOUSLY. That is what turned the first two
  facts into a confident, wrong "the engine honours `disabled`".

**Why it is confusing:** all three failures look like success. The button greys out, the click is
refused *on screen* by nothing at all, and the test is green.

**What to do:** enforce in the MODEL — a flag the handler checks — and let the attribute or the state bit
be the projection of it. If a click test confirms something surprising, check the attach before believing
it.

---

## 18. Odin's `fmt` eats CSS and script braces

Not the engine's fault, but it lands squarely on anyone generating a stylesheet or a script from Odin.
`fmt.aprintf` (and every other `fmt` procedure) reads `{…}` as a format directive, so a CSS rule or a JS
block passed through one comes out mangled or empty, with no error. Build markup with
`strings.Builder` / concatenation, and keep `fmt` for the values that go *into* it.

---

## 19. A scroll into a freshly loaded `<frame>` moves nothing, and every call reports success

**Symptom:** a host scrolls a framed page to an element right after loading it. Nothing moves. No error, no
warning, and `set_scroll_pos` returns `nil`. Try it again a moment later from a button and it works - so it
reads as "only the first time", or as the arithmetic being wrong.

**Cause:** `loadHtml` gives the frame its DOM synchronously - `select_all` finds the elements, which is what
makes this convincing - but **not its layout**. Until the sub-document is laid out it is not taller than its
view, and a scroll is clamped to `content - view`, i.e. to zero. `update_window` on the HOST window does not
flush it either. Every step succeeds and the position stays 0.

**Measured, on a 28,000px-tall document in a 800px view (windowless, as the view's own document):**

```
root: view 685x801    content 192x28433     <- the scroller
body: view 669x28418  content 176x28417     <- NOT a scroller: content - view is -1
```

So the document ROOT is what scrolls, and `body` - the element most hosts reach for - can never scroll,
because it is as tall as its content. Both `set_scroll_pos` on the root and `scroll_to_view` on a child move
it there, once layout exists.

**What to do:** treat the scroll as a REQUEST rather than a call.

1. compute the offset from boxes rather than line heights: `.Root` positions are what the viewport shows, so
   `target.y - scroller.y + info.pos.y` is the content-space offset (and `.Container` is the origin that
   ignores scrolling entirely);
2. **verify by re-reading `scroll_info`.** A scroll that did not move is indistinguishable from one that did,
   at the call site, and that is the whole of this gotcha;
3. if it did not move, try again shortly - a `set_timer` on the frame element is enough (a few 60ms
   attempts). `.TIMER` is delivered to handlers on the ELEMENT, so a window handler hears nothing;
4. and distinguish **nothing to scroll** from **not scrolled**: a page shorter than its view has no scroll
   range at all, and the target is already visible. Reporting that as a failure is how a retry loop starts
   crying wolf.

**A related one, same family:** matching an element in a rendered page by its TEXT fails as soon as the
markup is real - a heading holding an inline `<span>` or `<a>` does not read back as the string that
generated it. If the page carries ids derived from the source, compare those instead; `#1C--1D` is not a
valid CSS selector (an id may not start with a digit), so enumerate and compare the attribute.

---

## 20. Rebuilding a `<frame>`'s document from that frame's own handler hangs the window

**Symptom:** the application stops answering — the title bar says "not responding" — after an edit that a
timer was watching for. No crash, no log, nothing to attach to afterwards.

`.TIMER` never reaches a window handler, so a timer that paces work on a framed document has to be set on the
FRAME element and answered by a handler attached to it. That is fine until the work itself is
`loadHtml`/`loadFile` into that same frame: the engine is mid-dispatch into the element whose whole document
you are then replacing, and it does not come back.

The fix is not to render in the handler at all. Post it — `post_callback(window, code)` — and do the work in
`on_posted`, one turn of the pump later with nothing on the stack:

```odin
if te, ok := sciter_app.timer_event(event); ok && te.id == RENDER_TIMER {
	sciter_app.post_callback(app.window, RENDER)   // NOT the render itself
	return false                                   // one-shot; the next edit re-arms it
}
```

**A windowless view cannot test this.** A post goes to a WINDOW, and synthesising the timer event in a
windowless view segfaults on the post — which then hangs the test runner, since its crash handler touches the
engine from another thread. A program with a real window (the way `page_check` is a program rather than a
test) is the only harness that can drive it.

## 21. The caret is `text-selection-caret-color`, and on an empty line it is a block that stays behind

Two separate things, both invisible until the caret has a colour of its own.

**The property is not `caret-color`.** That is the browsers' spelling and this engine does not have it, so it
parses, matches, and leaves the engine's own black default in place — invisible on any dark field, which reads
as an editor that will not take the caret rather than as a missing colour. The engine's name is
`text-selection-caret-color` (SDK `docs/md/css/properties.md`, in the selection group beside
`text-selection-color` and `text-selection-background-color`). A property this engine does not know reads back
EMPTY through `style(el, name)`, which is how to tell the two spellings apart from a test.

The neighbouring two are worth leaving alone unless a design needs them: painting the selection background
makes a stale EMPTY selection visible as a bar sitting away from the caret.

**And a caret is only painted in a FOCUSED widget** — a view that shows a `<plaintext>` without focusing it
has no caret at all.

**On a line with no text the caret is drawn a whole CELL wide**, a block rather than a bar, and the block is
left on screen when the caret moves off that line. Measured: the widget's `selectionStart`/`selectionEnd` are
identical either side of it, moving the caret away does not clear it (only the caret's own region repaints),
and typing on that line does (the widget repaints that line). So it is stale paint, and the cure is to
invalidate:

```js
// ON THE WAY UP: the widget moves the caret while it HANDLES the key, so a keydown handler
// invalidates the old position and the ghost is laid down again immediately afterwards.
document.on("keyup", "#editor", function (event) {
  if (!CARET_KEYS[event.code]) return false;   // `code`, not `key` — see the keyboard note
  try { this.requestPaint(); } catch (x) {}
  return false;
});
```

## 22. `input`/`select` have a fixed `height: 1.4em`, and their text walks out of it under `zoom`

**Symptom:** at a high global zoom the text in every field sits low and is clipped by the bottom border, as
though the caret had grown taller than the box.

The engine's own sheet gives `input[type=text]` and `select` a fixed `height: 1.4em`. The box scales with
`zoom` correctly — it is the CAPTION inside that does not stay centred in it. Measured in painted pixels
(`paint_windowless` + `windowless_pixel`, scanning rows for ink) on a field whose text is centred at 100%:

| zoom | box | gap above the ink | gap below |
|---|---|---|---|
| 1.00 | 33px | 13 | 13 |
| 1.10 | 36px | 15 | 13 |
| 1.21 | 40px | 19 | 12 |
| 1.33 | 43px | 22 | 11 |

`height: auto` — the control sizing itself to its own content — holds it centred at every step (13/13, 14/15,
16/15, 17/17). Restore the height the fixed rule was giving with padding, or every row built around a 33px
field moves. The caption is INTERNAL to the control (`child_count` is 0, and a composite control's internals
take no author CSS), so nothing in the geometry API can see this: pixels are the only witness.

## 23. A width media query's FIRST rule still applies

Gotcha 15 has the half that kills the process. This is the half that changes the layout quietly.

`@media (max-width: 640px)` is a parse error here, and the parse error discards the rest of the stylesheet —
but the rules INSIDE the block are not all discarded with it. Measured on a page whose phone block opens with
`.opc, .shape { display: none; }`: those two elements computed to `display: none` in a 1200px desktop window,
while a browser showing the same page showed them.

So a page ported to this engine cannot rely on its phone block being skipped. Restate what the block hides,
above the query, at a specificity the phone rule cannot reach — order is not available, because the override
block has to come before the query that kills everything after it:

```css
@media sciter { .seat .opc, .seat .shape { display: block; } }   /* 0-2-0 beats the phone rule's 0-1-0 */
@media (max-width: 640px) { .opc, .shape { display: none; } ... }
```

A hidden element still measures **1×1 rather than 0×0**, so a check asking "does it have a box" passes
vacuously. Ask for a line of text's worth of height.

## 24. An inline box takes no margin, no padding and no background

**Symptom:** a line of small tags rendered from `<span class="tag">html</span><span class="tag">pbn</span>…`
comes out as one run-on word — `htmlpbnlinhvlinenumtext` — with no gaps, no pills and no background, though
the rule setting all three is right there and matches.

**Cause:** the spans are inline-level, and this engine's flow model gives an inline box no box of its own:
horizontal margins, padding and background are not painted for it. The rule is not ignored — the element has
nowhere to put it.

**Fix:** `display: inline-block` on anything that needs a box while sitting inside a line of text — tags,
pills, chips, badges, a coloured key inside a sentence.

```css
.tag {
	display: inline-block; /* without this, every other line here does nothing */
	margin-right: 0.3em;
	padding: 0 0.35em;
	border-radius: 3px;
	background: var(--line-soft);
}
```

**Related:** the same instinct catches a "why is my icon not spaced" question — an inline `<svg>` inside a
button takes vertical nudging (`margin-bottom`) but sits where the line box puts it.

---

## 25. A "selected" state has to be the accent, not a lighter grey

**Symptom:** a three-position segmented control, drawn with the selected segment on `--line` (#313244)
against the group's `--surface` (#181825) and its icon in `--accent`, reads in the real window as three
identical buttons. Reported as "cannot tell which is selected". The measurement said the rule applied; the
window said it did not communicate.

**Cause:** a few percent of luminance between two dark greys is not a state. It survives a screenshot in a
diff and dies on a real panel, at a real brightness, at arm's length — and an accent applied to a 15px ICON
is a few hundred coloured pixels, which is not where the eye looks first.

**Fix:** where the state is the ONLY information the control carries, make the ground carry it — the accent
as background with the label or icon knocked out of it. Keep the subtle version for things that also say
what they are in words.

**Why it belongs in an engine gotcha list:** because this engine paints no state feedback for a `<button>`
at all (see the interaction-states table in `html-css-js.md`), every `:hover`, `:active` and selected look is
author-written, so there is no platform default quietly making it legible for you.

---

## 26. `flow: horizontal` does not wrap, and a frameset pane keeps its old width until you click

Two separate ways a layout that is correct at one size is broken at another, both found by hosting a page in
a resizable PANE rather than a window.

**`display: flex; flex-wrap: wrap` has no one-property translation.** `flow: horizontal` is the row, and it
never wraps: a control bar with `width: max-content` is then as wide as its contents and everything past the
container edge is simply clipped — at a wide view there is room and nothing shows. The counterpart of
`flex-wrap: wrap` is **`flow: horizontal-flow`**, and it needs something to wrap against: with
`width: max-content` and no cap, the available width IS the content width, so add `max-width: 100%`. (The
border box then lands about a pixel past the cap; measured, and not worth chasing.)

**A frameset does not re-lay out when one of its panes is hidden.** `display: none` on a pane takes effect,
but the frame-set behavior recomputes the widths of the panes it is left with on its own schedule — the next
click is what tends to provide it, so the window sits with a blank strip until it is poked. Ask for it:

```odin
sciter_app.update_element(frameset, render = true) // style + layout + paint for that subtree
```

**Test-shape lesson from both:** a windowless check that only ever runs at one view size cannot see either.
Resize the view in the check (`resize_windowless`) and assert at the size the app actually hosts at.

---

## 27. A stroked `<svg>` shape loses its right and bottom edges under `zoom`

**Symptom:** small icons drawn as inline svg look right at 100% and degrade as the window is zoomed — a
rounded rectangle outline ends up as a rounded CORNER, "more like an r than a rectangle".

**Measured:** the icon markup painted inside an element with `zoom: 2.0`, pixels read back from a
windowless view — correct at 1:1, **top and left edges only** when zoomed. Unchanged by removing the
viewBox, by matching the viewBox 1:1 to the element size, by sizing the element in CSS rather than with
`width`/`height` attributes, and by `overflow: visible`. (Plain viewBox scaling is fine on its own: a mark
in the far corner of a `0 0 24 24` box lands correctly in a 40px element.)

**Fix:** for a shape a box can be — a rectangle, a bar, a square, a band — draw it with CSS instead. A
bordered element is drawn by the box painter and laid out by the same box model as the rest of the page, so
it scales with the document:

```css
.icon      { display: inline-block; width: 1.05em; height: 0.85em;
             border: 1px solid currentColor; border-radius: 2px; flow: horizontal; }
.icon > .fill { width: 1*; height: *; background: currentColor; }
```

`currentColor` works in both worlds, so the icon still inherits the control's `color` and every `:hover` /
`[disabled]` / selected rule recolours it for free. For a genuine diagonal, a text glyph (`↗`) is the
cheaper escape than keeping a vector.

**Caveat that decides how to test this:** the defect does NOT reproduce in a windowless view driven by the
same document — a test pointed at the broken icon passes. The difference to suspect is the rasterizer
(windowless is software; a real window is on a GPU backend by default). Force the software path to compare
if a drawing looks wrong in the window and right in a test.

---

## 28. A horizontal flow does not centre children of different heights

**Symptom:** a toolbar of mixed controls — a button, a checkbox, a small text label, an input — where every
item sits at its own level, and it gets worse as the window is zoomed.

**Cause:** `flow: horizontal` stacks children on the row without centring them, and a bare inline (a
`<label>`, a `<span>`) runs at its own text line rather than as a box that can be aligned at all.

**What works, measured on 6.0.4.9:**

```css
.bar        { flow: horizontal; }              /* `vertical-align: middle` here did NOTHING */
.bar .label { display: inline-block; vertical-align: middle; }   /* a bare inline needs a box */
.bar .group { flow: horizontal; vertical-align: middle; }        /* an inner flow DOES need it */
button.with-icon { flow: horizontal; vertical-align: middle; }   /* icon + word, laid out by the button */
```

The asymmetry is the point: the property did nothing on the outer container and was load-bearing on an
inner flow and on a button laying out its own content. Bisect rather than assume — and delete the rules that
turn out to do nothing, or the next person has to disprove them too.

**Test it across the ZOOM, not at rest.** At 100% a badly aligned row can measure fine; the drift appears
once paddings, borders and text round differently — measured here from 133% up, 3-4px.

---

## 29. Flex units are not a proportion: `N*` divides the space left AFTER content

**Symptom:** two panes given `width: 1487*` and `width: 835*` render as **28px and 2294px**. A layout that
works with light content collapses as soon as one pane holds something wide (here a framed page with a row
of fixed-width cards).

**Cause:** the SDK says it in one line (`docs/md/css/flows-and-flexes.md`): "Flex units distribute **free
space** left in a container **after** applying length units to content." A flex share is added on top of the
content's own width; it is not CSS-flexbox `flex-grow` with a zero basis. Wide content takes the room first
and the shares divide what is left. `min-width: 0` and `overflow: hidden` on the panes did not change it.

**What works:** give the pane whose size the user chose a LENGTH (`1487px`) and let one pane take the rest
(`1*`) — the sidebar-and-content shape. Clamp the length when rendering, because px is what `zoom` scales and
what a smaller window cannot hold.

**Test caveat:** a windowless check with a plain wide block in the frame honoured the shares exactly; only the
real page (which crashed the windowless test engine on load, not investigated) showed it. A real-window debug
log of the widths written and the widths that SETTLED found it — see #30's drag recipe.

---

## 30. For panes a user drags, a plain flow beats the frame-set behavior

`<frameset>` gives draggable `<splitter>`s and a `state` of pane widths for free. In an app with hidden panes,
a global `zoom` and a remembered layout, every one of these was measured, each found by fixing the last:

- `display: none` on a **`<splitter>`** breaks the frameset: every later `state` write throws
  (`TypeError: setting property 'state'`), so the dividers die. (A hidden **pane** is fine and drops out of
  `state`.)
- the behavior's own drag, under a root `zoom`, rewrites panes the drag is not about with on-screen pixels as
  CSS pixels — `250px` came back `303px` at 110% (250 × 1.1²).
- its numbers are content widths, so a pane's padding skews any measured-then-written width.
- in script, the widths are **`element.frameset.state`** (the behavior's object, as the host's `frameset`
  asset). `element.state` is the generic ElementState and assigning to it silently does nothing.

**What replaced it** — a `div` with `flow: horizontal`, ordinary `.divider` elements, inline `width`s,
`box-sizing: border-box` (so a number is the whole pane), and a script drag:

```js
document.on("mousedown", ".split > .divider", (evt, divider) => { /* note widths, screenX, wbZoom() */
  divider.state.capture(true);
  divider.parentElement.classList.add("dragging");  // CSS: .split.dragging frame { pointer-events: none; }
  return true; });
document.on("mousemove", evt => { if (!drag) return;
  if (typeof evt.buttons === "number" && !(evt.buttons & 1)) return endDrag();   // a release we never heard
  /* write ONLY the two panes beside the divider, in CSS px = on-screen / zoom; the last pane `1*` */ });
document.on("mouseup", evt => { if (drag) { endDrag(); return true; } });
// endDrag: release capture, remove .dragging, then el.postEvent(new Event("dragged", {bubbles: true}))
```

Lessons in that shape: listen for moves and the release **anywhere** (a release off the 5px divider left a
drag live, and the next buttonless pass over it jumped the panes); shield frames (`pointer-events: none`) or
the framed document takes the moves; on release **read the inline widths you wrote, never measure** — layout
lags the mouse (~124ms a step with a heavy framed page) and a measurement reads where the panes WERE. The
script's `postEvent` reaches the host as a `.CUSTOM` behavior event; `event_name(be)` gives the name. Hide a
divider beside a hidden pane with plain `display: none` (fine on an ordinary element), and once the panes are a
plain flow the container needs `overflow: hidden` and the tall pane its own scroll, or a pane's content makes
the whole view taller than the window — the frameset had clipped for free.

---

## 31. The root's `zoom` reaches framed documents, and a frame's own root `zoom` replaces it

**Measured:** with `zoom: 1.5` on the outer root, a heading in a `<frame>` grew 39px → 58px, and the framed
document's root reads back the outer factor. Setting `zoom` on the FRAMED root does not multiply — `1` there
gives the unzoomed 39px under a 150% window, `0.8` gives 31px. So a frame can have its own ABSOLUTE scale,
but it must be re-applied after every outer zoom change and after every load (both reset it). A CTRL+wheel
over a frame goes to the framed document, so give that document its own wheel handler from the outer script.

---

## 32. A theme switch by CSS variables needs a restyle, and a hidden subtree misses it

Tokens on `:root` and an override block under `html[theme="light"]` work, and setting the attribute
recolours the ROOT at once — but descendants keep the values they resolved before (a button stayed
`#CDD6F4` after its `--ink` had become `#4C4F69`) until `update_element(root, render = true)`. And that
restyle does **not** reach a `display: none` subtree: a view hidden at the moment of the switch kept the old
theme when shown again. Mark hidden views stale and restyle on their next showing.

---

## 33. `loadFile` into a frame returns before the document exists; `loadHtml` does not

Anything applied to the framed document right after the call — a zoom, a scroll, a focus — lands on the
OLD document after `loadFile`, while the same code works after `loadHtml` (synchronous). Re-apply such
per-document state on `.DOCUMENT_COMPLETE`, which reaches only a handler attached to the `<frame>` element
itself (subscribe `.BEHAVIOR_EVENT`), not a window handler. A test that only loads from memory passes on this.

---

## 34. A `display: none` element can still report its old box

`element.state.box("width")` on a pane hidden with `display: none` can return the width it had when shown.
Counting it as a live pane wrote three widths to a frameset showing two. Decide "hidden" by the inline
`display` your own code wrote (or by the computed style host-side), and fall back to a zero box only for an
element that has never been shown.

---

## Where the knowledge actually lives

- **`external/sciter/include/*.h`** — the C ABI. Comments are the only C-API documentation there is, and
  they are wrong in at least one place (see #2).
- **the SDK's `include/*.hpp`** — deliberately not vendored here, and worth reading anyway.
  `sciter-x-window.hpp` is the authority on both the start-up and the teardown sequence.
- **the SDK's `demos/`, `samples.*`** — `demos/sciter-mfc` shows the intended
  `SCITER_APP_INIT` → … → `SCITER_APP_SHUTDOWN` lifecycle. ~480 sample documents besides, mapped by question
  in [`SDK-DOCS-AND-SAMPLES.md`](./SDK-DOCS-AND-SAMPLES.md).
- **`include/sciter-x-key-codes.h`** — the engine's own key codes (GLFW-style, `KB_RIGHT = 262`), which no
  page documents. Nothing in the SDK includes the header either, so it is bound here by hand as
  `sciter.Sc_Kb_Codes` (in `src/prelude.odin`) rather than generated. **The engine translates platform
  keys into this set**: a Windows `VK_RETURN` (13) arrives as `.ENTER` (257) in `Key_Event.key_code`, so a
  handler comparing against platform virtual keys never fires. `windowless_key` does NOT translate — the
  host has to send from this set.
- **[docs.sciter.com](https://docs.sciter.com/docs/intro)** — a Docusaurus render of
  `sciter-js-sdk/docs/md`, which you already have in an SDK checkout. Script-side only: DOM, CSS, JS,
  behaviours. Nothing about the host API — but 128 pages of it, and
  [`SDK-DOCS-AND-SAMPLES.md`](./SDK-DOCS-AND-SAMPLES.md) says which ones settle what.
- **[sciter.com/forums](https://sciter.com/forums/)** — where host lifecycle knowledge is written down
  and nowhere else. "Close all windows and free all resources before exiting" is a 2019 forum post.
- **the GitLab wiki** — empty. Do not bother.
