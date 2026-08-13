# Parity with the SDK's own samples and docs

How this repository's examples, tests and documentation line up against everything upstream ships, so
that "do we understand the common ways to use Sciter?" has an answer with a shape rather than a feeling.

Both trees are at the same pin, so this is a fair comparison: the vendored engine is `6.0.4.9-bis`
(`external/sciter/VENDORED.md`) and the SDK checkout surveyed here is
`gitlab.com/sciter-engine/sciter-js-sdk` at tag `6.0.4.9-bis`, commit `5611857`.

**Method**, per [`RESEARCH-METHOD.md`](./RESEARCH-METHOD.md): every count below came from the local
checkout, not from the SDK's README. Sample directories were counted with `find`, host code was located
by looking for `.c`/`.cpp`/`.h` files rather than by reading descriptions, and every claim about what
"has no host API" was checked by grepping `sciter-x-api.h` for the symbol, not inferred from the absence
of an example.

---

## The finding that reframes the question

**"Parity with the SDK" is two different questions, and only one of them is about bindings.**

The SDK's sample mass is overwhelmingly script-side — HTML, CSS and JS that runs under `usciter` or
`scapp` with no host code anywhere:

| Area | Entries | C/C++ files |
| --- | --- | --- |
| `samples.sciter` | 64 | **0** |
| `samples.css` | 20 | 0 |
| `samples` | 20 | 0 |
| `samples.reactor` | 11 | 0 |
| `samples.charts`, `.md`, `.yaml`, `.barcode`, `.webgl`, `.gpu`, `.storage`, `.sys` | 15 | 0 |

Host code — the only thing an Odin binding can have parity *with* — lives in exactly seven places:

| | C/C++ files |
| --- | --- |
| `demos` (9 projects) | 49 |
| `demos.lite` (3 projects) | 1245, almost all of it a vendored copy of SDL |
| `sciter-webview` | 15 |
| `demos.d2d` | 11 |
| `sciter-sqlite` | 9 |
| `samples.c` | 5 |
| `sciter+` | 4 |

