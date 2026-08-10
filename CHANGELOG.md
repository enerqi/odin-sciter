# Changelog

Releases are named after the Sciter engine they vendor, because that is the question anyone reading a
tag actually has. `v6.0.4.9` is the first release against engine 6.0.4.9; `v6.0.4.9-2` would be a
second release of the bindings against the same engine. The policy, and the upgrade procedure behind
it, are in [`docs/UPGRADING.md`](docs/UPGRADING.md).

## Unreleased — v6.0.4.9

First release. Odin bindings for [Sciter.JS](https://sciter.com/) 6.0.4.9, `SCITER_API_VERSION` 10,
vendored from [gitlab.com/sciter-engine/sciter-js-sdk](https://gitlab.com/sciter-engine/sciter-js-sdk)
tag `6.0.4.9-bis`.

### Packages

- **`package sciter`** — generated from the vendored headers by
  [odin-c-bindgen](https://github.com/karl-zylinski/odin-c-bindgen), 1-to-1 with the C API so that
  sciter.com's documentation reads across directly. All 189 `ISciterAPI` slots, verified against the
  shipped engine. Idiomatic types applied declaratively so they survive regeneration: `bit_set`s for
  the flag enums, real enums for parameters the headers type as `UINT`, and `Scdom_Result` on all 101
  DOM slots.
- **`package sciter_app`** — hand-written, Odin-shaped: `string` in and out, an `Error` union that
  carries the engine's own result codes, and ownership rules stated rather than hidden. Covers the
  application lifecycle, windows, `Value`, the DOM (elements and nodes), events, the host resource
  callback, archives, engine options, and embedding the engine itself.

### Loading

- The library is opened at runtime — there is no static linking without a commercial licence — with an
  explicit five-step search order and a failure that reports every candidate it tried.
- The `ISciterAPI` version is checked at load and a mismatch is refused, because a mismatched table
  means every call lands in a different function than intended.
- `sciter.adopt()` takes a table the host already has, which is what a native extension needs.

### Examples

Twelve, each a single self-contained file with its explanation in the header comment: `hello_window`,
`api_map`, `load_file`, `eval`, `call_odin_from_js`, `dom_walk`, `events`, `custom_loader`, `archive`,
`single_binary`, `inspector`, and `extension` (Odin as a native extension the engine loads).

`api_map` is the one to run after any engine change: it walks every slot and resolves each pointer back
to the symbol and module it belongs to — `dladdr` on Linux and macOS, dbghelp plus `VirtualQuery` on
Windows.

### Tests

21 `@(test)` procs living beside the code they cover. The headless ones — `Value` round-trips and
refcounting, native functors, UTF-16 conversion, archive lookup, and the host callback's serve /
discard / not-ours decision — run anywhere. The windowed ones skip themselves without a display.

### Documentation

Nine guides in `docs/`, plus `PLAN.md` (findings and decisions), `RESEARCH-METHOD.md` (how each was
established), `UPGRADING.md` (version policy, upgrade procedure, repository-size budget) and
`WINDOWS-CHECKLIST.md`. Every Odin code block in the guides also lives in `docs/snippets/` and is type
checked by `just check`.

### Platforms

| | Vendored | Tested |
| --- | --- | --- |
| Linux x64 | yes | yes |
| Windows x64 | no | no — type checks for `windows_amd64`; see `docs/WINDOWS-CHECKLIST.md` |
| macOS | no | no |

### Known issues

- **X11 input-method segfault.** This machine's engine build crashes in `XSetICFocus` shortly after a
  window takes focus — 3 runs out of 3. `XMODIFIERS=@im=none` avoids it, 0 out of 3. The fault is
  inside the vendored engine binary, not the bindings.
- **`SciterGetViewExpando` is NULL on every platform** in Sciter 6, so `set_global` evaluates a
  one-line assignment function instead of writing into `globalThis` directly.
- Graphics, the request API, scroll and layout queries, element timers and drag-and-drop have no
  wrapper yet, and are reached through `sciter.api()`.
