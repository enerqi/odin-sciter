#!/usr/bin/env python3
"""Download the pinned odinfmt into a version-encoded directory, verified against its SHA-256.

    fetch-odinfmt.py <ols-tag> <platform> <sha256> [--check] [--force]

`just fetch-odinfmt` passes the first three from the `ols_*` variables in the justfile, which are the
single place the pin lives - the same arrangement `fetch-engine.py` has with `engine_*`. CI reads that
same variable rather than carrying its own copy, which is the whole point: see below.

**Why this exists.** odinfmt is not a formatter you can treat as interchangeable across versions. It
ships inside an ols release, has no `--version` flag to interrogate, and different releases disagree
about the same source. Measured, on this repository: ols master at 51578d51 (2026-08-06) leaves a
164-character composite literal on one line, while the pinned `dev-2026-06` wraps it - correctly, since
`odinfmt.json` sets `character_width: 120`. A developer whose ols is newer than the pin therefore runs
`just format`, gets a clean local tree, and fails CI on four files. That happened, which is why the pin
moved out of `.github/actions/toolchain/action.yml` (where only CI could see it) and into the justfile
(where both can).

**The version is in the path, not just in a check.** `~/.odin-tools/ols/<tag>/odinfmt` means the
existence test *is* the version test: there is no state where the right path holds the wrong binary,
which is the failure a single unversioned `~/.odin-tools/odinfmt` would reintroduce the first time the
pin moved. Several tags coexist, so switching branches switches formatter with no re-download.

The root is `$ODIN_TOOLS`, else `~/.odin-tools`. Outside the repository on purpose: it is shared by
every checkout and every worktree, it survives `just clean`, and it needs no gitignore line. The
archive is ~1 MB, so the cost of a cache miss is not worth engineering around - CI does not cache it.

**Atomicity matters more here than for the engine.** `ensure-odinfmt` treats "the file is there" as
"the pin is satisfied", because re-hashing a binary before every `just format` is a tax on every
build. That makes a half-extracted file permanently convincing. So the zip is hashed *before* anything
is extracted, the binary is written beside its destination and moved into place with `os.replace`,
and an interrupted run therefore leaves either nothing or the finished article.
"""

import hashlib
import os
import stat
import sys
import tempfile
import urllib.request
import zipfile

BASE = "https://github.com/DanielGavin/ols/releases/download"


def tools_root():
    """Where versioned tool installs live. See the module docstring for why it is outside the repo."""
    return os.environ.get("ODIN_TOOLS") or os.path.join(os.path.expanduser("~"), ".odin-tools")


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def extract_odinfmt(archive, dest):
    """Write the archive's odinfmt member to `dest`, atomically.

    The release ships platform-suffixed names (`odinfmt-x86_64-pc-windows-msvc.exe`) alongside `ols`
    itself and a `builtin/` directory, so the member is found by prefix rather than by exact name -
    the suffix is the platform string we already know, but matching on the prefix means a release that
    renames or drops the suffix still works.
    """
    with zipfile.ZipFile(archive) as z:
        names = [n for n in z.namelist() if os.path.basename(n).startswith("odinfmt")]
        if not names:
            sys.exit(f"  {archive} contains no odinfmt member - got {z.namelist()}")
        if len(names) > 1:
            sys.exit(f"  {archive} contains more than one odinfmt member: {names}")
        payload = z.read(names[0])

    os.makedirs(os.path.dirname(dest), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dest), suffix=".part")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(payload)
        # The zip carries no usable mode bits on every platform, so set the bit rather than trusting
        # them. Harmless on Windows, and without it the unix binary is not runnable.
        os.chmod(tmp, os.stat(tmp).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        os.replace(tmp, dest)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)

    tag, plat, want = argv[0], argv[1], argv[2]
    flags = argv[3:]
    check_only, force = "--check" in flags, "--force" in flags

    exe = ".exe" if "windows" in plat else ""
    dest = os.path.join(tools_root(), "ols", tag, "odinfmt" + exe)

    if os.path.exists(dest) and not force:
        print(f"{dest}: present")
        return

    if check_only:
        sys.exit(f"{dest}: missing - run `just fetch-odinfmt`")

    name = f"ols-{plat}.zip"
    url = os.environ.get("OLS_URL") or f"{BASE}/{tag}/{name}"

    fd, tmp = tempfile.mkstemp(suffix=".zip")
    os.close(fd)
    try:
        print(f"fetching {url}")
        try:
            urllib.request.urlretrieve(url, tmp)
        except OSError as e:  # URLError and HTTPError are both OSError subclasses
            sys.exit(f"  {e}\n  set OLS_URL to fetch {name} from somewhere else")

        got = digest(tmp)
        if not want or want.startswith("TODO"):
            # A platform whose hash is not recorded yet installs anyway and says what to write down,
            # so a bring-up is not blocked by the check that exists to protect it.
            print(f"  no recorded SHA-256 for {plat}. {os.path.getsize(tmp)} bytes,")
            print(f"  sha256 {got} - record it as ols_sha256 in the justfile before trusting it.")
        elif got != want:
            sys.exit(
                f"  sha256 {got}\n"
                f"  expected {want}\n"
                f"  refusing to install: this is not the pinned odinfmt. If ols re-cut {tag}, the pin\n"
                "  in the justfile has to be updated deliberately - a formatter that changes under you\n"
                "  is the exact failure this pin exists to prevent."
            )

        extract_odinfmt(tmp, dest)
        print(f"  installed {dest}")
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


if __name__ == "__main__":
    main(sys.argv[1:])
