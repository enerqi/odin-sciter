# Review: build system, code generation, CI, repository hygiene

Scope: `justfile`, `.github/workflows/{ci,bindgen,canary}.yml`, `.github/actions/toolchain/action.yml`,
`LICENSE`, `external/sciter/`, `lib/`, `.gitattributes`, `src/prelude.odin`, `docs/UPGRADING.md`,
`docs/WINDOWS-CHECKLIST.md`.
Date: 2026-08-13

## Summary

This is the strongest part of the project and it is not close. `bindgen.yml` pins the generator by
commit (`BINDGEN_COMMIT: 12f4e7a`) and asserts that regeneration is **byte-identical** to the committed
`sciter.odin` — the check most binding projects skip and then regret. `canary.yml` polls upstream's SDK
weekly and opens an issue, so an engine release is discovered rather than stumbled into. `ci.yml` runs
the slot verification, the full build, 364 tests under Xvfb with the X11 IME workaround applied, and
ASan on the `Value` refcounting path — and every non-obvious choice in it carries a comment explaining
why, including why there is no blanket retry and why the display stack is probed before the tests rather
than diagnosed from their wreckage. Licensing is handled properly: the engine EULA is vendored
separately from the SDK's BSD licence, and `README.md:262-270` explains which covers what.

Three real gaps. The `lint` recipe — the only thing enforcing `-vet`, `-strict-style` and `-vet-tabs` —
is never run by CI. The macOS engine path CI probes (`lib/macos/`) is not the path the loader searches
(`lib/macosx`), so following the bring-up instructions would produce a vendored engine the library
cannot find. And the 24 MB engine binary is committed to git with no LFS, which is a one-time cost today
and a compounding one at every SDK upgrade.

## Findings

### R7-01 — CI never runs `just lint`, so `-vet` and `-strict-style` enforce nothing  [severity: major]

**Where:** `.github/workflows/ci.yml` (steps: `api-map-verify`, `check`, `example-tests`,
`test_sanitize`), `justfile:129-130` (`lint`), `justfile:507-521` (`check`)
**What:** the two recipes differ in exactly the flags that matter:

```
lint:  odin check . -vet -vet-cast -strict-style -vet-tabs -no-entry-point
check: odin check . -no-entry-point          # plus per-example builds
```

CI runs `check`. It never runs `lint`, and it never runs `odinfmt` in check mode.
**Why it matters:** the `lint` recipe carries a comment (`justfile:123-125`) explaining that `-vet-tabs`
"is the only compiler-side enforcement of .editorconfig's `indent_style = tab`; it is not implied by
`-strict-style`, so without it a space-indented file lints clean". That reasoning was worked out and then
not wired to anything. Unused variables, shadowed declarations, suspicious casts and space indentation
all land on master today without complaint. The formatting side is worse than merely unenforced: `just
format` is known to fail on `examples/dom_walk.odin` (a local variable named `inline`) and to churn
`custom_loader.odin` and `extension.odin` on every run, so the formatter cannot currently be run
repository-wide at all — which is precisely why it needs a CI gate to stop the drift getting deeper.
**Fix:** add a `lint` step to the Linux job — it is seconds, needs no engine and no display, so it can
run before `check`. Fix the `dom_walk.odin` `inline` shadow and the two churn files (see the memory note
on that), then add `odinfmt -l` (list-only, non-zero exit on difference) as a second step. Until the
churn is fixed, gate the formatter check to the files it is clean on rather than leaving it out entirely.

### R7-02 — CI probes `lib/macos/`; the loader searches `lib/macosx`  [severity: major]

**Where:** `.github/workflows/ci.yml` macOS job — `ls lib/macos/*/libsciter.dylib` and the notice text
"no libsciter.dylib under lib/macos/"; against `src/prelude.odin:135-136`:

```odin
} else when ODIN_OS == .Darwin {
    add(&candidates, "lib/macosx")
```

and `justfile:9` `packfolder_platform := ... "macosx" ...`, `justfile:10` `scapp_platform := ...
"macosx" ...`.
**What:** three places spell the macOS vendor directory `macosx`; the CI job spells it `macos`, twice —
in the existence test and in the message telling a maintainer where to put the file.
**Why it matters:** the macOS job's whole purpose is to activate itself the moment somebody vendors the
dylib, and its notice is the instruction for how. Someone following that instruction puts
`libsciter.dylib` in `lib/macos/<arch>/`, the job goes green, `just api-map-verify` and `just check` run
— and then `sciter.load()` at runtime never looks there, falls through to the bare-name system search,
and reports `.Library_Not_Found` with a candidate list that does not include the file that is sitting
right there. That is the single most confusing failure this library has an error message specifically
designed to prevent. The Windows job has the same shape and gets it right (`lib/windows/x64/sciter.dll`
matches `prelude.odin:134`), which is what makes this a typo rather than a design difference.
**Fix:** change both occurrences in the macOS job to `lib/macosx/`. Better, remove the possibility:
have `src/prelude.odin` export the per-platform relative directory as a constant, and have the justfile
and CI read it rather than each spelling it.

