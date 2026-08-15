# `cmd.exe` for one reason: it starts in ~9ms. just launches a shell per recipe line, so startup is a
# fixed tax on every build. Bare `<shell> exit` under hyperfine: cmd ~9ms, `nu -c` ~41ms (the original
# default here), `powershell -NoLogo -NoProfile -Command` ~143ms (which replaced nu). Per recipe line
# that was ~178ms under PowerShell against ~45ms under cmd - so `just rerun`, whose entire purpose is
# skipping the compile, spent ~178ms of shell to launch a binary that prints one line.
#
# cmd also wins the portability argument that put PowerShell here over nu: it is on every Windows,
# needs no install, and has no profile to make a recipe unreproducible. The cost is that it is a poor
# language for a multi-line recipe - which does not bite, because every Windows body below is a single
# command and anything with logic uses `[script]`.
set windows-shell := ["cmd.exe", "/c"]
set shell := ["bash", "-c"]
set unstable  # [script] feature - https://github.com/casey/just/issues/1479
set lazy

# `python` alone is not a reliable cross-platform lookup: scoop (Windows) installs whatever version was
# last `scoop install`ed under the bare name `python`, with no version pin, and a bare `python3`/`python`
# on Linux is whatever the distro shipped. `uv run -p 3.14 python` sidesteps both - uv resolves (and
# downloads if missing) the newest 3.14 patch it knows of, the same on every platform, so uv becomes the
# one tool these recipes depend on instead of a system python. `--no-project`: without it, `uv run` walks
# up from cwd looking for a pyproject.toml/uv.toml to treat as the project root - none exists above this
# repo today, but if one ever did (e.g. a stray python project two directories up), these recipes would
# silently start syncing/using *that* project's venv and pinned version instead of the one below.
# `--no-project` disables that discovery so the version here is the only one that applies. Recipes opt in
# with the bare `[script]` attribute (no interpreter argument) to pick this up.
set script-interpreter := ["uv", "run", "--no-project", "-p", "3.14", "python"]

# Set by the newest just feature used below - currently user-defined functions (1.49), for
# `target_path`. Older features it also needs: `join()` 1.37, f-strings 1.44, `set lazy` 1.47.
# Without this an old just reports a plain syntax error at the offending line, which reads like a
# corrupt justfile rather than an out-of-date tool. Keep the README and `odin-skel doctor` in step.
set minimum-version := "1.49.0"

main_name := "main.exe"

# Shared-library extension, for `just extension`. Sciter's loadLibrary() takes a name without one.
shared_ext := if os() == "windows" { ".dll" } else if os() == "macos" { ".dylib" } else { ".so" }

# Where packfolder lives inside an SDK checkout, per platform (note: no x64 subfolder).
packfolder_platform := if os() == "windows" { "windows" } else if os() == "macos" { "macosx" } else { "linux" }

# Where scapp lives inside an SDK checkout, per platform.
scapp_platform := if os() == "windows" { "windows/x64" } else if os() == "macos" { "macosx" } else { "linux/x64" }

# Where the inspector lives inside an SDK checkout. It does NOT follow `scapp_platform`: on macOS the
# inspector ships as an .app bundle, so the real executable sits under Contents/MacOS rather than next
# to scapp.
inspector_rel := if os() == "windows" { "windows/x64/inspector.exe" } else if os() == "macos" { "macosx/inspector.app/Contents/MacOS/inspector" } else { "linux/x64/inspector" }

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

# Suffix on the SDK's own tools. They are `packfolder`/`scapp` everywhere except Windows, where they
# are `packfolder.exe`/`scapp.exe` - which is what `just pack` and `just extension-run` open.
exe_ext := if os() == "windows" { ".exe" } else { "" }
test_main_name := "test-main.exe"

# `join`, not the `/` operator: `/` always emits a forward slash, and cmd.exe rejects a forward-slash
# path in *command* position ("'target' is not recognized") even quoted. Odin takes either in an
# `-out:` argument, but the `rerun_*` recipes invoke the binary directly, so they need the native
# separator `join` gives. bash needs no `./` prefix - a path containing a slash is already a path.
target_path(dir, name) := join("target", dir, name)

