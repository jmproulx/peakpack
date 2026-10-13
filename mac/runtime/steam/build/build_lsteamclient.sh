#!/bin/bash
# build_lsteamclient.sh - build the PeakPack Steam bridge against OUR pinned Wine:
#   lsteamclient.dll  Wine builtin PE (x86_64-windows), Valve's lsteamclient + our patches
#   lsteamclient.so   Wine unixlib, x86_64 Mach-O, UNSIGNED; dlopens Mac Steam's steamclient.dylib
#
# Part of PeakPack for Mac (runtime/steam). MIT licence (see ../docs/README.md).
# Written for PeakPack; the out-of-tree idea follows Proton's BSD-3 make/rules-makedep.mk,
# no code copied. Not derived from NotProton.
#
# Wine's makedep (CrossOver 26.3 / Wine 11.0) has no C++ support, so the PE half goes
# through Wine's own build system (C sources only) and this script compiles the
# C++ unix half itself with clang++ -arch x86_64, linked against the SAME tree's
# ntdll.so (one RUNTIME_ID = one ABI, runtime/INTERFACES.md 1).
#
# Steps (default: all):
#   fetch    fetch_lsteamclient.sh (pinned, hash-checked Proton source + our patches)
#   pe       add dlls/lsteamclient (PE-only view) to the Wine source tree and `make` it
#            (runtime/INTERFACES.md 2.1 B). Skip this when build_wine.sh already built it
#            via --extra-dll-dir $STEAM_WORK/extra-dlls (2.1 A).
#   unix     compile the .cpp sources and link lsteamclient.so
#   collect  verify both files and copy them, with SHA256SUMS and build-info.txt, to $OUT
#
# Usage: build_lsteamclient.sh [fetch|pe|unix|collect|all]... [--sdk DIR] [--out DIR]
#                              [--install RUNTIME_DIR] [--jobs N]
# Env (defaults per runtime/INTERFACES.md 2):
#   PP_WORK     $GITHUB_WORKSPACE/_work on CI, else ~/peakpack-build
#   STEAM_WORK  $PP_WORK/steam
#   WINE_SRC    $PP_WORK/src/wine          (--sdk DIR: DIR/src/wine)
#   WINE_BUILD  $PP_WORK/build/wine        (--sdk DIR: DIR/build/wine)
#   NTDLL_SO    first of $WINE_BUILD/dlls/ntdll/ntdll.so, $PP_WORK/dist/runtime/lib/wine/x86_64-unix/ntdll.so
#   CXX         clang++ ; MACOSX_DEPLOYMENT_TARGET 11.0 ; RUNTIME_ID (recorded only)
#   PE_MODE     makedep (default: add to SUBDIRS + rerun tools/makedep, no reconfigure)
#               | reconfigure (make_makefiles + autoreconf + config.status --recheck)
#   LSC_ALLOW_UNDEFINED=1  link with -undefined dynamic_lookup (diagnostics only)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
steam_root=$(cd "$here/.." && pwd)
if [ -n "${GITHUB_WORKSPACE:-}" ]; then PP_WORK=${PP_WORK:-$GITHUB_WORKSPACE/_work}; else PP_WORK=${PP_WORK:-$HOME/peakpack-build}; fi
STEAM_WORK=${STEAM_WORK:-$PP_WORK/steam}
OUT=${OUT:-$STEAM_WORK/out}
JOBS=${JOBS:-$( (sysctl -n hw.ncpu || nproc || echo 4) 2>/dev/null | head -1)}
CXX=${CXX:-clang++}
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-11.0}
install_runtime=""
steps=""

while [ $# -gt 0 ]; do
    case "$1" in
        fetch|pe|unix|collect|all) steps="$steps $1"; shift ;;
        --sdk) WINE_SRC=$2/src/wine; WINE_BUILD=$2/build/wine; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        --install) install_runtime=$2; shift 2 ;;
        --jobs) JOBS=$2; shift 2 ;;
        -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$steps" ] || steps=all
