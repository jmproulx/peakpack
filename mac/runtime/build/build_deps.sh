#!/bin/bash
# build_deps.sh
# Builds the x86_64 macOS libraries Wine dlopens or links, into $PP_DEPS:
#   gmp 6.3.0, nettle 3.10, gnutls 3.8.3, freetype 2.13.3   (all from the CrossOver tarball)
#   libinotify-kqueue                                      (pinned release; inotify -> ReadDirectoryChangesW)
#   MoltenVK                                               (pinned Khronos release, thinned to x86_64)
# Every library gets an @rpath install name so the runtime is relocatable (bundle_dylibs.sh).
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
ensure_x86_64 "$@"
mac_x86_64_env
need make meson ninja autoconf autoreconf pkg-config lipo install_name_tool tar

J="$(ncpu)"
mkdir -p "$PP_DEPS" "$PP_BLD/deps"
host=x86_64-apple-darwin
common_cfg=(--prefix="$PP_DEPS" --host="$host" --enable-shared --disable-static)
# Autoconf 2.72 makes AC_PROG_CC pick -std=gnu23, under which old-style declarations in
# bundled gnulib/getopt code fail (CI run 38304185476: nettle getopt.c "conflicting types for
# 'getopt'/'getenv'"). Presetting the cache variable keeps clang's default (gnu17) for every
# autoconf-based dependency, whichever autoconf generated its configure.
export ac_cv_prog_cc_c23=no
export CPPFLAGS="-I$PP_DEPS/include"
export LDFLAGS="$LDFLAGS -L$PP_DEPS/lib"

# gnutls: --disable-gost, because gnutls 3.8.3 bundles GOST/Streebog code that collides with nettle
# 3.10's own streebog.h (CI run 38308287374; GOST is irrelevant to Wine's schannel and PEAK).
# Release tarballs ship generated autotools files; never regenerate them (CI run 38305928217:
# gnutls' make wanted aclocal-1.16, which the runner doesn't have). Sources are also copied with
# cp -Rp so timestamps don't make them look stale.
no_autoregen=(ACLOCAL=true AUTOCONF=true AUTOMAKE=true AUTOHEADER=true MAKEINFO=true)

# Fix the install name of a freshly installed dylib to @rpath/<leaf>.
rpathify() { local f; for f in "$@"; do install_name_tool -id "@rpath/$(basename "$f")" "$f"; done; }

if ! stamp_has deps-gmp; then
  log "gmp"
  rm -rf "$PP_BLD/deps/gmp" && cp -Rp "$PP_SRC/gmp" "$PP_BLD/deps/gmp"
  # --enable-fat: runtime CPU dispatch (safe under Rosetta, which hides AVX by default).
  (cd "$PP_BLD/deps/gmp" && ./configure "${common_cfg[@]}" --enable-fat && make -j"$J" && make install)
  stamp_done deps-gmp
fi

if ! stamp_has deps-nettle; then
  log "nettle"
  rm -rf "$PP_BLD/deps/nettle" && cp -Rp "$PP_SRC/nettle" "$PP_BLD/deps/nettle"
  (cd "$PP_BLD/deps/nettle" && { [ -x configure ] || ./.bootstrap; } \
     && ./configure "${common_cfg[@]}" --enable-fat --disable-documentation --disable-openssl \
     && make -j"$J" && make install)
  stamp_done deps-nettle
fi

if ! stamp_has deps-gnutls; then
  log "gnutls"
  rm -rf "$PP_BLD/deps/gnutls" && cp -Rp "$PP_SRC/gnutls" "$PP_BLD/deps/gnutls"
  # CrossOver's gnutls hooks.m4 only CHECKS for -lnettle/-lhogweed when NETTLE_LIBS/HOGWEED_LIBS are
  # empty and never adds them (CI run 38310697150: libgnutls failed to link, every nettle_* undefined),
  # so pass all three libraries explicitly. Each value must be ONE word: hooks.m4 tests them unquoted
  # (run 38312311180: "-L... -lnettle" broke `test`, so lib/nettle was never built). -L comes from LDFLAGS.
  (cd "$PP_BLD/deps/gnutls" && ./configure "${common_cfg[@]}" \
      NETTLE_CFLAGS="-I$PP_DEPS/include" NETTLE_LIBS="-lnettle" \
      HOGWEED_CFLAGS="-I$PP_DEPS/include" HOGWEED_LIBS="-lhogweed" \
      GMP_CFLAGS="-I$PP_DEPS/include" GMP_LIBS="-lgmp" \
      --with-included-libtasn1 --with-included-unistring --without-p11-kit --without-idn \
      --without-brotli --without-zstd --without-tpm --without-tpm2 --disable-doc --disable-manpages \
      --disable-tests --disable-tools --disable-cxx --disable-nls --disable-libdane \
      --disable-full-test-suite --disable-gost \
     && make -j"$J" "${no_autoregen[@]}" && make install "${no_autoregen[@]}")
  stamp_done deps-gnutls