### R7-03 — the 24 MB engine is committed to git with no LFS  [severity: major]

**Where:** `lib/linux/x64/libsciter.so` (24 MB, tracked); `.gitattributes` contains no `filter=lfs`
entries
**What:** verified — the binary is a normal git object, and `.gitattributes` (2.6 KB, otherwise
thorough about line endings) has no LFS configuration at all.
**Why it matters:** three compounding costs, and the third is the one that bites later.
1. Every clone is 24 MB minimum. `README.md:59` says `git clone --depth 1`, which mitigates it and is
   not explained (see finding R5-05).
2. Every SDK upgrade adds another ~24 MB **permanently** to history, because a binary does not delta
   against its predecessor. `docs/UPGRADING.md` describes the upgrade as routine and `canary.yml` is
   designed to surface upstream releases weekly, so the intended cadence is "regularly". Ten upgrades is
   a quarter-gigabyte repository whose working tree is 24 MB.
3. Windows and macOS are both scheduled to be vendored, at which point every clone carries three engines
   for whichever platform the user is on.

`docs/PLAN.md:63` already notes that a full-history clone of the *upstream* SDK is ~4 GB because "800+
commits, each carrying every platform's binaries" — the exact failure mode being reproduced here on a
smaller scale.
**Fix:** move `lib/**/libsciter.*` and `lib/**/sciter.dll` to git-lfs before the second engine binary
lands; retroactively is far more painful. If LFS is unwanted (it complicates forks and some CI setups),
the alternative is not vendoring at all — a `just fetch-engine` recipe that downloads and checksums the
binary from the pinned SDK tag, with the checksum committed. Either way the decision belongs in
`docs/UPGRADING.md`, which is the document that will otherwise carry the cost.

### R7-04 — the `check` recipe rebuilds every example into the same output path  [severity: minor]

**Where:** `justfile:513-520`
**What:**

```sh
for f in examples/*.odin; do
    ...
    odin build "$f" -file -out:{{ target_path("debug", "check.exe") }}
done
```

Twenty-seven examples are compiled and linked in sequence, each overwriting `check.exe`.
**Why it matters:** correct, and the slowest step in CI after the test suite — a full link per example
for an artifact that is immediately discarded. `odin check -file` would type-check without linking, but
the recipe deliberately *builds*, and the reason is sound: `examples/single_binary.odin` has a
`#panic` guarded by a `when` that only fires at build time, and linking is what proves the examples are
shippable. So the cost is bought on purpose. What is not deliberate is the serial execution and the
shared output path, which together prevent the obvious fix.
**Fix:** give each example its own `-out:` under `target/debug/check/` and run the loop with `xargs -P
$(nproc)`. On a 4-core runner that is roughly a 3× reduction in the longest non-test CI step, for a
two-line change. The distinct output paths are also what make a failure identifiable — currently a
failed build in the middle of the loop leaves `check.exe` from the previous example.

### R7-05 — the Windows job's own comments record two unresolved questions as inline TODOs  [severity: minor]

**Where:** `.github/workflows/ci.yml`, Windows job, the comments above "Type check and build everything"
and "Run the example tests"
**What:** two open questions live in workflow comments:
- "single_binary's `when` needs extending once the DLL is vendored (checklist step 8) or this fails on
  its deliberate `#panic` — that is the failure telling you to do step 8, not a broken build."
- "the windowed tests gate on DISPLAY/WAYLAND_DISPLAY, which are POSIX variables that do not exist on
  Windows. Watch whether this run skips them (wrong, but harmless) or runs them (correct). If it skips,
  the gate needs to treat Windows as always having a display."
**Why it matters:** the second one is answerable now, without a Windows machine and without vendoring
anything: `have_display()` in the examples tests `DISPLAY`/`WAYLAND_DISPLAY`, neither of which exists on
Windows, so the job **will** skip roughly two thirds of the suite the first time it runs. Since the whole
point of `docs/WINDOWS-CHECKLIST.md` step 5 is to find out whether the tests pass on Windows, the job as
written is set up to report a green run that tested almost nothing. Predicting the answer is cheaper than
discovering it during the bring-up, when attention is elsewhere.
**Fix:** make `have_display` return true unconditionally `when ODIN_OS == .Windows` — one line in the
shared harness proposed in finding R4-02 — and fold both notes into `docs/WINDOWS-CHECKLIST.md`, which is
where the open items belong. A CI comment is a poor issue tracker; it is only read by whoever is already
editing that file.

### R7-06 — `bindgen.yml` guards regeneration, but only on paths, and the pin has no expiry  [severity: minor]

