# Defects to report upstream

Ready to file at [gitlab.com/sciter-engine/sciter-js-sdk](https://gitlab.com/sciter-engine/sciter-js-sdk/-/issues),
written so each one can be pasted as an issue without re-deriving anything. Stage 2 of
[`SDK-PARITY.md`](./SDK-PARITY.md) calls this the cheapest possible action with the largest possible
payoff, and it is still true: **the engine is a binary blob with no source, so upstream is the only
route to a fix** — see [`ALTERNATIVES.md`](./ALTERNATIVES.md#vendor-risk-and-bus-factor).

Nothing here has been filed yet; this repository has no account on that tracker. Anyone who does can
lift these verbatim.

**Common preamble for every report:** Sciter.JS 6.0.4.9-bis, Linux x64, vendored binary from the SDK
release; reproduced from Odin bindings that call `ISciterAPI` directly, so every symptom is one C call
away from the engine.

---

## 1. `SXM_RESOLUTION` faults one message later, in a windowless view

**Severity:** crash. **Workaround:** never send the message, and accept the default DPI.

`SciterProcX(hwnd, SXM_RESOLUTION)` returns `TRUE`, and the process then segfaults the *next* time
anything drains the posted queue — the following `SXM_HEARTBIT` or `SXM_MOUSE`. The backtrace says why:

```
wing::window::setAttribute(int, int)
html::iwindow::setup_window_frame(gool::WINDOW_STATE)
html::view::on_media_changed()
qjs::xview::on_media_changed()
html::view::process_posted_things(bool)
html::view::handle_on_idle()
html::view::on_idle()
lite::view::proc_x(void*, SCITER_X_MSG*)
```

Setting the resolution posts a media-changed item; draining it makes the view reach for a native window
frame that a windowless view does not have. Because the fault surfaces one message after its cause, it
presents as "the heartbeat crashes".

**Reproduction:** create a windowless view, load any document, send `SXM_RESOLUTION`, then send one
`SXM_HEARTBIT`. `spike/windowless/main.odin -- res` in this repository does exactly that.

**Suggested fix:** `on_media_changed` should skip `setup_window_frame` when the view has no window
frame, as it already must elsewhere in windowless mode.

## 2. One `SXM_DESTROY` ends windowless mode for the whole process

**Severity:** crash. **Workaround:** create the views you need, keep them, swap documents with
`SciterLoadHtml`, and destroy only on the way out.

After any `SXM_DESTROY`, the next `SXM_CREATE` segfaults **inside the create call** — with the same
`HWINDOW` key or a fresh one, and whether or not other views are still alive. Two views created before
any destroy coexist happily, and a second destroy of an already-destroyed view is harmless (`FALSE`).

This makes a windowless view unusable for anything that opens and closes panes over a long-running
process, which is a large share of what the mode is for.

**Reproduction:** create a view, destroy it, create another. `examples/windowless.odin` documents the
rule and deliberately never destroys, because a test that did would take every later test with it.

## 3. `SL_TARGET_OPENGLES` is accepted and then draws nothing

**Severity:** silent wrong behaviour. **Workaround:** use a desktop GL context and `SL_TARGET_OPENGL`.

With `SL_TARGET_OPENGLES` the create succeeds, `SXM_PAINT` answers `FALSE`, and nothing is drawn — on a
GLES 3.2 context *and* on a desktop GL context. With a **GLES context and `SL_TARGET_OPENGL`**, paint
answers `TRUE` and still draws nothing, because Skia emits `#version 150` desktop GLSL that the driver
rejects (`GLSL 1.50 is not supported`). Desktop GL contexts, core and compatibility profiles both, work.

Either the GLES path is not implemented in this build or it needs a shader set that is not shipped; a
clear failure from `SXM_CREATE` would save the caller the bisect. `examples/windowless_gl.odin` carries
the measurements.

## 4. A SOM method thunk reads its arguments without checking `argc`

**Severity:** crash, from ordinary caller error. **Workaround:** the caller must count.

`som_method_def_t` carries `params`, and the generated thunks
(`sciter::om::member_function<…>::thunk`) read `argv[0..params)` unconditionally. Calling a method with
fewer arguments than it declares faults inside the engine:

```
sciter::om::member_function<bool (html::behavior::dd_select_ctl::*)(tool::t_value<unsigned int,…>)>
  ::thunk<&html::behavior::dd_select_ctl::api_show_popup>(som_asset_t*, unsigned int, tool::value const*, tool::value*)
```

Measured on `edit.insertText` (declares 1), `select.showPopup` (1) and `terminal.read` (3), each called
with none. Extra arguments are ignored safely; only the short case faults.

Since `params` is already in the passport, the thunk has everything it needs to answer `FALSE` instead.
This binding now refuses the call itself (`asset_call` → `.Wrong_Arity`), but every other host binding
is one mistake away from the same crash.

## 5. `SciterGetElementByUID` refuses every UID `SciterGetElementUID` produces

**Severity:** an API pair that cannot be used. **Workaround:** keep `HELEMENT`s, or use ids.

On the vendored 6.x engine, a UID obtained from `SciterGetElementUID` is rejected by
`SciterGetElementByUID` — with either window handle, whether the element was made or found. The pair is
documented as the way to carry a weak reference to an element across time, and there is no other way to
do that.

## 6. `SciterSetMediaType` takes effect only once per window

**Severity:** silent wrong behaviour.

The first call is honoured; every later one reports success and changes nothing, across document
reloads included. `SciterSetMediaVars` does switch every time, so the workaround is to express the
distinction as a media *variable* — but the asymmetry is surprising and undocumented.

## 7. `SciterInsertElement` segfaults on a large index

**Severity:** crash. **Workaround:** clamp to the child count.

`max(u32)` is the obvious spelling of "append" and crashes inside the engine rather than clamping or
answering `INVALID_PARAMETER`.

## 8. `SciterAtomNameCB` segfaults on an integer that is not an atom

**Severity:** crash, before engine initialisation.

Called before the engine is initialised, with an integer that is not an atom, it faults; after
initialisation the same call answers with an empty name. There is no API to ask whether an integer is
an atom, and the number space is shared with an encoding of immediates (1, 2, 3 decode to `"null"`,
`"false"`, `"true"`), so a host cannot validate the input itself.

## 9. `gStar` draws a scatter of disconnected fragments

**Severity:** wrong output, deterministic.

`gStar` answers `.OK` and paints a figure that never closes and never fills: 63 lit pixels against 353
for the same star built by hand with `gPolygon`. Deterministic, so the geometry is wrong rather than
the memory.

## 10. `gFillMode` answers `.NOTSUPPORTED`

**Severity:** documented feature absent.

The renderer is always even-odd; two nested squares wound the same way render with a hole either way.
The API slot exists and refuses.

---

## Not defects — corrections this repository had to make to itself

Kept here so nobody files them by mistake. Each was written up as an engine defect and each turned out
to be this repository's own CSS or timing:

| Reported as | Actually |
| --- | --- |
| "windowless mode never delivers mouse events" | the test page's click target was `position: absolute` with a percentage height, which lays out **1px tall**, so every click landed on `<body>` |
| "the intrinsic behaviors ignore the windowless mouse" | same cause, one rule along: an inline-level `<button>` / `<input>` positioned absolutely lays out **1 × 1** |
| "a behavior's click is not delivered" | a behavior's event is *posted*; it arrives on the next heartbeat |

The rule those three produced is in
[`html-css-js.md`](./html-css-js.md#absolutely-positioned-elements-collapse--two-separate-rules-both-measured),
and `dom_walk.odin` pins it so it cannot happen a fourth time.
