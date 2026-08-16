# How the findings in `PLAN.md` were researched

A record of the actual method — what was asked, which tool answered it, and why that tool. Written so
the findings can be re-derived or challenged, and so the same approach can be reused when Sciter ships a
new version.

It includes the part that went wrong. The first pass of this research built a complete and internally
consistent picture of Sciter that was four years out of date, and the only thing that caught it was a
runtime check against the actual shipped binary. That is the most transferable lesson here, so it gets
its own section rather than being quietly corrected.

---

## 1. Establish the baseline: how does a comparable project do it?

Before reading anything about Sciter, look at the project that is meant to be the model.

```sh
ls -la $HOME/dev/odin-dds
find . -path ./.git -prune -o -path ./target -prune -o -type f -print
head -30 .gitattributes
grep -n '^[a-z0-9_-]*:' justfile
cat bindgen.sjson
cat src/prelude.odin
```

This established the conventions to follow — `external/<lib>/` for vendored upstream, `lib/` for
binaries, `bindgen.sjson` + `src/prelude.odin` for generation, examples-as-tests, a `just` task list,
and a `.gitattributes` explicit about binary files rather than trusting Git's NUL-byte heuristic.
Reading `README.md` in full mattered more than the file listing: it documents *why* each choice was
made, and those reasons carry over.

Checking the toolchain is cheap and assumptions here are expensive:

```sh
odin version                        # dev-2026-08:8412dc37a
ls $HOME/dev | grep -i bindgen      # odin-c-bindgen present
```

## 2. Get the primary text locally, then grep it

`WebSearch` was used once, for orientation. Its value was not the summary but the shape it revealed:
every binding for Sciter, in every language, goes through a single struct of function pointers.

`WebFetch` was used for repository structure — the GitHub contents API, one call per directory — and to
read `LICENSE`. It was deliberately **not** trusted for header content: it summarises through a small
model, and a summary of a struct definition is worthless when the entire question is exact field order.

So the headers were pulled verbatim and every structural question after that was answered by `grep` and
`sed` against local text — exact, cheap, repeatable:

```sh
# Where does the struct start and end, and how is the API obtained?
grep -n "} ISciterAPI\|SciterAPI_ptr\|SCITER_DLL_NAME\|dlopen\|LoadLibrary" sciter-x-api.h

# What is the calling convention?
grep -n "define SCFN\|define SCAPI\|SC_CALLBACK" sciter-x-primitives.h    # __stdcall on Windows

# Is WCHAR 2 bytes or 4 on Linux? (the classic FFI trap)
grep -n "WCHAR\|LPCWSTR\|wchar_t\|char16_t\|SBOOL" sciter-x-primitives.h  # char16_t everywhere
```

The single most valuable grep was the one that asked *where the conditional compilation is*:

```sh
sed -n '50,305p' sciter-x-api.h | grep -n "WINDOWLESS\|#if\|#else\|#endif"
```

Six `#if` blocks, none of them `WINDOWLESS`. Reading those six showed every platform-specific slot is
NULL-padded with `LPVOID` on the platforms that lack it — so the struct layout is platform-invariant,
one Odin definition serves everywhere, and the bindings can be generated on whichever platform is most
convenient. That one finding determined the package structure, the bindgen configuration, and the
platform strategy at once.

**In a cross-platform C header, `#if` placement *is* the layout question.** Grep for it first.

## 3. Interrogate the binary, not the docs

Headers describe intent. The shipped library describes reality. Three questions, three standard binutils
tools:

**What must be installed to run it?** `ldd` resolves the full transitive set and, critically, reports
anything unresolved:

```sh
ldd bin/linux/x64/libsciter.so
ldd bin/linux/x64/libsciter.so | grep -i "not found"    # empty
```

**Is `SciterAPI` really the only entry point?**

```sh
nm -D --defined-only libsciter.so | grep -w SciterAPI   # 00000000007e4a19 T SciterAPI
nm -D --defined-only libsciter.so | wc -l               # 52051
```

52,051 exported symbols, but they are vendored third-party internals (Skia, QuickJS, libwebp, libjpeg)
and the engine's own C++ classes. Exactly one is the documented API. That confirms the vtable is not a
convenience wrapper — it is the only way in. What the rest of them are is in [`ENGINE.md`](./ENGINE.md).

