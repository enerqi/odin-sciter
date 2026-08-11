# A retained-diff layer, if we want one

**Status: design note, nothing built.** This describes a layer that does not exist, so that the decision
to build it — or not to — can be made against something concrete rather than a vibe. Nothing in
`sciter_app` depends on any of it, and nothing here is a commitment.

It is written for someone who has not yet built much on Sciter, which is the honest position at the
time of writing. So it leads with the problem, is explicit about when the answer is "don't", and ends
with a way to tell later rather than now.

---

## The problem, concretely

There is exactly one place in this repository that updates a list of things from a model, and it is
[`examples/task_list.odin`](../examples/task_list.odin). Its `render` is the whole of the current state
of the art:

```odin
render :: proc(app: ^App) -> sciter_app.Error {
	list := sciter_app.select_first(root, "#list") or_return

	builder := strings.builder_make(context.temp_allocator)
	for task in app.tasks {
		fmt.sbprintf(&builder, `<li id="task-%d" class="%s">…</li>`, task.id, …, escape_html(task.title, …))
	}
	sciter_app.set_html(list, strings.to_string(builder)) or_return
	…
}
```

That is a good design — the model is the truth, the DOM is a projection, data flows one way — and it is
the right thing to have written first. What it costs is all in one line: **`set_html` destroys every
child and parses a new subtree.** Consequences, in rough order of how soon you meet them:

| | |
| --- | --- |
| **Focus is lost** | typing in an `<input>` inside the re-rendered region ends the moment anything re-renders |
| **Scroll position resets** | the list jumps to the top; `task_list` works around this by re-applying `:current` and calling `scroll_to_view` after every render |
| **CSS transitions restart** | a fade or a slide never completes, because the element it was running on no longer exists |
| **Per-element handlers die** | anything from `attach_handler` — or from a `behavior:` name — is torn down and rebuilt each frame. With `named_behavior` in the picture, that is now a real cost: every widget is destroyed and recreated |
| **Escaping is a rule you must remember** | `escape_html` is four lines and not optional, and it is on the caller every single time |
| **It is a full parse per update** | fine for 20 rows; not fine for 2,000, and not fine at 60 Hz |

None of these is fatal. `task_list` is a working application. They are the reasons you eventually stop
re-rendering the whole container and start updating it.

## What the layer would be

A vnode tree built in Odin, diffed against the previous one, applied as the minimum set of DOM
mutations. It is `element.patch(vdom)` — which Sciter already implements in C++ for script (see
[`reactor.md`](./reactor.md)) — done on the Odin side for hosts that do not want the logic in
JavaScript.

Sketch, deliberately unambitious:

```odin
// Build. No DOM touched; this is a value.
ui := vd.el("ul", {id = "list"},
	vd.each(app.tasks, proc(t: Task) -> ^vd.Node {
		return vd.el("li", {key = t.id, class = "done" if t.done else ""},
			vd.el("span", {class = "box"}, vd.text("✓" if t.done else "☐")),
			vd.el("span", {class = "title"}, vd.text(t.title)),   // text, not markup
		)
	}),
)

// Apply. Touches only what changed.
vd.patch(&app.tree, list_element, ui)
```

Three properties that fall out of it, which are the actual payoff:

1. **Elements survive.** An `<li>` whose title did not change is the same `HELEMENT` afterwards, so its
   focus, scroll, transitions, state bits and attached handlers all persist.
2. **Text goes through `set_text`, not `set_html`.** The engine never parses user data as markup, so
   `escape_html` stops being a rule and becomes structurally impossible to forget. This is a security
   property, not an ergonomic one.
3. **The work is proportional to the change**, not to the size of the list.

## What it would need from the engine: nothing

This is the part worth being clear about, because it makes the layer much cheaper than it sounds.
**Every primitive a diff needs already exists in `sciter_app` and is already tested:**

| Diff operation | Call |
| --- | --- |
| create a node | `make_element(tag, text)` |
| insert at an index | `insert_element(el, parent, index)` |
| remove | `remove_element(el, finalize)` |
| reorder | `swap_elements` / `sort_children` |
| set/clear an attribute | `set_attribute` — `""` removes it |
| change text | `set_text` |
| change inline style | `set_style` |
| state bits (`:current`, `:checked`) | `set_element_state` |
| identity across renders | keep the `Element` handle in the vnode; `use_element` if it must outlive a turn |

So the layer is **pure Odin on top of an API that is already complete**. No new engine surface, no new
ABI risk, nothing that needs a probe. That is a very different proposition from the video work, where
the risk was entirely in the engine contract.

## Cost

Best estimate, and it is an estimate:

| | |
| --- | --- |
| vnode representation + arena, `el` / `text` / `each` builders | ~300 lines |
| the diff: same-type patch, keyed children reconciliation, unkeyed fallback | ~500 lines, and **this is where all the difficulty is** |
| the apply pass over the table above | ~300 lines |
| event/handler binding that survives a patch | ~200 lines |
| tests | ~700 lines, following the house style |

