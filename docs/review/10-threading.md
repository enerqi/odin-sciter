# Angle 10 — threading, affinity and the ledger under two threads — 2026-08-16

> **Later note, 2026-08-17.** The gate this review proposed shipped as `.github/scripts/check-affinity.py`
> and has since been rewritten in Odin as `tools/checks/affinity.odin`, one subcommand of `tools/checks`.
> `just check-affinity` is unchanged and the measurement is identical — 187 guarded call sites, one
> documented exception. Paths named below are the ones that existed when this was written.

A separate, later review, not part of the nine dated 2026-08-13. It exists because the subsystem it
covers landed **after** those closed: `5c99e32` "threading" and `0d2bd9a` "thread affinity" are both
2026-08-15, and the review's own fix commit `743a5b0` is 2026-08-14. Between that commit and `HEAD` the
tree moved by 104 files, +8561/−5983, so angle 9's ownership conclusions — every one of them measured
single-threaded — have never been checked against the code that now exists.

What is under review: `sciter_app/affinity.odin`, the ledger in `sciter_app/tracking.odin` that the
affinity rule is what makes lock-free, `docs/threading.md`, `docs/rules.md` §1, and the engine-facing
call sites the guard is supposed to stand in front of.

Everything below was measured on the vendored 6.0.4.9 engine, Windows x64, Odin
`dev-2026-08-nightly:902106f`, debug build. The probe is `affinity_probe.odin`, described at the end;
it is not committed.

| # | finding | severity | status |
|---|---|---|---|
| R10-01 | the guard misses 38% of the package's engine calls, including the family the docs name | major | **fixed** |
| R10-02 | the guard can charge the violation to the thread that owns the engine, and trap it | major | **fixed** |
| R10-03 | the unlocked ledger is mutated off-thread and loses counter updates | major | **premise restored** |
| R10-04 | the video API documents worker-thread use with nothing behind it | minor | open |
| R10-05 | the guard's own `on`/`strict` state is read and written non-atomically | minor | **fixed** |
| R10-06 | the rule the guard models is not the rule macOS enforces | minor | **fixed** |
| R10-07 | nothing tests guard *coverage*, and the one test that could is deliberately shaped not to | nit | **fixed** |
| R10-08 | found by fixing R10-01: the macOS test bootstrap really does use the engine from two threads | major | **fixed** |

## Status — 2026-08-16, the same day

Seven of the eight are closed. R10-08 was not in the original seven: it is what the completed guard
found on its first macOS CI run, an hour after the fix landed. R10-06 was expected to need a Mac and did
not — see its entry. The one still open, R10-04, needs a live video destination with a producing worker
before it needs a change.

`engine()` in `sciter_app/sciter_app.odin` is the fix that carried four of the five: it is now the
package's only route to the engine's function table, it calls `guard_engine_thread` on the way in, and
`just check-affinity` fails the build on a bare `sciter.api()` anywhere else. `post_callback` keeps the
bare call and is the script's one documented exemption.

Re-measured with the same probe, against the same four phases:

| | before | after |
|---|---:|---:|
| phase 1 — 50 off-thread `value_from_string` pairs | 0 violations | 200 |
| phase 2 — one off-thread `value_copy` (the control) | 1 | 9 |
| phase 3 — 20,000 tracked Values on each of two threads | 1 | 80,209 |
| phase 4 — worker arms itself, main is charged | main charged 1 | **worker charged 9, main 0** |

The counts rise because the guard now sees whole procedures rather than their result codes — phase 2's
control went from 1 to 9 for the same five wrapper calls, which is the same fact from the other side.

And with the shipped defaults — `strict = true`, nothing turned down — an off-thread `value_from_string`
that previously ran silently now stops the process at the call:

```
sciter_app: called from thread 66616, but the engine belongs to thread 67900
  every call must be on the thread that first used the engine - see docs/rules.md rule 1.
  `post_callback` is the only exception; `docs/threading.md` is the way across.
  at C:/Users/Enerqi/dev/odin-sciter/sciter_app/value.odin(127:2)
```

