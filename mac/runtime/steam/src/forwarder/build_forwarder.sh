#!/bin/bash
# build_forwarder.sh - build steamclient64.dll, the PeakPack export forwarder.
# Part of PeakPack for Mac (runtime/steam). MIT licence (see docs/README.md).
#
# Usage: build_forwarder.sh [OUT_DIR]          (default: ./out next to this script)
# Env:   PE_CC   PE C compiler. Default: "zig cc -target x86_64-windows-gnu" when
#                ZIG or zig is available, else x86_64-w64-mingw32-clang / -gcc
#                (llvm-mingw from runtime/build/pins.env on CI).
#        WINDRES resource compiler for non-zig toolchains (default x86_64-w64-mingw32-windres)
#        ZIG     path to zig
# The DLL imports nothing and has no CRT: every export is a PE forwarder to
# lsteamclient.dll (steamclient64.def). Built bit-for-bit reproducibly
# (no timestamp) so the same inputs give the same SHA-256.
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

res_input=""
repro="-Wl,--no-insert-timestamp"
case "$PE_CC" in
    *zig*) res_input="$here/steamclient64.rc"      # zig cc compiles .rc itself
           repro="" ;;                               # zig output has no timestamp
    *)     ${WINDRES:-x86_64-w64-mingw32-windres} -O coff -i "$here/steamclient64.rc" -o "$out/steamclient64.res.o"
           res_input="$out/steamclient64.res.o" ;;
esac

# shellcheck disable=SC2086
$PE_CC -O2 -shared -nostdlib -fno-stack-protector -mno-stack-arg-probe \
    -o "$out/steamclient64.dll" \
    "$here/forwarder.c" "$here/steamclient64.def" "$res_input" \
    -Wl,--entry=peakpack_forwarder_entry $repro -s

rm -f "$out"/*.lib "$out"/*.pdb "$out/steamclient64.res.o" 2>/dev/null || true
if command -v sha256sum >/dev/null 2>&1; then sha=$(sha256sum "$out/steamclient64.dll" | cut -d' ' -f1)
else sha=$(shasum -a 256 "$out/steamclient64.dll" | cut -d' ' -f1); fi
echo "==> built $out/steamclient64.dll ($(wc -c < "$out/steamclient64.dll" | tr -d ' ') bytes, sha256 $sha)"
