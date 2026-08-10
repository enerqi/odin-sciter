# The DOM from Odin

Reading and changing the document without going through script. Everything here is
[`sciter_app/dom.odin`](../sciter_app/dom.odin); the runnable version is
[`examples/dom_walk.odin`](../examples/dom_walk.odin), which also carries four display-gated tests.

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

`select_first` searches `element`'s subtree and returns `.Not_Found` rather than a nil handle, so the
error check is the existence check. `select_all` returns matches in document order; the slice is
allocated with the supplied allocator and is the caller's to `delete`, while the handles in it are
borrowed and are **not** `use_element`ed.

## Traversal

```odin
n, _      := sciter_app.child_count(el)
first, _  := sciter_app.child(el, 0)
up, err   := sciter_app.parent(el)      // .Not_Found at the root
name, _   := sciter_app.tag(el)         // "div", "button" - borrowed, valid for the element's life
```

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
created, _ := sciter_app.make_text_node(" appended")   // detached: yours until inserted
target, _  := sciter_app.node_from_element(summary)
sciter_app.node_insert(target, .APPEND, created)       // .BEFORE .AFTER .APPEND .PREPEND
```

Two lifetime rules, both the C API's:

- **Node handles are not reference counted on the way out.** `sciter-x-dom.h` says so outright. A
  handle is valid while the node is in the document; holding one longer needs `node_add_ref` /
  `node_release`, which is `use_element` under a different name.
- **A detached node is yours.** `make_text_node` and `make_comment_node` return a node in no document.
  Insert it or release it. `node_remove(node, finalize = false)` detaches rather than destroys, which
  is what moving a node between two places wants.

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

## Building and moving elements

`set_html` replaces a subtree with markup. This is the other way round — make the element, then put it
where it goes — which is what content coming from data wants, and the only way to *move* an element
rather than re-create it.

```odin
item, _ := sciter_app.make_element("li", "third")   // plain text, not parsed
defer sciter_app.unuse_element(item)                // yours, inserted or not
sciter_app.insert_element(item, list)               // no index: appended
```

**`make_element` and `clone_element` hand back a reference that is yours, and inserting does not
consume it** — the document takes its own. An element that is created and never unused leaks inside
the engine, where Odin's allocator tracking cannot see it. `remove_element(el, finalize = false)`
hands back a reference the same way; see below.

```odin
sciter_app.insert_element(el, parent, 0)      // at the front; the default appends
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

`element_uid(el)` returns an integer that survives being stored where a handle cannot go. Its partner
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
