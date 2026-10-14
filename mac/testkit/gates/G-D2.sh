#!/bin/bash
# TITLE: G-D2 PeakPack in the prefix: --headless --sync, modded launch loads every pack plugin, vanilla launch has no BepInEx
# Part of PeakPack for Mac (mac/testkit). MIT licence. Run through run_gate.sh.
#
# PeakPack.exe (latest pack release) goes to C:\users\<u>\AppData\Local\PeakPack\PeakPack.exe in the job's
# prefix (the only supported location, INTERFACES.md §3.1). Launch path B2 (PeakPack DESIGN §18.6):
# peakpack_steam_launcher.exe --no-launch --hold-ms advertises the bridge as the running Steam and stays
# alive, while PeakPack starts PEAK.exe directly (--launch-method direct, SteamAppId set by PeakPack).
#   1. PeakPack --headless --status            exit 0 expected (status file recorded)
#   2. PeakPack --headless --sync              exit 0 (exit 3 = foreign loader -> rerun with --adopt, recorded)
#   3. modded:  --headless --launch --launch-method direct; BepInEx LogOutput.log rewritten after the launch,
#      "Chainloader startup complete", every "N plugins to load" loaded, no load errors; agent screenshot (CU-modded)
#   4. vanilla: --headless --launch --vanilla --launch-method direct; Player.log rewritten with Steam initialised,
#      LogOutput.log NOT rewritten, no BepInEx/Doorstop lines in Player.log
# Optional list of plugin names that must load: expect/pack-plugins.txt or --expect-plugins FILE.
# Args: [--expect-plugins FILE] [--sync-timeout S] (default 900) [--launch-timeout S] (default 300)
set -u
. "$PP_KIT_DIR/lib/common.sh"
. "$PP_KIT_DIR/lib/assets.sh"
gate_begin G-D2 "PeakPack modded and vanilla launch"
gate_require_mac
gate_require_gui   # Wine/Unity windows need the logged-in GUI session (blocked otherwise)
expect="$PP_KIT_DIR/expect/pack-plugins.txt"; sync_to=900; launch_to=300
while [ $# -gt 0 ]; do
  case "$1" in --expect-plugins) expect=$2; shift 2 ;; --sync-timeout) sync_to=$2; shift 2 ;; --launch-timeout) launch_to=$2; shift 2 ;; *) shift ;; esac
done
rosetta_ok || gate_finish_as blocked "Rosetta 2 is not installed (P0)"
steam_running || gate_finish_as needs-human "Mac Steam is not running" "Run H-STEAM (Steam open and signed in under the fleet user), then re-run G-D2."
keep_awake
ensure_runtime || gate_finish_as blocked "runtime not available (run G-A1 first)"
ensure_tests >/dev/null 2>&1
ensure_bridge || note "bridge files missing:$BRIDGE_MISSING"
[ -f "$BRIDGE/peakpack_steam_launcher.exe" ] && [ -f "$BRIDGE/steamclient64.dll" ] || gate_finish_as blocked "Steam launcher/forwarder missing from the runtime (share/peakpack/steam)"
ensure_prefix || gate_finish_as error "prefix creation failed (logs/G-D2/create-prefix.log)"
ensure_game_in_prefix || gate_finish_as blocked "PEAK is not in the job dir (run G-B5 first)"
ensure_peakpack || gate_finish_as blocked "could not download PeakPack.exe (latest pack release)"
crit peakpack_placed pass "PeakPack.exe in C:\\users\\<u>\\AppData\\Local\\PeakPack" "$(job_env_get PEAKPACK_TAG | grep . || echo releases/latest), sha256 $(sha256_of "$DL/PeakPack.exe" | cut -c1-16)..."
GATE_CLEANUP=wine_stop
tests_dir="$PFX/drive_c/PeakPackTests"; mkdir -p "$tests_dir"
cp "$BRIDGE/peakpack_steam_launcher.exe" "$BRIDGE/steamclient64.dll" "$tests_dir/"
wu=$(wine_user)
PPEXE="C:\\users\\$wu\\AppData\\Local\\PeakPack\\PeakPack.exe"
ppdir=$(peakpack_win_dir)
bep_log="$ppdir/profile/BepInEx/LogOutput.log"
plog=$(player_log_path)

