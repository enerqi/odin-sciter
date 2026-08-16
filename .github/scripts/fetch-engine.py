#!/usr/bin/env python3
"""Download the pinned Sciter engine into lib/, verified against its SHA-256.

    fetch-engine.py <tag> <sha256> <relative-path> [--check] [--force]

`just fetch-engine` passes the first three from the `engine_*` variables in the justfile, which are the
single place the pin lives. The relative path is the same under both roots - `bin/<rel>` upstream,
`lib/<rel>` here.

**Plain `python3` rather than the justfile's `uv run` interpreter, deliberately.** This runs in CI and on
a contributor's first build, where the fewest dependencies wins: a `[script]` recipe fails on a runner
with no uv installed with `No such file or directory (os error 2)`, which is what happened the first
time this was wired up. `.github/scripts/check-ownership.py` is invoked the same way for the same
reason; the uv interpreter is for the developer-machine recipes that can assume it.

**Why the hash and not the size.** The upstream tag `6.0.4.9` serves a `libsciter.so` of exactly the
same 25 015 296 bytes as `6.0.4.9-bis`, with a different SHA-256 - measured, by fetching both. A check
on the length would install the wrong engine and report success.

**Three sources, because no engine is committed any more.** While the binaries were in git, upstream
withdrawing a tag was survivable: the bytes were in history. They are not, so a single source is a
single point of failure for every past commit as well as this one. Tried in this order:

    SCITER_ENGINE_URL       a complete URL for this one file - a corporate mirror, a file:// path on a
                            machine with no route to gitlab.com
    SCITER_ENGINE_BASE      replaces BASE below; the `/<tag>/bin/<rel>` shape is kept
    MIRROR                  our own release assets, which need no environment variable at all

All are verified against the same SHA-256, so a mirror can be untrusted without being unsafe: the
worst a bad one can do is fail the check.

**The third source is the one that survives upstream moving a tag**, and it is deliberately last:
GitLab is upstream and stays the primary. It also has to work without being configured - an
environment variable nobody knows to set is not a fallback - so `docs/UPGRADING.md` makes uploading
the three binaries a step of cutting a release, and the URL is derived from the pinned tag here
rather than written down anywhere a reader has to find. Until those assets exist for a given pin it
404s and costs one line of output.
"""

import hashlib
import os
import sys
import tempfile
import urllib.request

BASE = "https://gitlab.com/sciter-engine/sciter-js-sdk/-/raw"

# Our own release assets. The tag is `engine-<upstream tag>` and not a bindings version, so this URL
# moves when the *pin* moves and not when a release is cut against the same engine; the assets are flat
# because the three basenames (.so, .dll, .dylib) are already distinct, so one namespace holds every
# platform. Both halves have to stay in step with what `gh release create` is given in UPGRADING.md.
MIRROR = "https://github.com/enerqi/odin-sciter/releases/download/engine-{tag}/{name}"


def sources(tag, rel):
    """Where to look, most specific first. See the module docstring for why there is more than one."""
    urls = []
    if os.environ.get("SCITER_ENGINE_URL"):
        urls.append(os.environ["SCITER_ENGINE_URL"])
    base = os.environ.get("SCITER_ENGINE_BASE", BASE).rstrip("/")
    urls.append(f"{base}/{tag}/bin/{rel}")
    # `rsplit` rather than os.path.basename: `rel` is always slash-separated, on every platform.
    urls.append(MIRROR.format(tag=tag, name=rel.rsplit("/", 1)[-1]))
    return urls


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)

    tag, want, rel = argv[0], argv[1], argv[2]
    flags = argv[3:]
    check_only, force = "--check" in flags, "--force" in flags

    dest = os.path.join("lib", *rel.split("/"))
    urls = sources(tag, rel)

    # A platform whose hash is not recorded yet installs anyway and says loudly what to write down.
    # Refusing outright would block a bring-up, which is the first thing that uses this script.
    unverified = not want or want.startswith("TODO")

    if os.path.exists(dest) and not force:
        got = digest(dest)
        if unverified:
            print(f"{dest}: present, sha256 {got}")
            print("  no recorded hash for this platform - add it to external/sciter/VENDORED.md")
        elif got == want:
            print(f"{dest}: present and verified")
        else:
            sys.exit(
                f"{dest}: sha256 {got}\n"
                f"  expected {want}\n"
                "  this is not the pinned engine - `just fetch-engine --force` replaces it"
            )
        return

    if check_only:
        sys.exit(f"{dest}: missing - run `just fetch-engine`")

    os.makedirs(os.path.dirname(dest), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dest), suffix=".part")
    os.close(fd)
    try:
        # Each source is tried in turn and only a *transport* failure moves on to the next: a file that
        # arrives and hashes wrong is a bad pin, not a bad mirror, and falling through on it would turn
        # "the tag moved" into "some other source happened to have something".
        for i, url in enumerate(urls):
            print(f"fetching {url}")
            try:
                urllib.request.urlretrieve(url, tmp)
                break
            except OSError as e:  # URLError and HTTPError are both OSError subclasses
                if i == len(urls) - 1:
                    sys.exit(f"  {e}\n  no source served {rel} - see SCITER_ENGINE_URL in this script")
                print(f"  {e} - trying the next source")

        got = digest(tmp)
        if unverified:
            print(f"  no recorded SHA-256 for this platform. {os.path.getsize(tmp)} bytes,")
            print(f"  sha256 {got} - record it in external/sciter/VENDORED.md before trusting it.")
        elif got != want:
            sys.exit(
                f"  sha256 {got}\n"
                f"  expected {want}\n"
                "  refusing to install: this tag serves same-sized binaries that are not the same file"
            )
        os.replace(tmp, dest)
        # No chmod +x. `dlopen` does not need it, the committed copy is 0644, and setting the bit makes
        # `git status` report a modification on a file whose bytes are identical - which is exactly the
        # "the engine changed?!" scare this script exists to prevent.
        os.chmod(dest, 0o644)
        print(f"  installed {dest}")
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


if __name__ == "__main__":
    main(sys.argv[1:])
