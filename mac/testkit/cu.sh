#!/bin/bash
# cu.sh - the hub agent's side of the computer-use handshake (see README.md "Computer-use handshake").
# Part of PeakPack for Mac (mac/testkit). MIT licence.
#
#   bash cu.sh <job-dir> list                         open requests (one line each: <gate>.<step>  timeout  doc)
#   bash cu.sh <job-dir> show <gate>.<step>           full text of a request
#   bash cu.sh <job-dir> wait [SECONDS]               block until a request is open (default 600 s); prints them
#   bash cu.sh <job-dir> done <gate>.<step> ok|fail|skip ["note"] [key=value ...]
#                                                     answer (also works BEFORE the request exists: pre-answer)
#   bash cu.sh <job-dir> shot <gate> <name>           screenshot (screencapture -x) to evidence/<gate>/<name>.png
# Examples:
#   bash cu.sh ~/peakpack-test/slot1-20261013 done G-B5.download ok "complete" path="/Users/fleet/Library/.../depot_3527291" manifest=1234
#   bash cu.sh ~/peakpack-test/slot1-20261013 done G-A2-lite.fps ok "smooth" fps=58,60,57,59 min=57
set -u
job=${1:?usage: cu.sh <job-dir> list|show|wait|done ...}; cmd=${2:-list}
d="$job/cu"
[ -d "$d" ] || { echo "no $d (has a gate run in this job yet?)" >&2; exit 2; }
case "$cmd" in
  list)
    n=0
    for f in "$d"/*.request; do
      [ -f "$f" ] || continue
      n=$((n + 1))
      printf '%-28s timeout=%-6s %s\n' "$(basename "$f" .request)" "$(sed -n 's/^timeout_s=//p' "$f")" "$(sed -n 's/^doc=//p' "$f")"
    done
    [ "$n" = 0 ] && echo "(no open requests)"
    exit 0 ;;
  show)
    k=${3:?key}; f="$d/$k.request"; [ -f "$f" ] || f="$d/$k.request.closed"
    [ -f "$f" ] && cat "$f" || { echo "no request $k" >&2; exit 2; } ;;
  wait)
    to=${3:-600}; t0=$(date +%s)
    while [ $(( $(date +%s) - t0 )) -lt "$to" ]; do
      if ls "$d"/*.request >/dev/null 2>&1; then
        for f in "$d"/*.request; do echo "== $(basename "$f" .request)"; sed -n '/^---$/,$p' "$f" | sed 1d; done
        exit 0
      fi
      sleep 3
    done
    echo "(no request within ${to}s)"; exit 1 ;;
  done)
    k=${3:?key}; a=${4:?ok|fail|skip}; note=${5:-}
    case "$a" in ok|fail|skip) ;; *) echo "answer must be ok, fail or skip" >&2; exit 2 ;; esac
    case "$k" in *[!A-Za-z0-9._-]*) echo "bad key $k" >&2; exit 2 ;; esac
    # a 5th argument that looks like key=value is a result, not the note
    if printf '%s' "$note" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*='; then note=""; shift 4; else shift 5 2>/dev/null || shift $#; fi
    { printf '%s %s\n' "$a" "$note"; for kv in "$@"; do case "$kv" in *=*) printf '%s\n' "$kv" ;; esac; done; } > "$d/$k.done.tmp"
    mv "$d/$k.done.tmp" "$d/$k.done"
    echo "answered $k: $a" ;;
  shot)
    g=${3:?gate}; n=${4:?name}
    case "$g$n" in *[!A-Za-z0-9._-]*) echo "bad gate/name" >&2; exit 2 ;; esac
    mkdir -p "$job/evidence/$g"
    if [ "${PP_SCREENSHOTS:-0}" != 1 ]; then
      # screencapture would raise macOS's Screen Recording prompt; the hub saves its own screenshot instead
      echo "in-kit screenshots are off (PP_SCREENSHOTS=1 enables them): save your own screenshot as $job/evidence/$g/${n%.png}.png" ; exit 0
    fi
    screencapture -x -t png "$job/evidence/$g/${n%.png}.png" && echo "saved evidence/$g/${n%.png}.png" ;;
  *) sed -n '2,16p' "$0"; exit 2 ;;
esac
