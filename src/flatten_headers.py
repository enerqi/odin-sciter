#!/usr/bin/env python3
"""Flatten the Sciter C ABI headers into one self-contained header for odin-c-bindgen.

Why this exists
---------------
odin-c-bindgen only emits declarations that are *physically located in the input file*. Anything
reached through an `#include` is skipped (it becomes an inline anonymous type at the point of use, if
it is referenced at all). That leaves two bad options when the API is spread over ten headers:

  * feed only `sciter-x-api.h` - you get `ISciterAPI` but none of the enums, DOM types or `VALUE`
    machinery it refers to;
  * feed all ten headers - each becomes its own .odin file, but every file re-emits an inline copy of
    the types it borrows from its neighbours, and since they all share `package sciter` those copies
    collide.

Sciter's headers are also not individually self-contained: `sciter-x-dom.h` uses `UINT`, `INT` and
`LPCWSTR` without ever including `sciter-x-primitives.h`, because in normal use it is only ever
reached through `sciter-x.h` or `sciter-x-api.h`. Parsing it on its own produces a wall of
"unknown type name" errors.

So: concatenate the headers in dependency order into a single file, dropping the internal
`#include "..."` lines (the text is being inlined by hand instead) and keeping the system
`#include <...>` lines. bindgen then sees one translation unit where every declaration is in-file, and
emits one .odin file with no duplicates.

The vendored headers under external/sciter/include are never modified.

Usage: python3 src/flatten_headers.py [output_path]
"""

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INCLUDE_DIR = os.path.join(REPO, "external", "sciter", "include")

# Dependency order. `sciter-x-dom.h` and `sciter-x-behavior.h` include each other; the include guards
# make that work in C, but a flattened file has to pick an order - dom first, because behavior's
# structs embed HELEMENT while dom only needs behavior for trailing inline helpers.
HEADERS = [
    "sciter-version.h",       # SCITER_VERSION_0..3
    "sciter-x-primitives.h",  # SBOOL, WCHAR, UINT_PTR, INT_PTR, RECT, POINT, SIZE, calling conventions
    "sciter-x-types.h",       # HWINDOW, GFX_LAYER, SCITER_DLL_NAME
    "value.h",                # VALUE, VALUE_TYPE, VALUE_UNIT_*
    "sciter-x-value.h",       # typedef VALUE SCITER_VALUE (the C branch of it)
    "sciter-om.h",            # som_asset_t and friends
    "sciter-x-dom.h",         # HELEMENT, HNODE, SCDOM_RESULT, element/node API
    "sciter-x-graphics.h",    # SciterGraphicsAPI - uses HELEMENT, so must follow dom
    "sciter-x-behavior.h",    # EVENT_GROUPS, ElementEventProc, all the *_PARAMS structs
    "sciter-x-request.h",     # HREQUEST, SciterRequestAPI
    "sciter-x-def.h",         # host callbacks, SCITER_RT_OPTIONS, window/app commands
    "sciter-x-msg.h",         # SCITER_X_MSG (windowless message pump)
    "sciter-x-api.h",         # ISciterAPI itself - must come last
]

# Patches applied to one header's text before it is concatenated. Use these when the same literal text
# appears in more than one header and only one copy should change - a global replace would hit both.
PER_HEADER_PATCHES = {
    # `HELEMENT` is forward-declared identically in sciter-x-dom.h and sciter-x-request.h. C11 permits
    # the repeated typedef; Odin does not permit the two declarations bindgen emits from it. dom.h is
    # the natural home (it owns the whole element API), so request.h's copy goes.
    "sciter-x-request.h": [
        (
            "typedef struct _HELEMENT* HELEMENT;",
            "/* forward-declared in sciter-x-dom.h; removed by src/flatten_headers.py */",
        ),
    ],
}

