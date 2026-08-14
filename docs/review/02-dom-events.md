# Review: DOM, nodes, events, behaviors, layout

Scope: `sciter_app/dom.odin`, `sciter_app/node.odin`, `sciter_app/events.odin`,
`sciter_app/behavior.odin`, `sciter_app/layout.odin`, headers `sciter-x-dom.h`, `sciter-x-behavior.h`,
`value.h`.
Date: 2026-08-13

## Summary

The riskiest thing a binding like this does is get a callback's return protocol or an enum's numeric
values wrong, because both fail silently. I checked the ones that matter against the headers and they
are right: `PHASE_MASK` really is `BUBBLING = 0, SINKING = 0x8000, HANDLED = 0x10000`
(`sciter-x-behavior.h:76-82`), so `EVENT_CODE_MASK :: 0x7FFF` at `events.odin:99` is correct;
`DRAW_PARAMS.cmd` really is a bare `DRAW_EVENTS` 0..3 with no phase bits (`sciter-x-behavior.h:401-418`),
so `draw_event` not masking is correct rather than an oversight; `KeyValueCallback` really means "return
TRUE to continue" (`value.h:230-233`). The handle-ownership story is the strongest part — `remove_element`
taking the reference *before* `SciterDetachElement` (`dom.odin:601-602`) is a subtle thing to get right
and there is a comment saying why.

The defects are all in the second tier: one unclamped index that mirrors a segfault the file next door
already documents, one place where an enum flattens two orthogonal facts into one, and a handful of
spots where a distinction the header offers is thrown away before the caller sees it. Nothing here is
memory-unsafe on its own except R2-01.

## Findings

### R2-01 — `sort_children` clamps `last` but not `first`  [severity: major]

**Where:** `sciter_app/dom.odin:622-648`
**What:** the proc carefully resolves `last`:

```odin
stop := last
if stop < 0 {
    stop = child_count(element) or_return
}
if first >= stop {
    return nil
}
```

and then passes `u32(first)` straight through. `first` is a `Child_Index`, i.e. a signed `int`, with no
lower bound and no upper bound check. `first = -1` passes the `first >= stop` guard (`-1 >= 5` is false)
and reaches the engine as `u32(-1)` = 4294967295.
**Why it matters:** the sibling proc `insert_element` documents exactly this failure mode fifty lines
earlier (`dom.odin:576-579`): "a very large one (`max(u32)`, the obvious spelling of 'at the end')
segfaults inside the engine rather than appending, so the count is what gets passed." `SciterSortElements`
takes the same kind of index and there is no reason to think it is more defensive. `first = -1` is not an
exotic input either — it is what you get from `element_index(el) - 1` on a first child, or from a
`last`-style sentinel copied across from `insert_element`'s signature, where `-1` is the documented
default.
**Fix:** clamp both ends, the way `insert_element` does:

```odin
begin := first if first > 0 else 0
if begin >= stop { return nil }
```

and, while there, consider clamping `stop` to `child_count` as well — an explicit `last` past the end has
the same shape as the `insert_element` case.

### R2-02 — `Event_Phase` collapses two orthogonal facts, so a handler cannot see the phase of a handled event  [severity: major]

**Where:** `sciter_app/events.odin:101-129`
**What:** `PHASE_MASK` is not an enumeration of three phases. `sciter-x-behavior.h:76-82` gives
`BUBBLING = 0`, `SINKING = 0x8000` and `HANDLED = 0x10000` — the first two are the phase, and `HANDLED`
is an independent flag OR'ed on top of either. The wrapper models all three as one Odin enum and tests
`HANDLED` first:

```odin
switch {
case cmd & u32(sciter.Phase_Mask.HANDLED) != 0:
    return .Handled
case cmd & u32(sciter.Phase_Mask.SINKING) != 0:
    return .Sinking
}
return .Bubbling
```

**Why it matters:** once anything upstream has claimed an event, every later handler sees `.Handled` and
can no longer tell whether it is on the sinking or the bubbling pass. That is not a corner case: the
`Event_Handler` doc at `events.odin:37-40` explains that a handler returning true means "the rest of the
trip carries the HANDLED bit, so later handlers see `Event_Phase.Handled`", and separately warns that
"acting on every phase acts twice". So the package documents both that handlers must discriminate by
phase to avoid double-acting, *and* that the phase becomes unreadable as soon as anything handles the
event. A handler that does `if ev.phase == .Bubbling { act() }` — the documented way to act once —
silently stops acting the moment any other handler claims the event first.
**Fix:** make the two independent, which is what the C API models:

```odin
Event_Phase :: enum { Bubbling, Sinking }        // the direction
event_phase   :: proc(cmd: u32) -> Event_Phase   // SINKING bit only
event_handled :: proc(cmd: u32) -> bool          // HANDLED bit
```

and give `Behavior_Event`, `Mouse_Event` and the rest a `handled: bool` field alongside `phase`. This is
a breaking change to seven accessor structs, so it wants doing once rather than gradually; the current
shape cannot be fixed by adding a field without leaving the misleading `.Handled` variant in place.

