#!/bin/bash
# PeakPack for Mac, native track: build the SELF-CONTAINED converter bundle
#   peakpack-native-tools-<NT_VERSION>-macos-arm64.tar.xz (+ .sha256)
# = python-build-standalone CPython + hash-locked pip packages + SPIRV-Cross (built here, static,
#   ad-hoc signed, at native/bin/spirv-cross where peakmetal finds it by itself) + our converter
#   (mac/native/peakmetal, pm.py) + bin/pm launcher + LICENSES/ + MANIFEST.json + FILES.sha256 +
#   check/ (verify_bundle.sh, smoke.py). Layout contract: native/NOTES-bundle.md.
# No PEAK/Landfall or Unity data is read, downloaded or packed.
#
# Usage:
#   build_bundle.sh --check-pins            static pin/lock validation only (any OS; the CI guard job)
#   build_bundle.sh [--work DIR] [--out DIR] full build (macOS arm64 only; default ./_work/native-tools)
#
# Repo layout: this file is mac/native/packaging/build_bundle.sh; the converter is mac/native/{peakmetal,pm.py};
# our licence is mac/LICENSE. Needs: curl, git, cmake, Xcode command line tools, zstd (licences only).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
native="$(cd "$here/.." && pwd)"
macdir="$(cd "$native/.." && pwd)"

die() { echo "build_bundle: ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

# shellcheck source-path=SCRIPTDIR source=pins.env
. "$here/pins.env"

# ---------------------------------------------------------------------------------------------
# Pin validation (also what makes publish refuse unpinned inputs)
# ---------------------------------------------------------------------------------------------
check_var() {  # name regex
    local name="$1" re="$2" val
    eval "val=\"\${$name-}\""   # indirect expansion that also works in macOS /bin/bash 3.2
    [ -n "$val" ] || die "pins.env: $name is empty"
    case "$val" in FILL*|fill*|TODO*) die "pins.env: $name is not pinned ($val)" ;; esac
    printf '%s\n' "$val" | grep -Eq "$re" || die "pins.env: $name='$val' does not match $re"
}

# Print each requirement of a pip lock as one logical line (comments dropped, continuations joined).
lock_lines() {
    awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { if (line != "") { print line; line = "" } next }
        {
            l = $0
            if (l ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", l); line = line " " l; next }
            print line " " l; line = ""
        }
        END { if (line != "") print line }
    ' "$1"
}

check_lock() {
    local lock="$1" n=0 req
    [ -f "$lock" ] || die "missing $lock"
    while IFS= read -r req; do
        n=$((n + 1))
        printf '%s\n' "$req" | grep -Eq '^ *[a-z0-9][a-z0-9._-]*==[0-9][A-Za-z0-9.+!-]*( +--hash=sha256:[0-9a-f]{64})+ *$' \
            || die "$(basename "$lock"): not an exact, hash-pinned requirement: $req"
    done < <(lock_lines "$lock")
    [ "$n" -gt 0 ] || die "$(basename "$lock"): no requirements"
    echo "$(basename "$lock"): $n hash-pinned requirements"
}

check_pins() {
    check_var NT_VERSION '^[0-9]+\.[0-9]+\.[0-9]+$'
    check_var NT_PUBLISH_ALLOWED '^[01]$'
    check_var NT_MACOS_MIN '^[0-9]+\.[0-9]+$'
    check_var PBS_RELEASE '^[0-9]{8}$'
    check_var PBS_PYTHON_VERSION '^3\.1[1-9]\.[0-9]+$'
    check_var PBS_ASSET '^cpython-.*-aarch64-apple-darwin-install_only\.tar\.gz$'
    check_var PBS_FULL_ASSET '^cpython-.*-aarch64-apple-darwin-pgo\+lto-full\.tar\.zst$'
    [ "$PBS_ASSET" = "cpython-${PBS_PYTHON_VERSION}+${PBS_RELEASE}-aarch64-apple-darwin-install_only.tar.gz" ] \
        || die "pins.env: PBS_ASSET does not match PBS_PYTHON_VERSION/PBS_RELEASE"
    [ "$PBS_FULL_ASSET" = "cpython-${PBS_PYTHON_VERSION}+${PBS_RELEASE}-aarch64-apple-darwin-pgo+lto-full.tar.zst" ] \
        || die "pins.env: PBS_FULL_ASSET does not match PBS_PYTHON_VERSION/PBS_RELEASE"
    check_var PBS_SHA256 '^[0-9a-f]{64}$'
    check_var PBS_FULL_SHA256 '^[0-9a-f]{64}$'
    local base="https://github.com/astral-sh/python-build-standalone/releases/download/$PBS_RELEASE/"
    [ "$PBS_URL" = "$base${PBS_ASSET//+/%2B}" ] || die "pins.env: PBS_URL does not match PBS_RELEASE/PBS_ASSET"
    [ "$PBS_FULL_URL" = "$base${PBS_FULL_ASSET//+/%2B}" ] || die "pins.env: PBS_FULL_URL does not match PBS_RELEASE/PBS_FULL_ASSET"
    check_var SPIRV_CROSS_REPO '^https://github\.com/KhronosGroup/SPIRV-Cross\.git$'
    check_var SPIRV_CROSS_TAG '^vulkan-sdk-[0-9.]+$'
    check_var SPIRV_CROSS_COMMIT '^[0-9a-f]{40}$'
    check_var PYPI_INDEX_URL '^https://pypi\.org/simple$'
    check_lock "$here/requirements.lock"
    check_lock "$here/requirements-build.lock"
    echo "pins OK: native tools $NT_VERSION (python $PBS_PYTHON_VERSION, SPIRV-Cross $SPIRV_CROSS_TAG)"
}

work="$PWD/_work/native-tools"
out=""
case "${1-}" in
    --check-pins) check_pins; exit 0 ;;