**Where:** `.github/workflows/bindgen.yml` — `on.push.paths` / `on.pull_request.paths`, and
`BINDGEN_COMMIT: 12f4e7a`
**What:** the byte-identical regeneration check runs only when `sciter.odin`, `bindgen.sjson`, `src/**`,
`external/sciter/include/**` or the workflow itself changes. The generator is pinned to a commit with no
mechanism for noticing that upstream has moved.
**Why it matters:** the path filter is right and the pin is right — this is a much better position than
most projects. The gap is that the pin is invisible: nothing tells the maintainer that `odin-c-bindgen`
has had six months of fixes, and `sciter.odin` is 2769 lines of generated code whose quality is entirely
a function of that tool. `canary.yml` already implements exactly the right pattern for the *engine* —
poll upstream weekly, open an issue on a new tag — and the generator has none.
**Fix:** add a second job to `canary.yml` that compares `BINDGEN_COMMIT` against `odin-c-bindgen`'s
default branch head and mentions the gap in the same weekly issue. Ten lines, and it reuses machinery
that already exists.

**Done, and the pin moved while doing it.** The `bindgen-pin` job in `canary.yml` is the drift check.
`BINDGEN_COMMIT` itself no longer exists: it was declared in `bindgen.yml` *and* `canary.yml` and
nowhere a developer could see, so `just bindgen` locally used whatever the sibling checkout happened to
be at while CI asserted byte-identical output against `12f4e7a`. It is `bindgen_commit` in the justfile
now, read by both workflows, and `just bindgen` verifies the local checkout against it — plus that the
binary is not older than the commit, and that the host is Linux, since regenerating on Windows emits a
`sciter.odin` that does not compile. The same one-place-for-the-pin fix landed for odinfmt (`ols_tag`),
whose version had lived only in `.github/actions/toolchain/action.yml` and had already drifted.

### R7-07 — `spike/` and `docs/snippets/` are built by CI but are not part of the deliverable  [severity: minor]

**Where:** `justfile:120` (`odinfmt -w spike`), `justfile:512` (`odin check docs/snippets`), `spike/`
(three programs, 752 lines)
**What:** `spike/skeleton`, `spike/windowless` and `spike/smoke` are development scratch programs kept in
the repository and formatted by `just format`; `docs/snippets/snippets.odin` (1043 lines) is type-checked
by `just check` but is not an example and is not documented as a place to look.
**Why it matters:** `docs/snippets` being type-checked is genuinely good — it is what stops the code in
the guides from rotting, and it should be advertised rather than hidden in a recipe. `spike/` is the
opposite: three programs that duplicate what `examples/windowless.odin` and `examples/hello_window.odin`
now cover, carrying a maintenance cost (formatting, and the drift that follows when they are not
type-checked — note `check` does *not* build `spike/`, so those 752 lines can stop compiling silently).
**Fix:** say in `docs/PLAN-TESTING-AND-EXAMPLES.md` that `docs/snippets/snippets.odin` is the compiled
home of every code block in the guides, and how to add to it. Delete `spike/` or move it to a branch —
it served its purpose, the examples superseded it, and it is the only Odin in the tree that nothing
compiles.

**Done.** `spike/skeleton`, `spike/windowless` and `spike/smoke` are deleted — in the history if anyone
wants them — and `spike/xdnd/xdnd_source.py`, which is a live test harness rather than scratch work, is
now `tools/xdnd_source.py`. `spike` is out of `FORMAT_ROOTS` and out of the `format` recipe. The
`docs/snippets/` half is documented in `docs/PLAN-TESTING-AND-EXAMPLES.md`, along with the rule the
deletion leaves behind: Odin in this tree is either compiled or deleted.

## What is good, specifically

- **`bindgen.yml` asserts byte-identical regeneration against a commit-pinned generator.** This is the
  single most valuable check in the repository and it is rare. It means `sciter.odin` can be treated as
  a build artifact that happens to be committed, which is what makes the "propose changes to
  `bindgen.sjson`, not to `sciter.odin`" rule enforceable rather than aspirational.
- **`canary.yml` polls upstream weekly and opens an issue.** The project's founding lesson
  (`docs/PLAN.md:35-50`: the abandoned GitHub mirror ships a header its own binary does not implement)
  is about not noticing upstream. This is the mechanism that stops it recurring.
- **Every non-obvious CI choice is explained in a comment** — why Xvfb's screen depth is given
  explicitly, why `XMODIFIERS=@im=none`, why `GALLIUM_DRIVER` as well as `LIBGL_ALWAYS_SOFTWARE`, why
  `EXAMPLE_TEST_TIMEOUT` bounds each example instead of the job, why there is no blanket retry. The
  "no blanket retry — if the timer tests flake here that is a reason to fix the tests" note is the right
  call and worth keeping when they do.
- **Platform jobs gate on the binary being vendored and report what they skipped**, rather than being
  deleted or left red. Turning macOS on is one file drop — modulo finding R7-02.
- **Licensing is correct and explained.** Engine EULA vendored separately from the SDK's BSD licence,
  `README.md:262-270` states which covers what, and `sciter_app/embed.odin:25-29` reasons about the
  embedding case explicitly and flags it as a reading of the text rather than advice.
