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

## Host-side parity

The comparison that decides whether the bindings are complete.

| SDK artifact | What it is | Ours | Verdict |
| --- | --- | --- | --- |
| `demos/usciter` | The universal "browser" host — window, resources, inspector | [`hello_window`](../examples/hello_window.odin), [`load_file`](../examples/load_file.odin), [`inspector`](../examples/inspector.odin) | **Covered** |
| `demos/tsciter` | Minimal host: one `main.cpp`, one `index.htm` | `hello_window` | **Covered** |
| `demos/gsciter` | Same again, cross-platform sources | same | **Covered** |
| `demos/inspector` | Source of the inspector tool itself | `inspector.odin` attaches to the shipped tool | Covered for our purpose; we do not reimplement the tool |
| `demos/sciter-component` | A DLL component with `exports.def` | [`extension.odin`](../examples/extension.odin) | **Adjacent** — ours is `SciterLibraryInit` + `sciter.loadLibrary`, which is the mechanism the SDK documents for `scapp`/Quark |
| `demos.lite/lite-bitmap`, `lite-sdl`, `lite-sciter` | Windowless rendering into a bitmap or an SDL surface | [`spike/windowless`](../spike/windowless/main.odin), [`EMBEDDING.md`](./EMBEDDING.md) | **Partial** — `SL_TARGET_BITMAP` works; GPU targets untried; two engine defects found |
| `demos/integration` | A Sciter view inside an existing native window | — | **Gap** |
| `samples.c` | C modules against `jsbridge.h`, `import`ed from script | — | **Gap, and not buildable here**: `jsbridge.h` is absent from the entire checkout |
| `sciter-sqlite` | A native extension exposing a C library to script | `extension.odin`, much smaller | **Gap in scale, not in mechanism** |
| `sciter-webview` | A native behavior embedding the OS webview as an element | — | **Gap** |
| `demos/window-mixin`, `windows-directx`, `sciter-mfc`, `demos.d2d` | Win32 / MFC / Direct2D / DirectX hosts | — | **N/A on Linux**; revisit with [`WINDOWS-CHECKLIST.md`](./WINDOWS-CHECKLIST.md) |

### What we have that upstream does not

Not parity in our favour so much as evidence that the host surface here is not a subset:

`request_loader`, `custom_loader`, `archive`, `single_binary`, `worker_thread`, `drag_and_drop`,
`named_behavior`, `workbench`, `api_map`, and host-driven `video`. None has a C/C++ counterpart in the
SDK.

Upstream ships a *script-side* test sample (`samples.sciter/unit-test`) and **no host-side tests**: the
only C test sources in the whole checkout belong to the copy of SDL vendored inside `demos.lite`. This
repository carries **310 `@(test)` assertions across 18 files** (`grep -c '@(test)'`), plus
`just example-tests`.

**Read: on the cross-platform host API, this repository is at or ahead of the SDK's own C/C++ samples.**

## Capabilities with no host API at all

The most useful result of the sweep, and the thing that stops a naive port of `samples.sciter`. Each row
was checked by grepping `external/sciter/include/sciter-x-api.h` for the term:

| Capability | Occurrences in `sciter-x-api.h` | Reachable from Odin how |
| --- | --- | --- |
| Clipboard | 0 | script only — `Clipboard` global |
| Printing | 0 | script only — `behavior:pager` + `Window.print` |
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
that does it* — which is what [`eval.odin`](../examples/eval.odin) and
[`call_odin_from_js.odin`](../examples/call_odin_from_js.odin) are for, and what
[`calling-between-odin-and-js.md`](./calling-between-odin-and-js.md) documents.

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
| `unit-test` | our 310 `@(test)` assertions — a different mechanism for the same purpose |
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

### Worth trying from the host, not yet tried

- **`popup`** — `SciterShowPopup` is bound and wrapped but only incidentally exercised in `dom_walk`. A
  context menu driven from Odin is a small, honest example.
- **`global-events`** — `Window.post` is script-side, but `SciterFireEvent` / `SciterPostEvent` are
  bound. Whether the two meet in the middle is unmeasured.
