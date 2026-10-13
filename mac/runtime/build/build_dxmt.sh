#!/bin/bash
# build_dxmt.sh
# Builds DXMT (D3D11 -> Metal) at the pinned commit against OUR Wine (wine-dev install
# from build_wine.sh), following DXMT's own CI recipe (docs/DECISIONS.md D3):
#   - LLVM exactly 15.0.7, built for x86_64-darwin with no targets (airconv backend)
#   - llvm-mingw for the PE side, DXMT's build-win64.txt cross file
#   - wine_builtin_dll=false: d3d11/dxgi/d3d10core are native-style DLLs that the prefix
#     script copies into system32 and enables per app (PEAK.exe) with n,b overrides;
#     winemetal.dll is always a Wine builtin (winebuild --builtin) with winemetal.so.
# Output: $PP_STAGE/dxmt/{x86_64-windows,x86_64-unix}/ + DXMT-VERSION.txt
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
ensure_x86_64 "$@"
need cmake ninja meson tar lipo xcrun

[ -x "$PP_STAGE/wine-dev/bin/winebuild" ] || die "run build_wine.sh first (needs \$PP_STAGE/wine-dev)"
xcrun -sdk macosx metal --version >/dev/null 2>&1 || die "Metal toolchain missing (Xcode 16.x, or 'xcodebuild -downloadComponent MetalToolchain' on Xcode 26)"

# ---- LLVM 15 (cached by CI on LLVM15_SHA256 + this script's hash) ----------------------
llvm="$PP_TOOLS/llvm15-darwin-x86_64"
if [ ! -x "$llvm/bin/llvm-config" ]; then
  log "building LLVM $LLVM15_VERSION for x86_64-darwin (no targets)"
  rm -rf "$PP_BLD/llvm15-src" "$PP_BLD/llvm15" && mkdir -p "$PP_BLD/llvm15-src"
  tar -xJf "$PP_DL/$(basename "$LLVM15_URL")" -C "$PP_BLD/llvm15-src" --strip-components=1
  # DXMT's CI passes an extra libc++ define for LLVM 15 vs newer Xcode libc++ (transitive
  # includes). We could not read its exact spelling reliably from here, so it is empty by
  # default: if the LLVM build fails on missing std headers, copy the CMAKE_CXX_FLAGS value
  # from DXMT's .github/workflows/ci.yml at $DXMT_COMMIT into PP_LLVM15_CXXFLAGS.
  cmake -B "$PP_BLD/llvm15" -S "$PP_BLD/llvm15-src/llvm" -G Ninja \
    -DCMAKE_INSTALL_PREFIX="$llvm" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=x86_64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$PP_MACOS_MIN" \
    -DLLVM_HOST_TRIPLE=x86_64-apple-darwin \
    -DLLVM_ENABLE_ASSERTIONS=On \
    -DLLVM_ENABLE_ZSTD=Off -DLLVM_ENABLE_ZLIB=Off -DLLVM_ENABLE_LIBXML2=Off -DLLVM_ENABLE_TERMINFO=Off \
    -DLLVM_TARGETS_TO_BUILD="" \
    -DLLVM_BUILD_TOOLS=Off -DLLVM_INCLUDE_TOOLS=On \
    -DLLVM_INCLUDE_BENCHMARKS=Off -DLLVM_INCLUDE_TESTS=Off -DLLVM_INCLUDE_EXAMPLES=Off -DLLVM_INCLUDE_DOCS=Off \
    -DCMAKE_CXX_FLAGS="${PP_LLVM15_CXXFLAGS:-}"
  cmake --build "$PP_BLD/llvm15"
  cmake --install "$PP_BLD/llvm15"
  rm -rf "$PP_BLD/llvm15-src" "$PP_BLD/llvm15"
fi

# ---- llvm-mingw for DXMT: the version DXMT's own CI uses (pins.env LLVM_MINGW_DXMT_*) ----------
lm="$PP_TOOLS/llvm-mingw-dxmt"
if [ ! -x "$lm/bin/x86_64-w64-mingw32-clang" ]; then
  rm -rf "$lm" && mkdir -p "$lm"
  tar -xJf "$PP_DL/$(basename "$LLVM_MINGW_DXMT_URL")" -C "$lm" --strip-components=1
