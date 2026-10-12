#!/bin/bash
# pp-sample.sh <out.csv> [interval_s=10]
# Gate helper (G-A2/G-A3, DESIGN §7): samples memory pressure, swap and the PEAK/Wine
# processes' memory every N seconds until interrupted (Ctrl-C). macOS base tools only.
# Columns: utc, pressure_free_pct, swap_used_mb, peak_rss_mb, wine_total_rss_mb, wineserver_cpu
set -euo pipefail
out="${1:?usage: $0 <out.csv> [interval_s]}"; iv="${2:-10}"
echo "utc,pressure_free_pct,swap_used_mb,peak_rss_mb,wine_total_rss_mb,wineserver_cpu" > "$out"
while :; do
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  free="$(memory_pressure 2>/dev/null | sed -n 's/.*System-wide memory free percentage: \([0-9]*\)%.*/\1/p')"
  swap="$(sysctl -n vm.swapusage | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p')"
  peak="$(ps -axo rss=,command= | awk '/PEAK\.exe/ && !/awk/ {s+=$1} END {printf "%.0f", s/1024}')"
  wine="$(ps -axo rss=,command= | awk '/(wine|\.exe)/ && !/awk/ {s+=$1} END {printf "%.0f", s/1024}')"
  wscpu="$(ps -axo %cpu=,command= | awk '/wineserver/ && !/awk/ {s+=$1} END {printf "%.1f", s}')"
  echo "$ts,${free:-},${swap:-},${peak:-0},${wine:-0},${wscpu:-0}" >> "$out"
  sleep "$iv"
done
