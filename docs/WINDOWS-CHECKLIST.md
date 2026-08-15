# Windows bring-up

Status: **Windows x64 is vendored and has been run**, on a real desktop, on 2026-08-15. This file was a
checklist of things that could not be established without a machine; it is now the record of what that
machine said, and of the four things still open.

Engine: 6.0.4.9, `bin/windows/x64/sciter.dll`, 19 261 952 bytes,
`b49ff94759951c4dd87f18a0edac466adb48a352bdecadbd6d5568f5e2203083`, recorded in
`external/sciter/VENDORED.md`. Not `bin/windows.d2d/` (Direct2D) and not `bin/windows.xp/`.

## What a Windows machine needs

- **Odin**, **just** ≥ 1.49, and **uv**. That is the whole list. The justfile's multi-step recipes are
  `[script]` Python running through `uv run --no-project -p 3.14 python`, and its one-liners run under
  `cmd.exe`, so **nothing here needs bash on Windows** - see `justlib.py`'s header for what forced that.
  The short version is that `bash` on a stock Windows PATH is the WSL launcher, so a shebang recipe
  silently ran in a Linux VM with none of the toolchain, and `just` additionally wants `cygpath` and
  fails outright without it:

  ```
  error: could not find `cygpath` executable to translate recipe `check` shebang interpreter path
  ```

- Nothing else. No SDK is needed for anything below except steps 9 and 10.

## The results

| | Step | Result |
| --- | --- | --- |
| 1 | vendor the DLL | done; `just fetch-engine --check` verifies it |
| 2 | `just api-map-verify` | **passes, and is now a gate** - 189 slots, ISciterAPI version 10 |
| 3 | `just example hello_window` | window opens, HTML and CSS render. No XIM equivalent of the Linux segfault |
| 4 | `just check` | 28 examples build |
| 5 | `just example-tests` | runs; the windowed tests **run rather than skip**. 11 examples still fail - see below |
| 6 | core paths | `eval`, `dom_walk`, `events`, `call_odin_from_js` all have failing tests; see below |
| 7 | resource loading | `custom_loader` passes, `archive` passes, `request_loader` faults at exit |
| 8 | `just example single_binary` | **done** - see below |
| 9 | `just example inspector` | not yet run |
| 10 | `just extension-run` | `just extension` builds `odin-ext.dll`; running it under scapp not yet done |
| 11 | `just sanitize hello_window` | not yet run |
| — | `just leak-check` | **clean** - 10 resource kinds exercised and balanced. No Windows-only leak |
| — | `just lint`, `check-ownership`, `parity --check`, `stats --check` | pass |

## What was measured, and where it differed from what was predicted

**The ISciterAPI null list is the Linux list minus `SciterProcND`.** One slot is the entire difference
between the platforms. The prediction recorded here before the machine existed was that Windows would
*fill* `SciterProc`, `SciterTranslateMessage` and the D2D/DirectX entries. It fills none of them:
`SciterProc` and `SciterTranslateMessage` are the Sciter 4 HWND message-pump entry points and Sciter 6
owns its own window procedure, and the D2D/DirectWrite/DirectX slots belong to the `windows.d2d` build
this one deliberately is not. **An application must not reach for `SciterProc` or
`SciterTranslateMessage` on Windows.**

**`sciter.dll` exports 276 named symbols, not one.** The prediction was that only `SciterAPI` was
exported, so almost every slot would resolve as `sciter.dll+0x...` and rule 3 of the api-map check would
degrade to module containment. In fact 172 of the 174 non-null slots resolve to their own `...Imp` name,
so the Windows check is as strong as the Linux one and `check-api-map.py` now applies the same rule to
both. The two exceptions are the two whose `Imp` is genuinely absent from the export table, so dbghelp
names the export below them: `SciterProcND` and `SciterEGLGetProcAddress`, both
`SciterRequestAPIImp+0x1c...`.

**Two slots resolve to another function's name, and it is `/OPT:ICF`, not offset drift.** MSVC folds
byte-identical functions onto one address and the export table then carries several names for it.
Verified by parsing the export directory rather than inferred - the names share an RVA:

