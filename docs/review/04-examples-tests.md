# Review: examples and the test suite

Scope: all 29 files in `examples/` (measured across the whole set; read closely:
`hello_window.odin`, `dom_walk.odin`, `behavior.odin`, `video.odin`, `call_odin_from_js.odin`),
`docs/PLAN-TESTING-AND-EXAMPLES.md`, `justfile`.
Date: 2026-08-13

## Summary

I went in expecting the usual finding — that a large test count is mostly smoke tests that would pass
against a stub — and the measurements do not support it. There are **364** `@(test)` procedures and
**2354** `testing.expect*` calls, 6.5 assertions per test. Of those, **1774 are `expect_value`**, i.e.
comparisons against a concrete expected result, and only **420 (17.8%)** are the `expect_value(t, err,
nil)` shape. Twenty-four assertions in the whole suite are bare `x != nil`. Nineteen distinct error
variants across five error enums are asserted by value, so failure paths are genuinely exercised rather
than merely reachable. This is a real test suite.

The examples are also genuinely didactic rather than merely exhaustive: `hello_window.odin` numbers its
steps and calls out what is deliberately *absent* ("no GTK on Linux, no Win32 message loop, no Cocoa"),
and every file opens with a comment saying what the reader should learn and how to run it.

Three things are worth fixing. The published test count is stale everywhere (337 vs the real 364). The
same `test_window` harness is hand-written in ten separate files with no shared home. And the density
numbers have a floor: five files sit below 4.2 assertions per test, and `worker_thread.odin` at 2.8 is
where the suite is thinnest against the hardest-to-test subsystem.

## Findings

### R4-01 — every published test count is wrong, and they are wrong in the same direction  [severity: major]

**Where:** `README.md:12`, `docs/PLAN.md:12`, and any other doc quoting a suite size
**What:** measured now: `grep -c '@(test)' examples/*.odin` totals **364**. `README.md:12` says "337
tests", `docs/PLAN.md:12` says "`just example-tests` runs 337 `@(test)` procs". `README.md` also says
"twenty-five examples"; there are 29 `.odin` files in `examples/`, of which 28 declare tests or a
`main`.
**Why it matters:** a count is the one claim in a document that is trivially checkable and therefore the
one a sceptical reader checks first. Being 27 tests light also undersells the work. More importantly it
establishes that these numbers are hand-maintained, which means the *ratio* claims near them —
`docs/PLAN.md:14-15`'s "310 of its 347 exported procedures called from a test" — are equally likely to
have drifted, and those are the ones nobody can check by eye.
**Fix:** generate the numbers. A `just stats` recipe emitting test count, example count, exported-proc
count and covered-proc count, plus a CI check that fails when a doc's number disagrees, turns four
hand-maintained claims into one script. Until then, correct them and add a comment next to each saying
which command produces it.

### R4-02 — `test_window` is written ten times  [severity: major]

**Where:** ten files define a proc literally named `test_window`, including
`examples/dom_walk.odin:246`, and `examples/workbench.odin`, `behavior.odin`, `events.odin`,
`input.odin`, `graphics.odin` and others
**What:** each is the same fixture: check for a display, `load_engine()` or `fail_now`, lazily create a
process-lifetime window under `runtime.default_allocator()` so the test runner's tracking allocator does
not report the engine's retained argv as a leak, cache it in a file-local `g_window`. The boilerplate
around it is repeated at the same scale: `load_engine()` appears 63 times across 26 files,
`sciter_app.init()` 38 times across 22, `set_default_debug_output` in 25 files, `create_window(` 41
times across 21.
**Why it matters:** the fixture encodes two pieces of hard-won knowledge — the allocator swap and its
reason, and the display-absent skip — and there are ten copies that can drift apart. They already differ
in their skip messages. When the argv leak (finding R1-03) is fixed, ten files need editing to drop the
workaround. A newcomer reading a second example sees the same forty lines again and cannot tell what is
essential to *that* example.

Note that `src/prelude.odin` is not the place for it: that file is `bindgen.sjson`'s `imports_file`,
pasted verbatim into the generated `sciter.odin`, and it is imported by zero examples. So there is
currently no shared-helper home at all.
**Fix:** add `examples/harness/` (or `examples/common.odin` if the single-file-per-example build model
allows it) holding `test_window`, `have_display` and the debug-output setup, and have the examples
import it. If the constraint is that each example must be a standalone `odin run <file> -file`
demonstration — which `hello_window.odin`'s header suggests is deliberate — then say so in
`docs/PLAN-TESTING-AND-EXAMPLES.md` and accept the duplication as a stated cost rather than an accident.

### R4-03 — assertion density has a floor, and it is lowest where testing is hardest  [severity: minor]

**Where:** measured per file; the bottom of the distribution
**What:**

| file | tests | assertions | per test |
|---|---:|---:|---:|
| `worker_thread.odin` | 5 | 14 | 2.8 |
| `archive.odin` | 6 | 20 | 3.3 |
| `custom_loader.odin` | 9 | 34 | 3.8 |
| `graphics_gallery.odin` | 50 | 196 | 3.9 |
| `video.odin` | 14 | 58 | 4.1 |
| … | | | |
| `dom_walk.odin` | 71 | 606 | 8.5 |
| `windowless.odin` | 12 | 106 | 8.8 |
| `sqlite_extension.odin` | 7 | 64 | 9.1 |

