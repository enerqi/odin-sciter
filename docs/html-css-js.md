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
| Missing | `display:flexbox`, `display:grid`, `gap`, `vw`/`vh`, `clamp()`, WebGL-by-default, service workers, IndexedDB, most of the modern web platform API surface — **and any component library**, see [Styling controls](#styling-controls-and-the-states-you-inherit) |
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

With those two right, the declared `transition` animates the move — no script-side tween needed. What does
NOT animate is a layout property: a `transition: margin-left` reads back as an empty computed `transition`
and the element jumps to its final position in a frame or two. If a fallback has to move something by
layout (a margin, `left`), expect a jump and drive it yourself.

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

### Units

Sciter's default length unit is `ppx` — physical pixels, DPI-aware. `px` is accepted and treated as a
device-independent pixel. `dip`, `em`, `rem`, `%`, `mm`, `in`, `pt`, `sp` all work, and `*` is the flex
unit above. `docs/md/css/units/` covers the details.

**`vw`, `vh` and `clamp()` are NOT among them**, which is worth stating rather than leaving to the list
above, because the fluid-type idiom every recent browser stylesheet is full of —
`font-size: clamp(1rem, 2.6vw, 1.6rem)` — is three unsupported things in one declaration. Percentages,
`em`/`rem` and the flex unit cover the same ground here; a window that has to respond at breakpoints uses
`@media` on `width`.

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
- [ ] replace `vw`/`vh`/`clamp()` with `%`, `em`/`rem`, flex units, or `@media` on `width`
- [ ] **write the control states you were getting for free** — `:hover` above all, plus `:active`,
      `:focus` and `:disabled`, and put `appearance: none` first. A framework's stylesheet carried these;
      nothing here does, and painting a control deletes the engine's own (see
      [Styling controls](#styling-controls-and-the-states-you-inherit))
- [ ] give any element you made clickable a `behavior:` — a styled `<div>` raises no click event
- [ ] replace any framework build step — React, Vue, bundlers — with Reactor and native JSX, or drop to
      plain DOM calls
- [ ] replace `localStorage` / IndexedDB with `@storage`
- [ ] replace `fetch` of local files with `@sys.fs`, and grant the feature bits
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
