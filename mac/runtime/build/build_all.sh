#!/bin/bash
# build_all.sh [--extra-dll-dir DIR]... [--skip-dxvk]
# Local one-shot build on a Mac (Intel, or Apple silicon with Rosetta 2 + Xcode 16).
# CI runs the same steps as separate jobs (ci/workflows/mac-runtime.yml); DXVK is built on
# Linux there. Locally, --skip-dxvk expects $PP_STAGE/dxvk to exist already (copy the CI
# artifact), because DXVK needs mingw-w64 GCC.
#
# Build-tool prerequisites (Homebrew, any arch): autoconf automake libtool pkg-config bison
#   flex meson ninja cmake ccache xz gnu-tar ; plus Xcode 16.x selected with xcode-select.
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

extra=""
skip_dxvk=0
while [ $# -gt 0 ]; do
  case "$1" in
    --extra-dll-dir) [ $# -ge 2 ] || die "--extra-dll-dir needs a value"; extra="$extra --extra-dll-dir $2"; shift 2 ;;
    --skip-dxvk) skip_dxvk=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

B="$PP_BUILD_DIR"
"$B/fetch_sources.sh" --mac
# shellcheck disable=SC2086
"$B/prepare_sources.sh" $extra
"$B/build_deps.sh"
"$B/build_wine.sh" --no-prepare
"$B/build_dxmt.sh"
if [ "$skip_dxvk" = 0 ]; then
  if command -v x86_64-w64-mingw32-g++ >/dev/null 2>&1; then "$B/build_dxvk.sh"
  else die "no mingw-w64 GCC: build DXVK on Linux (CI job) and pass --skip-dxvk"; fi
fi
"$B/assemble_runtime.sh"
"$B/make_sdk.sh"
"$B/make_source_bundle.sh"
"$B/verify_runtime.sh" "$PP_DIST/$RUNTIME_ID"
log "done: $PP_DIST"
ls -l "$PP_DIST" >&2
