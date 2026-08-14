# Review: type safety and Odin idiom

Scope: the public surface of all 11 `sciter_app/*.odin` files (409 top-level `:: proc` declarations),
`src/prelude.odin`, `docs/typing.md`, headers `sciter-x-api.h`, `sciter-x-behavior.h`,
`sciter-om-def.h`.
Date: 2026-08-13

This angle was set by the maintainer's own note in `docs/typing.md`, so it answers those four questions
directly first, then reports what else the measurement turned up.

---

## Answers to `docs/typing.md`

### "is `eventCode` a constrained set of numbers in the C headers? `appEventCode`?"

**Both are already correctly typed, and neither is a closed set.** The headers:

```c
SCDOM_RESULT SCFN( SciterSendEvent)( HELEMENT he, UINT appEventCode, HELEMENT heSource, UINT_PTR reason, SBOOL* handled);   // sciter-x-api.h:157
SCDOM_RESULT SCFN( SciterPostEvent)( HELEMENT he, UINT appEventCode, HELEMENT heSource, UINT_PTR reason);                   // sciter-x-api.h:158
SCDOM_RESULT SCFN(SciterRequestAnimationFrameEvent)(HELEMENT he, UINT eventCode, UINT_PTR reason);                          // sciter-x-api.h:287
SCDOM_RESULT SCFN(SciterEGLSendEvent)(HELEMENT he, UINT eventCode, UINT_PTR reason);                                        // sciter-x-api.h:286
```

All four are `UINT`, and all four carry a `BEHAVIOR_EVENTS` value. The wrapper already types the three
it exposes — `send_event`, `post_event` (`events.odin:756`, `:779`) and `request_animation_frame`
(`events.odin:727`) all take `code: sciter.Behavior_Events`. So the question is answered: yes, they are
that enum, and yes, the binding already says so.

The follow-on that matters more: **`BEHAVIOR_EVENTS` is deliberately open-ended.** It has
`FIRST_APPLICATION_EVENT_CODE`, above which the application defines its own codes, and the docs tell you
to use it (`events.odin:741-742`, `behavior.odin:190`). So the enum is a *partial* naming of a `UINT`
space, and a user's own code reaches the API as `sciter.Behavior_Events(MY_CODE)` — a value with no
enum member. That is legal in Odin and it is the right trade, but it has two consequences nothing states:
a `switch` on `Behavior_Event.code` needs a `case:` default or it silently ignores every application
code, and `-vet` may object to the conversion.

**Recommendation:** keep the enum. Add a sentence to `Behavior_Event.code`'s doc and to
`Fired_Event.code`'s saying the enum is a partial naming and that a `switch` on it needs a default arm.
Consider a helper `app_event :: proc(n: u32) -> sciter.Behavior_Events` that asserts
`n >= FIRST_APPLICATION_EVENT_CODE`, so the conversion has one spelling and one check.

### "distinct: where would it help, balanced against friction?"

The pass already done is good and the friction is real but paid in the right places. Currently distinct:
`Child_Index`, `Node_Index`, `Parameter_Index`, `Request_Header_Index`, `Response_Header_Index` (all
`distinct int`), `Element_Uid` (`distinct u32`), `Atom` (`distinct u64`), plus the handle types
(`Element`, `Node`, `Window`, `Archive`, `Image`, `Graphics`, `Path`, `Text`, `Color`, `Request`).

The `Child_Index` / `Node_Index` pair is the one that earns its keep, and the reasoning at
`node.odin:96-107` is exactly right: they are two numberings of the same parent, the counts differ, and
handing one to the other's accessor silently finds the wrong element. That is a bug a type can prevent
and a comment cannot.

**Ranked recommendations for what remains:**

1. **`Timer_Id :: distinct uintptr` — do it.** `set_timer(element, interval, id)`,
   `stop_timer(element, id)` and `Timer_Event.id` (`events.odin:674`, `:686`, `:316`) all pass a bare
   `uintptr`. Its neighbours in the same file are also `uintptr`: `reason` on `send_event`, `post_event`,
   `request_animation_frame` and `Fired_Event`, and `wparam`/`lparam` on `post_callback`. Six bare
   `uintptr`s in one file, four of them adjacent in signatures, and `set_timer(el, dt, reason)` type
   checks. Friction: a handful of `Timer_Id(...)` casts at call sites that mint an id from a constant —
   and those are exactly the sites where being explicit is a feature.
2. **`Http_Status :: distinct u32` — probably not, but document harder.** `Data_Arrived.status`
   (`events.odin:592`), `succeed_request(..., status: u32 = 200)` and `fail_request(..., status: u32 =
   404)` share a name and *do not share a scale* — `events.odin:577-587` documents four different
   meanings for the incoming one, including that a successful `file://` load answers 0. A distinct type
   would not fix that, because the problem is one type with four meanings, not two types being confused.
   The existing four-bullet comment is the right fix and is already there.