The same tool answered a question that shaped the whole generation pipeline. The headers declare ~163
flat prototypes (`UINT SCAPI ValueInit(VALUE*)`, `HWINDOW SCAPI SciterCreateWindow(...)`). Are they
exported?

```sh
for s in SciterCreateWindow SciterLoadHtml ValueInit SciterGetRootElement; do
  nm -D --defined-only libsciter.so | grep -w "$s"
done                                                     # nothing
```

None of them. In C they resolve to `inline` wrappers that forward to `SAPI()->...`. bindgen would have
generated ~163 Odin `foreign` procedures that cannot link. They are stripped in the flatten step
instead — a whole class of wrong bindings removed because of one `nm` loop.

## 4. Compile the assumption

Two claims were load-bearing and both were cheaper to test than to research.

**Does Odin have a `"system"` calling convention?** Grepping the compiler source was inconclusive, so
the compiler was asked directly with a four-line file:

```odin
package cctest
Api :: struct {
	f: proc "system" (a: i32) -> i32,
	g: proc "c"      (a: i32) -> i32,
}
main :: proc() {}
```

```sh
odin build . -out:/dev/null     # exit 0
```

Exit 0. `proc "system"` exists and is right: `__stdcall` on 32-bit Windows, matching Sciter's `SCAPI`,
and the platform default elsewhere.

**Does the ABI theory hold at all?** A ~40-line Odin program declared only the first eight members of
`ISciterAPI`, opened the library with `core:dynlib`, resolved `SciterAPI`, called it, and read those
slots. Truncating the struct is safe — the engine owns the memory and only fields at the front are read
— which is what makes an incremental spike possible without first transcribing 189 members. (The
program itself is gone, superseded by [`examples/hello_window.odin`](../examples/hello_window.odin) and
by [`examples/api_map.odin`](../examples/api_map.odin), which verifies the whole vtable mechanically
rather than its first eight slots. It is in the history if anyone wants it.)

Every number it printed was a separate confirmation: `version` matching `SCITER_API_VERSION` proves the
struct starts where we think and the `u32`-then-pointers padding is right; `SciterClassName()` returning
`"sciter-view"` proves slot 1's offset *and* that `WCHAR` is genuinely UTF-16 on Linux (checked twice —
first by dumping raw code units, `115 99 105 116 101 114 45 118 105 101 119 0`, one `u16` per ASCII
character with no interleaved zeros, so not `wchar_t`; then by decoding through `core:unicode/utf16`).

**A 40-line spike is worth more than a chapter of design.** It converts the riskiest part of an FFI
project from unknown to done before any bindings exist.

## 5. Where it went wrong, and what caught it

Everything above was done against the GitHub repository `c-smile/sciter-js-sdk` — the one search engines
surface. Headers and binary came from the same tree, the version handshake succeeded, the smoke test
printed sensible numbers, `bindgen` produced a clean `sciter.odin`, and `odin check` passed. Every
signal was green.

Then the first window attempt segfaulted. `gdb` gave the decisive clue, and it was the *shape* of the
backtrace rather than its content:

```
Program received signal SIGSEGV
0x00007ffff698b7b7 in sciter::om::iasset<...>::thunk_asset_add_ref(som_asset_t*) () from libsciter-gtk.so
#1  0x000055555557b523 in main::main ()
```

The call was `SciterExec`. It landed in `thunk_asset_add_ref`. **A crash inside a function you did not
call means the offset is wrong, not the argument.** Argument bugs crash inside the right function.

That turned the question from "what did I pass" into "does this struct match this binary", which is
answerable directly. `examples/api_map.odin` walks the table with `core:reflect` and resolves each
pointer with `dladdr`:

```odin
fields := reflect.struct_fields_zipped(sciter.Isciter_Api)
slot := (^rawptr)(uintptr(api) + f.offset)^
dladdr(slot, &info)   // -> info.dli_sname
```

Slots 0–183 all resolved to their own name. Slots 184 and 185 — `SciterExec`, `SciterWindowExec` —
resolved to unrelated symbols. The header declared two slots the shipped engine did not implement; the
reads ran past the end of the real table into adjacent data.

