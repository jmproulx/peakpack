# G-D2: PeakPack modded and vanilla launch

| | |
|---|---|
| Slot | 1 |
| Needs a human | only if Mac Steam is not running (exit 3). Then run H-STEAM first. |
| Expected run time | 20 min (timeout 45 min) |
| Requires | G-A1, G-B5 |
| Run by | `run_slot.sh` (slot 1) or by hand |

## Purpose

Runs PeakPack.exe (the latest pack release) headless inside the job's Wine prefix. It checks `--status` and `--sync`. Then it launches PEAK with the pack (modded) and checks that BepInEx loads every plugin with no load errors and that the main menu draws. Last, it launches PEAK without the pack (vanilla) and checks that BepInEx does not start.

## Preconditions

- Rosetta 2 is installed. Without it the gate is blocked.
- Mac Steam is running and signed in under the fleet user. Otherwise the gate exits needs-human.
- G-A1 has passed. It provides the runtime. The prefix is created if it is missing.
- G-B5 has passed. PEAK must be in `$JOB/game/PEAK`.
- The Steam launcher and forwarder, `peakpack_steam_launcher.exe` and `steamclient64.dll`, are in the runtime's `share/peakpack/steam` folder. They are copied into `$JOB/bridge`.
- Network access to github.com for PeakPack.exe, from `releases/latest/download/PeakPack.exe`. `PP_PEAKPACK_URL` overrides the URL. A PeakPack.exe already in `$JOB/downloads` is reused.
- Optional: `expect/pack-plugins.txt` in the kit lists plugin names that must load. Without it the named-plugin check is skipped.

## Command

```sh
cd "$JOB/kit"
bash testkit/run_gate.sh G-D2 --job-dir "$JOB" [-- <args>]
```

| Argument | Default | What it does |
|---|---|---|
| `--expect-plugins FILE` | `expect/pack-plugins.txt` | File of plugin names that must load, one per line. Blank lines and lines starting with `#` are ignored. |
| `--sync-timeout S` | 900 | Time limit for the `--sync` run, in seconds. |
| `--launch-timeout S` | 600 | How long to wait for BepInEx's "Chainloader startup complete" line and PEAK's Steam line. The launch calls themselves are capped at 300 s. |

## What the script does

1. Starts the gate. Blocks if Rosetta 2 is missing. Exits needs-human if Mac Steam is not running. Starts caffeinate (process assertion only).
2. Checks the runtime (blocked if not). Runs `ensure_tests`, but a failure there is not fatal. Checks the launcher and forwarder in `$JOB/bridge` (blocked if not). Creates the prefix if needed (error if that fails). Checks that PEAK is in the prefix (blocked if not). Downloads PeakPack.exe (blocked if that fails).
3. Places PeakPack.exe at `C:\users\<user>\AppData\Local\PeakPack\PeakPack.exe` in the prefix. An existing file there is not replaced. Records `peakpack_placed`.
4. Copies the launcher and `steamclient64.dll` into `drive_c\PeakPackTests`. Sets Wine stop as the cleanup step.
5. Runs `PeakPack --headless --status --game-dir 'C:\Games\PEAK'` with a 300 s limit. Wine runs with `WINEDLLOVERRIDES=winhttp=n,b` for PeakPack calls only. The status JSON is copied when PeakPack writes one. Records `pp_status`. A non-zero exit ends the gate as fail.
6. Runs `--headless --sync` with the `--sync-timeout` limit. If it exits 3 (a foreign mod loader is in the game folder), it runs `--sync --adopt` (logged as `sync-adopt`) and uses that exit code. Records `pp_sync`. A failure ends the gate as fail.
7. Checks that `BepInEx.Preloader.dll` exists in the profile. Lists the plugin DLLs to `profile-plugin-dlls.txt` and records the count.
8. Modded launch: starts the Steam launcher in hold mode in the background (no launch, held for up to 1,500,000 ms), waits 8 s. Runs `--headless --launch --launch-method direct` with a 300 s limit. Records `launch_modded`. A failure ends the gate as fail.
9. Checks that the launch command line contains `-force-d3d11`. If it does, records `mac_extra_args` as pass. If not, records it as info, which is not a fail.
10. Waits up to `--launch-timeout` for `Chainloader startup complete` in BepInEx's `LogOutput.log`, written after the launch.
11. Waits 20 s and takes the screenshot `peak-modded-menu-script`. Then asks the agent for the main-menu check (`CU-modded`, 180 s). This runs even if step 10 failed.
12. Copies the modded `LogOutput.log` and Player.log, then stops Wine.
13. Reads the modded log. Takes the expected plugin count from the "N plugins to load" line and the loaded count from the "Loading [...]" lines. Writes `plugins-loaded.txt`, `bepinex-errors.txt` and `all-error-lines.txt`. Records the metrics.
14. Records `all_plugins` and `no_load_errors`. Then checks each name in the expect file for a "Loading [name " line, recording `expected_plugins`. Steps 13 and 14 only run if the log file exists.
15. Maps the agent's answer to `modded_menu`.
16. Vanilla launch: notes the modification time of `LogOutput.log`, waits 2 s, and starts the launcher again. Runs `--headless --launch --vanilla --launch-method direct` with a 300 s limit (`launch_vanilla`). Waits up to `--launch-timeout` for `Steam runtime manager initialized` in a new Player.log (`vanilla_started`). Takes `peak-vanilla-menu` after 15 s. A failure here does not end the gate.
17. Stops Wine. Checks that `LogOutput.log` was not changed (`vanilla_no_bepinex`). Checks that the vanilla Player.log has no BepInEx, Doorstop or Chainloader lines (`vanilla_player_log`).
18. Copies PeakPack's `log.txt` to `logs/G-D2/peakpack-log.txt`.

