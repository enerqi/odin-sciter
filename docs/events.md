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

if de, ok := sciter_app.draw_event(event); ok {
	// de.layer - .BACKGROUND, .CONTENT, .FOREGROUND, .OUTLINE, in that order per repaint
	// de.gfx   - the engine's graphics context, valid for this call only
	// de.area  - the element's rectangle, in the context's coordinates
	// returning true from on_event REPLACES that layer
}

if fe, ok := sciter_app.focus_event(event); ok {
	// fe.code   - .GOT, .LOST, .IN, .OUT, .REQUEST, .ADVANCE_REQUEST
	// fe.target - the *other* element in the move; can be nil at either end of the document
	// fe.raw.cancel = true during .REQUEST or .LOST refuses the move
}

if se, ok := sciter_app.scroll_event(event); ok {
	// se.code     - a bare u32: the header's enum stops at 12 and this engine emits 14
	// se.pos      - the new offset; se.vertical says which bar
	// se.source   - .KEYBOARD / .SCROLLBAR / .ANIMATOR / .WHEEL, and it chooses what se.reason means
}

if ac, ok := sciter_app.attribute_change_event(event, context.temp_allocator); ok {
	// ac.name / ac.value - a removal arrives with value ""
}

if da, ok := sciter_app.data_arrived_event(event, context.temp_allocator); ok {
	// da.data   - bytes from request_element_data / http_request; engine memory, this call only
	// da.status - the HTTP code when there was one; 0 for a local file that worked *and* for a
	//             connection that failed, so len(da.data) is the success test
}

if mc, ok := sciter_app.method_call(event); ok {
	// mc.id     - the method id; yours if >= FIRST_APPLICATION_METHOD_ID (256)
	// mc.params - the caller's parameter block, written in place
	// method_args(mc) types it for the engine's own ids - see api.md, "Behavior methods"
}

