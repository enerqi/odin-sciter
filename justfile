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
	odinfmt -w spike


# `-vet-tabs` is the only compiler-side enforcement of .editorconfig's `indent_style = tab`; it is not
# implied by `-strict-style`, so without it a space-indented file lints clean. Nothing in the Odin
# toolchain checks line endings - those are held in place by .gitattributes and odinfmt.json instead.
# Accepts extra args like `-show-timings` as needed.
# ---
# lint checks for style and potential bugs. No code generation
lint *args:
	odin check . -vet -vet-cast -strict-style -vet-tabs -no-entry-point {{args}}


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
# ---
# run the tests under a sanitizer (address | memory | thread)
test_sanitize name="eval" kind="address" *args: mktarget_dirs
	odin test examples/{{name}}.odin -file -debug -sanitize:{{kind}} -define:ODIN_TEST_THREADS=1 -out:{{ target_path("debug", f"sanitize-{{kind}}-{{name}}-test.exe") }} {{args}}

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
test1 example test_name *args: mktarget_dirs
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

# Regenerate sciter.odin from the vendored headers. Three steps, each explained in the file it runs:
#   1. src/flatten_headers.py  - concatenate the C ABI headers into one self-contained build/sciter.h,
#                                because bindgen only emits declarations found in the input file
#   2. bindgen                 - the actual generation, configured by bindgen.sjson
#   3. src/postprocess_bindings.py - rewrite `proc "c"` to `proc "system"` for 32-bit Windows
# ---
# regenerate the bindings from external/sciter/include
bindgen:
	uv run --no-project -p 3.14 python src/flatten_headers.py
	{{bindgen_bin}} .
	uv run --no-project -p 3.14 python src/postprocess_bindings.py sciter.odin
	odin check . -no-entry-point

# `-no-entry-point` for the two library packages, which have no `main`. The examples do have one, and
# are checked by building them - `odin check` on a `-file` target is not meaningfully cheaper.
# ---
# type check both packages and build every example
check: mktarget_dirs
	#!/usr/bin/env bash
	set -euo pipefail
	odin check . -no-entry-point
	odin check sciter_app -no-entry-point
	for f in examples/*.odin; do
	    if [ "$f" = "examples/extension.odin" ]; then
	        # Not an application: a native extension, so it has no `main` and builds as a shared library.
	        odin build "$f" -file -build-mode:shared -out:{{ target_path("debug", "odin-ext" + shared_ext) }}
	    else
	        odin build "$f" -file -out:{{ target_path("debug", "check.exe") }}
	    fi
	done
	echo "ok: both packages type check, all $(ls examples/*.odin | wc -l) examples build"

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
pack:
	#!/usr/bin/env bash
	set -euo pipefail
	sdk="${SCITER_SDK:-}"
	if [ -z "$sdk" ]; then
	    echo "SCITER_SDK is not set - point it at a sciter-js-sdk checkout." >&2
	    echo "packfolder is not vendored here; see external/sciter/VENDORED.md." >&2
	    exit 1
	fi
	packfolder="$sdk/bin/{{ packfolder_platform }}/packfolder"
	if [ ! -x "$packfolder" ]; then
	    echo "no packfolder at $packfolder" >&2
	    exit 1
	fi
	"$packfolder" examples/assets/app examples/assets/app.pak -binary

# `examples/extension.odin` is not an application - it is a Sciter *native extension*, a shared library
# the engine loads in response to script's `sciter.loadLibrary("odin-ext")`. It exports exactly one
# symbol, `SciterLibraryInit`, and has no `main`, so it is built rather than run.
#
# The name matters: `loadLibrary("odin-ext")` looks for `odin-ext.so` (no `lib` prefix) beside the
# host executable, so `-out:` sets it exactly.
# ---
# build the native extension -> target/debug/odin-ext.so
extension: mktarget_dirs
	odin build examples/extension.odin -file -build-mode:shared -out:{{ target_path("debug", "odin-ext" + shared_ext) }}

# Assembles a throwaway app folder - scapp, the extension and its document together, which is the
# layout `loadLibrary` requires - and runs it. Nothing in the SDK checkout is modified.
#
# scapp is the Sciter engine packaged as a standalone executable; it is NOT vendored here (see
# external/sciter/VENDORED.md), so point SCITER_SDK at a checkout:
#
#     SCITER_SDK=~/dev/sciter-js-sdk just extension-run
# ---
# build the extension and run it under the SDK's scapp
extension-run: extension
	#!/usr/bin/env bash
	set -euo pipefail
	sdk="${SCITER_SDK:-}"
	if [ -z "$sdk" ]; then
	    echo "SCITER_SDK is not set - point it at a sciter-js-sdk checkout." >&2
	    echo "scapp is not vendored here; see external/sciter/VENDORED.md." >&2
	    exit 1
	fi
	scapp="$sdk/bin/{{ scapp_platform }}/scapp"
	if [ ! -x "$scapp" ]; then
	    echo "no scapp at $scapp" >&2
	    exit 1
	fi
	app="target/debug/extension-app"
	rm -rf "$app" && mkdir -p "$app"
	cp "$scapp" "$app/"
	cp {{ target_path("debug", "odin-ext" + shared_ext) }} "$app/"
	cp examples/assets/extension/index.htm "$app/"
	echo "running $app/scapp"
	cd "$app" && ./scapp index.htm

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

# run every example's tests
example-tests:
	#!/usr/bin/env bash
	set -euo pipefail
	for f in examples/*.odin; do
	    name=$(basename "$f" .odin)
	    if grep -q '@(test)' "$f"; then
	        echo "--- $name"
	        just example-test "$name"
	    fi
	done

# build and run an example, e.g. `just example hello_window`
example name="hello_window" *args: mktarget_dirs
	odin run examples/{{name}}.odin -file -debug -linker:{{linker}} -out:{{ target_path("debug", name + ".exe") }} {{args}}
