#!/bin/bash
# t12_memsample.sh - T12 (DESIGN.md gate G-A3 / G-B4): sample memory, swap and
# Wine RSS during a long PEAK session on an 8 GB Mac. Read-only: it calls ps,
# vm_stat, sysctl, memory_pressure and pagesize, and writes only to the logs dir.
#
# Usage: t12_memsample.sh [--interval SEC] [--duration-min MIN] [--logs DIR]
#   --interval       seconds between samples (default 10)
#   --duration-min   total run time in minutes (default 60)
#   --logs           output dir (default ./logs-<timestamp>); gets memsample.csv
# Ctrl-C stops early and still prints the summary.
# Gate: swap growth = largest rise of swap used above the first sample must be
# under 1 GB (1024 MB). Exit 0 on PASS, 1 on FAIL.
#
# Part of PeakPack for Mac (runtime/steam). MIT licence (see ../../docs/README.md).
set -u

interval=10
duration=60
logs=""

usage() { echo "usage: $0 [--interval SEC] [--duration-min MIN] [--logs DIR]" >&2; exit 2; }
isint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --interval)     [ $# -ge 2 ] || usage; interval=$2; shift 2 ;;
    --duration-min) [ $# -ge 2 ] || usage; duration=$2; shift 2 ;;
    --logs)         [ $# -ge 2 ] || usage; logs=$2; shift 2 ;;
    *) usage ;;
  esac
done
isint "$interval" && [ "$interval" -gt 0 ] || usage
isint "$duration" && [ "$duration" -gt 0 ] || usage
[ -n "$logs" ] || logs="./logs-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$logs" || { echo "cannot create $logs" >&2; exit 2; }
csv="$logs/memsample.csv"
echo "timestamp,elapsed_s,mem_free_pct,swap_used_mb,pages_free_mb,pages_active_mb,pages_wired_mb,pages_compressed_mb,wine_rss_mb,wine_procs" > "$csv"
pagesz=$(pagesize 2>/dev/null || getconf PAGESIZE 2>/dev/null || echo 16384)

# System-wide free percentage: memory_pressure -Q, else the full report's line.
mem_free_pct() {
  v=$(memory_pressure -Q 2>/dev/null | grep -i 'free percentage' | head -1)
  [ -n "$v" ] || v=$(memory_pressure 2>/dev/null | grep -i 'free percentage' | head -1)
  v=$(printf '%s' "$v" | sed 's/.*: *//; s/%.*//')
  echo "${v:-NA}"
}

# Swap used in MB from "vm.swapusage: total = 2048.00M  used = 1024.50M  free = ..."
swap_used_mb() {
  sysctl -n vm.swapusage 2>/dev/null | awk '{
    for (i = 1; i <= NF; i++) if ($i == "used") {
      v = $(i + 2); u = substr(v, length(v), 1); n = substr(v, 1, length(v) - 1) + 0
      if (u == "K") n /= 1024; else if (u == "G") n *= 1024; else if (u == "T") n *= 1048576
      printf "%.0f", n
    } }'
}

# Free, active, wired and compressed memory in MB, from vm_stat page counts.
vm_mb() {
  if ! command -v vm_stat >/dev/null 2>&1; then echo "NA NA NA NA"; return; fi
  vm_stat 2>/dev/null | awk -F': *' -v ps="$pagesz" '
    { v = $2; gsub(/\./, "", v); k = $1 }
    k == "Pages free"           { f = v }
    k == "Pages active"         { a = v }
    k == "Pages wired down"     { w = v }
    k == "Pages occupied by compressor" { c = v }
    END { printf "%.0f %.0f %.0f %.0f", f * ps / 1048576, a * ps / 1048576, w * ps / 1048576, c * ps / 1048576 }'
}

# Summed RSS (MB) and process count for processes whose command matches wine|PEAK.exe|steamclient.
wine_rss() {
  ps -axo rss=,comm= 2>/dev/null | awk '
    tolower($0) ~ /wine|peak\.exe|steamclient/ { s += $1; n++ }
    END { printf "%.0f %d", s / 1024, n + 0 }'
}

max_rss=0
max_swap=0
first_swap=""
samples=0

summary() {
  echo ""
  echo "samples: $samples   csv: $csv"
  echo "max wine RSS: ${max_rss} MB"
  echo "max swap used: ${max_swap} MB"
  if [ -z "$first_swap" ]; then
    echo "FAIL: no swap readings (vm.swapusage unavailable), cannot check G-A3"
    return 1
  fi
  growth=$((max_swap - first_swap))
  echo "swap growth over first sample: ${growth} MB (gate: under 1024 MB)"
  if [ "$growth" -ge 1024 ]; then
    echo "FAIL: swap grew by ${growth} MB (G-A3 needs under 1 GB)"
    return 1
  fi
  echo "PASS: swap growth ${growth} MB is under 1 GB"
  return 0
}

finish() {  # $1 = exit code to use when the gate passes
  trap '' INT TERM
  summary
  rc=$?
  [ "$rc" -eq 0 ] && rc=$1
  exit "$rc"
}
trap 'finish 130' INT TERM

start=$(date +%s)
total=$((duration * 60))
while :; do
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -ge "$total" ] && break

  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  free=$(mem_free_pct)
  swap=$(swap_used_mb)
  swap=${swap:-NA}
  vm=$(vm_mb)
  set -- $vm
  pf=$1; pa=$2; pw=$3; pc=$4
  # shellcheck disable=SC2046  # intended: split wine_rss output into positional fields
  set -- $(wine_rss)
  wrss=${1:-0}
  wcount=${2:-0}

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$ts" "$elapsed" "$free" "$swap" "$pf" "$pa" "$pw" "$pc" "$wrss" "$wcount" >> "$csv"
  samples=$((samples + 1))

  case "$swap" in
    NA) ;;
    *)
      if [ -z "$first_swap" ]; then first_swap=$swap; fi
      if [ "$swap" -gt "$max_swap" ]; then max_swap=$swap; fi
      ;;
  esac
  if [ "$wrss" -gt "$max_rss" ]; then max_rss=$wrss; fi
  echo "$ts  free=${free}%  swap=${swap}MB  wine_rss=${wrss}MB ($wcount procs)"

  sleep "$interval"
done
finish 0
