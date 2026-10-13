#!/bin/bash
# Verify a PeakPack native-tools bundle on an Apple-silicon Mac. Ships in the bundle as check/verify_bundle.sh.
#   check/verify_bundle.sh [--ci] [BUNDLE_ROOT]      (root defaults to the folder above check/)
# Uses only tools present on every macOS install (shasum, file, codesign, xattr, find); installs nothing,
# writes only to a temporary folder, needs no network and no game data.
# --ci adds checks that need Xcode's otool (linked libraries, minimum macOS) - CI only, never on test Macs.
# Bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

ci=0
if [ "${1-}" = --ci ]; then ci=1; shift; fi
root="${1:-$(dirname "${BASH_SOURCE[0]}")/..}"
root="$(cd "$root" && pwd -P)"

fail() { echo "verify: FAIL: $*" >&2; exit 1; }
ok() { echo "verify: ok: $*"; }

[ "$(uname -s)" = Darwin ] || fail "macOS only"
[ "$(uname -m)" = arm64 ] || fail "Apple silicon only (uname -m = $(uname -m); a Rosetta shell reports x86_64)"
[ -f "$root/MANIFEST.json" ] && [ -f "$root/FILES.sha256" ] || fail "$root is not a native-tools bundle"
min="$(/usr/bin/sed -n 's/.*"macos_min": *"\([0-9.]*\)".*/\1/p' "$root/MANIFEST.json" | head -n 1)"
[ -n "$min" ] || fail "MANIFEST.json has no platform.macos_min"
cd "$root"

# Every file listed with the right hash, and nothing added or removed (.DS_Store from Finder is ignored).
check_sums() {
    local out listed actual
    if ! out="$(/usr/bin/shasum -a 256 -c FILES.sha256 2>&1)"; then
        printf '%s\n' "$out" | grep -v ': OK$' >&2 || true
        fail "files differ from FILES.sha256 (corrupt or modified bundle)"
    fi
    listed="$(wc -l < FILES.sha256 | tr -d ' ')"
    actual="$(find . -type f ! -name FILES.sha256 ! -name .DS_Store | wc -l | tr -d ' ')"
    [ "$listed" = "$actual" ] || fail "$actual files present but FILES.sha256 lists $listed (files added or removed)"
}
check_sums
ok "$(wc -l < FILES.sha256 | tr -d ' ') files match FILES.sha256"

# No game or engine data, ever.
bad="$(find . -type f \( -iname '*.unity3d' -o -iname '*.assets' -o -iname '*.resS' -o -iname '*.resource' \
    -o -iname '*.bank' -o -iname 'globalgamemanagers*' -o -iname 'sharedassets*' -o -iname 'level[0-9]*' \) | head -n 5)"
[ -z "$bad" ] || fail "game/Unity data in the bundle: $bad"
ok "no game or Unity data files"

# A browser download marks files quarantined; Gatekeeper then blocks the ad-hoc-signed binaries.
if /usr/bin/xattr -p com.apple.quarantine "$root/python/bin/python3" >/dev/null 2>&1; then
    fail "the bundle is quarantined (downloaded with a browser). After checking the .sha256, run:
    xattr -dr com.apple.quarantine \"$root\"
and re-run this check. (Downloading with curl avoids this.)"
fi

ver_le() {  # ver_le A B: A <= B for dotted versions (major.minor)
    local a1 a2 b1 b2
    IFS=. read -r a1 a2 _ <<< "$1."
    IFS=. read -r b1 b2 _ <<< "$2."
    a2="${a2:-0}"; b2="${b2:-0}"
    [ "$a1" -lt "$b1" ] || { [ "$a1" -eq "$b1" ] && [ "$a2" -le "$b2" ]; }
}

# Every Mach-O: has arm64 code and a valid signature (ad-hoc is enough on Apple silicon).
n=0
while IFS= read -r -d '' f; do
    desc="$(/usr/bin/file -b "$f")"
    case "$desc" in *Mach-O*) ;; *) continue ;; esac
    case "$desc" in *arm64*) ;; *) fail "$f has no arm64 code: $desc" ;; esac
    # arm64 slice only: universal2 wheels may leave their x86_64 slice unsigned; Apple silicon never loads it.
    /usr/bin/codesign --verify -a arm64 "$f" 2>/dev/null || fail "$f: missing or invalid arm64 code signature"
    if [ "$ci" = 1 ]; then
        for d in $(otool -arch arm64 -l "$f" | awk '$1 == "cmd" { c = $2 }
                $1 == "name" && (c == "LC_LOAD_DYLIB" || c == "LC_LOAD_WEAK_DYLIB" || c == "LC_REEXPORT_DYLIB" ||
                                 c == "LC_LOAD_UPWARD_DYLIB") { print $2 }'); do
            case "$d" in
                /usr/lib/*|/System/Library/*|@rpath/*|@loader_path/*|@executable_path/*) ;;
                *) fail "$f links $d (outside the bundle and the OS)" ;;
            esac
        done
        mv="$(otool -arch arm64 -l "$f" | awk '/LC_BUILD_VERSION/ { b = 1 } b && $1 == "minos" { print $2; exit }
                /LC_VERSION_MIN_MACOSX/ { v = 1 } v && $1 == "version" { print $2; exit }')"
        [ -n "$mv" ] || fail "$f: no minimum macOS version"
        ver_le "$mv" "$min" || fail "$f needs macOS $mv, bundle promises $min"
    fi
    n=$((n + 1))
done < <(find . -type f \( -perm -u+x -o -name '*.so' -o -name '*.dylib' \) -print0)
[ "$n" -gt 0 ] || fail "no Mach-O files found"
if [ "$ci" = 1 ]; then
    ok "$n Mach-O files: arm64, signed, OS-only links, minimum macOS <= $min"
else
    ok "$n Mach-O files: arm64, signed"
fi

# Run it in a scrubbed environment: no PATH tools, no PYTHON*/PIP* variables, a throwaway HOME and TMPDIR.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/pm-verify.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home"
clean() {
    env -i HOME="$tmp/home" TMPDIR="$tmp/" PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=en_US.UTF-8 \
        PEAKMETAL_SPIRV_CROSS="$root/native/bin/spirv-cross" "$@"
}
clean "$root/python/bin/python3" -I -B "$root/check/smoke.py" "$root" || fail "smoke test"
ok "smoke test (python, packages, spirv-cross via peakmetal)"
clean "$root/bin/pm" --help >/dev/null || fail "bin/pm --help"
ok "bin/pm --help"
echo "verify: running bin/pm doctor"
clean "$root/bin/pm" doctor || fail "bin/pm doctor"
ok "bin/pm doctor"

check_sums
ok "bundle unchanged after running (nothing written into it)"
echo "verify: PASS $root"
