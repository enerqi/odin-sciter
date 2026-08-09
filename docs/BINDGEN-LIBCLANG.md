# Side note — building odin-c-bindgen on Linux (libclang link failure)

Companion to [PLAN.md](PLAN.md) §5. That section names "build `odin-c-bindgen`" as the first prerequisite
and notes the binary was absent. It is now built. This note records the one obstacle hit on the way, because
it will recur on any fresh Linux machine and the error message does not point at the fix.

Verified on this machine on 2026-08-09 against Ubuntu's real LLVM packaging.

---

## Symptom

```
$ cd $HOME/dev/odin-c-bindgen
$ odin build src -out:bindgen.bin
/usr/bin/ld: cannot find -lclang: No such file or directory
clang: error: linker command failed with exit code 1 (use -v to see invocation)
```

Installing `libclang-dev` does **not** fix this. That is the confusing part.

## Cause

`libclang/*.odin` in odin-c-bindgen declares:

```odin
when ODIN_OS == .Windows {
    ...
} else {
    foreign import lib "system:clang"
}
```

`system:clang` becomes `-lclang`, which makes `ld` search the default paths for an unversioned
`libclang.so`. On Debian/Ubuntu that file is not in the default paths.

Normal Debian shared-library policy (Policy ch. 8) would put it there — runtime package ships
`/usr/lib/<triplet>/libfoo.so.1`, dev package ships the `/usr/lib/<triplet>/libfoo.so` symlink next to it,
and `-lfoo` just works. **LLVM deliberately opts out** so that multiple majors are co-installable; this
machine has llvm-18, llvm-19 and llvm-20 side by side. Two packages cannot both own
`/usr/lib/<triplet>/libclang.so`, so the packaging keeps the undecorated symlink inside a versioned prefix
and exposes only version-decorated names in the triplet dir.

Actual file ownership here (`dpkg -L`):

```
libclang1-20    (runtime) : /usr/lib/x86_64-linux-gnu/libclang-20.so.1
                            /usr/lib/x86_64-linux-gnu/libclang-20.so.20
libclang-20-dev (dev)     : /usr/lib/x86_64-linux-gnu/libclang-20.so    <- decorated only
                            /usr/lib/llvm-20/lib/libclang.so            <- undecorated, versioned dir
libclang-dev              : /.  /usr  /usr/share                        <- EMPTY metapackage
```

`libclang-dev` comes from the `llvm-defaults` source. It ships zero files — it is a pure `Depends:` pointer
at the distro-default major. Installing it gives you nothing that `-lclang` can find.

## Fix

Point the linker at the versioned libdir, discovered via `llvm-config` rather than hardcoded:

```sh
odin build src -out:bindgen.bin -extra-linker-flags:"-L$(llvm-config-20 --libdir)"
```

`llvm-config-20 --libdir` → `/usr/lib/llvm-20/lib`. Verified: builds clean, and no rpath is needed because
the runtime SONAME already lives in the default path:

```
$ ldd bindgen.bin | grep clang
libclang-20.so.20 => /lib/x86_64-linux-gnu/libclang-20.so.20
$ ./bindgen.bin
Usage: 'bindgen directory' or 'bindgen directory/bindgen.sjson'
```

Binary now at `$HOME/dev/odin-c-bindgen/bindgen.bin`. PLAN.md §5's prerequisite is cleared.

### Alternatives considered

| Option | Verdict |
| --- | --- |
| `-extra-linker-flags:"-L$(llvm-config-N --libdir)"` | **Use this.** Self-describing, no root, portable across majors. |
| Patch `foreign import lib "system:clang"` → `"system:clang-20"` | Works (`-lclang-20` links from the default path — tested). Hardcodes the major and dirties the vendored tree. |
| `sudo ln -s .../libclang-20.so.1 /usr/lib/x86_64-linux-gnu/libclang.so` | **Avoid.** Recreates exactly the global ambiguity LLVM's packaging exists to prevent, and leaves a dpkg-unowned file that a `libclang1-20` upgrade may stomp. |

### Not an `update-alternatives` job

Tempting, but no — and nothing clang/llvm is registered in alternatives on this machine (`/usr/bin/clang` is
a plain symlink to `/usr/lib/llvm-20/bin/clang`, not an alternatives link). Reasons it does not belong there:

- `libclang-19.so.1` and `libclang-20.so.1` have **different SONAMEs**, which is the ABI system's way of
  saying "not interchangeable." Alternatives assumes its choices are drop-in equivalents.
- A system-wide flip would silently change what `-lclang` means for every build on the box. Different
  projects want different majors.
- You would link against the selected headers but the loader still resolves by SONAME, so flipping after a
  build gives you a binary and headers that disagree, with no error until runtime.

The sanctioned "which LLVM do I build against" query API is `llvm-config`. There is no clang `.pc` file on
this system, so pkg-config is not an option either.

## Consequence for odin-sciter

Whatever recipe drives bindgen (`just bindgen`, per PLAN.md §5) should either assume `bindgen.bin` is
already built, or build it with the `llvm-config` flag above rather than a bare `odin build`. Worth a line
in the README prerequisites too — a contributor on a fresh Ubuntu box will hit `cannot find -lclang` and
will not guess that `apt install libclang-dev` is a no-op.

Note the version skew to watch: `llvm-config-20` is hardcoded to major 20 here. On a machine with a
different default, `llvm-config --libdir` (undecorated) or a `$(command -v llvm-config-21 || ...)` probe is
the more durable form.
