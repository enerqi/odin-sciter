# Events

Getting the engine to call Odin when something happens in the document — clicks, typing, the mouse —
without any script in the page. The code is [`sciter_app/events.odin`](../sciter_app/events.odin) and
the runnable version is [`examples/events.odin`](../examples/events.odin).

There is a second route into Odin, through script calling a native functor, covered in
[`calling-between-odin-and-js.md`](./calling-between-odin-and-js.md). Neither is more correct than the
other: use script when the document already knows what it wants to do, and an event handler when the
host owns the logic.

## The shape

```odin
Counter :: struct {
	handler: sciter_app.Event_Handler,
	count:   int,
}

on_event :: proc(handler: ^sciter_app.Event_Handler, event: sciter_app.Event) -> bool {
	counter := (^Counter)(handler.user_data)

	be, ok := sciter_app.behavior_event(event)
	if !ok || be.code != .BUTTON_CLICK || be.phase != .Bubbling {
		return false
	}

	counter.count += 1
	return true          // handled - see "The return value" below
}

// ...
counter := Counter {
	handler = {subscription = {.BEHAVIOR_EVENT}, on_event = on_event},
}
counter.handler.user_data = &counter

root, _ := sciter_app.root(window)
sciter_app.attach_handler(root, &counter.handler)
```

Attach to one element and you hear about that element and everything below it, so attaching at `root`
is the usual arrangement. `attach_window_handler(window, &handler)` covers the whole document
*including elements that do not exist yet* — the right choice when script rebuilds the DOM.

## Four rules

**1. The `Event_Handler` must not move.** The engine stores its address as the handler's tag. Put it in
a struct that outlives the window (as above), not on the stack of a procedure that returns, and do not
copy it after attaching.

**2. The subscription mask is not optional.** Right after attaching, the engine calls the handler with
`SUBSCRIPTIONS_REQUEST` to ask what to send. A handler that ignores that question **receives nothing at
all** — a silent, total failure that looks like a broken attach. `sciter_app` answers it for you from
`Event_Handler.subscription`, which is the whole reason that field exists.

```odin
subscription = {.BEHAVIOR_EVENT}                     // clicks, value changes, the useful ones
subscription = {.MOUSE, .KEY, .FOCUS}
subscription = sciter.HANDLE_ALL                     // everything; noisy, and DRAW is very noisy
```

`{}` receives nothing except initialization events, which arrive regardless.

**3. The phase is OR'ed into the event code.** Every parameter struct's `cmd` field carries the
propagation phase in its high bits, so `cmd == .BUTTON_CLICK` is false during sinking. That is why
`package sciter` leaves `cmd` a bare integer: `MOUSE_DOWN | SINKING` is not a value of the
`Mouse_Events` enum. The typed accessors split them for you into `code` and `phase`.

| `Event_Phase` | When |
| --- | --- |
| `.Sinking` | travelling down towards the target, before it sees the event — intercept here |
| `.Bubbling` | travelling back up from the target — the normal case, and where you want to be |
| `.Handled` | something already claimed it |

Filtering on `.Bubbling` is almost always what you want. Otherwise a single click looks like two or
three events and counters run double.

**4. The handler runs on the engine's thread with a borrowed context.** `attach_handler` captures the
calling `context` and the trampoline restores it, because the engine calls back as `proc "system"`
where Odin's implicit context does not exist. Whatever allocator was current at attach time is the one
your handler will allocate from — so attach from `main`, not from inside a temporary arena.

Blocking inside a handler freezes the UI; the pump is not running while you are.

## Typed parameters

`Event.params` points at the group's own parameter struct. Cast it with the accessors rather than by
hand — each returns `ok = false` if the event is not of that group:

```odin
if be, ok := sciter_app.behavior_event(event); ok {
	// be.code    - .BUTTON_CLICK, .VALUE_CHANGED, .HYPERLINK_CLICK, ...
	// be.target  - the element the behavior belongs to (the button)
	// be.source  - where the event originated
	// be.reason  - a CLICK_REASON or EDIT_CHANGED_REASON, depending on be.code
	// be.data    - the payload Value; borrowed, do not clear
	// be.raw     - the engine's own struct, for anything not surfaced
}

if me, ok := sciter_app.mouse_event(event); ok {
	// me.code    - .MOUSE_DOWN, .MOUSE_MOVE, ...
	// me.pos     - [2]i32, relative to the target element
	// me.buttons - Mouse_Buttons
}

if ke, ok := sciter_app.key_event(event); ok {
	// ke.code      - .KEY_DOWN, .KEY_UP, .KEY_CHAR
	// ke.key_code  - a virtual key for DOWN/UP, a character for CHAR
	// ke.modifiers - Keyboard_States
}
```

`.raw` is on every one of them deliberately: the wrapper surfaces the fields that are used constantly
and does not pretend to cover the rest, so nothing is out of reach.

For groups without an accessor yet — `.FOCUS`, `.SCROLL`, `.TIMER`, `.SIZE`, `.EXCHANGE`,
`.ATTRIBUTE_CHANGE` — cast `event.params` to the matching struct from `package sciter` yourself. The
struct name follows the header (`Focus_Params`, `Scroll_Params`, …).

## The return value

Returning `true` marks the event **handled**. Whoever sent it is told — that is the `handled` out of
`send_event` — and the rest of the trip carries the `HANDLED` bit, so handlers further along see
`Event_Phase.Handled` instead of `.Sinking` or `.Bubbling`.

