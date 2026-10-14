#!/bin/bash
# TITLE: G-APP6 PEAK (Modded).app repair (damaged prefix stamp and runtime file) and uninstall (moved out of the job's app data)
# Part of PeakPack for Mac (mac/testkit). MIT licence. Run through run_gate.sh.
#
# Needs G-APP5. (a) Repair: the script damages things INSIDE $JOB/appdata only (removes appdata/prefix/peakpack/prefix.json,
# replaces the runtime file share/wine/wine.inf under appdata/runtime/<id>/; the originals are copied to logs/G-APP6 first).
# The agent runs the options window's PEAK menu > Repair... > Repair. The app must reach phase ready with no problem;
# the stamp and the runtime file must be back (the file's SHA-256 equals the original, and the manifest's entry when the
# manifest has one); --print-status says readyToPlay true.
# (b) Uninstall: the agent runs PEAK menu > Uninstall... > Move to Trash. In this test build the app moves
# $JOB/appdata (with its Logs) into $JOB/uninstalled/appdata-<epoch> instead of the real Trash (privacy-protected, so
# the Trash itself is never tested). Checks: appdata is gone, the moved copy has runtime/ and prefix/, the app bundle is
# still in $JOB/apps, Steam's content, downloading and depotcache listings are unchanged, and the app quits.
# Args: [--app-release TAG] [--repair-timeout S] (default 1800)
set -u
. "$PP_KIT_DIR/lib/common.sh"
. "$PP_KIT_DIR/lib/assets.sh"
. "$PP_KIT_DIR/lib/app.sh"
gate_begin G-APP6 "PEAK (Modded).app repair and uninstall"
gate_require_mac
tag_arg=""; repair_to=1800
while [ $# -gt 0 ]; do
  case "$1" in --app-release) tag_arg=$2; shift 2 ;; --repair-timeout) repair_to=$2; shift 2 ;; *) shift ;; esac
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
  *) gate_finish_as blocked "the app is not set up in this job: run G-APP1 to G-APP5 first" ;;
esac

# ---- (a) damage, inside the job's app data only
if app_running; then app_quit || gate_finish_as error "could not quit the app before the damage step"; fi
app_wine_stop
pj="$APP_PFX/peakpack/prefix.json"
[ -f "$pj" ] || gate_finish_as blocked "no prefix stamp to damage (G-APP1 must have completed)"
rt=$(app_runtime_dir) || gate_finish_as blocked "no app runtime under $APP_DATA/runtime (G-APP1)"
target="$rt/share/wine/wine.inf"
[ -f "$target" ] || gate_finish_as blocked "runtime file share/wine/wine.inf is missing in $rt"
cp "$pj" "$GLOG/prefix.json.orig"
cp "$target" "$GLOG/wine.inf.orig"
orig_sha=$(sha256_of "$target")
version_set repair_target_original_sha256 "$orig_sha"
rm -f "$pj"
printf 'deliberately damaged by G-APP6 (repair check)\n' > "$target"
note "damage: removed $(rel_to_job "$pj") (copy in logs/G-APP6/prefix.json.orig); replaced $(rel_to_job "$target") (original in logs/G-APP6/wine.inf.orig)"
crit damage_done pass "damage made inside the job's app data (prefix stamp removed, runtime file replaced)" "$(rel_to_job "$target")"
# the expected hash from the runtime's own manifest.json, when it lists the file
mval=""
if [ -f "$rt/manifest.json" ]; then
  mval=$(json_get "$rt/manifest.json" "files.share/wine/wine.inf")
  [ -n "$mval" ] || mval=$(json_get "$rt/manifest.json" "files.share/wine/wine.inf.sha256")
fi