R10-03 is marked *premise restored* rather than fixed, deliberately. The ledger's counters are still
non-atomic `+= 1` / `-= 1` and its two maps are still unlocked; what changed is that the off-thread call
that corrupts them now traps before it arrives. That is the trade `tracking.odin:88` always described,
and it is now true. The alternative — locking the ledger — was rejected for the reason in the finding:
the ledger is not the thing that should be made thread-safe.

Verified after the change: `just check`, `just lint`, `just format-check`, `just check-ownership`,
`just check-affinity`, `just stats --check`, `just example-tests` (every example, all green) and
`just leak-check` (clean, 10 resource kinds exercised and balanced). The gate was also tested the way
this document warns it must be — a bare `sciter.api()` planted in `atom.odin` fails it with the file and
line, and the same run passes once removed.

One consequence worth knowing about, in `atom.odin`: with both of its engine calls going through
`engine()`, the file no longer names a single generated type, so `import sciter ".."` became an unused
import and `just lint` caught it. It is gone, with a comment saying why.

---

## Findings

### R10-01 — the affinity guard misses 38% of the package's engine calls, including the family the documentation names  [severity: major]

**Where:** `sciter_app/affinity.odin:24-26`; the six chokepoints at `sciter_app.odin:59`, `:69`,
`graphics.odin:71`, `:83`, `request.odin:87`, `:99`; `docs/rules.md:43`; `docs/threading.md:14,19`.

**What:** the guard is reached only through four error wrappers (`dom_err`, `value_err`, `gfx_err`,
`request_err`) and two table accessors (`graphics_api`, `request_api`). A procedure whose engine call
returns `SBOOL`, or nothing, or an `Api_Error` this layer invents, passes none of them.

Counted over `sciter_app/*.odin` — procedures calling `sciter.api().X` or a vtbl slot directly:

| | procedures | call sites |
|---|---:|---:|
| reach the engine | 193 | 199 |
| pass a chokepoint | 121 | 124 |
| **unguarded** | **72** | **75** |

`affinity.odin:25` describes the gap as "procedures that call the engine and return nothing". It is
wider than that. The unguarded 72 include `eval` and `call` (`window.odin:391`, `:420`),
`create_window`, `load_html`, `load_file`, `set_css`, `close`, `activate`, all fourteen constructors and
accessors in `value.odin`, all nine windowless input procedures, `init`, `run`, `run_once`, `heartbeat`,
`stop`, `shutdown`, and `set_host_handler`.

Measured, worker thread, guard on and counting:

```
phase 1 - 50 value_from_string + value_clear pairs on a worker thread
  affinity violations reported : 0
  ledger Value acquires seen   : 50

phase 2 - one value_copy (chokepoint: value_err) on a worker thread
  affinity violations reported : 1
```

Phase 2 is the control: the instrument works, and phase 1's zero is coverage, not a broken probe.

**Why it matters:** the two normative documents state the opposite. `rules.md:43` — "The first call into
the wrapper records the thread it happens on, and any later call from another thread **traps there,
naming the procedure**". `threading.md:19` — "**A debug build enforces this**", four lines under a
sentence (`:14`) that names "`Value` construction" as covered. `Value` construction is precisely the
family with no guard on it. A reader who trusts either sentence will conclude a silent debug run means
a clean one.

**Fix:** one helper, and the class closes. Add to `sciter_app`:

```odin
@(private)
engine :: proc(loc := #caller_location) -> ^sciter.Isciter_Api {
	guard_engine_thread(loc)
	return sciter.api()
}
```

then replace `sciter.api()` with `engine()` at all 199 sites, not only the 75 — uniform, idempotent, and
the double check on already-guarded paths is one atomic load. It also makes R10-07's gate a one-line
rule: no bare `sciter.api()` anywhere in `sciter_app/` outside `engine()`.

### R10-02 — the guard can name the wrong thread as the offender, and in strict mode traps it  [severity: major]

**Where:** `sciter_app/affinity.odin:111-129`; `app.odin:68`; `docs/rules.md:11`.

**What:** the guard arms on the first *guarded* call. `init` is not guarded (R10-01), so the thread that
ran `init` is not the thread that gets recorded — the first thread to reach a chokepoint is. Measured:

