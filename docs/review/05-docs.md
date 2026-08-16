# Review: documentation

Scope: `README.md`, `CHANGELOG.md`, all 27 files in `docs/` (sizes and structure measured across all;
read closely: README, PLAN.md, architecture.md, CHANGELOG.md, api.md, dom.md, ENGINE.md).
Date: 2026-08-13

## Summary

Two mechanical checks came back clean, and both are unusual enough to lead with. **Every relative
markdown link in all 29 files resolves** — checked per-file against the real path, zero misses. And
**every `sciter_app.X` name mentioned anywhere in the docs is a real declaration in the package** —
extracted all such names, diffed against the 409 declarations, and the only non-match was the string
`sciter_app.odin` in a filename. For 500 KB of prose written alongside a moving API, that is a better
result than most released libraries manage.

The problems are all structural rather than factual. Every hand-counted number is stale and stale in the
same direction (understated). 500 KB of documentation has no index and no user/maintainer split, so a
newcomer's first decision — which of 27 files to open — is unguided, and four of the largest files are
working notes rather than documentation. `CHANGELOG.md` is 38 KB describing one unreleased version,
which makes it a launch announcement rather than a changelog.

## Findings

### R5-01 — every hand-maintained count is wrong, all of them understating the work  [severity: major]

**Where:** `README.md:11-12`, `docs/PLAN.md:12-16`
**What:** measured against the tree today:

| claim | where | actual |
|---|---|---|
| "twenty-five examples" | `README.md:11` | **29** files in `examples/` |
| "337 tests" | `README.md:11`, `docs/PLAN.md:12` | **364** `@(test)` procs |
| "eleven guides" | `README.md:11` | **27** files in `docs/` (11 may mean a curated subset — undefined) |
| "347 exported procedures" | `docs/PLAN.md:14` | **409** top-level `:: proc` in `sciter_app/` |
| "310 of its 347 … called from a test" | `docs/PLAN.md:14` | not reproducible by any command in the tree |

The `189 ISciterAPI slots` and `16 null` figures, by contrast, are correct and are backed by a runnable
check (`just example api_map`) — which is exactly the difference.
**Why it matters:** counts are the claims a sceptical reader verifies first, they are cheap to check,
and being wrong on all five costs more credibility than the numbers earn. The 310/347 coverage figure is
the project's headline quality claim and it is the one no reader can reproduce. This repository has
already been bitten by a miscounting method — matching `\.Name(` instead of `\.Name\b` undercounts
wrapper coverage badly, because the wrapper is often stored or forwarded rather than called — and
nothing records which method produced 310.
**Fix:** make the numbers generated rather than written. A `just stats` recipe printing example count,
test count, exported-proc count, tested-proc count and doc count; a CI step that fails when a doc
disagrees with it; and the recipe name cited next to each number. Same fix as findings R4-01 and R4-07.

### R5-02 — 27 documents, no index, no user/maintainer split  [severity: major]

**Where:** `docs/` as a whole; `README.md` links a subset inline
**What:** there is no `docs/README.md` and no reading order. The directory listing mixes user
documentation (`getting-started.md`, `dom.md`, `events.md`) with maintainer working notes
(`RESEARCH-METHOD.md`, `BINDGEN-LIBCLANG.md`, `WINDOWS-CHECKLIST.md`), with planning documents
(`PLAN.md` at 41 KB, `PLAN-TESTING-AND-EXAMPLES.md` at 22 KB), with competitive research
(`ALTERNATIVES.md` at 84 KB — the single largest file in the project, larger than `sciter.odin`), and
with a one-page scratch note (`typing.md`, 24 lines, untracked).
**Why it matters:** a newcomer's first decision is which file to open, and the directory gives them no
help. Worse, the biggest files are the least likely to be what they want: `ALTERNATIVES.md` and
`PLAN.md` together are 125 KB and neither teaches the API. Status is claimed in three places that can
disagree — `PLAN.md`, `SDK-PARITY.md` and `CHANGELOG.md` — and finding R2-08 shows this already
happening: the fact that `SciterGetViewExpando`, `SciterGetObject` and `SciterGetElementNamespace` are
dead slots is documented four times, in `api.md`, `dom.md`, `ENGINE.md` and
`calling-between-odin-and-js.md`, and not at all in `SDK-PARITY.md`, whose name promises exactly that.
**Fix:** a concrete split, and a `docs/README.md` index that states it:

**For users of the library** — keep in `docs/`, list in reading order:
`getting-started.md` → `architecture.md` → `api.md` → the topic guides (`dom.md`, `events.md`,
`graphics.md`, `calling-between-odin-and-js.md`, `html-css-js.md`, `resources.md`, `BEHAVIORS.md`,
`EMBEDDING.md`, `deployment.md`) → `UPGRADING.md`, `UPSTREAM-DEFECTS.md`, `JS-RUNTIME.md`.

**For maintainers** — move to `docs/notes/`: `RESEARCH-METHOD.md`, `BINDGEN-LIBCLANG.md`,
`WINDOWS-CHECKLIST.md`, `PLAN.md`, `PLAN-TESTING-AND-EXAMPLES.md`, `ENGINE.md`, `SDK-PARITY.md`,
`typing.md`.

**Neither** — `ALTERNATIVES.md` (84 KB of comparison against other toolkits: valuable, but it is an
essay about the ecosystem, not documentation of this library; it belongs in a blog post or a
`docs/notes/` file with a header saying what it is for), `FLEURY-UI.md` (a stub awaiting content behind
a paywall), `VDOM.md` and `reactor.md` (Sciter's own frameworks — useful, but they document *Sciter*, not
these bindings; say so at the top of each).

### R5-03 — `CHANGELOG.md` is 38 KB describing one unreleased version  [severity: major]

**Where:** `CHANGELOG.md`, whole file; `CHANGELOG.md:8` is the only `## ` heading
**What:** 455 lines, one version section, headed `## Unreleased — v6.0.4.9`. The content is a complete
feature inventory of both packages, restating what `README.md` and `docs/PLAN.md` already say.
**Why it matters:** the question a changelog answers is "what changed between the version I have and the
one I am considering". With one entry there is nothing to answer, so the file has instead become a third
copy of the feature list — and now three documents have to be kept in sync. When v6.0.4.9-2 arrives, the
maintainer either appends a real diff-style entry underneath 400 lines of prose that is no longer about
any particular release, or rewrites the lot.

The versioning *policy* stated at `CHANGELOG.md:3-6` — releases named after the vendored engine, because
"that is the question anyone reading a tag actually has" — is genuinely good and worth keeping visible.
**Fix:** cut the first release entry to what a changelog entry is: what this release contains, in a
dozen bullets, linking to the guides for detail. Move the versioning policy to the top as a short
preamble (it is already there and already short). Move the feature inventory to `README.md` or delete it
as a duplicate of `PLAN.md`. Adopt Keep a Changelog headings (`### Added` / `### Fixed` / `### Known
issues`) so the next entry has a shape to follow.

**Done — and it had got worse first.** The Keep a Changelog headings landed early and the rest did not,
so the file went 455 → 839 lines and 38K → 71K while still describing nothing anyone could install. It
is 167 lines now. What was actually unique in it was the breaking-change list — `Breaking` appeared ten
times in `CHANGELOG.md` and nowhere else in the tree, while every engine fact it carried was already
written on the wrapper concerned, in `UPSTREAM-DEFECTS.md`, or in the guides. So the rewrite keeps a
`### Breaking` section as the top item of `## Unreleased`, summarises Fixed/Added/Changed in a line
each with links out, and cuts the first-release entry to a dozen bullets. Hand-maintained counts are
gone from it too, since `just stats --check` does not gate this file.

