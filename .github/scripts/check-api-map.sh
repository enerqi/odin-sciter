#!/usr/bin/env bash
#
# Turns `just example api_map` from a thing a human reads into a thing that fails a build.
#
# api_map itself prints and does not judge - deliberately, because which slots are null is
# platform-specific and a human reading the table is how the Windows and macOS null lists get
# recorded in the first place. But docs/UPGRADING.md calls this "the step the whole procedure exists
# for", and a step whose pass/fail lives in someone's eyes is not a step CI can run. This script
# applies the rules the example's header comment states:
#
#   1. the table has EXPECT_SLOTS slots (189 on engine 6.0.4.9)
#   2. the engine reports ISciterAPI version EXPECT_API_VERSION (10)
#   3. on Linux/macOS every non-null slot resolves to its own name plus the engine's `Imp` suffix
#   4. the set of null slots is exactly what this platform is known to null
#
# Rule 3 has three standing exceptions, all real and all in the shipped table:
#
#   GetSciterGraphicsAPI     -> SciterGraphicsAPIImp                 (the `Get` prefix is ours, not the engine's)
#   GetSciterRequestAPI      -> SciterRequestAPIImp                  (same)
#   SciterEGLGetProcAddress  -> _Z26SciterEGLGetProcAddressImpPKc    (C++ linkage, so the name is mangled)
#
# so the test is "the resolved symbol contains <field>Imp, or <field-minus-leading-Get>Imp".
#
# On Windows there are no names to check: sciter.dll exports exactly one symbol, so almost every slot
# resolves as `sciter.dll+0x...`. Rule 3 becomes "every non-null slot lands inside sciter.dll", which
# is what api_map's VirtualQuery fallback reports, and rule 4 becomes a report rather than a gate
# until a real Windows run records the list. That asymmetry is the point of the platform switch here,
# not an oversight - see the example's header comment.
#
# Usage:
#     just example api_map | .github/scripts/check-api-map.sh
#     just api-map-verify                       # the same thing, from the justfile
#
# Environment:
#     EXPECT_SLOTS        default 189
#     EXPECT_API_VERSION  default 10
#     PLATFORM            default from uname; linux | macos | windows
#
# On a version bump, the two counts and the null list are exactly what you expect to edit, and the
# diff of this file is then the record of what the new engine changed.

set -euo pipefail

EXPECT_SLOTS="${EXPECT_SLOTS:-189}"
EXPECT_API_VERSION="${EXPECT_API_VERSION:-10}"

if [ -z "${PLATFORM:-}" ]; then
	case "$(uname -s)" in
		Linux) PLATFORM=linux ;;
		Darwin) PLATFORM=macos ;;
		MINGW* | MSYS* | CYGWIN* | Windows_NT) PLATFORM=windows ;;
		*) PLATFORM=linux ;;
	esac
fi

# Measured on this machine, 2026-08: engine 6.0.4.9, Linux x64. 12 platform-padded plus the four
# `reserved` slots left from the removed script VM.
LINUX_NULLS="SciterProc SciterProcND SciterTranslateMessage SciterGetViewExpando SciterRenderD2D SciterD2DFactory SciterDWFactory SciterCreateNSView SciterCreateWidget reserved1 reserved2 reserved3 reserved4 SciterCreateOnDirectXWindow SciterRenderOnDirectXWindow SciterRenderOnDirectXTexture"

# Not yet measured - the first real run on each platform is what fills these in, and until then the
# null list is reported rather than enforced. Expected shapes, from the header layout:
#   windows: fills SciterProc, SciterProcND, SciterTranslateMessage and the D2D/DirectX entries;
#            nulls SciterCreateWidget and SciterCreateNSView
#   macos:   fills SciterCreateNSView; nulls SciterCreateWidget and the Windows entries
WINDOWS_NULLS=""
MACOS_NULLS=""

out="$(cat)"
printf '%s\n' "$out"

fail=0
note() { printf '\n::error::%s\n' "$*" >&2; fail=1; }

# --- rule 2: the version handshake ------------------------------------------------------------------
if ! printf '%s' "$out" | grep -q "ISciterAPI version ${EXPECT_API_VERSION}"; then
	note "expected 'ISciterAPI version ${EXPECT_API_VERSION}' in the header line"
fi

# --- parse the table --------------------------------------------------------------------------------
slots=0
nulls=""
mismatches=""

while read -r _idx _off field _arrow symbol; do
	slots=$((slots + 1))
	if [ "$symbol" = "<null>" ]; then
		nulls="$nulls $field"
		continue
	fi
	case "$PLATFORM" in
		windows)
			# Names are unavailable without a PDB; containment is the check that always works.
			case "$symbol" in
				*[Ss]citer.dll*) : ;;
				*"<unmapped>"* | *"<unnamed>"*) mismatches="$mismatches $field->$symbol" ;;
				*Imp*) : ;; # symbols did happen to be available
				*) mismatches="$mismatches $field->$symbol" ;;
			esac
			;;
		*)
			alt="${field#Get}"
			case "$symbol" in
				*"${field}Imp"* | *"${alt}Imp"*) : ;;
				*) mismatches="$mismatches $field->$symbol" ;;
			esac
			;;
	esac
done < <(printf '%s\n' "$out" | grep -E '^[[:space:]]*[0-9]+ off=[0-9]+ ')

# --- rule 1: slot count -----------------------------------------------------------------------------
if [ "$slots" -ne "$EXPECT_SLOTS" ]; then
	note "table has $slots slots, expected $EXPECT_SLOTS - a real API change; read the diff of sciter-x-api.h"
fi

# --- rule 3: every non-null slot resolves to its own function ---------------------------------------
if [ -n "$mismatches" ]; then
	note "slot/symbol mismatch - the generated struct and the binary disagree about field offsets:"
	for m in $mismatches; do printf '  %s\n' "$m" >&2; done
fi

# --- rule 4: the null list --------------------------------------------------------------------------
sorted_nulls="$(printf '%s\n' $nulls | sort | tr '\n' ' ' | sed 's/ *$//')"
case "$PLATFORM" in
	linux) expected_nulls="$LINUX_NULLS" ;;
	macos) expected_nulls="$MACOS_NULLS" ;;
	windows) expected_nulls="$WINDOWS_NULLS" ;;
esac

if [ -z "$expected_nulls" ]; then
	printf '\n::notice::%s null slots on %s, not yet pinned. Record this list in check-api-map.sh and in api_map.odin: %s\n' \
		"$(printf '%s\n' $nulls | wc -l | tr -d ' ')" "$PLATFORM" "$sorted_nulls"
else
	sorted_expected="$(printf '%s\n' $expected_nulls | sort | tr '\n' ' ' | sed 's/ *$//')"
	if [ "$sorted_nulls" != "$sorted_expected" ]; then
		note "null slot list changed on $PLATFORM"
		printf '  expected: %s\n  got:      %s\n' "$sorted_expected" "$sorted_nulls" >&2
	fi
fi

if [ "$fail" -eq 0 ]; then
	printf '\nok: %s slots, %s null, 0 mismatches, ISciterAPI version %s (%s)\n' \
		"$slots" "$(printf '%s\n' $nulls | wc -l | tr -d ' ')" "$EXPECT_API_VERSION" "$PLATFORM"
fi
exit "$fail"
