# Tuning matrix for gate G-A2 (and the G-A3 soak)

*12 Oct 2026, runtime team. Run on the 8 GB M1/M2 test Mac in the `peaktest` user (DESIGN §9). Every knob below can be changed without rebuilding: an env var through `pp-env.sh`, a prefix script, or a Unity argument.*

## 1. Pass/fail (from DESIGN §7)

**Route:** main menu → Base Camp → 5 min on the Shore at 1440×900 with the Mac preset (MacPreset plugin). Metal HUD on (`PP_HUD=1`). `prefix/pp-sample.sh` samples memory every 10 s.

| Gate | Pass when | Fail → |
|---|---|---|
| **G-A2** | Average fps **≥ 90 %** of CrossOver 26 (DXMT) on the same Mac, settings and route. **1 % low ≥ 30 fps.** Memory pressure **never red** (`memory_pressure` free % stays above the red threshold; record the minimum). **No crash in 30 min** | Sweep the axes below one at a time; then try DXVK and MoltenVK; then investigate the delta to CrossOver's DXMT build |
| **G-A3** | 30-min soak + 3 biome transitions: **0 crashes**, **swap growth < 1 GB** (`swap_used_mb` last minus first) | Rebuild variants (DXMT B, `PP_PE_TOOLCHAIN=mingw-gcc`), then report |

**Procedure:**
1. Run the baseline R0 three times.
2. Change **one** knob per row, three runs each.
3. Keep any change that improves average fps by more than 3 % or the 1 % low by more than 2 fps, with no new crash and no worse memory.
4. Then re-run the combination.

**Record per run:** row ID, runtime ID (manifest), DXMT commit, macOS build, average fps and 1 % low (Metal HUD; screenshots every 30 s if no frame-time log), minimum free %, swap growth, crash yes/no, notes.

The Metal HUD's file logging (`MTL_HUD_LOG_ENABLED`) is UNVERIFIED on macOS 15/26. If it works, use it for 1 % lows. Otherwise, record a 60 s screen capture of the HUD graph per run.

## 2. Baseline R0

| Knob | R0 value | Set by |
|---|---|---|
| Backend | `dxmt` (DXMT v0.80, our build) | `pp-backend.sh` |
| Unity args | `-force-d3d11 -screen-width 1440 -screen-height 900 -screen-fullscreen 1 -window-mode borderless` (PeakPack adds `-force-d3d11` from `platforms.mac.extraArgs`) | PeakPack / front end |
| Sync | msync (`WINEMSYNC=1`) | `PP_SYNC` |
| DXMT frame limiter | `d3d11.preferredMaxFrameRate = 60` | `prefix/dxmt.conf` |
| Retina | `RetinaMode=n`, 96 DPI | `reg/10-macdriver.reg`, `reg/00-base.reg` |
| Logging | `WINEDEBUG=-all`, `DXMT_LOG_LEVEL=none` | `pp-env.sh` normal mode |
| Rosetta AVX | not advertised | `PP_AVX=0` |
| In-game | Mac preset (RenderScale 0.8 STP, shadows low, AO off, FPS cap 60…) | MacPreset plugin |

## 3. Axes

