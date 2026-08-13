# Documentation index

Twenty-seven files, and the first decision a reader has to make is which one to open. This is that
decision, made for you.

The files are **not** split into directories, deliberately: every guide cross-links the others by
filename and moving them would break those links for no reader's benefit. The split below is by
audience instead.

## Start here

In this order. Each assumes the one before it.

1. [`getting-started.md`](./getting-started.md) — a window, a document, an event, an Odin function
   script can call. Start here even if you know Sciter; the Odin shape is what is new.
2. [`architecture.md`](./architecture.md) — the two packages, why there are two, and what the
   ergonomic layer actually does over the generated one.
3. [`rules.md`](./rules.md) — **the four contracts that decide whether your program is correct**:
   thread affinity, `Value` ownership, handle lifetimes, and which allocator a call uses. Short, and
   the one page here that is not optional.
4. [`api.md`](./api.md) — the reference. What exists, grouped by area.

## Topic guides

Read the one you need, when you need it.

| guide | what it covers |
| --- | --- |
| [`dom.md`](./dom.md) | finding, reading, building and moving elements and nodes |
| [`events.md`](./events.md) | handlers, phases, the event groups, timers and animation frames |
| [`calling-between-odin-and-js.md`](./calling-between-odin-and-js.md) | `eval`, `call`, native functors, SOM assets — both directions |
| [`graphics.md`](./graphics.md) | the 2D renderer, custom-drawn elements, offscreen images |
| [`resources.md`](./resources.md) | the load callback, custom URL schemes, the request API, archives |
| [`html-css-js.md`](./html-css-js.md) | what Sciter's dialects do and do not include |
| [`BEHAVIORS.md`](./BEHAVIORS.md) | the engine's intrinsic behaviors, measured one by one |
| [`EMBEDDING.md`](./EMBEDDING.md) | windowless rendering into a surface you own |
| [`deployment.md`](./deployment.md) | shipping: the engine, archives, one-file builds |
| [`JS-RUNTIME.md`](./JS-RUNTIME.md) | what script can reach at runtime |
| [`UPSTREAM-DEFECTS.md`](./UPSTREAM-DEFECTS.md) | engine bugs you will meet, and the workarounds |
| [`UPGRADING.md`](./UPGRADING.md) | the procedure for moving to a new SDK |

## About Sciter rather than about these bindings

Useful, and not documentation of this library. Each documents an upstream framework or the engine
itself; nothing here changes when this repository changes.

- [`VDOM.md`](./VDOM.md), [`reactor.md`](./reactor.md) — Sciter's own script-side frameworks
- [`ENGINE.md`](./ENGINE.md) — what the shipped engine binary contains
- [`FLEURY-UI.md`](./FLEURY-UI.md) — a stub, awaiting material that is behind a paywall
- [`ALTERNATIVES.md`](./ALTERNATIVES.md) — 84 KB comparing Sciter against other UI toolkits. An essay
  about the ecosystem, kept because the research was expensive; not a guide to this library

## Maintainer notes

Working documents. Read these if you are changing the bindings, not if you are using them.

- [`SDK-PARITY.md`](./SDK-PARITY.md) — **the coverage answer**: which C-API slots are wrapped, which
  are not, and why. Backed by `just parity`, with the unwrapped set committed as
  [`parity-baseline.txt`](./parity-baseline.txt) and checked in CI
- [`PLAN.md`](./PLAN.md) — what is done and what is not. Its counts come from `just stats`
- [`PLAN-TESTING-AND-EXAMPLES.md`](./PLAN-TESTING-AND-EXAMPLES.md) — house rules for the suite, and why
  the test fixture is duplicated across ten files
- [`RESEARCH-METHOD.md`](./RESEARCH-METHOD.md) — measure before documenting, and how
- [`BINDGEN-LIBCLANG.md`](./BINDGEN-LIBCLANG.md) — how `sciter.odin` is generated
- [`WINDOWS-CHECKLIST.md`](./WINDOWS-CHECKLIST.md) — what turning Windows on requires

## Where the status claims live

Three files make claims about how complete this is, and they answer different questions:

- **"is X available?"** → `SDK-PARITY.md`, and it is the only place with the slot inventory
- **"what is done?"** → `PLAN.md`
- **"what changed?"** → [`CHANGELOG.md`](../CHANGELOG.md)

The numbers in the first two are generated (`just parity`, `just stats`) and CI fails when they drift.
