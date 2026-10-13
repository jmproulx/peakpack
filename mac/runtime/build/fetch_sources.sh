#!/bin/bash
# fetch_sources.sh [--mac|--linux-dxvk|--all]
# Downloads every pinned input into $PP_WORK/downloads and verifies SHA-256 (or git commit).
#   --mac         inputs for the macOS jobs (Wine, deps, DXMT, MoltenVK, toolchains)  [default]
#   --linux-dxvk  inputs for the Linux DXVK job (CrossOver tarball only)
#   --all         everything (used by make_source_bundle.sh)
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

mode="${1:---mac}"
need curl git tar
mkdir -p "$PP_DL"

fetch_cx() {
  fetch_verify "$CX_URL" "$CX_SHA256" "$PP_DL/$CX_TARBALL" "$CX_MIRROR_URL"
}

fetch_mac() {
  fetch_cx
  fetch_verify "$LLVM_MINGW_MAC_URL" "$LLVM_MINGW_MAC_SHA256" "$PP_DL/$(basename "$LLVM_MINGW_MAC_URL")"
  fetch_verify "$LLVM_MINGW_DXMT_URL" "$LLVM_MINGW_DXMT_SHA256" "$PP_DL/$(basename "$LLVM_MINGW_DXMT_URL")"
  fetch_verify "$MOLTENVK_URL" "$MOLTENVK_SHA256" "$PP_DL/MoltenVK-macos-$MOLTENVK_VERSION.tar"
  fetch_verify "$LIBINOTIFY_URL" "$LIBINOTIFY_SHA256" "$PP_DL/$(basename "$LIBINOTIFY_URL")"
  fetch_verify "$NETTLE_URL" "$NETTLE_SHA256" "$PP_DL/$(basename "$NETTLE_URL")"
  fetch_verify "$LLVM15_URL" "$LLVM15_SHA256" "$PP_DL/$(basename "$LLVM15_URL")"
  git_fetch_commit "$DXMT_REPO" "$DXMT_COMMIT" "$PP_DL/dxmt.git" "$DXMT_TAG"
}

case "$mode" in
  --mac)        fetch_mac ;;
  --linux-dxvk) fetch_cx ;;
  --all)        fetch_mac ;;
  *) die "usage: $0 [--mac|--linux-dxvk|--all]" ;;
esac

if [ -s "$PP_WORK/UNPINNED.txt" ]; then
  log "WARNING: unpinned inputs were accepted (PP_ALLOW_UNPINNED=1):"
  cat "$PP_WORK/UNPINNED.txt" >&2
fi
log "fetch_sources $mode: OK"
