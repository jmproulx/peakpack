#!/bin/bash
# TITLE: G-A2-CX (optional) CrossOver 26 baseline for G-A2: detect only; the install/trial is Joshua's call
# Part of PeakPack for Mac (mac/testkit). MIT licence. Run through run_gate.sh.
#
# G-A2's main criterion is ">= 90 % of CrossOver/DXMT average fps on the same Mac and route". That needs a
# CrossOver trial with Steam + PEAK in a bottle (DESIGN §10a item 4: OK as a benchmark). Installing it means
# accepting CodeWeavers' licence and a trial sign-up, so this gate never does it:
#   CrossOver not found -> needs-human (exit 3) with the steps.
#   CrossOver found     -> needs-human too, with the measuring steps; when the hub has done them it re-runs
#                          with --fps "<comma separated HUD readings>" and the gate records the baseline.
# Args: [--fps LIST] (CrossOver HUD readings on the Shore, same route as G-A2-lite)
set -u
. "$PP_KIT_DIR/lib/common.sh"
gate_begin G-A2-CX "CrossOver baseline (optional)"
gate_require_mac
fps=""
while [ $# -gt 0 ]; do case "$1" in --fps) fps=$2; shift 2 ;; *) shift ;; esac; done
cx=""; for a in /Applications/CrossOver.app "$HOME/Applications/CrossOver.app"; do [ -d "$a" ] && cx=$a; done
if [ -n "$fps" ]; then
  stats=$(printf '%s\n' "$fps" | tr ',' '\n' | awk 'NF { n++; s += $1; if (m == "" || $1 < m) m = $1 } END { if (n) printf "%.1f %s %d", s / n, m, n }')
  # shellcheck disable=SC2086
  set -- $stats
  metric cx_fps_avg "${1:-}"; metric cx_fps_min "${2:-}"; metric cx_fps_samples "${3:-0}"
  version_set crossover "$(defaults read "$cx/Contents/Info" CFBundleShortVersionString 2>/dev/null)"
  crit baseline pass "CrossOver baseline recorded" "avg ${1:-?}, min ${2:-?} over ${3:-0} readings"
  job_env_set CX_FPS_AVG "${1:-}"
  gate_end
fi
STEPS="CrossOver baseline for G-A2 (optional; Joshua decides whether to use the trial, DESIGN §10a):
 1. Joshua (or the hub with his OK): install the CrossOver 26 trial for the fleet user only (~/Applications), accept the licence.
 2. In CrossOver: new Windows 10 64-bit bottle 'peak-baseline'; install Steam (Windows) into it; Joshua signs in (Steam Guard).
 3. Install PEAK in that bottle (or point its library at a copy of the depot from G-B5), enable D3DMetal OFF / DXMT ON per CrossOver's bottle settings, Metal HUD on.
 4. Launch PEAK -force-d3d11 -screen-width 1440 -screen-height 900 -screen-fullscreen 1 -window-mode borderless.
 5. Same route as G-A2-lite: main menu -> solo -> Shore, read HUD fps every 30 s for 2 min, screenshots cx-fps-<n>.png.
 6. Re-run: bash run_gate.sh G-A2-CX --job-dir <job> -- --fps <readings>.
 7. Cleanup: delete the bottle (CrossOver > Bottle > Delete), quit CrossOver; uninstalling CrossOver is Joshua's call."
if [ -z "$cx" ]; then
  crit crossover info "CrossOver installed" "no (optional)"
  gate_finish_as needs-human "CrossOver is not installed (optional benchmark; Joshua's call)" "$STEPS"
fi
crit crossover info "CrossOver installed" "$cx"
gate_finish_as needs-human "CrossOver present; the baseline run needs Steam sign-in inside the bottle" "$STEPS"
