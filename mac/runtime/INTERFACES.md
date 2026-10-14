# Runtime interfaces (owned by the runtime team)

*v0.3, 12 Oct 2026. Owner: runtime team (`runtime/build`, `runtime/prefix`, `runtime/ci`, `runtime/docs`). Readers: the Steam team (`runtime/steam/`), the front-end team (Track D2), and main. Change requests: write them in the "Requests" section at the end; the runtime team folds them into the next version.*

This file is the contract between the Wine runtime build and everything that builds against it or launches it. Paths marked **stable** won't change without a version bump here.

## 0. Where things live in the repo (decision from main, 12 Oct 2026)

- **Repo:** the existing public repo `jmproulx/peakpack`. Mac work lives under `mac/`. Another agent owns everything outside `mac/` and the `mac-*` workflow files.
- **Our files in the repo:**
  - `mac/runtime/build/`, `mac/runtime/prefix/`, `mac/runtime/docs/`, `mac/runtime/INTERFACES.md`
  - `.github/workflows/mac-runtime.yml`
- **The Steam team's files:** `mac/runtime/steam/`, plus its own `mac-*` workflow if it needs one (for example `mac-steam-bridge.yml`).
- Locally on Joshua's PC, `C:\Users\joshu\PeakMods\MacPort\runtime\` maps to `mac/runtime/`. The workflow is drafted at `runtime\ci\workflows\mac-runtime.yml` and becomes `.github/workflows/mac-runtime.yml` when main pushes it.
- **Releases:**
  - Tags use the prefix `mac-build-*`.
  - Every release is a **prerelease** and is **never marked latest** (`make_latest: false`, or `gh release create --prerelease --latest=false`). Friends' `releases/latest/download/PeakPack.exe` link must keep resolving to the newest pack release.
  - Runtime tag: `mac-build-runtime-<RUNTIME_ID>` (see §1).

## 1. Runtime identity (stable)

`RUNTIME_ID = pp<N>-cx<CX_VERSION>`, for example **`pp1-cx26.3.0`**:

- `pp<N>`: our revision, bumped on any change to patches, configure flags, DXMT/DXVK/MoltenVK pins or bundled dylibs.
- `cx<CX_VERSION>`: the CodeWeavers CrossOver LGPL source release our Wine comes from (Wine 11.0 base, with msync).

**One `RUNTIME_ID` = one ABI.**
- lsteamclient (and any other builtin we add) must be built against the SDK of the same `RUNTIME_ID`.
- The signed manifest pins the runtime and the bridge together (DESIGN §5.5).

## 2. Build machine layout (CI and local Mac builds)

All build scripts take `PP_WORK` (default `$GITHUB_WORKSPACE/_work` on CI, `~/peakpack-build` locally).

| Path | What | Stable? |
|---|---|---|
| `$PP_WORK/src/wine/` | Patched CrossOver Wine source (`sources/wine` from the tarball plus `mac/runtime/build/patches/wine/*.patch`) | yes |
| `$PP_WORK/build/wine/` | **Configured out-of-tree Wine build** (configured as `../../src/wine/configure`, so `src/` and `build/` move together) | yes |
| `$PP_WORK/build/wine/tools/winegcc/winegcc` | winegcc (also invoked as `wineg++` through a symlink in the same dir) | yes |
| `$PP_WORK/build/wine/tools/winebuild/winebuild` | winebuild | yes |
| `$PP_WORK/build/wine/tools/widl/widl`, `tools/wrc/wrc`, `tools/wmc/wmc`, `tools/makedep` | other Wine tools | yes |
| `$PP_WORK/src/wine/include/`, `$PP_WORK/build/wine/include/` | Wine headers (source plus generated) | yes |
| `$PP_WORK/build/wine/dlls/<name>/<arch>-windows/lib<name>.a` | PE import libraries (`arch` = `x86_64` or `i386`) | yes |
| `$PP_WORK/dist/runtime/` | Assembled runtime (§3), before it is packed | yes |
| `$PP_WORK/deps/x86_64/` | x86_64 dependency prefix (freetype, gnutls and their deps), when built from source | internal |

