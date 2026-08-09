#!/usr/bin/env python3
"""Fix the calling convention in the bindings odin-c-bindgen just wrote.

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

Usage: python3 src/postprocess_bindings.py sciter.odin
"""

import sys

FROM = 'proc "c" ('
TO = 'proc "system" ('


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "sciter.odin"

    with open(path, encoding="utf-8") as f:
        text = f.read()

    count = text.count(FROM)
    if count == 0:
        print("%s: nothing to rewrite (already `proc \"system\"`?)" % path)
        return 0

    text = text.replace(FROM, TO)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)

    print('%s: %d `proc "c"` -> `proc "system"`' % (path, count))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
