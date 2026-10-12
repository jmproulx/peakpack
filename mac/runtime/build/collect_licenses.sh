#!/bin/bash
# collect_licenses.sh <dest-dir>
# Copies the licence text of every component in the runtime and writes NOTICE.md and
# SOURCES.md (LGPL source offer with exact links + hashes). See docs/LICENSES.md.
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
dest="${1:?usage: $0 <dest-dir>}"
mkdir -p "$dest"

# copy_lic <component> <file>...   first existing file wins for each listed name
copy_lic() {
  local comp="$1" f any=0; shift
  mkdir -p "$dest/$comp"
  for f in "$@"; do
    if [ -f "$f" ]; then cp "$f" "$dest/$comp/"; any=1; fi
  done
  [ "$any" = 1 ] || die "no licence file found for $comp (looked at: $*)"
}

copy_lic wine        "$PP_SRC/wine/COPYING.LIB" "$PP_SRC/wine/LICENSE" "$PP_SRC/wine/AUTHORS"
copy_lic freetype    "$PP_SRC/freetype/LICENSE.TXT" "$PP_SRC/freetype/docs/FTL.TXT"
copy_lic gnutls      "$PP_SRC/gnutls/LICENSE" "$PP_SRC/gnutls/doc/COPYING.LESSER"
# The CrossOver copy of GnuTLS has only LICENSE (a pointer to LGPL-2.1-or-later); add the
# full LGPL-2.1 text (Wine's COPYING.LIB is that text).
[ -f "$dest/gnutls/COPYING.LESSER" ] || cp "$PP_SRC/wine/COPYING.LIB" "$dest/gnutls/COPYING.LESSER"
copy_lic nettle      "$PP_SRC/nettle/COPYING.LESSERv3" "$PP_SRC/nettle/COPYINGv2" "$PP_SRC/nettle/COPYINGv3"
copy_lic gmp         "$PP_SRC/gmp/COPYING.LESSERv3" "$PP_SRC/gmp/COPYINGv2" "$PP_SRC/gmp/COPYINGv3"
copy_lic libinotify  "$PP_BLD/deps/libinotify/LICENSE" "$PP_BLD/deps/libinotify/COPYING"
copy_lic moltenvk    "$(find "$PP_BLD/deps/moltenvk" -maxdepth 3 -name LICENSE | head -n 1)"
copy_lic dxvk        "$PP_SRC/dxvk/LICENSE"
copy_lic dxmt        "$PP_DL/dxmt.git/LICENSE"
# DXMT's winemetal.so statically links LLVM 15 (Apache-2.0 WITH LLVM-exception).
tar -xJf "$PP_DL/$(basename "$LLVM15_URL")" -O "llvm-project-$LLVM15_VERSION.src/llvm/LICENSE.TXT" > "$dest/LLVM-LICENSE.TXT" \
  || die "could not extract the LLVM licence"
mkdir -p "$dest/llvm" && mv "$dest/LLVM-LICENSE.TXT" "$dest/llvm/LICENSE.TXT"
# Third-party code vendored inside DXMT (submodules), if any.
if [ -d "$PP_DL/dxmt.git" ]; then
  find "$PP_DL/dxmt.git" -mindepth 2 -maxdepth 4 \( -name 'LICENSE*' -o -name 'COPYING*' \) ! -path '*/.git/*' | while IFS= read -r f; do
    rel="${f#"$PP_DL/dxmt.git/"}"
    mkdir -p "$dest/dxmt/vendored/$(dirname "$rel")"
    cp "$f" "$dest/dxmt/vendored/$rel"
  done
fi

dxmt_head="$(git -C "$PP_DL/dxmt.git" rev-parse HEAD 2>/dev/null || echo "$DXMT_COMMIT")"
cat > "$dest/NOTICE.md" <<EOF
# PeakPack for Mac runtime $RUNTIME_ID: notices

