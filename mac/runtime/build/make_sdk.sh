#!/bin/bash
# make_sdk.sh
# Packs the configured Wine tree as the SDK the Steam team builds lsteamclient against
# (INTERFACES.md §2.1 B): $PP_DIST/peakpack-wine-sdk-<RUNTIME_ID>.tar.xz
# The archive mirrors $PP_WORK and must be unpacked INTO the same PP_WORK path
# (on GitHub-hosted runners of this repo: $GITHUB_WORKSPACE/_work), because
# config.status records absolute paths (deps prefix):
#   src/wine        patched source (as configured)
#   build/wine      configured tree: Makefile, config.status, include/, tools/ binaries,
#                   every lib*.a import library; objects and built modules removed
#   deps/x86_64     headers + dylibs Wine was configured against
#   SDK-README.md, pins.env, manifest.json
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
need tar xz find
[ -f "$PP_BLD/wine/Makefile" ] || die "no configured Wine tree in $PP_BLD/wine"

S="$PP_DIST/sdk-stage"
rm -rf "$S" && mkdir -p "$S/src" "$S/build" "$S/deps"

log "copying source"
cp -R "$PP_SRC/wine" "$S/src/wine"

log "copying pruned build tree"
# Keep: everything except object files, built PE/unix modules, and test binaries.
(cd "$PP_BLD" && find wine -type f \
    ! -name '*.o' ! -name '*.so' ! -name '*.dll' ! -name '*.exe' ! -name '*.drv' ! -name '*.sys' \
    ! -name '*.ocx' ! -name '*.acm' ! -name '*.cpl' ! -name '*.tlb' ! -name '*.res' ! -name '*.fake' \
    ! -path 'wine/loader/wine' ! -path 'wine/server/wineserver' \
    | tar -cf - -T -) | (cd "$S/build" && tar -xf -)
# Symlinks (wineg++ -> winegcc, etc.)
(cd "$PP_BLD" && find wine -type l | tar -cf - -T -) | (cd "$S/build" && tar -xf -)

# Never publish the Steam team's injected sources (Valve's lsteamclient, Steamworks SDK licence):
# with --extra-dll-dir (INTERFACES.md 2.1 A) they sit in src/wine/dlls/lsteamclient and the build tree.
# Out-of-tree (Mode B) builds re-inject them from fetch_lsteamclient.sh.
for d in src/wine/dlls/lsteamclient build/wine/dlls/lsteamclient; do
  if [ -e "$S/$d" ]; then log "excluding $d (Steamworks-licensed, fetched at build time)"; rm -rf "${S:?}/$d"; fi
done
if [ -n "$(find "$S" -ipath '*lsteamclient*' -print -quit)" ]; then
  die "SDK still contains lsteamclient files; refusing to pack"
fi

for t in tools/winegcc/winegcc tools/winebuild/winebuild tools/widl/widl tools/wrc/wrc tools/wmc/wmc tools/makedep; do
  [ -x "$S/build/wine/$t" ] || die "SDK is missing $t"
done
n_implib="$(find "$S/build/wine/dlls" -name 'lib*.a' | wc -l | tr -d ' ')"
[ "$n_implib" -gt 100 ] || die "SDK has only $n_implib import libraries; expected hundreds"

log "copying deps prefix"
cp -R "$PP_DEPS" "$S/deps/x86_64"

cp "$PP_BUILD_DIR/pins.env" "$S/pins.env"
[ -f "$PP_DIST/$RUNTIME_ID/manifest.json" ] && cp "$PP_DIST/$RUNTIME_ID/manifest.json" "$S/manifest.json"
cat > "$S/SDK-README.md" <<EOF
# PeakPack Wine SDK for runtime $RUNTIME_ID

Configured CrossOver $CX_VERSION Wine tree (x86_64 macOS host, PE archs i386 + x86_64).
Build modules against it only for runtime $RUNTIME_ID. See mac/runtime/INTERFACES.md section 2.1.
Unpack into the same PP_WORK the runtime was built in (tar -C "\$PP_WORK" -xJf <sdk>);
the CI value is \$GITHUB_WORKSPACE/_work. Put llvm-mingw $LLVM_MINGW_VERSION first in PATH.
Tools are x86_64 macOS binaries: run them on an Intel runner or under Rosetta (arch -x86_64).
EOF

out="$PP_DIST/peakpack-wine-sdk-$RUNTIME_ID.tar.xz"
set -- src build deps SDK-README.md pins.env
[ -f "$S/manifest.json" ] && set -- "$@" manifest.json
tar -C "$S" -cf - "$@" | xz -T0 -9 > "$out"
printf '%s  %s\n' "$(sha256_of "$out")" "$(basename "$out")" > "$out.sha256"
rm -rf "$S"
log "SDK OK: $(cat "$out.sha256")"
