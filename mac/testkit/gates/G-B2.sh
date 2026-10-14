#!/bin/bash
# TITLE: G-B2 (T3-T5) Steam bridge inside our Wine: probe via forwarder, PEAK's steam_api64.dll, then PEAK itself
# Part of PeakPack for Mac (mac/testkit). MIT licence. Run through run_gate.sh.
#
# Wraps the Steam team's tests/mac/t3_t5_wine_bridge.sh unchanged:
#   --runtime <job>/runtime/<id> --prefix <job>/prefix --bridge <job>/bridge --game 'C:\Games\PEAK' --t5
# (the bridge is already merged into the runtime tarball, so no --install-bridge). T5 starts PEAK.exe
# -force-d3d11 through peakpack_steam_launcher.exe; the hub's agent confirms the main menu renders
# (CU-mainmenu: the DXMT render proof when G-A1 had no probe) and the script reads Player.log.
# Needs: G-A1 (runtime + prefix), G-B5 (game in the job dir), Mac Steam running + signed in.
# Args: [--t5-seconds N] (default 240)
set -u
. "$PP_KIT_DIR/lib/common.sh"
. "$PP_KIT_DIR/lib/assets.sh"
gate_begin G-B2 "Steam bridge in Wine (T3-T5)"
gate_require_mac
gate_require_gui   # Wine/Unity windows need the logged-in GUI session (blocked otherwise)
t5s=240
while [ $# -gt 0 ]; do case "$1" in --t5-seconds) t5s=$2; shift 2 ;; *) shift ;; esac; done
rosetta_ok || gate_finish_as blocked "Rosetta 2 is not installed (P0)"
steam_running || gate_finish_as needs-human "Mac Steam is not running" "Run H-STEAM (Steam open and signed in under the fleet user), then re-run G-B2."
keep_awake
ensure_runtime || gate_finish_as blocked "runtime not available (run G-A1 first)"
ensure_tests && [ -f "$TESTS/mac/t3_t5_wine_bridge.sh" ] || gate_finish_as blocked "Steam test kit (t3_t5_wine_bridge.sh) not available in $(release_tag)"
ensure_bridge || gate_finish_as blocked "bridge files missing:$BRIDGE_MISSING (runtime share/peakpack/steam or the Steam test kit's probe/)"
ensure_prefix || gate_finish_as error "prefix creation failed (logs/G-B2/create-prefix.log)"
ensure_game_in_prefix || gate_finish_as blocked "PEAK is not in the job dir (run G-B5 first)"
GATE_CLEANUP=wine_stop
mkdir -p "$PP_LOG_DIR"

launch_t0=$(now_s)
bash "$TESTS/mac/t3_t5_wine_bridge.sh" --runtime "$RT" --prefix "$PFX" --bridge "$BRIDGE" \
  --game 'C:\Games\PEAK' --t5 --t5-seconds "$t5s" --logs "$GLOG/t3_t5" > "$GLOG/t3_t5.out" 2>&1 &
tpid=$!
# While T5 runs: wait for PEAK's Player.log to show Steam initialised, then ask for the main-menu check.
plog=$(player_log_path)
if wait_for_file_text "$plog" "Steam runtime manager initialized" $(( t5s - 30 )) "$launch_t0"; then
  sleep 20
  snap peak-main-menu-script
  cu_request mainmenu 120 "PEAK should be on screen (started by the test). Wait until the main menu is fully drawn (title art, buttons). Screenshot evidence/G-B2/peak-main-menu.png. Answer ok if the menu renders correctly (no black screen, no garbled colours or missing text), fail <what is wrong> otherwise. Do not click anything in PEAK; the script quits it."
  cu_rc=$?
else
  cu_rc=9
  note "Player.log did not show the Steam line within $(( t5s - 30 )) s; skipping the main-menu check"
fi
wait "$tpid"; trc=$?
cat "$GLOG/t3_t5.out"
metric t3_t5_exit "$trc"
o="$GLOG/t3_t5.out"
chk() {  # chk ID "PASS-line prefix" "description" "FAIL-line prefix"
  if grep -q "^PASS: $2" "$o"; then crit "$1" pass "$3" "$(grep -m1 "^PASS: $2" "$o" | sed 's/^PASS: //; s/SteamID [0-9]*/SteamID (valid)/; s/with persona .*/with persona (found)/')"
  elif grep -q "^FAIL: $4" "$o"; then crit "$1" fail "$3" "$(grep -m1 "^FAIL: $4" "$o" | sed 's/^FAIL: //')"
  else crit "$1" fail "$3" "no result line (see logs/G-B2/t3_t5.out)"; fi
}
chk t3_load "T3 forwarder loads" "T3: forwarder -> lsteamclient.dll/.so -> steamclient.dylib loads" "T3 load"
chk t3_logged_on "T3 logged on" "T3: logged on" "T3 logged_on"
chk t3_steamid "T3 SteamID" "T3: real SteamID" "T3 SteamID"
chk t3_ticket "T3 ticket callback OK" "T3: auth ticket" "T3 ticket"
chk t4_restart "T4 RestartAppIfNecessary = false" "T4: RestartAppIfNecessary false" "T4 RestartAppIfNecessary"
chk t4_running "T4 IsSteamRunning = true" "T4: IsSteamRunning true (launcher pid)" "T4 IsSteamRunning"
chk t4_init "T4 SteamAPI_InitEx OK" "T4: SteamAPI_InitEx OK with PEAK's steam_api64.dll" "T4 InitEx"
chk t4_steamid "T4 SteamID" "T4: real SteamID through steam_api64.dll" "T4 SteamID"
chk t4_appid "T4 app id 3527290" "T4: app id 3527290" "T4 app id"
chk t4_ticket "T4 ticket via manual dispatch" "T4: ticket via manual dispatch" "T4 ticket callback"
chk t5_player_log "T5 Player.log" "T5: Player.log shows 'Steam runtime manager initialized: True' (+ persona)" "T5 Player.log"
# T5h (launcher 0.2.0+, runtime pp2): the Mac app's model, the launcher holds and PEAK is started separately
if grep -q -E '^(PASS|FAIL): T5h' "$o"; then
  chk t5h_hold "T5h hold-until-exit" "T5h: launcher --hold-until-exit held while PEAK ran, exit 0 after it exited" "T5h hold"
  chk t5h_player_log "T5h Player.log" "T5h: Steam initialised with PEAK started outside the launcher" "T5h Player.log"
else
  crit t5h_hold skip "T5h: launcher --hold-until-exit" "launcher without the option (runtime pp1)"
fi
# Cold start (tests 1.1.0+): did the FIRST ticket request return a ticket? PEAK's EOS login uses its first.
for t in t3 t4; do
  f="$GLOG/t3_t5/$t.log"; [ -f "$f" ] || continue
  rt=$(tr -d '\r' < "$f" | sed -n 's/^RESULT ticket_retry=\([^ ]*\).*/\1/p' | tail -1)   # Windows probes: CRLF
  fl=$(tr -d '\r' < "$f" | sed -n 's/^RESULT ticket_first_len=\([^ ]*\).*/\1/p' | tail -1)
  [ -n "$rt" ] && metric "${t}_ticket_retry" "$rt" && metric "${t}_ticket_first_len" "${fl:-0}"
  case "$rt" in
    0) crit "${t}_cold_ticket" pass "$t: first (cold) ticket request returns a ticket" "len $fl" ;;
    1) crit "${t}_cold_ticket" warn "$t: first (cold) ticket request returns a ticket" "first len ${fl:-0}; the retry after 3 s decided ${t}_ticket" ;;
  esac
