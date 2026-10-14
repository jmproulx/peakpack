# G-APP3: PEAK (Modded).app daily launch to the main menu

| | |
|---|---|
| Slot | app (slot-app.job.json) |
| Needs a human | no |
| Expected run time | 10 min (timeout 20 min, see APP-README.md) |
| Requires | G-APP2 |
| Run by | `run_slot.sh` (slot-app) or by hand |

## Purpose

Starts the app the way a Dock click does: no `--no-autoplay`. After setup the app starts modded PEAK at once. The gate checks that PEAK runs, that Steam is initialised in its Player.log, and that the main menu draws (agent). Then PEAK is ended from its main menu, as a friend would, and the app must quit by itself.

## Preconditions

- G-APP2 has passed: setup is done (phase `done`) and the app is quit.
- A logged-in GUI session. Rosetta 2 installed.
- Mac Steam running and signed in under the fleet user (the app's Steam init needs it).
- A PEAK process started by an earlier run is stopped first (the gate stops the app's prefix).

## Command

```sh
cd "$JOB/kit"
bash testkit/run_gate.sh G-APP3 --job-dir "$JOB" -- --app-release mac-build-app-0.1.1
```

| Argument | Default | What it does |
|---|---|---|
| `--app-release TAG` | `$PP_APP_RELEASE`, else the job's `APP_RELEASE` | The release tag. |
| `--start-timeout S` | 300 | How long the app has to reach phases `launching` and `playing`. |
| `--main-menu-timeout S` | 600 | How long the agent has to answer CU-mainmenu. |

## What the script does

1. Checks the preconditions: the app's phase is `done` or `ready` (else blocked). Stops PEAK from an earlier run.
2. Starts the app with `open -n ... --args --data-dir $JOB/appdata --skip-update-check --uninstall-to $JOB/uninstalled` and no `--no-autoplay`.
3. Waits for phase `launching`, then `playing` (each within the start timeout). Records the time to `playing`.
4. Waits up to 120 s for a `PEAK.exe` process.
5. Waits up to 240 s for `Steam runtime manager initialized: True` in the new `Player.log` (rewritten after the launch). Copies it to `logs/G-APP3/Player-daily.log`. Notes "Successfully got user token" or "Failed to authenticate" (a warning only).
6. Records the app's phase 6 s after `playing` (the window hides about 4 s after `playing`; nothing is clicked).
7. Computer-use step CU-mainmenu.
8. Computer-use step CU-quit. If PEAK is still running after 60 s, the script runs `wineserver -k` on the app's prefix (`END_METHOD=wineserver`).
9. Checks the app exits by itself within 60 s after PEAK is gone (quits it if not).
10. Checks the status: `lastLaunch` is `modded`, and there is no problem.

## Computer-use steps

### CU-mainmenu

When the request appears (`$JOB/cu/G-APP3.mainmenu.request`, timeout 600 s):

1. Waits until PEAK's main menu is fully drawn (no loading screen). The app's window is hidden; PEAK is the window to look at.
2. Does not click anything in PEAK. If a macOS microphone prompt appears, does not click Allow or Don't Allow. Takes it as `dialog-1` and says so.
3. Takes `peak-main-menu-app`.
4. Answers ok, or fail with what it shows.

Screenshot: `bash testkit/cu.sh "$JOB" shot G-APP3 peak-main-menu-app`

Answer: `bash testkit/cu.sh "$JOB" done G-APP3.mainmenu ok "main menu drawn"` or `... fail "<what you see>"`.

### CU-quit

When the request appears (`$JOB/cu/G-APP3.quit.request`, timeout 60 s):

1. In PEAK, uses the main menu's Quit button and confirms if PEAK asks.
2. Does not click anything else and no macOS prompt.
3. Answers ok when PEAK is gone.

Answer: `bash testkit/cu.sh "$JOB" done G-APP3.quit ok "PEAK quit from the menu"`.

If there is no answer within 60 s, the script stops the app's Wine prefix (wineserver -k). This is the fallback, and it is recorded in the criterion detail.

## Pass / fail criteria

| Criterion id | Check | Pass when |
|---|---|---|
| daily_launching | app enters phase launching | Phase `launching` or `playing` within the start timeout. |
| daily_playing | app enters phase playing | Phase `playing` within the start timeout. |
| peak_process | a PEAK.exe process runs | `pgrep` finds a PEAK.exe within 120 s. |
| steam_init | Player.log has "Steam runtime manager initialized: True" | Rewritten after the launch, within 240 s. |
| eos_login | EOS sign-in in Player.log | Warn when "Failed to authenticate" is found. Recorded as a metric otherwise. |
| main_menu | PEAK main menu fully drawn (agent) | The agent answers ok. Skipped on skip or timeout. |
| peak_exit | PEAK exits | Gone after the menu step, or after wineserver -k. |
| app_exit | the app quits by itself within 60 s after PEAK is gone | The app process is gone. |
| last_launch | status lastLaunch is modded | `modded`. |
| no_problem | status has no problem | No `problem.code`. |

Overall status: any failed criterion gives fail (exit 1). Phase `error` during the launch gives fail at once. Missing Rosetta 2 or no setup gives blocked (exit 2). No GUI session gives blocked.

## Results and evidence

- `$JOB/results/G-APP3.json`: criteria, metrics (`time_to_playing_s`, `phase_after_playing`, `eos_login`, `last_launch_status`), computer_use (mainmenu and quit answers).
- `$JOB/logs/G-APP3/`: `console.log`, `Player-daily.log`.
- `$JOB/evidence/G-APP3/`: `peak-main-menu-app.png` (agent).
- `$JOB/appdata/Logs/` and `$JOB/appdata/frontend/status.json`.

## Copy back

- `results/G-APP3.json`, `logs/G-APP3/`, `evidence/G-APP3/*.png`, `cu/G-APP3.*`.
- `$JOB/appdata/Logs/`, `$JOB/appdata/frontend/status.json`, `$JOB/appdata/prefix/drive_c/users/*/AppData/LocalLow/LandCrab/PEAK/Player.log`.

## Paths outside the job dir

None written by this gate. Steam is not touched. The app's Wine server socket `/tmp/.wine-<uid>/` is removed by `cleanup.sh`.

## If it fails or is blocked

- Blocked, setup not done: run G-APP1 and G-APP2 first.
- Fail, `daily_launching` or `daily_playing`: read the phase and problem in the detail; `appdata/Logs/`.
- Fail, `peak_process`: the app said playing but no PEAK.exe runs. Read `appdata/Logs/launcher.log` and `peakpack.log`.
- Fail, `steam_init`: read `logs/G-APP3/Player-daily.log`. Check that Mac Steam is running and signed in under fleet.
- Warn, `eos_login`: the EOS sign-in failed in Player.log. It does not fail the gate; record it.
- Fail, `app_exit`: the app did not quit by itself. Read the app's log. The gate quits it afterwards.
