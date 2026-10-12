#!/bin/bash
# fetch_lsteamclient.sh - stage Valve's lsteamclient for the PeakPack Steam bridge.
#
# Part of PeakPack for Mac (runtime/steam). Written for PeakPack; not derived
# from NotProton's GPL-3 scripts. The approach (pinned commit, content hash,
# build-time fetch) follows the decision record in docs/README.md.
#
# What it does:
#   1. Downloads ValveSoftware/Proton at the commit pinned in proton-pin.env
#      (or uses --tarball FILE), checks the tarball SHA-256.
#   2. Extracts ONLY lsteamclient/ into a fresh directory, refuses links,
#      and checks the content digest of the tree (authoritative).
#   3. Applies our patches from ../patches/*.patch in order.
#   4. Writes two views of the patched source:
#        $STEAM_WORK/src/lsteamclient/            full tree (unix side is built from here)
#        $STEAM_WORK/extra-dlls/lsteamclient/      PE-only view for Wine's build system:
#            Makefile.in without UNIXLIB and without the .cpp sources, because
#            Wine's makedep has no C++ support; build_lsteamclient.sh builds
#            the unix side (lsteamclient.so) itself with clang++.
#      Pass $STEAM_WORK/extra-dlls to runtime/build/build_wine.sh --extra-dll-dir
#      (runtime/INTERFACES.md 2.1 A), or let build_lsteamclient.sh build it.
#
# Valve's sources (Steamworks SDK licence) stay in the work dir: never commit
# them, never put them in a source tarball or release.
#
# Usage: fetch_lsteamclient.sh [--tarball FILE] [--work DIR] [--refetch] [--no-patch]
# Env:   PP_WORK (default $GITHUB_WORKSPACE/_work on CI, ~/peakpack-build otherwise)
#        STEAM_WORK (default $PP_WORK/steam), PP_STRICT_TARBALL=1 (tarball hash must match)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
steam_root=$(cd "$here/.." && pwd)
# shellcheck source=proton-pin.env
. "$here/proton-pin.env"

if [ -n "${GITHUB_WORKSPACE:-}" ]; then PP_WORK=${PP_WORK:-$GITHUB_WORKSPACE/_work}; else PP_WORK=${PP_WORK:-$HOME/peakpack-build}; fi
STEAM_WORK=${STEAM_WORK:-$PP_WORK/steam}
tarball_override=""
refetch=0
do_patch=1

while [ $# -gt 0 ]; do
    case "$1" in
        --tarball) tarball_override=$2; shift 2 ;;
        --work) STEAM_WORK=$2; shift 2 ;;
        --refetch) refetch=1; shift ;;
        --no-patch) do_patch=0; shift ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

say() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

sha256_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
    else shasum -a 256 | cut -d' ' -f1; fi
}
sha256_file() { sha256_stdin < "$1"; }

# Content digest of <root>/lsteamclient, see proton-pin.env for the formula.
tree_digest() {
    ( cd "$1" && LC_ALL=C find lsteamclient -type f | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s  %s\n' "$(sha256_file "$f")" "$f"
      done ) | sha256_stdin
}

mkdir -p "$STEAM_WORK/cache"
# The work dir must never be committed (Steamworks SDK licence).
[ -f "$STEAM_WORK/.gitignore" ] || printf '*\n' > "$STEAM_WORK/.gitignore"

# 1. tarball
if [ -n "$tarball_override" ]; then
    tarball=$tarball_override
    [ -f "$tarball" ] || die "no such tarball: $tarball"
else
    tarball=$STEAM_WORK/cache/proton-$PROTON_COMMIT.tar.gz
    [ "$refetch" = 1 ] && rm -f "$tarball"
    if [ ! -f "$tarball" ]; then
        say "downloading $PROTON_REPO $PROTON_TAG ($PROTON_COMMIT)"
        curl --fail --location --silent --show-error --retry 3 --proto '=https' --tlsv1.2 \
            -o "$tarball.part" "$PROTON_TARBALL_URL"
        mv "$tarball.part" "$tarball"
    fi
fi
got=$(sha256_file "$tarball")
if [ "$got" = "$PROTON_TARBALL_SHA256" ]; then
    say "tarball sha256 ok ($got)"
elif [ "${PP_STRICT_TARBALL:-0}" = 1 ]; then
    die "tarball sha256 mismatch: got $got, want $PROTON_TARBALL_SHA256"
