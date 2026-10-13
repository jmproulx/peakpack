#!/bin/bash
# TITLE: G-X1 cross-play Mac <-> Windows with a second player: room code, Steam join, voice, companion, networked mods (needs humans)
# Part of PeakPack for Mac (mac/testkit). MIT licence. Run through run_gate.sh. Slot 3.
#
# Two Steam accounts must play together, and one Steam account cannot be in two games at once, so this
# needs a second person. Recommended set-up (no credentials ever change hands):
#   Mac (iMac, fleet user): Joshua's account (already signed in), modded PEAK started by this gate.
#   Windows: the pilot friend's own PC, own account, PeakPack (same pack revision).
#   Joshua: at the iMac for voice (speaks/listens; answers the microphone prompt, H-MIC) - or on a call.
# Default: exit 3 with the instructions. With PP_HUMAN_PRESENT=1 the gate launches modded PEAK (same path as
# G-D2), then walks the agent through CU steps lobby, steamjoin, voice, companion, mods, and finally runs the
# Steam team's t6_t14_checklist.sh on the Mac's Player.log.
set -u
. "$PP_KIT_DIR/lib/common.sh"
. "$PP_KIT_DIR/lib/assets.sh"
gate_begin G-X1 "Cross-play Mac <-> Windows (human)"
gate_require_mac
gate_require_gui   # Wine/Unity windows need the logged-in GUI session (blocked otherwise)
INSTR="G-X1 cross-play session (about 45 min; needs two people):
 Before: G-D2 passed in this job (modded PEAK works on the Mac); the friend's Windows PC has PeakPack synced to the
 same pack revision (PeakPack shows the revision; the Mac's is in results/G-D2.json metrics.installed_revision).
 People: Joshua at the iMac (fleet user; speaks and listens for the voice test, answers the macOS microphone prompt),
 the pilot friend on Windows with their own Steam account, the hub's agent driving the Mac and taking screenshots.
 1. Joshua tells the hub 'G-X1 go'; the hub re-runs: PP_HUMAN_PRESENT=1 bash run_gate.sh G-X1 --job-dir <job>
    (and H-MIC with PP_HUMAN_PRESENT=1 in parallel).
 2. The agent hosts a lobby on the Mac; the friend joins by ROOM CODE; then the reverse (friend hosts, Mac joins).
 3. Steam join both ways: the friend uses 'Join Game' on the Mac account in their Steam friends list; then the Mac
    joins the friend from Mac Steam's friends list (the in-game invite button does nothing on Mac: expected, T11).
 4. Voice both ways with the built-in mic (not AirPods).
 5. The PeakPack companion's lobby check shows the same revision on both sides (no mismatch warning).
 6. Networked mods: heli (HeliPilot), glider (ElytraGlider), item tuner (ItemTuner), scoutmaster (ScoutmasterMode):
    each used by one player and seen correctly by the other.
 Pass: everything above works with no desync. Copy back: results/G-X1.json, logs/G-X1/, evidence/G-X1/."
if [ "${PP_HUMAN_PRESENT:-0}" != 1 ]; then
  gate_finish_as needs-human "cross-play needs Joshua and the pilot friend online" "$INSTR"
fi
steam_running || gate_finish_as needs-human "Mac Steam is not running" "Run H-STEAM first."
keep_awake
ensure_runtime || gate_finish_as blocked "runtime not available (G-A1)"
ensure_tests >/dev/null 2>&1; ensure_bridge >/dev/null 2>&1
ensure_prefix || gate_finish_as error "prefix creation failed"
ensure_game_in_prefix || gate_finish_as blocked "PEAK is not in the job dir (G-B5)"
ensure_peakpack || gate_finish_as blocked "PeakPack.exe not available"
[ -f "$(peakpack_win_dir)/profile/BepInEx/core/BepInEx.Preloader.dll" ] || gate_finish_as blocked "mods are not synced in this job's prefix (run G-D2 first)"
GATE_CLEANUP=wine_stop
tests_dir="$PFX/drive_c/PeakPackTests"; mkdir -p "$tests_dir"; cp "$BRIDGE/peakpack_steam_launcher.exe" "$BRIDGE/steamclient64.dll" "$tests_dir/"
wu=$(wine_user); plog=$(player_log_path)
pp_wine normal 'C:\PeakPackTests\peakpack_steam_launcher.exe' --forwarder-src 'C:\PeakPackTests\steamclient64.dll' \
  --log 'C:\PeakPackTests\launcher-x1.log' --no-launch --hold-ms 9000000 > "$GLOG/launcher.out" 2>&1 &
sleep 8
t0=$(now_s)
PP_EXTRA_OVERRIDES="winhttp=n,b" pp_wine normal "C:\\users\\$wu\\AppData\\Local\\PeakPack\\PeakPack.exe" --headless --launch \
  --launch-method direct --game-dir 'C:\Games\PEAK' --status-out 'C:\PeakPackTests\x1-launch.json' > "$GLOG/peakpack-launch.out" 2>&1
wait_for_file_text "$plog" "Steam runtime manager initialized" 300 "$t0" || gate_finish_as fail "modded PEAK did not start (no Steam line in Player.log)"
step() {  # step ID TIMEOUT "instruction" "criterion text"
  cu_request "$1" "$2" "$3"
  case $? in 0) crit "$1" pass "$4" "$CU_NOTE" ;; 1) crit "$1" fail "$4" "$CU_NOTE" ;; *) crit "$1" skip "$4" "$CU_ANSWER $CU_NOTE" ;; esac
}
step lobby 1800 "With Joshua and the friend on a call: (a) on the Mac choose Play and host a lobby, read out the ROOM CODE, the friend joins by code from Windows. Screenshot x1-a-mac-host.png with both scouts visible. (b) leave; the friend hosts, the Mac joins by the friend's code; screenshot x1-b-mac-joined.png. Answer ok if both directions worked, fail <which failed and the message>." "room-code join works both ways"
step steamjoin 1800 "(a) The friend right-clicks the Mac account in their Steam friends list and uses Join Game while the Mac hosts; screenshot x1-c.png. (b) The Mac joins the friend from Mac Steam's friends list (Join Game); screenshot x1-d.png. Pressing the in-game invite button on the Mac is expected to do nothing (record if it crashes). Answer ok/fail <details>." "Steam friends-list join works both ways"
step voice 900 "Voice: Joshua speaks near the iMac's built-in mic, the friend confirms hearing him; the friend speaks, Joshua confirms hearing them on the Mac. If a macOS microphone prompt appears, leave it for Joshua (H-MIC). Answer ok if both directions are audible, fail <direction that failed>." "voice works both ways (built-in mic)"
step companion 600 "PeakPack companion lobby check: in the shared lobby, confirm there is no pack/version mismatch notice on either side (screenshot x1-e-lobby-check.png). Answer ok or fail <message shown>." "companion lobby check: same pack revision, no mismatch"
step mods 2400 "Networked mods: start a run together. Try each: helicopter (HeliPilot), glider (ElytraGlider), item tuner (ItemTuner), scoutmaster (ScoutmasterMode). For each, one player uses it and the other confirms it looks right (no desync, no teleporting, items consistent). Screenshot x1-mod-<name>.png for each. Answer ok heli=ok glider=ok itemtuner=ok scoutmaster=ok, or fail with the per-mod results." "networked mods behave the same on both sides"
for k in heli glider itemtuner scoutmaster; do v=$(cu_kv "$k"); [ -n "$v" ] && metric "mod_$k" "$v" str; done
[ -f "$plog" ] && cp "$plog" "$GLOG/Player.log"
if [ -n "${TESTS:-}" ] && [ -f "$TESTS/mac/t6_t14_checklist.sh" ] && [ -f "$GLOG/Player.log" ]; then
  bash "$TESTS/mac/t6_t14_checklist.sh" "$GLOG/Player.log" > "$GLOG/t6_t14_checklist.txt" 2>&1
  grep -q '== T6' "$GLOG/t6_t14_checklist.txt" && note "T6-T14 evidence: $(grep -A3 '== T6\|== T7\|== T8' "$GLOG/t6_t14_checklist.txt" | grep -c 'Log:    FOUND') markers FOUND (see t6_t14_checklist.txt)"
fi
gate_end
