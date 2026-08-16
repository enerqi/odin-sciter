# Deep review — 2026-08-13

A multi-angle review of the whole repository: ~10.4k lines of bindings, ~23k lines of examples, 500 KB
of documentation, and the build/CI around them. Nine angles, each in its own file, each finding cited
to `file:line` and — where it concerns the C API — checked against the vendored headers rather than
against memory.

**This review is closed.** Every finding is fixed and every recommendation implemented; what is kept
here is the reasoning and the rejected alternatives, which the code does not record. It is an archive,
not a work queue — the counts and file:line references below are as they were on 2026-08-13 and are not
maintained. For the current numbers, `just stats`.

| # | angle | file | findings |
|---|---|---|---:|
| 1 | Value marshalling, SOM, atoms, archive, embed | [`01-value-som.md`](01-value-som.md) | 10 |
| 2 | DOM, nodes, events, behaviors, layout | [`02-dom-events.md`](02-dom-events.md) | 8 |
| 3 | Windowing, host, graphics, video, windowless, requests | [`03-window-graphics.md`](03-window-graphics.md) | 6 |
| 4 | Examples and the 364-test suite | [`04-examples-tests.md`](04-examples-tests.md) | 7 |
| 5 | Documentation | [`05-docs.md`](05-docs.md) | 7 |
| 6 | C-API parity and feature coverage | [`06-api-coverage.md`](06-api-coverage.md) | 4 |
| 7 | Build, codegen, CI, repo hygiene | [`07-build-ci.md`](07-build-ci.md) | 7 |
| 8 | Type safety and Odin idiom | [`08-typing-idiom.md`](08-typing-idiom.md) | 5 |
| 9 | Memory safety, resource lifetimes, ownership | [`09-memory-safety-ownership.md`](09-memory-safety-ownership.md) | 10 |

Angle 9 was written after the first eight and reviews the same tree with their fixes applied, so its
findings are the ones that survived that pass rather than a second opinion on it.

**[`10-threading.md`](10-threading.md) is not part of this review.** It is a separate pass dated
2026-08-16 over the threading subsystem, which landed on 2026-08-15 — a day *after* the nine closed, and
so was reviewed by none of them. Eight findings, four of them major — the eighth is what the repaired
thread guard caught on macOS CI an hour after landing; seven are fixed, and the one still
open needs a live video destination before it needs a change.

**[`11-partial-enforcement.md`](11-partial-enforcement.md) is its sequel**, same date. Angle 10's main
finding was a *shape* — an invariant enforced at a chokepoint that only saw some of the paths, with
nothing measuring the fraction — so this sweeps the other three invariants of that shape. All three
hold; none was being held. One finding, and a gate.

The engine and toolchain behaviour this review measured is **not** kept here: each fact was written
where it applies — `rules.md`, `gotchas.md`, and the doc comments on the wrappers concerned — which is
where someone hits it. A handoff note holding a second copy was deleted once the last of them landed.

## Status — the original six are fixed

Every item this section used to list has landed, along with the rest of angles 1–8 and all ten of
angle 9's findings. The combined patch is not kept in the tree; it is commit `743a5b0`.

| was | now |
|---|---|
| **[R1-01]** `asset_get` / `asset_set` called through `som_property_def_t` without reading its tag — a constant's value decoded as a function pointer and called | the tag is checked before either branch; a constant has no setter and says so (`sciter_app/som.odin:380`, `:424`) |
| **[R7-02]** CI told macOS maintainers to vendor at `lib/macos/`, the loader searched `lib/macosx` | both say `lib/macosx`, and the job notes why (`.github/workflows/ci.yml:242`) |
| **[R3-01]** `graphics_api()` / `request_api()` returned nil before `load()`, ~90 procs dereferenced it | both assert with the same sentence `sciter.api()` uses (`sciter_app/graphics.odin:74`, `sciter_app/request.odin:90`) |
| **[R2-01]** `sort_children` clamped `last` but not `first` | both ends clamped to the child count (`sciter_app/dom.odin:719`) |
| **[R7-01]** CI never ran `just lint` | it does, over both packages *and* all 30 examples (`.github/workflows/ci.yml:63`) |
| **[R1-02]** `load_embedded` reused a cached engine on a size match | the cached file's contents are hashed against the blob; the hash also names the directory (`sciter_app/embed.odin:53`) |

## Still open — nothing from this review

1. ~~**Windows.**~~ Both breaking changes and the leak gate have run on a real desktop; the sweep is
   clean and `docs/WINDOWS-CHECKLIST.md` is a measurement record now. macOS followed, in CI.
2. ~~**The repository-size decision**~~ (R7-03): actioned, and further than the finding proposed. No
   engine is committed on any platform, and the three that were are out of history —
   `git filter-repo`, `.git` 41 MB → ~2 MB. `docs/UPGRADING.md` has the decision and the runbook. The
   finding's timing argument was the correct one: cheap with one binary, a rewrite with three.

Closed since: the five procedures no test reached — `set_option`, `data_ready_async`, the `set_state`
group and the two `draw_rounded_rect_*` members — now have tests, and coverage is 383 of 383. Each of
the four turned up something the headers do not say, which is the argument for closing coverage gaps
rather than annotating them: a second `data_ready_async` on an answered request id segfaults;
`.SMOOTH_SCROLL` needs a window and four other options are refused outright; a compound literal cannot
be passed through the `set_state` overload group. All three are recorded on the wrappers.