# Which linker Odin hands the object files to. `odin build -linker:` accepts exactly four values:
#
#   default   let Odin choose - MSVC `link.exe` on Windows. The portable answer, and what every
#             platform used before this line existed.
#   lld       LLVM's linker. Windows and Linux. NOT available on a stock macOS: Odin drives the
#             link through clang, and Apple's clang ships no lld, so it fails with
#             "clang: error: invalid linker name in argument '-fuse-ld=lld'" unless you have
#             installed LLVM yourself. Note this is clang rejecting it, not Odin - `-linker:` takes
#             the value on every platform, so unlike mold there is no "not supported on this
#             platform" message to tell you up front.
#   radlink   RAD Debugger's linker. Windows only, and it ships *with* the Odin toolchain, so it
#             needs no install - which is why it is the default here. Odin has no build cache and
#             relinks on every `just run`, so the link step is a cost you pay on each iteration.
#   mold      Linux only, and NOT bundled - `apt install mold` (or equivalent) first.
#
# When the default is the better pick: neither radlink nor mold is an *incremental* linker, while
# MSVC `link.exe` is. Combined with `-use-separate-modules` (and `-lto`, which implies it), an
# incremental relink of one changed module can beat a full link that is individually faster. That
# combination is not the default shape of an Odin build - single-module builds have little for LTO
# to chew on, and statically linked external C libraries do not get LTO regardless - so it is worth
# measuring on your own project rather than assuming either way.
#
# `-lto` is also a hard conflict rather than a preference: on Windows it *requires* `-linker:lld`
# and exits 1 with "-lto:thin on Windows requires -linker:lld" if anything else is pinned. Use the
# env var below to get out of the way of it:
#
#     ODIN_LINKER=lld just run_release -lto:thin
#
# Odin rejects a linker its platform does not support rather than quietly falling back: asking for
# mold on Windows exits 1 with "'mold' linker is not supported on this platform" and produces no
# binary. That is the behaviour you want from a per-machine setting, so nothing here second-guesses
# it.
#
# The default below is what `odin-skel new --linker=<value>` rewrites. The env var overrides it for
# a single command, without editing this file - for the LTO case above, or for a machine that has
# mold when the project default does not assume it:
#
#     ODIN_LINKER=lld just run
#
# It is an env var rather than a recipe argument because `odin` errors on a repeated flag
# ("Previous flag set: 'linker'"), so passing `-linker:` through a recipe's `*args` would collide
# with the one added below.
linker := env_var_or_default("ODIN_LINKER", if os() == "windows" { "radlink" } else { "default" })

# SKELETON: name your extra collection (the `xyz:` prefix in `import "xyz:pkg"`) and where it lives.
# collection_path is read from an env var so the absolute path stays out of git; rename both to suit.
collection_name := "xyz"
collection_path := env_var_or_default("XYZ_HOME", "")

# Explicit paths rather than `odinfmt -w .`, because src/prelude.odin is deliberately not a standalone
# Odin file - it has no `package` line, since bindgen pastes it into sciter.odin under that file's own
# one (see `imports_file` in bindgen.sjson). odinfmt cannot parse it and fails the whole run.
# ---
# odinfmt every odin file in the project
format:
	odinfmt -w sciter.odin
	odinfmt -w sciter_app
	odinfmt -w examples
	odinfmt -w docs/snippets
	odinfmt -w spike


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
lint *args: ensure-engine
	import glob, os, sys
	sys.path.insert(0, ".github/scripts")
	from justlib import VET, X11_ONLY, run

	args = r"""{{args}}""".split()

	run(["odin", "check", ".", *VET, *args])
	run(["odin", "check", "sciter_app", *VET, *args])

	# The examples are 23k of the repository's ~34k lines, and they used to be excluded here - which
	# meant the vet flags covered the third of the code least likely to be read closely. They pass now;
	# the whole cleanup was 25 findings, all unused imports, unused locals and shadowed `err`s.
	#
	# `-no-entry-point` for all of them: `extension.odin` and `sqlite_extension.odin` are native
	# extensions built as shared libraries and have no `main`, and the flag is harmless for the rest.
	# The X11-only pair does not compile off Linux at all - see justlib - so there is nothing for the vet
	# flags to say about it there.
	skip = () if sys.platform.startswith("linux") else X11_ONLY
	examples = [f for f in sorted(glob.glob("examples/*.odin"))
	            if os.path.basename(f)[:-5] not in skip]
	for f in examples:
		run(["odin", "check", f, "-file", *VET, *args])

	tail = f" (skipped, X11-only: {' '.join(skip)})" if skip else ""
	all_ = "" if skip else "all "
	print(f"ok: both library packages and {all_}{len(examples)} examples pass -vet{tail}")


