# shellcheck shell=bash
# Common helpers for the PeakPack runtime build scripts.
# Sourced by every build/*.sh. Must stay compatible with macOS /bin/bash 3.2:
# no associative arrays, no mapfile, no ${var,,}, no |&.

set -euo pipefail

PP_BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PP_RUNTIME_SRC_DIR="$(cd "$PP_BUILD_DIR/.." && pwd)"   # mac/runtime in the repo
export PP_BUILD_DIR PP_RUNTIME_SRC_DIR

# shellcheck source=../pins.env
. "$PP_BUILD_DIR/pins.env"

if [ -z "${PP_WORK:-}" ]; then
  if [ -n "${GITHUB_WORKSPACE:-}" ]; then PP_WORK="$GITHUB_WORKSPACE/_work"; else PP_WORK="$HOME/peakpack-build"; fi
fi
export PP_WORK
PP_DL="$PP_WORK/downloads"        # verified downloads (cache key: pins.env hash)
PP_SRC="$PP_WORK/src"             # extracted + patched sources
PP_BLD="$PP_WORK/build"           # build trees (configured Wine tree lives in $PP_BLD/wine)
PP_DEPS="$PP_WORK/deps/x86_64"    # x86_64 dependency prefix (freetype, gnutls, ...)
PP_STAGE="$PP_WORK/stage"         # make install / meson install destinations
PP_DIST="$PP_WORK/dist"           # final artifacts
PP_TOOLS="$PP_WORK/tools"         # toolchains (llvm-mingw, llvm15)
export PP_DL PP_SRC PP_BLD PP_DEPS PP_STAGE PP_DIST PP_TOOLS

RUNTIME_ID="pp${PP_REVISION}-cx${CX_VERSION}"
export RUNTIME_ID

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
need() { local t; for t in "$@"; do command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"; done; }

ncpu() {
  if command -v sysctl >/dev/null 2>&1 && sysctl -n hw.ncpu >/dev/null 2>&1; then sysctl -n hw.ncpu
  elif command -v nproc >/dev/null 2>&1; then nproc
  else echo 4; fi
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

is_placeholder() { case "$1" in ""|FILL*|TODO*) return 0 ;; *) return 1 ;; esac; }

# fetch_verify <url> <sha256|FILL...> <dest-file> [mirror-url]
# Downloads once into $PP_DL, verifies SHA-256. A placeholder hash is allowed only
# when PP_ALLOW_UNPINNED=1 (first-download mode): the hash is then printed so it can
# be written into pins.env, and the build is marked unpinned in the manifest.
fetch_verify() {
  local url="$1" want="$2" dest="$3" mirror="${4:-}" got
  mkdir -p "$(dirname "$dest")"
  if [ ! -s "$dest" ]; then
    log "download $url"
    if ! curl -fL --retry 3 --retry-delay 5 -o "$dest.part" "$url"; then
      [ -n "$mirror" ] || die "download failed: $url"
      log "primary failed, trying mirror $mirror"
      curl -fL --retry 3 --retry-delay 5 -o "$dest.part" "$mirror" || die "download failed: $mirror"
    fi
    mv "$dest.part" "$dest"
  fi
  got="$(sha256_of "$dest")"
  if is_placeholder "$want"; then
    [ "${PP_ALLOW_UNPINNED:-0}" = 1 ] || die "no pinned SHA-256 for $(basename "$dest") (got $got). Fill pins.env or set PP_ALLOW_UNPINNED=1 for a first-download run."
    log "UNPINNED $(basename "$dest") sha256=$got  <-- copy into pins.env"
    printf '%s %s %s\n' "$(basename "$dest")" "$got" "$url" >> "$PP_WORK/UNPINNED.txt"
    return 0
  fi
  [ "$got" = "$want" ] || { rm -f "$dest"; die "SHA-256 mismatch for $(basename "$dest"): got $got want $want"; }
  log "verified $(basename "$dest")"
}

