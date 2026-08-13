#!/usr/bin/env python3
"""Checks the ownership rule in docs/rules.md section 4:

    If it takes an allocator, the result is yours to free. If it does not, it is borrowed.

Every exported procedure in `package sciter_app` that returns a string or a slice must either take an
`allocator` parameter (so the caller owns the result) or be listed in BORROWED below with the lifetime
its doc comment names. A new procedure that returns allocated memory without taking an allocator, or a
borrowing one that nobody has written down, fails the build.

This exists because the rule is the only ownership question in the package with a mechanical answer -
`Value` needs prose - and a rule nothing checks drifts. Run with `just check-ownership`.
"""

import glob
import re
import sys

# Procedures that return engine-owned memory. The value is the lifetime, and it must match what the
# doc comment says; adding a name here is a deliberate act, which is the point.
BORROWED = {
    "tag": "the element's lifetime",
    "request_method": "the request's lifetime",
    "value_to_bytes": "until the Value changes or is cleared",
    "archive_item": "until close_archive",
}

# Types whose return means "memory came back". `[]u16` is the wrapper's own UTF-16 scratch, which takes
# an allocator like everything else.
#
# Not `\b(...)\b`: a word boundary cannot match between a space and the `[` of a slice type, so every
# slice alternative in that spelling is dead and only `string` is ever tested. Lookarounds instead -
# and they still have to keep `string` from matching inside `cstring`.
RETURNS_MEMORY = re.compile(
    r"(?<![\w])(?:string|\[\]u8|\[\]u16|\[\]string|\[\]Element|\[\]Name_Value|\[\]Attribute)(?![\w])"
)


def split_signature(src, start):
    """From the '(' of a proc's parameter list, return (params, results, ok) using paren matching, so
    that multi-line signatures - most of them in this package - are read correctly rather than by a
    regex that stops at the first newline."""
    depth, i = 0, start
    while i < len(src):
        if src[i] == "(":
            depth += 1
        elif src[i] == ")":
            depth -= 1
            if depth == 0:
                break
        i += 1
    else:
        return "", "", False
    params = src[start + 1 : i]

    rest = src[i + 1 :]
    m = re.match(r"\s*->\s*", rest)
    if not m:
        return params, "", True  # returns nothing
    rest = rest[m.end() :]
    if rest.startswith("("):
        depth, j = 0, 0
        while j < len(rest):
            if rest[j] == "(":
                depth += 1
            elif rest[j] == ")":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        return params, rest[1:j], True
    return params, rest.split("{")[0], True


def main():
    problems = []
    checked = 0
    seen_borrowed = set()

    for path in sorted(glob.glob("sciter_app/*.odin")):
        src = open(path).read()
        for m in re.finditer(r"^([a-z_0-9]+) :: proc\b", src, re.M):
            name = m.group(1)
            # The rule is about the package's API surface. A file-private helper may hand back temp
            # memory to its own file - `behavior_name` in host.odin does - and no caller outside can
            # misread it.
            preceding = src[: m.start()].rsplit("\n\n", 1)[-1]
            if "@(private" in preceding:
                continue
            paren = src.find("(", m.end() - 1)
            if paren < 0:
                continue
            params, results, ok = split_signature(src, paren)
            if not ok or not RETURNS_MEMORY.search(results):
                continue
            checked += 1
            takes_allocator = "allocator" in params
            listed = name in BORROWED
            line = src[: m.start()].count("\n") + 1

            if takes_allocator and listed:
                problems.append(
                    f"{path}:{line}: {name} takes an allocator but is listed as borrowed - "
                    f"one of the two is wrong"
                )
            elif not takes_allocator and not listed:
                problems.append(
                    f"{path}:{line}: {name} returns memory but takes no allocator. Either give it one "
                    f"(the caller owns the result) or add it to BORROWED in this script with the "
                    f"lifetime its doc comment names."
                )
            if listed:
                seen_borrowed.add(name)

    for gone in sorted(set(BORROWED) - seen_borrowed):
        problems.append(f"BORROWED lists '{gone}', which no longer returns memory - drop it")

    if problems:
        print("ownership rule violated (docs/rules.md section 4):\n", file=sys.stderr)
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        return 1

    print(
        f"ok: {checked} procedures return memory; "
        f"{checked - len(seen_borrowed)} take an allocator, {len(seen_borrowed)} are documented borrows"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