# The engine, fetched instead of vendored - see `docs/UPGRADING.md` on the repository-size decision.
#
# Today `lib/` is committed, so this is a no-op on a fresh clone and the recipe exists to make the
# switch a one-line change rather than a project. From the next engine version the binary stops being
# committed, and then this is what a checkout needs before it can build - which is why every entry point
# below depends on `ensure-engine` rather than leaving it to a README step nobody reads.
#
# **`python3` rather than the `[script]` interpreter at the top of this file.** `[script]` runs through
# `uv`, which a CI runner does not have: the first version of this recipe failed on the Linux job with
# `No such file or directory (os error 2)` before it downloaded anything. `check-ownership` uses plain
# `python3` for the same reason - the uv interpreter is for recipes that can assume a developer machine,
# and anything CI or a first build depends on cannot.
#
# `--check` verifies what is already on disk, which is the useful mode in CI and after an upgrade.
# `--force` re-fetches over a file that is already there.
# ---
# download the pinned engine into lib/, verified against its SHA-256
[unix]
fetch-engine *args:
	python3 .github/scripts/fetch-engine.py {{engine_tag}} {{engine_sha256}} {{engine_rel}} {{args}}

# `python` rather than `python3`: the launcher on Windows is `python.exe` (or the `py` launcher), and
# `python3` exists only if someone made it. GitHub's windows-2022 image ships Python on PATH.
[windows]
fetch-engine *args:
	python .github\scripts\fetch-engine.py {{engine_tag}} {{engine_sha256}} {{engine_rel}} {{args}}

# Fetch only if it is not there. A stat, not a hash - this runs before every build, and `just
# fetch-engine --check` is the one that verifies.
# ---
# make sure the engine is on disk before anything tries to build against it
[unix]
@ensure-engine:
	test -f {{engine_path}} || just fetch-engine

[windows]
@ensure-engine:
	if not exist {{engine_path}} just fetch-engine

# Every `run_*`, `test*` and `diagnose` recipe depends on this, so it runs before every build - which
# makes its cost a tax on every iteration, and worth keeping small. odin does not create the output
# directory (the linker fails with LNK1104), so this cannot just be dropped.
#
# The directories are created all at once rather than one per line because just starts a new shell
# per recipe line, and on Windows the shell launch dwarfs the work: hyperfine puts `powershell.exe
# -NoProfile -Command exit` at ~149ms against ~40ms for the actual directory creation. Note the
# corollary - scoping this to only the one directory a given recipe needs saves ~5ms of that 40 and
# is not worth the complexity; the shell launch is the whole cost.
# ---
# ensure the build artifacts top level directory exists
[unix]
@mktarget_dirs:
	mkdir -p target/debug target/fast_debug target/release_debug target/release target/release_nochecks

# `if not exist` rather than swallowing md's "already exists" with `2>nul`, so a genuine failure still
# sets a non-zero exit.
#
# The loop variable is a single `%d`, NOT the `%%d` a .bat file would use: doubling is escaping for
# batch *files*, and `cmd /c` takes a command *line*. Getting it wrong is not subtle - cmd aborts the
# recipe with "%%d was unexpected at this time".
# ---
# ensure the build artifacts top level directory exists
[windows]
@mktarget_dirs:
	for %d in (debug fast_debug release_debug release release_nochecks) do @if not exist target\%d md target\%d || exit /b 1

# `-debug` implies `-o:none`, so this is the fastest to compile and the friendliest to step through.
# (-keep-executable so `rerun_debug` can skip recompiling)
# ---
# run with debug build
run_debug name="hello_window" *args: mktarget_dirs
	odin run examples/{{name}}.odin -file -debug -microarch:native -keep-executable -linker:{{linker}} -out:{{ target_path("debug", name + ".exe") }} {{args}}

alias run := run_debug

# `-o:minimal` is one rung above the `-debug` default of `-o:none`: still quick to compile and mostly
# faithful to step through, but noticeably faster at runtime.
# (-keep-executable so `rerun_fast_debug` can skip recompiling)
# ---
# run with debug info and light optimizations
run_fast_debug name="hello_window" *args: mktarget_dirs
	odin run examples/{{name}}.odin -file -debug -o:minimal -microarch:native -keep-executable -linker:{{linker}} -out:{{ target_path("fast_debug", name + ".exe") }} {{args}}

# Release codegen with debug info retained: for profiling and for chasing bugs that only appear under
# optimization. Slowest to compile, and the debugger will jump around inlined/reordered code.
# (-keep-executable so `rerun_release_debug` can skip recompiling)
# ---
# run with full optimizations AND debug info
run_release_debug name="hello_window" *args: mktarget_dirs
	odin run examples/{{name}}.odin -file -debug -o:speed -microarch:native -keep-executable -linker:{{linker}} -out:{{ target_path("release_debug", name + ".exe") }} {{args}}

