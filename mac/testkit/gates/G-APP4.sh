#!/bin/bash
# TITLE: G-APP4 PEAK (Modded).app options window: Show FPS on, Play with Mods, every pack plugin loads, Metal HUD, PEAK ends
# Part of PeakPack for Mac (mac/testkit). MIT licence. Run through run_gate.sh.
#
# Needs G-APP3. The app is opened with --options --no-autoplay (its options window, no autostart). The agent ticks
# "Show FPS" and clicks "Play with Mods". Then the same checks as G-D2's modded part: BepInEx's LogOutput.log is
# rewritten after the launch, "Chainloader startup complete", every "N plugins to load" plugin loaded, no load errors,
# every name in expect/pack-plugins.txt loaded. The app's own status says lastLaunch=modded. The agent checks the
# Metal HUD (Show FPS) and reads the fps. Then PEAK ends like in G-APP3, the agent unticks Show FPS in the options
# window, and the app is quit (it stays running after PEAK when opened with --options).
# Args: [--app-release TAG] [--launch-timeout S] (default 300)
set -u
. "$PP_KIT_DIR/lib/common.sh"
. "$PP_KIT_DIR/lib/assets.sh"
. "$PP_KIT_DIR/lib/app.sh"
gate_begin G-APP4 "PEAK (Modded).app options window: Play with Mods, plugins load, Metal HUD"
gate_require_mac
tag_arg=""; launch_to=300
while [ $# -gt 0 ]; do
  case "$1" in --app-release) tag_arg=$2; shift 2 ;; --launch-timeout) launch_to=$2; shift 2 ;; *) shift ;; esac
done
expect="$PP_KIT_DIR/expect/pack-plugins.txt"
app_tag_resolve "$tag_arg" || gate_finish_as blocked "no app release tag: pass --app-release, set PP_APP_RELEASE, or run G-APP1 first"
rosetta_ok || gate_finish_as blocked "Rosetta 2 is not installed (G-APP1 needs it)"
gate_require_gui
keep_awake
GATE_CLEANUP=app_wine_stop
ensure_app; rc=$?
case $rc in 0) ;; 2) crit app_download fail "app zip matches its SHA256SUMS" "see G-APP1"; gate_end ;; *) gate_finish_as blocked "app release $APP_TAG is not available (run G-APP1)" ;; esac
case "$(app_status_get phase)" in
  done|ready) ;;
  *) gate_finish_as blocked "the app is not set up in this job: run G-APP1 to G-APP3 first" ;;
esac

# ---- 1. options window
app_launch --options --no-autoplay || gate_finish_as error "could not start the app with --options"
wait_for_phase ready 180; rc=$?
case $rc in
  0) crit options_ready pass "app opens with phase ready (options window)" ;;
  2) crit options_ready fail "app opens with phase ready" "phase error: $(app_status_get problem.code) $(app_status_get problem.heading)"; gate_end ;;
  *) crit options_ready fail "app opens with phase ready within 180 s" "phase '$APP_PHASE_SEEN'"; gate_end ;;
esac
t_cu=$(now_s)
cu_request options 300 "The PEAK (Modded) options window is open. 1) Tick the 'Show FPS' checkbox (it shows the Metal HUD). 2) Click 'Play with Mods'. Do NOT click 'Play Normal PEAK' and do not click the other buttons. Screenshot before the first click: bash testkit/cu.sh \"$JOB\" shot G-APP4 options-window. Answer ok once you clicked Play with Mods, or fail with what you see."
rc=$?
case $rc in
  0) crit options_cu pass "agent ticked Show FPS and clicked Play with Mods" "$CU_NOTE" ;;
  1) crit options_cu fail "agent ticked Show FPS and clicked Play with Mods" "$CU_NOTE"; gate_end ;;
  2) gate_finish_as blocked "computer use is off (--no-cu): the options window needs clicks" ;;
  *) gate_finish_as error "no answer to the options step within 300 s" ;;
esac

# ---- 2. the modded launch reached the app and BepInEx
wait_for_phase "launching|playing" "$launch_to"; rc=$?
[ "$rc" = 0 ] && wait_for_phase playing "$launch_to"
if [ "$(app_status_get phase)" = playing ]; then crit modded_playing pass "app reports phase playing (modded)"
else crit modded_playing fail "app reports phase playing (modded)" "phase '$APP_PHASE_SEEN' ($(app_status_get problem.code))"; app_wine_stop; gate_end; fi
bep=$(app_bepinex_log)
if wait_for_file_text "$bep" "Chainloader startup complete" "$launch_to" "$t_cu"; then
  crit bepinex_started pass "BepInEx LogOutput.log rewritten after the launch, chainloader complete"
else
  crit bepinex_started fail "BepInEx chainloader complete within ${launch_to}s" "$( [ -f "$bep" ] && tail -3 "$bep" | tr '\n' ' ' || echo 'no LogOutput.log')"
