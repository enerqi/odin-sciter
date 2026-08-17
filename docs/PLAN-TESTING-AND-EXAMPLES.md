# House rules for the examples and the test suite

Everything here is load-bearing convention: how to work in `examples/`, why the test fixture is
duplicated ten times, how to pump the engine from a test, and the commenting standard that makes an
example worth reading. Match it when you add one.

**This file used to be a worklist**, written 2026-08-11 against a tree with 21 examples and 183 tests:
close the coverage gap batch by batch, then build one larger application. That work is done — the tree
is at 31 examples and 404 tests, `workbench` is the larger application, and coverage is every exported
procedure of `sciter_app` reached from a test (`just stats`). The batches, the proposal and their
acceptance boxes are in the history; what survived them is below, because it is the part that applies to
the *next* example rather than to that one.

---

## How to work here

House rules that will otherwise cost you time. All of these are load-bearing.

- **Measure before documenting.** Write a throwaway `@(test)` or a scratch `main` that prints what the
  engine actually does, read it, *then* write the assertion and the prose. Delete the probe. Across
  every API area in this repository this has caught a wrong assumption — including several taken
  straight from the C headers. See [`RESEARCH-METHOD.md`](./RESEARCH-METHOD.md).
- **Do not `git commit`.** The repository owner curates commits. Leave the tree dirty and report what
  changed.
- **Windowed runs need `XMODIFIERS=@im=none`** on X11 — the engine segfaults in `XSetICFocus`
  otherwise. Treat `timeout N ./target/debug/x.exe` returning 124 as the pass.
- **`just format` is clean and gated.** It exits 0, and a second run against a formatted tree changes
  nothing. `just format-check` is the non-writing version and runs in CI, so leaving something
  unformatted fails the build rather than surfacing in someone else's diff.
- **`events` timer tests flake under load.** Re-run on a quiet machine; don't chase.
- **`just example-tests` uses `set -e`**, so one failure skips every suite after it. Run the remainder
  individually when hunting.
- **Tests that need a window gate themselves** on `DISPLAY`/`WAYLAND_DISPLAY` and share one `g_window`
  across the suite. Copy the harness from `examples/behavior.odin` or `examples/named_behavior.odin`.
  Allocate anything the engine keeps (the window, handlers) from `runtime.default_allocator()` or the
  test runner reports it as a leak.
- **A test that creates a window calls `sciter_app.init()` first**, even in a file whose harness is
  otherwise windowless — `dom_walk`'s windowed helper is the shape. Without it everything passes and the
  *process* faults at exit; a debug build now traps in `create_window` instead.
- **`ODIN_TEST_THREADS=1` is required** — already in the `example-test` recipe.

## The duplicated fixture is a stated cost, not an oversight

`test_window` is written out in ten files. `have_display`, the `load_engine()` boilerplate and the
`runtime.default_allocator()` swap are repeated at the same scale. That is the price of the build model
and it is worth naming so nobody "fixes" it by accident:

**Every example is a standalone single file**, built and tested with `odin build examples/x.odin -file`
and `odin test examples/x.odin -file`. `-file` compiles exactly one file as its own `package main`, so
there is no second file for a shared helper to live in. A helper package (`examples/harness/`) would
work for the tests and would break the property the examples exist for: that one file, readable top to
bottom, is a complete program you can copy out of the repository. `src/prelude.odin` is not an option
either — it is `bindgen.sjson`'s `imports_file`, pasted verbatim into the generated `sciter.odin`.

The cost is real and has already been paid once: the skip messages have drifted apart between files, and
a change to the fixture is a ten-file edit. When you make one, make it in all ten.

## `docs/snippets/` is compiled

**`docs/snippets/snippets.odin` is every Odin code block in the guides**, wrapped in just enough
scaffolding to compile, and `just check` type-checks it. That is what stops the documentation from
rotting silently, and it is worth knowing about before you write a code block: add the snippet there,
in the section matching the guide, and the guide's block becomes something CI keeps honest.