# git_fetch_commit <repo-url> <full-commit-sha> <dest-dir> [fallback-ref]
# Pins by commit SHA (content-addressed), including submodules. The fallback ref
# (a tag) is used only in first-download mode while the SHA is still a placeholder.
git_fetch_commit() {
  local repo="$1" sha="$2" dest="$3" ref="${4:-main}" head
  is_placeholder "$sha" && [ "${PP_ALLOW_UNPINNED:-0}" != 1 ] && die "no pinned commit for $repo"
  if [ ! -d "$dest/.git" ]; then
    mkdir -p "$dest"
    git -C "$dest" init -q
    git -C "$dest" remote add origin "$repo"
  fi
  if is_placeholder "$sha"; then
    git -C "$dest" fetch -q --depth 1 origin "$ref"
  else
    git -C "$dest" fetch -q --depth 1 origin "$sha"
  fi
  git -C "$dest" checkout -q --detach FETCH_HEAD
  git -C "$dest" submodule update -q --init --recursive --depth 1
  head="$(git -C "$dest" rev-parse HEAD)"
  if is_placeholder "$sha"; then
    log "UNPINNED $repo at $head  <-- copy into pins.env"
    printf '%s %s %s\n' "$(basename "$repo")" "$head" "$repo" >> "$PP_WORK/UNPINNED.txt"
  else
    [ "$head" = "$sha" ] || die "commit mismatch for $repo: $head != $sha"
  fi
}

# Re-exec the calling script as x86_64 under Rosetta on Apple Silicon hosts.
# On an Intel runner (macos-15-intel / macos-26-intel) this is a no-op.
ensure_x86_64() {
  [ "$(uname -s)" = Darwin ] || die "this step must run on macOS"
  if [ "$(uname -m)" != x86_64 ]; then
    if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" != 1 ]; then
      /usr/bin/pgrep -q oahd || die "Rosetta 2 is not installed (softwareupdate --install-rosetta --agree-to-license)"
      log "re-exec under Rosetta: arch -x86_64 $0"
      exec /usr/bin/arch -x86_64 /bin/bash "$0" "$@"
    fi
  fi
}

# Toolchain environment for x86_64 macOS host objects.
mac_x86_64_env() {
  export MACOSX_DEPLOYMENT_TARGET="$PP_MACOS_MIN"
  export CC="${PP_CC:-clang} -arch x86_64"
  export CXX="${PP_CXX:-clang++} -arch x86_64"
  export OBJC="$CC"
  export CFLAGS="-O2 -mmacosx-version-min=$PP_MACOS_MIN"
  export CXXFLAGS="$CFLAGS"
  export LDFLAGS="-mmacosx-version-min=$PP_MACOS_MIN -Wl,-headerpad_max_install_names"
  export PKG_CONFIG_PATH="$PP_DEPS/lib/pkgconfig"
  export PKG_CONFIG_LIBDIR="$PP_DEPS/lib/pkgconfig"
  if command -v ccache >/dev/null 2>&1 && [ "${PP_CCACHE:-1}" = 1 ]; then
    export CC="ccache $CC" CXX="ccache $CXX" OBJC="ccache $OBJC"
  fi
}

# Put the PE cross toolchain on PATH.
pe_toolchain_env() {
  case "$PP_PE_TOOLCHAIN" in
    llvm-mingw) export PATH="$PP_TOOLS/llvm-mingw/bin:$PATH"; need x86_64-w64-mingw32-clang i686-w64-mingw32-clang ;;
    mingw-gcc)  need x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc ;;
    *) die "unknown PP_PE_TOOLCHAIN=$PP_PE_TOOLCHAIN" ;;
  esac
}

stamp_done() { mkdir -p "$PP_WORK/stamps"; : > "$PP_WORK/stamps/$1"; }
stamp_has()  { [ -f "$PP_WORK/stamps/$1" ]; }