### R2-03 — `attribute_change_event` discards the removed-vs-emptied distinction the header provides  [severity: major]

**Where:** `sciter_app/events.odin:425-437`
**What:** `sciter-x-behavior.h:638-643` is explicit:

```c
typedef struct ATTRIBUTE_CHANGE_PARAMS
{
  HELEMENT  he;           // this element
  LPCSTR    name;         // attribute name
  LPCWSTR   value;        // new attribute value, NULL if attribute was deleted
} ATTRIBUTE_CHANGE_PARAMS;
```

The wrapper runs `value` through `string_from_utf16_cstring`, which returns `""` for a nil pointer
(`src/prelude.odin:114-117`). So `removeAttribute("data-x")` and `setAttribute("data-x", "")` both arrive
as `value == ""`.
**Why it matters:** this event exists to watch a document for changes made by script — that is what the
doc comment at `events.odin:409-411` says it is for. Removal is a distinct thing to react to: a
`data-state` attribute being cleared versus removed is the difference between "the state is empty" and
"there is no state". The header hands the distinction over and the wrapper is the thing that loses it.
The doc comment at `events.odin:413-414` even records the measurement — "a removal arrives with `value`
empty rather than as a separate code" — without noticing that the emptiness is the wrapper's doing, not
the engine's.
**Fix:** add `removed: bool` to `Attribute_Change`, set from `p.value == nil` before the decode. One line,
no breaking change to existing fields.

### R2-04 — `combine_url` sizes its buffer by a fixed guess and the C API truncates silently  [severity: minor]

**Where:** `sciter_app/dom.odin:696-707`
**What:** the buffer is `utf16_len(url) + 1024` units, with a comment recording that the C API
"truncates silently rather than reporting that it did not fit — a four-unit buffer came back OK holding
'fil'". So the 1024 is slack for the base URL.
**Why it matters:** 1024 UTF-16 units is a generous *typical* base and an arbitrary *maximum*. A document
loaded from a deep path, a `data:` base, or an archive URL scheme with a long prefix silently produces a
truncated absolute URL, reported as success. The result then goes to a host callback or out to the
filesystem, where a truncated path is a confusing failure a long way from here. The measurement in the
comment is exactly what makes this dangerous — the call cannot report the overflow, so the wrapper is the
only place it can be caught.
**Fix:** detect truncation instead of trying to out-guess it. Call once at the current size; if the
result's length comes back at `size - 1` units — i.e. it exactly filled the buffer — retry at
`size * 4` and repeat a bounded number of times. That converts a silent wrong answer into a correct one
at the cost of a second call in the rare case.

### R2-05 — `set_timer` silently turns a negative interval into "stop" and truncates above 49 days  [severity: minor]

**Where:** `sciter_app/events.odin:674-683`
**What:**

```odin
ms := i64(interval / time.Millisecond)
if interval > 0 && ms < 1 { ms = 1 }
if ms < 0 { ms = 0 }
return dom_err(... SciterSetTimer(..., u32(ms), id))
```