Two checks then explained why:

```sh
curl -s "https://api.github.com/repos/c-smile/sciter-js-sdk/commits?per_page=1"
# github mirror HEAD: e3f9580f25  2022-04-19

curl -s "https://gitlab.com/api/v4/projects/sciter-engine%2Fsciter-js-sdk/repository/tags?per_page=15"
# 6.0.4.9-bis  2026-08-02
# 6.0.4.9      2026-08-02
# ...
```

The GitHub mirror is abandoned — four years stale, engine 4.4.8.33, API version 9, and internally
inconsistent at its final commit. GitLab is the live repository, at engine 6.0.4.9, API version 10.

Re-running the same probe against the GitLab `6.0.4.9-bis` engine: **189 slots checked, 16 null
(platform-padded), 0 mismatches**, all the way through `SciterRequestPaint`.

What generalises:

- **Prefer the upstream's own forge over the mirror.** "First search result" and "most linked" are not
  freshness signals. One API call for each repository's HEAD date would have caught this before any code
  was written; it now happens as part of vendoring, recorded in `external/sciter/VENDORED.md`.
- **A successful version handshake is not a compatibility check.** `api.version == 9` was true and
  meaningless. It validates a number, not a layout.
- **For a vtable ABI, verify the layout against the binary, mechanically.** `dladdr` over every slot is
  about forty lines, runs in a second, and is the only check here that could have failed usefully. It
  is now a permanent example rather than throwaway debugging, and re-running it is a required step on
  every SDK bump.
- **Read the crash's shape.** Landing in a function you never called is an offset bug. That single
  observation redirected the investigation from a dead end.

## 6. Re-reading the same questions against 6.x

With the correct source, the earlier findings had to be re-checked rather than assumed to carry over.
Several had changed outright:

| Question | 4.4.8.33 (stale) | 6.0.4.9 (actual) |
| --- | --- | --- |
| Linux library | `libsciter-gtk.so` | `libsciter.so` |
| Linux dependencies | GTK3, GDK, cairo, pango, X11, Wayland (~40) | fontconfig, freetype, EGL, GLESv2, png, brotli (16) |
| `HWINDOW` on Linux | `GtkWidget*`, header includes `<gtk/gtk.h>` | `void*`, no GTK anywhere |
| `SCITER_API_VERSION` | 9 (0x10009 windowless) | 10, unconditional |
| `SciterVersion` | `(SBOOL major)`, two components packed per call | `(UINT n)`, index 0..3 |
| Window flags | 11, incl. `SW_TITLEBAR`, `SW_RESIZEABLE` | 4; the rest commented out upstream |
| Licensing | `LICENSE` (BSD 3-Clause) | `LICENSE` **and** `SCITER-ENGINE-EULA.md` |

The licensing one is worth dwelling on, because the first pass got it wrong in a way that reads
plausibly. The repository has a BSD 3-Clause `LICENSE`, so "the SDK is BSD, therefore the `.so` is BSD"
is a natural inference — and wrong. 6.x ships `SCITER-ENGINE-EULA.md` alongside it, covering the engine
binary specifically: copyright retained, free commercial use, and a required attribution link in the
application's About box. `ls` on the repository root is what surfaced it; no amount of re-reading
`LICENSE` would have.

The generation pipeline needed re-checking too, and mostly got simpler: the `WINDOWLESS` define that
existed only to dodge `<gtk/gtk.h>` became unnecessary, and `INT_PTR` is now typedef'd upstream. But
6.x introduced its own C-validity bugs, found the same way — run `bindgen`, read the clang errors, fix
the smallest thing that resolves each:

- `sciter-x-primitives.h` typedefs `INT_PTR` twice on Linux, the second time as `ssize_t`, which nothing
  declares
- `HELEMENT` is forward-declared identically in both `sciter-x-dom.h` and `sciter-x-request.h`

Both are legal-ish C that Odin will not accept as two declarations, and both are handled by one-line
patches in `src/flatten_headers.py` that **hard-error if they stop matching** — so the next SDK bump
cannot silently drop one.

