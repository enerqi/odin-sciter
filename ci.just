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


# Needs -debug: sciter_app/tracking.odin compiles to nothing without it, and the sweep says so rather
# than passing vacuously. Not part of `example-tests` because it is a program, not a test file - see the
# header of examples/leak_sweep.odin for why the check cannot live in a test binary.
# ---
# exercise the resource-owning paths and fail if anything is still held by the engine at exit
leak-check: mktarget_dirs ensure-engine
	odin build examples/leak_sweep.odin -file -debug -out:{{ target_path("debug", "leak_sweep.exe") }}
	{{ target_path("debug", "leak_sweep.exe") }}


# ---
# assert the ownership rule in docs/rules.md section 4: takes an allocator => yours, otherwise borrowed
check-ownership:
	{{py}} .github/scripts/check-ownership.py


# `stats --check` asserts a test reaches every exported procedure; this asserts a *reader* can find one.
# The gap it closed was not a scattering: api.md is one section per source file and three files had no
# section at all - `scoped.odin`, `value_scope.odin` and `tracking.odin`, which is the whole
# leak-prevention surface and the whole debug ledger, 340 of 402 procedures mentioned. It wants the
# literal name, so a family covered by `retain_*` does not count - a reader cannot search for a
# wildcard either. Source and one markdown file; no engine, no display.
# ---
# assert docs/api.md mentions every exported procedure of sciter_app
check-api-coverage:
	{{py}} .github/scripts/check-api-coverage.py


# The listings inside `//` doc comments are the one kind of Odin in this tree that nothing compiles -
# `just check` covers the packages and `docs/snippets`, and a comment fragment has no declarations to
# type check against. Three of them passed an `Owned_Element` where a borrowed `Element` was wanted,
# on the most-copied DOM idiom in the library, and one of the three had a *correct* compiled twin in
# `snippets.odin` - so the guide and its checked copy had drifted. This checks the one thing about a
# fragment that can be checked without a compiler. `--self-test` runs it against that listing.
# ---
# assert the owned/borrowed split in the listings inside doc comments and guides
check-doc-ownership:
	{{py}} .github/scripts/check-doc-ownership.py --self-test
	{{py}} .github/scripts/check-doc-ownership.py


# Rule 1's static half. `guard_engine_thread` is the runtime check and it only sees calls that reach it,
# so this asserts that they all do: `engine()` is the package's only route to the function table, and a
# bare `sciter.api()` anywhere else is a call the guard cannot see. That is not hypothetical - it is how
# the guard shipped, watching 124 of 199 call sites while `eval`, `call` and every `Value` constructor
# went unwatched. No engine and no display needed.
# ---
# assert the thread-affinity rule in docs/rules.md section 1: every engine call goes through engine()
check-affinity:
	{{py}} .github/scripts/check-affinity.py


# Three more invariants of the same shape, each true today and each held true by nobody: a Value handed
# back is recorded in the ledger, an owned handle is too, and every `proc "system"` restores a context.
# All three were verified by hand in the 2026-08-13 review, which is the argument for the script rather
# than against it - so was rule 1, and it drifted. Follows delegation, so a `scoped_` twin is not a
# hole. No engine and no display needed.
# ---
# assert the ledger and callback-context invariants: tracked(), track_acquire(), and `context =`
check-invariants:
	{{py}} .github/scripts/check-invariants.py


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


# The windowed examples, run as **programs** rather than as tests - which on macOS is the only way they
# run at all.
#
# `odin test` puts every test on a `thread.Pool` worker and AppKit refuses to make an `NSWindow` off the
# main thread, so `have_display()` answers false under `ODIN_TEST` on Darwin and fourteen examples skip
# themselves. A skip is a pass in the runner's accounting, so the macOS suite's green says less than the
# other two platforms' (docs/MACOS-CHECKLIST.md section 2a). A program's `main` *is* the main thread, so
# the same code runs here with nothing skipped.
#
# The contract is the canaries': run it for a few seconds and see whether it is still alive. **124 is
# the pass** - the timeout fired, so the pump was still turning and the window was still up. 0 is
# reported separately rather than folded into either column: a windowed program that returns on its own
# has either finished legitimately or failed to open a window and given up, and from outside there is no
# telling which. Anything else is the crash it looks like.
#
# What this does *not* prove is that the window has anything in it - `docs/PLAN.md` section 1's ceiling,
# and the reason README.md's platform table keeps a "looked at by a human" column. Run `window-canary`
# first; if the machine cannot open a window at all, every line below is the same failure repeated.
#
# WINDOWED_EXAMPLE_SECONDS (default 8) is how long each one has to stay up.
# ---
# run every windowed example as a program and check it stays up
[script]
windowed-examples: mktarget_dirs ensure-engine
	import os, sys
	sys.path.insert(0, ".github/scripts")
	from justlib import host_x11_skip, parallel, run_with_timeout, windowed_examples

	secs = int(os.environ.get("WINDOWED_EXAMPLE_SECONDS", "8"))
	out = os.path.join("target", "debug", "windowed")
	os.makedirs(out, exist_ok=True)

	names = windowed_examples(host_x11_skip())
	exe = lambda n: os.path.join(out, n + ".exe")

	# Built in parallel, run one at a time: these take focus, and several windows racing for it on one
	# desktop is a different experiment from the one being run.
	def build(name):
		return run_with_timeout(
			["odin", "build", f"examples/{name}.odin", "-file", "-debug", f"-out:{exe(name)}"], 0
		)

	if any(parallel(names, build)):
		raise SystemExit("a windowed example failed to build")

	if sys.platform.startswith("linux"):
		# The XSetICFocus crash in README.md - the input method, not the window. Set on this process so
		# the children inherit it; `run_with_timeout` passes no environment of its own.
		os.environ.setdefault("XMODIFIERS", "@im=none")

	alive, exited, failed = [], [], []
	for name in names:
		print(f"--- {name}", flush=True)
		code = run_with_timeout([exe(name)], secs)
		if code == 124:
			alive.append(name)
		elif code == 0:
			exited.append(name)
		else:
			failed.append(f"{name}(exit {code})")

	print()
	print(f"stayed up for {secs}s: {len(alive)}/{len(names)}")
	if exited:
		print(f"exited on their own (read these): {' '.join(exited)}")
	if failed:
		print(f"FAILED: {' '.join(failed)}")
		raise SystemExit(1)
	print(f"ok: {len(names)} windowed examples ran as programs with no crash")


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