# ---- (a) repair: the agent runs PEAK menu > Repair...
app_launch --options --no-autoplay || gate_finish_as error "could not start the app with --options"
wait_for_phase "ready|setup|error" 300
metric phase_before_repair "$APP_PHASE_SEEN" str
cu_request repair 600 "The PEAK (Modded) app is open (its options window may be shown). Open the PEAK menu in the menu bar > Repair... A confirmation alert opens. Screenshot it first: bash testkit/cu.sh \"$JOB\" shot G-APP6 repair-alert. Then click 'Repair' (not 'Cancel'). Wait until the app shows ready with no error. Screenshot: bash testkit/cu.sh \"$JOB\" shot G-APP6 repair-done. Answer ok when the app shows ready, or fail with what you see. If macOS asks for an administrator password, do NOT type it: screenshot it as dialog-1 and answer fail with its text."
rc=$?
case $rc in
  0) crit cu_repair pass "agent started Repair and saw the app ready (CU-repair)" "$CU_NOTE" ;;
  1) crit cu_repair fail "agent started Repair (CU-repair)" "$CU_NOTE"; gate_end ;;
  2) gate_finish_as blocked "computer use is off (--no-cu): Repair needs clicks" ;;
  *) gate_finish_as error "no answer to CU-repair within 600 s" ;;
esac
if wait_for_phase ready "$repair_to"; then
  crit repair_ready pass "app reaches phase ready after Repair"
else
  crit repair_ready fail "app reaches phase ready after Repair within ${repair_to}s" "phase $APP_PHASE_SEEN, step $(app_status_get step) $(app_status_get stepState), $(app_status_get problem.code)"
  gate_end
fi
if [ -f "$pj" ]; then crit prefix_stamp_restored pass "prefix stamp is back (appdata/prefix/peakpack/prefix.json)"
else crit prefix_stamp_restored fail "prefix stamp is back (appdata/prefix/peakpack/prefix.json)"; fi
got=$(sha256_of "$target")
if [ "$got" = "$orig_sha" ]; then crit runtime_file_restored pass "share/wine/wine.inf has its original SHA-256" "$(printf '%s' "$got" | cut -c1-16)..."
else crit runtime_file_restored fail "share/wine/wine.inf has its original SHA-256" "got $(printf '%s' "$got" | cut -c1-16)..., expected $(printf '%s' "$orig_sha" | cut -c1-16)..."; fi
if printf '%s' "$mval" | grep -Eq '^[0-9a-f]{64}$'; then
  if [ "$got" = "$mval" ]; then crit runtime_manifest_match pass "share/wine/wine.inf matches the runtime manifest.json entry"
  else crit runtime_manifest_match fail "share/wine/wine.inf matches the runtime manifest.json entry" "manifest says $(printf '%s' "$mval" | cut -c1-16)..."; fi
else
  crit runtime_manifest_match skip "share/wine/wine.inf matches the runtime manifest.json entry" "manifest.json has no sha256 for files.share/wine/wine.inf (compared with the saved copy)"
fi
if app_no_problem; then crit no_problem pass "status has no problem after Repair"
else crit no_problem fail "status has no problem after Repair" "$(app_status_get problem.code): $(app_status_get problem.heading)"; fi
if app_cli 60 --print-status --data-dir "$APP_DATA"; then rc=0; else rc=$?; fi
cp "$GTMP/cli.out" "$GLOG/print-status-after-repair.json" 2>/dev/null
rtp=$(json_get "$GLOG/print-status-after-repair.json" readyToPlay)
if [ "$rc" = 0 ] && [ "$rtp" = true ]; then crit ready_to_play pass "--print-status says readyToPlay true"
else crit ready_to_play fail "--print-status says readyToPlay true" "exit $rc, readyToPlay '$rtp'"; fi

