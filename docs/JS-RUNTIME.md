# The JS runtime, for a host author

What Sciter's script runtime carries beyond browser JavaScript, and — the part that does not exist
anywhere upstream — **which of it a host should use instead of doing the job in Odin, and which of it a
host should ignore because there is a better API on this side.**

This is stage 4 of [`SDK-PARITY.md`](./SDK-PARITY.md#stage-4--a-jsruntime-reference). It is
documentation, not bindings: none of this is reachable through `ISciterAPI`. What makes it worth
writing down is that every real Sciter application uses some of it, and a host author reading the SDK's
`docs/md/JS.runtime` cannot tell which parts are *their* problem.

Everything below was checked against the vendored 6.0.4.9 by enumerating the live objects, not read off
the SDK's pages — `Object.keys` on each module, `typeof` on each global. Where this disagrees with
upstream's documentation, the measurement wins.

---

## Reaching any of it from Odin

Two kinds of thing, and they are reached differently:

- **Globals** — `Clipboard`, `Zip`, `Audio`, `BJSON`, `fetch`, `Intl`, `URL`, `Graphics`, `Window`,
  `Asset`, `Element`, `document`. `eval` and `call` see these directly.
- **Modules** — `@sys`, `@env`, `@sciter`, `@storage`, `@markdown`, `@yaml`, `@debug`. `eval` **cannot
  import them**: `eval("await import(\"@sys\")")` fails to *parse*, because the expression evaluator has
  no top-level await and no dynamic import. A `<script type="module">` in the document imports them and
  hangs them on `globalThis`, and from then on they are ordinary globals.

[`script_bridge.odin`](../examples/script_bridge.odin) is that pattern worked through, and
[`calling-between-odin-and-js.md`](./calling-between-odin-and-js.md#capabilities-that-only-script-can-reach)
maps each capability to the call that performs it.

**`@sys` is the only gated one.** With no `set_script_features` at all, everything else in this document
answers normally; `@sys` imports but exports only `Error`, so `tmpdir` reads as "not a function" and
`fs` as undefined. That presents as a missing member rather than as a refusal, which is worth knowing
before spending an afternoon on it.

## The verdict column

| Runtime feature | What it is | For a host author |
| --- | --- | --- |
| `fetch` | the Fetch API, plus a Sciter-only `sync: true` option | **Prefer the host.** `http_request` delivers the body as `.DATA_ARRIVED` and the request API (`request.odin`) gives you the headers, the status and the ability to answer from Odin. `fetch` is for script that owns its own data flow |
| `Zip` | reads `.zip` archives — `Zip.openFile`, `openData` | **Different thing from ours.** `SciterOpenArchive` (`archive.odin`) reads a *packfolder* resource blob, not a zip. If the payload is a real zip, this is the only route |
| `@sciter`'s `compress` / `decompress` | raw deflate on an ArrayBuffer | No host counterpart. Use Odin's own if the data is yours |
| `Graphics`, `Graphics.Image` | the 2D drawing API, from script | **Prefer the host.** `graphics.odin` binds the whole renderer, including painting inside a `.DRAW` event. Script-side `Graphics` is for `paintForeground`-style behaviour written in JS |
| `Clipboard` | `writeText` / `readText` / `write` / `read` / `has` | **Script only — there is no host API.** Works from a windowless view. Mind the trailing NUL and the CF_HTML wrapper: see `script_bridge.odin` |
| `Audio` | `Audio.load(url)` → play / pause / stop, with promises | **Script only.** No host API at all |
| `Asset` | `Asset.instanceOf(object, className)` — the script-side view of a native asset | **This is your SOM objects.** What `make_asset_class` publishes arrives in script as an `Asset`, and this is how script checks what it was handed. See `som.odin` |
| `BJSON` | binary JSON: `pack(data) → ArrayBuffer`, `unpack(blob, receiver)` | Useful *with* the host: a `Value` crossing as bytes rather than as a parsed object. No host-side packer, so both ends have to agree to use it |
| `Intl` | `Intl.NumberFormat`, `DateTimeFormat`, collation | **Script only**, and the reason to leave formatting in the document: the engine knows the user's locale (`@env.language`, `@env.country`) and Odin does not |
| `URL` | the WHATWG URL class, plus `filename` / `dir` / `extension` | Host counterpart for the one job that matters: `combine_url` resolves a relative URL against a document |
| `@sys` | `fs` (async file IO), `spawn`, `dns`, `TCP`, `UDP`, `Pipe`, `TTY`, `cwd`, `tmpdir`, `uname`, `hrtime`, `getenv` / `setenv`, `exepath`, `random` | **Prefer Odin for all of it.** `core:os`, `core:net` and `core:time` are better tools, and doing IO on the engine's thread is how a UI freezes. `@sys` exists for applications with no host at all — `scapp` and Quark |
| `@env` | `PLATFORM`, `OS`, `CPU`, `DEVICE`, `language`, `country`, `home()`, `path()`, `userName()`, `machineName()`, `drives()`, `launch()`, `exec()`, `variable()` | **Prefer Odin**, except `language` / `country`, which is the engine's own idea of the locale, and `launch()`, which is "open this with the system's default application" and has no host equivalent |
| `@storage` | `open(path)` → the persistent NoSQL object store | **Script only, and correctly so** — no host API exists, and there are four pages of SDK documentation behind that one `open` |
| `@markdown` | `toHTML`, `toFragment`, `toElement` | **Script only.** `toFragment` / `toElement` produce DOM directly, which no host-side markdown library can do |
| `@yaml` | `parse(text)` | **Script only**, but trivial to replace: if the YAML is the host's, parse it in Odin and hand over a `Value` |
| `@debug` | the inspector's own interface — breakpoints, call stacks, `setUnhandledExceptionHandler`, `setConsoleOutputHandler`, element/UID mapping | **Partly host territory.** `set_debug_mode` plus the shipped inspector is the supported route (`inspector.odin`), and `set_default_debug_output` is what makes script errors visible at all. Reach for `@debug` only for things the host cannot see, like an unhandled-rejection handler inside the document |
| `Window.this` | `selectFile`, `selectFolder`, `modal`, `trayIcon`, `state`, `move`, … | **The one that matters.** File dialogs, the tray icon and modal dialogs have **no host API**, and this object is the only way to them. Present even on a windowless view |
| `Element.prototype.popup` | shows a `<menu>` owned by an element | The placement half **is** bound — `show_popup` / `show_popup_at` — but the menu behaviour itself is script's |

## What is *not* there

Measured, because assuming otherwise costs an afternoon:

- **`performance`** is undefined. `@sys.hrtime()` is the high-resolution clock.
- **`@fs`** is not a module — the file API is `@sys.fs`. `Unknown built-in module '@fs'` is what asking
  gets you.
- **`Storage` and `env` are not globals**, only modules. `typeof Storage` is `"undefined"`, which reads
  like the feature is missing when it is one `import` away.
- **`Window.this.print` and `document.print` do not exist.** Printing is `behavior:pager` — and that
  behavior's asset *is* host-callable, so a PDF can be produced from Odin with no script at all. See
  [`BEHAVIORS.md`](./BEHAVIORS.md).
- **`@sys.fs` enumerates as one key** (`sync`). Its members are there — `$readfile` answers — but
  `Object.keys` will not show them to you, so discovery has to come from the SDK's own page.

## The rule of thumb

**If the job is data, do it in Odin. If the job is the user's machine, ask the document.**

The host API is a document and rendering API. Everything it binds — the DOM, graphics, events, values,
requests, archives, SOM — it binds better than script reaches it, with types and without a parse step
in the middle. Everything it does not bind is not an oversight: clipboard, dialogs, tray, audio,
storage and locale are *application services*, and Sciter put them in the runtime on purpose.

The failure mode worth naming is the middle: reimplementing `@sys.fs` calls from Odin through `eval` because
that is where the example was, or formatting dates in Odin because the host "should" own logic. The
first is slower and blocks the UI thread; the second gets the user's locale wrong.