This runtime contains the following third-party software. Each component's licence text is in the
folder of the same name. Our build scripts and patches are in the PeakPack repository under \`mac/runtime/\`.

| Component | Version | Licence | Where in the runtime |
|---|---|---|---|
| Wine (CodeWeavers CrossOver $CX_VERSION source release) | 11.0 + CrossOver changes | LGPL-2.1-or-later | bin/, lib/wine/, share/wine/ |
| DXMT | $DXMT_TAG ($dxmt_head) | $( [ "$DXMT_TAG" = v0.80 ] && echo "MIT (v0.80 is the last MIT release)" || echo "LGPL-2.1-or-later (check dxmt/LICENSE)") | lib/wine/*/winemetal.*, lib/peakpack/dxmt/ |
| LLVM (statically linked into winemetal.so) | $LLVM15_VERSION | Apache-2.0 WITH LLVM-exception | lib/wine/x86_64-unix/winemetal.so |
| DXVK (CrossOver $CX_VERSION source release) | 1.10.3 | zlib | lib/peakpack/dxvk/ |
| MoltenVK | $MOLTENVK_VERSION | Apache-2.0 | lib/libMoltenVK.dylib |
| FreeType | 2.13.3 | FreeType License (FTL) | lib/libfreetype.*.dylib |
| GnuTLS | 3.8.3 | LGPL-2.1-or-later | lib/libgnutls.*.dylib |
| Nettle (GNU release) | $NETTLE_VERSION | LGPL-3.0-or-later OR GPL-2.0-or-later | lib/libnettle.*.dylib, lib/libhogweed.*.dylib |
| GMP | 6.3.0 | LGPL-3.0-or-later OR GPL-2.0-or-later | lib/libgmp.*.dylib |
| libinotify-kqueue | $LIBINOTIFY_VERSION | MIT | lib/libinotify.*.dylib |

Portions of this software are copyright (C) The FreeType Project (www.freetype.org). All rights reserved.
MoltenVK is the Khronos release binary, modified only by thinning to x86_64 (lipo) and changing its
install name (install_name_tool).

The LGPL components are separate dynamic libraries and DLLs. You may replace them with your own
modified builds; see SOURCES.md for the exact sources and build scripts.
EOF

cat > "$dest/SOURCES.md" <<EOF
# Corresponding source for PeakPack runtime $RUNTIME_ID

Every input is pinned by SHA-256 (or git commit) in \`mac/runtime/build/pins.env\` of the PeakPack
repository (https://github.com/jmproulx/peakpack). The same release that carries this runtime also
carries \`peakpack-runtime-src-$RUNTIME_ID.tar.xz\` (our patches, build scripts, the DXMT
source at the exact commit, libinotify-kqueue and nettle).

| Source | Where | SHA-256 / commit |
|---|---|---|
| CrossOver $CX_VERSION sources (Wine, DXVK, FreeType, GnuTLS, GMP) | $CX_URL, mirrored unchanged at $CX_MIRROR_URL | $CX_SHA256 |
| DXMT | $DXMT_REPO | $dxmt_head |
| LLVM $LLVM15_VERSION | $LLVM15_URL | $LLVM15_SHA256 |
| MoltenVK $MOLTENVK_VERSION (binary release; source at the same tag) | $MOLTENVK_URL | $MOLTENVK_SHA256 |
| libinotify-kqueue $LIBINOTIFY_VERSION | $LIBINOTIFY_URL | $LIBINOTIFY_SHA256 |
| Nettle $NETTLE_VERSION (GNU release, unchanged; also in the source bundle) | $NETTLE_URL | $NETTLE_SHA256 |

Written offer (LGPL-2.1 section 6, LGPL-3.0 section 4): for at least three years after we last
distribute this runtime, anyone may get the complete corresponding source from the links above,
or by opening an issue in the PeakPack repository.
EOF
log "licences collected in $dest"
