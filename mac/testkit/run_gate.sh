#!/bin/bash
# run_gate.sh - run ONE gate of the PeakPack for Mac test kit, non-interactively.
# Part of PeakPack for Mac (mac/testkit). MIT licence.
#
# Usage: bash run_gate.sh <gate-id> [--job-dir DIR] [--job-id ID] [--release TAG]
#                         [--assets-dir DIR] [--timeout-min N] [--no-cu] [--] [gate arguments...]
#        bash run_gate.sh --list
#
#   <gate-id>      P0, H-STEAM, G-B0, G-B1, G-A1, G-B5, G-B2, G-D2, G-A2-lite, G-C0, G-A2-CX, H-MIC, G-X1
#   --job-dir DIR  default: $PP_JOB_DIR, else ~/peakpack-test/<job-id>. Must be under ~/peakpack-test/.
#   --job-id ID    default: $PP_JOB_ID, else "manual"
#   --release TAG  runtime release (default: the job's, else mac-build-runtime-pp1-cx26.3.0)
#   --assets-dir   folder where the hub already downloaded release assets (still SHA-256 verified)
#   --no-cu        no agent is watching: computer-use requests are answered "skip" at once (PP_CU=none)
#
# Output: results/<gate>.json, logs/<gate>/ (console.log = everything printed), evidence/<gate>/.
# Exit: 0 pass, 1 fail, 2 blocked (precondition missing), 3 needs-human, 4 error (incl. timeout).
# The gate runs in its own process group; on timeout the whole group gets TERM, then KILL.
set -u
KIT=$(cd "$(dirname "$0")" && pwd)
gate=""; job_dir=${PP_JOB_DIR:-}; job_id=${PP_JOB_ID:-}; release=""; timeout_min=""; env_release=${PP_RELEASE:-}
pass_args=()

gate_timeout_default() {  # minutes; generous on purpose (first runs translate x86 code with Rosetta)
  case "$1" in
    P0) echo 10 ;; H-STEAM) echo 3 ;; G-B0) echo 5 ;; G-B1) echo 10 ;; G-A1) echo 45 ;;
    G-B5) echo 100 ;; G-B2) echo 30 ;; G-D2) echo 45 ;; G-A2-lite) echo 35 ;; G-C0) echo 150 ;;
    G-A2-CX) echo 5 ;; H-MIC) echo 30 ;; G-X1) echo 150 ;; *) echo 30 ;;
  esac
}
list_gates() {
  local f id
  for f in "$KIT"/gates/*.sh; do
    id=$(basename "$f" .sh)
    printf '%-10s %4s min  %s\n' "$id" "$(gate_timeout_default "$id")" "$(sed -n 's/^# TITLE: //p' "$f" | head -1)"
  done
}

while [ $# -gt 0 ]; do
  case "$1" in
    --list) list_gates; exit 0 ;;
    --job-dir) job_dir=$2; shift 2 ;;
    --job-id) job_id=$2; shift 2 ;;
    --release) release=$2; shift 2 ;;
    --assets-dir) export PP_ASSETS_DIR=$2; shift 2 ;;
    --timeout-min) timeout_min=$2; shift 2 ;;
    --no-cu) export PP_CU=none; shift ;;
    --) shift; while [ $# -gt 0 ]; do pass_args+=("$1"); shift; done ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) if [ -z "$gate" ]; then gate=$1; else pass_args+=("$1"); fi; shift ;;
  esac
done
[ -n "$gate" ] || { sed -n '2,20p' "$0"; exit 4; }
script="$KIT/gates/$gate.sh"
[ -f "$script" ] || { echo "run_gate: unknown gate '$gate'. Known gates:" >&2; list_gates >&2; exit 4; }

# ---- job dir (all writes go here; see README "Paths outside the job dir")
root="$HOME/peakpack-test"
[ -n "$job_id" ] || job_id=manual
case "$job_id" in *[!A-Za-z0-9._-]*|'') echo "run_gate: bad job id '$job_id' (letters, digits, . _ -)" >&2; exit 4 ;; esac
[ -n "$job_dir" ] || job_dir="$root/$job_id"
mkdir -p "$job_dir" || { echo "run_gate: cannot create $job_dir" >&2; exit 4; }
job_dir=$(cd "$job_dir" && pwd -P)
root_real=$(mkdir -p "$root" && cd "$root" && pwd -P)
if [ "${PP_ALLOW_ANY_JOB_DIR:-0}" != 1 ]; then
  case "$job_dir/" in "$root_real"/?*/) ;; *) echo "run_gate: job dir must be inside $root (got $job_dir)" >&2; exit 4 ;; esac
fi
[ -f "$job_dir/.peakpack-testkit-job" ] || printf 'job_id=%s\ncreated=%s\nkit=%s\n' "$(basename "$job_dir")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$KIT" > "$job_dir/.peakpack-testkit-job"
mkdir -p "$job_dir"/{downloads,results,logs,evidence,state,cu,tmp}