| RVA | names | what it is |
| --- | --- | --- |
| `0x19354` | `SciterGetAttributeByNameImp`, `SciterGetElementNamespaceImp`, `SciterGetNthAttributeImp`, `SciterGetObjectImp` | `mov eax,5; ret` - all four are `SCDOM_OPERATION_FAILED` stubs |
| `0x17ba8` | `SciterElementWrapImp`, `SciterNodeWrapImp` | one real function; wrapping an element and a node is the same code |

Read a *new* pair appearing here as "are these two really the same code" before reading it as drift:
drift shifts every slot after it, not two in isolation.

**`os.rename` over an existing destination works.** This was the worry recorded against `embed.odin` -
POSIX `rename(2)` replaces silently and Win32 `MoveFile` refuses. Odin's `core:os` uses the replacing
variant, so `write_engine`'s rename-into-place behaves identically on both platforms, and the second run
of `single_binary` does not error. Measured directly, not inferred from the tests passing.

**`os.stat(...).inode` is 0 for every file on Windows.** Two `single_binary` tests asserted `a
replacement is a rename, not an overwrite` through inode identity, which on Windows is not a weak test
but a vacuous one - `0 != 0` never holds. Those assertions are now gated on `INODE_IS_MEANINGFUL`; the
content and size assertions, which are what actually matter, run everywhere.

**`single_binary`'s cache behaves exactly as designed.** The engine extracts to
`%LOCALAPPDATA%\odin-sciter\<hash>\sciter.dll` - measured
`C:\Users\...\AppData\Local\odin-sciter\6edbb3491c2976bf\sciter.dll`, 19 261 952 bytes, the vendored DLL
byte for byte. A second run reuses it: same path, unchanged mtime. **Anti-malware did not quarantine
it**, which was flagged here as the single most likely Windows-specific failure in the repository. One
data point on one machine with one product, so it is evidence rather than proof.

**`set_option` differs less than expected, and not where expected.** Measured across all seventeen
options, with and without a window. `.SMOOTH_SCROLL` needs a window on *both* platforms;
`.FONT_SMOOTHING` and `.ENABLE_UIAUTOMATION` are refused on both - the latter despite UI Automation
being a Windows API. What actually differs is the HTTP client pair, `.CONNECTION_TIMEOUT` and
`.HTTPS_ERROR`: refused on Linux, accepted on Windows, because Linux uses the system client and has
nothing to configure. Windows additionally has `.TRANSPARENT_WINDOW`, `.ALPHA_WINDOW` and
`.SET_MAIN_WINDOW`, and all three need a window. The `when` in `script_bridge.odin` and the table on
`set_option` in `app.odin` are now written from this rather than from Linux alone.

**The display gate was right, and it cost what it was meant to.** `have_display` returns true
unconditionally on Windows, so the first real run executed the whole suite rather than skipping two
thirds of it silently. That is why this list has an open-failures section.

## Still open

### 1. An access violation inside the engine at process teardown

`call_odin_from_js` and `request_loader` pass **every** test and then fault, so the tests are green and
the exit code is not. Located precisely:

```
AV on thread <main> at sciter.dll+0x3db6b, reading 0x38
```

A null-pointer dereference at `this+0x38`, inside the engine, in unexported code (0x175c7 past the
nearest export, so there is no name to give). What is established about it:

- it needs at least one test to have run - a binary whose test filter matches nothing exits cleanly
- calling `sciter_app.shutdown()` first does **not** prevent it
- `@(fini)` never runs; the fault is earlier, in the test runner's deferred cleanup
- **the faulting thread is the main thread, and the engine was initialised on a worker thread.** The
  test runner runs tests on a pool thread, so `init` and `create_window` happen there, and the main
  thread then tears the process down. Sciter is thread-affine - every ISciterAPI call must come from the
  thread that ran `SCITER_APP_INIT` - and process teardown is a call it never agreed to.

That last point is the likely root cause and it is a rule applications need, not only a test artifact.
Linux does not show it because Odin's test runner leaves through `os.exit`, which is a direct
`exit_group` syscall: no DLL detach, no destructors, nothing runs. Windows `ExitProcess` runs the
engine's detach path from a thread that never initialised it.

