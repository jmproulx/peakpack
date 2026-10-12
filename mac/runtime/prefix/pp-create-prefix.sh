#!/bin/bash
# pp-create-prefix.sh <runtime_dir> <prefix_dir> [backend]
# Creates (or updates, when the runtime changed) the PeakPack Wine prefix:
#   1. wineboot without wine-mono/wine-gecko and without menu entries
#   2. sandbox the user folders (no links to ~/Desktop, ~/Documents, ...: no TCC prompts,
#      nothing written outside the prefix)
#   3. import reg/[0-9]*.reg (win10, PEAK.exe winhttp override, Mac driver, audio, DPI)
#   4. select the graphics backend (default dxmt) and install dxmt.conf
#   5. stamp <prefix>/peakpack/prefix.json
# Safe to re-run. Uses only bash 3.2 + macOS base tools.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
R="${1:?usage: $0 <runtime> <prefix> [backend]}"; P="${2:?prefix}"; backend="${3:-}"
PREFIX_SCHEMA=1

# shellcheck source=pp-env.sh
. "$here/pp-env.sh"
pp_env "$R" "$P"
runtime_id="$(basename "$R")"
stamp="$P/peakpack/prefix.json"

old_runtime=""
if [ -f "$stamp" ]; then
  old_runtime="$(sed -n 's/.*"runtime_id": *"\([^"]*\)".*/\1/p' "$stamp")"
fi
[ -n "$backend" ] || backend="$(cat "$P/peakpack/backend" 2>/dev/null || echo dxmt)"

mkdir -p "$P"
if [ ! -f "$P/system.reg" ]; then
  echo "creating prefix $P with $runtime_id"
  WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d" "$R/bin/wine" wineboot --init
elif [ "$old_runtime" != "$runtime_id" ]; then
  echo "updating prefix $P: $old_runtime -> $runtime_id"
  WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d" "$R/bin/wine" wineboot --update
fi
"$R/bin/wineserver" -w

# Sandbox user shell folders: Wine links them to the Mac home folders by default.
users="$P/drive_c/users"
if [ -d "$users" ]; then
  for u in "$users"/*; do
    [ -d "$u" ] || continue
    for d in Desktop Documents Downloads Music Pictures Videos "My Documents" "My Music" "My Pictures" "My Videos" Templates; do
      if [ -L "$u/$d" ]; then rm -f "$u/$d"; mkdir -p "$u/$d"; fi
    done
  done
fi

for f in "$here"/reg/[0-9]*.reg; do
  "$R/bin/wine" reg import "$f" >/dev/null 2>&1 || { echo "reg import failed: $f" >&2; exit 1; }
done
"$R/bin/wineserver" -w

mkdir -p "$P/peakpack"
[ -f "$P/peakpack/dxmt.conf" ] || cp "$here/dxmt.conf" "$P/peakpack/dxmt.conf"
"$here/pp-backend.sh" "$R" "$P" "$backend"

cat > "$stamp" <<EOF
{
 "schema": $PREFIX_SCHEMA,
 "runtime_id": "$runtime_id",
 "backend": "$backend",
 "updated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
"$R/bin/wineserver" -k 2>/dev/null || true
echo "prefix ready: $P ($runtime_id, $backend)"
