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

## 4. Allocators: arguments are temporary, results are yours

The convention throughout, and it is uniform:

- **anything the wrapper builds to hand to the engine** — a UTF-16 copy of your string, a cstring for a
  selector — comes from `context.temp_allocator` and is gone when you next free it
- **anything returned to you** comes from the `allocator` parameter, which defaults to
  `context.allocator` and is always the **last** parameter
- a string or slice returned that way is **yours to `delete`**

Two specific cases that have caught people:

- `sciter.load` returns its `tried` candidate list **on every path, success included**, each string
  separately allocated. `load_engine` is the worked example of freeing it.
- strings decoded out of the engine are allocated at their exact length. Scratch space used during
  decoding comes from the temp allocator, so a `free_all(context.temp_allocator)` in your frame loop is
  worth having.

Where a proc borrows instead of allocating, its doc comment says "borrowed" and names the lifetime —
`tag`, the `name` in an attribute-change event, and the keyboard/cursor strings in the host callbacks
are all borrowed for the duration of the call.