```
phase 4 - main thread makes unguarded calls first, then a worker makes a guarded one
  after main's unguarded call, engine thread = 0 (main is 47836)
  after the worker's guarded call, engine thread = 67500
  violations charged to the worker: 0
  violations charged to the MAIN thread afterwards: 1
```

The worker's illegal call arms the guard and is charged nothing. The next legitimate call on the
engine's real thread is charged the violation. In the default configuration — `strict = true`, which
`rules.md:43` and the wrapper's own default both assume — that is not a miscounted statistic, it is
`runtime.trap()` on the innocent thread, printing a message that names the correct thread as the wrong
one.

**Why it matters:** `rules.md:11` states the rule as "the thread that called `init`". The code
implements "the thread of the first call that happens to pass a chokepoint". Those coincide in the
common case and diverge exactly when something is already wrong, which is the case the guard exists for.
A guard that misidentifies the culprit is worse than no guard: it sends the reader to the wrong file.

**Fix:** arm inside `init` as well, keeping first-use arming for the windowless path that
`affinity.odin:111-113` correctly protects. Arming twice is harmless — the compare-and-exchange at `:124`
already makes the first writer win. R10-01's `engine()` helper does this on its own, since `init` calls
`sciter.api()`.

### R10-03 — the lock-free ledger is mutated from other threads, and its counters lose updates  [severity: major]

**Where:** `sciter_app/tracking.odin:88-89`, `:126`, `:163`, `:182-183`, `:193-194`.

**What:** `tracking.odin:88` justifies the absence of a lock: "Call it once, early, on the engine's
thread — the ledger has no locking for the same reason the two cached API tables have none (see
docs/rules.md rule 1)." That is correct reasoning resting on a premise only R10-01's guarded 62%
enforces. Eleven ledger-mutating procedures never pass a chokepoint, nine of them touching a map:

| | |
|---|---|
| `value.odin:125,134,141,453` | `value_from_string`, `value_from_bytes`, `value_make_array`, `value_from_function` |
| `window.odin:391,420` | `eval`, `call` |
| `value.odin:30` | `value_clear` |
| `archive.odin:27,41` | `open_archive`, `close_archive` |
| `host.odin:95` | `data_ready_async` |
| `host.odin:329` | `host_trampoline` — benign, an engine callback is on the engine's thread by construction |

Measured — 20,000 tracked Values built and cleared on each of two threads, so the true outstanding count
is zero:

| run | reported outstanding |
|---|---:|
| 1 | 270 |
| 2 | 192 |
| 3 | 148 |
| 4 | 143 |
| 5 | 232 |

`g_tracker.counted[kind] += 1` and `-= 1` (`:126`, `:163`, `:182`, `:193`) are non-atomic
read-modify-writes; ~0.5% of 40,050 updates were lost each run. The map inserts into `g_tracker.sites`
survived all five runs, which is luck rather than a property: two threads inserting during a rehash is
heap corruption, not a wrong number, and the window is narrow because both threads here insert one key
each.

**Why it matters:** `report_leaked_resources` is the leak gate CI runs (`just leak-check`). Today the
sweep is single-threaded, so CI is honest — this is not a live CI defect. It becomes one the moment an
application, or a future test, does engine work off-thread: the gate then fabricates a leak, or hides a
real one, and the number it prints carries the same authority either way.

**Fix:** two options, and the cheap one is legitimate. Either make the counters atomic and take a lock
around the two maps — which buys thread-safety for a tool that should not need it — or close R10-01 so
the stated premise is actually true, and narrow `:88` to say the ledger is unsynchronised *and*
unprotected until then. Closing R10-01 is the better trade: the ledger is not the thing that should be
made thread-safe, the calls are the thing that should be caught.

### R10-04 — the video API documents worker-thread use with no guard behind it  [severity: minor]

**Where:** `sciter_app/video.odin:262-266`, and the nine procedures at `:156`, `:170`, `:183`, `:196`,
`:204`, `:219`, `:243`, `:267`, `:274`.

