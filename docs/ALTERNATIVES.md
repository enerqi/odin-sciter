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
| [Tauri](https://github.com/tauri-apps/tauri) / wry | Rust | MIT / Apache-2.0 | Rust — shim required | The mature one. Allowlisted `invoke` bridge, real mobile story |
| [webview/webview](https://github.com/webview/webview) | Single C header | MIT | **Directly bindable** — one C header | No framework around it, which is the point |
| [WebUI](https://github.com/webui-dev/webui) | C library | MIT | **Directly bindable** | Different bet again: uses the user's *installed browser*, bundles no webview at all. Smallest possible shipped artifact, at the cost of depending on whatever browser is present. Steady: 28 commits/90d |
| [Photino](https://www.tryphotino.io/) | .NET | MIT | Not practical | <1MB own binary but needs the .NET runtime present |
| [Wails](https://github.com/wailsapp/wails) | Go | MIT | Not practical | The Go-ecosystem equivalent of Tauri |
| [Neutralinojs](https://github.com/neutralinojs/neutralinojs) | Any language, over a local WebSocket/IPC protocol | MIT | Usable **without bindings** — talk the protocol | Loosest coupling in the table; also the least direct control |
| [saucer](https://github.com/saucer/saucer) | C++ | MIT | C++ — shim required | Modern C++ webview wrapper. 1 commit on the default branch in the trailing 90 days — the repo's recent `pushed_at` reflects other branches, which is exactly the trap `pushed_at` sets |

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
| Dear ImGui / egui | No markup — immediate-mode C++/Rust calls, any graphics backend | MIT (both) | ImGui via `cimgui`; egui is Rust-only | Fast because there's no DOM or CSS cascade to run. egui-on-native has full native access; egui-on-wasm is browser-sandboxed |

### What Odin can already reach today

Worth stating plainly, because it is the actual alternative to these bindings for an Odin project — not
a hypothetical port of a C++ toolkit:

| | Status | Note |
| --- | --- | --- |
| `vendor:microui` | Ships with the compiler (verified in the local Odin tree) | Immediate-mode, tiny, no markup. The zero-friction option |
| `vendor:raylib` (+ raygui) | Ships with the compiler | Game-oriented, includes basic widgets |
| [Clay](https://github.com/nicbarker/clay) | Single-header C, **official Odin bindings** in `bindings/odin/` (verified present), zlib | Flexbox-like retained layout, renderer-agnostic, has an HTML renderer. **Cooling**: 8 commits in the trailing 90 days, all of them before 2026-05-20, so nothing for nearly three months. Usable and dependency-free regardless — it is a single header you vendor. [Full comparison below](#clay-in-detail) |
| `vendor:nanovg`, `vendor:fontstash` | Ship with the compiler | Vector drawing and text, if you are building the UI layer yourself |

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
  written), anything in Odin's `vendor`.
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
