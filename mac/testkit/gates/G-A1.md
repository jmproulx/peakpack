# G-A1: Runtime boots

| | |
|---|---|
| Slot | 1 |
| Needs a human | no |
| Expected run time | 20 min (timeout 45 min) |
| Requires | P0 |
| Run by | `run_slot.sh` (slot 1) or by hand |

## Purpose

Checks that the PeakPack runtime downloads and matches the release's SHA256SUMS, then unpacks. Creates a Wine prefix inside the job dir with DXMT, and checks that cmd, reg and regedit work in it. If the D3D11 probe exe is available, it also checks that a D3D11 test renders through DXMT. Without the probe, that check is skipped and the DXMT proof moves to G-B2 and G-D2.

## Preconditions

- Rosetta 2 is installed. The kit never installs it. Without it the gate is blocked.
- **The gate runs inside the logged-in GUI (Aqua) session of the macOS user.** `launchctl managername` must print `Aqua`. From a remote shell (`Background`), Wine's Mac driver cannot open windows: Wine logs "nodrv_CreateWindow: The graphics driver is missing", explorer fails and no D3D11 device can be made. The gate then ends **blocked (exit 2)** right after its diagnostics.
  - Ways to start the kit inside the session:
    - Terminal on the desktop.
    - From the remote shell: write the command into `$JOB/run.command`, run `chmod +x` on it, then `open -a Terminal $JOB/run.command`.
    - `launchctl asuser $(id -u) /bin/bash -c '...'`, if the hub may use it.
  - `PP_ASSUME_GUI=1` overrides the check, for diagnostics only.
- github.com is reachable for SHA256SUMS and the release assets. `PP_ASSETS_DIR` can point to files already downloaded; they are still checked against SHA256SUMS.
- P0 has passed. P0 expects at least 12 GB free (20 GB recommended).
- Optional: Xcode Command Line Tools and the kit's `../runtime/build/verify_runtime.sh`. With both, the static runtime check runs. Without them it is skipped.
- Optional: the `d3d11_clear.exe` probe, passed with `--probe` or found in one of the folders listed below.

## Command

```sh
cd "$JOB/kit"
bash testkit/run_gate.sh G-A1 --job-dir "$JOB" [-- <args>]
```

| Argument | Default | What it does |
|---|---|---|
| `--probe PATH` | Searched (see below) | Path to `d3d11_clear.exe`. If not given, the script looks in this order: `$TESTS/probe/` (Steam test kit), `$PP_KIT_DIR/probes/out/`, `$PP_KIT_DIR/probes/`. |
| `--keep-wine` | off | Skips the final Wine stop at gate end, so the prefix's wineserver keeps running after the probe step. The script still stops Wine once after step 4. |

## What the script does

1. Starts the gate. Stops if not on macOS. Reads the two options. Blocks if Rosetta 2 is missing. Starts caffeinate (process assertion only).
2. Downloads SHA256SUMS and records it (criterion `sums`). Blocks if it cannot be fetched.
3. Downloads the runtime tarball, checks its SHA-256 against SHA256SUMS, and unpacks it to `$JOB/runtime/<id>`. A mismatch renames the file to `.bad` and ends the gate as error.
4. Checks that the manifest and the Steam test kit are present. Missing items give a warning only.
5. Runs `wine --version` and records it. Records the runtime size.
6. Checks that six runtime files exist (the `rt_*` criteria).
7. If the Xcode CLT, the runtime `manifest.json` and `verify_runtime.sh` are all present, runs `verify_runtime.sh`. Otherwise it skips and names the missing item. `kit-only-download` means only `testkit/` was unpacked; unpack all of `mac/` from the kit archive.
7b. Mac driver diagnostics, recorded before anything needs a window:
   - metrics `gui_session` (`launchctl managername`), `windowserver_running`, `console_user` and `run_user`;
   - with the CLT, every load command of `winemac.so` is resolved on this Mac (`winemac_links`; `logs/G-A1/winemac-links.txt`).
   - Not in a GUI session: blocked (exit 2).
   - Then `PP_WINEDEBUG=err+all,warn+module,warn+macdrv,+winediag,+loaddll` is set for the prefix boot and the probe.