The duplication had already produced the failure mode the finding predicted: four documents
(`api.md`, `ENGINE.md`, and `PLAN-TESTING-AND-EXAMPLES.md` twice) cited `CHANGELOG.md`'s known-issues
list as the canonical home of facts that also lived in `UPSTREAM-DEFECTS.md` and on the wrappers. Those
now point at the real home, and `PLAN-TESTING-AND-EXAMPLES.md`'s commenting standard says explicitly
not to record engine behaviour in the changelog.

### R5-04 — the threading rule is load-bearing and lives only in prose asides  [severity: major]

**Where:** referenced from `sciter_app/host.odin:107-109` as "see docs/architecture.md";
`sciter_app/host.odin:74` as "see docs/architecture.md on threading"
**What:** the rule — everything must be called from the thread that ran `init`, and `post_callback` is
the only way across — is stated in comments in `host.odin` and pointed at `architecture.md`. There is no
"Threading" section anywhere in the docs index, no per-proc annotation, and no statement of which
procedures are the exceptions.
**Why it matters:** this is the constraint that turns correct-looking code into intermittent corruption,
and it is the first thing every application with a worker thread runs into — `host.odin:107-109` says so
in as many words. It deserves a heading a reader can find *before* they write the worker thread, not a
cross-reference they meet after. The related rules are scattered the same way: the ownership rules for
`Value` are at the top of `value.odin` (excellent, and reachable only from the source), the element
handle rules at the top of `dom.odin`, the node handle rules at the top of `node.odin`.
**Fix:** one `docs/rules.md` — or a section of `architecture.md` promoted in the index — collecting the
four cross-cutting contracts: thread affinity, `Value` ownership, element/node handle lifetime, and
allocator conventions (which allocator a proc uses for arguments vs results). Each is already written
well somewhere in the source; this is a consolidation, not new writing. It is also the doc that finding
R1-10 (`load`'s undocumented success-path allocation) and R1-06 (`string_from_utf16`'s oversized
allocation) would both belong in.

### R5-05 — `README.md`'s quick start omits the engine's size and the X11 workaround  [severity: minor]

**Where:** `README.md:57-64`
**What:** the quick start is `git clone --depth 1`, `cd`, `just example hello_window`, with Odin and
`just` named as prerequisites.
**Why it matters:** two things a first-time reader meets and the README does not warn about.
`lib/linux/x64/libsciter.so` is **24 MB, tracked in git and not under LFS**, so the "quick" clone is a
24 MB download — the `--depth 1` in the instructions is doing real work and is not explained. And on
X11 this machine's engine segfaults in `XSetICFocus` shortly after a window takes focus; `PLAN.md:22-27`
records it, the workaround is `XMODIFIERS=@im=none`, and the README's quick start — which runs a
windowed example — does not mention it. The very first command a new user runs is the one that hits it.
**Fix:** two sentences in the quick start: the clone is ~24 MB because the engine is vendored (and why
`--depth 1`), and if `hello_window` segfaults on X11, prefix with `XMODIFIERS=@im=none` and see
`docs/UPSTREAM-DEFECTS.md`. Both are already known; neither is where the reader is.

### R5-06 — `SDK-PARITY.md` does not contain the parity table its name promises  [severity: minor]

**Where:** `docs/SDK-PARITY.md` (386 lines)
**What:** the coverage facts are distributed instead: dead slots in `api.md:834-836` and
`dom.md:565-566`, the null-slot count in `architecture.md:54` and four other files, and the thirteen
unwrapped-slot decisions nowhere at all (see finding R2-08 for the full table).
**Why it matters:** "is X available?" is the second question a prospective user has, after "does it
work?". It should have exactly one answer in exactly one place, and the file named for it should be that
place.
**Fix:** put the 176-row slot table in `SDK-PARITY.md` — C name, generated binding, ergonomic wrapper,
and a reason for each exclusion — generated by the same script as the counts in R5-01, and reduce the
four scattered mentions to links.

