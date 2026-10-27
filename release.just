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


# Step 8 of docs/UPGRADING.md's "Cutting a release": mirror the three pinned engine binaries as the
# assets of a GitHub release tagged `engine-<engine_tag>`, which is fetch-engine.py's last source. It
# hangs off the pin rather than off a bindings tag, so it is a no-op until `engine_tag` moves - the
# recipe checks for an existing release with all three assets first and stops if there is one.
#
# Everything the notes say is read out of external/sciter/VENDORED.md, and the files are checked against
# that table before anything is uploaded: the table is the pin, so a release that disagreed with it
# would be a mirror of the wrong bytes. All three binaries have to be in lib/ - the SDK's bin/ at the
# pinned tag has them - although `just fetch-engine` installs only the host's.
#
# **Without `--publish` it publishes nothing**: it prints the notes and the `gh` command. With it, it
# creates the release against master and then downloads each asset back through fetch-engine.py's own
# MIRROR URL and checks the hash, which is the loop the step is there to close.
#
#   just engine-release             # dry run: the checks, the notes, the command
#   just engine-release --publish   # the same, then `gh release create` and the round trip
# ---
# mirror the pinned engine binaries as the engine-<tag> GitHub release
[script]
[group('release')]
engine-release *flags:
	import importlib.util, json, os, re, shlex, subprocess, sys, tempfile, urllib.request

	sys.stdout.reconfigure(encoding="utf-8")

	flags = r"{{flags}}".split()
	unknown = [f for f in flags if f != "--publish"]
	if unknown:
		sys.exit("unknown flag(s): " + " ".join(unknown) + " - the only one is --publish")
	publish = "--publish" in flags

	tag = "{{engine_tag}}"
	release = "engine-" + tag

	# The URL shape lives in fetch-engine.py and nowhere else, so the round trip below goes through it.
	spec = importlib.util.spec_from_file_location("fetch_engine", ".github/scripts/fetch-engine.py")
	fetch_engine = importlib.util.module_from_spec(spec)
	spec.loader.exec_module(fetch_engine)

	def field(text, name):
		m = re.search(r"^\| " + re.escape(name) + r" \| (.+?) \|$", text, re.M)
		if not m:
			sys.exit("external/sciter/VENDORED.md has no '| " + name + " |' row")
		return m.group(1)

	def vendored(text):
		"""(upstream tag, commit, engine version, API version, [(path, size, sha256)])"""
		rows = re.findall(r"^\| `(lib/[^`]+)` \| ([\d ]+) \| `([0-9a-f]{64})` \|$", text, re.M)
		if len(rows) != 3:
			sys.exit(f"expected 3 binaries in VENDORED.md's table, found {len(rows)}")
		return (
			field(text, "Tag").strip("`"),
			re.match(r"`([0-9a-f]{40})`", field(text, "Commit")).group(1),
			field(text, "Engine version").split()[0],
			field(text, "`SCITER_API_VERSION`"),
			[(p, int(s.replace(" ", "")), h) for p, s, h in rows],
		)

	with open("external/sciter/VENDORED.md", encoding="utf-8") as f:
		upstream, commit, engine, api, files = vendored(f.read())
	if upstream != tag:
		sys.exit(f"VENDORED.md pins tag {upstream} but the justfile's engine_tag is {tag}")
	if "{{engine_sha256}}" not in [h for _, _, h in files]:
		sys.exit("the justfile's engine_sha256 for this platform is not in VENDORED.md's table")

	# `--target master` tags whatever master is on GitHub, so that commit has to pin this engine too.
	subprocess.run(["git", "fetch", "-q", "origin", "master"], check=True)
	remote = subprocess.run(
		["git", "show", "origin/master:external/sciter/VENDORED.md"],
		capture_output=True, text=True, encoding="utf-8", check=True,
	).stdout
	if vendored(remote)[0] != tag:
		sys.exit(f"origin/master does not pin {tag} yet - push and merge the upgrade first")

	view = subprocess.run(
		["gh", "release", "view", release, "--json", "assets"], capture_output=True, text=True,
	)
	if view.returncode == 0:
		have = sorted(a["name"] for a in json.loads(view.stdout)["assets"])
		want = sorted(os.path.basename(p) for p, _, _ in files)
		if have == want:
			print(f"{release} already has its three assets - nothing to do")
			sys.exit(0)
		sys.exit(f"{release} exists with assets {have}, not {want} - fix it by hand on GitHub")

	bad = []
	for path, size, sha in files:
		if not os.path.isfile(path):
			bad.append(f"  {path}: missing - copy it from the SDK's bin/ at tag {tag}")
			continue
		got = fetch_engine.digest(path)
		if os.path.getsize(path) != size or got != sha:
			bad.append(f"  {path}: {os.path.getsize(path)} bytes, sha256 {got}")
	if bad:
		sys.exit("lib/ does not hold the pinned binaries:\n" + "\n".join(bad))

	labels = {"libsciter.so": "linux x64", "sciter.dll": "windows x64", "libsciter.dylib": "macos, universal"}
	table = "\n".join(
		f"| `{os.path.basename(p)}` ({labels[os.path.basename(p)]}) | {s:,} | `{h}` |".replace(f"{s:,}", f"{s:,}".replace(",", " "))
		for p, s, h in files
	)
	notes = f"""**This is not a release of the bindings.** It is a byte-for-byte mirror of the Sciter engine
	binaries this repository pins, published so that a checkout stays buildable if upstream withdraws or
	moves a tag — no engine is committed to git any more. The tag exists to hold these three files and
	says nothing about the state of the Odin code at that commit.

	Bindings releases are tagged `vX.Y.Z.W`; see [`docs/UPGRADING.md`](docs/UPGRADING.md).

	Upstream: <https://gitlab.com/sciter-engine/sciter-js-sdk> at tag `{tag}`, commit
	`{commit}`. Engine version {engine}, `SCITER_API_VERSION` {api}.

	| File | Size | SHA-256 |
	| --- | --- | --- |
	{table}

	`.github/scripts/fetch-engine.py` reaches these automatically, as its last source after upstream, and
	verifies whatever arrives against the hashes above — so nothing here has to be trusted to be useful.

	The engine binary is covered by the Sciter engine EULA, not by this repository's BSD licence. It is
	free to use in commercial and non-commercial applications, with one requirement:

	> Your application shall include link to Terra Informatica site in "About" dialog or similar place in
	> your application. Text of the link: This Application (or Component) uses Sciter Engine
	> (http://sciter.com/), copyright Terra Informatica Software, Inc.
	"""
	notes = "\n".join(line.removeprefix("\t") for line in notes.splitlines()) + "\n"

	command = [
		"gh", "release", "create", release, *[p for p, _, _ in files],
		"--target", "master", "--title", "Sciter engine " + tag, "--notes-file", "<notes>",
	]
	print(notes)
	print("$ " + shlex.join(command))
	if not publish:
		print("\ndry run - nothing published. `just engine-release --publish` to create it.")
		sys.exit(0)

	with tempfile.TemporaryDirectory() as tmp:
		notes_file = os.path.join(tmp, "notes.md")
		with open(notes_file, "w", encoding="utf-8", newline="\n") as f:
			f.write(notes)
		subprocess.run([notes_file if a == "<notes>" else a for a in command], check=True)

		# Back down through the URL a fresh clone would use, rather than trusting the release page.
		for path, size, sha in files:
			name = os.path.basename(path)
			url = fetch_engine.MIRROR.format(tag=tag, name=name)
			local = os.path.join(tmp, name)
			urllib.request.urlretrieve(url, local)
			got = fetch_engine.digest(local)
			if got != sha:
				sys.exit(f"{url}: sha256 {got}, expected {sha}")
			print(f"ok: {url}")
	print(f"ok: {release} published and all three assets round-trip")
