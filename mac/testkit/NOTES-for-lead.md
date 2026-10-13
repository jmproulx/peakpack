# Test kit: requests to other owners, and open questions

*From the test-kit sub-lead, 12 Oct 2026. The kit only reads the runtime, Steam, prefix and DESIGN files; it never changes them. Everything below is a request for their owners or for Joshua.*

## Requests

| # | To | Request | Why / what the kit does meanwhile |
|---|---|---|---|
| **R1** | CI (runtime workflow) | Build `testkit/probes/d3d11_clear.c` and ship it as `probe/d3d11_clear.exe` in `peakpack-steam-tests-*.tar.xz`. The proposed step is below | G-A1's D3D11-over-DXMT proof. The check is "skip" until the exe ships, and PEAK's main menu in G-B2 serves as the DXMT proof meanwhile |
| **R2** | Steam team + CI | Add a prebuilt **macOS x86_64** `steam_client_probe` to the tests tarball as `probe/steam_client_probe-macos-x86_64`. Build it on the macOS runner with `clang -arch x86_64 -O1 -Wall` | G-B1 without the Xcode CLT. `t1_t2_rosetta_probe.sh` compiles with `clang` and calls `lipo`, and both are CLT shims that pop up an install dialog. The kit runs the prebuilt binary with the same checks when the CLT are absent; without either, G-B1 is *blocked* |
| **R3** | Steam team | Optional: an option on `peakpack_steam_launcher.exe` to stay alive until a named process (`PEAK.exe`) exits, for example `--no-launch --hold-until-exit PEAK.exe` | For B2, PeakPack starts PEAK itself (`--launch-method direct`), so the launcher must keep advertising the Steam pid. The kit now uses `--no-launch --hold-ms <long>` and kills it afterwards. The front end needs a clean version of this (see Q-F1) |
| **R4** | main (repo) | In `.gitattributes`, add `*.json`, `*.md`, `*.awk` and `*.manifest` with `text eol=lf`. Commit every `mac/**/*.sh` with the exec bit (`git update-index --chmod=+x`) | `expect/*.manifest` is compared byte for byte, and the JSON is parsed by awk. The kit already strips `\r` and always runs scripts with `bash`, so this is hygiene, not a blocker |
| **R5** | main | Commit `mac/testkit/` **before** the CI run that creates the `mac-build-runtime-*` tag. Alternatively, publish `peakpack-mac-testkit-<ver>.tar.gz` as a release asset | The hub takes the kit from `archive/refs/tags/<tag>.tar.gz → peakpack-<tag>/mac/testkit`. If the tag predates the kit, the hub needs another source |
| **R6** | PeakPack agent | (a) Publish `PeakPack.exe.sha256` with each pack release. (b) Confirm that `--headless --launch --launch-method direct --game-dir 'C:\Games\PEAK' --status-out …` is supported together. (c) Confirm the status-file key casing: the kit reads camelCase and falls back to PascalCase. (d) Has `PeakPack.exe` (.NET single-file) ever run under real Wine 11 x86_64? G-D2 is the first time | G-D2 records the SHA-256 but cannot verify it |
| **R7** | PeakPack agent | Provide `testkit/expect/pack-plugins.txt`: the BepInEx plugin names (as BepInEx logs them, "Loading [Name x.y.z]") that the current pack revision must load | G-D2 already checks that "N plugins to load" equals the number loaded and that there are no load errors. The name list makes "all pack plugins loaded" exact. Without it the criterion is "skip" |
| **R8** | runtime team | `pp-create-prefix.sh` calls `"$here/pp-backend.sh"` directly, so it needs the exec bit. Please call it with `bash`. `verify_runtime.sh` needs the CLT on the Mac (`lipo`, `otool`, `nm`, `strings`, `python3`) | The kit sets `chmod +x` on its own unpacked copy, and runs `verify_runtime.sh` only when the CLT are present |
| **R9** | lead (DESIGN) | Bring DESIGN §9 and TUNING.md in line with the hub model: user `fleet` instead of `peaktest`, no SSH, the hub does the computer use, and the job dir is cleaned instead of deleting the user | The kit follows the hub model, which is binding |
| **R10** | lead / Joshua | **G-C0 phase b converter environment on the Mac** (decision needed). `native/pm.py` needs Python 3.11 or newer, UnityPy 1.25.4, lz4 and `spirv-cross`. The CLT's `python3` is **3.9**, so even with the CLT the converter cannot run. Options: (1) the hub provides a Python 3.11+ environment and points `PP_CONVERTER_PYTHON`/`PEAKMETAL_SPIRV_CROSS` at it; (2) CI publishes a self-contained converter build for macOS arm64 (our MIT code plus UnityPy (MIT), lz4 (BSD) and SPIRV-Cross (Apache-2.0); no Landfall data); (3) a pip venv inside the job dir, which downloads from PyPI on the test Mac | The kit only detects and reports. Phase b becomes "skip" with the exact missing pieces, and phase a still runs |
| **R11** | lead | Confirm that `native/` becomes `mac/native/` in the repo. G-C0 looks for `$PP_KIT_DIR/../native/pm.py` | — |
| **R12** | MacPreset / A3 | An fps logger: once a second, write `fps=<n> frametime_ms=<x>` to LogOutput.log (or to a file in the profile) while the Mac preset is active | Makes G-A2 fully scriptable, with exact 1 % lows and no HUD reading by the agent. Today G-A2-lite takes HUD readings from the agent every 30 s. `MTL_HUD_LOG_ENABLED` is unverified on macOS 15/26 |
| **R13** | Steam team | The PEAK `Player.log` markers that the kit uses beyond T5 (measured from Joshua's Windows 2.6.b log): main menu `Loaded Server Settings` / `Photon StartPeerCreated` / `Has Valid Quicksave`; lobby `Update current scene: Airport`; island `Update current scene: Level_1`. Please keep these in mind if you add log checks | Used by G-A2-lite (detects reaching the Shore) and G-C0 (main-menu markers) |

### R1: proposed CI step (mac-runtime.yml, "Steam bridge" step, after the probes)

```yaml
          # G-A1 D3D11/DXMT probe (test kit); goes into the tests tarball's probe/ folder
          x86_64-w64-mingw32-clang -O2 -Wall -Wextra -o "$pe/d3d11_clear.exe" mac/testkit/probes/d3d11_clear.c \
            -ld3d11 -ldxgi -ldxguid -luser32
          # G-B1 without Xcode CLT: macOS x86_64 build of the Steam team's probe
          clang -arch x86_64 -O1 -Wall -o "$pe/steam_client_probe-macos-x86_64" mac/runtime/steam/tests/probe/steam_client_probe.c
```

`package_bridge.sh` would then add these two files, next to the existing probes, to the tests tarball:

```sh
cp "$pe/d3d11_clear.exe" "$pe/steam_client_probe-macos-x86_64" "$troot/probe/"
```

Checked on this PC: the probe builds warning-free with Zig 0.17 (`zig cc -target x86_64-windows-gnu -O2 -Wall -Wextra … -ld3d11 -ldxgi -ldxguid -luser32`). On Windows (RTX 3080 Ti) it gives `device=ok`, flip-discard, FL 11_1, `readback_ok=1`. It reports:

- `d3d11_wine_builtin`: Wine's "Wine builtin DLL" marker at offset 0x40;
- `winemetal_loaded`;
- the adapter name.

On the Mac, "native-style `d3d11.dll` and `winemetal.dll` loaded" proves that DXMT handled the D3D11 calls. G-A1 runs it as `PEAK.exe`, so the production PEAK.exe-scoped DllOverrides apply.

## Open questions for the hub

1. **Background runs.** Can the machine-running agent start a command in the background and keep polling? `run_slot.sh` and the gates wait on CU answers (`cu.sh <job> wait`). If not: run gates one by one, and pre-answer CU steps before starting the gate (`cu.sh done` works before a request exists). The G-B5 download is the long one.
2. **Screenshots.** May the scripts use `screencapture -x` under the hub's tooling (its screen-recording grant)? The kit saves screenshots to `evidence/<gate>/` with `cu.sh shot`. If the agent's own screenshots cannot be saved as files, please copy them back named as in the gate docs.
3. **Mac Steam.** Is Steam installed under `fleet`, and has it been started once (bootstrapped)? H-STEAM reports *blocked* when Steam.app is missing; the hub installs it.
4. **Rosetta and CLT.** P0 reports both. Without Rosetta, everything except P0, H-STEAM and G-B0 is blocked. Without the CLT, G-B0 and G-B1 use fallbacks: G-B1 needs R2 or the CLT.
5. **Network.** Slot 1 downloads about 2.5 GB: the 1.93 GB depot through Steam, plus the runtime tarball and the test kit from GitHub. Slot 4 adds the 725 MB Unity pkg.
6. **Display.** The Mac must stay unlocked and awake during the slot. The kit runs `caffeinate`, but it cannot unlock the screen. PEAK runs fullscreen-borderless at 1440×900, and the Metal HUD must be readable on the 4.5K panel.
7. **Steam console.** G-B5 runs `open 'steam://open/console'` only if Steam is already running; it never starts Steam. If the hub prefers to do this itself, set `PP_OPEN_CONSOLE=0`.
8. **Keeping files between slots.** Slot 4 (G-C0) needs the depot again. Either keep slot 1's job dir (`cleanup.sh --keep-job-dir`) or repeat G-B5. The slot-4 file repeats G-B5.
9. **Slot 3 timing.** Slot 3 (G-X1, H-MIC) needs Joshua at the iMac and the pilot friend online; schedule it with them.

## Decisions for Joshua (relayed by the lead)

- **G-X1 accounts.** DESIGN §7 says "Mac (a friend's own Steam account) + Joshua's Windows PC". That means the friend signs in to Steam on Joshua's iMac. The kit recommends the reverse: Mac on Joshua's account (already signed in), the friend on their own Windows PC. It tests the same Mac↔Windows path and no credentials change hands. Is that OK?
- **Xcode CLT** on the iMac (optional). It gives G-B0 its exact `nm` export check and lets G-B1 build its probe, unless R2 lands.
- **CrossOver trial** for G-A2-CX (optional; G-A2's "≥ 90 % of CrossOver" criterion stays "skip" without it).
- **Converter environment for G-C0 phase b** (R10).

## Known limits of the kit (by design)

- **G-B0 without the CLT** checks the export *names* in the x86_64 slice. It does not parse the export trie. This is marked `method: fallback` in the result.
- **H-STEAM** (13 Oct, kit 0.2.0): no longer reads any Steam login or config file (hub rule). It checks only that `steam_osx` is running, with an optional screenshot by the agent (`--confirm-window`). G-B1's `BLoggedOn` is the login proof, and G-B1 no longer requires H-STEAM.
- **G-A2-lite's fps** comes from the agent reading the Metal HUD every 30 s. That is coarse, and the lowest reading stands in for the 1 % low. "Memory pressure never red" uses `kern.memorystatus_vm_pressure_level` (4 = critical), sampled every 10 s.
- **G-B5's exact comparison** needs a reference manifest for the same PEAK version. The shipped one is 2.6.b, build 25739797, made read-only with the Steam team's `depot_manifest.sh` on Joshua's install. After a PEAK update, regenerate it: `bash runtime/steam/tests/depot_manifest.sh 'D:/SteamLibrary/steamapps/common/PEAK' testkit/expect/peak-win-<version>-build<id>.manifest`.
- **G-C0's assembly recipe is v0**: it uses the Windows Mono class libraries and the Mac `UnityEngine.*`. Track C owns refinements. Phase b follows the converter README: loose files, with no `data.unity3d`; `--bundle-variant` also tries the repacked archive.

## Resolved (lead, 12 Oct 2026)

- **R6** (PeakPack agent, FriendInstaller DESIGN §18.8): (a) pack releases since app 0.4.2 carry `PeakPack.exe.sha256`; `ensure_peakpack` now verifies against it (mismatch = fail; absent = recorded as unverified). (b) the combined `--headless --launch --launch-method direct --game-dir … --status-out …` command is supported. (c) the status file is camelCase only; the PascalCase fallback in G-D2 is removed. (d) PeakPack.exe has never run under real Wine; G-D2 is the first run (watch single-file extraction, schannel TLS, the ntdll lookup, the HKCU\Software\Wine write; fallback is a multi-file build).
- **R7**: `expect/pack-plugins.txt` regenerated for pack revision 5 (adds `PeakPack MacPreset`) with `PeakPack.Cli expect-plugins --platform mac`.
- **R1/R2, R4, R5, R8, R9, R12** done (CI probes, LF/exec rules, kit committed before any runtime tag, pp-backend via bash, hub model in DESIGN/TUNING, MacPreset frame-time log). **R3** (launcher hold-until-exit) and the **R10** converter bundle are backlog items.