### R5-07 — `docs/typing.md` is an untracked scratch note in the published docs directory  [severity: minor]

**Where:** `docs/typing.md` (24 lines, untracked per `git status`)
**What:** it is a to-do list addressed to a reviewer — "Analyze the project for where distinct could
help", "is `eventCode` a constrained set of numbers in the C headers?" — sitting alongside 26 finished
documents.
**Why it matters:** it will be committed by accident and then read as documentation. Its questions are
good and worth keeping; they are just not documentation. (Finding 08 in this review set answers them.)
**Fix:** move to `docs/notes/` with the rest of the working notes, or convert to an issue.

## Per-document verdict

| file | size | audience | verdict |
|---|---:|---|---|
| `README.md` | 22K | user | keep — fix counts (R5-01), add clone size + X11 note (R5-05) |
| `CHANGELOG.md` | 38K | user | ~~**rewrite** — one release entry, not a feature inventory (R5-03)~~ done |
| `getting-started.md` | 6K | user | keep — make it the documented entry point |
| `architecture.md` | 12K | user | keep — promote the threading section (R5-04) |
| `api.md` | 51K | user | keep — the reference; move its dead-slot note to SDK-PARITY |
| `dom.md` | 28K | user | keep |
| `events.md` | 21K | user | keep |
| `graphics.md` | 10K | user | keep |
| `calling-between-odin-and-js.md` | 24K | user | keep |
| `html-css-js.md` | 15K | user | keep |
| `resources.md` | 12K | user | keep |
| `BEHAVIORS.md` | 12K | user | keep — the measured intrinsic-behavior map is unique and valuable |
| `EMBEDDING.md` | 16K | user | keep |
| `deployment.md` | 8K | user | keep |
| `UPGRADING.md` | 15K | user | keep |
| `UPSTREAM-DEFECTS.md` | 7K | user | keep — link from README (R5-05) |
| `JS-RUNTIME.md` | 8K | user | keep |
| `SDK-PARITY.md` | 26K | user | keep — but put the actual parity table in it (R5-06) |
| `ENGINE.md` | 20K | maintainer | move to `docs/notes/` |
| `RESEARCH-METHOD.md` | 20K | maintainer | move to `docs/notes/` — genuinely good, wrong shelf |
| `BINDGEN-LIBCLANG.md` | 5K | maintainer | move to `docs/notes/` |
| `WINDOWS-CHECKLIST.md` | 9K | maintainer | move to `docs/notes/` |
| `PLAN.md` | 41K | maintainer | move to `docs/notes/` — fix counts first (R5-01) |
| `PLAN-TESTING-AND-EXAMPLES.md` | 22K | maintainer | move to `docs/notes/` |
| `typing.md` | 1K | maintainer | move to `docs/notes/` (R5-07) |
| `ALTERNATIVES.md` | 84K | neither | move to `docs/notes/` with a header saying what it is |
| `VDOM.md` | 18K | user (of Sciter) | keep, with a header: this documents Sciter's framework, not these bindings |
| `reactor.md` | 14K | user (of Sciter) | same |
| `FLEURY-UI.md` | 10K | neither | stub pending paywalled source — move to `docs/notes/` until it has content |

## What is good, specifically

- **Zero broken relative links** across 29 files, verified per-file.
- **Zero doc-referenced API names that do not exist**, verified against all 409 declarations.
- The measured-behaviour notes are the project's real documentation asset and have no equivalent
  upstream: `BEHAVIORS.md`'s intrinsic-behavior passport map, `value.odin`'s note that `value_isolate`
  does not work on this engine, `layout.odin`'s note that `min_height` ignores its width argument,
  `window.odin`'s five-row table of which window-teardown orders segfault. Whatever reorganisation
  happens, these are what must not be lost.
- `docs/UPSTREAM-DEFECTS.md` existing at all — separating "the engine is wrong" from "we are wrong" is a
  distinction most binding projects never make explicit.
