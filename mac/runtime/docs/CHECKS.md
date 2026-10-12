# Checks: done on the PC vs. needing CI or the Mac

*12 Oct 2026, runtime team.*

## 1. Static checks run on Joshua's PC (all pass)

| Check | Tool | Result |
|---|---|---|
| `bash -n` on all 20 `runtime/**/*.sh` | Git Bash | pass |
| ShellCheck, severity `style`, with `-x` and `.shellcheckrc` (`source-path=SCRIPTDIR`) | shellcheck v0.11.0 (`tools/shellcheck`, zip gh digest `8a4e35ab…740e`) | clean; SC2015 is deliberately disabled in `verify_runtime.sh` |
| ShellCheck of `pins.env` as bash | same | clean |
| yamllint of both workflows (line-length 140, `truthy` keys off) | yamllint 1.35.1 in `tools/venv` | clean |
| Every workflow `run:` block extracted, then `bash -n` and shellcheck on each | PyYAML + shellcheck | clean |
| `manifest.py` run against a dummy runtime | Python 3.13 `-I` | valid JSON, schema v1 |
| `.reg` files: `REGEDIT4` header and ASCII only | Python | pass |
| **`prepare_sources.sh` against the real CrossOver tarball:** extracts wine/dxvk/freetype/gnutls; `optional/0001…RTLD_GLOBAL.patch` applies cleanly (line 1089 becomes `RTLD_NOW \| RTLD_GLOBAL`); a dummy `--extra-dll-dir` module registers as `WINE_CONFIG_MAKEFILE(dlls/lsteamclient)` before the end marker; `APPLIED.txt` records the hashes. It stops at `autoreconf`, which this PC doesn't have, as expected | Git Bash | pass |
| **Prefix scripts against a stub Wine:** `pp-create-prefix.sh` (wineboot override env, reg import order 00 → 10 → backend, `prefix.json`, DXMT d3d11 + winemetal in system32); `pp-backend.sh dxvk-nodxgi` and `wined3d` restore Wine's DLLs; re-run is idempotent | Git Bash + stub `wine`/`wineserver` | pass |
| Licence files present in the extracted sources (Wine COPYING.LIB, FreeType FTL, GnuTLS doc/COPYING.LESSER, Nettle/GMP LGPLv3, DXVK) | ls | pass |
| GnuTLS configure flag names exist in its `configure` | grep | pass (removed `--disable-guile`, which doesn't exist) |
| From source: Mac Driver key names and defaults, Command → `VK_LMENU`, RetinaMode global-only, `macdrv_functions` export, msync env names, Wine's bare-soname dlopen, makedep flag order (`$(CFLAGS)` last) | CrossOver 26.3 source | confirmed |

## 2. Only checkable on CI (first `mac-runtime` run)

1. The CodeWeavers URL reachable from runners, or the mirror fallback.
2. The libinotify SHA-256 (the only `FILL`). MoltenVK, llvm-mingw and DXMT pins were read from GitHub API digests through a summarising fetch; a mismatch fails safely.
3. Builds succeed:
   - GMP and Nettle `--enable-fat` on x86_64 Darwin;
   - GnuTLS 3.8.3 with included libtasn1/unistring;
   - FreeType via meson `--wrap-mode=nodownload`;
   - **libinotify-kqueue on macOS** (Gcenx uses it, so it is expected to build).
4. Wine configure finds `SONAME_LIBFREETYPE`, `SONAME_LIBGNUTLS`, `SONAME_LIBVULKAN` (MoltenVK) and `HAVE_SYS_INOTIFY_H`. `build_wine.sh` fails otherwise.
5. Wine 11.0 builds PE i386 + x86_64 with llvm-mingw 20260826 (LLVM 23).
6. `winemac.so` exports `_macdrv_functions` (asserted in `build_wine.sh` and `verify_runtime.sh`).
7. LLVM 15.0.7 compiles with Xcode 16's libc++ (`PP_LLVM15_CXXFLAGS` escape hatch).
8. DXMT v0.80 builds against our `wine-dev` install via `-Dwine_install_path`. Its meson resolves `bin/winebuild` and `lib/wine`. Output names as expected; `winemetal.dll` carries the builtin marker and `d3d11.dll` does not.
9. CrossOver DXVK 1.10.3 builds with Ubuntu 24.04 mingw-w64 GCC (posix) and glslang.
10. Relocation: no build or Homebrew paths left, all Mach-O files x86_64, unixlibs unsigned.
11. Smoke test on the runner's GUI session: `wine --version`, prefix creation, `cmd /c ver`, `reg query` of the PEAK.exe overrides.
12. Job time within 340 min, and artifact and asset sizes.

## 3. Only checkable on the Mac (gates)

| Gate | What we learn about the runtime |
|---|---|
| **G-A1** (first) | `verify_runtime.sh <rt> --smoke` under Rosetta on M1/M2. **DXMT's `dlsym(RTLD_DEFAULT,"macdrv_functions")` succeeds** with an unpatched CrossOver Wine: run a D3D11 sample with `pp-run.sh --logs` and `DXMT_LOG_LEVEL=info`. If it fails, rebuild with `optional_patches=0001-ntdll-load-unixlibs-RTLD_GLOBAL.patch`, then with `PP_WINEMAC_EXPORT_ALL=1`. Also A/B our DXMT against upstream `dxmt-v0.80-builtin` |
| G-A1 | Gatekeeper and quarantine: the front end fetches the runtime itself, so it shouldn't be quarantined. Unsigned x86_64 dylibs load under Rosetta; dylibs with removed signatures are fine |
| G-A1 | `DYLD_FALLBACK_LIBRARY_PATH` survives our launch chain (front end → bash → `exec wine`): Wine finds FreeType, GnuTLS and MoltenVK (no "font"/"TLS"/"vulkan" errors in logs mode) |
| G-A2 / G-A3 | Everything in `TUNING.md` |
| G-D2 | Wine's `reg import` handles our REGEDIT4 files, including `"value"=-` deletions, and the AppDefaults scoping to PEAK.exe works (the winhttp proxy loads BepInEx) |
| G-D3 | libinotify → `ReadDirectoryChangesW` gets AutoReload's change events (TUNING D1) |
| G-X1 | Mic via coreaudio + the front end's `NSMicrophoneUsageDescription`; keyboard profile K1 |
| G-B2 | Steam team: lsteamclient built in-tree (`--extra-dll-dir`) or from the SDK loads in our runtime |