done
grep -q 'native steamclient lacks' "$GLOG/t3_t5/t3.log" 2>/dev/null && note "lsteamclient: $(grep -m2 'native steamclient lacks' "$GLOG/t3_t5/t3.log" | tr '\n' ' ')"
[ -f "$GLOG/t3_t5/t5/t5_summary.txt" ] && cp "$GLOG/t3_t5/t5/t5_summary.txt" "$GLOG/"
# DXMT evidence from the logs-mode run (t3_t5 uses pp_env ... logs)
dxl=$(find "$PP_LOG_DIR" -type f 2>/dev/null | grep -E -i -c 'd3d11|dxgi|dxmt' | tr -d ' ')
metric dxmt_log_files "${dxl:-0}"
case $cu_rc in
  0) crit main_menu_render pass "PEAK main menu renders (D3D11 -> DXMT, agent)" "$CU_NOTE" ;;
  1) crit main_menu_render fail "PEAK main menu renders (D3D11 -> DXMT, agent)" "$CU_NOTE" ;;
  9) crit main_menu_render fail "PEAK main menu renders" "PEAK did not get far enough (no Steam line in Player.log)" ;;
  *) crit main_menu_render skip "PEAK main menu renders (agent)" "$CU_ANSWER" ;;
esac
[ -f "$plog" ] && { cp "$plog" "$GLOG/Player.log"; metric player_log_lines "$(wc -l < "$plog" | tr -d ' ')"; }
gate_end