# Textual patches applied to the flattened output. Each one works around a place where Sciter's headers
# are not valid C - they compile only because in practice everyone includes them from C++. Keep this
# list short and each entry justified; anything bigger belongs in bindgen.sjson.
PATCHES = [
    # sciter-x-behavior.h, struct SOM_PARAMS. `som_passport_t` is only ever forward-declared as
    # `struct som_passport_t;` (sciter-om.h) and never typedef'd, so in C the bare name is not a type.
    # C++ injects the tag name into the ordinary namespace, which is why this compiles there.
    ("som_passport_t* passport;", "struct som_passport_t* passport;"),
    # `ElementEventProc` is typedef'd identically in BOTH sciter-x-dom.h and sciter-x-behavior.h. C11
    # allows a repeated identical typedef, but bindgen emits an Odin declaration for each and Odin does
    # not. Drop the sciter-x-behavior.h copy (it has the distinctive double space after `typedef`) and
    # keep the sciter-x-dom.h one, because dom's `LPELEMENT_EVENT_PROC` alias is what ISciterAPI's
    # SciterAttachEventHandler / SciterWindowAttachEventHandler slots are declared with.
    (
        "typedef  SBOOL SC_CALLBACK ElementEventProc(LPVOID tag, HELEMENT he, UINT evtg, LPVOID prms );",
        "/* duplicate of the sciter-x-dom.h typedef; removed by src/flatten_headers.py */",
    ),
    # Same story one level up: dom.h has `LPELEMENT_EVENT_PROC` and behavior.h has `LPElementEventProc`
    # for the identical pointer type. Distinct in C, but `force_ada_case_types` folds both to
    # `Lpelement_Event_Proc`. Drop behavior.h's typedef and point its one user (SciterBehaviorFactory)
    # at dom's spelling - which is also the spelling ISciterAPI uses.
    (
        "typedef  ElementEventProc * LPElementEventProc;",
        "/* duplicate of LPELEMENT_EVENT_PROC; removed by src/flatten_headers.py */",
    ),
    ("LPElementEventProc", "LPELEMENT_EVENT_PROC"),
    # sciter-x-primitives.h, 6.0.4.x. The Linux (and macOS) branches typedef INT_PTR twice: once
    # correctly as `intptr_t`, then a few lines later as `ssize_t` - which is not declared, because
    # nothing includes <sys/types.h>. clang rejects the second one. Dropping it leaves the correct
    # `typedef intptr_t INT_PTR` in place. Same size either way, so nothing about the ABI changes.
    ("typedef ssize_t INT_PTR;", "/* duplicate INT_PTR typedef; removed by src/flatten_headers.py */"),
]

SCAPI_TOKEN = re.compile(r"\bSCAPI\b")
PROTOTYPE_NAME = re.compile(r"\bSCAPI\s+(\w+)")


def code_spans(text):
    """Yield (start, end) of the regions of `text` that are code - i.e. not comment, not string.

    Needed because `SCAPI` also occurs inside prose. sciter-x-dom.h has, in a doc comment:

        * \\return \\b #SCDOM_RESULT SCAPI

    Treating that as the start of a prototype deletes everything up to the next `;`, which lands in the
    middle of the following enum and takes the comment's `**/` terminator with it. Cheap to get right,
    silently destructive to get wrong.
    """
    i, n, start = 0, len(text), 0
    while i < n:
        if text.startswith("/*", i):
            yield start, i
            end = text.find("*/", i + 2)
            i = n if end == -1 else end + 2
            start = i
        elif text.startswith("//", i):
            yield start, i
            end = text.find("\n", i)
            i = n if end == -1 else end
            start = i
        elif text[i] in "\"'":
            quote = text[i]
            i += 1
            while i < n and text[i] != quote:
                i += 2 if text[i] == "\\" else 1
            i += 1
        else:
            i += 1
    yield start, n


