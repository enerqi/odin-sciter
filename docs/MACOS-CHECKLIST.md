# macOS bring-up

Status: **pinned, and the first CI run has happened.** The engine loads, the ISciterAPI table verifies,
everything builds, and **a `macos-14` runner can open a Sciter window** — the canary passed, which is
what the suite steps below it running at all proves. What fails is the test *runner*, on the thread
this file predicted it would, for the reason it predicted.

This file was written *before* that run, on purpose. [`WINDOWS-CHECKLIST.md`](./WINDOWS-CHECKLIST.md)
earned its keep because the predictions in it were recorded before the machine existed and then turned
out wrong twice — the null list was not what was predicted, and `sciter.dll` exported 276 symbols
rather than the one that was expected. A prediction that is only written down after the measurement is
not a prediction. Sections below are being converted from prediction to measurement as results arrive;
each says which it is.

Engine: 6.0.4.9, `bin/macosx/libsciter.dylib`, 50 029 168 bytes,
`a7b65f37b265a0bacf7c127b8e45e8c0f66a16e3e1071b877b19ca333af1c25c`, recorded in
[`external/sciter/VENDORED.md`](../external/sciter/VENDORED.md).

**It is fetched, not committed** — as all three engines now are, and this file is where that decision
came from. 50 MB of universal binary, roughly half of it dead weight on any given machine, took `.git`
from 11 MB to 41 MB in one commit, for the platform nobody here can run; the answer was to stop
committing engines at all and to rewrite the three that had been. `just fetch-engine` installs it
against the hash above, `ensure-engine` runs before every recipe that builds or runs anything, and the
CI job fetches as its first step. The reasoning is in [`UPGRADING.md`](./UPGRADING.md). Nothing else in
this file changes: the file lands in `lib/macosx/` either way, and every measurement below was made
against exactly that binary.

## There is no Mac

Nobody working on this repository owns one, and that is the constraint everything here is shaped by.
The substitute is **GitHub-hosted `macos-14`** — Apple silicon, free on a public repository, and enough
to run every step the Windows desktop ran except the one that matters most.

So the honest end state has three parts rather than two, and `README.md`'s platform table says so:

| | What it means | Who can establish it |
| --- | --- | --- |
| **Pinned** | the engine is fetched by hash and verified | done, from any machine |
| **CI** | it loads, the ISciterAPI table matches, the suite passes, no leaks | the `macos` job |
| **Eyeballed** | a window opens and *renders what it should* | nobody, yet |

CI cannot tell you a window is blank, or that text is unantialiased, or that the wrong monitor was
chosen. Everything below is written to make the first two columns real and to be honest about the third.

## What was established without a Mac

