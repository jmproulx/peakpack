#!/bin/bash
# make_source_bundle.sh
# LGPL corresponding-source package for this runtime build:
#   $PP_DIST/peakpack-runtime-src-<RUNTIME_ID>.tar.xz
#     mac-runtime/              our build scripts, patches, prefix scripts, docs (as built)
#     APPLIED.txt               patches actually applied (+ hashes of injected DLL trees)
#     wine-configure-args.txt
#     dxmt-<commit>/            DXMT source at the exact commit, with submodules
#     libinotify-<ver>.tar.gz   unchanged upstream release
#     SOURCES.md                links + hashes for the CrossOver tarball (mirrored unchanged),
#                               LLVM and MoltenVK
# The CrossOver tarball itself (149 MB) is published once, unchanged, as the release
# mac-build-src-cx<ver> (CX_MIRROR_URL) instead of being repeated in every build.
# Never includes Steam team sources (Steamworks SDK licence): only tree hashes.
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
need tar xz git

B="$PP_DIST/src-stage/peakpack-runtime-src-$RUNTIME_ID"
rm -rf "$PP_DIST/src-stage" && mkdir -p "$B"

log "our scripts"
mkdir -p "$B/mac-runtime"
for d in build prefix docs ci; do
  if [ -d "$PP_RUNTIME_SRC_DIR/$d" ]; then cp -R "$PP_RUNTIME_SRC_DIR/$d" "$B/mac-runtime/$d"; fi
done
[ -f "$PP_RUNTIME_SRC_DIR/INTERFACES.md" ] && cp "$PP_RUNTIME_SRC_DIR/INTERFACES.md" "$B/mac-runtime/"
# The Steam team's folder is deliberately not copied (it may stage Steamworks-licensed files).
rm -rf "$B/mac-runtime/steam"

[ -f "$PP_SRC/APPLIED.txt" ] && cp "$PP_SRC/APPLIED.txt" "$B/"
[ -f "$PP_WORK/wine-configure-args.txt" ] && cp "$PP_WORK/wine-configure-args.txt" "$B/"

log "DXMT source"
head="$(git -C "$PP_DL/dxmt.git" rev-parse HEAD)"
mkdir -p "$B/dxmt-$head"
(cd "$PP_DL/dxmt.git" && find . -path ./.git -prune -o -type f -print | grep -v '/\.git/' | grep -v '/\.git$' | tar -cf - -T -) \
  | (cd "$B/dxmt-$head" && tar -xf -)

log "libinotify and nettle releases (unchanged upstream tarballs)"
cp "$PP_DL/$(basename "$LIBINOTIFY_URL")" "$B/"
cp "$PP_DL/$(basename "$NETTLE_URL")" "$B/"

if [ -f "$PP_DIST/$RUNTIME_ID/LICENSES/SOURCES.md" ]; then
  cp "$PP_DIST/$RUNTIME_ID/LICENSES/SOURCES.md" "$B/SOURCES.md"
else
  "$PP_BUILD_DIR/collect_licenses.sh" "$PP_DIST/src-stage/lic" && cp "$PP_DIST/src-stage/lic/SOURCES.md" "$B/SOURCES.md"
fi

out="$PP_DIST/peakpack-runtime-src-$RUNTIME_ID.tar.xz"
tar -C "$PP_DIST/src-stage" -cf - "peakpack-runtime-src-$RUNTIME_ID" | xz -T0 -9 > "$out"
printf '%s  %s\n' "$(sha256_of "$out")" "$(basename "$out")" > "$out.sha256"
rm -rf "$PP_DIST/src-stage"
log "source bundle OK: $(cat "$out.sha256")"
