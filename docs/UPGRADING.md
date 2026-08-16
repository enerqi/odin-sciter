# Upgrading the Sciter engine

Version policy, the upgrade procedure, and what to do about the repository growing.

## Policy

**Vendor the headers; fetch the engine.** `external/sciter/include` is in this repository — that is what
the bindings are generated from, it is BSD, and it is text that diffs. The engine binary is not, on any
platform: it is pinned by SHA-256 and installed by `just fetch-engine`, which `ensure-engine` runs
before the first build. So `git clone && just example hello_window` works with no SDK and no manual
step, but not with no network. The reasoning, and what that cost, is in
[the engine decision](#the-engine-decided---fetch-on-every-platform-and-history-was-rewritten-to-match)
below.

**Pin one version at a time.** Exactly one engine build per platform is pinned, named in
[`external/sciter/VENDORED.md`](../external/sciter/VENDORED.md) with its SHA-256. Upstream tags roughly
weekly; that is not an upgrade cadence, it is a changelog. Upgrade when there is a reason — a fix you
need, a platform you are adding, or a version that has been stable for a while — not on a schedule.

**Follow upstream's version in our tags.** A release of these bindings is tagged with the engine
version it pins:

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

**There is a second tag namespace, and it says nothing about the source.** `engine-<upstream tag>`
exists only to hold the mirrored engine binaries as release assets, because GitHub cannot publish an
asset without a tag. It points at whatever commit `master` was on when it was created, it blesses no
state of this repository, and a checkout of it is not a release of anything. `vX.Y.Z.W` is the only
tag that means "these bindings, released".

### Which engine each release speaks to

The mapping is many-to-one and stays that way: the source can be tagged repeatedly against one engine
(that is what the `-N` suffix is for), while the mirror release is published once per *pin*. A tag
still answers "which engine" on its own — the table is the record of what exists, not a decoder ring.

| Bindings tag | Engine | Mirror release |
| --- | --- | --- |
| *none yet — the bindings are unreleased* | `6.0.4.9-bis`, engine 6.0.4.9, API 10 | [`engine-6.0.4.9-bis`](https://github.com/enerqi/odin-sciter/releases/tag/engine-6.0.4.9-bis) |

Add a row when a bindings tag is cut; add a *mirror* row only when the pin moves, per step 8 below.

## The engine: decided - fetch, on every platform, and history was rewritten to match

**Done, 2026-08-15.** No engine is committed to this repository. All three are gitignored, pinned by
SHA-256 in [`external/sciter/VENDORED.md`](../external/sciter/VENDORED.md) and installed by
`just fetch-engine`, and the three copies that had already been committed were removed from history with
`git filter-repo`. `.git` went from **41 MB to ~2 MB**.

The reasoning, kept because it is the reasoning for the next binary anyone is tempted to commit:

`lib/linux/x64/libsciter.so` was 24 MB, tracked in git, not under LFS. It was **one blob**, committed
once at the initial spike and never changed. That was fine. It does not stay fine:

- a binary does not delta against its predecessor, so **every upgrade adds ~40 MB to history across the
  three platforms, permanently**. This document treats upgrades as routine and `canary.yml` surfaces
  upstream tags weekly, so the intended cadence is "regularly"
- all three platforms landed within a fortnight, and the last of them - macOS, 50 MB because it is a
  universal binary carrying two architectures - took `.git` from 11 MB to 41 MB in a single commit, for
  the one platform nobody working here can even run
- `docs/PLAN.md` already records that a full-history clone of the *upstream* SDK is ~4 GB because "800+
  commits, each carrying every platform's binaries" - the same failure mode, one scale down

**The decision: do not vendor.** `just fetch-engine` downloads the pinned binary and verifies it against
the recorded SHA-256; `ensure-engine` runs it automatically and is a dependency of every recipe that
builds or runs anything, so a checkout needs no ceremony beyond the first build. The switch cost what it
was predicted to cost: three gitignore lines, three CI steps changed from `--check` to a fetch, and the
doc edits. **Nothing in the build needed touching**, because `ensure-engine` had been in place, doing
nothing, since before there was anything to fetch.

The rewrite was done while it was cheap - 67 commits, one author, no tags, one branch, and exactly one
copy of each engine in history. Doing it after a second engine version would have meant six blobs and a
worse trade; doing it before the repository has other clones is the only comfortable time. Commands are
in [Rewriting history](#rewriting-history-if-a-binary-does-get-committed) below.

git-lfs was the alternative and was rejected: it keeps the offline-clone property but trades a size
problem you understand for a tooling one your contributors meet on their first `git clone` - a pointer
file and a confusing failure if `git-lfs` is not installed - plus quota and bandwidth billing that forks
inherit. The fetch recipe reaches the same place with no new dependency.

### What changes at the switch, and what it costs

The cost is real and worth stating: **`git clone` alone is no longer enough**, and the "works offline
from a clean clone with nothing installed" line in `README.md` became "works offline after one command".
`examples/single_binary.odin` embeds the engine with `#load`, which is *compile-time*, so `just check`
cannot build without the file - that is why `ensure-engine` is wired into the recipes rather than
documented as a step.

The switch itself was: three lines in `.gitignore`, `git rm --cached` on three files, three CI steps
from `just fetch-engine --check` to `just fetch-engine`, the two "is the engine vendored?" guards
deleted (a guard whose answer is now always "no" would skip the runtime steps and report green), the
offline claims in `README.md` and `docs/deployment.md`, and one `git filter-repo` run.

**When the next engine version lands**, the whole of it is now:

1. new `engine_tag` and `engine_sha256` in the `justfile`, new hash and size in `VENDORED.md`
2. `just fetch-engine --force`
3. the upgrade procedure below, starting at `just api-map-verify`

There is no blob to remove and no history to rewrite, which is the point.

### The trap the recipe exists to catch

The upstream tag `6.0.4.9` serves a `libsciter.so` of **exactly** the same 25 015 296 bytes as
`6.0.4.9-bis`, with a different SHA-256. Measured, by downloading both. A fetch that checked the length -
or a human comparing `ls -l` - would install the wrong engine and report success, and the failure would
surface later as something inexplicable in `api_map`. The tag suffix is part of the engine's identity and
the hash is what decides; `just fetch-engine --check` runs in CI for that reason.

## Cutting a release

A release here is a git tag and nothing else — there is no package manager to publish to, and Odin
consumers vendor or submodule the repository or import it by path.

1. `just check` — both packages, the guides' snippets, every example — then `just build-examples`,
   which is the half that links
2. `just test` — every `@(test)`, and `just test_sanitize eval` for the `Value` refcounting under ASan
3. `just example api_map` — 189 slots, 0 mismatches, against the engine actually installed
   and `just parity --check` — the slots the new headers declare against the ones `sciter_app` wraps,
   diffed against `docs/parity-baseline.txt`. `api_map` catches a slot that moved or vanished; this is
   the one that catches a slot that *appeared*, which is how coverage otherwise rots one SDK at a time
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

8. **publish the three engine binaries as release assets, if this pin has none yet.** Not optional, and
   not the same thing as vendoring them: nothing is in git history any more, so upstream withdrawing or
   moving a tag would otherwise leave every commit of this repository unbuildable, past ones included.
   A GitHub release allows 2 GB per asset and the three are 90 MB.

   **They hang off their own tag, `engine-<upstream tag>`, not off the bindings tag from step 7.** The
   assets are a byte-for-byte mirror of what upstream shipped, so the thing that should move the URL is
   the *pin* moving, not a release being cut. Cutting `v6.0.5` bindings against the same engine
   therefore makes this step a no-op — check whether `engine-6.0.4.9-bis` already has its three assets
   and stop if it does. It is `fetch-engine.py`'s third source, derived from `engine_tag` rather than
   configured, so a fresh clone gets the fallback without anyone setting an environment variable; the
   two that exist (`SCITER_ENGINE_URL`, a complete URL for one file, and `SCITER_ENGINE_BASE`, an
   alternative base) are for a corporate mirror or an air-gapped machine. All three are verified
   against the SHA-256 in `VENDORED.md`, so an untrusted source cannot do worse than fail the check.

   ```sh
   gh release create engine-6.0.4.9-bis \
       lib/linux/x64/libsciter.so lib/windows/x64/sciter.dll lib/macosx/libsciter.dylib \
       --target master --title "Sciter engine 6.0.4.9-bis" --notes-file notes.md
   ```

   The notes carry the SHA-256 table and the EULA's attribution line — the engine is not BSD, and
   redistributing it is exactly what the EULA contemplates *provided* that line travels with it. See
   [`VENDORED.md`](../external/sciter/VENDORED.md#licensing).

   Then prove the loop closes, rather than reading the release page: point the variable at the asset
   you just uploaded and make the fetch actually take it.

   ```sh
   SCITER_ENGINE_URL=https://github.com/enerqi/odin-sciter/releases/download/engine-6.0.4.9-bis/libsciter.so \
       just fetch-engine --force
   ```

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

Expected: **189 slots, 0 mismatches**, and the null count for the platform you are on — 16 on Linux and
macOS, 15 on Windows, which nulls that same list minus `SciterProcND`. Nulls are platform padding, so
the count differing by platform is not a fault; `examples/api_map.odin`'s header comment has the
measured list for each. Every non-null slot resolves to its
own name plus the engine's `Imp` suffix. A different slot count is a real API change and means reading
the diff of `sciter-x-api.h`. A *mismatch* means the generated struct and the binary disagree about
field offsets, and nothing else in the suite will tell you that — every call would simply land in the
wrong function.

**7. Check and test.**

```sh
just check          # type check: both packages, the guides' snippets, all examples
just build-examples # and the half that links
just example-tests  # every example's tests
just test_sanitize eval    # Value refcounting under ASan
```

**8. Run the windowed examples by hand.** `hello_window`, `dom_walk`, `events`, `archive`,
`custom_loader`, `inspector`. Automated tests cannot see a window that renders blank.

**9. Update the docs that name a version**: `README.md`'s version table, `docs/PLAN.md`'s status line,
`VENDORED.md`. Then tag per the policy above.

### What CI does for you

Most of the mechanical half of the list above runs in `.github/workflows/`, so a branch that bumps the
pin arrives with the answers already attached.

| Step | Where |
| --- | --- |
| 1 get the SDK | `canary.yml` fetches it blobless + sparse + depth 1 — two paths, not 4 GB |
| 2 read the SDK changelog | **you** |
| 3 headers, 4 binaries | by hand on a real upgrade; `canary.yml` does it on a scratch tree |
| 5 `just bindgen` | `bindgen.yml` — and it asserts the result is byte-identical to what is committed |
| 6 `just example api_map` | `ci.yml`, as `just api-map-verify` — the table is asserted, not printed for reading |
| 6b `just parity --check` | `ci.yml` — new unwrapped slots are a diff against `docs/parity-baseline.txt` |
| 7 check and test | `ci.yml`, on Linux under Xvfb, plus `just cross-check` for the two other targets |
| 8 windowed by hand | **you.** CI cannot see that a window renders blank |
| 9 docs | **you** |

The piece that does not correspond to a step is `canary.yml`, and it is the reason the rest is worth
having. Once a week it asks GitLab for the newest tag, and if it is not the pinned one it swaps that
engine's headers and Linux binary into a scratch tree, regenerates, and runs steps 5-7 against it —
committing nothing and moving nothing. So "does the new engine still fit these bindings?" is answered
before there is a reason to upgrade, and a reordered `ISciterAPI`, a changed `SCITER_API_VERSION`, or a
`flatten_headers.py` patch that stopped matching arrives as an issue rather than as a surprise in the
middle of an upgrade. It also feeds `api_map` the API version parsed out of the *new* headers, so the
headers-disagree-with-the-binary trap that cost this project a day on the GitHub mirror is checked on
every probe.

`api-map-verify`'s expectations — 189 slots, `SCITER_API_VERSION` 10, and the per-platform null list —
live in `.github/scripts/check-api-map.py`. On a version bump those are the lines you expect to edit,
and the diff of that file is then the record of what the new engine changed.

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

So the trajectory is roughly **40 MB of permanent history per engine bump** once all three platforms
are vendored. Ten bumps is 400 MB. That is survivable but not comfortable, and it is worth deciding
how to handle it before the second and third binaries land rather than after.

**And then all three landed inside a fortnight, which is how the table above stopped being a
projection.** `.git` was 11 MB with Linux alone; Windows added its 8; committing the macOS dylib took it
to **41 MB** - the single largest jump, from the single largest file, for the platform nobody here can
even run. The projection was right, it just arrived before the next engine version did, and the answer
was the one this section had been holding in reserve: none of them are committed now, the three blobs
were removed from history, and `.git` is **~2 MB**. See the decision at the top of this file.

### What we do about it

**0. Do not commit the engine.** This is the one that made the rest of the list mostly historical, and
it is listed last-first because it was reached last: the other mitigations all manage the cost of
carrying binaries, and this one declines to carry them. Kept below is what still applies if a binary
ever does land, deliberately or by accident.

**1. Upgrade deliberately, not weekly.** The policy above is still the primary mitigation for the
*download*, even now that it is not a history mitigation.

**2. Tell consumers to shallow-clone.** Much less necessary now that a full clone is ~2 MB, and still
the right advice for anyone who does not want 67 commits of history:

```sh
git clone --depth 1 <repo>
```

Someone who wants the history but not any large blob a future commit adds can use a blobless partial
clone instead — `git clone --filter=blob:none <repo>` — which keeps every commit and fetches file
contents on demand.

**3. Never keep two engine versions in the tree.** Replace the file; do not add
`lib/linux/x64/libsciter-6.0.5.so` beside the old one. The tag says which engine a checkout carries.

**4. Record SHA-256 in `VENDORED.md` for every engine binary.** This was written as cheap insurance and
as the precondition for switching strategies later without a flag day — and it is the mitigation that
paid, because that switch is exactly what happened. `just fetch-engine` downloads against those hashes
and refuses a mismatch, so recording them was the whole cost of moving from "committed" to "fetched",
and it is what makes an untrusted mirror (`SCITER_ENGINE_URL`) safe. Keep recording them: the hash is
the pin.

**5. Set a threshold, and act on it rather than drifting.** This was written as "when `.git` passes
~500 MB, squash onto an orphan branch". It was acted on at 41 MB instead, and with a `filter-repo`
rewrite rather than a squash, because at 67 commits and one author the rewrite keeps the history and
the squash throws it away. Both remain available; the runbook below is the one that was used.

### Rewriting history, if a binary does get committed

What was run on 2026-08-15 to remove the three engines, kept because the next accidental 20 MB commit
wants the same five steps. **It rewrites every SHA from the first affected commit onwards**, so it needs
a force-push and everyone with a clone re-clones. That is cheap here and gets less cheap with every
contributor.

```sh
# 1. what is actually big, before deciding anything
git rev-list --objects --all |
  git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' |
  awk '$1=="blob" && $3>400000 {printf "%7.2f MB  %s\n", $3/1048576, $4}' | sort -rn

# 2. a backup that does not depend on the remote, and the binaries themselves
git bundle create ../pre-rewrite.bundle --all
cp lib/linux/x64/libsciter.so lib/windows/x64/sciter.dll lib/macosx/libsciter.dylib ~/engine-backup/

# 3. the rewrite. --invert-paths turns the --path list into "everything except"
uv tool run --from git-filter-repo git-filter-repo --force \
    --path lib/linux/x64/libsciter.so \
    --path lib/windows/x64/sciter.dll \
    --path lib/macosx/libsciter.dylib \
    --invert-paths

# 4. filter-repo removes `origin` deliberately, so a force-push cannot be accidental
git remote add origin <url>

# 5. verify before pushing anything
git count-objects -vH        # expect ~2 MB
just fetch-engine            # the working tree gets its engine back
just check
```

Two things that are easy to miss:

- **`.git/filter-repo/commit-map`** maps every old SHA to its new one. Any document that quotes a commit
  hash is fiction until it is rewritten from that file. This bit once: a handoff note carrying a table of
  thirteen SHAs had to be repaired after the rewrite, and was later deleted for the same reason — a doc
  whose content is commit hashes is a doc that git already stores and that breaks every time history
  moves. Prefer naming what changed over naming the commit that changed it.
- a force-push does not delete anything from GitHub. Old objects stay addressable by SHA until their
  garbage collection runs. This is size hygiene for clones, not erasure.

Do the un-vendoring commit *first*, so the rewrite lands on a tree that already describes the world
correctly, and keep `--path` explicit rather than `--strip-blobs-bigger-than` for a one-off: the size
filter is the right tool for an ongoing policy and too blunt for a known list.

### Options considered

The whole menu, so that revisiting this decision later is a matter of picking a different row rather
than re-deriving the field. **Rows 1, 2 and 5 are what this repository does**; 3 is offered to users;
everything else is a documented fallback, not a rejection on principle.

| # | Strategy | History cost | Offline `clone && run` | Main cost |
| --- | --- | --- | --- | --- |
| 1 | Vendor binaries in git ← *was current until 2026-08-15* | ~40 MB per bump, three platforms | yes | permanent growth |
| **2** | **Upgrade deliberately, not on upstream's cadence** ← *current* | now a download cost rather than a history cost | — | you sit on known upstream fixes longer |
| **3** | Document `--depth 1` for consumers ← *offered* | unchanged server-side; user downloads tip only | — | no `git log`, no old tags without `--unshallow` |
| 4 | Document `--filter=blob:none` (blobless partial clone) | unchanged server-side; blobs on demand | — | history operations need network |
| 5 | Orphan-branch squash at a threshold | resets to ~40 MB | yes | disruptive once per reset; old history lives under an archive tag |
| **6** | **`git filter-repo` rewrite dropping the binaries** ← *done once, 2026-08-15* | dropped them retroactively: 41 MB → ~2 MB | no | rewrites every SHA, force-push, breaks forks and existing clones |
| 7 | Vendor compressed (`libsciter.so.zst`, decompressed by `just`) | ~9 MB instead of ~11 MB per platform-bump | after a decompress step | extra build step; `#load` and `single_binary` want the raw file |
| 8 | Binaries on an orphan `binaries` branch in this repo | unchanged server-side, excluded from `--single-branch` clones | only if the user fetches that branch | surprising, and two-step |
| **9** | **Our own GitHub Releases + pinned SHA-256** ← *current, as the last source, tried automatically* | **zero** | no — first run downloads | network failure mode on first run; we host and version the assets |
| 10 | Hybrid: Linux committed, Windows/macOS on releases | ~11 MB per bump | Linux only | two mechanisms to maintain |
| **11** | **Fetch straight from upstream's GitLab archive, pinned SHA** ← *current* | **zero** | no | upstream URLs can move - which is why row 9 sits behind it, tried without being asked for |
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

**Why the choice changed.** The original reasoning was that `git clone && just example hello_window`
working with no network, no SDK and no download step is the single biggest thing that makes a bindings
library approachable, and every zero-history-cost row buys its savings by breaking exactly that. That is
still true, and it lost anyway: the offline property is worth something once, and ~40 MB of permanent
history is a cost that recurs on every bump, for every clone, forever. What tipped it was the third
binary landing — 41 MB of `.git` for a repository whose source is under 2 MB — and the fact that
`ensure-engine` had already made the download invisible, so the property being traded away was narrower
than it looked: not "clone and run", but "clone and run *with no network*".

Row 11 with row 9 behind it is where that lands. The pin lives in `VENDORED.md`, upstream is the
primary source, our own release assets are the fallback when upstream moves — reached from the pinned
tag rather than from an environment variable, because a fallback nobody knows to configure is not one —
and every source is verified against the same hash.
