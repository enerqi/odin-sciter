#!/usr/bin/env bash
#
# Can the engine create a window on this machine at all?
#
# Ask once, in seconds, before the forty-five minute test job - because the answer "no" is invisible in
# that job's output. The engine does not report a machine it cannot run on; it faults, and it does so in
# at least two places that look nothing alike:
#
#   XDG_SESSION_TYPE is not `x11`     `wing::init()` picks the GTK4 backend, and
#                                     `wing::internal::PollMonitorsGtk4` calls a NULL function pointer
#                                     during `SciterExec(.INIT)` - before a window is even asked for.
#                                     Unset is the normal state of CI, a container, or ssh. This is what
#                                     the runner was hitting.
#
#   `wing::window::create` fails      it unwinds through `wing::window::destroy` into `XDestroyIC` with
#   (no usable renderer)              an XIC that was never created. The engine faults instead of
#                                     returning NULL, so it presents as SIGSEGV inside `create_window`.
#
# Either way every windowed test dies, the Odin test runner hangs rather than reaping the thread, and
# each example burns the whole EXAMPLE_TEST_TIMEOUT. Twenty-odd examples segfaulting identically reads
# like a broken binding and is not one. Neither of these is the `XSetICFocus` crash in README.md, and
# `XMODIFIERS=@im=none` does not prevent either of them.
#
# The canary is `hello_window` because it is the smallest thing that opens a window and it does it on
# the main thread, where a renderer failure often degrades to `SciterCreateWindow failed` and exit 1
# instead of faulting. Either way the exit code answers the question:
#
#   124  the timeout fired, so the program was still running, so the window exists   -> pass
#   1    SciterCreateWindow returned NULL                                            -> no renderer
#   139  SIGSEGV - read the trace below to see which of the two it was
#
# **Do not run this on your own X session.** A Sciter `SW_MAIN` window mode-sets the display to its own
# frame size on X11, so it will resize your desktop to 720x480. Under Xvfb or Xephyr that is contained,
# which is where CI runs it.
#
# On failure it prints the evidence that says which piece is missing, rather than leaving the next
# person to add print statements and push again. The call trace leads, because it is the only item that
# tells the two failures apart and rules candidates out rather than merely listing what is present: a
# `[wing] InitGtk4` line is the environment, an `[egl] …` line that does not come back is the renderer,
# and a bare SIGSEGV with neither is something new. The rest - libsciter.so's dependencies, the EGL
# vendor ICDs, the X server's extension list, eglinfo, glxinfo, and what Mesa says while it dies - is
# there to name the missing package once the trace says which kind of missing it is.

set -uo pipefail

cd "$(dirname "$0")/../.."

exe=target/debug/window-canary.exe
gdbcmds=target/debug/window-canary.gdb
mkdir -p target/debug

# -debug so the backtrace below has this program's own frames as well as the engine's. The engine's come
# from libsciter.so's 52,051 exported dynamic symbols either way - see docs/ENGINE.md.
odin build examples/hello_window.odin -file -debug -out:"$exe" || exit 1

timeout --kill-after=5s 20s "$exe"
code=$?

if [ "$code" = 124 ]; then
	echo "window canary: ok - a window was created and the program was still running 20s later"
	exit 0
fi

echo "::error::the engine cannot open a window on this machine (canary exited $code) - every windowed test below would fault the same way, in the engine and not in the bindings"
echo

# The backtrace first, because it is the only line of evidence that says *which* precondition is
# missing rather than which ones are present. A `-graphics-` or `-egl-` frame is a renderer problem; a
# frame in Xlib or in `wing::internal::*X11` before any GL call is an X server one, and the two have
# nothing in common but the symptom.
echo "--- how far it gets, and where it faults"
if ! command -v gdb >/dev/null; then
	sudo apt-get install -y --no-install-recommends gdb >/dev/null 2>&1 || true