peakpack() {  # peakpack NAME TIMEOUT_S ARGS... -> exit code; status JSON copied to logs/G-D2/NAME.status.json
  local name=$1 to=$2 rc pid t0; shift 2
  rm -f "$tests_dir/$name.json"
  PP_EXTRA_OVERRIDES="winhttp=n,b" pp_wine normal "$PPEXE" --headless "$@" --game-dir 'C:\Games\PEAK' --status-out "C:\\PeakPackTests\\$name.json" > "$GLOG/$name.out" 2>&1 &
  pid=$!; t0=$(now_s)
  while kill -0 "$pid" 2>/dev/null; do
    if [ $(( $(now_s) - t0 )) -ge "$to" ]; then kill "$pid" 2>/dev/null; echo "timeout after ${to}s" >> "$GLOG/$name.out"; wait "$pid" 2>/dev/null; return 124; fi
    sleep 3
  done
  wait "$pid"; rc=$?
  [ -f "$tests_dir/$name.json" ] && cp "$tests_dir/$name.json" "$GLOG/$name.status.json"
  return "$rc"
}
st() { json_get "$GLOG/$1.status.json" "$2"; }   # status file keys are camelCase (FriendInstaller DESIGN 18.8)
start_steam_hold() {
  pp_wine normal 'C:\PeakPackTests\peakpack_steam_launcher.exe' --forwarder-src 'C:\PeakPackTests\steamclient64.dll' \
    --log "C:\\PeakPackTests\\launcher-$1.log" --no-launch --hold-ms 1500000 > "$GLOG/launcher-$1.out" 2>&1 &
  sleep 8
}

# ---- 1. status
peakpack status 300 --status; rc=$?
metric status_exit "$rc"; metric peakpack_app_version "$(st status appVersion)" str
version_set peakpack_app "$(st status appVersion)"
case $rc in 0) crit pp_status pass "PeakPack --headless --status under Wine" "$(st status message)" ;;
  *) crit pp_status fail "PeakPack --headless --status under Wine" "exit $rc: $(st status message) $(head -c 300 "$GLOG/status.out")"; gate_end ;; esac

# ---- 2. sync
peakpack sync "$sync_to" --sync; rc=$?
if [ "$rc" = 3 ]; then note "sync exit 3 (foreign mod loader in the game folder); re-running with --adopt"; peakpack sync-adopt "$sync_to" --sync --adopt; rc=$?; fi
metric sync_exit "$rc"; metric installed_revision "$(st sync installedRevision)"
version_set pack_revision "$(st sync installedRevision)"
case $rc in 0) crit pp_sync pass "PeakPack --headless --sync" "revision $(st sync installedRevision): $(st sync message)" ;;
  *) crit pp_sync fail "PeakPack --headless --sync" "exit $rc: $(st sync message) / $(st sync problem.heading)"; gate_end ;; esac
[ -f "$ppdir/profile/BepInEx/core/BepInEx.Preloader.dll" ] && crit profile pass "profile has BepInEx core" || crit profile fail "profile has BepInEx core"
find "$ppdir/profile/BepInEx/plugins" -name '*.dll' 2>/dev/null | sed "s#^$ppdir/##" | sort > "$GLOG/profile-plugin-dlls.txt"
metric plugin_dlls "$(wc -l < "$GLOG/profile-plugin-dlls.txt" | tr -d ' ')"

# ---- 3. modded launch
start_steam_hold modded
t_mod=$(now_s)
peakpack launch-modded 300 --launch --launch-method direct; rc=$?
metric launch_modded_exit "$rc"
cmdline=$(st launch-modded commandLine); metric launch_modded_cmdline "$cmdline" str
case $rc in 0) crit launch_modded pass "PeakPack --launch (modded, direct)" "launched=$(st launch-modded launched)" ;;
  *) crit launch_modded fail "PeakPack --launch (modded, direct)" "exit $rc: $(st launch-modded message)"; gate_end ;; esac
case "$cmdline" in *-force-d3d11*) crit mac_extra_args pass "Mac extra args from the signed manifest (-force-d3d11)" ;;
  *) crit mac_extra_args info "Mac extra args from the signed manifest (-force-d3d11)" "not in the command line: the current pack revision has no platforms.mac.extraArgs?" ;; esac
if wait_for_file_text "$bep_log" "Chainloader startup complete" "$launch_to" "$t_mod"; then
  crit bepinex_started pass "BepInEx LogOutput.log rewritten after the launch, chainloader complete"
else
  crit bepinex_started fail "BepInEx chainloader complete within ${launch_to}s" "$( [ -f "$bep_log" ] && tail -3 "$bep_log" | tr '\n' ' ' || echo 'no LogOutput.log')"
