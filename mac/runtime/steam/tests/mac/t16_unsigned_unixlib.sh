#!/bin/bash
# t16_unsigned_unixlib.sh - test T16: the unsigned x86_64 lsteamclient.so loads
# even when quarantined (as after a browser download), and a code-signed copy
# does not (why we ship it unsigned). Re-runs the T3 probe for each variant.
# It swaps lib/wine/x86_64-unix/lsteamclient.so in the TEST runtime and always
# restores the original (trap), so run it on the peaktest runtime only.
# Part of PeakPack for Mac (runtime/steam). MIT licence (see ../../docs/README.md).
#
# Usage: t16_unsigned_unixlib.sh --runtime DIR --prefix DIR --bridge DIR [--logs DIR]
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
runtime=""; prefix=""; bridge=""; logs=""
while [ $# -gt 0 ]; do
    case "$1" in
        --runtime) runtime=$2; shift 2 ;;
        --prefix) prefix=$2; shift 2 ;;
        --bridge) bridge=$2; shift 2 ;;
        --logs) logs=$2; shift 2 ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
done
[ -n "$runtime" ] && [ -n "$prefix" ] && [ -n "$bridge" ] || { sed -n '2,12p' "$0"; exit 2; }
pp_logs "$logs"
so="$runtime/lib/wine/x86_64-unix/lsteamclient.so"
[ -f "$so" ] || { fail "no $so"; pp_finish; exit 1; }
cp -p "$so" "$LOGS/lsteamclient.so.orig"
restore() { cp -p "$LOGS/lsteamclient.so.orig" "$so"; xattr -c "$so" 2>/dev/null; say "original lsteamclient.so restored"; }
trap restore EXIT INT TERM

run_t3() {   # run_t3 NAME -> 0 when the probe got a SteamID
    "$here/t3_t5_wine_bridge.sh" --runtime "$runtime" --prefix "$prefix" --bridge "$bridge" \
        --logs "$LOGS/$1" > "$LOGS/$1.out" 2>&1
    grep -q '^PASS: T3 SteamID' "$LOGS/$1.out"
}

say "variant A: unsigned + quarantined"
cp -p "$LOGS/lsteamclient.so.orig" "$so"
xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");Safari;" "$so"
codesign -dv "$so" >/dev/null 2>&1 && fail "variant A unexpectedly signed"
xattr -p com.apple.quarantine "$so" >/dev/null 2>&1 && info "quarantine attribute set"
run_t3 unsigned-quarantined && pass "T16 unsigned + quarantined lsteamclient.so loads (T3 SteamID)" \
    || fail "T16 unsigned + quarantined copy did not work (see $LOGS/unsigned-quarantined.out)"

say "variant B: ad-hoc signed"
cp -p "$LOGS/lsteamclient.so.orig" "$so"
xattr -c "$so"
codesign -s - -f "$so" > "$LOGS/codesign-sign.txt" 2>&1
if run_t3 signed; then
    info "T16: the ad-hoc signed copy ALSO loaded on this macOS/Wine; record it (expected to fail)"
else
    pass "T16 signed copy fails to load, as expected (see $LOGS/signed.out)"
fi
pp_finish
