#!/usr/bin/env python3
"""Code in a comment is code nothing compiles, and this is the check for the one mistake it made.

`just check` type-checks two kinds of Odin: the packages, and `docs/snippets/snippets.odin`. It does not
type-check the third kind - the listings inside `//` doc comments in `sciter_app/*.odin` - and it cannot
usefully be made to, because those are fragments with no declarations around them.

That gap shipped a real defect. `Owned_Element` is `distinct Element`, so passing one where a borrowed
handle is wanted does not compile; three listings did exactly that (`sciter_app/dom.odin`,
`sciter_app/scoped.odin` and `docs/dom.md`, whose compiled twin in `snippets.odin` was correct all
along), on the single most-copied DOM idiom in the library. A reader pasting it got

    Error: Cannot assign value 'item' of type 'Owned_Element' to 'Element' in a procedure argument

against prose insisting the insert does not consume the reference.

So this checks the one thing about those fragments that can be checked without a compiler: the
owned/borrowed split. Any name bound from a procedure that hands back an `Owned_*`, later passed to a
procedure that takes the borrowed type, must go through `borrow_element` / `borrow_node` /
`borrow_request`.

**The two tables are read out of the source, not written here.** The producers are the procedures whose
return type is an `Owned_*`, and the borrow-takers are the parameters typed `Element`, `Node` or
`Request` - both scraped from `sciter_app/*.odin`, so adding a procedure of either kind extends this
check without editing it.

What it covers:

  - `//`-comment listings in sciter_app/*.odin  (the kind nothing else compiles)
  - ```odin blocks in docs/**/*.md              (whose snippets.odin twin can drift, and did)

  check-doc-ownership.py             check the tree
  check-doc-ownership.py --self-test check the checker against a listing known to be wrong
"""

import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

OWNED_TYPES = {"Owned_Element": "Element", "Owned_Node": "Node", "Owned_Request": "Request"}
BORROW_CAST = {"Element": "borrow_element", "Node": "borrow_node", "Request": "borrow_request"}

# `name :: proc(params) -> (results)`, possibly wrapped over several lines by odinfmt.
PROC = re.compile(r"^([a-z_][A-Za-z0-9_]*) :: proc\b", re.M)


def read(path: str) -> str:
	with open(path, encoding="utf-8", errors="replace") as f:
		return f.read()


def split_top_level(text: str) -> list[str]:
	"""Split on commas that are not inside brackets, quotes or a nested call."""
	out, depth, quote, start = [], 0, "", 0
	for i, ch in enumerate(text):
		if quote:
			if ch == quote and text[i - 1] != "\\":
				quote = ""
			continue
		if ch in "\"'`":
			quote = ch
		elif ch in "([{":
			depth += 1
		elif ch in ")]}":
			depth -= 1
		elif ch == "," and depth == 0:
			out.append(text[start:i])
			start = i + 1
	out.append(text[start:])
	return [s.strip() for s in out]


def signatures() -> tuple[dict[str, str], dict[str, list[str]]]:
	"""(producer -> owned type, proc -> parameter types) for package sciter_app."""
	producers: dict[str, str] = {}
	params: dict[str, list[str]] = {}

	for path in sorted(glob.glob(os.path.join(ROOT, "sciter_app", "*.odin"))):
		src = read(path)
		for m in PROC.finditer(src):
			name = m.group(1)
			# The whole declaration, up to the body's opening brace at depth 0.
			decl, depth = "", 0
			for ch in src[m.end():]:
				if ch == "{" and depth == 0:
					break
				decl += ch
				if ch in "([":
					depth += 1
				elif ch in ")]":
					depth -= 1
			arrow = decl.find("->")
			head = decl[:arrow] if arrow >= 0 else decl
			tail = decl[arrow:] if arrow >= 0 else ""

			for owned in OWNED_TYPES:
				if re.search(rf"\b{owned}\b", tail):
					producers[name] = owned
					break

			# Parameter types, in order, one entry per declared name so that positions line up:
			# `a, b: Element` is two parameters.
			inner = head[head.find("(") + 1:head.rfind(")")] if "(" in head else ""
			types: list[str] = []
			for part in split_top_level(inner):
				if ":" not in part:
					continue
				names, _, type_ = part.partition(":")
				type_ = type_.split("=")[0].strip()
				types.extend([type_] * len(split_top_level(names)))
			params[name] = types
	return producers, params


