# Native tools bundle (macOS arm64)

`peakpack-native-tools-<ver>-macos-arm64.tar.xz` is the self-contained converter for PeakPack for Mac's
native track: it runs `native/` (peakmetal) on an Apple-silicon Mac with **nothing installed** (no Python, no
Homebrew, no Xcode). G-C0 phase (b) runs it on the M1 iMac. Built only by CI
(`.github/workflows/mac-native-tools.yml`, from `mac/native/ci/mac-native-tools.yml`).

The bundle holds **no PEAK/Landfall or Unity data**, and CI downloads none (nothing from Steam or Unity).
Each friend converts their own game files on their own Mac.

## Contents

```
peakpack-native-tools-<ver>-macos-arm64/
  bin/pm                    launcher: bundled python3 -I -B native/pm.py "$@", PEAKMETAL_SPIRV_CROSS set
  native/pm.py, native/peakmetal/   our converter (MIT), copied from mac/native at build time (.py only)
  native/bin/spirv-cross    SPIRV-Cross CLI, pinned commit, Release, static libs, arm64, ad-hoc signed
  python/                   python-build-standalone CPython 3.13 (install_only, pruned) + 7 locked packages
  LICENSES/                 every licence (README.txt there is the index)
  MANIFEST.json             versions and SHA-256 of every input; hashes of the converter files
  FILES.sha256              SHA-256 of every file in the bundle (shasum -c format)
  check/verify_bundle.sh    integrity + signature + self-containment + smoke + `pm doctor`
  check/smoke.py            the Python half of the smoke test
```

Layout and the `bin/pm` / `PEAKMETAL_SPIRV_CROSS` contract are agreed with the converter team in
`native/NOTES-bundle.md`. Running `python/bin/python3 -I native/pm.py ...` directly also works: peakmetal
finds `native/bin/spirv-cross` on its own.

## Using it on a Mac (G-C0 phase b)

```
curl -LO <release or artifact URL>/peakpack-native-tools-<ver>-macos-arm64.tar.xz   # curl: no quarantine
curl -LO <...>/peakpack-native-tools-<ver>-macos-arm64.tar.xz.sha256
shasum -a 256 -c peakpack-native-tools-<ver>-macos-arm64.tar.xz.sha256
tar -xJf peakpack-native-tools-<ver>-macos-arm64.tar.xz
peakpack-native-tools-<ver>-macos-arm64/check/verify_bundle.sh
peakpack-native-tools-<ver>-macos-arm64/bin/pm doctor
peakpack-native-tools-<ver>-macos-arm64/bin/pm convert "<PEAK>/PEAK_Data/data.unity3d" --out ~/peakmetal-out
```

A file downloaded **with a browser** is quarantined, and Gatekeeper then blocks the ad-hoc-signed binaries
(`python3`, `spirv-cross`, the extension modules). `verify_bundle.sh` detects this and prints the fix:
`xattr -dr com.apple.quarantine <bundle folder>` (after checking the `.sha256`). That only changes the
extracted folder; nothing is installed. A GitHub Actions artifact arrives as a `.zip` that contains the
`.tar.xz`, `.sha256` and `MANIFEST.json`.

`verify_bundle.sh` uses only tools every macOS has (`shasum`, `file`, `codesign`, `xattr`), writes only to
a temporary folder, and checks: every file against `FILES.sha256` and nothing added; no game data files;
every Mach-O has arm64 code and a valid signature; the smoke test (`smoke.py`: the interpreter, `sys.path`
and every imported module are inside the bundle; the installed distributions are exactly the locked set;
UnityPy and lz4 work; peakmetal's `Toolchain` drives the bundled spirv-cross on a hand-built SPIR-V module,
with and without `PEAKMETAL_SPIRV_CROSS`); `bin/pm --help`; `bin/pm doctor`; and finally that running did
not write into the bundle. All of it runs under `env -i` with `PATH=/usr/bin:/bin` and a throwaway HOME.
CI adds `--ci`: every Mach-O links only the OS and the bundle, and needs at most macOS 11.0 (`otool`, which
needs Xcode, so never on a test Mac).

## Inputs and pins

