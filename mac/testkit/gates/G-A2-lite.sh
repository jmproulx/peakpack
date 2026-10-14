#!/bin/bash
# TITLE: G-A2-lite performance: PEAK -force-d3d11 on DXMT, Metal HUD, solo run to the Shore, 2 min sampled
# Part of PeakPack for Mac (mac/testkit). MIT licence. Run through run_gate.sh.
#
# Short version of G-A2 (DESIGN §7, TUNING.md R0) for slot 1:
#   PEAK.exe -force-d3d11 -screen-width 1440 -screen-height 900 -screen-fullscreen 1 -window-mode borderless
#   via peakpack_steam_launcher.exe (bridge), normal mode (WINEDEBUG=-all, no DXMT logs), PP_HUD=1 (Metal HUD).
#   Memory: the runtime's pp-sample.sh and the Steam team's t12_memsample.sh every 10 s for the whole run.
#   The hub's agent drives the game (CU-menu, CU-shore, CU-fps): main menu -> solo game -> Shore, then
#   reads the HUD fps every 30 s for 2 min and screenshots it.
# Criteria (lite; the full G-A2 needs the CrossOver baseline G-A2-CX and 30 min):
#   no crash during the run; lowest HUD fps >= 30 (stand-in for the 1 % low); memory pressure never red
#   (kern.memorystatus_vm_pressure_level never 4; min free % recorded); swap growth < 1 GB;
#   average fps recorded; ">= 90 % of CrossOver" skipped.
# Args: [--modded] start through PeakPack (needs G-D2) instead of vanilla  [--minutes N] (Shore time, default 2)
#       [--test-drive] (with --modded): the TEST-ONLY plugin PeakPack.TestDrive (Steam tests tarball, probes/testdrive)
#       is put into the test prefix's profile for this run only: it starts the solo run, the expedition, and walks
#       the scout on the Shore for N minutes (the agent cannot hold keys). Removed again at the end of the gate.
set -u
. "$PP_KIT_DIR/lib/common.sh"
. "$PP_KIT_DIR/lib/assets.sh"
gate_begin G-A2-lite "PEAK performance, short run"
gate_require_mac
gate_require_gui   # Wine/Unity windows need the logged-in GUI session (blocked otherwise)
modded=0; minutes=2; test_drive=0
while [ $# -gt 0 ]; do case "$1" in --modded) modded=1; shift ;; --minutes) minutes=$2; shift 2 ;; --test-drive) test_drive=1; shift ;; *) shift ;; esac; done
rosetta_ok || gate_finish_as blocked "Rosetta 2 is not installed (P0)"
steam_running || gate_finish_as needs-human "Mac Steam is not running" "Run H-STEAM, then re-run G-A2-lite."
keep_awake
ensure_runtime || gate_finish_as blocked "runtime not available (run G-A1 first)"
ensure_tests >/dev/null 2>&1
ensure_bridge >/dev/null 2>&1
[ -f "$BRIDGE/peakpack_steam_launcher.exe" ] || gate_finish_as blocked "Steam launcher missing from the runtime"
ensure_prefix || gate_finish_as error "prefix creation failed"
ensure_game_in_prefix || gate_finish_as blocked "PEAK is not in the job dir (run G-B5 first)"
tests_dir="$PFX/drive_c/PeakPackTests"; mkdir -p "$tests_dir"
cp "$BRIDGE/peakpack_steam_launcher.exe" "$BRIDGE/steamclient64.dll" "$tests_dir/"
plog=$(player_log_path)

samp_pids=""
td_dir=""; td_cfg=""; td_go=""
td_remove() {  # the test-only plugin never stays in the profile
  [ -n "$td_dir" ] && rm -rf "$td_dir"
  [ -n "$td_cfg" ] && rm -f "$td_cfg"
  [ -n "$td_go" ] && rm -f "$td_go"
  return 0
}
stop_all() {
  for p in $samp_pids; do kill -INT "$p" 2>/dev/null; done
  sleep 2
  for p in $samp_pids; do kill "$p" 2>/dev/null; done
  samp_pids=""
  wine_stop
  td_remove
}
GATE_CLEANUP=stop_all

# ---- samplers (whole run, 10 s)
total_min=$(( minutes + 12 ))
bash "$RT/share/peakpack/prefix/pp-sample.sh" "$GLOG/pp-sample.csv" 10 > /dev/null 2>&1 &
samp_pids="$samp_pids $!"
# macOS pressure level: 1 normal (green), 2 warning (yellow), 4 critical (red)
( while :; do
    printf '%s,%s\n' "$(date -u +%H:%M:%S)" "$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)" >> "$GLOG/pressure-level.csv"
    sleep 10
  done ) &
samp_pids="$samp_pids $!"
if [ -n "${TESTS:-}" ] && [ -f "$TESTS/mac/t12_memsample.sh" ]; then
  bash "$TESTS/mac/t12_memsample.sh" --interval 10 --duration-min "$total_min" --logs "$GLOG/t12" > "$GLOG/t12.out" 2>&1 &
  samp_pids="$samp_pids $!"
fi

# ---- launch
ARGS="-force-d3d11 -screen-width 1440 -screen-height 900 -screen-fullscreen 1 -window-mode borderless"
metric unity_args "$ARGS" str; metric hud 1; metric modded "$modded"
t_launch=$(now_s)
if [ "$modded" = 1 ]; then
  ensure_peakpack || gate_finish_as blocked "PeakPack.exe not available"
  wu=$(wine_user)
  metric prefix_users "$(users_seen "$PFX")" str
  # R12: if the pack carries PeakPack.MacPreset, switch on its frame-time log (1 s) for exact fps / 1 % low.
  bep="$PFX/drive_c/users/$wu/AppData/Local/PeakPack/profile/BepInEx"
  if [ -n "$(find "$bep/plugins" -iname 'PeakPack.MacPreset.dll' 2>/dev/null | head -n 1)" ]; then
    mp_cfg="$bep/config/peakpack.macpreset.cfg"; mkdir -p "$bep/config"
    if [ -f "$mp_cfg" ] && grep -q '^FpsLogSeconds' "$mp_cfg"; then
      sed -i '' 's/^FpsLogSeconds *=.*/FpsLogSeconds = 1/' "$mp_cfg"
    else
      printf '\n[Diagnostics]\n\nFpsLogSeconds = 1\n' >> "$mp_cfg"
    fi
    rm -f "$bep/PeakPack/macpreset-fps.log"
    metric macpreset_fps_log 1
  else
    metric macpreset_fps_log 0
  fi
  if [ "$test_drive" = 1 ]; then
    td_dll=$( [ -n "${TESTS:-}" ] && find "$TESTS" -name 'PeakPack.TestDrive.dll' 2>/dev/null | head -n 1)
    if [ -n "$td_dll" ] && [ -d "$bep/plugins" ]; then
      td_dir="$bep/plugins/PeakPack.TestDrive"; td_cfg="$bep/config/com.peakpack.testdrive.cfg"; td_go="$bep/config/peakpack.testdrive.go"
      mkdir -p "$td_dir" "$bep/config"; cp "$td_dll" "$td_dir/"; rm -f "$td_go"
      printf '[TestDrive]\n\nWalkSeconds = %s\n\nGoWaitSeconds = 900\n\nStageTimeoutSeconds = 600\n\nAscent = 0\n' "$(( minutes * 60 ))" > "$td_cfg"
      metric test_drive "on" str; metric test_drive_dll_sha256 "$(sha256_of "$td_dll")" str
    else
      test_drive=0; metric test_drive "unavailable" str
      note "--test-drive: PeakPack.TestDrive.dll not in the Steam tests (${TESTS:-none}) or no profile plugins folder; the agent drives instead"
    fi
  fi
  PP_HUD=1 pp_wine normal 'C:\PeakPackTests\peakpack_steam_launcher.exe' --forwarder-src 'C:\PeakPackTests\steamclient64.dll' \
     --log 'C:\PeakPackTests\launcher-a2.log' --no-launch --hold-ms 3000000 > "$GLOG/launcher.out" 2>&1 &
  sleep 8
  PP_HUD=1 PP_EXTRA_OVERRIDES="winhttp=n,b" pp_wine normal "C:\\users\\$wu\\AppData\\Local\\PeakPack\\PeakPack.exe" --headless --launch \
     --launch-method direct --game-dir 'C:\Games\PEAK' --status-out 'C:\PeakPackTests\a2-launch.json' > "$GLOG/peakpack-launch.out" 2>&1
  note "modded run: the resolution args come from the pack (-force-d3d11 only); PEAK uses its saved resolution"
else
  # shellcheck disable=SC2086  # ARGS is a fixed list of plain flags
  PP_HUD=1 pp_wine normal 'C:\PeakPackTests\peakpack_steam_launcher.exe' --forwarder-src 'C:\PeakPackTests\steamclient64.dll' \
     --log 'C:\PeakPackTests\launcher-a2.log' -- 'C:\Games\PEAK\PEAK.exe' $ARGS > "$GLOG/peak-wine.out" 2>&1 &
fi
# PEAK logs the Steam line after its first scene load (a cold prefix translates that scene's shaders first)
progress_monitor_start start
if wait_for_player_log "Steam runtime manager initialized" 600 "$t_launch"; then progress_monitor_stop; plog=$PLAYER_LOG_USED; metric player_log "$(rel_to_job "$plog")" str; crit started pass "PEAK started (Player.log, Steam initialised)" "$(( $(now_s) - t_launch )) s"
else hang_snapshot start; metric start_progress "$(progress_verdict start)" str; progress_monitor_stop; crit started fail "PEAK started within 600 s" "$(player_log_detail "$t_launch")"; gate_end; fi
metric start_to_steam_s "$(( $(now_s) - t_launch ))"

# ---- the agent drives the game
cu_request_peak menu 300 "PEAK is starting fullscreen with the Metal HUD (top-right overlay with FPS). When the main menu is drawn: screenshot evidence/G-A2-lite/a2-01-main-menu.png and read the HUD's FPS. Answer: ok fps=<number>. If a crash dialog or a black screen stays for 60 s, answer fail <what>."
cu1=$?; fps_menu=$(cu_kv fps); metric fps_main_menu "${fps_menu:-}"
[ -n "$td_go" ] && date -u +%Y-%m-%dT%H:%M:%SZ > "$td_go"   # test drive: start the solo run now
[ "$cu1" = 1 ] && { crit reached_menu fail "main menu reached (agent)" "$CU_NOTE"; gate_end; }
t_shore_req=$(now_s)
# Player.log scene markers: "Update current scene: Airport" (lobby), then "...: Level_<N>" for the island. N is the
# day's map (Level_1 on Windows 2.6.b on 13 Oct, Level_4 in Joshua's iMac session on 14 Oct), so any Level_<N> counts.
on_shore() { grep -a -q -E "Update current scene: Level_[0-9]+" "$plog" 2>/dev/null; }
bep_log="${bep:-}/LogOutput.log"
td_seen() { grep -a -q "TESTDRIVE $1" "$bep_log" 2>/dev/null; }
td_stop_or_walk() { td_seen walk_start || td_seen 'fail ' || td_seen 'inert '; }
if [ "$test_drive" = 1 ]; then
  # the plugin drives: menu -> Play Solo -> Airport -> kiosk -> Shore; wait for its walk_start (or its failure)
  t0=$(now_s); while ! td_stop_or_walk && [ $(( $(now_s) - t0 )) -lt 900 ]; do sleep 5; done
  grep -a 'TESTDRIVE' "$bep_log" > "$GLOG/testdrive.log" 2>/dev/null
  if td_seen walk_start; then cu2=0; CU_ANSWER=ok; CU_NOTE="test drive: $(grep -a -m1 'TESTDRIVE island_ready' "$bep_log" | sed 's/.*TESTDRIVE //')"
  else cu2=1; CU_ANSWER=fail; CU_NOTE="test drive did not reach the Shore within 900 s: $(grep -a 'TESTDRIVE' "$bep_log" 2>/dev/null | tail -2 | sed 's/.*TESTDRIVE //' | tr '\n' ' ')"; fi
else
cu_request shore 600 "Start a SOLO game and get to the Shore: in the main menu choose Play (pick the solo/offline option if PEAK offers one; otherwise host a private lobby, do not invite anyone). In the airport lobby walk (W, mouse to steer) to the boarding desk/kiosk and press E to start the expedition; confirm if asked. Wait until the island has loaded and you control your scout on the beach (Shore). Take screenshots a2-02-lobby.png and a2-03-shore.png. Answer ok when standing on the Shore, fail <where it got stuck> otherwise. Exact menu wording may differ; follow what PEAK shows. Never open the Steam overlay or invite friends." on_shore
cu2=$?
fi
grep -a -q "Update current scene: Airport" "$plog" 2>/dev/null && metric reached_airport true || metric reached_airport false
if on_shore; then metric reached_level true; metric island_scene "$(grep -a -o -E 'Update current scene: Level_[0-9]+' "$plog" | tail -1 | sed 's/.*: //')" str
else metric reached_level false; fi
metric menu_to_shore_s "$(( $(now_s) - t_shore_req ))"
if [ "$cu2" != 0 ]; then
  crit reached_shore fail "solo game reached the Shore (agent)" "$CU_ANSWER $CU_NOTE"
else
  crit reached_shore pass "solo game reached the Shore (agent)"
  t_shore=$(now_s)
  if [ "$test_drive" = 1 ]; then drive_text="The scout walks by itself for $minutes minutes (test drive): do NOT touch the keyboard or mouse in PEAK."
  else drive_text="On the Shore, for $minutes minutes: look around slowly / walk along the beach."; fi
  cu_request fps $(( minutes * 60 + 180 )) "$drive_text Every 30 s read the Metal HUD FPS and take a screenshot a2-fps-<n>.png (n = 1, 2, ...). Then answer: ok fps=<comma separated readings, e.g. 58,60,57,59> min=<lowest> notes=<stutter, hitches, artefacts>. Answer fail <what> if the game crashes or freezes."
  cu3=$?
  if [ "$test_drive" = 1 ]; then
    t0=$(now_s); while ! td_seen walk_end && ! td_seen 'fail ' && [ $(( $(now_s) - t0 )) -lt $(( minutes * 60 + 120 )) ]; do sleep 5; done
    grep -a 'TESTDRIVE' "$bep_log" > "$GLOG/testdrive.log" 2>/dev/null
    we=$(grep -a -m1 'TESTDRIVE walk_end' "$bep_log" | sed 's/.*TESTDRIVE //')
    metric test_drive_walk "${we:-none}" str
    if [ -n "$we" ]; then crit test_drive_walk pass "test drive walked on the Shore for the whole window" "$we"
    else crit test_drive_walk fail "test drive walked on the Shore for the whole window" "$(tail -2 "$GLOG/testdrive.log" 2>/dev/null | sed 's/.*TESTDRIVE //' | tr '\n' ' ')"; fi
  fi
  metric shore_seconds "$(( $(now_s) - t_shore ))"
  readings=$(cu_kv fps | tr -c '0-9.,\n' ' ' | tr -d ' ')
  metric fps_readings "$readings" str
  if [ -n "$readings" ]; then
    stats=$(printf '%s\n' "$readings" | tr ',' '\n' | awk 'NF { n++; s += $1; if (min == "" || $1 < min) min = $1 } END { if (n) printf "%.1f %s %d", s / n, min, n }')
    set -- $stats
    metric fps_avg "${1:-}"; metric fps_min "${2:-}"; metric fps_samples "${3:-0}"
    if [ -n "${2:-}" ] && awk -v m="$2" 'BEGIN { exit !(m >= 30) }'; then crit fps_floor pass "lowest HUD fps on the Shore >= 30 (1 % low stand-in)" "avg ${1} min ${2} over ${3} readings"
    else crit fps_floor fail "lowest HUD fps on the Shore >= 30 (1 % low stand-in)" "avg ${1:-?} min ${2:-?}"; fi
  else
    crit fps_floor skip "lowest HUD fps on the Shore >= 30" "no fps readings in the agent's answer ($CU_ANSWER)"
  fi
  [ "$cu3" = 1 ] && crit run_ok fail "no crash/freeze on the Shore (agent)" "$CU_NOTE"
fi
crit vs_crossover skip "average fps >= 90 % of CrossOver/DXMT on the same Mac" "needs the G-A2-CX baseline (optional, Joshua's call)"

# ---- R12: MacPreset frame-time log (modded runs whose pack carries MacPreset)
fpslog=""
[ "$modded" = 1 ] && fpslog="$PFX/drive_c/users/$(wine_user)/AppData/Local/PeakPack/profile/BepInEx/PeakPack/macpreset-fps.log"
if [ -n "$fpslog" ] && [ -f "$fpslog" ]; then
  cp "$fpslog" "$GLOG/macpreset-fps.log"
  # Shore = the island scene Level_<N>. avg = frames / seconds; 1 % low (conservative) = 1000 / worst per-interval p99.
  lstats=$(awk '/ scene=Level_[0-9]+ / {
      delete v; for (i = 1; i <= NF; i++) { k = $i; sub(/=.*/, "", k); x = $i; sub(/^[^=]*=/, "", x); v[k] = x }
      fr += v["frames"]; secs += v["frames"] * v["frametime_ms"] / 1000; if (v["p99_ms"] + 0 > p99) p99 = v["p99_ms"] + 0; n++ }
    END { if (n && secs > 0 && p99 > 0) printf "%.1f %.1f %d", fr / secs, 1000 / p99, n }' "$fpslog")
  if [ -n "$lstats" ]; then
    # shellcheck disable=SC2086  # three numbers
    set -- $lstats
    metric log_fps_avg "$1"; metric log_fps_1pct_low "$2"; metric log_intervals "$3"
    if awk -v m="$2" 'BEGIN { exit !(m >= 30) }'; then
      crit fps_1pct_low pass "1 % low on the Shore >= 30 fps (MacPreset frame-time log)" "avg $1, 1 % low $2 over $3 s"
    else
      crit fps_1pct_low fail "1 % low on the Shore >= 30 fps (MacPreset frame-time log)" "avg $1, 1 % low $2 over $3 s"
    fi
  else
    crit fps_1pct_low skip "1 % low on the Shore >= 30 fps (MacPreset frame-time log)" "log present but no Level_<N> (island) intervals; scenes seen: $(grep -a -o -E 'scene=[^ ]+' "$fpslog" | sort -u | tr '\n' ' ')"
  fi
elif [ "$modded" = 1 ]; then
  # MacPreset's FpsLogSeconds defaults to 0 (off in friends' sessions); this gate turns it on in the TEST profile.
  mpb="$PFX/drive_c/users/$(wine_user)/AppData/Local/PeakPack/profile/BepInEx"
  crit fps_1pct_low skip "1 % low on the Shore >= 30 fps (MacPreset frame-time log)" \
    "no frame-time log: $(path_detail "$fpslog"); config: $(grep -a -m1 '^FpsLogSeconds' "$mpb/config/peakpack.macpreset.cfg" 2>/dev/null || echo 'no FpsLogSeconds line'); LogOutput: $(grep -a -m1 -E 'FpsLogger|PeakPack MacPreset' "$mpb/LogOutput.log" 2>/dev/null | cut -c1-160 || echo none)"
else
  crit fps_1pct_low skip "1 % low on the Shore >= 30 fps (MacPreset frame-time log)" "vanilla run (HUD readings above apply)"
fi

# ---- crash check + memory verdict
alive=0; pgrep -U "$(id -u)" -f 'PEAK\.exe' >/dev/null 2>&1 && alive=1
metric peak_alive_at_end "$alive"
snap a2-end
[ -f "$plog" ] && cp "$plog" "$GLOG/Player.log"
stop_all
crashes=$(grep -a -c -i -E 'Crash!!!|Unhandled exception|access violation|SIGSEGV' "$GLOG/Player.log" 2>/dev/null | tr -d ' ')
metric crash_markers "${crashes:-0}"
if [ "$alive" = 1 ] && [ "${crashes:-0}" = 0 ]; then crit no_crash pass "PEAK still running at the end, no crash markers in Player.log"
else crit no_crash fail "PEAK still running at the end, no crash markers in Player.log" "alive=$alive markers=${crashes:-0}"; fi
if [ -f "$GLOG/pp-sample.csv" ]; then
  minfree=$(awk -F, 'NR > 1 && $2 != "" { if (m == "" || $2 + 0 < m) m = $2 + 0 } END { print m }' "$GLOG/pp-sample.csv")
  swap0=$(awk -F, 'NR == 2 { print $3 + 0 }' "$GLOG/pp-sample.csv"); swapmax=$(awk -F, 'NR > 1 { if ($3 + 0 > m) m = $3 + 0 } END { print m + 0 }' "$GLOG/pp-sample.csv")
  peakrss=$(awk -F, 'NR > 1 { if ($4 + 0 > m) m = $4 + 0 } END { print m + 0 }' "$GLOG/pp-sample.csv")
  winerss=$(awk -F, 'NR > 1 { if ($5 + 0 > m) m = $5 + 0 } END { print m + 0 }' "$GLOG/pp-sample.csv")
  metric samples "$(( $(wc -l < "$GLOG/pp-sample.csv") - 1 ))"; metric mem_free_min_pct "${minfree:-}"; metric peak_rss_max_mb "$peakrss"; metric wine_rss_max_mb "$winerss"
  growth=$(awk -v a="${swap0:-0}" -v b="${swapmax:-0}" 'BEGIN { printf "%.0f", b - a }'); metric swap_growth_mb "$growth"
  maxlvl=$(awk -F, '$2 != "" { if ($2 + 0 > m) m = $2 + 0 } END { print m + 0 }' "$GLOG/pressure-level.csv" 2>/dev/null)
  metric pressure_level_max "${maxlvl:-0}"
  if [ "${maxlvl:-0}" -ge 1 ] && [ "$maxlvl" -lt 4 ]; then crit mem_pressure pass "memory pressure never red (kern.memorystatus_vm_pressure_level < 4)" "max level $maxlvl, min free ${minfree:-?} %"
  elif [ "${maxlvl:-0}" -ge 4 ]; then crit mem_pressure fail "memory pressure never red" "level 4 (critical) seen; min free ${minfree:-?} %"
  else crit mem_pressure skip "memory pressure level" "no readings; min free ${minfree:-?} %"; fi
  if [ "$growth" -lt 1024 ]; then crit swap_growth pass "swap growth < 1 GB" "${growth} MB"; else crit swap_growth fail "swap growth < 1 GB" "${growth} MB"; fi
else
  crit mem_pressure fail "memory sampled during the run" "pp-sample.csv missing"
fi
[ -f "$GLOG/t12.out" ] && tail -6 "$GLOG/t12.out" > "$GLOG/t12-summary.txt"
gate_end
