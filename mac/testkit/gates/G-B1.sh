#!/bin/bash
# TITLE: G-B1 (T1/T2) x86_64 probe under Rosetta reaches the logged-in Mac Steam: SteamID, logged on, auth ticket
# Part of PeakPack for Mac (mac/testkit). MIT licence. Run through run_gate.sh.
#
# With the Xcode CLT: runs the Steam team's tests/mac/t1_t2_rosetta_probe.sh (builds the probe with clang).
# Without them: runs a prebuilt x86_64 macOS probe from the Steam test kit (probe/steam_client_probe-macos-x86_64,
# requested from CI in NOTES-for-lead.md) and applies the same checks. Neither available -> blocked.
# During the hold, the hub's agent checks that Mac Steam shows "Playing PEAK" (computer use, step CU-playing).
# Privacy: the SteamID and persona stay in logs/; results JSON only says whether they are valid.
# Args: [--hold SECONDS] (default 90) [--steam-dir DIR]
set -u
. "$PP_KIT_DIR/lib/common.sh"
. "$PP_KIT_DIR/lib/assets.sh"
gate_begin G-B1 "Rosetta probe talks to Mac Steam"
gate_require_mac
hold=90; dir=$STEAM_MACOS_DIR
while [ $# -gt 0 ]; do case "$1" in --hold) hold=$2; shift 2 ;; --steam-dir) dir=$2; shift 2 ;; *) shift ;; esac; done

rosetta_ok || gate_finish_as blocked "Rosetta 2 is not installed (P0)"
[ -f "$dir/steamclient.dylib" ] || gate_finish_as blocked "no steamclient.dylib (Mac Steam not installed or never started once)"
# Requires only a running Steam client (no login files are read); this gate's BLoggedOn is the login proof.
steam_running || gate_finish_as needs-human "Mac Steam is not running (the hub may start it: open -a Steam, then re-run G-B1)" "Open Steam under the fleet user (sign in with Remember me if it asks), leave it running, then re-run G-B1."
ensure_tests || note "no Steam test kit available (release asset peakpack-steam-tests-* or repo copy)"

probe_log=""; mode=""
stop_bg() { [ -n "${bgpid:-}" ] && kill "$bgpid" 2>/dev/null; return 0; }
GATE_CLEANUP=stop_bg

if clt_ok && [ -n "${TESTS:-}" ] && [ -f "$TESTS/mac/t1_t2_rosetta_probe.sh" ]; then
  mode=t1_t2-script
  bash "$TESTS/mac/t1_t2_rosetta_probe.sh" --steam-dir "$dir" --hold "$hold" --logs "$GLOG/t1_t2" > "$GLOG/t1_t2.out" 2>&1 &
  bgpid=$!
  probe_log="$GLOG/t1_t2/probe.log"
else
  pre=""
  for c in "${TESTS:-/nonexistent}/probe/steam_client_probe-macos-x86_64" "$PP_KIT_DIR/probes/out/steam_client_probe-macos-x86_64"; do
    [ -f "$c" ] && { pre=$c; break; }
  done
  [ -n "$pre" ] || gate_finish_as blocked "no Xcode CLT (to build the probe) and no prebuilt steam_client_probe-macos-x86_64 in the Steam test kit" \
    "Either the hub installs the Xcode Command Line Tools (Joshua's call, see P0), or CI adds the prebuilt probe to peakpack-steam-tests-* (NOTES-for-lead.md R2)."
  mode=prebuilt-probe
  cp "$pre" "$GTMP/steam_client_probe"; chmod +x "$GTMP/steam_client_probe"
  file -b "$GTMP/steam_client_probe" | grep -q x86_64 || gate_finish_as error "prebuilt probe is not x86_64: $(file -b "$GTMP/steam_client_probe")"
  probe_log="$GLOG/probe.log"
  ( STEAM_COMPAT_CLIENT_INSTALL_PATH="$dir" arch -x86_64 "$GTMP/steam_client_probe" --lib "$dir/steamclient.dylib" --hold "$hold" > "$probe_log" 2>&1 ) &
  bgpid=$!
fi
metric method "$mode" str

# While the probe holds the connection: the agent looks at Mac Steam.
sleep 12
snap steam-during-probe
cu_request playing $(( hold - 20 )) "Within the next minute: click the Steam window, open the Friends list (Friends > Show Friends List, or the friends icon at the bottom right). Does your own entry show 'Playing PEAK' (or 'In-Game PEAK')? Take screenshot evidence/G-B1/steam-playing-peak.png. Answer ok if it says PEAK, fail if it shows Online/no game. Do not click anything else in Steam."
cu_rc=$?
wait "$bgpid"; rc=$?; bgpid=""
GATE_CLEANUP=""
[ "$mode" = t1_t2-script ] && cat "$GLOG/t1_t2.out"
metric probe_exit "$rc"
[ -f "$probe_log" ] || gate_finish_as error "probe produced no log ($probe_log)"
cp "$probe_log" "$GLOG/probe-copy.log" 2>/dev/null

r() { sed -n "s/^RESULT $1=\([^ ]*\).*/\1/p" "$probe_log" | tail -1; }
[ "$(r load)" = ok ] && crit t1_load pass "steamclient.dylib loads in an x86_64 process under Rosetta" || crit t1_load fail "steamclient.dylib loads in an x86_64 process" "$(sed -n 's/^RESULT load=//p' "$probe_log" | tail -1)"
[ "$(r client)" = ok ] && crit t1_client pass "CreateInterface(SteamClient021)" || crit t1_client fail "CreateInterface(SteamClient021)" "$(r client)"
[ "$(r logged_on)" = 1 ] && crit t1_logged_on pass "BLoggedOn = 1" || crit t1_logged_on fail "BLoggedOn = 1" "logged_on=$(r logged_on) connected=$(r connected)"
sid=$(r steamid)
if [ -n "$sid" ] && [ "$sid" != 0 ]; then crit t1_steamid pass "real SteamID returned" "76561...${sid#"${sid%????}"}"; else crit t1_steamid fail "real SteamID returned" "steamid=$sid"; fi
[ "$(r appid)" = "$PEAK_APPID" ] && crit t1_appid pass "app id $PEAK_APPID" || crit t1_appid fail "app id $PEAK_APPID" "got '$(r appid)'"
[ -n "$(sed -n 's/^RESULT persona=//p' "$probe_log")" ] && metric persona_present true || metric persona_present false
tl=$(r ticket_len)
if [ -n "$tl" ] && [ "$tl" -gt 0 ] 2>/dev/null; then crit t2_ticket pass "auth session ticket returned" "$tl bytes"; else crit t2_ticket fail "auth session ticket returned" "ticket_len=$tl"; fi
[ "$(r ticket_callback_result)" = 1 ] && crit t2_ticket_cb pass "GetAuthSessionTicketResponse = k_EResultOK" || crit t2_ticket_cb fail "GetAuthSessionTicketResponse = k_EResultOK" "result=$(r ticket_callback_result)"
for e in Steam_IsKnownInterface Steam_NotifyMissingInterface; do metric "export_$e" "$(r "export_$e")"; done
case $cu_rc in
  0) crit playing_peak pass "Mac Steam shows 'Playing PEAK' during the hold (agent)" "$CU_NOTE" ;;
  1) crit playing_peak fail "Mac Steam shows 'Playing PEAK' during the hold (agent; DESIGN §7 G-B1)" "agent saw no game: $CU_NOTE" ;;
  *) crit playing_peak skip "Mac Steam shows 'Playing PEAK' during the hold (agent)" "$CU_ANSWER" ;;
esac
gate_end