# run with optimizations (-keep-executable so `rerun_release` can skip recompiling)
run_release name="hello_window" *args: mktarget_dirs
	odin run examples/{{name}}.odin -file -o:speed -microarch:native -keep-executable -linker:{{linker}} -out:{{ target_path("release", name + ".exe") }} {{args}}

# `run_release` plus every runtime safety check compiled out: `-no-bounds-check` (slice/array indexing),
# `-disable-assert` (the built-in `assert`) and `-no-type-assert` (union/any type assertions). Those
# checks are what turn a memory-corrupting bug into a clean panic, so a fault here is undefined
# behaviour rather than a readable message - benchmark against `run_release` before adopting it, and
# keep a checked build in your test matrix. `-o:aggressive` exists too but Odin flags it as risky.
# (-keep-executable so `rerun_release_nochecks` can skip recompiling)
# ---
# run with optimizations and ALL runtime safety checks removed
run_release_nochecks name="hello_window" *args: mktarget_dirs
	odin run examples/{{name}}.odin -file -o:speed -no-bounds-check -disable-assert -no-type-assert -microarch:native -keep-executable -linker:{{linker}} -out:{{ target_path("release_nochecks", name + ".exe") }} {{args}}

# `address` (ASan) catches out-of-bounds accesses and use-after-free; `memory` catches reads of
# uninitialized memory; `thread` catches data races. Only `address` is widely supported - `memory` and
# `thread` need a clang-ish toolchain and are unavailable on some platforms (notably Windows/MSVC).
# Built with `-debug` so reports carry file/line info, and to its own output name so it does not clobber
# the plain debug binary.
#
# KNOW THIS BEFORE TRUSTING A CLEAN RUN: on Windows, `address` does not detect heap errors at all.
# Odin's allocator calls `HeapAlloc` there (base/runtime/heap_allocator_windows.odin) instead of
# `malloc`, and ASan's redzones come from intercepting the allocator - so it never sees the allocation
# and has nothing to guard. Measured by writing one byte past a 16-byte `make([]u8, 16)` at +16, +24,
# +32, +64 and +256: Linux reports `heap-buffer-overflow` from +24 on, Windows reports nothing at any
# offset, and at +32 the process died with no ASan output whatsoever. Stack overflows are caught on
# both, because that instrumentation is compiler-inserted rather than interception-based.
#
# (+16 is not a bug: the allocator hands back more than the 16 bytes asked for, so a write there is
# still in bounds. Any probe of your own needs to clear that slack before it means anything.)
#
# The practical reading: on Windows a clean `just sanitize` rules out stack bugs, not heap bugs. Chase
# a suspected heap bug on Linux, or with the tracking allocator (`-define:TRACKING_ALLOCATOR=backtrace`)
# which does not depend on ASan. The `interception_win: unhandled instruction` line these builds print
# is this same limitation announcing itself, not a fault in your code.
#
# Both sanitizer recipes deliberately omit `-linker:{{linker}}`: link speed is worth nothing on a
# diagnostic run, and pinning it here actively broke things. A sanitizer has to interpose on the
# runtime, which not every linker cooperates with - `radlink` (this file's Windows default, and bundled
# with Odin, so it is what you get by accident) links an ASan test binary that dies on startup with a
# bare `0xc000001d` illegal-instruction exception and no usable stack, while `-linker:default` runs it.
# Letting Odin pick keeps these recipes a signal about your code rather than about the linker.
# Usage:  just sanitize   or   just sanitize thread -- --my-arg
# ---
# run a debug build under a sanitizer (address | memory | thread)
sanitize name="hello_window" kind="address" *args: mktarget_dirs
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

# Odin has no build cache, so a plain `run` always rebuilds. Requires a prior `run_debug`/`run` build.
# ---
# re-run the last debug binary WITHOUT recompiling
rerun_debug name="hello_window" *args:
	{{ target_path("debug", name + ".exe") }} {{args}}

alias rerun := rerun_debug

# re-run the last fast_debug binary without recompiling. Requires a prior `run_fast_debug` build.
rerun_fast_debug name="hello_window" *args:
	{{ target_path("fast_debug", name + ".exe") }} {{args}}

# re-run the last release_debug binary without recompiling. Requires a prior `run_release_debug` build.
rerun_release_debug name="hello_window" *args:
	{{ target_path("release_debug", name + ".exe") }} {{args}}

# re-run the last release binary without recompiling. Requires a prior `run_release` build.
rerun_release name="hello_window" *args:
	{{ target_path("release", name + ".exe") }} {{args}}

# re-run the last nochecks binary without recompiling. Requires a prior `run_release_nochecks` build.
rerun_release_nochecks name="hello_window" *args:
	{{ target_path("release_nochecks", name + ".exe") }} {{args}}

