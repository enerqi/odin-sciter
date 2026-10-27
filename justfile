# `cmd.exe` starts in ~9ms and always available. just launches a shell per recipe line.
#  - alternatives: `nu -c` ~41ms, `powershell -NoLogo -NoProfile -Command` ~143ms
#  - cost: it is a poor language for a multi-line recipe, hence uv -> python preferred for more complex tasks
set windows-shell := ["cmd.exe", "/c"]
set shell := ["bash", "-c"]
set lists  # `[cache(inputs = ...)]` takes a list; see build-checks in ci.just
set unstable  # [script] feature - https://github.com/casey/just/issues/1479
set lazy

# `python` alone is not a reliable cross-platform lookup (cf. python/python3/python3.x)
# uv resolves/downloads on every platform and --no-project means no looking for pyproject.toml / local .venv
# just recipes opt in with the bare `[script]` attribute (no interpreter argument)
set script-interpreter := ["uv", "run", "--no-project", "-p", "3.14", "python"]

# The same interpreter, for the recipes that run a *committed script file* rather than an inline
# `[script]` body. `set script-interpreter` only applies to inline bodies, so without this the file-based
# recipes would each spell the invocation out - and the one that did spell it out its own way
# (`fetch-engine`, as `python3` on unix and `python` on Windows) needed two platform recipes and a
# comment explaining a rule the others no longer followed. One spelling, one place to change it.
py := "uv run --no-project -p 3.14 python"

# Newest just features used below, in order of introduction: `[group]` (1.33), `--groups` (1.47),
# user-defined functions (1.49), `--list --group` (1.50), `set lists` and `split()` (1.53), and cached
# recipes (1.54) - the last of which is `build-checks` in ci.just.
#
# **The floor is 1.57.0, and it is set by two bugs rather than by a feature.** Both were measured by
# running this justfile under 1.55.1, 1.56.0, 1.57.0 and 1.58.0 - the developer machine was on 1.58.0
# and the pin was 1.55.1, which is exactly why Windows passed and Linux and macOS did not.
#
#   before 1.56  `set lazy` plus a *variable* in a `[cache(...)]` attribute. The attribute is evaluated
#                before the lazy variable is resolved, and the result is not a clean error:
#
#                    error: internal runtime error, this may indicate a bug in just:
#                           attempted to evaluate undefined variable `checks_sources`
#
#                Any non-literal variable does it. `outputs = <literal-valued variable>` is fine;
#                `inputs = split(<globbed variable>, " ")` is not.
#
#   before 1.57  the escaped `\"` inside `shell(...)` below does not survive to the shell, so the
#                python one-liner arrives truncated and exits with a SyntaxError. A backtick command
#                instead of `shell()` fails the same way, so this is about quoting and not about which
#                spelling reaches the shell.
#
# Keep the pin in `.github/actions/toolchain/action.yml`, docs/WINDOWS-CHECKLIST.md,
# docs/getting-started.md, README.md and `odin-skel doctor` in step.
set minimum-version := "1.57.0"

# **Every recipe carries a `[group('...')]`, and a new one should too.** Seven groups, and they are the
# split this project already made informally - in the recipe names (`example_*`, `example_rerun_*`,
# `check-*`, `fetch-*`) and in the division between this file and `ci.just`:
#
#	examples    launch one: example_*, inspector, diagnose, time_*
#	test        the test suite and the sanitizers
#	gates       everything ci.yml runs to pass or fail a change
#	build       produce an artifact that is not an example: bindings, extensions, the .pak, docs
#	toolchain   fetch and ensure the pinned tools, make the output directories, clean
#	release     cut a version
#	editor      Sublime Text integration
#
# `just --groups` lists them, `just --list --group gates` lists one. **Invocation is unchanged** -
# `just parity` is still `just parity`, which is why this and not `mod`: a module is a real namespace
# and would break every `run: just <recipe>` line in ci.yml, every inner `just` call (`ensure-engine`
# shells out to `just fetch-engine`), and every cross-file dependency, since variables, settings and
# recipes do not cross a module boundary. Measured: a module does not even inherit `set windows-shell`.
#
# Nothing enforces the attribute. A recipe written without one is not an error - it lists above the
# first heading, which is the whole of the feedback you get.

# Shared-library extension, for `just extension`. Sciter's loadLibrary() takes a name without one.
shared_ext := if os() == "windows" { ".dll" } else if os() == "macos" { ".dylib" } else { ".so" }

# The pinned engine, and where to fetch it when it is not on disk.
#
# **The tag suffix is part of the identity, and the size is not.** Measured: the plain `6.0.4.9` tag
# serves a `libsciter.so` of *exactly* the same 25 015 296 bytes as `6.0.4.9-bis` and a different
# SHA-256, so a fetch that checks the length would install the wrong engine and report success. The
# hash below is the one in `external/sciter/VENDORED.md`, and it is what decides.
engine_tag := "6.0.4.9-bis"

# One hash per platform, because the pin is per *file*, not per tag. A single hash here would have made
# `just fetch-engine` on Windows fetch sciter.dll and compare it against the Linux .so's digest - which
# fails with "refusing to install", i.e. the recipe that exists to install the engine cannot install it.
#
# The macOS entry covers both architectures: `bin/macosx/libsciter.dylib` is a universal binary with an
# x86_64 and an arm64 slice, so there is one file and one hash rather than a directory per arch. That is
# why `engine_rel` below has no `x64` component on macOS and the other two do.
engine_sha256 := if os() == "windows" { "b49ff94759951c4dd87f18a0edac466adb48a352bdecadbd6d5568f5e2203083" } else if os() == "macos" { "a7b65f37b265a0bacf7c127b8e45e8c0f66a16e3e1071b877b19ca333af1c25c" } else { "b2e4a33682dcb7f2a63a76707e5d47faa9cb1440d986bf08fdc23ecd3964968b" }

# The same relative path under two roots: `bin/` upstream, `lib/` here.
engine_rel := if os() == "windows" { "windows/x64/sciter.dll" } else if os() == "macos" { "macosx/libsciter.dylib" } else { "linux/x64/libsciter.so" }
engine_path := "lib/" + engine_rel

# Suffix on a native executable, for the tool paths built below (`odinfmt_bin`, `bindgen_bin`). The SDK's
# own tools need the same suffix and resolve it in justlib's `sdk_tool`, which owns their layout.
exe_ext := if os() == "windows" { ".exe" } else { "" }

# The pinned formatter. odinfmt ships inside an ols release and has no `--version` flag, so nothing
# about a binary on PATH says which one it is - and different releases disagree about the same source.
# Measured here: ols master at 51578d51 leaves a 164-character composite literal on one line where the
# pin below wraps it, correctly, since odinfmt.json sets `character_width: 120`. So `just format` on a
# machine with a newer ols produced a clean local tree and four CI failures.
#
# **This pin used to live in `.github/actions/toolchain/action.yml` as an input default**, where only
# CI could see it, which is exactly how the two drifted apart. It lives here now and the workflows read
# it with `just --evaluate ols_tag`. `bindgen_commit` further down is the same lesson.
ols_tag := "dev-2026-06"

