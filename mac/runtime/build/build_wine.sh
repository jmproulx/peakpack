#!/bin/bash
# build_wine.sh [--extra-dll-dir DIR]... [--with-optional-patch NAME]... [--no-prepare]
# Configures and builds CrossOver-26.3 Wine (11.0 + msync) for x86_64 macOS with WoW64
# (PE archs i386 + x86_64), then installs it into $PP_STAGE/wine-dev (full install, with
# dev files: winegcc, winebuild, include, import libs). assemble_runtime.sh later copies
# only the runtime parts.
#
# The configured tree stays in $PP_BLD/wine (INTERFACES.md §2), configured with a
# RELATIVE srcdir (../../src/wine) so src/ + build/ can be shipped together as the SDK.
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
ensure_x86_64 "$@"

prep_args=""
do_prepare=1
while [ $# -gt 0 ]; do
  case "$1" in
    --extra-dll-dir|--with-optional-patch) [ $# -ge 2 ] || die "$1 needs a value"; prep_args="$prep_args $1 $2"; shift 2 ;;
    --no-prepare) do_prepare=0; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

mac_x86_64_env
need make bison flex pkg-config clang
# Wine needs bison >= 3.0; Apple's /usr/bin/bison is 2.3.
bison --version | head -n 1 | grep -Eq ' (3|4)\.' || die "bison >= 3 required first in PATH (brew bison is keg-only: add \$(brew --prefix bison)/bin)"

if [ "$do_prepare" = 1 ]; then
  # shellcheck disable=SC2086
  "$PP_BUILD_DIR/prepare_sources.sh" $prep_args
fi
[ -f "$PP_SRC/wine/configure" ] || die "no prepared Wine source in $PP_SRC/wine"

# PE cross toolchain.
if [ "$PP_PE_TOOLCHAIN" = llvm-mingw ] && [ ! -x "$PP_TOOLS/llvm-mingw/bin/x86_64-w64-mingw32-clang" ]; then
  log "unpacking llvm-mingw $LLVM_MINGW_VERSION"
  rm -rf "$PP_TOOLS/llvm-mingw" && mkdir -p "$PP_TOOLS/llvm-mingw"
  tar -xJf "$PP_DL/$(basename "$LLVM_MINGW_MAC_URL")" -C "$PP_TOOLS/llvm-mingw" --strip-components=1
fi
pe_toolchain_env
case "$PP_PE_TOOLCHAIN" in
  llvm-mingw) mingw_arg="--with-mingw=llvm-mingw" ;;
  mingw-gcc)  mingw_arg="--with-mingw" ;;
esac

# configure may be regenerated with autoconf 2.72 (extra DLLs), whose AC_PROG_CC picks
# -std=gnu23; keep clang's default gnu17 for the unix side, as for the deps (build_deps.sh).
export ac_cv_prog_cc_c23=no

# Absolute rpath to the deps prefix for the build only; bundle step rewrites it.
export LDFLAGS="$LDFLAGS -L$PP_DEPS/lib -Wl,-rpath,$PP_DEPS/lib"
export CPPFLAGS="-I$PP_DEPS/include"
export FREETYPE_CFLAGS="-I$PP_DEPS/include/freetype2" FREETYPE_LIBS="-L$PP_DEPS/lib -lfreetype"
export GNUTLS_CFLAGS="-I$PP_DEPS/include" GNUTLS_LIBS="-L$PP_DEPS/lib -lgnutls"
export INOTIFY_CFLAGS="-I$PP_DEPS/include" INOTIFY_LIBS="-L$PP_DEPS/lib -linotify"

