# Upgrading the Sciter engine

Version policy, the upgrade procedure, and what to do about the repository growing.

## Policy

**Vendor, by default.** The engine binary and the headers live in this repository, so
`git clone && just example hello_window` works with no network, no SDK, and no `fetch` step. That is
the single biggest thing that makes a bindings library approachable, and it is worth the bytes. The
cost is real and is budgeted for below.

**Pin one version at a time.** The working tree holds exactly one engine build per platform, named in
[`external/sciter/VENDORED.md`](../external/sciter/VENDORED.md) with its SHA-256. Upstream tags roughly
weekly; that is not an upgrade cadence, it is a changelog. Upgrade when there is a reason — a fix you
need, a platform you are adding, or a version that has been stable for a while — not on a schedule.

**Follow upstream's version in our tags.** A release of these bindings is tagged with the engine
version it vendors:

```
v6.0.4.9          # bindings for engine 6.0.4.9
v6.0.4.9-2        # same engine, second bindings release (API changes, fixes, docs)
v6.0.4.9-3        # ... and so on
```

The bare `vX.Y.Z.W` form is the first release against that engine; the `-N` suffix counts
bindings-only releases on top of it, and only appears when needed. Reading a tag therefore answers the
question anyone actually has — *which engine does this speak to* — without a lookup table. Upstream's
own suffixes (`6.0.4.9-bis`) stay recorded in `VENDORED.md`, not in our tag, since they are the SDK
repository's packaging detail and do not change the engine's API version.

The Odin ecosystem has no package manager to satisfy, so the tag is for humans and for
`git checkout`. No `latest` tag, no moving tags.

## Upgrade procedure

Work on a branch. Every step is cheap except the last, which is the point of the list.

**1. Get the SDK.** GitLab, never the GitHub mirror — see
[`VENDORED.md`](../external/sciter/VENDORED.md) for why.

```sh
git clone --depth 1 https://gitlab.com/sciter-engine/sciter-js-sdk.git
# or the release archive, which avoids the ~4 GB history entirely
```

**2. Read the SDK's `CHANGELOG.md`** between the pinned version and the new one. What matters:
anything added to, removed from, or reordered in `ISciterAPI`, and any change to
`SCITER_API_VERSION`.

**3. Replace the headers.** `external/sciter/include/` is a straight copy of the SDK's `include/`,
minus what `VENDORED.md` records as deliberately left out (`*.hpp`, `behaviors/`, `gles/`,
`sciter-main.cpp`).

**4. Replace the binaries.** One per platform, into `lib/<platform>/`. Update `VENDORED.md`: tag,
commit, engine version, `SCITER_API_VERSION`, and the SHA-256 of each binary.

**5. Regenerate.**

```sh
just bindgen
```

If `src/flatten_headers.py` reports a patch that no longer matches, that is a **hard error and it is
doing its job** — upstream changed something the patch was compensating for. Read the patch's comment,
check whether the underlying problem is gone (delete the patch) or moved (update it). Do not skip it.

**6. Verify the table against the shipped engine.** This is the step the whole procedure exists for:

```sh
just example api_map
```

Expected: **189 slots, 16 null (platform-padded), 0 mismatches**, every non-null slot resolving to its
own name plus the engine's `Imp` suffix. A different slot count is a real API change and means reading
the diff of `sciter-x-api.h`. A *mismatch* means the generated struct and the binary disagree about
field offsets, and nothing else in the suite will tell you that — every call would simply land in the
wrong function.

**7. Check and test.**

```sh
just check          # both packages, the guides' snippets, all examples
just test           # the headless tests
just test_sanitize eval    # Value refcounting under ASan
```

**8. Run the windowed examples by hand.** `hello_window`, `dom_walk`, `events`, `archive`,
`custom_loader`, `inspector`. Automated tests cannot see a window that renders blank.