**What:** `video_add_ref`'s doc comment says it exists for "a worker thread producing frames", and that
"a worker may hold a reference and check `video_is_alive`, but the frames themselves go through
`post_callback`". So the package documents a second cross-thread entry point besides `post_callback`.
All nine video procedures call the vtbl directly, so none of them reaches `sciter.api()` or a
chokepoint, and none is measured. Whether the engine's `asset_add_ref` / `asset_release` are atomic is
not stated in `sciter-x-om.h` and was not tested here.

**Why it matters:** `post_callback` earned its exception with five measured properties recorded in
`host.odin:149-158`. This one has a sentence. Either it is a real exception and deserves the same
treatment — a measurement, and a line in `rules.md` §1 next to `post_callback` — or the comment is
inviting a refcount race on a claim nobody checked.

**Fix:** measure `video_add_ref` / `video_release` / `video_is_alive` from a worker against a live
destination, under ASan; then either document the exception properly or narrow the comment to
"take the reference on the engine's thread, hold it on the worker".

### R10-05 — the guard's own state is read and written non-atomically  [severity: minor]

**Where:** `sciter_app/affinity.odin:66-69`, `:117`, `:132`.

**What:** `id` and `violations` are accessed through `sync.atomic_*`, correctly. `on` and `strict` are
not: `guard_engine_thread` reads `g_affinity.on` at `:117` and `.strict` at `:132` as plain loads, and
`check_thread_affinity` assigns the whole `Affinity` struct at `:66` as a plain store — while
documenting itself as a re-arm that may be called at runtime, which is what `worker_thread.odin` does
around its tests.

**Why it matters:** benign in practice on x86 for a byte-sized flag, and it will stay benign. It is
listed because this is the one file in the package whose entire job is to be correct about threads, and
the mixed treatment reads as an oversight rather than a decision — the next reader cannot tell which.

**Fix:** `sync.atomic_load` / `atomic_store` on both flags, or one sentence saying why they do not need
it.

### R10-06 — the rule the guard models is not the rule macOS enforces  [severity: minor]

**Where:** `docs/MACOS-CHECKLIST.md:132-186`; `docs/rules.md:11`; `sciter_app/affinity.odin` throughout.

**What:** the guard models *consistency* — every call on whichever thread came first. On Darwin the
engine needs the **main** thread specifically: `init`, `create_image` and `create_windowless` all
construct the `xwing::application` singleton, which builds `NSApplication`, and `create_window` reaches
`NSWindow`, which aborts with `NSInternalInconsistencyException` anywhere else. A consistent non-main
thread satisfies rule 1 and satisfies the guard, and aborts in AppKit.

**Why it matters:** the checklist closes with "none of this affects a real macOS app. `main` runs on the
main thread, so `create_window` from `main` is correct by construction." True — and by-construction
correctness with nothing checking it is the exact situation `affinity.odin:5-6` was written to end for
rule 1. An application that runs its UI on a spawned thread (a plugin host, an embedded runtime, a
second UI thread) is portable on Linux and Windows and aborts on macOS, with the guard silent.

**Fixed**, and more cheaply than expected. `check_thread_affinity` gained a third parameter,
`main_thread`, defaulting to `ODIN_OS == .Darwin`: when the guard arms, the thread that armed it must
also be the process's main thread. No platform API and nothing to link — `@(init)` procedures run at
start-up on the first thread, which `MACOS-CHECKLIST.md` had already verified on macOS directly, so
recording `sync.current_thread_id()` there is the whole implementation.

The check itself is platform-neutral; only the default is Darwin. That is what made it measurable from
Windows, with `strict = false` so the counter can be read instead of trapping:

| | arming thread | violations |
|---|---|---:|
| `main_thread = false` (the non-Darwin default) | a worker | 0 |
| `main_thread = true` (what Darwin gets) | a worker | **1** |
| `main_thread = true` | main | 0 |

