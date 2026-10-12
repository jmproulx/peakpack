#!/bin/bash
# build_dxvk.sh
# Builds the DXVK fallback (D3D11 -> Vulkan, run on MoltenVK) from the CrossOver tarball's
# sources/dxvk (DXVK 1.10.3 with CodeWeavers' macOS changes). PE-only, so it runs on the
# Linux job with mingw-w64 GCC, the same toolchain CodeWeavers' own cxlab CI uses.
# 64-bit only (PEAK is 64-bit). Output: $PP_STAGE/dxvk/x86_64-windows/{d3d11,dxgi,d3d10core}.dll
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
need meson ninja glslangValidator x86_64-w64-mingw32-gcc x86_64-w64-mingw32-g++ tar

if [ ! -d "$PP_SRC/dxvk" ]; then
  [ -s "$PP_DL/$CX_TARBALL" ] || die "missing $PP_DL/$CX_TARBALL (run fetch_sources.sh --linux-dxvk)"
  mkdir -p "$PP_SRC.dxvk.tmp"
  tar -xzf "$PP_DL/$CX_TARBALL" -C "$PP_SRC.dxvk.tmp" sources/dxvk
  mkdir -p "$PP_SRC" && rm -rf "$PP_SRC/dxvk" && mv "$PP_SRC.dxvk.tmp/sources/dxvk" "$PP_SRC/dxvk"
  rm -rf "$PP_SRC.dxvk.tmp"
fi
grep -q "version : 'v1.10.3'" "$PP_SRC/dxvk/meson.build" || die "unexpected DXVK version in CrossOver sources"

# mingw-w64 must use the posix thread model for DXVK (std::thread).
x86_64-w64-mingw32-g++ -v 2>&1 | grep -q 'Thread model: posix' \
  || die "x86_64-w64-mingw32-g++ must be the posix-threads variant (update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix)"

out="$PP_STAGE/dxvk-install"
rm -rf "$PP_BLD/dxvk64" "$out"
# DXVK 1.10.3 (2022) relies on <cstdint> arriving transitively through libstdc++ headers; GCC 13+
# no longer does that (CI run 38301709070: util_matrix.cpp "'uint32_t' was not declared"), and
# ~250 sources use fixed-width types without including it. Force-include it for all C++ instead
# of patching CodeWeavers' sources. The CI job also pins an ubuntu:22.04 (GCC 10) container.
mkdir -p "$PP_BLD"
extra_cross="$PP_BLD/dxvk-extra-cross.txt"
cat > "$extra_cross" <<'EOF'
[built-in options]
cpp_args = ['-include', 'cstdint']
EOF
(cd "$PP_SRC/dxvk" && meson setup "$PP_BLD/dxvk64"    --cross-file build-win64.txt --cross-file "$extra_cross" --buildtype release --strip --prefix "$out"    --bindir x86_64-windows --libdir x86_64-windows    -Denable_tests=false -Denable_d3d9=false -Denable_d3d10=true -Denable_d3d11=true -Denable_dxgi=true)
ninja -C "$PP_BLD/dxvk64" install

stage="$PP_STAGE/dxvk"
rm -rf "$stage" && mkdir -p "$stage/x86_64-windows"
for f in d3d11.dll dxgi.dll d3d10core.dll; do
  p="$(find "$out" -name "$f" | head -n 1)"
  [ -n "$p" ] || die "DXVK did not produce $f"
  cp "$p" "$stage/x86_64-windows/$f"
done
# Optional extras DXVK may produce (d3d10.dll, d3d10_1.dll, d3d9.dll): copy if present.
for f in d3d10.dll d3d10_1.dll; do
  p="$(find "$out" -name "$f" | head -n 1)"; [ -z "$p" ] || cp "$p" "$stage/x86_64-windows/$f"
done
{
  echo "dxvk $(sed -n "s/.*version : '\(v[0-9.]*\)'.*/\1/p" "$PP_SRC/dxvk/meson.build" | head -n 1) (CrossOver $CX_VERSION sources)"
  echo "mingw $(x86_64-w64-mingw32-gcc -dumpversion)"
  echo "meson $(meson --version)"
  echo "glslang $(glslangValidator --version 2>/dev/null | head -n 1)"
} > "$stage/DXVK-VERSION.txt"
cat "$stage/DXVK-VERSION.txt" >&2
log "DXVK OK"