8. Creates the prefix in `$JOB/prefix` with the runtime's `pp-create-prefix.sh` (backend dxmt). Output goes to `logs/G-A1/create-prefix.log`. If this fails, the gate ends as fail.
9. Checks the prefix: `system.reg` exists, the prefix stamp says backend dxmt, `system32\d3d11.dll` is the same file as the runtime's DXMT copy, and the user's Desktop, Documents and Downloads folders are real folders (not links to the Mac home). Records the prefix size.
9b. Classifies the Mac driver in the boot log (`macdrv_boot`; excerpt in `logs/G-A1/macdrv-boot-excerpt.txt`):
   - `ok`: `winemac.drv` loaded;
   - `unixlib-load-failed`: `winemac.so` failed to load;
   - `no-driver`: nodrv_CreateWindow, typically no GUI session;
   - `not-loaded`.
   The probe run is classified the same way (`macdrv_probe`, `macdrv-probe-excerpt.txt`).
10. Runs `cmd /c ver`.
11. Runs `reg query` on the PEAK.exe DllOverrides key and the Mac Driver key.
12. Runs `regedit /E` on `HKCU\Software\Wine`, then checks the export contains the PEAK.exe AppDefaults. The export is copied to the logs and deleted from the prefix.
13. Stops Wine.
14. Looks for the probe. If none is found, records `d3d11_render` as skip and ends the gate.
15. Copies the probe into the prefix as `PeakPackTests\dxprobe\PEAK.exe` (so the PEAK.exe overrides apply). Runs it with 600 frames at 1280 x 720 and holds for 8 s. Takes a screenshot 8 s after the start.
16. Reads the `RESULT key=value` lines the probe prints and checks device, readback, DXMT loading and presentation.
17. Writes the results JSON.

## Computer-use steps

None.

The script takes its own screenshot, `evidence/G-A1/d3d11-probe-window.png`, about 8 s after the probe starts. This only happens when the probe runs. `PP_SNAP=0` turns screenshots off.

## Pass / fail criteria

| Criterion id | Check | Pass when |
|---|---|---|
| sums | SHA256SUMS downloaded | The file downloads. If it cannot, the gate is blocked instead. |
| runtime_asset | runtime tarball verified and unpacked | The SHA-256 matches SHA256SUMS. A mismatch or missing file ends the gate as error. |
| manifest_asset | manifest verified | The manifest matches. If it is missing the result is warn, not fail. |
| tests_asset | Steam test kit available | The test kit is found. If it is missing the result is warn, not fail. |
| wine_version | wine --version | Output starts with `wine-`. |
| rt_lsteamclient.so | runtime has lib/wine/x86_64-unix/lsteamclient.so | File exists. |
| rt_lsteamclient.dll | runtime has lib/wine/x86_64-windows/lsteamclient.dll | File exists. |
| rt_steamclient64.dll | runtime has share/peakpack/steam/steamclient64.dll | File exists. |
| rt_peakpack_steam_launcher.exe | runtime has share/peakpack/steam/peakpack_steam_launcher.exe | File exists. |
| rt_d3d11.dll | runtime has lib/peakpack/dxmt/x86_64-windows/d3d11.dll | File exists. |
| rt_winemetal.dll | runtime has lib/wine/x86_64-windows/winemetal.dll | File exists. |
| verify_runtime | verify_runtime.sh (static) | The script exits 0 ("ALL PASS"). Skipped without CLT or the repo files. |
| prefix_create | pp-create-prefix.sh created the prefix in the job dir | The script exits 0. On failure the gate ends as fail. |
| wineboot | wineboot wrote system.reg | `system.reg` exists in the prefix. |
| prefix_stamp | prefix stamp: backend dxmt | `peakpack/prefix.json` contains `"backend": "dxmt"`. |
| dxmt_installed | system32/d3d11.dll is DXMT's | The prefix file is byte-identical to the runtime's DXMT `d3d11.dll`. |
| sandbox | user shell folders are real folders | Desktop, Documents and Downloads are not symlinks. |
| cmd_ver | wine cmd /c ver | Output contains "Windows". |
| reg_winhttp | PEAK.exe winhttp=native,builtin | The PEAK.exe override query has winhttp with `native,builtin`. |
| reg_d3d11 | PEAK.exe d3d11=native,builtin (DXMT) | The PEAK.exe override query has d3d11 with `native,builtin`. |
| reg_retina | Mac Driver RetinaMode=n | The Mac Driver query has a RetinaMode line with an `n` after it (a loose text match). |
| regedit | regedit /E export contains the PEAK.exe AppDefaults | The export contains `AppDefaults\PEAK.exe`. |
| d3d11_render | D3D11 renders through DXMT | Only ever recorded as skip, when no probe is found. |
| d3d11_device | D3D11 device + swap chain | The probe prints `device=ok`. |
| d3d11_readback | cleared colour reads back | The probe prints `readback_ok=1`. |
| d3d11_dxmt | DXMT handled it (native-style d3d11.dll + winemetal.dll loaded) | The probe prints `d3d11_wine_builtin=0` and `winemetal_loaded=1`. |
| d3d11_present | all frames presented | The probe prints `present_failures=0`. |

