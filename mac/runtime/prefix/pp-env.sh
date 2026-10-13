# shellcheck shell=bash
# pp-env.sh: the ONE place that defines the Wine environment for PeakPack (INTERFACES.md §4).
# Source it from bash (macOS /bin/bash 3.2 is fine), call pp_env, then exec wine directly
# from the same bash process, so DYLD_FALLBACK_LIBRARY_PATH survives (SIP strips DYLD_*
# when a protected binary such as /bin/sh is exec'd in between).
#
#   . "$RUNTIME/share/peakpack/prefix/pp-env.sh"
#   pp_env "$RUNTIME" "$PREFIX" [normal|logs]
#   exec "$RUNTIME/bin/wine" ...
#
# Tuning knobs (TUNING.md) are read from the caller's environment when set:
#   PP_SYNC=msync|esync|none (default msync)   PP_HUD=0|1 (Metal HUD)
#   PP_AVX=0|1 (ROSETTA_ADVERTISE_AVX)         PP_DXMT_CONFIG="key=value;..."
#   PP_LOG_DIR=<dir> (default <prefix>/../logs)

pp_env() {
  local rt="${1:?pp_env: runtime dir}" pfx="${2:?pp_env: prefix dir}" mode="${3:-normal}"
  [ -x "$rt/bin/wine" ] || { echo "pp_env: $rt is not a PeakPack runtime" >&2; return 1; }
  # Absolute paths only: Wine child processes run with another working directory, so relative
  # WINELOADER/WINEPREFIX values break them ("could not load kernel32.dll, status c0000135").
  rt="$(cd "$rt" && pwd)"
  mkdir -p "$pfx" && pfx="$(cd "$pfx" && pwd)"

  export PP_RUNTIME="$rt"
  export WINEPREFIX="$pfx"
  export WINELOADER="$rt/bin/wine"
  export WINESERVER="$rt/bin/wineserver"
  export PATH="$rt/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export DYLD_FALLBACK_LIBRARY_PATH="$rt/lib:/usr/lib"
  # Never inherit overrides: the per-app registry keys are the source of truth, and the env
  # var would beat them. Callers that need the Doorstop backup set it after pp_env.
  unset WINEDLLOVERRIDES WINEDLLPATH

  case "${PP_SYNC:-msync}" in
    msync) export WINEMSYNC=1 WINEESYNC=0 ;;
    esync) export WINEMSYNC=0 WINEESYNC=1 ;;
    none)  export WINEMSYNC=0 WINEESYNC=0 ;;
    *) echo "pp_env: bad PP_SYNC=$PP_SYNC" >&2; return 1 ;;
  esac

  local logdir="${PP_LOG_DIR:-$(dirname "$pfx")/logs}"
  mkdir -p "$logdir"
  if [ "$mode" = logs ]; then
    export WINEDEBUG="err+all,warn-all,fixme-all"
    export DXMT_LOG_LEVEL=info DXMT_LOG_PATH="$logdir"
  else
    export WINEDEBUG="-all"
    export DXMT_LOG_LEVEL=none DXMT_LOG_PATH=none
  fi
  # Diagnostics override (CI smoke, support): PP_WINEDEBUG wins over the mode default.
  if [ -n "${PP_WINEDEBUG:-}" ]; then export WINEDEBUG="$PP_WINEDEBUG"; fi

  export DXMT_CONFIG_FILE="$pfx/peakpack/dxmt.conf"
  if [ -n "${PP_DXMT_CONFIG:-}" ]; then export DXMT_CONFIG="$PP_DXMT_CONFIG"; else unset DXMT_CONFIG; fi
  export DXMT_SHADER_CACHE_PATH="$pfx/peakpack/dxmt-cache"
  mkdir -p "$DXMT_SHADER_CACHE_PATH"

  export MTL_HUD_ENABLED="${PP_HUD:-0}"
  # Steam bridge (runtime/steam, R4): unix dir of the Mac Steam client's steamclient.dylib.
  # The patched lsteamclient falls back to this same default when unset.
  export STEAM_COMPAT_CLIENT_INSTALL_PATH="${STEAM_COMPAT_CLIENT_INSTALL_PATH:-$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS}"
  if [ "${PP_AVX:-0}" = 1 ]; then export ROSETTA_ADVERTISE_AVX=1; else unset ROSETTA_ADVERTISE_AVX; fi
  # winemenubuilder is not built (--disable-winemenubuilder) and is also disabled in
  # reg/00-base.reg, so Wine never creates Mac menu or Launchpad entries.
}