**Why it matters:** the two extremes are informative in opposite ways. `graphics_gallery.odin` at 3.9 is
fine — 50 tests each drawing one primitive and checking a few pixels via the `.RAW` encoding trick
documented at `sciter_app/graphics.odin:192-195` is exactly the right shape, and low density there is
the design. `worker_thread.odin` at 2.8 across 5 tests is not: cross-thread delivery through
`post_callback` is the subsystem with the most ways to be subtly wrong (ordering, `heartbeat` vs
`run_once` delivery, the dropped-message cases), `sciter_app/host.odin:126-135` records four measured
properties of it, and 14 assertions is not enough to pin four properties plus the happy path.
`archive.odin` at 3.3 is the other one worth a look, since archives are the shipping story.
**Fix:** treat the four measured properties in `host.odin:126-135` as a test checklist — ordering
preserved, `heartbeat` delivers, a window with no host handler drops silently, a nil window drops
silently — and add the ones that are missing. Each is a few lines and each pins a claim the docs already
make.

### R4-04 — `Api_Error.Asset_Failed` is never asserted anywhere  [severity: minor]

**Where:** `sciter_app/sciter_app.odin:49`; producers at `sciter_app/som.odin:214` and
`sciter_app/som.odin:223`
**What:** of the eleven `Api_Error` variants, ten appear in an assertion somewhere in `examples/`.
`Asset_Failed` appears in none — it is produced only by `set_global_asset` and `release_global_asset`
failing, and no test drives either to failure.
**Why it matters:** small in itself, but it is the one error branch in the SOM path with no coverage, and
SOM is where finding R1-01 lives. A test that makes `SciterSetGlobalAsset` refuse — the obvious
candidate is publishing an asset whose class has a name the engine rejects, or publishing after the
engine has shut down — would also be the natural place to add coverage for the constant-property case
once R1-01 is fixed.
**Fix:** one test in `examples/call_odin_from_js.odin`, next to the existing asset tests at
`call_odin_from_js.odin:707-738`.

### R4-05 — seventeen of the 24 test-bearing files depend on wall-clock or pump-turn timing  [severity: minor]

**Where:** `time.sleep` / `run_once` / `heartbeat` appear in 17 files; the heaviest are
`examples/workbench.odin` (21 occurrences), `examples/windowless.odin` (17) and `examples/input.odin`
(13)
**What:** the engine has no "quiesce" primitive, so tests advance it by pumping a fixed number of turns
or sleeping a fixed duration and then asserting.
**Why it matters:** this is unavoidable given the API — there is genuinely nothing else to wait on — and
it is not a defect in the tests so much as a property of the suite that should be written down. The
known flaky timer tests are the visible symptom, and the memory of this project already records them as
pre-existing. What is missing is a stated convention: is the rule "pump N turns", "pump until predicate
or timeout", or "sleep"? All three appear.
**Fix:** put one `pump_until(window, predicate, timeout)` helper in the shared harness proposed in
R4-02 and convert the fixed-count sites to it. A predicate with a timeout is strictly more robust than a
fixed count and is not more code at the call site. Document the convention in
`docs/PLAN-TESTING-AND-EXAMPLES.md`.

### R4-06 — file-local `g_window` makes tests within a file order-coupled, by design, undocumented  [severity: minor]

**Where:** `g_window` is a package-level global in 15 files; the lazy-init pattern at
`examples/dom_walk.odin:255`
**What:** the first test to call `test_window` creates the window and every later test in that file
reuses it, with whatever document and state the previous test left behind. Since each example builds as
its own package, there is no cross-file contamination — the coupling is within a file only.
**Why it matters:** it is the right trade (creating a window per test would be slow and, per
`sciter_app/window.odin:250-273`, closing them is itself hazardous), but it means a test that mutates the
document can break a later one and the failure will point at the wrong test. `dom_walk.odin` has 71
tests sharing one window. The reuse is explained at the allocation level (`dom_walk.odin:256-259`
explains the allocator swap) but the *sharing* and its consequence for test independence is not stated.
**Fix:** one comment at each `g_window` declaration: the window is shared by every test in the file, so
a test that changes the document must restore it — and a convention for how (a `set_html(root, DOC)`
reset at the top of any test that mutates).

### R4-07 — `PLAN.md`'s coverage claims are unverifiable as written  [severity: minor]

**Where:** `docs/PLAN.md:14-16`
**What:** "Coverage of the wrapper is 310 of its 347 exported procedures called from a test; the rest are
proc-group members reached through their group."
**Why it matters:** the number is precise, load-bearing (it is the project's main quality claim), and
there is no command in the tree that reproduces it. The counting method is also exactly the one this
repository has already been bitten by: matching `\.Name(` rather than `\.Name\b` undercounts badly,
because the wrapper is frequently stored or forwarded rather than called. A reader cannot tell which
method produced 310/347, and neither can the next maintainer.
**Fix:** add the script that computes it as a `just` recipe, print it in CI, and cite the recipe name
next to the number in `PLAN.md`. Same fix as R4-01 and best done once.

## What is good, specifically

Worth recording so it is not lost in a later refactor:

- `examples/hello_window.odin` uses **only** the generated bindings, with numbered steps. Having one
  example that deliberately refuses the ergonomic layer is the right way to show what that layer does.
- The `.RAW` pixel-readback trick (`sciter_app/graphics.odin:192-195`) makes drawing assertable with no
  decoder and no display, and `graphics_gallery.odin`'s 50 tests are built on it. That is the single
  highest-leverage testing decision in the project.
- Failure paths are asserted by value, not by "an error happened": 23 assertions on
  `Api_Error.Not_Found`, 9 on `Scdom_Result.INVALID_HANDLE`, 6 on `PASSIVE_HANDLE`. Distinguishing those
  two is exactly the diagnosis `sciter_app.odin:26-28` says the error union exists to preserve, and the
  tests prove it works.
- Every test-bearing example skips itself cleanly without a display rather than failing.
