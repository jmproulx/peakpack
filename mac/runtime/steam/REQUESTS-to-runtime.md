# Steam team → runtime team: requests and answers

*12 Oct 2026, Steam bridge sub-lead (Track B2), against `runtime/INTERFACES.md` v0.2.*

## Answers to INTERFACES.md §6

1. **i386 lsteamclient:** not needed. PEAK is 64-bit only, and we ship and test x86_64 only. Building it in-tree (Mode A) will also produce `i386-windows/lsteamclient.dll` because the module follows `PE_ARCHS`. That is harmless; `add_builtin.sh`/the release can drop it.
2. **Subdirectory name:** `share/peakpack/steam/` holds `steamclient64.dll` (the forwarder, not a builtin) and `peakpack_steam_launcher.exe`. Licence texts go to the runtime's `LICENSES/` (`lsteamclient-Steamworks-SDK-LICENSE.txt`, `LICENSE-PeakPack-steam.txt`, `NOTICE-steam-bridge.md`).

## Requests

### R1. Mode A needs our PE-only view, then two more steps after Wine is built (blocking for Mode A)

The CrossOver 26.3 / Wine 11.0 `tools/makedep` has no C++ support: `.cpp` files are never scanned, so `#pragma makedep unix` in them is ignored, and nothing ever uses `CXX`. Proton's lsteamclient has 219 `.cpp` unix sources. Fed to makedep as-is, they would be compiled as PE C sources, and `lsteamclient.so` would link with no objects. So:

- `steam/build/fetch_lsteamclient.sh` stages a **PE-only view** at `$PP_WORK/steam/extra-dlls/lsteamclient/`: Proton's `Makefile.in` without `UNIXLIB` and without the `.cpp` sources, plus the C sources, headers and spec. Pass **`--extra-dll-dir $PP_WORK/steam/extra-dlls`** to `build_wine.sh`.
- After `build_wine.sh`, run **`steam/build/build_lsteamclient.sh unix collect`** with the same `PP_WORK`. It compiles the C++ unix half with `clang++ -arch x86_64 -std=c++17`, links it against `$PP_WORK/build/wine/dlls/ntdll/ntdll.so`, checks it is unsigned, and writes `$PP_WORK/steam/out/{lsteamclient.dll,lsteamclient.so,SHA256SUMS,build-info.txt}`.
- Then `build/add_builtin.sh <runtime> $PP_WORK/steam/out/lsteamclient.{dll,so}`.

In `mac-runtime.yml` that comes to three extra steps: fetch before `build_wine`, then unix+collect and `add_builtin` before `assemble_runtime`/`verify_runtime`. Please add them, or tell us where to put them.

The other route is a makedep patch adding C++ support, as Proton's Wine has. That is a runtime patch, and we don't need it.

### R2. Keep `ntdll.so` reachable for Mode B (SDK)

Linking `lsteamclient.so` needs the `ntdll.so` of the same `RUNTIME_ID`. §2.1 B says "built modules removed" from the SDK. Please either:

- keep `build/wine/dlls/ntdll/ntdll.so` in `peakpack-wine-sdk-*.tar.xz`, or
- confirm that the runtime tarball's `lib/wine/x86_64-unix/ntdll.so` is the same file. Our draft workflow takes it from there via `NTDLL_SO`.

### R3. Mode B without a reconfigure

`./config.status --recheck` in the SDK tree reruns configure. That needs the dependency prefix (`$PP_WORK/deps/x86_64`) and the same llvm-mingw path, and the SDK has neither. `build_lsteamclient.sh pe` therefore defaults to **`PE_MODE=makedep`**:

1. add `dlls/lsteamclient` to `SUBDIRS` in `build/wine/Makefile`;
2. run `tools/makedep -C` in `build/wine`;
3. run `make dlls/lsteamclient/all`.

This needs only `tools/makedep`, `winegcc`/`winebuild`, the headers, the import libs, and llvm-mingw on `PATH`. It is untested until the first SDK exists. Please check that the SDK's top `Makefile` still has `SUBDIRS` and that `tools/makedep` is present. If you prefer, `PE_MODE=reconfigure` runs your documented §2.1 B sequence.

### R4. Launch and environment contract