export PP_KIT_DIR="$KIT" PP_JOB_DIR="$job_dir" PP_JOB_ID
PP_JOB_ID=$(basename "$job_dir")
export TMPDIR="$job_dir/tmp/"
# shellcheck source=lib/common.sh
. "$KIT/lib/common.sh"
if [ -n "$release" ]; then job_env_set RELEASE "$release"; fi
# release: --release > the job's job.env > $PP_RELEASE > default
PP_RELEASE=$(job_env_get RELEASE); [ -n "$PP_RELEASE" ] || { PP_RELEASE=${env_release:-$PP_DEFAULT_RELEASE}; job_env_set RELEASE "$PP_RELEASE"; }
export PP_RELEASE
version_set kit_version "$PP_KIT_VERSION"
version_set release "$PP_RELEASE"
snapshot_preexisting

# ---- run with a watchdog
[ -n "$timeout_min" ] || timeout_min=$(gate_timeout_default "$gate")
mkdir -p "$job_dir/logs/$gate"
console="$job_dir/logs/$gate/console.log"
rm -f "$job_dir/results/$gate.json" "$job_dir/tmp/gate-$gate/pid"
printf '\n==== %s run_gate %s (kit %s, release %s, timeout %s min)\n' "$(now_utc)" "$gate" "$PP_KIT_VERSION" "$PP_RELEASE" "$timeout_min" >> "$console"
set -m
( bash "$script" ${pass_args[@]+"${pass_args[@]}"} < /dev/null 2>&1 | tee -a "$console"; exit "${PIPESTATUS[0]}" ) &
pid=$!
set +m
# Stop the gate: signal the gate's own shell first (its trap stops Wine and writes the result; bash runs
# the trap once its foreground child ends), then that child, then the whole process group.
stop_gate() {
  local gpid; gpid=$(cat "$job_dir/tmp/gate-$gate/pid" 2>/dev/null)
  if [ -n "$gpid" ]; then kill -"$1" "$gpid" 2>/dev/null; pkill -"$1" -P "$gpid" 2>/dev/null; fi
  [ "$1" = KILL ] || sleep 5
  kill -"$1" -- "-$pid" 2>/dev/null || kill -"$1" "$pid" 2>/dev/null
}
# If run_gate itself is stopped, pass it on (the gate cleans up Wine itself).
trap 'stop_gate TERM; sleep 10; stop_gate KILL; exit 4' TERM INT HUP
deadline=$(( $(now_s) + timeout_min * 60 ))
timed_out=0
while kill -0 "$pid" 2>/dev/null; do
  if [ "$(now_s)" -ge "$deadline" ]; then
    timed_out=1
    echo "run_gate: $gate exceeded ${timeout_min} min; stopping it" | tee -a "$console"
    stop_gate TERM
    for _ in 1 2 3 4 5 6; do kill -0 "$pid" 2>/dev/null || break; sleep 5; done
    stop_gate KILL
    break
  fi
  sleep 3
done
wait "$pid" 2>/dev/null; rc=$?

# ---- make sure there is a result file with a valid status
json="$job_dir/results/$gate.json"
if [ ! -s "$json" ] || [ "$timed_out" = 1 ] || [ "$rc" -gt 4 ]; then
  GATE_ID=$gate; GATE_TITLE=$(sed -n 's/^# TITLE: //p' "$script" | head -1)
  GTMP="$job_dir/tmp/gate-$gate"; GLOG="$job_dir/logs/$gate"; GEVID="$job_dir/evidence/$gate"
  mkdir -p "$GTMP"; for f in criteria.jsonl metrics.tsv notes.txt cu.jsonl evidence.txt; do [ -f "$GTMP/$f" ] || : > "$GTMP/$f"; done
  GATE_START=$(now_utc); GATE_T0=$(now_s)
  if [ "$timed_out" = 1 ]; then GATE_REASON="timed out after ${timeout_min} min"; else GATE_REASON="gate script ended without a valid result (exit $rc); see logs/$gate/console.log"; fi
  # keep a partial result when the gate wrote one
  if [ -s "$json" ] && [ "$timed_out" = 1 ]; then GATE_REASON="$GATE_REASON (partial results were written)"; fi
  GATE_STATUS=error; GATE_HUMAN=""
  gate_write_json
  rc=4
  if [ "${RT:-}" = "" ] && [ -d "$job_dir/runtime" ]; then
    for w in "$job_dir"/runtime/*/bin/wineserver; do [ -x "$w" ] && WINEPREFIX="$job_dir/prefix" "$w" -k >/dev/null 2>&1; done
  fi
fi
status=$(sed -n 's/^  "status": "\([^"]*\)".*/\1/p' "$json" | head -1)
printf 'GATE %s %s (exit %s) %s\n' "$gate" "${status:-error}" "$rc" "$json" | tee -a "$console"
exit "$rc"
