# The four rules

Everything else in these guides is about what you can do. This page is about what you must do, and it
is short on purpose. Each rule is written out where it applies, in the source, and each is repeated here
because meeting one of them for the first time inside a debugger is expensive.

---

## 1. Thread affinity: one thread, and one way across

**Every call into this library must happen on the thread that called `init`.** That includes DOM reads
that look harmless, `Value` construction, and the engine's own callbacks — the engine calls you back on
its thread, and the context restored inside those callbacks is the one captured at attach time on that
thread.

There is exactly one exception, and it exists precisely because applications have worker threads:

```odin
// on any thread
sciter_app.post_callback(window, ROWS_READY, uintptr(len(rows)))

// back on the engine's thread, as Host_Handler.on_posted
on_posted :: proc(handler: ^sciter_app.Host_Handler, posted: sciter_app.Posted) {
    if posted.wparam == ROWS_READY { redraw(...) }
}
```

`post_callback` is safe to call from any thread, returns immediately, and delivers on the engine's
thread. Two machine words travel with it; anything larger goes as a pointer to something the worker owns
and the handler takes over, or as an index into a queue the two share.

Measured properties worth designing around, all recorded in `sciter_app/host.odin`:

- it is **delivery, not a call** — there is no "wait for the answer" mode, and the notification's return
  value does not come back to the poster
- messages arrive **in the order they were posted**, one per turn of the pump
- **`heartbeat` delivers them**, not only `run_once`
- a window with **no host handler drops them silently**, and so does a nil window

What breaks if you ignore this is not a clean error: it is intermittent corruption in engine state that
surfaces somewhere else entirely.

The two lazily-cached sub-API tables (`graphics_api()`, `request_api()`) are written on first use with
no synchronisation, which is correct under this rule and only under this rule.

---

## 2. `Value` ownership: who clears what

A `Value` is 16 bytes of plain data that may own a reference to something inside the engine — a string,
an array, a map, a script object. The rules are the C API's and this package does not hide them:

- a Value must be `value_init`ed before first use, **or zeroed**, which is the same thing
- a Value that **came out of the engine** — `eval`, `call`, `value_at`, `element_value`, `asset_get` —
  owns a reference, and the receiver must `value_clear` it
- `value_copy` takes a **second** reference; two clears are then owed
- a Value handed **to** the engine as an argument is **not consumed** — it is still yours to clear

`defer value_clear(&v)` next to every Value that came from the engine is the whole discipline.

**Or let the language do it.** For the common shape — read a value, use it here, done — there is a
`scoped_` twin of every producer, and the release is `@(deferred_out)` rather than your memory:

```odin
v, err := sciter_app.scoped_eval(window, "getRows()")   // released at the end of this scope
_, _ = sciter_app.scoped_eval(window, "refresh()")      // released too, discarded or not
```

Reach for the plain one when the Value has to outlive the scope — stored in a struct, returned upwards,
handed to the engine to keep — and for `scoped_` otherwise. See `sciter_app/scoped.odin`.

What this costs to skip is not theoretical: measured on the vendored engine, 2000 discarded `eval`s of
a 100 kB string grow the process by **390 MB**, and the same loop cleared grows it by 76 kB. And the
shape of the script is no guide — an assignment (`x = "hi"`) evaluates to a STRING and
`el.on("click", f)` evaluates to a RESOURCE, so both own a reference where "it returns nothing" was the
natural assumption.

Two places where the direction is easy to get backwards, both in behavior method calls
(`sciter_app/behavior.odin`):

- **`GET_VALUE`** — what you write into `args.val` is handed to the caller and the **caller** owns it.
  Do not clear it. If you also keep it, `value_copy` first.
- **`SET_VALUE`** — `args.val` is **borrowed for the call**. Keeping it means `value_copy`; clearing it
  is a use-after-free in the caller.

`just test_sanitize eval` runs the refcounting under ASan, which is the check that catches breaking
this.

---

## 3. Handle lifetime: elements, nodes, requests