## Computer-use steps

### CU-modded

When the request appears: after step 11, the request is written to `$JOB/cu/G-D2.modded.request`. It appears whether or not the BepInEx line was seen. Watch for it with `bash testkit/cu.sh "$JOB" wait`.

Steps:

1. Look at the screen. Modded PEAK should be running, started by PeakPack.
2. Wait for the main menu to be fully drawn.
3. Note any mod notice or version text, for example from PeakPack or a companion mod.
4. Take the screenshot (command below).
5. Answer ok if the main menu works. Answer fail with what is wrong if the screen is black, crashed or stuck. Do not click in PEAK. The request text says the script quits PEAK.

Screenshots:

```sh
bash testkit/cu.sh "$JOB" shot G-D2 peak-modded-main-menu
```

The script also takes `peak-modded-menu-script` before the request.

Timeout: 180 s. An answer after that is not counted, and the criterion becomes skip.

Answers:

```sh
bash testkit/cu.sh "$JOB" done G-D2.modded ok "main menu works; <any mod notice or version text>"
bash testkit/cu.sh "$JOB" done G-D2.modded fail "<what is wrong>"
```

## Pass / fail criteria

| Criterion id | Check | Pass when |
|---|---|---|
| peakpack_placed | PeakPack.exe in C:\users\<u>\AppData\Local\PeakPack | Always recorded as pass when reached. The file is copied in, or was already there. |
| pp_status | PeakPack --headless --status under Wine | Exit code 0. Otherwise fail, and the gate ends. |
| pp_sync | PeakPack --headless --sync | Exit code 0. After an exit 3 retry with `--adopt`, that exit code counts. Otherwise fail, and the gate ends. |
| profile | profile has BepInEx core | `BepInEx.Preloader.dll` exists in the profile. |
| launch_modded | PeakPack --launch (modded, direct) | Exit code 0. Otherwise fail, and the gate ends. |
| mac_extra_args | Mac extra args from the signed manifest (-force-d3d11) | The launch command line contains `-force-d3d11`. Otherwise info, which is not a fail. |
| bepinex_started | BepInEx chainloader complete | `LogOutput.log` was rewritten after the launch and contains "Chainloader startup complete" within `--launch-timeout`. |
| all_plugins | every plugin BepInEx found was loaded | The loaded count is at least the "N plugins to load" count, and above 0. |
| no_load_errors | no BepInEx load errors | No BepInEx error or fatal line, no "Could not load", "Skipping" or "Error loading" line, and no "missing dependenc" or "incompatible" text. |
| expected_plugins | every plugin in pack-plugins.txt loaded | Each listed name appears as "Loading [name ". Skipped when there is no expect file. |
| modded_menu | modded PEAK reaches the main menu (agent) | The agent answers ok. Fail on a fail answer. Skip on skip or timeout. |
| launch_vanilla | PeakPack --launch --vanilla | Exit code 0. |
| vanilla_started | vanilla PEAK started (new Player.log, Steam initialised) | Player.log contains "Steam runtime manager initialized" within `--launch-timeout`. |
| vanilla_no_bepinex | vanilla launch did not start BepInEx (LogOutput.log untouched) | The modification time of `LogOutput.log` is unchanged. |
| vanilla_player_log | no BepInEx/Doorstop lines in the vanilla Player.log | The vanilla Player.log has no BepInEx, Doorstop or Chainloader text. |

Overall status:

- Any failed criterion makes the gate fail (exit 1). The status, sync and modded-launch failures end the gate at once.
- Otherwise it passes (exit 0) if at least one criterion passed. Info and skip do not fail it.
- Blocked (exit 2): Rosetta 2 missing, runtime missing, launcher or forwarder missing, PEAK missing, or PeakPack.exe cannot be downloaded.
- Needs-human (exit 3): Mac Steam is not running.
- Error (exit 4): prefix creation failed, or a timeout or signal from `run_gate.sh`.

## Results and evidence

- `$JOB/results/G-D2.json`: status, exit_code, reason, timings, versions, criteria, metrics, computer_use (the modded answer), evidence, human, notes.
- Versions: `peakpack_app`, `pack_revision`, `peakpack_exe_sha256`, `runtime_id`, `runtime_built_at`, `steam_tests`.
- Metrics: `status_exit`, `peakpack_app_version`, `sync_exit`, `installed_revision`, `plugin_dlls`, `launch_modded_exit`, `launch_modded_cmdline`, `launch_vanilla_exit`, `any_error_lines`, `plugins_to_load`, `plugins_loaded`, `bepinex_error_lines`, `bepinex_version`.
- `$JOB/logs/G-D2/`: `console.log`; for each PeakPack call, `<name>.out` and `<name>.status.json` (`status`, `sync`, `sync-adopt` if used, `launch-modded`, `launch-vanilla`); `launcher-modded.out`, `launcher-vanilla.out`; `LogOutput-modded.log`; `Player-modded.log`; `Player-vanilla.log`; `profile-plugin-dlls.txt`; `plugins-loaded.txt`; `bepinex-errors.txt`; `all-error-lines.txt`; `peakpack-log.txt`; and `cu-modded.answer.txt` (when answered).
- `$JOB/evidence/G-D2/`: `peak-modded-menu-script.png` (script), `peak-modded-main-menu.png` (agent), `peak-vanilla-menu.png` (script).

## Copy back

- `results/G-D2.json`.
- All of `logs/G-D2/`, especially `LogOutput-modded.log` and the Player logs.
- `evidence/G-D2/*.png`.
- The `cu/G-D2.modded.*` request and answer files.
- Or run `bash testkit/collect.sh "$JOB"`.

## Paths outside the job dir

- `/tmp/.wine-<uid>/server-*`: the Wine server socket of the prefix. `cleanup.sh` removes it.
- Everything else is inside `$JOB/prefix`: PeakPack.exe and its profile under `AppData\Local\PeakPack`, the `PeakPackTests` folder, the LocalLow Player.log, and the `Games\PEAK` link to `$JOB/game/PEAK` (inside the job dir).
- PeakPack.exe is downloaded into `$JOB/downloads`.
- Mac Steam: the gate only checks that the Steam process is running. Its own code does not read or write Steam's files.

## If it fails or is blocked

- Needs-human, Mac Steam not running: run H-STEAM, then re-run G-D2.
- Blocked, launcher or forwarder missing: the runtime's `share/peakpack/steam` folder is incomplete. Check the runtime from G-A1.
- Blocked, PeakPack.exe not downloaded: check the network to github.com, or set `PP_PEAKPACK_URL`.
- Blocked, PEAK missing: run G-B5 first.
- Error, prefix creation failed: read `logs/G-D2/create-prefix.log`.
- Fail, `pp_status`: read `logs/G-D2/status.out` and `status.status.json`.
- Fail, `pp_sync`: exit 3 is retried with `--adopt`. A fail after that means the foreign loader was not adopted. Read `logs/G-D2/sync.out` and `sync-adopt.out`. The script reads `Problem.Heading` from the status JSON.
- Fail, `launch_modded`: read `logs/G-D2/launch-modded.out` and its status JSON.
- Fail, `bepinex_started`: the detail shows the last three lines of `LogOutput.log`. Read `logs/G-D2/LogOutput-modded.log`.
- Fail, `all_plugins` or `no_load_errors`: read `plugins-loaded.txt`, `bepinex-errors.txt` and `all-error-lines.txt`.
- Fail, `expected_plugins`: the detail lists the missing names.
- Fail, `modded_menu`: check the screenshot and the agent's note.
- Fail, `vanilla_no_bepinex`: the vanilla launch rewrote `LogOutput.log`. Check the live file at `prefix/drive_c/users/<user>/AppData/Local/PeakPack/profile/BepInEx/LogOutput.log`.
- Fail, `vanilla_player_log`: read `logs/G-D2/Player-vanilla.log` and find the BepInEx, Doorstop or Chainloader lines.
- Info, `mac_extra_args`: `-force-d3d11` was not on the launch command line. This is not a failure.
