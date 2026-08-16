# Ryan Fleury's hybrid immediate/retained UI architecture

Referenced from [`ALTERNATIVES.md`](./ALTERNATIVES.md) as the "hybrid retained/immediate" design behind
the RAD Debugger's UI. Ryan Fleury writes it up as a numbered series, "UI," at
[dgtlgrove.com](https://www.dgtlgrove.com/) (his current Substack; older posts also mirror at
[rfleury.com](https://www.rfleury.com/)). Most of the series is paid-subscriber content. What follows is
only what loaded without a subscription, checked post by post — per
[`RESEARCH-METHOD.md`](./RESEARCH-METHOD.md), a summary of a paywall teaser is labeled as exactly that,
not filled in with guesses about what's behind it.

## The series, and what's actually readable

| Part | Title | Access |
| --- | --- | --- |
| [1](https://www.dgtlgrove.com/p/ui-part-1-the-interaction-medium) | The Interaction Medium | **Free** |
| [2](https://www.dgtlgrove.com/p/ui-part-2-build-it-every-frame-immediate) | Every Single Frame (IMGUI) | **Free** |
| [3](https://www.dgtlgrove.com/p/ui-part-3-the-widget-building-language) | The Widget Building Language | **Free** |
| [4](https://www.dgtlgrove.com/p/ui-part-4-the-widget-is-a-lie-node) | The Widget Is A Lie (Node Composition) | Paywalled |
| [5](https://www.dgtlgrove.com/p/ui-part-5-visual-content) | Visual Content | Paywalled |
| [6](https://www.dgtlgrove.com/p/ui-part-6-rendering) | Rendering | Paywalled |
| [7](https://www.dgtlgrove.com/p/ui-part-7-where-imgui-ends) | Where IMGUI Ends | Paywalled |
| [8](https://www.dgtlgrove.com/p/ui-part-8-state-mutation-jank-and) | State Mutation, Jank, and Hotkeys | Paywalled |
| [9](https://www.dgtlgrove.com/p/ui-part-9-keyboard-and-gamepad-navigation) | Keyboard and Gamepad Navigation | Paywalled |
| [bonus 1](https://www.dgtlgrove.com/p/ui-bonus-1-simple-single-line-text) | Simple Single-Line Text Input | Paywalled |

Also relevant, free, not part of the numbered series: [Cracking the Code: Realtime Debugger
Visualization Architecture](https://www.dgtlgrove.com/p/cracking-the-code-realtime-debugger) — write-up of
his 2025 Better Software Conference talk on the RAD Debugger's evaluation/visualization pipeline. It does
not cover retained-vs-immediate rendering; it's about debug-info evaluation feeding watch-window trees and
visualizers, one level above the UI layer this doc is about.

Parts 1–3 lay out the actual hybrid architecture — the "cached-but-immediate" core — in enough detail to
be useful on their own. Parts 4 onward extend it (node composition, styling, GPU rendering, jank/input
handling, text editing) but weren't reachable here.

## Part 1 — why immediate-mode, framed as an information problem

Fleury frames a UI as the *barrier* between a user and a program, and states the design goal as a ratio:
**bits sent to bits usefully received**. His example: making a user type "Hello, Mr. Program. I would
like you to toggle the checkbox, please" encodes the same information as a click, at far higher cost —
that gap is what a UI is supposed to close.

From that he derives:

- **Standard widgets exist to lower the cost of learning**, not because they're individually optimal —
  a bespoke widget might communicate better in isolation but costs the user unfamiliarity.
- **Signifiers and animation** carry information about state and affordance beyond the widget's function
  itself; an instant state flip communicates less than a smooth transition does.
- **The architecture splits into two layers**: a small reusable *core* (generic widget machinery,
  standard widget implementations) and *builder code* (the specific interface composed from it), with
  deliberate escape hatches so builder code isn't boxed in when it needs something the core doesn't
  provide.

That two-layer split is the frame the rest of the series builds inside.

## Part 2 — the actual hybrid: immediate API, retained cache

The argument against pure retained-mode: widget construction, mutation, and interaction handling end up
scattered across separate call sites, so keeping them in sync is a standing source of bugs, and dead
widgets accumulate because nothing forces their removal to be symmetric with their creation.

Immediate-mode fixes that by making a widget's code — appearance, behavior, click handling — **one call,
one place**. But a naive immediate-mode UI has no memory between frames, which breaks anything that needs
state to persist (hover animations, scroll position, focus). Fleury's fix is a widget struct that is
*rebuilt* every frame for its tree structure but *looked up* every frame for its persistent state:

```c
struct UI_Widget {
  // tree links (rebuilt each frame)
  UI_Widget *first, *last, *next, *prev, *parent;

  // hash links (persistent cache, keyed and looked up each frame)
  UI_Widget *hash_next, *hash_prev;
  UI_Key key;
  U64 last_frame_touched_index;

  // semantic input (what the builder asked for)
  UI_Size semantic_size[2];

  // computed output (filled in by the layout pass)
  F32 computed_rel_position[2];
  F32 computed_size[2];
  Rng2F32 rect;
};
```

Each frame: the tree pointers are thrown away and rewritten from scratch by that frame's builder calls,
while the hash table is a persistent cache — a widget with the same key across frames finds its old entry
and keeps whatever state lives there (`last_frame_touched_index` is how the system notices a widget
*stopped* being built, i.e. it's gone). Per-widget `hot_t` / `active_t` float fields live in that cached
struct too, which is how hover/press animations stay smooth without any builder code having to manage
them explicitly — the animation state simply persists across the immediate-mode calls that rebuild
everything else.

**Why a full hierarchy can't be laid out live, and the fix**: a widget call doesn't know its siblings or
children yet when it runs, so layout can't happen inline. The frame is split into stages, with a one-frame
input delay on layout (built against *last* frame's cached tree):

1. Build the hierarchy (tree links freshly written, cache looked up by key)
2. Autolayout — an offline pass that now has the whole tree:
   - standalone sizes first (fixed pixels, text content)
   - upwards-dependent sizes (percent-of-parent)
   - downwards-dependent sizes (children-sum)
   - violation solving (compress children that overflow their parent)
   - final position computation
3. Render, from the now-resolved tree

Sizing is a small tagged union rather than raw pixels, so the same call site can ask for any of the four
kinds:

```c
enum UI_SizeKind { Pixels, TextContent, PercentOfParent, ChildrenSum };

struct UI_Size {
  UI_SizeKind kind;
  F32 value;
  F32 strictness;  // resistance to being shrunk by the violation pass
};
```

Keying follows Dear ImGui's convention directly: a widget's key is hashed out of a `##`/`###`-delimited
suffix on its display string (`"Save##save_btn"` displays "Save", hashes on `save_btn`; `"Item##%d"` in a
loop disambiguates by index; `###` scopes the hash to a parent/sibling context instead of the label).

## Part 3 — flags instead of a widget-kind enum

The alternative to `enum UI_WidgetKind { Button, Checkbox, Slider, ... }` with a switch per behavior: one
`UI_Widget` struct, one flags field, and orthogonal boolean flags for each independent behavior
(`Clickable`, `DrawText`, and so on):

```c
typedef U32 UI_WidgetFlags;
// UI_WidgetFlag_Clickable, UI_WidgetFlag_DrawText, ...
```

The claimed payoff is combinatorial: N independent flags cover 2^N possible widget behaviors while the
core only ever branches on N conditions, not one code path per combination — so a "checkbox" is just
`Clickable | DrawBorder | DrawBackground` composed inline rather than a distinct type with its own
implementation. High-level helpers like `UI_Button()` still exist as thin convenience wrappers over the
flags, but builder code can drop to the flag-level API directly for anything that doesn't fit the
provided helpers — the "escape hatch" from Part 1's two-layer split, concretely.

Fleury's own size argument for why this doesn't matter for memory: at roughly 512 bytes per widget,
1,024 live widgets is 0.5MiB — small enough to sit inside L2 cache, so the generality costs branches, not
bytes.

## Where the paywall starts, and what's only known from teasers

From Part 4 on, only the subtitle/teaser loaded — listed here as topic pointers, not summaries, since
there's nothing behind them to summarize honestly:

- **Part 4**, "The Widget Is A Lie": drops the idea that a widget must be an explicit node in the
  hierarchy data structure at all.
- **Part 5**, "Visual Content": how styling and spacing get specified from builder code.
- **Part 6**, "Rendering": GPU techniques for the actual paint step.
- **Part 7**, "Where IMGUI Ends": makes the case that higher-level entities — windows, tabs, panels —
  should *not* have their state owned by the core UI system. This is the one that most directly answers
  "where does the hybrid model's immediate-mode part stop," and it's the one this doc couldn't retrieve.
- **Part 8**: timing/consistency of state mutation and where visual "jank" comes from; hotkeys.
- **Part 9**: keyboard and gamepad navigation without every builder call site having to implement it.
- **Bonus 1**: a worked single-line text input covering ~20 standard editing shortcuts
  (word-wise Ctrl+arrow/backspace, selection, clipboard), argued to be less code than expected once
  factored properly.

## How this relates to what's in ALTERNATIVES.md

This is the architecture behind picking **Dear ImGui-family** over **Slint** in
[`ALTERNATIVES.md`](./ALTERNATIVES.md#native-access-real-widgets-and-no-htmlcssjs) done properly: Fleury's system is still immediate-mode
at the call site (Part 2's whole pitch), so it keeps ImGui's FFI simplicity — one function call per
widget, no markup, no VM — while the hash-keyed cache buys back the persistent state (animation,
scroll position, focus, and per Part 7's teaser, higher-level entities like tabs) that a naive immediate
UI doesn't have and that makes Sciter's retained DOM attractive in the first place. It's a third point on
the same tradeoff triangle as the ALTERNATIVES.md table, not a rebuttal of it: still no HTML/CSS, still no
sandbox, still a from-scratch layout engine to own rather than get from a CSS cascade.
