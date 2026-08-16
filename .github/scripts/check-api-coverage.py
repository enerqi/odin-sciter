#!/usr/bin/env python3
"""Every exported procedure of `sciter_app` has to appear in docs/api.md, which is the page that
promises to say what exists.

`stats.py` already counts the exported procedures and asserts that a test reaches every one of them.
Nothing asserted that a *reader* could find them, and the gap that opened was not a scattering of odd
names: api.md is organised one section per source file, and three files had no section at all -
`scoped.odin` (26 procedures), `value_scope.odin` (4) and `tracking.odin` (4). That is the whole
leak-prevention surface and the whole debug ledger, which is to say the two APIs `docs/rules.md` sends
a newcomer to look up. 340 of 402 procedures were mentioned; the missing 62 also included
`borrow_element` (while `borrow_node` and `borrow_request` were both there), `request_close`,
`app_event`, `destroy_asset_class`, the four gradient setters, the retain/release pairs and the
request header and parameter getters.

Several of those were "documented" only by a wildcard - `retain_*` / `release_*`, "the four
`set_*_gradient_*`", "the `value_to_*` inverses". That reads well and is not checkable, and a reader
searching for `retain_text` does not find it, so this check wants the literal name and the page now
spells the families out.

**Only this direction is checked.** A name in api.md that no longer exists would be the other kind of
rot, and it is not checkable the same way: api.md writes procedure names bare, in the same backticks it
uses for types, struct fields, enum members and C-API names, so "looks like a procedure" has no honest
definition here. `just check` catches the same rot in the compiled snippets, which is where it matters.

  check-api-coverage.py    fail with the list of procedures api.md does not mention
"""

import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
API_MD = os.path.join(ROOT, "docs", "api.md")

# Same rule as stats.py's `exported_procs`, deliberately: top-level `name :: proc`, minus anything
# marked @(private) on the line before. Proc-group members are declared the same way and count once, as
# the group - but a member the group cannot infer (`draw_rounded_rect_uniform`) is still its own
# declaration and so is still required here.
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
	exported = exported_procs()
	if not exported:
		print("no exported procedures found - has package sciter_app moved?")
		return 1

	api = read(API_MD)
	missing = [n for n in exported if not re.search(rf"\b{re.escape(n)}\b", api)]

	if missing:
		print(f"docs/api.md does not mention {len(missing)} of {len(exported)} exported procedures:\n")
		for name in missing:
			print(f"  {name}")
		print(
			"\napi.md is the page that answers \"what exists\". Add them to the section for the file they\n"
			"live in - and spell the name out rather than covering a family with a `*`, which no check\n"
			"can see and no reader can search for."
		)
		return 1

	print(f"ok: docs/api.md mentions all {len(exported)} exported procedures of sciter_app")
	return 0


if __name__ == "__main__":
	raise SystemExit(main(sys.argv[1:]))
