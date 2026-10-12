#!/bin/bash
# build_launcher.sh - build peakpack_steam_launcher.exe (Windows x86_64 console exe).
# Part of PeakPack for Mac (runtime/steam). MIT licence (see docs/README.md).
#
# Usage: build_launcher.sh [OUT_DIR]           (default: ./out next to this script)
# Env:   PE_CC (default: "zig cc -target x86_64-windows-gnu" if zig/ZIG is available,
#        else x86_64-w64-mingw32-clang or -gcc), ZIG (path to zig)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/out}
mkdir -p "$out"

if [ -z "${PE_CC:-}" ]; then
    if [ -n "${ZIG:-}" ]; then PE_CC="$ZIG cc -target x86_64-windows-gnu"
    elif command -v zig >/dev/null 2>&1; then PE_CC="zig cc -target x86_64-windows-gnu"
    elif command -v x86_64-w64-mingw32-clang >/dev/null 2>&1; then PE_CC=x86_64-w64-mingw32-clang
    else PE_CC=x86_64-w64-mingw32-gcc; fi
fi
echo "==> PE_CC=$PE_CC"

# shellcheck disable=SC2086
$PE_CC -O2 -Wall -Wextra -Wno-unused-parameter \
    -o "$out/peakpack_steam_launcher.exe" "$here/peakpack_steam_launcher.c" \
    -ladvapi32 -lshell32 -lkernel32 -s

rm -f "$out"/*.pdb "$out"/*.lib 2>/dev/null || true
if command -v sha256sum >/dev/null 2>&1; then sha=$(sha256sum "$out/peakpack_steam_launcher.exe" | cut -d' ' -f1)
else sha=$(shasum -a 256 "$out/peakpack_steam_launcher.exe" | cut -d' ' -f1); fi
echo "==> built $out/peakpack_steam_launcher.exe ($(wc -c < "$out/peakpack_steam_launcher.exe" | tr -d ' ') bytes, sha256 $sha)"