if xe, ok := sciter_app.exchange_event(event); ok {
	// xe.code   - .WILL_ACCEPT_DROP, .DRAG_ENTER, .DRAG, .DROP, ...
	// xe.pos    - [2]i32, relative to the target element
	// xe.source - the dragged element; nil for a drag from another application
	// xe.mode   - .COPY / .MOVE / .LINK, as the source offered it
	// xe.data   - the payload Value; borrowed, do not clear
}
```

`.raw` is on every one of them deliberately: the wrapper surfaces the fields that are used constantly
and does not pretend to cover the rest, so nothing is out of reach.

`.SIZE` has no accessor because it has no parameters: `event.element` — the element whose box changed —
is the whole payload. Measured, it is that element's own resize rather than the window's: maximizing
and restoring the window produced none, restyling a `<div>`'s width produced one.

**Three groups never reach a window handler.** `.METHOD_CALL`, `.SCROLL` and `.ATTRIBUTE_CHANGE` are
delivered only to handlers attached to the element itself, so `attach_handler` is the only attachment
that receives one — measured with both attached at once. The animation frame below behaves the same
way.

For any group still without an accessor, cast `event.params` to the matching struct from
`package sciter` yourself. The struct name follows the header (`Style_Change_Params`, …). `.TIMER` has
`timer_event`, below.

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

## Animation frames

The engine's frame clock, which the timers above are not: a timer counts milliseconds and fires whether
or not anything is being drawn; this fires on the next frame the engine paints. It is script's
`requestAnimationFrame` reached from native code.

```odin
sciter_app.request_animation_frame(el, TICK)     // TICK >= .FIRST_APPLICATION_EVENT_CODE
```

`code` arrives as an ordinary `.BEHAVIOR_EVENT` carrying `reason`, and — like `.TIMER`, and unlike
everything else in this file — **the handler's return value decides whether it happens again**: true
re-arms it for the next frame, false is the last one. Measured: answered false, one request produced
exactly one event however long the pump ran; answered true, one per frame.

It reaches handlers on that element only, so it needs `attach_handler`. The engine brackets each
request with its own `.ANIMATION` events, `reason = 1` before and `reason = 0` after, and those two
*do* bubble to a window handler.

## Which events exist

- **`.BEHAVIOR_EVENT`** — the logical, semantic ones, emitted by the intrinsic behaviors:
  `.BUTTON_CLICK`, `.BUTTON_PRESS`, `.VALUE_CHANGED`, `.VALUE_CHANGING`, `.SELECTION_CHANGED`,
  `.HYPERLINK_CLICK`, the popup and menu events. **Start here** — `.BUTTON_CLICK` on a `<button>` is
  what you want, not a `.MOUSE_UP` you have to hit-test yourself.
- **`.MOUSE`**, **`.KEY`**, **`.FOCUS`** — the raw input events, for custom controls.
- **`.SIZE`**, **`.SCROLL`**, **`.TIMER`** — layout and timing.
- **`.DRAW`** — a paint request, and the onscreen way to get a `Graphics`. Very high frequency;
  subscribe only when you mean to draw. `draw_event(event)` decodes it — see
  [`graphics.md`](./graphics.md#the-draw-event).
- **`.EXCHANGE`** — system drag-and-drop. See [Drag and drop](#drag-and-drop).
- **`.METHOD_CALL`**, **`.SCRIPTING_METHOD_CALL`** — behavior-specific method dispatch.

The full lists are `Behavior_Events`, `Mouse_Events`, `Key_Events` and friends in `sciter.odin`,
generated straight from `sciter-x-behavior.h`.

## Drag and drop

System drag-and-drop is one event group, `.EXCHANGE`, on an ordinary handler — there is no separate API
table for it. [`drag_and_drop`](../examples/drag_and_drop.odin) is the whole arrangement.

```odin
handler := sciter_app.Event_Handler {
	subscription = {.EXCHANGE},
	on_event     = on_event,
}
sciter_app.attach_handler(drop_zone, &handler)   // on the target, so pos is element-relative
```

The events for one drop, measured against an X11 drag source on 6.0.4.9:

```
WILL_ACCEPT_DROP -> DRAG_ENTER -> DRAG -> WILL_ACCEPT_DROP -> DROP
```

each delivered twice, sinking then bubbling.

**Consume both `.WILL_ACCEPT_DROP` and `.DRAG`** — return `true` for them — or the engine tells the drag
source it is not interested and `.DROP` never arrives. `sciter-x-behavior.h` documents only the first of
the two; consuming just that was measured to leave the drop refused, and `.DRAG_ENTER` makes no
difference either way. Act in one phase: consuming a `.DROP` in both counts it twice.

```odin
switch xe.code {
case .WILL_ACCEPT_DROP: return true    // "this element takes drops"
case .DRAG:             return true    // ... and means it
case .DROP:             take(xe.data); return true
}
```

### What Linux does not do

Both of these are the vendored engine's behaviour, not the bindings':

- **The payload arrives empty.** A real X11 drop delivered `.DROP` with `xe.data` an empty map, so what
  was dragged is not readable through this path. The positions, the target element and the event
  sequence are all correct — it is only the data.
- **There is no drag source.** Nothing in `ISciterAPI` starts a drag; the only way is script's
  `Window.this.performDrag(data, mode)`, and on Linux it returns `null` immediately with no EXCHANGE
  events following. `.MOUSE_DRAG_REQUEST` in the `.MOUSE` group *is* delivered, so "the user has begun
  dragging this element" is observable; turning that into a system drag is not.

## Detaching

```odin
sciter_app.detach_handler(el, &handler)
sciter_app.detach_window_handler(window, &handler)
```

Detach before the `Event_Handler`'s storage goes away. A handler attached to an element that is
destroyed with the document is cleaned up with it, so an application-lifetime handler on `root` needs
nothing.

## Named events

`send_event` and `post_event` carry a code, a source and a reason. `fire_event` carries a **name** and a
**payload** as well, which is what makes it the channel *to* script:

```js
document.$("#chart").on("data-arrived", function(e) { redraw(e.data); });
```

```odin
value := sciter_app.value_parse(json) or_return
defer sciter_app.value_clear(&value)