fi
sleep 20
snap peak-modded-menu-script
cu_request modded 180 "Modded PEAK should be on screen (started by PeakPack). Wait for the main menu. Screenshot evidence/G-D2/peak-modded-main-menu.png. If a mod shows a notice or version text (e.g. PeakPack/companion), note it. Answer ok if the main menu works, fail <what> if it is black/crashed/stuck. Do not click in PEAK; the script quits it."
cu_m=$?
[ -f "$bep_log" ] && cp "$bep_log" "$GLOG/LogOutput-modded.log"
[ -f "$plog" ] && cp "$plog" "$GLOG/Player-modded.log"
wine_stop
L="$GLOG/LogOutput-modded.log"
if [ -f "$L" ]; then
  n_expect=$(sed -n 's/.*\] \([0-9][0-9]*\) plugins\{0,1\} to load.*/\1/p' "$L" | tail -1)
  n_loaded=$(grep -a -c '\] Loading \[' "$L" | tr -d ' ')
  grep -a 'Loading \[' "$L" | sed 's/.*Loading \[\(.*\)\].*/\1/' > "$GLOG/plugins-loaded.txt"
  grep -a -E '\[(Error|Fatal) *: *BepInEx\]|Could not load \[|Skipping \[|Error loading \[|missing dependenc|incompatible' "$L" > "$GLOG/bepinex-errors.txt"
  n_err=$(wc -l < "$GLOG/bepinex-errors.txt" | tr -d ' ')
  grep -a -E '\[(Error|Fatal) *:' "$L" > "$GLOG/all-error-lines.txt"
  metric any_error_lines "$(wc -l < "$GLOG/all-error-lines.txt" | tr -d ' ')"
  metric plugins_to_load "${n_expect:-0}"; metric plugins_loaded "$n_loaded"; metric bepinex_error_lines "$n_err"
  metric bepinex_version "$(grep -a -m1 -o 'BepInEx [0-9][0-9.]*' "$L")" str
  if [ -n "$n_expect" ] && [ "$n_loaded" -ge "$n_expect" ] && [ "$n_loaded" -gt 0 ]; then crit all_plugins pass "every plugin BepInEx found was loaded" "$n_loaded of $n_expect"
  else crit all_plugins fail "every plugin BepInEx found was loaded" "${n_loaded} of ${n_expect:-?}"; fi
  if [ "$n_err" = 0 ]; then crit no_load_errors pass "no BepInEx load errors"; else crit no_load_errors fail "no BepInEx load errors" "$n_err line(s): $(head -2 "$GLOG/bepinex-errors.txt" | tr '\n' ' ')"; fi
  if [ -f "$expect" ]; then
    miss=""
    while IFS= read -r name; do
      name=$(printf '%s' "$name" | tr -d '\r'); case "$name" in ''|'#'*) continue ;; esac
      grep -a -F -q "Loading [$name " "$L" || miss="$miss [$name]"
    done < "$expect"
    if [ -z "$miss" ]; then crit expected_plugins pass "every plugin in $(basename "$expect") loaded"; else crit expected_plugins fail "every plugin in $(basename "$expect") loaded" "missing:$miss"; fi
  else
    crit expected_plugins skip "named pack plugins loaded" "no expect/pack-plugins.txt (list recorded in logs/G-D2/plugins-loaded.txt)"
  fi
fi
case $cu_m in 0) crit modded_menu pass "modded PEAK reaches the main menu (agent)" "$CU_NOTE" ;;
  1) crit modded_menu fail "modded PEAK reaches the main menu (agent)" "$CU_NOTE" ;;
  *) crit modded_menu skip "modded PEAK reaches the main menu (agent)" "$CU_ANSWER" ;; esac

# ---- 4. vanilla launch
bep_mtime=$(mtime_of "$bep_log")
sleep 2
start_steam_hold vanilla
t_van=$(now_s)
peakpack launch-vanilla 300 --launch --vanilla --launch-method direct; rc=$?
metric launch_vanilla_exit "$rc"
case $rc in 0) crit launch_vanilla pass "PeakPack --launch --vanilla" "launched=$(st launch-vanilla launched)" ;;
  *) crit launch_vanilla fail "PeakPack --launch --vanilla" "exit $rc: $(st launch-vanilla message)" ;; esac
if wait_for_file_text "$plog" "Steam runtime manager initialized" "$launch_to" "$t_van"; then
  crit vanilla_started pass "vanilla PEAK started (new Player.log, Steam initialised)"
else
  crit vanilla_started fail "vanilla PEAK started within ${launch_to}s"
fi
sleep 15
snap peak-vanilla-menu
[ -f "$plog" ] && cp "$plog" "$GLOG/Player-vanilla.log"
wine_stop
if [ "$(mtime_of "$bep_log")" = "$bep_mtime" ]; then crit vanilla_no_bepinex pass "vanilla launch did not start BepInEx (LogOutput.log untouched)"
else crit vanilla_no_bepinex fail "vanilla launch did not start BepInEx" "LogOutput.log was rewritten"; fi
if [ -f "$GLOG/Player-vanilla.log" ] && ! grep -a -i -q -E 'BepInEx|Doorstop|Chainloader' "$GLOG/Player-vanilla.log"; then
  crit vanilla_player_log pass "no BepInEx/Doorstop lines in the vanilla Player.log"
else crit vanilla_player_log fail "no BepInEx/Doorstop lines in the vanilla Player.log"; fi
cp "$ppdir/log.txt" "$GLOG/peakpack-log.txt" 2>/dev/null
gate_end