- The front end launches PEAK through our launcher:

  ```
  wine 'C:\Program Files (x86)\Steam\peakpack_steam_launcher.exe' [--connect-lobby <id>] -- 'C:\Games\PEAK\PEAK.exe' -force-d3d11 [Doorstop args]
  ```

  On first use it can run the copy at `Z:<runtime>/share/peakpack/steam/peakpack_steam_launcher.exe`. Without `--forwarder-src`, the launcher installs `steamclient64.dll` from its own folder into `C:\Program Files (x86)\Steam\` in the prefix, and rewrites its registry keys on every launch. **No prefix setup is needed from you.**
- Please add `STEAM_COMPAT_CLIENT_INSTALL_PATH` to `pp-env.sh`, or let the front end export it. It is the unix directory of the Mac Steam client's `steamclient.dylib`. Default: `$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS`. Set it in the environment of the bash that `exec`s wine. Our patched lsteamclient falls back to that same default when the variable is unset.
- Never put `lsteamclient`, `steamclient64` or `steam_api64` in `DllOverrides` or `WINEDLLOVERRIDES`.
- The launcher refuses to write the registry outside Wine (it detects `wine_get_version`). It stays alive as the advertised Steam pid while PEAK runs, and returns PEAK's exit code. Its own error codes are 120–124.

### R5. Lint

`mac-runtime-lint.yml` skips `mac/runtime/steam/`. Our scripts pass `bash -n` and `shellcheck -S warning`; the one SC2046 is in `tests/mac/t12_memsample.sh` and is intended. Please include `mac/runtime/steam/**/*.sh` in the lint, or we add `mac-steam-bridge-lint` to our proposal.

### R6. Question: `patches/wine/optional/0001-ntdll-load-unixlibs-RTLD_GLOBAL.patch`

Is it meant for the Steam overlay or for lsteamclient? Our bridge does not need it: lsteamclient dlopens `steamclient.dylib` with `RTLD_NOW` itself.

## Resolutions (lead, 12 Oct 2026)

- **R1, Mode A in CI: done.** Joshua approved pushing this to `jmproulx/peakpack`. `mac-runtime.yml` has a `steam_bridge` input (default true) that builds the bridge in the same job and Wine tree. Steps, in order:
  1. `fetch_lsteamclient.sh` runs before *Prepare sources*.
  2. `prepare_sources.sh` gets `--extra-dll-dir $GITHUB_WORKSPACE/_work/steam/extra-dlls`; `build_wine.sh --no-prepare` then builds `lsteamclient.dll` in-tree.
  3. After DXMT: `build_lsteamclient.sh unix collect`, the forwarder, launcher and probes (llvm-mingw from `_work/tools`), `verify_forwarder.py` and `package_bridge.sh`. The CI fails if the bridge package contains any source file.
  4. The package is unpacked into `_work/stage/steam`. `assemble_runtime.sh` merges it into the runtime: `lsteamclient.{dll,so}`, `share/peakpack/steam/*` and the licence texts. It drops the i386 `lsteamclient.dll` and refuses source files.

  The bridge and test-kit tarballs are attached to the same `mac-build-runtime-*` prerelease. `add_builtin.sh` stays the tool for out-of-tree (Mode B) builds.
- **R2/R3, Mode B (SDK):** not used for the first runs. `make_sdk.sh` now **excludes `src/wine/dlls/lsteamclient` and `build/wine/dlls/lsteamclient`**, and refuses to pack if any lsteamclient file is left, so Valve's sources never reach the published SDK. `ci/mac-steam-bridge.yml` (Mode B) stays a local draft and is not pushed.
- **R4:** `pp-env.sh` exports `STEAM_COMPAT_CLIENT_INSTALL_PATH`, defaulting to the Mac Steam client folder; a value already set is kept. No `lsteamclient`/`steamclient64`/`steam_api64` overrides are set anywhere.
- **R5:** `mac-runtime-lint.yml` lints `mac/runtime/steam/**/*.sh` too, and py-compiles `verify_forwarder.py`. Two intentional findings got inline directives: SC2034 in `tests/mac/lib.sh` (used by the scripts that source it) and SC2046 in `t12_memsample.sh`.
- **R6:** the optional `0001-ntdll-load-unixlibs-RTLD_GLOBAL` patch is not needed by the bridge. It stays opt-in and off by default.
- **Licence:** MIT is approved for our own code under `mac/` (`docs/LICENSE-PeakPack-steam.txt`).
