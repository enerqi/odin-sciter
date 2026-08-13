# odin-sciter — findings and implementation plan

Status as of 2026-08-12: **the bindings generate, compile, and run, and there is an ergonomic layer on
top of them.** `just bindgen` produces `sciter.odin` from the vendored headers, `just example api_map`
verifies all 189 `ISciterAPI` slots against the shipped engine, and twenty-five examples build and run —
covering windows, loading from disk, JS evaluation, calling Odin from script (functors and SOM assets),
the DOM, events, behavior methods, behaviors a stylesheet asks for by name, synthesised input,
background threads, drag-and-drop, graphics (both a custom-painted element and a gallery covering the
whole 2D API),
video streaming through the one C++ interface the API has, custom resource loading
(including the request API), archives, one-file shipping, the inspector and a native extension.
`just example-tests` runs 367 `@(test)` procs, and the eleven guides in `docs/` are written. Coverage of
the wrapper is 355 of its 360 exported procedures called from a test; the rest are proc-group members
reached through their group.

Every number in that paragraph comes from `just stats` (`.github/scripts/stats.sh`), and `just stats
--check` fails if this file and `README.md` have drifted from it - which they had, by 29 tests. The
counting rule is `\.name\b` and not `\.name(`: the examples store and forward wrappers as often as
they call them, and matching the open paren undercounts. `close` is now among the covered ones: there is exactly one order in which
a secondary window can be closed without crashing the engine - hide, pump, close - and
`examples/workbench.odin` pins it. What remains
is Windows - and everything that could be prepared for it without the machine has been, including
`api_map` building and reporting usefully there; see [`WINDOWS-CHECKLIST.md`](./WINDOWS-CHECKLIST.md).

**Running a windowed example on X11**: this machine's engine build segfaults in `XSetICFocus`, inside
libsciter's X input-method handling, shortly after a window takes focus — 3 runs out of 3. Running with
`XMODIFIERS=@im=none` stops the engine creating the input context and the crash goes away (0 out of 3).
It is inside the vendored binary, not the bindings; `just example api_map` is the check that would
catch a real slot mismatch.

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

The library exports 52,051 dynamic symbols, but they are vendored third-party internals (Skia, QuickJS,
libwebp, libjpeg) and the engine's own C++ classes. Exactly one is the API — see
[`ENGINE.md`](./ENGINE.md).

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

`examples/api_map.odin` walks the table field by field and resolves each pointer back to the symbol and
module it belongs to - `dladdr` on Linux and macOS, dbghelp plus `VirtualQuery` on Windows:

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

`just bindgen` runs four steps. All of it is reproducible from a clean checkout, and running it twice
produces a byte-identical `sciter.odin`.

```
uv run python src/flatten_headers.py      # -> build/sciter.h
../odin-c-bindgen/bindgen.bin .           # -> sciter.odin, per bindgen.sjson
uv run python src/postprocess_bindings.py sciter.odin
odin check . -no-entry-point
odinfmt -w sciter.odin                    # bindgen's line breaking is not odinfmt's
odin check . -no-entry-point
```

