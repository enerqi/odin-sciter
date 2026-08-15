#!/usr/bin/env python3
"""C-API coverage: which SCFN slots the headers declare, and which of them `package sciter_app` reaches.

`just api-map-verify` answers the other half of the same question - that the slots the bindings expect
resolve to the right symbols in the engine that shipped. That catches a reordered or removed slot. It
cannot catch an *added* one: a new SDK with six more slots regenerates into `sciter.odin` as six fields
nothing wraps, and nothing says so. This is that check, and the reason it belongs next to the other one
in CI and in docs/UPGRADING.md.

Two counting rules, both of which a naive grep gets wrong:

  - **comments and `#if 0` are stripped first.** `imageGetPixels` (sciter-x-graphics.h) is inside a `//`
    block and `Request` (sciter-x-request.h) is inside `#if 0`; both match a bare SCFN grep and neither
    exists. Counting them as gaps produces two findings that can never be closed.
  - **usage is matched as `\\.Name\\b`, not `\\.Name\\(`.** The wrappers frequently store or forward a
    slot rather than calling it on the spot, and the open paren undercounts.

Usage:
  parity.py            print the tables
  parity.py --check    print them, then exit 1 if the unwrapped set differs from the baseline

The baseline is docs/parity-baseline.txt: the sorted list of declared-but-unwrapped slots, each one a
decision somebody made. A diff against it is the upgrade asking a question, at the moment the person
doing the upgrade is the right one to answer it.

Ported from parity.sh. The shell version was four coordinated awk/sed/grep passes to strip C comments,
which is the kind of thing that only ever ran on Linux; this runs anywhere the rest of the justfile does.
"""

import difflib
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
INCLUDE = os.path.join(ROOT, "external", "sciter", "include")
BASELINE = os.path.join(ROOT, "docs", "parity-baseline.txt")

SCFN = re.compile(r"SCFN\(\s*(\w+)")


def strip_dead_code(text: str) -> str:
	"""Remove `#if 0 ... #endif` blocks, then `/* */` and `//` comments - in that order."""
	kept, skip = [], False
	for line in text.splitlines():
		if re.match(r"^\s*#if 0", line):
			skip = True
			continue
		if skip:
			if re.match(r"^\s*#endif", line):
				skip = False
			continue
		kept.append(line)
	body = "\n".join(kept)
	body = re.sub(r"/\*.*?\*/", "", body, flags=re.S)
	body = re.sub(r"//.*", "", body)
	return body


def slots(header: str) -> list[str]:
	with open(os.path.join(INCLUDE, header), encoding="utf-8", errors="replace") as f:
		return sorted(set(SCFN.findall(strip_dead_code(f.read()))))


def odin_sources(directory: str) -> str:
	out = []
	for dirpath, _dirs, files in os.walk(os.path.join(ROOT, directory)):
		for name in files:
			if name.endswith(".odin"):
				with open(os.path.join(dirpath, name), encoding="utf-8", errors="replace") as f:
					out.append(f.read())
	return "\n".join(out)


def report(title: str, header: str, directory: str, unwrapped: list[str]) -> None:
	all_slots = slots(header)
	haystack = odin_sources(directory)
	used = [n for n in all_slots if re.search(rf"\.{re.escape(n)}\b", haystack)]
	unused = [n for n in all_slots if n not in used]

	print(f"{title} ({header} -> {directory})")
	print(f"  declared (live): {len(all_slots)}")
	print(f"  reached:         {len(used)}")
	print(f"  not reached:     {len(unused)}")
	for n in unused:
		print(f"    {n}")
	print()

	unwrapped.extend(f"{header} {n}" for n in unused)


def main(argv: list[str]) -> int:
	unwrapped: list[str] = []

	print("C-API coverage, measured from the vendored headers")
	print()
	report("main table", "sciter-x-api.h", "sciter_app", unwrapped)
	report("graphics sub-table", "sciter-x-graphics.h", "sciter_app", unwrapped)
	report("request sub-table", "sciter-x-request.h", "sciter_app", unwrapped)

	if "--check" not in argv:
		return 0

	got = sorted(unwrapped)
	with open(BASELINE, encoding="utf-8") as f:
		want = [line.rstrip("\n") for line in f if line.strip()]

	if got == want:
		print(f"unwrapped set matches {os.path.relpath(BASELINE, ROOT)}")
		return 0

	print("the set of unwrapped slots has changed:")
	sys.stdout.writelines(
		difflib.unified_diff(
			[f"{line}\n" for line in want],
			[f"{line}\n" for line in got],
			fromfile=os.path.relpath(BASELINE, ROOT),
			tofile="measured",
		)
	)
	print()
	print(f"A '+' line is a slot nothing wraps - decide about it and add it to {BASELINE} with a reason")
	print("in docs/SDK-PARITY.md, or wrap it. A '-' line means one got wrapped: drop it from the baseline.")
	return 1


if __name__ == "__main__":
	sys.exit(main(sys.argv[1:]))
