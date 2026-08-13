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
	xvfb libegl1 libgl1-mesa-dri libglx-mesa0 \
	libfontconfig1 libfreetype6 fonts-dejavu-core

# `libgles2` is the current name of the GLESv2 runtime; older images call it `libgles2-mesa`.
sudo apt-get install -y --no-install-recommends libgles2 \
	|| sudo apt-get install -y --no-install-recommends libgles2-mesa

command -v clang >/dev/null || sudo apt-get install -y --no-install-recommends clang

# Print what the engine resolves to, so a future "it did not load" has the evidence in the log already.
ldd lib/linux/x64/libsciter.so