The formatting pass is part of generation rather than left to `just format`, and it runs only after the
first check passes. Without it, every regeneration lands a few thousand lines of formatting noise on
top of whatever actually changed in the API, and `just format` then "changes" a file nobody edited.
The second check confirms the formatter did not break what the generator got right.

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
  sciter.odin                     # GENERATED - package sciter, ~2760 lines
  bindgen.sjson                   # bindgen configuration
  src/prelude.odin                # hand-written; pasted into sciter.odin by bindgen
  src/flatten_headers.py          # headers -> build/sciter.h
  src/postprocess_bindings.py     # proc "c" -> proc "system"; drops the `-> Void` returns
  sciter_app/                     # hand-written ergonomic layer - package sciter_app
    sciter_app.odin               # errors, UTF-16 conversion, overload groups
    app.odin                      # load_engine, init, run, stop, options, debug output, master CSS
    window.odin                   # create, load, eval, call, set_global, focus, state
    value.odin                    # VALUE construction/extraction, arrays, maps, native functors
    atom.odin                     # interned names - the currency of the SOM API
    dom.odin                      # selectors, hit testing, traversal, text, HTML, attributes, popups
    node.odin                     # text and comment nodes, the half of the tree dom.odin skips
    layout.odin                   # boxes, intrinsic sizes, window metrics, scrolling
    behavior.odin                 # behavior methods: control_type, do_click, METHOD_CALL both ways
    events.odin                   # Event_Handler, typed event params, timers, frames, synthesised input
    graphics.odin                 # the graphics API: paths, text, images, layers
    som.odin                      # SOM assets - an Odin object script can read, write and call
    host.odin                     # SC_LOAD_DATA host callback, and post_callback across threads
    request.odin                  # the HREQUEST side of a .MYSELF load
    archive.odin                  # packfolder blobs opened in place
    embed.odin                    # the engine binary embedded in the executable
  external/sciter/
    include/                      # vendored headers, unmodified
    LICENSE                       # BSD 3-Clause (SDK contents)
    SCITER-ENGINE-EULA.md         # the engine binary's licence
    VENDORED.md                   # pinned version, what was left out, licensing
  lib/linux/x64/libsciter.so      # the engine, 25 MB
  examples/
    hello_window.odin             # window + HTML + CSS + app loop, raw bindings only
    api_map.odin                  # ISciterAPI slot/symbol verification
    load_file.odin                # load from disk, base URLs, relative references
    eval.odin                     # JS from Odin, Value round-trips (+15 tests)
    call_odin_from_js.odin        # native functors and a SOM asset: script calling into Odin
    dom_walk.odin                 # selectors, traversal, text/attributes, nodes, SOM (+54 tests)
    events.odin                   # ELEMENT_EVENT_PROC, subscriptions, phases, timers (+21 tests)
    behavior.odin                 # do_click vs send_event, control_type, hit testing (+9 tests)
    input.odin                    # real mouse and key input, animation frames, expando (+14 tests)
    task_list.odin                # a whole small application: model, render, keys, saving (+11 tests)
    worker_thread.odin            # post_callback: a background thread driving the UI (+5 tests)
    graphics.odin                 # painting from a .DRAW handler (+12 tests)
    drag_and_drop.odin            # the EXCHANGE group (+3 tests)
    custom_loader.odin            # SC_LOAD_DATA: serving CSS and images from memory
    request_loader.odin           # .MYSELF: answering a load through the request API (+5 tests)
    archive.odin                  # packfolder blob + #load, resources inside the executable (+6 tests)
    single_binary.odin            # archive + the engine embedded too - one file, Linux x64 (+7 tests)
    inspector.odin                # SW_ENABLE_DEBUG + SCITER_SET_DEBUG_MODE
    extension.odin                # NOT an app - a native extension .so, see section 11
    assets/                       # hello.htm + css + svg; extension/index.htm
      app/                        # the folder packfolder packs, for `archive`
      app.pak                     # COMMITTED 2 KB archive, so `archive` needs no SDK
  spike/
    smoke/main.odin               # minimal ABI handshake, no generated code
    xdnd/xdnd_source.py           # a minimal X11 drag source, to measure a real system drop
    skeleton/main.odin            # the template main this repo started from; no Sciter in it
  docs/
    snippets/snippets.odin        # every Odin block in docs/*.md, wrapped just enough to compile
