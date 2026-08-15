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
| 5 | `just example-tests` | runs; the windowed tests **run rather than skip**. Down from 11 failing examples to 5, and three of those five pass every test and fail only on the exit code - see below |
| 6 | core paths | `events` and `dom_walk` pass; `eval` has more behind a guard, `call_odin_from_js` passes its tests and faults at exit |
| 7 | resource loading | `custom_loader`, `archive`, `graphics_gallery`, `input` pass; `request_loader` passes its tests and faults at exit |
| 8 | `just example single_binary` | **done** - see below |
| 9 | `just example inspector` | **passes, after a real fix** - the example was missing `.SOCKET_IO`; see below |
| 10 | `just extension-run` | **passes** - `odin-ext.dll` builds, scapp loads it, the document gets its values |
| 11 | `just sanitize hello_window` | **clean**, with the expected `interception_win: unhandled instruction` notice. Read the justfile's warning before trusting it: Windows ASan catches no heap errors at all |
| — | `just pack` | works; packfolder found through `SCITER_SDK` |
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

### 0. The biggest single finding: install a debug-output handler

**`sciter_app.set_default_debug_output()` is close to mandatory on Windows, and every test harness in
`examples/` now calls it.** With no handler installed the engine reports CSS and script diagnostics
through `OutputDebugStringW`, and Windows implements that by *raising an exception* -
`DBG_PRINTEXCEPTION_WIDE_C`, `0x4001000A`. With no debugger attached the OS normally handles it and
execution continues, so nothing notices. Odin's test runner is the case where something does notice: it
registers a vectored handler that stops the test on any exception it sees.

Measured: `set_css(window, "this is not css")` inside a test killed that test and every test after it in
the binary, reported as `Signal caught: Unknown` - which reads like a segfault and is not one. The same
sequence in a plain `main` is completely clean, which is what made it look like a thread problem for a
while. Installing a handler routes the diagnostic to the callback and the `OutputDebugStringW` path is
never taken.

That one change took the suite from 11 failing examples to 7, and it is recorded on
`set_default_debug_output` in `app.odin` because it is advice for applications too, not only for tests.

### The state of the suite, as of the last full run

**Green**, on a stock Odin toolchain, which is what CI uses. Every example, every test.

That is down from eleven failing examples and four distinct causes at the start of the bring-up, all
four now closed:

| cause | outcome |
| --- | --- |
| no debug-output handler installed (section 0) | fixed - every test harness installs one |
| a text-free document faults the engine at exit (section 1) | root-caused, worked around in three documents |
| Odin's runner stops a test for any exception (section 1b) | patch written and verified; four tests guarded meanwhile |
| behavioural differences (section 3) | characterization gaps, not faults - measured and recorded |

Two of those are still live bugs in other people's code - the engine's teardown fault and Odin's
exception filtering - and both have reproductions written down here.

### 1. A text-free document faults the engine at process teardown — FOUND, worked around

**A window whose document never renders any text faults inside sciter.dll when the process exits.** An
unhandled null dereference at `this+0x38`, deep in unexported engine code:

```
AV on thread <main> at sciter.dll+0x3db6b, reading 0x38
```

The reproduction is fifteen lines and needs nothing but a window and a document:

```odin
@(test)
zz_min :: proc(t: ^testing.T) {
	sciter_app.load_engine()
	w, _ := sciter_app.create_window({width = 400, height = 300})
	sciter_app.load_html(w, `<html><body><p></p></body></html>`)   // faults at exit
}                                                                  // `<body>hello</body>` does not
```

Bisected down to exactly that. What does and does not matter:

| | |
| --- | --- |
| `create_window` + `load_html` | **required** - either alone is clean |
| `sciter_app.init()` | irrelevant - faults with and without |
| assets, asset classes, `set_global_asset`, native functors | irrelevant - all ruled out individually |
| `show`, `hide`, `close`, pumping | irrelevant |
| `sciter_app.shutdown()` first | does not prevent it |
| **any text in the document** | **the whole difference** |

`<html><body>hello</body></html>` is clean; `<html><body><p></p></body></html>`, `<html></html>` and a
document containing only a `<script>` all fault. Deterministic, 3 runs out of 3. The guess is a
font/text-layout resource created lazily on first layout and released unconditionally at teardown, but
that is inference - the engine is closed source and the faulting code is 0x175c7 past the nearest
export.

