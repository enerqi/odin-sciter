#!/usr/bin/env bash
#
# Can the engine create a window on this Mac at all?
#
# The Darwin half of `window-canary.sh`. Same contract, same reason for existing - ask in twenty
# seconds, before the forty-five minute test job, because "no" is invisible in that job's output and
# presents as twenty-odd identical faults that read like broken bindings.
#
# What is different here is *everything the failure could be*. The Linux script diagnoses an X server
# and an EGL stack; neither exists on macOS. The engine's `HWINDOW` is an `NSView*`, the dylib links
# AppKit, Cocoa, Carbon, Metal and OpenGL, and the failure modes are Apple-shaped:
#
#   no GUI session          A process in a `Background` launchd session has no connection to
#                           WindowServer. AppKit calls then abort rather than degrade, classically with
#                           "_RegisterApplication(), FAILED TO establish the default connection to the
#                           WindowServer". This is the open question the canary exists to answer on a
#                           GitHub runner: `launchctl managername` below prints which session this is.
#
#   code signature          arm64 macOS refuses to map unsigned code. `dlopen` fails, or the process is
#                           killed outright with SIGKILL - "Killed: 9", exit 137 - which looks nothing
#                           like a load error. The vendored dylib is ad-hoc signed (see
#                           external/sciter/VENDORED.md), so this should not fire; if it does, the file
#                           on disk is not the file that was pinned.
#
#   quarantine              a dylib that arrived through a browser or an unzipped archive carries
#                           `com.apple.quarantine` and is refused. `just fetch-engine` uses urllib,
#                           which does not set it. `xattr -l` below says whether this copy has it.
#
#   main thread             AppKit requires window work on the main thread. `hello_window` is a plain
#                           program, so it is already there - which is exactly why the canary is a
#                           program and not a test. If the canary passes and the windowed *tests* fault,
#                           the thread is the difference, not the engine.
#
# Exit codes, same as the Linux canary:
#
#   124  the timeout fired, so the program was still running, so the window exists   -> pass
#   1    SciterCreateWindow returned NULL                                            -> no window server
#   137  SIGKILL - almost always the code signature
#   139  SIGSEGV - read the lldb trace below
#
# Unlike the Linux one this is safe to run on your own desktop: a Sciter `SW_MAIN` window does not
# mode-set the display on macOS. It will take focus for twenty seconds.

set -uo pipefail

cd "$(dirname "$0")/../.."

exe=target/debug/window-canary.exe
mkdir -p target/debug

# -debug so the lldb backtrace below has this program's own frames as well as the engine's.
odin build examples/hello_window.odin -file -debug -out:"$exe" || exit 1

# macOS ships no `timeout(1)` - it is GNU coreutils, and a stock runner does not have it. Emulating it
# here rather than depending on `brew install coreutils` keeps the canary's own dependencies to what
# Apple ships, which is the whole point of running it before anything else. The 124 is chosen to match
# GNU timeout so both canaries report a pass the same way.
run_for() {
	local secs="$1"
	shift
	"$@" &
	local pid=$! i=0
	while kill -0 "$pid" 2>/dev/null; do
		if [ "$i" -ge "$secs" ]; then
			kill -9 "$pid" 2>/dev/null
			wait "$pid" 2>/dev/null
			return 124
		fi
		sleep 1
		i=$((i + 1))
	done
	wait "$pid"
}

run_for 20 "$exe"
code=$?

if [ "$code" = 124 ]; then
	echo "window canary: ok - a window was created and the program was still running 20s later"
	exit 0
fi

echo "::error::the engine cannot open a window on this machine (canary exited $code) - every windowed test below would fault the same way, in the engine and not in the bindings"
echo

# The session type first, because it is the one thing that cannot be inferred from a backtrace and the
# one most likely to be the answer on a hosted runner. `Aqua` is a GUI session; `Background` or
# `StandardIO` means no WindowServer connection is available to this process at all, and nothing else
# printed below matters until that changes.
echo "--- launchd session (Aqua = a GUI session; Background/StandardIO = no WindowServer)"
launchctl managername 2>&1 || echo "(launchctl managername unavailable)"
echo "SSH_TTY=${SSH_TTY:-(unset)}  TERM_SESSION_ID=${TERM_SESSION_ID:-(unset)}"
echo

echo "--- how far it gets, and where it faults"
if command -v lldb >/dev/null; then
	# `-b` batch, and `-o` commands in order. `thread backtrace all` after the stop gives the engine's
	# frames; libsciter is stripped of nothing useful, so the C++ names come through.
	run_for 120 lldb -b \
		-o 'settings set target.process.stop-on-exec false' \
		-o run \
		-o 'thread backtrace all' \
		-o 'quit' \
		-- "$exe" 2>&1 | tail -60
else
	echo "(lldb not available - install the Xcode command line tools)"
fi
echo

echo "--- what the dylib is, and whether the system will accept it"
lipo -archs lib/macosx/libsciter.dylib 2>&1 || true
codesign -dv --verbose=4 lib/macosx/libsciter.dylib 2>&1 | sed -n '1,12p' || true
echo "extended attributes (a com.apple.quarantine line here is the whole answer):"
xattr -l lib/macosx/libsciter.dylib 2>&1 || echo "(none)"
echo

echo "--- its dependencies (all of them should be system frameworks)"
otool -L lib/macosx/libsciter.dylib 2>&1 | sed -n '2,40p' || true
echo

echo "--- displays, if any"
system_profiler SPDisplaysDataType 2>&1 | head -30 || true
echo
sw_vers 2>&1 || true
echo "arch: $(uname -m)"
echo

# The engine writes its own diagnostics through the debug-output callback, and `hello_window` installs
# the default handler, so a second plain run often prints the one line that names the missing piece
# without a debugger in the way.
echo "--- a second run, plain (the engine's own diagnostics, if it emits any)"
run_for 20 "$exe" 2>&1 | head -40

exit 1