A negative `interval` becomes `0`, and `0` is the engine's spelling of "stop this timer" — which
`stop_timer` at `events.odin:686-688` relies on. A `time.Duration` above ~49.7 days exceeds `max(u32)`
milliseconds and wraps.
**Why it matters:** the sub-millisecond case is handled carefully and documented ("rounding down to zero
would stop the timer"), which shows the author knew the hazard; the negative case falls into exactly the
trap the comment describes and is not mentioned. `set_timer(el, -delay)` from an arithmetic slip stops a
running timer instead of erroring, and the caller sees `nil`.
**Fix:** return `sciter.Scdom_Result.INVALID_PARAMETER` for `interval < 0`, and clamp — or reject —
above `max(u32)` milliseconds. Two lines, and it makes `stop_timer` the only way to spell stopping.

### R2-06 — `make_text_node` and `make_comment_node` do not check for a nil handle  [severity: minor]

**Where:** `sciter_app/node.odin:199-212`
**What:** both return `Node(hn)` straight after `dom_err(...) or_return`, with no `if hn == nil` guard.
Every comparable proc in the package has one — `make_element` (`dom.odin:552`), `clone_element`
(`dom.odin:563`), `node_from_element` (`node.odin:39`), and the shared `found_node` helper
(`node.odin:160-165`) exists precisely for this.
**Why it matters:** the file's own header comment says a created node "belongs to the caller until
`node_insert` puts it in a document… Insert it, or release it, or it leaks." A caller following that
advice on a nil handle calls `node_insert(nil, ...)` or `node_release(nil)`. It is inconsistent rather
than dangerous — the engine most likely never returns OK with a nil handle here — but the rest of the
file does not make that assumption and neither should these two.
**Fix:** `return found_node(hn)` in both, which is what every sibling does.

### R2-07 — `set_behavior_value` and `fire_event` copy a Value by assignment, not `value_copy`  [severity: minor]

**Where:** `sciter_app/behavior.odin:102` (`params.val = value^`), `sciter_app/events.odin:938`
(`params.data = event.data^`)
**What:** both take the caller's `^Value` and memcpy the 16-byte struct into a parameter block that is
then handed to the engine. No reference is taken.
**Why it matters:** for `fire_event` this is established as safe — the doc at `events.odin:921` and
`events.odin:929` records that the engine copies the payload, `post` included, and says it was measured.
For `set_behavior_value` there is no such measurement and no such note. The receiver is an arbitrary
behavior, possibly one written by the user against this same package, and the natural thing for a
`SET_VALUE` implementation to do with `args.val` is to store it — or, if it is careful about the
ownership rules stated at the top of `value.odin`, to `value_clear` it. Either one operates on a
reference the caller still believes it owns. `set_behavior_value`'s doc says only "`value` is not
consumed", which is a claim about this wrapper, not about the behavior on the other end.
**Fix:** state the contract for the receiving side in `set_behavior_value`'s doc comment — that the
parameter block borrows and a `SET_VALUE` implementation must `value_copy` to keep it — and say the same
in the "Answering a method call" section at `behavior.odin:147-185`, which currently shows
`args.val = sciter_app.value_from(42)` for `GET_VALUE` without saying who then owns that reference.

### R2-08 — DOM/event coverage is complete; the *record* of why each exclusion is deliberate is scattered  [severity: minor]

**Where:** measured across `sciter_app/*.odin` against `external/sciter/include/sciter-x-api.h`
**What:** of the 176 `SCFN(...)` slots declared in the header, 163 are reached from `sciter_app`. Every
one of the thirteen that is not turns out to be a deliberate exclusion, and every one is justified
somewhere in the tree:

| slot | why not wrapped | where that is written down |
|---|---|---|
| `SciterSelectElements`, `SciterSelectParent` | the `...W` variants are wrapped instead | nowhere |
| `SciterGetElementTypeCB` | `SciterGetElementType` is wrapped as `tag` | nowhere |
| `SciterProc`, `SciterProcND`, `SciterClassName` | Windows window-proc plumbing; no `foreign import` design | nowhere |
| `SciterAttachHwndToElement`, `SciterGetElementHwnd` | native child windows | nowhere |
| `SciterEGLGetProcAddress`, `SciterEGLSendEvent` | windowless EGL | nowhere |
| `SciterGetViewExpando` | **NULL slot on Sciter 6** — dead with the removed TIScript VM | `window.odin:342-346`, `docs/ENGINE.md:256`, `docs/calling-between-odin-and-js.md:334` |
| `SciterGetObject`, `SciterGetElementNamespace` | answer `.OPERATION_FAILED` for every element; same VM leftovers | `docs/api.md:834-836`, `docs/dom.md:565-566` |

So there is no missing DOM or event functionality. That is a genuinely good result for a binding this
young, and it is worth stating plainly because nothing in the tree currently does.
**Why it matters:** the three dead slots are documented four times over, in four different files, at the
place each was discovered — but a reader asking "is everything wrapped?" has no single place to look.
`docs/SDK-PARITY.md` is the file whose name promises that answer. The six mechanical exclusions
(ANSI variants, the CB variant, the Windows window-proc trio) are not written down at all, so the next
person to audit coverage re-derives them, exactly as this review did.
**Fix:** put the whole thirteen-row table in `docs/SDK-PARITY.md` with a one-line reason each, and link
to it from the places that currently carry the individual findings. The measurement is a five-line shell
loop over `grep -oP 'SCFN\(\s*\K\w+'`; it belongs in CI next to the `api_map` check so the table cannot
silently go stale (see the build/CI review).

## Nits

- `sciter_app/layout.odin:8-12` — the header comment ends "rather than ship an argument nobody has
  checked, `sciter.api().SciterGetElementLocation` takes the raw flag word - `u32(box) | u32(origin) |
  0x8000`". It reads as though `location` passes `0x8000`; it does not (`layout.odin:76` passes
  `u32(box) | u32(origin)`). It is telling the reader how to get `AS_PPX` through the raw API. Say that:
  "if you want `AS_PPX`, call the raw API with `… | 0x8000`".
- `sciter_app/events.odin:459` — `gesture_event` builds `pos` as `{p.pos.x, p.pos.y}` while
  `mouse_event` (`events.odin:205`) and `exchange_event` (`events.odin:272`) write
  `{i32(p.pos.x), i32(p.pos.y)}`. Same underlying type; pick one spelling.
- `sciter_app/dom.odin:576` — `insert_element`'s `index := Child_Index(-1)` default is spelled as a
  sentinel where the doc says "The default appends". A separate `append_element` proc, or a
  `Maybe(Child_Index)`, would say that in the signature.
- `sciter_app/behavior.odin:228` — the `switch` lists `.FIRST_APPLICATION_METHOD_ID` as a case returning
  nil, which is fine but reads as if 256 were a method rather than a floor. A comment would help.
