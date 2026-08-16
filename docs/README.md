# Documentation index

30 files besides this index, and the first decision a reader has to make is which one to open. This is
that decision, made for you.

The guides are **not** split into directories, deliberately: every one cross-links the others by
filename and moving them would break those links for no reader's benefit. The split below is by
audience instead. Two subdirectories exist and neither holds a guide: [`snippets/`](./snippets/) is the
Odin in these pages, wrapped just enough to compile, and [`review/`](./review/) is a dated
whole-repository audit — findings and their fixes, not documentation of the library. `just stats`
prints the file count and CI fails when this line disagrees with it.

## Start here

In this order. Each assumes the one before it.

1. [`getting-started.md`](./getting-started.md) — a window, a document, an event, an Odin function
   script can call. Start here even if you know Sciter; the Odin shape is what is new.
2. [`architecture.md`](./architecture.md) — the two packages, why there are two, and what the
   ergonomic layer actually does over the generated one.
3. [`rules.md`](./rules.md) — **the four contracts that decide whether your program is correct**:
   thread affinity, `Value` ownership, handle lifetimes, and which allocator a call uses. Short, and
   the one page here that is not optional.
4. [`gotchas.md`](./gotchas.md) — **the things that cost a day each.** Close every window before you
   exit, install a debug-output handler on Windows, publish assets before the load and functors after,
   and the platform differences that run the way round you would not guess. Measured, not guessed, and
   none of it derivable from the headers.
5. [`api.md`](./api.md) — the reference. What exists, grouped by area, and complete: every exported
   procedure is named there or `just check-api-coverage` fails the build.

## Topic guides

Read the one you need, when you need it.

| guide | what it covers |
| --- | --- |
| [`dom.md`](./dom.md) | finding, reading, building and moving elements and nodes |
| [`events.md`](./events.md) | handlers, phases, the event groups, timers and animation frames |
| [`threading.md`](./threading.md) | workers, `post_callback`, failure and cancellation, and what to do about the UI while work runs |
| [`calling-between-odin-and-js.md`](./calling-between-odin-and-js.md) | `eval`, `call`, native functors, SOM assets — both directions |
| [`graphics.md`](./graphics.md) | the 2D renderer, custom-drawn elements, offscreen images |
| [`resources.md`](./resources.md) | the load callback, custom URL schemes, the request API, archives |
| [`html-css-js.md`](./html-css-js.md) | what Sciter's dialects do and do not include |
| [`BEHAVIORS.md`](./BEHAVIORS.md) | the engine's intrinsic behaviors, measured one by one |
| [`EMBEDDING.md`](./EMBEDDING.md) | windowless rendering into a surface you own |
| [`using-in-your-project.md`](./using-in-your-project.md) | **your program, this repository as a dependency** — what to vendor, the collection flag, and getting the engine to your users. Everything else here is written from inside this checkout |
| [`deployment.md`](./deployment.md) | shipping: the engine, archives, one-file builds |
| [`JS-RUNTIME.md`](./JS-RUNTIME.md) | what script can reach at runtime |
| [`UPSTREAM-DEFECTS.md`](./UPSTREAM-DEFECTS.md) | engine bugs you will meet, and the workarounds |
| [`UPGRADING.md`](./UPGRADING.md) | the procedure for moving to a new SDK |

## About Sciter rather than about these bindings

Useful, and not documentation of this library. Each documents an upstream framework or the engine
itself; nothing here changes when this repository changes.

- [`reactor.md`](./reactor.md) — Sciter's own script-side framework: JSX, `patch()`, components, Signals
- [`ENGINE.md`](./ENGINE.md) — what the shipped engine binary contains
- [`ALTERNATIVES.md`](./ALTERNATIVES.md) — 87 KB comparing Sciter against other UI toolkits. An essay
  about the ecosystem, kept because the research was expensive; not a guide to this library. It absorbed
  `FLEURY-UI.md`, which was a summary of somebody else's paywalled blog series and about no part of this
  repository

## Maintainer notes

Working documents. Read these if you are changing the bindings, not if you are using them.

- [`SDK-PARITY.md`](./SDK-PARITY.md) — **the coverage answer**: which C-API slots are wrapped, which
  are not, and why. Backed by `just parity`, with the unwrapped set committed as
  [`parity-baseline.txt`](./parity-baseline.txt) and checked in CI
- [`PLAN.md`](./PLAN.md) — what is done and what is not. Its counts come from `just stats`
- [`VDOM.md`](./VDOM.md) — **a decision record, not a plan**: should these bindings grow a retained-diff
  layer over the DOM? It predicted six costs, `workbench` was built to test them, five never bit, and
  the recommendation narrowed to one trigger. Nothing built, and the evidence argues against it
- [`review/08-typing-idiom.md`](./review/08-typing-idiom.md) — where `distinct` types, default arguments
  and enums did and did not pay for themselves, with the four questions that prompted the pass answered
  at the top
- [`PLAN-TESTING-AND-EXAMPLES.md`](./PLAN-TESTING-AND-EXAMPLES.md) — house rules for the suite: why the
  test fixture is duplicated across ten files, how to pump the engine from a test, the commenting
  standard, and the acceptance checklist. The worklist it was named for is finished and gone
- [`RESEARCH-METHOD.md`](./RESEARCH-METHOD.md) — measure before documenting, and how
- [`BINDGEN-LIBCLANG.md`](./BINDGEN-LIBCLANG.md) — how `sciter.odin` is generated
- [`WINDOWS-CHECKLIST.md`](./WINDOWS-CHECKLIST.md) — the Windows bring-up, measured: what was
  established on a real desktop, and the two bugs found in other people's code on the way
- [`MACOS-CHECKLIST.md`](./MACOS-CHECKLIST.md) — the same for macOS, which nobody here has run: what
  the binary itself establishes, what CI is expected to, and the predictions it confirmed or
  contradicted
- [`review/`](./review/) — a dated whole-repository audit, nine areas. **Closed**: every finding is
  fixed, and what is kept is the reasoning and the rejected alternatives, which the code does not
  record. An archive, not a work queue; [`review/README.md`](./review/README.md) is its own index

## Where the status claims live

Three files make claims about how complete this is, and they answer different questions:

- **"is X available?"** → `SDK-PARITY.md`, and it is the only place with the slot inventory
- **"what is done?"** → `PLAN.md`
- **"what changed?"** → [`CHANGELOG.md`](../CHANGELOG.md)

The numbers in the first two are generated (`just parity`, `just stats`) and CI fails when they drift.
