#!/bin/bash
# run_slot.sh - run the gates of a slot file in order (the hub's job spec, e.g. slot1.job.json).
# Part of PeakPack for Mac (mac/testkit). MIT licence.
#
# Usage: bash run_slot.sh <slot-file.json> [--job-dir DIR] [--job-id ID] [--release TAG]
#                         [--only "G-B0 G-B1"] [--from GATE] [--assets-dir DIR] [--no-cu]
#   Reads job_id, release.tag, run_order[], gates[].{id,args,requires[]} and early_cu[] from the slot file.
#   early_cu requests are written at once, so the agent can start long manual steps (the depot download)
#   while the scripts run other gates. A gate whose "requires" did not pass is recorded as blocked and
#   skipped. Every gate still gets results/<gate>.json; the slot gets results/summary.{json,txt}.
#   Start it in the BACKGROUND and answer computer-use requests with cu.sh while it runs.
# Exit: 0 all pass; 1 any fail/error; 2 any blocked (none failed); 3 only needs-human left.
set -u
KIT=$(cd "$(dirname "$0")" && pwd)
slot=${1:-}; [ -f "$slot" ] || { sed -n '2,14p' "$0"; exit 4; }
shift
job_dir=""; job_id=""; release=""; only=""; from=""; extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    --job-dir) job_dir=$2; shift 2 ;; --job-id) job_id=$2; shift 2 ;; --release) release=$2; shift 2 ;;
    --only) only=" $2 "; shift 2 ;; --from) from=$2; shift 2 ;;
    --assets-dir) extra+=(--assets-dir "$2"); shift 2 ;; --no-cu) extra+=(--no-cu); shift ;;
    *) echo "unknown argument $1" >&2; exit 4 ;;
  esac
done
flat=$(mktemp "${TMPDIR:-/tmp}/ppslot.XXXXXX"); trap 'rm -f "$flat"' EXIT
awk -f "$KIT/lib/json_flat.awk" "$slot" > "$flat" || { echo "run_slot: $slot is not valid JSON" >&2; exit 4; }
jv() { awk -F'\t' -v p="$1" '$1 == p { v = $2 } END { printf "%s", v }' "$flat"; }

[ -n "$job_id" ] || job_id=$(jv job_id)
case "$job_id" in ''|*'{'*|auto) job_id="$(jv slot | tr -cd 'A-Za-z0-9-')"; job_id="${job_id:-slot}-$(date +%Y%m%d-%H%M)" ;; esac
[ -n "$release" ] || release=$(jv release.tag)
[ -n "$job_dir" ] || job_dir="$HOME/peakpack-test/$job_id"
mkdir -p "$job_dir/cu" "$job_dir/results"
echo "run_slot: $(jv title) | job $job_id | dir $job_dir | release ${release:-default}"

# early computer-use requests (pre-announced so the agent can start them now)
n=$(jv early_cu._count); i=0
while [ "$i" -lt "${n:-0}" ]; do
  k=$(jv "early_cu.$i.key"); to=$(jv "early_cu.$i.timeout_s"); txt=$(jv "early_cu.$i.instruction")
  if [ -n "$k" ] && [ ! -f "$job_dir/cu/$k.done" ]; then
    printf 'gate=%s\nstep=%s\ndoc=gates/%s.md#cu-%s\ntimeout_s=%s\ncreated=%s\nearly=1\nanswer_with=bash testkit/cu.sh %s done %s ok|fail|skip "note" [key=value ...]\n---\n%s\n' \
      "${k%%.*}" "${k#*.}" "${k%%.*}" "${k#*.}" "$to" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$job_dir" "$k" "$(printf '%b' "$txt")" > "$job_dir/cu/$k.request"
    echo "[CU-REQUEST] $k (early; start it now): $(printf '%s' "$txt" | cut -c1-200)"
  fi
  i=$((i + 1))
done