# run all tests
alias test := example-tests

# Filtering is a `core:testing` define rather than a compiler flag - there is no `-test-name:`, and a
# stale spelling of one fails with `Unknown flag: 'test-name'` before anything builds. TEST_NAME takes a
# comma-separated list and the package prefix is optional, so `main.my_test`, `my_test` and
# `one,two` all work. The first argument says which example to look in:
#     just test1 eval test_value_array
# ---
# run one named test from one example (comma-separated for several)
test1 example test_name *args: mktarget_dirs ensure-engine
	odin test examples/{{example}}.odin -file -debug -microarch:native -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES={{test_name}} -linker:{{linker}} -out:{{ target_path("debug", example + "_test.exe") }} {{args}}

# simple delete of all debug databases and executables in the target directory
[unix]
clean:
	rm -rf target
	just mktarget_dirs

# cmd's equivalent of `rm -rf` is `rmdir /s /q`. Guarded by `if exist` because rmdir prints "The
# system cannot find the file specified" and exits non-zero on a missing path, which would fail the
# recipe on an already-clean tree.
# ---
# simple delete of all debug databases and executables in the target directory
[windows]
clean:
	if exist target rmdir /s /q target
	just mktarget_dirs

# build with some verbose diagnostics
diagnose *args: mktarget_dirs
	odin build . -debug -microarch:native -show-more-timings -show-debug-messages -show-timings -linker:{{linker}} -out:{{ target_path("debug", main_name) }} {{args}}


# Cross platform: Sublime then offers them in every window. The `.sublime-project` file is
# project-local and intentionally NOT installed. Override the destination with the SUBLIME_USER_DIR
# env var if your setup is non-standard.
# ---
# install the editor snippets + build systems into Sublime Text's global `Packages/User` directory
[script]
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
		"Odin.sublime-build",
		"OdinJustTarget.sublime-build",
	):
		shutil.copy2(os.path.join(".sublime", name), os.path.join(target, name))
		print("installed " + name)
	print("-> " + target)


# Opening the project in Sublime then exposes project-local build variants (Tools -> Build System) with
# no global install. Seeds one working `just run` build plus commented-out examples to extend. Refuses
# if a build_systems entry already exists. (Excluded from the Just-Odin snippet because it contains
# literal `$file` / `$project_path` which would be parsed as snippet fields; still copied into new
# projects by `just new`.)
# ---
# add a `build_systems` stub to the project's .sublime-project
[script]
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
		'            "shell_cmd": "just run",\n'
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
		'            //     { "name": "release",                "shell_cmd": "just run_release" },\n'
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


# Resolves an extra collection import (`import "{{collection_name}}:pkg"`). Only needed when you pull
# packages from a directory outside this project. ols.json holds a machine-specific absolute path, so
# gitignore it and regenerate after cloning or when the path changes:
#     XYZ_HOME=/path/to/collection just ols-config
# FILL IN: rename collection_name / collection_path (and the XYZ_HOME env var) above to match your collection.
# ---
# SKELETON: (re)generate ols.json so the Odin language server resolves an extra collection
[script]
ols-config:
	import json, sys
	path = r"{{collection_path}}"
	if not path:
		sys.exit("set the collection path env var first, e.g. XYZ_HOME=/path/to/collection just ols-config")
	config = {
		"$schema": "https://raw.githubusercontent.com/DanielGavin/ols/master/misc/ols.schema.json",
		"collections": [{"name": "{{collection_name}}", "path": path}],
	}
	with open("ols.json", "w") as f:
		f.write(json.dumps(config, indent=4) + "\n")
	print("wrote ols.json -> {{collection_name}} collection at " + path)


# ---------------------------------------------------------------------------------------------------
# odin-sciter
#
# The root package here is `package sciter` - a generated library with no `main` - so the skeleton's
# `run_*` / `rerun_*` / `sanitize` / `test*` recipes have been repointed at `examples/NAME.odin`, which
# is where every `main` and every `@(test)` in this repository lives. They keep their build profiles and
# their names, and each takes an example name:
#
#     just run                     # hello_window, debug
#     just run_release dom_walk    # optimized
#     just rerun events            # last debug build, no recompile
#     just sanitize eval           # under ASan
#     just test                    # every example's tests
#     just test_sanitize eval      # those tests under ASan
#
# `just example NAME` remains the short spelling of `just run NAME`.
#
# One trap, and it is not optional: Sciter is single-threaded - every ISciterAPI call has to come from
# the thread that ran SCITER_APP_INIT - while Odin's test runner is parallel by default. Every test
# recipe below passes `-define:ODIN_TEST_THREADS=1`. Without it the engine's heap is corrupted rather
# than the tests failing cleanly, which presents as `malloc(): unaligned tcache chunk detected`.
# ---------------------------------------------------------------------------------------------------