def code_blocks(path: str) -> list[tuple[int, list[str]]]:
	"""Contiguous runs of Odin: tab-indented lines inside `//` comments, or ```odin fences."""
	lines = read(path).splitlines()
	blocks: list[tuple[int, list[str]]] = []
	run: list[str] = []
	start = 0

	if path.endswith(".md"):
		fenced = False
		for i, line in enumerate(lines):
			if line.startswith("```"):
				if fenced:
					blocks.append((start, run))
					run = []
				fenced = line.strip() in ("```odin", "```odin\r")
				start = i + 2
				continue
			if fenced:
				run.append(line)
		return blocks

	for i, line in enumerate(lines):
		stripped = line.lstrip()
		if stripped.startswith("//\t"):
			if not run:
				start = i + 1
			run.append(stripped[2:])
			continue
		if run:
			blocks.append((start, run))
			run = []
	if run:
		blocks.append((start, run))
	return blocks


def check_block(first_line: int, block: list[str], producers, params) -> list[tuple[int, str]]:
	bound: dict[str, str] = {}  # variable -> owned type
	problems: list[tuple[int, str]] = []

	for offset, line in enumerate(block):
		lineno = first_line + offset

		# `x := sciter_app.make_element(...)`, `x, err := ...`, `x, _ = ...`
		assign = re.match(r"\s*([A-Za-z_][\w, ]*?)\s*:?=\s*(?:sciter_app\.)?([a-z_]\w*)\(", line)
		if assign:
			call = assign.group(2)
			if call in producers:
				names = [n.strip() for n in assign.group(1).split(",")]
				if names and names[0] not in ("_", ""):
					bound[names[0]] = producers[call]

		for call in re.finditer(r"(?:sciter_app\.)?([a-z_]\w*)\(", line):
			name = call.group(1)
			if name not in params or name.startswith("borrow_"):
				continue
			rest = line[call.end():]
			close = rest.find(")")
			args = split_top_level(rest[:close] if close >= 0 else rest)
			for i, arg in enumerate(args):
				if i >= len(params[name]):
					break
				want = params[name][i]
				owner = bound.get(arg.strip())
				if owner and OWNED_TYPES[owner] == want:
					problems.append(
						(
							lineno,
							f"`{arg.strip()}` is an {owner} and {name} takes {want} - "
							f"wrap it in {BORROW_CAST[want]}",
						)
					)
	return problems


SELF_TEST = [
	"item := sciter_app.make_element(\"li\", \"third\") or_return",
	"defer sciter_app.unuse_element(item)",
	"sciter_app.insert_element(item, list) or_return",
]


def main(argv: list[str]) -> int:
	producers, params = signatures()
	if not producers:
		print("no Owned_* producers found - has the package moved?")
		return 1

	if "--self-test" in argv:
		found = check_block(1, SELF_TEST, producers, params)
		if len(found) != 1:
			print(f"self-test FAILED: expected 1 problem in a listing known to be wrong, got {len(found)}")
			return 1
		print(f"self-test ok: {found[0][1]}")
		return 0

	targets = sorted(glob.glob(os.path.join(ROOT, "sciter_app", "*.odin")))
	targets += sorted(glob.glob(os.path.join(ROOT, "docs", "**", "*.md"), recursive=True))
	targets.append(os.path.join(ROOT, "README.md"))

	bad = 0
	blocks = 0
	for path in targets:
		if not os.path.exists(path):
			continue
		for first, block in code_blocks(path):
			blocks += 1
			for lineno, why in check_block(first, block, producers, params):
				bad += 1
				print(f"{os.path.relpath(path, ROOT)}:{lineno}: {why}")

	if bad:
		print(f"\n{bad} listing(s) would not compile. Code in a comment is still code someone pastes.")
		return 1
	print(
		f"ok: {blocks} code listings in doc comments and guides, "
		f"{len(producers)} Owned_* producers, none handed to a borrowed parameter"
	)
	return 0


if __name__ == "__main__":
	raise SystemExit(main(sys.argv[1:]))
