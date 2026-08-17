# Angle 11 — invariants with partial enforcement — 2026-08-16

> **Later note, 2026-08-17.** The three checks proposed here shipped as `.github/scripts/check-invariants.py`
> and have since been rewritten in Odin as `tools/checks/invariants.odin`, one subcommand of
> `tools/checks`. `just check-invariants` is unchanged. The rewrite was not a translation: parsing rather
> than grepping showed that rule A had been passing four procedures it should have failed. The old scan
> took a procedure's body to run to the next column-0 declaration, so it swept up the doc comment above
> `tracked` — which reads ``a producer reads `return tracked(v), nil` `` — and credited every caller of
> `value_clear` with a path to the ledger. `behavior_value`, `asset_call` and the two `scoped_` twins had
> no such path; `tracked()` was added to the two producers, and to `asset_get`'s accessor branch, which
> has the same hole and which the per-procedure rule still cannot see. Paths named below are the ones
> that existed when this was written.

A sweep rather than an audit, and it exists because of what [`10-threading.md`](10-threading.md) turned
out to be. R10-01 was not really a threading bug. It was a *shape*: an invariant with a chokepoint that
only saw some of the paths, and nothing measuring the fraction. The guard watched 124 of 199 engine call
sites, the number was in nobody's head, and the gap hid a genuine two-thread split on macOS for a day.

So: where else does this repository state an invariant, enforce it at a chokepoint, and not measure the
coverage? Three candidates, all mechanical enough to count:

| | invariant | what enforces it | what measures the coverage |
|---|---|---|---|
| A | a procedure handing back a `Value` records the reference | `tracked()` at each producer | nothing |
| B | a procedure handing back an owned handle records it | `track_acquire()` at each producer | nothing |
| C | every `proc "system"` restores an Odin context | a `context = ` at the top of each | nothing |

**All three hold. None of them was being held.** That distinction is the finding, and it is the same one
angle 10 ended on: A and C were verified by hand in the 2026-08-13 sweep — angle 9 checked all eighteen
trampolines and called it "a clean sweep… the failure mode most likely to produce unexplainable
corruption" — and so was rule 1, nine days before it drifted.

---

## Method, and the thing that nearly buried it

A first pass asked the obvious question: does this procedure call the recorder? It reported 40 holes in
invariant A against 63 producers, which is not a result, it is noise. Every `scoped_` twin, every
wrapper and every convenience overload delegates: `value_get` calls `value_get_key`, which calls
`tracked`; `remove_element` calls `use_element`; `take_request` calls `use_request`. Each reads as a
hole and each is fine.

Following delegation — a procedure is inside the enforcement if it records the resource *or reaches
something that does* — takes invariant A from 40 residual to 8, and those 8 are questions worth reading
rather than a list to skim. The same closure is what makes the gate usable rather than a source of
`# noqa`-style exemptions.

The other trap was type declarations. `Asset_Call :: proc(asset: ^Asset, args: []Value) -> (result:
Value, ok: bool)` declares a callback type; it returns a `Value` and records nothing, correctly, because
it has no body. Scanning forward for the `{` that starts a body is not enough on its own — with nothing
to stop it the scan runs into the *next* procedure's brace and every type declaration reads as a
definition. A blank line or the next column-0 declaration has to end the search first.

Both are the same class of mistake as the one `check-ownership.py`'s docstring records against itself,
and as the one this review's own first script made against `graphics_api\(\)`. Which is the argument for
the rule stated at the end of angle 10: **test the gate against something known-good, not only against
something known-bad.**

## Results

### A — the `Value` ledger: 58 producers, 52 reach `tracked()`, 6 exempt

The six, each read and each correct:

- `value_from_bool`, `value_from_int`, `value_from_i64`, `value_from_f64` — inline payloads. The Value
  owns nothing, clearing it is a no-op, and counting them would bury a real leak under hundreds of
  harmless ones. This is the reason `value_owns_reference` exists.
- `value_from_asset` — already documented as deliberate at `tracking.odin:291`: a bare
  `ValueInt64DataSet`, the engine does not `add_ref`, the asset has to outlive the Value.
- `scope_add` — hands back a Value its producer already recorded.

### B — the handle ledger: 23 producers, 19 reach `track_acquire()`, 4 exempt

The four are `value_to_graphics`, `value_to_image`, `value_to_path` and `value_to_text`, and these were
the one real gap in the sweep — not in the code, in what the code says. See below.

### C — callback context: 19 `proc "system"` definitions, 15 restore a context, 4 exempt