| Row | Axis | Values to try (R0 first) | How | Why / expected |
|---|---|---|---|---|
| **R1** | Graphics backend | `dxmt` · `dxvk` · `dxvk-nodxgi` · `wined3d` (diagnostic only) · CrossOver 26 (benchmark) · D3DMetal (only if the friend imported GPTK; never shipped) | `pp-backend.sh <rt> <pfx> <backend>`; for Vulkan through MoltenVK also try `-force-vulkan` instead of `-force-d3d11` with the `wined3d` backend set | DXMT is the measured best path on 8 GB M1 (≈60 fps Medium in CrossOver) |
| **R2** | DXMT version | v0.80 (MIT, R0) · `main` ≥ `e40c9d7a` (LGPL; #220 LUT fix) · upstream prebuilt `dxmt-v0.80-builtin.tar.gz` (A/B for our build) | Rebuild with `DXMT_COMMIT`/`DXMT_TAG` in `pins.env` (bump `PP_REVISION`), or swap the files in `lib/peakpack/dxmt` for the A/B | Black or garbled post-processing points to #220 |
| **R3** | Sync primitive | `msync` · `esync` · `none` | `PP_SYNC=…` | One report of a rare Steam hang with msync; Whisky advises `WINEMSYNC=0` on Wine 11.15+ (we are on 11.0). Watch `wineserver_cpu` in the CSV |
| **R4** | Render resolution / upscaling | 1440×900 (R0) · 1280×800 · 1680×1050 · 1152×720 + MetalFX (`DXMT_METALFX_SPATIAL_SWAPCHAIN=1`, `PP_DXMT_CONFIG="d3d11.metalSpatialUpscaleFactor=1.25"`) | `-screen-width/-screen-height`; env through the front end | Unified memory and GPU bound on the M1 Air |
| **R5** | Unity render threading | default · `-force-gfx-direct` (single-threaded rendering) · `-force-d3d11-singlethreaded` · `-force-d3d11-no-singlethreaded` (notpop's choice) | Extra args | Rosetta makes the CPU side costlier; gfx jobs may hurt or help. (`-force-gfx-jobs` is not in the Unity 6000.3 docs; skip it) |
| **R6** | Window mode | `-screen-fullscreen 1 -window-mode borderless` (R0) · `-window-mode exclusive` · `-screen-fullscreen 0` (windowed 1440×900) | Extra args | Exclusive fullscreen under winemac may capture displays (`CaptureDisplaysForFullscreen` defaults to off). Also watch Cmd-Tab behaviour |
| **R7** | Rosetta AVX | off (R0) · `PP_AVX=1` (`ROSETTA_ADVERTISE_AVX=1`) | env | Burst and Unity may pick AVX paths. Whether this macOS release supports it is UNVERIFIED: check that PEAK still starts and compare CPU-bound scenes |
| **R8** | Frame cap | DXMT 60 + game 60 (R0) · DXMT off (`PP_DXMT_CONFIG="d3d11.preferredMaxFrameRate=0"`) + game 60 · both off | `dxmt.conf` / `PP_DXMT_CONFIG` | Pacing on 60 Hz panels; double limiting can stutter |
| **R9** | DXMT shader cache | on (R0) · `DXMT_SHADER_CACHE=0` | env | First-run stutter (the cache lives in `prefix/peakpack/dxmt-cache`) |
| **R10** | Mac preset | on (R0) · off (PC defaults) | MacPreset plugin | Bounds the preset's contribution |
| **R11** | Wine PE toolchain | llvm-mingw (R0) · mingw-gcc build | `PP_PE_TOOLCHAIN` + rebuild | Only if crashes or stalls point at core DLLs (winecx-gptk saw a Steam stall with llvm-built kernelbase) |

## 4. Functional checks to run during the sweep (not perf)

| ID | Check | Pass when | Fallback |
|---|---|---|---|
| **K1** | Keyboard profile (PEAK.exe Mac Driver keys): left ⌘ = Ctrl, left ⌥ = Alt, right ⌘ = Alt | Crouch/sprint/mod hotkeys work; ⌘+Q does not quit mid-climb; ⌥+Return toggles fullscreen; Companion host Ctrl+F9 works as ⌃+F9 and ⌘+F9 (fn may be needed) | Wine default profile: delete the four values from `AppDefaults\PEAK.exe\Mac Driver` |
| **K2** | macOS shortcuts | ⌘-Tab leaves and returns without a black window; Mission Control works | `WindowsFloatWhenInactive`, `-window-mode` variants (R6) |
| **A1** | Audio out + **built-in mic** (Photon Voice) | Voice both ways with Joshua (G-X1). The front end's `Info.plist` has `NSMicrophoneUsageDescription`, and the macOS prompt was accepted | Note AirPods (HFP drops output to 16 kHz); recommend the built-in mic |
| **D1** | File-change notifications (libinotify → `ReadDirectoryChangesW`) | AutoReload reloads a plugin DLL replaced by `--hot-update` (G-D3) | `MONO_MANAGED_WATCHER`, Companion-triggered reload (DESIGN §3.4) |
| **V1** | Video / Media Foundation | No `mfplat`/`winegstreamer` errors in a logs-mode run (`pp-run.sh --logs`); any in-game videos play | Rebuild with GStreamer (sources in the CX tarball) |
| **F1** | Fonts | Menus and chat render (Unity ships its own fonts; PeakPack is headless) | Install fonts in the prefix only if glyphs are missing |
| **S1** | Retina / scaling | The game fills the screen at 1440×900, mouse mapping is correct, nothing is blurry beyond the expected upscale | `RetinaMode=y` + 192 DPI as an experiment only (memory cost) |

## 5. Rows already decided (don't re-test unless something changes)

- `WINEDEBUG=-all` for perf runs (logs mode only for diagnosis).
- `wined3d` is never a shipping option.
- No D3D12 path: PEAK's D3D12 default goes through `-force-d3d11`. D3DMetal is the only DX12 route, and it is the friend's own import.
