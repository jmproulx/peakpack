#!/bin/bash
# TITLE: kit self-test: sleep N seconds, then pass (CI test of run_gate stop/restart; in no slot)
# Part of PeakPack for Mac (mac/testkit). MIT licence. Run through run_gate.sh. Args: [--seconds N] (default 10)
set -u
. "$PP_KIT_DIR/lib/common.sh"
gate_begin X-SLEEP "kit self-test (sleep)"
n=10
while [ $# -gt 0 ]; do case "$1" in --seconds) n=$2; shift 2 ;; *) shift ;; esac; done
i=0
while [ "$i" -lt "$n" ]; do sleep 1; i=$((i + 1)); done
crit slept pass "slept $n s"
gate_end
