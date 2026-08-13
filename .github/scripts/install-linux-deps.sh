#!/usr/bin/env bash
#
# Everything a Linux runner needs to build and run this repository. One script rather than a list
# duplicated across ci.yml and canary.yml, because the two must not drift: the canary's whole job is
# to run the same checks CI runs, against a different engine.
#
# Three separate groups, and they fail differently, which is worth knowing when one of them is missing:
#
#   link-time (-dev packages)
#     The examples link native libraries directly. `integration` and `native_child` are raw Xlib, and
#     `vendor:x11/xlib` declares foreign imports for X11, Xcursor, Xfixes, Xrandr and Xi; `windowless_gl`
#     links EGL to make its own offscreen context. Missing, the build dies as
#     `/usr/bin/ld: cannot find -lX11` during `just check`, which reads like an Odin problem and is not.
#     The runner images ship the runtime .so.N files but not the undecorated .so symlinks a link needs.
#
#   run-time (the engine's own dependencies)
#     libsciter.so links 16 libraries - see docs/ENGINE.md - and the runner is missing the EGL/GLES pair
#     and the software rasteriser behind them. Missing, `sciter.load()` fails with a dlopen error
#     listing every path it tried.
#
#     `libegl1` alone is NOT enough and the distinction bites: it is libglvnd's *dispatcher*, which
#     loads whichever vendor ICD is installed and has no renderer of its own. The implementation is
#     `libegl-mesa0`, and the software rasteriser it dispatches to is in `libgl1-mesa-dri`. Without the
#     ICD, `eglInitialize` fails and the engine faults during window creation rather than reporting
#     anything - which on a headless runner presents as a segfault in the first windowed test.
#
#   fonts
#     The engine measures text through fontconfig. An image with no fonts installed does not fail
#     loudly; it makes text metrics assertions come back with wrong numbers, which reads like a
#     binding bug. Cheapest possible insurance.
#
# clang is Odin's linker driver on Linux and is normally already on the image; installed only if absent.

set -euo pipefail

sudo apt-get update

sudo apt-get install -y --no-install-recommends \
	libx11-dev libxcursor-dev libxfixes-dev libxrandr-dev libxi-dev \
	libegl-dev \
	xvfb libegl1 libegl-mesa0 libgbm1 libgl1-mesa-dri libglx-mesa0 \
	libfontconfig1 libfreetype6 fonts-dejavu-core \
	mesa-utils x11-utils

# `libgles2` is the current name of the GLESv2 runtime; older images call it `libgles2-mesa`.
sudo apt-get install -y --no-install-recommends libgles2 \
	|| sudo apt-get install -y --no-install-recommends libgles2-mesa

command -v clang >/dev/null || sudo apt-get install -y --no-install-recommends clang

# Evidence, printed while it is cheap rather than after a confusing failure:
#   - what the engine's own dependencies resolve to
#   - which EGL vendor ICDs libglvnd can see. An empty directory here means `libegl1` has nothing to
#     dispatch to, which is the difference between "no GPU" (fine, llvmpipe) and "no EGL at all".
ldd lib/linux/x64/libsciter.so
echo "--- EGL vendor ICDs:"
ls -l /usr/share/glvnd/egl_vendor.d/ 2>&1 || true