Call it **1,500–2,000 lines**, comparable to `dom.odin` and `events.odin` together. The line count is
not the risk. The risk is that **keyed list reconciliation is genuinely subtle** — insert, remove,
reorder and move, all at once, correct in every interleaving — and a bug there is a UI that is silently
wrong rather than one that crashes. Every framework that has done this has shipped bugs in it.

The mitigation is the same one the rest of this repository uses: the diff is pure and deterministic, so
unlike almost everything else here it can be tested **headlessly and exhaustively**. Generate random
before/after trees, apply the diff, assert the result equals a from-scratch build. That is a property
test, it needs no display, and it is the single thing that would make this layer trustworthy.

## When you would *not* want this

Being straight about it, since the whole question is whether it is worth the second layer:

- **The UI is mostly static.** A settings dialog, a form, a toolbar — direct DOM calls are simpler and
  every other example here uses them for good reason.
- **You are happy with script.** Sciter already has `patch()` and signals, in C++, maintained by
  upstream, documented in [`reactor.md`](./reactor.md), for free. Choosing the Odin layer is choosing to
  reimplement that so the logic can be in Odin. That is a real reason — `task_list`'s "no JavaScript at
  all" is a genuine selling point — but it is a preference, not a capability gap.
- **Updates are localised.** If a change touches one counter, `set_text` on one element is the whole
  job. A diff earns its keep on *lists* and *trees whose shape changes*.
- **You have not hit the pain yet.** This is the honest one. Every cost in the first table is invisible
  until you build something that has a scrolling list with focusable rows in it. Building the layer
  first means guessing at requirements.

## When you would

The trigger is specific rather than aesthetic. Reach for it when at least two of these are true:

- a list of more than a few dozen rows that updates while the user is looking at it
- anything focusable or scrollable inside a region that re-renders
- CSS transitions or animation on elements that re-render
- per-element handlers or `behavior:` widgets inside a re-rendered region
- updates at interactive rates rather than on user action

## Alternatives, ranked by cost

| | Cost | What you give up |
| --- | --- | --- |
| **Direct DOM calls** (today, most examples) | zero | you hand-write every update path |
| **`set_html` re-render** (today, `task_list`) | zero | the whole first table |
| **Targeted patching by hand** — keep element handles in the model, update in place | small, per application | it is bespoke each time and easy to get subtly out of step |
| **Sciter's Reactor** | zero binding work | the UI logic lives in JavaScript |
| **This layer** | 1,500–2,000 lines, once | maintenance of a diff, forever |

The third row is worth taking seriously as the first move: it is what you would write anyway on the way
to discovering whether the general version is needed, and the experience of writing it twice is exactly
what would tell you.

## If it is built, build it in this order

Each stage is independently useful and independently abandonable, which is the point.

1. **A second, harder example first — no layer.** Something with a long scrolling list of focusable
   rows, updated live, written with `set_html`. Feel the failures listed above rather than take them on
   trust. This is cheap and it is the only step that produces a real answer to "do we need this".
2. **Keyed identity, no diff.** A helper that maps model keys to element handles and creates/removes/
   reorders children to match, leaving each row's contents to the caller. Perhaps 200 lines, and it
   kills the top four costs on its own.
3. **Attributes and text.** Extend it to patch each row's contents from a description. Now it is a
   diff, but only one level deep.
4. **General nested trees + property tests.** Only if 2 and 3 turn out to be used enough to justify it.

Stopping after 2 would be a perfectly good outcome.

## Open questions this note does not answer

- **Where handlers live.** A vnode is rebuilt every frame, so a closure in it is rebuilt too, while
  `attach_handler` needs a stable address that outlives the attachment. The likely answer is that
  handlers are keyed and owned by the layer, not by the vnode — but that is the design's real unknown,
  and it is the same boundary Fleury's Part 7 ("Where IMGUI Ends") is about, which is
  [still paywalled](./FLEURY-UI.md#where-the-paywall-starts-and-whats-only-known-from-teasers).
- **How it composes with `behavior:` names.** `named_behavior` means the engine can attach a widget to
  any element the stylesheet matches, including ones the diff just created. That looks like a good fit —
  the diff owns structure, the engine owns widgets — but it has not been tried.
- **Whether an immediate-mode call site is wanted on top** (option C in the earlier survey, and the
  subject of [`FLEURY-UI.md`](./FLEURY-UI.md)). Everything above is the retained half either way, so it
  is not a fork in the road yet.

## Reading

- [`reactor.md`](./reactor.md) — what Sciter already does, in C++, for script. Read this before deciding
  the Odin layer is necessary.
- [`FLEURY-UI.md`](./FLEURY-UI.md) — the immediate-mode-over-retained-cache architecture, Parts 1–3.
- [`examples/task_list.odin`](../examples/task_list.odin) — the current state of the art here, and the
  thing this would replace the middle of.
- [`api.md`](./api.md#the-dom--domodin) — the DOM primitives the apply pass would be written against.