case " $steps " in *" all "*) steps="fetch pe unix collect" ;; esac
WINE_SRC=${WINE_SRC:-$PP_WORK/src/wine}
WINE_BUILD=${WINE_BUILD:-$PP_WORK/build/wine}

say() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

SRC=$STEAM_WORK/src/lsteamclient
PEVIEW=$STEAM_WORK/extra-dlls/lsteamclient
OBJ=$STEAM_WORK/obj-unix

step_fetch() {
    if [ -f "$SRC/PEAKPACK-STAMP" ] && [ -f "$PEVIEW/Makefile.in" ]; then
        say "source already staged ($(grep proton_commit "$SRC/PEAKPACK-STAMP"))"
    else
        STEAM_WORK=$STEAM_WORK PP_WORK=$PP_WORK "$here/fetch_lsteamclient.sh"
    fi
}

step_pe() {
    [ -f "$PEVIEW/Makefile.in" ] || die "run the fetch step first"
    [ -f "$WINE_BUILD/Makefile" ] && [ -x "$WINE_BUILD/config.status" ] || die "no configured Wine build at $WINE_BUILD"
    [ -f "$WINE_SRC/configure.ac" ] || die "no Wine source at $WINE_SRC"
    say "adding dlls/lsteamclient to $WINE_SRC"
    rm -rf "$WINE_SRC/dlls/lsteamclient"
    cp -R "$PEVIEW" "$WINE_SRC/dlls/lsteamclient"
    if [ "${PE_MODE:-makedep}" = makedep ]; then
        # Default: no reconfigure (the SDK tree has no dependency prefix to re-run configure
        # against). Add the dir to SUBDIRS in the configured top Makefile and let makedep
        # regenerate the rules; makedep reads SUBDIRS from there.
        if ! grep -Eq '^[[:space:]]*dlls/lsteamclient([[:space:]]|\\|$)' "$WINE_BUILD/Makefile"; then
            awk '
                !done && /^SUBDIRS[ \t]*=/ {
                    if ($0 ~ /\\[ \t]*$/) { print; print "\tdlls/lsteamclient \\"; done = 1; next }
                    print $0 " dlls/lsteamclient"; done = 1; next
                }
                { print }
                END { if (!done) exit 3 }
            ' "$WINE_BUILD/Makefile" > "$WINE_BUILD/Makefile.pp" || die "no SUBDIRS in $WINE_BUILD/Makefile; use PE_MODE=reconfigure"
            mv "$WINE_BUILD/Makefile.pp" "$WINE_BUILD/Makefile"
        fi
        ( cd "$WINE_BUILD" && tools/makedep -C ) || die "makedep failed"   # same flags as configure
    else
        # PE_MODE=reconfigure: runtime/INTERFACES.md 2.1 B, needs the full build environment.
        if ! grep -q 'WINE_CONFIG_MAKEFILE(dlls/lsteamclient)' "$WINE_SRC/configure.ac"; then
            ( cd "$WINE_SRC" && tools/make_makefiles )        # registers new dlls/*/Makefile.in
            grep -q 'WINE_CONFIG_MAKEFILE(dlls/lsteamclient)' "$WINE_SRC/configure.ac" \
                || echo 'WINE_CONFIG_MAKEFILE(dlls/lsteamclient)' >> "$WINE_SRC/configure.ac"
            ( cd "$WINE_SRC" && autoreconf -f )
        fi
        ( cd "$WINE_BUILD" && ./config.status --recheck && ./config.status )
    fi
    grep -q 'dlls/lsteamclient/all' "$WINE_BUILD/Makefile" || die "dlls/lsteamclient has no rules in $WINE_BUILD/Makefile"
    say "building dlls/lsteamclient (PE) in $WINE_BUILD"
    make -C "$WINE_BUILD" -j"$JOBS" dlls/lsteamclient/all
}

