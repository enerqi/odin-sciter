#!/usr/bin/env python3
"""Checks the thread-affinity rule in docs/rules.md section 1:

    Every call into this library must happen on the thread that called `init`.

The runtime half of that rule is `guard_engine_thread` in `sciter_app/affinity.odin`, and it can only
check calls that pass through it. `engine()` in `sciter_app.odin` is what makes that "all of them": it
is the only way the package reaches the engine's function table, and it guards on the way in. This
script is what keeps that true - a new procedure written with a bare `sciter.api()` would compile, work,
and be invisible to the guard.

It exists because that is exactly what happened. The guard originally sat in the four error-wrapping
helpers and the two sub-table accessors, so it saw a call only if that call returned a result code: 124
of 199 engine call sites, with `eval`, `call`, every `Value` constructor and the whole windowless
surface among the 75 it missed. Nothing failed, because nothing was checking. See
`docs/review/10-threading.md`.

Run with `just check-affinity`.
"""

import glob
import re
import sys

# The one place a bare `sciter.api()` is correct. `post_callback` is rule 1's documented exception - it
# is meant to be called from a worker thread, so the guard would trap the use it exists for.
EXEMPT = {
    "post_callback": "rule 1's one exception - safe from any thread, see docs/threading.md",
}

# Where `engine()` itself lives. It is the wrapper around `sciter.api()`, so it is not a violation of
# the rule it implements.
DEFINITION = ("sciter_app/sciter_app.odin", "engine")

# A call *through* the table, not the word in a doc comment: `sciter.api().SciterFoo(...)`, or the bare
# form bound to a local first, as `version` in app.odin does.
CALL = re.compile(r"sciter\.api\s*\(")
PROC = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*::\s*proc\b")
# Doc comments quote `sciter.api()` in prose in four places; a line that is only a comment is not a call.
COMMENT = re.compile(r"^\s*//")


def enclosing_procs(lines):
    """Line number (1-based) -> the name of the procedure it is inside, for a file of Odin at column 0."""
    starts = [(i, m.group(1)) for i, l in enumerate(lines) if (m := PROC.match(l))]
    owner = {}
    for n, (i, name) in enumerate(starts):
        end = starts[n + 1][0] if n + 1 < len(starts) else len(lines)
        for j in range(i, end):
            owner[j] = name
    return owner


def main():
    problems = []
    guarded = 0
    exempted = {}

    for path in sorted(glob.glob("sciter_app/*.odin")):
        lines = open(path, encoding="utf-8").read().splitlines()
        owner = enclosing_procs(lines)
        for i, line in enumerate(lines):
            if COMMENT.match(line):
                continue
            for kind, pattern in (("engine", re.compile(r"\bengine\s*\(")), ("api", CALL)):
                if not pattern.search(line):
                    continue
                name = owner.get(i, "<file scope>")
                if kind == "engine":
                    if (path.replace("\\", "/"), name) != DEFINITION:
                        guarded += 1
                    continue
                if (path.replace("\\", "/"), name) == DEFINITION:
                    continue
                if name in EXEMPT:
                    exempted[name] = EXEMPT[name]
                    continue
                problems.append(
                    f"{path}:{i + 1}: {name} reaches the engine through `sciter.api()`, which does not "
                    f"check the thread. Use `engine()` instead - it is the same table with "
                    f"`guard_engine_thread` in front of it. If this really is a call that must work "
                    f"from any thread, add it to EXEMPT in this script with the reason."
                )

    for gone in sorted(set(EXEMPT) - set(exempted)):
        problems.append(f"EXEMPT lists '{gone}', which no longer calls `sciter.api()` - drop it")

    if problems:
        print("thread-affinity rule unenforced (docs/rules.md section 1):\n", file=sys.stderr)
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        return 1

    print(
        f"ok: {guarded} engine calls go through `engine()` and are thread-checked; "
        f"{len(exempted)} documented exception{'' if len(exempted) == 1 else 's'}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
