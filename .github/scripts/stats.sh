#!/usr/bin/env bash
#
# The numbers the documentation quotes about itself: how many examples, how many tests, how many of the
# wrapper's exported procs a test actually reaches.
#
# These were hand-maintained and had drifted - README and PLAN both said 337 tests against an actual
# 364-odd, which is the sort of claim a sceptical reader checks first and the sort that quietly
# undersells the work. Anything a doc asserts about this repository's size should come from here.
#
# The counting rule that matters, and the one this repository has already been bitten by: a wrapper is
# matched as `\.name\b`, **not** `\.name(`. The examples frequently store or forward a proc rather than
# calling it on the spot, and the open paren undercounts.
#
#   stats.sh            print the numbers
#   stats.sh --check    also verify the numbers quoted in README.md and docs/PLAN.md still match
set -euo pipefail

cd "$(dirname "$0")/../.."

examples=$(ls examples/*.odin | wc -l)
tests=$(grep -ch '@(test)' examples/*.odin | paste -sd+ | bc)
test_files=$(grep -lc '@(test)' examples/*.odin | wc -l)

# Exported procs of the wrapper: top-level `name :: proc`, minus anything marked @(private) on the line
# before. Proc-group members are declared the same way and count once, as the group.
exported=$(awk '
	/^@\(private/ { private = 1; next }
	/^[a-z_][a-zA-Z0-9_]* :: proc/ {
		if (private) { private = 0; next }
		name = $1
		print name
		next
	}
	{ private = 0 }
' sciter_app/*.odin | sort -u)
exported_count=$(echo "$exported" | grep -c . || true)

covered=0
while read -r name; do
	[ -n "$name" ] || continue
	if grep -rqE "\.${name}\b" examples --include='*.odin'; then
		covered=$((covered + 1))
	fi
done <<<"$exported"

printf 'examples:            %s files, %s with tests\n' "$examples" "$test_files"
printf 'tests:               %s @(test) procs\n' "$tests"
printf 'wrapper procs:       %s exported\n' "$exported_count"
printf 'reached from a test: %s\n' "$covered"

if [ "${1:-}" = "--check" ]; then
	fail=0
	check() { # file, what, expected-number-found-in-file
		if ! grep -qE "$3" "$1"; then
			echo "$1 does not quote the current $2 ($3)"
			fail=1
		fi
	}
	check README.md "test count" "\b$tests\b"
	check docs/PLAN.md "test count" "\b$tests\b"
	check docs/PLAN.md "coverage" "\b$covered\b of its \b$exported_count\b|$covered of its $exported_count"
	if [ "$fail" = 1 ]; then
		echo
		echo "Update the docs, or the code changed the numbers - either way they are meant to agree."
		exit 1
	fi
	echo "README.md and docs/PLAN.md agree with the measurement"
fi