Toolchain facts the Steam team needs:
- **Unix side:** `clang -arch x86_64` (Apple clang from Xcode or the CommandLineTools), `MACOSX_DEPLOYMENT_TARGET=11.0`.
- **PE side:** llvm-mingw (version pinned in `build/pins.env`), triplets `x86_64-w64-mingw32` and `i686-w64-mingw32`.
- **Configure flags:** recorded verbatim in `manifest.json` → `wine.configure_args` and in `$PP_WORK/build/wine/config.log`.

### 2.1 Two ways to build a builtin DLL against our Wine

**A. In-tree (preferred for lsteamclient; matches Proton).**
- Pass `--extra-dll-dir <DIR>` to `build/build_wine.sh`. It can be given more than once.
- Each `<DIR>/<name>/` must contain a Wine-style `Makefile.in` (`MODULE = <name>.dll`, `UNIXLIB = <name>.so`, `SOURCES = ...`) and its sources.
- The script copies `<DIR>/<name>` into `src/wine/dlls/<name>`, appends `WINE_CONFIG_MAKEFILE(dlls/<name>)` to `configure.ac`, runs `tools/make_makefiles` and `autoreconf`, configures, and builds it with the rest of Wine. `make install` then places it in the runtime automatically.
- The Steam team's CI job stages `<DIR>` (fetching the pinned Proton commit and verifying its hash) before calling our script. **Nothing under `<DIR>` is committed to the repo or published in our source tarball** (Steamworks SDK licence; see `docs/LICENSES.md`).

**B. Out-of-tree against the SDK artifact.**
- The release ships **`peakpack-wine-sdk-<RUNTIME_ID>.tar.xz`** (`build/make_sdk.sh`). It mirrors `$PP_WORK`, so **unpack it into the same `PP_WORK` path**: `tar -C "$PP_WORK" -xJf peakpack-wine-sdk-….tar.xz`. On GitHub-hosted runners of `jmproulx/peakpack` that is `$GITHUB_WORKSPACE/_work`. `config.status` records absolute paths to the deps prefix. Contents:

  ```
  src/wine/        patched source
  build/wine/      configured tree: Makefile, config.status, tools/ binaries (x86_64 macOS), include/,
                   every lib*.a import library; object files and built modules removed
  deps/x86_64/     headers + dylibs Wine was configured against (freetype, gnutls, inotify, MoltenVK)
  pins.env         toolchain pins used for this runtime (llvm-mingw version: put it first in PATH)
  manifest.json    same as the runtime's
  ```

- To add a module without rebuilding Wine:
  1. Copy the module to `src/wine/dlls/<name>`.
  2. Insert `WINE_CONFIG_MAKEFILE(dlls/<name>)` before the line `dnl End of auto-generated output commands` in `src/wine/configure.ac`. `tools/make_makefiles` would need a git checkout; `build/prepare_sources.sh` uses `awk` for this.
  3. Run `autoreconf -f` in `src/wine`.
  4. In `build/wine`, run `./config.status --recheck && ./config.status && make dlls/<name>/all`.
- Or call `tools/winegcc/winegcc` directly with `--winebuild tools/winebuild/winebuild -I../../src/wine/include -Iinclude`.
- **Recommendation:** use path A in CI. It is the same workflow pattern and has no path coupling.
- The **x86_64-unix `.so` must stay unsigned** (no `codesign`). `add_builtin.sh` and `verify_runtime.sh` enforce this.

### 2.2 Adding built files to a runtime

```
build/add_builtin.sh <runtime_dir> <file>...
```

| File | Goes to |
|---|---|
| `*.dll`, `*.exe` (Wine builtin PE, i.e. built by winebuild, which sets the builtin marker) | `<runtime>/lib/wine/x86_64-windows/` (or `i386-windows/` by PE machine type) |
| `*.so` (Mach-O x86_64 unixlib) | `<runtime>/lib/wine/x86_64-unix/` |