3. **`Event_Cmd :: distinct u32` — skip.** `event_code(cmd)`, `event_phase(cmd)` and `mouse_code(cmd)`
   take a raw `cmd`, but callers get it from `raw.cmd` on a typed params struct and hand it straight
   back. There is nothing to confuse it with.
4. **The three request index types — consider collapsing to one.** `Parameter_Index`,
   `Request_Header_Index` and `Response_Header_Index` (`request.odin:414-416`) index three lists on the
   same object. Unlike `Child_Index`/`Node_Index`, these are not two numberings of one thing that a
   caller might mix up while walking — you get each from its own `*_count` and hand it straight to its
   own accessor, in the same expression. Three types where one would do is friction without a
   corresponding bug class. This is the one place the `distinct` pass went one step past the line.
5. **Pixel/length types — skip.** `Rect`, `location`, `send_mouse` and the graphics calls all traffic in
   `i32`/`f32` coordinates in documented spaces (`.Self`, `.View`, `.Root`, `.Container`). The space is
   the thing that gets confused, not the unit, and `Origin` already names it as an enum argument. A
   `Ppx :: distinct i32` would add casts everywhere and prevent nothing.

### "default params: what is commonly nil/one value?"

**This is already done, and the measurement says it worked.** Fifteen public procs take a defaulted
`bool`, and across all 29 examples only **two** call sites pass a bare positional `true`/`false`
(`sciter_app.windowless_focus` and `sciter_app.activate`, once each). Everywhere else the default is
taken or the argument is named. That is the outcome default parameters are for.

Allocator parameters are consistently last and consistently `:= context.allocator` — 41 occurrences
across 12 files, no outliers found.

**One default worth re-examining:** `remove_element(element, finalize := true)` (`dom.odin:596`) and
`node_remove(node, finalize := true)` (`node.odin:234`). The default destroys. For `remove_element` the
non-default branch is the one with the subtle contract — it hands the caller a reference, taken *before*
the detach, and the comment explains why (`dom.odin:591-595`). Defaulting to the destructive option is
defensible (it is what a caller usually wants and it cannot leak), but it means the safe-looking call
`remove_element(el)` is the irreversible one. At minimum the doc's first line should say "destroys it"
rather than leading with the flag.

### "odin wrappers: where is the API still ugly?"

Three places, in order of how often they will be hit:

1. **The `Value` clear dance.** `value_clear` appears **294 times** across 16 example files. Every
   engine-produced Value owes a `defer value_clear(&v)`, and the discipline is stated plainly at the top
   of `value.odin`. It is correct and it is the single highest-frequency piece of ceremony in the
   package. Odin cannot give this a destructor, but `value_clear_all :: proc(vs: ..^Value)` would collapse
   the common three-or-four-Value block, and a `scoped_value` pattern is worth thinking about.
2. **Reading a string out of the engine.** Four separate procs (`text`, `html`, `attribute`, `style`)
   each build a `String_Sink`, pass a `proc "system"` receiver, and return an allocated string. The
   plumbing is `@(private)` and invisible to users, so this is not friction they feel — but a caller who
   wants *several* attributes pays one allocation each with no batch form. `attributes()` exists and is
   the right shape; there is no equivalent for reading a known set of names.
3. **Building an asset class.** `make_asset_class(name, properties, methods, allocator)` requires
   declaring `Asset_Property` and `Asset_Method` literals with matching getter/setter procs, and the
   32-member ceiling is a hard constant. The example at `som.odin:7` is one line and readable; the real
   friction is that each getter/setter is a separate top-level proc taking `^Asset` and digging
   `user_data` out. Nothing to fix in the type system — worth noting it is the roughest surface.

---

## Findings

### R8-01 — `Api_Error` variants are reused for failures they do not describe  [severity: minor]

**Where:** `sciter_app/sciter_app.odin:39-51`; misuses at `app.odin:127`, `app.odin:206`,
`app.odin:212`, `archive.odin:43`, `som.odin:124`
**What:** `Load_Failed` is documented as "SciterLoadHtml / SciterLoadFile returned FALSE" and is also
returned by `set_option`, `set_master_css`, `append_master_css` and `close_archive`. `Wrong_Type` is
documented as "a Value held something other than what was asked for" and is also returned by
`make_asset_class` when a member list exceeds `MAX_ASSET_MEMBERS`.
**Why it matters:** this is the same defect as finding R1-07, restated here because it is a *type design*
problem rather than a local bug: the enum's eleven variants were chosen carefully enough that each has a
one-line comment, and five call sites undo that by borrowing the nearest available name. The error union
exists so that "the distinction between, say, INVALID_HANDLE and PASSIVE_HANDLE is the whole diagnosis"
(`sciter_app.odin:26-28`) — the same care is owed on the `Api_Error` side.
**Fix:** add `Option_Failed` and `Too_Many_Members`; point `close_archive` at `.Not_Found` or a new
`Archive_Failed`. Five call sites, no signature changes.