Everything is pinned; there is no unpinned mode. `build_bundle.sh --check-pins` (also the workflow's guard
job and the release job's first step) rejects empty/`FILL` values, malformed hashes, URLs that do not match
their release/asset, and any lock line that is not `name==version --hash=sha256:...`.

| Input | Pin | Where |
|---|---|---|
| CPython 3.13.16 | python-build-standalone 20261009, `aarch64-apple-darwin-install_only`, SHA-256 from the release's `SHA256SUMS` (= GitHub asset digest = hashed locally) | `pins.env` |
| Licence texts of CPython's bundled libraries | the same release's `pgo+lto-full` archive (only `python/licenses/` and `PYTHON.json` are taken) | `pins.env` |
| Python packages | exact version + SHA-256 of the one file used | `requirements.lock` |
| Build backend for the `tpk_ar` sdist | setuptools 84.0.0 (uninstalled again with pip; not shipped) | `requirements-build.lock` |
| SPIRV-Cross | commit `f11ba9f0…` = tag `vulkan-sdk-1.4.363.0` (lightweight; the build checks the tag still points there) = the PC's build | `pins.env` |
| GitHub Actions | full commit SHAs (checkout v7.0.1, upload-artifact v7.0.2, download-artifact v8.0.2) | workflow |

Not pinned, and recorded in `MANIFEST.json` instead: the runner image, Xcode/clang and cmake that compile
SPIRV-Cross, and `zstd` (preinstalled, or from Homebrew; only decompresses the hash-checked licence archive).

### Python packages

```
UnityPy==1.25.4  lz4==4.4.5  brotli==1.2.0  pillow==12.3.0  attrs==26.1.0  fsspec==2026.9.0  tpk_ar==0.2.4
```

Installed with `pip install --require-hashes --no-deps`: this is the complete set peakmetal needs, and the
same versions its tests ran with on the PC. `import UnityPy` eagerly imports lz4, brotli, fsspec, attrs,
PIL and tpk_ar (checked with an import blocker over peakmetal's whole import graph). UnityPy's other declared
dependencies are imported only by `UnityPy.export` (texture/audio export), which peakmetal never calls, and
are deliberately **not shipped**: `fmod_toolkit`/`pyfmodex` (its wheels carry the proprietary FMOD library),
`texture2ddecoder`, `etcpak`, `astc-encoder-py`, `archspec`. The converter team agreed this set in
`native/NOTES-bundle.md`.

`tpk_ar` exists on PyPI only as an sdist (pure Python, MIT). pip does not hash-check the build dependencies of
an isolated build, so the hash-pinned setuptools is installed first and the sdist is built with
`--no-build-isolation` (`--only-binary=:all: --no-binary=tpk-ar`: everything else must be a wheel). Tried on
the PC with these exact pins.

### Updating a pin

1. Edit `pins.env` / the locks, bump `NT_VERSION` (any change to the inputs, the scripts or the converter).
2. python-build-standalone: take the asset's line from the release's `SHA256SUMS` and compare with
   `gh api repos/astral-sh/python-build-standalone/releases/tags/<tag>` → `assets[].digest`. Update both
   archives (`install_only` and the matching `pgo+lto-full`).
3. PyPI: `https://pypi.org/pypi/<name>/<version>/json` → the `cp313-cp313-macosx_*_arm64` (or `universal2`,
   or `py3-none-any`) file's `digests.sha256`. Cross-check on any OS (downloads only, nothing runs):
   ```
   pip download --no-deps --require-hashes --only-binary=:all: --platform macosx_11_0_arm64 \
     --python-version 3.13 --implementation cp --abi cp313 -d wheels -r <lock without tpk-ar>
   ```
   If a new UnityPy adds an eagerly imported dependency, add it (the smoke test fails on a missing import).
4. SPIRV-Cross: `gh api repos/KhronosGroup/SPIRV-Cross/git/ref/tags/<tag>` (dereference annotated tags via
   `git/tags/<sha>`). Change it only together with the converter team: another version changes the MSL.
5. `bash build_bundle.sh --check-pins`, shellcheck, actionlint, yamllint; then a `publish=false` run.

## What the build does

`build_bundle.sh` (macOS arm64 only, natively): verify pins → download both CPython archives, check
SHA-256 → extract `install_only` → hash-locked pip installs (`--report` files feed the manifest) → uninstall
setuptools and pip → prune Tk/Tcl/IDLE/turtledemo/ensurepip/headers → licences (CPython, the bundled
libraries from the full archive, every wheel's dist-info licences, SPIRV-Cross, ours) → fetch the pinned
SPIRV-Cross commit and build `spirv-cross` (cmake Release, `SPIRV_CROSS_SHARED=OFF`, static libraries, arm64,
deployment target 11.0, `strip -S -x`, `codesign --force -s -`) → copy the converter (`.py` only; anything
else aborts the build) → `bin/pm` → byte-compile everything with hash-checked `.pyc` → `MANIFEST.json`,
`FILES.sha256` → `check/verify_bundle.sh --ci` in place → `tar.xz` (no xattrs/AppleDouble, owner root) +
`.sha256`.

Local run on an Apple-silicon Mac with Xcode command line tools and cmake (not needed on test Macs):
`bash mac/native/packaging/build_bundle.sh --work /tmp/nt --out /tmp/nt-out`.

## Licences

`LICENSES/README.txt` in the bundle lists each component: PeakPack MIT (`mac/LICENSE`), CPython PSF,
python-build-standalone's bundled libraries (OpenSSL Apache-2.0, libffi, SQLite, xz, zlib, bzip2, mpdecimal,
ncurses, libedit, ...), SPIRV-Cross Apache-2.0 (+ its REUSE texts), UnityPy MIT, lz4 BSD-3-Clause (bundles
liblz4 BSD-2-Clause), Brotli MIT, Pillow MIT-CMU (with its bundled image libraries), attrs MIT, fsspec
BSD-3-Clause, tpk_ar MIT.
