#!/bin/bash
# TITLE: G-APP2 PEAK (Modded).app game step: Steam console paste (or an existing PEAK folder), verify, PeakPack and mods, quit
# Part of PeakPack for Mac (mac/testkit). MIT licence. Run through run_gate.sh.
#
# Needs G-APP1: the app is at its game step, waiting. Mode A (default, the friend's way): the agent clicks the app's
# "Open Steam Console" button, pastes the command the app put on the clipboard into Steam's Console and presses Return.
# Steam downloads the depot; the app verifies it, moves it into $JOB/appdata/prefix/drive_c/Games/PEAK, installs
# PeakPack and syncs the mods, then shows "All set". The script waits for that (up to 100 min) and reads
# Steam's console_log.txt only for the completion line. Mode B (--from-depot DIR, or --use-existing-depot for
# $JOB/game/PEAK): the agent picks an existing PEAK folder with the app's "Use a PEAK Folder I Already Have..."; the
# app copies it. Then the script checks the installed game, the PeakPack install and the mods, and quits the app.
# Args: [--app-release TAG] [--from-depot DIR | --use-existing-depot] [--timeout-min N] (default 100 for the wait)
set -u
. "$PP_KIT_DIR/lib/common.sh"
. "$PP_KIT_DIR/lib/assets.sh"
. "$PP_KIT_DIR/lib/app.sh"
gate_begin G-APP2 "PEAK (Modded).app game step: Steam console paste (or an existing PEAK folder), verify, PeakPack and mods"
gate_require_mac
tag_arg=""; from=""; use_existing=0; wait_min=100
while [ $# -gt 0 ]; do
  case "$1" in
    --app-release) tag_arg=$2; shift 2 ;;
    --from-depot) from=$2; shift 2 ;;
    --use-existing-depot) use_existing=1; shift ;;
    --timeout-min) wait_min=$2; shift 2 ;;
    *) shift ;;
  esac
done
app_tag_resolve "$tag_arg" || gate_finish_as blocked "no app release tag: pass --app-release, set PP_APP_RELEASE, or run G-APP1 first"
mode="paste"
if [ -n "$from" ]; then mode=folder
elif [ "$use_existing" = 1 ]; then from=$GAME_DIR; mode=folder
fi
if [ "$mode" = folder ]; then
  [ -f "$from/PEAK.exe" ] || gate_finish_as blocked "no PEAK.exe in $from: run G-B5 first, or pass --from-depot DIR"
fi
metric game_mode "$mode" str
rosetta_ok || gate_finish_as blocked "Rosetta 2 is not installed (G-APP1 needs it)"
gate_require_gui
keep_awake
GATE_CLEANUP=app_wine_stop

ensure_app; rc=$?
case $rc in
  0) ;;
  2) crit app_download fail "app zip matches its SHA256SUMS" "see G-APP1"; gate_end ;;
  *) gate_finish_as blocked "app release $APP_TAG is not available (run G-APP1)" ;;
esac

# ---- 1. the app runs and waits at its game step
if app_running; then log "the app is already running (G-APP1 leaves it at the game step): using it"
else app_launch --no-autoplay || gate_finish_as error "could not start the app"
fi
already_done=0
ph=$(app_status_get phase)
case "$ph" in
  done|ready) already_done=1; note "the app is already set up in this job (phase $ph): its game step is not repeated" ;;
esac
if [ "$already_done" = 0 ]; then
  wait_for_step game waiting-for-user 900; rc=$?
  case $rc in
    0) crit game_step pass "app waits at its game step" "step game, waiting for user" ;;
    2) crit game_step fail "app reaches its game step" "phase error: $(app_status_get problem.code) $(app_status_get problem.heading)"; gate_end ;;
    *) crit game_step fail "app reaches its game step within 15 min" "phase $APP_PHASE_SEEN, step $(app_status_get step) $(app_status_get stepState)"; gate_end ;;
  esac
fi

