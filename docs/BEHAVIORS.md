# The intrinsic behaviors, from Odin

What the engine's own widgets expose to a *host*, measured rather than read off the SDK's docs. This is
stage 1 of [`SDK-PARITY.md`](./SDK-PARITY.md#stage-1--the-intrinsic-behaviors-sweep), and the answer to
its opening probe.

`docs/md/behaviors` in the SDK documents 39 behaviors and describes their methods as script members —
`element.edit.selectRange(0, 4)`. Nothing upstream says whether a host can reach them. It can: **most
of them publish a SOM asset, and a passport with real properties and callable methods behind it.**

*Asset*, *passport* and *SOM* are Sciter's words, defined together in
[`architecture.md`](./architecture.md#the-vocabulary) if this is the first page you have opened.

Everything below came from one probe document holding one element per behavior, loaded into a
windowless view, with every behavior name tried as an asset interface name against every element — so
the mapping is measured, not guessed. Signatures were cross-checked against the engine binary's own
symbols (`nm -DC lib/linux/x64/libsciter.so | grep member_function`), per
[`RESEARCH-METHOD.md`](./RESEARCH-METHOD.md).

Engine: 6.0.4.9, Linux x64.

---

## The four doors

An element with an intrinsic behavior can be driven four ways, and they are not interchangeable:

| Door | Call | What it reaches |
| --- | --- | --- |
| **What is it** | `control_type` | the engine's own name for the behavior — `.EDIT`, `.DD_SELECT`, `.SCROLLBAR` |
| **Click it** | `do_click` | the behavior's activation path: a real click, not an injected event code |
| **Its native interface** | `element_asset` + `asset_get` / `asset_set` / `asset_call` | the properties and methods the behavior publishes — the largest surface, and the one this document maps |
| **The DOM** | `set_attribute`, `set_state`, `element_value`, `set_element_value` | everything a behavior configures itself from |

The asset door is the interesting one and was the unknown. `behavior.odin` only ever proved the
`SciterCallBehaviorMethod` door, whose method IDs are a fixed set (`DO_CLICK`, `GET_VALUE`, `SET_VALUE`,
`IS_EMPTY`) — and of those, **only `DO_CLICK` is implemented by any intrinsic behavior on Sciter 6**.
The per-behavior surface is not there. It is in the passports.

```odin
asset, _ := sciter_app.element_asset(input, "edit")     // interface name, not tag name
mode, _  := sciter_app.asset_get(asset, "selectionEnd") // a property
n        := sciter_app.value_from_string("hello")
_, _      = sciter_app.asset_call(asset, "insertText", {n})
```

## Read this before calling anything: arity is not optional

**The engine's SOM thunks read their arguments positionally and never check `argc`.** Calling a method
declared with one parameter with none faults inside `sciter::om::member_function<…>::thunk` — a
segfault in the engine, before any Odin code runs again. Measured on `edit.insertText`,
`select.showPopup` and `terminal.read`; the backtrace names the thunk directly.

`asset_call` therefore refuses the call rather than making it: fewer arguments than the passport's
`params` is `.Wrong_Arity`. Passing *more* is harmless — the extras are ignored — so when in doubt,
over-supply. `asset_method_arity` asks up front:

```odin
arity, ok := sciter_app.asset_method_arity(asset, "showPopup")   // 1, true
```

The arity is in the tables below as `name/N`. The guard can be waived with `check_arity = false`, and
the only asset for which that is reasonable is one you made yourself with `make_asset_class` — its
thunk is this package's own and tolerates a short call. Never waive it for an asset out of
`element_asset`.

## What the passport name is

The interface name is the *behavior* name, not the tag name: an `<input type=password>` answers to
`"edit"`, a `<select>` to `"select"`, a `<div>` with `behavior:virtual-list` to `"vlist"`. For these
intrinsic behaviors the passport name is also the name script uses (`element.edit.…`), which is *not* a
general rule — `<video>`'s asset publishes `renderingSite`, which script cannot see at all.

## The table

`=` marks a writable property; everything else is read-only, and `asset_set` on it answers
`.Not_Found`. `name/N` is a method and its required argument count.

### Behaviors with a native interface

| Behavior | Element that carries it | `control_type` | Interface | Properties | Methods |
| --- | --- | --- | --- | --- | --- |
| `edit` | `<input type=text>`, `<input type=password>` | `.EDIT`, `.PASSWORD` | `edit` | `selectionStart` `selectionEnd` `selectionText` `isStandalone=` | `selectAll/0` `selectRange/2` `removeText/0` `insertText/1` `appendText/1` |
| `masked-edit` | `<input type=masked>` | `.EDIT` | `masked` | `groupsCount` `currentGroup=` `mask=` `value=` | `selectAll/0` `selectGroup/1` `setGroupValue/2` `getGroupValue/1` `groupType/1` |
| `textarea` | `<textarea>` | `.TEXTAREA` | `textarea` | `selectionStart` `selectionEnd` `selectionText` | `selectAll/0` `selectRange/2` `removeText/0` `insertText/1` `appendText/1` |
| `plaintext` | `<plaintext>` | `.PLAINTEXT` | `plaintext` | `content=` `lines` `selectionStart` `selectionEnd` `selectionText` `isModified` | `selectAll/0` `selectRange/4` `insertLine/2` `removeLine/2` `appendLine/1` `load/1` `save/1` `update/2` |
| `htmlarea` | `<htmlarea>` | `.HTMLAREA` | `htmlarea` | `url=` `isModified` `body` `document` | `load/2` `loadEmpty/0` `contentToSource/0` `sourceToContent/4` `contentToBytes/0` `bytesToContent/2` `save/1` `update/2` |
| `select` | `<select size=N>`, `<select\|list>`, `<select\|tree>` | `.SELECT_SINGLE`, `.SELECT_TREE` | `select` | `options` `currentOption=` | `optionByValue/1` |
| `select-dropdown` | `<select>` | `.DD_SELECT` | `select` | `options` | `showPopup/1` `hidePopup/0` |
| `calendar` | `<input type=calendar>` | `.DATE` | `calendar` | `mode=` | `stepUp/1` `stepDown/1` |
| `slider` | `<input type=hslider>` | `.SLIDER` | `slider` | `min=` `max=` `step=` | — |
| `scrollbar` | `<widget\|vscrollbar>`, `<widget\|hscrollbar>` | `.SCROLLBAR` | `scrollbar` | `position=` `overscroll=` `min` `max` `page` `step` | `values/5` |
| `form` | `<form>` | `.FORM` | `form` | — | `reset/0` `submit/0` |
| `frame` | `<frame>`, `<iframe>` | `.FRAME` | `frame` | `mediaVars=` `url=` `debugMode=` `document` | `loadHtml/2` `loadFile/1` `loadEmpty/0` `saveFile/1` `saveBytes/0` |
| `frame-set` | `<frameset cols=…>` | `.FRAMESET` | `frameset` | `state=` | — |
| `history` | `<frame history>` | `.FRAME` | `history` | `length` `forwardLength` | `back/0` `forward/0` `go/1` |
| `pager` | `<frame type=pager>` | `.FRAME` | `pager` | `pages` `page=` `rows=` `columns=` `document` `templateDocument` `pageWidth` `pageHeight` `pageSize=` | `loadFile/2` `loadHtml/3` `savePDF/2` |
| `virtual-list` | CSS `behavior:virtual-list` | `.LIST` | `vlist` | `firstVisibleItem` `lastVisibleItem` `firstVisibleItemIndex` `lastVisibleItemIndex` `firstBufferIndex` `lastBufferIndex` `itemsBefore=` `itemsAfter=` `itemsTotal` `slidingWindowSize=` | `navigate/2` `navigateTo/2` `advanceTo/1` `scrollBy/1` |
| `lottie` | `<lottie>` | `.IMAGE` | `lottie` | `speed=` `loop=` `forward=` `playing` `duration` `markers` `frame=` `frames` `position=` | `load/1` `play/2` `stop/0` `update/3` |
| `terminal` | `<terminal>` | `.PLAINTEXT` | `terminal` | `rows` `columns` `caretRow` `caretColumn` | `write/1` `read/3` `resize/2` `clear/0` `moveCaret/2` |
| `video` | `<video>` | — | `video` | not measurable here | not measurable here |

**`frame` is the other one worth calling out.** `loadHtml` / `loadFile` put a document into a
`<frame>` from Odin, and the `document` property comes back as a Value that `element_from_value`
unwraps into the framed document's `<html>` element — so the host can `select_first` and `set_text`
inside a sub-document it loaded. Selectors do not cross the boundary in the other direction: from the
outer document's root, an id inside the frame is `.Not_Found`.

**`pager` is the surprise in that table.** `SDK-PARITY.md` lists printing among the capabilities with
no host API, and as a *dialog* that is still true — but the pager behavior's asset is host-callable, and
`loadHtml` followed by `savePDF` produced a real 1-page PDF **from Odin, with no window and no script
involved**. Two argument shapes to know, both measured: `loadHtml(html, baseUrl, name)` treats a
non-empty `name` as a file to open (pass `""`), and `savePDF` takes an *options map* first —
`{filePath:"…"}` — not a path string.

`video` is the one row that could not be measured: `behavior:video` needs libVLC at runtime and fails
silently without it, leaving the element at `control_type` `.NO` with no asset. Its interface is real —
`video.odin` drives `renderingSite` through the C++ vtable — see [`ENGINE.md`](./ENGINE.md).

### Behaviors with no native interface

Nothing to call. Everything they do is markup, CSS, DOM state and events — which for most of them is
the whole point.

| Behavior | Element | `control_type` | `do_click` | Drive it with |
| --- | --- | --- | --- | --- |
| `button` | `<button>`, `<input type=button>` | `.BUTTON` | **yes** | `do_click`, `.BUTTON_CLICK` |
| `clickable` | CSS `behavior:clickable` | `.CLICKABLE` | **yes** | `do_click` |
| `hyperlink` | `<a href>` | `.HYPERLINK` | **yes** | `do_click` navigates |
| `check` | `<input type=checkbox>` | `.CHECKBOX` | **yes** | `do_click` toggles `:checked` |
| `radio` | `<input type=radio>` | `.RADIO` | **yes** | `do_click` |
| `details` | `<details>` | `.LIST` | **yes** | `do_click` toggles `:expanded` |
| `selectable` | `<section selectable>` | `.HTML_SELECTION` | **yes** | DOM selection, script `Clipboard` |
| `label` | `<label>` | `.LABEL` | no | attributes |
| `output` | `<output>` | `.LABEL` | no | `set_element_value` |
| `progress` | `<progress>`, `<meter>` | `.PROGRESS` | no | `set_element_value`, `max`/`value` attributes |
| `integer`, `decimal`, `number` | `<input type=integer\|decimal\|number>` | `.NUMERIC` | no | `element_value`; the inner `<caption>` carries `edit` |
| `date`, `time` | `<input type=date\|time>` | `.DATE`, `.TIME` | no | `element_value`; the inner `<caption>` carries `masked` |
| `menu` | `<menu class=popup>` | `.MENU` | no | `show_popup` / `show_popup_at` |
| `menu-bar` | CSS `behavior:menu-bar` | `.MENUBAR` | no | DOM and events |
| `expandable-list` | CSS `behavior:expandable-list` | `.LIST` | no | DOM and `:expanded` |
| `selection` | CSS `behavior:selection` | `.NO` | no | script only |
| `frame-set` splitters | — | — | — | `frameset.state` above |

Two traps in that table worth stating on their own:

- **The composite inputs delegate.** `<input type=date>` has no asset, but its generated `<caption>`
  sub-element is a full `masked` editor, and the numeric inputs' captions are full `edit`s. The route
  is `select_first(input, "caption")` and then `element_asset` on that. This matches what the SDK's
  behavior docs say the DOM model is, and it is the only case where the asset is not on the element you
  started from.
- **`behavior:scrollbar` in CSS does not attach.** A `<div>` styled `behavior:scrollbar` answers
  `control_type` `.NO`. The scrollbar behavior only appears on `<widget|vscrollbar>` /
  `<widget|hscrollbar>`, and both then carry the full `scrollbar` interface.

### Not a Sciter type

`<input type=range>` is HTML's slider and Sciter has no behavior for it — `control_type` `.NO`, no
asset, nothing happens. The Sciter spelling is `<input type=hslider>`.

**CSS `behavior: slider` on the HTML one is worse than nothing**, and this is the shape of the bug it
produces. The behavior *does* attach — `control_type` reads `.SLIDER`, so every check that asks the DOM
passes — but the widget then paints at its own intrinsic size inside whatever box the CSS gave it:
measured by sampling the painted row, **a 27px control in a 147px box**. The remaining 120px are invisible
and still live, so a click on what looks like blank page moves the value. Use the engine's own element.

### What a slider's geometry actually does

Measured on 6.0.4.9 with `<input type=hslider min=1 max=13>`, 147px wide:

- The engine walks the knob's **LEFT EDGE** from the track's left edge to its **RIGHT** edge, so at the
  top of the range the whole knob is *past* the track. A browser's range thumb instead has its *middle*
  travel between the ends.
- **Padding reserves no room for it** — `padding-right`, symmetric `padding`, and `box-sizing:
  border-box` all measured an identical overhang.
- **Clicks are mapped onto the input's own box**, so drawing the track on a wrapper of a different width
  (to give the knob somewhere to land) separates what the user aims at from what answers — visible as a
  control that responds where it is not drawn.

What works, if the default placement is not wanted: hide the engine's knob (inline `display: none`),
append your own as a **child of the input** — the input's flow is `stack`, so a `margin-left` places it
over the track without disturbing layout — and derive its offset from the input's box, which is the same
box the clicks use. `getBoundingClientRect` on the knob is stale within the call that moved it, so a
self-calibrating placement (`inset = knobLeft - trackLeft - lastAppliedMargin`) plus one deferred re-run
converges where a single computed offset does not.

## What `do_click` is worth

Eight of the behaviors answer a `do_click`: `button`, `clickable`, `hyperlink`, `check`, `radio`,
`details`, and the two editors that take focus from it (`plaintext`, `htmlarea`).
Everything else answers `handled = false`. In particular **`do_click` does not open a `<select>`** —
`select`'s `showPopup/1` does.

## Where this leaves the host

The practical shape: an application driven from Odin can *configure* any behavior through the DOM,
*activate* the button-shaped ones with `do_click`, and *operate* the eighteen above through their
passports — load a document into a frame, write to a terminal, scroll a virtual list to a record, drive
a lottie animation, print a pager to PDF, read and replace an editor's selection.

What still has no host route at all is the list in
[`SDK-PARITY.md`](./SDK-PARITY.md#capabilities-with-no-host-api-at-all) — clipboard, printing dialogs,
tray icon, file dialogs — and that is unchanged by this sweep. `menu` is the near miss: the behavior
has no interface, but `show_popup` places one, so a context menu *is* host-drivable.

## Reproducing this

The probe is not kept in the tree — it is a throwaway by design, per
[`RESEARCH-METHOD.md`](./RESEARCH-METHOD.md). The shape to rebuild it:

1. one document with one element per behavior, each with an `id`;
2. a windowless view, `load_html`, eight heartbeat-and-paint frames to let it settle;
3. for every element × every behavior name, `element_asset` and then `asset_members` /
   `asset_method_arity` on whatever answers;
4. run each *call* as its own process invocation, because an arity mistake takes the process down
   rather than returning.

Step 4 is what turned "the probe crashes" into "the engine does not check `argc`", which is the finding
that mattered most.