**The first version of this defaulted to on for all of Darwin, and that was wrong** — it went red on the
next macOS CI run. The eighteen windowed examples were unaffected, because their bootstrap re-arms the
guard anyway; `archive` and `single_binary`, which deliberately have no bootstrap and whose tests do
touch the engine, trapped on their first call and took 8 of their 15 tests with them. Odin's runner
keeps the main thread for its own loop and submits every test to a pool at any `ODIN_TEST_THREADS`
count, so *no* test binary on macOS can satisfy the rule.

The default is now `ODIN_OS == .Darwin && !ODIN_TEST` — one expression in the library rather than an
opt-out per example, because `ODIN_TEST` is a build-level constant visible inside `sciter_app` (checked,
not assumed) and "a test binary is never on the main thread" is a fact about `odin test` and not about
any one example. It also means the eighteen bootstraps need no `main_thread` argument at all, and
carrying one would have taught the nineteenth example to copy it.

The general shape is worth more than the fix: **a check whose default no test can satisfy is not a
strict check, it is a broken build.** Both times this guard has been wrong, macOS is what said so.

### R10-07 — nothing tests guard coverage, and the test that could is deliberately shaped not to  [severity: nit]

**Where:** `examples/worker_thread.odin:753-812`.

**What:** the off-thread test calls `assert_engine_thread()` from the worker, with the reasoning stated
at `:762-764`: "Calling a real DOM procedure here would prove the same thing by doing the exact damage
rule 1 exists to prevent, in a process that has 380 tests left to run." That reasoning is right. Its
consequence is that the suite proves the guard *primitive* works and never touches the *wiring*, which
is where all of R10-01 lives.

**Why it matters:** the repository's own pattern for a rule whose check cannot be a runtime test is a
static gate — `just check-ownership` for rule 4, `just stats --check` for the counts. Rule 1 has a
runtime primitive and no gate, and R10-01 is what grew in the gap.

**Fix:** a `check-affinity.py` beside `check-ownership.py`, ~60 lines: fail if any `sciter.api()` appears
in `sciter_app/*.odin` outside `engine()`. With R10-01's helper in place that is a grep, not an analysis.

One warning, from `check-ownership.py`'s own docstring: that script was written with
`\b(string|[]u8|...)\b`, in which "a word boundary cannot match between a space and the `[` of a slice
type, so every slice alternative in that spelling is dead and only `string` is ever tested." The first
pass of this review's coverage script hit the identical bug — `\b(...|graphics_api\(\)|...)\b` never
matches, because there is no word boundary after `)` — and it over-reported 21 graphics and request
procedures as unguarded until the control case caught it. Any gate written for this must be tested
against a procedure known to be guarded, not only against one known to be bare.

---

### R10-08 — the macOS test bootstrap uses the engine from two threads, and only the fixed guard could see it  [severity: major, found by fixing R10-01]

**Where:** the `when ODIN_OS == .Darwin && ODIN_TEST` block in 18 examples;
`docs/MACOS-CHECKLIST.md` section 2.

**What:** the macOS CI job went red on the first run after R10-01 landed, on every example with tests:

```
sciter_app: called from thread 55503, but the engine belongs to thread 54965
  at /Users/runner/.../sciter_app/app.odin(221:2)
* thread #4, stop reason = EXC_BREAKPOINT
    frame #0: sciter_app::[affinity.odin]::guard_engine_thread
```

Not a regression, and not a false positive. `darwin_main_thread_bootstrap` is an `@(init)` that calls
`sciter_app.init()` on the **main** thread, because AppKit aborts the process if the engine's
`NSApplication` singleton is built anywhere else. Odin's test runner then runs every test on a
`thread.Pool` worker, at any `ODIN_TEST_THREADS` count. So the engine is initialised on one thread and
called from another, on every macOS test run, and has been since the bootstrap was written on
2026-08-15. The old guard could not see it for the reason R10-02 describes: `init` was unguarded, so
`main` never armed anything and the worker armed itself instead — the two-thread split was
indistinguishable from a one-thread run.

**Why it matters:** the finding here is not the bootstrap, which is the only arrangement that lets any
test run at all on macOS. It is that the platform's own CI was the first thing the completed guard
caught, one run in. Whatever tolerance the engine has for this split, it had never been stated, and
until 13:46 on 2026-08-16 nobody knew the split was there.