handled, err := sciter_app.fire_event({
	code   = .CUSTOM,
	name   = "data-arrived",
	target = chart,
	data   = &value,
})
```

Script sees an ordinary event whose type is the name, so a document can be written against events it
declares and Odin can raise them without knowing what listens. On the receiving side in Odin,
`event_name(be, allocator)` decodes the name — it is not in `Behavior_Event` because the engine hands it
over as UTF-16 and most handlers never look at it.

Four rules of its own:

- **It goes down and back up**, like every other event, so a handler that acts on both phases acts
  twice.
- **A nil `target` broadcasts** to every window — and only handlers attached with
  `attach_window_handler` receive that. An element handler, `root`'s included, does not.
- **`post = true` copies the name and the payload**, so neither has to outlive the call. It also means
  `handled` is always false: nothing has seen the event yet.
- **`data` is borrowed**, not consumed. Clear it as usual.

## Mouse capture

While an element holds the capture, **every** mouse event goes to it — wherever the pointer is, inside
the element or not, inside the window or not. That is what makes a drag possible: the `.MOUSE_DOWN`
that starts one takes the capture, `.MOUSE_MOVE` keeps arriving while the button is down, and
`.MOUSE_UP` gives it back.

```odin
if me, ok := sciter_app.mouse_event(event); ok {
	#partial switch me.code {
	case .MOUSE_DOWN: sciter_app.set_capture(me.target)
	case .MOUSE_MOVE: // arrives even outside the element, because of the capture
	case .MOUSE_UP:   sciter_app.release_capture(me.target)
	}
}
```

Neither call is fussy: taking the capture while another element holds it moves it, and releasing when
nothing was captured succeeds — so an unconditional `release_capture` on the way out is safe. The one
failure is `.INVALID_HWND`, for an element that is in no document and therefore in no window.

This is *mouse* capture and has nothing to do with [drag and drop](#drag-and-drop) above, which is the
system's own protocol for data crossing an application boundary.

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
directly, bypassing the intrinsic behavior that would normally produce it. Handlers do hear the event —
a window handler counting `.BUTTON_CLICK`s counts this one — but nothing else happens: measured on a
checkbox, `send_event(cb, .BUTTON_CLICK, cb)` leaves `:checked` exactly as it was.

To drive the widget rather than announce it, call the behavior:

```odin
handled, err := sciter_app.do_click(checkbox)   // :checked flips, VALUE_CHANGED then BUTTON_CLICK
```

`do_click` is in [`behavior.odin`](../sciter_app/behavior.odin); `examples/behavior.odin` puts the two
side by side. The state change is synchronous, the events it raises are queued, so a handler has not
seen them until the pump turns.

## Synthesising input

`do_click` drives one widget. `send_mouse` and `send_key` are the general mechanism — the engine's
`SciterTraverseUIEvent`, which sinks and bubbles the event the way the window system's own input does,
so the intrinsic behaviors run:

```odin
sciter_app.send_mouse(button, .MOUSE_DOWN, at, {.Main})
sciter_app.send_mouse(button, .MOUSE_UP, at, {.Main})     // BUTTON_CLICK follows

sciter_app.set_focus(field)
sciter_app.send_text(field, "hello")                      // .DOWN/.CHAR/.UP per rune
```

This is what a test driving its own UI needs, what an automation or accessibility layer is built on,
and the only route to hover, drag, the wheel and the keyboard. Three requirements, each measured:

- **the element must be named.** There is no hit testing inside the call — a nil one is
  `.INVALID_HANDLE`. `element_at(window, pos)` is how a coordinate becomes the element to aim at.
- **`buttons` must carry the button.** A `.MOUSE_DOWN` with an empty set is delivered to handlers,
  reports `processed = false`, and the button behavior ignores it — no `:active`, no `.BUTTON_CLICK`.
  It is which buttons are held *during* the event, so a press and its release both carry one.
- **the position is in the window's client area**, the space `location(el, .Border, .View)` and
  `element_at` use. The engine recomputes the element-relative `pos` each handler sees from it.

`examples/input.odin` drives a button, a checkbox and a text field this way, and asserts it.

Use it for **application event codes of your own** — `Behavior_Events` values at or above
`FIRST_APPLICATION_EVENT_CODE` — which have no behavior behind them and are exactly what this is for.
That gives you a document-scoped notification bus that both Odin and script can listen on.

To simulate a real interaction — in a test, say — go through script instead:

```odin
sciter_app.eval(window, "document.$('#ok').click()")
```

That runs the behavior and produces the genuine event.

`post_event` queues an application event code for a later turn of the pump, but it is **not** the way
in from another thread: like everything else here it has to be called on the engine's thread.
[`post_callback`](./api.md#posting-work-to-the-engines-thread) is the one call that is safe from a
worker. See [`architecture.md`](./architecture.md#threading) — every `ISciterAPI` call has to come from
the thread that ran `SCITER_APP_INIT`.

## Debugging a handler that never fires

In order of likelihood:

1. `subscription` does not include the group. `.BEHAVIOR_EVENT` is the one people forget.
2. The handler was attached to the wrong subtree — attach at `root` and narrow later.
3. The comparison did not strip the phase. Use `be.code`, not `p.cmd`.
4. The `Event_Handler` moved or went out of scope after attaching.
5. The event was synthesised with `send_event` and no `source` — nothing is delivered at all.
6. The document reloaded. Element-attached handlers go with the old document; use
   `attach_window_handler` if you reload.
