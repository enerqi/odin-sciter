#!/usr/bin/env python3
"""Turn `just example api_map` from a thing a human reads into a thing that fails a build.

api_map itself prints and does not judge - deliberately, because which slots are null is
platform-specific and a human reading the table is how the Windows and macOS null lists get recorded in
the first place. But docs/UPGRADING.md calls this "the step the whole procedure exists for", and a step
whose pass/fail lives in someone's eyes is not a step CI can run. This applies the rules the example's
header comment states:

  1. the table has EXPECT_SLOTS slots (189 on engine 6.0.4.9)
  2. the engine reports ISciterAPI version EXPECT_API_VERSION (10)
  3. every non-null slot resolves to its own name plus the engine's `Imp` suffix
  4. the set of null slots is exactly what this platform is known to null

Rule 3 has three standing exceptions, all real and all in the shipped table:

  GetSciterGraphicsAPI     -> SciterGraphicsAPIImp                 (the `Get` prefix is ours, not the engine's)
  GetSciterRequestAPI      -> SciterRequestAPIImp                  (same)
  SciterEGLGetProcAddress  -> _Z26SciterEGLGetProcAddressImpPKc    (C++ linkage, so the name is mangled)

so the test is "the resolved symbol contains <field>Imp, or <field-minus-leading-Get>Imp".

Windows was expected to be the weak case - "sciter.dll exports one symbol, so rule 3 degrades to every
slot lands inside the module". Measured 2026-08-15 on engine 6.0.4.9, that is wrong and in the useful
direction: sciter.dll exports 276 named symbols, and 172 of the 174 non-null slots resolve to their own
`...Imp` name exactly as on Linux. So rule 3 is the same rule on both platforms.

The two that do not are the two whose `Imp` is genuinely not in the export table, so dbghelp reports the
nearest export below them instead:

  SciterProcND            -> SciterRequestAPIImp+0x1cc
  SciterEGLGetProcAddress -> SciterRequestAPIImp+0x1c4

WINDOWS_NEAREST_EXPORT below is that allowlist. Those two are checked for module containment only, which
is what api_map's VirtualQuery fallback was written for. A third slot joining them is a signal, not
noise: it means the engine stopped exporting something it used to.

WINDOWS_ICF_ALIASES is the other Windows-only wrinkle, and it is a linker artifact rather than anything
about Sciter. MSVC links release builds with `/OPT:ICF`, which folds functions whose machine code is
byte-identical onto one address; the export table then has several names for that address and dbghelp
picks one. sciter.dll has five such addresses, and two of them are ISciterAPI slots:

  0x19354  SciterGetAttributeByNameImp, SciterGetElementNamespaceImp, SciterGetNthAttributeImp,
           SciterGetObjectImp                     - all `mov eax,5; ret`, i.e. return
                                                    SCDOM_OPERATION_FAILED. Unimplemented stubs.
  0x17ba8  SciterElementWrapImp, SciterNodeWrapImp - one real function; wrapping an element and
                                                    wrapping a node are the same code.

GNU ld does no ICF by default, which is why Linux resolves each of these to its own name and this list
has no Linux counterpart. Verified by parsing the export directory rather than inferred: the names share
an RVA. Read a *new* pair appearing here as "check whether these two really are the same code" before
reading it as offset drift - drift shifts every slot after it, not two in isolation.

Usage:
    just example api_map | uv run --no-project -p 3.14 python .github/scripts/check-api-map.py
    just api-map-verify                       # the same thing, from the justfile

Environment:
    EXPECT_SLOTS        default 189
    EXPECT_API_VERSION  default 10
    PLATFORM            default from sys.platform; linux | macos | windows

On a version bump, the two counts and the null list are exactly what you expect to edit, and the diff of
this file is then the record of what the new engine changed.
"""

import os
import re
import sys

EXPECT_SLOTS = int(os.environ.get("EXPECT_SLOTS", "189"))
EXPECT_API_VERSION = os.environ.get("EXPECT_API_VERSION", "10")

# Measured on this machine, 2026-08: engine 6.0.4.9, Linux x64. 12 platform-padded plus the four
# `reserved` slots left from the removed script VM.
LINUX_NULLS = """
	SciterProc SciterProcND SciterTranslateMessage SciterGetViewExpando SciterRenderD2D
	SciterD2DFactory SciterDWFactory SciterCreateNSView SciterCreateWidget
	reserved1 reserved2 reserved3 reserved4
	SciterCreateOnDirectXWindow SciterRenderOnDirectXWindow SciterRenderOnDirectXTexture
""".split()

# Measured on this machine, 2026-08-15: engine 6.0.4.9, Windows x64, `bin/windows/x64/sciter.dll`.
#
# It is the Linux list minus `SciterProcND`, and that one slot is the whole difference. The expectation
# recorded here before the machine existed was that Windows would fill `SciterProc`,
# `SciterTranslateMessage` and the D2D/DirectX entries - it fills none of them:
#
#   SciterProc, SciterTranslateMessage   the HWND message-pump entry points of Sciter 4. Sciter 6 owns
#                                        its own window procedure and does not publish them.
#   SciterRenderD2D, SciterD2DFactory,   Direct2D/DirectWrite. This is the plain `bin/windows/` build,
#   SciterDWFactory                      which renders through Skia; those live in `bin/windows.d2d/`.
#   the three DirectX entries            same reason.
#   SciterCreateWidget                   Linux/GTK, gone in Sciter 6 there too.
#   SciterCreateNSView                   macOS - and null *there* too, measured. See MACOS_NULLS below.
#
# So an application must not reach for SciterProc/SciterTranslateMessage on Windows: nothing in this
# repository does, and the null list is why.
WINDOWS_NULLS = [n for n in LINUX_NULLS if n != "SciterProcND"]

