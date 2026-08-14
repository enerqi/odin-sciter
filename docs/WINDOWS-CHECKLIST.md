# Windows bring-up checklist

Everything that could be established without a Windows machine has been. This is the part that cannot:
the list to work through top to bottom when one is available, with the expected result of each step so
that a surprise is recognisable as one.

Status: **Linux x64 is the only platform vendored and run.** Windows is expected to work — the
`ISciterAPI` layout is identical on every platform, the calling convention is already handled, and
everything in this repository type checks for `windows_amd64` — but "type checks" is not "runs".

## What was already done for Windows, without the machine

- **`odin check -target:windows_amd64` passes** for `package sciter`, `package sciter_app`,
  `docs/snippets`, and every *portable* example. That is the cheap half of a port and it is done:

  ```sh
  just cross-check          # windows_amd64 and darwin_amd64, both packages, snippets, examples
  ```

  It runs on every push (`.github/workflows/ci.yml`), which is what stops this rotting: nothing here
  builds for Windows day to day, so an example that stops checking there is otherwise invisible until
  someone has the machine.

  Three examples are excluded, each deliberately rather than because it failed. `integration` and
  `native_child` are raw Xlib — they are the two halves of "a Sciter view and a native window inside
  each other", and on Linux that means X11; the Windows equivalents would be different programs, not
  the same program compiled elsewhere. `single_binary` embeds the engine with `#load` and only the
  Linux binary is vendored, so it stops at its own `#panic` — which is step 8 below.

- **`examples/api_map.odin` was rewritten to build and mean something on Windows.** It previously used
  `dladdr` through `foreign import dl "system:dl"`, which does not exist on Windows — the one tool the
  upgrade procedure tells you to run first would not have linked. It now resolves symbols through
  dbghelp, falls back to `VirtualQuery` + `GetModuleFileNameW` for module attribution, and prints the
  null-slot list explicitly. See the header comment for why the Windows check is weaker than the Linux
  one.

- **`just pack` and `just extension-run` now look for `packfolder.exe` and `scapp.exe`** via a new
  `exe_ext` variable. They would have failed to find the SDK's tools otherwise.

- The justfile's other Windows handling came with the skeleton and is believed sound: `radlink` as the
  default linker, `cmd.exe` as the shell, `.dll` for `shared_ext`, `windows/x64` for `scapp_platform`,
  `windows` (no arch subfolder) for `packfolder_platform`.

## Bring-up, in order

Steps 2, 4, 5 and 7 are already wired into CI: `.github/workflows/ci.yml` has a `windows-2022` job that
sits dormant while `lib/windows/x64/sciter.dll` is absent and runs `just api-map-verify`, `just check`
and `just example-tests` the moment it is committed. So step 1 below turns the job on, and a good part
of this list then answers itself on a runner — including step 5's open question about the display gate.
What a runner cannot answer is anything that needs eyes on a window (steps 3, 6, 9) or a real desktop's
anti-malware (step 8).

**1. Vendor the binary.**

```
lib/windows/x64/sciter.dll        <- from the SDK's bin/windows/x64/
```

Use the plain `bin/windows/` build, not `bin/windows.d2d/` (a Direct2D variant) or `bin/windows.xp/`.
Record its size and SHA-256 in `external/sciter/VENDORED.md` beside the Linux entry.

Check `.gitattributes` marks `*.dll` binary — it already covers `*.so`/`*.dll`/`*.dylib`, but confirm
before the first commit, because a `.dll` that goes through line-ending normalisation is a corrupt
`.dll` and the failure looks like a broken engine rather than a broken checkout.

**2. `just example api_map`.** The step everything else depends on.

Expected: **189 slots**, `ISciterAPI version 10`, and a *different* null list from Linux —
`SciterProc`, `SciterProcND`, `SciterTranslateMessage` and the D2D/DirectX entries should now be
**present**, while `SciterCreateWidget` (Linux/GTK-era) and `SciterCreateNSView` (macOS) should be
**null**. `SciterGetViewExpando` and `reserved1..4` are null everywhere.

Most slots will print `sciter.dll+0x...` rather than a name: sciter.dll exports only `SciterAPI`, so
there is nothing for dbghelp to resolve without a PDB. **That is expected and is not a failure.** What
matters is that every non-null slot lands inside `sciter.dll`. A slot pointing into some *other*
module, or `<unmapped>`, is a real problem.

Record the null list in the header comment of `api_map.odin`, where the Linux one already is.

**3. `just example hello_window`.** A window with rendered HTML and CSS. The Linux XIM segfault
(`XSetICFocus`, worked around with `XMODIFIERS=@im=none`) is X11-specific and should not appear.

**4. `just check`.** Both packages, the doc snippets and all twenty-one examples build.

**5. `just example-tests`.** All tests, with `-define:ODIN_TEST_THREADS=1` already in the recipe. The tests that
need a display gate themselves on `DISPLAY`/`WAYLAND_DISPLAY`, **which are POSIX environment variables
that do not exist on Windows** — so check whether those tests skip themselves (wrong, but harmless) or
run (correct). Fix the gate to treat Windows as always-having-a-display if they skip.

**6. `just example eval`, `dom_walk`, `events`, `call_odin_from_js`.** The core paths: script, DOM,
events, native functors. Watch for anything UTF-16-shaped going wrong — Windows is where an
encoding-conversion bug would show up differently, though the C API is UTF-16 on every platform so
there is no separate code path to get wrong.

**7. `just example custom_loader` and `archive`.** Resource loading. `archive` uses the committed
`app.pak` and needs no SDK.

