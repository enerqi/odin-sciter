# Vendored Sciter SDK files

## What is here

| Path | Contents |
| --- | --- |
| `external/sciter/include/` | The SDK's C/C++ headers, unmodified |
| `lib/linux/x64/libsciter.so` | The Linux x64 engine - **fetched, not committed** |
| `lib/windows/x64/sciter.dll` | The Windows x64 engine - **fetched, not committed** |
| `lib/macosx/libsciter.dylib` | The macOS engine - **fetched, not committed**; one universal file |

**Only the headers are actually in this repository.** All three engines are gitignored and installed by
`just fetch-engine`, verified against the hashes below; `ensure-engine` runs before every recipe that
builds or runs anything, so a checkout needs no step a reader has to remember. The three are 90 MB
between them, a binary does not delta-compress, and every engine bump would therefore have added ~40 MB
to history permanently - see [`docs/UPGRADING.md`](../../docs/UPGRADING.md) for the arithmetic, the
history rewrite that removed the copies already committed, and why not git-lfs.

Nothing about the pin changes: it was always on the *file* rather than on the tag, and the hash table
below is what the fetch verifies against.

## Version

| | |
| --- | --- |
| Upstream | <https://gitlab.com/sciter-engine/sciter-js-sdk> |
| Tag | `6.0.4.9-bis` |
| Commit | `561185714dcd7f18f0db57b494d083437da8123f` (2026-08-02) |
| Engine version | 6.0.4.9 (as reported by `SciterVersion(0..3)`) |
| `SCITER_API_VERSION` | 10 |
| Mirror release | [`engine-6.0.4.9-bis`](https://github.com/enerqi/odin-sciter/releases/tag/engine-6.0.4.9-bis) - these three binaries, republished here so upstream cannot take them away |

Which bindings tags speak to which engine is a separate table, in
[`docs/UPGRADING.md`](../../docs/UPGRADING.md#which-engine-each-release-speaks-to) - several of the
former can share one of the latter.

Verified against the shipped library rather than assumed - `just example api_map` walks all 189
`ISciterAPI` slots and resolves each function pointer back to its symbol name.

### Binaries

All three are fetched rather than committed, so this table *is* the engine as far as this repository is
concerned - it is the only record of which bytes these bindings were verified against.

| File | Size | SHA-256 |
| --- | --- | --- |
| `lib/linux/x64/libsciter.so` | 25 015 296 | `b2e4a33682dcb7f2a63a76707e5d47faa9cb1440d986bf08fdc23ecd3964968b` |
| `lib/windows/x64/sciter.dll` | 19 261 952 | `b49ff94759951c4dd87f18a0edac466adb48a352bdecadbd6d5568f5e2203083` |
| `lib/macosx/libsciter.dylib` | 50 029 168 | `a7b65f37b265a0bacf7c127b8e45e8c0f66a16e3e1071b877b19ca333af1c25c` |

The Windows entry is the plain `bin/windows/x64/` build, **not** `bin/windows.d2d/` (a Direct2D variant)
or `bin/windows.xp/`.

### What the macOS file is

It is the largest of the three and the only one that is two engines, so it is worth being precise about
what was pinned. Everything here was read out of the Mach-O headers, not assumed:

| | |
| --- | --- |
| Format | universal (`FAT_MAGIC`), 2 slices: x86_64 at +16 384 (25 462 016 bytes), arm64 at +25 493 504 (24 535 664 bytes) |
| Minimum OS | macOS 11.5, built against the 26.5 SDK - both slices |
| Install name | `/usr/local/lib/libsciter.dylib` - an absolute path, **not** `@rpath/...` |
| Code signature | present on both slices, **ad-hoc**: `CodeDirectory` flags `0x2`, empty CMS blob, identifier `libsciter-55554944b7c9594f88483d738faed48ff1997311` |
| Dependencies | system frameworks only - AppKit, Cocoa, Carbon, Foundation, CoreGraphics, QuartzCore, Metal, OpenGL, AVFoundation, CoreText, IOSurface, `libc++`, `libobjc`, `libSystem`. Nothing third-party |

Three of those have consequences:

- **Ad-hoc signed is enough to load, and not enough to ship.** arm64 macOS refuses to map unsigned code,
  so the ad-hoc signature is why `dlopen` works at all; but it carries no Developer ID and is not
  notarized, so an application redistributing this file has to re-sign it with its own identity and
  notarize the bundle. Re-signing rewrites the file and therefore breaks the hash above - sign a copy in
  your build output, never `lib/`.
- **The install name is absolute.** Irrelevant here, because the loader in `src/prelude.odin` is
  `dlopen`-by-path rather than link-time, and worth knowing before anyone tries to link against it:
  that path is where a link-time consumer would look at runtime unless `install_name_tool` says
  otherwise.
- **One file, two architectures.** ~24 MB of it is dead weight on any given machine, which is what makes
  the macOS engine 50 MB against Windows' 19 MB. `lipo -thin arm64` is the fix in an application's own
  build; it is deliberately not done here, so that what is pinned is what upstream shipped. It is also
  the whole reason this one platform is fetched rather than committed - thinning it in the tree would
  have meant a hash per architecture and a Mac to produce them, for a file this repository would then
  be shipping rather than pinning.

`just fetch-engine` installs against these hashes, `just fetch-engine --check` verifies what is already
on disk, `just ensure-engine` is a dependency of every build recipe, and every CI job fetches as its
first real step. A binary obtained out of band - a mirror, a colleague, an SDK checkout - can be checked
against them too. Regenerate with `sha256sum lib/linux/x64/libsciter.so`.

**These hashes are now load-bearing in a way they were not while the binaries were committed.** Upstream
withdrawing or moving a tag used to be survivable, because the bytes were in git history; they are not
any more. `fetch-engine.py` therefore tries three sources, all verified against the same hash, so a
mirror can be untrusted without being unsafe - the worst a bad one can do is fail the check:
`SCITER_ENGINE_URL` (a complete URL for one file), `SCITER_ENGINE_BASE` (an alternative base), and then
this repository's own release assets at
`https://github.com/enerqi/odin-sciter/releases/download/engine-<tag>/<filename>`. That third one takes
no configuration - the URL is built from the pinned tag - which is what makes it a fallback for a fresh
clone rather than for whoever already knows about it. Publishing the three binaries under an
`engine-<tag>` release is a step of cutting a release for exactly this reason.

The justfile's `engine_sha256` is per-platform for the same reason this table has a row per file: the
pin is on the binary, not on the tag. One shared hash made `just fetch-engine` on Windows compare
`sciter.dll` against the Linux `.so`'s digest and refuse to install.

**The upstream tag is `6.0.4.9-bis`, and the suffix is not cosmetic.** The plain `6.0.4.9` tag serves a
`libsciter.so` of *exactly* the same 25 015 296 bytes with a different SHA-256 - measured, by fetching
both. Size is not identity here; the tag and the hash are.

Upgrading the pinned version is a procedure with one non-negotiable step in it - see
[`docs/UPGRADING.md`](../../docs/UPGRADING.md), which also covers our tagging and the repository-size
budget.

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

- `bin/` for platforms other than Linux x64, Windows x64 and macOS - the `windows.d2d/` and
  `windows.xp/` variants, Android, and the 32-bit and ARM Linux builds
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
