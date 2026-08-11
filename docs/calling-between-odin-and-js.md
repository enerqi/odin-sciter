# Calling between Odin and JavaScript

Four things travel across the boundary: script you run from Odin, functions you call from Odin,
Odin procedures script calls, and the `Value`s that carry data in both directions. `Value` is the part
that needs discipline, so it comes first.

Runnable versions of everything here: [`examples/eval.odin`](../examples/eval.odin) and
[`examples/call_odin_from_js.odin`](../examples/call_odin_from_js.odin).

## Why lifetime is the hard part

The rules below look fussy in isolation. They exist because binding two languages to one set of objects
creates a specific, well-known problem: **two ownership systems, one object.** Every language binding to
a native UI toolkit hits it, and the three big resolutions of it are worth knowing, because this package
picked the third.

The problem produces two symmetric failures, which read as unrelated bugs until you see the shape:

| | Cause | Symptom |
| --- | --- | --- |
| **Premature free** | Your side dropped the last reference while the engine still expected the object | Crash, or a mysteriously empty UI |
| **Dangling wrapper** | The engine freed it while you still hold a handle | Crash on next use — and there is no safe way to test the handle first |

And, in a garbage-collected host, a third: **cross-language cycles**, where the collector cannot trace
through the native side and the cycle simply leaks.

### Three ways this gets resolved