```

`src/prelude.odin` is the hand-written half. It has no `foreign import` — the library is opened at
runtime — and provides `load()`, `adopt()`, `api()`, `loaded()` and `unload()`. `load` searches, in
order:

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
| `MOUSE_BUTTONS` | `button_state` is every button held, so two at once is 3 and none is 0 — neither a member |
| `KEYBOARD_STATES` | `alt_state` likewise; `SHIFT`/`CONTROL`/`ALT`/`COMMAND` are the left-or-right pairs, so they become constants |
| `VALUE_UNIT_TYPE_DATE` | `HAS_DATE`, `HAS_TIME`, `HAS_SECONDS`, `UTC` combine on one timestamp |
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
8. ~~Ergonomic layer — `package sciter_app`~~ **done**: window, load, eval, call, `Value` conversions,
   native functors, DOM access (elements *and* nodes), event handler registration, engine options, and
   the `.DELAYED` half of the host callback. `Value` is reference-counted with explicit
   `ValueInit`/`ValueClear`/`ValueCopy`, and the tests concentrate there.
9. ~~**Examples and guides** — §9~~ **done**: all twenty-three examples run, and the eleven guides are
   written — the last of them, [`ENGINE.md`](./ENGINE.md), measured from the shipped binary rather than
   written against the headers.
10. **Cross-platform** — vendor the Windows binary and verify there (the only other machine available);
    macOS ships untested and should say so. Prepared without the machine: everything type checks for
    `windows_amd64` and `darwin_amd64` (`odin check -target:`), `examples/api_map.odin` was rewritten
    to build on all three (it used `dladdr`, which does not exist on Windows, so the one tool the
    upgrade procedure leads with would not have linked), the `dom_walk` tests no longer gate
    themselves on `DISPLAY`/`WAYLAND_DISPLAY` on platforms that have neither, and `just pack` /
    `just extension-run` look for `packfolder.exe` / `scapp.exe`. The rest is in
    [`WINDOWS-CHECKLIST.md`](./WINDOWS-CHECKLIST.md).
11. ~~Native extensions (`SciterLibraryInit`)~~ **done** — not in the original plan. See §11 below.
12. **Housekeeping** — ~~reworking the skeleton's `run_*` / `rerun_*` / `sanitize` / `test` recipes,
    `run_*` / `rerun_*` / `sanitize` / `test` recipes~~ **done**: they now take an example name and
    keep their build profiles. (Done already: `git init`; `.gitignore`
    negations so the skeleton's `*.so` / `*.dll` / `*.dylib` build-artifact patterns do not silently
    exclude the vendored engine; `.gitattributes` already marks those extensions `binary`.)

---

## 9. Docs and examples

Source material: <https://sciter.com/tutorials/> and <https://docs.sciter.com/docs/intro>. Note both
predate 6.x in places, so check anything platform-specific against the SDK.

**Guides** (`docs/`) — all eleven **done**. Written against the source rather than from memory, and
against the SDK's own `docs/md/` tree for the HTML/CSS/JS material, which is the only complete
description of what the engine actually implements.

- ~~`getting-started.md`~~ — install, the five calls in order, the debug output, the search path, and a
  troubleshooting section covering the XIM segfault and `Version_Mismatch`
- ~~`architecture.md`~~ — the vtable, why there is one entry point, why it is dynamic-only, threading,
  the two packages, how the generated half is produced, the three architectures, BSD vs EULA
- ~~`html-css-js.md`~~ — flow/flex instead of flexbox and grid, native behaviors, style sets, QuickJS
  ES2020, the `@sciter`/`@sys`/`@storage` runtime, URL schemes, and a porting checklist
- ~~`calling-between-odin-and-js.md`~~ — `Value` ownership first, then `eval`/`call`, native functors,
  why `set_global` evaluates an assignment function, and a table of the usual mistakes
- ~~`dom.md`~~ — handles and `use_element`, selectors, traversal, text/HTML/attributes, state bits,
  when to use `eval` instead, and the `context` rule for raw callbacks
- ~~`events.md`~~ — the four rules (immovable handler, subscription mask, phase bits, engine thread),
  typed parameters, why synthesised events are not user input
- ~~`resources.md`~~ — the `SC_LOAD_DATA` callback, the two meanings of `.OK`, archives, why
  `this://app/` is a host convention, and the embedded engine
- ~~`deployment.md`~~ — what ships per platform, the runtime search order, one file vs two, the
  attribution, the upgrade procedure, and a pre-ship checklist