fi

if ! stamp_has deps-freetype; then
  log "freetype"
  rm -rf "$PP_BLD/deps/freetype"
  meson setup "$PP_BLD/deps/freetype" "$PP_SRC/freetype" --prefix="$PP_DEPS" --libdir=lib \
    --buildtype=release --default-library=shared --wrap-mode=nodownload \
    -Dharfbuzz=disabled -Dpng=disabled -Dbrotli=disabled -Dbzip2=disabled -Dzlib=system -Dtests=disabled
  ninja -C "$PP_BLD/deps/freetype" install
  stamp_done deps-freetype
fi

if ! stamp_has deps-inotify; then
  log "libinotify-kqueue $LIBINOTIFY_VERSION"
  rm -rf "$PP_BLD/deps/libinotify" && mkdir -p "$PP_BLD/deps/libinotify"
  tar -xzf "$PP_DL/$(basename "$LIBINOTIFY_URL")" -C "$PP_BLD/deps/libinotify" --strip-components=1
  (cd "$PP_BLD/deps/libinotify" && { [ -x configure ] || autoreconf -fvi; } \
     && ./configure "${common_cfg[@]}" && make -j"$J" "${no_autoregen[@]}" && make install "${no_autoregen[@]}")
  stamp_done deps-inotify
fi

if ! stamp_has deps-moltenvk; then
  log "MoltenVK $MOLTENVK_VERSION (thin to x86_64)"
  rm -rf "$PP_BLD/deps/moltenvk" && mkdir -p "$PP_BLD/deps/moltenvk"
  tar -xf "$PP_DL/MoltenVK-macos-$MOLTENVK_VERSION.tar" -C "$PP_BLD/deps/moltenvk"
  mvk="$(find "$PP_BLD/deps/moltenvk" -path '*dylib/macOS/libMoltenVK.dylib' | head -n 1)"
  [ -n "$mvk" ] || die "libMoltenVK.dylib not found in MoltenVK-macos.tar"
  lipo "$mvk" -verify_arch x86_64 || die "MoltenVK has no x86_64 slice"
  mkdir -p "$PP_DEPS/lib"
  lipo -thin x86_64 "$mvk" -output "$PP_DEPS/lib/libMoltenVK.dylib"
  stamp_done deps-moltenvk
fi

# Normalise install names to @rpath/<leaf> and inter-library references to @rpath too.
log "normalising install names in $PP_DEPS/lib"
for f in "$PP_DEPS"/lib/*.dylib; do
  [ -L "$f" ] && continue
  rpathify "$f"
done
for f in "$PP_DEPS"/lib/*.dylib; do
  [ -L "$f" ] && continue
  otool -L "$f" | tail -n +2 | awk '{print $1}' | while IFS= read -r ref; do
    case "$ref" in "$PP_DEPS"/lib/*) install_name_tool -change "$ref" "@rpath/$(basename "$ref")" "$f" ;; esac
  done
done

# Record versions for the manifest.
{
  echo "gmp $(sed -n "s/^PACKAGE_VERSION='\(.*\)'/\1/p" "$PP_SRC/gmp/configure" | head -n 1)"
  echo "nettle $(sed -n 's/^AC_INIT(\[nettle\], \[\([^]]*\)\].*/\1/p' "$PP_SRC/nettle/configure.ac")"
  echo "gnutls $(pkg-config --modversion gnutls)"
  echo "freetype $(pkg-config --modversion freetype2) (libtool version; FreeType 2.13.3)"
  echo "libinotify $LIBINOTIFY_VERSION"
  echo "moltenvk $MOLTENVK_VERSION"
} > "$PP_DEPS/VERSIONS.txt"
cat "$PP_DEPS/VERSIONS.txt" >&2
log "deps OK"
