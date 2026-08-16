# The DOM from Odin

Reading and changing the document without going through script. Everything here is
[`sciter_app/dom.odin`](../sciter_app/dom.odin); the runnable version is
[`examples/dom_walk.odin`](../examples/dom_walk.odin), which also carries 54 display-gated tests.

## Handles and lifetime

`Element` is a distinct `sciter.Helement` — a **borrowed pointer into the engine's document tree**. It
stays valid as long as the element is in the document. For anything you reach from `root` and use
immediately, or use inside one event handler, that is the whole time you are looking at it and there is
nothing to manage.

Holding a handle *longer* — across the message pump, in a struct that outlives the callback — needs a
reference:

```odin
sciter_app.use_element(el)
defer sciter_app.unuse_element(el)
```

Without it the handle becomes a dangling pointer the moment script removes the element, and the next
call through it returns `.PASSIVE_HANDLE` if you are lucky or faults if you are not. `Scdom_Result`
distinguishes the cases, which is why `Error` carries the engine's own code:

| Code | Means |
| --- | --- |
| `.INVALID_HANDLE` | not an element handle at all |
| `.PASSIVE_HANDLE` | a real element, but no `Sciter_UseElement` reference is held |
| `.INVALID_PARAMETER` | usually a nil pointer where one was required |
| `.OPERATION_FAILED` | the engine refused — e.g. invalid HTML in `set_html` |
| `.OK_NOT_HANDLED` | **not an error.** It is -1, and `!= .OK` is therefore not the test |

`dom_err` inside the package treats both `.OK` and `.OK_NOT_HANDLED` as success, so an `Error` you get
back is always a real failure.

## Getting in

Every traversal starts at the document element:

```odin
root, err := sciter_app.root(window)   // <html>
```

`root` is valid once a document is loaded. Right after `create_window` and before any `load_*` there is
nothing to get.

## Finding elements

CSS selectors, the same dialect the document's own CSS uses:

```odin
button, err := sciter_app.select_first(root, "button#ok")
if err != nil {return}                               // .Not_Found if nothing matched
```

```odin
items, err := sciter_app.select_all(root, "li.item")
if err != nil {return}
defer delete(items)                                  // the slice is yours; the handles are borrowed

for item in items {
	text, _ := sciter_app.text(item)
	defer delete(text)
	fmt.println(text)
}
```

Upwards is a separate call, and the one an event handler usually wants — given the thing that was
clicked, which row is it in:

```odin
row, err := sciter_app.select_parent(clicked, "tr")   // script's closest()
```

`select_parent` counts the element itself as the first candidate, so a selector the element matches
answers with the element. `depth` limits how far up to look and counts from there: the default 0 is
unlimited, 1 searches only the element, 2 adds its parent. One measured quirk — **`<html>` never
matches**, at any depth; `root(window)` is how to reach the document element.

`select_first` searches `element`'s subtree and returns `.Not_Found` rather than a nil handle, so the
error check is the existence check. `select_all` returns matches in document order; the slice is
allocated with the supplied allocator and is the caller's to `delete`, while the handles in it are
borrowed and are **not** `use_element`ed.

### By position

The other way to find an element is to point at it — hit testing, the question a mouse asks:

```odin
el, err := sciter_app.element_at(window, {x, y})     // .Not_Found off the document
```

The point is in the window's client area, which is the space `location(el, .Border, .View)` reports
and the space `show_popup_at` takes — so "put a context menu where the pointer is" is those two calls
back to back. What comes back is what a click would reach: the innermost element painted there, with
`z-index` and popups respected. Sciter 6 draws its own titlebar as part of the document, so a point
near the top of the window can legitimately answer `<window-caption>`. A window that has never been
shown still hit-tests, as long as its document has been laid out.

## Traversal

```odin
n, _      := sciter_app.child_count(el)
first, _  := sciter_app.child(el, 0)
up, err   := sciter_app.parent(el)      // .Not_Found at the root
name, _   := sciter_app.tag(el)         // "div", "button" - borrowed, valid for the element's life
i, _      := sciter_app.element_index(el)  // position among the parent's elements
```

`element_index` counts elements only — a text node in front of an element does not shift it — which is
the same numbering `child` and `insert_element` use. That numbering is a `Child_Index`, a `distinct int`,
and the node view's is a `Node_Index`: two counts of the same parent that do not agree, so the compiler
refuses to let one stand in for the other. Ranges, arithmetic and comparison work as on any integer —
`for i in 0 ..< child_count(el)` infers the type — and only mixing one with an unrelated `int` needs a
cast, which is exactly the boundary worth seeing.

