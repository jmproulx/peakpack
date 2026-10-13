#!/bin/bash
# package_tests.sh - pack the Steam/Mac test kit (probes + gate scripts; not for friends).
# Part of PeakPack for Mac (runtime/steam). MIT licence (see ../docs/README.md).
#
#   <name>.tar.xz -> <name>/probe/  steam_client_probe.exe, steam_api_probe.exe, and when present
#                                   d3d11_clear.exe, steam_client_probe-macos-x86_64, HarmonyProbe.dll; our probe sources
#                    <name>/mac/    tests/mac/*.sh (the Mac gate scripts)
#                    <name>/build-info.txt (when --info FILE is given)
# Used by package_bridge.sh (runtime builds) and by the tests-only workflow mac-steam-tests.yml.
# Usage: package_tests.sh --pe DIR --dist DIR --name NAME [--info FILE]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
steam_root=$(cd "$here/.." && pwd)
pe=""; dist=""; tname=""; info=""
while [ $# -gt 0 ]; do
    case "$1" in
        --pe) pe=$2; shift 2 ;;
        --dist) dist=$2; shift 2 ;;
        --name) tname=$2; shift 2 ;;
        --info) info=$2; shift 2 ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
done
[ -n "$pe" ] && [ -n "$dist" ] && [ -n "$tname" ] || { sed -n '2,10p' "$0"; exit 2; }
case "$tname" in *[!A-Za-z0-9._-]*) echo "bad package name $tname" >&2; exit 2 ;; esac
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
troot=$stage/$tname
mkdir -p "$troot/probe" "$troot/mac"
cp "$pe/steam_client_probe.exe" "$pe/steam_api_probe.exe" "$troot/probe/"
for p in d3d11_clear.exe steam_client_probe-macos-x86_64 HarmonyProbe.dll; do
    if [ -f "$pe/$p" ]; then cp "$pe/$p" "$troot/probe/"; fi
done
cp "$steam_root"/tests/probe/*.c "$steam_root"/tests/probe/*.h "$troot/probe/"
cp "$steam_root"/tests/mac/*.sh "$troot/mac/"
if [ -n "$info" ]; then cp "$info" "$troot/build-info.txt"; fi
mkdir -p "$dist"
tar -C "$stage" -cJf "$dist/$tname.tar.xz" "$tname"
echo "$(sha "$dist/$tname.tar.xz")  $tname.tar.xz" > "$dist/$tname.tar.xz.sha256"
