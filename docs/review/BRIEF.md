# Shared brief — deep review pass, 2026-08-13

Read this before starting your assigned angle.

## What the project is

Odin bindings for Sciter.JS 6.0.4.9 (embeddable HTML/CSS/JS engine, single ~25MB .so).

- `sciter.odin` (2769 lines) — **generated** by `just bindgen` from `external/sciter/include/*.h`.
  Do not propose hand-edits to it; propose changes to `bindgen.sjson` instead, and say so explicitly.
- `sciter_app/*.odin` (~6600 lines) — hand-written ergonomic layer. This is the real review target.
- `src/prelude.odin` — shared helpers.
- `examples/*.odin` (~23k lines) — 25 examples, each doubling as the test suite (337 `@(test)` procs).
- `docs/*.md` — 29 guides. `docs/PLAN.md` is the status-of-truth doc, `docs/SDK-PARITY.md` tracks
  C-API coverage, `docs/UPSTREAM-DEFECTS.md` records engine bugs.
- `justfile` — all build/test/run entry points. `just example NAME`, `just example-tests`, `just check`.

## Ground rules

1. **Do not modify any code, doc, or config file.** Read-only, except the single markdown file you
   are told to write. No `git commit`, no `just format`, no edits to `sciter_app/` or `examples/`.
2. **Verify before asserting.** The vendored headers in `external/sciter/include/` are the authority
   on the C API. If you claim a wrapper misuses the API, quote the header line that proves it.
   Assumptions about this engine have been wrong every time; headers beat intuition.
3. **Cite `file.odin:LINE` for every finding.** A finding without a line number is not a finding.
4. Windowed examples segfault on this X11 box inside the engine's input-method code. That is a known
   upstream issue (`XMODIFIERS=@im=none` works around it), not a binding bug. Do not report it.
   Timer tests in `sciter_app/events.odin` flake under load — pre-existing, do not report.
5. Prefer running things (`just check`, `just example-test NAME`) over speculating, but do not spend
   more than a few minutes on any one build.
6. Don't report style nits that `odinfmt` owns. Report things that change behaviour, correctness,
   performance, safety, or a reader's understanding.

## Output format

Write exactly one file, at the path you were given, structured as:

```markdown
# Review: <angle name>

Scope: <files you actually read>
Date: 2026-08-13

## Summary

<5-10 lines. What is good, what is the single biggest problem.>

## Findings

### R<N>-01 — <one-line title>  [severity: critical | major | minor | nit]

**Where:** `path/file.odin:123`
**What:** <the defect, stated once>
**Why it matters:** <concrete failure or cost>
**Fix:** <specific, actionable>

...
```

Use your angle's prefix for `<N>` (given in your task). Order findings most-severe-first. If an angle
turns up nothing at a severity, say so — an honest "this area is clean" is a useful result. Do not
pad. Do not include praise sections beyond the summary line.

## Severity guide

- **critical** — memory corruption, UB, crash, data loss, or a documented claim that is false in a way
  that will bite a user immediately.
- **major** — wrong results in a reachable case, a leak, a missing API that blocks real use, a doc
  section that is materially misleading.
- **minor** — inefficiency, awkward API, missing test for a real branch, incomplete doc.
- **nit** — naming, comment wording, cosmetic inconsistency. Keep these to a short list at the end.