Overall status:

- Any failed criterion makes the gate fail (exit 1). A failed `prefix_create` also ends as fail, not error.
- Otherwise it passes (exit 0) if at least one criterion passed. Skip, warn and info results do not fail it.
- If nothing passed or failed, the status is error (exit 4).
- Blocked (exit 2): Rosetta 2 missing, or SHA256SUMS cannot be downloaded.
- Error (exit 4): runtime tarball missing or SHA-256 mismatch. Also a timeout or signal from `run_gate.sh`.

## Results and evidence

- `$JOB/results/G-A1.json`: status, exit_code, reason, timings, versions, criteria, metrics, computer_use (empty here), evidence, notes.
- Versions: `wine`, `runtime_id`, `runtime_built_at`, `steam_tests`.
- Metrics: `wine_version`, `runtime_mb`, `prefix_create_s`, `wine_user`, `prefix_mb`, `probe_sha256`, `probe_exit`, `adapter`, `feature_level`, `fps`, `frames`, `swap_effect`, `d3d11_path`, `dxmt_log_files`, `dxmt_proof` (`probe`, or `deferred` when skipped).
- `$JOB/logs/G-A1/`: `console.log`, `SHA256SUMS`, `curl.log`, `verify_runtime.log` (if run), `create-prefix.log`, `cmd.err`, `cmd-ver.txt`, `reg-peak-overrides.txt`, `reg-macdriver.txt`, `regedit-export-hkcu-wine.reg`, `d3d11-probe.out`, `d3d11-probe.txt`, and `wine/` (Wine and DXMT logs from the probe run).
- `$JOB/evidence/G-A1/`: `d3d11-probe-window.png` (only when the probe runs).

## Copy back

- `results/G-A1.json`.
- All of `logs/G-A1/`.
- `evidence/G-A1/*.png`.
- Or run `bash testkit/collect.sh "$JOB"`, which bundles every gate's results, logs and evidence.

## Paths outside the job dir

- Read only: `/Library/Apple/usr/share/rosetta/rosetta` (existence check) and `arch -x86_64 /usr/bin/true` (Rosetta check).
- `/tmp/.wine-<uid>/server-*`: the Wine server socket of the prefix. `cleanup.sh` removes it.
- Everything else is inside the job dir: the prefix (`$JOB/prefix`), the runtime (`$JOB/runtime`), downloads (`$JOB/downloads`) and logs.

## If it fails or is blocked

- Blocked, `gui_session`: started from a remote shell. Start the kit inside the desktop session (see Preconditions) and re-run.
- Fail, `winemac_links` or `macdrv_boot = unixlib-load-failed`: `winemac.so` does not load on this macOS. This is a runtime bug. Send `winemac-links.txt` and `macdrv-boot-excerpt.txt` to the lead.
- Fail, `macdrv_boot = no-driver` inside an Aqua session: send `macdrv-boot-excerpt.txt` and `create-prefix.log` to the lead.
- Blocked, Rosetta 2 missing: the kit never installs it. Report it to the lead. Do not install it.
- Blocked, SHA256SUMS not reachable: check the network to github.com and the release tag (`PP_RELEASE`, or the default in `common.sh`). Re-run.
- Error, runtime tarball missing or SHA-256 mismatch: a bad file is renamed `.bad` in `$JOB/downloads`. Check `logs/G-A1/console.log`, then re-run.
- Fail, `prefix_create`: read `logs/G-A1/create-prefix.log`. The console also prints its last 40 lines.
- Fail, `cmd_ver`, `reg_*`, `regedit` or `sandbox`: read the matching text files in `logs/G-A1/`.
- Fail, `d3d11_*`: read `logs/G-A1/d3d11-probe.txt` and `logs/G-A1/wine/`. The probe's RESULT lines show where it failed, for example `create_hr`.
- Skip, `d3d11_render`: no probe was found. This is not a failure. The DXMT proof then comes from the G-B2 main-menu check.
