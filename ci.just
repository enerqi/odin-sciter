# Recipes that exist for CI and for the checks worth running by hand after an engine change -
# gates, audits and coverage measurements rather than anything in an edit-compile loop. They are
# here to keep the justfile proper down to what you type while working; `just` merges an imported
# file into one namespace, so `just parity` and `just --list` behave exactly as they did when these
# lived in the justfile, and `linker`, `py`, `target_path`, `mktarget_dirs` and `ensure-engine`
# resolve from there.
#
# Everything below is called by `.github/workflows/ci.yml` except where a comment says otherwise.

# The gate for `just format`. **Idempotence is the whole precondition** - a formatter that rewrites a
# file on every run can never be a gate, because the gate then fails on a clean checkout. It holds here:
# `just format` exits 0, and a second run against an already-formatted tree changes nothing.
#
# `odinfmt <file>` with no `-w` prints the formatted source to stdout, so this compares that against
# what is on disk and writes nothing. Bytes, not text: reading in binary keeps a line-ending difference
# visible instead of letting Python's newline translation hide one on Windows.
# ---
# fail if anything is not odinfmt-clean, without writing to it
[script]
format-check: ensure-odinfmt
	import subprocess, sys
	sys.path.insert(0, ".github/scripts")
	from justlib import format_sources, parallel

	odinfmt = r"{{odinfmt_bin}}"

	def unformatted(path):
		want = subprocess.run([odinfmt, path], capture_output=True).stdout
		with open(path, "rb") as fh:
			have = fh.read()
		return path if want != have else None

	files = format_sources()
	bad = [p for p in parallel(files, unformatted) if p]

	if bad:
		print(f"not odinfmt-clean ({len(bad)} of {len(files)}):")
		for p in bad:
			print(f"    {p}")
		print()
		print("Run `just format`.")
		raise SystemExit(1)
	print(f"ok: all {len(files)} Odin files are odinfmt-clean")


# Every example built and *linked*, which is the only part `just check` cannot do for you.
#
# One output path per example, and the loop run in parallel. Both halves matter: linking every example
# over a single `check.exe` serialises the slowest non-test step in CI onto one core, and leaves the
# *previous* example's binary in place when one fails, so the artifact says nothing about which.
# ---
# build and link every example - the coverage `check` cannot give you
[script]
build-examples: mktarget_dirs ensure-engine
	import os, subprocess, sys
	sys.path.insert(0, ".github/scripts")
	from justlib import EXTENSIONS, example_sources, host_x11_skip, parallel, shared_ext

	out = os.path.join("target", "debug", "check")
	os.makedirs(out, exist_ok=True)

	skip = host_x11_skip()
	targets = example_sources(skip)

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
	print(f"ok: {all_}{len(targets)} examples build and link{tail}")


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
	{{py}} .github/scripts/check-ownership.py


# Rule 1's static half. `guard_engine_thread` is the runtime check and it only sees calls that reach it,
# so this asserts that they all do: `engine()` is the package's only route to the function table, and a
# bare `sciter.api()` anywhere else is a call the guard cannot see. That is not hypothetical - it is how
# the guard shipped, watching 124 of 199 call sites while `eval`, `call` and every `Value` constructor
# went unwatched. No engine and no display needed.
# ---
# assert the thread-affinity rule in docs/rules.md section 1: every engine call goes through engine()
check-affinity:
	{{py}} .github/scripts/check-affinity.py


# The other half of the same question. `api-map-verify` proves the slots the bindings expect are the
# slots the engine has - it catches a reordered or removed one. It cannot catch an *added* one: a newer
# SDK regenerates into `sciter.odin` as fields nothing wraps, and coverage degrades one upgrade at a
# time with no signal. This measures the headers against `sciter_app` and diffs the unwrapped set
# against docs/parity-baseline.txt, so a new slot is a one-line diff during the upgrade rather than a
# surprise afterwards. No engine and no display needed - it reads headers and .odin files.
# ---
# C-API coverage: which SCFN slots sciter_app reaches, checked against the committed baseline
parity *args:
	{{py}} .github/scripts/parity.py {{args}}


# The counts the documentation quotes about itself - examples, tests, wrapper procs, and how many of
# those a test reaches. `--check` fails when README.md or docs/PLAN.md disagree with the measurement,
# which is how they came to claim 337 tests against an actual 366. Same counting rule as `parity`:
# `\.name\b`, not `\.name(`, because a wrapper is as often stored or forwarded as called.
# ---
# suite and coverage counts; `just stats --check` asserts the docs still agree
stats *args:
	{{py}} .github/scripts/stats.py {{args}}


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
# `integration` and `native_child` are excluded by decision, not because they failed: they are raw Xlib,
# and `vendor:x11/xlib` declares nothing off Linux. The Windows equivalents would be different programs,
# not the same program compiled elsewhere.
#
# `single_binary` is a conditional third. It `#load`s the target platform's engine, and `#load` is a
# compile-time read of a real file, so checking it for `windows_amd64` needs `lib/windows/x64/sciter.dll`
# on this disk - and `just fetch-engine` installs only the host's, so a CI runner has two of the three
# missing. Skipped per target with a line saying so, checked when the file is there. Nothing is lost:
# all three platform jobs run `just check`, which builds it natively against the engine they fetched.
# ---
# type check both packages, the snippets and every portable example for windows and macOS
[script]
cross-check: ensure-engine
	import os, sys
	sys.path.insert(0, ".github/scripts")
	from justlib import X11_ONLY, odin_check_cmds, parallel, try_run

	# What `single_binary` #loads for each target, and therefore what has to be on disk to check it.
	engine_for = {
		"windows_amd64": "lib/windows/x64/sciter.dll",
		"darwin_amd64": "lib/macosx/libsciter.dylib",
		"darwin_arm64": "lib/macosx/libsciter.dylib",
	}

	targets = ("windows_amd64", "darwin_amd64", "darwin_arm64")

	# `X11_ONLY` unconditionally here, unlike `check`'s host-dependent skip: these targets are Windows
	# and macOS whatever machine the recipe runs on, and `vendor:x11/xlib` declares nothing for either.
	jobs = []
	for target in targets:
		skip = set(X11_ONLY)
		engine = engine_for[target]
		if not os.path.exists(engine):
			skip.add("single_binary")
			print(f"{target}: single_binary skipped, it #loads {engine} and that is not on disk")
		jobs += [(target, c) for c in odin_check_cmds(skip, target)]

	# One flat parallel pass over all three targets rather than three sequential loops. This was ~93
	# `odin check` invocations run one at a time; the compiler releases the GIL for the whole of each,
	# so they thread. `try_run` for the same reason as in `check`: a target that fails should not hide
	# what the other two would have said, which is three pushes to find out otherwise.
	codes = parallel([c for _, c in jobs], try_run)
	bad = [(t, c) for (t, c), code in zip(jobs, codes) if code]

	if bad:
		print()
		print(f"FAILED to type check ({len(bad)}):")
		for t, c in bad:
			print(f"    {t}: {' '.join(c)}")
		raise SystemExit(1)

	print(f"ok: both packages, the doc snippets and every portable example type check for {', '.join(targets)}")
