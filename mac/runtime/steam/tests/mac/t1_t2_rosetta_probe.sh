#!/bin/bash
# t1_t2_rosetta_probe.sh - gate G-B1 (tests T1, T2): an x86_64 process under
# Rosetta talks to the running, logged-in Mac Steam client through Valve's own
# steamclient.dylib: SteamID, logged-on state, persona, app id, then an auth
# session ticket (T2). No Wine involved. Uses the player's real login; Steam
# is not modified, started or stopped by this script.
# Part of PeakPack for Mac (runtime/steam). MIT licence (see ../../docs/README.md).
#
# Needs: Rosetta 2, Xcode Command Line Tools (clang), Mac Steam running and logged in
#        with an account that owns PEAK.
# Usage: t1_t2_rosetta_probe.sh [--steam-dir DIR] [--hold SECONDS] [--logs DIR]
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
dir=$STEAM_MACOS_DEFAULT
hold=30
logs=""
while [ $# -gt 0 ]; do
    case "$1" in
        --steam-dir) dir=$2; shift 2 ;;
        --hold) hold=$2; shift 2 ;;
        --logs) logs=$2; shift 2 ;;
        *) echo "usage: $0 [--steam-dir DIR] [--hold SECONDS] [--logs DIR]" >&2; exit 2 ;;
    esac
done
pp_logs "$logs"

arch -x86_64 /usr/bin/true 2>/dev/null && pass "Rosetta 2 available" || { fail "Rosetta 2 missing (softwareupdate --install-rosetta, Joshua approves)"; pp_finish; exit 1; }
if pgrep -x steam_osx >/dev/null 2>&1 || pgrep -f 'Steam.AppBundle/Steam/Contents/MacOS' >/dev/null 2>&1; then
    pass "Mac Steam is running"
else
    fail "Mac Steam is not running: start it and log in (by hand), then re-run"; pp_finish; exit 1
fi

probe="$LOGS/steam_client_probe"
clang -arch x86_64 -O1 -Wall -o "$probe" "$here/../probe/steam_client_probe.c" 2> "$LOGS/build.log" \
    && pass "probe built (x86_64)" || { fail "probe build failed (see build.log)"; pp_finish; exit 1; }
[ "$(lipo -archs "$probe")" = x86_64 ] || fail "probe is not x86_64"

say "running probe under Rosetta; it holds the connection for $hold s"
say ">>> While it runs, look at Mac Steam (friends list / your profile): it should show you playing PEAK."
# screencapture only on request (it raises macOS's Screen Recording prompt otherwise)
if [ "${PP_SCREENSHOTS:-0}" = 1 ]; then ( sleep $(( hold / 2 + 5 )); screencapture -x "$LOGS/steam-while-probe.png" 2>/dev/null ) & fi
STEAM_COMPAT_CLIENT_INSTALL_PATH="$dir" arch -x86_64 "$probe" --lib "$dir/steamclient.dylib" --hold "$hold" \
    > "$LOGS/probe.log" 2>&1
rc=$?
wait
cat "$LOGS/probe.log"
log="$LOGS/probe.log"

[ "$(result "$log" load)" = ok ] && pass "T1 steamclient.dylib loads in an x86_64 process" || fail "T1 dylib load"
[ "$(result "$log" client)" = ok ] && pass "T1 CreateInterface(SteamClient021)" || fail "T1 CreateInterface"
[ "$(result "$log" logged_on)" = 1 ] && pass "T1 BLoggedOn = 1" || fail "T1 not logged on (exit $rc)"
sid=$(result "$log" steamid)
[ -n "$sid" ] && [ "$sid" != 0 ] && pass "T1 SteamID $sid" || fail "T1 SteamID"
[ "$(result "$log" appid)" = 3527290 ] && pass "T1 app id 3527290" || fail "T1 app id is '$(result "$log" appid)'"
info "persona: $(sed -n 's/^RESULT persona=//p' "$log")"
tl=$(result "$log" ticket_len)
[ -n "$tl" ] && [ "$tl" -gt 0 ] && pass "T2 auth session ticket ($tl bytes)" || fail "T2 no ticket"
[ "$(result "$log" ticket_callback_result)" = 1 ] && pass "T2 GetAuthSessionTicketResponse k_EResultOK" || fail "T2 ticket callback result '$(result "$log" ticket_callback_result)'"
info "ownership (client view): subscribed=$(result "$log" subscribed) subscribed_app=$(result "$log" subscribed_app)"
info "cold first ticket: handle=$(result "$log" ticket_first_handle) len=$(result "$log" ticket_first_len) retry=$(result "$log" ticket_retry) (retry=1: the first, cold request returned no ticket)"
info "ticket identity: $(result "$log" ticket_identity) (PEAK passes its own SteamID); NULL-identity call: handle=$(result "$log" ticket_null_handle) len=$(result "$log" ticket_null_len) cb=$(result "$log" ticket_null_callback_result)"
info "manual check: did Mac Steam show 'Playing PEAK' during the hold? (screenshot: steam-while-probe.png if allowed)"
pp_finish