# ---- 2. the agent starts the download (mode A) or picks the folder (mode B)
cl=$(app_console_log); cl_off=0
[ -f "$cl" ] && cl_off=$(file_size "$cl")
t_cu=$(now_s)
if [ "$already_done" = 0 ]; then
  if [ "$mode" = paste ]; then
    cu_request paste 900 "In the app's setup window (step Game; it shows a drawing of Steam's console) click the button 'Open Steam Console'. Steam's Console view opens. Click the input box at the very bottom of the Console view, press Cmd+V (the app has put the command download_depot 3527290 3527291 on the clipboard), then press Return. Type nothing else. Never type credentials. Do not quit Steam. Screenshot before the paste: bash testkit/cu.sh \"$JOB\" shot G-APP2 app-console-guide. Screenshot after Return: bash testkit/cu.sh \"$JOB\" shot G-APP2 steam-console-pasted. Answer ok once Return is pressed (the app then downloads the depot, which takes a while: the script waits for it, you need not), or fail with what you see."
  else
    cu_request folder 900 "In the app's setup window (step Game) click the 'More' menu next to the 'Open Steam Console' button and choose 'Use a PEAK Folder I Already Have...'. In the standard folder picker choose exactly this folder: $from . Choose it with the picker's Open/Choose button. Do not choose another folder. Screenshot after choosing: bash testkit/cu.sh \"$JOB\" shot G-APP2 app-folder-picked. Answer ok once the app starts copying the folder, or fail with what you see."
  fi
  rc=$?
  case $rc in
    0) crit cu_source pass "game source step answered ok (CU-$mode)" "$CU_NOTE" ;;
    1) crit cu_source fail "game source step answered ok (CU-$mode)" "$CU_NOTE"; gate_end ;;
    2) gate_finish_as blocked "computer use is off (--no-cu): the game step needs the agent" ;;
    *) gate_finish_as error "no answer to CU-$mode within 15 min" ;;
  esac
fi

# ---- 3. wait for the app: phase done ("All set")
deadline=$(( $(now_s) + wait_min * 60 ))
max_prog=0; t_mods=""; t_done=""; t_line=""
while :; do
  ph=$(app_status_get phase); st=$(app_status_get step); pr=$(app_status_get progress)
  if is_num "$pr"; then max_prog=$(awk -v a="$max_prog" -v b="$pr" 'BEGIN { print (b + 0 > a + 0) ? b : a }'); fi
  if [ -z "$t_mods" ] && [ "$st" = mods ]; then t_mods=$(( $(now_s) - t_cu )); log "app reached step mods"; fi
  if [ "$mode" = paste ] && [ -z "$t_line" ] && [ "$already_done" = 0 ] && app_console_done_since "$cl_off"; then
    t_line=$(( $(now_s) - t_cu )); log "Steam's console reported the depot download complete"
  fi
  if [ "$ph" = "done" ]; then t_done=$(( $(now_s) - t_cu )); break; fi
  if [ "$ph" = error ]; then break; fi
  [ "$(now_s)" -lt "$deadline" ] || break
  sleep 5
done
metric max_progress "$max_prog"
[ -n "$t_mods" ] && metric time_to_mods_s "$t_mods"
[ -n "$t_line" ] && metric console_done_after_s "$t_line"
[ -n "$t_done" ] && metric time_to_done_s "$t_done"
if [ "$ph" = "done" ]; then
  crit setup_done pass "app reaches phase done ('All set')" "$(( $(now_s) - t_cu )) s after the start"
elif [ "$ph" = error ]; then
  crit setup_done fail "app reaches phase done" "phase error: $(app_status_get problem.code) $(app_status_get problem.heading)"; gate_end
else
  crit setup_done fail "app reaches phase done within ${wait_min} min" "phase $ph, step $(app_status_get step) $(app_status_get stepState), progress $max_prog"; gate_end
fi
if app_no_problem; then crit no_problem pass "status has no problem"
else crit no_problem fail "status has no problem" "$(app_status_get problem.code): $(app_status_get problem.heading)"; fi

# ---- 4. the manifest id (mode A: a number in the status and the same id as Steam's console line)
mid=$(app_status_get game.manifestId)
if [ "$mode" = paste ]; then
  line=$(app_console_line_since "$cl_off")
  [ -n "$line" ] && printf '%s\n' "$line" > "$GLOG/console-line.txt"
  cmid=$(printf '%s' "$line" | sed -n 's/.*(manifest \([0-9][0-9]*\)).*/\1/p')
  if is_num "$mid"; then crit manifest_id pass "status game.manifestId is a number" "$mid"
  else crit manifest_id fail "status game.manifestId is a number" "got '$mid'"; fi
  if [ -n "$cmid" ] && [ "$cmid" = "$mid" ]; then crit manifest_match pass "Steam console manifest equals the app's" "$mid"
  elif [ -n "$cmid" ]; then crit manifest_match fail "Steam console manifest equals the app's" "console $cmid, app $mid"
  else crit manifest_match info "Steam console manifest" "completion line not read (the app may have seen it first)"; fi
  [ -n "$mid" ] && metric depot_manifest_id "$mid" str
else
  crit manifest_id info "game.manifestId (existing folder: not expected)" "$mid"
fi

# ---- 5. the installed game (drive_c/Games/PEAK in the app's prefix)
gd=$(app_game_dir)
miss=""
for f in PEAK.exe UnityPlayer.dll PEAK_Data/Plugins/x86_64/steam_api64.dll PEAK_Data/Managed/Assembly-CSharp.dll; do
  [ -f "$gd/$f" ] || miss="$miss $f"