# No --with-opengl: on macOS winemac.drv draws OpenGL through CGL; with the flag, the EGL check
# (X11/Wayland only) becomes a hard error (CI run 38316710000). PEAK uses D3D11 via DXMT (Metal).
# Configure flags: start from Gcenx's MacPorts wine-stable 11.0 port, adapted (DECISIONS.md D2).
CONFIGURE_ARGS="--prefix=/ \
 --build=x86_64-apple-darwin --host=x86_64-apple-darwin \
 --enable-archs=i386,x86_64 $mingw_arg \
 --disable-tests --disable-winemenubuilder \
 --with-coreaudio --with-freetype --with-gnutls --with-inotify --with-vulkan \
 --with-pthread --with-unwind \
 --without-alsa --without-capi --without-cups --without-dbus --without-ffmpeg --without-fontconfig \
 --without-gettext --without-gettextpo --without-gphoto --without-gssapi --without-gstreamer \
 --without-krb5 --without-netapi --without-opencl --without-oss --without-pcap --without-pcsclite \
 --without-pulse --without-sane --without-sdl --without-udev --without-usb --without-v4l2 \
 --without-wayland --without-x"
# Normalise whitespace for the manifest.
CONFIGURE_ARGS="$(printf '%s' "$CONFIGURE_ARGS" | tr -s ' \n' ' ')"
printf '%s\n' "$CONFIGURE_ARGS" > "$PP_WORK/wine-configure-args.txt"

mkdir -p "$PP_BLD/wine"
cd "$PP_BLD/wine" || exit 1
if [ ! -f Makefile ] || [ "$PP_SRC/wine/configure" -nt Makefile ]; then
  log "configure Wine ($PP_PE_TOOLCHAIN)"
  # shellcheck disable=SC2086
  ../../src/wine/configure $CONFIGURE_ARGS
fi

# Hard requirements we rely on (fail early instead of shipping a silently degraded build).
for v in SONAME_LIBFREETYPE SONAME_LIBGNUTLS SONAME_LIBVULKAN HAVE_SYS_INOTIFY_H; do
  grep -q "#define $v" include/config.h || die "configure did not find $v (see config.log)"
done
{ grep -q '^x86_64_CC' Makefile && grep -q '^i386_CC' Makefile; } || die "PE cross compilers for x86_64/i386 not configured"

log "make Wine (-j$(ncpu))"
make -j"$(ncpu)"

log "make install -> $PP_STAGE/wine-dev"
rm -rf "$PP_STAGE/wine-dev"
make install DESTDIR="$PP_STAGE/wine-dev"

# Checks DXMT relies on: CrossOver exports macdrv_functions from winemac.so (DECISIONS.md D3).
ws="$PP_STAGE/wine-dev/lib/wine/x86_64-unix/winemac.so"
[ -f "$ws" ] || die "winemac.so not built"
nm -gU "$ws" | grep -q ' _macdrv_functions$' || die "winemac.so does not export macdrv_functions (DXMT will fail)"
log "winemac.so exports macdrv_functions: OK"

# The default visibility rebuild (notpop's approach for upstream Wine) is NOT needed with
# CrossOver sources; kept as an opt-in escape hatch for a G-A1 failure.
if [ "${PP_WINEMAC_EXPORT_ALL:-0}" = 1 ]; then
  log "rebuilding winemac.so with -fvisibility=default (PP_WINEMAC_EXPORT_ALL=1)"
  # makedep puts \$(CFLAGS) after EXTRACFLAGS (-fvisibility=hidden), so the last flag wins
  # for the unix side only (PE objects use x86_64_CFLAGS).
  rm -f dlls/winemac.drv/*.o dlls/winemac.drv/winemac.so
  # shellcheck disable=SC2153  # CFLAGS is exported by mac_x86_64_env
  make dlls/winemac.drv/all CFLAGS="$CFLAGS -fvisibility=default"
  make install DESTDIR="$PP_STAGE/wine-dev"
fi

"$PP_STAGE/wine-dev/bin/wine" --version > "$PP_WORK/wine-version.txt" 2>/dev/null || \
  sed -n 's/^Wine version //p' "$PP_SRC/wine/VERSION" > "$PP_WORK/wine-version.txt"
log "Wine OK: $(cat "$PP_WORK/wine-version.txt")"
stamp_done wine
