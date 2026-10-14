#!/bin/bash
# collect.sh - bundle what the hub copies back: results, logs, evidence, CU answers, state.
# Part of PeakPack for Mac (mac/testkit). MIT licence.
#
# Usage: bash collect.sh <job-dir> [--max-file-mb N]  (default 50: bigger single files are listed, not packed)
# Output: <job-dir>/copyback/peakpack-<job-id>-results.tar.gz (+ .sha256) and a file list on stdout.
# Not included: downloads/, runtime/, prefix/, game/, unity/, native/ (big, reproducible, or licensed content).
set -u
job=${1:?usage: collect.sh <job-dir> [--max-file-mb N]}; shift
max=50
while [ $# -gt 0 ]; do case "$1" in --max-file-mb) max=$2; shift 2 ;; *) shift ;; esac; done
job=$(cd "$job" && pwd -P)
id=$(basename "$job")
mkdir -p "$job/copyback"
list="$job/copyback/files.txt"; big="$job/copyback/skipped-large-files.txt"
: > "$list"; : > "$big"
( cd "$job" && for d in results logs evidence cu state; do [ -d "$d" ] && find "$d" -type f; done; for f in job.env .peakpack-testkit-job downloads/SHA256SUMS run_slot-console.txt; do [ -f "$f" ] && echo "$f"; done ) |
  while IFS= read -r f; do
    sz=$(wc -c < "$job/$f" | tr -d ' ')
    if [ "$sz" -gt $(( max * 1048576 )) ]; then printf '%s\t%s\n' "$f" "$sz" >> "$big"; else printf '%s\n' "$f" >> "$list"; fi
  done
tgz="$job/copyback/peakpack-$id-results.tar.gz"
# Privacy: everything is packed from a staging copy in which every text file went through redact_text
# (EOS token in Player.log, Steam session tickets, auth tokens; lib/common.sh). The job dir itself is untouched.
stage="$job/copyback/stage"; rm -rf "$stage"; mkdir -p "$stage/copyback"
while IFS= read -r f; do mkdir -p "$stage/$(dirname "$f")"; cp -p "$job/$f" "$stage/$f"; done < "$list"
cp "$big" "$stage/copyback/"
PP_KIT_DIR=${PP_KIT_DIR:-$(cd "$(dirname "$0")" && pwd)}
eval "$(sed -n '/^redact_text() {/,/^}/p; /^redact_file() {/,/^}/p; /^redact_dir() {/,/^}/p' "$PP_KIT_DIR/lib/common.sh")"
redact_dir "$stage"
tar -C "$stage" -czf "$tgz" -T "$list" copyback/skipped-large-files.txt
rm -rf "$stage"
shasum -a 256 "$tgz" | sed "s#  .*#  $(basename "$tgz")#" > "$tgz.sha256"
echo "copy back: $tgz ($(du -h "$tgz" | cut -f1), $(wc -l < "$list" | tr -d ' ') files)"
[ -s "$big" ] && { echo "not packed (larger than ${max} MB):"; cat "$big"; }
[ -f "$job/results/summary.txt" ] && cat "$job/results/summary.txt"
exit 0
