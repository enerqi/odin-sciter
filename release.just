# Cutting a release: the text surgery half of `docs/UPGRADING.md`'s "Cutting a release", separated
# from the justfile proper because it runs once per tag rather than once per edit. Imported into one
# namespace, so `just release` and `just changelog_section` work as before and the settings at the
# top of the justfile (`set script-interpreter`, in particular) apply to the `[script]` bodies here.

# Step 5 of docs/UPGRADING.md's "Cutting a release", which is the only step in that checklist that is
# pure text surgery: move the `## Unreleased` heading to the version being cut. Everything under
# Unreleased becomes the new section - including its introductory prose, which is why the recipe tells
# you to read the diff rather than assuming it got the boundary right.
#
# Versions here are the engine's, four components and an optional bindings revision: `6.0.4.9`,
# `6.0.4.9-2`. The `v` is the tag's, not the version's, and is added to the heading to match the one
# already in the file - the section parser accepts either spelling.
#
# **It edits CHANGELOG.md and stops.** It does not commit, stage or tag, and that is not laziness: steps
# 1-4 of the same checklist are a build, the suite, `api_map`/`parity`, and running the windowed
# examples by hand on every platform that claims to be tested. A tag is the one artifact here that
# consumers pin, so nothing automates its way past that gate.
#
#   just release 6.0.4.9-2      # then: review, finish the checklist, commit, tag, push
# ---
# promote CHANGELOG.md's Unreleased section to a version heading
[script]
[group('release')]
release version:
	import datetime, re, sys

	version = r"{{version}}".lstrip("v")
	if not re.fullmatch(r"\d+\.\d+\.\d+\.\d+(-\d+)?", version):
		sys.exit(
			"expected an engine version like 6.0.4.9, or 6.0.4.9-2 for a second bindings release "
			"against the same engine - got: " + version
		)

	path = "CHANGELOG.md"
	with open(path, encoding="utf-8") as f:
		lines = f.read().splitlines()

	# `## Unreleased` and `## v6.0.4.9 - the first release` are both headings here, so the version is the
	# first whitespace-delimited token after the hashes and anything after it is free text. Brackets are
	# optional so a Keep a Changelog `## [1.2.3]` would parse too.
	heading = re.compile(r"^##\s+\[?([^\]\s]+)\]?")

	unreleased = None
	for i, line in enumerate(lines):
		m = heading.match(line)
		if not m:
			continue
		if m.group(1) == "Unreleased":
			unreleased = i
		elif m.group(1).lstrip("v") == version:
			sys.exit("CHANGELOG.md already has a '## v" + version + "' section")
	if unreleased is None:
		sys.exit("no '## Unreleased' heading in CHANGELOG.md")

	# Everything from Unreleased up to the next heading is what gets promoted.
	end = len(lines)
	for i in range(unreleased + 1, len(lines)):
		if heading.match(lines[i]):
			end = i
			break
	if not any(l.strip() for l in lines[unreleased + 1:end]):
		sys.exit("the Unreleased section is empty - nothing to release")

	# An em dash and no brackets, matching the `## v6.0.4.9 —` heading already in the file. This
	# changelog carries no `[Unreleased]: .../compare/...` link definitions - releases are git tags and
	# nothing else (docs/UPGRADING.md) - so unlike the skeleton's version of this recipe there is
	# nothing at the bottom of the file to rewrite.
	today = datetime.date.today().isoformat()
	lines[unreleased + 1:unreleased + 1] = ["", "## v" + version + " — " + today]

	with open(path, "w", encoding="utf-8", newline="\n") as f:
		f.write("\n".join(lines).rstrip("\n") + "\n")

	print("CHANGELOG.md: Unreleased -> v" + version + " (" + today + ")")
	print("next: review the diff, then finish docs/UPGRADING.md 'Cutting a release' from step 5")
	print("      the tag is step 7: git tag -a v" + version + " -m \"bindings for Sciter " + version + "\"")


# Prints one CHANGELOG.md section, which is what `gh release create --notes-file` wants. GitHub's own
# note generator lists merged pull requests only, so for a repository that pushes straight to master it
# would produce a release with essentially no notes - hence a section written by hand, and a non-zero
# exit when the version being cut has none.
#   just changelog_section 6.0.4.9 > notes.md
# ---
# print the CHANGELOG.md section for a version
[script]
[group('release')]
changelog_section version:
	import re, sys

	# The changelog is full of em dashes; without this the Windows console encoding mangles them and the
	# release notes carry the damage.
	sys.stdout.reconfigure(encoding="utf-8")

	want = r"{{version}}".lstrip("v")
	with open("CHANGELOG.md", encoding="utf-8") as f:
		lines = f.read().splitlines()

	heading = re.compile(r"^##\s+\[?([^\]\s]+)\]?")

	start = None
	for i, line in enumerate(lines):
		m = heading.match(line)
		if not m:
			continue
		if start is None and m.group(1).lstrip("v") == want:
			start = i + 1
		elif start is not None:
			lines = lines[start:i]
			break
	else:
		if start is None:
			sys.exit("no '## v" + want + "' section in CHANGELOG.md - add one before tagging")
		lines = lines[start:]

	# The last section in the file runs to EOF, which would sweep up any trailing link definitions.
	while lines and (not lines[-1].strip() or re.match(r"^\[[^\]]+\]:\s", lines[-1])):
		lines.pop()

	body = "\n".join(lines).strip("\n")
	if not body:
		sys.exit("the '## v" + want + "' section in CHANGELOG.md is empty")
	print(body)