def strip_scapi_prototypes(text):
    """Delete the flat C prototypes (`UINT SCAPI ValueInit( VALUE* );` and friends).

    These are the single biggest trap in binding Sciter. The headers declare ~180 plain C functions -
    ValueInit, SciterCreateWindow, SciterGetRootElement, ... - and bindgen faithfully turns each into an
    Odin `foreign` procedure. But **none of them are exported by the shared library**. Checked directly:

        $ nm -D --defined-only libsciter.so | grep -w SciterCreateWindow   # no output
        $ nm -D --defined-only libsciter.so | grep -w SciterAPI
        00000000007e4a19 T SciterAPI

    In a C program those prototypes resolve to the `inline` wrappers further down sciter-x-api.h, which
    forward to `SAPI()->SciterCreateWindow(...)` - the vtable. There is nothing to link against. Odin
    `foreign` declarations for them would either fail to link or, worse, link against nothing useful.

    So they are removed here rather than generated and then explained away. Every one of them is
    reachable as a field of ISciterAPI, which is what the bindings actually expose.

    Returns (text, [removed names]) so the caller can report the count and notice drift.
    """
    in_code = [False] * (len(text) + 1)
    for span_start, span_end in code_spans(text):
        for i in range(span_start, span_end):
            in_code[i] = True

    removed = []
    out = []
    pos = 0
    for m in SCAPI_TOKEN.finditer(text):
        if m.start() < pos or not in_code[m.start()]:
            continue
        line_start = text.rfind("\n", 0, m.start()) + 1
        line_end = text.find("\n", m.start())
        line = text[line_start : line_end if line_end != -1 else len(text)]
        stripped_line = line.lstrip()
        # Keep: `#define SCAPI __stdcall`; the C++ `inline ... SCAPI ...` vtable wrappers; and the
        # callback typedefs that also carry the calling convention (`typedef SBOOL SCAPI
        # image_write_function(...)` in sciter-x-graphics.h) - those are types, not prototypes, and
        # ISciterAPI refers to them.
        if (
            stripped_line.startswith("#")
            or stripped_line.startswith("typedef")
            or "inline" in line
        ):
            continue
        end = m.end()
        while True:
            end = text.find(";", end)
            if end == -1 or in_code[end]:
                break
            end += 1
        if end == -1:
            continue

        # Also drop the doc comment sitting directly above the prototype. Left in place it would be
        # re-attached by clang to whatever declaration comes next, putting "Get bounding rectangle of
        # the element" on top of an unrelated enum in the generated bindings.
        cut = line_start
        before = text[:cut].rstrip()
        if before.endswith("*/"):
            comment_start = before.rfind("/*")
            if comment_start != -1:
                cut = comment_start

        name_match = PROTOTYPE_NAME.search(text, m.start(), end)
        removed.append(name_match.group(1) if name_match else "?")
        out.append(text[pos:cut])
        pos = end + 1
    out.append(text[pos:])
    return "".join(out), removed

# Matches `#include "foo.h"` but not `#include <foo.h>`.
INTERNAL_INCLUDE = re.compile(r'^\s*#\s*include\s*"')

BANNER = """// GENERATED FILE - DO NOT EDIT.
//
// Produced by src/flatten_headers.py from the vendored headers in external/sciter/include.
// This is a concatenation of the Sciter C ABI headers in dependency order, with the internal
// `#include "..."` lines removed. It exists only as input for odin-c-bindgen; see the docstring in
// src/flatten_headers.py for why. Regenerate with `just bindgen`.
"""


def flatten() -> str:
    out = [BANNER]
    for name in HEADERS:
        path = os.path.join(INCLUDE_DIR, name)
        with open(path, encoding="utf-8", errors="replace") as f:
            body = "".join(
                line for line in f if not INTERNAL_INCLUDE.match(line)
            )
        for old, new in PER_HEADER_PATCHES.get(name, ()):
            if old not in body:
                raise SystemExit(
                    "patch target no longer present in %s, review PER_HEADER_PATCHES: %r" % (name, old)
                )
            body = body.replace(old, new)
        out.append("\n\n// ==== %s %s\n\n" % (name, "=" * (68 - len(name))))
        out.append(body)

    text = "".join(out)
    for old, new in PATCHES:
        if old not in text:
            raise SystemExit("patch target no longer present, review PATCHES: %r" % old)
        text = text.replace(old, new)
    return strip_scapi_prototypes(text)


def main() -> int:
    out_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "build", "sciter.h")
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    text, removed = flatten()
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print(
        "%s (%d headers, %d lines, %d unexported SCAPI prototypes stripped)"
        % (out_path, len(HEADERS), text.count("\n") + 1, len(removed))
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