- **`frame-host`** — the closest script-side analogue to `demos/integration`.

## The `docs/md` sweep

128 markdown files, which is the reference this repository's guides are effectively a translation of.

| SDK area | Files | Our counterpart | State |
| --- | --- | --- | --- |
| `behaviors` | 40 | [`html-css-js.md`](./html-css-js.md), `behavior.odin`, `named_behavior.odin` | **Thinnest area.** Forty documented intrinsic behaviors — `button`, `calendar`, `check`, `edit`, `masked-edit`, `pager`, `scrollbar`, `select-dropdown`, `slider`, `terminal`, `virtual-list` … — and our examples touch a handful |
| `DOM` | 19 | [`dom.md`](./dom.md), [`api.md`](./api.md) | Good |
| `css` | 15 | `html-css-js.md` | Good on the layout story (`flow:`, flex units, no grid); thinner on `style-sets`, `image-map`, `marker-and-shadow`, vector `path:` images |
| `JS.runtime` | 15 | [`calling-between-odin-and-js.md`](./calling-between-odin-and-js.md) | **Mostly uncovered** — `Asset`, `Audio`, `BJSON`, `Clipboard`, `Fetch`, `Intl`, `URL`, `Zip`, `@env`, `@sys`, `@markdown`, `@yaml`. All script-side, all things a real app uses |
| `reactor` | 12 | [`reactor.md`](./reactor.md) | Good |
| `graphics` | 9 | [`graphics.md`](./graphics.md), `graphics_gallery.odin` | Good — the gallery covers `Brush`, `Path`, `Image`, `Text` |
| `HTML` | 5 | `html-css-js.md` | Good |
| `storage` | 4 | — | **Uncovered, and correctly so** — no host API exists |
| `JS` | 5 | `calling-between-odin-and-js.md` | Partial |
| `scapp` | 2 | [`deployment.md`](./deployment.md), `extension.odin` | Good |

## Gaps, ranked by what they would actually tell us

1. **The 40 intrinsic behaviors.** The largest and most useful unexplored area. `behavior.odin` proves
   `SciterCallBehaviorMethod` is the door into them; nothing systematically walks what is behind it.
   This is where a real cookbook would come from.
2. **Embedding into an existing native window** (`demos/integration`). Started —
   [`EMBEDDING.md`](./EMBEDDING.md) — and it immediately produced two engine defects, which is the usual
   sign that an area is worth the time.
3. **GPU windowless targets** — `SL_TARGET_OPENGL` and the DX variants. The spike only did `BITMAP`.
4. **`JS.runtime`** — not bindable, but the thing every real application uses, and undocumented here.
5. **C modules via `jsbridge.h`** — blocked: the header is not in the checkout.

## A plan to close them

