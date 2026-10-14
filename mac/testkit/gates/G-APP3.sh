#!/bin/bash
# TITLE: G-APP3 PEAK (Modded).app daily launch (as a Dock click): PEAK starts modded, the main menu draws, PEAK quits, the app quits
# Part of PeakPack for Mac (mac/testkit). MIT licence. Run through run_gate.sh.
#
# Needs G-APP2 (setup done, the app quit). The app is started WITHOUT --no-autoplay, the way a Dock click starts it:
# after setup it starts PEAK modded at once (phase launching, then playing). The script checks the PEAK process,
# Player.log ("Steam runtime manager initialized: True"), the main menu (agent, CU-mainmenu), then ends PEAK
# (agent, CU-quit: the main menu's Quit button; after 180 s the script stops the app's prefix with wineserver -k).
# The app must quit by itself within 60 s after PEAK is gone (it does so after a modded daily launch).
# Args: [--app-release TAG] [--start-timeout S] (default 300) [--main-menu-timeout S] (default 600)
set -u
. "$PP_KIT_DIR/lib/common.sh"
. "$PP_KIT_DIR/lib/assets.sh"
. "$PP_KIT_DIR/lib/app.sh"
gate_begin G-APP3 "PEAK (Modded).app daily launch: modded PEAK starts, main menu, PEAK quits, the app quits"
gate_require_mac
tag_arg=""; start_to=300; menu_to=600
while [ $# -gt 0 ]; do
  case "$1" in
    --app-release) tag_arg=$2; shift 2 ;;
    --start-timeout) start_to=$2; shift 2 ;;
    --main-menu-timeout) menu_to=$2; shift 2 ;;
    *) shift ;;
  esac
done
app_tag_resolve "$tag_arg" || gate_finish_as blocked "no app release tag: pass --app-release, set PP_APP_RELEASE, or run G-APP1 first"
rosetta_ok || gate_finish_as blocked "Rosetta 2 is not installed (G-APP1 needs it)"
gate_require_gui
keep_awake
GATE_CLEANUP=app_wine_stop
ensure_app; rc=$?
case $rc in 0) ;; 2) crit app_download fail "app zip matches its SHA256SUMS" "see G-APP1"; gate_end ;; *) gate_finish_as blocked "app release $APP_TAG is not available (run G-APP1)" ;; esac

# ---- 1. preconditions: setup done in this job (G-APP2), no PEAK left over from an earlier run
app_require_setup "run G-APP1 and G-APP2 first"
if app_peak_running; then
  log "PEAK from an earlier run is still running: stopping this job's leftovers first"
  app_job_stop_leftovers || gate_finish_as error "PEAK is still running from before this gate (not this job's prefix)"
fi

# ---- 2. start the app like a Dock click (no --no-autoplay)
t_launch=$(now_s)
app_launch || gate_finish_as error "could not start the app"
wait_for_phase "launching|playing" "$start_to"; rc=$?
case $rc in
  0) crit daily_launching pass "app enters phase launching (or playing) after the start" "after $(( $(now_s) - t_launch )) s" ;;
  2) crit daily_launching fail "app enters phase launching" "phase error: $(app_status_get problem.code) $(app_status_get problem.heading)"; gate_end ;;
  *) crit daily_launching fail "app enters phase launching within ${start_to} s" "phase '$APP_PHASE_SEEN'"; gate_end ;;
esac
wait_for_phase playing "$start_to"; rc=$?
if [ "$rc" = 0 ]; then
  metric time_to_playing_s "$(( $(now_s) - t_launch ))"
  crit daily_playing pass "app enters phase playing" "after $(( $(now_s) - t_launch )) s"
else
  crit daily_playing fail "app enters phase playing within ${start_to} s" "phase '$APP_PHASE_SEEN' ($(app_status_get problem.code))"
  app_wine_stop
  gate_end
fi
last0=$(app_status_get lastLaunch)
metric last_launch_status "$last0" str

