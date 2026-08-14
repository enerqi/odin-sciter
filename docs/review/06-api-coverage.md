# Review: feature coverage and C-API parity

Scope: `external/sciter/include/sciter-x-api.h`, `sciter-x-graphics.h`, `sciter-x-request.h`,
`sciter-om-def.h`, `sciter-x-video-api.h` against `sciter.odin` (generated) and `sciter_app/*.odin`.
Date: 2026-08-13

## The measurement

Counting method, stated so it can be re-run and disputed. Slot names come from the header's own
declaration macro:

```sh
grep -oP 'SCFN\(\s*\K\w+' external/sciter/include/sciter-x-api.h | sort -u
```

Wrapper usage is matched as `\.<Name>\b`, **not** `\.<Name>\(` — the wrapper frequently stores or
forwards a slot rather than calling it directly, and matching on the open paren undercounts. Every
"unwrapped" result below was then read in context to confirm it is genuinely absent rather than
differently spelled, and each header declaration was checked to see whether it is live or commented out.

## Coverage table

### Main table — `ISciterAPI`

| | count |
|---|---:|
| slots declared via `SCFN` in `sciter-x-api.h` | 176 |
| fields in the generated `Isciter_Api` struct | 189 (`version` + reserved + platform padding) |
| verified against the shipped engine by `just example api_map` | 189 checked, 16 null, 0 mismatches |
| generated into `package sciter` | all 176 |
| reached from `package sciter_app` | **163** |
| not reached | 13 — every one a deliberate exclusion, itemised below |

### The thirteen

| slot | category | why not wrapped | recorded in |
|---|---|---|---|
| `SciterSelectElements` | superseded | the `...W` (wide) variant is wrapped as `select_all` | — |
| `SciterSelectParent` | superseded | `SciterSelectParentW` is wrapped as `select_parent` | — |
| `SciterGetElementTypeCB` | superseded | `SciterGetElementType` is wrapped as `tag` | — |
| `SciterProc` | platform | Windows window-proc; no `foreign import` in this design | — |
| `SciterProcND` | platform | same | — |
| `SciterClassName` | platform | Windows window class registration | — |
| `SciterAttachHwndToElement` | feature | native child windows | — |
| `SciterGetElementHwnd` | feature | native child windows | — |
| `SciterEGLGetProcAddress` | feature | windowless EGL | — |
| `SciterEGLSendEvent` | feature | windowless EGL | — |
| `SciterGetViewExpando` | **dead slot** | NULL on every platform on Sciter 6; TIScript-VM leftover | `window.odin:342-346`, `ENGINE.md:256`, `calling-between-odin-and-js.md:334`, `WINDOWS-CHECKLIST.md:71` |
| `SciterGetObject` | **dead slot** | `.OPERATION_FAILED` for every element tried | `api.md:834-836`, `dom.md:565-566` |
| `SciterGetElementNamespace` | **dead slot** | same | `api.md:834-836`, `dom.md:565-566` |

### Graphics sub-table — `SciterGraphicsAPI`

| | count |
|---|---:|
| `SCFN` declarations in `sciter-x-graphics.h` | 73 |
| of those, commented out in the header (`imageGetPixels`, lines 146-148) | 1 |
| live slots | **72** |
| reached from `sciter_app/graphics.odin` | **70** |
| not reached | 2 |

| slot | why not wrapped | recorded in |
|---|---|---|
| `gCreate` | answers `.NOTSUPPORTED` on this engine — `paint_image` is the offscreen path instead | `graphics.odin:8-10` |
| `gGetNativeDC` | deliberately raw-only; the table is exposed for it | `graphics.odin:53-54` |

**Every usable graphics slot is wrapped.**

### Request sub-table — `SciterRequestAPI`

| | count |
|---|---:|
| `SCFN` declarations in `sciter-x-request.h` | 30 |
| of those, inside `#if 0` (`Request`, lines 186-189) | 1 |
| live slots | **29** |
| reached from `sciter_app/request.odin` | **29** |
| not reached | **0** |

### Non-slot interfaces

| interface | shape | status |
|---|---|---|
| SOM (`sciter-om-def.h`) | C structs + function-pointer tables, reached via `SciterSetGlobalAsset` / `SciterGetElementAsset` | wrapped in `som.odin`, both directions (making assets and reading engine ones) |
| video destination | C++ vtable subobject, reached via `asset_get_interface` | wrapped in `video.odin`; the pointer offset is obtained from the engine rather than computed — see `som.odin:405-413` |
| `aux-*.h` helpers (`aux-slice.h`, `aux-cvt.h`, `aux-asset.h`) | C++ header-only templates | not applicable — these are C++ conveniences, and the Odin package provides its own equivalents (`Value`, `string` conversion, `Asset`) |

## Findings

### R6-01 — coverage is effectively complete, and nothing in the tree says so  [severity: major]