**Status: not started, and deliberately not started.** Other work is in flight; this is written so the
work can be picked up cold rather than re-derived. Every stage is independently useful and independently
abandonable, which is the same shape [`VDOM.md`](./VDOM.md#if-it-is-built-build-it-in-this-order) uses
and for the same reason: the value is front-loaded, so stopping after stage 1 is a good outcome.

Two rules carried from [`RESEARCH-METHOD.md`](./RESEARCH-METHOD.md) apply throughout, because this whole
area is exactly where they were learned: **probe before documenting**, and **a headers claim is a
hypothesis**. Every stage below therefore opens with a cheap measurement whose result is allowed to
cancel the rest of the stage.

### Stage 1 — the intrinsic behaviors sweep

The largest gap and the one that produces the cookbook. `docs/md/behaviors` documents 40; this
repository exercises roughly four.

**Open with a probe, not a plan.** `behavior.odin` proves `SciterCallBehaviorMethod` reaches
`behavior:button` via `do_click`. It does **not** establish that other intrinsic behaviors expose
anything callable. Before committing to 40 of anything, take four with very different shapes —
`edit`, `select-dropdown`, `calendar`, `slider` — and find out whether they answer at all.

| Probe result | What the stage becomes |
| --- | --- |
| Most expose callable methods | a systematic sweep, and a real capability table |
| Only a handful do | a short doc saying which, and why the rest are DOM-and-CSS-only — still a genuine finding |
| None but `button` do | stop. Write three sentences in [`html-css-js.md`](./html-css-js.md) and move to stage 2 |

If it goes past the probe, the deliverable is **a table, not forty examples**: behavior name, what it
is, whether it is reachable from Odin, by which call, and what the DOM-side surface is instead. One new
example — a tour page carrying the behaviors worth driving — plus tests for the ones that answer.

Scope control: the sweep is the deliverable and the example is the illustration. If it runs long, cut
the example and keep the table.

### Stage 2 — finish the windowless story

[`EMBEDDING.md`](./EMBEDDING.md) got as far as "renders, scripts, and cannot take a mouse". Three
separable pieces, in order of value per hour:

1. **Report the two defects upstream.** `SXM_RESOLUTION` faulting on the next idle drain, and
   `SXM_MOUSE` never being handled, both with the backtrace already captured. Cheapest possible action
   with the largest possible payoff, since the second one is what gates interactivity — and the engine
   is not forkable, so upstream is the only route. See
   [`ALTERNATIVES.md`](./ALTERNATIVES.md#vendor-risk-and-bus-factor) for why that asymmetry matters.
2. **A GPU target.** `SL_TARGET_OPENGL` with `vendor:sdl3` or `vendor:glfw` supplying the context and
   `glGetProcAddress`, which is the arrangement the SDK's own `demos.lite/lite-sdl` uses. Establishes
   whether the defects are specific to the bitmap path.
3. **A real example, not a spike.** A Sciter pane composited into a frame this repository draws —
   which is the `demos/integration` equivalent, and the thing
   [`ALTERNATIVES.md`](./ALTERNATIVES.md#the-other-direction-sciter-inside-an-immediate-mode-app)
   claims is possible.

Piece 3 is worth holding until piece 1 has an answer: a pane that cannot be clicked is a demo with a
hole in it, and shipping it as an example commits us to explaining that hole forever.

### Stage 3 — the script-bridge pattern for host-less capabilities

Clipboard, printing, file dialogs, tray icon, menus, audio, gestures, zip, storage — nine capabilities,
zero API slots, per [the table above](#capabilities-with-no-host-api-at-all).

The mistake to avoid is writing nine examples. They would all be the same example. The deliverable is
**one** — the round trip of "Odin asks the document to do a thing that only script can do, and gets the
result back" — plus a table in
[`calling-between-odin-and-js.md`](./calling-between-odin-and-js.md) mapping each capability to the
script call that performs it.

Pick the one capability for the example on which is most annoying to get wrong rather than which is
easiest: a save dialog returning a path, or clipboard round-tripping non-text, both of which have a
failure mode more interesting than "it printed".

### Stage 4 — a `JS.runtime` reference

Documentation only, no code, no engine risk. Fifteen modules — `Asset`, `Audio`, `BJSON`, `Clipboard`,
`Fetch`, `Intl`, `URL`, `Zip`, `@env`, `@sys`, `@markdown`, `@yaml`, `@debug` — none bindable, all used
by real applications, none covered here.

Written for a host author rather than a script author: what exists, what it is for, and which of them
have a host-side counterpart that should be preferred (`Fetch` versus the request API, `Zip` versus
`SciterOpenArchive`, `@sys` versus doing it in Odin). That last column is the part that does not exist
anywhere upstream and is the reason to write it at all.

### Stage 5 — the long tail

Only if stages 1–4 are done and still felt worth extending.

- **A `sciter-webview` equivalent** — a native behavior embedding the OS webview as an element. The
  inverse of stage 2, and the answer to "can a Sciter app show a real web page".
- **An extension at `sciter-sqlite` scale** — `extension.odin` proves the mechanism; nothing proves it
  at the size of a real library binding.
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

**Does not:** confidence that we know how Sciter applications are *written*. That knowledge lives in the
64 script samples and the 40 behavior documents, and it is mostly unreachable from Odin by design. The
honest position is that these bindings are complete and the cookbook is not, and that those are separate
projects.
