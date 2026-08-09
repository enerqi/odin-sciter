#!/usr/bin/env python3
"""Fix up the two things odin-c-bindgen cannot express, in the bindings it just wrote.

1. THE CALLING CONVENTION

bindgen derives the calling convention from what clang sees, and on Linux Sciter's `SCFN` macro expands
to a plain `(*name)` with no attribute, so every function pointer comes out as `proc "c"`. On Windows
the same macro expands to `(__stdcall *name)`.

    #if defined(WINDOWS)
      #define SCAPI __stdcall
      #define SCFN(name) (__stdcall *name)
    #else
      #define SCAPI
      #define SCFN(name) (*name)
    #endif

`proc "c"` is therefore right on Linux and macOS, right on 64-bit Windows (where there is only one
convention), and wrong on 32-bit Windows. Odin spells exactly that "whatever the platform's system ABI
is" convention `"system"` - the same thing Rust means by `extern "system"`, and what rust-sciter uses.
Since the bindings are generated once on Linux and compiled everywhere, rewrite them to `"system"`.

There is no bindgen setting for this, and generating on Windows instead is not an option: those headers
pull in windows.h, HWND, MSG and IUnknown, which libclang on Linux cannot resolve.

2. `-> Void` RETURNS

sciter-x-primitives.h has `typedef void VOID;`, and bindgen turns a typedef of `void` into the Odin
type `Void :: struct {}` - a zero-sized struct. As a *return* type that is wrong in the way that
matters: `proc "system" (...) -> Void` is not the same Odin type as a proc that returns nothing, so no
ordinary Odin callback can be passed where the engine wants one without declaring a dummy `Void`
return and writing `return {}`.

Stripping the return makes them what the C actually says - `void` - and is what lets a plain Odin proc
be handed to SciterSetupDebugOutput, the `...CB` receivers and the native functor slots.

Only the return position is touched. `^Void` parameters (the native functor's `tag`) are left alone:
they are genuine pointers, and Odin has no problem with a pointer to a zero-sized struct.

Usage: python3 src/postprocess_bindings.py sciter.odin
"""

import re
import sys

CALLCONV_FROM = 'proc "c" ('
CALLCONV_TO = 'proc "system" ('

# `-> Void` at the end of a proc type. The trailing context is either end-of-line, a `,` (a struct
# field), or the start of a comment - never another type, so there is nothing to be greedy about.
VOID_RETURN = re.compile(r" -> Void(?=\s*(?:,|$|//|/\*))", re.MULTILINE)


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "sciter.odin"

    with open(path, encoding="utf-8") as f:
        text = f.read()

    callconv_count = text.count(CALLCONV_FROM)
    text = text.replace(CALLCONV_FROM, CALLCONV_TO)

    text, void_count = VOID_RETURN.subn("", text)

    if callconv_count == 0 and void_count == 0:
        print("%s: nothing to rewrite (already post-processed?)" % path)
        return 0

    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)

    print(
        '%s: %d `proc "c"` -> `proc "system"`, %d `-> Void` returns dropped'
        % (path, callconv_count, void_count)
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