All of this was read out of the Mach-O headers of the vendored file, and it answers questions that were
open when this bring-up was planned. The detail is in
[`VENDORED.md`](../external/sciter/VENDORED.md#what-the-macos-file-is):

- **universal**, x86_64 + arm64. There is no arch subdirectory to vendor, which is why `lib/macosx/`
  has no `x64` component and why the CI gate that used to glob `lib/macosx/*/libsciter.dylib` could
  never fire
- **ad-hoc code-signed**, both slices. This was the risk that looked most likely to block the port
  outright: arm64 macOS refuses to map unsigned code. It is signed, so `dlopen` should work — and it is
  *only* ad-hoc, so anyone redistributing it must re-sign and notarize
- **minimum macOS 11.5**, so the runner is comfortably in range
- **no third-party dependencies at all** — system frameworks only. Contrast Linux, where `ldd` lists
  sixteen entries and a missing `libEGL` is a whole class of failure. That class does not exist here
- it links **AppKit, Cocoa, Carbon, Metal *and* OpenGL**, which is the first hint about what the null
  list might do

## The steps

Every row runs in the `macos` job of `.github/workflows/ci.yml` unless it says otherwise.

| | Step | Predicted | Result |
| --- | --- | --- | --- |
| 1 | pin the dylib, `just fetch-engine` | passes | **done** — hash established from Windows, no Mac involved. Fetched rather than committed; the job downloads it |
| 2 | `lipo` / `codesign` / `xattr` report | universal, ad-hoc signed, no quarantine | **done** — read from the file itself |
| 3 | `just api-map-verify` | 189 slots, version 10, 0 mismatches; null list per §5 below | **passes, and is now a gate** — `MACOS_NULLS` is pinned to the 16 it printed, which are the Linux 16 exactly (§5) |
| 4 | `just check` | builds; nothing is X11- or Win32-shaped outside the two excluded examples | **passes** |
| 5 | `just window-canary` | the open question — see §1 | **passes** — see §1, and it is the single most useful result so far |
| 6 | `just example-tests` | the second open question — see §2 | **21 of 22 example files green.** First run: 18 of 22 aborted in AppKit. After the bootstrap and the windowed-test skip: only `sqlite_extension` fails. See §2 and §2a |
| 7 | `just leak-check` | clean, as on both other platforms | not reached — step 6 fails first |
| 8 | `just cross-check` (Linux) | now covers `darwin_arm64` as well as `darwin_amd64` | **done** |
| 9 | `just example single_binary` | embeds all 50 MB and extracts to `~/Library/Caches/odin-sciter` | |
| 10 | `just pack`, `just inspector` (needs the SDK) | the justfile's `macosx` / `inspector.app/Contents/MacOS` paths are untested | |

---

## The predictions

### The ledger — audited 2026-08-16

Every section below was written before the machine existed. Scoring them against what the runs actually
said is the only way to find out whether writing predictions down is paying for itself, and the answer
has a shape:

| § | prediction | outcome |
| --- | --- | --- |
| 1 | a hosted runner can reach WindowServer | **held** |
| 2 | AppKit's main-thread rule breaks the windowed tests | **held, and under-scoped** — it is not about windows: `create_image` and `create_windowless` reach the singleton too |
| 3 | nothing is quarantined in CI | **held** |
| 4 | an unbundled binary may never come forward | **unresolved, and unresolvable here** — needs a human at a Mac |
| 5 | 15 null slots: the Linux list minus `SciterCreateNSView` | **wrong** — 16, the Linux list exactly, and the slot named for the platform is null *on* it |
| 5 | `dladdr` resolves every non-null slot to its own `…Imp` | **held** — 173 of 173 |
| 6 | no JIT entitlement is needed | **untested** — nothing here runs under the hardened runtime, so this is still reasoning, not a result |
| 7 | the extracted universal dylib keeps its ad-hoc signature and loads | **held**, and it turned out to be checkable after all — `single_binary`'s 8 tests are green (§2a) |
| 8 | the X11-only pair has no macOS equivalent | not a prediction, a statement of scope |

**Four held, one wrong, one unresolvable, one untested.** The pattern in that column is worth more than
the score: *every prediction about the environment held, and the one about the engine's API surface was
wrong.* §5 already records that this is the third API-shape prediction in this repository to be wrong,
after two for Windows. Environments are guessable — a hosted macOS runner is a documented thing, and so
is `com.apple.quarantine`. What an undocumented C API answers on a platform nobody has run it on is not,
and no amount of reasoning about the header improves it. That is the argument for `api-map-verify` and
`MACOS_NULLS` being gates rather than notes, and it generalises: **predict the environment, measure the
API.**

One more entry belongs here and has no section, because nobody predicted it: fixing §2 introduced a
genuine two-thread split — the singleton built on `main` by the bootstrap, every test on a pool worker —
which nothing caught until the thread guard was completed nine days later and went red on the first
macOS run. It is written up as R10-08 in [`review/10-threading.md`](./review/10-threading.md) and in
"The bootstrap and the affinity guard" below. The lesson is not about macOS: a workaround for a
platform rule is itself a change that wants a prediction, and this one did not get one.

### 1. Does a CI runner have a window server? — **MEASURED: yes**

Predicted: it works, the canary exits 124 and the suite runs. **It does.**

The canary passed, and the way that is known is worth stating because the log does not say it in words:
the job's steps are ordered and fail-fast, and `just example-tests` ran, so every step above it — the
engine verification, `api-map-verify`, `check` and `window-canary` — passed first. A `macos-14` runner
therefore builds `hello_window`, opens a real Sciter window, and is still running twenty seconds later.

That is the best single result of the bring-up. It means:

- GitHub's hosted macOS runners are in a session that can reach WindowServer. No `Background`-session
  problem, and `launchctl managername` never had to be read in anger
- the ad-hoc code signature is sufficient — the dylib maps and `dlopen` succeeds on arm64
- nothing is quarantined
- the engine's Cocoa backend initialises and creates an `NSView`-backed window on this hardware

What it does **not** mean: nobody has seen what is in that window. The canary's pass condition is "the
process was still alive after 20s", which a blank window satisfies. That is the ceiling described at the
top of this file, and it has not moved.

### 2. The main thread — **MEASURED: confirmed, and worse in one specific way**

Predicted: the canary passes and the windowed tests fault, with an assertion naming a main-thread
requirement, in every windowed test. **That is what happened**, and the abort message is exact:

```
*** Assertion failure in -[NSMenu _setMenuName:], NSMenu.m:777
*** Terminating app due to uncaught exception 'NSInternalInconsistencyException',
    reason: 'API misuse: setting the main menu on a non-main thread.
             Main menu contents should only be modified from the main thread.'

  3  AppKit         -[NSMenu _setMenuName:]
  4  AppKit         -[NSApplication setMainMenu:]
  5  libsciter      initMenuBar()
  6  libsciter      wing::internal::InitCocoa()
  7  libsciter      wing::init()
  8  libsciter      xwing::application::application()
  9  libsciter      xskia::application::application()
 12  libsciter      SciterExecImp
 13  <example>      sciter_app::init
 14  libsystem_pthread  thread_start          <- not the main thread, and that is the whole bug
```

18 of the 22 examples with tests abort with SIGABRT (exit 134) this way. Frame 14 is the finding: the
test is on a pool worker.

**Where the prediction was too kind: this is not about windows.** Three different entry points reach the
same abort, because they all construct the one `xwing::application` singleton, which builds
`NSApplication` and its menu bar:

| Entry point | Path into it |
| --- | --- |
| `sciter_app.init` | `SciterExecImp` → `xskia::application` → `wing::init` → `InitCocoa` |
| `sciter_app.create_image` | `ImageCreateImp` → `gool::bitmap` ctor → `xwing::application` → same |
| `sciter_app.create_windowless` | `lite::view::proc_x` → `lite::application::factory` → same |

So on macOS there is **no display-free half of the engine**. `examples/windowless.odin`'s header says it
deliberately does not call `sciter_app.init()` because that "stands up the windowed application
subsystem" — true on Linux and Windows, **false here**: `create_windowless` stands it up anyway. Same
for `create_image`, which has nothing to do with windows at all. That is a real platform difference and
it is now written into both examples.

**Why no `ODIN_TEST_THREADS` value fixes it.** Read `core/testing/runner.odin`: the runner always builds
a `thread.Pool` (`pool_init`, line ~392), always submits tests as tasks (`pool_add_task`, ~554), and
keeps the main thread for its own event/timeout/status loop (~609). At `thread_count == 1` there is one
worker instead of many — still not the main thread. There is no define that changes this.

**The fix being tried: an `@(init)` bootstrap.** `@(init)` procedures *do* run on the main thread, before
the runner starts — verified directly, by comparing thread ids in a probe test. So building the engine's
singleton there puts `InitCocoa` on the right thread, and every later `sciter_app.init()` is a no-op
(`g_initialized`, `sciter_app/app.odin:72`). It is scoped `when ODIN_OS == .Darwin && ODIN_TEST`, so it
touches test binaries only.

It went into two examples, chosen to answer two different questions in one run: `windowless` (needs no
window — the best case) and `behavior` (needs a real one — the worst).

**`behavior` answered first, and the answer is that the bootstrap works and is not enough.** The
`initMenuBar` abort is gone. The test now gets all the way past `sciter_app.init()` to
`create_window`, and dies at the *next* main-thread rule:

```
*** 'NSInternalInconsistencyException', reason: 'NSWindow should only be instantiated
    on the main thread!'

  3  AppKit         -[NSWindow _initContent:styleMask:backing:defer:contentView:]
  4  AppKit         -[NSWindow initWithContentRect:styleMask:backing:defer:]
  5  libsciter      wing::internal::CreateWindowCocoa
  6  libsciter      wing::window::create
  7  libsciter      xwing::application::create_frame
  8  libsciter      SciterCreateWindowImp
  9  <example>      sciter_app::create_window
 10  libsystem_pthread  thread_start        <- still a worker, and nothing can change that
```

Two conclusions, and the first is what makes the second safe to act on:

1. **The bootstrap does what it was built to do.** A different, later, more specific abort is the proof:
   the singleton now exists, constructed on the right thread, before any test runs
2. **Windowed tests cannot run under `odin test` on macOS. At all.** `NSWindow` requires the main
   thread, the runner has no way to put a test there, and no amount of earlier initialisation moves a
   test onto a thread it is not on. This is not a bindings bug, not an engine bug, and not an Odin bug —
   it is an AppKit rule meeting a parallel test runner

So the shape of the answer is the fallback this file listed second: **display-free tests under
`odin test` with the bootstrap; windowed examples driven as programs.** A runner patch, as on Windows,
is the wrong tool here — patching Odin to run tests on the main thread would be fixing an AppKit rule in
someone else's code.

**`windowless` answered second: 12 tests, all passing.** Before the bootstrap it aborted before its
first assertion. Nothing on that path creates an `NSWindow`, so the singleton was the entire problem
there — which makes the split real rather than theoretical:

| | Under `odin test` on macOS | Covered by |
| --- | --- | --- |
| windowless views, images, Values, DOM over a windowless view | **run** | the bootstrap |
| anything calling `create_window` | **skip** | running the example as a program |

### What was rolled out

- the bootstrap is in all 18 examples whose tests touch the engine. `archive`, `drag_and_drop` and
  `single_binary` do not get it: their `create_window` is in `main`, their tests never reach the
  singleton, and they were green from the first run. `single_binary` especially must not have it — it
  would load the on-disk engine and quietly stop testing the embedded one
- `have_display()` gained a Darwin branch in the 14 window-creating examples: true normally, **false
  under `ODIN_TEST`**, with the reason printed. `windowless`, `script_bridge` and `sqlite_extension`
  keep it true — they need no window, and skipping them would throw away the coverage that just came
  back
- the skip messages stopped claiming `DISPLAY`. 28 call sites said "no DISPLAY or WAYLAND_DISPLAY -
  skipping…", which is false on macOS and was about to become the repository's own version of the
  silent-skip bug `sqlite_extension`'s comment warns about. `have_display` now prints *why* and the call
  site prints *what* it skipped, so both lines are true on every platform
- `graphics.odin` needed `base:runtime` for the bootstrap, used only inside a `when` - so it is
  `@(require) import`, the same trap `api_map.odin` documents for `core:unicode/utf16`

### The bootstrap and the affinity guard, 2026-08-16

**The bootstrap puts the engine on two threads, and now that rule 1 is fully checked the guard says so.**
It is the same fact this section is about, seen from the other end: the singleton is built on `main`
because AppKit demands it, every test then runs on a `thread.Pool` worker because the runner demands
*that*, and those are two different threads. Nothing changed about the arrangement — what changed is
that `engine()` now guards every call rather than only the ones returning a result code, so
`sciter_app.init()` inside the bootstrap arms the guard as `main` and the first test call trips it:

```
sciter_app: called from thread 55503, but the engine belongs to thread 54965
  at /Users/runner/.../sciter_app/app.odin(221:2)
* thread #4, stop reason = EXC_BREAKPOINT
    frame #0: sciter_app::[affinity.odin]::guard_engine_thread
```

That is a true positive. The split is real, it is unavoidable here, and it was invisible before.

The bootstrap therefore ends with `sciter_app.check_thread_affinity()`, which forgets the armed thread
without turning the check off. The first call inside the first test arms the worker, and everything
after it is checked against *that* — so what is exempted is exactly the main-to-worker handover the
platform forces, and no more. Turning the guard off (`check_thread_affinity(on = false)`, which
`rules.md` §1 offers for a multi-threaded runner) would have been the bigger hammer and would have cost
the rest of the coverage on the one platform nobody here can watch by hand.

Two things follow. Applications are unaffected — `main` is the main thread, so a real app builds the
singleton and calls the engine on one thread. And if the macOS suite is ever run at
`ODIN_TEST_THREADS > 1` the guard will trap, correctly: that would be several workers sharing an engine,
which is the thing rule 1 forbids.

**And the same rule caught the guard's own second half, one run later.** The main-thread check added for
R10-06 defaulted to on for all of Darwin, so every macOS *test* binary inherited a rule no test can
satisfy — the runner keeps the main thread for its own loop and submits tests to a pool, at any thread
count. The windowed examples were fine, because their bootstrap re-arms the guard anyway. `archive` and
`single_binary` were not: they deliberately have no bootstrap (see above — `single_binary` must not load
the on-disk engine), their tests touch the engine, and all seven and one of eight respectively trapped on
their first call.

The fix is `&& !ODIN_TEST` on the default, in `sciter_app/affinity.odin`, rather than an opt-out per
example: `ODIN_TEST` is a build-level constant visible inside the library, and "no test binary on macOS
can be on the main thread" is a fact about `odin test`, not about any one example. Eighteen bootstraps
briefly carried an explicit `main_thread = false`; they no longer need it and no longer have it. The
useful part of the episode is the shape — **a check whose default no test can satisfy is not a strict
check, it is a broken build** — and it was found the way the one before it was found, by a platform
nobody here can run.

Verified before pushing: `just lint`, `just check`, `just cross-check` (all three targets), and the
Darwin-only blocks compiled *for real* by pointing their `when` at Windows in one file and running
`odin test` — `odin check` does not enter `when ODIN_TEST`, so nothing else would have compiled them.
`events`, `behavior` and `graphics` still pass 24, 14 and 12 tests on Windows.

Was open, now closed, and it was the point: with the windowed tests skipping rather than aborting the
macOS suite goes green, and green then means *less* here than on the other two platforms. Two things
were built to say how much less.

**`just windowed-examples`** runs every example that calls `create_window` as a *program*, which is
where `main` is the main thread and nothing skips. Same contract as the canaries — 124 is the pass, the
timeout fired so the window was still up. It runs on all three platforms in CI, deliberately: a windowed
example that fails only on macOS is a platform finding, one that fails everywhere is a broken example,
and without the other two columns there is no telling which. It does not prove the window has anything
in it; that ceiling has not moved, and the "Looked at by a human" column in `README.md` is still what
covers it.

**`just example-tests` counts the skips.** It prints how many test procedures ran of how many exist, and
how many of those returned early — so this file no longer has to warn in prose that the total overstates
itself. Measured on Windows the day it was written: 384 of 396 ran, 5 skipped. On macOS the skipped
number is the one to read.

It read **224 skipped of 389, with 165 actually exercising anything.**

### Recovering that, 2026-08-16

The skips were not really about windows. Almost every one of them wanted a laid-out *document*, and a
window was just how the harness got one — so eleven examples now build a **windowless view** instead,
which needs no `NSWindow` and therefore no main thread. `sciter_app/windowless.odin` says why this is
cheap: four procedures are windowless-specific and "everything else in the package works unchanged".

| converted | skips it was carrying on macOS |
| --- | ---: |
| `dom_walk` | 72 |
| `call_odin_from_js` | 17 |
| `events` | 15 |
| `input` | 14 |
| `behavior` | 14 → 1 |
| `video` | 13 |
| `eval` | 11 |
| `graphics_gallery` | 10 |
| `custom_loader` | 9 |
| `named_behavior` | 9 |
| `worker_thread` | 9 |
| `task_list` | 4 |

All of them still pass on Windows, which is the point: the same tests, one less requirement. **Predicted
macOS skips: 28 rather than 224** — `workbench` 13, `request_loader` 9, `windowless_gl` 5 and
`behavior`'s one genuine window test. Predicted, not measured: this file's own ledger says predictions
about the environment hold and predictions about engine behaviour do not, and "does the engine lay out
the same way windowless on Darwin" is the second kind. CI is the verifier.

Three did not convert, and each says something:

- **`behavior`'s `test_window_metrics`** reads `ppi`, `min_width` and `min_height` — questions about a
  window, not a document. It keeps a real one, and its skip is now a statement about that test rather
  than about all fourteen.
- **`workbench`** creates a *second* window and drives it with the application pump. Converted, two of
  its tests failed with zero behavior attachments — and passed when run alone. A windowless view and a
  windowed application do not share a process; gotcha 11 has the measurement.
- **`request_loader`** went flaky, one run in three: a windowless view has no pump, so a request answered
  asynchronously had not finished by the time the assertion read it. Same gotcha, second half.

Note for applications, since the trace invites the wrong conclusion: none of this affects a real macOS
app. `main` runs on the main thread, so `create_window` from `main` is correct by construction. Only a
test binary has this problem.

### 2a. Where the suite stands

21 of the 22 example files that run off Linux are green — every one except `sqlite_extension`. Across
them 382 test procedures report success, and **that number should be read carefully**: a large share of
them are the windowed tests skipping themselves, which is a pass in the runner's accounting and not
evidence about macOS. What is genuinely exercised here is the display-free half — Values, the DOM over a
windowless view, archives, images, graphics, the embedded engine, requests, atoms, SOM.

The four that were green from the very first run, before any of this work:

Four examples came back green, and they are not a random four:

| Example | Tests | What it establishes |
| --- | --- | --- |
| `archive` | 7 | the engine loads and serves packed resources — no application singleton on this path |
| `drag_and_drop` | 3 | pure data-shape tests, no engine |
| `single_binary` | 8 | **`#load` of the 50 MB universal dylib works**, and the extracted copy loads — so the embedded engine keeps its ad-hoc signature through extraction, which §7 predicted and had no way to check |
| `windowless_gl` | 5 | skips itself off Linux, as designed (its GL context is EGL) |

**`sqlite_extension` is two problems wearing one exit code**, and the skip message on top hides the
second:

- `target/debug/odin-sqlite.dylib` was never built — CI runs `just example-tests` but never
  `just extension`, so `test_script_can_load_the_library_and_query` skips itself with "run
  `just extension sqlite_extension odin-sqlite` first". That is a gap in the *job*, not a macOS finding:
  it is true on every platform, and it means the one test that exercises `SciterLibraryInit` has never
  run in CI anywhere. Fixing it is one step (`just extension sqlite_extension odin-sqlite`) before the
  suite, in all three jobs — deliberately not done during this bring-up, because it starts a
  previously-skipping test on Linux and Windows too and that is a separate thing to land
- the exit 134 is separate, and it is **not** the AppKit abort. With the bootstrap in place this file
  still dies with SIGABRT, mid-run, with no `Finished N tests` line and no message of its own

### What the last run says about it

Two things are settled by what is *absent* from the log:

- **`libsqlite3` loads on macOS.** Not one "no libsqlite3 on this machine - skipping" line appears, so
  the four tests that need it ran for real. Worth knowing because `/usr/lib/libsqlite3.dylib` does not
  exist as a file on macOS 11+ — the dyld shared cache serves it to `dlopen` by name, which is exactly
  how `SQLITE_LIBRARY_NAMES` asks for it
- **the abort is mid-run, not at exit.** No `Finished N tests` line. So it is not the macOS twin of the
  Windows exit-path fault that `<p>.</p>` works around in this same file

What is missing is *which test*. `odin test` prints results as it goes, but stdout is a pipe in CI
rather than a terminal, so it is block-buffered and the abort discards whatever had not been flushed —
which is why this reports `exit 134` against a file and names no test. The whole log shows that
buffering: skip messages land after the `Finished` lines they precede.

So `example-tests` now **bisects its casualties**: any example that exits non-zero is re-run one test
per process, each with a single `ODIN_TEST_NAMES`, and the summary names the test that died. It costs a
compile per test and only happens on a run that has already failed.

**It named it on the first try, and the debugger pass named the cause on the next run:**

```
    EXIT 134  test_script_can_load_the_library_and_query
    --- where test_script_can_load_the_library_and_query died
    malloc: *** error for object 0x65: pointer being freed was not allocated
    thread #4, stop reason = signal SIGABRT
```

**It is our bug, not macOS's, and it exists on all three platforms.**

```odin
directory := filepath.dir(os.args[0])
defer delete(directory)                 // <- frees memory nothing allocated
```

`filepath.dir` is `os.dir`, which **slices its argument rather than allocating** — the result points
into `os.args[0]`. Verified directly rather than assumed: `raw_data(filepath.dir(p)) == raw_data(p)`.
So the `delete` hands the allocator a pointer it never issued. Linux and Windows swallowed it for as
long as the example has existed; macOS's malloc checks, and aborts.

That is the useful shape of this whole finding: **the bug was never macOS-specific, only the diagnosis
was.** A third platform earns its keep by being stricter than the other two.

**Odin's test runner would have caught this, and was switched off two lines earlier.** The runner wraps
every test in a `mem.Tracking_Allocator` and counts bad frees alongside leaks — `runner.odin` reads
`bad_frees := len(data.tracking_allocator.bad_free_array)` and reports "Memory failure in `pkg.test`
with N leaks and M bad frees", failing the test. A bad free is exactly what this was, so it would have
been named, at its line, on Linux, long before macOS aborted over it.

It stayed silent because the test did this first:

```odin
context.allocator = runtime.default_allocator()
```

for a good reason — the view and assets the library creates outlive the test, and the runner's
per-test allocator would reclaim them underneath the engine — but *thirty lines too early*, which
turned the net off for the whole test including code that never touches the engine. That line has moved
down to just before the allocations that genuinely have to escape. **Opt out as late as possible, and
only for what has to escape**; every line above the opt-out keeps a bad-free detector that works.

Two more things fell out of chasing it:

- `single_binary.odin` carried the same wrong belief in a comment — "`filepath.dir` allocates with the
  context allocator" — and switched `context.allocator` to protect against a leak that cannot happen.
  Harmless, because it never paired it with a `delete`; corrected, because the next person to copy it
  might
- **`src/prelude.odin` had drifted from the generated `sciter.odin`.** It read `filepath.dir(os.args[0],
  context.temp_allocator)` — an argument that procedure does not take — under a comment claiming it
  allocated. `sciter.odin` carried the correct one-argument call, so *nothing ever compiled the prelude
  version* and the error sat there unseen. `just bindgen` pastes that file verbatim, so the next
  regeneration would have turned it into a build failure. Both now say the same thing

The test's own path, for the record — it dies on the way out of doing almost nothing:

```
load_sqlite()               -> true
load_engine()               -> true
set_default_debug_output()
context.allocator = runtime.default_allocator()
directory := filepath.dir(os.args[0])   ; defer delete(directory)
os.exists(".../odin-sqlite.dylib")      -> false
println("no ... - skipping")            ; return       <- prints, then SIGABRT
```

All three constraints noticed while chasing it held up, and the last one is what pointed at the
allocator rather than at AppKit:

- it dies on the skip path, after its own message, on the way out of a test that created nothing
- it printed nothing without a debugger attached — macOS's malloc *does* write its error to stderr, but
  the abort discarded the buffered stream before it reached the log. Under lldb the message survives
- `test_the_three_classes_publish_the_expected_members` and `test_a_query_runs_through_the_som_layer`
  both load sqlite *and* the engine and pass, so it was never the two libraries coexisting

The bisect **re-runs the dead test under a debugger** and prints the stack, which is what closed this:
`ODIN_TEST_NAMES` is a compile-time define, so the binary from the failing run is already filtered to
that one test and needs no rebuild. lldb on macOS, gdb on Linux, neither on Windows — where testing it
found a stray MSYS gdb that took the multi-word `-ex` arguments as filenames.

Holding the missing `odin-sqlite.dylib` back was the right call: building the extension in CI would
have sent this test down its real path instead of the skip, and the bad `delete` — which is on the skip
path — would have vanished unfixed and unexplained. **That step is now the next thing to land**, and
with the abort gone it should merely turn a skip into a real run of `SciterLibraryInit`, on all three
platforms, for the first time.

### 3. Quarantine — **MEASURED: not an issue**

`just fetch-engine` downloads through `urllib`, which does not set `com.apple.quarantine`; a
`git checkout` does not either. Predicted: not an issue in CI. **Confirmed** — the engine loaded on the
runner, which it could not have done under quarantine or an unacceptable signature. This also settles
the code-signing question at the top of this file: ad-hoc is enough to load on arm64.

For a human who fetched the SDK by hand: `xattr -dr com.apple.quarantine <path>`. The CI job prints
`xattr -l` so this is never a guess.

### 4. Bundle and activation policy — **unresolved, and CI cannot resolve it**

An unbundled binary can create windows, but has no `Info.plist` and may never become the frontmost
application — the window opens behind everything and never takes keyboard focus. Irrelevant to CI,
very relevant to someone running `just example hello_window` on their own desk, and the reason
[`deployment.md`](./deployment.md) talks about `Contents/Frameworks/`.

Prediction: **the examples run and the window may not come forward.** Nobody should read that as a
failure, and nobody can confirm it from CI either.

### 5. The null list — **MEASURED: 16, and the prediction was wrong**

Predicted 15: the Linux list minus `SciterCreateNSView`, on the reasoning that macOS would be the one
platform to fill the slot named after its own view class.

Measured: **16 — the Linux list, exactly.** 189 slots, ISciterAPI version 10, 0 mismatches.
`SciterCreateNSView` is null *on macOS*, which is the finding:

| | Nulls | |
| --- | --- | --- |
| Linux x64 | 16 | |
| macOS arm64 | 16 | the same 16 |
| Windows x64 | 15 | the same, minus `SciterProcND` |

Every slot named after a platform — `SciterCreateNSView`, `SciterCreateWidget`, `SciterRenderD2D` and
friends — is null **on the platform it is named for**. They are Sciter 4 API for putting a view inside a
host widget or renderer, and Sciter 6 does not implement any of them anywhere; it creates its own
window on every platform instead.

The consequence is worth stating because the slot's existence implies the opposite: **there is no
supported way to hand this engine an existing `NSView`.** `SciterCreateWindow` or a windowless view via
`SciterProcX` are the two doors, on macOS as everywhere else. Anyone porting Sciter 4 code that embedded
a view in a host hierarchy has to change approach, not just recompile.

`MACOS_NULLS` in `.github/scripts/check-api-map.py` is now `list(LINUX_NULLS)`, so this is a gate rather
than a notice.

Secondary prediction — that `dladdr` resolves every non-null slot to its own `…Imp` name, as on Linux —
**held**: 173 of 173 resolve, 0 mismatches. One is spelled differently and still passes:
`SciterEGLGetProcAddress` resolves to the C++-mangled `_Z26SciterEGLGetProcAddressImpPKc`, which the
check's substring rule accepts without needing a special case. On Windows that same slot is one of the
two that has no export of its own.

**Three platform-specific predictions have now been made in this repository before the machine existed,
and all three were wrong** — twice for Windows (the D2D slots, the export count), once here. That is the
argument for `api-map-verify` being a gate rather than a document.

### 5a. Behavioural differences — one so far

With the aborts out of the way, the suite started producing *test failures*, which is the interesting
kind. Exactly one behavioural difference has surfaced:

**The clipboard accepts a `json` flavour and does not hold it.** `script_bridge` writes a Value to the
clipboard under the `json` flavour, the write answers true, and the next read reports no json at all —
so the object is gone with no error. On Linux and Windows it round trips exactly, which is the thing
that example exists to demonstrate.

It is the flavour rather than the clipboard, and the same run proves it: in the same windowless view,
`text` round trips exactly and `html` round trips with the CF_HTML wrapper **and its trailing NUL**,
which macOS answers the way Linux does — that assertion is a `when ODIN_OS == .Windows { … } else { … }`
that had never run on a Mac, and macOS took the `else` correctly. So clipboard access works, the session
is not headless-broken, and no permission is involved.

Pinned with a `when` rather than skipped, so an engine that fixes it fails the test and says so.
Written up as defect 12 in [`UPSTREAM-DEFECTS.md`](./UPSTREAM-DEFECTS.md), and the workaround for a host
carrying structure through the clipboard is `JSON.stringify` / `JSON.parse` around the text flavour.

### 6. No JIT entitlement is needed — **still reasoning, not a result**

Sciter 6's script engine is QuickJS, an interpreter. Nothing here needs
`com.apple.security.cs.allow-jit` or `allow-unsigned-executable-memory` under the hardened runtime.
Written down because it is exactly the sort of entitlement that gets added cargo-cult, and every one
added weakens the sandbox for nothing.

### 7. `single_binary` on macOS

`sciter_app/embed.odin` already has its Darwin branch — the extracted engine goes to
`~/Library/Caches/odin-sciter`. Two macOS-specific notes:

- the extracted copy is byte-identical to `lib/macosx/libsciter.dylib`, so it carries the same ad-hoc
  signature and should load. A *modified* copy would not — anything that rewrites the file on the way
  out invalidates the signature and the extracted engine is then unloadable on arm64
- 50 MB embedded rather than 19, because it is universal. `examples/single_binary.odin` says why it
  embeds both slices rather than thinning one

### 8. Things that are simply absent

`integration` and `native_child` are raw Xlib and are excluded everywhere off Linux
(`X11_ONLY` in `.github/scripts/justlib.py`). The macOS equivalents would be different programs written
against AppKit, not the same program compiled elsewhere. Not a gap in the port; a gap in the examples,
and the same one Windows has.

## Notes for whoever runs this next

- **Read the canary step first, always.** Exit 124 is the pass. If it is anything else, the
  forty-five-minute step below it is noise, which is the entire reason it runs first
- the toolchain action already resolves `macOS-ARM64` (`odin-macos-arm64`, `aarch64-apple-darwin`), so
  nothing there needs changing
- `linker` resolves to `default` off Windows. **Do not set `-linker:lld` on a Mac**: Odin drives the
  link through Apple's clang, which ships no lld, and it fails with `invalid linker name in argument
  '-fuse-ld=lld'` — clang rejecting it, not Odin
- the test recipes pass `-microarch:native`. Unverified on Apple silicon; if it errors, that is a
  toolchain finding and not an engine one
- macOS has no `timeout(1)`. `macos-canary.sh` emulates it rather than depending on
  `brew install coreutils`, and the test recipes already use `run_with_timeout` from `justlib.py`
- when the first run happens, **rewrite this file's Result column and turn the predictions into
  measurements**, the way `WINDOWS-CHECKLIST.md` was rewritten. A prediction file that is never
  reconciled is worse than none

## Done as part of this bring-up

- pinned `lib/macosx/libsciter.dylib` and recorded its size, hash, architectures, signature, install
  name and dependencies — all read from the file, no Mac involved. It was briefly committed, which is
  what settled the repository-size question for every platform: see [`UPGRADING.md`](./UPGRADING.md)
- fixed the macOS CI gate, which globbed an arch subdirectory that nothing else in the repository uses
  and therefore skipped the job unconditionally while reporting success
- gave the `macos` job the shape of the Linux one: engine verification, a dylib report, `api-map-verify`,
  `check`, a window canary, the test suite with a per-example timeout, and a leak sweep
- added `.github/scripts/macos-canary.sh`
- added `darwin_arm64` to `just cross-check` — the architecture CI actually builds on, previously
  unchecked
- extended `examples/single_binary.odin`'s `when` to Darwin and removed its exclusion from `cross-check`
- recorded the null-list prediction next to `MACOS_NULLS`
