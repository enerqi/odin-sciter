# The SDK's own documentation and samples: what is where

Everything in this repository is about the HOST API. Sciter's own documentation is about the other side —
the document, its CSS, its script — and there is a lot of it: **128 markdown pages** under
`sciter-js-sdk/docs/md` and roughly **480 runnable `.htm` samples** across a dozen `samples.*` directories.
None of it is vendored here (`lib/` carries the engine and nothing else), and none of it mentions the host
API. That is why the other guides here keep saying "script-side only".

It is still where a host author has to go for half the answers, and it is not navigable by guessing. This
page is the index: which page answers which question, which sample demonstrates it, and the handful of
facts in there that changed what this repository says.

The same pages are rendered at [docs.sciter.com](https://docs.sciter.com/docs/intro), and the local copy is
what you have in an SDK checkout — see [`UPGRADING.md`](./UPGRADING.md) for where that checkout comes from.

---

## Facts from these pages that a host author needs

Four of them are corrections to what looks obvious, and each one was rediscovered here by measurement
before anybody read the page it was on. Read this section before the map.

**Media queries are NOT W3C syntax.** `docs/md/css/media-const-mixin.md` says so outright:

```css
@media screen and (max-width: 600px) { … }   /* W3C — a syntax error in Sciter */
@media screen and (width < 600px)    { … }   /* Sciter */
```

This matters more than a dialect difference, because a CSS syntax error takes the REST of the stylesheet
with it (measured — [`html-css-js.md`](./html-css-js.md)). A ported page whose phone query is the W3C form
loses every rule after it, silently. Either write the Sciter form or keep such a block last.

**`calc()` is supported**, with one restriction: flex units (`*`) cannot appear inside it
(`docs/md/css/units/dimentional.md`). `min()`, `max()` and `clamp()` are not — so `calc()` is the escape
hatch when a value has to be computed.

**The unit list is longer than you would guess**: `em`, `rem`, `ex`, `ch`, `%`, `vw`, `vh`, `vmin`, `vmax`,
plus Sciter's own `width(X%)` and `height(Y%)` — a percentage of the element's own width or height, which is
how `line-height: height(100%)` is expressed. Flex units (`*`) are a separate mechanism, documented in
`docs/md/css/flows-and-flexes.md`.

**But a documented unit is not valid everywhere.** Measured on 6.0.4.9 against that list: `vh` resolves in
`max-height` and does NOT resolve in `font-size` — the computed value comes back empty and the element falls
back to sizing by content. The page documents the unit, not the properties it works in.

**Key codes are the engine's own**, in `include/sciter-x-key-codes.h` rather than in the docs: GLFW-style
values (`KB_RIGHT = 262`, `KB_LEFT = 263`), not platform virtual keys. Nothing in this repository binds that
header, so a `windowless_key` caller passing a Windows `VK_RIGHT` (39) sees the document report the `Quote`
key. The event side of it is in [`html-css-js.md`](./html-css-js.md): the engine fills in `event.code`, not
`event.key`.

---

## The map: docs/md

### CSS — the section a porting author lives in

| page | what it settles |
| --- | --- |
| `css/properties.md` | **the supported-property list**, grouped. The authority on whether a property exists at all — though not on which values it accepts |
| `css/flows-and-flexes.md` | `flow:` and flex units, with a **side-by-side against flexbox** and per-flow diagrams (`horizontal`, `horizontal-wrap`, `vertical`, `vertical-wrap`, `grid`, `table`, `stack`). The page to read before rewriting a flexbox layout |
| `css/units/dimentional.md` | every length unit, `calc()`, flexes, and Sciter's `width(X%)`/`height(Y%)` |
| `css/units/color.md` | colour syntaxes |
| `css/media-const-mixin.md` | `@media` (and its non-W3C query syntax), `@const`, `@mixin` including parametric ones |
| `css/conditionals.md` | `@supports`, and Sciter's own `@if`/`@else` in CSS |
| `css/style-sets.md` | `@set` / `style-set:` — encapsulated styling for a component subtree |
| `css/behaviors-and-aspects.md` | `behavior:` and `aspect:` — attaching a native controller, or script, from CSS |
| `css/selectors.md` | the selector dialect, including what CSS3 it does and does not carry |
| `css/variables-and-attributes.md` | both variable syntaxes (`--name`/`var(--name)` and Sciter's `var(name):`/`var(name)`), and attribute-driven styling |
| `css/marker-and-shadow.md`, `css/image-map.md`, `css/paths-and-vector-images.md` | markers, sprite maps, and vector images in CSS (`url(path: …)`, the `icon:` scheme) |
| `css/scroll-bar-styling.md` | one line: `TBD`. The samples are the documentation (`samples.sciter/note.css`, the themes) |
| `css/demo/` | runnable demo pages, `flow-vs-flexbox.htm` among them |

### DOM and HTML — what script can do to a document

| page | what it settles |
| --- | --- |
| `DOM/Element/README.md` | the Element API. Also where the **animation hooks** are documented: `morphContent(step, {duration, ease})` with ~25 named easings, `replaceContent(jsx, {effect})` with named slide/blend effects, and `takeOff()` for out-of-window elements |
| `DOM/Element/State.md` | `element.state` — the CSS state bits as script sees them, and `state.box(...)`, which is the box model reader |
| `DOM/Element/Style.md` | `style.setProperty`, `style.variables({…})` — the documented way to drive CSS from script |
| `DOM/Element/Selection.md` | selection inside an element |
| `DOM/Event.md` | the event objects, their fields and phases |
| `DOM/Globals.md` | `requestAnimationFrame`, `setTimeout`/`setInterval`, and the rest of the global surface |
| `DOM/Window.md` | `Window.this` — the object behind file dialogs, modal dialogs, the tray icon and window state, none of which the host API reaches |
| `DOM/Document/life-cycle.md` | the document's own load/unload events, which is what script hangs initialisation off |
| `DOM/out-of-canvas-elements.md` | tooltips (static, dynamic, styled), context `<menu>`s, popups and their life cycle |
| `DOM/CSS.md`, `DOM/Components.md`, `DOM/Node/*` | stylesheet objects, custom elements, and the node types (`Text`, `Comment`, `Range`, `NodeIterator`, `NodeList`) |
| `HTML/html-elements.md`, `HTML/html-inputs.md` | the tags and input types the engine adds or omits |
| `HTML/html-window.md` | **the window expressed as HTML**: root attributes that decide window type, frame, and behaviour |
| `HTML/html-include.md` | `<include>` — server-side-style composition, no build step |

### behaviors/ — one page per intrinsic control

`behaviors/README.md` plus 30 pages, one for each: `button`, `check`, `radio`, `edit`, `masked-edit`,
`textarea`, `plaintext`, `htmlarea`, `select`, `select-dropdown`, `slider`, `scrollbar`, `calendar`, `date`,
`time`, `integer`, `decimal`, `number`, `password`, `progress`, `form`, `frame`, `frame-set`, `history`,
`pager`, `menu`, `menu-bar`, `details`, `expandable-list`, `selectable`, `selection`, `clickable`,
`hyperlink`, `label`, `output`, `lottie`, `terminal`, `video`, `virtual-list`.

[`BEHAVIORS.md`](./BEHAVIORS.md) measures what a HOST can reach on each of them — the asset, its properties
and methods, and whether `do_click` does anything. These pages are the other half: what the behavior is for,
what markup it wants, and its script-side interface.

### JS.runtime/ and JS/ — the runtime script gets

One page per global and per module: `Asset`, `Audio`, `BJSON`, `Clipboard`, `Fetch`, `Intl-i18n`, `URL`,
`Zip`, and the modules `@sciter`, `@sys`, `@env`, `@debug`, `@markdown`, `@yaml`. `JS/units/*` documents the
first-class UI types (`Length`, `Angle`, `Duration`). [`JS-RUNTIME.md`](./JS-RUNTIME.md) is the host-author
view of the same surface: which of it to use and which to do in Odin instead.

### The rest

`graphics/*` (nine pages: `Brush`, `Color`, `Image`, `Path`, `Point`, `Rect`, `Size`, `Text`) is the
script-side mirror of [`graphics.md`](./graphics.md). `reactor/*` (twelve pages) is Sciter's own JSX +
`patch()` framework — summarised in [`reactor.md`](./reactor.md). `storage/*` is the `@storage` NoSQL store,
including its architecture. `scapp/README.md` documents the SDK's own scriptable application shell, which is
the thing this repository replaces. `URL-sciter-schemes.md` lists `sciter:`, `home:`, `this://app/` and
friends — see [`resources.md`](./resources.md) for serving them from Odin.

---

## The map: samples

Roughly 480 `.htm` files. The ones worth knowing about, by the question they answer:

| looking for | sample |
| --- | --- |
| flow vs flexbox, side by side | `docs/md/css/demo/flow-vs-flexbox.htm`, `samples.css/css++/` |
| a script-driven animation | `samples.sciter/effects/animated-steps.htm` (`morphContent` + `paintForeground`), `animated-content-change.htm` (`replaceContent` effects), `focus-animator.js` (animating a paint over a focus move) |
| a transform driven from script | `samples.sciter/gestures/zoom-rotation.htm` — `transform: rotate(var(rotation)) scale(var(zoom))` updated through `style.variables({…})` |
| a document inside a document | `samples.sciter/frame/`, `frame-host/`, `frameset/` |
| printing to a PDF or a printer | `samples.sciter/printing/` (`behavior:pager`) |
| syntax highlighting in an editor | `samples.sciter/colorizer/`, `editor-plaintext/`, `code-beautifier/` |
| a long list that stays fast | `samples.sciter/virtual-list/` |
| themes to crib control states from | `samples.sciter/themes/` (windows-flat, android-material, …) |
| tooltips beyond `title=` | `samples.sciter/tooltips++/` |
| menus, popups, dialogs, toasts | `samples.sciter/menu/`, `popup/`, `msgbox+dialog/`, `lightbox-dialog/`, `toast-notification/` |
| the tray icon, splash, window chrome | `samples.sciter/tray-icon/`, `splash/`, `window/` (including `chrome-types/`) |
| drag and drop, inside and from the OS | `samples.sciter/drag-n-drop/`, `drag-n-drop-system/` |
| tables, forms, input styling | `samples.sciter/tables/`, `forms/`, `input-elements/`, `input-elements-styling/`, `@inputs/` |
| custom painting, immediate mode | `samples.sciter/graphics/`, `immediate-mode-painting/`, `image-generation-painting/` |
| a native behavior written in C++ | `samples.sciter/native-behaviors/`, `native-access/` |
| testing a document | `samples.sciter/unit-test/` |
| Reactor, components, i18n | `samples.reactor/`, `samples.sciter/components/`, `i18n/`, `i18n-reactor/` |
| the storage API | `samples.storage/`, `samples.sys/` |
| charts, markdown, YAML, barcodes, WebGL | `samples.charts/`, `samples.md/`, `samples.yaml/`, `samples.barcode/`, `samples.webgl/` |
| a whole application | `samples.sciter/applications.quark/`, `demos/` |
| ready-made widgets | `widgets/` — twelve of them |

`demos/` is the C++ host side, and [`SDK-PARITY.md`](./SDK-PARITY.md) maps each demo to the example here
that covers the same ground.

---

## Using them

- **They are script, not Odin.** A sample shows what the document can do; getting the same result from the
  host is this repository's job, and where the two differ [`SDK-PARITY.md`](./SDK-PARITY.md) says which.
- **Run them with the SDK's own `usciter`** (`bin/windows/x64/usciter.exe` and friends), which is a browser
  for local documents. `scapp` runs a folder as an application.
- **The docs describe the engine, not this version of it.** Every measurement in these guides was made
  against the vendored 6.0.4.9, and where a page and a measurement disagree, the measurement wins and says
  so — the media-query syntax and the transform spellings in [`html-css-js.md`](./html-css-js.md) are of
  that kind. `vh` in a `font-size` was cited here as another, and it was the other way round: the SDK page
  listing the unit was right, the measurement against it was a stylesheet silently truncated at 32 KiB. A
  measurement beats a page about what the engine DOES; it does not beat one about what the engine SUPPORTS
  until its own diagnosis holds up.