find_ntdll() {
    if [ -n "${NTDLL_SO:-}" ]; then echo "$NTDLL_SO"; return; fi
    for c in "$WINE_BUILD/dlls/ntdll/ntdll.so" "$PP_WORK/dist/runtime/lib/wine/x86_64-unix/ntdll.so"; do
        [ -f "$c" ] && { echo "$c"; return; }
    done
    die "ntdll.so of this runtime not found; set NTDLL_SO (must be the same RUNTIME_ID)"
}

step_unix() {
    [ -f "$SRC/Makefile.in" ] || die "run the fetch step first"
    [ "$(uname -s)" = Darwin ] || die "the unix half is built on macOS (Xcode clang, -arch x86_64)"
    ntdll=$(find_ntdll)
    [ "$(lipo -archs "$ntdll")" = x86_64 ] || die "$ntdll is not x86_64"
    mkdir -p "$OBJ"
    extradefs=$(sed -n 's/^EXTRADEFS[[:space:]]*=[[:space:]]*//p' "$SRC/Makefile.in")
    sources=$(sed -E -n 's/^[[:space:]]*([A-Za-z0-9_]+\.cpp)[[:space:]]*\\?[[:space:]]*$/\1/p' "$SRC/Makefile.in")
    count=$(printf '%s\n' "$sources" | wc -l | tr -d ' ')
    [ "$count" -gt 100 ] || die "only $count C++ sources found in Makefile.in"
    # Force-include the C/C++ library headers BEFORE Wine's: winebase.h #defines wcsncpy()/strncpy() as
    # errors, and Apple's libc++ (<array> -> <algorithm> -> <cwchar>) declares them after that macro exists
    # (CI run 38331541292: _wchar.h "expected ';' after top level declarator"). Include guards keep them from
    # being re-read later; direct uses in lsteamclient still hit Wine's macro, as intended.
    CXXFLAGS_LSC="-include cwchar -include cstring -include cstdlib -include array -include algorithm -include string \
-arch x86_64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -std=c++17 -O2 -g -fPIC \
-fno-strict-aliasing -fasynchronous-unwind-tables -Wno-deprecated-declarations \
-D__WINESRC__ -DWINE_UNIX_LIB $extradefs -I$SRC -I$WINE_BUILD/include -I$WINE_SRC/include ${LSC_EXTRA_CXXFLAGS:-}"
    export CXX CXXFLAGS_LSC SRC OBJ
    say "compiling $count C++ sources with $CXX ($JOBS jobs)"
    # shellcheck disable=SC2016
    printf '%s\n' "$sources" | xargs -P "$JOBS" -I{} sh -c '
        s="$SRC/$1"; o="$OBJ/${1%.cpp}.o"
        if [ ! -f "$o" ] || [ "$s" -nt "$o" ]; then
            $CXX $CXXFLAGS_LSC -c -o "$o.tmp" "$s" && mv "$o.tmp" "$o" || { echo "FAILED: $1" >&2; exit 255; }
        fi' _ {}
    objs=""
    for s in $sources; do objs="$objs $OBJ/${s%.cpp}.o"; done
    undef=""
    [ "${LSC_ALLOW_UNDEFINED:-0}" = 1 ] && undef="-Wl,-undefined,dynamic_lookup"
    say "linking lsteamclient.so against $ntdll"
    # shellcheck disable=SC2086
    $CXX -arch x86_64 -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -dynamiclib \
        -install_name @rpath/lsteamclient.so -Wl,-rpath,@loader_path/ $undef \
        -o "$OBJ/lsteamclient.so" $objs "$ntdll"
}