**An element handle is a borrowed pointer into the engine's document tree.** It is valid while the
element is in the document, which for anything reached from `root` during an event handler or straight
after a load is the whole time you are looking at it. To hold one longer — across the message pump, in a
struct that outlives the callback — take a reference:

```odin
sciter_app.use_element(el)
defer sciter_app.unuse_element(el)
```

Otherwise the handle dangles the moment script removes the element.

The exception is an element you **made** rather than found: `make_element` and `clone_element` hand back
a reference that is already yours, and it stays yours after the element is inserted.

**Nodes** are the same, with one addition: a node you created belongs to you until `node_insert` puts it
in a document. Insert it, or release it, or it leaks.

**Requests** are valid for the duration of the load callback and no longer. `take_request` is what keeps
one alive past that, and every `take_request` owes an `unuse_request`. A request that is never answered
is a resource the document waits on forever. This was measured, not assumed: the engine hands out the
*same* pointer for a later, unrelated request once the first is finished with.

---

## 4. Allocation: the library takes an allocator, you decide the lifetime

### The convention

Uniform across all 50 procedures that allocate:

- **anything the wrapper builds to hand to the engine** — a UTF-16 copy of your string, a cstring for a
  selector — comes from `context.temp_allocator` and is gone when you next free it
- **anything returned to you** comes from the `allocator` parameter, which defaults to
  `context.allocator` and is always the **last** parameter
- a string or slice returned that way is **yours to `delete`**

Where a proc borrows instead of allocating, its doc comment says "borrowed" and names the lifetime —
`tag`, the `name` in an attribute-change event, and the keyboard/cursor strings in the host callbacks
are all borrowed for the duration of the call. No procedure in the package allocates into your
allocator without taking one, so what follows is entirely your choice to make.

Which gives the one ownership question in this package a mechanical answer, and it is worth stating as
a rule of its own because it holds without exception:

> **If it takes an allocator, the result is yours to free. If it does not, it is borrowed.**

Thirty exported procedures return a `string` or a slice. Twenty-six take an `allocator` — `text`,
`html`, `attribute`, `style`, `value_to_string`, `atom_name`, `request_url`, `asset_members` and the
rest — and hand back memory you own. The other four — `tag`, `request_method`, `value_to_bytes`,
`archive_item` — hand back a pointer into the engine, and each one's doc comment says how long it
lives. There is no third case, and `just check-ownership` fails the build if one appears.

The same test does not work for a `Value`, which is why §2 above is a page of prose: `Value` is one type
covering four contracts, and the signature cannot tell you which. The `scoped_*` procedures are the way
out of that for the common case — see below.

### You own the temp-allocator boundary

There are ~75 uses of `context.temp_allocator` inside the wrapper, and every one of them bumps *your*
arena: `dom.odin` alone does it 19 times, `window.odin` 10, `host.odin` 9. Any call taking a string,
a selector or a URL is one of them.

**Nothing in this package ever calls `free_all`**, deliberately — the arena is the caller's and the
library has no idea where your boundaries are. That means a long-running program that never frees it
grows forever, one selector at a time, and the growth looks like a leak in the bindings when it is not.

Pick a boundary and put it somewhere unconditional:

```odin
for sciter_app.run_once() {
    sciter_app.heartbeat()
    // ... your per-turn work, DOM reads, whatever ...
    free_all(context.temp_allocator)   // the boundary
}
```

The three that fall out naturally:

| boundary | why |
| --- | --- |
| one turn of the pump | the common case for a windowed application; everything scratch dies with the frame |
| one event handler | a handler that does substantial DOM work, if a frame is too coarse |
| one served request | `on_load_data` can build a lot of strings, and the answer is copied out before you return |

`free_all` on an arena is a pointer reset, so a boundary costs nothing and having one is what makes the
temp allocator the right default for scratch in the first place.

### The capture rule: attach from where the object will live

Six entry points store the **whole `runtime.Context`** — `context.allocator` *and*
`context.temp_allocator` as they were at the moment you called — and restore it inside every later
callback, because the engine calls back as `proc "system"` where Odin's implicit context does not exist:

