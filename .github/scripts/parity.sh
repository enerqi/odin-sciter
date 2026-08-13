#!/usr/bin/env bash
#
# C-API coverage: which SCFN slots the headers declare, and which of them `package sciter_app` reaches.
#
# `just api-map-verify` answers the other half of the same question - that the slots the bindings expect
# resolve to the right symbols in the engine that shipped. That catches a reordered or removed slot. It
# cannot catch an *added* one: a new SDK with six more slots regenerates into `sciter.odin` as six fields
# nothing wraps, and nothing says so. This is that check, and the reason it belongs next to the other one
# in CI and in docs/UPGRADING.md.
#
# Two counting rules, both of which a naive grep gets wrong:
#
#   - **comments and `#if 0` are stripped first.** `imageGetPixels` (sciter-x-graphics.h) is inside a
#     `//` block and `Request` (sciter-x-request.h) is inside `#if 0`; both match a bare SCFN grep and
#     neither exists. Counting them as gaps produces two findings that can never be closed.
#   - **usage is matched as `\.Name\b`, not `\.Name\(`.** The wrappers frequently store or forward a slot
#     rather than calling it on the spot, and the open paren undercounts.
#
# Usage:
#   parity.sh            print the tables
#   parity.sh --check    print them, then exit 1 if the unwrapped set differs from the baseline
#
# The baseline is docs/parity-baseline.txt: the sorted list of declared-but-unwrapped slots, each one a
# decision somebody made. A diff against it is the upgrade asking a question, at the moment the person
# doing the upgrade is the right one to answer it.
set -euo pipefail

cd "$(dirname "$0")/../.."

INCLUDE=external/sciter/include
BASELINE=docs/parity-baseline.txt

# Strip `#if 0 ... #endif` blocks and C/C++ comments, then pull the SCFN name out of what is left.
slots() {
	local header="$1"
	awk '
		/^[[:space:]]*#if 0/ { skip = 1 }
		skip && /^[[:space:]]*#endif/ { skip = 0; next }
		!skip { print }
	' "$header" |
		sed -e 's://.*::' |
		awk 'BEGIN { c = 0 }
			{
				line = $0
				while (1) {
					if (c == 0) {
						i = index(line, "/*")
						if (i == 0) { print line; break }
						head = substr(line, 1, i - 1)
						line = substr(line, i + 2)
						c = 1
						j = index(line, "*/")
						if (j == 0) { print head; break }
						line = head substr(line, j + 2)
						c = 0
					} else {
						j = index(line, "*/")
						if (j == 0) { break }
						line = substr(line, j + 2)
						c = 0
					}
				}
			}' |
		grep -oP 'SCFN\(\s*\K\w+' | sort -u
}

# Which of those names appear as `.Name` anywhere in the wrapper package.
used() {
	local names="$1" dir="$2"
	while read -r name; do
		[ -n "$name" ] || continue
		if grep -rqE "\.${name}\b" "$dir" --include='*.odin'; then
			echo "$name"
		fi
	done <<<"$names"
}

report() {
	local title="$1" header="$2" dir="$3"
	local all used_list unused
	all="$(slots "$INCLUDE/$header")"
	used_list="$(used "$all" "$dir")"
	unused="$(comm -23 <(echo "$all") <(echo "$used_list"))"

	printf '%s (%s -> %s)\n' "$title" "$header" "$dir"
	printf '  declared (live): %s\n' "$(echo "$all" | grep -c . || true)"
	printf '  reached:         %s\n' "$(echo "$used_list" | grep -c . || true)"
	printf '  not reached:     %s\n' "$(echo "$unused" | grep -c . || true)"
	if [ -n "$unused" ]; then
		echo "$unused" | sed 's/^/    /'
	fi
	echo

	# `|| true` because a sub-table with nothing unwrapped - the request table today - makes `grep .`
	# exit 1, and under `set -e` that would end the run with no output and a mystery exit code.
	echo "$unused" | grep . | sed "s|^|$header |" >>"$TMP_UNWRAPPED" || true
}

TMP_UNWRAPPED="$(mktemp)"
trap 'rm -f "$TMP_UNWRAPPED"' EXIT

echo "C-API coverage, measured from the vendored headers"
echo
report "main table" sciter-x-api.h sciter_app
report "graphics sub-table" sciter-x-graphics.h sciter_app
report "request sub-table" sciter-x-request.h sciter_app

if [ "${1:-}" = "--check" ]; then
	sort -o "$TMP_UNWRAPPED" "$TMP_UNWRAPPED"
	if ! diff -u "$BASELINE" "$TMP_UNWRAPPED" >/dev/null 2>&1; then
		echo "the set of unwrapped slots has changed:"
		diff -u "$BASELINE" "$TMP_UNWRAPPED" || true
		echo
		echo "A '+' line is a slot nothing wraps - decide about it and add it to $BASELINE with a reason"
		echo "in docs/SDK-PARITY.md, or wrap it. A '-' line means one got wrapped: drop it from the baseline."
		exit 1
	fi
	echo "unwrapped set matches $BASELINE"
fi
