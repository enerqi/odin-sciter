# Changelog

Releases are named after the Sciter engine they pin, because that is the question anyone reading a tag
actually has. `v6.0.4.9` is the first release against engine 6.0.4.9; `v6.0.4.9-2` would be a second
release of the bindings against the same engine. No engine is committed here — the pin is a version and
a SHA-256 in [`external/sciter/VENDORED.md`](external/sciter/VENDORED.md), and `just fetch-engine`
installs against it. The policy and the upgrade procedure are in
[`docs/UPGRADING.md`](docs/UPGRADING.md).

**This file records what changed, and nothing else.** The engine behaviour and measurements behind
these entries are written where they apply and are not copied here: engine defects in
[`docs/UPSTREAM-DEFECTS.md`](docs/UPSTREAM-DEFECTS.md), traps in
[`docs/gotchas.md`](docs/gotchas.md), the cross-cutting contracts in [`docs/rules.md`](docs/rules.md),
per-procedure facts on the wrappers themselves, and the review that found most of the fixes below in
[`docs/review/`](docs/review/). Headings follow [Keep a Changelog](https://keepachangelog.com/).

## Unreleased

Nothing has shipped yet: v6.0.4.9 is written up ready to tag and this section is what has landed on top
of it since. Fixes and hardening from a whole-repository review, [`docs/review/`](docs/review/).

### Breaking

- **Temp memory allocated inside a callback no longer outlives that callback.** Every callback that runs
  your code — event handlers, host notifications, native functors, SOM getters/setters/methods, paint
  procs, `value_each` visitors, element comparators — now unwinds `context.temp_allocator` to the mark it
  had when the engine called in, which is what gives an application driven by `run` a temp boundary at
  all (see Added). Anything a callback keeps has to be cloned or allocated from something that outlives
  it. This was always the contract; with nothing ever calling `free_all` it had no symptom, and it has
  one now. Three example files were relying on it and are fixed.
- **`init` installs the default debug output** unless you pass `debug_output = false`. Programs that
  installed their own handler *after* `init` are unaffected — `set_debug_output` still replaces it.
  Programs relying on the engine's `OutputDebugStringW` fallback will now see diagnostics on stderr
  instead.
- **`make_element`, `clone_element`, `use_element` and `remove_element(finalize = false)` return an
  `Owned_Element`**, and `unuse_element` accepts only that — releasing a handle you never held no longer
  compiles. `borrow_element(owned)` is the free cast. Affects code that creates, clones, holds or
  removes elements.
- **`take_request` and `use_request` return an `Owned_Request`**, same split, same reason;
  `borrow_request(owned)` is the cast and `use_request` also returns the handle it took.
- **`make_text_node`, `make_comment_node` and `node_add_ref` return an `Owned_Node`**; `node_release`
  and `node_insert`'s `what` take only that, and `node_add_ref` gains a result.
- **`Event_Phase` loses its `.Handled` variant.** HANDLED is an independent bit, not a third phase, and
  folding it in made `if ev.phase == .Bubbling` stop firing once anything claimed the event. All seven
  typed event parameter structs gain `handled: bool`; `event_handled(cmd)` reads the bit.
- **`event_code`, `event_phase`, `event_handled` and `mouse_code` take an `Event_Cmd`**, not a bare
  `u32`, so `event_phase(event_code(cmd))` no longer compiles. Affects sites decoding a raw `cmd`.
- **`set_timer` and `stop_timer` take a `Timer_Id`** and `Timer_Event.id` is one. Untyped constants are
  unaffected; only a stored id needs the type.
- **`insert_element`'s index is `Maybe(Child_Index)`** — "append" is `nil`, not `-1`. Affects callers
  passing `-1` explicitly.
- **`window_state` returns `(state, ok)`.** A destroyed window answers `0xFFFFFFFE`, which is not a
  member of `SCITER_WINDOW_STATE`.
- **`Api_Error` gains `Option_Failed`, `Archive_Failed` and `Too_Many_Members`.** Affects code matching
  on `Load_Failed` or `Wrong_Type`, which those paths used to borrow.
- **Every commit SHA changed.** The engine binaries were removed from history (see Changed); re-clone
  rather than pull.

### Added

- **A temp-allocator boundary at every callback**, in `callback_temp_scope`. `run` is the engine's own
  loop and never returns to application code, so an application whose handlers do DOM work had nowhere to
  put `free_all` and the arena grew for the life of the process. It is a watermark rather than a
  `free_all`, because the engine dispatches handlers synchronously from inside this package's own calls
  and freeing the arena there would take the argument buffer of the call still on the stack. Measured:
  64 deliveries allocating 64 KB each grow the arena by 8 MB without it and by nothing with it
  (`examples/events.odin`).
- **`examples/app_skeleton.odin`** — the step between `getting-started.md`'s five calls and
  `task_list`'s thousand lines: a model, one render, one handler and the four rules a first program gets
  wrong, in about 200 lines meant to be copied and cut down. Five tests, two of which fail if the escape
  or the clone is removed.
- **`close_secondary(window)`** — hide, pump, close, pump: the one teardown order for a secondary window
  that does not segfault, as one call. The five-row measurement stays on `close`.
- **`just fetch-engine` / `just ensure-engine`** — the engine is downloaded and hash-verified rather
  than vendored, from three sources in order so a withdrawn upstream tag cannot strand a past commit.
  [`docs/UPGRADING.md`](docs/UPGRADING.md).
- **[`docs/rules.md`](docs/rules.md)** — the four cross-cutting contracts (thread affinity, `Value`
  ownership, handle lifetime, allocator conventions) in one place, and
  **[`docs/threading.md`](docs/threading.md)**, the guide rule 1 needed.
  **[`docs/README.md`](docs/README.md)** indexes the lot in reading order.
- **`sciter_app/affinity.odin`** — rule 1 is now checked in debug builds, not just written down: the
  wrapper arms on first use and traps on a later call from another thread. The whole example suite
  passes with it armed and strict.
- **`create_window` traps in a debug build when `init` has not run.** Measured on Windows: without
  `init` the window opens, the document loads, the DOM answers and the teardown succeeds — and the
  process segfaults on the way out of `main`, exit 139, with nothing on the stack naming the omission.
  The guard fires where the call still is. `docs/getting-started.md` said this crashed at window
  creation, which it does not.
- **[`docs/using-in-your-project.md`](docs/using-in-your-project.md)** — the case every other page
  assumed away: your program, this repository as a dependency. What to vendor (the minimum that
  compiles is `sciter.odin` plus `sciter_app/`, measured at 560 KB), why it is the repository root and
  not `sciter_app/` alone, the `-collection:` flag with both import spellings — `sciter:.` for the raw
  bindings, since the bare `sciter:` is a syntax error — and how the engine reaches your users. All of
  it built and run from outside the tree.
- **`just check-api-coverage`** in CI, and the 62 procedures it found missing from
  [`docs/api.md`](docs/api.md). The reference is organised one section per source file and **three files
  had no section at all** — `scoped.odin`, `value_scope.odin` and `tracking.odin`, which is the whole
  leak-prevention surface and the whole debug ledger, the two APIs `rules.md` sends a reader to look up.
  340 of 402 procedures were named; it is 402 of 402 now, with the wildcards that used to stand in for
  families (`retain_*`, "the four `set_*_gradient_*`", "the `value_to_*` inverses") spelled out, because
  a reader cannot search for a wildcard and no check can see one.
- **`just check-doc-ownership`** in CI — the listings inside `//` doc comments are the one kind of Odin
  here that nothing compiles, and three of them passed an `Owned_Element` where a borrowed `Element`
  was wanted. The check reads both the producers and the borrow-takers out of `sciter_app/*.odin`, so
  it extends itself, and `--self-test` runs it against the listing that was wrong.
- **`sciter_app/tracking.odin`** and **`just leak-check`** in CI — a debug ledger for the resources that
  live *inside* the engine, which `mem.Tracking_Allocator` cannot see, plus the sweep that fails the
  build when any are still held at exit.
- **`sciter_app/scoped.odin`** and **`sciter_app/value_scope.odin`** — a `scoped_` twin of every `Value`
  producer, and a `Value_Scope` for a batch of references with one lifetime.
- **The macOS engine is pinned and CI is the Mac** — nobody here owns one, so the `macos-14` job runs
  verification, `check`, a window canary, the example suite and the leak sweep.
  [`docs/MACOS-CHECKLIST.md`](docs/MACOS-CHECKLIST.md).
- **New gates in CI**: `just parity --check` (C-API slot coverage against
  [`docs/parity-baseline.txt`](docs/parity-baseline.txt)), `just check-ownership` (allocator ⇒ owned),
  `just check-affinity` (every engine call goes through `engine()`, so the runtime thread guard can
  see it — the gap it closes is described under Fixed), `just check-invariants` (a `Value` or an owned
  handle handed back is recorded in the debug ledger, and every `proc "system"` restores a context —
  three invariants that were true and that nothing was keeping true), `just stats --check` (the counts
  the docs quote), and `just lint` over both packages and all examples. `just example-tests` bisects a test that kills the process, which used to report `exit 134`
  against a file and name nothing.
- **`just windowed-examples`** — every example that opens a window, run as a *program* rather than as a
  test, with the canaries' contract: exit 124 means the timeout fired, so the window was still up. On
  macOS this is the only way those examples run at all, because AppKit will not make an `NSWindow` on
  the test runner's pool thread and fourteen of them skip themselves. It runs on all three platforms in
  CI so a macOS-only failure can be told apart from a broken example. The windowed set is derived from
  the source, not listed, so a new one is covered the day it is written.
- **`just example-tests` counts the skips.** "384 of 396 test procedures ran, in 22 of 24 example files;
  5 of the 384 skipped themselves." A skip is a pass in the runner's accounting, so a total on its own
  overstates a platform that skips a lot — which is macOS. This replaces a paragraph in
  [`docs/MACOS-CHECKLIST.md`](docs/MACOS-CHECKLIST.md) asking the reader to remember that.
- **The thread guard checks the *main* thread on macOS**, not just a consistent one:
  `check_thread_affinity(main_thread = …)`, on by default on Darwin. AppKit aborts the process if the
  engine's singleton is built anywhere but the main thread, and rule 1 on its own permits a consistent
  worker — which passes every check here and then dies in Apple's code. No platform API involved:
  `@(init)` runs on the first thread, so recording its id there is the whole implementation. **Off in a
  test binary** (`&& !ODIN_TEST`): Odin's runner keeps the main thread for its own loop and submits every
  test to a pool, so no macOS test binary can satisfy the rule — a default no test can satisfy is a
  broken build rather than a strict check, which is what one CI run said.
- **Eleven examples test against a windowless view instead of a window**, which is what makes them run
  on macOS: a test there can never own an `NSWindow`, and almost none of these tests wanted a window —
  they wanted a laid-out document. The macOS suite was reporting ~389 passing while exercising **165**.
  Tests that genuinely need a window keep one, with the skip that implies: `behavior`'s window metrics,
  `dom_walk`'s 23 window-state tests, `workbench`, `request_loader`, `worker_thread`.
  Three things came out of doing it, all now in `docs/gotchas.md` §11: **a windowless view and a
  windowed application do not share a process**; a windowless view has no pump, so anything
  asynchronous finishes only while you beat it; and **`run_once`/`heartbeat` abort the process on macOS
  off the main thread**, so a test drives the view and never the application.
- **`.View` and `.Root` are the same origin on a windowless view**, on every platform — the surface *is*
  the client area, so nothing sits between them. Windowed they agree on Windows and differ on Linux,
  which is what `dom_walk`'s `test_location_origins` used to assert.
- **Every exported wrapper procedure is now reached by a test.**
- `released_resources()`, `app_event(n)`, and twelve further `scoped_` constructors.

### Changed

- **The examples reach for the `scoped_` twins where the Value is a local read** — 104 sites across 12
  files, each of them a producer immediately followed by `defer value_clear`. The behaviour is the same
  and the release is now the language's job rather than the reader's; it also covers the early-return
  paths between the producer and the `defer`, which leaked. What deliberately stays manual: `eval.odin`,
  where Value ownership is the subject being taught; `leak_sweep.odin`, which exercises the release paths
  on purpose; every producer that hands a Value *out* to its caller; and the `value_from` scalars, which
  have no scoped twin (see Known issues).
- **No engine is committed on any platform, and history was rewritten to remove the three that were** —
  `.git` 41 MB → ~2 MB. A binary does not delta-compress, so committing all three cost ~40 MB of
  permanent history per engine bump in a repository whose source is under 2 MB. `ensure-engine` fetches
  on the first build, so nothing in the build needed changing.
  [`docs/UPGRADING.md`](docs/UPGRADING.md) has the arithmetic, the runbook and why not Git LFS.
- **Both "is the engine vendored?" CI gates are gone** with the binaries they guarded; the hash-checked
  fetch is the gate now, and it names a mismatch instead of skipping the run and reporting green.
- **CI builds the SQLite native extension before the suite**, so `SciterLibraryInit` has coverage — its
  test had silently skipped itself since it was written.
- **`Attribute_Change` gains `removed: bool`**, distinguishing a removed attribute from an emptied one.
- **`just cross-check` covers `darwin_arm64`**, the architecture CI's macOS runner actually builds on.
- **Windowed tests skip themselves on macOS and the skip messages stopped lying** — they used to name
  `DISPLAY`/`WAYLAND_DISPLAY` on platforms where neither exists.
- **`load_engine`'s failure message is written for the reader's platform**, and for a program outside
  this repository, which is where it is actually read. It used to print
  `SCITER_LIB=/path/to/sdk/bin/linux/x64 just example hello_window` on all three platforms — a Linux
  path, a shell idiom that does nothing in cmd or PowerShell, and a recipe from a checkout the reader
  does not have — and never mentioned the answer a shipped application wants, which is the library
  beside the executable and already the first candidate it prints.
- **`docs/getting-started.md` names `uv` as a prerequisite**, which it always was: the first command on
  the page fetches the engine, and every Python step runs through uv. It and the README now also name
  the toolchain versions CI builds with (`odin dev-2026-08`, `just 1.55.1`) instead of "a recent
  nightly", and point at the one file the pin lives in.
- **The README's example table marks what is not `just example NAME`** — `extension` is a shared
  library, `leak_sweep` is a gate, and `integration` and `native_child` are Linux/X11 only and do not
  build elsewhere, which the table implied they did.
- **`docs/PLAN-TESTING-AND-EXAMPLES.md` is the house rules and nothing else.** The worklist it was named
  for — close the coverage gap, build a larger example — is finished, so its batches, its proposal and
  its ticked acceptance boxes are in the history and the conventions that outlived them are not.
- **`just --list` stopped showing fragments.** `example-test` and `leak-check` had their one-line
  description written *above* a following paragraph, and just shows the last comment line; the three
  `[windows]` recipe variants that carried no comment of their own listed blank on Windows.

### Fixed

Twenty-odd correctness fixes from the review, the sharpest of them memory-safety: `asset_get` reading a
`som_property_def_t` union without its tag (a constant's value called as a function pointer),
`resize_windowless` leaving `view.pixels` dangling on a refused resize, `string_from_utf16` returning a
3×-oversized slice that made every `delete` a wrong-size free, `load_embedded` reusing a cached engine
on a size match alone, `sort_children` clamping one end of its range, `combine_url` truncating silently,
and `sqlite_extension` freeing memory nothing had allocated — undefined behaviour on all three
platforms, fatal only on macOS. Each is listed with the wrapper it lives on in
[`docs/review/README.md`](docs/review/README.md).

A later pass fixed four more: `examples/hello_window.odin` and `examples/api_map.odin` leaked the
candidate list `sciter.load` returns on every path — the exact mistake `docs/rules.md` §4 warns about,
demonstrated by the two files a newcomer reads first; `value_make_array(0)` dropped the error Value
`value_parse` hands back on failure; an unbalanced `restore_state` trapped the resource ledger with a
message about a segfault that does not happen for graphics state, contradicting `restore_state`'s own
measured documentation, and is now counted and reported instead; and three listings passed an
`Owned_Element` to a borrowed parameter (`sciter_app/dom.odin`, `sciter_app/scoped.odin`,
`docs/dom.md`, whose compiled twin in `snippets.odin` was right all along).

Two documentation claims about the repository itself were left behind by the un-vendoring:
`docs/deployment.md`'s status block still said Linux and Windows were vendored and only macOS fetched —
in the guide where a wrong claim about what ships costs money — and the README's layout table described
`lib/` as "the engine binaries" four hundred lines after saying no engine is in the tree. `lib/` is the
git-ignored destination `just fetch-engine` writes to.

A second group corrected documentation that was **wrong**, which is the more dangerous kind: `eval`
never reports a script error through its `Error` (the returned Value carries it), over-releasing a
borrowed handle is a segfault rather than a leak, inserting a node does not take your reference, and
answering a `.DELAYED` request twice dies inside the engine. All are now recorded on the procedures
concerned and in [`docs/UPSTREAM-DEFECTS.md`](docs/UPSTREAM-DEFECTS.md).

- **The thread-affinity guard watches every engine call, not 62% of them.** It sat in the four
  error-wrapping helpers and the two sub-table accessors, so it only saw a call that returned a result
  code: 124 of 199 call sites, with `eval`, `call`, `load_html`, `create_window`, every `Value`
  constructor and the whole windowless surface unwatched. Fifty `value_from_string` calls from a worker
  thread reported zero violations. The check moved into `engine()`, the package's single route to the
  engine's function table, so it now runs *before* the call rather than after it. `post_callback` keeps
  the bare `sciter.api()`, being rule 1's one exception.
- **The guard no longer blames the wrong thread.** `init` was among the unguarded calls, so the armed
  thread was whichever thread first reached a *guarded* one — a worker could arm itself as the engine's
  thread, take no violation for doing so, and the engine's real thread would then trap on its next
  legitimate call. Measured, then fixed by the same change.
- **`check_thread_affinity`'s `on` and `strict` are read and written atomically**, like `id` and
  `violations` already were, instead of through a whole-struct assignment racing the guard's reads.

- **The macOS test bootstrap re-arms the guard**, and the reason is a finding of its own: the completed
  check went red on macOS CI on its first run, because `darwin_main_thread_bootstrap` builds the
  engine's AppKit singleton on the **main** thread — which AppKit requires — while Odin's runner runs
  every test on a pool worker. That two-thread split is real, has been there since the bootstrap was
  written, and was invisible while `init` went unguarded. The bootstrap now ends with
  `sciter_app.check_thread_affinity()`: the armed thread is forgotten, the check stays on and strict,
  and the first test call arms the worker. What is exempted is the main-to-worker handover the platform
  forces, and nothing else. [`docs/MACOS-CHECKLIST.md`](docs/MACOS-CHECKLIST.md) section 2.

The findings, the measurements behind them and the two still open are in
[`docs/review/10-threading.md`](docs/review/10-threading.md).

- **`just stats` counted one test that does not exist.** It counted the string `@(test)`, and
  `examples/eval.odin`'s header says "the `@(test)` procs at the bottom exercise the conversions" — so
  prose about tests was a test. It now requires a declaration to follow the marker, and steps over any
  attributes stacked in between, which the old pattern in `example-tests` would have dropped instead:
  a test nothing counts is a test the failure-bisect never re-runs. 397 → 396, and `docs/PLAN.md` with
  it.
- **`value_to_graphics`, `value_to_image`, `value_to_path` and `value_to_text` say what they hand
  back.** They had no doc comment at all, in the one family where the signature cannot answer the
  question — those four types are the same ones the *owning* `value_from_*` family returns. Measured:
  the unwrap gives back the identical handle and takes no reference of its own, so it is **borrowed**
  and dies with the Value; the wrap does take one, which is what the ledger records. Also measured and
  now written on `image_size`: a released image answers `0x0` with a `nil` error rather than failing.
  [`docs/review/11-partial-enforcement.md`](docs/review/11-partial-enforcement.md).

### Removed

- **`spike/` is gone** — `skeleton`, `windowless` and `smoke`, 752 lines of scratch programs from before
  the bindings existed. Nothing compiled them, so they were the only Odin in the tree that could stop
  building unnoticed, and what they demonstrated is covered by `examples/hello_window.odin`,
  `examples/api_map.odin` and `examples/windowless.odin`. They are in the history.
  [`docs/review/07-build-ci.md`](docs/review/07-build-ci.md) R7-07. The rule left behind: Odin in this
  tree is either compiled or deleted.
- `spike/xdnd/xdnd_source.py` moved to [`tools/xdnd_source.py`](tools/xdnd_source.py) — a live test
  harness rather than scratch work, and the only way to stage a real system drop.
- **`docs/FLEURY-UI.md` is gone** — 174 lines summarising a third-party blog series, most of it behind
  a paywall, and nothing in it about these bindings. The free parts' architecture is now a section of
  [`docs/ALTERNATIVES.md`](docs/ALTERNATIVES.md), where the comparison belongs; `docs/VDOM.md` points
  there. `docs/` is 29 documents besides its index.

### Known issues

- **`value_from`'s four scalar members have no `scoped_` twin.** `scoped_value_from_string` and
  `scoped_value_from_bytes` exist; `value_from_bool`, `value_from_int`, `value_from_i64` and
  `value_from_f64` do not, so ~32 sites in the examples still write `defer value_clear` for a Value that
  holds a number. Nothing is wrong with them - it is a gap in the scoped surface, not a leak.

- The timer tests in `examples/events.odin` flake under load.
- Engine defects are tracked in [`docs/UPSTREAM-DEFECTS.md`](docs/UPSTREAM-DEFECTS.md).

## v6.0.4.9 — the first release, unreleased

Odin bindings for [Sciter.JS](https://sciter.com/) 6.0.4.9, `SCITER_API_VERSION` 10, pinned to
[gitlab.com/sciter-engine/sciter-js-sdk](https://gitlab.com/sciter-engine/sciter-js-sdk) tag
`6.0.4.9-bis`. What the release contains, in brief — [`README.md`](README.md) is the tour and
[`docs/README.md`](docs/README.md) the index.

- **`package sciter`** — generated from the vendored headers by
  [odin-c-bindgen](https://github.com/karl-zylinski/odin-c-bindgen), 1-to-1 with the C API so
  sciter.com's documentation reads across. All 189 `ISciterAPI` slots, verified against the shipped
  engine. Idiomatic types are applied declaratively, so they survive regeneration.
- **`package sciter_app`** — hand-written and Odin-shaped: `string` in and out, an `Error` union
  carrying the engine's own result codes, ownership stated rather than implied. Application lifecycle,
  windows, `Value`, the DOM, events, graphics, the host resource callback and the request API behind it,
  archives, engine options, SOM, video, and windowless views.
- **The library is opened at runtime** — there is no static linking without a commercial licence — with
  a five-step search order and a failure that reports every candidate it tried. The `ISciterAPI` version
  is checked at load. `sciter.adopt()` takes a table the host already has, which is what a native
  extension needs.
- **Windowless views**, on CPU and GPU: the document renders into a buffer the host allocated, at the
  host's own stride, or through Sciter's Skia pipeline into the host's OpenGL framebuffer.
  [`docs/EMBEDDING.md`](docs/EMBEDDING.md).
- **SOM** — an Odin object exposed to script with properties and methods, and the other direction:
  reading an asset the engine owns, such as a behavior's native interface.
- **Video** — the one area outside `ISciterAPI`. `sciter::video_destination` is a C++ class of pure
  virtuals with no C declaration, so its vtable is laid out by hand and verified against the engine's
  own symbol.
- **Behavior methods and synthesised input** — `do_click` produces a real click where `send_event` only
  injects a code; `send_mouse` / `send_key` / `send_text` drive the intrinsic behaviors the way the
  window system's own input does.
- **`on_attach_behavior`** answers a `behavior:` name the document asked for, so a *stylesheet* rather
  than a call site decides which elements get native code.
- **`post_callback`** is the one call safe from another thread, and the rest of the notification family
  is wrapped alongside it.
- **Examples**, each a single self-contained file with its explanation in the header comment, and tests
  living beside the code they cover — the counts are in [`README.md`](README.md), gated by
  `just stats --check`. `api_map` is the one to run after any engine change: it walks every slot and
  resolves each pointer back to the symbol and module it belongs to.
- **CI** runs slot verification, the full build, the suite under Xvfb, ASan on the `Value` refcounting
  path, and byte-identical regeneration against a commit-pinned generator — which is what lets
  `sciter.odin` be treated as a build artifact that happens to be committed.
- **Platforms**: Linux x64 and Windows x64 tested, macOS tested in CI. See
  [`README.md`](README.md#finding-the-engine) for what CI can and cannot prove.
</content>