done
if [ -z "$miss" ]; then crit game_files pass "PEAK.exe, UnityPlayer.dll, steam_api64.dll and Assembly-CSharp.dll in drive_c/Games/PEAK"
else crit game_files fail "PEAK.exe, UnityPlayer.dll, steam_api64.dll and Assembly-CSharp.dll in drive_c/Games/PEAK" "missing:$miss"; fi
ver=$(head -1 "$gd/version.txt" 2>/dev/null | tr -d '\r '); rev=$(sed -n 2p "$gd/version.txt" 2>/dev/null | tr -d '\r ')
[ -n "$ver" ] && version_set peak_version "$ver"
[ -n "$rev" ] && version_set peak_revision "$rev"
if [ -f "$gd/PEAK.exe" ]; then
  log "hashing the installed game (about 2 GB, a few minutes)"
  app_hash_depot "$gd" "$GLOG/peak-app.manifest"
  nfiles=$(wc -l < "$GLOG/peak-app.manifest" | tr -d ' ')
  nbytes=$(awk '{ s += $2 } END { printf "%.0f", s }' "$GLOG/peak-app.manifest")
  metric files "$nfiles"; metric bytes "$nbytes"
  if [ "$nfiles" -ge 200 ] && [ "$nbytes" -ge 1500000000 ] && [ "$nbytes" -le 3000000000 ]; then
    crit size pass "file count and size plausible (>= 200 files, 1.5-3 GB, as G-B5)" "$nfiles files, $nbytes bytes"
  else crit size fail "file count and size plausible (>= 200 files, 1.5-3 GB, as G-B5)" "$nfiles files, $nbytes bytes"; fi
  ref=$(app_ref_manifest "$ver")
  if [ -n "$ref" ]; then
    ref_manifest_clean < "$ref" > "$GTMP/ref.manifest"
    if diff "$GTMP/ref.manifest" "$GLOG/peak-app.manifest" > "$GLOG/manifest.diff" 2>&1; then
      crit exact_match pass "every installed file matches the Windows reference ($(basename "$ref"))" "$nfiles files"
    else
      crit exact_match fail "every installed file matches the Windows reference ($(basename "$ref"))" "$(grep -c '^[<>]' "$GLOG/manifest.diff") differing lines, see logs/G-APP2/manifest.diff"
    fi
  else
    crit exact_match skip "exact match with a Windows reference" "no expect/peak-win-${ver:-?}-*.manifest for this version"
  fi
fi

# ---- 6. PeakPack and the mods (the app's PeakPack folder in its prefix)
ppd=$(app_pp_dir)
if [ -f "$ppd/PeakPack.exe" ]; then crit peakpack_exe pass "PeakPack.exe installed by the app"
else crit peakpack_exe fail "PeakPack.exe installed by the app" "$ppd"; fi
if [ -f "$ppd/profile/BepInEx/core/BepInEx.Preloader.dll" ]; then crit profile_bepinex pass "BepInEx core in the PeakPack profile"
else crit profile_bepinex fail "BepInEx core in the PeakPack profile"; fi
if app_has_key "$APP_STATEFILE" packRevision; then
  prv=$(json_get "$APP_STATEFILE" packRevision); version_set pack_revision "$prv"
  crit state_pack_revision pass "frontend/state.json has packRevision" "$prv"
else crit state_pack_revision fail "frontend/state.json has packRevision"; fi

# ---- 7. Steam's side: the depot must have left Steam's content folder; the depotcache entries are recorded
steam_res=pass; steam_det="content folders clear"
while IFS= read -r d; do
  [ -n "$d" ] || continue
  [ -d "$d" ] || continue
  if [ -e "$d/depot_$PEAK_DEPOT" ]; then steam_res=fail; steam_det="depot_$PEAK_DEPOT still in $d"; fi
  if [ -n "$(ls -A "$d" 2>/dev/null)" ] && [ "$steam_res" = pass ]; then steam_res=info; steam_det="not empty: $(ls -A "$d" | tr '\n' ' ')"; fi
done <<EOF
$(app_steam_content_dirs)
EOF
crit steam_content "$steam_res" "Steam's app_$PEAK_APPID content folder is gone or empty (the app moved the depot out)" "$steam_det"
app_record_depotcache

# ---- 8. quit the app (G-APP3 starts it again like a friend would)
if app_quit; then crit app_quit pass "app quit at the end of the game step"
else crit app_quit fail "app quit at the end of the game step"; fi
version_set app_status_version "$(app_status_get appVersion)"
gate_end