**The correspondence is maintained by hand, and it has drifted once.** `docs/dom.md`'s build-and-insert
listing passed an `Owned_Element` where an `Element` was wanted while its compiled twin was correct, so
the guide showed code that does not compile. When you change one, change the other — and prefer writing
the block in `snippets.odin` first, where the compiler is watching.

**`spike/` used to be the opposite, and is now gone.** `spike/skeleton`, `spike/windowless` and
`spike/smoke` were 752 lines of development scratch programs that `just format` formatted and nothing
compiled - so they could have stopped building without anyone noticing - and what they demonstrated is
covered by `examples/windowless.odin` and `examples/hello_window.odin`. Deleted; they are in the
history. The one part worth keeping was the X11 drag source, now `tools/xdnd_source.py`.

**The rule that outlives them: Odin in this tree is either compiled or deleted.** `examples/` builds,
`docs/snippets/` type-checks, the tests run. A new directory of Odin that nothing in `just check`
touches is a directory that will rot.

## Advancing the engine in a test

The engine has no "quiesce" call, so a test that waits for the engine to do something has to pump it.
Three spellings appear in the suite — a fixed number of `run_once` turns, `heartbeat` in a loop, and
`time.sleep`. Prefer, in order:

1. **Pump until a predicate, with a turn cap.** `for i in 0 ..< 200 { if done() { break }; run_once() }`
   and then assert on the predicate. Robust against a slow machine, and it fails as "the thing never
   happened" rather than as a mystery.
2. **A fixed number of turns**, when there is nothing to predicate on — a "nothing should arrive" test.
3. **`time.sleep`** only where the engine's own clock is the thing under test, as in the timer tests.

The known-flaky timer tests are what option 3 costs, and they are why 1 is the default.

## The commenting standard

This is what makes the work useful to somebody who has not used Sciter. Match the existing files.

- **Every example opens with a header comment** that says what concept it teaches, how to run it, and —
  crucially — *what surprised us*. See `examples/named_behavior.odin` for the shape: six numbered
  measured rules before a line of code.
- **Test names are sentences.** `test_removing_the_element_detaches_the_behavior`, not `test_detach_2`.
  A reader scanning `just example-test x` output should learn the API's rules from the names alone.
- **Each test's comment says what rule it pins and why anyone cares**, not what the code does. "Rule 3:
  the engine keeps its own names. This is the one that decides whether a `behavior:` name of your own
  can shadow a built-in — it cannot."
- **Write down engine behaviour that is surprising, wrong, or undocumented** in the example header and
  in the wrapper's doc comment; where it is an engine defect, add it to
  [`UPSTREAM-DEFECTS.md`](./UPSTREAM-DEFECTS.md) — and keep a characterization test that fails loudly
  if a future engine fixes it. Not in `CHANGELOG.md`: that file records what changed, not what is true,
  and a fact kept in two places is a fact that will disagree with itself.

## Acceptance, for a new example or a batch of tests

The house checklist. [`SDK-PARITY.md`](./SDK-PARITY.md) points at this list and adds its own row about
keeping its tables current.

- [ ] the probe that established the behaviour was run, and its result is recorded — including when it
      contradicted the headers
- [ ] anything measured that contradicts the headers is in the example header, the wrapper's doc comment,
      and — where it is an engine defect — [`UPSTREAM-DEFECTS.md`](./UPSTREAM-DEFECTS.md)
- [ ] `just check` passes — both packages, `docs/snippets`, every example
- [ ] `just example-tests` green in one run on a quiet machine
- [ ] a new windowed example runs headless-ish: `XMODIFIERS=@im=none timeout 15 ./target/debug/NAME.exe`,
      exit 124
- [ ] `just format-check` clean, and `just stats --check` still agrees with the docs
- [ ] nothing committed — report the dirty tree
