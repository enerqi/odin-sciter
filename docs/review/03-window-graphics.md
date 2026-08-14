# Review: windowing, host callbacks, graphics, video, windowless, requests

Scope: `sciter_app/window.odin`, `sciter_app/host.odin`, `sciter_app/graphics.odin`,
`sciter_app/app.odin`, `sciter_app/video.odin`, `sciter_app/windowless.odin` (scanned),
`sciter_app/request.odin` (scanned), headers `sciter-x-def.h`, `sciter-x-msg.h`,
`sciter-x-graphics.h`, `sciter-x-request.h`.
Date: 2026-08-13

## Summary

Three things I expected to find wrong are right. The windowless message protocol has no `cbSize`
discipline to get wrong — `SCITER_X_MSG` is a bare `{ UINT msg; }` (`sciter-x-msg.h:37-43`) — so the
struct-literal-with-header-code pattern used throughout `windowless.odin` is correct and the zeroed
tail is intended. The host callback handles every live notification code: `sciter-x-def.h` defines
`SC_LOAD_DATA` 0x01 through `SC_SET_CURSOR` 0x0A with 0x03 marked obsolete in the header itself, and
`host_trampoline` has an arm for all nine. And the `video.odin` vtable is not guessed — the pointer
comes from `asset_interface`, with a comment at `som.odin:405-413` explaining that the engine is the
only thing that knows the subobject offset.

The one real defect is structural and affects two subsystems equally: `graphics_api()` and
`request_api()` return nil when the engine is not loaded, and every one of the ~90 procs built on them
dereferences that nil without checking. The rest of the package routes through `sciter.api()`, which
asserts with a sentence explaining the mistake. Graphics and requests are the two subsystems where the
first call a new user makes crashes with no message instead.

## Findings

### R3-01 — the graphics and request sub-API tables are dereferenced without the nil check `sciter.api()` makes  [severity: major]

**Where:** `sciter_app/graphics.odin:55-60` (`graphics_api`), `sciter_app/request.odin:45-50`
(`request_api`), and every call site in both files
**What:** both accessors are lazy and both can legitimately return nil:

```odin
graphics_api :: proc() -> ^sciter.Sciter_Graphics_Api {
    if g_graphics_api == nil && sciter.loaded() {
        g_graphics_api = sciter.api().GetSciterGraphicsAPI()
    }
    return g_graphics_api
}
```

Their own doc comments say so — "Nil only if the engine is not loaded." Every consumer then writes
`graphics_api().imageCreate(...)` / `request_api().RequestUse(...)` with no guard, so a call before
`sciter.load()` is a nil-pointer dereference through a function-pointer field.
**Why it matters:** the main table does the opposite, deliberately and with a comment saying why
(`src/prelude.odin:68-73`):

```odin
api :: proc(loc := #caller_location) -> ^Isciter_Api {
    fmt.assertf(g_api != nil, "sciter.load() must be called before any other sciter call", loc = loc)
    return g_api
}
```

`docs/architecture.md:30-33` promotes that assert to an architectural principle: "calling through a nil
table would fault deep inside the bindings with no indication of the real cause." Graphics and requests
are exactly where that reasoning applies hardest, because both are reachable without ever creating a
window — `paint_image` is documented at `graphics.odin:12-13` as the offscreen path that "works with no
window and no display, which makes it testable", so it is precisely the call a new user tries first, in
a test, before writing any `load()` boilerplate. They get a segfault at a function-pointer offset.
**Fix:** mirror `sciter.api()` in both accessors:

```odin
graphics_api :: proc(loc := #caller_location) -> ^sciter.Sciter_Graphics_Api {
    if g_graphics_api == nil && sciter.loaded() {
        g_graphics_api = sciter.api().GetSciterGraphicsAPI()
    }
    fmt.assertf(g_graphics_api != nil, "sciter.load() must be called before any graphics call", loc = loc)
    return g_graphics_api
}
```

and update both doc comments, which currently promise a nil return that no caller can survive.

### R3-02 — `serve` cannot answer with a legitimately empty resource  [severity: minor]

**Where:** `sciter_app/host.odin:50-57`
**What:**

```odin
serve :: proc(request: ^Load_Request, data: []u8) -> Load_Result {
    if len(data) == 0 {
        return .DISCARD
    }
    ...
}
```

**Why it matters:** an empty stylesheet, an empty JS module, or an empty `data.json` is a normal thing
for an application to serve — from an archive, from a database row, from a generated response. `serve`
turns all of them into `.DISCARD`, which `Load_Result`'s own doc at `host.odin:20` defines as "refuse
the request. The resource is simply never loaded." So the document behaves as though the file were
missing rather than empty, and there is no error anywhere. `serve_archive`
(`sciter_app/archive.odin:97-101`) routes through `serve`, so a zero-byte entry in a packed archive is
indistinguishable from an absent one — and `serve_archive` separately maps genuinely-absent to
`.DISCARD` too, with a deliberate comment explaining that choice, so the two cases collapse.
**Fix:** conflating "nothing to serve" with "an empty answer" is the bug. Either return `.OK` with
`outDataSize = 0` for an empty-but-present slice and reserve `.DISCARD` for `data == nil`, or add an
explicit `serve_empty`. Whichever, say in the doc comment which one an empty slice means — right now
neither the proc nor `Load_Result` mentions it.

### R3-03 — `save_image` allocates its scratch buffer from the caller's allocator and then copies  [severity: minor]

