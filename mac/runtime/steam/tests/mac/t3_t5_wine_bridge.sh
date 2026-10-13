#!/bin/bash
# t3_t5_wine_bridge.sh - gate G-B2 (tests T3, T4, optional T5): the bridge inside
# OUR Wine runtime, through the launcher exactly as PEAK will use it.
#   T3  steam_client_probe.exe -> steamclient64.dll forwarder -> lsteamclient.dll/.so
#       -> Mac Steam's steamclient.dylib: SteamID, logged on, ticket
#   T4  steam_api_probe.exe with PEAK's own steam_api64.dll: RestartAppIfNecessary
#       false, SteamAPI_InitEx OK, SteamID/persona, ticket via manual dispatch
#   T5  (--t5) PEAK.exe -force-d3d11 itself; then t5_check_player_log.sh
# Mac Steam must be running and logged in. Steam itself is never touched.
# Part of PeakPack for Mac (runtime/steam). MIT licence (see ../../docs/README.md).
#
# Usage: t3_t5_wine_bridge.sh --runtime DIR --prefix DIR --bridge DIR [--install-bridge]
#            [--game 'C:\Games\PEAK'] [--steam-dir DIR] [--t5 [--t5-seconds N]] [--logs DIR]
#   --bridge DIR: holds steamclient64.dll, peakpack_steam_launcher.exe, steam_client_probe.exe,
#                 steam_api_probe.exe (and lsteamclient.dll/.so for --install-bridge)
#   --install-bridge: first add lsteamclient.dll/.so to the runtime (runtime/build/add_builtin.sh)
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
runtime=""; prefix=""; bridge=""; install=0; game='C:\Games\PEAK'; t5=0; t5_seconds=180
steam_dir=$STEAM_MACOS_DEFAULT; logs=""
while [ $# -gt 0 ]; do
    case "$1" in
        --runtime) runtime=$2; shift 2 ;;
        --prefix) prefix=$2; shift 2 ;;
        --bridge) bridge=$2; shift 2 ;;
        --install-bridge) install=1; shift ;;
        --game) game=$2; shift 2 ;;
        --steam-dir) steam_dir=$2; shift 2 ;;
        --t5) t5=1; shift ;;
        --t5-seconds) t5_seconds=$2; shift 2 ;;
        --logs) logs=$2; shift 2 ;;
        *) echo "unknown argument $1 (see the header of $0)" >&2; exit 2 ;;
    esac
done
[ -n "$runtime" ] && [ -n "$prefix" ] && [ -n "$bridge" ] || { sed -n '2,20p' "$0"; exit 2; }
pp_logs "$logs"

if [ "$install" = 1 ]; then
    "$here/../../../build/add_builtin.sh" "$runtime" "$bridge/lsteamclient.dll" "$bridge/lsteamclient.so" \
        && pass "bridge added to the runtime" || { fail "add_builtin.sh"; pp_finish; exit 1; }
fi
for f in lib/wine/x86_64-windows/lsteamclient.dll lib/wine/x86_64-unix/lsteamclient.so; do
    [ -f "$runtime/$f" ] && pass "runtime has $f" || fail "runtime lacks $f (use --install-bridge)"
done
if codesign -dv "$runtime/lib/wine/x86_64-unix/lsteamclient.so" >/dev/null 2>&1; then
    fail "lsteamclient.so in the runtime is signed (Wine refuses it)"
fi
pgrep -x steam_osx >/dev/null 2>&1 || pgrep -f 'Steam.AppBundle/Steam/Contents/MacOS' >/dev/null 2>&1 \
    && pass "Mac Steam is running" || { fail "Mac Steam is not running"; pp_finish; exit 1; }

# shellcheck source=/dev/null
. "$runtime/share/peakpack/prefix/pp-env.sh"
pp_env "$runtime" "$prefix" logs || { fail "pp_env"; pp_finish; exit 1; }
export WINEDEBUG="err+all,warn+steamclient,fixme-all"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$steam_dir"
tests_dir="$WINEPREFIX/drive_c/PeakPackTests"
mkdir -p "$tests_dir"
for f in steamclient64.dll peakpack_steam_launcher.exe steam_client_probe.exe steam_api_probe.exe; do
    cp "$bridge/$f" "$tests_dir/" || fail "missing $bridge/$f"
done
launcher='C:\PeakPackTests\peakpack_steam_launcher.exe'
lopts="--forwarder-src C:\\PeakPackTests\\steamclient64.dll --log C:\\PeakPackTests\\launcher.log"

# T3/T4 measure the COLD first ticket, so the launcher's own ticket warm-up (launcher 0.2.0+, runtime pp2)
# is switched off for them; T5 (PEAK itself) keeps it, as in production. Older launchers lack the flag.
t34=""
if grep -q -- '--no-warmup' <<<"$("$WINELOADER" "$launcher" --help 2>&1)"; then t34="--no-warmup"; info "launcher has the ticket warm-up; T3/T4 run with --no-warmup, T5 with it"; fi

