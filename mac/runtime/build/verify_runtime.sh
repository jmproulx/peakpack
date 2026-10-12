#!/bin/bash
# shellcheck disable=SC2015  # ok() and bad() never fail, so "A && ok || bad" is safe here
# verify_runtime.sh <runtime_dir> [--smoke]
# Static checks on an assembled runtime (any macOS host), and with --smoke a short live
# test: create a throwaway prefix with our prefix scripts and run a few Windows programs.
# On CI the smoke test runs on the macOS runner (it has a GUI session); on the Mac it is the
# first step of gate G-A1.
set -euo pipefail
# shellcheck disable=SC2015  # ok() and bad() never fail, so A && ok || bad is safe here
R="${1:?usage: $0 <runtime_dir> [--smoke]}"
smoke="${2:-}"
fail=0
ok()   { printf 'PASS %s\n' "$*"; }
bad()  { printf 'FAIL %s\n' "$*"; fail=1; }

[ -f "$R/manifest.json" ] && ok "manifest.json present" || bad "manifest.json missing"

# 1. Every Mach-O is x86_64 and free of build/brew paths.
n=0
while IFS= read -r f; do
  file -b "$f" | grep -q Mach-O || continue
  n=$((n+1))
  lipo "$f" -verify_arch x86_64 2>/dev/null || bad "not x86_64: $f"
  if otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -Eq '^(/usr/local/|/opt/homebrew/|/opt/local/|/Users/)'; then
    bad "absolute non-system load path in $f"
  fi
done <<EOF
$(find "$R" -type f \( -name '*.so' -o -name '*.dylib' -o -path '*/bin/*' \))
EOF
ok "checked $n Mach-O files"

# 2. Wine unixlibs must be unsigned (Wine refuses signed ones in the bridge tests).
signed="$(find "$R/lib/wine/x86_64-unix" -name '*.so' -exec sh -c 'codesign -dv "$1" >/dev/null 2>&1 && echo "$1"' _ {} \; | head -n 5)"
[ -z "$signed" ] && ok "unixlibs unsigned" || bad "signed unixlibs: $signed"

# 3. DXMT prerequisites.
nm -gU "$R/lib/wine/x86_64-unix/winemac.so" | grep -q ' _macdrv_functions$' && ok "winemac.so exports macdrv_functions" || bad "macdrv_functions not exported"
[ -f "$R/lib/wine/x86_64-unix/winemetal.so" ] && [ -f "$R/lib/wine/x86_64-windows/winemetal.dll" ] && ok "winemetal present" || bad "winemetal missing"
for b in dxmt dxvk; do
  for f in d3d11.dll dxgi.dll d3d10core.dll; do
    [ -f "$R/lib/peakpack/$b/x86_64-windows/$f" ] || bad "$b/$f missing"
  done
done
ok "backend DLL sets present"

# 4. msync, inotify, sonames.
strings "$R/lib/wine/x86_64-unix/ntdll.so" | grep -q WINEMSYNC && ok "msync compiled in" || bad "WINEMSYNC not found in ntdll.so"
otool -L "$R/bin/wineserver" | grep -q 'libinotify' && ok "wineserver links libinotify (file change notifications)" || bad "wineserver lacks inotify"
for so in libfreetype.6.dylib libgnutls.30.dylib libMoltenVK.dylib; do
  [ -e "$R/lib/$so" ] && ok "bundled $so" || bad "missing lib/$so (Wine dlopens this exact name)"
done

# 5. Manifest hashes match the files.
python3 -I - "$R" <<'PY' && ok "manifest hashes match" || bad "manifest hash mismatch"
import hashlib, json, os, sys
r = sys.argv[1]; m = json.load(open(os.path.join(r, "manifest.json")))
bad = 0
for rel, h in m["files"].items():
    p = os.path.join(r, rel)
    if not os.path.isfile(p) or hashlib.sha256(open(p, "rb").read()).hexdigest() != h:
        print("  mismatch:", rel); bad += 1
sys.exit(1 if bad else 0)
PY

if [ "$smoke" = --smoke ]; then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ppsmoke.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  ver="$("$R/bin/wine" --version 2>&1 || true)"
  case "$ver" in wine-11.*) ok "wine --version: $ver" ;; *) bad "wine --version: $ver" ;; esac
  if "$R/share/peakpack/prefix/pp-create-prefix.sh" "$R" "$tmp/prefix" > "$tmp/create.log" 2>&1; then
    ok "prefix created"
    # shellcheck disable=SC1091
    . "$R/share/peakpack/prefix/pp-env.sh"
    pp_env "$R" "$tmp/prefix"
    out="$("$R/bin/wine" cmd /c ver 2>/dev/null | tr -d '\r' || true)"
    case "$out" in *Windows*) ok "cmd /c ver: $(printf '%s' "$out" | tail -n 1)" ;; *) bad "cmd /c ver failed" ;; esac
    q="$("$R/bin/wine" reg query 'HKCU\Software\Wine\AppDefaults\PEAK.exe\DllOverrides' 2>/dev/null | tr -d '\r' || true)"
    printf '%s' "$q" | grep -q 'winhttp.*native,builtin' && ok "PEAK.exe winhttp override" || bad "PEAK.exe winhttp override missing"
    printf '%s' "$q" | grep -q 'd3d11.*native,builtin' && ok "PEAK.exe DXMT overrides" || bad "PEAK.exe d3d11 override missing"
    cmp -s "$R/lib/peakpack/dxmt/x86_64-windows/d3d11.dll" "$tmp/prefix/drive_c/windows/system32/d3d11.dll" \
      && ok "DXMT d3d11.dll in system32" || bad "system32/d3d11.dll is not DXMT's"
    "$R/bin/wineserver" -k 2>/dev/null || true
  else
    bad "prefix creation failed:"; tail -n 40 "$tmp/create.log"
  fi
fi

[ "$fail" = 0 ] && echo "verify_runtime: ALL PASS" || { echo "verify_runtime: FAILURES"; exit 1; }