# The release ships one archive per platform and the digests are published per asset, so the pin is a
# hash and not just a tag - the same reasoning as `engine_sha256`, and cheap insurance against a tag
# being re-cut. macOS and Linux each have two, because unlike the engine's universal dylib these are
# per-architecture files.
ols_plat := if os() == "windows" { "x86_64-pc-windows-msvc" } else if os() == "macos" { if arch() == "aarch64" { "arm64-darwin" } else { "x86_64-darwin" } } else { if arch() == "aarch64" { "arm64-unknown-linux-gnu" } else { "x86_64-unknown-linux-gnu" } }
ols_sha256 := if ols_plat == "x86_64-pc-windows-msvc" { "08785a8ae2ef5073b9d2e27abae83a7a8000cc6503711d0a92a61e2900bddf9e" } else if ols_plat == "arm64-darwin" { "931bca3776491e7809fc5054fad1c95459c25e62af5492294b84c5950c1a5e36" } else if ols_plat == "x86_64-darwin" { "2e2d3c168ae8dc56d76574a95ebd998f7764b21d5da4dc1f4a66b1e880acbc9b" } else if ols_plat == "arm64-unknown-linux-gnu" { "423c28323223d229dea3b69bc49679dbadd6e4559dc5d6b50eb10ac708f9c9eb" } else { "d0b232947a258032979321626a54c3dba54e44ebd23be255a34eb254dfc679a3" }

# Where versioned tool installs live, and the resolved formatter under it. The tag is *in the path*, so
# the existence test is the version test: there is no state where the right path holds the wrong
# binary. Outside the repository because it is shared by every checkout and worktree, survives `just
# clean`, and needs no gitignore line. `$ODIN_TOOLS` overrides the root.
#
# `USERPROFILE` before `HOME` on Windows deliberately: a Git-bash parent sets `HOME=/c/Users/you`, an
# MSYS path, and every Windows recipe here runs under cmd.exe, which cannot use one.
home_dir := if os() == "windows" { env_var_or_default("USERPROFILE", env_var_or_default("HOME", ".")) } else { env_var_or_default("HOME", ".") }
odin_tools := env_var_or_default("ODIN_TOOLS", join(home_dir, ".odin-tools"))
odinfmt_bin := join(odin_tools, "ols", ols_tag, "odinfmt" + exe_ext)

# `join`, not the `/` operator: `/` always emits a forward slash, and cmd.exe rejects a forward-slash
# path in *command* position ("'target' is not recognized") even quoted. Odin takes either in an
# `-out:` argument, but the `example_rerun_*` recipes invoke the binary directly, so they need the native
# separator `join` gives. bash needs no `./` prefix - a path containing a slash is already a path.
target_path(dir, name) := join("target", dir, name)

# The static-check tool: `tools/checks`, one binary with a subcommand per check. It reads this
# repository's own Odin through `core:odin/parser`, which is the same parser the compiler front end and
# ols use, so a question like "what does this procedure return" is a field access rather than a regex.
#
# It replaces six Python scripts that between them hand-rolled four partial parsers. One binary rather
# than six programs because `package sciter_app` is parsed once and every check reads the same index -
# measured at 0.16 s for four checks against 0.61 s for the four Python equivalents.
checks_bin := target_path("debug", "checks" + exe_ext)

# The sources `build-checks` is cached against - see the `[cache]` attribute on that recipe in ci.just.
#
# Globbed rather than listed, and that is the difference between a cache that is safe and one that is
# a trap. `[cache(inputs = ...)]` hashes each named file, so a hand-written list goes stale silently
# the day somebody adds a file to tools/checks: the new check compiles into the binary on one machine
# and never on CI, and nothing says so. Re-globbing on every evaluation means a new file changes the
# input *list*, which changes the key. Measured: adding a file invalidates.
#
# `set lazy` is why this is affordable at all - the `shell()` call runs only for the recipes that name
# the variable, not on every `just` invocation. It is still the expensive half of the arrangement:
# measured at ~113 ms a call, essentially all of it uv's startup, against the ~400 ms `odin build` the
# cache is there to skip. Across the seven checks that is 0.8 s spent to save 2.4 s, and the whole
# warm suite runs in 1.1 s. Cheaper spellings exist (`dir /b` on Windows, `ls` elsewhere) and were not
# taken: they need an `if os()` branch, one of them emits `\r\n`, and neither is worth a second
# cross-platform quoting hazard for 0.7 s.
#
# A `"..."` string, not a `` `...` `` one: backticks are command evaluation in just, so the obvious
# spelling runs the python before `shell()` ever sees it.
checks_sources := trim(shell(py + " -c \"import glob;print(' '.join(sorted(glob.glob('tools/checks/*.odin'))))\""))

# Which linker Odin hands the object files to. `-linker:` takes exactly four values: `default` (Odin
# picks - MSVC `link.exe` on Windows), `lld`, `radlink` (Windows only, bundled with Odin, hence the
# Windows default here) and `mold` (Linux only, not bundled). Odin has no build cache and relinks on
# every build, so this is a per-iteration cost. `odin-skel new --linker=VALUE` rewrites the default below.
#
# Override for one command without editing this file - for `-lto`, which on Windows *requires* lld, or
# for a machine that has mold when the project default does not assume it:
#
#     ODIN_LINKER=lld just example_release -lto:thin
#
# An env var rather than a recipe argument because `odin` errors on a repeated flag ("Previous flag set:
# 'linker'"), so a `-linker:` passed through a recipe's `*args` would collide with the one added below.
# Which value to pick, and the lld-on-macOS and incremental-linking caveats: README, "Choosing a linker".
linker := env_var_or_default("ODIN_LINKER", if os() == "windows" { "radlink" } else { "default" })

# The gates and the release surgery live in their own files. An import shares one namespace with this
# one, so `just parity`, `just release` and `just --list` behave exactly as they did when both were part
# of this file, and everything above - `py`, `linker`, `target_path`, `mktarget_dirs`, `ensure-engine` -
# resolves from there. `import`, not `import?`: both are committed, and a missing one is a broken
# checkout rather than a feature you declined.
import 'ci.just'
import 'release.just'

# Explicit paths rather than `odinfmt -w .`, because src/prelude.odin is deliberately not a standalone
# Odin file - it has no `package` line, since bindgen pastes it into sciter.odin under that file's own
# one (see `imports_file` in bindgen.sjson). odinfmt cannot parse it and fails the whole run.
#
# The same roots are in `FORMAT_ROOTS` in justlib, which is what `format-check` reads. Change both.
#
# **`{{odinfmt_bin}}`, never a bare `odinfmt`.** The pin is only worth having if the pinned binary is
# the one that runs, and a developer with ols on PATH has a different formatter sitting in front of it.
# See `ols_tag` at the top of this file for the four-file CI failure that argument is not hypothetical
# about.
# ---
# odinfmt every odin file in the project
[group('gates')]
format: ensure-odinfmt
	{{odinfmt_bin}} -w sciter.odin
	{{odinfmt_bin}} -w sciter_app
	{{odinfmt_bin}} -w examples
	{{odinfmt_bin}} -w docs/snippets