`asset_add_ref`, `asset_release`, `asset_get_interface` and `asset_get_passport`. Exactly the set angle 9
cleared by hand — the first three allocate nothing, the fourth only dereferences. The invariant is
unchanged nine days on, which is a good result and not an argument that the check is unnecessary: the
same was true of rule 1 the day before it broke.

## The one real finding

### R11-01 — the four `value_to_*` unwrappers state no ownership, in the one family where the signature cannot  [severity: minor]

**Where:** `sciter_app/graphics.odin`, `value_to_graphics` / `value_to_image` / `value_to_path` /
`value_to_text`.

**What:** each returns an engine handle and, before this pass, carried no doc comment at all — no
statement of whether the caller owes a release. Everywhere else in the package that question is answered
either by the type (`Owned_Element`, `Owned_Request`) or by prose. Here it can only be prose:
`Image`, `Path`, `Text` and `Graphics` are the same types the *owning* `value_from_*` family returns, so
the two directions are indistinguishable at a call site. The header is silent too —
`sciter-x-graphics.h:397` is a bare prototype, and the `const VALUE*` is suggestive rather than
decisive. Nothing in the repository measured it.

**Measured**, by creating a 4x4 image, wrapping it, unwrapping it, and dropping the two references one
at a time:

| step | result |
|---|---|
| `value_to_image` of a wrapped image | the **same** handle, not a copy |
| after `release_image` of the caller's own reference | still alive, still 4x4 |
| after `value_clear` of the Value | gone |

So `value_from_image` takes a reference of its own — which is what the ledger's `tracked()` records —
and the unwrap takes nothing. **Borrowed**, and the handle dies with the Value. Both facts are now on
the wrappers, and the same answer is a listed exemption in the gate, so the two cannot drift apart
silently.

**A second thing fell out of it, and it is the sharper half:** `image_size` on that image *after* the
last reference went answered `0x0` with a `nil` error. Not a failure — a plausible measurement of a dead
handle. The only case that reports `.BAD_PARAM` is a nil pointer, and that check is this wrapper's, not
the engine's. Same shape as the return codes already documented on `eval` and `unuse_element`: the
result answers "did the call complete", never "is this handle still live". Recorded on `image_size`.

## The gates themselves

The other half of a sweep about enforcement is whether the enforcers work. Every static gate was given a
planted violation and had to fail:

| gate | planted | result |
|---|---|---|
| `check-ownership` | a proc returning `string` with no allocator | fails, names it |
| `check-ownership` | a proc returning `[]Element` with no allocator | fails — the `\b` bug its own docstring records is genuinely fixed |
| `check-affinity` | a bare `sciter.api()` in `atom.odin` | fails, names file and line |
| `check-invariants` A | a `Value` producer with no `tracked()` | fails |
| `check-invariants` B | a handle producer with no `track_acquire()` | fails |
| `check-invariants` C | a `proc "system"` with no `context =` | fails |
| `check-invariants` | a stale name in an exemption list | fails, says to drop it |
| `check-invariants` | a *type declaration* returning a `Value` | correctly **not** reported |
| `stats --check` | `12 engine defects` → `13` in README.md | fails, quotes the pattern it wanted |
| `parity --check` | a fabricated slot in the baseline | fails, diffs it |

Not tested: `leak-check` and `api-map-verify`, both of which are runtime gates that need the engine and
are exercised on every run rather than being pattern matches that can quietly stop matching.

One accident worth recording, because it is evidence rather than noise: `stats --check` failed during
this pass for a reason nobody planted — a scratch probe left in `examples/` had made it 31 examples
instead of 30, and the gate caught the count before anything else did.

## What landed

- `.github/scripts/check-invariants.py`, `just check-invariants`, and a CI step beside
  `check-affinity`. Three checks, delegation followed, each exemption carrying its reason the way
  `check-ownership.py`'s `BORROWED` does, and a stale entry reported rather than ignored.
- Ownership and lifetime written onto `value_to_graphics` and its three siblings, with the measurement.
- The dead-handle behaviour written onto `image_size`.

## What this did not look at

Rule 2 (`Value` ownership — who clears what) and rule 3 (handle lifetime) in the general case. Both are
partly enforced by type (`Owned_Element`, `Owned_Request`, `Value_Scope`) and partly not enforceable at
all: `check-ownership.py`'s docstring already makes the case that the allocator rule is "the only
ownership question in the package with a mechanical answer — `Value` needs prose". That judgement was
re-read and stands. What changed here is narrower: the *ledger* that observes those rules at runtime is
now known to be complete, so a clean `just leak-check` means what it says.