**Where:** `sciter_app/graphics.odin:196-220`
**What:** the `Byte_Sink` is given `allocator` (the caller's), accumulates the engine's chunks into it,
and then a second allocation from the same allocator receives an exact-size copy; the scratch is freed
by `defer delete(sink.out)`.
**Why it matters:** peak memory is twice the encoded image while the copy happens, and the caller's
allocator sees a grow-by-doubling sequence plus a final allocation for what should be one result. For a
PNG of a 4K window that is tens of megabytes of avoidable churn. Worse, the pattern breaks under the
allocators most likely to be passed here: with `context.temp_allocator` the `delete` is a no-op, so the
scratch is retained until the next `free_all` *and* the copy is retained — the doubling becomes
permanent for the arena's lifetime rather than transient.
**Fix:** accumulate into `context.temp_allocator` and make only the final exact-size copy from
`allocator`. One-word change to the `Byte_Sink` initialiser, and it makes the `defer delete` genuinely
free.

### R3-04 — `create_window` builds a degenerate frame when exactly one of width/height is zero  [severity: minor]

**Where:** `sciter_app/window.odin:35-44`
**What:**

```odin
frame := sciter.Tag_Rect{ left = ..., right = sciter.Int(opts.x + opts.width), ... }
pframe := &frame
if opts.width == 0 && opts.height == 0 {
    pframe = nil // let the engine choose
}
```

The "let the engine choose" escape requires *both* to be zero. `{width = 800}` — a perfectly natural
way to say "800 wide, you pick the height" — passes a frame whose bottom equals its top, i.e. a
zero-height window.
**Why it matters:** `Window_Options`'s field comment says "0,0 lets the engine pick", which describes
the pair but reads at a glance as a per-field rule, and the position comment immediately above says
"ignored unless width and height are set" — so the struct documents three interacting cases in two
lines and the code implements only the all-or-nothing one. The failure is a window that appears to
create successfully and has no visible content.
**Fix:** treat a zero in either dimension as "engine picks that dimension" if the engine supports it, or
— simpler and honest — reject the mixed case with `.Window_Failed` and say so in the field comment. The
current behaviour is the one thing that should not happen silently.

### R3-05 — the lazily-cached sub-API pointers are written without synchronisation  [severity: minor]

**Where:** `sciter_app/graphics.odin:50-60`, `sciter_app/request.odin:40-50`
**What:** `g_graphics_api` and `g_request_api` are package globals populated on first use, with a
plain `if x == nil { x = ... }`.
**Why it matters:** benign under the package's stated threading model — everything on the engine's
thread — but that model is stated in `docs/architecture.md` and in a comment in `host.odin:107-109`,
not next to these globals. `post_callback` exists precisely because applications *do* have worker
threads, and a worker that calls `request_api()` (say, to build a response off-thread before posting
it) races. The write is a single aligned pointer so it will not tear on any target here; the real cost
is that `GetSciterGraphicsAPI` could be called twice, which is harmless. So this is a documentation
defect more than a correctness one.
**Fix:** one comment on each global saying it is engine-thread-only, referring to the threading section
that already exists. If the threading rule is ever relaxed, these are two of the places that have to
change.

### R3-06 — `video_destination` depends on passport walking that R1-01 shows is unsafe on constants  [severity: minor]

**Where:** `sciter_app/video.odin:124-141`
**What:** the lookup chain is `element_asset` → `asset_call(asset, "renderingSite")` → `value_to_asset`
→ `asset_interface`. `asset_call` reads `Som_Method_Def_T.func`, which is a plain field with no union
(`sciter-om-def.h:85`), so this path is safe as written.
**Why it matters:** it is worth recording that it *is* safe, because the neighbouring property path is
not — see finding R1-01 in `01-value-som.md`, where `asset_get`/`asset_set` read
`som_property_def_t.u.accs` without checking `type`. `examples/video.odin:419` calls `asset_get` on an
engine asset, so the video example exercises both the safe method path and the unsafe property path.
When R1-01 is fixed, this is the call chain to re-check first.
**Fix:** no change here. Add a line to the comment at `video.odin:132` noting that the method path is
union-free and the property path is not, so the distinction is not rediscovered.

## Nits

- `sciter_app/graphics.odin:33-34` — the header comment explains that `release_*(nil)` is `nil` while
  `retain_*(nil)` is `.BAD_PARAM`, "because that is what a `defer` after a failed create does". That is
  a good asymmetry, deliberately chosen and documented; noting it here only so a future reviewer does
  not file it as an inconsistency the way I nearly did.
- `sciter_app/window.odin:236-238` — `window_state` returns `sciter.Sciter_Window_State` and the doc
  says a closed window answers `0xFFFFFFFE`, which is not a member of the enum. Returning an
  out-of-range enum value is UB-adjacent in Odin's model even though it works. A `(state, ok)` pair, or
  an explicit `.Dead` member, would make the documented `switch` default unnecessary.
- `sciter_app/host.odin:388` and `:396` — `strings.clone(string(kr.keyboardType), ...)` and the
  `cursorUrl` equivalent clone into `context.temp_allocator` inside a callback that nothing frees. Same
  unbounded-arena shape as R1-04, but these two fire rarely enough (`on_set_cursor` measured zero times
  in windowed mode) that it is only worth mentioning alongside the debug-output fix.
- `sciter_app/windowless.odin:8-14` — the file header says the protocol was derived from the examples
  "not read off the headers". Now that `sciter-x-msg.h` has been checked and `SCITER_X_MSG` is confirmed
  to be a bare `{ UINT msg; }` with no size field, that sentence undersells the result: it is worth
  saying the header was later confirmed to agree, so nobody re-derives it.