These walk *elements*, which is what an application wants nearly all of the time. Text and comment
nodes are `Node`, a separate handle type with its own set of calls — see [Nodes](#nodes) below.

## Nodes

A document is really a tree of *nodes*: text and comments are nodes with no element around them.
Elements are the useful view almost always, and the node view is what you need for the rest — reading
the text around an inline `<b>` without flattening it, inserting text between two elements, or walking
the document exactly as written.

```odin
node, err := sciter_app.node_from_element(el)   // every element is a node
type, _  := sciter_app.node_type(node)          // .ELEMENT, .TEXT, .COMMENT

child, cerr := sciter_app.node_first_child(node)
if cerr == nil {
	content, _ := sciter_app.node_text(child)    // the text a .TEXT node carries
	defer delete(content)
}
```

Traversal is `node_first_child`, `node_last_child`, `node_next_sibling`, `node_prev_sibling`,
`node_child`, `node_child_count`, and `node_parent` — which returns an `Element`, since only an element
can contain nodes. Each returns `.Not_Found` at the end of the walk rather than a nil handle, so the
error is the loop's termination condition:

```odin
for child, err := sciter_app.node_first_child(node); err == nil; child, err = sciter_app.node_next_sibling(child) {
	// ...
}
```

`node_to_element` crosses back and fails with `.Not_Found` on a text or comment node — check
`node_type` first when the distinction matters more than the failure.

Creating and moving:

```odin
created, _ := sciter_app.make_text_node(" appended")   // an Owned_Node: owes one node_release
defer sciter_app.node_release(created)                 // owed whether or not it is inserted
target, _  := sciter_app.node_from_element(summary)
sciter_app.node_insert(target, .APPEND, created)       // .BEFORE .AFTER .APPEND .PREPEND
```

Three lifetime rules, the first two the C API's and the third measured here:

- **Node handles are not reference counted on the way out.** `sciter-x-dom.h` says so outright. A
  handle is valid while the node is in the document; holding one longer needs `node_add_ref` /
  `node_release`, which is `use_element` under a different name.
- **A node you made is an `Owned_Node`.** `make_text_node`, `make_comment_node` and `node_add_ref` are
  the only three sources of one, and `node_release` accepts nothing else — so releasing a node you
  merely walked to does not compile. It used to, and one such call is enough to segfault the process
  when the document is torn down.
- **Inserting does not hand the reference over.** The document takes its own; yours is still owed.
  Measured at +400 MB over 2000 inserted-and-never-released 100 kB nodes, against +200 kB when they are
  released. `node_remove(node, finalize = false)` detaches without destroying and without giving you
  anything to release — and the detached node can never be inserted again, so it is not half of a move.

## Text, HTML and attributes

```odin
t, err := sciter_app.text(el)                        // allocated in the given allocator
defer delete(t)
sciter_app.set_text(el, "42")

h, _ := sciter_app.html(el, outer = true)            // outer includes the element's own tag
defer delete(h)
sciter_app.set_html(el, "<b>bold</b>")               // replaces the children

v, _ := sciter_app.attribute(el, "href")             // "" when absent
defer delete(v)
sciter_app.set_attribute(el, "href", "https://…")
sciter_app.set_attribute(el, "href", "")             // "" removes it
```

`set_html` takes a `Set_Element_Html` position: `.SIH_REPLACE_CONTENT` (the default) replaces the
element's children, `.SOH_REPLACE` replaces the element itself, and there are insert-before/after and
prepend/append variants.

Everything that returns a string allocates into the allocator you pass — `text`, `html`, `attribute`
all take one, defaulting to `context.allocator`. Pass `context.temp_allocator` for scratch reads.
Element *tags* are the exception: `tag` returns a borrowed `string` over the engine's own storage, so
there is nothing to free.

### Enumerating attributes

`attribute` answers for a name you already know, and an absent attribute reads the same as an empty
one. To discover what is actually on an element, enumerate:

```odin
attrs, err := sciter_app.attributes(el, context.temp_allocator)   // markup order
defer sciter_app.delete_attributes(attrs, context.temp_allocator)
for a in attrs {
	fmt.printfln("%s = %q", a.name, a.value)
}
```

`attribute_count(el)` and `attribute_at(el, n)` are the same thing one at a time; an index past the end
is `.INVALID_PARAMETER` rather than an empty answer. `clear_attributes(el)` removes the lot, `class`
and `id` included — see the note in the next section about what that does *not* immediately change.

## Style

Inline style is a different store from the `style` attribute, and reading it is a different question
from reading markup:

```odin
c, _ := sciter_app.style(el, "color", context.temp_allocator)     // "#A6E3A1" — the used value
sciter_app.set_style(el, "color", "blue")                         // inline, beats the stylesheet
sciter_app.set_style(el, "color", "")                             // removes it again
```

Three things about that, all measured against the engine rather than taken from the header:

- **Reading gives the used value.** An element coloured only by a stylesheet still answers with a
  colour — resolved, as `#RRGGBB` — not with `""`. A property nothing set, and a property that does
  not exist, both read as `""`.
- **Writing does not touch the `style` attribute.** After `set_style(el, "color", "blue")`,
  `attribute(el, "style")` is unchanged. `set_attribute(el, "style", …)` is the other way in and it
  replaces everything.
- **The used value is stored, so it is only as fresh as the last cascade.** Writing an attribute re-runs
  the cascade; `clear_attributes` does not, and the old value keeps being reported until something
  forces the update — `update_element(el, render = true)` being the direct way.

An unknown property is accepted and ignored on the way in: the engine has no way to say "no such rule",
so a declaration that fails to apply is a matter for the inspector rather than for the error code.

## Focus

The focus is a property of the window — one element per window has it — and it *is* the `:focus` state,
which is why there is no `SciterSetFocus`:

```odin
sciter_app.set_focus(input)                          // == set_element_state(input, {.FOCUS})
who, err := sciter_app.focus_element(window)         // .Not_Found when nothing has it
```

There is no way to focus *nothing*: clearing `.FOCUS` stops the element matching the pseudo-class, but
`focus_element` keeps reporting it. Move the focus somewhere else instead.

`set_highlighted_element(window, el)` is the unrelated neighbour — the debug outline the SDK's inspector
draws, cleared with a nil element. It is an overlay and leaves no state on the element, so nothing in
the document can match on it.

## Popups

A popup is an element of the document shown **out of flow**, in a window of its own that may extend
past the main window's edge — a menu, a dropdown, a tooltip. It stays where it is in the tree; showing
it does not move it.

```odin
menu, _ := sciter_app.select_first(root, "#context-menu")
sciter_app.show_popup(menu, button, .Bottom)          // against an anchor
sciter_app.show_popup_at(menu, {x, y}, .Top_Left)     // at a point in window coordinates
sciter_app.hide_popup(menu)
```

`Popup_Placement` is named the way a numeric keypad is laid out, which is how the C API numbers it, and
the two calls read it differently: `show_popup` names the side of the *anchor* (`.Bottom` is below it),
while `show_popup_at` names the corner of the *popup* that lands on the point (`.Top_Left` is the usual
"where the mouse is").

Three things measured rather than assumed:

- **A popup wants a shown window.** On a window that has never been shown the calls report success and
  the element takes the `:popup` state, but the engine does not finish: the anchor never gains
  `:owns-popup` and `hide_popup` does not clear `:popup`.
- **`hide_popup` takes the popup**, or an element inside it — not the anchor. The anchor answers
  `.OK_NOT_HANDLED`, which is a success code, and leaves the popup up.
- **Both elements must be in a document.** A detached one is `.PASSIVE_HANDLE`, because it is the
  window that shows a popup.

For a menu that needs no Odin at all, CSS has `context-menu: selector(#menu)` — see
[`html-css-js.md`](./html-css-js.md#sciter-only-css-worth-knowing). This is for deciding what to show,
or where, in code.

### Redrawing

The engine tracks what is dirty, and everything in this package that writes to the DOM marks it. Three
calls exist for what it cannot know about:

```odin
sciter_app.update_element(el, render = true)   // re-run style and layout, repaint now
sciter_app.refresh_element_area(el, area)      // repaint a rectangle in the element's own coordinates
sciter_app.request_paint(el)                   // repaint all of it at the next frame
```

`update_element` is the heavy one and the only one that re-runs the cascade — the answer to a `style`
read that is stale after `clear_attributes`. The other two only mark pixels, which is what a `.DRAW`
handler that painted something needs. `update_window(window)` flushes the lot immediately, for a custom
message loop.

## Building and moving elements

`set_html` replaces a subtree with markup. This is the other way round — make the element, then put it
where it goes — which is what content coming from data wants, and the only way to *move* an element
rather than re-create it.

```odin
item, _ := sciter_app.make_element("li", "third")   // plain text, not parsed
defer sciter_app.unuse_element(item)                // yours, inserted or not
el := sciter_app.borrow_element(item)               // Owned_Element -> Element, a free cast
sciter_app.insert_element(el, list)                 // no index: appended
```

**`make_element` and `clone_element` hand back a reference that is yours, and inserting does not
consume it** — the document takes its own. An element that is created and never unused leaks inside
the engine, where Odin's allocator tracking cannot see it. `remove_element(el, finalize = false)`
hands back a reference the same way; see below.

```odin
sciter_app.insert_element(el, parent, 0)      // at the front; a nil index appends
sciter_app.insert_element(el, other_parent)   // a move — the engine disconnects it first
sciter_app.swap_elements(a, b)                // exchanges both indexes and parents
sciter_app.remove_element(el)                 // destroyed, behaviors and all
sciter_app.remove_element(el, finalize = false)   // detached and kept — see below
sciter_app.sort_children(list, by_length)     // in place, comparator runs before this returns
```

### What a detached element can do

An element that is not in a document is more limited than it looks, and each limit was measured:

- **`insert_element` works between two detached elements.** Assembling a subtree offline and inserting
  the outer element brings the whole thing in. This is the way to build.
- **`set_html` does not.** It needs a document and fails with `INVALID_HWND`. Insert first, then set
  the markup.
- **Its descendants are passive handles.** They read fine, but writing to one returns
  `PASSIVE_HANDLE`, and `use_element` does not change that — the element you hold a reference to is
  writable, the tree underneath it is not. Insert, then edit.

### Detaching without destroying

`remove_element(el, finalize = false)` takes the element out of the document and **takes a reference
for you**. That is a deliberate difference from the C API: a bare `SciterDetachElement` drops the last
reference to an element nobody else is holding, and the next use of the handle is a segfault rather
than an error code. Unuse it once it has been re-inserted, or to throw it away.

### Identity

`element_uid(el)` returns an `Element_Uid` - a `distinct u32`, opaque like `Atom` - that survives being
stored where a handle cannot go. Its partner
`element_by_uid(window, uid)` **does not work on the vendored 6.x engine** — every UID the engine
hands out is refused with `OPERATION_FAILED`, whichever window handle is used and whether or not the
element has been `use_element`ed. Treat UIDs as opaque labels for now, not as a way back to an element.

## State

Sciter's CSS pseudo-class bits are readable and writable from the host, which browsers do not offer:

```odin
state, _ := sciter_app.element_state(el)
if .HOVER in state {
	// ...
}

sciter_app.set_element_state(el, set = {.DISABLED}, clear = {.ACTIVE})
```

`Element_State_Bits` is a real `bit_set` — `STATE_LINK`, `STATE_HOVER`, `STATE_ACTIVE`,
`STATE_FOCUS`, `STATE_CHECKED`, `STATE_DISABLED` and the rest, with the `STATE_` prefix stripped.
Setting a bit triggers the matching CSS rule, which is how you drive `:disabled` styling from
application state rather than from a class.

The overload group `state(x)` / `set_state(x, …)` resolves to the element or the window version by
argument type — a window is shown or minimized, an element is hovered or checked, and the two are
named apart so either can be called directly.

## Values

`element_value` is script's `element.value`: the text of an `<input>`, the selection of a `<select>`,
the checked state of a checkbox. What it means is decided by the native behavior attached to the
element.

```odin
v, err := sciter_app.element_value(input)
defer sciter_app.value_clear(&v)                     // owns a reference
text, _ := sciter_app.value_to_string(&v)

nv := sciter_app.value_from("new text")
defer sciter_app.value_clear(&nv)                    // set_element_value does not consume it
sciter_app.set_element_value(input, &nv)
```

See [`calling-between-odin-and-js.md`](./calling-between-odin-and-js.md) for the `Value` rules.

### Elements as Values

That is an element's *value*. The other direction is putting the **element itself** into a `Value`, so
it can be an argument to script or a return value from Odin:

```odin
v, err := sciter_app.element_to_value(el)            // script sees a real Element
defer sciter_app.value_clear(&v)

back, _ := sciter_app.element_from_value(&v)         // and out again
```

To script, that Value is an `Element`: `instanceof Element` is true and `.tag`, `.id`, `.style` and the
rest all work. In the other direction, an element script hands to an Odin functor arrives as an
argument you unwrap:

```odin
on_pick :: proc(args: []sciter_app.Value, user_data: rawptr) -> sciter_app.Value {
	el, err := sciter_app.element_from_value(&args[0])
	if err != nil {                                  // a number, a string, a text node
		return sciter_app.value_from(false)
	}
	id, _ := sciter_app.attribute(el, "id", context.temp_allocator)
	...
}
```

Without this the only way to name an element across the boundary is its UID or a selector that finds it
again. Two rules:

- **The Value holds its own reference.** An element stays alive for as long as a Value wraps it, even
  after the `use_element` reference you had is given back.
- **The handle from `element_from_value` is borrowed**, on the same terms as every other handle here.
  `use_element` it if it has to outlive the Value.

A wrapped element reports its type as `.RESOURCE` and renders as `""`, so `value_to_display_string` is
no help in looking at one.

`node_to_value` / `node_from_value` are the node half, and they are the only way to hand script a text
or comment node. The two are not symmetric: an element *is* a node, so an element's Value unwraps
either way, while `element_from_value` on a text node's Value fails with `.OPERATION_FAILED`.

## Script, scoped to an element

```odin
r, err := sciter_app.eval_element(el, "this.innerText")            // `this` is the element
defer sciter_app.value_clear(&r)

r2, _ := sciter_app.call_method(el, "edit.setRange", a, b)         // a behavior's own method
defer sciter_app.value_clear(&r2)
```

`call_method` reaches behavior methods, which is the intended way to drive `<select>`, the editor
behaviors, and anything else with a native controller behind it.

## Geometry

Where layout put an element, and what its content wants. All of it reads the result of layout, so it
answers after the document has been laid out and not before.

```odin
box, _ := sciter_app.location(el)                        // .Border, .Root: the painted extent
size, _ := sciter_app.location(el, .Border, .Self)       // x, y are the insets; width, height the size
onscreen, _ := sciter_app.location(el, .Border, .View)   // relative to the window's client area
```

`Box` picks which box of the CSS box model to measure — `.Content`, `.Padding`, `.Border`, `.Margin`,
each containing the one before it, plus `.Background_Image`, `.Foreground_Image` and `.Scrollable`.
`Origin` picks what the coordinates are relative to. They are two fields of one flag word in the C
API, which is why they are two arguments here.

Scrolling an ancestor moves what `.Root` and `.View` report — they differ by a fixed offset, where the
root element sits in the window — and leaves `.Container` alone, because that one is measured from the
container's own content origin. `.Self` puts the content box at `(0, 0)`, so an outer box comes back
with negative `x`/`y`: that is how to read a padding or border width.

An element with no box — `display: none`, or not in the document — does not report zeros. It keeps
answering with the last rectangle it had, so this is never the way to ask whether an element is there:

```odin
shown, _ := sciter_app.visible(el)      // false for display:none, true for visibility:hidden
on, _ := sciter_app.enabled(el)         // :disabled, itself or inherited — a separate question
```

### Intrinsic sizes

What the content wants, as opposed to the layout it was given — CSS's `min-content` and `max-content`.
This is the measurement a container makes before deciding how much room to hand out.

```odin
min, max, _ := sciter_app.intrinsic_widths(el)   // narrowest wrap, and one line
tall, _ := sciter_app.intrinsic_height(el, min)  // narrower is taller
```

### Window metrics

```odin
dpi := sciter_app.ppi(window)                    // 96 is unscaled; dpi.x / 96 is the scale factor
narrowest := sciter_app.min_width(window)
```

`ppi` is only needed when talking to something that is not already in the engine's scaled pixels —
everything in this package, `location` and `element_at` included, already is.

`min_width` and `min_height` look like "how small may this window be", and they are not.
**Measured, on five documents: they return exactly `intrinsic_widths(root).min` and
`intrinsic_height(root, …)`.** Because `<html>` fills the view by default its min-content width is a
small constant — 16px against the vendored engine — however wide the content inside it is, so
`min_width` answers the same number for a 600px-wide child as for an empty body. They mean something
only when the root itself is sized by its content:

```css
html, body { width: max-content; height: max-content }   /* now min_width is the content's width */
```

with which a 500×250 child measured 516 and 296. `min_height` also **ignores its `for_width`
argument** — the same number comes back for 100, 400 and 800 — and both are only meaningful once
layout has run. To size a window to its document, ask `intrinsic_widths` / `intrinsic_height` of the
element that actually holds the content, usually `<body>`.

### Scrolling

```odin
info, _ := sciter_app.scroll_info(el)
// info.pos     - current offset
// info.view    - the visible window onto the content
// info.content - the full content size; the part beyond `view` is what scrolls

sciter_app.set_scroll_pos(el, {0, info.content.y})    // past the end is clamped, not refused
sciter_app.scroll_to_view(child, to_top = true)
```

`scroll_to_view` has two behaviours worth knowing, because both look like the call being ignored.
Measured against the vendored engine: **nothing moves until the window has been shown and rendered at
least once** — `set_scroll_pos` has no such requirement — and without `to_top` the scroll is applied on
the engine's own schedule, so reading the position straight back can still show the old one. With
`to_top` it has landed by the time the call returns.

## The element's script object

`call_method` and `eval_element` cross into script one call at a time. `expando` hands over the whole
object — what script reaches through `document.$(sel)` and hangs its own properties on:

```odin
expando, _ := sciter_app.expando(el)
defer sciter_app.value_clear(&expando)

rank, _ := sciter_app.value_get(&expando, "rowIndex")   // read what script put there
```

Reading is reliable in both directions: a string or a number script wrote comes back intact, and so
does one written from here. **Writing has one hole and it is sharp.** Measured: `value_set` of an
`i32`, `f64` or `bool` round-trips and script sees it immediately; `value_set` of a **string** reports
success and then reads back as garbage from both sides, `value_isolate` first does not help, and a
later unrelated `value_clear` has aborted the process. Put a string there through script:

```odin
sciter_app.eval_element(el, `this.note = "hello"`)      // not value_set(&expando, "note", &s)
```

Same family as the rule in `set_global`: a Value handed to an engine-owned object is not always copied
the way the header implies, and strings are where it shows. A detached element has no document and so
no object — `.INVALID_HANDLE`.

`call_function(el, name, args…)` is the other half of `call_method`: it looks up a *function* visible
from the element, `globalThis`'s included, where `call_method` wants a method on the element itself. A
plain `function` in the document answers to the first and is `.OPERATION_FAILED` through the second.

Two neighbouring slots are dead on this engine and are not wrapped: `SciterGetObject` and
`SciterGetElementNamespace` answer `.OPERATION_FAILED` for every element, leftovers from the removed
script VM.

## URLs

```odin
full, _ := sciter_app.combine_url(el, "images/logo.png", context.temp_allocator)
// -> "file:///home/me/app/assets/images/logo.png"
```

The engine's own resolution against the document `el` is in — the same one that turns
`<img src="logo.png">` into something it can fetch. What a host callback needs when it is handed a
relative reference and has to answer for it. Measured: a relative path resolves against the base, `..`
walks up, a leading `/` becomes root-relative, an already-absolute URL is returned unchanged, and an
empty string answers with the base itself. The C API resolves in place in a caller-sized buffer and
**truncates silently** rather than reporting that it did not fit, which is why the wrapper sizes the
buffer rather than leaving it to you.

## Doing it from the other side

Not everything belongs in Odin. Reading a form's values element by element from the host is a lot of
calls where one `eval` would do:

```odin
v, _ := sciter_app.eval(window, "JSON.stringify(document.form.value)")
```

The rule of thumb: use the DOM API when Odin owns the state and the document is a view of it, and use
`eval` / `call` when the document already knows how to answer the question. Layout-dependent work —
measuring, scrolling into view, focus — is markedly easier in script, and simulating a user
interaction is *only* correct in script:
`eval(window, "document.$('#ok').click()")` runs the button behavior; a synthesised
[`.BUTTON_CLICK` event](./events.md#synthesising-events) does not.

## Callbacks and `context`

Several DOM calls take a receiver the engine calls back into — `SciterGetElementTextCB`,
`SciterSelectElementsW`. The engine calls them as `proc "system"`, where Odin's implicit `context` does
not exist, so every one of them carries the calling context across in its parameter struct and restores
it before touching anything that allocates. If you drop to the raw `sciter.` calls for something the
wrapper does not cover, do the same:

```odin
Sink :: struct {
	ctx: runtime.Context,
	out: string,
}

my_receiver :: proc "system" (str: [^]u16, str_length: u32, param: rawptr) {
	sink := (^Sink)(param)
	context = sink.ctx
	sink.out = sciter_app.string_from_utf16(str, uint(str_length))
}
```

Forgetting the `context =` line does not fail cleanly; it faults on the first allocation.