# `-vet-tabs` is the only compiler-side enforcement of .editorconfig's `indent_style = tab`; it is not
# implied by `-strict-style`, so without it a space-indented file lints clean. Nothing in the Odin
# toolchain checks line endings - those are held in place by .gitattributes and odinfmt.json instead.
# Accepts extra args like `-show-timings` as needed.
#
# Both library packages, because CI runs this and the root package alone left `sciter_app` - where
# nearly all the hand-written code is - unlinted. Not `examples/`: those do not lint clean today.
# ---
# lint checks for style and potential bugs. No code generation
[script]
[group('gates')]
lint *args: ensure-engine
	import sys
	sys.path.insert(0, ".github/scripts")
	from justlib import VET, example_sources, host_x11_skip, parallel, try_run

	args = r"""{{args}}""".split()

	# The examples are 23k of the repository's ~34k lines, and they used to be excluded here - which
	# meant the vet flags covered the third of the code least likely to be read closely. They pass now;
	# the whole cleanup was 25 findings, all unused imports, unused locals and shadowed `err`s.
	#
	# `-no-entry-point` is in VET for all of them: `extension.odin` and `sqlite_extension.odin` are
	# native extensions built as shared libraries and have no `main`, and the flag is harmless for the
	# rest. The X11-only pair does not compile off Linux at all - see justlib - so there is nothing for
	# the vet flags to say about it there.
	#
	# Parallel and keep-going, for the same reasons as `check`: vet findings come in batches, and one
	# file's worth at a time is the slow way to clear them.
	# Not `PACKAGES`: `docs/snippets` is deliberately out, because a guide's snippet is written to read
	# well and declares things it does not use to make a point. `tools/checks` is in - it is ordinary
	# Odin this repository owns, and holding the tool that checks the tree to a lower bar than the tree
	# is the wrong way round.
	skip = host_x11_skip()
	cmds = [["odin", "check", p, *VET, *args] for p in (".", "sciter_app", "tools/checks")]
	cmds += [["odin", "check", f, "-file", *VET, *args] for f in example_sources(skip)]

	codes = parallel(cmds, try_run)
	bad = [c for c, code in zip(cmds, codes) if code]

	if bad:
		print()
		print(f"FAILED -vet ({len(bad)}):")
		for c in bad:
			print(f"    {' '.join(c)}")
		raise SystemExit(1)

	tail = f" (skipped, X11-only: {' '.join(skip)})" if skip else ""
	all_ = "" if skip else "all "
	# `- 3` for the two library packages and the check tool, leaving the example count.
	print(f"ok: both library packages, tools/checks and {all_}{len(cmds) - 3} examples pass -vet{tail}")


# The engine, fetched instead of vendored - see `docs/UPGRADING.md` on the repository-size decision.
#
# **No engine is committed on any platform**, so this is what a fresh clone needs before it can build
# anything - which is why every entry point below depends on `ensure-engine` rather than leaving it to a
# README step nobody reads. It was a no-op for as long as `lib/` was committed, and the switch cost the
# gitignore lines and the CI steps, exactly as predicted: nothing in the build changed.
#
# `/` in the script path is safe here even on Windows: cmd.exe only rejects a forward slash in *command*
# position, and this one is an argument to the interpreter.
#
# `require-uv` is a dependency rather than an assumption because this is the first recipe a fresh clone
# runs: without it the failure is `No such file or directory (os error 2)`, which names neither uv nor
# what to do about it.
#
# `--check` verifies what is already on disk, which is the useful mode in CI and after an upgrade.
# `--force` re-fetches over a file that is already there.
# ---
# download the pinned engine into lib/, verified against its SHA-256
[group('toolchain')]
fetch-engine *args: require-uv
	{{py}} .github/scripts/fetch-engine.py {{engine_tag}} {{engine_sha256}} {{engine_rel}} {{args}}

# uv is a hard prerequisite, not a developer convenience: every Python recipe here runs through it, and
# `fetch-engine` is one, so a clean clone cannot build without it. This turns "some tool exited 2" into a
# sentence naming the tool and the command that installs it.
#
# It does NOT install uv for you. This repository's pitch is that its supply chain is short and its trust
# decisions are visible, and a build recipe that silently pipes a remote installer into a shell is the
# opposite of that. The command is printed; running it is yours.
#
# Shell rather than `[script]`, necessarily: a `[script]` guard for uv would run through uv.
# ---
# fail with instructions if uv is missing
[unix]
[group('toolchain')]
@require-uv:
	command -v uv >/dev/null 2>&1 || { \
	  echo "uv is not on PATH, and every Python recipe here runs through it."; \
	  echo "Install it with:  curl -LsSf https://astral.sh/uv/install.sh | sh"; \
	  echo "or see https://docs.astral.sh/uv/getting-started/installation/"; \
	  exit 1; }