### R8-02 — three procs return a bare `bool` where the rest of the package returns `Error`  [severity: minor]

**Where:** `sciter_app/app.odin:19` (`load_engine`), `sciter_app/video.odin:146` (`video_is_alive`),
`sciter_app/video.odin:173` (`video_stop_streaming`), `sciter_app/video.odin:186`
(`video_render_frame`) and the other `video_render_*` procs
**What:** `load_engine` returns `bool` and prints to stderr; every `video_*` render call returns `bool`.
**Why it matters:** `or_return` is the package's idiom and these break the chain — a caller writing a
frame pump has to switch styles mid-expression:

```odin
dest := sciter_app.video_destination(el) or_return       // Error
if !sciter_app.video_render_frame(dest, buf) { ... }     // bool
```

For `load_engine` the `bool` is deliberate and right: it is the "print the diagnosis and give up"
convenience over `sciter.load`, which does return a typed error, and its doc says so. For the video
calls it is inherited from the C++ vtable, which returns `bool` and offers nothing more — so there is
genuinely no error to report. That is worth *saying*, because the asymmetry currently reads as an
oversight.
**Fix:** one line in `video.odin`'s header comment: the destination interface reports failure as a bare
`bool` and carries no error code, so these procs cannot do better. No code change.

### R8-03 — `Event_Phase` is an enum over two orthogonal facts  [severity: major, duplicate of R2-02]

**Where:** `sciter_app/events.odin:101-129`
Recorded here because it is the clearest *typing* defect in the package rather than a logic bug:
`PHASE_MASK` is a direction (`BUBBLING = 0` / `SINKING = 0x8000`) plus an independent flag
(`HANDLED = 0x10000`), and modelling all three as one enum makes the direction unreadable once anything
has handled the event. Full detail and fix in `02-dom-events.md`.

### R8-04 — `sciter.Behavior_Events` is used as both a closed enum and an open number space  [severity: minor]

**Where:** `events.odin:727`, `events.odin:756`, `events.odin:779`, `events.odin:905`;
`behavior.odin:190`
**What:** covered in the `typing.md` answer above. The type is right; the contract is unstated.
**Why it matters:** `request_animation_frame`'s doc (`events.odin:717-720`) already flags the sharpest
consequence — "the default here is `.BUTTON_CLICK`'s numeric value 0 in the C API, which would be
indistinguishable from a real click" — which is the same open-set problem seen from the other end. A
reader who has not met that paragraph has no reason to expect that a `switch` on `Behavior_Event.code`
can miss values.
**Fix:** as above — document the partial naming on `Behavior_Event.code` and `Fired_Event.code`, and add
an `app_event(n)` constructor that asserts the floor.

### R8-05 — `Popup_Placement` is a hand-written enum whose values are the C API's, with no link to it  [severity: nit]

**Where:** `sciter_app/dom.odin:413-423`
**What:** the nine values (1..9, numeric-keypad layout) are written out with a comment explaining the
layout but no reference to where in the C API they come from, and no compile-time tie to it.
**Why it matters:** it is the one enum in the package defined by transcription rather than by the
generator or by a header constant. If upstream renumbers, nothing catches it — unlike every generated
enum, which regeneration would change, and unlike `Box`/`Origin` in `layout.odin`, which carry the same
risk but at least document that they are two fields of one flag word.
**Fix:** cite the header file and line in the comment, so the next SDK upgrade has something to check
against. Same for `layout.odin`'s `Box` (`:30-38`) and `Origin` (`:55-60`).

## What is good, specifically

- **Naming is consistent throughout.** 409 procs, snake_case without exception; types are `Title_Case`
  with underscores; the subject is the first parameter and the allocator is last in all 41 procs that
  take one. Proc groups (`value_from`, `draw_rounded_rect`, `state`, `set_state`) are used where the
  overloads are genuinely interchangeable and not where they would hide which one was picked.
- **The `(value, ok)` vs `(value, err)` split is principled**: `ok` where absence is a normal answer
  (`atom_name`, the typed event accessors, `graphics_caps`, `asset_method_arity`), `err` where the engine
  can fail. The typed event accessors returning `ok` rather than an error is exactly right — "this event
  is not of that group" is a question, not a failure.
- **`Error` as a `#shared_nil` union over the engine's own result enums** is the correct shape and pays
  off immediately: the tests assert `Scdom_Result.INVALID_HANDLE` against `PASSIVE_HANDLE` nine times and
  six times respectively, which is only possible because the wrapper did not flatten them to a bool.
- **`Scdom_Result` is hand-declared as `enum Int` for a measured reason** (`src/prelude.odin:33-42`):
  Odin's default `int` backing is 8 bytes against the C `int`'s 4, "the upper half of the returned
  register would be read as part of the value". That is the kind of detail that decides whether a binding
  works, and it is written down at the declaration.
