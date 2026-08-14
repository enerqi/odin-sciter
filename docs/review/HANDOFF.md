# Handoff — memory safety, lifetimes and ownership

Written 2026-08-14, at the end of the session that produced `09-memory-safety-ownership.md` and the
thirteen commits after it. Read this first if you are picking the work up; the review file is the
findings, this is the state.

---

## Where things stand

All of the review's findings are fixed and all four of its ownership recommendations are implemented.
The work is thirteen commits on top of `2a08d41 ci fix`:

| commit | what |
| --- | --- |
| `8fdd349` | the eight review findings, `scoped_*`, `just check-ownership` |
| `41156b5` | the call family reports failures the way `eval` does |
| `466facf` | over-releasing a borrowed element handle segfaults |
| `9bf50fd` | run the ownership check in CI |
| `2d3bf1e` | `http_request`'s temp-allocator arguments are safe, measured |
| `97d2b67` | `distinct Owned_Request` |
| `e4acfb0` | changelog and the documented counts |
| `d562c61` | debug tracking for engine-side resources |
| `a19208c` | `distinct Owned_Element` |
| `4995925` | the three unmeasured ownership claims, measured |
| `f6791d3` | the leak gate, and the two instrumentation gaps it found |
| `76648d7` | `Value_Scope`, and Windows notes |
| `c5e4fa2` | the examples pass `-vet`, and CI checks them |

**These SHAs are post-rewrite.** The messages were rewritten to drop a `Co-Authored-By` trailer at the
user's request; the trees are byte-identical to the pre-rewrite versions (verified: same tree hash,
empty `git diff`). The force-push has since happened — `origin/master` is at `c5e4fa2`. A backup of the
pre-rewrite branch is still at `refs/original/refs/heads/worktree-memory-safety-review` and can be
deleted.

## Still open

1. **Windows.** Two breaking changes (`Owned_Element`, `Owned_Request`) and the leak gate have never run
   there. `docs/WINDOWS-CHECKLIST.md` has a section listing exactly what to check and why, including
   which half of the new `set_option` test is expected to answer differently.
2. **The repository-size decision** (review finding R7-03): the 24 MB engine is in git with no LFS, and
   both ways out are cheap now and expensive after a second binary lands. Written up in
   `docs/UPGRADING.md`; deliberately not actioned, because it rewrites history.
3. **The worktree** `.claude/worktrees/memory-safety-review` has nothing unique left in it. Safe to
   remove.

Closed since this was written: `docs/review/README.md` has the row for `09` and a status table in place
of "fix these first"; `docs/review/` and `docs/typing.md` are tracked, which is what had blocked it; and
the five procedures no test reached now have tests, taking coverage to 383 of 383. Each of those four
subjects produced a measured fact — a second `data_ready_async` on an answered request id **segfaults**,
`.SMOOTH_SCROLL` needs a window while four other options are refused outright, `.SET_INIT_SCRIPT`
replaces rather than accumulates and is copied by the engine, and a compound literal cannot be passed
through an overload group. All are recorded on the wrappers.

## What not to re-derive

Everything below was measured on the vendored 6.0.4.9 engine this session. The probes are described in
`09-memory-safety-ownership.md`; do not re-litigate these from the headers.

**Engine behaviour**

- `eval`, `call`, `call_function` and `call_method` share one failure model: **the error code answers
  "could I call it", the returned Value answers "did it work".** A thrown exception is `err = nil` plus
  an `.ERROR`-unit string carrying the message and a stack trace; a name nothing defines is a real error
  code with an `.UNDEFINED` result. `value_is_error` is the test.
- **SOM is the exception**: an engine asset's methods answer a plain `BOOL`/`INT`, never an error string.
  `value_is_error` on an `asset_call` result is wrong.
- A discarded string-bearing Value leaks the engine's whole allocation: **390 MB over 2000 evals** of a
  100 kB string, against 76 kB cleared.
