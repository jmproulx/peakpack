#!/bin/bash
# cleanup.sh - remove everything a test job created, and nothing else.
# Part of PeakPack for Mac (mac/testkit). MIT licence.
#
# Usage: bash cleanup.sh <job-dir> [--dry-run] [--keep-job-dir] [--report FILE]
#   1. stops our Wine processes (the runtime's wineserver -k with OUR WINEPREFIX) and any process whose
#      command line contains the job dir (PEAK.exe under our Wine, the G-C0 player, samplers)
#   2. removes paths outside the job dir that a gate created and that did NOT exist when the job started
#      (state/preexisting.tsv): Steam's steamapps/content/app_3527290 and downloading/3527290 (both Steam
#      layouts), new depotcache/3527291_*.manifest files, Unity's LandCrab/PEAK per-user folders (G-C0),
#      and our Wine server socket dir (/tmp/.wine-<uid>/server-<dev>-<inode> of our prefix)
#   3. deletes the job dir (only under ~/peakpack-test/ and only with the kit's marker file); removes
#      ~/peakpack-test when it is then empty
# Never touches: the Steam app, Steam's login/config/registry.vdf, other games, system settings, Rosetta,
# the Xcode CLT, other users. Collect the results first (collect.sh): they are inside the job dir.
# Exit: 0 clean, 1 something could not be removed (listed), 2 refused (unsafe path).
set -u
job=${1:-}; shift || true
dry=0; keep=0; report=""
while [ $# -gt 0 ]; do
  case "$1" in --dry-run) dry=1; shift ;; --keep-job-dir) keep=1; shift ;; --report) report=$2; shift 2 ;; *) echo "unknown argument $1" >&2; exit 2 ;; esac
done
[ -n "$job" ] && [ -d "$job" ] || { echo "usage: cleanup.sh <job-dir> [--dry-run] [--keep-job-dir] [--report FILE]" >&2; exit 2; }
job=$(cd "$job" && pwd -P)
root=$(cd "$HOME/peakpack-test" 2>/dev/null && pwd -P)
case "$job/" in "$root"/?*/) ;; *) [ "${PP_ALLOW_ANY_JOB_DIR:-0}" = 1 ] || { echo "refusing: $job is not inside ~/peakpack-test" >&2; exit 2; } ;; esac
[ -f "$job/.peakpack-testkit-job" ] || { echo "refusing: $job has no .peakpack-testkit-job marker" >&2; exit 2; }

STEAM_DATA="$HOME/Library/Application Support/Steam"
pre="$job/state/preexisting.tsv"; outside="$job/state/outside-paths.tsv"
out=$(mktemp "${TMPDIR:-/tmp}/ppclean.XXXXXX")
say() { printf '%s\n' "$*" | tee -a "$out"; }
problems=0
run() { if [ "$dry" = 1 ]; then say "  (dry run) $*"; else "$@"; fi; }
preexisted() { [ -f "$pre" ] && awk -F'\t' -v p="$1" '$1 == p && $2 == 1 { f = 1 } END { exit !f }' "$pre"; }
snapshot_known() { [ -f "$pre" ] && awk -F'\t' -v p="$1" '$1 == p { f = 1 } END { exit !f }' "$pre"; }
# Only these locations may ever be removed outside the job dir.
allowed_outside() {
  case "$1" in
    "$STEAM_DATA"/steamapps/content/app_3527290|"$STEAM_DATA"/Steam.AppBundle/Steam/Contents/MacOS/steamapps/content/app_3527290) return 0 ;;
    "$STEAM_DATA"/steamapps/content/app_3527290/depot_3527291|"$STEAM_DATA"/Steam.AppBundle/Steam/Contents/MacOS/steamapps/content/app_3527290/depot_3527291) return 0 ;;
    "$STEAM_DATA"/steamapps/downloading/3527290|"$STEAM_DATA"/Steam.AppBundle/Steam/Contents/MacOS/steamapps/downloading/3527290) return 0 ;;
    "$STEAM_DATA"/depotcache/3527291_*.manifest|"$STEAM_DATA"/Steam.AppBundle/Steam/Contents/MacOS/depotcache/3527291_*.manifest) return 0 ;;
    "$HOME/Library/Logs/LandCrab"|"$HOME/Library/Logs/LandCrab/PEAK") return 0 ;;
    "$HOME/Library/Application Support/LandCrab"|"$HOME/Library/Application Support/LandCrab/PEAK"|"$HOME/Library/Application Support/unity.LandCrab.PEAK") return 0 ;;
    "$HOME/Library/Preferences/unity.LandCrab.PEAK.plist") return 0 ;;
    "$HOME/Library/Saved Application State/com.peakpack.testkit.native.savedState"|"$HOME/Library/Caches/com.peakpack.testkit.native"|"$HOME/Library/Caches/LandCrab") return 0 ;;
    # PEAK (Modded).app's own macOS entries (G-APP gates; the app's data itself is in the job dir)
    "$HOME/Library/Preferences/com.peakpack.modded.plist"|"$HOME/Library/Saved Application State/com.peakpack.modded.savedState"|"$HOME/Library/Caches/com.peakpack.modded") return 0 ;;
  esac
  return 1
}
remove_outside() {  # path why
  local p=$1
  [ -e "$p" ] || [ -L "$p" ] || return 0
  if ! allowed_outside "$p"; then say "  KEPT $p (not on the allowed list)"; return 0; fi
  if preexisted "$p"; then say "  KEPT $p (existed before the job)"; return 0; fi
  if ! snapshot_known "$p" && [ ! -f "$pre" ]; then say "  KEPT $p (no pre-job snapshot, cannot prove it is ours)"; return 0; fi
  run rm -rf "$p" && say "  REMOVED $p ($2)"
  [ "$dry" = 1 ] || { [ -e "$p" ] && { say "  FAILED to remove $p"; problems=$((problems + 1)); }; }
}

