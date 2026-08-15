# Threading: getting work off the UI thread, and its results back

Sciter is single-threaded. [`rules.md` §1](./rules.md) states the contract in a paragraph; this guide is
the part that a paragraph cannot carry — what the patterns are, which one to reach for, and what goes
wrong in every application that gets this far.

Everything asserted here about the engine was measured on the vendored 6.0.4.9 engine; the examples
that hold those measurements as tests are named at the end.

---

## The rule, and the one way across

**Every call into `sciter_app` must happen on the thread that ran `init`.** DOM reads that look
harmless, `Value` construction, and the engine's own callbacks included. There is no locking to opt into
and no "call from any thread" mode. What breaks if you ignore it is not an error you can react to; it is
intermittent corruption of engine state, surfacing somewhere unrelated.

**A debug build enforces this.** The wrapper arms itself on its first call and traps on any later call
from another thread, naming the procedure; `assert_engine_thread()` is the same check for your own
helpers, and `check_thread_affinity` turns it down to counting or off. It compiles out of a release
build. `examples/worker_thread.odin` has the tests, including what the counter reads after a worker
touches it.

`post_callback` is the only exception, and it is the *whole* exception:

```odin
// on any thread
sciter_app.post_callback(window, ROWS_READY, uintptr(len(rows)))

// back on the engine's thread, as Host_Handler.on_posted
on_posted :: proc(handler: ^sciter_app.Host_Handler, posted: sciter_app.Posted) {
    if posted.wparam == ROWS_READY { ... }
}
```

Measured properties, all of them load-bearing:

- **It is delivery, not a call.** There is no "wait for the answer" mode, and the handler's return value
  does not come back to the poster. Nothing is delivered inside the call itself — the pump delivers it.
- **Two machine words**, and that is the entire payload.
- **Each poster's messages arrive in the order that poster sent them**, one per turn of the pump.
  Measured with two threads posting 25 messages each: both sequences arrive complete and in their own
  order. **Nothing orders the two senders against each other** — that is a guarantee the queue does not
  offer rather than an interleaving anyone measured, so a design that needs "A's message before B's"
  needs its own sequence number.
- **`heartbeat` delivers them**, not only `run` / `run_once`.
- **A window with no host handler drops them silently**, and so does a nil window. No error, no log.

`examples/worker_thread.odin` holds all of these as tests.

## The doorbell pattern

Two words is not a transport. The message says *that* something happened; the shared structure says
*what*, and the lock is what makes reading it safe:

```odin
App :: struct {
    using host: sciter_app.Host_Handler,
    window:     sciter_app.Window,
    mutex:      sync.Mutex,
    results:    [dynamic]string,   // written by the worker, read on the engine's thread
}
```

The worker appends under the lock and rings the doorbell with a count; the handler takes the lock, copies
what is new, releases it, and only then touches the DOM. Nothing in the worker calls the engine except
`post_callback`.

**Name the allocator on both sides of the boundary.** A worker thread gets a fresh context, so
"the default allocator" is only the same allocator on both ends by accident — under a test runner it is
not, because the runner installs a per-test tracking allocator on the thread it runs on. A string
allocated on the worker and freed by the reader is then a bad free, and Odin's tracking allocator will
say so. Pass `allocator = runtime.default_allocator()` explicitly for anything that crosses.

## Every path ends in exactly one terminal message

A worker that returns without posting anything leaves the UI showing a progress bar forever. That is the
same bug as a `.DELAYED` request nobody answers ([`resources.md`](./resources.md)), and it is worth
enforcing as a shape rather than remembering as a rule:

```odin
work :: proc(app: ^App) {
    for step in 1 ..= 10 {
        if sync.atomic_load(&app.cancel) {
            sciter_app.post_callback(app.window, FINISHED, 1)   // cancelled
            return
        }
        if failed {
            sciter_app.post_callback(app.window, FAILED, uintptr(step))
            return
        }
        sciter_app.post_callback(app.window, PROGRESS, uintptr(step * 10))
    }
    sciter_app.post_callback(app.window, FINISHED, 0)           // ran to the end
}
```

**Failure is a message like any other**, with one wrinkle: the interesting part — *why* — does not fit in
two words, so it travels in the shared struct exactly as a result does. A worker that can only succeed
turns its failures into silence.

