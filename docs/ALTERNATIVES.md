# Alternatives

Where Sciter sits among the other ways to build a native desktop UI, and why the niche it holds is
narrower than "HTML/CSS UI toolkit" suggests. Written the way [`RESEARCH-METHOD.md`](./RESEARCH-METHOD.md)
describes: web search for orientation only, facts pulled from each project's own repository, and
freshness checked against the repo's own commit/release history rather than trusted from a blog post.
Sciter's own traits below are not re-derived here — they come from
[`architecture.md`](./architecture.md) and [`ENGINE.md`](./ENGINE.md), which measured them against the
vendored binary.

## Sciter's actual position

Three things distinguish it from the field, together rather than individually:

1. **Its own HTML/CSS/JS engine, not the OS webview and not Chromium.** Skia + QuickJS, one `.so`,
   identical layout on every platform — see
   [`architecture.md`](./architecture.md#the-layout-is-identical-on-every-platform). The qualifier
   matters: plenty of options below ship their own renderer at a small size (Slint, Avalonia, Flutter,
   egui) — they just don't render HTML. Restricted to *web-language* engines the field is small but not
   empty: Ultralight, RmlUi, Blitz, Lynx and Coherent Gameface are all in the same box.
2. **Not sandboxed.** The document runs in the host process. Script reaches native code through
   `sciter::om` / native extensions, not through a security boundary — see
   [`calling-between-odin-and-js.md`](./calling-between-odin-and-js.md). Most HTML-UI alternatives
   deliberately put a wall there; Sciter has no wall. That cuts both ways — see
   [Security patching](#security-patching-the-cost-of-no-sandbox).
3. **A full DOM and a real CSS cascade with a scripting language attached** — not a
   markup-to-native-widget translation (XAML, `.slint`), not immediate-mode imperative calls
   (ImGui-family), and not a layout library you drive from the host language with no script engine at all
   (litehtml, RmlUi's C++ core, Blitz).

Every alternative below gives up at least one of these three. What none of the three says, and what
[HTML/CSS reuse](#htmlcss-reuse-and-standards-conformance) covers instead, is how much *existing web
code* comes along — the answer is less than "HTML/CSS/JS" implies.

## Sciter's own health

Applying the same liveness audit this document applies to Ultralight and Orca, because a comparison that
only audits the competition isn't a comparison. Two facts sit in tension:

```sh
curl -s "https://api.github.com/repos/c-smile/sciter-js-sdk" | grep -E '"pushed_at"|"archived"'
# pushed_at: 2022-04-19, archived: true

curl -s "https://api.github.com/repos/c-smile/sciter-sdk" | grep -E '"pushed_at"|"archived"'
# pushed_at: 2023-07-03, archived: true
```

Both GitHub repositories are **archived**, and nothing on the author's GitHub account has been pushed
since 2024-06. Anyone evaluating Sciter from GitHub alone concludes it is dead. It isn't — development
moved to GitLab, which is where this project's pinned SDK comes from
(`gitlab.com/sciter-engine/sciter-js-sdk`, tag `6.0.4.9-bis`, see [`../README.md`](../README.md)):

```sh
curl -s "https://gitlab.com/api/v4/projects/sciter-engine%2Fsciter-js-sdk/repository/tags?per_page=5" \
  | jq -r '.[] | "\(.name)  \(.commit.created_at[0:10])"'
# 6.0.4.9-bis  2026-08-02
# 6.0.4.9      2026-08-02
# 6.0.4.8      2026-07-24
# 6.0.4.7      2026-07-17

# 17 commits in the trailing 90 days; 131 stars
```

Read: **alive and shipping**, on a roughly weekly patch cadence, more actively than most of the field.
But the risk profile is the same shape as the Ultralight critique below — a closed-source binary core
with a single maintainer behind it, a visible community of 131 GitLab stars, and a public GitHub
presence that has been archived for years. The engine cannot be forked, patched, or audited if that
maintainer stops. That is the honest counterweight to everything Sciter does well, and it is the reason
this document tracks the field at all rather than treating the choice as settled. See
[Vendor risk](#vendor-risk-and-bus-factor).

## Landscape

Grouped by what the thing actually is, because the interesting comparisons are within a group, not
across. "From Odin" is the column that matters most for this repository: Sciter's single `ISciterAPI`
C struct is the reason these bindings exist at all, and most of the field has no C ABI to bind to.

### Own HTML/CSS engine, no browser underneath — Sciter's real peer group

| | Engine basis | License | From Odin | Gap vs Sciter |
| --- | --- | --- | --- | --- |
| [Ultralight](https://github.com/ultralight-ux/Ultralight) | WebKit port, own GPU/Skia-CPU renderer | Free under $100k revenue, else paid; core proprietary | Documented [C API](https://ultralig.ht/api/c/1_3_0/) — directly bindable, no shim | Closest direct peer on paper — own engine, not sandboxed by default. **Stalled**: see below |
| [RmlUi](https://github.com/mikke89/RmlUi) | Own HTML/CSS-like layout engine, **no JS** (Lua plugin), caller supplies the renderer | MIT | C++ only — needs a hand-written C shim | The nearest thing to "Sciter without the JS engine or the graphics". Full DOM, events, data binding, `@media`, transforms, transitions; but you write or adopt a render backend, and script means Lua |
| [litehtml](https://github.com/litehtml/litehtml) | Own HTML/CSS layout, **no JS**, no own graphics — caller supplies draw callbacks | BSD-3-Clause | C++ only — needs a shim | Layout-only half of what Sciter is, and less of it than RmlUi. Fine for tooltips/rich text, not an app-UI engine |
| [Blitz](https://github.com/DioxusLabs/blitz) | Own engine: Stylo (Servo's CSS engine) + Taffy layout + Vello/WGPU paint. No JS — the host language drives the DOM | Apache-2.0 / MIT | Rust crate — needs a `cbindgen`-style C ABI shim | **Pre-alpha, says so itself.** Same "own HTML/CSS engine, not Chromium-scale" box the Ultralight pitch occupied, being actively built. Content model is Rust-driven (Dioxus), not scripted |
| [Lynx](https://github.com/lynx-family/lynx) | Own engine, CSS + JS on PrimJS, dual-thread architecture | Apache-2.0 | C++/ObjC/Java, mobile toolchain — impractical | ByteDance, production at TikTok scale. Mobile-first with desktop secondary — the inverse of Sciter's priorities. Heavy build, not a single-`.so` drop-in |
| Coherent Gameface | Own engine (Chromium-derived), HTML/CSS/JS for game UI | Closed, commercial, per-title | C++ SDK, commercial licence | Sciter's most direct *commercial* competitor — same pitch, games market, real console support. Priced for studios, no free tier, no public repo to audit |

Freshness for that group, checked the same way as everything else here (commits in the trailing 90 days
as of 2026-08-10, counted with `jq length` over the paged commits endpoint):

| | Pushed | Commits/90d | Stars | Latest release |
| --- | --- | --- | --- | --- |
| Sciter (GitLab) | 2026-08-03 | 17 | 131 | 6.0.4.9-bis, 2026-08-02 |
| Ultralight | 2024-04-22 | 0 | 5.0k | 1.3.0, 2023 |
| RmlUi | 2026-08-07 | 36 | 4.3k | 6.2, 2026-01-11 |
| Blitz | 2026-08-10 | 283 | 4.0k | none — pre-alpha, crates.io only |
| Lynx | 2026-08-10 | 102 | 15.1k | 4.0.1, 2026-07-31 |

Blitz is the busiest thing in Sciter's peer group by a wide margin and the least usable; RmlUi is the
steadiest; Lynx is the largest by community and the least embeddable. Sciter's 17 commits/90d look small
next to those, but they are release commits on a mature engine rather than pre-alpha churn — the
comparison to draw is with Ultralight's zero.

### Full browser, embedded

| | Engine basis | License | From Odin | Gap vs Sciter |
| --- | --- | --- | --- | --- |
| CEF | Full Chromium, multi-process | BSD | C API (`libcef_dll`) — bindable, but an enormous surface | Best web compat, heaviest (100MB+). Chromium's renderer-process sandbox is real, unlike Sciter's in-process model |
| Electron / NW.js | Chromium + Node | MIT | N/A — you write the app in JS, Odin would be a subprocess | Full JS ecosystem, same footprint problem, ships a runtime rather than a library |
| Qt WebEngine | Chromium inside Qt | LGPL-3.0 / commercial | C++ only — needs a shim, and pulls in Qt | Chromium's weight plus a whole application framework. Absent from most comparisons but the most-deployed of the lot |

### OS-webview wrappers — no engine of their own

All share one tradeoff: three different rendering engines across platforms (WebView2 / WebKitGTK /
WKWebView), which is the inconsistency Sciter's own-renderer design exists to avoid. All sandbox the
content and route native access through an explicit bridge.

| | Host / binding | License | From Odin | Note |
| --- | --- | --- | --- | --- |
| [Tauri](https://github.com/tauri-apps/tauri) / wry | Rust | MIT / Apache-2.0 | Rust — shim required | The mature one. DOM-based; native access through the `invoke` bridge, gated in v2 by capabilities and permissions rather than one allowlist. Real mobile story |
| [webview/webview](https://github.com/webview/webview) | Single C header | MIT | **Directly bindable** — one C header | No framework around it, which is the point |
| [WebUI](https://github.com/webui-dev/webui) | C library | MIT | **Already bound**: `webui-dev/odin-webui` | Different bet again: drives the user's *installed browser*, bundles no webview at all. Smallest possible shipped artifact, at the cost of depending on whatever browser is present. See [below](#webui-in-detail) |
| [Photino](https://www.tryphotino.io/) | .NET | MIT | Not practical | <1MB own binary but needs the .NET runtime present |
| [Wails](https://github.com/wailsapp/wails) | Go | MIT | Not practical | The Go-ecosystem equivalent of Tauri |
| [Neutralinojs](https://github.com/neutralinojs/neutralinojs) | Any language, over a local WebSocket/IPC protocol | MIT | Usable **without bindings** — talk the protocol | Loosest coupling in the table; also the least direct control |
| [saucer](https://github.com/saucer/saucer) | C++ | MIT | C++ — shim required | Modern C++ webview wrapper. 1 commit on the default branch in the trailing 90 days — the repo's recent `pushed_at` reflects other branches, which is exactly the trap `pushed_at` sets |

### WebUI, in detail

WebUI gets its own subsection because it is the only entry in this document with **official Odin
bindings maintained by the upstream project**, which makes it the shortest path from here to a
sandboxed UI.

It is not really an OS-webview wrapper, despite sitting in that table. It ships no engine and embeds no
webview: it starts a local server, launches **a browser the user already has**, and talks to the page
over a binary WebSocket protocol. Your document loads `webui.js` and that is the whole client side.

```odin
package main

import ui "webui"

main :: proc() {
    my_window: uint = ui.new_window()
    ui.show(my_window, "<html><script src=\"webui.js\"></script>Thanks for using WebUI!</html>")
    ui.wait()
}
```

Installation is a git submodule plus a `setup.sh` / `setup.ps1` that fetches the C library — no package
manager, no system dependencies. Contrast `webview/webview`, which on Linux needs
`libgtk-4-dev` + `libwebkitgtk-6.0-dev` (or the GTK3 / webkit2gtk-4.1 pairing) at build *and* run time.

| | |
| --- | --- |
| Shipped size | "Few Kb library" per its README, plus your binary. Nothing else — no engine, no runtime |
| Browsers driven | Firefox, Chrome, Edge, Chromium, Yandex, Brave, Vivaldi on all three platforms. Safari macOS "coming soon", unavailable on Linux/Windows. Opera "coming soon" everywhere |
| Optional WebView mode | Yes, if you would rather embed than launch a browser |
| Transport | Binary WebSocket over localhost; optional TLS via OpenSSL |
| Isolation | The UI is a real browser page in a **private profile** — the strongest content sandbox in this document, stronger than CEF's, because it is a whole separate browser process tree you do not own |
| Native access | Only what you expose across the socket. There is no ambient filesystem or device access from the page |

**Health, and the caveat that matters.** The core is active — 28 commits in the trailing 90 days — but
its newest release is **`2.5.0-beta.3`, published 2025-03-07**: no stable 2.5 has ever shipped, and the
tag is more than a year old. The Odin bindings are worse: `webui-dev/odin-webui` has **0 commits in the
trailing 90 days**, last pushed 2026-03-26, pinned at `v2.5.0-beta.3`. So "already bound for Odin" is
true, and "actively maintained bindings" is not. Budget for carrying them yourself; they are a thin
wrapper over a C API, which is the saving grace.

The deeper tradeoff is architectural rather than technical, and it is covered in
[the last section](#sandboxed-small-fast-and-reachable-from-odin): a WebUI app is a client/server
application in which the server happens to be your own process.

### Not HTML/CSS at all

| | Engine basis | License | From Odin | Gap vs Sciter |
| --- | --- | --- | --- | --- |
| [Slint](https://slint.dev/) | Own `.slint` DSL compiled to native code, no JS/DOM | GPL-3.0, or the Royalty-free licence (free, attribution required, desktop/mobile/web only — **not** embedded systems) | **No C API** — `api/` in `slint-ui/slint` holds `cpp`, `rs`, `node`, `python`, `slint-sc`, `wasm-interpreter`, and no C binding. Needs a hand-written shim | Not HTML/CSS at all. Runtime under 300KiB, no interpreter |
| Qt Quick / QML | Own scene-graph renderer, QML + JS | LGPL-3.0 / commercial | C++ only — shim, plus Qt itself | The XAML-family option with the largest real deployment. Own renderer, consistent layout, but an entire framework rather than a library |
| Avalonia | XAML, own cross-platform Skia renderer | MIT | Not practical (.NET) | Same "own renderer, consistent layout" bet as Sciter, but XAML/.NET instead of HTML/CSS/JS |
| [Compose Multiplatform](https://github.com/JetBrains/compose-multiplatform) | Kotlin, Skia via Skiko | Apache-2.0 | Not practical (JVM/Kotlin-native) | Same Skia renderer family as Sciter and Flutter. Desktop + Android + iOS + web from one codebase; JetBrains-funded, 75 commits/90d |
| .NET MAUI | XAML, wraps real native controls per platform | MIT | Not practical | Not web tech, not even a shared renderer — heaviest of the native-control options |
| NoesisGUI | XAML for games, own renderer | Closed, commercial | C API exists, commercial licence | The XAML analogue of Gameface. Named for completeness: the games-UI market is where Sciter's closed competitors live |
| Flutter (desktop) | Skia, own widget system, Dart | BSD-3-Clause | Embedder C API exists, but you still ship the Dart runtime | Same renderer family as Sciter (Skia), unrelated content model |
| Dear ImGui / egui | No markup — immediate-mode C++/Rust calls, any graphics backend | MIT (both) | ImGui via `dear_bindings` or `cimgui` — [detail below](#immediate-mode-in-detail); egui is Rust-only | Fast because there's no DOM or CSS cascade to run. egui-on-native has full native access; egui-on-wasm is browser-sandboxed |

### What Odin can already reach today

Worth stating plainly, because it is the actual alternative to these bindings for an Odin project — not
a hypothetical port of a C++ toolkit:

| | Status | Note |
| --- | --- | --- |
| `vendor:microui` | Ships with the compiler (verified in the local Odin tree) | Immediate-mode, tiny, no markup. An Odin-native **source port** of rxi's C original, not a binding — so upstream's stalling doesn't reach you. The zero-friction option. [Widget set below](#the-widget-ladder) |
| `vendor:raylib` (+ raygui) | Ships with the compiler — `vendor/raylib/raygui.odin`, verified present | Game-oriented, and its widget set is markedly wider than microui's. [Below](#the-widget-ladder) |
| [Dear ImGui](https://github.com/ocornut/imgui) | Third-party bindings only, and the popular one is **archived** — see [below](#getting-dear-imgui-into-odin) | The widest widget set in this document that is reachable from Odin at all. Costs a C++ build step (premake5 + Python), not a vendored `.a` |
| [Nuklear](https://github.com/Immediate-Mode-UI/Nuklear) | **No Odin bindings** — but a single C89 header with no dependencies, so `odin-c-bindgen` is the whole job | Sits between microui and ImGui on widgets. The least-effort unbound option here |
| [Clay](https://github.com/nicbarker/clay) | Single-header C, **official Odin bindings** in `bindings/odin/` (verified present), zlib | Flexbox-like retained layout, renderer-agnostic, has an HTML renderer. **Cooling**: 8 commits in the trailing 90 days, all of them before 2026-05-20, so nothing for nearly three months. Usable and dependency-free regardless — it is a single header you vendor. [Full comparison below](#clay-in-detail) |
| `vendor:nanovg`, `vendor:fontstash` | Ship with the compiler | Vector drawing and text, if you are building the UI layer yourself |
| [`odin-webui`](https://github.com/webui-dev/odin-webui) | Upstream-authored Odin bindings, MIT, 104★ — but **0 commits in the trailing 90 days** | The sandboxed option: HTML/CSS/JS in the user's own browser, driven from Odin over a localhost socket. [Detail above](#webui-in-detail) |

None of these give you HTML/CSS authoring, and that is exactly the trade: Sciter costs a 25MB
proprietary binary and a binding layer; microui costs an import statement.

One correction on Slint's licensing, checked against the licence text and FAQ in `slint-ui/slint` rather
than the marketing page: the free-but-you-have-to-apply "Ambassador" licence is the *old* programme. The
current **Royalty-free licence (v2.0)** replaced it and dropped the application step — usable without
asking anyone, still free, still requires the Slint attribution, still excludes embedded systems.
Existing Ambassador grantees keep their perpetual licence.

## Ultralight's actual health, and what's more alive in the same niche

The 4,998-star flagship repo is what everyone finds, and it reads as maintained — recent-looking README,
active-sounding docs site. Checked directly against the GitHub API rather than taken on trust:

```sh
curl -s "https://api.github.com/repos/ultralight-ux/Ultralight" | grep -E '"pushed_at"|"open_issues_count"'
# pushed_at: 2024-04-22, open_issues: 281

curl -s "https://api.github.com/repos/ultralight-ux/Ultralight/commits?since=2025-08-10T00:00:00Z" | jq length
# 0
```

Zero commits in the trailing year. The last real commit (2023-07-22) is 1.3.0 release notes — no release
since. 281 open issues, none being closed there. The actual renderer (`UltralightCore`) was never open
source to begin with, so the public repo was always a shell around a closed core — and that shell stopped
moving. Sibling repos under the same org are patchier, not dead: `WebCore` and `AppCore` got pushes in
March 2026, `Samples` was pushed today. Reads like the OSS side is minimally kept alive around a
commercial product whose real activity isn't visible on GitHub, rather than the whole thing being dead —
but nothing here supports treating it as an actively developed option.

Four projects occupy the same "own engine, not Chromium-scale, embeddable" niche and are unambiguously
alive, checked the same way (`pushed_at`, and commits in the trailing 90 days counted with `jq length`
over the *paged* commits endpoint):

```sh
count() {                       # $1 = owner/repo
  total=0; page=1
  while :; do
    n=$(curl -s "https://api.github.com/repos/$1/commits?since=2026-05-12T00:00:00Z&per_page=100&page=$page" | jq length)
    total=$((total+n)); [ "$n" -lt 100 ] && break; page=$((page+1))
  done
  echo "$1 = $total"
}
```

The obvious one-liner, `curl … | grep -c '"sha"'`, is wrong in both directions and earlier revisions of
this document quoted its output. It **overcounts** roughly threefold on quiet repos, because each commit
object carries its own sha plus its tree's and its parents'; and it **undercounts** badly on busy ones,
because a single request caps at 100 commits, so anything busier silently reports the cap. WPE's real
figure is 36, not the ~117 that method produced; Servo's is 1,404, not ~300.

`pushed_at` has a related trap worth stating once: it moves for a push to *any* branch, so a repo can
look active while its default branch is idle. saucer is the example here — `pushed_at` two days ago, one
commit on the default branch in ninety. Freshness claims in this document mean default-branch commits.

| | Pushed | Commits/90d | Stars | What it actually is |
| --- | --- | --- | --- | --- |
| [Servo](https://servo.org/) | today | 1,404 | 37.7k | Own Rust engine, no WebKit/Chromium underneath. Stewarded by Linux Foundation Europe since 2020, Igalia-staffed since 2023. **Shipped a stable 0.1.0 in April 2026**, and took a €545,400 Sovereign Tech Fund grant earmarked specifically for a stable embeddable WebView API — i.e. funded right now to become exactly what Ultralight was supposed to be |
| [Ladybird](https://ladybird.org/) | today | 1,500+ (paging stopped there) | 65.2k | Own engine (LibWeb + LibJS), ex-SerenityOS, huge momentum and funding. **Caveat**: targets a standalone browser *application*, not an embedding SDK — no "drop this library into your app" product yet |
| [WPE WebKit](https://wpewebkit.org/) | today | 36 | 246 | The actual WebKit port for embedded targets, maintained by Igalia. Boring by design — but proven at real scale: adopted by Comcast/RDK for set-top boxes, tens of millions of deployed devices. Still WebKit (not standalone), heavier dependency chain (Cairo, GStreamer, GLib) than Sciter or Ultralight |
| [gosub](https://github.com/gosub-io/gosub-engine) | 2026-08-08 | 657 | 3.7k | Own browser engine in Rust, MIT, explicitly designed to be *used as a component* rather than only as a browser — the stated goal Servo is being funded to reach and Ladybird isn't chasing. Far earlier than the other three and a much smaller community, but 657 commits/90d against 3.7k stars is the highest activity-per-attention ratio in the table |

One datapoint against the optimistic reading of Servo: [Verso](https://github.com/versotile-org/verso),
the concrete attempt to wrap Servo as an embeddable webview (Tauri-adjacent, 5.4k stars), was
**archived on 2025-10-08**. The Sovereign Tech Fund grant targets Servo's own WebView API rather than
Verso, so the funding argument stands — but the one shipped attempt at "Servo as a drop-in webview" is
dead, which is worth knowing before treating Servo as a near-term option.

Read: if the pitch that attracted you to Ultralight was "own rendering engine, small enough to embed,
free of Chromium's weight," Servo is the one being built toward that right now with funding attached to
the exact gap (embeddability) that matters here. WPE is the mature, unglamorous, already-proven choice if
"boring and shipping in production for a decade" outweighs "modern and Rust". Blitz is the same idea at a
fraction of the scope and admits it's pre-alpha. None is a drop-in Sciter replacement today.

## Axes

### Size (disk)

| | Footprint |
| --- | --- |
| Sciter | 25MB `libsciter.so`, measured ([`ENGINE.md`](./ENGINE.md)) |
| CEF / Electron | 100–150MB+, full Chromium |
| Ultralight | Smaller than CEF; no figure published, though the SDK is a public download and could be measured the way `ENGINE.md` measured Sciter's |
| RmlUi / litehtml | Low single-digit MB for the core — but the number is misleading until you add the renderer, font stack and image decoders you have to supply yourself |
| Tauri (wry) | Sub-600KB core — webview borrowed from the OS, not bundled |
| Photino | Under 1MB own binary, needs the .NET runtime present or self-contained bloats it |
| Slint | Under 300KiB runtime |
| Dear ImGui / egui / microui | Tens of KB to low MB, no separate runtime |

Disk is the least interesting of the size numbers and the only one usually quoted. Resident memory after
first paint, and cold-start-to-first-frame, decide whether a UI feels native — and both are measurable
against the vendored binary here, the way `ENGINE.md` measured the 25MB. Neither is measured yet; treat
the table above as the shallow axis it is.

### Binding effort from Odin

The axis this repository exists on, and the one most comparisons omit entirely.

- **Directly bindable, no shim**: Sciter (one `ISciterAPI` struct — see [`api.md`](./api.md)), Ultralight
  (documented C API), `webview/webview` (one header), WebUI, CEF (C API, huge), Clay (bindings already
  written), Nuklear (one C89 header), anything in Odin's `vendor`.
- **C++, but somebody already generates the C API**: Dear ImGui, via `dear_bindings` or `cimgui`. Not a
  shim you write, but not free either — you build the C++ library yourself. See
  [below](#getting-dear-imgui-into-odin).
- **Needs a hand-written C shim**: RmlUi, litehtml, Slint, Qt, saucer — all C++-only APIs. This is real
  work and it is ongoing work, since the shim tracks their API changes.
- **Needs a foreign runtime, so effectively out**: Tauri/wry and Blitz (Rust ABI), Photino/Avalonia/MAUI
  (.NET), Wails (Go), Compose (JVM), Flutter (Dart), Electron (Node).
- **Bindings-free by protocol**: Neutralinojs, which you drive over local IPC rather than linking.

Sciter's advantage here is larger than its feature list suggests: a stable, versioned, single-entry-point
C ABI is rare in this field, and it is what makes an Odin binding a weekend's work rather than a
subproject.

### Native FS / API access

Two families, not a spectrum:

- **Same process, no sandbox.** Sciter, Ultralight, RmlUi, litehtml, Blitz, Slint, native-target
  ImGui/egui, MAUI, Avalonia, Qt. The host language always has full native access; the UI side reaches it
  however the toolkit wires it up — for Sciter that is `sciter::om` and native extensions, for ImGui and
  litehtml there is nothing to wire because they aren't scriptable.
- **Content sandboxed on purpose, native access is a bridge.** CEF/Electron (Chromium process sandbox +
  IPC), Tauri/Photino/Wails/webview.h/WebUI (the webview is a real browser page; native calls go through
  an allowlisted bridge), egui-on-wasm (browser sandbox, filesystem only via the File System Access API
  with a permission prompt), Orca (capability-gated file API, by design).

Sciter looking like a browser but behaving like the first family is the point worth remembering: most
other HTML-UI options put a wall between content and host on purpose. Sciter doesn't, because there
isn't one.

### Security patching: the cost of no sandbox

The flip side of point 2 in [Sciter's actual position](#sciters-actual-position), and the reason "not
sandboxed" is a design choice rather than a free win:

- **You ship the engine, so you ship its CVE fixes.** A vulnerability in Sciter's HTML parser, CSS engine
  or QuickJS is yours to patch by shipping a new `libsciter.so` to every installed user. With no
  sandbox, a parser bug is arbitrary code execution in your process with your process's privileges —
  there is no second boundary to catch it. Same for Ultralight, RmlUi, Blitz, Gameface.
- **OS-webview wrappers get patched by the OS.** Tauri, Photino, Wails, webview.h, WebUI inherit
  WebView2 / WebKitGTK / WKWebView security updates through Windows Update, distro packages and macOS
  updates — for free, including for software you shipped years ago.
- **CEF/Electron sit in between**: you ship the engine and must chase Chromium releases, but the
  renderer sandbox means a content bug is usually contained rather than immediately fatal.

This only bites if you render untrusted content. A Sciter app whose HTML is entirely your own, bundled
in the binary, has a much smaller exposure than one that loads remote pages — but "we never load remote
content" is a constraint worth writing down deliberately rather than discovering later.

### HTML/CSS reuse and standards conformance

The claim that needs the most qualification, because "HTML/CSS/JS" implies an ecosystem that mostly does
not come along.

| | What actually transfers |
| --- | --- |
| Electron, NW.js, CEF, Tauri, Photino, Wails, webview.h, WebUI | Everything. It is a real browser: npm, React/Vue/Svelte builds, Tailwind, existing components, browser DevTools |
| Ultralight | Most of it — a real WebKit port, so standards conformance is high; older WebKit, so newest features lag |
| **Sciter** | **Your knowledge, not your code.** See below |
| RmlUi, litehtml, Blitz | HTML/CSS *shaped* languages with real cascades, but each supports a defined subset and none runs browser JS. Existing web projects do not port |
| Slint, MAUI, Avalonia, Qt Quick, Compose | Nothing — different markup language entirely |
| Dear ImGui / egui / microui | Nothing — no markup at all |

Sciter deserves its own line, and [`html-css-js.md`](./html-css-js.md) has the measured detail. The
decisive fact is in its CSS section: **there is no `display:flex` and no `display:grid`**. Sciter replaces
both with flex units (`*`, `2*`) and the `flow:` property. CSS 2.1 is complete and the practical CSS3
modules are there, but the two layout primitives every modern stylesheet is built on are not — so a
stylesheet written for a browser does not port, it gets rewritten. On top of that the engine adds its own
vocabulary (`behavior:`, `@set`/`style-set`, `@const`/`@mixin`, `@image-map`, vector `path:` images), and
the script side is QuickJS against the Sciter DOM with a NodeJS-shaped stdlib (`@sys`, `@storage`) — no
npm, no `require`, no `localStorage`, no service workers.

That document's own porting checklist is the honest summary of the gap. The practical consequence: an
experienced web developer is productive almost immediately, but an existing React app, a Tailwind build,
or a component library off npm does not run unmodified — Sciter's own bundled `+query` sample, a
700-line reimplementation of basic jQuery, is the tell.

Budget for "authoring UI in a familiar language", not for "reusing our web frontend". This is the
strongest reason to keep watching Ultralight's successors: they aim at browser conformance, which is the
one thing Sciter deliberately does not provide.

### Vendor risk and bus factor

Since this is the axis most likely to decide the project over a five-year horizon, and the one no
feature table shows:

| | Risk shape |
| --- | --- |
| **Sciter** | Single maintainer, closed binary core, GitHub presence archived (see [above](#sciters-own-health)). Cannot be forked or patched by anyone else. Highest concentration risk in this document — mitigated only by the fact that it currently ships weekly |
| Ultralight | Same shape, but the shell has already stopped moving. The failure mode Sciter's profile *could* become |
| Gameface, NoesisGUI | Commercial vendors, closed, but corporately staffed rather than one person. Risk is pricing and discontinuation, not abandonment |
| CEF, Chromium, WebKit/WPE, Qt | Effectively unkillable — multiple funded organisations, permissive or LGPL licences, forkable |
| Servo, Ladybird | Foundation/nonprofit stewardship, open source, forkable. Risk is immaturity, not disappearance |
| Tauri, Slint, Avalonia, Compose, Flutter | Company- or foundation-backed open source. Forkable, active communities |
| RmlUi, litehtml, Clay, microui | Small maintainer teams, but genuinely open — you can vendor the source and carry it yourself, which is the whole difference |

The asymmetry worth internalising: every open-source option on this list can be forked and carried
forward by whoever needs it. Sciter cannot. That is not an argument against it — it is the price of the
25MB binary that does what nothing else in its size class does.

### DevTools and accessibility

Two practical axes that only surface once you build something real:

- **Debugging.** Sciter ships an inspector and a script debugger (`inspector` from the SDK, over its own
  debug protocol) — genuinely useful, but not Chrome DevTools. Anything browser-based (CEF, Electron,
  Tauri, Photino, webview.h) gives you the full, familiar toolchain including network inspection,
  profiling and source maps. RmlUi/litehtml/Blitz have far less again.
- **Accessibility.** Every own-renderer option in this document is weak here — Sciter, Ultralight, RmlUi,
  Blitz, Slint, Flutter and ImGui all have to re-expose a native accessibility tree per platform, and
  coverage is partial at best. The options that wrap real native controls (MAUI, and to a lesser extent
  Qt Widgets) get screen-reader support for free; the ones that wrap a real webview (Tauri, CEF,
  Electron) inherit the browser's mature accessibility layer. If a screen reader is a requirement rather
  than a nice-to-have, that consideration outranks most of this document.

### WASM and immediate-mode

ImGui/egui/microui are fast because they skip the retained DOM and the CSS cascade entirely — draw calls
every frame, layout done by hand or a thin flex helper. That is the trade against Sciter: give up
declarative HTML/CSS authoring, get a much smaller and simpler engine.

"WASM" is not one axis — it splits on where the sandbox boundary sits:

- **In the browser.** The wasm blob is a browser tab's guest, same sandbox as any web page — egui-on-wasm,
  Datastar's SSE-driven DOM (no wasm at all, see below), Odin's `js_wasm32` target. Distribution is a URL;
  the browser is the runtime you don't ship.
- **As a local app, still sandboxed.** Orca: the wasm blob *is* the app, run by a dedicated native host
  that provides the sandbox instead of a browser providing it. No URL, no tab, but still capability-gated.
- **Not sandboxed at all.** `freestanding_wasm32` / `wasi_wasm32` used as a portable compile target rather
  than a security boundary — closer to "wasm as a CPU architecture" than "wasm as a sandbox."

Odin's own WASM targets, checked against the compiler repo and forum: `js_wasm32` (browser + JS glue,
canvas), `freestanding_wasm32`, `wasi_wasm32` — all community-carried, thinner than Rust's
wasm-bindgen ecosystem (no shipped equivalent of egui-web in `vendor`).

### Mobile

Checked against each project's own site/repo rather than assumed. The honest read: **small + fast +
mobile + HTML/CSS + in-process native access** is the combination nothing here hits. Drop the HTML/CSS
requirement and Compose or Flutter cover it; drop the in-process requirement and Tauri covers it; drop
"small" and MAUI covers it. Lynx is the interesting near-miss — own engine, CSS, JS, mobile-first,
production-proven — but it is a heavyweight build with no single-`.so` embedding story, so it trades away
"small" and "bindable" instead.

| | Mobile status |
| --- | --- |
| Sciter | Headers are portable (`sciter-x-primitives.h` has `ANDROID`/`IOS` branches, per [`ENGINE.md`](./ENGINE.md#mobile)), but no `wing::` backend is built and no mobile binary is vendored here. Not usable today |
| Ultralight | Desktop + consoles only; [own site](https://ultralig.ht/) says "mobile coming soon" |
| Lynx | Mobile-first by design — iOS/Android are the primary targets, desktop secondary. The only own-HTML-engine option here with a real mobile story |
| RmlUi / litehtml / Blitz | No packaged mobile story; portable C++/Rust, so technically buildable, but you supply the platform layer |
| CEF / Electron / NW.js | No mobile. CEF is desktop-only; Android's own WebView is a separate thing entirely |
| Tauri | Real: iOS/Android stable API since 2.0 (Oct 2024), WKWebView / Android System WebView. Desktop production-grade, mobile stable-API-but-not-all-plugins-ported |
| Slint | iOS is a tech preview (1.12+), Android shipped (1.5+) — **Rust bindings only**, C++/JS bindings have no mobile port |
| Compose Multiplatform | Android is first-class (it *is* the Android UI toolkit), iOS stable since 1.8, desktop mature. Strongest "one codebase everywhere" story after Flutter — at the cost of the JVM/Kotlin-native runtime |
| .NET MAUI | Mobile-first by design, most mature native-control story here, but heaviest |
| Avalonia | iOS/Android in beta, actively invested in through 2026, one Skia renderer shared with desktop — but beta, and .NET |
| Qt | iOS/Android supported for years, commercially or LGPL. Mature but heavy |
| Dear ImGui / egui / microui | No first-class mobile target; embedded ad hoc via custom backends |
| Flutter | Mobile is the original target, most mature of all — at the cost of its own Dart runtime, not "small" |
| Orca | Windows + macOS only, no mobile |

## Native access, real widgets, and no HTML/CSS/JS

The mirror image of [the sandboxed question](#sandboxed-small-fast-and-reachable-from-odin): keep the
in-process native access Sciter gives you, keep a widget stack worth the name, and drop the web
languages. Filtering the whole document against those three at once removes more than it looks like it
should. Start from the "same process, no sandbox" family in
[Native FS / API access](#native-fs--api-access), then drop the HTML engines (Sciter, Ultralight, RmlUi,
litehtml, Blitz) and the foreign runtimes (.NET, JVM, Dart). What survives:

| | Widget stack | From Odin | The bill |
| --- | --- | --- | --- |
| **Qt Widgets / Qt Quick** | The best here, and not close: text entry with IME and bidi, tables, trees, dialogs, model/view — plus **screen-reader support for free** in Widgets, since they wrap real native controls. The only row in this table that clears [the accessibility bar](#devtools-and-accessibility) | C++ only → hand-written shim, maintained forever against their API | You ship a whole framework, not a library. LGPL-3.0 or commercial |
| **Slint** | `std-widgets`: button, line edit, list view, combo box, scroll view, tabs, spin box, slider. Real, moderate, not app-complete | **No C API** (verified — `api/` holds `cpp`, `rs`, `node`, `python`, `slint-sc`, `wasm-interpreter`) → C++ shim | Under 300KiB runtime, own renderer, identical layout everywhere, designer-editable `.slint` markup. Royalty-free licence: free, attribution required, **not** embedded systems |
| **Dear ImGui** | Widest of anything actually reachable from Odin — tables, trees, multi-select, docking, plots, colour pickers, menus. Weak exactly where Qt is strong: IME, bidi, i18n, accessibility, and the visual register is "tool", not "application" | `dear_bindings` / `cimgui` → generated C API, third-party Odin bindings. [Below](#getting-dear-imgui-into-odin) | Immediate mode, so this is also the answer to the next section. A C++ build step |
| **NoesisGUI** | XAML, full widget set, games-oriented | C API exists | Closed, commercial, per-title. The same single-vendor concentration risk as Sciter, [with the same shape](#vendor-risk-and-bus-factor) — you are trading one closed binary for another |
| **RmlUi** *(borderline)* | Real form controls, data binding, **no JS** (Lua optional) | C++ → shim | Only half-qualifies: the markup is HTML/CSS-*shaped*, so it fails "no HTML/CSS" while passing "no JS". And you still supply the renderer and the font stack |

The shape of that table is the finding. **Nothing offers a rich widget stack behind a C ABI.** Rich
widgets live in C++ frameworks, and every C++ framework charges the same toll — a shim you write and
then maintain. The options with a usable C boundary (ImGui, Nuklear, raygui, microui, Clay) are all
immediate-mode, and all trade widget depth for it. That is not a coincidence, and the next section is
why.

## Immediate mode, in detail

The API-shape question, asked separately from the sandbox and markup ones because it cuts across both:
what does a *more immediate-mode-like* experience cost when native access is a given?

Immediate mode means no retained tree that you mutate and the engine reconciles. You call
`if button("Save") { ... }` inside your frame loop; the widget's identity comes from a hashed id, its
state lives in one context struct, and its output is a draw list. [Clay](#clay-in-detail) is the same
authoring model with the widget half removed.

### The widget ladder

Immediate mode is not one point on the spectrum. Four rungs, verified by reading each project's own
source or Odin binding rather than its feature page:

| | Widgets it actually ships | Read from |
| --- | --- | --- |
| **`vendor:microui`** | Twelve: `text`, `label`, `button`, `checkbox`, `textbox`, `slider`, `number`, `header`, `treenode`, `begin_window`, `begin_popup`, `begin_panel`. **No** combo box, list, table, menu bar, tabs or radio | `vendor/microui/microui.odin` in the local Odin tree |
| **`vendor:raylib` + raygui** | Roughly thirty, and a genuinely different tier: `GuiTabBar`, `GuiScrollPanel`, `GuiComboBox`, `GuiDropdownBox`, `GuiSpinner`, `GuiValueBox`, `GuiListView`/`GuiListViewEx`, `GuiMessageBox`, `GuiTextInputBox`, `GuiGrid`, `GuiToggleGroup`, `GuiProgressBar`, `GuiStatusBar`, four colour pickers, styling and tooltips. **No** tree view, no table, no docking | `vendor/raylib/raygui.odin` in the local Odin tree |
| **Nuklear** | Between the two, plus charts, groups, and a property/tree system. Single C89 header, ~18kLOC, no dependencies — "not even the standard library if not wanted", per its own README | the project README |
| **Dear ImGui** | The top rung: tables with sorting/resizing/freezing, trees, docking, multi-viewport, plots, drag-and-drop, an id stack deep enough for real editors | the project's own docs and demo |

The interesting part is that the ladder is *also* a binding-effort ladder in reverse. microui and raygui
are already in `vendor`, Nuklear is one header away, and ImGui — the only rung with an app-grade widget
set — is the one that needs a C++ toolchain.

### Freshness

Same method as everywhere else in this document: default-branch commits in the trailing 90 days, counted
with `jq length` over the **paged** commits endpoint, as of 2026-08-12. The
[one-liner warning](#ultralights-actual-health-and-whats-more-alive-in-the-same-niche) applies here too —
ImGui at 173 commits would have silently reported the 100-commit cap.

| | Pushed | Commits/90d | Stars | Licence | Latest release |
| --- | --- | --- | --- | --- | --- |
| `ocornut/imgui` | 2026-08-07 | 173 | 75.6k | MIT | v1.92.9b, 2026-07-31 |
| `raysan5/raygui` | 2026-08-05 | 75 | 5.1k | Zlib | 5.0, 2026-07-20 |
| `Capati/odin-imgui` | 2026-08-01 | 39 | 44 | MIT | none — pin a commit |
| `cimgui/cimgui` | 2026-08-12 | 24 | 1.9k | MIT | **v1.53.1, 2018-01-02** |
| `Immediate-Mode-UI/Nuklear` | 2026-08-08 | 21 | 11.3k | NOASSERTION | v4.13.3, 2026-05-05 |
| `nicbarker/clay` | 2026-05-20 | 8 | 17.8k | Zlib | v0.14, 2025-06-06 |
| `rxi/microui` | 2024-08-13 | 0 | 6.8k | MIT | none, ever |
| `ThisDevDane/odin-imgui` | 2023-07-08 | 0 | 69 | MIT | **archived** |

Three of those rows need reading rather than scanning:

- **Dear ImGui is the healthiest thing in this entire document.** 173 commits in ninety days, 75.6k stars,
  tagged releases on a monthly cadence, MIT, a single maintainer of long standing but a large contributor
  base and no closed core. Against Sciter's 17 commits and unforkable binary, that is the opposite risk
  profile in every respect.
- **`cimgui`'s last *release* is from 2018** while its last *commit* was today. It is not stale — it
  tracks ImGui continuously and people consume it from `master`. But anyone filtering the field by release
  tags would write it off, which is
  [the `pushed_at` trap](#ultralights-actual-health-and-whats-more-alive-in-the-same-niche) running the
  other way round.
- **`rxi/microui` upstream has been idle since August 2024 and never cut a release** — and it does not
  matter here, because `vendor:microui` is an Odin-native **source port** (header credits rxi, oskarnp and
  gingerBill), maintained in the Odin repository. You depend on the Odin compiler's tree, not on rxi.

Clay is where [its own section](#clay-in-detail) left it: 8 commits, nothing since 2026-05-20, still
usable because a vendored single header cannot rot out from under you.

### Getting Dear ImGui into Odin

Worth its own subsection because the obvious path is a trap, in the same way the archived GitHub
repositories are for [Sciter](#sciters-own-health) and
[Ultralight](#ultralights-actual-health-and-whats-more-alive-in-the-same-niche).

**The binding most search results point at is archived.** `ThisDevDane/odin-imgui` is the top hit by
stars (69), and it was last pushed on 2023-07-08 with `archived: true`, pinned to ImGui v1.82 — a 2021
release. `alektron/imgui-odin-backends` (22 stars) is not archived but has had no commits in ninety days.

**The live one is `Capati/odin-imgui`** — 39 commits in ninety days, tracking **v1.92.9b-docking**, MIT.
Read out of its README rather than assumed:

- It generates its C API with **`dear_bindings`**, not `cimgui`. Both exist and both work; `dear_bindings`
  is the newer, metadata-driven generator and is what an actively maintained binding tends to pick today.
- Backends are bound for `glfw`, `sdl2`, `sdl3`, `sdlgpu3`, `sdlrenderer2/3`, `opengl3`, `vulkan`, `wgpu`,
  `metal`, `dx11`, `dx12`, `osx` and `win32` — which is close to a one-to-one match with Odin's own
  `vendor` set, so the window and GPU layer is already there.
- It publishes **no releases**. Pin a commit.

The cost that the "directly bindable" framing hides: **it ships no prebuilt libraries.** You build C++
ImGui yourself, via **premake5 + Python 3 + `make`** (and glibc 2.38 or newer on Unix), selecting backends
at generation time:

```sh
premake5 --backends=glfw,opengl3 gmake
cd build/make/linux && make config=release_x86_64
```

Compare [Clay](#clay-in-detail), which ships `linux/clay.a`, `windows/clay.lib`, `macos`, `macos-arm64`
and `wasm/clay.o` prebuilt, and compare Sciter, which ships a `.so` you `dlopen`. ImGui-from-Odin is a
build-system dependency in your project, and that is the real difference between it and everything else
on the ladder — not the binding quality, which is fine.

### An immediate-mode feel *with* markup

The question splits once markup is allowed back in, because "immediate mode" and "HTML/CSS" are not
actually opposed — what they are opposed to is *a retained tree you mutate from the host across a
boundary*.

| | How close it gets |
| --- | --- |
| **[Clay](#clay-in-detail)** | The closest thing to immediate-mode *layout*: declare the tree every frame in Odin, get render commands back, no cascade to invalidate. No widgets, no text stack — you supply `SetMeasureTextFunction` (`vendor:kb_text_shape` or `vendor:fontstash` will do it) and every control |
| **RmlUi** | Host-driven document with data binding and a real cascade, **no JS engine required**. The nearest thing to "CSS styling, immediate-ish authoring, native access". Costs a C++ shim plus a render backend |
| **Blitz** | Precisely this model — own HTML/CSS engine, host language drives the DOM, no JS — and unreachable: Rust ABI, self-declared pre-alpha |
| **Sciter** | **Not this, and the distinction matters.** From Odin you drive a *retained* DOM through the DOM API. [Reactor](./reactor.md) does give React-style declarative re-render with diffing, which is the immediate-mode authoring feel — but it runs in QuickJS, in the document, not in your host language. Sciter's answer to "immediate mode from Odin" is "write it in JS instead" |

That last row is the honest limit of what these bindings can offer on this axis. Sciter's architecture
puts the declarative-rerender ergonomics on the script side of the engine, by design.

### The other direction: Sciter *inside* an immediate-mode app

Worth separating from the row above, because it is a different question with a better answer. Sciter has a
windowless mode — `SciterProcX` and the `SXM_*` messages — in which it renders the document into a pixel
buffer or GPU texture **you** allocate, which is exactly the shape an ImGui `Image()` or a raylib
`DrawTexture` call wants. So a Sciter pane can live inside a frame loop somebody else owns.

Measured rather than assumed, in [`EMBEDDING.md`](./EMBEDDING.md) and
[`spike/windowless`](../spike/windowless/main.odin), against 6.0.4.9 on Linux x64. The short version:
rendering, CSS, QuickJS, the DOM API, hit-testing and `SciterEval` all work with no window in the
process — but `SXM_RESOLUTION` crashes the engine and `SXM_MOUSE` is never handled, so today it is a
*display* embedding rather than an interactive one.

The size argument does not survive the arrangement, though: a 25MB engine inside a tens-of-KB
immediate-mode UI inverts the reason most people reach for immediate mode.

### Summary

| If you want | Take |
| --- | --- |
| Immediate-mode API *and* an app-grade widget set, native, from Odin | **Dear ImGui** via `Capati/odin-imgui` — and accept premake5 + Python in your build |
| Immediate mode with zero friction, tool-grade widgets | **`vendor:microui`** — an import statement, twelve widgets |
| Immediate mode, wider widgets, still zero external build | **`vendor:raylib` + raygui** — roughly thirty controls, renderer included |
| A single-header C dependency you vendor and own outright | **Nuklear** — write the bindings with `odin-c-bindgen`, no shim, no build system |
| Immediate-mode *layout* with your own renderer and widgets | **Clay** — [as its section says](#the-honest-read), layout is the solved part |
| Real widgets, native, no HTML — and budget for a shim | **Qt Widgets** (best widgets, heaviest) or **Slint** (smallest, moderate widgets) |
| HTML/CSS authoring *and* no boundary | **Sciter** — but the immediate-mode ergonomics live in JS, not in Odin |

## Clay, in detail

Clay earns a section rather than a table row because it is the only alternative here that is *already
bound for Odin by its own authors*, and because the comparison with Sciter is more interesting than
"HTML or not". Everything below was read out of `bindings/odin/clay-odin/clay.odin` at
`nicbarker/clay@main` — 601 lines, one file — rather than from the project's marketing.

### What it is

A **layout engine**, not a UI toolkit. You declare a tree each frame; it returns a list of drawing
instructions; you draw them. There is no renderer, no font rasteriser, no widget set and no event loop
inside Clay.

This block is Clay's API, not this project's, so unlike every other Odin block in these guides it is not
mirrored in [`docs/snippets/`](./snippets/) — there is nothing here for `just check` to compile it
against.

```odin
Clay.BeginLayout()
// `UI` is a proc group: pass an ElementId for a stable one, or call it bare for an auto id. It
// returns the proc that takes the declaration, which is what makes the `if` + block nesting work.
if Clay.UI(Clay.ID("sidebar"))({
    layout = { sizing = { width = Clay.SizingFixed(200), height = Clay.SizingGrow({}) },
               padding = Clay.PaddingAll(16), childGap = 8,
               layoutDirection = .TopToBottom },
    backgroundColor = PANEL,
}) {
    Clay.TextStatic("Files", { fontId = 0, fontSize = 18, textColor = FG })
}
commands := Clay.EndLayout(delta_time)     // -> ClayArray(RenderCommand)
```

`RenderCommandType` is the whole output vocabulary: `Rectangle`, `Border`, `Text`, `Image`,
`ScissorStart`/`ScissorEnd`, `OverlayColorStart`/`OverlayColorEnd`, `Custom`. Ten cases, and `Custom` is
an escape hatch carrying your own pointer. That is genuinely all a backend has to handle.

Memory is a single arena you size up front (`MinMemorySize`, `CreateArenaWithCapacityAndMemory`), with
a settable `SetMaxElementCount`. No allocator, no per-frame garbage. Errors arrive through an
`ErrorHandler` callback with a typed `ErrorType` — `ArenaCapacityExceeded`, `ElementsCapacityExceeded`,
`DuplicateId`, `PercentageOver1`, `UnbalancedOpenClose` — instead of crashing.

### What it actually gives you

| Area | Clay |
| --- | --- |
| Sizing | `Fit`, `Grow`, `Fixed`, `Percent`, each with min/max constraints |
| Box model | padding (4 sides), `childGap`, borders with per-side widths, corner radii |
| Direction & alignment | `LeftToRight` / `TopToBottom`, child alignment on both axes |
| Floating elements | 9×9 attach points (element corner → parent corner), offset, expand, `zIndex`, attach to parent / element-by-id / root, optional clip to attached parent |
| Clipping & scrolling | per-axis clip, `childOffset` for scroll, `UpdateScrollContainers` with drag-scroll and momentum, `GetScrollContainerData` |
| Text | colour, font id, size, letter spacing, line height, wrap mode (`Words`/`Newlines`/`None`), alignment |
| Images, aspect ratio | image element carrying your texture pointer; `aspectRatio` config |
| Input | `SetPointerState`, `Hovered()`, `PointerOver(id)`, `OnHover` callback, `GetPointerOverIds`, pointer capture vs passthrough |
| Animation | transition configs with properties, enter/exit triggers, sibling ordering, an `EaseOut` helper |
| Debugging | `SetDebugModeEnabled` — a built-in layout inspector, which is more than most immediate-mode libraries ship |
| Performance | `SetCullingEnabled`, a measure-text cache with a resettable word budget |

### What you supply

This is the part that decides it:

- **Text measurement.** `SetMeasureTextFunction` is mandatory — Clay will raise
  `TextMeasurementFunctionNotProvided` otherwise. You own font loading, metrics and shaping.
- **All rendering.** Every rectangle, glyph run, border and scissor rect.
- **Every widget.** There is no button, text input, dropdown, tree, table, scrollbar chrome, focus ring
  or caret. `Hovered()` and `OnHover` are the raw material you build those from.
- **Text editing, IME, selection, clipboard, accessibility, i18n.** None of it exists.

### Against Sciter

| | Sciter | Clay |
| --- | --- | --- |
| What it is | Whole UI engine — parse, style, lay out, paint, script, input | Layout only |
| Shipped size | 25MB `libsciter.so` | Single-header C; prebuilt static libs in the Odin bindings, tens of KB |
| From Odin | Bindings in this repo, over `ISciterAPI` | `bindings/odin/clay-odin/`, authored upstream, prebuilt `linux/clay.a`, `windows/clay.lib`, `macos`, `macos-arm64`, **`wasm/clay.o`** |
| UI language | HTML + CSS + JS, hot-reloadable, designer-editable | Odin code. Recompile to change the UI |
| Model | Retained DOM, event-driven | Immediate mode — rebuild the tree every frame |
| Layout | CSS cascade, `flow:`, flex units, `@media`, style sets | One flexbox-ish model, no cascade, no selectors, no stylesheet |
| Text stack | Full: shaping, bidi, `@font-face`, rich text, selection, editing | You provide a measure callback and draw the glyphs |
| Widgets | `<input>` family, `<select type=tree>`, menus, dialogs, scrollbars — all native behaviors | None |
| Scripting | QuickJS, ES2020, [Reactor](./reactor.md), Signals | None — the host language is the only language |
| Graphics | Skia, canvas superset, SVG, filters, transitions | Ten render commands you rasterise |
| Debug tooling | DevTools-style inspector over a socket | Built-in layout debug view |
| Rendering backend | Bundled | Yours — or one of Clay's examples (raylib, SDL, WebGL, terminal) |
| Vendor risk | Closed binary, one maintainer, unforkable | zlib, source vendorable, forkable |
| Liveness (90d) | 17 commits, weekly releases | 8 commits, none since 2026-05-20 |
| Accessibility | Partial, engine-provided | Nothing, and no path to it |

### The honest read

Clay is not an alternative to Sciter; it is an alternative to *the layout box* inside Sciter. Choosing it
means writing the renderer, the text stack and every widget yourself, in exchange for deleting a 25MB
proprietary dependency and its single-maintainer risk. For a tool UI with a dozen controls and a
graphics backend already in the project — a game editor, a debug overlay, something already drawing with
raylib or SDL from Odin's `vendor` — that trade is very good, and the wasm target is a real bonus.

For an application UI with forms, text entry, menus and tables, the widget gap is not a weekend of work;
it is the reason toolkits exist. Sciter hands you `<select type=tree>` and a CSS file. Clay hands you
`Hovered()`.

Worth stating plainly since Clay's 17.8k stars invite it: **this is not a "which should I use" decision**
with a single answer, because the two do not overlap much. What Clay does do is set a useful floor —
if the answer to "what would we lose by dropping Sciter" is "layout, and we'd write the rest", Clay is
proof that the layout part is a solved, small, vendorable problem.

## Hypermedia: Datastar

A different axis entirely, worth naming because it inverts the whole premise above: instead of shipping
a UI engine to the client, put the state on the server and ship the smallest possible client.
[Datastar](https://data-star.dev/) — plain JavaScript, **11.76KiB** total, no build step. `data-*`
attributes for reactivity, signals for the client-local part, HTML fragments or SSE (`text/event-stream`)
for the server-driven part. Backed by a nonprofit (Star Federation), SDKs in Go/Python/TypeScript/Rust/etc.

Datastar's own site describes the core as plain JS with no WebAssembly — noted because the claim
"Datastar is now wasm" circulates and the primary source doesn't support it.

Not comparable to Sciter on the size/native-access/mobile axes above at all — it has no native app story,
no filesystem access, no offline mode without a server. It's the opposite bet: minimize the client instead
of maximizing what a native shell can do, useful context for *why* Sciter's "full DOM+JS in-process"
design is a deliberate choice rather than the only way to use web tech for UI.

## Orca

The one genuinely Odin-relevant find among the sandboxed options: [Orca](https://github.com/orca-app/orca)
is a sandboxed WASM runtime for GUI apps — "Handmade Electron." Own canvas-based rendering API (not
HTML/CSS), capability-gated file API, apps distributed like web apps without a browser. Odin gained a
first-class target for it in 2026: `-target:orca_wasm32`, bindings at `core:sys/orca`.

It is the structural opposite of Sciter on two of the three axes above — sandboxed instead of native, own
canvas API instead of HTML/CSS — which is what makes it worth tracking rather than adopting.

Freshness, checked directly against the GitHub API rather than assumed from the announcement date:

```sh
curl -s "https://api.github.com/repos/orca-app/orca" | grep -E '"pushed_at"|"stargazers_count"|"archived"'
# pushed_at: 2026-07-23, stargazers: 632, archived: false

curl -s "https://api.github.com/repos/orca-app/orca/releases?per_page=100" | grep '"tag_name"' | grep -v test-release
# (empty)
```

- Alive: last push 2026-07-23, not archived.
- Slowing: 7 commits in the trailing 90 days, against a markedly busier preceding quarter.
- Recent commits are internal renames (`oc_list_xxx_entry` → `elt`), not feature work.
- **Never cut a real version release** — only auto-generated `test-release-*` CI tags exist, back to
  2025-04. No semver tag, ever.
- Windows and macOS only. No Linux.

Read: maintained, not dead, but pre-1.0, cooling, no ship date, and missing the platform this project
targets first. A watch item, not a dependency.

## Sandboxed, small, fast, and reachable from Odin

The combination worth asking about directly, since it is the one Sciter *doesn't* satisfy — Sciter is
small-ish and Odin-reachable, but deliberately not sandboxed. Filtering the whole document against all
four constraints at once produces a short list and one structural surprise.

### Sandboxed and Clay cannot be combined for a native app

Not a gap in the options — a consequence of what the words mean here. "Sandboxed" in this document means
the UI content runs inside something else's process boundary: a browser, a webview, or a wasm host. In
all three, the UI language is fixed by the host — HTML/CSS/JS for the first two, the host's own canvas
API for Orca. [Clay](#clay-in-detail) emits render commands for a native graphics backend *you* own, so
there is nowhere to put it inside a sandbox someone else defines.

Clay becomes available again only when **your Odin code is the thing inside the sandbox** — i.e. when
you compile to wasm. That splits the answer into two routes that share no components.

### Route A — sandboxed content, Odin stays native

The UI is HTML/CSS/JS in a browser or webview; Odin is the host on the other side of a bridge. Clay is
irrelevant here.

| | Verdict |
| --- | --- |
| **[WebUI](#webui-in-detail)** | **Best fit.** Pure C, few-KB library, official (if stale) Odin bindings, no GTK/WebKit build dependency, strongest isolation of the three because the page runs in a separate browser in a private profile. Costs a browser dependency at runtime and a beta-only release history |
| `webview/webview` | Directly bindable from one C header, but on Linux drags in **GTK + WebKitGTK** at build and run time — the toolkit dependency this project exists without — and gives you three different rendering engines across platforms. No Odin bindings |
| Neutralinojs | No bindings needed at all (local WebSocket protocol), but NOASSERTION licensing, an extra process, and the least control of the three |

### Route B — Odin inside the sandbox, Clay as the toolkit

| | Verdict |
| --- | --- |
| **Odin `js_wasm32` + Clay** | Clay's Odin bindings ship a **`wasm/clay.o`**, so this actually works: browser sandbox, tiny, Clay does layout, everything in Odin. You still write the canvas/WebGL backend and the text-measure callback. The catch is not technical — it is a web page, so no filesystem and distribution is a URL |
| Orca | The **only option in this document that satisfies all four constraints simultaneously** — sandboxed by design, small, capability-gated file access, and a first-class Odin target (`-target:orca_wasm32`, `core:sys/orca`). And it is unavailable here: Windows and macOS only, no Linux, pre-1.0, never released, 7 commits/90d |

That Orca is the clean answer and cannot be used is the honest summary of this axis.

### When the sandbox and the local logic are actually needed

Route A has a property worth noticing: **a WebUI or Neutralino app is a client/server application in
which the server happens to be your own process.** Having chosen it, you inherit the entire hypermedia
argument — the same one [Datastar](#hypermedia-datastar) is built around, and the same one that plays
out between server-rendered HTML and single-page applications.

The usual framing of that debate is misleading, and the confusion carries directly into this decision.
It is not "server state versus client state". Every architecture keeps UI-only state on the client —
which panel is open, what is hovered, which row is selected, what is focused, what is optimistically
shown before confirmation. Hypermedia advocates do not dispute that; Datastar ships signals precisely
for it. The real axis is narrower:

> **Does the interaction loop have to cross a boundary, and what does that boundary cost?**

Which makes it a latency question, and the boundaries in this document differ by orders of magnitude:

| Boundary | Order of magnitude | Fits inside a 60fps frame? |
| --- | --- | --- |
| In-process call — Sciter's `sciter::om`, native ImGui/Clay | sub-microsecond | Thousands of times over |
| Localhost socket — **WebUI**, Neutralino | tens of microseconds to ~1ms | Yes, comfortably |
| Process-sandbox IPC — CEF, Electron, Tauri's `invoke` (JSON-serialized, so payload size dominates) | ~microseconds to ~1ms | Yes |
| Network round trip — Datastar and any real hypermedia app | ~10–200ms | No, not once |

(Orders of magnitude, from the architectures rather than measured here — unlike the engine figures
elsewhere in this document, which were measured. The 16.7ms frame budget is arithmetic: 1/60s.)

The conclusion that matters: **the objection usually raised against hypermedia — "a round trip per
interaction is too slow for a rich UI" — largely does not apply to Route A.** A localhost round trip is
two to four orders of magnitude cheaper than an internet one, and disappears inside a frame. Most of
what makes server-driven UI feel sluggish on the web is simply absent when the server is a process on
the same machine.

What *does* survive the move to localhost, and is the real cost of Route A:

- **You must serialize.** Every value crossing the boundary is encoded and decoded. Pointers, handles
  and large buffers do not cross; they get copied or referenced by id.
- **You cannot do per-frame work across it.** One round trip inside a frame is fine. Sixty round trips
  per second, each carrying a re-serialized data structure, is a different proposition — and dragging,
  resizing, canvas painting, timeline scrubbing and data-driven animation are exactly that.
- **You cannot share memory.** A large table, an image buffer or a mesh lives on one side. Interactions
  that need it on the other side pay for it repeatedly.

So the genuine requirement for local logic and no boundary is not "the app is complex" or "the app is
interactive". It is one of:

1. **Sub-frame interaction over shared data** — drag, scrub, paint, live-resize, direct manipulation of
   something big.
2. **Data too large or too pointer-shaped to serialize per interaction.**
3. **Native APIs with no serializable shape** — file handles, devices, GPU resources.
4. **A hard no-runtime-dependency guarantee** — no browser present, offline, locked-down machine.

If none of those hold — forms, CRUD, settings, wizards, dashboards, navigation, anything whose loop runs
at human pace — the boundary is free, and Route A gives you a sandbox, a few-KB dependency and no engine
to ship. That is a genuinely better trade than a 25MB proprietary binary.

If one of them holds, the boundary is the whole problem, and the choice is between Sciter (no boundary,
HTML/CSS/JS, 25MB, closed vendor) and a native toolkit (no boundary, no markup, small, and you write
more of it — [Clay](#clay-in-detail) plus `vendor:raylib` or `vendor:sdl3`).

### Summary

| If you need | Take |
| --- | --- |
| Sandbox + tiny + Odin + native window, human-paced interaction | **WebUI** via `odin-webui`, carrying the bindings yourself |
| Sandbox + Clay as the toolkit, and a URL is acceptable delivery | **Odin `js_wasm32` + Clay** (`wasm/clay.o`) |
| All four constraints properly satisfied | **Orca** — and wait for Linux support, or pick something else |
| Sub-frame interaction, big local data, native APIs — and HTML/CSS authoring | **Sciter**, which is why it has no sandbox |
| Sub-frame interaction, and no need for HTML/CSS | **Clay + `vendor:raylib`/`vendor:sdl3`** — smallest, fastest, entirely in-tree |

## Dropping the Odin constraint

The same question with the binding requirement removed — sandboxed, fast, cross-platform, any language.
It mostly does collapse into the HTML/CSS/JS world, but for a more specific reason than "web won", and
with one escape hatch that is easy to miss.

### There are only three sandbox technologies

That is the whole reason the field feels collapsed. Trustworthy sandboxes were built by browser vendors
and wasm runtimes; nobody else ships one, so requiring a sandbox means adopting somebody else's.

| Sandbox | Provided by | What it confines |
| --- | --- | --- |
| Browser / webview process sandbox | Chromium, WebKit | The UI **content**, from your host process |
| WASM | A browser, or a standalone host (Orca, Wasmtime/WASI) | **Your code**, from the machine |
| **OS-level** — Flatpak, macOS App Sandbox, Windows AppContainer/MSIX, seccomp | The operating system | **Your whole application, whatever toolkit it uses** — but see the caveat below |

The first two drag you into the browser world. The third does not, and it is routinely forgotten — but
it is also **not one sandbox**. It is three unrelated ones with a shared goal, which matters more than
it first appears:

| | Mechanism | Applies when |
| --- | --- | --- |
| Linux | Flatpak (or Snap): builder manifest, `--filesystem=` grants, xdg-desktop-portal for file dialogs and screen capture | Only if the user installs *that package*. A `.deb` or a tarball is unconfined |
| macOS | App Sandbox: entitlements plist; separately, hardened runtime and notarization | Mandatory for the App Store, optional outside it |
| Windows | AppContainer / MSIX: package manifest capabilities | Mandatory for the Store, optional outside it |

Three manifest formats, three capability vocabularies, three sets of "what breaks once confined" bugs —
file dialogs, IPC, auto-update, GPU access, font enumeration — and three test matrices. Worse for a
security argument: **the confinement only exists if the user installed through that channel.** A
side-loaded build of the same application is unconfined on all three platforms.

The browser and wasm sandboxes have neither property. One model, everywhere, always on, regardless of
how the application was delivered. If cross-platform consistency is a floor requirement rather than a
preference — and for most application developers it is — that uniformity is the entire point, and it is
what the OS-level route cannot offer.

Which leaves a real gap worth naming: **there is no mature cross-platform sandbox that is not a
browser.** The slot belongs to wasm hosts with one capability model everywhere, and in practice it is
empty — Orca is pre-1.0, unreleased and missing Linux; WASI has no UI story at all. That absence is why
the field collapses toward browser engines, more than any property of HTML or CSS.

### The threat model decides this, not the toolkit

Two questions that look identical and have opposite answers:

- **Untrusted content** — you render HTML/JS you did not author: plugins, user scripts, remote pages,
  anything user-supplied. You need an *in-app content* boundary, so you need a browser engine or a wasm
  host. This genuinely does collapse to HTML/CSS/JS, and it is the case Sciter explicitly does not serve
  — see [Security patching](#security-patching-the-cost-of-no-sandbox).
- **Untrusted app, trusted content** — you wrote every line of the UI, and you want blast-radius limits
  or a store's confinement requirement satisfied. Then OS-level sandboxing does the job with **no change
  to the UI architecture**: Qt, Slint, Flutter, Avalonia, Dear ImGui, Clay + SDL, or for that matter a
  Sciter app, all run inside Flatpak / App Sandbox / AppContainer at full native speed. The UI stays
  cross-platform; the *confinement layer* does not, and that is the bill — three manifests and three
  capability models, as above. It is close to free only when you are already shipping through the stores
  that demand those manifests anyway.

Most desktop applications are the second case and reach for the first anyway. That mismatch is where a
good deal of "why is this Electron app using 400MB" comes from.

### What actually costs speed

JS execution is not the bottleneck people assume. Modern JITs are within a small multiple of native, and
typical UI work is not compute-bound. The real costs, roughly in order:

1. **Style and layout recalculation over a large DOM** — the dominant cost, and not JavaScript at all.
2. **Memory baseline** — a bundled Chromium starts in the hundreds of MB before your code runs.
3. **Cold start** — spinning up that runtime.
4. **GC pauses** — what turns a good average frame time into visible stutter.
5. **The serialization boundary** — fine once per interaction, fatal once per frame. Same argument as
   [the previous section](#sandboxed-small-fast-and-reachable-from-odin).

Where a browser engine genuinely loses: sustained 60/120fps over large scenes, very large data grids
without virtualization, low-latency input (drawing, audio, instruments), predictable frame timing, and
memory-constrained targets.

Items 1, 4 and 5 are the ones usually misdiagnosed, so they are worth taking apart.

#### Why style and layout cost what they do

Not because DOM nodes are heavy objects. Because **style and layout are global, interdependent
computations with poor locality**, and because the invalidation rules propagate much further than the
code that triggered them suggests.

**Style recalculation** answers "which declarations apply to this element, and what is its computed
style". Three things make it expensive:

- **Selectors match right-to-left.** For `.sidebar .item span`, the engine starts at each candidate
  `span` and walks *up* the ancestor chain, because the rightmost part is the most selective. Cost
  therefore tracks tree depth and how many rules share a rightmost key, not the number of elements you
  think the rule "is about".
- **The cascade is a sort plus an inheritance walk.** Matched declarations are ordered by origin,
  specificity and document order, then merged with the parent's computed style to resolve inherited
  properties and relative units. Every element gets its own computed-style struct out of this.
- **Invalidation is subtree-shaped.** Toggling a class on a container can dirty everything beneath it;
  descendant and sibling combinators mean a change here forces re-matching *there*. Custom properties
  are the sharpest edge — changing one variable on `:root` invalidates every element that inherits it,
  which is usually the whole document.

The engine only restyles *dirty* elements, so cost scales with what you invalidated. Bad invalidation
patterns invalidate everything, and that is the difference between a UI that scales to 50,000 nodes and
one that stalls at 5,000.

**Layout** then computes geometry, and it is inherently interdependent: a width change flows into
children, re-wrapping changes their heights, which flows back out to parents and siblings.

- **Some layouts need multiple passes.** Intrinsic sizing (`min-content`, `max-content`, `auto` flex
  bases, `auto` grid tracks, tables) requires measuring children before the parent can size itself, so
  the tree gets walked more than once.
- **Text is the expensive inner loop** — line breaking, font fallback, shaping with ligatures, kerning
  and bidi. For text-heavy UI this frequently dominates everything else.
- **Reading geometry forces synchronous layout.** This is the classic killer and it is an *access
  pattern*, not an engine flaw. Touching `offsetHeight` or `getBoundingClientRect()` after a write
  obliges the engine to flush pending layout immediately to give a correct answer. Do that in a loop —
  write, read, write, read — and you get N full layout passes in a frame instead of one. "The DOM is
  slow" is usually this.

Which explains why a few hundred lines of layout code can beat a browser engine on a specific UI:
**it isn't doing the general case.** [Clay](#clay-in-detail) resolves fit/grow/fixed/percent in a
fixed number of passes with no selectors, no cascade, no inheritance and no custom properties — so it
has no invalidation problem to get wrong. That is the entire performance story of immediate-mode UI, and
it is a scope argument rather than a cleverness argument. CSS containment (`contain`,
`content-visibility`) exists to buy back some of the same bounded-propagation property inside a browser.

#### GC pauses — yes, but not only JavaScript

The instinct is right: pauses come from garbage-collected languages, and in a browser that means JS.
Two refinements matter for the architecture, though.

**The DOM is a large share of what the collector has to trace.** DOM nodes are native objects with
script wrappers, and a live tree keeps a big cross-language object graph reachable. A document of tens
of thousands of nodes is GC pressure that exists whether or not your own code allocates.

**wasm linear memory is not garbage collected.** That is the underrated reason the canvas + wasm pattern
scales: a document model living in wasm memory is invisible to the JS collector no matter how large it
gets, and it has no DOM wrappers. The usual pitch for wasm is raw compute speed; for UI work the bigger
win is usually *escaping GC and escaping the DOM's object graph*. Note the corollary — the newer
WasmGC proposal reintroduces a collected heap, so this property belongs to linear-memory wasm, not to
"wasm" as a blanket term.

#### Why the serialization boundary costs what it does

Every value crossing a process or language boundary is encoded, copied, decoded and rebuilt on the other
side. Four costs, only the first of which is obvious:

- **CPU for encode/decode**, roughly linear in payload size.
- **Allocation on both sides.** You materialize a second copy of the data — which, on the JS side,
  becomes GC pressure proportional to how chatty the boundary is. Costs 4 and 5 in the list above are
  the same cost seen twice.
- **Loss of referential identity.** Pointers and handles do not cross. Shared subgraphs get duplicated,
  cycles need special handling, and the receiver cannot mutate the original — only ask for it to be
  mutated.
- **The payload-size asymmetry**, which is the one that actually bites: cost scales with *how much data
  you send*, not with *how much meaning changed*. Dragging a slider one pixel can re-send an entire
  model. This is exactly why once per interaction is free and once per frame is fatal.

Browsers provide escape hatches, and their shape confirms the diagnosis: `Transferable` objects move
buffers instead of copying them, and `SharedArrayBuffer` shares memory outright. Both amount to "stop
serializing".

**The JS↔wasm boundary has its own version of this**, and it surprises people. The *call* is cheap —
close to a direct function call. Passing anything that is not a number is not, because wasm cannot hold
a JS reference: strings and objects must be copied into or out of linear memory by hand. A chatty
wasm API taking string arguments can easily be slower than the equivalent plain JavaScript.

**So WASM narrows the compute gap and fixes only some of the rest.** It removes GC pressure for data
that lives in linear memory and it sidesteps the DOM if you render to canvas — but it does nothing for
DOM layout cost if you keep the DOM, it adds a boundary of its own, and in the browser it has no threads
without `SharedArrayBuffer` and the COOP/COEP headers that unlock it.

### The pattern that actually works

The shell falls into HTML/CSS/JS; the hot path should not. Use the browser engine for what it is good
at — sandboxing, portability, tooling, ecosystem — and put the performance-critical surface on
canvas/WebGL/WebGPU with wasm behind it, bypassing the DOM entirely.

The worked example is **Figma**, a browser-based interface-design tool, and it is worth citing precisely
rather than by reputation. From its co-founder's own write-up,
[*WebAssembly cut Figma's load time by 3x*](https://www.figma.com/blog/webassembly-cut-figmas-load-time-by-3x/)
(Evan Wallace, 8 June 2017):

> "our product is written in **C++**, which can easily be compiled into WebAssembly"
>
> "a browser-based interface design tool with a powerful **2D WebGL rendering engine** that supports very
> large documents"

The split is exactly the one recommended above:

| Layer | Built with |
| --- | --- |
| Chrome around the edges — panels, menus, toolbars, dialogs | DOM |
| The design canvas — document model, layout, rendering | C++ compiled to WebAssembly, painted through WebGL, **no DOM** |

The migration numbers in that post are the clearest public measurement of the wasm case: load time
improved **more than 3x regardless of document size**, because wasm **parses around 20x faster than
asm.js**. (A 2017 post, so treat the figures as of that migration; the architecture has persisted.)

The caveat that citation carries, and the reason "just use canvas" is not the easy advice it sounds
like: to get there they wrote **their own 2D renderer and their own text layout engine** — precisely the
things Sciter, or the DOM, hand you for free. It works, at a cost most projects cannot pay.

Which produces the one lesson that transfers to a small project: **once you are writing your own
renderer anyway, the browser stops being the obvious host.** Figma-in-a-tab and
[Clay](#clay-in-detail) + `vendor:raylib` are the same architectural bet — own layout, own paint, no
DOM — differing only in whether a browser wraps the result. If the renderer cost is being paid either
way, the browser buys a sandbox and URL distribution, and charges wasm's constraints and the JS boundary
for them.

The cross-platform caveat is real and checkable rather than folklore: WebKit's own feature registry
(`Source/WebCore/features.json` on `WebKit/WebKit@main`) still lists **WebGPU with
`status: "In Development"`**, while Chromium-family webviews shipped it some time ago. Since WKWebView
and WebKitGTK both derive from WebKit, a WebGPU-based hot path is a Chromium-first strategy today. WebGL
remains the portable floor.

### The options, ranked for this constraint set

| | When it wins |
| --- | --- |
| **Tauri** | Best overall. Ships no engine (sub-600KB core), and v2 has a real security model — a **capabilities** system that grants or denies named **permissions** per window/webview, rather than one global allowlist. Desktop and mobile. Costs: three rendering engines across platforms, and it is **DOM-based** — see the note below |
| **CEF / Electron** | When identical rendering everywhere matters more than 100–150MB. Strongest content sandbox in practice, and the best debugging story of anything in this document |
| **Browser wasm** — egui/Rust, Blazor, Emscripten, Odin's own `js_wasm32` | Maximum sandbox, zero install, URL distribution. Fast when it skips the DOM |
| **OS sandbox + native toolkit** | When the threat model is "confine my app", not "isolate untrusted content", **and** you already ship through platform stores. Fastest option here, and the UI stays cross-platform — but the sandbox itself is three per-platform mechanisms, and it evaporates on side-loaded builds |
| **Orca / a WASI host** | When the sandbox *is* the product, and pre-1.0 is acceptable |

With no language constraint and nothing else known: **Tauri** — but read the next note before assuming
it inherits the performance argument above.

#### What Tauri's bridge does and does not buy

Tauri is **DOM-first**, and nothing about it steers you toward the canvas pattern. It loads your HTML
page into the OS webview; the entire proposition is the web stack on the desktop. Every cost in
[What actually costs speed](#what-actually-costs-speed) — style recalculation, layout, forced
synchronous layout — applies in full. Canvas works inside a Tauri window because it is a webview and
`<canvas>` exists there, but that is you opting out of the thing you chose Tauri for, not a road it
paves.

Its `invoke` bridge is genuinely useful and precisely bounded. Per Tauri's own v2 documentation, the two
IPC primitives are **Events** (fire-and-forget, one-way) and **Commands** (an FFI-like abstraction), and:

> "Because this mechanism uses a **JSON-RPC like protocol** under the hood to serialize requests and
> responses, all arguments and return data must be serializable to JSON."

So it is exactly the boundary described in
[Why the serialization boundary costs what it does](#why-the-serialization-boundary-costs-what-it-does),
with JSON on the wire. That fixes its shape:

- **Good** for coarse-grained work with a small message relative to the compute — parse this file, run
  this query, hash this, decode this image and write it to a path.
- **Bad** for per-frame calls and large results. Encode, copy, decode on every crossing, and cost tracks
  bytes moved rather than meaning changed. No zero-copy binary through plain commands; that wants a
  custom protocol or the asset protocol.

And the limit that matters most: **the bridge offloads compute, not rendering.** Style and layout happen
in the webview regardless. Moving work to Rust does not make a 50,000-row table lay out faster — only
virtualization does, and that is a DOM technique. Tauri can take computation off the web stack; it
cannot take rendering off it.

Which gives a cleaner boundary than "use canvas":

- **The web stack is genuinely worth something to you** — component ecosystem, CSS, accessibility for
  free, iteration speed, hiring → Tauri, accept the DOM costs, mitigate with the ordinary web techniques
  (virtualization, `contain` / `content-visibility`, not reading geometry mid-write), and push coarse
  compute across `invoke`. This is the common case and the right answer for it.
- **Your hot path is genuinely a canvas surface** — design tool, DAW, map, node editor → the webview
  degenerates into a window with a GPU context and a JS interpreter, and nearly everything you picked a
  web stack for stops applying. A native toolkit becomes competitive again on the merits.

One asymmetry worth carrying from the Figma example: its canvas bet also buys **zero-install
distribution through a URL**, which is a large part of what justifies rebuilding a renderer and a text
engine. A desktop-only Tauri app pays that same cost for a much smaller benefit. And per the WebGPU
status noted above, a canvas hot path diverges per platform inside Tauri too — compounding the
inconsistency Tauri already carries rather than escaping it.

Determine the threat model first, because it changes which row applies. If the requirement is confining
your own application rather than isolating content you did not write, **a native toolkit inside
Flatpak / App Sandbox / AppContainer** beats every row above on speed, keeps the UI cross-platform, and
lets you keep Sciter — which is otherwise disqualified by having no sandbox at all.

What it does not do is give you *one* sandbox. You take on a per-platform packaging and capability
matrix, and the guarantee only holds for users who installed through the sanctioned channel. If
"cross-platform" is a floor that covers the security story and not just the UI, that route is out, and
the honest ranking is: Tauri, then Electron/CEF, then browser wasm — all three of which sandbox
identically everywhere because they inherited someone else's engine to do it.
