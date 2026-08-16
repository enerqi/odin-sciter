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
  `just stats --check` (the counts the docs quote), and `just lint` over both packages and all
  examples. `just example-tests` bisects a test that kills the process, which used to report `exit 134`
  against a file and name nothing.
- **Every exported wrapper procedure is now reached by a test.**
- `released_resources()`, `app_event(n)`, and twelve further `scoped_` constructors.

### Changed

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

### Fixed

Twenty-odd correctness fixes from the review, the sharpest of them memory-safety: `asset_get` reading a
`som_property_def_t` union without its tag (a constant's value called as a function pointer),
`resize_windowless` leaving `view.pixels` dangling on a refused resize, `string_from_utf16` returning a
3×-oversized slice that made every `delete` a wrong-size free, `load_embedded` reusing a cached engine
on a size match alone, `sort_children` clamping one end of its range, `combine_url` truncating silently,
and `sqlite_extension` freeing memory nothing had allocated — undefined behaviour on all three
platforms, fatal only on macOS. Each is listed with the wrapper it lives on in
[`docs/review/README.md`](docs/review/README.md).

A second group corrected documentation that was **wrong**, which is the more dangerous kind: `eval`
never reports a script error through its `Error` (the returned Value carries it), over-releasing a
borrowed handle is a segfault rather than a leak, inserting a node does not take your reference, and
answering a `.DELAYED` request twice dies inside the engine. All are now recorded on the procedures
concerned and in [`docs/UPSTREAM-DEFECTS.md`](docs/UPSTREAM-DEFECTS.md).

### Removed

- **`spike/` is gone** — `skeleton`, `windowless` and `smoke`, 752 lines of scratch programs from before
  the bindings existed. Nothing compiled them, so they were the only Odin in the tree that could stop
  building unnoticed, and what they demonstrated is covered by `examples/hello_window.odin`,
  `examples/api_map.odin` and `examples/windowless.odin`. They are in the history.
  [`docs/review/07-build-ci.md`](docs/review/07-build-ci.md) R7-07. The rule left behind: Odin in this
  tree is either compiled or deleted.
- `spike/xdnd/xdnd_source.py` moved to [`tools/xdnd_source.py`](tools/xdnd_source.py) — a live test
  harness rather than scratch work, and the only way to stage a real system drop.

### Known issues

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
