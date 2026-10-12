#!/bin/bash
# package_bridge.sh - pack the BUILT Steam bridge for a mac-build-* prerelease.
# Part of PeakPack for Mac (runtime/steam). MIT licence (see ../docs/README.md).
#
# Contains binaries and licence texts only; never Valve's sources.
#   peakpack-steam-bridge-<RUNTIME_ID>-<rev>/
#     lib/wine/x86_64-windows/lsteamclient.dll   -> runtime (runtime/build/add_builtin.sh)
#     lib/wine/x86_64-unix/lsteamclient.so       -> runtime (unsigned)
#     share/peakpack/steam/steamclient64.dll     forwarder, copied into the prefix by the launcher
#     share/peakpack/steam/peakpack_steam_launcher.exe
#     LICENSES/  build-info.txt  SHA256SUMS
#   peakpack-steam-tests-<RUNTIME_ID>-<rev>.tar.xz: probes + Mac gate scripts (not for friends)
#
# Usage: package_bridge.sh --bridge DIR --pe DIR --dist DIR [--rev REV]
#   --bridge  output of build_lsteamclient.sh collect (lsteamclient.dll/.so, build-info.txt, LICENSE.lsteamclient.txt)
#   --pe      dir with steamclient64.dll, peakpack_steam_launcher.exe, steam_client_probe.exe, steam_api_probe.exe
#   --dist    where the .tar.xz files and their .sha256 go
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
steam_root=$(cd "$here/.." && pwd)
bridge=""; pe=""; dist=""; rev=${GITHUB_SHA:-local}
while [ $# -gt 0 ]; do
    case "$1" in
        --bridge) bridge=$2; shift 2 ;;
        --pe) pe=$2; shift 2 ;;
        --dist) dist=$2; shift 2 ;;
        --rev) rev=$2; shift 2 ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
done
[ -n "$bridge" ] && [ -n "$pe" ] && [ -n "$dist" ] || { sed -n '2,20p' "$0"; exit 2; }
rev=$(printf '%s' "$rev" | cut -c1-12)
rid=${RUNTIME_ID:-$(sed -n 's/^runtime_id=//p' "$bridge/build-info.txt")}
name=peakpack-steam-bridge-$rid-$rev
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
root=$stage/$name
mkdir -p "$root/lib/wine/x86_64-windows" "$root/lib/wine/x86_64-unix" "$root/share/peakpack/steam" "$root/LICENSES"
cp "$bridge/lsteamclient.dll" "$root/lib/wine/x86_64-windows/"
cp "$bridge/lsteamclient.so" "$root/lib/wine/x86_64-unix/"
cp "$pe/steamclient64.dll" "$pe/peakpack_steam_launcher.exe" "$root/share/peakpack/steam/"
cp "$bridge/build-info.txt" "$root/"
cp "$bridge/LICENSE.lsteamclient.txt" "$root/LICENSES/lsteamclient-Steamworks-SDK-LICENSE.txt"
cp "$steam_root/docs/LICENSE-PeakPack-steam.txt" "$root/LICENSES/"
cp "$steam_root/docs/NOTICE-steam-bridge.md" "$root/LICENSES/"
if command -v codesign >/dev/null 2>&1 && codesign -dv "$root/lib/wine/x86_64-unix/lsteamclient.so" >/dev/null 2>&1; then
    echo "ERROR: lsteamclient.so is signed" >&2; exit 1
fi
( cd "$root" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s  %s\n' "$(sha "$f")" "${f#./}"; done > SHA256SUMS )
mkdir -p "$dist"
tar -C "$stage" -cJf "$dist/$name.tar.xz" "$name"
echo "$(sha "$dist/$name.tar.xz")  $name.tar.xz" > "$dist/$name.tar.xz.sha256"

tname=peakpack-steam-tests-$rid-$rev
troot=$stage/$tname
mkdir -p "$troot/probe" "$troot/mac"
cp "$pe/steam_client_probe.exe" "$pe/steam_api_probe.exe" "$troot/probe/"
cp "$steam_root"/tests/probe/*.c "$steam_root"/tests/probe/*.h "$troot/probe/"
cp "$steam_root"/tests/mac/*.sh "$troot/mac/"
tar -C "$stage" -cJf "$dist/$tname.tar.xz" "$tname"
echo "$(sha "$dist/$tname.tar.xz")  $tname.tar.xz" > "$dist/$tname.tar.xz.sha256"
ls -l "$dist"
