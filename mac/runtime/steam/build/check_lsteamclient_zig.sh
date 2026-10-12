#!/bin/bash
# check_lsteamclient_zig.sh - compile-only check of the staged, patched
# lsteamclient sources with Zig, without a Wine build tree or a Mac.
#
# Part of PeakPack for Mac (runtime/steam). Catches patch/header breakage on
# any machine (Windows git-bash included) before the real build on the Mac/CI.
#   unix side (*.cpp): zig c++ -target x86_64-macos  -fsyntax-only
#   PE side   (*.c)  : zig cc  -target x86_64-windows-gnu -fsyntax-only (Wine msvcrt headers)
#
# Usage: check_lsteamclient_zig.sh <staged lsteamclient dir> <wine source include dir> [jobs]
#   e.g. check_lsteamclient_zig.sh "$PP_WORK/steam/src/lsteamclient" "$PP_WORK/src/wine/include" 8
# Env: ZIG (path to zig; default: zig on PATH)
set -uo pipefail

src=${1:?staged lsteamclient dir}
winc=${2:?wine include dir}
jobs=${3:-4}
ZIG=${ZIG:-zig}
src=$(cd "$src" && pwd)
winc=$(cd "$winc" && pwd)
defs="-D__WINESRC__ -DSTEAM_API_EXPORTS -Dprivate=public -Dprotected=public"

# libc++ headers pull in <wchar.h>, which collides with Wine's __WINESRC__
# poison macros for wcsncpy & co. when Wine's headers come first. Pre-include
# the C++ headers lsteamclient uses so they are parsed before Wine's.
pre="-include cwchar -include string -include unordered_map -include vector -include array -include type_traits"

check_one() {
    f=$1
    case "$f" in
        *.cpp) out=$("$ZIG" c++ -target x86_64-macos -std=c++17 -fsyntax-only $pre $defs -DWINE_UNIX_LIB \
                      -I"$src" -I"$winc" "$src/$f" 2>&1) ;;
        *.c)   out=$("$ZIG" cc -target x86_64-windows-gnu -fsyntax-only -nostdinc -isystem "$winc/msvcrt" \
                      $defs -D__WINE_PE_BUILD -I"$src" -I"$winc" "$src/$f" 2>&1) ;;
    esac
    errs=$(printf '%s\n' "$out" | grep -E ': error:' | grep -v 'failed to rename')
    if [ -n "$errs" ]; then printf 'FAIL %s\n%s\n' "$f" "$errs"; else printf 'ok   %s\n' "$f"; fi
}
export -f check_one
export ZIG src winc defs pre

files=$(cd "$src" && sed -E -n 's/^[[:space:]]*([A-Za-z0-9_]+\.(c|cpp))[[:space:]]*\\?[[:space:]]*$/\1/p' Makefile.in)
[ -n "$files" ] || { echo "no SOURCES in $src/Makefile.in" >&2; exit 2; }
total=$(printf '%s\n' "$files" | wc -l | tr -d ' ')
echo "==> checking $total sources with $jobs jobs"
results=$(printf '%s\n' "$files" | xargs -P "$jobs" -I{} bash -c 'check_one "$@"' _ {})
printf '%s\n' "$results" | grep -v '^ok' || true
fails=$(printf '%s\n' "$results" | grep -c '^FAIL' || true)
echo "==> $((total - fails))/$total sources passed"
[ "$fails" = 0 ]
