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

These walk *elements*. Text and comment nodes are `Node`, a separate handle type; the wrapper exposes
the type but the node-level calls (`SciterNodeChildrenCount`, `SciterNodeCastFromElement`, …) are
reached through `sciter.api()` for now.

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
