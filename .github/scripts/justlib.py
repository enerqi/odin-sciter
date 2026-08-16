"""Shared helpers for the justfile's `[script]` recipes.

Every recipe that needs more than one command is a `[script]` recipe running Python through
`uv run --no-project -p 3.14 python`, rather than a `#!/usr/bin/env bash` script. The reason is Windows:
`just` resolves a shebang interpreter through `PATH`, where a bare `bash` is Windows' WSL launcher (so
the recipe silently runs in a Linux VM with none of the toolchain), and `just` additionally wants
`cygpath` to translate the path it hands the interpreter - which fails outright with

    error: could not find `cygpath` executable to translate recipe `<name>` shebang interpreter path

unless Git for Windows' `usr/bin` is ahead of `System32` on `PATH`. Both of those are a developer-machine
setup problem that no amount of care inside the recipe can fix. Python is already a hard dependency of
this repository (bindgen, fetch-engine, check-ownership), so the recipes use it and the shebang problem
does not arise.

Recipes add `.github/scripts` to `sys.path` and import from here:

    import sys
    sys.path.insert(0, ".github/scripts")
    from justlib import run, sdk_tool

Recipes run with the repository root as the working directory, which is what `just` guarantees.
"""

from __future__ import annotations

import glob
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

# The flags `just lint` applies to everything. `-vet-tabs` is the only compiler-side enforcement of
# .editorconfig's `indent_style = tab`; it is not implied by `-strict-style`.
VET = ["-vet", "-vet-cast", "-strict-style", "-vet-tabs", "-no-entry-point"]

# `integration` and `native_child` are raw Xlib - `vendor:x11/xlib` declares nothing off Linux, so they
# do not build anywhere else. They are the two halves of "a Sciter view and a native window in each
# other's frame"; the Windows equivalents would be different programs, not this one recompiled.
X11_ONLY = ("integration", "native_child")

# Not applications: native extensions loaded by `sciter.loadLibrary(...)` from script. No `main`, so
# they build as shared libraries.
EXTENSIONS = ("extension", "sqlite_extension")

# Everything with source to type check that is not an example: the generated bindings, the ergonomic
# layer, and every Odin block in the guides. `check` and `cross-check` walk the same three, and used to
# spell them out separately - which is how one of them ends up checking something the other does not.
PACKAGES = (".", "sciter_app", "docs/snippets")


def host_x11_skip() -> tuple[str, ...]:
	"""`X11_ONLY` off Linux, nothing on it - for checks aimed at the machine they run on."""
	return () if sys.platform.startswith("linux") else X11_ONLY


def example_sources(skip: "tuple[str, ...] | set[str]" = ()) -> list[str]:
	"""Every `examples/*.odin`, minus `skip` given as bare names (no directory, no extension)."""
	skip = set(skip)
	return [f for f in sorted(glob.glob("examples/*.odin")) if os.path.basename(f)[:-5] not in skip]


def odin_check_cmds(skip: "tuple[str, ...] | set[str]" = (), target: str | None = None) -> list[list[str]]:
	"""`odin check` command lines for both packages, the guides' snippets and every example.

	One definition of "everything that type checks", shared by `check` (no target) and `cross-check`
	(one call per target). `-no-entry-point` throughout: the packages have no `main`, and the examples
	have one but do not need it entered to type check.
	"""
	suffix = [f"-target:{target}"] if target else []
	cmds = [["odin", "check", p, "-no-entry-point", *suffix] for p in PACKAGES]
	cmds += [["odin", "check", f, "-file", "-no-entry-point", *suffix] for f in example_sources(skip)]
	return cmds


def die(message: str) -> "NoReturn":  # noqa: F821
	print(message, file=sys.stderr)
	raise SystemExit(1)


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
	"""Run a command, echoing it first, and abort the recipe if it fails.

	The echo matters: a plain `just` recipe prints each line before running it, and a `[script]` recipe
	prints nothing, so without this a build that takes a minute looks like a hang.
	"""
	print(" ".join(cmd), flush=True)
	proc = subprocess.run(cmd, **kwargs)
	if proc.returncode != 0:
		raise SystemExit(proc.returncode)
	return proc


def try_run(cmd: list[str], **kwargs) -> int:
	"""`run` for the callers that want to keep going and report at the end."""
	print(" ".join(cmd), flush=True)
	return subprocess.run(cmd, **kwargs).returncode