- The script checks the arch with `file` and `lipo`, refuses signed unixlibs, and adds each file's SHA-256 to `manifest.json → extra_builtins[]`.
- The **non-builtin** mingw forwarder `steamclient64.dll` is not a Wine builtin. Ship it under `<runtime>/share/peakpack/steam/` (the Steam team's choice of subdir), and copy it into the prefix at setup.

## 3. Runtime layout on the friend's Mac (stable)

Installed at `~/Library/Application Support/PeakPack/runtime/<RUNTIME_ID>/` (DESIGN §3.1). The tarball `peakpack-runtime-<RUNTIME_ID>-x86_64.tar.xz` unpacks to exactly this:

```
<RUNTIME_ID>/
  bin/wine                      Wine 11 loader (x86_64; WoW64, so also runs 32-bit PE)
  bin/wineserver
  bin/winecfg, bin/wineboot, …  helper scripts from make install
  lib/                          bundled third-party dylibs (freetype, gnutls+deps, MoltenVK, …); install names @rpath/…
  lib/wine/x86_64-unix/         Wine unixlibs (*.so) + winemetal.so (DXMT) [+ lsteamclient.so]
  lib/wine/x86_64-windows/      Wine builtin PE (64-bit) + winemetal.dll (DXMT) [+ lsteamclient.dll]
  lib/wine/i386-windows/        Wine builtin PE (32-bit, WoW64)
  lib/peakpack/dxmt/x86_64-windows/   DXMT d3d11.dll, dxgi.dll, d3d10core.dll (native-style; copied into the prefix)
  lib/peakpack/dxvk/x86_64-windows/   DXVK-macOS d3d11.dll, dxgi.dll, d3d10core.dll (fallback; copied into the prefix)
  share/wine/                   wine.inf, nls, fonts
  share/peakpack/prefix/        prefix scripts and .reg files (copy of mac/runtime/prefix)
  share/peakpack/steam/         steamclient64.dll (forwarder) + peakpack_steam_launcher.exe (§4.1)
  LICENSES/                     every licence text + NOTICE.md + SOURCES.md (LGPL source offer and links)
  manifest.json                 versions, pins, SHA-256 of every file (schema §5)
```

### 3.1 Prefix layout and ownership (stable)

`~/Library/Application Support/PeakPack/prefix/` is created by `prefix/pp-create-prefix.sh <runtime> <prefix> [backend]`. The script is idempotent and re-runs `wineboot --update` when the runtime ID changes.

**The prefix's Windows user is always `crossover`**, so `<u>` below is `crossover`.
- This comes from CrossOver Hack 12735 in `advapi32` `GetUserName`: it reports a consistent user name regardless of the Mac account. We never set `CX_REPORT_REAL_USERNAME`.
- The per-user folders are therefore `drive_c/users/crossover/…`: `AppData\Local\PeakPack`, `AppData\LocalLow\LandCrab\PEAK\Player.log` (PEAK's log and saves), and so on.
- Code that locates them should not use the Mac user name. Use `crossover`, or the only non-`Public` folder under `drive_c/users`.

| Path in the prefix | Owner | Notes |
|---|---|---|
| `drive_c/users/<u>/AppData/Local/PeakPack/PeakPack.exe` | PeakPack agent | **Must be exactly here.** PeakPack's self-update and the Companion's live-update launch depend on it (PeakPack DESIGN §18). It is not `C:\PeakPack`. |
| `drive_c/users/<u>/AppData/Local/PeakPack/profile/` | PeakPack | BepInEx + mods |
| `drive_c/Games/PEAK/` | front end / Steam team (game download) | Windows depot 3527291 |
| `drive_c/users/<u>/{Desktop,Documents,Downloads,Music,Pictures,Videos}` | runtime (prefix script) | **Real folders, not links to the Mac home.** This avoids TCC prompts, and nothing gets written outside the prefix. |
| `drive_c/windows/system32/{d3d11,dxgi,d3d10core,winemetal}.dll` | runtime (`pp-backend.sh`) | backend DLL set |
| `peakpack/prefix.json`, `peakpack/backend`, `peakpack/dxmt.conf`, `peakpack/dxmt-cache/` | runtime | stamp, backend choice, DXMT config and shader cache |
| `../logs/` | runtime + front end | Wine/DXMT logs in logs mode |

**Registry keys written by the runtime** (from `prefix/reg/*.reg`, ASCII REGEDIT4, applied with `wine reg import`):

| Key | Values |
|---|---|
| `HKCU\Software\Wine` | `Version=win10` |
| `HKCU\Software\Wine\DllOverrides` | `mscoree=""`, `mshtml=""`, `winemenubuilder.exe=""` (disabled) |
| `HKCU\Software\Wine\AppDefaults\PEAK.exe\DllOverrides` | `winhttp=native,builtin`. PeakPack writes the **identical** value before each launch, so either writer is fine. Backend values: `d3d11`, `dxgi`, `d3d10core` = `native,builtin` for dxmt/dxvk, removed for wined3d. |
| `HKCU\Software\Wine\Mac Driver` | `RetinaMode=n` (global-only key) |
| `HKCU\Software\Wine\AppDefaults\PEAK.exe\Mac Driver` | `LeftCommandIsCtrl=y`, `LeftOptionIsAlt=y`, `RightCommandIsCtrl=n`, `RightOptionIsAlt=n`, `WindowsFloatWhenInactive=none` |
| `HKCU\Software\Wine\Drivers` | `Audio=coreaudio` |
| `HKCU\Control Panel\Desktop` | `LogPixels=96` |

**Rule for anyone setting `WINEDLLOVERRIDES`** (PeakPack sets it for the processes it starts):
- **List only `winhttp`.** Never `d3d11`, `dxgi`, `d3d10core` or `winemetal`.
- Wine checks the env var per DLL before the AppDefaults registry key. A DLL named in the env var therefore loses its PEAK.exe registry setting, and listing a graphics DLL would silently switch the backend.

**PeakPack headless CLI** (for the front end and the Steam helper; owned by the PeakPack agent; listed here so launch paths stay consistent):
- `PeakPack.exe --headless --status | --sync [--adopt] | --launch [--vanilla] [--on-sync-fail stop|installed|vanilla] [--status-out F]`
- Exit codes: 0 ok, 1 failed, 2 no PEAK, 3 foreign loader, 4 PEAK running, 5 not installed.
- The signed manifest's `platforms.mac.extraArgs` is `["-force-d3d11"]`. The runtime adds no Unity arguments of its own. Tuning rows in `docs/TUNING.md` change only the extra args.

## 4. Environment the launcher sets (stable names)

The front end, or the Steam team's helper when it launches PEAK, builds the environment with **`prefix/pp-env.sh`** and does not hand-roll it: `source <runtime>/share/peakpack/prefix/pp-env.sh`, then `pp_env <runtime_dir> <prefix_dir> [backend]`.

| Var | Value | Why |
|---|---|---|
| `WINEPREFIX` | `~/Library/Application Support/PeakPack/prefix` | our bottle |
| `PP_RUNTIME` | the runtime dir | used by our scripts |
| `PATH` | `$PP_RUNTIME/bin:/usr/bin:/bin:/usr/sbin:/sbin` | so `wine`/`wineserver` resolve |
| `WINESERVER` | `$PP_RUNTIME/bin/wineserver` | pins the server binary |
| `WINELOADER` | `$PP_RUNTIME/bin/wine` | |
| `DYLD_FALLBACK_LIBRARY_PATH` | `$PP_RUNTIME/lib:/usr/lib` | Wine dlopens bare sonames (`libfreetype.6.dylib`, `libgnutls.30.dylib`, `libMoltenVK.dylib`); this is how it finds our bundled copies. **Set it in the process that execs `wine` directly.** SIP strips `DYLD_*` across `/bin/sh` and other protected binaries, so `pp-env.sh` is sourced by bash and then `exec`s `wine` |
| `WINEDEBUG` | `-all`; logs mode: `err+all,warn-all,fixme-all`; **`PP_WINEDEBUG` (if set) overrides both** (diagnostics/support) | perf |
| `WINEMSYNC` / `WINEESYNC` | `1`/`0`; knob `PP_SYNC=msync\|esync\|none` | Mach-semaphore sync (CrossOver's msync) |
| `WINEDLLOVERRIDES` | **Unset by `pp_env`.** During prefix creation only: `mscoree,mshtml=;winemenubuilder.exe=d`. At PEAK launch: only `winhttp=n,b`, set by PeakPack (see §3.1 rule) | the env var beats AppDefaults per DLL |
| `DXMT_LOG_LEVEL` / `DXMT_LOG_PATH` | `none`/`none`; logs mode: `info` / `<prefix>/../logs` | DXMT logging |
| `DXMT_CONFIG_FILE` | `$WINEPREFIX/peakpack/dxmt.conf` | frame limiter etc. (TUNING.md) |
| `DXMT_CONFIG` | from knob `PP_DXMT_CONFIG` (per-run `key=value;…`), else unset | tuning rows |
| `DXMT_SHADER_CACHE_PATH` | `$WINEPREFIX/peakpack/dxmt-cache` | keeps the cache inside our folder |
| `MTL_HUD_ENABLED` | knob `PP_HUD` (`0`/`1`, menu: Show FPS) | Metal HUD |
| `ROSETTA_ADVERTISE_AVX` | knob `PP_AVX=1` sets it; default unset | TUNING.md row R7 |
| `STEAM_COMPAT_CLIENT_INSTALL_PATH` | default `~/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS` (dir of Mac Steam's `steamclient.dylib`); an existing value is kept | lsteamclient loads the Mac client from here |
| `SteamAppId`, `SteamGameId` | set by `peakpack_steam_launcher.exe` (3527290) for itself and the game | §5.3 of DESIGN |

**Paths:** `pp_env` and every prefix script canonicalise `<runtime_dir>` and `<prefix_dir>` to absolute paths (the prefix dir is created if missing). Wine child processes start in another working directory, so relative paths are not supported.

**GUI session (required):** Wine's Mac driver needs the logged-in user's GUI (Aqua) session. A process started from Finder/the Dock (the front-end app) has it; a remote shell (SSH, `launchctl managername` = `Background`) does not, and then every window fails ("nodrv_CreateWindow: The graphics driver is missing", explorer fails). Prefix creation itself works headless but logs those errors.

**Graphics backend selection:**
- Run `prefix/pp-backend.sh <dxmt|dxvk|wined3d>`. It copies the chosen DLL set into `drive_c/windows/system32`, then writes or removes `HKCU\Software\Wine\AppDefaults\PEAK.exe\DllOverrides`.
- This is per prefix and persistent, so the launcher does not pass it per run.
- Default: `dxmt`.

### 4.1 `peakpack_steam_launcher.exe` (Steam bridge launcher; runs inside Wine)

```
wine 'C:\…\peakpack_steam_launcher.exe' [--appid 3527290] [--steam-dir 'C:\Program Files (x86)\Steam'] [--client-dll …]
    [--forwarder-src …] [--no-install] [--steam-client-dir /Users/…/MacOS] [--language english]
    [--connect-lobby <id>] [--cwd …] [--log WINPATH] [--dry-run] [--registry-root Software\PeakPackTest [--delete-test-root]]
    [--no-launch [--hold-ms N] [--hold-until-exit IMAGE]] [--keep-registry] [--no-warmup] [--version]
    --  <game.exe> [game args…]
```

- It installs the forwarder at `<steam-dir>\steamclient64.dll`, advertises itself as the running Steam (`ActiveProcess\pid`), sets `SteamAppId`/`SteamGameId`, starts the game, waits, and resets `pid`/`Running` at exit.
- **Exit code:** the game's. The launcher's own codes: 120 usage, 121 refused (outside Wine), 122 registry, 123 launch, 124 install, **125 game never started** (`--hold-until-exit` timeout).
- Arguments after `--` reach the game unchanged. A first argument `steam://…` is logged and ignored (exit 0).
- **Auth-ticket warm-up (launcher 0.2.0, runtime pp2 and later; pp1 ships 0.1.0 without it).**
  - Before starting the game, the launcher requests and cancels one auth session ticket exactly as PEAK does. This guards PEAK's one-shot EOS login against a cold Steam client.
  - It takes at most ~5 s on a cold client and ~0.1 s on a warm one, and logs `warm-up:` lines.
  - It never runs with `--dry-run`, `--registry-root`, `--no-warmup`, or outside Wine.
  - Front ends need do nothing. Pass `--no-warmup` only for tests that measure a cold request.
- **Hold mode (launcher 0.2.0, runtime pp2 and later):** `--no-launch --hold-until-exit PEAK.exe [--hold-ms N]`. It is for a front end that starts the game itself.
  - After the warm-up, the launcher stays alive as the advertised Steam.
  - It waits up to `--hold-ms` (default 120000) for a process with that image name (case-insensitive) to **appear**, then until it **exits**. Then it resets `pid`/`Running` and exits **0**.
  - If the process never appears it exits **125**.
  - It logs a `hold:` line at each transition: waiting, started (pid), exited, timeout, done.
  - `--hold-until-exit` without `--no-launch` is a usage error (120).
- **Feature detection (key on this per runtime):**
  - `manifest.json` → `"launcher": {"version": "0.2.0", "features": ["warmup", "hold-until-exit"], "warmup": true, "holdUntilExit": true}`. It is read from markers embedded in the launcher binary.
  - **A missing `launcher` key or `holdUntilExit: false` means launcher 0.1.0 (pp1): no hold mode and no warm-up.**
  - The same values are in the release's `BUILD-STATUS.txt` as `launcher_version=`, `launcher_warmup=yes|no` and `launcher_hold_until_exit=yes|no`.
  - At run time, `peakpack_steam_launcher.exe --version` prints `PPLAUNCHER-VERSION:<v> PPLAUNCHER-FEATURES:<list>`. Launcher 0.1.0 rejects `--version` (exit 120).

## 5. `manifest.json` schema (v1)

```json
{
  "schema": 1,
  "runtime_id": "pp1-cx26.3.0",
  "built_at": "<UTC ISO8601>",
  "builder": {"runner": "macos-15-intel", "xcode": "...", "macos": "...", "workflow_run": "<url>"},
  "wine": {"source": "crossover-sources-26.3.0.tar.gz", "source_sha256": "...", "wine_version": "11.0",
           "patches": [{"file": "...", "sha256": "..."}], "configure_args": "...", "msync": true,
           "winemac_default_visibility": true},
  "components": {"dxmt": {"version": "...", "sha256_src": "...", "licence": "..."},
                 "dxvk": {...}, "moltenvk": {...}, "freetype": {...}, "gnutls": {...}},
  "toolchain": {"llvm_mingw": "...", "dxmt_llvm": "...", "meson": "...", "bison": "..."},
  "files": {"bin/wine": "<sha256>", "...": "..."},
  "extra_builtins": [{"path": "lib/wine/x86_64-unix/lsteamclient.so", "sha256": "...", "from": "steam team build id"}]
}
```

## 5a. Released runtimes

| Runtime ID | Release (prerelease, never latest) | Contents / status |
|---|---|---|
| `pp1-cx26.3.0` | `mac-build-runtime-pp1-cx26.3.0` (commit 168a11e, CI run 38366553896) | Wine 11 (CrossOver 26.3 sources) + DXMT 0.80 + DXVK fallback + Steam bridge; launcher 0.1.0. On the M1 iMac: G-A1 (D3D11 via DXMT, 57 fps probe) and G-B1 pass |
| `pp2-…` | not built yet | Batched: launcher 0.2.0 (auth-ticket warm-up, `--hold-until-exit`, `--version`, manifest `launcher` block), plus the first computer-use slot's findings (DESIGN §1). `PP_REVISION` is bumped in `build/pins.env` |

The test-kit-side packages are separate prereleases: Steam tests `mac-build-steam-tests-<ver>` and kit tags `mac-testkit-<ver>` (git tags only).

## 6. Requests / open items

- *(Steam team, resolved)* lsteamclient ships **x86_64 only**; `assemble_runtime.sh` drops the in-tree i386 PE.
- *(Steam team, resolved)* The subdirectory is `share/peakpack/steam/`. It holds `steamclient64.dll` and `peakpack_steam_launcher.exe`.
- *(front end)* `NSMicrophoneUsageDescription` must be in the front-end app's `Info.plist`. Wine runs as a child of the app, so TCC attributes the mic request to the app.