**Where:** `docs/SDK-PARITY.md` (386 lines), `docs/PLAN.md`, `README.md`
**What:** the measured result — 163/163 reachable main slots, 70/70 usable graphics slots, 29/29 request
slots, with every exclusion justified — is a stronger claim than any the documentation makes. `PLAN.md`
and `README.md` talk about coverage in terms of *examples* and *tests*; `SDK-PARITY.md` discusses parity
topic by topic without a slot inventory.
**Why it matters:** "is X available?" is the second question a prospective user asks. Right now the
answer requires reading four files and then deriving the six mechanical exclusions, which are written
down nowhere at all. The three dead slots are documented four times over, in four different files, which
is the same information cost paid four times and still not paid in the file named for it.
**Fix:** put the three tables above into `docs/SDK-PARITY.md`, generated by a script rather than typed —
the whole measurement is four `grep`s and a shell loop. Add it as a `just` recipe (`just parity`) and run
it in CI so a newly-added slot that nobody wrapped shows up as a diff rather than as a surprise after the
next SDK upgrade. Reduce the four scattered dead-slot mentions to links.

### R6-02 — two commented-out header declarations are indistinguishable from real slots to any naive audit  [severity: minor]

**Where:** `external/sciter/include/sciter-x-graphics.h:146-148` (`imageGetPixels`),
`external/sciter/include/sciter-x-request.h:186-189` (`Request`, inside `#if 0`)
**What:** both appear in a `grep` for `SCFN(...)` and both look like unwrapped functionality. Neither is
real: `imageGetPixels` is inside a `//` comment block, `Request` inside `#if 0`.
**Why it matters:** they are traps for exactly the audit this section performs — including the automated
version proposed in R6-01, which would report two false gaps forever. `imageGetPixels` is the more
tempting of the two: direct pixel access is a real thing to want, and its absence currently forces
`save_image(.RAW)` (`graphics.odin:196-220`), which encodes into an allocated buffer and then copies it
(see finding R3-03). Somebody will read the header, see the declaration, and file the gap.
**Fix:** have the parity script strip comments and `#if 0` blocks before matching, and add a line to the
generated table marking both as "declared but disabled upstream". Also worth a sentence in
`graphics.odin`'s header comment: `imageGetPixels` is not available, so `save_image(.RAW)` is the pixel
readback path — the file already explains the `gCreate` absence the same way, and this is the same class
of question.

### R6-03 — the two native-integration features are excluded without a stated decision  [severity: minor]

**Where:** the four unwrapped platform-feature slots — `SciterAttachHwndToElement`,
`SciterGetElementHwnd`, `SciterEGLGetProcAddress`, `SciterEGLSendEvent`
**What:** unlike the dead slots and the superseded variants, these four are live, implemented and
unwrapped, and no file says why. `examples/native_child.odin` (432 lines) and
`examples/windowless_gl.odin` (566 lines) exist and demonstrate the two areas — but verified, neither
example touches any of the four slots, so whatever they demonstrate is a different route.
**Why it matters:** a reader who wants to embed a native OpenGL child view inside a Sciter document finds
an example named `native_child`, a header slot named `SciterAttachHwndToElement`, and no connection
between them. That is the most confusing possible state: it looks like coverage, and the coverage claim
cannot be checked. It is also the one place where "we deliberately do not support this" and "nobody has
got to it yet" are genuinely indistinguishable from outside.
**Fix:** one paragraph in `SDK-PARITY.md` for each pair. If native child windows are out of scope because
the design has no `HWND` story on Linux, say that. If EGL is deferred until there is hardware to test on,
say that. And say in each example's header comment what route it *does* take, so the reader stops looking
for the slot.

### R6-04 — nothing detects a slot that appears in a future SDK  [severity: minor]

**Where:** `.github/workflows/`, `justfile` — the upgrade path described in `docs/UPGRADING.md`
**What:** `just example api_map` verifies that the 189 slots the bindings expect resolve to the right
symbols in the shipped engine. That catches a *reordered* or *removed* slot, which is the catastrophic
case and rightly the one guarded. It does not catch an *added* slot: a new SDK with 195 slots, regenerated
into `sciter.odin`, produces six new fields that no wrapper covers and no check mentions.
**Why it matters:** `docs/UPGRADING.md` is built around `api_map` as the post-upgrade check, and it is
the right check for correctness. Coverage is the other half, and it currently degrades silently — the
first sign would be a user asking for something the docs imply exists. Given that the whole point of the
parity story is completeness, losing it one SDK at a time is the likely failure mode.
**Fix:** the `just parity` recipe from R6-01, run in CI and in the `UPGRADING.md` checklist next to
`api_map`, with the current unwrapped list committed as a baseline file. A new slot then shows up as a
one-line diff during the upgrade, when the person doing the upgrade is the right person to decide about it.

## Note on `sciter.odin` usability

Spot-checked for generated-but-unusable declarations: opaque handles are `distinct rawptr` and are
consumed by the wrappers unchanged; callback typedefs carry `proc "system"` and are called with a
restored `context` at every one of the trampolines checked (`value.odin:381`, `dom.odin:857`,
`events.odin:74`, `host.odin:306`, `som.odin:467`); `Scdom_Result` is hand-declared as `enum Int` for the
documented reason that Odin's default `int` backing would be 8 bytes against the C `int`
(`src/prelude.odin:33-42`). No slot was found that is present in the generated bindings but impossible to
call from Odin.
