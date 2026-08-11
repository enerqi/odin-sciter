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

## Cutting a release

A release here is a git tag and nothing else — there is no package manager to publish to, and Odin
consumers vendor or submodule the repository or import it by path.

1. `just check` — both packages, the guides' snippets, all twenty-one examples
2. `just test` — every `@(test)`, and `just test_sanitize eval` for the `Value` refcounting under ASan
3. `just example api_map` — 189 slots, 0 mismatches, against the engine actually vendored
4. run the windowed examples by hand on every platform that claims to be tested
5. move the `## Unreleased` heading in [`CHANGELOG.md`](../CHANGELOG.md) to the version being cut, and
   check the platform table in it and in `README.md` still tell the truth
6. confirm `external/sciter/VENDORED.md` names the right tag, commit, engine version, API version and
   SHA-256
7. tag and push:

   ```sh
   git tag -a v6.0.4.9 -m "bindings for Sciter 6.0.4.9"
   git push origin v6.0.4.9
   ```

If the release attaches binaries as GitHub release assets rather than committing them, that is row 9
or 10 of the options table below — a change of strategy, not a step to add quietly here.

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
just example-tests  # every example's tests
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
published. Someone who wants the history but not the dead binaries can use a blobless partial clone
instead — `git clone --filter=blob:none <repo>` — which keeps every commit and fetches file contents
on demand.

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

### Options considered

The whole menu, so that revisiting this decision later is a matter of picking a different row rather
than re-deriving the field. **Rows 1, 2 and 5 are what this repository does**; 3 is offered to users;
everything else is a documented fallback, not a rejection on principle.

| # | Strategy | History cost | Offline `clone && run` | Main cost |
| --- | --- | --- | --- | --- |
| **1** | **Vendor binaries in git** ← *current* | ~40 MB per bump, three platforms | yes | permanent growth |
| **2** | **Upgrade deliberately, not on upstream's cadence** ← *current* | multiplies row 1 by 2–3/year instead of ~50 | yes | you sit on known upstream fixes longer |
| **3** | Document `--depth 1` for consumers ← *offered* | unchanged server-side; user downloads tip only | yes | no `git log`, no old tags without `--unshallow` |
| 4 | Document `--filter=blob:none` (blobless partial clone) | unchanged server-side; blobs on demand | yes, for the tip | history operations need network |
| **5** | **Orphan-branch squash at a threshold** ← *current, at ~500 MB* | resets to ~40 MB | yes | disruptive once per reset; old history lives under an archive tag |
| 6 | `git filter-repo` rewrite dropping old binaries | drops them retroactively | yes | rewrites every SHA, force-push, breaks forks and existing clones |
| 7 | Vendor compressed (`libsciter.so.zst`, decompressed by `just`) | ~9 MB instead of ~11 MB per platform-bump | after a decompress step | extra build step; `#load` and `single_binary` want the raw file |
| 8 | Binaries on an orphan `binaries` branch in this repo | unchanged server-side, excluded from `--single-branch` clones | only if the user fetches that branch | surprising, and two-step |
| 9 | Our own GitHub Releases + `just fetch-sdk` + pinned SHA-256 | **zero** | no — first run downloads | network failure mode on first run; we host and version the assets |
| 10 | Hybrid: Linux committed, Windows/macOS on releases | ~11 MB per bump | Linux only | two mechanisms to maintain |
| 11 | Fetch straight from upstream's GitLab release archive, pinned SHA | **zero** | no | upstream URLs can move; no hosting burden for us |
| 12 | Git LFS | pointers only | no — LFS fetch on clone | quota and bandwidth billing, server support required |
| 13 | Submodule pointing at a binaries repo | zero here | no | submodule failure modes in everyone's first five minutes; the other repo grows identically |
| 14 | Sibling repo, tags in lockstep, no submodule | zero here | no | manual pairing, version-skew risk |
| 15 | Headers only; user supplies the engine via `SCITER_LIB` | zero | no | every user needs the SDK before anything runs |
| 16 | Expect a system or distro package | zero | depends | nothing packages Sciter; version drift meets a `Version_Mismatch` refusal |
| 17 | Nix flake / container image carries the engine | zero | yes, for those users | only helps users already in that ecosystem |
| 18 | Ship the engine only inside our own release *binaries* (`single_binary`) | zero | no, for library consumers | fine for an application, useless for a bindings library |
| 19 | Vendor one platform, document the others as fetch-yourself | ~11 MB per bump | Linux only | pushes the work onto Windows and macOS users |

Facts that cut across the table:

- Anything from row 9 down only pays off if the binaries were **never committed**. Publishing a release
  asset for a blob already in a pack shrinks nothing — that is why rows 5 and 6 exist as the only
  retroactive fixes.
- Rows 3 and 4 reduce what a *user downloads*, never the server-side repository. Only 5, 6, and never
  committing reduce that.
- GitHub hard-rejects a single file over 100 MB and warns over 50 MB; release assets allow 2 GB per
  file and are not counted against repository size. `libsciter.dylib` at 47.7 MB is the closest any of
  our files comes to a limit.
- Every fetch-based row needs the SHA-256 records in `VENDORED.md`. Keeping those current is what makes
  9, 10 and 11 available at any time without a flag day.
- The EULA permits redistributing the engine binary in any of these forms. The About-box attribution is
  the only obligation and does not vary by mechanism.

Why the current choice and not the cheaper ones: `git clone && just example hello_window` working with
no network, no SDK and no download step is the single biggest thing that makes a bindings library
approachable, and every zero-history-cost row buys its savings by breaking exactly that. Row 10 is the
most likely first concession if the budget bites — it keeps the offline property on the platform most
people land on while cutting the per-bump cost by three quarters.
