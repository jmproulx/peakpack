#!/bin/bash
# runner_restart_test.sh - regression test (kit 0.3.3): the hub stops a run_gate and at once starts a new one
# in the same job dir. The old runner's stop path must never touch the new run (slot-app, kit 0.3.2: the new
# G-APP2 was killed, exit 137). Runs on Linux (CI lint) and macOS. Exit 0 = pass.
set -u
kit=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); job="$tmp/job"
bash "$kit/run_gate.sh" X-SLEEP --job-dir "$job" -- --seconds 90 > "$tmp/old.out" 2>&1 &
old=$!
sleep 6
kill -TERM "$old"                                   # stop the old runner ...
bash "$kit/run_gate.sh" X-SLEEP --job-dir "$job" -- --seconds 8 > "$tmp/new.out" 2>&1   # ... and start a new one at once
rc=$?
wait "$old" 2>/dev/null; orc=$?
status=$(sed -n 's/^  "status": "\([^"]*\)".*/\1/p' "$job/results/X-SLEEP.json" 2>/dev/null | head -1)
echo "old runner exit $orc; new runner exit $rc, result status '$status'"
if [ "$rc" = 0 ] && [ "$status" = pass ]; then echo "PASS: new run survived the old runner's stop"; rm -rf "$tmp"; exit 0; fi
echo "FAIL: new run did not finish cleanly"; echo "--- new.out"; cat "$tmp/new.out"; echo "--- old.out"; cat "$tmp/old.out"; exit 1
