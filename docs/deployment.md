# Deployment

What to ship, where the engine has to be, what you owe Terra Informatica, and what to expect on each
platform.

> **Status.** Linux x64 and Windows x64 are both vendored and run. macOS is untested and unvendored —
> treat its rows below as instructions, not as verified results.
>
> Two Windows results here are measured rather than assumed, and both were open questions in this file
> until 2026-08-15. The single-binary cache resolves to `%LOCALAPPDATA%\odin-sciter\<hash>\sciter.dll`,
> is written once, is reused on the second run, and **was not quarantined by anti-malware** — one
> machine and one product, so evidence rather than proof. And `os.rename` over an existing destination
> succeeds, because Odin's `core:os` uses the replacing variant of `MoveFile`, so the extract-and-rename
> path behaves identically on both platforms.
>
> **Call `set_default_debug_output()`, or install your own handler, in every Windows application.** With
> none installed the engine reports diagnostics through `OutputDebugStringW`, which Windows implements
> by raising an exception. That is harmless in a normal run and fatal under anything that treats
> first-chance exceptions as errors — a test runner, some crash reporters, some sandboxes.
>
> What is still open on Windows is in [`WINDOWS-CHECKLIST.md`](WINDOWS-CHECKLIST.md).

## What ships

| | |
| --- | --- |
| your executable | built with `odin build` |
| the engine | `libsciter.so` / `sciter.dll` / `libsciter.dylib`, ~25 MB |
| your UI | as files, or inside the executable — see [`resources.md`](./resources.md) |
| attribution | a line in your About box, see [Licensing](#licensing) |

Nothing else. No runtime to install, no Chromium, no Node, no separate process.

### Per platform

| Platform | Engine file | Where it goes | From |
| --- | --- | --- | --- |
| Linux x64 | `libsciter.so` | beside the executable | `bin/linux/x64/` in the SDK |
| Windows x64 | `sciter.dll` | beside the `.exe` | `bin/windows/x64/` |
| macOS | `libsciter.dylib` | `Contents/Frameworks/` in the bundle | `bin/macosx/` |

The SDK also ships `bin/windows.d2d/` (a Direct2D build) and `bin/windows.xp/`, plus arm64 builds for
Linux, Windows and macOS. Pick one build and pin it — and re-run `just example api_map` against it,
which is the check that catches a header/binary mismatch.

### Runtime dependencies

Linux needs, and a stock desktop install already has: fontconfig, freetype, EGL, GLESv2, expat, zlib,
libpng, brotli, libstdc++, libuuid. Sixteen entries in `ldd`, nothing exotic.

**Sciter 6 does not use GTK.** Sciter 4 did, and much of the material online still says so. There is no
`libgtk-3` dependency, and no X11 or Wayland client library either — the engine renders through its own
EGL/GLESv2 backend.

A headless container needs a display and working EGL to open a window. The headless-testable parts —
library loading, the version handshake, `Value` round-trips, archive open/read — do not, which is why
the tests that need a window gate themselves on `DISPLAY` / `WAYLAND_DISPLAY`.

**If the UI plays video, libVLC is a dependency you have to ship or require.** `behavior: video` —
which `<video>` gets by default — is implemented on top of libVLC and is dlopened by name (`libvlc`,
`libvlc/libvlc.so`). Missing, it does not degrade or complain: the behavior does not attach at all, and
the element is inert with no error anywhere. Ship `libvlc.so` / `libvlc.dll` / `libvlc.dylib` beside
the engine, or require the player (`libvlc-dev` on Linux) on the target machine. See
[`ENGINE.md`](./ENGINE.md#what-it-links-and-what-it-only-looks-for).

An application that generates its own frames does **not** need it: `behavior: custom-video` and
[`video.odin`](../sciter_app/video.odin) go through a rendering site that touches no codec library.

## Where the engine is found at runtime

`sciter.load()` searches in this order:

1. an explicit path you pass
2. `SCITER_LIB` — a file or a directory
3. **the directory containing the running executable** ← this is the one that matters when shipping
4. `lib/<platform>/` relative to the working directory
5. the system loader's search path

Shipping the engine beside the executable therefore needs no configuration at all. Relying on the
system path is the fragile option: a user with another Sciter version installed gets it instead, and
the version check then refuses to load rather than misbehaving — which is correct, but is a support
call.

If you install the engine somewhere else, pass the path explicitly rather than depending on the
working directory, which is whatever the launcher felt like:

```odin
sciter_app.load_engine("/usr/lib/myapp/libsciter.so")
```

## One file, or two

Two artifacts is the ordinary arrangement and the one to reach for by default: your executable plus the
engine beside it.

For a single artifact, `load_embedded` puts the engine in the executable as data, writes it out once to
the user's cache directory, and loads it from there. [`resources.md`](./resources.md#the-engine-itself)
covers the mechanics. Before adopting it, weigh:

- the executable grows by ~25 MB
- the first run writes to a cache directory, which must be writable and **must not be mounted
  `noexec`** — which is why this uses the user's cache directory rather than `/tmp`, since `/tmp` is
  `noexec` on a fair number of hardened systems
- on Windows, a freshly written DLL is exactly the pattern anti-malware heuristics look at
- the extracted file is an ordinary file; this hides nothing and protects nothing
- code-signing and notarization (macOS) apply to what is on disk, and an extracted library is not
  covered by your bundle's signature

For a signed, notarized macOS `.app` or a Windows installer, ship the two files. For a
`curl | download and run` CLI-style tool, embedding is the difference between one artifact and a
tarball.

### Packaging notes

**Linux.** An AppImage or a tarball with the engine beside the binary needs nothing further. For a
`.deb`/`.rpm` that installs to `/usr/lib/<app>/`, pass the path explicitly. Do not expect a distro
package for Sciter to exist.

**Windows.** `sciter.dll` beside the `.exe`. No registry, no COM registration, no manifest requirement.

**macOS.** `libsciter.dylib` in `Contents/Frameworks/`, and the executable's rpath set accordingly —
or, since the loader here is `dlopen`-based rather than link-time, simply pass the resolved bundle path
to `load_engine`. Untested: expect to spend time on notarization and hardened-runtime entitlements
before it launches cleanly.

## Licensing

Two licences apply, and they cover different things.

**The SDK's contents** — headers, samples, documentation — are BSD 3-Clause. These bindings are
generated from those headers, which is why generating and shipping them is unencumbered.

**The engine binary is not BSD.** It is covered by
[`external/sciter/SCITER-ENGINE-EULA.md`](../external/sciter/SCITER-ENGINE-EULA.md). Terra Informatica
retains copyright and grants free use in commercial and non-commercial applications, subject to one
concrete obligation:

> Your application shall include link to Terra Informatica site in "About" dialog or similar place in
> your application. Text of the link: This Application (or Component) uses Sciter Engine
> (http://sciter.com/), copyright Terra Informatica Software, Inc.

So: Sciter is free to use, including commercially, and **you owe that line**. It is one `<p>` in your
about dialog, and nobody reads the EULA to find out, which is why it is stated in the README, in the
plan, and here.

Access to the engine's *source code*, and the right to link it statically, are the paid tiers at
<https://sciter.com/prices/>.

**These bindings** are under [`LICENSE`](../LICENSE) in the repository root.

On embedding the engine in your executable: the EULA's grant is "You may utilize sciter.dll in any
manner you see fit (subject to the limitations outlined in this license)", and the only limitation it
states is the attribution above. It says nothing about embedding. That is a reading of the text and not
legal advice; ask Terra Informatica if it matters commercially.

## Version pinning and upgrades

The engine is pinned at `6.0.4.9-bis` — see
[`external/sciter/VENDORED.md`](../external/sciter/VENDORED.md) for the commit and the API version.
Upstream tags roughly weekly.

The upgrade procedure:

1. drop in the new headers and binary
2. `just bindgen` — regenerate `sciter.odin`
3. **`just example api_map`** — 189 slots, 16 null, 0 mismatches. This is the check.
4. `just check` and `just example-tests`
5. run the windowed examples

Step 3 is not optional and it is not a formality. `ISciterAPI` is an ordered struct of function
pointers: a slot inserted upstream shifts everything after it, and the only symptom is a crash
somewhere unrelated. The version field guards the gross case; `api_map` catches the rest.

**Use the GitLab repository**, <https://gitlab.com/sciter-engine/sciter-js-sdk>. The
`c-smile/sciter-js-sdk` mirror on GitHub is abandoned — last commit 2022, engine 4.4.8.33 — and its
headers do not match the binaries committed beside them.

## Pre-ship checklist

- [ ] the engine is beside the executable, or `load_engine` is given an explicit path
- [ ] `load_engine` failure is surfaced to the user, not swallowed — the candidate list is the
      diagnosis
- [ ] the attribution line is in the About box
- [ ] `just example api_map` passes against the engine build you are shipping
- [ ] the UI loads from the archive, not from a path that only exists on your machine
- [ ] if anything uses `<video>`, libVLC ships beside the engine or is a stated requirement
- [ ] script features (`set_script_features`) are granted deliberately, not copied from an example
- [ ] the inspector is off: no `.ENABLE_DEBUG` in the release window flags
- [ ] debug output goes somewhere sane in release — a log file, or nowhere, not stderr on Windows
- [ ] tested on a machine without the SDK installed