- Over-releasing a **borrowed** handle is a crash, not a leak: one spurious `unuse_request` segfaults,
  `unuse_element` takes two. Every one of those calls returns `.OK` first.
- `http_request` copies the URL and every parameter during the call, so the temp allocator is safe there
  despite the request being asynchronous. Verified with a poisoned arena and a canary.
- `value_from_function`'s record is freed by the engine exactly once.
- `GET_VALUE` / `SET_VALUE` own their Values in the directions `docs/rules.md` §2 claims.
- `set_text` on a **detached** clone is `.PASSIVE_HANDLE`, even though the clone holds a reference.
  Insert first, then write.

**Odin and toolchain behaviour**

- `@(require_results)` rejects a bare `producer()` and **accepts `_, _ = producer()`** — so it does not
  catch the discarding form that leaks. `@(deferred_out)` fires on both, which is why `scoped_*` is
  built on it.
- **An Odin test binary has no end-of-run hook.** `@(fini)` does not run in one, and neither does a libc
  `atexit` handler, because the runner leaves through `os.exit`. That is why the leak gate is a program
  (`examples/leak_sweep.odin`) and not a test.
- A zero-valued `[dynamic]T` adopts `context.allocator` at its first `append` and ignores any allocator
  stored beside it. This was the `save_image` bug.
- `mem.Tracking_Allocator` frees by pointer and ignores the size a `delete` reports, so a
  size-mismatched free raises nothing there.
- `utf16.decode_to_utf8` bounds-checks, so a fixed decode buffer truncates rather than overflowing.

## The gates, and how to run them

```
just check              # both packages, doc snippets, all 30 examples build
just lint               # -vet over both packages AND all 30 examples
just check-ownership    # allocator ⇒ owned, otherwise borrowed
just parity --check     # C-API slot coverage against the baseline
just stats --check      # the counts README.md and docs/PLAN.md quote
just example-tests      # 381 tests across 24 files
just leak-check         # the engine-resource leak gate (needs -debug and a display)
```

All of them run in CI. Three environment notes that cost time if missed:

- `XMODIFIERS=@im=none` for anything that makes a window, or the engine segfaults in its input-method
  code. This is an upstream bug, not a binding one.
- `SCITER_LIB=<repo>/lib/linux/x64` when running a binary from outside the repository root.
- `examples/events.odin`'s timer tests **flake under load**. Confirmed pre-existing by running master's
  own binary three times: one run failed three tests, two were clean. Do not chase them.

## The shape of the ownership story

Four mechanisms, and they are complementary rather than alternatives:

- **`scoped_*`** (`sciter_app/scoped.odin`) — `@(deferred_out)` releases at the end of the calling
  scope, including when the caller discards the results. For the single value.
- **`Value_Scope`** (`sciter_app/value_scope.odin`) — for a batch whose size is decided at run time,
  which `scoped_*` cannot cover because inside a loop "the calling scope" is one iteration.
- **`Owned_Element` / `Owned_Request`** — `distinct` types so that releasing something you never held
  does not compile. This is the only one that addresses the **crash**; the others address leaks.
- **`sciter_app/tracking.odin`** — a debug-only ledger for what the allocator cannot see. Handles are
  tracked exactly, with the acquiring site; Values are counted rather than identified, because a Value
  is passed by value and `value_copy` makes two of them share a payload.

The asymmetry that justifies all of it: **an under-flow can be caught the instant it happens and a leak
cannot**, because a resource never released looks exactly like one not released yet. So the type system
takes the crash and the ledger takes the leak.

## House rules picked up along the way

- The user integrates branches and force-pushes themselves. Do not merge or push.
- **No `Co-Authored-By` trailer in commit messages.**
- Measure before documenting. Every "the header says" in this codebase that was checked this session had
  something wrong with it, and the ones that were right are now recorded as measured rather than assumed.
- A check that CI does not run enforces nothing — that was a finding in the previous review pass and it
  recurred once in this one, with `just check-ownership`.