## Cancellation runs the other way, so it is a flag

`post_callback` has no reverse channel. A cancel request is therefore a flag the worker reads, and three
consequences follow:

- **It is cooperative.** The worker notices at its next check, so the granularity of a cancel is one step.
  A long step needs the check inside it too.
- **Atomic, not mutex-guarded.** The worker reads it every step and the UI writes it at most once; a lock
  there would be a lock taken thousands of times to answer a question that changes once.
- **"Cancelled" is an outcome the worker reports**, not something the UI decides. The UI waits for the
  terminal message, not for the thread — that is what keeps the pump running while the job winds down.

Join order matters at shutdown: **stop the pump, then join.** Not because joining first deadlocks —
`post_callback` returns immediately, so a worker never blocks on a full queue — but because
`thread.join` blocks the engine thread, which is the thread that delivers messages and draws. Join
before the terminal message and the UI freezes for the rest of the job, with the terminal message
sitting undelivered in the queue you are no longer pumping. After `run` returns, nothing more can
arrive and the join is instant.

## Answers that arrive too late

An answer that arrives after the user has typed another character is *wrong*, and nothing about it looks
wrong — it is a correct answer to a question nobody is asking any more. The fix is a generation number:
every request bumps a counter, the worker carries that number through and posts it back, and the handler
drops anything that is not current.

`examples/workbench.odin` does this for type-ahead search over 10,000 rows, counts the answers it drops,
and its tests pin the drop. Nine lines, and they are the whole correctness argument for an asynchronous
list.

## Guarding the application's own state

The engine's state is protected by the affinity rule. **Your** state is not, and a worker that reads the
model while the UI writes it is an ordinary data race. `workbench.odin` uses a `sync.RW_Mutex`: the worker
takes a shared lock to scan, the engine thread takes it exclusively to write, and the example writes down
the trade rather than hiding it — a scan can stall one frame of the live feed, and in exchange a keystroke
never stalls.

The alternative, when the work is short, is to copy what the worker needs under the lock and let it work
on the copy. That trades memory for the stall, and for a filter over 10k rows the copy was the more
expensive of the two.

## Which strategy, and when

| the work | do this | why |
| --- | --- | --- |
| slow **and touches the DOM** | time-slice on the engine thread: `run_once` + `heartbeat`, paced by a timer or `request_animation_frame` | a worker cannot touch the DOM anyway, so a thread would add a lock and buy nothing |
| pure compute over your own state | worker + doorbell, UI stays live | the case this guide is about |
| must genuinely block the user | see below — there is no modal in the C API | |

**There is no modal window in the C API.** `Sciter_Window_Cmd` is `SET_STATE`, `GET_STATE`, `ACTIVATE`,
placement and the Vulkan trio — nothing else — and Sciter 6 removed the `SW_TITLEBAR` / `SW_TOOL` family
of window flags. Modality exists only in script, as `window.modal()` (SDK `docs/md/DOM/Window.md`), so
from Odin the routes are:

1. **Do not block.** Disable the controls that would act on the state the worker is reading, show
   progress, and let the rest of the UI stay live. This is the route these bindings support directly and
   the one the examples take.
2. **Drive script's modal through `eval`.** Available in principle; **not exercised by this repository**,
   so treat it as untested rather than as a recommendation.

If the UI does not block, then the application has to: whatever the worker reads must not be edited
underneath it. Disable those controls for the duration, or version the state and refuse an edit that
targets a version the worker has already consumed. That is the same generation argument as above, applied
to input rather than to output.

## Where the code is

- [`examples/worker_thread.odin`](../examples/worker_thread.odin) — the mechanism on its own: progress,
  results, **failure**, **cancellation**, and the ordering guarantees, with 8 tests.
- [`examples/workbench.odin`](../examples/workbench.odin) — the hard version: two workers, generation
  numbers, an `RW_Mutex` over a 10,000-row model, and the latency numbers to justify it.
- [`rules.md` §1](./rules.md) — the contract itself.
- [`api.md`](./api.md#posting-work-to-the-engines-thread) — `post_callback`, `run`, `run_once`,
  `heartbeat`, `stop`.