say "cleanup of $job ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
pfx="$job/prefix"
# ---- 1. processes
say "1. processes"
for ws in "$job"/runtime/*/bin/wineserver; do
  [ -x "$ws" ] && [ -d "$pfx" ] && { run env WINEPREFIX="$pfx" "$ws" -k >/dev/null 2>&1; say "  wineserver -k for our prefix ($(basename "$(dirname "$(dirname "$ws")")"))"; }
done
sleep 2
pids=$(pgrep -U "$(id -u)" -f -- "$job" 2>/dev/null | grep -v -x -e "$$" -e "$PPID")
if [ -n "$pids" ]; then
  say "  stopping $(printf '%s\n' "$pids" | wc -l | tr -d ' ') process(es) started from the job dir"
  for p in $pids; do run kill -TERM "$p" 2>/dev/null; done
  sleep 5
  for p in $pids; do kill -0 "$p" 2>/dev/null && run kill -KILL "$p" 2>/dev/null; done
else say "  none running"; fi

# ---- 2. outside the job dir
say "2. paths outside the job dir"
if [ -f "$outside" ]; then
  while IFS="$(printf '\t')" read -r p kind gate why; do
    [ -n "$p" ] || continue
    case "$kind" in created-by-us) remove_outside "$p" "$gate: $why" ;; *) say "  KEPT $p ($kind)" ;; esac
  done < "$outside"
fi
if [ -f "$pre" ]; then
  while IFS="$(printf '\t')" read -r p was; do
    case "$p" in '#'*|'') continue ;; esac
    [ "$was" = 0 ] && remove_outside "$p" "did not exist before the job"
  done < "$pre"
fi
for d in "$STEAM_DATA/depotcache" "$STEAM_DATA/Steam.AppBundle/Steam/Contents/MacOS/depotcache"; do
  for f in "$d"/3527291_*.manifest; do [ -e "$f" ] && [ -f "$pre" ] && ! preexisted "$f" && remove_outside "$f" "depotcache entry from our download_depot"; done
done
# Wine server socket dir of OUR prefix (named after the prefix dir's device and inode)
if [ -d "$pfx" ]; then
  # shellcheck disable=SC2046  # intended: split "dev inode" into two positional fields
  set -- $(stat -f '%d %i' "$pfx" 2>/dev/null)
  if [ $# = 2 ]; then
    sname=$(printf 'server-%x-%x' "$1" "$2")
    for base in "/tmp/.wine-$(id -u)" "$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null).wine-$(id -u)"; do
      [ -d "$base/$sname" ] && { run rm -rf "$base/$sname"; say "  REMOVED $base/$sname (Wine server socket dir of our prefix)"; }
      [ -d "$base" ] && [ "$dry" = 0 ] && rmdir "$base" 2>/dev/null && say "  REMOVED empty $base"
    done
  fi
fi
say "  untouched: the Steam app, Steam login and settings, other games, system settings, Rosetta, Xcode CLT"

# ---- 3. the job dir
say "3. job dir"
if [ "$keep" = 1 ]; then say "  KEPT $job (--keep-job-dir)"
else
  sz=$(du -sk "$job" 2>/dev/null | awk '{ printf "%.1f GB", $1 / 1048576 }')
  if [ "$dry" = 1 ]; then say "  (dry run) would remove $job ($sz)"
  else
    find "$job" -type d ! -perm -u+w -exec chmod u+w {} + 2>/dev/null   # read-only dirs (Wine, pkgutil) would block rm
    rm -rf "$job"
    if [ -e "$job" ]; then say "  FAILED to remove $job completely"; problems=$((problems + 1)); else say "  REMOVED $job ($sz)"; fi
    rmdir "$root" 2>/dev/null && say "  REMOVED empty $root"
  fi
fi
[ -n "$report" ] && cp "$out" "$report"
rm -f "$out"
[ "$problems" = 0 ] && { say "cleanup: OK"; exit 0; }
say "cleanup: $problems problem(s)"; exit 1