fi
if command -v gdb >/dev/null; then
	# `dprintf` rather than breakpoints: it prints and continues on its own, which is the only way to
	# trace a sequence of calls from a batch script with no loop. The list is the window-creation
	# sequence in order, so the last line printed before the fault is the call that did not come back
	# the way the engine expected - and an empty EGL section says the engine never got that far, which
	# rules the renderer out rather than merely failing to implicate it.
	cat > "$gdbcmds" <<-'EOF'
		set confirm off
		set debuginfod enabled off
		set breakpoint pending on
		dprintf _ZN4wing8internal7InitX11Ev,"[wing] InitX11  (the backend that works headless)\n"
		dprintf _ZN4wing8internal8InitGtk4Ev,"[wing] InitGtk4 (XDG_SESSION_TYPE is not 'x11' - this path faults)\n"
		dprintf _ZN4wing8internal16PollMonitorsGtk4Ev,"[wing] PollMonitorsGtk4\n"
		dprintf XOpenIM,"[x11] XOpenIM\n"
		dprintf XCreateIC,"[x11] XCreateIC\n"
		dprintf XCreateWindow,"[x11] XCreateWindow\n"
		dprintf XRRGetScreenResources,"[x11] XRRGetScreenResources\n"
		dprintf eglGetDisplay,"[egl] eglGetDisplay\n"
		dprintf eglGetPlatformDisplay,"[egl] eglGetPlatformDisplay\n"
		dprintf eglInitialize,"[egl] eglInitialize\n"
		dprintf eglChooseConfig,"[egl] eglChooseConfig\n"
		dprintf eglCreateWindowSurface,"[egl] eglCreateWindowSurface\n"
		dprintf eglCreateContext,"[egl] eglCreateContext\n"
		dprintf eglMakeCurrent,"[egl] eglMakeCurrent\n"
		run
		echo \n--- backtrace at the fault\n
		thread apply all bt 25
	EOF
	timeout --kill-after=5s 120s gdb -batch -nx -x "$gdbcmds" "$exe" 2>&1 |
		grep -vE '^Function\(s\) |will be skipped when stepping|Thread debugging using|Using host libthread_db|^Function ".*" not defined\.$|^Dprintf [0-9]+ \(.*\) pending\.$' |
		tail -60
else
	echo "(gdb not available)"
fi
echo
echo "--- libsciter.so's dependencies (anything 'not found' here is the whole answer)"
ldd lib/linux/x64/libsciter.so 2>&1 | grep -E 'not found' || echo "(all resolved)"
ldd lib/linux/x64/libsciter.so 2>&1 | grep -Ei 'egl|gles|gl\.so|glx|x11|xcb|xi\.so|xrandr|xcursor|xfixes'
echo
echo "--- EGL vendor ICDs libglvnd can dispatch to (empty means libegl1 has no implementation)"
ls -l /usr/share/glvnd/egl_vendor.d/ 2>&1 || true
echo
# The first thing to check, and the cheapest: anything but the literal `x11` sends `wing::init()` into
# the GTK4 backend, which faults in `PollMonitorsGtk4` before a window is ever asked for.
echo "--- backend selection"
echo "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-(unset - the engine will pick GTK4 and fault)}"
echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-(unset)}  DISPLAY=${DISPLAY:-(unset)}"
echo
echo "--- what this X server offers (the engine wants XKB, Xi, RANDR, MIT-SHM and a 24-bit visual)"
if command -v xdpyinfo >/dev/null; then
	xdpyinfo 2>&1 | sed -n '/number of extensions/,/^default screen number/p' | head -40
	xdpyinfo 2>&1 | grep -E 'depth of root window|dimensions:|number of extensions' || true
else
	echo "(xdpyinfo not installed)"
fi
echo
echo "--- glxinfo, if it is installed"
command -v glxinfo >/dev/null && glxinfo -B 2>&1 | head -20 || echo "(glxinfo not installed)"
echo
# glxinfo passing does not mean EGL works. They are different Mesa paths on the same driver: GLX has a
# software fallback that has always worked headless, EGL-on-X11 needs the platform extension and the
# DRI device behind it, and the engine uses EGL. Ask the question the engine asks.
echo "--- eglinfo: the path the engine actually uses (mesa-utils-extra)"
if command -v eglinfo >/dev/null; then
	eglinfo -B 2>&1 | head -30 || eglinfo 2>&1 | head -30
else
	echo "(eglinfo not installed - mesa-utils-extra)"
fi
echo
echo "--- Mesa's own account (silence before the crash means it faulted before EGL was ever asked)"
EGL_LOG_LEVEL=debug LIBGL_DEBUG=verbose MESA_DEBUG=1 timeout --kill-after=5s 20s "$exe" 2>&1 | head -40

exit 1
