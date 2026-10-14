#!/bin/bash
# lib.sh - shared helpers for the PeakPack Steam bridge gate scripts (bash 3.2).
# Part of PeakPack for Mac (runtime/steam). MIT licence (see ../../docs/README.md).
# Source it: . "$(dirname "$0")/lib.sh"

PP_PASS=0
PP_FAIL=0
pp_logs() {
    # pp_logs [dir] -> sets LOGS (default ./logs-<test>-<timestamp>)
    LOGS=${1:-./logs-$(basename "$0" .sh)-$(date +%Y%m%d-%H%M%S)}
    mkdir -p "$LOGS"
    LOGS=$(cd "$LOGS" && pwd)
    echo "logs: $LOGS"
}
say()  { printf '==> %s\n' "$*"; }
pass() { printf 'PASS: %s\n' "$*"; PP_PASS=$((PP_PASS + 1)); [ -n "${LOGS:-}" ] && printf 'PASS: %s\n' "$*" >> "$LOGS/summary.txt"; return 0; }
fail() { printf 'FAIL: %s\n' "$*"; PP_FAIL=$((PP_FAIL + 1)); [ -n "${LOGS:-}" ] && printf 'FAIL: %s\n' "$*" >> "$LOGS/summary.txt"; return 0; }
info() { printf 'INFO: %s\n' "$*"; [ -n "${LOGS:-}" ] && printf 'INFO: %s\n' "$*" >> "$LOGS/summary.txt"; return 0; }
# result FILE KEY -> value of the last "RESULT KEY=value" line (first word only)
# The Windows probes (T3/T4) write CRLF (C runtime text mode): carriage returns are dropped before matching.
result() { tr -d '\r' < "$1" | sed -n "s/^RESULT $2=\([^ ]*\).*/\1/p" | tail -1; }
pp_finish() {
    printf '== %s: %d passed, %d failed (logs: %s)\n' "$(basename "$0")" "$PP_PASS" "$PP_FAIL" "${LOGS:-}"
    [ "$PP_FAIL" -eq 0 ]
}
# shellcheck disable=SC2034  # used by the test scripts that source this file
STEAM_MACOS_DEFAULT="$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS"