Reproduce with the vectored-exception-handler probe described in the history of this file, or simply:

```
just example-test call_odin_from_js
```

Other examples fault mid-run rather than at exit, and have not been separated from this one yet:
`dom_walk` #22, `eval` #7, `input` #8, `task_list` #4, `sqlite_extension` #0, `graphics_gallery` #25.

### 2. Window state is implemented on Windows and is not on Linux

The characterization tests were measured on Linux and assert the engine reports almost nothing. Windows
reports the truth, so they fail:

- `dom_walk.test_a_window_that_was_never_shown_reports_itself_closed` - Windows says `HIDDEN`, Linux
  says `CLOSED`
- `dom_walk.test_asking_for_a_window_state_never_breaks_the_window` - asking for `MINIMIZED`,
  `MAXIMIZED` and `HIDDEN` gets each of them back, where Linux only ever reports `SHOWN` or `CLOSED`
- `workbench.test_a_secondary_window_is_closed_by_hiding_it_and_pumping_first` - and a destroyed window
  reports `0xFFFFFFFE`, which is not a value the enum has

Mechanical: widen the `when`s the way `set_option`'s were. The Windows behaviour is the *better* one, so
the guards should not read as "Windows is the exception".

### 3. Behavioural differences not yet characterized

- `dom_walk.test_element_uid_is_readable_but_not_resolvable` - the UID **is** resolvable on Windows; the
  test name is a Linux fact
- `dom_walk.test_finalizing_a_removed_node_takes_it_out_of_the_document` - `node_remove(finalize=true)`
  returns `INVALID_PARAMETER`
- `input.test_combine_url_resolves_against_the_document` - `combine_url("style.css")` against
  `file:///base/dir/doc.htm` yields `file://base/dir/style.css`, one slash short of the Linux answer.
  **This is the one that looks like a defect rather than a platform fact** and is worth reading before
  the others.
- `eval.test_a_value_scope_releases_the_whole_batch` - `Call_Failed`
- `graphics_gallery.styled_element` - `Not_Found` / `INVALID_HANDLE`

### 4. Steps 9, 10 and 11

`just example inspector`, `SCITER_SDK=... just extension-run`, and `just sanitize hello_window`. The SDK
is at `C:\Users\Enerqi\dev\sciter-js-sdk` on this machine and has all three tools in the layout the
justfile expects. For step 11, read the justfile's own comment first: Windows ASan does not intercept
Odin's `HeapAlloc`-based allocator and so catches no heap errors at all. A clean Windows ASan run rules
out stack bugs and nothing else.

## Notes for whoever runs this next

**`just check` and `just lint` skip `integration` and `native_child` off Linux.** They are raw Xlib and
`vendor:x11/xlib` declares nothing elsewhere, so they cannot build on Windows at all. Without that skip
the Windows CI job could never have passed `just check`, which is most of what that job is.

**The per-example timeout kills the process tree.** `EXAMPLE_TEST_TIMEOUT` used to be GNU `timeout`,
which killed `just` and left the test executable `odin test` had spawned still running and still holding
the inherited stdout pipe - so the ceiling fired and the run hung anyway, which is the opposite of the
point. `run_with_timeout` in `justlib.py` uses `taskkill /T` on Windows and a process group on POSIX.
Note that the budget covers compilation, so a tight ceiling times out examples that are merely slow to
build.

**`just fetch-engine` on Windows runs `python`, not `python3`**, and `engine_sha256` is per-platform.
It was a single value, which meant fetching on Windows compared `sciter.dll` against the Linux `.so`'s
digest and refused to install - the recipe that exists to install the engine could not install it.

**`libpng error: IDAT: incorrect header check`** is printed by `just leak-check` on Windows. The sweep
still reports clean. Not investigated.

## After the open items close

- update the platform table in `README.md` (Windows row: vendored yes, tested yes)
- update `docs/PLAN.md` milestone 10
- update `docs/deployment.md`'s status note, which currently says Windows is unverified
- per `docs/UPGRADING.md`, the repository's history cost is now ~19 MB per engine bump rather than ~11,
  so the row-10 hybrid (Linux committed, Windows on releases) has stopped being hypothetical