- ~~`graphics.md`~~ — why a context is only ever handed to you, the `DRAW` event and its three layers,
  state/transforms/shapes, paths, text, images, and the reference-counting rules
- ~~`api.md`~~ — conventions (errors, allocators, strings, ownership) then every area of `sciter_app`,
  plus what to reach for the raw table for
- ~~`ENGINE.md`~~ — what the shipped binary is built from (Skia, QuickJS, HarfBuzz, its own `wing::`
  X11/Wayland layer), what it links and dlopens at runtime, and the consequences for a host
  application. Measured with `readelf`/`nm`/`strings`, not quoted from sciter.com

**Examples** (`examples/`), each runnable with `just example NAME`, ordered by difficulty:

1. ~~`hello_window`~~ — done
2. ~~`api_map`~~ — done (diagnostic rather than tutorial, but it belongs here)
3. ~~`load_file`~~ — done: loading from disk, base URLs, relative references
4. ~~`eval`~~ — done, with 9 headless `Value` round-trip tests
5. ~~`call_odin_from_js`~~ — done, via native functors and a SOM asset (`Backend`), which is the
   runnable demonstration of `som.odin`
6. ~~`dom_walk`~~ — done, with 23 display-gated tests: selectors, traversal, nodes, the geometry
   queries, and building/moving/sorting elements
7. ~~`events`~~ — done, with 21 tests: the parameter accessors and the code/phase split headless,
   the trampoline, the subscription reply, both propagation phases and the element timers
   display-gated
8. ~~`drag_and_drop`~~ — done, with 3 decoding tests; no test can stage a system drag, so the sequence
   was established by driving a real X11 drag by hand
9. ~~`graphics`~~ — done, with 12 tests: paths, text, images and the 2D renderer
10. ~~`custom_loader`~~ — done: the `SC_LOAD_DATA` host callback, serving CSS and images from memory
11. ~~`request_loader`~~ — done, with 5 tests: the request API behind the callback, including every
    wrapper's answer to a nil handle
12. ~~`archive`~~ — done, with 6 tests: `packfolder` + `SciterOpenArchive`, resources inside the
    executable
13. ~~`single_binary`~~ — done, with 7 tests: the embedded engine, its cache naming and write-once
    behaviour
14. ~~`inspector`~~ — done
15. ~~`extension`~~ — done: Odin as a native extension the engine loads, via `adopt` (§11)
16. ~~`behavior`~~ — done, with 9 tests: `control_type`, `do_click` against `send_event`, a method of
    the caller's own through a `.METHOD_CALL` handler, hit testing and the window metrics
17. ~~`worker_thread`~~ — done, with 5 tests: `post_callback` from this thread and from a worker, the
    ordering, delivery by `heartbeat` alone, and the window that drops what it has no handler for
18. ~~`input`~~ — done, with 14 tests: `SciterTraverseUIEvent` driving a button, a checkbox and a text
    field for real, the `.FOCUS` / `.SCROLL` / `.ATTRIBUTE_CHANGE` / `.DATA_ARRIVED` accessors, the
    animation frame and its inverted return value, the element expando, `combine_url`, and
    `http_request` delivering the same way
19. ~~`named_behavior`~~ — done, with 9 tests: `SC_ATTACH_BEHAVIOR`, so a stylesheet rather than a call
    site decides which elements get Odin code, with the `.DETACH` ownership rule pinned.
20. ~~`video`~~ — done, with 12 tests: frames generated in Odin and streamed into a `<video>` element
    through `sciter::video_destination`, the one interface in the whole API that is a C++ vtable rather
    than a table slot. See §13.
21. ~~`task_list`~~ — done, with 11 tests: a whole small application, script-free - an Odin model that
    the DOM is a projection of, one `render`, keyboard commands through real key events, HTML escaping
    of user text, and state saved as JSON through a Value

