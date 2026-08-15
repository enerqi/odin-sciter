#!/usr/bin/env python3
"""The numbers the documentation quotes about itself: how many examples, how many tests, how many of the
wrapper's exported procs a test actually reaches.

These were hand-maintained and had drifted - README and PLAN both said 337 tests against an actual
364-odd, which is the sort of claim a sceptical reader checks first and the sort that quietly undersells
the work. Anything a doc asserts about this repository's size should come from here.

The counting rule that matters, and the one this repository has already been bitten by: a wrapper is
matched as `\\.name\\b`, **not** `\\.name(`. The examples frequently store or forward a proc rather than
calling it on the spot, and the open paren undercounts.

  stats.py            print the numbers
  stats.py --check    also verify the numbers quoted in README.md and docs/PLAN.md still match

Ported from stats.sh; see parity.py's header for why.
"""

import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

TEST_MARKER = "@(test)"

# Exported procs of the wrapper: top-level `name :: proc`, minus anything marked @(private) on the line
# before. Proc-group members are declared the same way and count once, as the group.
PROC = re.compile(r"^([a-z_][a-zA-Z0-9_]*) :: proc")


def read(path: str) -> str:
	with open(path, encoding="utf-8", errors="replace") as f:
		return f.read()


def exported_procs() -> list[str]:
	names: set[str] = set()
	for path in sorted(glob.glob(os.path.join(ROOT, "sciter_app", "*.odin"))):
		private = False
		for line in read(path).splitlines():
			if line.startswith("@(private"):
				private = True
				continue
			m = PROC.match(line)
			if m:
				if not private:
					names.add(m.group(1))
				private = False
				continue
			private = False
	return sorted(names)


def main(argv: list[str]) -> int:
	example_files = sorted(glob.glob(os.path.join(ROOT, "examples", "*.odin")))
	sources = {p: read(p) for p in example_files}

	tests = sum(text.count(TEST_MARKER) for text in sources.values())
	test_files = sum(1 for text in sources.values() if TEST_MARKER in text)

	exported = exported_procs()
	haystack = "\n".join(sources.values())
	covered = sum(1 for n in exported if re.search(rf"\.{re.escape(n)}\b", haystack))

	print(f"examples:            {len(example_files)} files, {test_files} with tests")
	print(f"tests:               {tests} @(test) procs")
	print(f"wrapper procs:       {len(exported)} exported")
	print(f"reached from a test: {covered}")

	if "--check" not in argv:
		return 0

	fail = False

	def check(relpath: str, what: str, pattern: str) -> None:
		nonlocal fail
		if not re.search(pattern, read(os.path.join(ROOT, relpath))):
			print(f"{relpath} does not quote the current {what} ({pattern})")
			fail = True

	check("README.md", "test count", rf"\b{tests}\b")
	check("docs/PLAN.md", "test count", rf"\b{tests}\b")
	check("docs/PLAN.md", "coverage", rf"\b{covered}\b of its \b{len(exported)}\b|{covered} of its {len(exported)}")

	if fail:
		print()
		print("Update the docs, or the code changed the numbers - either way they are meant to agree.")
		return 1
	print("README.md and docs/PLAN.md agree with the measurement")
	return 0


if __name__ == "__main__":
	sys.exit(main(sys.argv[1:]))
