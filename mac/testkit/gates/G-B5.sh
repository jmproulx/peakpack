#!/bin/bash
# TITLE: G-B5 (T15) PEAK's Windows depot via Valve's own client (Mac Steam console download_depot), verified, moved into the job dir
# Part of PeakPack for Mac (mac/testkit). MIT licence. Run through run_gate.sh.
#
# Game files come ONLY from Valve's tools (DESIGN §10a): the hub's agent types
#   download_depot 3527290 3527291
# into the Mac Steam console (computer-use step CU-download). This script:
#   1. opens the console view (`open steam://open/console`, only when Steam already runs; set
#      PP_OPEN_CONSOLE=0 to leave that to the agent too) and asks for the download (CU-download);
#      it also watches Steam's console_log.txt for "Depot download complete" (read-only);
#   2. locates depot_3527291 (path from the agent's answer, else the known content folders);
#   3. verifies it: PEAK.exe/UnityPlayer.dll/steam_api64.dll/Assembly-CSharp.dll present, version.txt,
#      file count and size, and an exact per-file SHA-256 comparison with expect/peak-win-<version>-*.manifest
#      (made on Joshua's PC with the Steam team's depot_manifest.sh) when the versions match;
#   4. moves it to <job>/game/PEAK (same volume: a rename) and removes the now-empty
#      steamapps/content/app_3527290 folder if it did not exist before the job.
# Paths outside the job dir: Steam's content/download folders and depotcache (recorded in state/outside-paths.tsv;
# cleanup.sh removes only what did not exist before the job). Steam itself is never modified.
# Args: [--from-dir DIR] verify an existing depot folder instead of downloading (it is moved too unless --copy)
#       [--copy] copy instead of move   [--timeout-min N] download wait (default 90)
set -u
. "$PP_KIT_DIR/lib/common.sh"
. "$PP_KIT_DIR/lib/assets.sh"
gate_begin G-B5 "PEAK Windows depot via Mac Steam download_depot"
gate_require_mac
from=""; copy=0; dl_timeout=90
while [ $# -gt 0 ]; do
  case "$1" in --from-dir) from=$2; shift 2 ;; --copy) copy=1; shift ;; --timeout-min) dl_timeout=$2; shift 2 ;; *) shift ;; esac
done
keep_awake
console_log="$STEAM_DATA/logs/console_log.txt"
candidates() {
  printf '%s\n' "$STEAM_MACOS_DIR/steamapps/content/app_$PEAK_APPID/depot_$PEAK_DEPOT" \
                "$STEAM_DATA/steamapps/content/app_$PEAK_APPID/depot_$PEAK_DEPOT"
}

depot=""
if [ -f "$GAME_DIR/PEAK.exe" ]; then
  log "depot already in the job dir ($GAME_DIR); verifying only"
  depot=$GAME_DIR
  metric source already-in-job str
elif [ -n "$from" ]; then
  [ -f "$from/PEAK.exe" ] || gate_finish_as blocked "--from-dir $from has no PEAK.exe"
  depot=$from; metric source from-dir str
else
  steam_running || gate_finish_as needs-human "Mac Steam is not running" "Run H-STEAM first (Steam open and signed in under the fleet user)."
  req_t=$(now_s)
  # Steam's console log: remember its size so only new lines count
  cl_off=0; [ -f "$console_log" ] && cl_off=$(file_size "$console_log")
  depot_done_in_log() {
    [ -f "$console_log" ] || return 1
    tail -c +"$(( cl_off + 1 ))" "$console_log" 2>/dev/null | grep -a -q "Depot download complete"
  }
  # steam://open/console only when the slot runs computer-use steps (the agent works in Steam anyway);
  # never with --no-cu (PP_CU=none), so no Steam/macOS window or dialog appears unattended.
  if [ "${PP_CU:-}" != none ] && [ "${PP_OPEN_CONSOLE:-1}" = 1 ] && [ ! -f "$CU_DIR/G-B5.download.done" ]; then
    open 'steam://open/console' >/dev/null 2>&1 && log "asked Steam to show its console (steam://open/console)"
    sleep 3
  fi
  snap b5-before-download
  cu_request download $(( dl_timeout * 60 )) "In Mac Steam's Console view (opened for you via steam://open/console; if it is not visible, see gates/G-B5.md step CU-download): click the input line at the bottom, type exactly: download_depot $PEAK_APPID $PEAK_DEPOT  and press Return. Screenshot evidence/G-B5/b5-console-started.png. Wait (up to ${dl_timeout} min, about 1.93 GB) until the console prints 'Depot download complete : \"<path>\" (manifest <id>)'. Screenshot evidence/G-B5/b5-console-complete.png. Answer: ok path=<the path in quotes> manifest=<id>. On an error line, screenshot b5-console-error.png and answer fail <the message>. Never type credentials; do not quit Steam." depot_done_in_log
  rc=$?
  metric download_wait_s "$(( $(now_s) - req_t ))"
  [ -f "$console_log" ] && tail -c +"$(( cl_off + 1 ))" "$console_log" 2>/dev/null | grep -a -i 'depot\|download_depot' | tail -40 > "$GLOG/steam-console-excerpt.txt"
  case $rc in
    0) crit download pass "download_depot finished (Valve's client)" "$CU_NOTE" ;;
    1) crit download fail "download_depot finished" "$CU_NOTE"; gate_end ;;
    2) gate_finish_as blocked "computer use not available for the console step (PP_CU=none) and no depot found" ;;
    *) gate_finish_as error "download did not finish within ${dl_timeout} min" ;;
  esac
  p=$(cu_kv path); m=$(cu_kv manifest)
  [ -n "$m" ] && metric depot_manifest_id "$m" str
  [ -z "$p" ] && p=$(sed -n 's/.*Depot download complete : "\([^"]*\)".*/\1/p' "$GLOG/steam-console-excerpt.txt" 2>/dev/null | tail -1)
  [ -z "$m" ] && m=$(sed -n 's/.*Depot download complete.*(manifest \([0-9]*\)).*/\1/p' "$GLOG/steam-console-excerpt.txt" 2>/dev/null | tail -1) && [ -n "$m" ] && metric depot_manifest_id "$m" str
  if [ -n "$p" ] && [ -f "$p/PEAK.exe" ]; then depot=$p
  else
    while IFS= read -r c; do [ -f "$c/PEAK.exe" ] && { depot=$c; break; }; done <<EOF
