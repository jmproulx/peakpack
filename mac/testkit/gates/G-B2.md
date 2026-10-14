# G-B2: Steam bridge in Wine (T3-T5)

| | |
|---|---|
| Slot | 1 |
| Needs a human | only if Mac Steam is not running (exit 3). Then run H-STEAM first. |
| Expected run time | 10 min (timeout 30 min) |
| Requires | G-A1, G-B5 |
| Run by | `run_slot.sh` (slot 1) or by hand |

## Purpose

Runs the Steam team's T3-T5 bridge test inside the runtime's Wine. The test kit script is run unchanged. T3 checks that the Steam forwarder logs on and gets a real SteamID and auth ticket. T4 checks that PEAK's own `steam_api64.dll` initialises Steam. T5 starts PEAK and checks its Player.log. The agent then confirms the main menu is drawn on screen.

## Preconditions

- Rosetta 2 is installed. Without it the gate is blocked.
- Mac Steam is running and signed in under the fleet user. Otherwise the gate exits needs-human.
- G-A1 has passed. It provides the runtime. The prefix is created if it is missing.
- G-B5 has passed. PEAK must be in `$JOB/game/PEAK`.
- The Steam test kit `t3_t5_wine_bridge.sh` is available, from the release tarball or the kit's `runtime/steam/tests` copy.
- Bridge files are present. They are copied into `$JOB/bridge`: `steamclient64.dll` and `peakpack_steam_launcher.exe` from the runtime, `steam_client_probe.exe` and `steam_api_probe.exe` from the test kit, and `lsteamclient.dll` and `lsteamclient.so` from the runtime.

## Command

```sh
cd "$JOB/kit"
bash testkit/run_gate.sh G-B2 --job-dir "$JOB" [-- <args>]
```

| Argument | Default | What it does |
|---|---|---|
| `--t5-seconds N` | 600 | Length of the T5 run. The script waits up to N minus 30 s for PEAK's Steam line in Player.log. PEAK logs that line only after its first scene has loaded, and on a cold prefix DXMT translates that scene's shaders first. Slot 1 passes 600. |

## What the script does

1. Starts the gate. Blocks if Rosetta 2 is missing. Exits needs-human if Mac Steam is not running. Starts caffeinate (process assertion only).
2. Checks that the runtime exists (blocked if not), the test kit has `t3_t5_wine_bridge.sh` (blocked if not), and the bridge files are in `$JOB/bridge` (blocked, with the missing names listed). Creates the prefix if needed (error if that fails). Checks that PEAK is in the prefix (blocked if not). The last step links `prefix/drive_c/Games/PEAK` to `$JOB/game/PEAK`.
3. Sets Wine stop as the cleanup step.
4. Starts `t3_t5_wine_bridge.sh --runtime <rt> --prefix <prefix> --bridge <bridge> --game 'C:\Games\PEAK' --t5 --t5-seconds N --logs logs/G-B2/t3_t5` in the background. Its output goes to `logs/G-B2/t3_t5.out`.
5. Waits for PEAK's Player.log to contain `Steam runtime manager initialized`. It waits up to N minus 30 s, and only accepts a log written after the launch started.
6. If the line appears, waits 20 s, takes the screenshot `peak-main-menu-script`, and asks the agent for the main-menu check (`CU-mainmenu`, 120 s). If the line does not appear, the script notes it and the `main_menu_render` check fails.
7. Waits for the T5 run to end, prints its output, and records its exit code.
8. Reads the PASS and FAIL lines for T3, T4 and T5. Each one becomes a criterion (see the table below). A check with no result line counts as fail.
9. If `logs/G-B2/t3_t5/t3.log` contains `native steamclient lacks`, writes that line into the notes.
10. Copies `t5_summary.txt` if it exists. Counts files under `logs/G-B2/wine/` whose paths mention d3d11, dxgi or dxmt.
11. Maps the agent's answer to `main_menu_render`.
12. Copies PEAK's Player.log to `logs/G-B2/Player.log` and records its line count.

## Computer-use steps

### CU-mainmenu

When the request appears: after the script sees PEAK's Steam line in Player.log, the request is written to `$JOB/cu/G-B2.mainmenu.request`. Watch for it with `bash testkit/cu.sh "$JOB" wait`. If the Steam line never appears, no request is made.

Steps:

1. Look at the screen. PEAK should already be running, started by the test.
2. Wait until the main menu is fully drawn: title art and buttons visible.
3. Take the screenshot (command below).
4. Check for a black screen, garbled colours or missing text.
5. Answer ok or fail. Do not click anything in PEAK. The request text says the script quits PEAK.

Screenshots:

```sh
bash testkit/cu.sh "$JOB" shot G-B2 peak-main-menu
```

The script also takes `peak-main-menu-script` 20 s after the Steam line, before the request.

Timeout: 120 s. An answer after that is not counted, and the criterion becomes skip.

Answers:

```sh
bash testkit/cu.sh "$JOB" done G-B2.mainmenu ok "main menu renders"
bash testkit/cu.sh "$JOB" done G-B2.mainmenu fail "<what is wrong>"
```

