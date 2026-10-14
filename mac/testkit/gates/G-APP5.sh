#!/bin/bash
# TITLE: G-APP5 PEAK (Modded).app "Play Normal PEAK" from the options window: vanilla launch, no BepInEx, PEAK ends, the app quits
# Part of PeakPack for Mac (mac/testkit). MIT licence. Run through run_gate.sh.
#
# Needs G-APP4. The app is opened with --options --no-autoplay; the agent clicks "Play Normal PEAK". Checks (as the
# vanilla part of G-D2): Player.log is rewritten with "Steam runtime manager initialized", BepInEx's LogOutput.log is
# NOT rewritten (its modification time is unchanged), Player.log has no BepInEx/Doorstop/Chainloader text, the app's
# status says lastLaunch=vanilla. PEAK then ends like in G-APP3 and the app is quit.
# Args: [--app-release TAG] [--launch-timeout S] (default 300)
set -u
. "$PP_KIT_DIR/lib/common.sh"
. "$PP_KIT_DIR/lib/assets.sh"
. "$PP_KIT_DIR/lib/app.sh"
gate_begin G-APP5 "PEAK (Modded).app: Play Normal PEAK (vanilla) from the options window"
gate_require_mac
tag_arg=""; launch_to=300
while [ $# -gt 0 ]; do
  case "$1" in --app-release) tag_arg=$2; shift 2 ;; --launch-timeout) launch_to=$2; shift 2 ;; *) shift ;; esac
done
app_tag_resolve "$tag_arg" || gate_finish_as blocked "no app release tag: pass --app-release, set PP_APP_RELEASE, or run G-APP1 first"
rosetta_ok || gate_finish_as blocked "Rosetta 2 is not installed (G-APP1 needs it)"
gate_require_gui
keep_awake
GATE_CLEANUP=app_wine_stop
ensure_app; rc=$?
case $rc in 0) ;; 2) crit app_download fail "app zip matches its SHA256SUMS" "see G-APP1"; gate_end ;; *) gate_finish_as blocked "app release $APP_TAG is not available (run G-APP1)" ;; esac
case "$(app_status_get phase)" in
  done|ready) ;;
  *) gate_finish_as blocked "the app is not set up in this job: run G-APP1 to G-APP4 first" ;;
esac

# ---- 1. options window
app_launch --options --no-autoplay || gate_finish_as error "could not start the app with --options"
wait_for_phase ready 180; rc=$?
case $rc in
  0) crit options_ready pass "app opens with phase ready (options window)" ;;
  2) crit options_ready fail "app opens with phase ready" "phase error: $(app_status_get problem.code) $(app_status_get problem.heading)"; gate_end ;;
  *) crit options_ready fail "app opens with phase ready within 180 s" "phase '$APP_PHASE_SEEN'"; gate_end ;;
esac
bep=$(app_bepinex_log)
bep_before=$(mtime_of "$bep")
[ -f "$bep" ] || bep_before=0
t_cu=$(now_s)
cu_request playnormal 300 "The PEAK (Modded) options window is open. Click 'Play Normal PEAK' (the button without mods). Do not tick or untick anything and do not click 'Play with Mods'. Screenshot before the click: bash testkit/cu.sh \"$JOB\" shot G-APP5 options-before-click. Answer ok once you clicked Play Normal PEAK, or fail with what you see."
rc=$?
case $rc in
  0) crit playnormal_cu pass "agent clicked Play Normal PEAK" "$CU_NOTE" ;;
  1) crit playnormal_cu fail "agent clicked Play Normal PEAK" "$CU_NOTE"; gate_end ;;
  2) gate_finish_as blocked "computer use is off (--no-cu): the options window needs clicks" ;;
  *) gate_finish_as error "no answer to the options step within 300 s" ;;
esac

# ---- 2. vanilla PEAK started, Steam initialised
wait_for_phase "launching|playing" "$launch_to"; rc=$?
[ "$rc" = 0 ] && wait_for_phase playing "$launch_to"
if [ "$(app_status_get phase)" = playing ]; then crit vanilla_playing pass "app reports phase playing (vanilla)"
else crit vanilla_playing fail "app reports phase playing (vanilla)" "phase '$APP_PHASE_SEEN' ($(app_status_get problem.code))"; app_wine_stop; gate_end; fi
t0=$(now_s); seen=0
while [ $(( $(now_s) - t0 )) -lt 120 ]; do
  if app_peak_running; then seen=1; break; fi
  sleep 3
done
if [ "$seen" = 1 ]; then crit peak_process pass "a PEAK.exe process runs (Wine)"
else crit peak_process fail "a PEAK.exe process runs (Wine)" "none within 120 s"; fi
plog=$(app_player_log)
if wait_for_file_text "$plog" "Steam runtime manager initialized" "$launch_to" "$t_cu"; then
  crit vanilla_started pass "Player.log rewritten: Steam runtime manager initialized (vanilla)"
else
  crit vanilla_started fail "Player.log rewritten: Steam runtime manager initialized within ${launch_to}s" "looked in $(rel_to_job "$plog"): $( [ -f "$plog" ] && printf 'modified %s s after the click, last line: %s' "$(( $(mtime_of "$plog") - t_cu ))" "$(tail -1 "$plog" | cut -c1-120)" || printf 'missing (prefix users: %s)' "$(users_seen "$APP_PFX")")"
fi
sleep 15
[ -f "$plog" ] && cp "$plog" "$GLOG/Player-vanilla.log"

# ---- 3. no BepInEx in the vanilla launch
bep_after=$(mtime_of "$bep")
[ -f "$bep" ] || bep_after=0
if [ "$bep_after" = "$bep_before" ]; then crit vanilla_no_bepinex pass "vanilla launch did not start BepInEx (LogOutput.log untouched)"
else crit vanilla_no_bepinex fail "vanilla launch did not start BepInEx" "LogOutput.log was rewritten"; fi
if [ -f "$GLOG/Player-vanilla.log" ] && ! grep -a -i -q -E 'BepInEx|Doorstop|Chainloader' "$GLOG/Player-vanilla.log"; then
  crit vanilla_player_log pass "no BepInEx/Doorstop/Chainloader lines in the vanilla Player.log"
elif [ -f "$GLOG/Player-vanilla.log" ]; then crit vanilla_player_log fail "no BepInEx/Doorstop/Chainloader lines in the vanilla Player.log" \
  "$(rel_to_job "$plog"): $(grep -a -i -m2 -E 'BepInEx|Doorstop|Chainloader' "$GLOG/Player-vanilla.log" | tr '\n' ' ' | cut -c1-240)"
else crit vanilla_player_log fail "no BepInEx/Doorstop/Chainloader lines in the vanilla Player.log" "no vanilla Player.log: $(path_detail "$plog")"; fi
ll=$(app_status_get lastLaunch)
if [ "$ll" = vanilla ]; then crit last_launch pass "app status lastLaunch is vanilla" "$ll"
else crit last_launch fail "app status lastLaunch is vanilla" "got '$ll'"; fi

# ---- 4. end PEAK like a friend (main menu's Quit), then quit the app
if app_end_peak quit "In PEAK use the main menu's Quit button. Confirm if PEAK asks. Do not click anything else or any macOS prompt. Answer ok when PEAK is gone, or fail with what you see."; then
  crit peak_exit pass "PEAK exited ($END_METHOD)"
else
  crit peak_exit fail "PEAK exited" "still running after the menu step and wineserver -k"
fi
if app_quit; then crit app_quit pass "app quit"
else crit app_quit fail "app quit" "still running after 30 s"; fi
app_wine_stop
gate_end