$(candidates)
EOF
  fi
  [ -n "$depot" ] || gate_finish_as fail "download reported complete but no depot_$PEAK_DEPOT folder with PEAK.exe was found (agent path: ${p:-none})"
  metric source download_depot str
  metric steam_depot_path "$depot" str
  case "$depot" in "$JOB"/*) ;; *) outside_record "$depot" created-by-us "download_depot output (moved into the job dir below)" ;; esac
fi

# ---- verify
[ -f "$depot/PEAK.exe" ] && crit peak_exe pass "PEAK.exe present" || crit peak_exe fail "PEAK.exe present"
for f in UnityPlayer.dll PEAK_Data/Plugins/x86_64/steam_api64.dll PEAK_Data/Managed/Assembly-CSharp.dll; do
  [ -f "$depot/$f" ] && crit "has_$(basename "$f")" pass "$f present" || crit "has_$(basename "$f")" fail "$f present"
done
ver=$(head -1 "$depot/version.txt" 2>/dev/null | tr -d '\r '); rev=$(sed -n 2p "$depot/version.txt" 2>/dev/null | tr -d '\r ')
if [ -n "$ver" ]; then crit version_txt pass "version.txt" "$ver ${rev:+($rev)}"; version_set peak_version "$ver"; [ -n "$rev" ] && version_set peak_revision "$rev"
else crit version_txt fail "version.txt readable"; fi
log "hashing the depot (about 2 GB)"
depot_manifest "$depot" "$GLOG/peak-mac.manifest"   # lib/common.sh: skips mod-loader artifacts and caches
nfiles=$(wc -l < "$GLOG/peak-mac.manifest" | tr -d ' ')
nbytes=$(awk '{ s += $2 } END { printf "%.0f", s }' "$GLOG/peak-mac.manifest")
metric files "$nfiles"; metric bytes "$nbytes"
# Reference build 2.6.b: 270 files, 1,930,335,969 bytes. A newer build may differ a little.
if [ "$nfiles" -ge 200 ] && [ "$nbytes" -ge 1500000000 ] && [ "$nbytes" -le 3000000000 ]; then crit size pass "file count and size plausible" "$nfiles files, $nbytes bytes"
else crit size fail "file count and size plausible (>= 200 files, 1.5-3 GB)" "$nfiles files, $nbytes bytes"; fi
ref=""
for e in "$PP_KIT_DIR"/expect/peak-win-"$ver"-*.manifest; do [ -f "$e" ] && ref=$e; done
if [ -n "$ref" ]; then
  ref_manifest_clean < "$ref" > "$GTMP/ref.manifest"
  if diff "$GTMP/ref.manifest" "$GLOG/peak-mac.manifest" > "$GLOG/manifest.diff" 2>&1; then
    crit exact_match pass "every file matches the Windows reference install ($(basename "$ref"))" "$nfiles files"
  else
    crit exact_match fail "every file matches the Windows reference install ($(basename "$ref"))" "$(grep -c '^[<>]' "$GLOG/manifest.diff") differing lines, see logs/G-B5/manifest.diff"
  fi
  metric reference "$(basename "$ref")" str
else
  crit exact_match skip "exact match with a Windows reference" "no expect/peak-win-$ver-*.manifest (reference is 2.6.b); regenerate it with depot_manifest.sh for this build"
fi

# ---- move into the job dir
if [ "$depot" != "$GAME_DIR" ] && ! crit_failed peak_exe; then
  mkdir -p "$(dirname "$GAME_DIR")"
  if [ "$copy" = 1 ]; then cp -R "$depot" "$GAME_DIR" && crit placed pass "depot copied to the job dir" "$GAME_DIR" || crit placed fail "copy to the job dir"
  elif mv "$depot" "$GAME_DIR" 2>"$GLOG/mv.err"; then
    crit placed pass "depot moved into the job dir (nothing left in Steam's content folder)" "$GAME_DIR"
    app=$(dirname "$depot")
    if [ "$(basename "$app")" = "app_$PEAK_APPID" ] && ! preexisted "$app"; then
      rmdir "$app" 2>/dev/null && log "removed the empty $app (created by our download)"
    fi
  else
    crit placed fail "depot moved into the job dir" "$(head -c 300 "$GLOG/mv.err")"
  fi
fi
# Steam-side leftovers of the download (depotcache manifest, downloading/), for cleanup.sh
while IFS= read -r d; do
  for f in "$d/${PEAK_DEPOT}"_*.manifest; do [ -e "$f" ] && ! preexisted "$f" && outside_record "$f" created-by-us "Steam depotcache entry from download_depot"; done
done <<EOF
$(depotcache_dirs)
EOF
version_set peak_files "$nfiles"
gate_end