verify_so() {
    so=$1
    [ "$(lipo -archs "$so")" = x86_64 ] || die "$so: arch is $(lipo -archs "$so"), want x86_64"
    # Search captured output (no "producer | grep -q" under pipefail: SIGPIPE false negatives).
    grep -q '___wine_unix_call_funcs' <<<"$(nm -gU "$so")" || die "$so: no __wine_unix_call_funcs export"
    grep -q '@rpath/ntdll.so' <<<"$(otool -L "$so")" || die "$so: not linked to @rpath/ntdll.so"
    if codesign -dv "$so" >/dev/null 2>&1; then
        say "$so is signed; removing the signature (Wine refuses signed x86_64 unixlibs)"
        codesign --remove-signature "$so"
        codesign -dv "$so" >/dev/null 2>&1 && die "$so is still signed"
    fi
    [ "$(wc -c < "$so")" -gt 1000000 ] || die "$so is suspiciously small"
}

verify_dll() {
    dll=$1
    grep -q 'PE32+ executable.*x86-64' <<<"$(file "$dll")" || die "$dll: not an x86_64 PE"
    head -c 128 "$dll" | LC_ALL=C grep -aq 'Wine builtin DLL' || die "$dll: no Wine builtin marker"
    if command -v llvm-objdump >/dev/null 2>&1 || command -v x86_64-w64-mingw32-objdump >/dev/null 2>&1; then
        od_tool=$(command -v x86_64-w64-mingw32-objdump || command -v llvm-objdump)
        exports=$("$od_tool" -p "$dll" 2>/dev/null || true)
        for e in CreateInterface Steam_BGetCallback Steam_FreeLastCallback Steam_GetAPICallResult \
                 Steam_ReleaseThreadLocalMemory Steam_IsKnownInterface Steam_NotifyMissingInterface; do
            grep -q "$e" <<<"$exports" || die "$dll: export $e missing"
        done
    else
        say "no objdump found; export check skipped"
    fi
}

step_collect() {
    dll=$(find "$WINE_BUILD/dlls/lsteamclient" -path '*x86_64-windows*' -name lsteamclient.dll 2>/dev/null | head -1)
    [ -n "$dll" ] || dll=$(find "$WINE_BUILD/dlls/lsteamclient" -name lsteamclient.dll 2>/dev/null | head -1)
    [ -n "$dll" ] || die "lsteamclient.dll not built (pe step, or build_wine.sh --extra-dll-dir)"
    so=$OBJ/lsteamclient.so
    [ -f "$so" ] || die "lsteamclient.so not built (unix step)"
    verify_dll "$dll"
    verify_so "$so"
    mkdir -p "$OUT"
    cp "$dll" "$OUT/lsteamclient.dll"
    cp "$so" "$OUT/lsteamclient.so"
    cp "$SRC/LICENSE" "$OUT/LICENSE.lsteamclient.txt"
    {
        echo "PeakPack Steam bridge build"
        echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "runtime_id=${RUNTIME_ID:-unknown}"
        cat "$SRC/PEAKPACK-STAMP"
        echo "cxx=$($CXX --version | head -1)"
        echo "macosx_deployment_target=$MACOSX_DEPLOYMENT_TARGET"
        echo "wine_build=$WINE_BUILD"
        echo "ntdll_so_sha256=$(sha256 "$(find_ntdll)")"
        echo "workflow_run=${GITHUB_SERVER_URL:-}${GITHUB_REPOSITORY:+/$GITHUB_REPOSITORY/actions/runs/}${GITHUB_RUN_ID:-}"
    } > "$OUT/build-info.txt"
    ( cd "$OUT" && for f in lsteamclient.dll lsteamclient.so; do echo "$(sha256 "$f")  $f"; done > SHA256SUMS )
    say "bridge ready in $OUT:"
    cat "$OUT/SHA256SUMS"
    if [ -n "$install_runtime" ]; then
        adder=$steam_root/../build/add_builtin.sh
        [ -x "$adder" ] || die "runtime/build/add_builtin.sh not found"
        "$adder" "$install_runtime" "$OUT/lsteamclient.dll" "$OUT/lsteamclient.so"
    fi
}

for s in $steps; do
    say "step: $s"
    "step_$s"
done