# Measured on `macos-14` (arm64), 2026-08-15: engine 6.0.4.9, `bin/macosx/libsciter.dylib`.
#
# **It is the Linux list, exactly - and the prediction recorded here was wrong.** The guess was 15 nulls,
# the Linux list *minus* `SciterCreateNSView`, on the reasoning that macOS should be the one platform to
# fill the slot named after its own view class. It does not fill it. `SciterCreateNSView` is NULL on all
# three platforms, which makes it a twin of `SciterCreateWidget`: both are Sciter 4 entry points for
# putting a view inside a host widget, and Sciter 6 creates its own window on every platform instead.
#
# The consequence is an API one, and it is worth stating because the slot's existence implies otherwise:
# **there is no supported way to hand this engine an existing NSView.** `SciterCreateWindow` or a
# windowless view (`SciterProcX`) are the two doors, on macOS as everywhere else.
#
# So the three lists are: Linux 16, macOS 16 (the same 16), Windows 15 (the same minus `SciterProcND`).
# Every platform-specific prediction made in this file before its machine existed has now been wrong -
# twice for Windows, once here - which is the argument for measuring rather than reasoning about it.
MACOS_NULLS = list(LINUX_NULLS)

# The two Windows slots whose implementation is not in sciter.dll's export table - see the header. They
# get the module-containment check instead of the name check.
WINDOWS_NEAREST_EXPORT = {"SciterProcND", "SciterEGLGetProcAddress"}

# field -> symbol pairs the linker folded onto one address - see the header. The symbol is what dbghelp
# names; the field is the slot that legitimately points there.
WINDOWS_ICF_ALIASES = {
	"SciterGetElementNamespace": "SciterGetObjectImp",
	"SciterElementWrap": "SciterNodeWrapImp",
}

ROW = re.compile(r"^\s*(\d+) off=(\d+) (\S+)\s+->\s+(.*\S)\s*$")


def platform() -> str:
	if env := os.environ.get("PLATFORM"):
		return env
	if sys.platform == "win32":
		return "windows"
	if sys.platform == "darwin":
		return "macos"
	return "linux"


def main() -> int:
	plat = platform()
	out = sys.stdin.read()
	sys.stdout.write(out)
	if not out.endswith("\n"):
		sys.stdout.write("\n")

	fail = False

	def note(msg: str) -> None:
		nonlocal fail
		print(f"\n::error::{msg}", file=sys.stderr)
		fail = True

	# --- rule 2: the version handshake ---------------------------------------------------------------
	if f"ISciterAPI version {EXPECT_API_VERSION}" not in out:
		note(f"expected 'ISciterAPI version {EXPECT_API_VERSION}' in the header line")

	# --- parse the table ------------------------------------------------------------------------------
	slots = 0
	nulls: list[str] = []
	mismatches: list[str] = []

	for line in out.splitlines():
		m = ROW.match(line)
		if not m:
			continue
		slots += 1
		field, symbol = m.group(3), m.group(4)
		if symbol == "<null>":
			nulls.append(field)
			continue

		# --- rule 3: every non-null slot resolves to its own function ---------------------------------
		if plat == "windows" and field in WINDOWS_NEAREST_EXPORT:
			# No export of its own: only containment can be checked. `<name>+0x...` is dbghelp reporting
			# the nearest export below it, which is still inside the module.
			if "sciter.dll" in symbol.lower() or "+0x" in symbol:
				continue
			mismatches.append(f"{field}->{symbol}")
			continue

		alt = field[3:] if field.startswith("Get") else field
		if f"{field}Imp" in symbol or f"{alt}Imp" in symbol:
			continue
		if plat == "windows" and WINDOWS_ICF_ALIASES.get(field) == symbol:
			continue
		mismatches.append(f"{field}->{symbol}")

	# --- rule 1: slot count ---------------------------------------------------------------------------
	if slots != EXPECT_SLOTS:
		note(
			f"table has {slots} slots, expected {EXPECT_SLOTS} - a real API change; "
			"read the diff of sciter-x-api.h"
		)

	if mismatches:
		note("slot/symbol mismatch - the generated struct and the binary disagree about field offsets:")
		for m in mismatches:
			print(f"  {m}", file=sys.stderr)

	# --- rule 4: the null list ------------------------------------------------------------------------
	expected = {"linux": LINUX_NULLS, "macos": MACOS_NULLS, "windows": WINDOWS_NULLS}[plat]
	if not expected:
		print(
			f"\n::notice::{len(nulls)} null slots on {plat}, not yet pinned. Record this list in "
			f"check-api-map.py and in api_map.odin: {' '.join(sorted(nulls))}"
		)
	elif sorted(nulls) != sorted(expected):
		note(f"null slot list changed on {plat}")
		print(f"  expected: {' '.join(sorted(expected))}", file=sys.stderr)
		print(f"  got:      {' '.join(sorted(nulls))}", file=sys.stderr)

	if not fail:
		print(
			f"\nok: {slots} slots, {len(nulls)} null, 0 mismatches, "
			f"ISciterAPI version {EXPECT_API_VERSION} ({plat})"
		)
	return 1 if fail else 0


if __name__ == "__main__":
	sys.exit(main())
