#!/bin/bash
# t0_steamclient_dylib.sh - gate G-B0 (test T0): does the installed Mac Steam
# client ship an x86_64 steamclient.dylib with the exports lsteamclient needs?
# Read-only: inspects files, never starts/stops/modifies Steam.
# Part of PeakPack for Mac (runtime/steam). MIT licence (see ../../docs/README.md).
#
# Usage: t0_steamclient_dylib.sh [STEAM_MACOS_DIR] [--logs DIR]
#   STEAM_MACOS_DIR default: ~/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
dir=$STEAM_MACOS_DEFAULT
logs=""
while [ $# -gt 0 ]; do
    case "$1" in
        --logs) logs=$2; shift 2 ;;
        *) dir=$1; shift ;;
    esac
done
pp_logs "$logs"
dylib="$dir/steamclient.dylib"

if [ ! -f "$dylib" ]; then
    fail "no $dylib (is Mac Steam installed and has it updated itself once?)"
    pp_finish; exit 1
fi
pass "found $dylib"
archs=$(lipo -archs "$dylib" 2>&1)
info "archs: $archs"
case " $archs " in
    *" x86_64 "*) pass "x86_64 slice present" ;;
    *) fail "NO x86_64 slice: B2 is blocked until an arm64 Wine exists (fall back to B1 / Track C)" ;;
esac

nm -gU -arch x86_64 "$dylib" > "$LOGS/nm-x86_64.txt" 2>&1
for sym in CreateInterface Steam_BGetCallback Steam_FreeLastCallback Steam_GetAPICallResult Steam_ReleaseThreadLocalMemory; do
    if grep -q " _$sym\$" "$LOGS/nm-x86_64.txt"; then pass "export $sym"; else fail "export $sym missing"; fi
done
for sym in Steam_IsKnownInterface Steam_NotifyMissingInterface; do
    if grep -q " _$sym\$" "$LOGS/nm-x86_64.txt"; then pass "export $sym (optional)"
    else info "export $sym absent: OK, our patch 0001 makes it optional"; fi
done

info "sha256 $(shasum -a 256 "$dylib" | cut -d' ' -f1)"
codesign -dv "$dylib" > "$LOGS/codesign.txt" 2>&1
info "signing: $(grep -E '^(Authority|TeamIdentifier)=' "$LOGS/codesign.txt" | head -2 | tr '\n' ' ')"
plist="$dir/../Info.plist"
[ -f "$plist" ] && info "Steam bundle version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null)"
manifest="$HOME/Library/Application Support/Steam/package/steam_client_osx.manifest"
[ -f "$manifest" ] && info "client manifest: $(grep -m1 '"version"' "$manifest" | tr -s ' \t' ' ')"
sw_vers > "$LOGS/sw_vers.txt"; uname -a >> "$LOGS/sw_vers.txt"
pp_finish
