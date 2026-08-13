# Resources: serving the UI from inside the binary

A Sciter document refers to stylesheets, images, scripts and fonts. Where those come from is entirely
the host's business — the engine asks before it fetches anything, and answering that question is how an
application ships its whole UI inside the executable instead of beside it.

Four examples cover the ladder: [`custom_loader`](../examples/custom_loader.odin) (serve from a map in
memory), [`request_loader`](../examples/request_loader.odin) (status codes, MIME types and an answer that
arrives later), [`archive`](../examples/archive.odin) (serve from a compressed blob), and
[`single_binary`](../examples/single_binary.odin) (the engine embedded too).

## The host callback

Every resource the engine needs produces one `SC_LOAD_DATA` notification, and it arrives **before** the
engine tries to fetch the URL. That makes it both the resource loader and the place to implement a
custom URL scheme.

```odin
handler := sciter_app.Host_Handler {
	on_load_data = on_load_data,
	user_data    = &app,
}
sciter_app.set_host_handler(window, &handler)   // BEFORE loading the document
sciter_app.load_html(window, INDEX, "res://app/")
```

```odin
on_load_data :: proc(
	handler: ^sciter_app.Host_Handler,
	request: ^sciter_app.Load_Request,
) -> sciter_app.Load_Result {
	app := (^App)(handler.user_data)

	if data, found := app.files[request.uri]; found {
		return sciter_app.serve(request, data)
	}
	return .OK   // not ours - let the engine fetch it as it would have
}
```

Two things this API exists to make unambiguous:

**`.OK` means two different things**, distinguished only by whether the request was filled in. `.OK`
with no data is "engine, load it yourself"; `.OK` *with* data is "here it is". `serve` sets the data
pointer and returns the right code, which is why it exists rather than a bare `return .OK`.

**Install the handler before the load.** The document's own load goes through the same callback, and so
do the stylesheets it pulls in. A handler installed afterwards misses all of it. The same rule covers
every other notification on the same handler — `on_attach_behavior` in particular arrives *inside*
`load_html`.

### The other notifications on the same handler

`Host_Handler` is one struct for the whole `SCITER_CALLBACK_NOTIFICATION` family, not just loading:

| | |
| --- | --- |
| `on_load_data` | a resource is wanted — the loader, above |
| `on_data_loaded` | one the engine fetched itself has arrived, or failed. Reporting only |
| `on_attach_behavior` | the document asked for a `behavior:` name by name. See [`api.md`](./api.md#named-behaviors--the-document-asking-for-odin-by-name) |
| `on_posted` | `post_callback` coming back on the engine's thread |
| `on_invalidate_rect` | an area was repainted. **Fires constantly in a windowed embedding** — not windowless-only |
| `on_keyboard_request` | a text field took focus and the engine wants an on-screen keyboard |
| `on_set_cursor` | a cursor change. Never seen in windowed mode — the engine owns its own window |
| `on_graphics_failure` | the renderer drew nothing. Never seen here |
| `on_engine_destroyed` | final; nothing in the API is callable after it |

`on_attach_behavior` is the interesting one for anything beyond loading: it is how a stylesheet, rather
than a call site, decides which elements get Odin code behind them.

### The request

| Field | |
| --- | --- |
| `uri` | the fully qualified URL, e.g. `res://app/style.css`. Allocated in the callback's `context.temp_allocator` — clone it to outlive the call. |
| `type` | what the engine intends it for: `.STYLE`, `.IMAGE`, `.SCRIPT`, `.FONT`, … Worth checking; the same URL can legitimately be requested as more than one kind. |
| `raw` | the engine's own `Scn_Load_Data`, for what the wrapper does not surface — `requestId`, `principal`, `initiator` |

### The result codes

| | |
| --- | --- |
| `.OK` | carry on — with your data if `serve` filled it in, otherwise the engine loads it |
| `.DISCARD` | refuse. The resource is never loaded. |
| `.DELAYED` | you will answer later, out of band, with `data_ready_async(window, uri, data, raw.requestId)`. **Every delayed request must eventually be answered or it leaks.** |
| `.MYSELF` | you take the underlying `HREQUEST` over and answer it yourself — see [Taking a request over](#taking-a-request-over) |

`.DELAYED` is the one that makes a network-backed or database-backed loader possible without blocking
the pump:

```odin
// in the callback: remember the id, answer nothing yet
app.pending = request.raw.requestId
return .DELAYED

// later, back on the engine's thread
sciter_app.data_ready_async(window, uri, bytes, app.pending)
```

Answering from the engine's thread is still required — see
[`architecture.md`](./architecture.md#threading) for how to get back onto it.

### Lifetime of the data you serve

The engine consumes the bytes during the callback — "Sciter does not store pointer to this data", per
`sciter-x-def.h` — so a buffer valid for the duration of the handler is enough. Data from `#load` is
valid forever, which removes the question entirely. If keeping the bytes alive even that long is
awkward, `SciterDataReady` on the raw table copies immediately.

### Leave the engine's own requests alone

The engine asks for its own built-ins through this same callback — `sciter:window-frame.js` and
friends. Match on your prefix and return `.OK` for everything else; do not `.DISCARD` by default.

## Taking a request over

`serve` answers with bytes and nothing else: status 200, type guessed from the URL, delivered inside the
callback. The engine also hands the host its own request object on every notification, and `.MYSELF`
takes that object over — which is how you answer with a **status code**, a **MIME type**, **later**, or
**in chunks**. [`request_loader`](../examples/request_loader.odin) does all four; the API is in
[`api.md`](./api.md#requests--requestodin).

```odin
// a status and a type the URL does not imply, answered inside the callback
return sciter_app.serve_request(request, css, mime = "text/css")
```

```odin
// a real 404 rather than a silent .DISCARD
sciter_app.fail_request(sciter_app.request_of(request), 404)
return .MYSELF
```

An answer that cannot be given now needs the handle to survive the callback, and that needs a reference:

```odin
// in the callback
rq, result := sciter_app.take_request(request)   // use_request + .MYSELF
app.pending = rq
return result

// later, on the engine's thread
sciter_app.succeed_request(app.pending, bytes)
sciter_app.unuse_request(app.pending)
```

Without `take_request` the handle is the engine's to recycle the moment the callback returns — measured:
the engine handed out the same pointer for a later, unrelated request.

### Deferring does not rewind the document

An answer that arrives late is used for anything the document consumes **when it arrives** — images,
fonts, media. It is *not* used for anything consumed **in order**: a `<script src>` answered after
parsing has moved past it is fetched and never executed. Both measured on 6.0.4.9; a deferred image
cleared its element's `.INCOMPLETE` and `.BUSY` state as soon as the answer landed, and a deferred script
never ran.

Use `.DELAYED` + `data_ready_async` for a whole-buffer answer on the engine's thread, and `.MYSELF` +
`take_request` when the status code, the type, or streaming matters.

### `.MYSELF` versus the rest

| | |
| --- | --- |
| `serve` | bytes, now, 200, type guessed. The default. |
| `serve_request` | bytes, now, with a status and a MIME type |
| `.DELAYED` + `data_ready_async` | whole buffer, later, no status |
| `take_request` + `succeed_request` | anything, later, with a status; `append_request_data` streams it |

### What the request knows

`request_url`, `request_method`, `request_data_type`, `request_status` → `(state, status)`,
`request_times` and `request_time` (the duration between them), `request_data`, `request_headers` /
`response_headers` / `request_parameters` — three independently numbered lists, hence three distinct
index types — and
`request_requestor` — which reports the element the resource is **for**, not the one that named it: a
stylesheet pulled in by `<link>` in the head reports `html`.

A failed request is answered as a failure, not as silence: 404 an image and the engine's next question
through this same callback is `sciter:no-image.png`, its own placeholder, which has to be left alone.

## Archives

The SDK's `packfolder` turns a directory tree into one compressed blob, and the engine can index it and
hand back files by path. That is how a Sciter application ships its HTML, CSS, scripts and images
inside the executable.

```sh
SCITER_SDK=/path/to/sciter-js-sdk just pack     # examples/assets/app/ -> examples/assets/app.pak
```

`packfolder <folder> <out> -binary` is the underlying command. It is not vendored here, hence
`SCITER_SDK`; the resulting 2 KB `app.pak` **is** committed, so `just example archive` builds from a
clean checkout with no SDK present.

```odin
RESOURCES :: #load("assets/app.pak")

archive, err := sciter_app.open_archive(RESOURCES)
defer sciter_app.close_archive(archive)

data, found := sciter_app.archive_item(archive, "index.htm")   // path within the packed folder
```

**The engine indexes the blob in place and does not copy it**, so it must stay valid and unmoved until
`close_archive`. Odin's `#load` is ideal: the bytes live in the executable's read-only data for the
life of the process, so there is no lifetime question at all — and it keeps a hex dump out of git,
unlike the C SDK's generated `resources.cpp`.

`archive_item` paths are relative to the packed folder with no leading slash: `index.htm`,
`script/app.js`. The returned bytes are borrowed from the archive.

### `this://app/` is a convention, not a feature

Opening an archive gives you lookup by path. It does **not** teach the engine a new URL scheme. Serving
`this://app/index.htm` out of an archive is something the *host* implements, in the same `SC_LOAD_DATA`
callback as anything else. `serve_archive` does exactly that:

```odin
on_load_data :: proc(h: ^sciter_app.Host_Handler, r: ^sciter_app.Load_Request) -> sciter_app.Load_Result {
	app := (^App)(h.user_data)
	if result, handled := sciter_app.serve_archive(r, app.archive); handled {
		return result
	}
	return .OK
}
```

`handled = false` means the URL was not under the prefix — the signal to fall through and let the
engine's own built-ins load. A URL that *is* under the prefix but missing from the archive is answered
`.DISCARD` rather than passed through: that is a genuine mistake, a typo in a `<link href>`, and
letting the engine try to fetch `this://app/...` itself would only turn it into a more confusing
failure.

The prefix is `sciter_app.ARCHIVE_URL_PREFIX`, `"this://app/"`. Nothing in the engine enforces it — it
is what the SDK's C++ host callback uses (`sciter-x-host-callback.h`), so documents written for Sciter
expect it, and matching it keeps them portable.

Then load the entry point through the same convention, and every relative reference inside the document
resolves against it:

```odin
sciter_app.load_file(window, "this://app/index.htm")
```

## Choosing between them

| | When |
| --- | --- |
| files on disk (`load_file`) | during development — edit and reload without rebuilding |
| `#load` + a `map[string][]u8` | a handful of resources; no SDK tooling needed. `custom_loader` |
| `#load` + archive | a real UI: many files, subdirectories, compressed. `archive` |
| archive + embedded engine | one artifact and nothing else. `single_binary` |

Nothing stops you switching on a build flag: serve from disk in debug, from the archive in release,
behind the same `this://app/` URLs, so the document never knows the difference.

## The engine itself

`archive` puts the UI in the executable, and the executable still needs a ~25 MB `libsciter.so` beside
it, because Sciter is dynamic-link-only without a commercial licence. `single_binary` closes that gap
the only way a dynamic-only engine allows — embed the library as data, write it out once, load it from
there:

```odin
ENGINE    :: #load("../lib/linux/x64/libsciter.so")
RESOURCES :: #load("assets/app.pak")

path, err := sciter_app.load_embedded(ENGINE)
```

`load_embedded` writes the engine to a hash-named directory under the user's cache
(`~/.cache/odin-sciter/<hash>/libsciter.so`) and loads it from there. The hash names the directory so a
different engine build gets a different one instead of silently reusing a stale library; an unchanged
one is written exactly once and later runs reuse it untouched. The write goes to a temporary file and
is renamed into place, so two copies starting at once cannot see a half-written library.

This is **not** static linking and it does not avoid the disk — there is no portable way to hand the
system loader a library from memory. What it buys is a single artifact. The trade-offs are in
[`sciter_app/embed.odin`](../sciter_app/embed.odin) and repeated in
[`deployment.md`](./deployment.md#one-file-or-two).