Testing is example-driven — there is no engine source to unit-test against. Follow odin-dds and put
`@(test)` procs inside `examples/*.odin`. Headless-testable: library loading, the version handshake,
`Value` round-trips through `ValueInit`/`ValueFromString`/`ValueToString`/`ValueClear`, `SciterEval`
results, archive open/read, atom round-trips. Anything needing a window needs a display, so gate those
on `DISPLAY`/`WAYLAND_DISPLAY`. Run the headless subset under ASan on Linux — `Value` refcounting is
exactly the code that benefits, and per the skeleton README, Linux ASan catches heap errors that Windows
ASan does not.

---

## 11. Native extensions — the third architecture

Not in the original plan, and cheap enough once §8 existed to be worth doing: `scapp` and
[Quark](https://quark.sciter.com/) are a JavaScript-only path, and a native extension is the escape
hatch from it.

Three architectures, all supported by the same engine:

| | Who owns `main` | Your code is |
| --- | --- | --- |
| Embedding | your Odin executable | Odin, hosting the engine |
| scapp / Quark | the SDK's prebuilt `scapp` | JavaScript only |
| Native extension | `scapp`, or any Sciter host | an Odin shared library |

The contract is one exported symbol, declared in `sciter-x-api.h` and confirmed against the shipped
`sciter-sqlite.so` (`nm -D` shows exactly one `T SciterLibraryInit`):

```c
SBOOL SCAPI SciterLibraryInit(ISciterAPI* psapi, SCITER_VALUE* plibobject);
```

The host **hands over the API table**, so `load()` is wrong here — it would open a second copy of a
library that is already loaded. `sciter.adopt()` in `src/prelude.odin` takes the supplied table
instead, applying the same version check, after which every wrapper in `sciter_app` works unchanged.
`unload()` learned to skip the `dlclose` when the table was adopted, because the host owns the library.

Verified end to end under the SDK's `scapp`: the extension is loaded, `adopt` succeeds, and script
receives Odin-built values back —

```
ext.greet('scapp')  -> hello, scapp - from Odin, inside a Sciter extension
ext.version()       -> 6.0.4.9      (read through the adopted table)
ext.calls()         -> 3
ext.calls()         -> 4            (state persists inside the .so)
```

`scapp` is not vendored, so `just extension-run` needs `SCITER_SDK` pointing at a checkout. It
assembles a throwaway app folder under `target/` rather than writing into the SDK.

---

## 12. Open questions

- ~~**Repo size.**~~ **decided: vendor.** Offline `git clone && just example hello_window` is worth the
  bytes. Measured cost is ~40 MB of permanent history per engine bump once all three platforms are
  vendored (11 MB Linux, 8 MB Windows, 20 MB macOS, compressed), against 11 MB of `.git` today. The
  mitigations — upgrade deliberately, tell users to `--depth 1`, never keep two engine versions in the
  tree, record SHA-256s so a fetch-based fallback stays possible, and squash history onto an orphan
  branch if `.git` passes ~500 MB — are in [`UPGRADING.md`](./UPGRADING.md), along with why Git LFS and
  a binaries submodule are the wrong trade for a library whose pitch is "clone it and run an example".
- **Naming.** `sciter.SciterCreateWindow` maps 1-to-1 onto upstream documentation, which is worth a lot
  for a library whose users will be reading sciter.com. `sciter.create_window` reads better. The
  intended answer is both, in two packages: generated `package sciter` stays 1-to-1, ergonomic
  `package sciter_app` is snake_case and Odin-shaped.
- ~~**Version pin policy.**~~ **decided**, in [`UPGRADING.md`](./UPGRADING.md): pin one engine version
  at a time, upgrade when there is a reason rather than on upstream's roughly-weekly tag cadence, and
  tag releases after the engine they vendor — `v6.0.4.9`, with a `-N` suffix for bindings-only releases
  on the same engine. `api_map` on every bump is step 6 of a nine-step procedure, and is the step the
  procedure exists for.
- ~~**Windowless / lite.**~~ **done**, and it did cost little as predicted: `sciter_app/windowless.odin`
  wraps every `SXM_*` message over `SciterProcX`, and [`examples/windowless.odin`](../examples/windowless.odin)
  is a worked embedding with eleven tests - including a view rendering straight into a rectangle of a
  larger image the host owns. `on_invalidate_rect` turned out to work on a windowless view exactly as it
  does on a windowed one, so the hook side really was already there.

  Four things were measured that the headers do not say, and one earlier finding was **retracted**: the
  windowless mouse works. `EMBEDDING.md` had said it did not, because the page it was tested with caught
  clicks on an absolutely positioned overlay with a percentage height, and Sciter lays that out one
  pixel tall - so every event landed on `<body>`. The engine had been blamed for a stylesheet bug. What
  is genuinely missing is narrower: the intrinsic behaviors ignore the mouse (drive them through the
  element), script timers run on the wall clock rather than on the heartbeat's timestamp, one
  `SXM_DESTROY` ends windowless mode for the process, and the mode still needs a display.
- **A layer above the bindings.** Whether to add a retained-diff ("vdom") layer over the DOM, so that a
  list can be updated rather than rebuilt with `set_html` the way `task_list` does. Written up as a
  decision aid in [`VDOM.md`](./VDOM.md): the cost (~1,500-2,000 lines, all of the risk in keyed list
  reconciliation), the fact that it needs **nothing new from the engine**, when it would not be worth
  it, and a four-stage order in which the first two stages are independently useful. **Deferred** -
  there is not enough experience with a real Sciter application yet to judge the trade, and the
  recommended first move in that note is to write a harder example *without* a layer and see what
  actually hurts.

---

## 13. The C++ layer below the tables — **done for video**

Also not in the original plan. With `ISciterAPI`, the graphics table and the request table all wrapped,
the only reachable functionality left in the engine is the part that is **not in any table**: the
`sciter::om` interfaces, which are C++ classes of pure virtuals. `sciter-x-video-api.h` declares three -
`video_source`, `video_destination`, `fragmented_video_destination` - and nothing else in the SDK's
headers adds a fourth that the engine implements.

`video_destination` is now wrapped (`sciter_app/video.odin`, `examples/video`). What that took, and what
it says about doing the same again:

- **The vtable is read out of the binary before anything runs.** `libsciter.so` is stripped of its
  symbol table but keeps 52,770 mangled *dynamic* symbols, including
  `_ZTVN4html8behavior28fragmented_video_destinationE` with its size (`0x68` = 13 words = two of
  Itanium header plus eleven functions) and a relocation per slot naming the function that fills it.
  That is the whole layout question answered statically. The procedure is written up as §10 of
  [`RESEARCH-METHOD.md`](./RESEARCH-METHOD.md).
- **`asset_get_interface` does the pointer adjustment, and nothing else may.** The `som_asset_t` the C
  API hands over is one base subobject; the interface is another, 24 bytes earlier for `<video>`. The
  wrong offset is not a wrong answer, it is a destructor call.
- **The generic half is worth having on its own.** `asset_passport` / `asset_members` / `asset_call` /
  `asset_get` / `asset_set` / `asset_interface` in `som.odin` read *any* engine asset, so the same
  machinery reaches `<input>`'s `edit` behavior (`selectionStart`, `insertText`, …). Those members are
  the native interface and are not the same set script sees.

**`video_source` is the one left, and it is the hard direction.** It would let the element's own
controls drive playback - seek, pause, volume - by having the engine call *into* Odin. That means
building a C++ object Odin owns: a vtable of `proc "c"` in declaration order with an
`iasset`-compatible header, handed to `start_streaming`. Feasible, unverifiable by `api_map`, and worth
doing only when something actually wants seekable host-fed video.

`behavior:video`'s own playback is out of scope for a different reason: it is libVLC, and the engine
already drives it (see [`ENGINE.md`](./ENGINE.md)).