# ---- (b) uninstall: listings before (names only, never file contents)
snap_steam() {
  local out=$1 d
  : > "$out"
  while IFS= read -r d; do
    printf '== %s\n' "$d" >> "$out"
    [ -d "$d" ] && ls -A "$d" >> "$out" 2>/dev/null
  done <<EOF
$(app_steam_content_dirs)
$STEAM_DATA/steamapps/downloading/$PEAK_APPID
$STEAM_MACOS_DIR/steamapps/downloading/$PEAK_APPID
$(depotcache_dirs)
EOF
  return 0
}
snap_steam "$GLOG/steam-before.txt"
ls -A "$HOME/Library/Application Support" > "$GLOG/appsupport-before.txt" 2>/dev/null
ls -A "$HOME/Library/Preferences" > "$GLOG/prefs-before.txt" 2>/dev/null
cu_request uninstall 600 "The PEAK (Modded) app is open. Open the PEAK menu in the menu bar > Uninstall... A confirmation alert opens. Screenshot it first: bash testkit/cu.sh \"$JOB\" shot G-APP6 uninstall-alert. Then click 'Move to Trash' (not 'Cancel'). This test build moves the app's data into the job folder, not into the real Trash. Wait until the app shows its message screen or its window closes. Screenshot: bash testkit/cu.sh \"$JOB\" shot G-APP6 uninstall-done. Answer ok, or fail with what you see. Never click a macOS prompt; never touch Steam."
rc=$?
case $rc in
  0) crit cu_uninstall pass "agent started the uninstall (Move to Trash) (CU-uninstall)" "$CU_NOTE" ;;
  1) crit cu_uninstall fail "agent started the uninstall (CU-uninstall)" "$CU_NOTE"; gate_end ;;
  2) gate_finish_as blocked "computer use is off (--no-cu): Uninstall needs clicks" ;;
  *) gate_finish_as error "no answer to CU-uninstall within 600 s" ;;
esac
t0=$(now_s)
while [ -e "$APP_DATA" ] && [ $(( $(now_s) - t0 )) -lt 300 ]; do sleep 3; done
if [ -e "$APP_DATA" ]; then crit appdata_removed fail "app data folder is gone after Uninstall" "$APP_DATA still exists"
else crit appdata_removed pass "app data folder is gone after Uninstall (moved out of the app's data)"; fi
moved=$(ls -d "$APP_UNINSTALL_TO"/appdata-* 2>/dev/null | head -1)
if [ -n "$moved" ] && [ -d "$moved/runtime" ] && [ -d "$moved/prefix" ]; then
  crit uninstalled_copy pass "moved copy in uninstalled/ has runtime/ and prefix/" "$(rel_to_job "$moved")"
else crit uninstalled_copy fail "moved copy in uninstalled/ has runtime/ and prefix/" "${moved:-no uninstalled/appdata-* folder}"; fi
mph=""
[ -n "$moved" ] && mph=$(json_get "$moved/frontend/status.json" phase)
if [ "$mph" = message ]; then crit uninstall_message pass "app shows phase message after Uninstall (status in the moved copy)"
else crit uninstall_message info "app shows phase message after Uninstall" "status in the moved copy: phase '${mph:-no status file}' (the status file may not be written after the move)"; fi
if [ -x "$APP_EXE" ]; then crit bundle_kept pass "app bundle still in $JOB/apps (not moved in test mode)"
else crit bundle_kept fail "app bundle still in $JOB/apps" "$APP_EXE missing"; fi
snap_steam "$GLOG/steam-after.txt"
if cmp -s "$GLOG/steam-before.txt" "$GLOG/steam-after.txt"; then crit steam_untouched pass "Steam content, downloading and depotcache listings unchanged"
else crit steam_untouched fail "Steam content, downloading and depotcache listings unchanged" "$(diff "$GLOG/steam-before.txt" "$GLOG/steam-after.txt" | head -4 | tr '\n' ' ')"; fi
ls -A "$HOME/Library/Application Support" > "$GLOG/appsupport-after.txt" 2>/dev/null
ls -A "$HOME/Library/Preferences" > "$GLOG/prefs-after.txt" 2>/dev/null
dd1=$(diff "$GLOG/appsupport-before.txt" "$GLOG/appsupport-after.txt" | grep '^[<>]' | tr '\n' ' ')
dd2=$(diff "$GLOG/prefs-before.txt" "$GLOG/prefs-after.txt" | grep '^[<>]' | tr '\n' ' ')
if [ -z "$dd1$dd2" ]; then crit home_listing info "top-level ~/Library/Application Support and Preferences" "unchanged"
else crit home_listing info "top-level ~/Library/Application Support and Preferences" "changed (outside the job dir, listed only): $dd1 $dd2"; fi

# ---- quit the app
if app_quit; then crit app_quit pass "app quit after Uninstall"
else crit app_quit fail "app quit after Uninstall" "still running after 30 s"; fi
app_wine_stop
gate_end