else
    echo "WARNING: tarball sha256 differs (got $got, want $PROTON_TARBALL_SHA256)." >&2
    echo "         GitHub may have regenerated the archive; the tree digest below decides." >&2
fi

# 2. extract lsteamclient/ only, into a fresh directory
ext=$STEAM_WORK/extract.part
rm -rf "$ext"; mkdir -p "$ext"
prefix="Proton-$PROTON_COMMIT"
say "extracting $prefix/lsteamclient"
tar -xzf "$tarball" -C "$ext" "$prefix/lsteamclient"
[ -d "$ext/$prefix/lsteamclient" ] || die "lsteamclient/ not found in tarball"
if [ -n "$(find "$ext" -type l -print -quit)" ]; then die "tarball contains links; refusing"; fi
count=$(find "$ext/$prefix/lsteamclient" -type f | wc -l | tr -d ' ')
[ "$count" = "$LSTEAMCLIENT_FILE_COUNT" ] || die "file count $count, want $LSTEAMCLIENT_FILE_COUNT"
say "computing tree digest of $count files"
digest=$(tree_digest "$ext/$prefix")
[ "$digest" = "$LSTEAMCLIENT_TREE_SHA256" ] || die "lsteamclient tree digest mismatch: got $digest, want $LSTEAMCLIENT_TREE_SHA256"
say "tree digest ok ($digest)"

# 3. our patches
src_part=$STEAM_WORK/src.part
rm -rf "$src_part"; mkdir -p "$src_part"
mv "$ext/$prefix/lsteamclient" "$src_part/lsteamclient"
rm -rf "$ext"
patch_list=""
if [ "$do_patch" = 1 ]; then
    for p in "$steam_root"/patches/*.patch; do
        [ -f "$p" ] || continue
        say "applying $(basename "$p")"
        ( cd "$src_part" && patch -p1 --forward --batch --dry-run < "$p" >/dev/null ) \
            || die "patch does not apply cleanly: $p"
        ( cd "$src_part" && patch -p1 --forward --batch -s < "$p" ) || die "patch failed: $p"
        patch_list="$patch_list $(basename "$p"):$(sha256_file "$p")"
    done
    find "$src_part" \( -name '*.orig' -o -name '*.rej' \) -delete
fi

cat > "$src_part/lsteamclient/PEAKPACK-STAMP" <<EOF
proton_repo=$PROTON_REPO
proton_tag=$PROTON_TAG
proton_commit=$PROTON_COMMIT
tarball_sha256=$got
tree_sha256=$digest
patches=${patch_list# }
EOF

# 4a. full tree
mkdir -p "$STEAM_WORK/src"
rm -rf "$STEAM_WORK/src/lsteamclient"
mv "$src_part/lsteamclient" "$STEAM_WORK/src/lsteamclient"
rm -rf "$src_part"

# 4b. PE-only view for Wine's makedep (C sources, headers, spec; no .cpp, no UNIXLIB)
pe=$STEAM_WORK/extra-dlls/lsteamclient
rm -rf "$pe"; mkdir -p "$pe"
( cd "$STEAM_WORK/src/lsteamclient" && find . -type f ! -name '*.cpp' ! -name 'Makefile.in' -print ) |
while IFS= read -r f; do
    mkdir -p "$pe/$(dirname "$f")"
    cp -p "$STEAM_WORK/src/lsteamclient/$f" "$pe/$f"
done
awk '
    /^UNIXLIB[ \t]*=/ { next }               # unix side is built by build_lsteamclient.sh
    $1 ~ /[.]cpp$/ { next }                  # makedep cannot compile C++
    { print }
' "$STEAM_WORK/src/lsteamclient/Makefile.in" | sed '$ s/[[:space:]]*\\$//' > "$pe/Makefile.in"
grep -q '^MODULE[ \t]*=[ \t]*lsteamclient.dll' "$pe/Makefile.in" || die "unexpected Makefile.in"
if grep -q '\.cpp' "$pe/Makefile.in"; then die "C++ sources left in PE Makefile.in"; fi

say "staged:"
say "  full source : $STEAM_WORK/src/lsteamclient"
say "  PE-only view: $STEAM_WORK/extra-dlls   (build_wine.sh --extra-dll-dir)"
