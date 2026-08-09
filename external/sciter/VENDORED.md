# Vendored Sciter SDK files

## What is here

| Path | Contents |
| --- | --- |
| `external/sciter/include/` | The SDK's C/C++ headers, unmodified |
| `lib/linux/x64/libsciter.so` | The Linux x64 engine |

## Version

| | |
| --- | --- |
| Upstream | <https://gitlab.com/sciter-engine/sciter-js-sdk> |
| Tag | `6.0.4.9-bis` |
| Commit | `561185714dcd7f18f0db57b494d083437da8123f` (2026-08-02) |
| Engine version | 6.0.4.9 (as reported by `SciterVersion(0..3)`) |
| `SCITER_API_VERSION` | 10 |

Verified against the shipped library rather than assumed - `just example api_map` walks all 189
`ISciterAPI` slots and resolves each function pointer back to its symbol name.

> **Use GitLab, not GitHub.** The `c-smile/sciter-js-sdk` mirror on GitHub is abandoned: its last commit
> is 2022-04-19, engine 4.4.8.33, `SCITER_API_VERSION` 9. Its headers and binaries are also internally
> inconsistent - `sciter-x-api.h` there declares `SciterExec` and `SciterWindowExec` at the end of
> `ISciterAPI`, but the `libsciter-gtk.so` committed beside it implements neither, so calling them
> reads past the end of the engine's real table and jumps into unrelated code.
>
> `git clone` of the GitLab repository pulls ~4 GB, because all 800+ commits carry platform binaries.
> Use `git clone --depth 1`, or the release archive:
> `https://gitlab.com/sciter-engine/sciter-js-sdk/-/archive/6.0.4.9/sciter-js-sdk-6.0.4.9.zip`

## What was left out

Only what the bindings need is vendored. Everything else stays upstream:

- `bin/` for platforms other than Linux x64 - Windows (`windows/`, `windows.d2d/`, `windows.xp/`),
  macOS, Android, and the 32-bit and ARM Linux builds
- the SDK tools: `packfolder`, `inspector`, `scapp`, `usciter`, `tsciter`, `lite-sciter-sdl`,
  `sciter-sqlite.so`
- `demos/`, `samples*/`, `widgets/`, `quark/`, `sciter+/`, `sciter-webview/`, `docs/`
- `include/behaviors/` and `include/gles/` - C++ sample behaviours and GLES shims, not part of the C ABI
- `include/*.hpp` and `include/sciter-main.cpp` - the C++ convenience layer. Deliberately not vendored:
  these bindings target the C ABI, and `sciter-x-window.hpp` is only worth reading, not shipping (it is
  the authority on the correct start-up sequence, and how `SCITER_APP_INIT` really wants UTF-16 argv).

## Licensing

Two licences apply, and they are not the same:

- **`LICENSE` (BSD 3-Clause)** covers the SDK repository's contents - the headers here, the samples, the
  documentation.
- **`SCITER-ENGINE-EULA.md`** covers the engine binary itself (`sciter.dll` / `libsciter.so` /
  `libsciter.dylib`). It is *not* BSD. Terra Informatica retains copyright, and grants free use in
  commercial and non-commercial applications, with one requirement:
  > Your application shall include link to Terra Informatica site in "About" dialog or similar place in
  > your application. Text of the link: This Application (or Component) uses Sciter Engine
  > (http://sciter.com/), copyright Terra Informatica Software, Inc.

So redistributing `libsciter.so` inside this repository is exactly what the EULA contemplates, but
anything shipping these bindings owes that attribution line. Access to the *engine sources*, and the
right to link statically, remain the paid tiers at <https://sciter.com/prices/>.

Both licence files are copied next to this one as `LICENSE` and `SCITER-ENGINE-EULA.md`.
