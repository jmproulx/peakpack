#!/bin/bash
# add_builtin.sh <runtime_dir> <file>...
# Adds Wine builtin modules built against this runtime's SDK (INTERFACES.md §2.2):
#   *.dll/*.exe/*.drv/*.sys with the Wine builtin marker -> lib/wine/<arch>-windows/
#   *.so (Mach-O x86_64 unixlib, must be unsigned)        -> lib/wine/x86_64-unix/
# and records each file's SHA-256 in manifest.json -> extra_builtins[].
# Runs on macOS (needs lipo/codesign for unixlibs).
set -euo pipefail
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }

[ $# -ge 2 ] || die "usage: $0 <runtime_dir> <file>..."
R="$1"; shift
[ -f "$R/manifest.json" ] && [ -d "$R/lib/wine/x86_64-unix" ] || die "$R is not a PeakPack runtime"

entries=""
for f in "$@"; do
  [ -f "$f" ] || die "no such file: $f"
  name="$(basename "$f")"
  case "$name" in
    *.so)
      grep -q 'Mach-O 64-bit.*x86_64' <<<"$(file -b "$f")" || die "$name is not an x86_64 Mach-O"
      if codesign -dv "$f" >/dev/null 2>&1; then die "$name is code-signed; Wine unixlibs must stay unsigned"; fi
      dest="lib/wine/x86_64-unix/$name" ;;
    *.dll|*.exe|*.drv|*.sys)
      grep -q 'Wine builtin DLL' "$f" || die "$name lacks the Wine builtin marker (build it with winegcc/winebuild); non-builtin PE files go to share/peakpack/<team>/"
      # PE machine type: 0x8664 = x86_64, 0x014c = i386 (offset of 'PE\0\0' is at 0x3c).
      machine="$(python3 -I -c 'import struct,sys
d=open(sys.argv[1],"rb").read(4096); o=struct.unpack_from("<I",d,0x3c)[0]
print(hex(struct.unpack_from("<H",d,o+4)[0]))' "$f")"
      case "$machine" in
        0x8664) dest="lib/wine/x86_64-windows/$name" ;;
        0x14c)  dest="lib/wine/i386-windows/$name" ;;
        *) die "$name: unsupported PE machine $machine" ;;
      esac ;;
    *) die "$name: unsupported file type" ;;
  esac
  cp "$f" "$R/$dest"
  entries="$entries$dest $(sha "$R/$dest")
"
  printf 'added %s\n' "$dest"
done

printf '%s' "$entries" | python3 -I -c '
import json,sys
path=sys.argv[1]; m=json.load(open(path))
src=sys.argv[2]
for line in sys.stdin.read().splitlines():
    if not line.strip(): continue
    p,h=line.split()
    m["files"][p]=h
    m["extra_builtins"]=[e for e in m.get("extra_builtins",[]) if e["path"]!=p]+[{"path":p,"sha256":h,"from":src}]
json.dump(m,open(path,"w"),indent=1); open(path,"a").write("\n")
' "$R/manifest.json" "${PP_BUILTIN_FROM:-unspecified}"
