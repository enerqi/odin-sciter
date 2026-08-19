# Sciter's HTML, CSS and JavaScript

Sciter is not a browser and does not embed one. It has its own HTML parser, its own CSS engine, its own
layout and paint, and QuickJS for script — all inside a single ~25 MB shared library with no Chromium,
no Node.js and no separate process.

That buys the size and the startup time. What it costs is that "it is just HTML" is only about
three-quarters true. This guide is the part that is not, so you find out here rather than by staring
at a blank window.

The authoritative reference is the SDK's own `docs/md/` tree and
[docs.sciter.com](https://docs.sciter.com/docs/intro). This guide is oriented at someone arriving from
web development with an Odin host to write.

## The short version

| | |
| --- | --- |
| HTML | a full HTML5 parser, a fixed set of known tags plus arbitrary custom ones, and Sciter-specific elements (`<frame>`, `<popup>`, `<menu>`, `<include>`) |
| CSS | CSS 2.1 in full, selected CSS3 modules, plus Sciter's own flow/flex layout, style sets, `@image-map`, and CSS-assigned behaviors |
| JS | QuickJS implementing **ES2020 in full**, plus JSX with a native parser, Signals, and a small NodeJS-shaped standard library |
| Missing | `display:flexbox`, `display:grid`, `gap`, `clamp()`/`min()`/`max()`, WebGL-by-default, service workers, IndexedDB, most of the modern web platform API surface — **and any component library**, see [Styling controls](#styling-controls-and-the-states-you-inherit) |
| Extra | native behaviors, a persistent NoSQL store, real desktop windows and popups from script |

**The expectation to reset first**, because it decides how much CSS you are signing up to write: the web
platform hands you a framework — Material, Fluent, Bootstrap, Bulma, Tailwind — and with it a component
vocabulary and, more importantly, the *states* of every control. None of that exists here, and none of it
can be ported: every one of those frameworks is flex/grid at its core, and their distribution is
npm/CDN, which this engine has no notion of. What the SDK offers instead is three sample themes to copy,
`@set` style-sets as the encapsulation mechanism, and thirteen script widgets. See
[Styling controls](#styling-controls-and-the-states-you-inherit).

## HTML

The parser is a real HTML parser, so malformed markup is repaired rather than rejected. The recognised
tag set is fixed and listed in the SDK's `docs/md/HTML/html-elements.md` — it is the classic HTML set
plus Sciter's own.

**Custom tags are fully supported.** If `<toolbar>` reads better than `<div class="toolbar">`, use it;
the only requirement is a CSS rule giving it a `display`:

```css
toolbar { display: block; flow: horizontal; }
```

Sciter-specific markup you will actually reach for:

- **`<frame>`** can appear anywhere a block element can — an embedded document, not an iframe sandbox.
  `<frameset>` is a split container with real, stylable `<splitter>` elements, and can contain ordinary
  `<div>`s as well as frames.
- **`<popup>` and `<menu class=popup|context>`** render in separate desktop popup windows, so they can
  extend beyond the host window's bounds. Real menus, not `position:absolute` imitations.
- **`<include src="...">`** assembles the final document from fragments at parse time.
- **Tag shortcuts**: `<div#component.super>` is `<div id="component" class="super">`.
- **An extended set of `<input>` types** — see `docs/md/HTML/html-inputs.md`.

The window's **title comes from the document's `<title>`**. Sciter 6 has no window-title API, and
`create_window` has no title field for that reason.

**Declare the encoding, even for a document you assembled in Odin.** `load_html` takes UTF-8 bytes, but
the bytes being UTF-8 is not the same as the document *saying* so: with no `<meta charset="utf-8">` the
engine decodes with the SYSTEM codepage, and on a Windows-1252 machine an em dash arrives as `â€"`
and `·` as `Â·`. A file loaded by URL can be sniffed; a string handed to `load_html`
has nothing to sniff, so the declaration is the only signal there is. The failure is silent in every
direction that matters — nothing in the debug output, and the mangling is in the DOM rather than only on
screen, so it survives into `text()` and into every attribute you read back. Two lines of head:

```html
<head>
  <meta charset="utf-8">
```

## CSS

CSS 2.1 is implemented in full. CSS3 is implemented in the modules that are practical for desktop UI:
`transform` (2D only, and **not every function** — see
[Animation](#animation-what-moves-and-the-two-ways-a-transform-is-silently-ignored)), `transition`,
`animation`, most CSS3 selectors, `border-radius`, `box-shadow`, `opacity`, `rgba()`/`hsl()`,
`@font-face`, `@media`, `var()`, gradients, `filter()` and `backdrop-filter()`.

### Layout is flow and flex units, not flexbox

This is the single biggest adjustment. **There is no `display:flexbox` and no `display:grid.`** Sciter
replaces both with two mechanisms that compose better with each other:

**Flex units** — `*`, `2*`, `0.5*` — apply to almost any property that takes a length: `width`,
`height`, margins, paddings, border widths. The physical model is a coil of that strength attached to
that side. They distribute the free space left over *after* fixed and percentage lengths are applied.

```css
child {
  margin-left:  0.7*;   /* pushed right, 70/30 against the other coil */
  margin-right: 0.3*;
}
sidebar { width: 200px; }
main    { size: *; }    /* shorthand for width:1*; height:1* - fill what is left */
```

**The `flow` property** declares the layout manager used *inside* an element:

```css
body      { flow: vertical; }
toolbar   { flow: horizontal; }
gallery   { flow: grid(1* 1* 1*); }   /* three equal columns */
```

`flow: horizontal | vertical | horizontal-flow | vertical-flow | grid(...) | stack | table | ...`.
`docs/md/css/flows-and-flexes.md` in the SDK has a side-by-side cheat sheet against flexbox, and
`css/demo/flow-vs-flexbox.htm` is runnable.

Porting instinct: `display:flex; flex-direction:row` becomes `flow:horizontal`, and `flex:1` becomes
`size:*` or `width:*`.

**`gap` does not exist either**, and it is the one people miss because it is a *spacing* property rather
than a layout mode — a stylesheet full of `gap: .5rem` loses every one of them silently. Spacing between
children is margins on the children (`.line > * { margin-right: .5em }` for a row), or flex-unit margins
when the space should distribute rather than repeat.

### Absolutely positioned elements collapse — two separate rules, both measured

The most expensive pair of facts in this repository. Between them they have produced **three** false
findings, two written up as engine defects, because an element with no box is not under the pointer and
every click lands on `<body>` instead.

**Rule 1 — a percentage *height* on an absolutely positioned element resolves to 1px.**

```css
#overlay { position: absolute; left: 0; top: 0; width: 100%; height: 100%; }   /* 479 × 1 */
#half    { position: absolute; left: 0; top: 0; width: 120px; height: 100%; }  /* 121 × 1 */
#wide    { position: absolute; left: 0; top: 0; width: 100%; height: 30px; }   /* 479 × 31 ✓ */
```

The width resolves; the height does not. A pixel height is fine. So the full-size transparent overlay a
browser page would use to catch clicks is one pixel tall here, and receives nothing.

**Rule 2 — an inline-level *widget* taken out of flow collapses to 1 × 1.** `<button>` and `<input>`
are `display: inline-block` by default, and positioning one absolutely leaves it with no box at all,
whatever size the CSS asks for:

```css
#btn   { position: absolute; left: 20px; top: 80px; width: 120px; height: 30px; }              /* 1 × 1 */
#btn2  { display: block; position: absolute; left: 20px; top: 80px; width: 120px; height: 30px; } /* 149 × 39 ✓ */
```

`display: block` is the fix. Measured on `<button>` and `<input type=text>`; a `<div>`, a `<span>` and
a `<select>` in the same position all get their boxes, so this is about the default display of those
two rather than about `position` in general. `position: fixed` behaves the same way as `absolute`
throughout.

**The general-purpose alternative is `flow: stack`**, which the SDK's own CSS documentation calls "a
simpler and faster alternative to position:absolute". The container stacks its children on top of one
another; each child positions itself with margins and sizes itself with flex units, and *percentage
heights are not involved*:

```css
#stage   { flow: stack; width: *; height: *; }
#overlay { width: *; height: *; z-index: 2; }                    /* 479 × 379 — a real click catcher */
#panel   { width: 120px; height: 30px; margin: 80px * * 20px; }  /* 20px from the left, 80px down */
```

The three findings these rules cost:

- the original windowless spike → "the engine never delivers mouse events in windowless mode" —
  retracted (rule 1), see [`EMBEDDING.md`](./EMBEDDING.md).
- `examples/windowless.odin` → "the intrinsic behaviors ignore the windowless mouse" — retracted
  (rule 2); a click presses a button, toggles a checkbox and focuses an editor.
- the same test's "an `<input>` does not take the caret from a click" — same cause, same retraction.

**When an element does not receive events, ask `location(el, .Border, .View)` what shape the engine
thinks it is** before concluding anything about the event system.

### Sciter-only CSS worth knowing

- **`behavior: button;`** — attaches a *native* controller to an element. This is how `<button>`,
  `<select>`, `<input type=date>` and the rest are implemented, and it is available to your own
  elements. Each behavior contributes methods under its own name (`el.edit.setRange(0, 10)`), which
  avoids collisions with the standard DOM. The catalogue is `docs/md/behaviors/` **in the Sciter SDK
  checkout, not in this repository**; what a *host* can reach from Odin is measured in
  [`BEHAVIORS.md`](./BEHAVIORS.md).

  **Read the absence as well as the presence: a click event comes from the CONTROLLER, so an element with
  no behavior produces none.** A `<div>` you have made to look like a row or a tab is not clickable in
  any sense a host can hear — no `.BUTTON_CLICK` reaches an `Event_Handler`, and nothing in the document
  or the log says why. Measured, same view: a plain `<div>` answers `do_click` with `handled = false` and
  reports `control_type` `.NO`; the same `<div>` with `behavior: button` answers `true` and `.BUTTON`.
  **`control_type` is the diagnostic** — ask an unresponsive element what the engine thinks it is before
  suspecting the event system. (For pointer events without a behavior, subscribe to `.MOUSE` instead.)

  One timing consequence, and it only shows in a windowless view: a behavior goes live when the
  element's style is RESOLVED, not when it is inserted. An element added by `set_html` reports its
  `control_type` immediately but answers `do_click` with `handled = false` until the engine has run a
  pass over it — measured `false` before `windowless_heartbeat` + `paint_windowless`, `true` after. A
  windowed application pumps continuously and never sees this; a test that renders and clicks in the same
  breath sees it every time, and blames the CSS.
- **Style sets** — `@set name { ...rules... }`, applied with `style-set: name`. Encapsulated styling
  for a component subtree, closer to shadow DOM than to a class.
- **CSS constants and mixins** — `@const`, `@mixin`, evaluated at parse time.
- **`context-menu: selector(#menu)`** — binds a `<menu class=context>` to an element declaratively.
- **`@image-map`** — sprite sheets without arithmetic in every rule.
- **Vector images in CSS** — `background-image: url(path: M 0 0 L 1 1 Z)` and the `icon:` scheme.
- **`sciter:ux-master.css`** is the default stylesheet every document inherits. Read it when an
  element's default look is a mystery.

### Styling controls, and the states you inherit

**Measured on 6.0.4.9, Windows, in a windowless view.** A `<button>`'s default look is drawn by the
engine as an *appearance* — native chrome — not as CSS properties you can read, extend or partly
override. What the default cascade actually gives a bare `<button>`:

| state | `background-color` | `border-top-color` |
| --- | --- | --- |
| rest | `transparent` | `#CECECE` |
| `:hover` | `transparent` | `#CECECE` |
| `:active` | **`#EBEBEB`** | `#CECECE` |
| `:focus` | `transparent` | **`window-accent-color`** |
| `[disabled]` | `#E8E8E8` (text `#AAAAAA`) | `#CECECE` |

Three things follow, and the second is the one that bites.

**1. There is no hover state at all**, on any of them. A pressed flash, a focus border and a disabled
wash are the whole of it.

**2. Painting a control REMOVES the little you had.** Set a `background` and the `:active` flash is gone
— the same button, given `background: #89b4fa`, measures `#89B4FA` at rest, hovered, pressed *and*
focused. You do not start from "no feedback" and add; you start from "a bit of feedback" and silently
delete it. The result is a control that looks finished and feels dead, which is exactly the bug a quick
visual check passes:

```css
/* the whole set, because there is nothing to inherit and no framework to inherit it from */
button           { appearance: none; background: var(--accent); color: var(--accent-ink); }
button:hover     { background: var(--accent-hover); }
button:active    { background: var(--accent-active); }
button:focus     { box-shadow: 0 0 0 2px rgba(137,180,250,.35); }
button:disabled  { background: var(--line); color: var(--ink-dim); }  /* LAST: it must beat :hover */
```

`:disabled` last is not style — specificity between those five is a tie, so source order decides, and a
disabled button that still lights up under the pointer is the standard way to get this wrong.

**3. `appearance: none` is the first line, not a fix for a symptom.** It drops the native chrome — with
it, the same button reports no `border-top-color` at all — and the SDK's own
`samples.sciter/input-elements-styling/button.htm` opens with it for that reason. Keep the native look or
replace it; do not paint over it.

`window-accent-color` in that table is not a colour this file made up: the engine resolves **symbolic
system colours**, so a focus ring can follow the user's desktop accent instead of guessing at one.

**Where to copy from.** `sciter:ux-master.css` is the *diagnostic* — read it when a default look is a
mystery. The *starting point* is `samples.sciter/themes/` in the SDK checkout: three complete themes
restyling every intrinsic control — `windows-flat` (702 lines, 19 state rules), `android-material` (479),
`default-unisex` (52). They are written in Sciter's own variable form and hook `:theme(dark)` and
`[ui-size="compact"]`, so a dark/compact switch is a token swap rather than a second stylesheet. For
individual widgets, `widgets/` has thirteen (tabs, color-selector, prop-list, virtual-tree, console,
editable-label, tag-list, …), each a small `.css` + `.js` pair — components to lift, not a design system
to adopt.

**Two variable syntaxes, both real.** Standard custom properties work (`--name:` + `var(--name)`, 4.4.8.0
and later) and are the ones to reach for. Sciter's own ergonomic form is what every SDK theme is written
in, so anyone cribbing from one meets it in the first twenty lines:

```css
body { var(button-back): #555; }              /* declare, Sciter form */
button { background: color(button-back); }     /* use — color() / length() are the typed accessors */
```

`docs/md/css/variables-and-attributes.md` in the SDK has both, plus `attr(name):` — CSS-assigned default
*attributes*, which is how `<select>`'s options get their `role` without any script.

### Animation: what moves, and the two ways a transform is silently ignored

`transition`, `animation` and `transform` are all on the engine's supported-property list, and they do
work — but a browser page's transform usually does nothing here, for two reasons that produce no error,
no warning and no visible clue. Both measured on 6.0.4.9, **in pixels**, which is the first thing to know:

**A transform is paint-time, so no box can see it.** `getBoundingClientRect` in script and `location` in
the host both keep reporting the element's LAYOUT rectangle, transformed or not. An assertion built on
either says "nothing moved" about a page that is moving perfectly, and — worse — says "centred" about one
that is not. `windowless_pixel` on a windowless view is the honest instrument:

```odin
// Did the engine actually PAINT the element where the transform asked? Ask the surface, not the DOM.
r, g, b, _ := sciter_app.windowless_pixel(&view, 220, 80)
moved := r == 0x00 && g == 0xff && b == 0x00 // the box's own colour, 200px right of its layout position
```

**Fact 1 — `translate(x, y)` is honoured; `translateX(x)` is not.** No error, no warning: the element
simply stays put. `scale()` and `rotate()` paint — the SDK's own transform sample
(`samples.sciter/gestures/zoom-rotation.htm`) uses exactly those two, which is the clue in hindsight.

**Fact 2 — `style.setProperty("transform", …)` applies; assigning `style.transform = …` does not.**
Setting the whole inline style with `setAttribute("style", …)` did not apply it either. So the working
pair from script, and it is valid CSS in a browser too, which is what makes it the portable choice:

```css
.track { transition: transform 0.35s ease; }   /* the engine animates this, on its own frame clock */
```

```js
// Both halves matter. `style.transform = "translateX(-300px)"` is two mistakes in one line and is silent.
track.style.setProperty("transform", "translate(-300px, 0)");
```

**Fact 3 — a `transition` animates a transform that changes through the CASCADE, not one set inline.** This
is the one that costs an afternoon, because the first two make the element move and this one makes the move
instant. Measured in the same page: toggling a class whose rule carries `transform: scale(1)` animates over
its declared duration, while `style.setProperty("transform", …)` on the same element with the same
`transition` arrives within two frames, whatever the duration says. On screen that reads as a jump followed
by whatever else was animating — a class-driven scale, say — continuing on its own.

So a script-driven move has to be tweened, and the runtime has the hook for it (see the table below):

```js
// Sciter: step the transform yourself, at the engine's frame rate, with a named easing.
var from = current, delta = target - current;
track.morphContent(function (progress) {
   track.style.setProperty("transform", "translate(" + (from + delta * progress) + "px, 0)");
   return true;
}, { duration: 320, ease: "cubic-out" });
```

`morphContent`'s presence is also a serviceable test for which engine you are on: a browser does not have it
and does not need it, because there the stylesheet's `transition` animates the inline change too.

A layout property does not animate either: a `transition: margin-left` reads back as an empty computed
`transition` and the element jumps in a frame or two. If a fallback has to move something by layout (a
margin, `left`), expect a jump and drive it yourself.

**A `var()` inside `transform` did not resolve** — neither `var(--w3c-name)` nor Sciter's own `var(name)`
syntax, with the variable declared on the element and updated through `style.variables({…})`, which is how
the SDK's sample drives its rotate/scale. It may want the variable on an ancestor; `setProperty` sidesteps
the question.

When script does have to own the animation, the runtime has better tools than a `setInterval` tween, all
script-side (see [`JS-RUNTIME.md`](./JS-RUNTIME.md)):

| Call | What it gives you |
| --- | --- |
| `element.morphContent(step, {duration, ease})` | the engine calls `step(progress: 0…1)` at frame rate and stops when it returns false; ~25 named easings (`"cubic-out"`, `"bounce-in-out"`, …). The general-purpose tween |
| `element.replaceContent(jsx, {duration, ease, effect})` | swaps content with a named effect — `"slide-left"`, `"blend"`, `"scroll-top"`, … — and returns a promise that resolves when it ends |
| `requestAnimationFrame` / `cancelAnimationFrame` | present, and paced by the paint clock rather than a timer |
| `element.scrollTo({left, top, behavior: "smooth"})` | an animated scroll, which is often the whole feature |

### Making a big document cheap: layout is the cost, and `display: none` is the switch

A document that feels fine in a browser can be unusable here, and the reason is almost never the paint —
it is how much of the document takes part in LAYOUT. Measured on 6.0.4.9, a page of 48 sections (~60
elements each) laid out side by side, one visible at a time:

| | per resize step |
| --- | --- |
| all 48 in layout | **124 ms** |
| far sections `visibility: hidden` | 119 ms — no help at all |
| far sections `display: none` | **6 ms** |

`visibility: hidden` is the trap: it hides the pixels and keeps the box, so every hidden section is still
measured, positioned and re-measured on every resize step. `display: none` takes it out of layout, and that
is the whole difference. A window edge being dragged delivers one resize per mouse move, so 124 ms/step is
a window that cannot be dragged, and 6 ms/step is one that can.

Two consequences worth designing for:

- **Keep only what is on screen (plus a neighbour) in layout.** A carousel, a pager, a long list: park the
  rest with `display: none`. It is the same win in a browser — it is just that a browser can afford not to
  take it.
- **Parking changes the geometry under you.** Dropping a section from the left moves everything after it,
  so a script that positions the visible part has to re-measure AFTER parking, and apply any compensating
  move with the transition switched off — otherwise the correction animates and reads as a jump.

**What is NOT worth chasing**, all measured on the same page: `box-shadow`, `border-radius`, `opacity` on
inactive sections, `transform: scale()`, background colours and even hiding all the text changed the frame
cost by nothing outside noise. Neither did `set_debug_mode(true)`, which is worth knowing before blaming
the inspector hooks for a slow debug build.

**`paint_windowless` is not a frame-rate proxy.** It rasterises the entire surface on every call, with no
dirty-rect tracking, so a windowless loop reports a fixed ~90-180 ms/frame for a full-window page and says
nothing about what a real window does. Use a windowless view to measure LAYOUT (`load_html`,
`resize_windowless` + `heartbeat`), and measure frame rate in a window.

**The one host-side lever is the graphics layer.** `graphics_caps` reports how the engine rates the machine
(and reported `.Software` on the machine these numbers come from), and `SET_GFX_LAYER` chooses the backend —
there is no typed wrapper, because it is one `set_option` with no window:

```odin
// Before creating any window. `.SKIA_GPU` asks for the best GPU layer the platform has.
err := sciter_app.set_option(.SET_GFX_LAYER, uintptr(sciter.Gfx_Layer.SKIA_GPU))
```

**A GPU layer is ALREADY the default**, which is worth knowing before wiring a switch for it: the SDK's
changelog records DX12/Vulkan as the Windows default (with an OpenGL fallback), Vulkan on Linux and Metal on
macOS. `SET_GFX_LAYER` is therefore for FORCING a particular backend, or for going back to software Skia when
a GPU path misbehaves — the same Skia GL path is the one whose desktop shaders a driver can reject outright
(see `create_windowless`'s `.OPENGL` note). Make it a flag, print what the engine answered, and keep the
raster layer reachable.

And `graphics_caps` does not answer "which layer am I on". It is the Direct2D-era 0/1/2 rating of the machine
and reported `.Software` on a Windows build whose default is a GPU layer. Nothing in the API reports the
active layer.

### A stylesheet is capped at 32 KiB, and the rest is dropped in silence

The most expensive measurement in this file, because nothing tells you. Bisected on 6.0.4.9 with one
`<style>` element in one document:

| `<style>` contents | result |
| --- | --- |
| 32,763 bytes | every rule applies |
| 32,816 bytes | **nothing past the cut applies at all** |

32,768 is the number. Past it there is no warning, no error, and — this is what makes it so confusing — the
engine's CSS diagnostics go QUIET, because the parser never reaches the rules that would have produced them.
A page like that still loads and still runs its script; it is simply half-styled, and the half that lost is
the bottom of the file.

Two consequences for anything with a large stylesheet:

- **Comments count.** A well-documented stylesheet is mostly prose, and prose is bytes. Strip comments when
  you EMIT the page rather than deleting them from the source: a browser has no use for them either, and one
  card-page template in the wild dropped from 33.3 KB to 18.4 KB that way — the difference between a
  stylesheet a sentence can break and one with 14 KB of headroom.
- **Assert it.** A byte count is trivial to check and impossible to notice by eye:

```odin
// Somewhere the page is produced or tested. The cap is the engine's, not this package's.
style_bytes := len(stylesheet)
assert(style_bytes < 32 * 1024, "the stylesheet is over Sciter's 32 KiB cap; the rest would be dropped")
```

An external stylesheet (`<link>`) is a separate parse and gets its own budget, so splitting one sheet into
two is also a way out.

### Three stylesheets, in order

Under the document's own CSS sit two more, and they are different scopes:

| | Scope | Call |
| --- | --- | --- |
| Master | the whole engine, every window | `set_master_css(css)` / `append_master_css(css)` |
| Window | one window, every document loaded into it | `set_css(window, css, base_url, media_type)` |
| Document | `<style>` and `<link>` in the markup | — |

`set_master_css` **replaces** what is there, so set the base sheet once and `append_master_css`
after that; `""` is refused rather than treated as "clear it", so a sheet that matches nothing
(`no-such-element {}`) is how to get back to nothing. Both apply to documents that are *already*
loaded, but the cascade has to be re-run for that to show — `update_element(el, render = true)` or a
reload.

### `@media`, and switching it at runtime

The media **type** is one name per window — `screen` by default, `print`, `handheld`, or whatever the
document's CSS uses:

```odin
sciter_app.set_media_type(window, "print")     // before loading the document that needs it
```

Only the **first** call on a window has any effect. Later ones report success and change nothing, a
reload included, so it is a property of the window rather than a switch.

The switchable half is media **variables**, which are flags rather than name/value pairs. Every name
set truthy becomes a query the CSS matches by bare name, and this is the mechanism for a theme:

```css
@media dark { body { background: #11111b; color: #cdd6f4; } }
```

```odin
vars: sciter_app.Value
defer sciter_app.value_clear(&vars)
on := sciter_app.value_from(true)
defer sciter_app.value_clear(&on)
sciter_app.value_set(&vars, "dark", &on)
sciter_app.set_media_vars(window, &vars)
```

Flags **merge**: a call naming only `dark` leaves `screen` and everything else already set alone, and
turning one off means naming it with `false`, not leaving it out. They take effect every time, and
survive a reload.

One trap, because it fails silently: `@media (name: "value")` parses and then matches
*unconditionally*. It is not an error and not a flag test. Name the state itself — `@media dark`.

### What the SDK's own pages settle, and where they disagree with the engine

`sciter-js-sdk/docs/md/css/` is the authority on the dialect, and four of its answers are the ones a porting
author most needs — all mapped in [`SDK-DOCS-AND-SAMPLES.md`](./SDK-DOCS-AND-SAMPLES.md):

- **Media queries are not W3C syntax.** `@media screen and (max-width: 600px)` is a syntax ERROR here; the
  Sciter form is `@media screen and (width < 600px)` (`css/media-const-mixin.md`). Since a CSS syntax error
  costs the rest of the stylesheet, a ported page's phone query has to be rewritten or kept last.
- **`calc()` is supported** — flex units (`*`) just cannot appear inside it (`css/units/dimentional.md`).
  `min()`, `max()` and `clamp()` are not, so `calc()` is the way to compute a value.
- **The units are** `em`, `rem`, `ex`, `ch`, `%`, `vw`, `vh`, `vmin`, `vmax`, plus Sciter's own `width(X%)`
  and `height(Y%)` (a percentage of the element's own width or height — `line-height: height(100%)`).
- **`css/properties.md` is the property list** and `css/flows-and-flexes.md` is the flexbox cheat sheet, with
  a runnable `css/demo/flow-vs-flexbox.htm` beside it.

And the correction that cost the most, measured on 6.0.4.9: **`vh` DOES resolve in a `font-size`**, and it
re-evaluates on a resize — `font-size: 2.4vh` computes 21.6px in a 900px-tall view, 28.8px at 1200 and 12px
at 500, on a fresh view and after resizing a live one. This guide said the opposite for a while, on a reading
where the computed size came back EMPTY and a text-sized box grew to fill its container. That reading was
real and the diagnosis was wrong: the whole stylesheet block holding the rule had been dropped by the
[32 KiB stylesheet cap](#a-stylesheet-is-capped-at-32-kib-and-the-rest-is-dropped-in-silence), so no `font-size` was being applied at all. When a
declaration appears not to work, check the sheet's SIZE before concluding anything about the property.

### Units

Sciter's default length unit is `ppx` — physical pixels, DPI-aware. `px` is accepted and treated as a
device-independent pixel. `dip`, `em`, `rem`, `%`, `mm`, `in`, `pt`, `sp` all work, and `*` is the flex
unit above. `docs/md/css/units/` covers the details.

`vw`, `vh`, `vmin` and `vmax` all work, `font-size` included — but **`clamp()`, `min()` and `max()` do
not**, which is what breaks the fluid-type idiom every recent browser stylesheet is full of:
`font-size: clamp(1rem, min(2.4vh, 4.3vw), 2.2rem)` loses its bounds (a `clamp()` degrades to its PREFERRED
term) and the nested `min()` invalidates the declaration outright — measured, `min(2.4vh, 4.3vw)` computes a
flat 13.33px that does not track the window at all. The port is to keep the viewport term and drop the
bounds: one `2.4vh`, which tracks the window exactly as the browser's middle term does. `calc()` IS supported
if the value has to be computed, with two caveats — flex units (`*`) cannot appear inside it, and
`getComputedStyle` reads a `calc()` back as the literal string `calc(...)`, so a value you want to ASSERT has
to be a plain unit. The bounds themselves can be had from a media query on `height`/`width`, but measured, a
dimension query only takes effect after a RESIZE and not on the first layout, so a capped size is wrong on
the freshly opened window and right once it is dragged.

## JavaScript

QuickJS, implementing **ES2020 in full** — modules, classes, `async`/`await`, generators, destructuring,
optional chaining, `BigInt`. It is a genuinely current language, not an ES5 dialect. Sciter's additions
are aimed at the "language behind a UI" role:

- **JSX with a native parser.** No build step, no Babel. `<div class="x">{value}</div>` is a literal.
- **Reactor** — JSX plus a native `element.patch()` reconciler, which together give you React's model
  with no build step. Function and class components, lifecycle methods, and **Signals**. Not a
  framework: the SDK calls it "just a built-in set of features". See [`reactor.md`](./reactor.md).
- **Built-in persistent Storage** — a NoSQL object database, no dependency.
- **`__FILE__`, `__DIR__`, `__FUNC__`, `__LINE__`** as predefined constants.
- **UI data types and units** — a length literal is a first-class value.

### The DOM is W3C-shaped with simplifications

```js
document.$("#count").innerText = "0";          // querySelector
document.$$("li.item").forEach(el => ...);     // querySelectorAll, returns a real array
document.on("click", "button#ok", evt => ...); // delegated handler, selector filter built in
el.classList.add("busy");
el.state.disabled = true;                       // Sciter: the CSS state bits, scriptable
el.value                                        // typed by the behavior attached to the element
```

`document.$()` and `$$()` are the everyday accessors. `on(event, selector, handler)` with an optional
selector is the Sciter idiom for delegation, and `off()` removes it. `Element`, `Node`, `Text`,
`Comment`, `Range`, `NodeIterator` and `Event` are all present.

The **document lifecycle** events are worth knowing since scripts commonly hang off them:

```js
document.on("ready", () => { /* DOM parsed, styles applied */ });
```

### Keyboard events: `code`, not `key`, and only with focus

Two measured differences, and together they make a page's shortcuts look unimplemented:

- **The event carries `code`, not `key`.** A browser fills in both (`key: "ArrowRight"`, `code:
  "ArrowRight"`; `key: "n"`, `code: "KeyN"`); this engine leaves `key` undefined. A handler written as
  `if (e.key === "ArrowRight")` therefore never fires here. `code` is the PHYSICAL key, so a letter arrives
  as `KeyN` rather than as whatever the layout would type:

```js
function keyOf(e) {
   if (e.key) return e.key;                    // browsers
   var code = e.code || "";                    // Sciter fills this one in
   if (code.length === 4 && code.slice(0, 3) === "Key") return code.charAt(3).toLowerCase();
   return code;                                // "ArrowLeft", "Escape", …
}
```

- **A key only reaches a document once something IN it holds the focus.** For a document in a `<frame>`,
  focusing the frame element is not enough — focus an element inside the sub-document (its `<body>` is the
  least surprising choice, and is what a click on the page background would focus):

```odin
// after loadHtml/loadFile: frame.document -> element_from_value -> its body
if body, err := sciter_app.select_first(framed_root, "body"); err == nil {
    sciter_app.set_focus(body)
}
```

**And the key CODES are the engine's own**, from the SDK's `include/sciter-x-key-codes.h` — GLFW-style
values, not platform virtual keys: `KB_RIGHT = 262`, `KB_LEFT = 263`. Sending a Windows `VK_RIGHT` (39) to
`windowless_key` arrives in the document as the `Quote` key, which is a puzzling ten minutes. That header is
not bound in this package.

### The standard library

Sciter's runtime is a small NodeJS-shaped set of modules, imported by name:

| Module | What |
| --- | --- |
| `@sciter` | `loadLibrary()`, `encode`/`decode`, `parseValue`, app-level odds and ends |
| `@sys` | `fs`, `spawn`, `pathes` — a subset of NodeJS |
| `@storage` | the persistent NoSQL store |
| `@env` | environment, paths, locale |
| `@debug` | logging and inspector hooks |

Plus globals: `console.log/warn/error`, `setTimeout`, `setInterval`, `fetch`, `URL`, `Clipboard`,
`Audio`, `Zip`, `BJSON`, `Intl`.

**What is not there**: the DOM APIs a browser needs and a desktop UI does not. No service workers, no
IndexedDB, no `history` beyond a behavior, no WebRTC, no `localStorage` (use `@storage`). WebGL exists
but is a separate concern (`samples.webgl` in the SDK).

## URL schemes

The engine resolves these, and the host callback sees every one of them before the engine acts (see
[`resources.md`](./resources.md)):

| Scheme | Meaning |
| --- | --- |
| `http://`, `https://` | platform HTTP client — libcurl on Linux, WinINET on Windows, CoreNetwork on macOS |
| `file://` | local filesystem, via memory-mapped reads |
| `data://` | standard inline data URIs |
| `home://` | relative to the location of `libsciter.so` / the executable |
| `sciter:` | resources inside the engine — `sciter:ux-master.css`, `sciter:msgbox.htm` |
| `path:`, `icon:` | vector images in CSS |
| `this://app/` | **a host convention, not an engine feature** — an archive, served by your callback |

`this://app/` matters here: nothing in the engine implements it. The SDK's C++ host callback serves it
out of a `packfolder` archive, and `sciter_app.serve_archive` does the same thing in Odin. Documents
written for Sciter expect it, so matching the convention keeps them portable.

## Security defaults

Script gets **no file access and no socket access** unless the host grants them:

```odin
sciter_app.set_script_features({.FILE_IO, .SOCKET_IO, .EVAL, .SYSINFO})
```

Call it before creating the window. A document that suddenly cannot `fetch` or read a file is usually
this and not a bug.

## Debugging a document

1. **Install the debug output.** `sciter_app.set_default_debug_output()` routes CSS warnings, script
   exceptions and `console.log` to stderr. Without it they are silent.
2. **Use the inspector.** Create the window with `.ENABLE_DEBUG`, then run the SDK's `inspector` tool —
   a DevTools-style element inspector, style viewer and console, over a socket.
   [`examples/inspector.odin`](../examples/inspector.odin) does the setup.
3. **Check `sciter:ux-master.css`** when an element looks wrong before you have styled it.
4. **`console.reportException`** can be overridden to route unhandled exceptions somewhere visible.

## Porting a browser UI: the realistic checklist

- [ ] keep (or add) the `<meta charset="utf-8">` — a document built as a string has nothing to sniff, and
      without it non-ASCII text is decoded with the system codepage, silently
- [ ] replace `display:flex` / `display:grid` with `flow:` and flex units
- [ ] replace `gap` with margins on the children — it is silently ignored, unlike `display`
- [ ] replace `clamp()`/`min()`/`max()` with a single term (`vw`/`vh` work, and in `font-size` too), `calc()`,
      `%`, `em`/`rem`, flex units, or `@media` on `width`
- [ ] **write the control states you were getting for free** — `:hover` above all, plus `:active`,
      `:focus` and `:disabled`, and put `appearance: none` first. A framework's stylesheet carried these;
      nothing here does, and painting a control deletes the engine's own (see
      [Styling controls](#styling-controls-and-the-states-you-inherit))
- [ ] give any element you made clickable a `behavior:` — a styled `<div>` raises no click event
- [ ] replace any framework build step — React, Vue, bundlers — with Reactor and native JSX, or drop to
      plain DOM calls
- [ ] replace `localStorage` / IndexedDB with `@storage`
- [ ] replace `fetch` of local files with `@sys.fs`, and grant the feature bits
- [ ] **check the stylesheet's size**: over 32 KiB and the rest of it is silently dropped (see
      [A stylesheet is capped at 32 KiB](#a-stylesheet-is-capped-at-32-kib-and-the-rest-is-dropped-in-silence)) —
      strip CSS comments when emitting, and assert the byte count
- [ ] replace `e.key` with a `code` fallback, and give the document's `<body>` the focus, or no keyboard
      shortcut in it will ever fire
- [ ] **park what is off screen with `display: none`** — layout cost scales with everything in the layout,
      and `visibility: hidden` does not help (see
      [Making a big document cheap](#making-a-big-document-cheap-layout-is-the-cost-and-display-none-is-the-switch))
- [ ] **check every `transform`**: `translate(x, y)` not `translateX(x)`, and `style.setProperty("transform", …)`
      not `style.transform = …` — either mistake is silent and leaves the element where layout put it (see
      [Animation](#animation-what-moves-and-the-two-ways-a-transform-is-silently-ignored))
- [ ] don't assert a transform with a box — it is paint-time, so `getBoundingClientRect` and `location`
      report the untransformed rectangle; read pixels instead
- [ ] replace `getBoundingClientRect()` with `element.state.box("xywh", "border", "view")`
- [ ] check every third-party JS dependency: no npm, no `require`, ES modules only, and no browser
      globals
- [ ] re-check custom scrollbars, `<select>` styling and focus rings — Sciter's are native behaviors
      and style differently, usually more easily

A UI built for Sciter from the start is markedly less work than one ported from a browser, and the
result is a fraction of the size of the Electron equivalent. That is the trade the engine is making.