esac
while [ $# -gt 0 ]; do
    case "$1" in
        --work) work="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
check_pins

[ "$(uname -s)" = Darwin ] || die "the full build runs on macOS only"
[ "$(uname -m)" = arm64 ] || die "the full build runs on Apple silicon (arm64) only, natively"
[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 0 ] || die "running under Rosetta"
[ -f "$macdir/LICENSE" ] || die "missing $macdir/LICENSE (our MIT licence)"
[ -f "$native/pm.py" ] && [ -d "$native/peakmetal" ] || die "converter not found under $native"

name="peakpack-native-tools-${NT_VERSION}-macos-arm64"
mkdir -p "$work"
work="$(cd "$work" && pwd)"
out="${out:-$work/out}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
dl="$work/downloads"
stage="$work/stage/$name"
rm -rf "$work/stage" "$work/src" "$work/build" "$work/tmp"
mkdir -p "$dl" "$stage/bin" "$stage/native/bin" "$stage/LICENSES" "$stage/check" "$work/src" "$work/build" "$work/tmp"
export MACOSX_DEPLOYMENT_TARGET="$NT_MACOS_MIN"

fetch() {  # url file sha256
    local url="$1" file="$dl/$2" sum="$3"
    if [ -f "$file" ] && [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$sum" ]; then
        log "cached $2"
        return 0
    fi
    log "download $2"
    rm -f "$file" "$file.part"
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 5 -o "$file.part" "$url"
    local got
    got="$(shasum -a 256 "$file.part" | cut -d' ' -f1)"
    [ "$got" = "$sum" ] || die "$2: sha256 $got, pinned $sum"
    mv "$file.part" "$file"
}

# ---------------------------------------------------------------------------------------------
# 1. python-build-standalone
# ---------------------------------------------------------------------------------------------
fetch "$PBS_URL" "$PBS_ASSET" "$PBS_SHA256"
fetch "$PBS_FULL_URL" "$PBS_FULL_ASSET" "$PBS_FULL_SHA256"
log "extract CPython $PBS_PYTHON_VERSION"
tar -xzf "$dl/$PBS_ASSET" -C "$stage"
py="$stage/python/bin/python3"
[ -x "$py" ] || die "no python/bin/python3 in $PBS_ASSET"
[ "$("$py" -I -c 'import platform; print(platform.python_version())')" = "$PBS_PYTHON_VERSION" ] \
    || die "python version mismatch"

# ---------------------------------------------------------------------------------------------
# 2. Python packages: exact versions, hash-checked, no dependency resolution
# ---------------------------------------------------------------------------------------------
log "pip install (hash-locked)"
unset PIP_INDEX_URL PIP_EXTRA_INDEX_URL PIP_FIND_LINKS PIP_TRUSTED_HOST PIP_REQUIRE_VIRTUALENV PYTHONPATH PYTHONHOME
export PIP_CONFIG_FILE=/dev/null PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_INPUT=1 PIP_NO_CACHE_DIR=1
pipi() { "$py" -I -m pip install --index-url "$PYPI_INDEX_URL" --require-hashes --no-deps --no-compile \
    --break-system-packages --no-warn-script-location "$@"; }
pip_version="$("$py" -I -m pip --version | cut -d' ' -f2)"
pipi --only-binary=:all: --report "$work/pip-report-build.json" -r "$here/requirements-build.lock"
# tpk_ar is sdist-only on PyPI: built by the hash-checked setuptools above, without build isolation.
pipi --no-build-isolation --only-binary=:all: --no-binary=tpk-ar --report "$work/pip-report.json" \
    -r "$here/requirements.lock"
"$py" -I -m pip uninstall -y -q setuptools pip
rm -f "$stage"/python/bin/pip "$stage"/python/bin/pip3 "$stage"/python/bin/pip3.*

# ---------------------------------------------------------------------------------------------
# 3. Prune what the converter can never use (Tk/IDLE, headers, ensurepip). Recorded in MANIFEST.json.
# ---------------------------------------------------------------------------------------------
log "prune"
pruned=(
    python/include
    python/bin/idle3 python/bin/idle3.13
    python/lib/python3.13/idlelib python/lib/python3.13/tkinter python/lib/python3.13/turtledemo
    python/lib/python3.13/ensurepip
    python/lib/tcl9.0 python/lib/tk9.0 python/lib/tcl9 python/lib/libtcl9.0.dylib python/lib/libtcl9tk9.0.dylib
)
for p in "${pruned[@]}"; do rm -rf "${stage:?}/$p"; done
# Versioned Tcl extension dirs and the _tkinter module (names carry versions / ABI tags).
for p in "$stage"/python/lib/itcl* "$stage"/python/lib/thread[0-9]* "$stage"/python/lib/python3.13/lib-dynload/_tkinter*.so; do
    [ -e "$p" ] || continue
    rm -rf "$p"
    pruned+=("${p#"$stage"/}")
done
find "$stage" -name __pycache__ -type d -prune -exec rm -rf {} +

# ---------------------------------------------------------------------------------------------
# 4. Licences of everything python-build-standalone links in (from the matching full archive)
# ---------------------------------------------------------------------------------------------
log "licences"
command -v zstd >/dev/null 2>&1 || { log "zstd missing: brew install zstd (only used to read the hash-checked full archive)"; brew install zstd; }
mkdir -p "$work/tmp/pbs-full"
zstd -dc "$dl/$PBS_FULL_ASSET" | tar -xf - -C "$work/tmp/pbs-full" python/licenses python/PYTHON.json
[ -d "$work/tmp/pbs-full/python/licenses" ] || die "no python/licenses in $PBS_FULL_ASSET"
mkdir -p "$stage/LICENSES/python-build-standalone"
cp -R "$work/tmp/pbs-full/python/licenses/." "$stage/LICENSES/python-build-standalone/"
cp "$work/tmp/pbs-full/python/PYTHON.json" "$stage/LICENSES/python-build-standalone/PYTHON.json"
cp "$stage/python/lib/python3.13/LICENSE.txt" "$stage/LICENSES/Python-PSF-LICENSE.txt"
cp "$macdir/LICENSE" "$stage/LICENSES/PeakPack-MIT-LICENSE.txt"
site="$stage/python/lib/python3.13/site-packages"
for di in "$site"/*.dist-info; do
    dname="$(basename "$di" .dist-info)"
    dest="$stage/LICENSES/python-packages/$dname"
    mkdir -p "$dest"
    if [ -d "$di/licenses" ]; then
        cp -R "$di/licenses/." "$dest/"
    fi
    for f in "$di"/LICENSE* "$di"/LICENCE* "$di"/COPYING* "$di"/NOTICE* "$di"/AUTHORS*; do
        if [ -f "$f" ]; then cp "$f" "$dest/"; fi
    done
    [ -n "$(ls -A "$dest")" ] || die "$dname: no licence file in its dist-info"
done

# ---------------------------------------------------------------------------------------------
# 5. SPIRV-Cross: pinned commit, Release, static libraries, arm64, ad-hoc signed
# ---------------------------------------------------------------------------------------------
log "SPIRV-Cross $SPIRV_CROSS_TAG ($SPIRV_CROSS_COMMIT)"
src="$work/src/SPIRV-Cross"
git init -q "$src"
git -C "$src" remote add origin "$SPIRV_CROSS_REPO"
git -C "$src" -c protocol.version=2 fetch -q --depth 1 origin "$SPIRV_CROSS_COMMIT"
git -C "$src" -c advice.detachedHead=false checkout -q FETCH_HEAD
[ "$(git -C "$src" rev-parse HEAD)" = "$SPIRV_CROSS_COMMIT" ] || die "SPIRV-Cross checkout is not the pinned commit"
tag_sha="$(git ls-remote "$SPIRV_CROSS_REPO" "refs/tags/$SPIRV_CROSS_TAG" "refs/tags/$SPIRV_CROSS_TAG^{}" \
    | awk '{ sha = $1 } /\^\{\}$/ { peeled = $1 } END { print (peeled != "" ? peeled : sha) }')"
[ "$tag_sha" = "$SPIRV_CROSS_COMMIT" ] || die "tag $SPIRV_CROSS_TAG is $tag_sha upstream, pinned commit is $SPIRV_CROSS_COMMIT"
cp "$src/LICENSE" "$stage/LICENSES/SPIRV-Cross-Apache-2.0-LICENSE.txt"
if [ -d "$src/LICENSES" ]; then
    mkdir -p "$stage/LICENSES/SPIRV-Cross"
    cp -R "$src/LICENSES/." "$stage/LICENSES/SPIRV-Cross/"
fi
cmake_flags=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_ARCHITECTURES=arm64
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=$NT_MACOS_MIN"
    -DSPIRV_CROSS_SHARED=OFF
    -DSPIRV_CROSS_STATIC=ON
    -DSPIRV_CROSS_CLI=ON
    -DSPIRV_CROSS_ENABLE_TESTS=OFF
    -DSPIRV_CROSS_SKIP_INSTALL=ON
)
cmake -S "$src" -B "$work/build/spirv-cross" "${cmake_flags[@]}" >/dev/null
cmake --build "$work/build/spirv-cross" --config Release --target spirv-cross -j "$(sysctl -n hw.ncpu)"
spx="$stage/native/bin/spirv-cross"
install -m 0755 "$work/build/spirv-cross/spirv-cross" "$spx"
strip -S -x "$spx"
codesign --force --sign - "$spx"
codesign --verify --strict "$spx"
"$spx" --revision

# ---------------------------------------------------------------------------------------------
# 6. Our converter (sources only) and the launcher
# ---------------------------------------------------------------------------------------------
log "converter"
cp "$native/pm.py" "$stage/native/pm.py"
cp -R "$native/peakmetal" "$stage/native/peakmetal"
find "$stage/native/peakmetal" \( -name __pycache__ -o -name .pytest_cache \) -type d -prune -exec rm -rf {} +
find "$stage/native/peakmetal" -type f -name '*.py[co]' -delete
stray="$(find "$stage/native/peakmetal" -type f ! -name '*.py')"
[ -z "$stray" ] || die "non-Python files in the converter tree (data must never ship): $stray"

cat > "$stage/bin/pm" <<'LAUNCHER'
#!/bin/bash
# PeakPack native tools launcher: runs the bundled converter with the bundled Python and spirv-cross.
#   bin/pm <command> ...   (e.g. bin/pm doctor, bin/pm convert <PEAK_Data/data.unity3d> --out DIR)
# Bash 3.2 compatible (macOS /bin/bash). Nothing outside this folder is used.
set -euo pipefail
src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    case "$src" in /*) ;; *) src="$dir/$src" ;; esac
done
root="$(cd -P "$(dirname "$src")/.." && pwd)"
export PEAKMETAL_SPIRV_CROSS="$root/native/bin/spirv-cross"
exec "$root/python/bin/python3" -I -B "$root/native/pm.py" "$@"
LAUNCHER
chmod 0755 "$stage/bin/pm"
install -m 0755 "$here/verify_bundle.sh" "$stage/check/verify_bundle.sh"
install -m 0644 "$here/smoke.py" "$stage/check/smoke.py"

# ---------------------------------------------------------------------------------------------
# 7. Byte-compile (hash-checked .pyc: valid after any copy, never rewritten; launcher runs -B)
# ---------------------------------------------------------------------------------------------
log "compileall"
"$py" -I -m compileall -q -j 0 --invalidation-mode checked-hash "$stage/python/lib/python3.13" "$stage/native"

# ---------------------------------------------------------------------------------------------
# 8. MANIFEST.json and FILES.sha256
# ---------------------------------------------------------------------------------------------
log "manifest"
cat > "$stage/LICENSES/README.txt" <<'EOF'
Licences of everything in this bundle
=====================================
PeakPack-MIT-LICENSE.txt        our converter (native/peakmetal, native/pm.py), bin/pm, check/ (MIT)
Python-PSF-LICENSE.txt          CPython (PSF License, with CPython's third-party notices)
python-build-standalone/        licences of the libraries python-build-standalone links into CPython
                                (OpenSSL, libffi, SQLite, xz, zlib, bzip2, mpdecimal, ncurses, libedit, ...);
                                PYTHON.json lists which component each licence belongs to.
                                (Tcl/Tk are listed there but were pruned from this bundle.)
SPIRV-Cross-Apache-2.0-LICENSE.txt, SPIRV-Cross/   native/bin/spirv-cross (Apache-2.0; REUSE licence texts)
python-packages/<dist>/         licences shipped in each installed wheel's dist-info:
                                UnityPy (MIT), lz4 (BSD-3-Clause; bundles liblz4, BSD-2-Clause),
                                Brotli (MIT), Pillow (MIT-CMU; its file includes the bundled libraries'
                                licences), attrs (MIT), fsspec (BSD-3-Clause), tpk_ar (MIT).
Exact versions and source hashes: ../MANIFEST.json.
EOF

export NT_VERSION NT_MACOS_MIN PBS_RELEASE PBS_PYTHON_VERSION PBS_ASSET PBS_URL PBS_SHA256 PBS_FULL_ASSET \
    PBS_FULL_URL PBS_FULL_SHA256 SPIRV_CROSS_REPO SPIRV_CROSS_TAG SPIRV_CROSS_COMMIT PYPI_INDEX_URL
PRUNED="${pruned[*]}" CMAKE_FLAGS="${cmake_flags[*]}" PIP_VERSION="$pip_version" \
NAME="$name" STAGE="$stage" WORK="$work" NATIVE="$native" \
CMAKE_VERSION="$(cmake --version | head -n 1)" CLANG_VERSION="$(clang --version | head -n 1)" \
XCODE_VERSION="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' || true)" \
MACOS_VERSION="$(sw_vers -productVersion) ($(sw_vers -buildVersion))" \
SPIRV_REVISION="$("$spx" --revision 2>&1 | tr '\n' ' ')" \
"$py" -I - <<'PY'
import datetime, hashlib, json, os

e = os.environ


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def report(path):
    with open(path, encoding="utf-8") as f:
        items = json.load(f)["install"]
    out = []
    for it in items:
        info = it["download_info"]
        h = info.get("archive_info", {}).get("hashes", {}).get("sha256") or \
            info.get("archive_info", {}).get("hash", "").partition("=")[2]
        out.append({"name": it["metadata"]["name"], "version": it["metadata"]["version"],
                    "url": info["url"], "sha256": h})
    return sorted(out, key=lambda p: p["name"].lower())


conv = {}
for base, dirs, files in os.walk(os.path.join(e["STAGE"], "native")):
    dirs[:] = sorted(d for d in dirs if d not in ("__pycache__", "bin"))
    for fn in sorted(files):
        p = os.path.join(base, fn)
        conv[os.path.relpath(p, os.path.join(e["STAGE"], "native")).replace(os.sep, "/")] = sha(p)

m = {
    "name": e["NAME"],
    "version": e["NT_VERSION"],
    "platform": {"os": "macos", "arch": "arm64", "macos_min": e["NT_MACOS_MIN"]},
    "built_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "source": {k: e.get(v, "") for k, v in (("repository", "GITHUB_REPOSITORY"), ("commit", "GITHUB_SHA"),
                                             ("ref", "GITHUB_REF"), ("workflow", "GITHUB_WORKFLOW"),
                                             ("run_id", "GITHUB_RUN_ID"), ("run_attempt", "GITHUB_RUN_ATTEMPT"))},
    "builder": {"macos": e["MACOS_VERSION"], "image": "%s %s" % (e.get("ImageOS", ""), e.get("ImageVersion", "")),
                "xcode": e["XCODE_VERSION"].strip(), "clang": e["CLANG_VERSION"], "cmake": e["CMAKE_VERSION"]},
    "python": {"version": e["PBS_PYTHON_VERSION"], "distribution": "python-build-standalone",
               "release": e["PBS_RELEASE"], "asset": e["PBS_ASSET"], "url": e["PBS_URL"], "sha256": e["PBS_SHA256"],
               "licences_from": {"asset": e["PBS_FULL_ASSET"], "url": e["PBS_FULL_URL"],
                                 "sha256": e["PBS_FULL_SHA256"]},
               "pruned": e["PRUNED"].split()},
    "python_packages": report(os.path.join(e["WORK"], "pip-report.json")),
    "build_only_packages": report(os.path.join(e["WORK"], "pip-report-build.json")) +
                           [{"name": "pip", "version": e["PIP_VERSION"], "url": "bundled with python-build-standalone",
                             "sha256": ""}],
    "pip_index": e["PYPI_INDEX_URL"],
    "spirv_cross": {"repo": e["SPIRV_CROSS_REPO"], "tag": e["SPIRV_CROSS_TAG"], "commit": e["SPIRV_CROSS_COMMIT"],
                    "revision": e["SPIRV_REVISION"].strip(), "cmake_flags": e["CMAKE_FLAGS"].split(),
                    "path": "native/bin/spirv-cross",
                    "binary_sha256": sha(os.path.join(e["STAGE"], "native", "bin", "spirv-cross")),
                    "signature": "ad-hoc (codesign -s -)"},
    "converter": {"path": "native/", "files_sha256": conv},
    "launcher": "bin/pm",
    "contains_game_data": False,
}
with open(os.path.join(e["STAGE"], "MANIFEST.json"), "w", encoding="utf-8", newline="\n") as f:
    json.dump(m, f, indent=2, sort_keys=False)
    f.write("\n")
PY

# shellcheck disable=SC2094  # FILES.sha256 is excluded from the list it is written to
(cd "$stage" && find . -type f ! -name FILES.sha256 -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 > FILES.sha256)

# ---------------------------------------------------------------------------------------------
# 9. Verify in place, then pack
# ---------------------------------------------------------------------------------------------
log "verify (in place)"
"$stage/check/verify_bundle.sh" --ci "$stage"

log "pack $name.tar.xz"
rm -f "$out/$name.tar.xz" "$out/$name.tar.xz.sha256"
(cd "$work/stage" && COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs --uid 0 --gid 0 --uname root --gname wheel \
    --options xz:compression-level=9 -cJf "$out/$name.tar.xz" "$name")
(cd "$out" && shasum -a 256 "$name.tar.xz" > "$name.tar.xz.sha256")
cp "$stage/MANIFEST.json" "$out/$name.MANIFEST.json"
ls -l "$out"
cat "$out/$name.tar.xz.sha256"
if [ -n "${GITHUB_OUTPUT-}" ]; then
    {
        echo "name=$name"
        echo "version=$NT_VERSION"
        echo "tarball=$out/$name.tar.xz"
    } >> "$GITHUB_OUTPUT"
fi
log "done: $out/$name.tar.xz"
