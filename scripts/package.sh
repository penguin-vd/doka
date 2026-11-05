#!/bin/sh
# The editor packaged to hand out, with its libraries inside, in zig-out/dist/. Linux builds in a
# container on Ubuntu 24.04, so the AppImage runs on that glibc (2.39) and anything newer.
#   scripts/package.sh                 this host's own
#   scripts/package.sh linux macos     only those (macos needs a Mac)
# PACKAGE_PLATFORM=linux/amd64 picks the AppImage's architecture; by default, this machine's.
set -eu
cd "$(dirname "$0")/.."
dist=$PWD/zig-out/dist
mkdir -p "$dist"

# The starter looks go in the package (CC BY-SA 4.0, with their CREDITS.txt): made once.
looks() {
    if ! ls zig-out/package/looks/*.cube >/dev/null 2>&1; then
        mkdir -p zig-out/package/looks
        python3 -I scripts/starter-looks.py "$HOME/.cache/doka/HaldCLUT.zip" zig-out/package/looks
    fi
}

linux() {
    looks
    engine=$(command -v docker || command -v podman) || { echo "linux: needs docker or podman" >&2; return 1; }
    platform=${PACKAGE_PLATFORM:+--platform=$PACKAGE_PLATFORM}
    "$engine" build $platform -q -t doka-package -f scripts/package/Dockerfile scripts/package >/dev/null
    "$engine" run --rm $platform -u "$(id -u):$(id -g)" -v "$PWD:/src:ro" -v "$dist:/dist" doka-package sh /src/scripts/package/appimage.sh
}

macos() {
    [ "$(uname -s)" = Darwin ] || { echo "macos: build it on a Mac (it copies Homebrew's libraries)" >&2; return 1; }
    looks
    # Baseline: any Apple Silicon, not only this machine's chip.
    zig build -Doptimize=ReleaseSafe -Dcpu=baseline
    python3 -I scripts/package/macos.py zig-out/bin/doka "$dist/Doka.app"
    (cd "$dist" && rm -f Doka-macos.zip && ditto -c -k --keepParent Doka.app Doka-macos.zip)
    echo "zig-out/dist/Doka.app, zig-out/dist/Doka-macos.zip"
}

if [ $# -eq 0 ]; then
    case "$(uname -s)" in
        Darwin) set -- macos ;;
        *) set -- linux ;;
    esac
fi
for platform_name in "$@"; do
    case "$platform_name" in
        linux) linux ;;
        macos) macos ;;
        *) echo "unknown platform: $platform_name" >&2; exit 1 ;;
    esac
done
