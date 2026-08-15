# macOS bring-up

Status: **vendored, and the first CI run has happened.** The engine loads, the ISciterAPI table verifies,
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

## There is no Mac

Nobody working on this repository owns one, and that is the constraint everything here is shaped by.
The substitute is **GitHub-hosted `macos-14`** — Apple silicon, free on a public repository, and enough
to run every step the Windows desktop ran except the one that matters most.

So the honest end state has three parts rather than two, and `README.md`'s platform table says so:

| | What it means | Who can establish it |
| --- | --- | --- |
| **Vendored** | the pinned engine is in the tree and hash-verified | done, from any machine |
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
| 1 | vendor the dylib, `just fetch-engine --check` | passes | **done** — verified from Windows, no Mac involved |
| 2 | `lipo` / `codesign` / `xattr` report | universal, ad-hoc signed, no quarantine | **done** — read from the file itself |
| 3 | `just api-map-verify` | 189 slots, version 10, 0 mismatches; null list per §5 below | **passes** — the null list it printed still has to be transcribed into `MACOS_NULLS` |
| 4 | `just check` | builds; nothing is X11- or Win32-shaped outside the two excluded examples | **passes** |
| 5 | `just window-canary` | the open question — see §1 | **passes** — see §1, and it is the single most useful result so far |
| 6 | `just example-tests` | the second open question — see §2 | **fails, exactly as predicted** — 18 of 22 abort in AppKit. See §2 |
| 7 | `just leak-check` | clean, as on both other platforms | not reached — step 6 fails first |
| 8 | `just cross-check` (Linux) | now covers `darwin_arm64` as well as `darwin_amd64` | **done** |
| 9 | `just example single_binary` | embeds all 50 MB and extracts to `~/Library/Caches/odin-sciter` | |
| 10 | `just pack`, `just inspector` (needs the SDK) | the justfile's `macosx` / `inspector.app/Contents/MacOS` paths are untested | |

---

## The predictions

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

It is in two examples so far, deliberately chosen to answer two different questions in one run:

- **`windowless`** — the best case. Nothing here needs a window, so if the *thread* is the entire
  problem, these tests come back
- **`behavior`** — the worst case. These need a real window, created from a worker thread after the
  bootstrap. AppKit is documented to want `NSWindow` on the main thread too, so this may well still fail
  — and that answer is the one that decides whether the remaining 16 examples get the same treatment

If `behavior` also comes back, roll the bootstrap out to every example with tests. If only `windowless`
does, the shape of the answer is: **display-free tests under `odin test`, windowed examples driven as
programs** — the split `have_display()` already expresses, with the canary harness generalised to run
them. A runner patch, as on Windows, is the last resort: this is an AppKit rule rather than an Odin bug,
so patching Odin to run tests on the main thread would be fixing it in the wrong place.

### 2a. What passed, and what it proves

Four examples came back green, and they are not a random four:

| Example | Tests | What it establishes |
| --- | --- | --- |
| `archive` | 7 | the engine loads and serves packed resources — no application singleton on this path |
| `drag_and_drop` | 3 | pure data-shape tests, no engine |
| `single_binary` | 8 | **`#load` of the 50 MB universal dylib works**, and the extracted copy loads — so the embedded engine keeps its ad-hoc signature through extraction, which §7 predicted and had no way to check |
| `windowless_gl` | 5 | skips itself off Linux, as designed (its GL context is EGL) |

One failure is not the AppKit one and should not be counted with them: **`sqlite_extension` fails
because `target/debug/odin-sqlite.dylib` was never built** — CI runs `just example-tests` but never
`just extension`, so this example has nothing to load. It is a gap in the job, not a macOS finding, and
it exists on every platform where the extension is not built first. Its exit 134 is a second abort after
the skip message, so it needs a look rather than an assumption.

### 3. Quarantine — **MEASURED: not an issue**

`just fetch-engine` downloads through `urllib`, which does not set `com.apple.quarantine`; a
`git checkout` does not either. Predicted: not an issue in CI. **Confirmed** — the engine loaded on the
runner, which it could not have done under quarantine or an unacceptable signature. This also settles
the code-signing question at the top of this file: ad-hoc is enough to load on arm64.

For a human who fetched the SDK by hand: `xattr -dr com.apple.quarantine <path>`. The CI job prints
`xattr -l` so this is never a guess.

### 4. Bundle and activation policy

An unbundled binary can create windows, but has no `Info.plist` and may never become the frontmost
application — the window opens behind everything and never takes keyboard focus. Irrelevant to CI,
very relevant to someone running `just example hello_window` on their own desk, and the reason
[`deployment.md`](./deployment.md) talks about `Contents/Frameworks/`.

Prediction: **the examples run and the window may not come forward.** Nobody should read that as a
failure, and nobody can confirm it from CI either.

### 5. The null list

Predicted: **15 nulls — the Linux list minus `SciterCreateNSView`**, which is the one slot macOS should
be the platform to fill. `SciterProcND` stays null (Windows-only), `SciterCreateWidget` stays null
(Linux/GTK, and gone in Sciter 6 there too), the D2D and DirectX entries stay null. That would make the
macOS list the same *shape* as the Windows one: one slot different from Linux, a different slot.

Confidence: low, and deliberately so. The identical prediction for Windows was wrong in both directions.
The prediction and its reasoning live next to `MACOS_NULLS` in `.github/scripts/check-api-map.py`, which
**reports rather than enforces** until the first run fills it in. Whatever the job prints goes into that
list in a follow-up commit — and only then does it become a gate.

Secondary prediction, of the kind that was wrong last time: `dladdr` resolves every non-null slot to its
own `…Imp` name, as on Linux. The dylib is not stripped of its exports, or `SciterAPI` itself could not
be found.

### 6. No JIT entitlement is needed

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

- vendored `lib/macosx/libsciter.dylib` and recorded its size, hash, architectures, signature, install
  name and dependencies — all read from the file, no Mac involved
- fixed the macOS CI gate, which globbed an arch subdirectory that nothing else in the repository uses
  and therefore skipped the job unconditionally while reporting success
- gave the `macos` job the shape of the Linux one: engine verification, a dylib report, `api-map-verify`,
  `check`, a window canary, the test suite with a per-example timeout, and a leak sweep
- added `.github/scripts/macos-canary.sh`
- added `darwin_arm64` to `just cross-check` — the architecture CI actually builds on, previously
  unchecked
- extended `examples/single_binary.odin`'s `when` to Darwin and removed its exclusion from `cross-check`
- recorded the null-list prediction next to `MACOS_NULLS`
