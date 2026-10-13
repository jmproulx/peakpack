#!/bin/bash
# pp-backend.sh <runtime_dir> <prefix_dir> <dxmt|dxvk|dxvk-nodxgi|wined3d>
# Selects PEAK's D3D11 backend for a prefix: copies the DLL set into system32 and imports
# the matching PEAK.exe-scoped override file. Persistent; the launcher does not pass it.
# Default backend: dxmt. Records the choice in <prefix>/peakpack/backend.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
R="${1:?usage: $0 <runtime> <prefix> <backend>}"; P="${2:?prefix}"; B="${3:?backend}"
R="$(cd "$R" && pwd)"; mkdir -p "$P" && P="$(cd "$P" && pwd)"   # absolute (Wine child processes have another cwd)
# shellcheck source=pp-env.sh
. "$here/pp-env.sh"
pp_env "$R" "$P"

sys32="$P/drive_c/windows/system32"
[ -d "$sys32" ] || { echo "pp-backend: $P is not an initialised prefix" >&2; exit 1; }
wine_dlls="$R/lib/wine/x86_64-windows"

put_wine_builtin() { cp "$wine_dlls/$1" "$sys32/$1"; }   # restores Wine's builtin placeholder

case "$B" in
  dxvk|dxvk-nodxgi)
    # DXVK is an optional fallback; a runtime built without it says so instead of half-switching.
    [ -f "$R/lib/peakpack/dxvk/x86_64-windows/d3d11.dll" ] \
      || { echo "pp-backend: this runtime has no DXVK fallback (see manifest.json components.dxvk.present)" >&2; exit 3; } ;;
esac

case "$B" in
  dxmt)
    for f in d3d11.dll dxgi.dll d3d10core.dll; do cp "$R/lib/peakpack/dxmt/x86_64-windows/$f" "$sys32/$f"; done
    cp "$wine_dlls/winemetal.dll" "$sys32/winemetal.dll"
    reg="backend-dxmt.reg" ;;
  dxvk)
    for f in d3d11.dll dxgi.dll d3d10core.dll; do cp "$R/lib/peakpack/dxvk/x86_64-windows/$f" "$sys32/$f"; done
    reg="backend-dxvk.reg" ;;
  dxvk-nodxgi)
    for f in d3d11.dll d3d10core.dll; do cp "$R/lib/peakpack/dxvk/x86_64-windows/$f" "$sys32/$f"; done
    put_wine_builtin dxgi.dll
    reg="backend-dxvk-nodxgi.reg" ;;
  wined3d)
    for f in d3d11.dll dxgi.dll d3d10core.dll; do put_wine_builtin "$f"; done
    reg="backend-wined3d.reg" ;;
  *) echo "pp-backend: unknown backend '$B' (dxmt|dxvk|dxvk-nodxgi|wined3d)" >&2; exit 2 ;;
esac

"$R/bin/wine" reg import "$here/reg/$reg" >/dev/null 2>&1 || { echo "pp-backend: reg import $reg failed" >&2; exit 1; }
"$R/bin/wineserver" -w
mkdir -p "$P/peakpack"
printf '%s\n' "$B" > "$P/peakpack/backend"
echo "backend: $B"