**This is why exactly three examples failed the Windows suite**, and why it looked mysterious: they were
the three whose *test* documents render nothing. `call_odin_from_js` used `<p id="out"></p>`,
`request_loader` an `<img>` on its own, `sqlite_extension` a bare `<script>`. Every other example's
document has visible text, which is why realistic documents never showed it.

The workaround is one character: each of those three documents now ends `<p>.</p>`, with a comment
saying why. **Do not tidy those away.** The engine bug is real and unfixed - anything here that loads a
text-free document into a window will hit it again.

Earlier notes on this file blamed thread affinity, because the engine is initialised on the test
runner's pool thread and the fault surfaces on the main thread. That was wrong: the thread arrangement
is incidental. Linux does not show it because Odin's test runner leaves through `os.exit`, a direct
`exit_group` syscall - no DLL detach, no destructors, nothing runs.

### 1b. Odin's test runner cannot host a library that throws C++ exceptions

Separate from the above, same symptom. Sciter throws C++ exceptions in ordinary operation and catches
them itself - the justfile's ASan notes already record this. On Windows every C++ throw is an SEH
exception (code `0xE06D7363`), and `core/testing/signal_handler_windows.odin` registers a vectored
handler that stops the test on **any** exception code, with no filtering:

```odin
win32.AddVectoredExceptionHandler(0, stop_test_callback)   // stop_test_callback does not check `code`
```

So loading a document whose script will not parse kills the test that did it and every test after it in
the binary. Nothing on this side can prevent it: `testing.expect_signal` only whitelists SIGILL, SIGSEGV
and SIGFPE, and the handler cannot be removed without its registration handle.

It is worse than a failed test, because the binary then **hangs**: execution recovers from the benign
exception and the test runs to completion, while the runner has already been told to stop it and waits
for a test that never stops. That is what the `exit 124` entries in the summary are, and it is why
`EXAMPLE_TEST_TIMEOUT` is not optional on Windows.

**Diagnosed to a minimal reproduction, and fixed.** The reproduction needs no third-party library -
`OutputDebugStringW` raises `0x4001000A` by itself:

```odin
@(test)
on_the_test_thread :: proc(t: ^testing.T) {
	OutputDebugStringW(&MSG[0])          // runner hangs after this
}

@(test)
on_a_spawned_thread :: proc(t: ^testing.T) {
	th := thread.create_and_start(proc() { OutputDebugStringW(&MSG[0]) })
	thread.join(th); thread.destroy(th)  // fine: local_test_index_set is thread_local, and false there
}
```

That second test is the handler's own escape hatch - `if !local_test_index_set { return
EXCEPTION_CONTINUE_SEARCH }` - and it passing is what confirms the diagnosis rather than merely
suggesting it.

The fix is one early return in `stop_test_callback`, filtering to codes that actually mean "this thread
cannot continue". It is written up with the reproduction in
[`odin-test-runner-windows.patch`](./odin-test-runner-windows.patch), ready to submit upstream, and it
was applied and measured locally:

| | stock runner | patched runner |
| --- | --- | --- |
| `task_list` | hangs (`exit 124`) | **11/11 green** |
| `eval`, guards removed | hangs | **38/38 green** |
| deliberate null dereference | `Segmentation_Fault` | `Segmentation_Fault` - unchanged |

**The guards stay until the fix is in a released Odin**, because CI builds with the stock toolchain and
an unguarded run there does not reliably fail - it often hangs, for the whole 45-minute job timeout.
What is guarded, and why each one throws:

| Guard | What throws |
| --- | --- |
| `eval.odin`, three diagnostics tests as a group | each loads a document whose script will not parse |
| `eval.test_value_parse_reports_the_message` | **every** `value_parse` failure throws |
| `eval.test_value_parse_dialects`, failing half only | the `.JSON_MAP` whole-document case; the successes above it still run |
| `task_list.test_load_of_a_missing_or_broken_file` | parses deliberately broken JSON |

Each is a one-line `when` to remove. Finding them was iterative and the lesson is worth recording: a
guarded test stops masking the next one, so the list grew twice after the first fix looked complete.
**Do not assume the set is closed** - anything that makes the engine fail a parse is a candidate.

While the patch was applied it also settled section 1: with `TerminateProcess` taken out of the runner's
main-thread branch, the teardown access violation **still killed the process with `0xC0000005`**. So
nothing handles that one and it is a genuine unhandled fault in the engine, not a false positive of the
same kind.

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

### 3. Behavioural differences - characterized and closed

All of these were measured with a throwaway probe and the tests widened from the measurement. They are
recorded on the wrapper procedures as well as in the tests, because each is something an application
would get wrong.

- **Element UIDs round-trip on Windows and not on Linux.** `element_by_uid(element_uid(e))` returns
  exactly `e` here, for each of two elements, while an invented UID still fails - so the Linux build's
  `SciterGetElementByUID` is the broken one. Recorded on `element_by_uid` in `dom.odin`; the test is
  `test_element_uid_is_readable_and_resolvable_only_on_windows`.
- **`file:` URLs from `combine_url` have two slashes here and three on Linux.** This looked like a
  defect and is not: the wrapper is a straight `SciterCombineURL` pass-through, and the engine's
  canonical Windows `file:` form has no empty authority - a document loaded with either
  `file:///C:/tmp/dir/` or `file://C:/tmp/dir/` resolves `style.css` to `file://C:/tmp/dir/style.css`
  both times. `https:` is identical on both. The one inconsistency is on *both* platforms: a
  root-relative reference gives three slashes and drops the drive letter (`/abs.css` ->
  `file:///abs.css`). Recorded on `combine_url`.
