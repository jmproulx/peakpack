#!/bin/bash
# TITLE: H-MIC microphone permission for voice (needs Joshua: a macOS privacy prompt)
# Part of PeakPack for Mac (mac/testkit). MIT licence. Run through run_gate.sh.
#
# Photon Voice in PEAK opens the microphone. Under our Wine there is no front-end app yet, so macOS (TCC)
# attributes the request to the "responsible" app: whatever started Wine (the hub's tooling / Terminal).
# Granting microphone access is a privacy decision: agents never click Allow. The TCC database cannot be
# read without Full Disk Access, so the state cannot be checked from here either.
#   Default: exit 3 with the instructions below.
#   With PP_HUMAN_PRESENT=1 (Joshua is at the iMac): the agent watches for the prompt while Joshua answers it
#   during G-X1 (CU-prompt) and the gate records the app name and decision. Run it in parallel with G-X1.
set -u
. "$PP_KIT_DIR/lib/common.sh"
gate_begin H-MIC "Microphone permission (human)"
gate_require_mac
INSTR="Microphone permission for voice chat (needed for G-X1 only):
 1. Joshua is at the iMac (fleet user) when G-X1 starts PEAK.
 2. The first time PEAK opens the mic, macOS shows '<app> would like to access the microphone'. <app> is the
    program that started Wine (the hub's tool or Terminal), because there is no PeakPack app bundle yet.
 3. Joshua clicks Allow (agents never do). If no prompt appears and voice is silent: System Settings > Privacy &
    Security > Microphone > switch on that app, then restart PEAK.
 4. For the record: which app name the prompt showed, and whether AirPods or the built-in mic were used
    (TUNING.md A1: use the built-in mic; AirPods drop output to 16 kHz).
 5. After the slot: Joshua may switch that app's microphone access off again (System Settings > Privacy & Security > Microphone)."
if [ "${PP_HUMAN_PRESENT:-0}" = 1 ]; then
  cu_request prompt 1800 "Joshua is at the iMac for voice tests. When the macOS microphone prompt appears (during G-X1), do NOT click it; screenshot evidence/H-MIC/mic-prompt.png and wait until Joshua has answered. Answer ok app=<app name in the prompt> decision=<allowed|denied>, or skip if no prompt appeared within 30 min."
  case $? in
    0) crit mic_prompt pass "Joshua answered the microphone prompt" "app=$(cu_kv app) decision=$(cu_kv decision)"; metric prompt_app "$(cu_kv app)" str; metric decision "$(cu_kv decision)" str; gate_end ;;
    *) crit mic_prompt info "microphone prompt" "$CU_ANSWER $CU_NOTE" ;;
  esac
fi
gate_finish_as needs-human "microphone access is a privacy decision only Joshua makes" "$INSTR"