**8. `just example single_binary`.** This one **will not compile as-is**: `ENGINE` is behind
`when ODIN_OS == .Linux && ODIN_ARCH == .amd64`, with a deliberate `#panic` otherwise. Extend the
`when` to cover Windows once the DLL is vendored, then check the interesting parts:

- the cache directory resolves to `%LOCALAPPDATA%\odin-sciter\<hash>\sciter.dll`
- the file is written once and reused on the second run
- **anti-malware does not quarantine it.** A freshly written DLL is exactly the heuristic pattern, and
  this is the single most likely Windows-specific failure in the repository. If it trips, that is a
  finding for `docs/deployment.md`, not necessarily a bug to fix.

**9. `just example inspector`.** Needs the SDK's `inspector.exe` running; `SCITER_SET_DEBUG_MODE` and
`.ENABLE_DEBUG` are already set by the example.

**10. `just extension` and `SCITER_SDK=... just extension-run`.** Builds `odin-ext.dll` and runs it
under `scapp.exe`. `loadLibrary("odin-ext")` looks for `odin-ext.dll` beside the executable, and
`-out:` already names it exactly. The `.exe` suffixes fixed above are what make this recipe find the
SDK's tools at all.

**11. `just sanitize hello_window`.** ASan on Windows is genuinely different from Linux: it does not
intercept Odin's `HeapAlloc`-based allocator the way it intercepts the Linux one, so it catches less.
The justfile's own comments cover this. Do not treat a clean Windows ASan run as equivalent to a clean
Linux one.

## Things to look at specifically

**`single_binary.odin` will fail the build until its `when` covers Windows.** It has a deliberate
`#panic` for platforms whose engine is not vendored, so `just check` on the Windows CI job fails on it
the first time the DLL lands. That failure is step 8 of this list asking to be done, not a regression -
which is worth knowing before someone reads it as a broken build. (Previously recorded as a TODO in
`ci.yml`; it belongs here.)

**The display gate is already correct here, and its cost is that nothing has run.** `have_display` in
the examples returns true unconditionally `when ODIN_OS == .Windows`, because `DISPLAY` and
`WAYLAND_DISPLAY` are X11/Wayland variables that do not exist on Windows - had it tested for them, every
windowed test would have skipped silently, which is the worst way for a test not to run. So the first
real Windows run executes the whole suite, roughly two thirds of which has never run on this platform.
Budget for that rather than expecting a quick green.

`examples/windowless_gl.odin` is the one deliberate exception: it gates on `ODIN_OS != .Linux` and skips
everywhere else, because it creates its GL context with EGL.

**Recipes with a bash shebang.** `pack`, `extension-run`, `check` and a few others are `#!/usr/bin/env
bash` scripts. `just` runs those through the shebang rather than `windows-shell`, so they need bash in
`PATH` — Git for Windows provides it. If they fail with something like "The system cannot find the file
specified", that is what happened.

**`os.rename` over an existing file.** `embed.odin` writes to a temporary name and renames into place.
Windows `MoveFile` fails when the destination exists, unlike POSIX. The code already treats a failed
rename as "someone else won the race" and verifies the destination's size, so the behaviour should be
correct either way — but confirm the *second* run of `single_binary` does not error, since that is the
path where the destination exists.

**Executable permission bits.** `write_engine` sets read+execute permissions, which mean nothing on
Windows. Harmless, but if a DLL fails to load from the cache directory, permissions are not the reason
— look at anti-malware and at `LoadLibrary` dependency resolution instead.

**Dependent DLL resolution.** `sciter.dll` links only system libraries, so loading it from a cache
directory should be fine. If it is not, that is `LoadLibraryExW(LOAD_WITH_ALTERED_SEARCH_PATH)`
territory, in `core:dynlib`, and worth reporting upstream rather than working around here.

**Path separators.** `examples/load_file.odin`'s `file_url` already converts `C:\x\y` to
`file:///C:/x/y`. Confirm it, since it is the only place in the repository that builds a URL from a
filesystem path.

**The ownership types and the leak sweep are new since this list was written, and none of it has run on
Windows.** All of it is platform-independent by construction, which is the reason to check it rather
than the reason to skip it:

- `Owned_Element` and `Owned_Request` are `distinct` types over the same handles, so they cannot behave
  differently per platform — but they changed the signature of `use_element`, `remove_element` and
  `use_request`, and every example was touched. A build failure here is a missed call site, not a
  platform difference.
- `just leak-check` builds `examples/leak_sweep.odin` with `-debug` and fails if the engine is still
  holding anything at exit. It needs a display (it makes a windowless view, which still needs one — see
  `windowless.odin`), so run it after the window canary. A leak reported *only* on Windows would be a
  genuine finding: it would mean a reference-counting path differs there, which nothing in the wrapper
  intends.
- `sciter_app/tracking.odin` compiles to nothing without `-debug`, so confirm the ordinary
  `just example-tests` run is unaffected and only `leak-check` pays for it.
- `just check-ownership` is a Python script over the source and needs neither engine nor display; it
  should pass identically. If Python is missing from the Windows runner, that step is the one to skip
  rather than to fix in a hurry.

## After it works

- update the platform table in `README.md` (Windows row: vendored yes, tested yes)
- update `external/sciter/VENDORED.md` with the DLL's size and SHA-256
- update `docs/PLAN.md` milestone 10
- update `docs/deployment.md`'s status note, which currently says Windows is unverified
- record the Windows null-slot list in `examples/api_map.odin`
- per `docs/UPGRADING.md`, this is when the repository's history cost goes from ~11 MB to ~19 MB per
  engine bump. Nothing to do about it now, but it is the moment the row-10 hybrid (Linux committed,
  Windows on releases) stops being hypothetical.
