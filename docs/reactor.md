# Reactor

Sciter's answer to React, and the reason a Sciter UI needs no build step, no bundler and no npm. This
page covers what Reactor actually is, the parts that differ from React in ways that will bite, and how
it meets the Odin side of these bindings.

Everything here was checked against the vendored engine (6.0.4.9) with a probe document run under the
SDK's `scapp`, not transcribed from the SDK's `docs/md/reactor/`. Three behaviours below are *not*
in those docs, and two SDK examples contradict each other — see [Traps](#traps).

## What it is

The SDK's own README is blunt: "Reactor is not a framework or a library. It is just a built-in set of
features of SciterJS." Those features are two, plus signals:

1. **JSX, parsed natively by the script compiler.** `<div class="x">{value}</div>` is a JavaScript
   literal, the same way `[1,2]` is. No Babel, no transpiler, no build step.
2. **`element.patch(vdom)`** — real-DOM/virtual-DOM reconciliation implemented in C++ inside the engine.
3. **Signals** — `Reactor.signal` / `computed` / `effect`, observable values with automatic subscription.

That is the whole of it. There is no component registry, no scheduler you configure, no framework
runtime to ship. Everything else is convention on top of those three.

```js
document.body.patch(<body>Hello, world!</body>);   // the smallest Reactor program
```

## JSX

A JSX literal is a plain value — cheap to create, no DOM touched:

```js
const vn = <div id="foo">bar</div>;

Reactor.isNode(vn)      // true
Reactor.tagOf(vn)       // "div"
Reactor.propsOf(vn).id  // "foo"
Reactor.kidsOf(vn)[0]   // "bar"
```

The literal form and the function form are equivalent, which is occasionally useful for building nodes
dynamically:

```js
<div id="foo">bar</div>  ===  JSX("div", {id:"foo"}, ["bar"])
```

JSX is not tied to components. `el.append(<li>new item</li>)` is a perfectly ordinary use of it.

## `patch()` and reconciliation

`element.patch(vdom)` compares the element's current subtree against the virtual one and applies only
the differences. Measured on the vendored engine:

```js
root.patch(<div id="root"><h1>one</h1><p>keep</p></div>);
const h1 = root.$("h1");
root.patch(<div id="root"><h1>two</h1><p>keep</p></div>);

root.$("h1") === h1        // true  - same DOM object, not a replacement
root.$("h1").innerText     // "two" - only the text node changed
```

The untouched `<p>` is the same object too. This is what lets you re-render the whole UI description on
every tick and pay only for what changed:

```js
function tick() {
  document.$("#root").patch(
    <div id="root">
      <h1>Hello, world!</h1>
      <h2>It is {new Date().toLocaleTimeString()}.</h2>
    </div>);
  return true;                 // keep the timer running
}
setInterval(tick, 1000);
```

**`patch()` owns the attributes of everything it manages.** Measured: an attribute set imperatively
outside `render()` is *removed* by the next patch, even though the element object itself survives.

```js
h1.setAttribute("data-mark", "kept");
root.patch(<div id="root"><h1>three</h1><p>keep</p></div>);
h1.getAttribute("data-mark")   // null - wiped
```

So a patched subtree is not a place to stash imperative state. Anything that must survive a re-render
belongs in the vdom your `render()` returns, or on a DOM element outside the patched region. This is not
documented in the SDK.

### `patch()` vs `content()`

`content(vdom)` builds the subtree outright; `patch(vdom)` reconciles against what is there. Use
`content()` for the first render of a region and `patch()` for updates — or just use `patch()` for both,
which is what `componentUpdate()` does internally.

## Components

A component is a function (or class) taking props and returning a virtual element. **Names must start
with a capital letter** — that is how the compiler tells `<Welcome/>` from `<welcome/>`.

```js
function Welcome(props) {
  return <h1>Hello, {props.name}</h1>;
}

document.$("#host").content(<Welcome name="Ivan"/>);   // -> <h1>Hello, Ivan</h1>
```

The full signature is `(props, kids, parent)`:

```html
<FunctionComponent mode="start">
   <div>bar</div>
</FunctionComponent>
```

gives `props = { mode: "start" }`, `kids = [ <div>bar</div> ]`, and `parent` = the container DOM element
the component will live in.

### Class components, and the big difference from React

```js
class Clock extends Element {
  time = new Date();                     // local state is just a field

  componentDidMount() {
    this.timer(1000, () => {
      this.componentUpdate({ time: new Date() });
      return true;
    });
  }

  render() {
    return <div>It is {this.time.toLocaleTimeString()}</div>;
  }
}
```

`extends Element` is not decoration. **`this` *is* the real DOM element** — verified: the rendered
element satisfies `instanceof Clock`, and `this.time` is a property of that DOM element. There is no
wrapper object and there are no refs, because there is nothing to get a reference *through*. `this.$()`,
`this.classList`, `this.state`, `this.timer()` and every other `Element` method are available inside a
component with no ceremony.

That single difference explains most of the divergence from React below.

### Lifecycle

| Method | When |
| --- | --- |
| `constructor(props, kids)` | standard JS constructor, once, at element creation |
| `this(props, kids)` | after `constructor` and before each `render()` — i.e. every time props/kids arrive |
| `componentDidMount()` | after the element is attached to the DOM |
| `componentWillUnmount()` | immediately before removal from the DOM |
| `render([props, kids])` | **mandatory**; returns the JSX describing the element's content |
| `componentUpdate(props)` | *you* call this to update state |

`this(props, kids)` as a method name is Sciter's own syntax, not standard JavaScript, and it is the
closest thing to React's "component received new props".

**`componentDidMount()` is asynchronous.** Measured: it had *not* fired when `content(<Clock/>)`
returned, and had fired by the next event cycle. Do not write code that assumes the component is mounted
on the line after you render it. Not documented in the SDK.

### `componentUpdate()`

The engine's implementation is effectively:

```js
componentUpdate(newdata = null) {
  if (typeof newdata == "object") Object.assign(this, newdata);
  this.post(() => this.patch(this.render()));
}
```

Three consequences, all measured:

- **It is deferred.** `this.post()` schedules the re-render for the next event cycle. Immediately after
  calling `componentUpdate({time:"t1"})` the DOM still showed the old value; it showed the new one on the
  next cycle. This is a feature — multiple updates collapse into one `render()` and one patch.
- **Updates are merged**, so separate calls for different parts of the state coalesce:
  ```js
  clock.componentUpdate({ time: new Date() });
  clock.componentUpdate({ greeting: "John" });   // one render(), one patch
  ```
- **Assigning directly does not re-render.** `this.comment = "Hello"` changes the field and nothing else.
  Direct assignment is only correct in the constructor / field initialiser.

## Signals

Observable values. `Reactor.signal(v)` returns an object whose `.value` you read and write; reading it
inside an `effect()` or `computed()` subscribes automatically, with no explicit subscribe call.

```js
const { signal, computed, effect } = Reactor;

const count = signal(0);
effect(() => console.log(`count is ${count.value}`));   // runs now, and on every change
count.value += 1;                                        // -> logs "count is 1"

const name = signal("John"), surname = signal("Smith");
const fullName = computed(() => `${name.value} ${surname.value}`);
fullName.value        // "John Smith"
name.value = "Jane";
fullName.value        // "Jane Smith"
```

Four kinds of subscriber:

1. **`effect(fn)`** — arbitrary code re-run on change. Returns a signal you can `.dispose()`.
2. **`computed(fn)`** — a derived signal, itself subscribable.
3. **Reactive components** — a component that reads `someSignal.value` in its body re-renders whenever
   that signal changes, with no `componentUpdate()` call. Measured: setting the signal took the rendered
   text from `clicked 0 times` to `clicked 7 times`, with `render()` running a second time.
   ```js
   const clicks = signal(0);
   function ButtonCounter() {
     return <div>
       <button onClick={() => clicks.value++}>Click me</button>
       <span>clicked {clicks.value} times</span>
     </div>;
   }
   document.body.append(<ButtonCounter/>);
   ```
4. **Signal-bound inputs**, two-way: `<input|integer value={count}/>`. User edits fire the signal; code
   writes update the input — *except* while the input has focus.

### Signal API

| | |
| --- | --- |
| `Reactor.signal(init)` | new signal |
| `Reactor.computed(fn)` | derived signal |
| `Reactor.effect(fn)` | side effect; returns a disposable signal |
| `element.signal(init)` | signal whose **lifespan is tied to that element** — the right choice inside a function component, via `this.signal(0)` |
| `s.value` | read/write; assignment fires only if the value actually changed |
| `s.send(v)` | fire unconditionally, even if unchanged |
| `s.peek()` | read *without* subscribing |
| `s.dispose()` | stop the signal, free its links |
| `s.valueElements` | input elements bound to it |
| `s.observingElements` | DOM elements observing it |

**Lifetime trap.** A signal lives only as long as the variable holding it. Let it go out of scope and it
is destroyed, silently invalidating every observer. Module-level `const` for app-wide signals,
`this.signal()` for component-scoped ones — never a bare local in a function that returns.

The SDK claims `computed(() => \`${name} ${surname}\`)` works — bare signal names, no `.value`. Verified:
it does. Prefer the explicit `.value` anyway; the bare form reads like a bug to anyone who knows JS.

## Lists and keys

Same rules as React, for the same reason:

```js
const items = todos.map(todo =>
  <li key={todo.id} status={todo.status}>{todo.text}</li>);

document.$("#list").patch(<ul>{items}</ul>);
```

Keys are only needed for lists you intend to `patch()` — a list rendered once with `content()` does not
need them. Keys must be unique among siblings, not globally. Do not use array indexes when the order can
change.

## Component styles

Components carry their own CSS through **style sets**, which do not pollute the global rule list:

```js
render() {
  return <clock styleset={__DIR__ + "styles.css#clock"}>
    <div class="greeting">Hello, world!</div>
  </clock>;
}
```

```css
@set clock {
  :root      { display: block; flow: vertical; }
  span.time  { display: inline-block; white-space: nowrap; }
}
```

`:root` inside an `@set` means the component's own element. The style set can also be declared inline in
the same JS file with the `CSS.set` tagged template:

```js
const clockStyles = CSS.set`
  :root { display: block; flow: vertical; }
`;
// ... styleset={clockStyles}
```

Convention worth keeping: a reusable component's default style set should carry only the rules its
*layout* depends on, leaving appearance to the application.

## Top-level API

| | |
| --- | --- |
| `JSX(type, props, children)` | build a vnode; what a JSX literal compiles to |
| `Reactor.cloneOf(vnode, props, kids)` | clone with shallow-merged props; preserves `key` |
| `Reactor.isNode(o)` | is it a vnode |
| `Reactor.tagOf(vnode)` | `"div"` |
| `Reactor.propsOf(vnode)` | props object |
| `Reactor.kidsOf(vnode)` | children array |
| `element.patch(vnode)` | reconcile |
| `element.content(vnode)` | build outright |
| `element.componentUpdate(data)` | merge state, schedule a re-render |

## Traps

Collected, because most of these cost an hour each:

- **`componentDidMount()` is async** — not fired by the time the render call returns.
- **`patch()` wipes attributes it does not own**, while keeping the element object itself.
- **`componentUpdate()` is deferred** to the next event cycle. Assert on the DOM after a `setTimeout`,
  not on the next line — this matters in tests especially.
- **Direct field assignment never re-renders.** Only `componentUpdate()` does.
- **Signals die with their variable.** Out of scope means observers silently stop firing.
- **Component names must be capitalised**, or the compiler emits a plain HTML tag instead.
- **`obj.method { a: 1 }` is Sciter syntax sugar** for `obj.method({a: 1})` — verified working. The SDK
  docs use both forms interchangeably; it is not a typo, but it is not JavaScript either.
- **The SDK's own examples disagree** on where component state lives: `docs/md/reactor/component-update.md`
  writes the field as `this.time` in one sample and reads it as `this.data.time` in the next. The engine
  agrees with `this.time` — state is a plain property of the element. Measured: on a freshly rendered
  class component `typeof this.data` is `"undefined"`, so `this.data` is prose convention only, not
  something the runtime provides. Pick one and it should be the plain field.
- **`Window.this.close()` crashes the engine if called synchronously from a `ready` handler** — a hard
  core dump, not an exception, and it happens with an empty document and no Reactor involved at all.
  Defer it (`setTimeout(() => Window.this.close(), 0)`). This only bites when writing self-terminating
  probe or test documents, which is exactly what you write when checking behaviour like the above.

## From Odin

Reactor is entirely script-side; nothing in these bindings knows about it. Two points of contact:

- **Feeding data in.** Publish through `sciter_app.set_global(window, name, &value)`, then read it from
  a component's `render()` or seed a signal with it. `set_global` publishes into the *document's* global
  scope, so it must be redone after every document load — see
  [`calling-between-odin-and-js.md`](./calling-between-odin-and-js.md). Do not assign into `globalThis`
  from an `eval`'d string as a shortcut.
- **Driving updates from native code.** Call the component's method rather than rebuilding the DOM from
  Odin: get the element, then `eval_element(el, "this.componentUpdate({...})")`, or hold a `Value`
  holding the function and call it. Letting `render()` stay the single description of the UI is the whole
  point of the design; patching the DOM from two directions defeats it.

For a native object exposed to script as a first-class value, `set_global_asset` and the SOM path in
[`api.md`](./api.md) are the better tool — a Reactor component can then read properties off it directly.

## Further reading

The SDK's own docs, in `docs/md/reactor/` of a
[sciter-js-sdk](https://gitlab.com/sciter-engine/sciter-js-sdk) checkout: `README.md`, `JSX.md`,
`rendering.md`, `component.md`, `component-update.md`, `component-styles-events.md`,
`lists-and-keys.md`, `signals.md`, `reactor-api.md`, `reactor-vs-reactjs.md`, `component-lifecycle.md`,
`JSX-i18n.md` (built-in i18n primitives, not covered here).
