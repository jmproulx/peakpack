#!/bin/bash
# pp-run.sh <runtime_dir> <prefix_dir> [--logs] -- <windows program> [args...]
# Test helper for gates G-A1/G-A2 (the front end and the Steam helper have their own
# launchers but must build the environment with pp-env.sh the same way).
# Examples:
#   pp-run.sh "$RT" "$PFX" -- winecfg
#   PP_HUD=1 pp-run.sh "$RT" "$PFX" --logs -- 'C:\Games\PEAK\PEAK.exe' -force-d3d11 \
#       -screen-width 1440 -screen-height 900 -screen-fullscreen 1
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
R="${1:?usage: $0 <runtime> <prefix> [--logs] -- <program> [args]}"; P="${2:?prefix}"; shift 2
R="$(cd "$R" && pwd)"; mkdir -p "$P" && P="$(cd "$P" && pwd)"   # absolute (Wine child processes have another cwd)
mode=normal
while [ $# -gt 0 ]; do
  case "$1" in
    --logs) mode=logs; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done
[ $# -ge 1 ] || { echo "pp-run: no program given" >&2; exit 2; }
# shellcheck source=pp-env.sh
. "$here/pp-env.sh"
pp_env "$R" "$P" "$mode"
if [ "$mode" = logs ]; then
  log="${PP_LOG_DIR:-$(dirname "$P")/logs}/wine-$(date +%Y%m%d-%H%M%S).log"
  echo "logging to $log" >&2
  exec "$R/bin/wine" "$@" >>"$log" 2>&1
fi
exec "$R/bin/wine" "$@"