**Fix:** the bootstrap ends with `sciter_app.check_thread_affinity()` — forget the armed thread, keep
the check on and strict. The first call inside the first test arms the worker; everything after it is
checked against that. The exemption is exactly the main-to-worker handover the platform forces, and
nothing wider: `check_thread_affinity(on = false)` would have bought silence on the one platform nobody
here can watch by hand. Verified by the trick `MACOS-CHECKLIST.md` established for Darwin-only code —
point the `when` at Windows and run `odin test`, since `odin check` does not enter `when ODIN_TEST`.
With the re-arm, `eval` passes 34 tests that way; without it, the same binary traps.

## What was checked and is not a finding

- **`post_callback` from any thread is sound.** It reaches `sciter.api()`, which is a plain read of
  `g_api` (`src/prelude.odin:70-73`), written once in `load` before any thread exists. No lazy
  initialisation, nothing to race. The five behavioural properties in `host.odin:149-158` were not
  re-measured; they are tested in `worker_thread.odin`.
- **`graphics_api()` and `request_api()` cache lazily with no lock** — `graphics.odin:72-74`,
  `request.odin:88-90` — and `rules.md:55` calls this out as correct under rule 1 and only under it.
  Both accessors guard *before* the cache write, so they are the two places in the package where the
  premise and the enforcement actually meet. They are the model the rest should follow.
- **`ODIN_TEST_THREADS=1` is set everywhere it needs to be** — `justfile:498`, `:537`, `:944` — and the
  reason is written down in three places. On macOS it is documented as insufficient rather than
  forgotten (`MACOS-CHECKLIST.md:147`), with the `@(init)` bootstrap and the reasoning for it.
- **`host_trampoline` mutates the ledger without a guard** (`host.odin:329`) and this is fine: an engine
  callback runs on the engine's thread by construction, and the trampoline restores its captured context
  first.
- **Every `proc "system"` trampoline restores a captured context**, per angle 9's sweep. Nothing in the
  post-review commits added one that does not; `set_host_handler:324` captures at attach time, on the
  attaching thread, which is the behaviour `rules.md:11-14` describes.

## Order fixed in

Recorded because the order was the argument: one change carried four findings, and everything else was
smaller than it.

1. **R10-01's `engine()` helper**, applied at all 194 `sciter.api()` sites rather than the 75 that
   needed it — uniform beats surgical here, and the double check on an already-guarded path is one
   atomic load. Closed R10-02 on its own, because `init` came inside the guarded set.
2. **R10-05**, two atomic loads and a field-at-a-time store, while the file was open.
3. **R10-07's gate** — `.github/scripts/check-affinity.py`, `just check-affinity`, and a CI step beside
   `check-ownership`, so the coverage cannot rot back.
4. **The two documentation overclaims** — `rules.md:43` and `threading.md:19` — rewritten only after (1)
   made them true, plus the ledger's own note in `tracking.odin:88`.
5. **R10-06** later, once it turned out not to need a Mac: the check is platform-neutral and only its
   default is Darwin, so it was written and measured from Windows by passing `main_thread = true`
   explicitly.
6. **R10-04** remains open. It needs a live video destination with a producing worker before it needs a
   change, and that is a scenario rather than a hardware problem — `examples/video.odin` streams frames
   from the engine's own thread today.

## The probe

`affinity_probe.odin`, four phases, run five times:

1. 50 × (`value_from_string` + `value_clear`) on a worker — the unguarded family.
2. one `value_copy` on a worker — the control, through `value_err`.
3. 20,000 tracked Values on each of two threads — the ledger under contention.
4. main thread unguarded first, then a worker through a chokepoint — who gets armed, and who gets
   charged.

Built with `odin build <probe>.odin -file -debug` and run from the repository root. It is a `main`
rather than a test for the reason `leak_sweep.odin:5-10` gives, and it is deliberately not committed: it
calls the engine from the wrong thread on purpose, dozens of times per run, which is not something to
leave in a suite that runs on every push. The findings above are what it printed; reproducing them needs
the file, which is in this review's working directory rather than in the tree.
