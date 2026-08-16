# A retained-diff layer, if we want one

**Status: design note, nothing built — and on the evidence since, probably not worth building.** This
describes a layer that does not exist, so that the decision to build it — or not to — can be made
against something concrete rather than a vibe. Nothing in `sciter_app` depends on any of it, and
nothing here is a commitment.

**The short version, if you read nothing else.** This note predicted six costs that a re-render-the-lot
approach would impose. [`examples/workbench.odin`](../examples/workbench.odin) was then built as the
hard case — 10,000 rows, virtualised, editable, live-updating, an Odin-painted widget per row, no
script — and **five of the six never bit**. The one that did (focus destroyed by a re-render) has a
model-side workaround that handles everything but the caret. Virtualisation turned out to be the better
first move and is a tenth of the size: ~40 lines, and it removes the parse cost and the scroll cost
together. So the trigger for building anything here narrowed to one case — *a text field the user is
actively typing into, inside a region something else re-renders* — and the recommendation settles at
option 2 of the build order ("keyed identity, no diff"), not at a diff. [What actually
hurt](#what-actually-hurt) is the measurement; [What this
changes](#what-this-changes) is the revised recommendation.

Kept because the reasoning is the record: the cheap experiment was run, it contradicted the note that
proposed it, and that is the argument for not building the layer rather than for building it later.

The rest is written for someone who has not yet built much on Sciter, which was the honest position at
the time of writing. So it leads with the problem, is explicit about when the answer is "don't", and
ends with a way to tell later rather than now.

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

## What actually hurt

**This section is the experiment, not the argument.** The recommendation below used to be "write a
harder example without a layer and see what breaks"; [`examples/workbench.odin`](../examples/workbench.odin)
is that example — ten thousand rows, virtualised, editable, live-updating, with an Odin-painted widget
per row and no script anywhere — and this is what building it was actually like.

The headline: **five of the six costs in the first table never bit, and the one that did was cheap to
work around.** That is not the answer this note expected.

| Predicted cost | What happened |
| --- | --- |
| **Focus is lost** | Real, and the only one that mattered. Editing a cell and scrolling one row destroys the `<input>`. |
| **Scroll position resets** | Never happened — but only because virtualisation inverts the relationship. The scroll lives on `#viewport`, which is *not* re-rendered; `set_html` goes to `#rows` inside it. The scrollbar is a function of the model, so nothing the renderer does can disturb it. |
| **CSS transitions restart** | Not reached. A row that lives ~200 ms between renders has nothing to transition. This cost is real for a panel that re-renders occasionally, not for a list that re-renders constantly. |
| **Per-element handlers die** | Real, and irrelevant — because nothing uses `attach_handler` per row. The sparkline is a `behavior:` name, so the *engine* re-attaches it to every row the renderer creates. That is 33 attach/detach pairs per frame and it costs one `new` and one `free` each. |
| **Escaping is a rule you must remember** | Real, and unchanged. `escape_html` is on the caller at every interpolation, exactly as predicted. A test pins that a row named `<b>` stays text. |
| **A full parse per update** | Not reached, by construction. Virtualisation caps the parse at the visible window: `set_html` runs on ~31 rows whether the model holds ten thousand or ten million. |

### The one that hurt, precisely

Focus. The workaround is nine lines — keep the edit in the model, find the new `<input>` after each
render, `set_focus` it — and it is in
[`restore_focus`](../examples/workbench.odin). Two things about it are worth recording:

- **It works, completely.** The edit survives re-renders, survives its row scrolling out of the window
  entirely (it was never in the DOM to begin with), and survives scrolling back. Two tests pin both.
- **It has to be right on every path that re-renders, and every path re-renders.** That is the actual
  cost: not the nine lines, but that they are load-bearing from nine call sites and nothing enforces it.

What it does *not* preserve is caret position within the field, or the selection. Nobody noticed in
this example because the edits are short; in a text area it would be unacceptable, and no amount of
`set_focus` fixes it. **That is the honest ceiling of the workaround.**

### What was harder than any of it

Two things cost more time than the whole focus problem:

- **Layout.** `display: flex` parses and then does not lay out the way a browser does. The first
  version of the document came out as a single stacked column and looked like a rendering bug. Sciter's
  own `flow:` model is the answer and [`html-css-js.md`](./html-css-js.md) says so in as many words. A
  diff layer would not have helped by one line.
- **A measured engine rule nothing else here had hit**: a `behavior:` name on an element created by
  `set_html` is attached on the *next turn of the pump*, not inside the call — unlike an element in the
  document being loaded, which `named_behavior` measures as attaching inside `load_html`. Code that
  renders and then immediately reaches for a row's widget finds nothing. There is a test for it.

### What the numbers say

Added afterwards, when the workbench grew type-ahead search on a worker thread. Both numbers are printed
by `test_the_search_worker_delivers_its_answer_through_post_callback`, so they can be re-measured on any
machine rather than believed:

| | Cost |
| --- | --- |
| Scanning **10,000 rows** for a substring match, on a worker thread | **~1.1–1.3 ms** |
| `set_html` of the **31 rows** that scan put on screen | **~2.0–3.4 ms** |

**Rendering thirty-one rows costs more than filtering ten thousand.** Three runs on the same machine,
same process, one after the other. That is the whole cost argument for this note in two lines: the
expensive half of a keystroke is not the model work, it is handing markup to the engine and having it
parse, style and lay out — which is precisely what a diff layer removes and what virtualisation only
bounds.

It does not overturn the recommendation, because 3 ms at 12 Hz is not a problem anyone can see. It does
say where the remaining cost is, and that a second application which re-renders a *larger* window than
31 rows — a table that fills a 4K screen, say — would meet it much sooner than the row count suggests.

Two smaller findings from the same work:

- **The worker is not what makes type-ahead correct — the generation number is.** A scan that lands
  after the next keystroke is a correct index for a query nobody is asking. Nine lines
  (`search_apply`) drop it. Any asynchronous list needs this, with or without a diff layer, and a diff
  layer would not have supplied it.
- **A `behavior:` widget reads its data when it attaches, so "update the widget" means "replace the
  element".** The details window's large sparkline is rewritten wholesale on every tick for that
  reason. A diff layer that patched attributes in place would *not* have updated it — it would have
  had to know to recreate the element, which is the same knowledge the hand-written path already has.

### What this changes

The recommendation stands, but the trigger moves.

**Virtualisation is a better first move than a diff, and it is a tenth of the size.** It removes the
parse cost, and it removes the scroll cost as a side effect. It is roughly 40 lines here — `visible_rows`
plus two `set_style` calls — and the only subtlety is clamping the window at both ends of the model,
which a test caught during writing.

So the "when you would" list above is too generous. On this evidence:

- *"a list of more than a few dozen rows that updates while the user is looking at it"* — **not
  sufficient on its own.** Virtualise instead; the workbench does 10,000 rows at 12 Hz with `set_html`.
- *"anything focusable inside a region that re-renders"* — **this is the real trigger**, and it is the
  only one that survived contact. Specifically: a text field the user is *typing into* while something
  else re-renders it. The model-side workaround handles focus but not the caret.
- *"per-element handlers or `behavior:` widgets inside a re-rendered region"* — **no longer a reason.**
  A `behavior:` name is free across re-renders. Only `attach_handler` would have suffered, and a
  `behavior:` name is the better tool for a widget in a list anyway.

The thing that would settle it is the *second* application of the hand-written patching — `VDOM.md`'s
own advice, and still untaken, since the workbench needed it only once. Until then the estimate stands
at option 2 of the build order below ("keyed identity, no diff"), and the case for going past it is
weaker than this note originally assumed.

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

1. ~~**A second, harder example first — no layer.**~~ **Done**:
   [`examples/workbench.odin`](../examples/workbench.odin), and the results are in
   [What actually hurt](#what-actually-hurt) above. It changed the answer: virtualisation removes most
   of the cost, and only focus-while-typing survives as a reason to go further.
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
- [`examples/task_list.odin`](../examples/task_list.odin) — the gentle version of the same design, and
  the thing this would replace the middle of.
- [`examples/workbench.odin`](../examples/workbench.odin) — the hard version, and the evidence behind
  [What actually hurt](#what-actually-hurt).
- [`api.md`](./api.md#the-dom--domodin) — the DOM primitives the apply pass would be written against.
