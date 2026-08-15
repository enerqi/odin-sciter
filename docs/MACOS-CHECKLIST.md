# macOS bring-up

Status: **the engine is vendored; nothing has been run yet.** This file is written *before* the first
run, on purpose. [`WINDOWS-CHECKLIST.md`](./WINDOWS-CHECKLIST.md) earned its keep because the
predictions in it were recorded before the machine existed and then turned out wrong twice — the null
list was not what was predicted, and `sciter.dll` exported 276 symbols rather than the one that was
expected. A prediction that is only written down after the measurement is not a prediction.

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
| 3 | `just api-map-verify` | 189 slots, version 10, 0 mismatches; null list per §5 below | |
| 4 | `just check` | builds; nothing is X11- or Win32-shaped outside the two excluded examples | |
| 5 | `just window-canary` | the open question — see §1 | |
| 6 | `just example-tests` | the second open question — see §2 | |
| 7 | `just leak-check` | clean, as on both other platforms | |
| 8 | `just cross-check` (Linux) | now covers `darwin_arm64` as well as `darwin_amd64` | **done** |
| 9 | `just example single_binary` | embeds all 50 MB and extracts to `~/Library/Caches/odin-sciter` | |
| 10 | `just pack`, `just inspector` (needs the SDK) | the justfile's `macosx` / `inspector.app/Contents/MacOS` paths are untested | |

---

## The predictions

### 1. Does a CI runner have a window server?

**The single question the whole job depends on.** A process in a `Background` launchd session has no
connection to WindowServer, and AppKit does not degrade when that is true — it aborts, classically with
`_RegisterApplication(), FAILED TO establish the default connection to the WindowServer`. GitHub's
macOS runners are believed to run in an `Aqua` session, which would make this a non-issue, but
"believed" is why `.github/scripts/macos-canary.sh` prints `launchctl managername` first thing.

Prediction: **it works.** The canary exits 124 and the suite runs.

If it does not, the port is not blocked — it is reduced. The display-free two thirds of the suite still
run (`have_display()` already expresses that split, and would need a WindowServer check on Darwin
rather than its current unconditional `true`), and the windowed third would wait for a real Mac.

### 2. The main thread — the likeliest thing to sink the suite

AppKit requires window work on the main thread. The engine's `HWINDOW` **is** an `NSView*`
(`sciter_app/window.odin:6`), and Odin's test runner does not run tests on the process main thread.

That is the same shape as the Windows finding — a test *runner* incompatibility, not a binding bug —
which took the Windows bring-up a patch to solve
([`odin-test-runner-windows.patch`](./odin-test-runner-windows.patch)).

Prediction: **the canary passes and the windowed tests fault**, because the canary is a plain program
with its window on the main thread and the tests are not. Predicted symptom: an abort or an assertion
naming a main-thread requirement, in every windowed test, on every example — the failure that looks
like a broken binding and is not one.

Fallback if that happens, in preference order:

1. check whether `ODIN_TEST_THREADS=1` (already passed by the test recipes) puts tests on the main
   thread on Darwin — if it does, there is nothing to do
2. drive the windowed examples as *programs* under the canary harness, and keep only the display-free
   tests under `odin test`. The split already exists in every example as `have_display()`
3. a runner patch, as on Windows

### 3. Quarantine

`just fetch-engine` downloads through `urllib`, which does not set `com.apple.quarantine`; a
`git checkout` does not either. A dylib that arrived through a browser or an unzipped SDK archive
does, and is then refused with an error that reads like a missing file.

Prediction: **not an issue in CI.** For a human who fetched the SDK by hand: `xattr -dr
com.apple.quarantine <path>`. The CI job prints `xattr -l` so this is never a guess.

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
