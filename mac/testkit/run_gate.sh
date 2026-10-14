#!/bin/bash
# run_gate.sh - run ONE gate of the PeakPack for Mac test kit, non-interactively.
# Part of PeakPack for Mac (mac/testkit). MIT licence.
#
# Usage: bash run_gate.sh <gate-id> [--job-dir DIR] [--job-id ID] [--release TAG]
#                         [--assets-dir DIR] [--timeout-min N] [--no-cu] [--] [gate arguments...]
#        bash run_gate.sh --list
#
#   <gate-id>      P0, H-STEAM, G-B0, G-B1, G-A1, G-B5, G-B2, G-D2, G-A2-lite, G-C0, G-A2-CX, H-MIC, G-X1
#   --job-dir DIR  default: $PP_JOB_DIR, else ~/peakpack-test/<job-id>. Any dedicated folder works (not /, ~ or
#                  ~/peakpack-test itself; a non-empty folder needs the kit's marker). The marker is written.
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
    G-B5) echo 100 ;; G-B2) echo 40 ;; G-D2) echo 60 ;; G-A2-lite) echo 50 ;; G-C0) echo 150 ;;
    G-A2-CX) echo 5 ;; H-MIC) echo 30 ;; G-X1) echo 150 ;;
    G-APP1) echo 45 ;; G-APP2) echo 130 ;; G-APP3) echo 30 ;; G-APP4) echo 30 ;; G-APP5) echo 25 ;; G-APP6) echo 60 ;;
    *) echo 30 ;;
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
root_real=$( { [ -d "$root" ] && cd "$root" && pwd -P; } || printf %s "$root")   # no ~/peakpack-test created for jobs kept elsewhere
# Any explicit job dir is accepted (the hub may keep jobs elsewhere, e.g. ~/projects/peak/<id>); only the
# obviously wrong ones are refused. The marker file below is what cleanup.sh trusts before deleting.
# (PP_ALLOW_ANY_JOB_DIR is no longer needed here; cleanup.sh still honours it for dirs outside ~/peakpack-test.)
home_real=$(cd "$HOME" && pwd -P)
case "$job_dir" in /|"$home_real"|"$root_real") echo "run_gate: refusing job dir $job_dir (use a dedicated folder per job)" >&2; exit 4 ;; esac
if [ ! -f "$job_dir/.peakpack-testkit-job" ]; then
  for e in "$job_dir"/* "$job_dir"/.[!.]*; do
    [ -e "$e" ] || continue
    case "$(basename "$e")" in kit|cu|results|run_slot-console.txt|run.command|.DS_Store) ;;
      *) echo "run_gate: $job_dir is not empty and has no .peakpack-testkit-job marker; use a new folder per job" >&2; exit 4 ;;
    esac
  done
fi
[ -f "$job_dir/.peakpack-testkit-job" ] || printf 'job_id=%s\ncreated=%s\nkit=%s\n' "$(basename "$job_dir")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$KIT" > "$job_dir/.peakpack-testkit-job"
mkdir -p "$job_dir"/{downloads,results,logs,evidence,state,cu,tmp}

export PP_KIT_DIR="$KIT" PP_JOB_DIR="$job_dir" PP_JOB_ID
PP_JOB_ID=$(basename "$job_dir")
export TMPDIR="$job_dir/tmp/"
# shellcheck source=lib/common.sh
. "$KIT/lib/common.sh"
if [ -n "$release" ]; then job_env_set RELEASE "$release"; fi
if [ -n "${PP_STEAM_TESTS_TAG:-}" ]; then job_env_set STEAM_TESTS_TAG "$PP_STEAM_TESTS_TAG"; fi
if [ -n "${PP_PEAKPACK_TAG:-}" ]; then job_env_set PEAKPACK_TAG "$PP_PEAKPACK_TAG"; fi
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
# One runner per gate and job dir. A second runner (e.g. the hub restarting a slot while the old one is
# being stopped) waits up to 60 s for the previous one to exit, then refuses (exit 4). Nothing below ever
# reads another runner's state: the gate shell's PID goes to a file named after THIS runner ($$).
gdir="$job_dir/tmp/gate-$gate"; mkdir -p "$gdir"
lock="$gdir/runner.lock"; waited=0
while :; do
  if ( set -o noclobber; printf '%s\n' "$$" > "$lock" ) 2>/dev/null; then break; fi
  other=$(cat "$lock" 2>/dev/null)
  if [ -n "$other" ] && [ "$other" != "$$" ] && kill -0 "$other" 2>/dev/null; then
    if [ "$waited" -ge 60 ]; then echo "run_gate: another run_gate for $gate is still running in $job_dir (pid $other); refusing" >&2; exit 4; fi
    [ "$waited" = 0 ] && echo "run_gate: waiting for the previous run_gate for $gate (pid $other) to finish" >&2
    sleep 2; waited=$((waited + 2))
  else
    rm -f "$lock"   # stale lock of a runner that is gone
  fi
done
gate_pidfile="$gdir/pid.$$"
export PP_GATE_PIDFILE="$gate_pidfile"
cleanup_runner() { rm -f "$gate_pidfile"; [ "$(cat "$lock" 2>/dev/null)" = "$$" ] && rm -f "$lock"; return 0; }
rm -f "$job_dir/results/$gate.json" "$gate_pidfile"
printf '\n==== %s run_gate %s (kit %s, release %s, timeout %s min)\n' "$(now_utc)" "$gate" "$PP_KIT_VERSION" "$PP_RELEASE" "$timeout_min" >> "$console"
set -m
( bash "$script" ${pass_args[@]+"${pass_args[@]}"} < /dev/null 2>&1 | tee -a "$console"; exit "${PIPESTATUS[0]}" ) &
pid=$!
set +m
# Stop the gate: signal the gate's own shell first (its trap stops Wine and writes the result; bash runs
# the trap once its foreground child ends), then that child, then the whole process group. Only THIS
# runner's gate: its private pid file and its own process group ($pid leads it, set -m above).
gate_shell_pid=""
stop_gate() {
  local gpid
  [ -n "$gate_shell_pid" ] || gate_shell_pid=$(cat "$gate_pidfile" 2>/dev/null)
  gpid=$gate_shell_pid
  if [ -n "$gpid" ]; then kill -"$1" "$gpid" 2>/dev/null; pkill -"$1" -P "$gpid" 2>/dev/null; fi
  [ "$1" = KILL ] || sleep 5
  kill -"$1" -- "-$pid" 2>/dev/null || kill -"$1" "$pid" 2>/dev/null
}
# If run_gate itself is stopped, pass it on (the gate cleans up Wine itself).
trap 'stop_gate TERM; sleep 10; stop_gate KILL; cleanup_runner; exit 4' TERM INT HUP
deadline=$(( $(now_s) + timeout_min * 60 ))
timed_out=0
while kill -0 "$pid" 2>/dev/null; do
  [ -n "$gate_shell_pid" ] || gate_shell_pid=$(cat "$gate_pidfile" 2>/dev/null)   # captured once, never re-read
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
cleanup_runner

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
