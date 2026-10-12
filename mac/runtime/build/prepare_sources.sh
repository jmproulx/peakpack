#!/bin/bash
# prepare_sources.sh [--extra-dll-dir DIR]... [--with-optional-patch NAME]...
# Extracts the parts of the CrossOver tarball we build, applies our patch series,
# and injects extra builtin DLL sources (e.g. the Steam team's lsteamclient).
#
# Result:
#   $PP_SRC/wine        patched Wine source (configure regenerated if needed)
#   $PP_SRC/dxvk        DXVK 1.10.3 (CodeWeavers) source
#   $PP_SRC/freetype, $PP_SRC/gmp, $PP_SRC/nettle, $PP_SRC/gnutls
#   $PP_SRC/APPLIED.txt record of patches and injected DLLs (goes into the manifest)
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

extra_dirs=""
optional=""
while [ $# -gt 0 ]; do
  case "$1" in
    --extra-dll-dir) [ $# -ge 2 ] || die "--extra-dll-dir needs a value"; extra_dirs="$extra_dirs $2"; shift 2 ;;
    --with-optional-patch) [ $# -ge 2 ] || die "--with-optional-patch needs a value"; optional="$optional $2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

need tar patch
tarball="$PP_DL/$CX_TARBALL"
[ -s "$tarball" ] || die "missing $tarball (run fetch_sources.sh)"

rm -rf "$PP_SRC.tmp" && mkdir -p "$PP_SRC.tmp"
log "extracting CrossOver sources (wine, dxvk, freetype, gnutls)"
tar -xzf "$tarball" -C "$PP_SRC.tmp" sources/wine sources/dxvk sources/freetype sources/gnutls
rm -rf "$PP_SRC" && mkdir -p "$PP_SRC"
mv "$PP_SRC.tmp/sources/wine"            "$PP_SRC/wine"
mv "$PP_SRC.tmp/sources/dxvk"            "$PP_SRC/dxvk"
mv "$PP_SRC.tmp/sources/freetype"        "$PP_SRC/freetype"
mv "$PP_SRC.tmp/sources/gnutls/gmp"      "$PP_SRC/gmp"
mv "$PP_SRC.tmp/sources/gnutls/nettle"   "$PP_SRC/nettle"
mv "$PP_SRC.tmp/sources/gnutls/gnutls"   "$PP_SRC/gnutls"
rm -rf "$PP_SRC.tmp"

grep -q '^Wine version 11\.0' "$PP_SRC/wine/VERSION" || die "unexpected Wine version: $(cat "$PP_SRC/wine/VERSION")"
[ -f "$PP_SRC/wine/dlls/ntdll/unix/msync.c" ] || die "msync not present in the Wine source"

applied="$PP_SRC/APPLIED.txt"
: > "$applied"

apply_patch() {
  local p="$1"
  log "patch $(basename "$p")"
  patch -p1 -N -d "$PP_SRC/wine" < "$p" || die "patch failed: $p"
  printf 'patch %s %s\n' "$(basename "$p")" "$(sha256_of "$p")" >> "$applied"
}

# Patch series: build/patches/wine/series lists patch files in order (comments with #).
series="$PP_BUILD_DIR/patches/wine/series"
if [ -f "$series" ]; then
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -n "$line" ] || continue
    apply_patch "$PP_BUILD_DIR/patches/wine/$line"
  done < "$series"
fi
for name in $optional; do
  apply_patch "$PP_BUILD_DIR/patches/wine/optional/$name"
done

# Inject extra builtin DLLs (INTERFACES.md §2.1 A).
regen=0
for d in $extra_dirs; do
  [ -d "$d" ] || die "--extra-dll-dir $d does not exist"
  for mod in "$d"/*/; do
    mod="${mod%/}"; name="$(basename "$mod")"
    [ -f "$mod/Makefile.in" ] || die "$mod has no Makefile.in"
    [ ! -e "$PP_SRC/wine/dlls/$name" ] || die "dlls/$name already exists in Wine"
    log "inject dlls/$name from $d"
    cp -R "$mod" "$PP_SRC/wine/dlls/$name"
    # Insert before the end marker of the auto-generated makefile list. tools/make_makefiles
    # would do this too, but it needs a git checkout and the tarball is not one.
    awk -v line="WINE_CONFIG_MAKEFILE(dlls/$name)" \
      '/^dnl End of auto-generated output commands$/ { print line } { print }' \
      "$PP_SRC/wine/configure.ac" > "$PP_SRC/wine/configure.ac.new"
    grep -qx "WINE_CONFIG_MAKEFILE(dlls/$name)" "$PP_SRC/wine/configure.ac.new" \
      || die "could not register dlls/$name in configure.ac"
    mv "$PP_SRC/wine/configure.ac.new" "$PP_SRC/wine/configure.ac"
    # Record a hash of the tree, not the sources (they may be under a non-redistributable licence).
    tree_hash="$(cd "$mod" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s  %s\n' "$(sha256_of "$f")" "$f"; done | shasum -a 256 | awk '{print $1}')"
    printf 'extra-dll %s tree-sha256 %s\n' "$name" "$tree_hash" >> "$applied"
    regen=1
  done
done

# Regenerate configure when configure.ac changed (extra DLLs, or a patch touching it).
if [ "$regen" = 1 ] || [ "$PP_SRC/wine/configure.ac" -nt "$PP_SRC/wine/configure" ]; then
  need autoreconf
  log "regenerating configure (autoreconf -f)"
  (cd "$PP_SRC/wine" && autoreconf -f)
fi

log "sources ready in $PP_SRC"
cat "$applied" >&2 || true
