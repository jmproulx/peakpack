#!/bin/bash
# assemble_runtime.sh
# Builds the runtime tree (INTERFACES.md §3) from the staged parts, makes it relocatable,
# adds licences + source offer, writes manifest.json, and packs:
#   $PP_DIST/peakpack-runtime-<RUNTIME_ID>-x86_64.tar.xz (+ .sha256)
# Inputs: $PP_STAGE/wine-dev (build_wine.sh), $PP_DEPS (build_deps.sh),
#         $PP_STAGE/dxmt (build_dxmt.sh), $PP_STAGE/dxvk (build_dxvk.sh, Linux job artifact).
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/macho.sh
. "$PP_BUILD_DIR/lib/macho.sh"
need otool install_name_tool codesign lipo file python3 tar xz

W="$PP_STAGE/wine-dev"
[ -x "$W/bin/wine" ] || die "missing $W (build_wine.sh)"
[ -f "$PP_STAGE/dxmt/x86_64-windows/d3d11.dll" ] || die "missing DXMT stage (build_dxmt.sh)"
[ -f "$PP_STAGE/dxvk/x86_64-windows/d3d11.dll" ] || die "missing DXVK stage (build_dxvk.sh artifact)"

R="$PP_DIST/$RUNTIME_ID"
rm -rf "$R" && mkdir -p "$R/bin" "$R/lib" "$R/share" "$R/LICENSES"

log "Wine runtime files"
# Runtime binaries only; dev tools (winegcc, winebuild, widl, wrc, wmc, winedump, winemaker,
# function_grep.pl, winecpp, wineg++) stay in the SDK.
for b in wine wineserver msidb msiexec notepad regedit regsvr32 wineboot winecfg wineconsole \
         winedbg winefile winemine winepath; do
  if [ -e "$W/bin/$b" ]; then cp -P "$W/bin/$b" "$R/bin/$b"; fi
done
[ -x "$R/bin/wine" ] && [ -x "$R/bin/wineserver" ] || die "wine/wineserver missing from install"
mkdir -p "$R/lib/wine"
for d in x86_64-unix x86_64-windows i386-windows; do
  [ -d "$W/lib/wine/$d" ] || die "missing lib/wine/$d"
  mkdir -p "$R/lib/wine/$d"
  # Import libraries (*.a) and .def files are SDK-only.
  (cd "$W/lib/wine/$d" && find . -type f ! -name '*.a' ! -name '*.def' | tar -cf - -T -) | (cd "$R/lib/wine/$d" && tar -xf -)
done
cp -R "$W/share/wine" "$R/share/wine"

log "bundled dylibs"
for f in "$PP_DEPS"/lib/*.dylib; do cp -P "$f" "$R/lib/"; done

log "DXMT + DXVK"
cp "$PP_STAGE/dxmt/x86_64-unix/winemetal.so"     "$R/lib/wine/x86_64-unix/winemetal.so"
cp "$PP_STAGE/dxmt/x86_64-windows/winemetal.dll" "$R/lib/wine/x86_64-windows/winemetal.dll"
mkdir -p "$R/lib/peakpack/dxmt/x86_64-windows" "$R/lib/peakpack/dxvk/x86_64-windows"
for f in d3d11.dll dxgi.dll d3d10core.dll; do
  cp "$PP_STAGE/dxmt/x86_64-windows/$f" "$R/lib/peakpack/dxmt/x86_64-windows/$f"
done
cp "$PP_STAGE"/dxvk/x86_64-windows/*.dll "$R/lib/peakpack/dxvk/x86_64-windows/"

# Steam bridge (optional; built in the same job against this exact Wine tree, INTERFACES.md 2.1 A).
# $PP_STAGE/steam is the unpacked peakpack-steam-bridge-* package (binaries + licence texts only).
if [ -d "$PP_STAGE/steam" ]; then
  log "Steam bridge"
  S="$PP_STAGE/steam"
  [ -f "$S/lib/wine/x86_64-unix/lsteamclient.so" ] && [ -f "$S/lib/wine/x86_64-windows/lsteamclient.dll" ] \
    || die "incomplete Steam bridge stage in $S"
  cp "$S/lib/wine/x86_64-unix/lsteamclient.so"     "$R/lib/wine/x86_64-unix/lsteamclient.so"
  cp "$S/lib/wine/x86_64-windows/lsteamclient.dll" "$R/lib/wine/x86_64-windows/lsteamclient.dll"
  rm -f "$R/lib/wine/i386-windows/lsteamclient.dll"   # PEAK is 64-bit only; in-tree build also makes an i386 PE
  mkdir -p "$R/share/peakpack/steam"
  cp "$S"/share/peakpack/steam/* "$R/share/peakpack/steam/"
  if find "$R" \( -name '*.cpp' -o -name '*.h' \) -ipath '*steam*' -print -quit | grep -q .; then
    die "source files from the Steam bridge in the runtime"
  fi
fi

log "prefix scripts"
mkdir -p "$R/share/peakpack"
cp -R "$PP_RUNTIME_SRC_DIR/prefix" "$R/share/peakpack/prefix"
chmod +x "$R"/share/peakpack/prefix/*.sh

log "relocating Mach-O files"
find "$R" -type f | while IFS= read -r f; do
  is_macho "$f" || continue
  lipo "$f" -verify_arch x86_64 || die "$f has no x86_64 slice"
  fix_macho "$f" "$R" "$PP_WORK"
done
assert_no_build_paths "$R" "$PP_WORK" || die "build-machine paths left in the runtime"

log "licences and source offer"
"$PP_BUILD_DIR/collect_licenses.sh" "$R/LICENSES"
if [ -d "$PP_STAGE/steam/LICENSES" ]; then cp "$PP_STAGE"/steam/LICENSES/* "$R/LICENSES/"; fi

log "manifest"
python3 -I "$PP_BUILD_DIR/manifest.py" --runtime "$R" --work "$PP_WORK" --pins "$PP_BUILD_DIR/pins.env" \
  --runtime-id "$RUNTIME_ID" > "$R/manifest.json"

mkdir -p "$PP_DIST"
tarball="$PP_DIST/peakpack-runtime-$RUNTIME_ID-x86_64.tar.xz"
log "packing $tarball"
if command -v gtar >/dev/null 2>&1; then
  gtar -C "$PP_DIST" --sort=name --owner=0 --group=0 --numeric-owner \
       --mtime="@${SOURCE_DATE_EPOCH:-0}" -cf - "$RUNTIME_ID" | xz -T0 -9 > "$tarball"
else
  tar -C "$PP_DIST" -cf - "$RUNTIME_ID" | xz -T0 -9 > "$tarball"
fi
(cd "$PP_DIST" && printf '%s  %s\n' "$(sha256_of "$tarball")" "$(basename "$tarball")" > "$tarball.sha256")
cp "$R/manifest.json" "$PP_DIST/manifest-$RUNTIME_ID.json"
log "runtime OK: $(cat "$tarball.sha256")"