# Path to a built odin-c-bindgen. Override with `just bindgen_bin=/path/to/bindgen.bin bindgen`.
bindgen_bin := env_var_or_default("ODIN_C_BINDGEN", join(justfile_directory(), "..", "odin-c-bindgen", "bindgen.bin"))

# Regenerate sciter.odin from the vendored headers. Four steps, each explained in the file it runs:
#   1. src/flatten_headers.py  - concatenate the C ABI headers into one self-contained build/sciter.h,
#                                because bindgen only emits declarations found in the input file
#   2. bindgen                 - the actual generation, configured by bindgen.sjson
#   3. src/postprocess_bindings.py - rewrite `proc "c"` to `proc "system"` for 32-bit Windows
#   4. odin check, odinfmt, odin check again
#
# The formatting pass runs only after the first check passes, so a generation that produced something
# that does not compile is not also reformatted - the diff you have to read to find out why stays a
# diff about the generator. The second check is one second and confirms the formatter did not break
# what the generator got right.
#
# It is part of *this* recipe rather than left to `just format` because sciter.odin is generated:
# bindgen's own line breaking is not odinfmt's, so without this every regeneration lands a few thousand
# lines of formatting noise on top of whatever actually changed in the API, and `just format` then
# quietly "changes" a file nobody edited.
# ---
# regenerate the bindings from external/sciter/include
bindgen:
	uv run --no-project -p 3.14 python src/flatten_headers.py
	{{bindgen_bin}} .
	uv run --no-project -p 3.14 python src/postprocess_bindings.py sciter.odin
	odin check . -no-entry-point
	odinfmt -w sciter.odin
	odin check . -no-entry-point

# `-no-entry-point` for the two library packages, which have no `main`. The examples do have one, and
# are checked by building them - `odin check` on a `-file` target is not meaningfully cheaper.
#
# `docs/snippets` is every Odin code block in the guides, wrapped just enough to compile. Documentation
# drifts silently, so it is checked like anything else.
# ---
# type check both packages and the guides' snippets, and build every example
[script]
check: mktarget_dirs ensure-engine
	import glob, os, subprocess, sys
	sys.path.insert(0, ".github/scripts")
	from justlib import EXTENSIONS, X11_ONLY, parallel, run, shared_ext

	run(["odin", "check", ".", "-no-entry-point"])
	run(["odin", "check", "sciter_app", "-no-entry-point"])
	run(["odin", "check", "docs/snippets", "-no-entry-point"])

	# One output path per example, and the loop run in parallel. Both halves matter: every example used
	# to link over a single `check.exe`, which serialised the slowest non-test step in CI onto one core
	# and left the *previous* example's binary in place when one failed, so the artifact said nothing
	# about which. Building rather than `odin check`ing is deliberate - single_binary.odin has a `when`
	# guarded `#panic` that only fires at build time, and linking is what proves an example is shippable.
	out = os.path.join("target", "debug", "check")
	os.makedirs(out, exist_ok=True)

	# The X11-only pair does not build off Linux - see justlib. Without this skip the Windows CI job can
	# never pass `just check`, which is most of what that job is.
	skip = () if sys.platform.startswith("linux") else X11_ONLY
	targets = [f for f in sorted(glob.glob("examples/*.odin"))
	           if os.path.basename(f)[:-5] not in skip]

	def build_one(f):
		name = os.path.basename(f)[:-5]
		if name in EXTENSIONS:
			cmd = ["odin", "build", f, "-file", "-build-mode:shared",
			       f"-out:{os.path.join(out, name + shared_ext())}"]
		else:
			cmd = ["odin", "build", f, "-file", f"-out:{os.path.join(out, name + '.exe')}"]
		print(" ".join(cmd), flush=True)
		return subprocess.run(cmd).returncode

	if any(parallel(targets, build_one)):
		raise SystemExit(1)

	tail = f" (skipped, X11-only: {' '.join(skip)})" if skip else ""
	all_ = "" if skip else "all "
	print(f"ok: both packages and the doc snippets type check, {all_}{len(targets)} examples build{tail}")

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
extension name="extension" lib="odin-ext": mktarget_dirs
	odin build examples/{{name}}.odin -file -build-mode:shared -out:{{ target_path("debug", lib + shared_ext) }}