## The gates these findings turned into

A finding that CI does not check is a finding that comes back — it did, once, within this review.

```
just check            # both packages, doc snippets, all 30 examples build
just lint             # -vet over both packages and all 30 examples
just cross-check      # the same, type checked for windows_amd64 and darwin_amd64
just check-ownership  # allocator ⇒ owned, otherwise borrowed
just parity --check   # C-API slot coverage against the baseline
just stats --check    # the counts README.md and docs/PLAN.md quote
just example-tests    # 381 tests across 24 files
just leak-check       # the engine-resource leak gate (needs -debug and a display)
```

## Cross-cutting themes

**Counts are hand-maintained and all of them have drifted.** README says 25 examples / 337 tests /
eleven guides; the tree has 29 / **364** / 27. `PLAN.md` says 347 exported procs; there are **409**. The
one number that is right — 189 slots, 16 null — is the one backed by a runnable check
(`just example api_map`). The pattern is the finding: numbers that a command produces stay true and
numbers that a person types do not. Appears as R4-01, R5-01, R4-07, R6-01, R6-04. **One fix serves all
five:** a `just stats` / `just parity` pair that emits the counts and the slot table, run in CI, cited
next to each number in the docs.

**Coverage is essentially complete and nothing says so.** Measured: 163/163 reachable `ISciterAPI`
slots wrapped, 70/70 usable graphics slots, 29/29 request slots. Every one of the thirteen unwrapped
main-table slots is a deliberate exclusion — three are dead slots on this engine, three are superseded
by wide/CB variants, four are Windows window-proc plumbing, two are native-child/EGL features. The dead
ones are documented four times across four files and not at all in `SDK-PARITY.md`, whose name promises
that answer; the six mechanical exclusions are written down nowhere. → [`06`](06-api-coverage.md)

**The measured-behaviour notes are the project's real asset.** `value_isolate` does not work on this
engine. `min_height` ignores its width argument. The `.RAW` image encoding is BGRA, not the header's
`[a,b,g,r]`. There is exactly one window-teardown order that does not segfault, and there is a
five-row table of the four that do. A method call reaches only handlers on that exact element. None of
this exists upstream, all of it was measured, and it is what makes these bindings worth more than the
headers. Whatever reorganisation happens (see R5-02), these must not be lost — and the discipline that
produced them is why so few real defects turned up.

**Documentation is factually accurate and structurally unnavigable.** Zero broken relative links across
29 files, and zero `sciter_app.X` names in the prose that are not real declarations — both checked
mechanically. But 27 files with no index mix user guides, maintainer notes, two 40 KB+ planning
documents and an 84 KB ecosystem essay, and `CHANGELOG.md` is 38 KB describing one unreleased version.
→ [`05`](05-docs.md) — the index landed as [`docs/README.md`](../README.md), and `CHANGELOG.md` is now
167 lines that record changes only.

**Cross-cutting contracts live in source comments, not in the docs.** Thread affinity, `Value`
ownership, element/node handle lifetime, allocator conventions — each is written well, at the top of the
file that implements it, reachable only by reading that file. The threading rule in particular is the
one that turns correct-looking code into intermittent corruption, and it appears as a cross-reference in
two comments. R5-04 proposes consolidating the four into one `docs/rules.md`; R1-06 and R1-10 are both
findings that would live there.

**Small allocator sloppiness in the hottest paths.** `string_from_utf16` returns a string whose backing
allocation is up to 3× its length (R1-06) and it is on the return path of every string leaving the
engine. `save_image` allocates scratch from the caller's allocator and then copies (R3-03). The default
debug-output handler allocates per message from a `temp_allocator` nothing frees (R1-04). None is
dangerous; together they are the difference between a binding that behaves under an arena and one that
only behaves under the heap.

## What this review did not do

- Angles 1–8 did not run the test suite or any example — they are static plus header cross-checks, plus
  mechanical measurement over the tree. Angle 9 is the exception: every claim it makes about engine or
  Odin behaviour was measured with a throwaway probe, and the probes are described inline.
- Did not read all 23k lines of `examples/`; that angle is measurement-led, with five files read closely
  and the rest sampled. The per-file assertion-density table in [`04`](04-examples-tests.md) is complete.
- Did not audit `sciter.odin` line by line. It is generated, `bindgen.yml` proves regeneration is
  byte-identical, and `api_map` proves the layout matches the shipped engine — so the audit that matters
  is already automated. Spot checks for generated-but-unusable declarations found none.
- Did not evaluate Windows or macOS behaviour, only the paths and the type-check story.

Nothing in this directory changes any source, doc or config file. Findings are ordered most-severe-first
within each angle, against the severity guide the angles were written to:

- **critical** — memory corruption, UB, crash, data loss, or a documented claim that is false in a way
  that will bite a user immediately.
- **major** — wrong results in a reachable case, a leak, a missing API that blocks real use, a doc
  section that is materially misleading.
- **minor** — inefficiency, awkward API, missing test for a real branch, incomplete doc.
- **nit** — naming, comment wording, cosmetic inconsistency.