- **`.View` and `.Root` are the same origin here and different on Linux** - `.Root` is the document root,
  `.View` is the window client area, and whether anything sits between them is a windowing-system
  question. `dom_walk.test_location_origins`.
- **The clipboard's text flavour is clean here and NUL-terminated on Linux.** The HTML flavour carries
  the CF_HTML wrapper and its NUL on both. `get_text`'s trim stays unconditional - it costs nothing
  where there is no NUL. `script_bridge.test_html_comes_back_wrapped_and_nul_terminated`.
- Two apparent differences turned out to be **collateral from an earlier crash in the same binary** and
  pass in isolation: `dom_walk.test_finalizing_a_removed_node_takes_it_out_of_the_document` and
  `eval.test_a_value_scope_releases_the_whole_batch`. Worth checking any new "difference" that way
  before investigating it.

### 4. Bugs the Windows run found that were not platform differences

Three of these had nothing to do with Windows except that Windows is where they became visible.

**`examples/inspector.odin` never enabled `.SOCKET_IO`, so the inspector could not attach - on any
platform.** The connection is a socket opened by the *document's* script runtime, and without that
permission the window is inspectable, the engine is listening, and the inspector sits on "Waiting for a
connection with Sciter's view" forever - which reads as one of the two documented halves being wrong.
The example now sets `{.FILE_IO, .SOCKET_IO, .EVAL, .SYSINFO}`, which is what the inspector's own start
screen asks for, and it attaches. Recorded on `set_debug_mode` in `app.odin`.

**`examples/sqlite_extension.odin` crashed on `sqlite3_open_v2`, and it was two bugs stacked.**

- It never called `sqlite3_initialize`. A SQLite built with `SQLITE_OMIT_AUTOINIT` does not initialise
  itself on first use and dereferences a null instead - measured as a bare access violation with no
  diagnostic. The identical sequence against the identical DLL succeeds with one `sqlite3_initialize()`
  in front of it. On a build that does auto-init the call is a reference-counted no-op.
- Loading `sqlite3.dll` by bare name lets the Windows loader pick whatever is first on `PATH`. On this
  machine that was `C:\Program Files\Amazon\AWSCLIV2\sqlite3.dll` (3.49.1), with Sublime Text's (3.49.2)
  and Zeal's (3.52.0) behind it - and the AWS one is the `OMIT_AUTOINIT` build. Which SQLite you get
  was a property of the machine's `PATH`. `winsqlite3.dll` ships with Windows and is now tried first.

**Two silent-skip bugs in the same file.** `test_script_can_load_the_library_and_query` gated on
`DISPLAY`/`WAYLAND_DISPLAY` directly instead of the `have_display` every other example uses, so it
skipped itself on Windows forever; and once that was fixed it looked for `odin-sqlite.so` with the
extension hardcoded, so it skipped again with a message that reads like the build step was forgotten.
`loadLibrary` takes the name *without* a suffix and appends the platform's own, which is exactly why
that mistake is easy to make and hard to see. Both fixed.

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

## Done as part of this bring-up

- `README.md`'s platform table: Windows is vendored and tested, with the two open items named
- `docs/PLAN.md`: the "what remains is Windows" paragraph, and the null-slot count
- `docs/deployment.md`'s status note, which said Windows was unverified

## Still to decide

Per `docs/UPGRADING.md`, the repository's history cost is now ~19 MB per engine bump rather than ~11,
so the row-10 hybrid (Linux committed, Windows on releases) has stopped being hypothetical.