fi
# llvm-mingw ships x86_64-w64-mingw32-gcc/g++ wrappers that point at clang, which is what
# DXMT's build-win64.txt names; putting it first in PATH selects clang, like DXMT's CI.
export PATH="$lm/bin:$PATH"
log "llvm-mingw for DXMT: $LLVM_MINGW_DXMT_VERSION"
grep -qi clang <<<"$(x86_64-w64-mingw32-gcc --version)" || die "x86_64-w64-mingw32-gcc is not llvm-mingw clang"

# ---- DXMT -----------------------------------------------------------------------------
src="$PP_BLD/dxmt-src"
rm -rf "$src" && cp -R "$PP_DL/dxmt.git" "$src"
dxmt_head="$(git -C "$src" rev-parse HEAD)"
out="$PP_STAGE/dxmt-install"
rm -rf "$PP_BLD/dxmt" "$out"
(
  cd "$src" || exit 1
  # The x86_64 unix side (winemetal.so) is built natively for macOS by meson's build
  # machine compiler: force x86_64 even when the outer shell is translated.
  # Absolute host compilers: llvm-mingw is first in PATH here and has its own (Windows-targeting) clang.
  export CC="$PP_HOST_CC -arch x86_64" CXX="$PP_HOST_CXX -arch x86_64" OBJC="$PP_HOST_CC -arch x86_64" OBJCXX="$PP_HOST_CXX -arch x86_64"
  export MACOSX_DEPLOYMENT_TARGET="$PP_MACOS_MIN"
  meson setup "$PP_BLD/dxmt" \
    --cross-file build-win64.txt \
    --buildtype release --strip --prefix "$out" \
    -Dnative_llvm_path="$llvm" \
    -Dwine_install_path="$PP_STAGE/wine-dev" \
    -Dwine_builtin_dll=false \
    -Denable_nvapi=false -Denable_nvngx=false
  meson compile -C "$PP_BLD/dxmt"
  meson install -C "$PP_BLD/dxmt"
)

# ---- Collect into a fixed layout --------------------------------------------------------
stage="$PP_STAGE/dxmt"
rm -rf "$stage" && mkdir -p "$stage/x86_64-windows" "$stage/x86_64-unix"
for f in d3d11.dll dxgi.dll d3d10core.dll winemetal.dll; do
  p="$(find "$out" -name "$f" -path '*x86_64*' | head -n 1)"
  [ -n "$p" ] || p="$(find "$out" -name "$f" | head -n 1)"
  [ -n "$p" ] || die "DXMT did not produce $f"
  cp "$p" "$stage/x86_64-windows/$f"
done
so="$(find "$out" -name winemetal.so | head -n 1)"
[ -n "$so" ] || die "DXMT did not produce winemetal.so"
cp "$so" "$stage/x86_64-unix/winemetal.so"
lipo "$stage/x86_64-unix/winemetal.so" -verify_arch x86_64 || die "winemetal.so is not x86_64"
# winemetal.dll must carry Wine's builtin marker; d3d11.dll must NOT (native-style).
grep -q 'Wine builtin DLL' "$stage/x86_64-windows/winemetal.dll" || die "winemetal.dll lacks the Wine builtin marker"
if grep -q 'Wine builtin DLL' "$stage/x86_64-windows/d3d11.dll"; then die "d3d11.dll is builtin-marked; expected wine_builtin_dll=false"; fi

{
  echo "dxmt_tag $DXMT_TAG"
  echo "dxmt_commit $dxmt_head"
  echo "dxmt_submodules $(git -C "$src" submodule status --recursive | awk '{print $2"@"$1}' | tr '\n' ' ')"
  echo "llvm $LLVM15_VERSION"
  echo "llvm_mingw $LLVM_MINGW_VERSION"
  echo "meson $(meson --version)"
  echo "xcode $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
} > "$stage/DXMT-VERSION.txt"
cat "$stage/DXMT-VERSION.txt" >&2
log "DXMT OK"
