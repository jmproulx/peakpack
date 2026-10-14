#!/bin/bash
# depot_manifest.sh - read-only file manifest of a PEAK install, for test T15
# (gate G-B5): compare the Windows depot fetched on the Mac with Valve's own
# tools against a reference install of the same build.
# Part of PeakPack for Mac (runtime/steam). MIT licence (see ../docs/README.md).
#
# Runs on macOS (bash 3.2) and in Windows git-bash. Never writes into GAME_DIR.
# Usage: depot_manifest.sh GAME_DIR OUT_FILE
#   Windows reference: depot_manifest.sh 'D:/SteamLibrary/steamapps/common/PEAK' peak-win.manifest
#   Mac, download_depot: depot_manifest.sh "$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamapps/content/app_3527290/depot_3527291" peak-mac.manifest
#   Compare: diff peak-win.manifest peak-mac.manifest   (no output = identical)
# Lines: "<sha256>  <size>  <relative path>", sorted. Mod-loader artifacts (BepInEx/, BepInEx's root
# changelog.txt, Doorstop's files on Windows and macOS, MelonLoader) and Unity's per-machine caches are
# skipped, so a modded reference install still compares. The same pattern is in testkit/lib/common.sh
# (MODLOADER_PATHS, applied again when comparing) and in the mac-runtime-lint check of testkit/expect/.
set -euo pipefail
MODLOADER_PATHS='BepInEx/|doorstop_libs/|MelonLoader/|changelog\.txt$|\.doorstop_version$|doorstop_config\.ini$|winhttp\.dll$|libdoorstop\.|run_bepinex\.sh$'
dir=${1:?game dir}; out=${2:?output file}
[ -f "$dir/PEAK.exe" ] || { echo "no PEAK.exe in $dir" >&2; exit 1; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | cut -d' ' -f1; else shasum -a 256 < "$1" | cut -d' ' -f1; fi; }
( cd "$dir" && LC_ALL=C find . -type f \
    ! -path './BepInEx/*' ! -name 'doorstop_config.ini' ! -name 'winhttp.dll' ! -name '.doorstop_version' \
    ! -name 'output_log.txt' ! -name 'Player*.log' ! -path './PEAK_Data/*Cache*' | LC_ALL=C sort |
  { grep -v -E "^\./($MODLOADER_PATHS)" || true; } |
  while IFS= read -r f; do
      printf '%s  %s  %s\n' "$(sha "$f")" "$(wc -c < "$f" | tr -d ' ')" "${f#./}"
  done ) > "$out"
echo "$(wc -l < "$out" | tr -d ' ') files -> $out"
