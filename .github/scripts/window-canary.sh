#!/usr/bin/env bash
#
# Can the engine create a window on this machine at all?
#
# Ask once, in seconds, before the forty-five minute test job - because the answer "no" is invisible in
# that job's output. When `wing::window::create` fails, the engine's own cleanup path faults:
#
#   #0  XDestroyIC ()                        from libX11.so.6
#   #1  wing::internal::DestroyWindowX11 ()   from libsciter.so
#   #2  wing::window::destroy ()
#   #3  wing::window::create ()
#   #4  xwing::application::create_frame ()
#   #5  SciterCreateWindowImp ()
#
# so every windowed test dies with SIGSEGV inside `create_window`, the Odin test runner then hangs
# rather than reaping the thread, and each example burns the whole EXAMPLE_TEST_TIMEOUT. Twenty-odd
# examples segfaulting identically reads like a broken binding; it is one missing renderer. Note that
# this is a *different* crash from the `XSetICFocus` one in README.md, and `XMODIFIERS=@im=none` does
# not prevent it - that one needs a window, this one happens because there is not going to be one.
#
# The canary is `hello_window` because it is the smallest thing that opens a window and it does it on
# the main thread, where the same failure usually degrades to `SciterCreateWindow failed` and exit 1
# instead of faulting. Either way the exit code answers the question:
#
#   124  the timeout fired, so the program was still running, so the window exists   -> pass
#   1    SciterCreateWindow returned NULL                                            -> no renderer
#   139  SIGSEGV in the cleanup path above                                           -> no renderer
#
# **Do not run this on your own X session.** A Sciter `SW_MAIN` window mode-sets the display to its own
# frame size on X11, so it will resize your desktop to 720x480. Under Xvfb or Xephyr that is contained,
# which is where CI runs it.
#
# On failure it prints the evidence that says which piece is missing, rather than leaving the next
# person to add print statements and push again: what libsciter.so's GL dependencies resolve to, which
# EGL vendor ICDs libglvnd can see, and what Mesa says while it fails.

set -uo pipefail

cd "$(dirname "$0")/../.."

exe=target/debug/window-canary.exe
mkdir -p target/debug

odin build examples/hello_window.odin -file -out:"$exe" || exit 1

timeout --kill-after=5s 20s "$exe"
code=$?

if [ "$code" = 124 ]; then
	echo "window canary: ok - a window was created and the program was still running 20s later"
	exit 0
fi

echo "::error::the engine cannot create a window here (canary exited $code) - every windowed test below would fault inside SciterCreateWindow"
echo
echo "--- libsciter.so's GL dependencies"
ldd lib/linux/x64/libsciter.so | grep -Ei 'egl|gles|gl\.so|glx' || echo "(none resolved)"
echo
echo "--- EGL vendor ICDs libglvnd can dispatch to (empty means libegl1 has no implementation)"
ls -l /usr/share/glvnd/egl_vendor.d/ 2>&1 || true
echo
echo "--- Mesa's own account of the failure (unfiltered - silence here means libglvnd found no ICD to ask)"
EGL_LOG_LEVEL=debug LIBGL_DEBUG=verbose MESA_DEBUG=1 timeout --kill-after=5s 20s "$exe" 2>&1 | head -40
echo
echo "--- glxinfo, if it is installed"
command -v glxinfo >/dev/null && glxinfo -B 2>&1 | head -20 || echo "(glxinfo not installed)"

exit 1