def run_with_timeout(cmd: list[str], limit: int) -> int:
	"""Run `cmd`, killing its whole process tree if it outlives `limit` seconds. 0 means no ceiling.

	Returns the exit code, or 124 for a timeout - the same number GNU `timeout` uses, and the number the
	summary line and CI both read as "this one hung".

	**The process tree, not the process.** This replaces `timeout --kill-after=10s`, which had a failure
	mode measured on Windows: `just example-test <name>` spawns `odin test`, which builds and then runs a
	test executable. Killing `just` leaves that executable running, still holding the inherited stdout
	pipe, so the caller blocks on a read that never ends - the ceiling fires and the run hangs anyway.
	`taskkill /T` walks the tree; on POSIX the same job is done by a process group.

	"""
	print(" ".join(cmd), flush=True)

	if limit <= 0:
		return subprocess.run(cmd).returncode

	kwargs = {}
	if not is_windows():
		kwargs["start_new_session"] = True

	proc = subprocess.Popen(cmd, **kwargs)
	try:
		return proc.wait(timeout=limit)
	except subprocess.TimeoutExpired:
		print(f"::warning::timed out after {limit}s, killing the process tree", flush=True)
		if is_windows():
			subprocess.run(
				["taskkill", "/T", "/F", "/PID", str(proc.pid)],
				stdout=subprocess.DEVNULL,
				stderr=subprocess.DEVNULL,
			)
		else:
			import signal

			os.killpg(proc.pid, signal.SIGKILL)
		proc.wait()
		return 124


def parallel(jobs: list, worker) -> list:
	"""Map `worker` over `jobs` across as many threads as there are cores.

	Threads rather than processes: every job here is `subprocess.run` on a compiler, so the GIL is
	released for the whole of it.
	"""
	with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
		return list(pool.map(worker, jobs))


def is_windows() -> bool:
	return sys.platform == "win32"


def exe_ext() -> str:
	return ".exe" if is_windows() else ""


def shared_ext() -> str:
	if is_windows():
		return ".dll"
	if sys.platform == "darwin":
		return ".dylib"
	return ".so"


# Where each SDK tool lives inside a checkout, per platform. `packfolder` has no arch subfolder, and the
# inspector does not follow scapp: on macOS it ships as an .app bundle, so the real executable is under
# Contents/MacOS rather than next to scapp.
def _platform_dirs() -> dict[str, str]:
	if is_windows():
		return {"packfolder": "windows", "scapp": "windows/x64", "inspector": "windows/x64/inspector.exe"}
	if sys.platform == "darwin":
		return {
			"packfolder": "macosx",
			"scapp": "macosx",
			"inspector": "macosx/inspector.app/Contents/MacOS/inspector",
		}
	return {"packfolder": "linux", "scapp": "linux/x64", "inspector": "linux/x64/inspector"}


def sdk_tool(name: str) -> str:
	"""Resolve `packfolder`, `scapp` or `inspector` inside a sciter-js-sdk checkout, or exit with why.

	These are SDK tools and are deliberately not vendored here - see external/sciter/VENDORED.md - so
	they are found through SCITER_SDK or not at all.
	"""
	sdk = os.environ.get("SCITER_SDK", "")
	if not sdk:
		die(
			"SCITER_SDK is not set - point it at a sciter-js-sdk checkout.\n"
			f"{name} is not vendored here; see external/sciter/VENDORED.md."
		)
	dirs = _platform_dirs()
	rel = dirs["inspector"] if name == "inspector" else f"{dirs[name]}/{name}{exe_ext()}"
	path = os.path.join(sdk, "bin", *rel.split("/"))
	if not os.path.isfile(path):
		die(f"no {name} at {path}")
	return path


def scapp_app(app_name: str, lib: str, document: str) -> None:
	"""Assemble a throwaway app folder - scapp, a native extension and its document together, which is
	the layout `sciter.loadLibrary()` requires - and run it. Nothing in the SDK checkout is modified.

	The extension has to sit *beside the executable* under the exact name script asks for, which is why
	this copies rather than pointing scapp at the build directory.
	"""
	import shutil

	scapp = sdk_tool("scapp")
	app = os.path.join("target", "debug", app_name)
	shutil.rmtree(app, ignore_errors=True)
	os.makedirs(app)
	shutil.copy2(scapp, app)
	shutil.copy2(os.path.join("target", "debug", lib + shared_ext()), app)
	shutil.copy2(document, app)

	exe = os.path.join(app, "scapp" + exe_ext())
	print(f"running {exe}")
	run([os.path.abspath(exe), os.path.basename(document)], cwd=app)