So the 64 directories in `samples.sciter` are not a binding gap. They are a *Sciter* cookbook, and a
large part of what they demonstrate is unreachable from the host by design — see
[Capabilities with no host API](#capabilities-with-no-host-api-at-all).

## C-API coverage

The other parity question, and the one with a countable answer: of the function-table slots the SDK's
headers declare, how many does `package sciter_app` reach?

Measured by [`.github/scripts/parity.sh`](../.github/scripts/parity.sh) — `just parity` — which strips
comments and `#if 0` blocks before matching (two declarations in the headers are disabled upstream and
would otherwise read as permanent gaps), and matches usage as `.Name` rather than `.Name(` because the
wrappers often store or forward a slot rather than calling it on the spot.

| table | header | live slots | reached | not reached |
| --- | --- | ---: | ---: | ---: |
| main | `sciter-x-api.h` | 176 | **163** | 13 |
| graphics | `sciter-x-graphics.h` | 72 | **70** | 2 |
| request | `sciter-x-request.h` | 29 | **29** | 0 |

**Every slot that is live, implemented and reachable is wrapped.** The fifteen that are not are listed
below with a reason each, and the list is committed as
[`parity-baseline.txt`](./parity-baseline.txt): `just parity --check` diffs against it and CI runs that,
so a slot added by a future SDK shows up as a one-line diff during the upgrade rather than as a user
asking for something that quietly does not exist.

### Declared but disabled upstream

Not gaps, and not counted above. Both match a naive `grep` for `SCFN(` and neither is a real slot:

| slot | header | why it does not exist |
| --- | --- | --- |
| `imageGetPixels` | `sciter-x-graphics.h:146-148` | inside a `//` comment block. Direct pixel access is a real thing to want; `save_image(.RAW)` is the readback path here |
| `Request` | `sciter-x-request.h:186-189` | inside `#if 0` |

### Not wrapped, with reasons

| slot(s) | category | why not |
| --- | --- | --- |
| `SciterSelectElements`, `SciterSelectParent` | superseded | the wide variants are wrapped instead, as `select_all` and `select_parent` |
| `SciterGetElementTypeCB` | superseded | `SciterGetElementType` is wrapped as `tag` |
| `SciterProc`, `SciterProcND`, `SciterClassName` | platform | Win32 window-proc and window-class plumbing. This design has no `foreign import` of the Win32 window machinery: windows come from `SciterCreateWindow` and messages from the engine's own pump |
| `SciterAttachHwndToElement`, `SciterGetElementHwnd` | **deliberate, see below** | native child windows |
| `SciterEGLGetProcAddress`, `SciterEGLSendEvent` | **deliberate, see below** | windowless EGL |
| `SciterGetViewExpando` | dead slot | NULL on every platform on Sciter 6 — a leftover of the removed TIScript VM. `window.odin`, [`ENGINE.md`](./ENGINE.md) |
| `SciterGetObject`, `SciterGetElementNamespace` | dead slot | answer `.OPERATION_FAILED` for every element tried; same VM leftovers. [`api.md`](./api.md), [`dom.md`](./dom.md) |
| `gCreate` | not supported by the engine | answers `.NOTSUPPORTED`; `paint_image` is the offscreen path. `graphics.odin` |
| `gGetNativeDC` | raw on purpose | platform handle passthrough; `graphics_api()` exposes the table for it |

### The two native-integration decisions

These are the only four live, implemented slots left unwrapped, so "out of scope" and "nobody got to it"
need telling apart:

**Native child windows** (`SciterAttachHwndToElement`, `SciterGetElementHwnd`) — **deferred, not
refused.** Both slots take an `HWND`, and the parameter is a Win32 window handle whose X11 meaning this
binding has not established. [`native_child.odin`](../examples/native_child.odin) takes the other route:
it owns an X11 child window itself and positions it over the element's rectangle, which works today on
the platform the repository is tested on. Wrapping the pair is the right move once there is a Windows
box in the loop — see [`WINDOWS-CHECKLIST.md`](./WINDOWS-CHECKLIST.md).

**Windowless EGL** (`SciterEGLGetProcAddress`, `SciterEGLSendEvent`) — **deferred pending hardware.**
[`windowless_gl.odin`](../examples/windowless_gl.odin) drives the windowless path through
`SciterProcX` with `SL_TARGET_OPENGL`, which is the documented route and the one that renders on the
software stack available here. The EGL pair is for handing the engine an EGL context the host already
owns; testing that needs a GPU this repository does not currently run on, and shipping an untestable
wrapper is worse than not shipping one.

## Host-side parity

The comparison that decides whether the bindings are complete.

| SDK artifact | What it is | Ours | Verdict |
| --- | --- | --- | --- |
| `demos/usciter` | The universal "browser" host — window, resources, inspector | [`hello_window`](../examples/hello_window.odin), [`load_file`](../examples/load_file.odin), [`inspector`](../examples/inspector.odin) | **Covered** |
| `demos/tsciter` | Minimal host: one `main.cpp`, one `index.htm` | `hello_window` | **Covered** |
| `demos/gsciter` | Same again, cross-platform sources | same | **Covered** |
| `demos/inspector` | Source of the inspector tool itself | `inspector.odin` attaches to the shipped tool | Covered for our purpose; we do not reimplement the tool |
| `demos/sciter-component` | A DLL component with `exports.def` | [`extension.odin`](../examples/extension.odin) | **Adjacent** — ours is `SciterLibraryInit` + `sciter.loadLibrary`, which is the mechanism the SDK documents for `scapp`/Quark |
| `demos.lite/lite-bitmap`, `lite-sdl`, `lite-sciter` | Windowless rendering into a bitmap or an SDL surface | [`windowless`](../examples/windowless.odin), [`windowless_gl`](../examples/windowless_gl.odin), [`spike/windowless`](../spike/windowless/main.odin), [`EMBEDDING.md`](./EMBEDDING.md) | **Covered** — `SL_TARGET_BITMAP` and `SL_TARGET_OPENGL` both render; `SL_TARGET_OPENGLES` is refused by this build, and one engine defect stands (`SXM_RESOLUTION`) |
| `demos/integration` | A Sciter view inside an existing native window | [`integration.odin`](../examples/integration.odin) | **Covered** — an X11 window this repository owns and draws, with the pane composited in and its input translated |
| `samples.c` | C modules against `jsbridge.h`, `import`ed from script | — | **Gap, and not buildable here**: `jsbridge.h` is absent from the entire checkout |
| `sciter-sqlite` | A native extension exposing a C library to script | [`sqlite_extension.odin`](../examples/sqlite_extension.odin) | **Covered** — the same three SOM classes over the system `libsqlite3`, loaded with `dynlib` |
| `sciter-webview` | A native behavior embedding the OS webview as an element | [`native_child.odin`](../examples/native_child.odin) | **Mechanism covered, browser not** — a native window inside a Sciter layout works; upstream's own Linux backend cannot reparent either. See stage 5 |
| `demos/window-mixin`, `windows-directx`, `sciter-mfc`, `demos.d2d` | Win32 / MFC / Direct2D / DirectX hosts | — | **N/A on Linux**; revisit with [`WINDOWS-CHECKLIST.md`](./WINDOWS-CHECKLIST.md) |

### What we have that upstream does not

Not parity in our favour so much as evidence that the host surface here is not a subset:

`request_loader`, `custom_loader`, `archive`, `single_binary`, `worker_thread`, `drag_and_drop`,
`named_behavior`, `workbench`, `api_map`, and host-driven `video`. None has a C/C++ counterpart in the
SDK.

Upstream ships a *script-side* test sample (`samples.sciter/unit-test`) and **no host-side tests**: the
only C test sources in the whole checkout belong to the copy of SDL vendored inside `demos.lite`. This
repository carries **362 `@(test)` assertions across 24 files** (`grep -c '@(test)'`), plus
`just example-tests`.

**Read: on the cross-platform host API, this repository is at or ahead of the SDK's own C/C++ samples.**

## Capabilities with no host API at all

The most useful result of the sweep, and the thing that stops a naive port of `samples.sciter`. Each row
was checked by grepping `external/sciter/include/sciter-x-api.h` for the term:

| Capability | Occurrences in `sciter-x-api.h` | Reachable from Odin how |
| --- | --- | --- |
| Clipboard | 0 | script only — `Clipboard` global |
| Printing | 0 | **partly bound after all** — `behavior:pager`'s SOM asset is host-callable, and `loadHtml` + `savePDF` produced a real PDF from Odin with no script. `Window.print` does not exist. See [`BEHAVIORS.md`](./BEHAVIORS.md) |
| Tray icon | 0 | script only |
| File open/save dialogs | 0 | script only — `Window.this.selectFile` |
| Audio | 0 | script only — `@sys` / `Audio` |
| Menus | 0 | script only — `behavior:menu`, plus `SciterShowPopup` for placement |
| Gestures | 0 | script only |
| Zip | 0 | script only — `@sciter` `Zip`. Distinct from `SciterOpenArchive`, which we do bind |
| **Storage** | 0, and **zero in every header** | script only — the `@storage` NoSQL module |
| Popups | 6 (`SciterShowPopup`, `SciterShowPopupAt`, `SciterHidePopup`) | **bound**, wrapped as `show_popup` / `show_popup_at`, used in `dom_walk` |
| Archive | 3 | **bound** — `archive.odin`, `single_binary.odin` |

So for **45 of the 64** `samples.sciter` directories — the bucket enumerated
[below](#script-only--no-host-api-exists) — "parity" cannot mean "bind it". It means *drive the script
that does it* — which is what [`script_bridge.odin`](../examples/script_bridge.odin) is,
[`eval.odin`](../examples/eval.odin) and [`call_odin_from_js.odin`](../examples/call_odin_from_js.odin)
are the mechanics of, and what
[`calling-between-odin-and-js.md`](./calling-between-odin-and-js.md#capabilities-that-only-script-can-reach)
tabulates capability by capability.

That is a real architectural fact about Sciter and it belongs in a decision about this repository's
scope: **the host API is a document and rendering API, not an application-services API.**

## The `samples.sciter` sweep

All 64, bucketed. Imports and API use were extracted per directory with `grep -rhoE 'from "@[a-z]+"'`
and a pattern over `Window.*`, `behavior:*`, `Graphics` and `.paint*`.

### Demonstrated here already

| SDK sample | Ours |
| --- | --- |
| `native-behaviors` | [`named_behavior.odin`](../examples/named_behavior.odin), [`behavior.odin`](../examples/behavior.odin) |
| `native-access` | [`extension.odin`](../examples/extension.odin), [`call_odin_from_js.odin`](../examples/call_odin_from_js.odin) |
| `graphics`, `immediate-mode-painting`, `image-generation-painting`, `effects` | [`graphics.odin`](../examples/graphics.odin), [`graphics_gallery.odin`](../examples/graphics_gallery.odin) |
| `drag-n-drop`, `drag-n-drop-system` | [`drag_and_drop.odin`](../examples/drag_and_drop.odin) |
| `video` | [`video.odin`](../examples/video.odin) — and see the libVLC caveat in [`ENGINE.md`](./ENGINE.md) |
| `virtual-list` | [`workbench.odin`](../examples/workbench.odin), which virtualises by hand rather than using `behavior:virtual-list` |
| `unit-test` | our `@(test)` assertions — a different mechanism for the same purpose |
| `input-elements` and the 39 `docs/md/behaviors` pages | [`BEHAVIORS.md`](./BEHAVIORS.md) — the host-side map of every intrinsic behavior, with tests in `behavior.odin` |
| `input-elements`, `@inputs` (partly) | [`input.odin`](../examples/input.odin), `behavior.odin` |
| `window` (partly) | `hello_window`, plus `sciter_app/window.odin` |

### Script-only — no host API exists

`clipboard`, `printing`, `tray-icon`, `load-save-dialogs`, `audio`, `menu`, `gestures`, `terminal`,
`i18n`, `i18n-reactor`, `lottie`, `toast-notification`, `splash`, `msgbox+dialog`, `lightbox-dialog`,
`docking`, `resizable`, `tooltips++`, `themes`, `tables`, `forms`, `code-beautifier`, `code-linting`,
`colorizer`, `editor-htmlarea`, `editor-plaintext`, `aspects`, `components`, `observable`, `js++`,
`js-module-resolver`, `runtime`, `svg-icons`, `images`, `frame`, `frameset`, `frame-host`,
`desktop-dom-elements`, `ideas`, `extras`, `@sciter`, `@sys`, `applications.quark`, `zip`, `process`.

Reachable only by loading the document and letting it run, or by `eval`. Porting them to Odin is not
possible and not desirable; **reading them is still how you learn what Sciter documents are supposed to
look like.**

### Worth trying from the host — **tried, 2026-08-13**

All three answered, and all three work:

- **`popup`** — a context menu driven entirely from Odin. On a *shown* window `show_popup(menu, anchor,
  .Bottom)` gives the menu `:popup` and the anchor `:owns-popup`, the menu gets a real box (81 × 71
  here) and `element_at` on its centre hit-tests to the `<li>` inside it; `hide_popup` clears both
  states, and `show_popup_at` places it at a point instead. (The half-working case is a window that has
  never been shown — already a known issue in `CHANGELOG.md`.)
- **`global-events`** — **the two do meet in the middle.** `fire_event` with a `.CUSTOM` code and a
  name reaches script's own handlers: an element's `.on("odin-says")`, then `document.on`, then
  `Window.this.on`, in that order, carrying the payload as `e.data`. Posting rather than sending
  delivers the same three on a later turn of the pump. So a host can raise an application event and the
  document hears it with no glue on either side.
- **`frame-host`** — a host can own a sub-document. `frame.loadHtml` through the frame behavior's asset
  loads it, `frame.url` reads it back, and **`frame.document` unwraps to a real `Element`** with
  `element_from_value` — from which `select_first` and `set_text` work normally inside the framed
  document. What does *not* happen is selectors crossing the boundary: `select_first("#inner")` from
  the outer document's root is `.Not_Found`, which is the correct isolation and the thing to know.

## The `docs/md` sweep

128 markdown files, which is the reference this repository's guides are effectively a translation of.

| SDK area | Files | Our counterpart | State |
| --- | --- | --- | --- |
| `behaviors` | 40 | [`BEHAVIORS.md`](./BEHAVIORS.md), [`html-css-js.md`](./html-css-js.md), `behavior.odin`, `named_behavior.odin` | **Swept, 2026-08-12.** All 39 documented behaviors measured from Odin: what each one's `control_type` is, which 18 publish a callable native interface, every property with whether it is writable, every method with its required arity |
| `DOM` | 19 | [`dom.md`](./dom.md), [`api.md`](./api.md) | Good |
| `css` | 15 | `html-css-js.md` | Good on the layout story (`flow:`, flex units, no grid); thinner on `style-sets`, `image-map`, `marker-and-shadow`, vector `path:` images |
| `JS.runtime` | 15 | [`JS-RUNTIME.md`](./JS-RUNTIME.md), [`calling-between-odin-and-js.md`](./calling-between-odin-and-js.md) | **Covered, 2026-08-12** — every module and global enumerated from the live runtime, each with the host-side counterpart to prefer, plus the list of things that are not there at all |
| `reactor` | 12 | [`reactor.md`](./reactor.md) | Good |
| `graphics` | 9 | [`graphics.md`](./graphics.md), `graphics_gallery.odin` | Good — the gallery covers `Brush`, `Path`, `Image`, `Text` |
| `HTML` | 5 | `html-css-js.md` | Good |
| `storage` | 4 | — | **Uncovered, and correctly so** — no host API exists |
| `JS` | 5 | `calling-between-odin-and-js.md` | Partial |
| `scapp` | 2 | [`deployment.md`](./deployment.md), `extension.odin` | Good |

## Gaps, ranked by what they would actually tell us

1. ~~**The 40 intrinsic behaviors.**~~ **Closed** by [`BEHAVIORS.md`](./BEHAVIORS.md). The door turned
   out not to be `SciterCallBehaviorMethod` — whose method ids are a fixed set — but the SOM asset each
   behavior publishes. Stage 1 below records what the probe found.
2. ~~**Embedding into an existing native window**~~ (`demos/integration`). **Closed** by
   [`integration.odin`](../examples/integration.odin) — and it was the area that produced the most, as
   this kind of work usually is: one real engine defect (`SXM_RESOLUTION`), one build limitation
   (`SL_TARGET_OPENGLES`), and *three retractions* of findings this repository had written up against
   the engine and which turned out to be its own CSS.
3. ~~**GPU windowless targets**~~ — `SL_TARGET_OPENGL` is done
   ([`windowless_gl.odin`](../examples/windowless_gl.odin)); `SL_TARGET_OPENGLES` is refused by this
   build and the DX variants need the Windows machine.
4. ~~**`JS.runtime`**~~ — **Closed** by [`JS-RUNTIME.md`](./JS-RUNTIME.md): every module and global
   enumerated from the live runtime, with the host-side counterpart to prefer for each.
5. **C modules via `jsbridge.h`** — blocked: the header is not in the checkout. The only item on this
   list still open, and it is not openable from here.

## A plan to close them

**Status: stages 1–4 done, stage 5 all but its blocked item (2026-08-13).** This is written so the work can be picked up
cold rather than re-derived. Every stage is independently useful and independently
abandonable, which is the same shape [`VDOM.md`](./VDOM.md#if-it-is-built-build-it-in-this-order) uses
and for the same reason: the value is front-loaded, so stopping after stage 1 is a good outcome.

Two rules carried from [`RESEARCH-METHOD.md`](./RESEARCH-METHOD.md) apply throughout, because this whole
area is exactly where they were learned: **probe before documenting**, and **a headers claim is a
hypothesis**. Every stage below therefore opens with a cheap measurement whose result is allowed to
cancel the rest of the stage.

### Stage 1 — the intrinsic behaviors sweep — **done**, [`BEHAVIORS.md`](./BEHAVIORS.md)

The largest gap and the one that produces the cookbook. `docs/md/behaviors` documents 39; this
repository exercised roughly four.

**Opened with a probe, not a plan.** `behavior.odin` proved `SciterCallBehaviorMethod` reaches
`behavior:button` via `do_click`. It did **not** establish that other intrinsic behaviors expose
anything callable.

**Probe result: they do, through a door the plan did not name.** `SciterCallBehaviorMethod`'s method
ids are a fixed set and only `DO_CLICK` is implemented by any intrinsic behavior — so on *that* door
the pessimistic branch was right. But **18 of the 39 behaviors publish a SOM asset**, with real
properties and callable methods behind `element_asset` + `asset_get` / `asset_set` / `asset_call`:
`edit`, `masked-edit`, `textarea`, `plaintext`, `htmlarea`, `select`, `select-dropdown`, `calendar`,
`slider`, `scrollbar`, `form`, `frame`, `frame-set`, `history`, `pager`, `virtual-list`, `lottie`,
`terminal` (plus `video`, unmeasurable without libVLC). So the stage became the systematic sweep and a
real capability table, which is [`BEHAVIORS.md`](./BEHAVIORS.md): every behavior, its element, its
`control_type`, its interface name, every property with whether it is writable, and every method with
its required argument count.

The probe also found a defect in this repository, which is the reason it was worth running as code
rather than reasoning: **the engine's SOM thunks ignore `argc`**, so calling a passport method with
fewer arguments than it declares segfaults inside the engine. `asset_call` now refuses with
`.Wrong_Arity`, `asset_method_arity` exposes the count, and `behavior.odin` carries the tests.

Not done, and deliberately: the tour example. The scope control this stage was written with — *the
sweep is the deliverable and the example is the illustration; if it runs long, cut the example and keep
the table* — applied. The table plus four tests in `behavior.odin` carry what the example would have
shown.

### Stage 2 — finish the windowless story — **done**, [`integration.odin`](../examples/integration.odin)

[`EMBEDDING.md`](./EMBEDDING.md) renders, scripts, takes a mouse and a key, and runs on the GPU. Two
pieces are left, and the third is struck out because it is done:

1. **Report the defects upstream.** **Written up and ready to file** —
   [`UPSTREAM-DEFECTS.md`](./UPSTREAM-DEFECTS.md) carries ten of them, each with a reproduction and,
   where the backtrace was captured, the function that faults. Nothing has been *filed*: this
   repository has no account on that tracker, so the last step belongs to somebody who does. The engine
   is not forkable, so upstream is the only route — see
   [`ALTERNATIVES.md`](./ALTERNATIVES.md#vendor-risk-and-bus-factor) for why that asymmetry matters.
2. ~~**A GPU target.**~~ Done — [`windowless_gl.odin`](../examples/windowless_gl.odin) renders through
   `SL_TARGET_OPENGL` into a framebuffer the host owns.
3. ~~**A real example, not a spike.**~~ Done — [`integration.odin`](../examples/integration.odin): a
   Sciter pane composited into a frame this repository draws, in a window it owns, driven by its own
   X11 event loop. About a hundred lines of raw Xlib, no toolkit. It is the `demos/integration`
   equivalent and the evidence for what
   [`ALTERNATIVES.md`](./ALTERNATIVES.md#the-other-direction-sciter-inside-an-immediate-mode-app)
   claims.

**The probe cancelled the stage's own premise, which is why it was worth running.** The plan said to
hold this piece until the input defect was answered, because "a pane that cannot be clicked is a demo
with a hole in it". There is no hole: the intrinsic behaviors *do* act on windowless mouse input — a
click presses a button, toggles a checkbox and focuses an editor. The two measurements that said
otherwise had their widgets at `position: absolute`, which collapses an inline-level `<button>` or
`<input>` to 1×1 in this engine. That retraction, the second of its kind from the same cause, is in
[`html-css-js.md`](./html-css-js.md#absolutely-positioned-elements-collapse--two-separate-rules-both-measured),
and `dom_walk.odin` now pins both collapse rules so it cannot happen a fourth time.

The one real rule left is smaller and was hiding underneath: **a behavior's event is posted**, so it
arrives on the next `windowless_heartbeat` rather than inside the call that caused it.

### Stage 3 — the script-bridge pattern for host-less capabilities — **done**, [`script_bridge.odin`](../examples/script_bridge.odin)

Clipboard, printing, file dialogs, tray icon, menus, audio, gestures, zip, storage — nine capabilities,
zero API slots, per [the table above](#capabilities-with-no-host-api-at-all).

The mistake to avoid is writing nine examples. They would all be the same example. The deliverable is
**one** — the round trip of "Odin asks the document to do a thing that only script can do, and gets the
result back" — plus a table in
[`calling-between-odin-and-js.md`](./calling-between-odin-and-js.md) mapping each capability to the
script call that performs it.

Done as written: **one** example, and the capability chosen was clipboard round-tripping non-text —
the save dialog is modal and cannot be tested without a human. It earned its place. JSON survives a
round trip exactly; **HTML does not**, coming back wrapped in
`<html><!--StartFragment-->…<!--EndFragment--></html>` **with a trailing NUL inside the string** — and
the NUL is on the *text* flavour too, so a host comparing what it wrote with what it read fails for a
reason it cannot see in a log.

Two findings the probe added to the plan's picture:

- **`eval` cannot import a module.** `eval("await import(\"@sys\")")` fails to *parse*, so `@sys`,
  `@env`, `@sciter` and `@storage` are unreachable from `eval` at any privilege level. A
  `<script type="module">` that hangs them on `globalThis` is the bridge, and it is part 1 of the
  pattern in the example.
- **The permission gate is much narrower than expected.** With no `set_script_features` at all,
  `Clipboard`, `Zip`, `Audio`, `BJSON`, `fetch`, `Intl`, `URL`, `@env`, `@sciter`, `@markdown`,
  `@yaml`, `@debug` and `@storage` all work. Only `@sys` is gated, and it fails by exporting nothing
  but `Error` rather than by refusing.

### Stage 4 — a `JS.runtime` reference — **done**, [`JS-RUNTIME.md`](./JS-RUNTIME.md)

Documentation only, no code, no engine risk. Fifteen modules — `Asset`, `Audio`, `BJSON`, `Clipboard`,
`Fetch`, `Intl`, `URL`, `Zip`, `@env`, `@sys`, `@markdown`, `@yaml`, `@debug` — none bindable, all used
by real applications, none covered here.

Written for a host author rather than a script author: what exists, what it is for, and which of them
have a host-side counterpart that should be preferred (`Fetch` versus the request API, `Zip` versus
`SciterOpenArchive`, `@sys` versus doing it in Odin). That last column is the part that does not exist
anywhere upstream and is the reason to write it at all.

Written from the live objects rather than from upstream's pages — `Object.keys` on every module,
`typeof` on every global — which turned up a short list of things that are *not* there and read as
missing features: `performance` is undefined, `@fs` is not a module (the file API is `@sys.fs`),
`Storage` and `env` are modules rather than globals, and `Window.this.print` does not exist because
printing is `behavior:pager`.

### Stage 5 — the long tail — **two of three done (2026-08-13)**

- **A `sciter-webview` equivalent** — **the embedding half is done and the browser half is not portable
  here.** [`native_child.odin`](../examples/native_child.odin) puts a native window *inside* a Sciter
  window, tracking an element's box, and it rests on a measurement that is not in any header:
  **`HWINDOW` is an X11 window id on Linux**, not an opaque handle — `XGetWindowAttributes` on it
  succeeds, a child created with it as parent maps, and the engine's own repaints leave the child
  alone. That is the whole mechanism `sciter-webview` needs.

  What is missing is WebKit, and the reason is upstream's: its own GTK backend
  (`sciter-webview/webview/sciter_webkitgtk.cpp`) implements `set_parent_window()` as
  `{ return false; }` and opens a *detached* top-level window on Linux, so even the SDK's binding does
  not embed a browser in a Sciter layout there. A GTK webview also wants its own main loop. On Windows
  and macOS the same file would hand the window handle to WebView2 or WKWebView — which belongs to
  [`WINDOWS-CHECKLIST.md`](./WINDOWS-CHECKLIST.md) and a machine that can run it.

- **An extension at `sciter-sqlite` scale** — **done**,
  [`sqlite_extension.odin`](../examples/sqlite_extension.odin). The same three SOM classes upstream's
  C++ binding publishes — `SQLite`, `DB`, `Recordset` — over the system's own `libsqlite3`, opened with
  `dynlib` so there is no header, no link flag and no development package. Seven tests, including one
  that loads the built `.so` through `sciter.loadLibrary` and runs a query from script.

  It found a rule that had gone unnoticed through every smaller asset: **a passport's `params` caps how
  many arguments script may pass.** A method declared `params = 1` and called as `db.exec(sql, a, b)`
  receives only `sql`, silently — which presented as every bound database parameter arriving as NULL
  and rows of nulls coming back. `som.odin` and [`api.md`](./api.md) now say so.

- **C modules via `jsbridge.h`** — **blocked**, and worth stating rather than silently skipping: the
  header is absent from the SDK checkout, so upstream's own `samples.c` cannot be built from it either.
  Reopen only if a later SDK ships the header.

### What this plan deliberately does not do

- **Port `samples.sciter`.** Two-thirds of it demonstrates capabilities with no host API at all. Reading
  those samples is valuable; translating them is not possible and would not be evidence of anything.
- **Chase the Windows-only demos** — `window-mixin`, `windows-directx`, `sciter-mfc`, `demos.d2d`. They
  belong to [`WINDOWS-CHECKLIST.md`](./WINDOWS-CHECKLIST.md) and to a machine that can run them.
- **Reimplement the inspector.** The SDK ships it; `inspector.odin` attaches to it. That is the correct
  division.

### Acceptance

Per stage, matching the house checklist in
[`PLAN-TESTING-AND-EXAMPLES.md`](./PLAN-TESTING-AND-EXAMPLES.md):

- [ ] the stage's opening probe was run, and its result is recorded even when it cancelled the stage
- [ ] anything measured that contradicts the headers is in the example header, the wrapper doc comment,
      and `CHANGELOG.md`'s known-issues list
- [ ] `just check` passes — both packages, `docs/snippets`, every example
- [ ] `just example-tests` green in one run on a quiet machine
- [ ] new examples run headless-ish: `XMODIFIERS=@im=none timeout 15 ./target/debug/NAME.exe`, exit 124
- [ ] counts updated in `CHANGELOG.md` and `README.md`, and **this document's tables updated** — a
      parity document that goes stale is worse than none
- [ ] `just format`, then `git checkout -- examples/custom_loader.odin examples/extension.odin`
- [ ] **nothing committed** — report the dirty tree

## What parity does and does not buy

**Does:** confidence that the host API is exercised. On that axis the evidence is good — every
cross-platform host demo the SDK ships has a counterpart here, most have tests, and several capabilities
here have no upstream counterpart at all.

**Does not:** confidence that we know how Sciter applications are *written*. That knowledge lives in
the 64 script samples, and it is mostly unreachable from Odin by design. The behavior documents are no
longer in that bucket — [`BEHAVIORS.md`](./BEHAVIORS.md) maps all 39 from the host side — but the
script cookbook still is. The honest position is that these bindings are complete and the cookbook is
not, and that those are separate projects.