**9. Update the docs that name a version**: `README.md`'s version table, `docs/PLAN.md`'s status line,
`VENDORED.md`. Then tag per the policy above.

### When `SCITER_API_VERSION` changes

`sciter.load()` refuses a table whose `version` field does not match the headers the bindings were
generated from, so an old binding against a new engine fails loudly at `load` rather than crashing
later. That is the intended behaviour and it means **the bindings and the engine ship together**. There
is no supported configuration where a user points `SCITER_LIB` at a different major API version.

### Adding a platform

Same procedure, plus: run `just example api_map` **on that platform** — the NULL slots differ (Windows
fills `SciterProc`, `SciterProcND` and the D2D/DirectX entries; Linux fills `SciterCreateWidget`;
macOS fills `SciterCreateNSView`), so the count of nulls is expected to move even though the *layout*
does not. Record what it printed.

## Repository size

The concern is legitimate: binaries do not delta-compress, so every engine version you commit stays in
history at close to full size, forever.

Measured, not guessed:

| | On disk | In git (compressed) |
| --- | --- | --- |
| `libsciter.so` (Linux x64) | 23.9 MB | ~11 MB |
| `sciter.dll` (Windows x64) | 18.4 MB | ~8 MB |
| `libsciter.dylib` (macOS) | 47.7 MB | ~20 MB |
| all three, per engine version | 90 MB | **~40 MB** |

This repository's `.git` is 11 MB today, with one platform and one engine version.

So the trajectory is roughly **40 MB of permanent history per engine bump** once all three platforms
are vendored. Ten bumps is 400 MB. That is survivable but not comfortable, and it is worth deciding
how to handle it before the second and third binaries land rather than after.

### What we do about it

**1. Upgrade deliberately, not weekly.** The policy above is the primary mitigation and costs nothing.
Two or three engine bumps a year is ~100 MB a year.

**2. Tell consumers to shallow-clone.** A user does not need the history:

```sh
git clone --depth 1 <repo>
```

That fetches one copy of the current binaries and nothing else, so history size is a maintainer
problem, not a user problem. This belongs in the README's quick start once the repository is
published.

**3. Never keep two engine versions in the tree.** Replace the file; do not add
`lib/linux/x64/libsciter-6.0.5.so` beside the old one. The tag says which engine a checkout carries.

**4. Record SHA-256 in `VENDORED.md` for every vendored binary.** Cheap now, and it is the
precondition for switching strategies later without a flag day: a `just fetch-sdk` that downloads and
verifies against those hashes can be added at any point, and the vendored copy simply becomes the
default rather than the only option.

**5. Set a threshold, and act on it rather than drifting.** When `.git` passes **~500 MB**, do a
history reset rather than continuing:

- tag the current history `history-pre-squash-<date>` and keep that tag pushed, so nothing is lost
- create an orphan branch from the current tree, commit it as a single "history reset" commit, and
  make it the new default branch
- the old objects remain reachable through the archive tag; anyone who needs archaeology fetches it
  explicitly, and everyone else clones a repository whose history starts at ~40 MB

This is disruptive exactly once and is a normal thing for a repository that vendors binaries. Doing it
on a threshold, with the old history kept under a tag, is much better than doing it in a panic with
`filter-repo` and a force-push.

### What we deliberately do not do

**Git LFS.** It moves the bytes rather than removing them, needs server-side support and quota, and
breaks the offline-clone property that vendoring exists to provide — an LFS clone still has to reach a
server for the actual binary. For a repository whose whole pitch is "clone it and run an example", that
is the wrong trade.

**A binaries submodule.** Same objection: a clone that needs a second network fetch is not offline, and
it adds a submodule's failure modes to every user's first five minutes.

**Fetch-on-demand as the default.** This is the fallback if the numbers get worse than projected — the
SHA-256 records exist so it can be added without ceremony — but it turns the first run into a download
with a pinned-checksum failure mode, and that is exactly the friction vendoring is buying its way out
of.