## Pass / fail criteria

| Criterion id | Check | Pass when |
|---|---|---|
| t3_load | T3 forwarder loads | Output has `PASS: T3: forwarder -> lsteamclient.dll/.so -> steamclient.dylib loads`. |
| t3_logged_on | T3 logged on | Output has `PASS: T3: logged on`. |
| t3_steamid | T3 SteamID | Output has `PASS: T3: real SteamID`. |
| t3_ticket | T3 ticket callback OK | Output has `PASS: T3: auth ticket`. |
| t4_restart | T4 RestartAppIfNecessary = false | Output has `PASS: T4: RestartAppIfNecessary false`. |
| t4_running | T4 IsSteamRunning = true | Output has `PASS: T4: IsSteamRunning true (launcher pid)`. |
| t4_init | T4 SteamAPI_InitEx OK | Output has `PASS: T4: SteamAPI_InitEx OK with PEAK's steam_api64.dll`. |
| t4_steamid | T4 SteamID | Output has `PASS: T4: real SteamID through steam_api64.dll`. |
| t4_appid | T4 app id 3527290 | Output has `PASS: T4: app id 3527290`. |
| t4_ticket | T4 ticket via manual dispatch | Output has `PASS: T4: ticket via manual dispatch`. |
| t5_player_log | T5 Player.log | Output has `PASS: T5: Player.log shows 'Steam runtime manager initialized: True' (+ persona)`. |
| main_menu_render | PEAK main menu renders (D3D11 -> DXMT, agent) | The agent answers ok. |

For the T3, T4 and T5 rows: a matching `FAIL:` line, or no result line, gives fail. For `main_menu_render`: a fail answer gives fail. If the Steam line never appeared, it is fail too ("PEAK did not get far enough"). A skip answer or a timeout gives skip.

Overall status:

- Any failed criterion makes the gate fail (exit 1).
- Otherwise it passes (exit 0). Skip does not fail it.
- Blocked (exit 2): runtime, test kit, bridge files, or PEAK in the job dir is missing.
- Needs-human (exit 3): Mac Steam is not running.
- Error (exit 4): prefix creation failed, or a timeout or signal from `run_gate.sh`.

## Results and evidence

- `$JOB/results/G-B2.json`: status, exit_code, reason, timings, versions, criteria, metrics, computer_use (the mainmenu answer), evidence, notes.
- Versions: `runtime_id`, `runtime_built_at`, `steam_tests`.
- Metrics: `t3_t5_exit`, `dxmt_log_files`, `player_log_lines`.
- `$JOB/logs/G-B2/`: `console.log`, `t3_t5.out` (wrapper output), `t3_t5/` (the test kit's own logs, including `t3/t3.log` and `t5/`), `t5_summary.txt` (copy, when present), `wine/` (Wine and DXMT logs), `Player.log` (copy), `cu-mainmenu.answer.txt` (when answered).
- `$JOB/evidence/G-B2/`: `peak-main-menu-script.png` (script), `peak-main-menu.png` (agent).

## Copy back

- `results/G-B2.json`.
- `logs/G-B2/`, especially `Player.log`, `t3_t5.out` and `t3_t5/`.
- `evidence/G-B2/*.png`.
- The `cu/G-B2.mainmenu.*` request and answer files.
- Or run `bash testkit/collect.sh "$JOB"`.

## Paths outside the job dir

- `/tmp/.wine-<uid>/server-*`: the Wine server socket of the prefix. `cleanup.sh` removes it.
- Everything else the Wine run writes is inside `$JOB/prefix`. The bridge files are in `$JOB/bridge`. The link `prefix/drive_c/Games/PEAK` points to `$JOB/game/PEAK`, which is also inside the job dir.
- Mac Steam: the gate only checks that the Steam process is running. Its own code does not read or write Steam's files. The wrapped `t3_t5_wine_bridge.sh` is not read here, so its file access is not listed.

## If it fails or is blocked

- Needs-human, Mac Steam not running: run H-STEAM, then re-run G-B2.
- Blocked, runtime missing: run G-A1 first.
- Blocked, test kit missing: the release has no test kit tarball and the kit has no `runtime/steam/tests` copy.
- Blocked, bridge files missing: the note lists the missing names. Check the runtime and the test kit's `probe/` folder.
- Blocked, PEAK missing: run G-B5 first.
- Error, prefix creation failed: read `logs/G-B2/create-prefix.log`.
- Fail, t3_* or t4_*: read `logs/G-B2/t3_t5.out` and `logs/G-B2/t3_t5/`. "no result line" means the test printed nothing for that check.
- Fail, `t5_player_log` or `main_menu_render` ("did not get far enough"): Steam's line was not in Player.log in time. Read `logs/G-B2/Player.log` and `t3_t5.out`.
- Skip, `main_menu_render`: no answer within 120 s. This is not a failure. A late answer is not counted.
- Note "native steamclient lacks": read `logs/G-B2/t3_t5/t3.log`.