It does **not** cancel delivery. Claiming an event during the sinking phase does not stop the bubbling
phase from reaching the same handler, which is the other half of why acting on every phase acts twice.
What `true` does is tell intrinsic behaviors that someone dealt with it — and getting *that* wrong is
subtle in one direction: swallowing a `.MOUSE` event that an intrinsic behavior needed makes a control
stop responding for no visible reason. When in doubt, return `false` for anything you only observed.

## Timers

A timer belongs to an element and delivers a `.TIMER` event to the handlers on it. It is the engine's
own clock rather than a thread: the event arrives on the engine's thread inside the message pump, so a
handler can touch the DOM directly and needs no synchronisation.

```odin
sciter_app.set_timer(el, 100 * time.Millisecond, MY_TIMER)   // id tells several timers apart
sciter_app.stop_timer(el, MY_TIMER)
```

```odin
if te, ok := sciter_app.timer_event(event); ok {
	if te.id == MY_TIMER {
		tick()
	}
	return true          // keep it running; false stops it
}
```

Three things about timers that are all invisible when they go wrong, because each one looks like a
timer that never started:

- **The return value is inverted for this group.** `true` keeps the timer running and `false` stops
  it — the opposite of every other group, and the opposite of the advice above to return `false` for
  anything you only observed. A handler ending in an unconditional `return false` gets exactly one
  tick.
- **A timer does not bubble.** It is delivered to handlers on the element it was set on and nowhere
  else, so a handler on `root` hears nothing about a timer set on a button inside it. Set the timer on
  the element the handler is attached to, or attach a handler to the element with the timer.
- **Nothing arrives unless the pump runs.** `run` does it; when Sciter shares a thread, `heartbeat`
  services timers without touching input.

Calling `set_timer` again with the same `id` replaces that timer rather than adding a second one, so
it doubles as "change the interval". The engine counts whole milliseconds and an interval of zero is
what stops a timer, so `set_timer` raises a positive sub-millisecond interval to one millisecond
instead of rounding it down to a silent stop — `stop_timer` is the way to spell stopping.

`.TIMER` has to be in `subscription` like any other group.

## Which events exist

- **`.BEHAVIOR_EVENT`** — the logical, semantic ones, emitted by the intrinsic behaviors:
  `.BUTTON_CLICK`, `.BUTTON_PRESS`, `.VALUE_CHANGED`, `.VALUE_CHANGING`, `.SELECTION_CHANGED`,
  `.HYPERLINK_CLICK`, the popup and menu events. **Start here** — `.BUTTON_CLICK` on a `<button>` is
  what you want, not a `.MOUSE_UP` you have to hit-test yourself.
- **`.MOUSE`**, **`.KEY`**, **`.FOCUS`** — the raw input events, for custom controls.
- **`.SIZE`**, **`.SCROLL`**, **`.TIMER`** — layout and timing.
- **`.DRAW`** — a paint request. Very high frequency; subscribe only when you mean to draw.
- **`.METHOD_CALL`**, **`.SCRIPTING_METHOD_CALL`** — behavior-specific method dispatch.

The full lists are `Behavior_Events`, `Mouse_Events`, `Key_Events` and friends in `sciter.odin`,
generated straight from `sciter-x-behavior.h`.

## Detaching

```odin
sciter_app.detach_handler(el, &handler)
sciter_app.detach_window_handler(window, &handler)
```

Detach before the `Event_Handler`'s storage goes away. A handler attached to an element that is
destroyed with the document is cleaned up with it, so an application-lifetime handler on `root` needs
nothing.

## Synthesising events

```odin
handled, err := sciter_app.send_event(el, .BUTTON_CLICK, source = el)   // synchronous, down and back up
```

```odin
err := sciter_app.post_event(el, .BUTTON_CLICK, source = el)            // queued, returns immediately
```

**`source` is not optional in practice.** It defaults to `nil`, and the engine delivers nothing at all
for a nil source — not to `el`, not to anything on the chain. The call still succeeds and reports "not
handled", which is indistinguishable from an event nobody wanted. Pass `el` itself when there is no
separate originating element.

The two handles also land the opposite way round from what the names suggest: `source` arrives as
`be.target` and `el` as `be.source`. Events from intrinsic behaviors put the acting element in
`be.target`, so a handler written against real clicks reads a synthesised one backwards.

**This is not the same as the user doing it.** It injects the event code into the element chain
directly, bypassing the intrinsic behavior that would normally produce it: sending `.BUTTON_CLICK` to a
`<button>` does not go through the button behavior, and a handler watching for clicks will not see one.

Use it for **application event codes of your own** — `Behavior_Events` values at or above
`FIRST_APPLICATION_EVENT_CODE` — which have no behavior behind them and are exactly what this is for.
That gives you a document-scoped notification bus that both Odin and script can listen on.

To simulate a real interaction — in a test, say — go through script instead:

```odin
sciter_app.eval(window, "document.$('#ok').click()")
```

That runs the behavior and produces the genuine event.

`post_event` is also the tidy way to get work from a non-engine thread onto the engine's thread: queue
an application event code and handle it in the pump. See
[`architecture.md`](./architecture.md#threading) — every `ISciterAPI` call has to come from the thread
that ran `SCITER_APP_INIT`.

## Debugging a handler that never fires

In order of likelihood:

1. `subscription` does not include the group. `.BEHAVIOR_EVENT` is the one people forget.
2. The handler was attached to the wrong subtree — attach at `root` and narrow later.
3. The comparison did not strip the phase. Use `be.code`, not `p.cmd`.
4. The `Event_Handler` moved or went out of scope after attaching.
5. The event was synthesised with `send_event` and no `source` — nothing is delivered at all.
6. The document reloaded. Element-attached handlers go with the old document; use
   `attach_window_handler` if you reload.