status_of() { sed -n 's/^  "status": "\([^"]*\)".*/\1/p' "$job_dir/results/$1.json" 2>/dev/null | head -1; }
gate_index() { awk -F'\t' -v g="$1" '$1 ~ /^gates\.[0-9]+\.id$/ && $2 == g { split($1, a, "."); print a[2]; exit }' "$flat"; }
write_blocked() {  # gate reason
  ( export PP_KIT_DIR="$KIT" PP_JOB_DIR="$job_dir"
    # shellcheck source=lib/common.sh
    . "$KIT/lib/common.sh"
    GATE_ID=$1; GATE_TITLE=$(sed -n 's/^# TITLE: //p' "$KIT/gates/$1.sh" | head -1)
    GTMP="$job_dir/tmp/gate-$1"; GLOG="$job_dir/logs/$1"; GEVID="$job_dir/evidence/$1"; mkdir -p "$GTMP" "$GLOG"
    for f in criteria.jsonl metrics.tsv notes.txt cu.jsonl evidence.txt; do : > "$GTMP/$f"; done
    GATE_START=$(now_utc); GATE_T0=$(now_s); GATE_STATUS=blocked; GATE_REASON=$2; GATE_HUMAN=""; PP_RELEASE=$release
    gate_write_json )
}

started=0; [ -z "$from" ] && started=1
order_n=$(jv run_order._count); i=0; ran=""
while [ "$i" -lt "${order_n:-0}" ]; do
  g=$(jv "run_order.$i"); i=$((i + 1))
  [ "$started" = 1 ] || { [ "$g" = "$from" ] && started=1 || continue; }
  [ -z "$only" ] || case "$only" in *" $g "*) ;; *) continue ;; esac
  gi=$(gate_index "$g")
  args=""; [ -n "$gi" ] && args=$(jv "gates.$gi.args")
  missing=""
  if [ -n "$gi" ]; then
    rn=$(jv "gates.$gi.requires._count"); r=0
    while [ "$r" -lt "${rn:-0}" ]; do
      req=$(jv "gates.$gi.requires.$r"); r=$((r + 1))
      [ "$(status_of "$req")" = pass ] || missing="$missing $req($(status_of "$req"))"
    done
  fi
  echo; echo "======== $g $(date +%H:%M:%S)"
  if [ -n "$missing" ]; then
    echo "run_slot: $g skipped, required gate(s) not passed:$missing"
    write_blocked "$g" "required gate(s) not passed:$missing"
  else
    # shellcheck disable=SC2086  # args from the slot file are plain flags
    bash "$KIT/run_gate.sh" "$g" --job-dir "$job_dir" --job-id "$job_id" ${release:+--release "$release"} ${extra[@]+"${extra[@]}"} -- $args
  fi
  ran="$ran $g"
done

# summary
{
  printf '{\n  "job_id": "%s",\n  "slot_file": "%s",\n  "release": "%s",\n  "finished": "%s",\n  "gates": [' "$job_id" "$(basename "$slot")" "$release" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  first=1
  for g in $ran; do
    s=$(status_of "$g"); d=$(sed -n 's/^  "duration_s": \([0-9]*\).*/\1/p' "$job_dir/results/$g.json" 2>/dev/null | head -1)
    rs=$(sed -n 's/^  "reason": \(".*"\),$/\1/p' "$job_dir/results/$g.json" 2>/dev/null | head -1)
    [ $first = 1 ] && first=0 || printf ','
    printf '\n    {"gate": "%s", "status": "%s", "duration_s": %s, "reason": %s, "result": "results/%s.json"}' "$g" "${s:-error}" "${d:-0}" "${rs:-\"\"}" "$g"
  done
  printf '\n  ]\n}\n'
} > "$job_dir/results/summary.json"
{
  printf '%-10s %-12s %8s  %s\n' GATE STATUS SECONDS REASON
  for g in $ran; do
    printf '%-10s %-12s %8s  %s\n' "$g" "$(status_of "$g")" "$(sed -n 's/^  "duration_s": \([0-9]*\).*/\1/p' "$job_dir/results/$g.json" 2>/dev/null | head -1)" \
      "$(sed -n 's/^  "reason": "\(.*\)",$/\1/p' "$job_dir/results/$g.json" 2>/dev/null | head -1 | cut -c1-90)"
  done
} > "$job_dir/results/summary.txt"
echo; cat "$job_dir/results/summary.txt"
echo; echo "copy back: bash $KIT/collect.sh $job_dir   then clean up: bash $KIT/cleanup.sh $job_dir"
worst=0
for g in $ran; do
  case "$(status_of "$g")" in fail|error) worst=1 ;; blocked) [ "$worst" = 1 ] || worst=2 ;; needs-human) [ "$worst" = 0 ] && worst=3 ;; esac
done
exit "$worst"