# ---- 3. the PEAK process and its Player.log
t0=$(now_s); seen=0
while [ $(( $(now_s) - t0 )) -lt 120 ]; do
  if app_peak_running; then seen=1; break; fi
  sleep 3
done
if [ "$seen" = 1 ]; then crit peak_process pass "a PEAK.exe process runs (Wine)"
else crit peak_process fail "a PEAK.exe process runs (Wine)" "none within 120 s"; fi
plog=$(app_player_log)
if wait_for_file_text "$plog" "Steam runtime manager initialized: True" 240 "$t_launch"; then
  crit steam_init pass "Player.log rewritten: 'Steam runtime manager initialized: True'"
else
  crit steam_init fail "Player.log rewritten: 'Steam runtime manager initialized: True' within 240 s" "$( [ -f "$plog" ] && grep -a -i 'steam' "$plog" | tail -2 | tr '\n' ' ' || echo 'no Player.log')"
fi
cp "$plog" "$GLOG/Player-daily.log" 2>/dev/null
if [ -f "$GLOG/Player-daily.log" ]; then
  if grep -a -q "Successfully got user token" "$GLOG/Player-daily.log"; then metric eos_login "user token" str
  elif grep -a -q "Failed to authenticate" "$GLOG/Player-daily.log"; then
    metric eos_login "failed to authenticate" str
    crit eos_login warn "EOS sign-in (Player.log)" "'Failed to authenticate' in Player.log (recorded only)"
  else metric eos_login "not in Player.log" str; fi
fi
# The window hides itself about 4 s after phase playing: record what the status says, nothing more.
sleep 6
metric phase_after_playing "$(app_status_get phase)" str

# ---- 4. the main menu (agent)
cu_request_peak mainmenu "$menu_to" "PEAK should be running, started by the app (the app's window hides itself). Wait until the PEAK main menu is fully drawn (no loading screen). Do not click anything in PEAK. If a macOS microphone prompt appears, do NOT click Allow or Don't Allow: screenshot it as dialog-1 and say so in your answer. Screenshot: bash testkit/cu.sh \"$JOB\" shot G-APP3 peak-main-menu-app. Answer ok (the main menu is fully drawn), or fail with what you see."
rc=$?
case $rc in
  0) crit main_menu pass "PEAK main menu fully drawn (agent)" "$CU_NOTE" ;;
  1) crit main_menu fail "PEAK main menu fully drawn (agent)" "$CU_NOTE" ;;
  *) crit main_menu skip "PEAK main menu fully drawn (agent)" "$CU_ANSWER ${CU_NOTE:-}" ;;
esac

# ---- 5. end PEAK like a friend (main menu's Quit), then the app must quit by itself
if app_end_peak quit "In PEAK use the main menu's Quit button. Confirm if PEAK asks. Do not click anything else, and do not click any macOS prompt. Answer ok when PEAK is gone (it is closed within about a minute), or fail with what you see."; then
  crit peak_exit pass "PEAK exited ($END_METHOD)" "CU-quit answer: ${CU_ANSWER:-none}"
else
  crit peak_exit fail "PEAK exited" "still running after the menu step and wineserver -k"
fi
t_gone=$(now_s)
while app_running && [ $(( $(now_s) - t_gone )) -lt 60 ]; do sleep 2; done
if app_running; then
  crit app_exit fail "the app quits by itself within 60 s after PEAK is gone" "still running"
  app_quit
else
  crit app_exit pass "the app quits by itself within 60 s after PEAK is gone" "after $(( $(now_s) - t_gone )) s"
fi

# ---- 6. the status after the daily launch
ll=$(app_status_get lastLaunch)
if [ "$ll" = modded ]; then crit last_launch pass "status lastLaunch is modded" "$ll"
else crit last_launch fail "status lastLaunch is modded" "got '$ll'"; fi
if app_no_problem; then crit no_problem pass "status has no problem"
else crit no_problem fail "status has no problem" "$(app_status_get problem.code): $(app_status_get problem.heading)"; fi
app_wine_stop
gate_end