## 7. Reading the C++ layer without shipping it

`sciter-x-window.hpp` is not vendored — these bindings target the C ABI — but it is the authority on how
the engine is *meant* to be started, and it settled a question the C headers get wrong.

`SCITER_APP_INIT` is documented in `sciter-x-def.h` as `p2 - CHAR** argv`. Passing `char**` crashed;
passing `NULL` crashed. The C++ header shows why:

```cpp
inline void start() {
  std::vector<const WCHAR*> args;
  for (auto& arg : argv()) args.push_back(arg.c_str());
  SciterExec(SCITER_APP_INIT, (UINT_PTR)args.size(), (UINT_PTR)&args[0]); }
```

UTF-16, not `char**`. The comment in the C header is simply stale.

**When a C API's own comments disagree with its C++ convenience layer, believe the layer** — it is
compiled and used by the vendor's own samples; the comment is not.

## 8. Measuring instead of assuming

The SDK clone was measured, repeatedly, rather than estimated:

```sh
du -sh $HOME/dev/sciter-js-sdk/.git    # 838M ... 1.5G ... 2.1G ... 3.9G
```

800+ commits each carrying every platform's binaries. That is why `PLAN.md` recommends `--depth 1` or
the release archive, and why `VENDORED.md` says so at the top.

## 9. Staging an interaction the test runner cannot

Drag-and-drop is delivered by the window system, so no `@(test)` can produce one and the header's
description of the protocol - "drop target element shall consume this event in order to receive X_DROP"
- had to be checked some other way.

The rig is one small program and a nested X server, so nothing touches the real desktop:

```sh
Xephyr :77 -screen 1024x768 &          # a second X server, in a window
DISPLAY=:77 ./drag_and_drop &          # the example under test
DISPLAY=:77 python3 tools/xdnd_source.py       # ctypes, no dependencies: a synthetic XDND drag source
```

The source is the smallest XDND implementation that works: find the window advertising `XdndAware`,
own the `XdndSelection`, then `XdndEnter` -> `XdndPosition` -> read `XdndStatus` -> `XdndDrop`. The
engine's answer in `XdndStatus` is the measurement - it says, in one bit, whether the host's handler
convinced the engine to accept the drop.

That bit is what turned a guess into a rule. Consuming `.WILL_ACCEPT_DROP` alone, which is all the
header asks for, answers `accept=False` and no `.DROP` follows. The matrix over all combinations:

| consumed | `XdndStatus` | `.DROP` delivered |
| --- | --- | --- |
| nothing | accept=False | no |
| `.DRAG` | accept=False | no |
| `.WILL_ACCEPT_DROP` | accept=False | no |
| `.WILL_ACCEPT_DROP` + `.DRAG_ENTER` | accept=False | no |
| `.WILL_ACCEPT_DROP` + `.DRAG` | **accept=True** | **yes** |

The same rig showed two things that are easy to assume the other way: the payload `Value` arrives as an
empty map on Linux, and consuming an event in both the sinking and the bubbling pass counts the drop
twice.

The generalisable part is the shape: put the engine in a disposable display, drive the *protocol* rather
than the input device, and find the one bit the engine sends back that says whether it agreed. XTEST
mouse synthesis was tried first and is strictly worse - it moves a real pointer, and it cannot tell you
what the engine concluded.

## 10. Reading a C++ vtable out of a stripped binary

`sciter::video_destination` is the one interface with no C declaration: a class of pure virtuals in
`sciter-x-video-api.h`, invisible to the binding generator, usable only by laying its virtual table out
in Odin. The layout is an ABI assumption, and getting it wrong does not fail cleanly — a wrong slot
index calls whatever else is at that offset.

The naive plan was to get a live destination and dump the table. That is the wrong order: it needs a
working `<video>` before there is anything to measure, and on this machine there is none (§ libVLC, in
[`ENGINE.md`](./ENGINE.md)). The order that worked is **static first, then live**.

`libsciter.so` has no symbol table — `nm` says "no symbols" — but it has 52,770 **dynamic** symbols,
with full Itanium mangling. The whole class hierarchy is in there:

```sh
nm -D --defined-only lib/linux/x64/libsciter.so | c++filt | grep 'behavior.*video'
# html::behavior::vlc_video_ctl::play()
# html::behavior::custom_video_ctl::asset_get_passport() const
# html::behavior::zero_video_ctl::start_streaming(int, int, int, sciter::video_source*)
# ...
```

Including the vtable itself, with its size:

```sh
nm -D --defined-only -S lib/linux/x64/libsciter.so | grep fragmented_video_destination
# 0000000001767080 0000000000000068 V _ZTVN4html8behavior28fragmented_video_destinationE
```

`0x68` is 13 words: two of Itanium header plus **eleven** functions — exactly the count the header
declares. Reading the words themselves gives zeroes, because a vtable lives in `.data.rel.ro` and is
filled in by the dynamic loader; the answer is in the relocations, not the bytes:

```sh
readelf -rW lib/linux/x64/libsciter.so | grep -A12 '^0000000001767080'
# ... _ZN6sciter2om6iassetINS_17video_destinationEE19asset_get_interfaceEPKcPPv
# ... __cxa_pure_virtual   (x9 - is_alive, start_streaming, render_frame, ...)
```

That is the slot order, named, before a single line of Odin exists — and `__cxa_pure_virtual` in nine
of the eleven confirms it is the abstract interface rather than some implementation that reordered
things.

Only then is the live check worth doing, and it is one `dladdr` per slot against a real destination:

| slot | resolves to |
| --- | --- |
| 4 | `zero_video_ctl::is_alive()` |
| 5 | `zero_video_ctl::start_streaming(int, int, int, sciter::video_source*)` |
| 10 | `zero_video_ctl::render_frame_part(unsigned char const*, unsigned, int, int, int, int)` |

Every slot named what the header said it should be. Two lessons came out of the attempt that skipped
this step:

- **The interface pointer is not the asset pointer.** `SciterGetElementAsset` hands back the
  `som_asset_t` of one base subobject; the `video_destination` base is 24 bytes earlier. Guessing that
  offset lands the vtable pointer on a *different* class's table, where slot 4 turned out to be
  `custom_video_ctl::~custom_video_ctl()` — calling `is_alive()` ran a destructor and dumped core.
  `asset_get_interface` exists precisely because it is the only thing that knows the offset, and using
  it removes the arithmetic from the problem entirely.
- **`strings` under-reports.** Only `fragmented.destination.video.sciter.com` appears in the binary;
  `destination.video.sciter.com` is the same literal, tail-merged by the linker, and shows up as a
  second `lea` at `+0x34` and `+0x3f` of the same address. Both names work at runtime. A grep over
  `strings` output would have concluded the plain interface did not exist.

The generalisable part: **when the ABI is the risk, verify it out of the binary before running
anything.** A stripped library still carries mangled dynamic symbols and relocations, and between them
they name every slot. The live run is then a confirmation with a known-good answer to check against,
rather than an experiment whose failure mode is a corrupted process.

---

## Summary of what generalises

- Get the primary text locally, then grep it. Summarising tools are for orientation, useless for struct
  field order.
- Ask the binary, not the docs, about dependencies, entry points and exported symbols. `ldd`, `nm -D`
  and `file` answer in seconds what would otherwise be assumptions.
- Grep for the conditional compilation first: in a cross-platform C header, `#if` placement is the
  layout question.
- Compile the assumption. Whether `proc "system"` exists is a five-second `odin build`.
- A 40-line spike beats a chapter of design.
- Verify a vtable ABI against the binary mechanically, and keep the verifier as an example. A version
  handshake is not a compatibility check.
- Read the crash's shape: landing in a function you never called is an offset bug.
- Check the upstream forge's freshness before trusting a mirror, and record what you pinned.
- When an interaction cannot be staged in a test, stage the protocol underneath it in a disposable
  display, and measure the answer the engine sends back rather than what the screen looks like.
- When the ABI is the risk, read it out of the binary before running anything. A stripped library still
  has mangled dynamic symbols and relocations, and a vtable's size and slot order are both in there.
- Never compute a C++ subobject offset by hand when the object will do it for you. `asset_get_interface`
  is a `dynamic_cast`; guessing its answer calls a destructor.
