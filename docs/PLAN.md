# odin-sciter — findings and implementation plan

Status as of 2026-08-09: **the bindings generate, compile, and run.** `just bindgen` produces
`sciter.odin` from the vendored headers, `just example api_map` verifies all 189 `ISciterAPI` slots
against the shipped engine, and `just example hello_window` opens a window with HTML and CSS in it.
What remains is the ergonomic layer, the guides, and the rest of the examples.

Target: Odin bindings for [Sciter.JS](https://sciter.com/) — the JavaScript (QuickJS) generation of the
Sciter HTML/CSS/JS UI engine. Not the TIScript generation, not the TypeScript wrapper.

How every finding below was established — which tool answered which question — is in
[`RESEARCH-METHOD.md`](./RESEARCH-METHOD.md).

---

## 1. Use GitLab. The GitHub mirror is a trap.

This cost the first pass of this project several hours, so it goes first.

There are two `sciter-js-sdk` repositories. The GitHub one, `c-smile/sciter-js-sdk`, is the one search
engines surface and the one every blog post links. **Its last commit is 2022-04-19.** It ships engine
4.4.8.33 with `SCITER_API_VERSION` 9.

The real one is <https://gitlab.com/sciter-engine/sciter-js-sdk>, currently at tag **`6.0.4.9-bis`**
(2026-08-02), engine 6.0.4.9, `SCITER_API_VERSION` **10**.

Worse than merely stale: the GitHub mirror is *internally inconsistent*. Its `sciter-x-api.h` declares
`SciterExec` and `SciterWindowExec` at the tail of `ISciterAPI`, but the `libsciter-gtk.so` committed
beside it implements neither. Calling them reads two pointers past the end of the engine's real table
and jumps into whatever data follows — which presents as a segfault inside an unrelated engine function
with a plausible-looking backtrace. Nothing about the header, the version handshake, or the first 184
slots gives any hint.

Getting the SDK:

```sh
git clone --depth 1 https://gitlab.com/sciter-engine/sciter-js-sdk.git
# or
curl -L -o sciter-js-sdk.zip \
  https://gitlab.com/sciter-engine/sciter-js-sdk/-/archive/6.0.4.9/sciter-js-sdk-6.0.4.9.zip
```

A full-history clone is ~4 GB: 800+ commits, each carrying every platform's binaries.

---

## 2. What we are binding to

Sciter ships as a shared library with **one exported entry point**: `SciterAPI()`. It returns a pointer
to `ISciterAPI`, a plain C struct of 189 function pointers plus a leading `version` field. There is
nothing else to link against — the whole engine is reached through that one table.

```
$ nm -D --defined-only bin/linux/x64/libsciter.so | grep -w SciterAPI
00000000007e4a19 T SciterAPI
```

The library exports ~17,000 dynamic symbols, but they are vendored third-party internals (QuickJS,
libjpeg, Skia). Exactly one is the API.

### The layout is identical on every platform

Sciter keeps every slot on every platform and fills the ones it cannot implement there with NULL,
rather than `#ifdef`-ing them out:

```c
#if defined(WINDOWS)
  LRESULT SCFN( SciterProc )(HWINDOW hwnd, UINT msg, WPARAM wParam, LPARAM lParam);
  LRESULT SCFN( SciterProcND )(...);
#else
  LPVOID   SciterProc;   // NULL
  LPVOID   SciterProcND; // NULL
#endif
```

The same pattern covers `SciterTranslateMessage`, `SciterRenderD2D` / `SciterD2DFactory` /
`SciterDWFactory`, the three DirectX entry points, `SciterCreateNSView` (macOS) and
`SciterCreateWidget` (Linux). Every padded slot is pointer-sized, so **one Odin struct definition serves
Windows, Linux and macOS**, and the bindings can be generated on whichever platform is most convenient.
16 of the 189 slots are NULL on Linux — 12 platform-padded plus 4 `reserved` left from the removed
script-VM API.

### Verified, not assumed

`examples/api_map.odin` walks the table field by field and resolves each pointer with `dladdr`:

```
001 off=0008 SciterClassName                    -> SciterClassNameImp
002 off=0016 SciterVersion                      -> SciterVersionImp
...
184 off=1472 SciterExec                         -> SciterExecImp
189 off=1512 SciterRequestPaint                 -> SciterRequestPaintImp

189 slots, 16 null (platform-padded)
```

Every non-null slot resolves to its own name plus the engine's `Imp` suffix — 189 checked, **0
mismatches**. This is the check that catches a header/binary mismatch, and it is the reason the GitHub
mirror's problem was found rather than shipped. Run it whenever the vendored SDK version changes.

---

## 3. Licensing — two licences, not one

The SDK repository carries **`LICENSE` (BSD 3-Clause)**, and separately **`SCITER-ENGINE-EULA.md`**.
They cover different things, and conflating them is easy:

- **BSD 3-Clause** covers the repository's contents — the headers, samples and documentation. That is
  what these bindings are generated from, and it is why generating them is unencumbered.
- **The Sciter Engine EULA** covers the binary itself (`sciter.dll` / `libsciter.so` /
  `libsciter.dylib`). It is *not* BSD. Terra Informatica retains copyright and grants free use in
  commercial and non-commercial applications, subject to one concrete obligation:

  > Your application shall include link to Terra Informatica site in "About" dialog or similar place in
  > your application. Text of the link: This Application (or Component) uses Sciter Engine
  > (http://sciter.com/), copyright Terra Informatica Software, Inc.

The repository has **no engine source** — `include/` and `bin/` only. Access to the sources, and the
right to link statically, are the paid tiers at <https://sciter.com/prices/>.

For a bindings library this is the good case: bindings come from headers, so nothing about the paid tier
blocks the project. Two consequences to carry:

1. Dynamic linking only. The library must be found at runtime, which makes the loader's error message a
   first-class feature rather than an afterthought (see §6).
2. The README must state the attribution requirement plainly. Anyone shipping an application built on
   these bindings owes that About-box line, and they will not read the EULA to find out.

---

## 4. Sciter 6 dropped GTK

This is the single biggest change from the 4.x material that most of the internet still describes, and
it is entirely good news for a bindings library.

Sciter 4 on Linux was `libsciter-gtk.so`: a GTK3 application-level library, whose window handle *was* a
`GtkWidget*` and whose message pump was `gtk_main()`. Binding it properly meant also binding GTK.

Sciter 6 on Linux is `libsciter.so`, and renders through its own EGL/GLESv2 backend:

```
$ ldd bin/linux/x64/libsciter.so
libuuid, libfontconfig, libfreetype, libGLESv2, libEGL, libstdc++, libm, libgcc_s, libc,
libexpat, libz, libbz2, libpng16, libbrotlidec, libGLdispatch, libbrotlicommon
```

Sixteen entries, no GTK, no X11 or Wayland client libraries, nothing resolved as missing on a stock
Ubuntu desktop. `HWINDOW` is now a plain `void*` on Linux — the header does not even include
`<gtk/gtk.h>` any more, which also removes the need for `libgtk-3-dev` at binding-generation time.

The application lifecycle is Sciter's own, on all three platforms:

```c
typedef enum SCITER_APP_CMD {
  SCITER_APP_STOP     = 0,  // request to quit the message pump
  SCITER_APP_LOOP     = 1,  // run pump until SCITER_APP_STOP or main window closes
  SCITER_APP_INIT     = 2,  // p1 = argc, p2 = argv
  SCITER_APP_SHUTDOWN = 3,
} SCITER_APP_CMD;

INT_PTR SciterExec(UINT appCmd, UINT_PTR p1, UINT_PTR p2);
INT_PTR SciterWindowExec(HWINDOW hwnd, UINT windowCmd, UINT_PTR p1, UINT_PTR p2);
```

So `examples/hello_window.odin` creates a window, loads HTML and runs to completion with **no GTK, no
Win32 and no Cocoa symbols anywhere in the bindings**. odin-sciter is a single-dependency library.

Two traps found the hard way, both now documented in the example:

- **`SCITER_APP_INIT` wants UTF-16 argv.** The comment on it in `sciter-x-def.h` says `p2 - CHAR** argv`
  and that is wrong; `application::start()` in `sciter-x-window.hpp` builds a `vector<const WCHAR*>`.
  Passing `char**` — or `NULL` — crashes.
- **`SciterVersion(n)` takes an index 0..3**, returning one component of the version vector. In 4.x it
  took a boolean and packed two components into the result. Old code and old blog posts do the latter.

Window creation flags shrank in 6.x, too. `SW_TITLEBAR`, `SW_RESIZEABLE`, `SW_CONTROLS`, `SW_TOOL`,
`SW_GLASSY`, `SW_ALPHA` and `SW_OWNS_VM` are all commented out upstream; only `SW_CHILD`, `SW_MAIN`,
`SW_POPUP` and `SW_ENABLE_DEBUG` remain. Window chrome is a CSS concern now.

---

## 5. Generating the bindings

`just bindgen` runs three steps. All of it is reproducible from a clean checkout.

```
uv run python src/flatten_headers.py      # -> build/sciter.h
../odin-c-bindgen/bindgen.bin .           # -> sciter.odin, per bindgen.sjson
uv run python src/postprocess_bindings.py sciter.odin
odin check . -no-entry-point
```

### Why the flatten step exists

odin-c-bindgen only emits declarations **physically located in the input file**; anything reached
through an `#include` is skipped. Feeding it only `sciter-x-api.h` yields `ISciterAPI` and none of the
enums, DOM types or `VALUE` machinery it refers to. Feeding it all ten headers yields ten `.odin` files
that each re-emit inline copies of their neighbours' types — and since they share `package sciter`,
those copies collide.

Sciter's headers are also not individually self-contained: `sciter-x-dom.h` uses `UINT`, `INT` and
`LPCWSTR` without including `sciter-x-primitives.h`, because in practice it is only ever reached through
`sciter-x-api.h`. Parsed alone it produces a wall of "unknown type name".

`src/flatten_headers.py` concatenates the 13 C-ABI headers in dependency order into one
`build/sciter.h`, dropping the internal `#include "..."` lines and keeping the system `<...>` ones. One
translation unit, every declaration in-file, one output file, no duplicates.

It also does two things worth knowing about:

**It strips the 163 flat `SCAPI` prototypes.** The headers declare `UINT SCAPI ValueInit(VALUE*)`,
`HWINDOW SCAPI SciterCreateWindow(...)` and ~160 more. **None of them are exported by the library** —
in C they resolve to `inline` wrappers further down `sciter-x-api.h` that forward to
`SAPI()->ValueInit(...)`. Generated as Odin `foreign` procedures they are dead weight that cannot link.
Removing them at the source is cleaner than generating and then explaining them.

**It applies a short list of justified patches** where the headers are not valid C (they compile in
practice only because everyone includes them from C++). Each is one line with a comment saying why:

| Patch | Why |
| --- | --- |
| `som_passport_t*` → `struct som_passport_t*` | only ever forward-declared as a struct tag; C++ injects the tag into the ordinary namespace, C does not |
| drop `sciter-x-behavior.h`'s `ElementEventProc` typedef | typedef'd identically in `sciter-x-dom.h`; C11 allows the repeat, Odin does not |
| `LPElementEventProc` → `LPELEMENT_EVENT_PROC` | two spellings of one type; `force_ada_case_types` folds both to `Lpelement_Event_Proc` |
| drop `sciter-x-request.h`'s `HELEMENT` forward declaration | same duplicate-typedef problem, `sciter-x-dom.h` owns it |
| drop the second `typedef ssize_t INT_PTR` | 6.0.4.x typedefs `INT_PTR` twice on Linux and macOS, the second time as `ssize_t`, which nothing declares |

A patch that stops matching is a hard error, not a silent skip, so an SDK upgrade cannot quietly drop
one.

The prototype stripper is comment-aware, which is not fussiness: `sciter-x-dom.h` contains the line
`* \return \b #SCDOM_RESULT SCAPI` inside a doc comment. Treating that as a prototype deletes everything
to the next `;` — landing mid-enum and taking the comment's terminator with it.

### bindgen.sjson

Two clang defines, and a handful of type overrides:

```
clang_defines = {
	"LINUX" = "1"                        // without a platform, no primitive typedefs exist at all
	"char16_t" = "__CHAR16_TYPE__"       // a C++ built-in; in C it needs <uchar.h>, which Sciter never includes
}

type_overrides = {
	"SBOOL"    = "b32"      // `typedef int SBOOL` - 4 bytes, so NOT Odin's 1-byte `bool`
	"LPCBYTE"  = "[^]u8"    // always a buffer, never a pointer to one byte
	"LPCWSTR"  = "[^]u16"   // UTF-16 run
	"UINT_PTR" = "uintptr"  // half its uses are genuinely pointers
}
```

`SBOOL` is the one that matters most for day-to-day use: as `i32` the API reads
`if api.SciterLoadHtml(...) != 0`; as `b32` it reads `if api.SciterLoadHtml(...)`, and
`api.SciterVersion(true)` type-checks.

### The post-process step

bindgen derives the calling convention from what clang sees. On Linux `SCFN(name)` expands to
`(*name)`, so every function pointer comes out `proc "c"`; on Windows it is `(__stdcall *name)`. Odin
spells "the platform's system ABI" `proc "system"` — the same thing Rust means by `extern "system"`, and
what rust-sciter uses. Since the bindings are generated once on Linux and compiled everywhere, all 299
occurrences are rewritten. bindgen has no setting for this, and generating on Windows instead is not an
option: those headers pull in `windows.h`, `HWND`, `MSG` and `IUnknown`, which libclang on Linux cannot
resolve.

---

## 6. What exists now

```
odin-sciter/
  sciter.odin                     # GENERATED - package sciter, ~1800 lines
  bindgen.sjson                   # bindgen configuration
  src/prelude.odin                # hand-written; pasted into sciter.odin by bindgen
  src/flatten_headers.py          # headers -> build/sciter.h
  src/postprocess_bindings.py     # proc "c" -> proc "system"
  external/sciter/
    include/                      # vendored headers, unmodified
    LICENSE                       # BSD 3-Clause (SDK contents)
    SCITER-ENGINE-EULA.md         # the engine binary's licence
    VENDORED.md                   # pinned version, what was left out, licensing
  lib/linux/x64/libsciter.so      # the engine, 25 MB
  examples/
    hello_window.odin             # window + HTML + CSS + app loop
    api_map.odin                  # ISciterAPI slot/symbol verification
  spike/smoke/main.odin           # minimal ABI handshake, no generated code
  docs/
```

`src/prelude.odin` is the hand-written half. It has no `foreign import` — the library is opened at
runtime — and provides `load()`, `api()`, `loaded()` and `unload()`. `load` searches, in order:

1. an explicit path argument
2. `SCITER_LIB` (a file or a directory)
3. the directory of the running executable
4. `lib/<platform>/` relative to the working directory
5. the system loader's search path

and returns the full list of candidates it tried on failure, because "it did not load" is the most
common first-run problem with Sciter and a bare `dlopen` error says nothing useful. It also refuses to
proceed when `version` does not match `SCITER_API_VERSION` — a silent mismatch means every call lands in
the wrong slot.

---

## 7. Idiomatic Odin types — **done**

Applied, all of it declaratively in `bindgen.sjson` so it survives regeneration. `Isciter_Api` is still
1520 bytes and `just example api_map` still resolves 189/189 slots, so none of it moved the ABI.

- **`bit_setify`** on `EVENT_GROUPS`, `SCITER_CREATE_WINDOW_FLAGS`, `ELEMENT_STATE_BITS`,
  `SCRIPT_RUNTIME_FEATURES`, `SCITER_SCROLL_FLAGS`. Each generates a singular member enum plus the
  C-named `bit_set[...; u32]`, and multi-bit members (`HANDLE_ALL`, `SUBSCRIPTIONS_REQUEST`) become
  constants of the bit_set type.
- **`procedure_type_overrides`** on the app/window/option commands, the DOM state and node/control
  types, the event subscription mask on both sides (`SciterWindowAttachEventHandler.subscription` and
  `ElementEventProc.evtg`), `ValueType.pType`, the debug output callback, and all **101** slots that
  return `SCDOM_RESULT`. Four `const BYTE*` parameters that the `LPCBYTE` override cannot see are
  augmented to `[^]` individually.
- **`Scdom_Result`** is hand-written in `src/prelude.odin`, not generated: upstream has
  `#define SCDOM_RESULT INT` and six more `#define`s, so there is no C enum to convert, and bindgen's
  `enumify_macros` builds enums over Odin's 8-byte `int` — wrong for a 4-byte C `int` return. The
  `SCDOM_*` macros are `remove`d so there is one spelling of each code.
- **`rename`** for the Hungarian leftovers that appear in signatures callers write: `Sbool` →
  `Bool32`, `Lpcwstr` → `Wide_String`, `Lpcbyte` → `Bytes`, `Hsarchive` → `Archive`, and the three
  `*_RECEIVER` callbacks to match. Everything else keeps its upstream spelling.
- **`remove_enum_member_prefix`** for `SET_ELEMENT_HTML`, whose members are `SIH_*` and `SOH_*`: the
  automatic pass stripped their shared leading `S` and produced names that exist nowhere upstream.

Three items in the tables below were **not** applied, because each would have compiled and been wrong.
The reasoning is recorded in full in `bindgen.sjson` next to where it would have gone:

- `ELEMENT_AREAS` is not a flag set. It packs two alternations (relative-to: 1,2,3,4 — note 3, which is
  not `1|2`; and box: 0x00,0x10,...,0x60) plus one real flag, `AS_PPX`. A bit_set would make invalid
  combinations expressible and hide the actual rule. It stays an enum, and `SciterGetElementLocation`'s
  `areas` stays a `Uint`.
- `OUTPUT_SUBSYTEMS` is `0,1,2,3` — an alternation. As a bit_set, `DOM` (zero-valued) would be deleted
  outright and `SCRIPT` would become `{.CSSS, .CSS}`.
- `SciterWindowExec`'s `p1` is a `SCITER_WINDOW_STATE` only for `SET_STATE`; it is a `POINT*` for
  `SET_PLACEMENT` and a boolean for `ACTIVATE`. Likewise `ValueType`'s `pUnits`, whose enum is chosen
  by `pType` — one of five. Both stay untyped.

The original plan for this section follows.

The generated layer is a faithful 1-to-1 port, which means it is still C-shaped: bare `Uint` where an
enum belongs, integers where a `bit_set` belongs, `Int` returns where a result enum belongs. The same
polish that odin-dds and odin-rure apply should apply here, and bindgen supports all of it declaratively
in `bindgen.sjson` — so it survives regeneration. Concretely:

**`bit_setify`** — enums that are really flag sets:

| C enum | Notes |
| --- | --- |
| `EVENT_GROUPS` | `HANDLE_MOUSE`, `HANDLE_KEY`, ... — the subscription mask for event handlers |
| `SCITER_CREATE_WINDOW_FLAGS` | `SW_MAIN \| SW_ENABLE_DEBUG` is the common case and reads badly as `u32(...) \| u32(...)` |
| `ELEMENT_STATE_BITS` | `STATE_LINK`, `STATE_HOVER`, `STATE_ACTIVE`, ... |
| `SCRIPT_RUNTIME_FEATURES` | `ALLOW_FILE_IO`, `ALLOW_SOCKET_IO`, `ALLOW_EVAL`, `ALLOW_SYSINFO` |
| `OUTPUT_SUBSYTEMS`, `ELEMENT_AREAS`, `SCITER_SCROLL_FLAGS` | same shape |

**`procedure_type_overrides` / `struct_field_overrides`** — parameters and returns that are enums
wearing an integer:

| Slot | Today | Should be |
| --- | --- | --- |
| `SciterExec.appCmd` | `Uint` | `Sciter_App_Cmd` |
| `SciterWindowExec.windowCmd` | `Uint` | `Sciter_Window_Cmd` (and `p1` is a `Sciter_Window_State`) |
| `SciterCreateWindow.creationFlags` | `Uint` | `Sciter_Create_Window_Flags` bit_set |
| `SciterSetOption.option` | `Uint` | `Sciter_Rt_Options` |
| every `SCDOM_RESULT` return | `Int` | `Scdom_Result` enum |
| `ValueType`'s out-params | `^Uint` | `^Value_Type`, `^Value_Unit_Type` |
| `SciterAttachEventHandler.subscription` | `Uint` | `Event_Groups` bit_set |
| `ELEMENT_AREAS` parameters | `Uint` | the bit_set |

**`remove_enum_member_prefix`** where the automatic common-prefix stripping misfires, and a review pass
over the `Ada_Case` results — `Lpcwstr`, `Sbool`, `Hsarchive` are faithful but ugly, and a `rename` table
can give the handful that appear in user-facing signatures better names.

Worth doing before the ergonomic layer is written, not after: the wrapper API should be built on top of
types that are already right, or the same conversions get written twice.

---

## 8. Milestones

1. ~~Prerequisites — build odin-c-bindgen, get the SDK from GitLab~~ **done**
2. ~~Spike — prove the ABI handshake from Odin~~ **done** (`spike/smoke`)
3. ~~Vendor headers + Linux binary, pin the version, record licensing~~ **done**
4. ~~Generate — flatten, `bindgen.sjson`, prelude, post-process~~ **done**
5. ~~Verify the generated struct against the shipped engine~~ **done** (`examples/api_map`)
6. ~~First window~~ **done** (`examples/hello_window`)
7. ~~Idiomatic types — §7~~ **done**
8. **Ergonomic layer** — `package sciter_app`: window, load, eval, call, `Value` conversions to and from
   Odin types, event handler registration. `Value` is reference-counted with explicit
   `ValueInit`/`ValueClear`/`ValueCopy`, so this is where the memory bugs will live and where the tests
   should concentrate.
9. **Examples and guides** — §9.
10. **Cross-platform** — vendor the Windows binary and verify there (the only other machine available);
    macOS ships untested and should say so.
11. **Housekeeping** — reworking the skeleton's `run_*` / `rerun_*` / `sanitize` / `test` recipes,
    which still assume the root package has a `main`. (Done already: `git init`; `.gitignore`
    negations so the skeleton's `*.so` / `*.dll` / `*.dylib` build-artifact patterns do not silently
    exclude the vendored engine; `.gitattributes` already marks those extensions `binary`.)

---

## 9. Docs and examples

Source material: <https://sciter.com/tutorials/> and <https://docs.sciter.com/docs/intro>. Note both
predate 6.x in places, so check anything platform-specific against the SDK.

**Guides** (`docs/`)

- `getting-started.md` — install, where the library must live, first window, what to do when it will not
  load
- `architecture.md` — the vtable, why there is one entry point, why it is dynamic-only, BSD vs EULA and
  what you owe
- `html-css-js.md` — what Sciter's HTML/CSS/JS is and is not (not a browser: a large subset plus
  Sciter-specific extensions)
- `calling-between-odin-and-js.md` — `SciterCall`, `SciterEval`, native functors, `Value` lifecycle
- `dom.md` — element handles, `Sciter_UseElement`/`Sciter_UnuseElement` refcounting, traversal
- `events.md` — `SciterAttachEventHandler`, `EVENT_GROUPS`, `ElementEventProc`
- `resources.md` — `packfolder` and `SciterOpenArchive`/`SciterGetArchiveItem` for one-binary shipping
- `deployment.md` — what to ship per platform, the About-box attribution, runtime dependencies
- `api.md` — the idiomatic-Odin API guide, mirroring odin-dds's

**Examples** (`examples/`), each runnable with `just example NAME`, ordered by difficulty:

1. ~~`hello_window`~~ — done
2. ~~`api_map`~~ — done (diagnostic rather than tutorial, but it belongs here)
3. `load_file` — load an `.htm` from disk, `SciterSetHomeURL`
4. `eval` — run JS from Odin, read the result back as a `Value`
5. `call_odin_from_js` — expose an Odin proc to script
6. `dom_walk` — find elements, read and write text and attributes
7. `events` — button clicks and input via `ElementEventProc`
8. `custom_loader` — the `SC_LOAD_DATA` host callback, serving resources from memory
9. `archive` — `packfolder` + `SciterOpenArchive`, single-binary deployment
10. `inspector` — `SW_ENABLE_DEBUG` and attaching the SDK inspector

Testing is example-driven — there is no engine source to unit-test against. Follow odin-dds and put
`@(test)` procs inside `examples/*.odin`. Headless-testable: library loading, the version handshake,
`Value` round-trips through `ValueInit`/`ValueFromString`/`ValueToString`/`ValueClear`, `SciterEval`
results, archive open/read, atom round-trips. Anything needing a window needs a display, so gate those
on `DISPLAY`/`WAYLAND_DISPLAY`. Run the headless subset under ASan on Linux — `Value` refcounting is
exactly the code that benefits, and per the skeleton README, Linux ASan catches heap errors that Windows
ASan does not.

---

## 10. Open questions

- **Repo size.** `lib/linux/x64/libsciter.so` is 25 MB, and Windows plus macOS would add ~50 MB more.
  Vendoring buys `git clone && just example hello_window` working offline, which is the single biggest
  thing that makes a bindings library approachable. The alternative is headers-only plus a mandatory
  `just fetch-sdk` with pinned checksums. Recommendation: vendor, but decide before the first commit —
  it is much easier now than after the binaries are in history.
- **Naming.** `sciter.SciterCreateWindow` maps 1-to-1 onto upstream documentation, which is worth a lot
  for a library whose users will be reading sciter.com. `sciter.create_window` reads better. The
  intended answer is both, in two packages: generated `package sciter` stays 1-to-1, ergonomic
  `package sciter_app` is snake_case and Odin-shaped.
- **Version pin policy.** Pinned at `6.0.4.9-bis` today. The tag cadence is roughly weekly, so a policy
  is needed — probably "pin, and re-run `api_map` on every bump".
- **Windowless / lite.** `bin/linux/x64/lite-sciter-sdl` and `sciter-x-lite.hpp` exist. Out of scope for
  v1, but the layout invariance means supporting it later costs little.