# build the SQLite extension and run it under the SDK's scapp
[script]
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
extension-run: extension
	import sys
	sys.path.insert(0, ".github/scripts")
	from justlib import scapp_app

	scapp_app("extension-app", "odin-ext", "examples/assets/extension/index.htm")

# Run the `@(test)` procs that live inside the examples.
#
# ODIN_TEST_THREADS=1 is not optional: Sciter is single-threaded - every ISciterAPI call has to come
# from the thread that ran SCITER_APP_INIT - and Odin's test runner is parallel by default. Sharing one
# engine across test threads corrupts its heap rather than failing cleanly.
#
# Tests that need a window skip themselves when there is no DISPLAY / WAYLAND_DISPLAY.
# ---
# run the tests inside one example, e.g. `just example-test eval`
example-test name="eval" *args: mktarget_dirs
	odin test examples/{{name}}.odin -file -define:ODIN_TEST_THREADS=1 -linker:{{linker}} -out:{{ target_path("debug", name + "_test.exe") }} {{args}}

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
example-tests: ensure-engine
	import glob, os, sys
	sys.path.insert(0, ".github/scripts")
	from justlib import X11_ONLY, run_with_timeout

	limit = int(os.environ.get("EXAMPLE_TEST_TIMEOUT", "0"))

	# The X11-only pair does not compile off Linux at all - see justlib - so running their tests there
	# reports a build failure per example and says nothing about this platform.
	skip = () if sys.platform.startswith("linux") else X11_ONLY

	failed = []
	for f in sorted(glob.glob("examples/*.odin")):
		name = os.path.basename(f)[:-5]
		if name in skip:
			continue
		with open(f, encoding="utf-8", errors="replace") as fh:
			if "@(test)" not in fh.read():
				continue
		print(f"--- {name}", flush=True)
		code = run_with_timeout(["just", "example-test", name], limit)
		if code != 0:
			failed.append(f"{name}(exit {code})")

	print()
	if skip:
		print(f"(skipped, X11-only: {' '.join(skip)})")
	if failed:
		print(f"FAILED: {' '.join(failed)}")
		raise SystemExit(1)
	print("ok: every example's tests passed")

# build and run an example, e.g. `just example hello_window`
example name="hello_window" *args: mktarget_dirs ensure-engine
	odin run examples/{{name}}.odin -file -debug -linker:{{linker}} -out:{{ target_path("debug", name + ".exe") }} {{args}}

# `just example api_map` prints the table and leaves the judging to a human, which is right for a
# diagnostic and wrong for a gate: docs/UPGRADING.md calls the slot check "the step the whole procedure
# exists for", and a step whose pass/fail lives in someone's eyes cannot run in CI. This pipes the
# output through .github/scripts/check-api-map.py, which applies the rules the example's header states
# - 189 slots, ISciterAPI version 10, every non-null slot resolving to its own name plus `Imp`, and the
# platform's known null list unchanged. Run it after any engine bump, and edit the script's expectations
# as the record of what the new engine changed.
# ---
# run api_map and assert its table (slots, version, symbols, null list)
[script]
api-map-verify: mktarget_dirs
	import subprocess, sys

	# The two halves are run and joined here rather than with a `|`, so this needs no shell at all and
	# behaves the same under cmd.exe as under sh.
	table = subprocess.run(["just", "example", "api_map"], capture_output=True, text=True)
	if table.returncode != 0:
		sys.stderr.write(table.stderr)
		raise SystemExit(table.returncode)

	check = subprocess.run(
		[sys.executable, ".github/scripts/check-api-map.py"], input=table.stdout, text=True
	)
	raise SystemExit(check.returncode)


# ---
# exercise the resource-owning paths and fail if anything is still held by the engine at exit
#
# Needs -debug: sciter_app/tracking.odin compiles to nothing without it, and the sweep says so rather
# than passing vacuously. Not part of `example-tests` because it is a program, not a test file - see the
# header of examples/leak_sweep.odin for why the check cannot live in a test binary.
leak-check: mktarget_dirs ensure-engine
	odin build examples/leak_sweep.odin -file -debug -out:{{ target_path("debug", "leak_sweep.exe") }}
	{{ target_path("debug", "leak_sweep.exe") }}


# ---
# assert the ownership rule in docs/rules.md section 4: takes an allocator => yours, otherwise borrowed
check-ownership:
	uv run --no-project -p 3.14 python .github/scripts/check-ownership.py