**The browser DOM — solved, expensively.** DOM nodes are C++ objects with JavaScript wrappers, exactly
this problem at enormous scale. Browser engines answered it with cross-heap tracing: the collector
follows references through the C++ objects into the script wrappers and back, so cycles spanning the
boundary are reclaimed. It works, and it is why the wrapper graph is a *throughput* cost — a large
retained tree is a lot to trace, discussed in
[`ALTERNATIVES.md`](./ALTERNATIVES.md#gc-pauses--yes-but-not-only-javascript) — rather than a
correctness cost. The price was years of engine work that only a browser vendor can afford.

**Qt and PyQt/PySide — unsolved, delegated to you.** Every `QObject` gets a Python wrapper, and two
lifetime disciplines run over the same memory: Python's refcount and cycle collector, and Qt's
parent-child ownership, where a parent deletes its children and calls like `layout.addWidget(w)` or
`setParent()` transfer ownership across the boundary implicitly. Both failure modes above are routine —
a parentless widget collected too early, or the famous
`RuntimeError: wrapped C/C++ object of type X has been deleted` for the reverse. Cross-language cycles
just leak, because Python's collector cannot see C++ parent chains. The decisive weakness is that
**ownership is per-API and implicit**: which side owns an object depends on which call you last made,
and that fact is not in the type.

**This package — the problem shrinks, but does not vanish.** Odin has no garbage collector, so the cycle
class disappears outright: nothing traces, so nothing can fail to trace. What remains is ownership, and
the answer here is to make it explicit per object kind rather than clever:

| Kind | Discipline | Where |
| --- | --- | --- |
| `Value` | Engine-returned values own a reference; the receiver owes a `value_clear`. `value_copy` owes a second. A `Value` passed *to* the engine is not consumed | below, and `sciter_app/value.odin` |
| `Element` | Handles are **borrowed** — valid while the element is in the document. To outlive the callback, `use_element` / `unuse_element`. An element you *made* is already yours | [Passing elements](#passing-elements), `sciter_app/dom.odin` |
| `Asset` | The Odin side owns the storage outright | `sciter_app/som.odin` |

That third row is the general escape hatch, and it is worth stating as a technique rather than a
detail. The engine reference counts assets, and this package **declines to participate**:
`asset_add_ref` and `asset_release` return a constant `1` and never free anything, because — as the
comment there puts it — "an Asset belongs to whoever made it, and freeing it from under `destroy_asset`
would be worse than holding it a moment too long."

> **Do not let a foreign reference count decide when your memory dies.** Let the other side count for
> its own bookkeeping, and keep allocation lifetime on exactly one side.

That is precisely the option PyQt does not have, because Qt genuinely does own widgets and will delete
them whatever Python thinks. Sciter's SOM assets leave the choice open, so this package takes it. Where
the engine really does own the object — `Value`'s referenced payloads, elements in the document — the
rules below are not avoidable, and `defer value_clear` is the discipline that pays for them.

## Value

`Value` is the engine's variant type — 16 bytes of plain data that may own a reference to something
inside the engine (a string, an array, a map, a script object). `sciter_app.Value` *is* `sciter.Value`,
so the two packages pass them back and forth without conversion.

The rules are the C API's, and this package does not hide them:

- a `Value` must be `value_init`ed before first use, **or zeroed, which is the same thing**
- a `Value` that came *out* of the engine — from `eval`, `call`, `value_at`, `element_value`,
  `value_invoke` — owns a reference, and the receiver must `value_clear` it
- `value_copy` takes a second reference; two clears are then owed
- a `Value` handed *to* the engine as an argument is **not** consumed — it is still yours to clear

The convenience in this package is in construction and extraction, not in lifetime.
`defer value_clear(&v)` next to every `Value` that came from the engine is the whole discipline.

```odin
result, err := sciter_app.eval(window, "1 + 1")
if err != nil {return}
defer sciter_app.value_clear(&result)

n, _ := sciter_app.value_to_int(&result)   // 2
```

The `Value` tests in `examples/eval.odin` are the ones worth running under ASan
(`just test_sanitize eval`), because refcounting is exactly the code that benefits.

### Constructing

Every constructor returns a `Value` the caller owns and must clear.

```odin
b := sciter_app.value_from(true)             // BOOL
i := sciter_app.value_from(i32(42))          // INT
n := sciter_app.value_from(3.5)              // FLOAT
s := sciter_app.value_from("hello")          // STRING - the engine copies it
d := sciter_app.value_from([]u8{1, 2, 3})    // BYTES  - the engine copies it
a := sciter_app.value_make_array(3)          // ARRAY of 3 undefined slots
```

`value_from` is an overload group over `value_from_bool` / `_int` / `_i64` / `_f64` / `_string` /
`_bytes`. Note that `value_from(42)` will not compile — Odin's untyped integer needs a hint, so write
`i32(42)` or call `value_from_int` directly.

### Extracting

```odin
b, err := sciter_app.value_to_bool(&v)
i, _   := sciter_app.value_to_int(&v)
f, _   := sciter_app.value_to_f64(&v)
s, _   := sciter_app.value_to_string(&v)     // allocates; fails unless the Value is a STRING
p, _   := sciter_app.value_to_bytes(&v)      // borrowed from the engine - copy to outlive the Value
```

Every one of them returns `(value, Error)`; the checks are dropped above only to keep the list short.
A `Value` holding something other than what was asked for fails with `.INCOMPATIBLE_TYPE` rather than
converting.

To render *any* `Value` as text — an array, a map, a script object — use `value_to_display_string`,
which is what script's `String(v)` does:

```odin
text, _ := sciter_app.value_to_display_string(&v, .JSON_LITERAL)
defer delete(text)
```

`.SIMPLE` renders terminal values; `.JSON_LITERAL` produces JSON and is what you want for a container.
This converts the `Value` in place, so the wrapper takes a copy first — your original is untouched.

### Types

`value_type` reports what a `Value` holds, plus a `units` qualifier whose meaning depends on the type
(a `VALUE_UNIT_TYPE` for `.LENGTH`, a `VALUE_UNIT_TYPE_OBJECT` for `.OBJECT`), which is why it comes
back as a bare integer.

| `Value_Type` | Odin side |
| --- | --- |
| `.UNDEFINED`, `.NULL` | `value_is_undefined`, `value_is_null` |
| `.BOOL`, `.INT`, `.FLOAT` | `value_to_bool` / `_int` / `_f64` |
| `.BIG_INT` | `value_to_i64` |
| `.STRING` | `value_to_string` |
| `.BYTES` | `value_to_bytes` |
| `.ARRAY`, `.MAP` | `value_len`, `value_at`, `value_get`, below |
| `.FUNCTION`, `.OBJECT` | `value_invoke`, `value_is_function` |
| `.LENGTH`, `.DURATION`, `.ANGLE`, `.COLOR`, `.DATE` | UI types; read the raw fields, or render to text |

### Arrays and maps

In Sciter these are the same machinery — an array is a `Value` whose keys are the integers `0..n`, so
`value_len` and `value_at` work on both.

```odin
arr := sciter_app.value_make_array(0)
defer sciter_app.value_clear(&arr)

item := sciter_app.value_from("first")
defer sciter_app.value_clear(&item)          // value_set_at copies; this one is still yours
sciter_app.value_set_at(&arr, 0, &item)

n, _ := sciter_app.value_len(&arr)
for i in 0 ..< n {
	e, _ := sciter_app.value_at(&arr, i)     // owns a reference
	defer sciter_app.value_clear(&e)
	// ...
}
```

Maps use string keys through `value_get` / `value_set`, or arbitrary `Value` keys through
`value_get_key` / `value_set_key`. `value_key_at(v, n)` walks a map's keys by index.

`value_each` walks either in one call, with no reference to clear per element — but an array reports
its keys as *undefined* rather than as indexes, so count if the position matters:

```odin
sciter_app.value_each(&obj, proc(k, v: ^sciter_app.Value, _: rawptr) -> bool {
	name, _ := sciter_app.value_to_string(k, context.temp_allocator)
	fmt.println(name)
	return true                              // false stops the walk
})
```

```odin
obj: sciter_app.Value                        // a zeroed Value is a valid undefined
defer sciter_app.value_clear(&obj)

count := sciter_app.value_from(i32(3))
defer sciter_app.value_clear(&count)
sciter_app.value_set(&obj, "count", &count)  // obj is now a MAP
```

### Text in, value out

`value_from_string` stores text in a `Value`; `value_parse` reads text *as* one, which is what JSON off
a socket or a length out of a config file wants.

```odin
v, err := sciter_app.value_parse(`{"name":"sciter","tags":[1,2,3]}`)   // a MAP holding an ARRAY
defer sciter_app.value_clear(&v)
```

The engine reports a parse failure in the *result* rather than in the return code — it hands back a
string carrying the `.ERROR` unit. So `err` is `.Parse_Failed` and the Value that came back is the
message ("JSON parsing error in line 0 at 4 position"), which `value_to_string` will give you. The same
check is `value_is_error`, and it is worth running on anything that came back from script.

`how` picks the dialect: `.JSON_LITERAL` (the default) and `.XJSON_LITERAL` parse documents, `.SIMPLE`
parses one terminal value the way an attribute would — `12.5%` is a `.LENGTH`, `[1,2,3]` is just a
string — and never fails, and `.JSON_MAP` resumes an object whose `{` has already been consumed, so it
wants `a:1}` and rejects `{"a":1}`.

## Odin → script

### eval

Runs a script in the window's global scope and returns its result.

```odin
v, err := sciter_app.eval(window, "document.$('#count').innerText")
defer sciter_app.value_clear(&v)
```

A script *error* comes back as `.Eval_Failed`, and the exception itself goes to the debug output — so
without `set_default_debug_output()` installed there is nothing to see. Install it before you start
debugging script.

`eval_element(element, script)` is the same thing with `this` bound to an element.

### call

Calls a function already defined in the document's global scope. Cheaper than `eval` and does not
re-parse anything, so it is the right call in a loop.

```odin
arg := sciter_app.value_from("world")
defer sciter_app.value_clear(&arg)           // arguments are not consumed

result, err := sciter_app.call(window, "greet", arg)
defer sciter_app.value_clear(&result)
```

`call_method(element, name, args...)` calls a method on an element's script object, including a
behavior's own methods.

### Which to use

| | |
| --- | --- |
| `eval` | one-off script, expressions, anything not worth defining a function for |
| `call` | a named function that exists in the document — no parsing, typed arguments |
| `call_method` | a method on one element, or on a behavior attached to it |
| `value_invoke` | a function you already hold as a `Value` — a callback script handed you |

## Script → Odin

A `Value` can hold a pointer to an Odin procedure — a **native functor** — and script then calls it
like any other function.

```odin
App :: struct {
	calls: int,
}

odin_reverse :: proc(args: []sciter_app.Value, user_data: rawptr) -> sciter_app.Value {
	app := (^App)(user_data)
	app.calls += 1

	if len(args) < 1 {
		return sciter_app.value_from("expected one argument")
	}
	s, err := sciter_app.value_to_string(&args[0], context.temp_allocator)
	if err != nil {
		return sciter_app.value_from("not a string")
	}
	return sciter_app.value_from(reverse(s))
}
```

Wrap it and publish it into the document's globals:

```odin
app := App{}

fn := sciter_app.value_from_function(odin_reverse, &app)
defer sciter_app.value_clear(&fn)
sciter_app.set_global(window, "odin_reverse", &fn)
```

Script sees `globalThis.odin_reverse`:

```js
document.$("#out").innerText = odin_reverse(document.$("input").value);
```

The contract, in full:

- **`args` is borrowed** for the duration of the call. Copy anything that must outlive it.
- **The returned `Value` is handed to the engine, which takes ownership** of that reference. Do not
  clear it. Returning a zeroed `Value` means `undefined`.
- `user_data` is whatever you passed to `value_from_function`, and is how a functor reaches state
  other than globals.
- The wrapper allocates a small record holding the procedure, the user data and the calling context;
  the engine frees it when the last reference to the `Value` goes. **The allocator must outlive the
  `Value`** — for a function living in the document's globals, that means outliving the window.
- The procedure **runs on the engine's thread, inside script's stack frame.** Blocking there freezes
  the UI. Panicking there unwinds through C++.

### Globals belong to the document

`set_global` publishes into the *document's* global scope, not the window's, so **it has to be redone
after every load**. Load first, then publish, then anything script does on `ready` can see it.

`global(window, name)` reads one back — the ones published here and the ones script defined itself.
A name that is not there comes back undefined rather than as an error, which is the answer script would
give too.

```odin
v, err := sciter_app.global(window, "some_setting")
defer sciter_app.value_clear(&v)
if sciter_app.value_is_undefined(&v) { … }
```

An implementation note, because the obvious route does not work: `ISciterAPI` has
`SciterGetViewExpando`, which would hand back `globalThis` as a `Value` to assign into, but on Sciter 6
that slot is NULL on every platform — `just example api_map` lists it among the 16 unimplemented ones,
left behind with the removed TIScript VM. `SciterSetVariable` is the pair that does work, and is what
these two use. Its `hwndOrNull` parameter is not optional despite the name: passing NULL reports
success and publishes nothing.

### Calling a function script gave you

When script hands you a callback — as an argument to one of your own functors, or as the result of an
`eval` of a function expression — you hold it as a `Value` and invoke it directly:

```odin
cb := args[0]                                       // borrowed for the call; copy it to keep it
if !sciter_app.value_is_function(&cb) {return {}}

arg := sciter_app.value_from(i32(1))
defer sciter_app.value_clear(&arg)

r, err := sciter_app.value_invoke(&cb, nil, {arg})  // `this` = nil means unbound
defer sciter_app.value_clear(&r)
```

To keep a callback past the current call, `value_copy` it into storage that outlives the frame, and
clear that copy when you are done with it.

### Passing elements

An element can cross the boundary the same way, in either direction, through `element_to_value` /
`element_from_value`:

```odin
odin_took :: proc(args: []sciter_app.Value, user_data: rawptr) -> sciter_app.Value {
	el, err := sciter_app.element_from_value(&args[0])   // script called odin_took(document.$("#row"))
	if err != nil {                                      // .OPERATION_FAILED: not an element
		return sciter_app.value_from(false)
	}
	sciter_app.set_style(el, "color", "red")
	return sciter_app.value_from(true)
}
```

Returning one goes the other way — and, as with any returned `Value`, the engine takes ownership of the
reference, so it is not cleared here:

```odin
odin_gave :: proc(args: []sciter_app.Value, user_data: rawptr) -> sciter_app.Value {
	el, _ := sciter_app.select_first(root, "#tasks")
	v, err := sciter_app.element_to_value(el)
	if err != nil {return sciter_app.value_from(false)}
	return v                                             // script gets a real Element
}
```

Script sees an `Element`, not an opaque handle: `instanceof Element` is true and the usual properties
work. The `Value` holds its own reference to the element, and the handle that comes back out is
borrowed like every other handle — `use_element` it if it has to outlive the `Value`. `node_to_value` /
`node_from_value` do the same for text and comment nodes. See
[`dom.md`](./dom.md#elements-as-values).

### Objects, not just functions

A functor gives script a function. **SOM** gives it an object — properties it can read and write,
methods it can call — which is what a document written against an application's model wants.

```odin
get_count :: proc(asset: ^sciter_app.Asset) -> (sciter_app.Value, bool) {
	state := (^Backend)(asset.user_data)
	return sciter_app.value_from(state.count), true          // the engine takes the reference
}

set_count :: proc(asset: ^sciter_app.Asset, value: ^sciter_app.Value) -> bool {
	state := (^Backend)(asset.user_data)
	n, err := sciter_app.value_to_int(value)                 // borrowed for the call
	if err != nil {return false}
	state.count = n
	return true
}

reload :: proc(asset: ^sciter_app.Asset, args: []sciter_app.Value) -> (sciter_app.Value, bool) {
	state := (^Backend)(asset.user_data)
	state.reloads += 1
	return sciter_app.value_from(i32(state.reloads)), true
}
```

```odin
class, cerr := sciter_app.make_asset_class(
	"Backend",
	{{name = "count", get = get_count, set = set_count}},
	{{name = "reload", params = 0, call = reload}},
)
asset := sciter_app.make_asset(class, &state)
sciter_app.set_global_asset(asset)
sciter_app.load_html(window, DOC)        // the asset appears in *this* document, not the last one
```

```js
Backend.count += 1;
Backend.reload();
```

The rules, all measured against the engine:

- **Publish before loading.** A global asset appears in the next document loaded, not in the one already
  there. Releasing it works the same way round.
- **The class and the asset must outlive the engine's use of them.** The engine stores the addresses;
  the C header asks for the passport to be effectively static. Make one class per kind, once.
- **A property with no `set` is read-only**, and assigning to it throws in script — `eval` reports that
  as a Value that `value_is_error` recognises, not as an `Error`.
- **Members are not enumerable.** `Object.keys(Backend)` is empty; script has to know the names.
- **32 properties and 32 methods per class** (`MAX_ASSET_MEMBERS`). The C API passes no member index to
  its callbacks, so this package writes out one thunk per slot; over the limit is `.Wrong_Type` rather
  than a silent truncation.

`element_asset(el, "edit")` is the other half: the asset an element's *behavior* publishes, which is
what the intrinsic controls expose themselves through.

## Common mistakes

| Symptom | Cause |
| --- | --- |
| Steady memory growth while the UI is idle | a `Value` from `eval` / `call` / `value_at` never cleared |
| Crash on the *second* run of a handler | a `Value` cleared twice, or a returned functor `Value` cleared by you |
| `odin_x is not defined` | `set_global` ran before the load, or the document reloaded afterwards |
| `.Eval_Failed` with no message | no debug output installed — `set_default_debug_output()` |
| Garbled non-ASCII text | a raw `sciter.` call given a UTF-8 pointer; the C API is UTF-16 throughout |
| `value_to_string` returns `.INCOMPATIBLE_TYPE` | the `Value` is not a STRING — use `value_to_display_string` |
| UI freezes when a button is clicked | blocking work inside a native functor, on the engine's thread |
| `value_parse` "succeeded" but gave a string | it failed — check the `.Parse_Failed` error, or `value_is_error` |
| A global asset is `undefined` in script | it was published after the document loaded; publish first |