# The same, in cmd. Each platform variant carries its own description because `just --list` only sees
# the comment above the variant it selects - without this the recipe lists blank on Windows.
# ---
# fail with instructions if uv is missing
[windows]
[group('toolchain')]
@require-uv:
	where uv >nul 2>&1 || (echo uv is not on PATH, and every Python recipe here runs through it. & echo Install it with:  irm https://astral.sh/uv/install.ps1 ^| iex & echo or see https://docs.astral.sh/uv/getting-started/installation/ & exit /b 1)

# Fetch only if it is not there. A stat, not a hash - this runs before every build, and `just
# fetch-engine --check` is the one that verifies.
# ---
# make sure the engine is on disk before anything tries to build against it
[unix]
[group('toolchain')]
@ensure-engine:
	test -f {{engine_path}} || just fetch-engine

# ---
# make sure the engine is on disk before anything tries to build against it
[windows]
[group('toolchain')]
@ensure-engine:
	if not exist {{engine_path}} just fetch-engine

# The formatter half of the same arrangement. `--check` verifies presence, `--force` re-installs over
# what is there, and the pin comes from `ols_*` at the top of this file so CI and a developer machine
# read one value - see the comment there for the drift that made this necessary.
# ---
# download the pinned odinfmt into ~/.odin-tools, verified against its SHA-256
[group('toolchain')]
fetch-odinfmt *args: require-uv
	{{py}} .github/scripts/fetch-odinfmt.py {{ols_tag}} {{ols_plat}} {{ols_sha256}} {{args}}

# A stat, not a hash: this gates every `format` and `format-check`, and the version is in the path, so
# the file being there is the pin being satisfied. `just fetch-odinfmt --force` is the repair.
# ---
# make sure the pinned odinfmt is installed before formatting with it
[unix]
[group('toolchain')]
@ensure-odinfmt:
	test -f "{{odinfmt_bin}}" || just fetch-odinfmt

# ---
# make sure the pinned odinfmt is installed before formatting with it
[windows]
[group('toolchain')]
@ensure-odinfmt:
	if not exist "{{odinfmt_bin}}" just fetch-odinfmt

# Every recipe that produces a binary depends on this. Odin does not create the output directory
# One line/call keeps the cost to one shell command
# ---
# ensure the build artifacts top level directory exists
[unix]
[group('toolchain')]
@mktarget_dirs:
	mkdir -p target/debug target/fast_debug target/release_debug target/release target/release_nochecks

# `if not exist` rather than swallowing md's "already exists" with `2>nul`, so a genuine failure still
# sets a non-zero exit. The loop var is a single `%d`, NOT the `%%d` that a .bat file would use for escaping
# ---
# ensure the build artifacts top level directory exists
[windows]
[group('toolchain')]
@mktarget_dirs:
	for %d in (debug fast_debug release_debug release release_nochecks) do @if not exist target\%d md target\%d || exit /b 1

# `-debug` implies `-o:none`, so this is the fastest to compile and the friendliest to step through.
# (-keep-executable so `example_rerun_debug` can skip recompiling)
# ---
# run with debug build
[group('examples')]
example_debug name="hello_window" *args: mktarget_dirs ensure-engine
	odin run examples/{{name}}.odin -file -debug -microarch:native -keep-executable -linker:{{linker}} -out:{{ target_path("debug", name + ".exe") }} {{args}}


# `-o:minimal` is one rung above the `-debug` default of `-o:none`: still quick to compile and mostly
# faithful to step through, but noticeably faster at runtime.
# (-keep-executable so `example_rerun_fast_debug` can skip recompiling)
# ---
# run with debug info and light optimizations
[group('examples')]
example_fast_debug name="hello_window" *args: mktarget_dirs ensure-engine
	odin run examples/{{name}}.odin -file -debug -o:minimal -microarch:native -keep-executable -linker:{{linker}} -out:{{ target_path("fast_debug", name + ".exe") }} {{args}}

# Release codegen with debug info retained: for profiling and for chasing bugs that only appear under
# optimization. Slowest to compile, and the debugger will jump around inlined/reordered code.
# (-keep-executable so `example_rerun_release_debug` can skip recompiling)
# ---
# run with full optimizations AND debug info
[group('examples')]
example_release_debug name="hello_window" *args: mktarget_dirs ensure-engine
	odin run examples/{{name}}.odin -file -debug -o:speed -microarch:native -keep-executable -linker:{{linker}} -out:{{ target_path("release_debug", name + ".exe") }} {{args}}

# run with optimizations (-keep-executable so `example_rerun_release` can skip recompiling)
[group('examples')]
example_release name="hello_window" *args: mktarget_dirs ensure-engine
	odin run examples/{{name}}.odin -file -o:speed -microarch:native -keep-executable -linker:{{linker}} -out:{{ target_path("release", name + ".exe") }} {{args}}

# `example_release` plus every runtime safety check compiled out: `-no-bounds-check` (slice/array indexing),
# `-disable-assert` (the built-in `assert`) and `-no-type-assert` (union/any type assertions). Those
# checks are what turn a memory-corrupting bug into a clean panic, so a fault here is undefined
# behaviour rather than a readable message - benchmark against `example_release` before adopting it, and
# keep a checked build in your test matrix. `-o:aggressive` exists too but Odin flags it as risky.
# (-keep-executable so `example_rerun_release_nochecks` can skip recompiling)
# ---
# run with optimizations and ALL runtime safety checks removed
[group('examples')]
example_release_nochecks name="hello_window" *args: mktarget_dirs ensure-engine
	odin run examples/{{name}}.odin -file -o:speed -no-bounds-check -disable-assert -no-type-assert -microarch:native -keep-executable -linker:{{linker}} -out:{{ target_path("release_nochecks", name + ".exe") }} {{args}}

# KIND is `address` (default, ASan: out-of-bounds and use-after-free), `memory` (reads of uninitialized
# memory) or `thread` (data races); only `address` is widely supported, the other two need a clang-ish
# toolchain. Built with `-debug` for file/line info, to its own output name so it does not clobber the
# plain debug binary.
#
# ON WINDOWS `address` CATCHES STACK ERRORS BUT NOT HEAP ERRORS - Odin allocates through `HeapAlloc`,
# which ASan does not intercept, so it never sees the allocation and a clean run there says nothing about
# your heap. (Probed one byte past a 16-byte allocation at +16, +24, +32, +64, +256: Linux reports
# `heap-buffer-overflow` from +24 on, Windows at none. +16 is in bounds either way - the allocator hands
# back more than asked for.) The `interception_win: unhandled instruction` line these builds print is the
# same limitation announcing itself. Chase a suspected heap bug on Linux, or with the tracking allocator
# (`-define:TRACKING_ALLOCATOR=backtrace`), which does not depend on ASan.
#
# Both sanitizer recipes deliberately omit `-linker:{{linker}}` - do not "fix" the inconsistency. A
# sanitizer has to interpose on the runtime and not every linker cooperates: `radlink` (this file's
# Windows default, and bundled with Odin, so it is what you get by accident) links an ASan binary that
# dies on startup with a bare `0xc000001d` illegal-instruction exception and no usable stack, while
# `-linker:default` runs it. Link speed is worth nothing on a diagnostic run anyway.
#
# Usage:  just sanitize   or   just sanitize thread -- --my-arg
# ---
# run a debug build under a sanitizer (address | memory | thread)
[group('test')]
sanitize name="hello_window" kind="address" *args: mktarget_dirs ensure-engine
	odin run examples/{{name}}.odin -file -debug -sanitize:{{kind}} -out:{{ target_path("debug", f"sanitize-{{kind}}-{{name}}.exe") }} {{args}}

# same sanitizer options as `sanitize`; see its notes for platform support and the linker note.
#
# LD_PRELOAD OF libstdc++, AND WHY IT IS NOT OPTIONAL HERE. Without it this recipe cannot finish against
# Sciter at all: the engine throws C++ exceptions in ordinary operation - loading a document with a
# `<script>`, `value_parse` on text that will not parse - and ASan dies on the first one with
#
#     AddressSanitizer: CHECK failed: asan_interceptors.cpp:463
#     "((__interception::real___cxa_throw)) != (0)" (0x0, 0x0)
#
# That is not a fault in the code under test. ASan intercepts `__cxa_throw` and finds the real one with
# `dlsym(RTLD_NEXT, ...)`; an Odin binary links no C++ runtime, and libsciter.so carries its own
# statically, so there is no next `__cxa_throw` to find and the interceptor holds a null. Preloading the
# system libstdc++ gives it one. Measured: 27/27 eval tests clean with the preload, hard failure on the
# first throw without it.
# ---
# run the tests under a sanitizer (address | memory | thread)
[script]
[group('test')]
test_sanitize name="eval" kind="address" *args: mktarget_dirs
	import os, re, subprocess, sys
	sys.path.insert(0, ".github/scripts")
	from justlib import run

	name, kind = "{{name}}", "{{kind}}"

	env = os.environ.copy()
	if sys.platform.startswith("linux"):
		# See the recipe comment: without a real `__cxa_throw` to find, ASan dies on the engine's first
		# C++ exception. `ldconfig -p` is the only portable way to locate the system libstdc++.
		try:
			cache = subprocess.run(["ldconfig", "-p"], capture_output=True, text=True).stdout
			hit = re.search(r"=> (\S*libstdc\+\+\.so\.6)", cache)
			if hit and os.path.isfile(hit.group(1)):
				env["LD_PRELOAD"] = hit.group(1)
		except FileNotFoundError:
			pass

	out = os.path.join("target", "debug", f"sanitize-{kind}-{name}-test.exe")
	run([
		"odin", "test", f"examples/{name}.odin", "-file", "-debug", f"-sanitize:{kind}",
		"-define:ODIN_TEST_THREADS=1", f"-out:{out}",
		*r"""{{args}}""".split(),
	], env=env)

# Odin has no build cache, so a plain `run` always rebuilds. Requires a prior `example_debug`/`run` build.
# ---
# re-run the last debug binary WITHOUT recompiling
[group('examples')]
example_rerun_debug name="hello_window" *args:
	{{ target_path("debug", name + ".exe") }} {{args}}


# re-run the last fast_debug binary without recompiling. Requires a prior `example_fast_debug` build.
[group('examples')]
example_rerun_fast_debug name="hello_window" *args:
	{{ target_path("fast_debug", name + ".exe") }} {{args}}

# re-run the last release_debug binary without recompiling. Requires a prior `example_release_debug` build.
[group('examples')]
example_rerun_release_debug name="hello_window" *args:
	{{ target_path("release_debug", name + ".exe") }} {{args}}

# re-run the last release binary without recompiling. Requires a prior `example_release` build.
[group('examples')]
example_rerun_release name="hello_window" *args:
	{{ target_path("release", name + ".exe") }} {{args}}

# re-run the last nochecks binary without recompiling. Requires a prior `example_release_nochecks` build.
[group('examples')]
example_rerun_release_nochecks name="hello_window" *args:
	{{ target_path("release_nochecks", name + ".exe") }} {{args}}

# hyperfine (https://github.com/sharkdp/hyperfine) times whole *processes*, and is installed separately.
# Over `example_rerun_release`'s binary rather than `just example_release`: Odin has no build cache, so timing the
# recipe would mostly time the compiler - build first. `-N` skips the shell hyperfine would otherwise
# spawn per run, at the cost that the command is split on whitespace rather than parsed: no pipes,
# redirects or quoted arguments containing spaces.
#
# **The example has to exit on its own**, which most of them do not: anything that opens a window runs
# `sciter_app.run()` until you close it, and hyperfine would sit there for `--warmup 3` plus every
# measured run waiting for a human. `api_map` is the default because it loads the engine, walks the
# function table and returns - the same reason it is what `api-map-verify` drives. `eval` and
# `leak_sweep` are the other two that terminate without a display.
#
# Process startup, engine load and teardown are most of what this measures - `api_map` is 18 ms here
# against a 25 MB libsciter. It times a program, not a procedure.
#
# **`/` here, not `target_path`.** Everything else in this file uses `target_path` because cmd.exe
# rejects a forward slash in command position, but under `-N` hyperfine does not run a shell at all - it
# spawns the program itself, and its lookup will not resolve `target\release\api_map.exe`, failing with
# "program not found" on a file that is plainly there. The forward-slash spelling runs on both. Measured;
# do not "fix" the inconsistency back.
#
# Usage:  just time_release                    time api_map's release binary
#         just time_release eval               ... a different example
#         just time_release api_map --flag=x   ... passing arguments to the program
# ---
# time an example's release binary end to end with hyperfine (needs a prior example_release)
[group('examples')]
time_release name="api_map" *args:
	hyperfine -N --warmup 3 "target/release/{{name}}.exe {{args}}"

# A/B two build profiles in one run - hyperfine prints the ratio between them, which is the number worth
# knowing about `-no-bounds-check`. Times both binaries, so needs a prior `example_release` AND
# `example_release_nochecks` of the same example.
# ---
# compare an example's release and nochecks binaries with hyperfine
[group('examples')]
time_profiles name="api_map" *args:
	hyperfine -N --warmup 3 "target/release/{{name}}.exe {{args}}" "target/release_nochecks/{{name}}.exe {{args}}"

# run all tests
alias test := example-tests

# Filtering is a `core:testing` define rather than a compiler flag - there is no `-test-name:`, and a
# stale spelling of one fails with `Unknown flag: 'test-name'` before anything builds. TEST_NAME takes a
# comma-separated list and the package prefix is optional, so `main.my_test`, `my_test` and
# `one,two` all work. The first argument says which example to look in:
#     just test1 eval test_value_array
# ---
# run one named test from one example (comma-separated for several)
[group('test')]
test1 example test_name *args: mktarget_dirs ensure-engine
	odin test examples/{{example}}.odin -file -debug -microarch:native -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES={{test_name}} -linker:{{linker}} -out:{{ target_path("debug", example + "_test.exe") }} {{args}}

# simple delete of all debug databases and executables in the target directory
[unix]
[group('toolchain')]
clean:
	rm -rf target .justcache
	just mktarget_dirs

# cmd's equivalent of `rm -rf` is `rmdir /s /q`. Guarded by `if exist` because rmdir prints "The
# system cannot find the file specified" and exits non-zero on a missing path, which would fail the
# recipe on an already-clean tree.
# ---
# simple delete of all debug databases and executables in the target directory
[windows]
[group('toolchain')]
clean:
	if exist target rmdir /s /q target
	if exist .justcache rmdir /s /q .justcache
	just mktarget_dirs

# It used to build `.`, which cannot work: the root package is `package sciter`, a library with no
# `main`, so every invocation died on `Undefined entry point procedure 'main'` before printing a single
# timing. Repointed at `examples/NAME.odin` like the rest of the build family, and to the same output
# path as `example_debug` so `just example_rerun_debug NAME` finds what this built.
# ---
# build an example with some verbose diagnostics
[group('examples')]
diagnose name="hello_window" *args: mktarget_dirs ensure-engine
	odin build examples/{{name}}.odin -file -debug -microarch:native -show-more-timings -show-debug-messages -show-timings -linker:{{linker}} -out:{{ target_path("debug", name + ".exe") }} {{args}}


# Cross platform: Sublime then offers them in every window. The `.sublime-project` file is
# project-local and intentionally NOT installed. Override the destination with the SUBLIME_USER_DIR
# env var if your setup is non-standard.
# ---
# install the editor snippets + build systems into Sublime Text's global `Packages/User` directory
[script]
[group('editor')]
install-sublime:
	import os, sys, shutil
	home = os.path.expanduser("~")
	override = os.environ.get("SUBLIME_USER_DIR")
	if override:
		candidates = [override]
	elif sys.platform == "win32":
		appdata = os.environ.get("APPDATA", os.path.join(home, "AppData", "Roaming"))
		candidates = [os.path.join(appdata, p, "Packages", "User") for p in ("Sublime Text", "Sublime Text 3")]
	elif sys.platform == "darwin":
		base = os.path.join(home, "Library", "Application Support")
		candidates = [os.path.join(base, p, "Packages", "User") for p in ("Sublime Text", "Sublime Text 3")]
	else:
		base = os.path.join(home, ".config")
		candidates = [os.path.join(base, p, "Packages", "User") for p in ("sublime-text", "sublime-text-3")]

	# prefer a candidate whose Sublime data dir (the `Packages` parent) already exists
	target = next((c for c in candidates if os.path.isdir(os.path.dirname(c))), None)
	if target is None:
		sys.exit(
			"could not find a Sublime Text Packages directory. Set SUBLIME_USER_DIR to your "
			"Packages/User folder and retry. Tried: " + ", ".join(candidates)
		)
	os.makedirs(target, exist_ok=True)
	for name in (
		"Odin-skeleton.sublime-snippet",
		"Just-Odin.sublime-snippet",
		"Just-Odin-lib.sublime-snippet",
		"Odin.sublime-build",
		"OdinJustTarget.sublime-build",
	):
		shutil.copy2(os.path.join(".sublime", name), os.path.join(target, name))
		print("installed " + name)
	print("-> " + target)


# Opening the project in Sublime then exposes project-local build variants (Tools -> Build System) with
# no global install. Seeds one working `just example` build plus commented-out examples to extend. Refuses
# if a build_systems entry already exists. (Excluded from the Just-Odin snippet because it contains
# literal `$file` / `$project_path` which would be parsed as snippet fields; still copied into new
# projects by `just new`.)
# ---
# add a `build_systems` stub to the project's .sublime-project
[script]
[group('editor')]
sublime-build-init:
	import glob, os, sys
	matches = glob.glob(os.path.join(".sublime", "*.sublime-project"))
	if not matches:
		sys.exit("no .sublime/*.sublime-project file found")
	if len(matches) > 1:
		sys.exit("multiple .sublime-project files found: " + ", ".join(matches))
	path = matches[0]
	with open(path, encoding="utf-8") as f:
		text = f.read()
	if "build_systems" in text:
		sys.exit(path + " already has a build_systems entry - edit it by hand")
	name = os.path.splitext(os.path.basename(path))[0]
	block = (
		'    "build_systems":\n'
		'    [\n'
		'        {\n'
		'            "name": "' + name + ' (just)",\n'
		'            "selector": "source.odin",\n'
		'            "working_dir": "$project_path/..",\n'
		'\n'
		'            // file_regex turns lines of build output into clickable error links. Odin reports\n'
		'            // diagnostics as `path(line:column) message`, so the four regex capture groups below\n'
		'            // map, in order, to (1) file path (2) line (3) column (4) message -- the order Sublime\n'
		'            // expects. A matched line becomes a link that jumps to that file/line/column; F4 and\n'
		'            // Shift+F4 step forward/back through the matches. The doubled backslashes are JSON\n'
		'            // string escaping: `\\\\(` in this file is the regex `\\(` (a literal open paren).\n'
		'            "file_regex": "^(.+)\\\\(([0-9]+):([0-9]+)\\\\) (.+)$",\n'
		'\n'
		'            "shell_cmd": "just example",\n'
		'\n'
		'            // uncomment / extend; each variant appears under Tools -> Build With... Sublime expands\n'
		'            // these build variables in shell_cmd / working_dir (full list:\n'
		'            // https://www.sublimetext.com/docs/build_systems.html#variables):\n'
		'            //   $file            full path of the current file,  e.g. /home/me/proj/src/main.odin\n'
		'            //   $file_path       directory of the current file (its package dir for Odin)\n'
		'            //   $file_base_name  current file name without extension,  e.g. main\n'
		'            //   $folder          first folder open in the side bar (the project root; no project file needed)\n'
		'            //   $project_path    directory containing this .sublime-project file\n'
		'            // "variants":\n'
		'            // [\n'
		'            //     { "name": "release",                "shell_cmd": "just example_release" },\n'
		'            //     { "name": "test",                   "shell_cmd": "just test" },\n'
		'            //     { "name": "lint",                   "shell_cmd": "just lint" },\n'
		'            //     { "name": "current file (run)",     "shell_cmd": "odin run \\"$file\\" -file -debug" },\n'
		'            //     { "name": "current package",        "shell_cmd": "odin build \\"$file_path\\" -debug" },\n'
		'            //     { "name": "current file -> target", "working_dir": "$folder", "shell_cmd": "odin build \\"$file\\" -file -out:target/debug/$file_base_name.exe -debug" },\n'
		'            // ],\n'
		'        },\n'
		'    ],\n'
	)
	idx = text.index("{") + 1
	text = text[:idx] + "\n" + block.rstrip("\n") + text[idx:]
	with open(path, "w", encoding="utf-8", newline="\n") as f:
		f.write(text)
	print("added build_systems stub to " + path)


# No `ols-config` recipe: the skeleton ships one to register an extra collection (the `xyz:` in
# `import "xyz:pkg"`), and this project has none. Everything here is the root package plus `sciter_app`,
# and the examples reach them by relative path because they live inside the repository - see
# docs/getting-started.md. The recipe sat unedited with its placeholder `xyz` / `XYZ_HOME` names, so it
# could only ever have written an ols.json pointing at nothing. Take the skeleton's `ols-config *pairs`
# if a collection is ever added.


# ---------------------------------------------------------------------------------------------------
# odin-sciter
#
# The root package here is `package sciter` - a generated library with no `main` - so the skeleton's
# `example_*` / `sanitize` / `test*` recipes have been repointed at `examples/NAME.odin`, which
# is where every `main` and every `@(test)` in this repository lives. They keep their build profiles and
# their names, and each takes an example name:
#
#     just example                     # hello_window, debug
#     just example_release dom_walk    # optimized
#     just example_rerun_debug events  # last debug build, no recompile
#     just sanitize eval               # under ASan
#     just test                        # every example's tests
#     just test_sanitize eval          # those tests under ASan
#
# `just example NAME` is the short spelling of `just example_debug NAME`. The skeleton's `run_*` /
# `rerun_*` names are gone: this project builds no application, so `just run` read as though it
# did. `run` and `rerun` were aliases and were dropped with them.
#
# One trap, and it is not optional: Sciter is single-threaded - every ISciterAPI call has to come from
# the thread that ran SCITER_APP_INIT - while Odin's test runner is parallel by default. Every test
# recipe below passes `-define:ODIN_TEST_THREADS=1`. Without it the engine's heap is corrupted rather
# than the tests failing cleanly, which presents as `malloc(): unaligned tcache chunk detected`.
# ---------------------------------------------------------------------------------------------------

# Path to a built odin-c-bindgen. Override with `just bindgen_bin=/path/to/bindgen.bin bindgen`.
#
# Two names, because the generator's own build does not agree with CI's. `bindgen.yml` builds it with
# `-out:bindgen.bin`, which is what this used to assume unconditionally - but odin-c-bindgen's README
# builds `bindgen.exe` on Windows, so a developer who followed upstream's instructions had a working
# generator that this file could not see, and got "not found" pointing at a path they had no reason to
# create. `bindgen.bin` first, since that is what CI produces and what the message below tells you to
# build; `bindgen{{exe_ext}}` second, since that is what you get by following upstream.
bindgen_dir := join(justfile_directory(), "..", "odin-c-bindgen")
bindgen_bin := env_var_or_default("ODIN_C_BINDGEN", if path_exists(join(bindgen_dir, "bindgen.bin")) == "true" { join(bindgen_dir, "bindgen.bin") } else { join(bindgen_dir, "bindgen" + exe_ext) })

# The generator's pinned commit. `bindgen.yml` regenerates with exactly this and asserts the result is
# byte-identical to the committed `sciter.odin`, which is what lets that file be treated as an artifact
# that happens to be tracked.
#
# **It used to live only in `bindgen.yml`**, so `just bindgen` here ran whatever the sibling checkout
# was at and the two could silently be different programs - the failure mode being a CI error saying
# `sciter.odin` had been hand-edited when it had not. Same shape as the odinfmt pin above, same fix:
# one value, read by both. odin-c-bindgen publishes no releases, so this is a commit rather than a tag
# and `require-bindgen-pin` can only verify it, not install it.
bindgen_commit := "12f4e7a"

# Regenerate sciter.odin from the vendored headers. Four steps, each explained in the file it runs:
#   1. src/flatten_headers.py  - concatenate the C ABI headers into one self-contained build/sciter.h,
#                                because bindgen only emits declarations found in the input file
#   2. bindgen                 - the actual generation, configured by bindgen.sjson
#   3. src/postprocess_bindings.py - rewrite `proc "c"` to `proc "system"` for 32-bit Windows
#   4. odin check, odinfmt, odin check again
#
# The odinfmt pass belongs to *this* recipe rather than to `just format` because sciter.odin is
# generated: bindgen's line breaking is not odinfmt's, so without it every regeneration lands a few
# thousand lines of formatting noise on top of whatever actually changed in the API. It runs only after
# the first check passes, so a generation that does not compile is not also reformatted - the diff you
# have to read stays a diff about the generator. The second check confirms the formatter broke nothing.
# ---
# regenerate the bindings from external/sciter/include
[group('build')]
bindgen: require-bindgen-pin ensure-odinfmt
	{{py}} src/flatten_headers.py
	{{bindgen_bin}} .
	{{py}} src/postprocess_bindings.py sciter.odin
	odin check . -no-entry-point
	{{odinfmt_bin}} -w sciter.odin
	odin check . -no-entry-point

# Both halves of "regenerating here produces what CI asserts" are version pins, and this checks the one
# that cannot be fetched. `BINDGEN_PIN_SKIP=1` opts out; a generator whose commit cannot be read warns
# rather than failing, because `$ODIN_C_BINDGEN` may legitimately point outside a git checkout.
# ---
# fail if the local odin-c-bindgen is not at the commit bindgen.yml verifies against
[group('toolchain')]
@require-bindgen-pin: require-uv
	{{py}} .github/scripts/check-bindgen-pin.py "{{bindgen_bin}}" {{bindgen_commit}}

# **`check` type checks and does not build**, which is roughly twice as fast: measured per example,
# check 164-183 ms against build 318-345 ms, and 1.2 s against 2.4 s across the whole set in parallel on
# 24 cores. The gap widens on fewer cores, where the parallelism stops hiding it.
#
# What building buys is the *link*, and that is `build-examples` in ci.just: `odin check` cannot see an
# undefined symbol. A narrow win - two of the thirty examples have a `foreign import` - but a real one,
# and CI runs both.
#
# `-no-entry-point` throughout: the two library packages have no `main`, and the examples do but do not
# need it entered to type check.
#
# `docs/snippets` is every Odin code block in the guides, wrapped just enough to compile. Documentation
# drifts silently, so it is checked like anything else.
# ---
# type check both packages, the guides' snippets and every example
[script]
[group('gates')]
check: ensure-engine
	import sys
	sys.path.insert(0, ".github/scripts")
	from justlib import host_x11_skip, odin_check_cmds, parallel, try_run

	# The X11-only pair does not build off Linux - see justlib. Without this skip the Windows CI job can
	# never pass, which is most of what that job is.
	skip = host_x11_skip()
	cmds = odin_check_cmds(skip)

	# `try_run` rather than `run`: report every file that does not type check, not just the first. A
	# compiler error is usually one edit's worth of fallout across several files, and finding them one
	# run at a time is the slow way to do it.
	codes = parallel(cmds, try_run)
	bad = [c for c, code in zip(cmds, codes) if code]

	if bad:
		print()
		print(f"FAILED to type check ({len(bad)}):")
		for c in bad:
			print(f"    {' '.join(c)}")
		raise SystemExit(1)

	tail = f" (skipped, X11-only: {' '.join(skip)})" if skip else ""
	all_ = "" if skip else "all "
	# One command per entry in `PACKAGES` plus one per example, so subtracting the former leaves the
	# example count. Derived rather than written as a literal, because `PACKAGES` has grown twice.
	from justlib import PACKAGES

	n = len(cmds) - len(PACKAGES)
	print(f"ok: both packages, the doc snippets, tools/checks and {all_}{n} examples type check{tail}")

# Writes to stdout; redirect it to keep a copy.
#
# `sciter_app` by default because that is the API: the root `package sciter` is bindgen's output, so
# `odin doc .` prints the raw C surface - 189 function-table slots under their SCFN names, with the
# header banners the generator carries across. Useful when you are checking what a wrapper wraps, and
# not what you want when the question is "what can I call".
#
# Deliberately NOT `-all-packages`, which documents every package the project *uses*, all of `core:`
# included, rather than this one.
#   just doc              # the wrapper API
#   just doc .            # the generated bindings
# ---
# print a package's documentation (sciter_app, or `.` for the generated bindings)
[group('build')]
doc pkg="sciter_app" *args:
	odin doc {{pkg}} {{args}}


# Examples are single files that import the root package, so each builds with `-file`. Run from the
# repository root so the loader finds lib/<platform>/ - see `load` in src/prelude.odin for the full
# search order, or set SCITER_LIB.
# ---
# Regenerates examples/assets/app.pak from examples/assets/app/, for the `archive` example.
#
# The .pak is COMMITTED, so `just example archive` works from a clean checkout with no SDK and no
# network - it is 2 KB. Run this only after editing something under examples/assets/app/.
#
# packfolder is an SDK tool and is not vendored (see external/sciter/VENDORED.md), so point SCITER_SDK
# at a checkout:
#
#     SCITER_SDK=~/dev/sciter-js-sdk just pack
#
# `-binary` rather than one of packfolder's source generators (-csharp/-dlang/-go, or its default C
# array): Odin's `#load` embeds a plain file at compile time, which keeps a hex dump out of git and
# puts the bytes in the executable's read-only data - which is exactly what SciterOpenArchive needs,
# since it indexes the blob in place rather than copying it.
# ---
# rebuild examples/assets/app.pak from examples/assets/app/
[script]
[group('build')]
pack:
	import sys
	sys.path.insert(0, ".github/scripts")
	from justlib import run, sdk_tool

	run([sdk_tool("packfolder"), "examples/assets/app", "examples/assets/app.pak", "-binary"])

# `examples/extension.odin` is not an application - it is a Sciter *native extension*, a shared library
# the engine loads in response to script's `sciter.loadLibrary("odin-ext")`. It exports exactly one
# symbol, `SciterLibraryInit`, and has no `main`, so it is built rather than run.
#
# The name matters: `loadLibrary("odin-ext")` looks for `odin-ext.so` (no `lib` prefix) beside the
# host executable, so `-out:` sets it exactly.
# ---
# `just extension` builds examples/extension.odin as odin-ext.so; `just extension sqlite_extension
# odin-sqlite` builds the SQLite binding. The library name is what script's `loadLibrary` is given.
# ---
# build a native extension -> target/debug/<lib>.so
[group('build')]
extension name="extension" lib="odin-ext": mktarget_dirs
	odin build examples/{{name}}.odin -file -build-mode:shared -out:{{ target_path("debug", lib + shared_ext) }}

# build the SQLite extension and run it under the SDK's scapp
[script]
[group('build')]
extension-sqlite: (extension "sqlite_extension" "odin-sqlite")
	import sys
	sys.path.insert(0, ".github/scripts")
	from justlib import scapp_app

	scapp_app("sqlite-app", "odin-sqlite", "examples/assets/sqlite/index.htm")

# Assembles a throwaway app folder - scapp, the extension and its document together, which is the
# layout `loadLibrary` requires - and runs it. Nothing in the SDK checkout is modified.
#
# scapp is the Sciter engine packaged as a standalone executable; it is NOT vendored here (see
# external/sciter/VENDORED.md), so point SCITER_SDK at a checkout:
#
#     SCITER_SDK=~/dev/sciter-js-sdk just extension-run
# ---
# build the extension and run it under the SDK's scapp
[script]
[group('build')]
extension-run: extension
	import sys
	sys.path.insert(0, ".github/scripts")
	from justlib import scapp_app

	scapp_app("extension-app", "odin-ext", "examples/assets/extension/index.htm")

# Runs the `@(test)` procs that live inside the examples. `ODIN_TEST_THREADS=1` for the reason in this
# section's header. Tests that need a window skip themselves when there is no DISPLAY / WAYLAND_DISPLAY.
#
# `-keep-executable` because `odin test` deletes the binary after running it, and `example-tests`'
# `trace()` re-runs that binary under lldb/gdb to get a backtrace out of a test that aborted without a
# message. Without this flag the file is always gone by the time `trace` looks, its `os.path.exists`
# guard is always false, and the whole debugger path is unreachable on every platform - which is what it
# was. Measured: run this recipe and `target/debug/<name>_test.exe` does not exist afterwards.
#
# The one-line description goes last, under the `# ---`: `just --list` shows the *last* comment line
# above a recipe, so a paragraph written after it becomes the description and reads as a fragment.
# ---
# run the tests inside one example, e.g. `just example-test eval`
[group('test')]
example-test name="eval" *args: mktarget_dirs ensure-engine
	odin test examples/{{name}}.odin -file -debug -keep-executable -define:ODIN_TEST_THREADS=1 -linker:{{linker}} -out:{{ target_path("debug", name + "_test.exe") }} {{args}}

# Runs every example's tests and keeps going, rather than stopping at the first failure: one example
# faulting is a fact about that example, and finding out which of the other twenty-three also fault
# should not cost twenty-three more pushes. The summary at the end is the report; the exit code is
# still non-zero if anything failed.
#
# EXAMPLE_TEST_TIMEOUT (seconds, default none) puts a ceiling on each example. A windowed test on a
# display that cannot render can block on the message pump forever, and without this the whole run
# hangs until CI's own six-hour limit rather than telling you which example stopped. 124 in the
# summary is that timeout firing; anything else is the example's own exit code. The budget covers
# compilation too - `odin test` builds before it runs.
# ---
# run every example's tests
[script]
[group('test')]
example-tests: ensure-engine
	import glob, os, sys
	sys.path.insert(0, ".github/scripts")
	import re, shutil
	from justlib import X11_ONLY, is_windows, run_with_timeout

	limit = int(os.environ.get("EXAMPLE_TEST_TIMEOUT", "0"))

	# **Naming the test is half of it; the other half is where it died.** A test that aborts with no
	# message leaves nothing to read. `ODIN_TEST_NAMES` is a *compile-time* define, so the binary the
	# failing run just built is already filtered to the one test - re-running it under a debugger costs
	# no rebuild and prints the stack. Best-effort: no debugger changes nothing about the exit code, this
	# only ever adds evidence.
	def trace(name, test, limit):
		exe = os.path.join("target", "debug", f"{name}_test.exe")
		# Windows is excluded rather than left to `shutil.which`: this machine turned out to have an
		# MSYS gdb on PATH, which took the multi-word `-ex` arguments below as filenames ("apply: No
		# such file or directory") and printed four lines of nothing at every failure. POSIX passes argv
		# through untouched, so the same strings are fine on Linux and macOS.
		if is_windows() or not os.path.exists(exe):
			return
		if shutil.which("lldb"):
			cmd = ["lldb", "-b", "-o", "run", "-o", "thread backtrace all", "-o", "quit", "--", exe]
		elif shutil.which("gdb"):
			cmd = ["gdb", "-batch", "-ex", "run", "-ex", "thread apply all bt 25", exe]
		else:
			return
		print(f"    --- where {test} died", flush=True)
		run_with_timeout(cmd, limit)

	# The name of the proc `@(test)` decorates. `\s*` spans the newline between them, and the inner group
	# steps over any further attributes stacked in between - without it, a test written
	# `@(test)` / `@(private)` / `name ::` is one the bisect below never re-runs, which is the one place
	# a missing name costs something. Requiring a declaration to follow is also what keeps prose *about*
	# `@(test)` from counting, which the test counter was doing until this pattern was shared with it.
	# That counter is now `tools/checks/stats.odin` and asks the parser instead - a `Value_Decl` with a
	# `test` attribute - so the two no longer have to agree about a regex.
	TEST_NAME = re.compile(r"@\(test\)\s*(?:@\([^)]*\)\s*)*([A-Za-z_][A-Za-z0-9_]*)\s*::")
	bisect = []

	# The X11-only pair does not compile off Linux at all - see justlib - so running their tests there
	# reports a build failure per example and says nothing about this platform.
	skip = () if sys.platform.startswith("linux") else X11_ONLY

	# **A skip is a pass in the runner's accounting, and that is how a green suite overstates itself.**
	# `Finished N tests` counts a test that returned early after printing "skipping" exactly the same as
	# one that exercised the engine, so on macOS - where every windowed test skips under `ODIN_TEST`, see
	# docs/MACOS-CHECKLIST.md - the total says roughly three times more than it means. Counting the skip
	# lines is what turns that from a paragraph somebody has to remember into a number in the output.
	#
	# One line per skipped test, which holds while every skip site prints exactly once, and they all go
	# through the same `if !have_display()` shape. It is a tally rather than a gate: the honest count
	# differs per platform and per machine, so a threshold here would be a number to silence rather than
	# a fact to read.
	SKIPPED = re.compile(r"^.*\bskipping\b.*$", re.M | re.I)
	FINISHED = re.compile(r"^Finished (\d+) tests?", re.M)

	failed = []
	tally = []
	for f in sorted(glob.glob("examples/*.odin")):
		name = os.path.basename(f)[:-5]
		if name in skip:
			continue
		with open(f, encoding="utf-8", errors="replace") as fh:
			if "@(test)" not in fh.read():
				continue
		print(f"--- {name}", flush=True)
		code, out = run_with_timeout(["just", "example-test", name], limit, capture=True)
		tally.append((name, sum(int(n) for n in FINISHED.findall(out)), len(SKIPPED.findall(out))))
		if code != 0:
			failed.append(f"{name}(exit {code})")
			bisect.append(name)

	# **A test that kills the process takes the report with it.** `odin test` prints results as it goes,
	# but stdout is a pipe here, so it is block-buffered and an abort discards whatever had not been
	# flushed - which is why a SIGABRT reports `exit 134` against a *file* and names no test. Measured on
	# macOS, where sqlite_extension aborted with nothing in the log but the runner's start-up lines. So
	# re-run the casualties one test per process: the one that dies is the one named on the line above
	# the corpse. Costs a compile per test, on a run that has already failed.
	for name in bisect:
		names = TEST_NAME.findall(open(f"examples/{name}.odin", encoding="utf-8", errors="replace").read())
		print()
		print(f"--- {name}: {len(names)} tests, one process each", flush=True)
		for test in names:
			code = run_with_timeout(
				["just", "example-test", name, f"-define:ODIN_TEST_NAMES={test}"], limit
			)
			print(f"    {'ok  ' if code == 0 else f'EXIT {code}'}  {test}", flush=True)
			if code != 0:
				trace(name, test, limit)

	print()
	ran = sum(n for _, n, _ in tally)
	skipped = sum(s for _, _, s in tally)

	# The static total, so the two numbers can be compared rather than each read alone. They differ by
	# whatever this platform did not build - the X11-only pair off Linux - and a difference with no
	# named cause is the thing worth noticing.
	declared = files = 0
	for f in sorted(glob.glob("examples/*.odin")):
		n = len(TEST_NAME.findall(open(f, encoding="utf-8", errors="replace").read()))
		declared, files = declared + n, files + (1 if n else 0)

	print(f"{ran} of {declared} test procedures ran, in {len(tally)} of {files} example files")
	print(f"    {skipped} of the {ran} skipped themselves")
	if skipped:
		for name, n, s in tally:
			if s:
				print(f"      {name:<22} {n:>3} tests, {s:>3} skipped")
		print(f"    {ran - skipped} actually exercised something")
		print("    a skip is a pass to the runner - `just windowed-examples` is how the windowed ones run")
	if skip:
		print(f"(skipped, X11-only: {' '.join(skip)})")
	if failed:
		print(f"FAILED: {' '.join(failed)}")
		raise SystemExit(1)
	print("ok: every example's tests passed")

# `example` is the name the docs use and `example_debug` is the name the build-profile family uses,
# and they
# were two recipes writing the *same* `target/debug/NAME.exe` with different flags. That is worse than
# duplication: `example` lacked `-keep-executable`, and `odin run` deletes the executable afterwards by
# default - so the workflow README documents, `just example NAME` then `just example_rerun_debug NAME`,
# could not work, and whichever of the two you ran last silently decided what the re-run found.
# One recipe, two names.
# ---
# build and run an example, e.g. `just example hello_window`
alias example := example_debug


# Launches the SDK's inspector - the DevTools-style DOM tree, style viewer, console and debugger. It is
# a separate application that attaches over a socket, so it is run *alongside* your app, not by it:
#
#     just example inspector          # terminal one - the app, with .ENABLE_DEBUG
#     SCITER_SDK=~/dev/sciter-js-sdk just inspector   # terminal two - attaches to it
#
# The app side needs both halves or the window stays invisible to this tool, and neither can be turned
# on after the window exists: `set_debug_mode()` before the window, and `.ENABLE_DEBUG` in its flags.
# See examples/inspector.odin and docs/html-css-js.md.
#
# The inspector is an SDK tool and is not vendored here (see external/sciter/VENDORED.md), so point
# SCITER_SDK at a checkout.
# ---
# run the SDK's inspector, to attach to a window built with .ENABLE_DEBUG
[script]
[group('examples')]
inspector:
	import sys
	sys.path.insert(0, ".github/scripts")
	from justlib import run, sdk_tool

	insp = sdk_tool("inspector")
	print(f"running {insp}")
	print("(the app must already be running, built with set_debug_mode() and .ENABLE_DEBUG)")
	run([insp])
