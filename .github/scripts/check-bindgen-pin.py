#!/usr/bin/env python3
"""Assert the local odin-c-bindgen checkout is at the pinned commit before regenerating.

    check-bindgen-pin.py <bindgen-binary-path> <pinned-commit>

`just bindgen` depends on this. The pin is `bindgen_commit` in the justfile, and `bindgen.yml` reads
that same variable rather than declaring its own - which is the fix this script is half of.

**The bug it closes.** `bindgen.yml` asserts that regenerating `sciter.odin` from the vendored headers
is *byte-identical* to the committed file. That check is the reason `sciter.odin` can be treated as a
build artifact that happens to be tracked, and it is the most valuable gate in the repository. But the
generator it ran was pinned only inside the workflow, while `just bindgen` on a developer machine used
`$ODIN_C_BINDGEN` or a sibling checkout at whatever commit happened to be there. So the local
regeneration and the one CI verifies against could be different programs, and the way you found out
was a CI failure saying `sciter.odin` had been hand-edited when it had not.

This is the same class of drift as the odinfmt one - a version pinned where only CI can see it - and
the same fix: the pin moves to the justfile, both sides read it, and the local side is checked rather
than assumed.

**Why a commit and not a release.** odin-c-bindgen publishes no releases, so there is no tag to pin and
no archive to fetch. That rules out the `fetch-odinfmt` treatment: this can verify what you have, but
it cannot install what you do not, which is why it prints the two commands rather than running them.

**Why this is a warning and not a hard stop when the path is not a git checkout.** `$ODIN_C_BINDGEN`
may point at a binary copied out of a build tree, a package manager's location, or a container path
with no `.git` beside it. Refusing those would break working setups to enforce a check that cannot be
performed on them, so an unidentifiable generator says so and continues; only a checkout that *is*
identifiable and *is* at the wrong commit fails. `BINDGEN_PIN_SKIP=1` opts out entirely.

**The host platform is part of the pin, which is not obvious and cost a corrupted file to find.**
bindgen resolves the headers' `#if` blocks through libclang *for the machine it runs on*, so
regenerating on Windows takes the Win32 branch and emits a `sciter.odin` referring to `Hwnd`, `Wparam`,
`Lparam` and `Lresult` - types the generated file never declares. It does not compile, and the only
thing that catches it is the `odin check` inside `just bindgen`, by which point the committed
`sciter.odin` has already been overwritten with the broken one. `bindgen.yml` runs on ubuntu-24.04, so
Linux is what the committed file was generated on and the only host that reproduces it byte for byte.
"""

import datetime
import os
import subprocess
import sys


def git(repo, *args):
    """`git -C repo <args>` stripped, or None if it is not a checkout we can read."""
    try:
        out = subprocess.run(
            ["git", "-C", repo, *args], capture_output=True, text=True, check=True
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    return out.stdout.strip()


def head_of(repo):
    """The short HEAD of `repo`, or None if it is not a git checkout we can read."""
    return git(repo, "rev-parse", "--short=7", "HEAD")


def built_before_head(binary, repo):
    """True when `binary` is older than the commit it is meant to implement.

    The commit check below proves the *source* is at the pin; it says nothing about the binary beside
    it, and "checked the right commit out, forgot to rebuild" is the likelier mistake of the two. This
    catches it with the one comparison that cannot produce a false positive: a binary whose mtime
    predates the authoring of HEAD cannot have been built from HEAD. The converse does not hold - a
    newer binary may still have come from some other commit - so this is a floor, not a proof, and it
    is why the message says rebuild rather than claiming the binary is wrong.
    """
    when = git(repo, "log", "-1", "--format=%ct")
    if when is None:
        return None
    try:
        return os.path.getmtime(binary) < int(when)
    except (OSError, ValueError):
        return None


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)

    binary, want = argv[0], argv[1]

    if os.environ.get("BINDGEN_PIN_SKIP"):
        print(f"bindgen pin check skipped (BINDGEN_PIN_SKIP), wanted {want}")
        return

    # Before the generator is even looked at: on the wrong host it cannot produce the committed file,
    # and the failure overwrites that file on its way to being noticed. See the docstring.
    if not sys.platform.startswith("linux"):
        sys.exit(
            f"regenerating on {sys.platform} cannot reproduce the committed sciter.odin.\n"
            "  bindgen resolves the headers' #if blocks for the host, so a non-Linux run emits\n"
            "  references to Hwnd/Wparam/Lparam/Lresult that the file never declares - it does not\n"
            "  compile, and `just bindgen` will have overwritten sciter.odin before saying so.\n"
            "  bindgen.yml regenerates on ubuntu-24.04; use Linux, WSL, or let CI do it.\n"
            "  BINDGEN_PIN_SKIP=1 overrides this if you know why you want it."
        )

    if not os.path.exists(binary):
        sys.exit(
            f"{binary}: not found\n"
            "  `just bindgen` needs a built odin-c-bindgen. Point ODIN_C_BINDGEN at one, or:\n"
            "    git clone https://github.com/karl-zylinski/odin-c-bindgen ../odin-c-bindgen\n"
            f"    git -C ../odin-c-bindgen checkout {want}\n"
            "    cd ../odin-c-bindgen && odin build src -out:bindgen.bin\n"
            "  `src`, not `.`: at the pinned commit the sources are under src/, which is what\n"
            "  bindgen.yml builds. Upstream's README describes a later layout."
        )

    repo = os.path.dirname(os.path.abspath(binary))
    got = head_of(repo)

    if got is None:
        print(f"warning: {repo} is not a readable git checkout, so the generator's commit is unknown.")
        print(f"  bindgen.yml regenerates with {want} and asserts the result is byte-identical, so a")
        print("  different generator here means a CI failure that reads as `sciter.odin` was edited.")
        return

    # `want` is written short in the justfile; compare on the length actually pinned so a full 40-char
    # pin keeps working if anyone lengthens it.
    if got.startswith(want) or want.startswith(got):
        if built_before_head(binary, repo):
            built = datetime.datetime.fromtimestamp(os.path.getmtime(binary))
            sys.exit(
                f"{binary}: built {built:%Y-%m-%d %H:%M}, before {got} was even authored\n"
                f"  {repo} is checked out at the pin, but this binary predates it, so it is a build of\n"
                "  some earlier commit and regenerating with it would produce output CI rejects.\n"
                f"    cd {repo} && odin build src -out:{os.path.basename(binary)}"
            )
        print(f"odin-c-bindgen at {got}, matching the pin")
        return

    sys.exit(
        f"{repo}: at {got}, pinned at {want}\n"
        "  bindgen.yml regenerates with the pinned commit and asserts byte-identical output, so\n"
        "  generating here with a different one lands a diff CI will reject as a hand edit.\n"
        f"    git -C {repo} checkout {want}\n"
        f"    cd {repo} && odin build src -out:{os.path.basename(binary)}\n"
        "  If the generator moved on purpose, bump `bindgen_commit` in the justfile instead."
    )


if __name__ == "__main__":
    main(sys.argv[1:])