# The other half of the same question. `api-map-verify` proves the slots the bindings expect are the
# slots the engine has - it catches a reordered or removed one. It cannot catch an *added* one: a newer
# SDK regenerates into `sciter.odin` as fields nothing wraps, and coverage degrades one upgrade at a
# time with no signal. This measures the headers against `sciter_app` and diffs the unwrapped set
# against docs/parity-baseline.txt, so a new slot is a one-line diff during the upgrade rather than a
# surprise afterwards. No engine and no display needed - it reads headers and .odin files.
# ---
# C-API coverage: which SCFN slots sciter_app reaches, checked against the committed baseline
parity *args:
	uv run --no-project -p 3.14 python .github/scripts/parity.py {{args}}


# The counts the documentation quotes about itself - examples, tests, wrapper procs, and how many of
# those a test reaches. `--check` fails when README.md or docs/PLAN.md disagree with the measurement,
# which is how they came to claim 337 tests against an actual 366. Same counting rule as `parity`:
# `\.name\b`, not `\.name(`, because a wrapper is as often stored or forwarded as called.
# ---
# suite and coverage counts; `just stats --check` asserts the docs still agree
stats *args:
	uv run --no-project -p 3.14 python .github/scripts/stats.py {{args}}


# The precondition every windowed test has and none of them states. A machine with no working EGL/GLES
# cannot create a Sciter window, and the engine's failure path faults rather than returning - so the
# suite reports twenty-odd identical segfaults inside `create_window` and takes the full
# EXAMPLE_TEST_TIMEOUT per example to do it. This asks the question once, in seconds, and prints the
# renderer diagnosis when the answer is no. Read the script's header before running it: an `SW_MAIN`
# window mode-sets the X display to its own size, so this belongs under Xvfb or Xephyr, not on your
# desktop session.
#
# `[linux]` and `[macos]` rather than one `[unix]` recipe, because the two scripts share only their
# contract - build `hello_window`, run it under a short timeout, exit 124 means the window lived. The
# evidence they print when the answer is no has nothing in common: gdb/ldd/EGL ICDs/xdpyinfo on Linux,
# lldb/otool/codesign/lipo on macOS. One script with a platform switch would be two scripts in a
# trench coat.
# ---
# [under Xvfb only] can the engine create a window on this machine?
[linux]
window-canary: mktarget_dirs
	.github/scripts/window-canary.sh

# ---
# can the engine create a window on this machine?
[macos]
window-canary: mktarget_dirs
	.github/scripts/macos-canary.sh

# The cheap half of a port, and the half that rots silently: nothing here builds for Windows or macOS
# day to day, so an example that stops type checking there is invisible until someone has the machine.
#
# **`darwin_arm64` is in the list because that is what CI's macOS runner is.** `macos-14` and later are
# Apple silicon, so checking only `darwin_amd64` would leave the architecture the mac job actually
# builds on unchecked - and the vendored dylib is universal, so both slices are real targets rather
# than one being theoretical. Three targets is still seconds; the engine is never loaded here.
#
# Two examples are excluded, for a stated reason rather than because they failed:
#
#   integration, native_child  raw Xlib. They are the two halves of "a Sciter view and a native window
#                              in each other's frame", and on Linux that means X11 - `vendor:x11/xlib`
#                              declares nothing off Linux. The Windows equivalents would be different
#                              programs, not the same program compiled elsewhere.
#
# `single_binary` used to be a third, because it `#load`s the engine and macOS was the platform whose
# binary was not vendored. It is vendored now, its `when` covers both Darwin architectures, and so it
# is checked here like everything else.
# ---
# type check both packages, the snippets and every portable example for windows and macOS
[script]
cross-check: ensure-engine
	import glob, os, sys
	sys.path.insert(0, ".github/scripts")
	from justlib import X11_ONLY, run

	targets = ("windows_amd64", "darwin_amd64", "darwin_arm64")
	for target in targets:
		skip = set(X11_ONLY)
		print(f"--- {target}")
		run(["odin", "check", ".", "-no-entry-point", f"-target:{target}"])
		run(["odin", "check", "sciter_app", "-no-entry-point", f"-target:{target}"])
		run(["odin", "check", "docs/snippets", "-no-entry-point", f"-target:{target}"])
		for f in sorted(glob.glob("examples/*.odin")):
			if os.path.basename(f)[:-5] in skip:
				continue
			run(["odin", "check", f, "-file", "-no-entry-point", f"-target:{target}"])
	print(f"ok: both packages, the doc snippets and every portable example type check for {', '.join(targets)}")

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
inspector:
	import sys
	sys.path.insert(0, ".github/scripts")
	from justlib import run, sdk_tool

	insp = sdk_tool("inspector")
	print(f"running {insp}")
	print("(the app must already be running, built with set_debug_mode() and .ENABLE_DEBUG)")
	run([insp])
