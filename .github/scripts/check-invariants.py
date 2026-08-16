#!/usr/bin/env python3
"""Checks three invariants that hold today and that nothing was keeping true.

    A. a procedure that hands back a Value records it in the ledger
    B. a procedure that hands back an owned engine handle records it too
    C. every `proc "system"` the engine calls back into restores a context

None of the three is a rule a reader can see being broken. A missing `tracked()` makes
`just leak-check` report clean while leaking - and `tracking.odin` says why that direction is the
dangerous one: an under-flow is catchable the instant it happens, a leak is only ever a question you
can ask at the end. A `proc "system"` that allocates without restoring a context is, per the angle-9
sweep, "the failure mode most likely to produce unexplainable corruption".

All three were verified by hand in the 2026-08-13 review and were still clean when this was written.
That is the argument for the script rather than against it: `docs/review/10-threading.md` is about an
invariant that was hand-verified, drifted, and then hid the drift for a day on the one platform nobody
can watch. Run with `just check-invariants`.

Delegation is followed. A procedure counts as inside the enforcement if it records the resource itself
or calls something that does, because otherwise every `scoped_` twin and every wrapper reads as a hole
and buries the real ones - 40 false positives against 8 real questions, measured.
"""

import glob
import re
import sys

# Each entry is a deliberate act, and the value is the reason - the same shape as BORROWED in
# check-ownership.py. An entry that stops being needed is reported, so the lists cannot rot.

VALUE_EXEMPT = {
    "value_from_bool": "an inline payload - the Value owns nothing and clearing it is a no-op",
    "value_from_int": "inline payload",
    "value_from_i64": "inline payload",
    "value_from_f64": "inline payload",
    "value_from_asset": "a bare ValueInt64DataSet - the engine does not add_ref, see `.ASSET` in tracking.odin",
    "scope_add": "hands back a Value that its producer already recorded",
}

HANDLE_EXEMPT = {
    "value_to_graphics": "unwraps the handle the Value already holds - borrowed, the Value still owns it",
    "value_to_image": "borrowed from the Value, as above",
    "value_to_path": "borrowed from the Value, as above",
    "value_to_text": "borrowed from the Value, as above",
}

CONTEXT_EXEMPT = {
    "asset_add_ref": "allocates nothing",
    "asset_release": "allocates nothing",
    "asset_get_interface": "allocates nothing",
    "asset_get_passport": "only dereferences",
}

PROC = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*::\s*proc\b")
SYSTEM = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*\s*::\s*proc\s+"system"')
CALL = re.compile(r"\b([a-z_][a-z_0-9]*)\s*\(")
RETURNS_VALUE = re.compile(r"->\s*\(?[^)]*\bValue\b")
RETURNS_HANDLE = re.compile(
    r"->\s*\(?[^)]*\b(Owned_Element|Owned_Node|Owned_Request|Image|Path|Text|Archive|Graphics)\b"
)


def definitions():
    """name -> (path, line, body, signature), for column-0 procedures **with a body**.

    The body test is what separates a definition from a type declaration - `Asset_Call :: proc(...) ->
    (result: Value, ok: bool)` declares a callback type and records nothing, correctly. Scanning until
    a line ending in `{` is not enough on its own: with nothing to stop it, the scan runs on into the
    *next* procedure's brace and every type declaration reads as a definition. A blank line or the next
    column-0 declaration ends the search first.
    """
    out = {}
    for path in sorted(glob.glob("sciter_app/*.odin")):
        lines = open(path, encoding="utf-8").read().splitlines()
        starts = [(i, m.group(1)) for i, l in enumerate(lines) if (m := PROC.match(l))]
        for n, (i, name) in enumerate(starts):
            end = starts[n + 1][0] if n + 1 < len(starts) else len(lines)
            sig_end = None
            for j in range(i, end):
                if lines[j].rstrip().endswith("{"):
                    sig_end = j
                    break
                if j > i and (not lines[j].strip() or re.match(r"^[A-Za-z_@]", lines[j])):
                    break
            if sig_end is None:
                continue
            out[name] = (path, i + 1, "\n".join(lines[i:end]), "\n".join(lines[i : sig_end + 1]))
    return out


PROCS = definitions()


def reaches(name, recorders, seen=None):
    """Does `name` reach a recorder, directly or through other procedures in the package?"""
    seen = seen if seen is not None else set()
    if name in seen or name not in PROCS:
        return False
    seen.add(name)
    called = set(CALL.findall(PROCS[name][2])) - {name}
    if called & recorders:
        return True
    return any(reaches(c, recorders, seen) for c in called)


def run(label, rule, selects, satisfied, exempt, problems, counts):
    used = set()
    checked = inside = 0
    for name, (path, line, _body, sig) in sorted(PROCS.items(), key=lambda kv: (kv[1][0], kv[1][1])):
        if not selects(name, sig):
            continue
        checked += 1
        if satisfied(name):
            inside += 1
            if name in exempt:
                problems.append(
                    f"{path}:{line}: {name} is listed as exempt from {label} but satisfies it now - "
                    f"drop it from the list in this script"
                )
                used.add(name)
            continue
        if name in exempt:
            used.add(name)
            continue
        problems.append(f"{path}:{line}: {name} {rule}")
    for gone in sorted(set(exempt) - used):
        problems.append(f"'{gone}' is listed as exempt from {label} but no longer matches - drop it")
    counts.append((label, checked, inside, len(used)))


def main():
    problems = []
    counts = []

    run(
        "A (Value ledger)",
        "hands back a Value and never reaches `tracked()`. Either return `tracked(v)` so the "
        "reference is counted, or add it to VALUE_EXEMPT in this script with the reason it owns nothing.",
        lambda n, sig: bool(RETURNS_VALUE.search(sig)) and "^Value" not in sig.split("->", 1)[1],
        lambda n: reaches(n, {"tracked", "track_acquire_counted"}),
        VALUE_EXEMPT,
        problems,
        counts,
    )

    run(
        "B (handle ledger)",
        "hands back an engine handle and never reaches `track_acquire()`. Either record it, or add it "
        "to HANDLE_EXEMPT in this script with the reason the caller does not own it.",
        lambda n, sig: "->" in sig and bool(RETURNS_HANDLE.search(sig)),
        lambda n: reaches(n, {"track_acquire"}),
        HANDLE_EXEMPT,
        problems,
        counts,
    )

    run(
        "C (callback context)",
        'is a `proc "system"` with no `context = ` in it. The engine calls it on a thread with no Odin '
        "context, so anything that allocates - `fmt`, `make`, a temp-allocator string - reads whatever "
        "was there. Restore one, or add it to CONTEXT_EXEMPT with the reason it needs none.",
        lambda n, sig: bool(SYSTEM.match(sig)),
        lambda n: re.search(r"^\s*context = ", PROCS[n][2], re.M) is not None,
        CONTEXT_EXEMPT,
        problems,
        counts,
    )

    if problems:
        print("invariant unenforced:\n", file=sys.stderr)
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        return 1

    for label, checked, inside, exempt in counts:
        print(f"ok: {label} - {checked} procedures, {inside} satisfy it, {exempt} documented exemptions")
    return 0


if __name__ == "__main__":
    sys.exit(main())