fi
sleep 20
[ -f "$bep" ] && cp "$bep" "$GLOG/LogOutput-modded.log"
L="$GLOG/LogOutput-modded.log"
if [ -f "$L" ]; then
  n_expect=$(sed -n 's/.*\] \([0-9][0-9]*\) plugins\{0,1\} to load.*/\1/p' "$L" | tail -1)
  n_loaded=$(grep -a -c '\] Loading \[' "$L" | tr -d ' ')
  grep -a 'Loading \[' "$L" | sed 's/.*Loading \[\(.*\)\].*/\1/' > "$GLOG/plugins-loaded.txt"
  bepinex_load_errors "$L"
  n_err=$(wc -l < "$GLOG/bepinex-errors.txt" | tr -d ' ')
  grep -a -E '\[(Error|Fatal) *:' "$L" > "$GLOG/all-error-lines.txt"
  metric any_error_lines "$(wc -l < "$GLOG/all-error-lines.txt" | tr -d ' ')"
  metric plugins_to_load "${n_expect:-0}"; metric plugins_loaded "$n_loaded"; metric bepinex_error_lines "$n_err"
  metric bepinex_version "$(grep -a -m1 -o 'BepInEx [0-9][0-9.]*' "$L")" str
  if [ -n "$n_expect" ] && [ "$n_loaded" -ge "$n_expect" ] && [ "$n_loaded" -gt 0 ]; then crit all_plugins pass "every plugin BepInEx found was loaded" "$n_loaded of $n_expect"
  else crit all_plugins fail "every plugin BepInEx found was loaded" "${n_loaded} of ${n_expect:-?}"; fi
  if [ "$n_err" = 0 ]; then crit no_load_errors pass "no BepInEx load errors"
  else crit no_load_errors fail "no BepInEx load errors" "$n_err line(s): $(head -2 "$GLOG/bepinex-errors.txt" | tr '\n' ' ')"; fi
  if [ -f "$expect" ]; then
    miss=""
    while IFS= read -r name; do
      name=$(printf '%s' "$name" | tr -d '\r'); case "$name" in ''|'#'*) continue ;; esac
      grep -a -F -q "Loading [$name " "$L" || miss="$miss [$name]"
    done < "$expect"
    if [ -z "$miss" ]; then crit expected_plugins pass "every plugin in $(basename "$expect") loaded"
    else crit expected_plugins fail "every plugin in $(basename "$expect") loaded" "missing:$miss"; fi
  else
    crit expected_plugins skip "named pack plugins loaded" "no expect/pack-plugins.txt"
  fi
fi
sl="$APP_PFX/drive_c/PeakPackMac/status-launch.json"
[ -f "$sl" ] && cp "$sl" "$GLOG/status-launch.json"
cmdline=$(json_get "$sl" commandLine); metric launch_commandline "$cmdline" str
metric status_launch_launched "$(json_get "$sl" launched)" str
case "$cmdline" in
  *-force-d3d11*) crit mac_extra_args pass "Mac extra args from the signed manifest (-force-d3d11) on the launch" ;;
  *) crit mac_extra_args info "Mac extra args from the signed manifest (-force-d3d11) on the launch" "not in the command line (or no status-launch.json)" ;;
esac
ll=$(app_status_get lastLaunch)
if [ "$ll" = modded ]; then crit launch_mode pass "app status lastLaunch is modded" "$ll"
else crit launch_mode fail "app status lastLaunch is modded" "got '$ll'"; fi

# ---- 3. Metal HUD (agent)
cu_request_peak hud 300 "PEAK is running modded, started by the app. With 'Show FPS' on, the Metal HUD (an FPS overlay) should show in the corner of the screen. Wait about 30 s for the value to settle. Do not click in PEAK. Screenshot: bash testkit/cu.sh \"$JOB\" shot G-APP4 peak-modded-hud. Answer ok fps=<the number the HUD shows>, or fail with what you see (no HUD, black screen, crash). Example: bash testkit/cu.sh \"$JOB\" done G-APP4.hud ok \"HUD visible\" fps=58"
rc=$?
fps=$(cu_kv fps)
[ -n "$fps" ] && metric fps "$fps"
case $rc in
  0) crit metal_hud pass "Metal HUD visible with the modded PEAK (agent)" "fps ${fps:-not given}" ;;
  1) crit metal_hud fail "Metal HUD visible with the modded PEAK (agent)" "$CU_NOTE" ;;
  *) crit metal_hud skip "Metal HUD visible with the modded PEAK (agent)" "$CU_ANSWER ${CU_NOTE:-}" ;;
esac

# ---- 4. end PEAK like a friend (as G-APP3)
if app_end_peak quit "In PEAK use the main menu's Quit button. Confirm if PEAK asks. Do not click anything else or any macOS prompt. Answer ok when PEAK is gone, or fail with what you see."; then
  crit peak_exit pass "PEAK exited ($END_METHOD)"
else
  crit peak_exit fail "PEAK exited" "still running after the menu step and wineserver -k"
fi

# ---- 5. untick Show FPS again; the app is still running (opened with --options)
cu_request fpsoff 300 "PEAK has quit. The PEAK (Modded) app is still running (it was opened with its options window). Bring that window up: click the app's Dock icon if no window is visible (or use the PEAK menu > Show Options). Untick the 'Show FPS' checkbox. Do not click Play with Mods or Play Normal PEAK. Screenshot: bash testkit/cu.sh \"$JOB\" shot G-APP4 options-after. Answer ok when Show FPS is unticked, or fail with what you see."
rc=$?
case $rc in
  0) crit fps_unticked pass "Show FPS unticked again (agent)" "$CU_NOTE" ;;
  1) crit fps_unticked fail "Show FPS unticked again (agent)" "$CU_NOTE" ;;
  *) crit fps_unticked skip "Show FPS unticked again (agent)" "$CU_ANSWER ${CU_NOTE:-}" ;;
esac

# ---- 6. quit the app
if app_quit; then crit app_quit pass "app quit"
else crit app_quit fail "app quit" "still running after 30 s"; fi
app_wine_stop
gate_end