| call | what it captures | used by |
| --- | --- | --- |
| `attach_handler`, `attach_window_handler` | full context | every `on_event` for the life of the attachment |
| `set_host_handler` | full context | every host notification, including `on_load_data` |
| the handler returned from `on_attach_behavior` | full context | that behavior's events |
| `make_asset` | full context, plus `allocator` for the asset itself | every getter, setter and method call from script |
| `set_default_debug_output` | full context | the stderr logger (it decodes into a fixed buffer, so this is for `fmt`'s use only) |

**So the scope you attach from decides the allocator for that object's whole life.** Attaching from
inside a temporary arena — a `defer free_all` block, a scratch scope in a setup routine — binds the
callbacks to an arena that is about to be reset, and the failure arrives much later, in a callback, as
memory that was reused underneath it.

Attach from where the object lives: `main`, or an init routine whose context is the process-lifetime
one. The test suites here do the same thing for the same reason, via
`context.allocator = runtime.default_allocator()` before creating the process-lifetime window.

Four more places take an allocator and keep it, rather than the whole context:
`make_asset_class`, `make_asset`, `create_windowless` (the view reallocates its pixel buffer from it on
every resize) and `init` (the argv the engine holds until `shutdown`).

### Choosing an allocator by lifetime

The package is written so that objects sharing a lifetime can share an allocator; it does not choose
for you. What each kind of lifetime wants:

**Process-lifetime singletons** — the engine's argv, an `Asset_Class` and its assets, a windowless
view's surface. The default heap allocator is right. These are allocated once, freed at `shutdown` or
not at all, and the allocation cost is irrelevant.

**A batch with one lifetime** — this is where the win is, and where a general-purpose allocator is
worst. A document's `select_all` result plus the text and attributes read from it; a request's
parameters and headers; a frame's worth of measured strings. All of it dies at the same instant, so
give the batch its own arena and pass that arena to the calls:

```odin
import vmem "core:mem/virtual"

arena: vmem.Arena
_ = vmem.arena_init_growing(&arena)
batch := vmem.arena_allocator(&arena)
defer vmem.arena_destroy(&arena)     // one call frees the lot

rows := sciter_app.select_all(root, "tr", batch) or_return
for row in rows {
    text := sciter_app.text(row, batch) or_return
    // ... no individual delete anywhere ...
}
```

That replaces one `delete` per string plus one for the slice with a single reset, and it makes the
lifetime a property of the arena rather than of your discipline. `core:mem/virtual`'s growing arena is
the natural fit: it reserves address space and commits as it goes, so the batch does not need a size
estimate up front.

**Scratch inside one scope** — `context.temp_allocator`, with a boundary as above. This is what the
wrapper itself uses for every argument it builds.

**Never the temp allocator for anything the engine keeps.** The engine holds pointers past the call in
six places, and every one of them will read the memory after your next `free_all`:

- the argv given to `init` — held until `shutdown`
- an `Asset_Class`'s passport — the C header says it must "survive last instance of the engine"
- any handler struct you attach — the engine stores its *address* as the tag
- the bytes handed to `serve` — borrowed for the duration of the callback, so they must outlive the
  return, and `data_ready` is the copying alternative when they cannot
- **a windowless view's pixel surface** — a buffer passed to `create_windowless` or `resize_windowless`
  is drawn into on every later `paint_windowless`, so it is held for the life of the view or until the
  next resize. It looks like a frame buffer and frame buffers look per-frame; this one is not.
- **an archive blob** — `open_archive` indexes it in place and does not copy, so it must stay valid and
  unmoved until `close_archive`. `#load`ed data is ideal, and is why the examples use it.

### Two specific cases that have caught people

- `sciter.load` returns its `tried` candidate list **on every path, success included**, each string
  separately allocated. `load_engine` is the worked example of freeing it.
- strings decoded out of the engine are allocated at their exact length, in the allocator you passed.
  The oversized scratch used while decoding comes from the temp allocator, which is another reason the
  boundary above matters.