say "T3: probe through forwarder -> lsteamclient -> steamclient.dylib"
# shellcheck disable=SC2086
"$WINELOADER" "$launcher" $lopts $t34 -- 'C:\PeakPackTests\steam_client_probe.exe' > "$LOGS/t3.log" 2>&1
cat "$LOGS/t3.log"
[ "$(result "$LOGS/t3.log" load)" = ok ] && pass "T3 forwarder loads (steamclient64 -> lsteamclient)" || fail "T3 load"
[ "$(result "$LOGS/t3.log" logged_on)" = 1 ] && pass "T3 logged on" || fail "T3 logged_on"
sid=$(result "$LOGS/t3.log" steamid)
[ -n "$sid" ] && [ "$sid" != 0 ] && pass "T3 SteamID $sid" || fail "T3 SteamID"
[ "$(result "$LOGS/t3.log" ticket_callback_result)" = 1 ] && pass "T3 ticket callback OK" || fail "T3 ticket"
info "T3 cold first ticket: handle=$(result "$LOGS/t3.log" ticket_first_handle) len=$(result "$LOGS/t3.log" ticket_first_len) retry=$(result "$LOGS/t3.log" ticket_retry)"
grep -q "native steamclient lacks" "$LOGS/t3.log" && info "lsteamclient: $(grep -m2 'native steamclient lacks' "$LOGS/t3.log" | tr '\n' ' ')"

say "T4: PEAK's own steam_api64.dll"
api="$game\\PEAK_Data\\Plugins\\x86_64\\steam_api64.dll"
# shellcheck disable=SC2086
"$WINELOADER" "$launcher" $lopts $t34 -- 'C:\PeakPackTests\steam_api_probe.exe' "$api" > "$LOGS/t4.log" 2>&1
cat "$LOGS/t4.log"
[ "$(result "$LOGS/t4.log" restart_app_if_necessary)" = 0 ] && pass "T4 RestartAppIfNecessary = false" || fail "T4 RestartAppIfNecessary"
[ "$(result "$LOGS/t4.log" is_steam_running)" = 1 ] && pass "T4 IsSteamRunning = true (launcher pid)" || fail "T4 IsSteamRunning"
[ "$(result "$LOGS/t4.log" init)" = 0 ] && pass "T4 SteamAPI_InitEx OK" || fail "T4 InitEx: $(sed -n 's/^RESULT init_errmsg=//p' "$LOGS/t4.log")"
sid4=$(result "$LOGS/t4.log" steamid)
[ -n "$sid4" ] && [ "$sid4" != 0 ] && pass "T4 SteamID $sid4" || fail "T4 SteamID"
[ "$(result "$LOGS/t4.log" utils_appid)" = 3527290 ] && pass "T4 app id 3527290" || fail "T4 app id"
[ "$(result "$LOGS/t4.log" ticket_callback_result)" = 1 ] && pass "T4 ticket via manual dispatch" || fail "T4 ticket callback"
info "T4 cold first ticket: handle=$(result "$LOGS/t4.log" ticket_first_handle) len=$(result "$LOGS/t4.log" ticket_first_len) retry=$(result "$LOGS/t4.log" ticket_retry)"
info "T4 persona: $(sed -n 's/^RESULT persona=//p' "$LOGS/t4.log")"
cp "$tests_dir/launcher.log" "$LOGS/" 2>/dev/null

if [ "$t5" = 1 ]; then
    say "T5: starting PEAK (-force-d3d11) for $t5_seconds s; reach the main menu, then quit PEAK normally"
    # shellcheck disable=SC2086
    "$WINELOADER" "$launcher" $lopts -- "$game\\PEAK.exe" -force-d3d11 > "$LOGS/t5-wine.log" 2>&1 &
    wpid=$!
    waited=0
    while kill -0 "$wpid" 2>/dev/null && [ "$waited" -lt "$t5_seconds" ]; do sleep 5; waited=$((waited + 5)); done
    kill -0 "$wpid" 2>/dev/null && info "PEAK still running after $t5_seconds s; checking the log now (quit PEAK by hand)"
    persona=$(sed -n 's/^RESULT persona=//p' "$LOGS/t4.log" | tail -1)
    "$here/t5_check_player_log.sh" --wineprefix "$WINEPREFIX" --logs "$LOGS/t5" ${persona:+--expect-persona "$persona"} \
        && pass "T5 Player.log: Steam initialised${persona:+ with persona $persona}" || fail "T5 Player.log checks"
    cp "$tests_dir/launcher.log" "$LOGS/" 2>/dev/null
    # launcher 0.2.0+: the auth-ticket warm-up before PEAK (cold-start defence for PEAK's EOS login)
    wl=$(grep -a 'warm-up:' "$LOGS/launcher.log" 2>/dev/null | tail -n 4 | tr '\r\n' '  ')
    [ -n "$wl" ] && info "T5 launcher warm-up: $wl"
fi
pp_finish
