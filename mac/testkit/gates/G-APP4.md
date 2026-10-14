# G-APP4: PEAK (Modded).app options window: Show FPS, Play with Mods, every pack plugin loads, Metal HUD

| | |
|---|---|
| Slot | app (slot-app.job.json) |
| Needs a human | no |
| Expected run time | 15 min (timeout 30 min, see APP-README.md) |
| Requires | G-APP3 |
| Run by | `run_slot.sh` (slot-app) or by hand |

## Purpose

The modded launch from the app's options window, the way a friend starts the modded game with FPS shown. The checks are G-D2's modded checks, but driven by the app: BepInEx loads every plugin in `expect/pack-plugins.txt` with no load errors, and the app's status says `lastLaunch` is `modded`. The agent reads the Metal HUD's fps. Then PEAK ends as in G-APP3, Show FPS is unticked again, and the app is quit.

## Preconditions

- G-APP3 has passed.
- A logged-in GUI session. Rosetta 2 installed. Mac Steam signed in under fleet.
- `expect/pack-plugins.txt` in the kit (the plugin list of pack revision 5). Without it the named-plugin criterion is skipped.

## Command

```sh
cd "$JOB/kit"
bash testkit/run_gate.sh G-APP4 --job-dir "$JOB" -- --app-release mac-build-app-0.1.1
```

| Argument | Default | What it does |
|---|---|---|
| `--app-release TAG` | `$PP_APP_RELEASE`, else the job's `APP_RELEASE` | The release tag. |
| `--launch-timeout S` | 300 | How long to wait for the BepInEx line and for playing. |

## What the script does

1. Checks the setup (phase `done` or `ready`), Rosetta 2, the GUI session.
2. Starts the app with `--options --no-autoplay`. Waits for phase `ready` (180 s).
3. Computer-use step CU-options: the agent ticks Show FPS and clicks Play with Mods.
4. Waits for phase `launching` then `playing`. Waits up to `--launch-timeout` for "Chainloader startup complete" in BepInEx's `LogOutput.log`, rewritten after the click (the time is taken before the CU step).
5. Waits 20 s, then copies `LogOutput.log` to `logs/G-APP4/LogOutput-modded.log`. Parses it as G-D2 does: the "N plugins to load" count, the "Loading [...]" lines, the BepInEx error patterns, and each name in `expect/pack-plugins.txt`.
6. Reads `PeakPackMac/status-launch.json` (the launch command line, `launched`). Checks `-force-d3d11` in the command line (info if absent). Checks the app's `lastLaunch` is `modded`.
7. Computer-use step CU-hud: the agent reads the Metal HUD's fps (recorded as the metric `fps`).
8. Ends PEAK as in G-APP3 (CU-quit, with the wineserver -k fallback after 60 s).
9. Computer-use step CU-fpsoff: the agent unticks Show FPS in the options window. The app is still running; it was opened with `--options`.
10. Quits the app.

## Computer-use steps

### CU-options

When the request appears (`$JOB/cu/G-APP4.options.request`, timeout 300 s):

1. Takes `options-window` (before the first click).
2. Ticks "Show FPS".
3. Clicks "Play with Mods". Does not click "Play Normal PEAK".
4. Answers ok.

Screenshot: `bash testkit/cu.sh "$JOB" shot G-APP4 options-window`

Answer: `bash testkit/cu.sh "$JOB" done G-APP4.options ok "Show FPS on, Play with Mods clicked"`.

### CU-hud

When the request appears (`$JOB/cu/G-APP4.hud.request`, timeout 300 s):

1. Waits about 30 s for the Metal HUD value to settle. Does not click in PEAK.
2. Takes `peak-modded-hud`.
3. Answers ok with the HUD's number, or fail.

Screenshot: `bash testkit/cu.sh "$JOB" shot G-APP4 peak-modded-hud`

Answer: `bash testkit/cu.sh "$JOB" done G-APP4.hud ok "HUD visible" fps=58`.

### CU-quit

As in G-APP3 (`G-APP4.quit`, 60 s, with the same fallback).

### CU-fpsoff

When the request appears (`$JOB/cu/G-APP4.fpsoff.request`, timeout 300 s):

1. PEAK has quit. The app is still running. Brings its options window up: click the app's Dock icon if no window is visible (or use the PEAK menu > Show Options).
2. Unticks "Show FPS". Does not click Play with Mods or Play Normal PEAK.
3. Takes `options-after`.
4. Answers ok.

Screenshot: `bash testkit/cu.sh "$JOB" shot G-APP4 options-after`

Answer: `bash testkit/cu.sh "$JOB" done G-APP4.fpsoff ok "Show FPS unticked"`.

## Pass / fail criteria

| Criterion id | Check | Pass when |
|---|---|---|
| options_ready | app opens with phase ready | Phase `ready` within 180 s. |
| options_cu | agent ticked Show FPS and clicked Play with Mods | The agent answers ok. |
| modded_playing | app reports phase playing (modded) | Phase `playing`. |
| bepinex_started | BepInEx chainloader complete | "Chainloader startup complete" in a LogOutput.log rewritten after the click. |
| all_plugins | every plugin BepInEx found was loaded | The loaded count is at least the "N plugins to load" count, and above 0. |
| no_load_errors | no BepInEx load errors | No error or fatal line, no "Could not load", "Skipping", "Error loading", "missing dependenc" or "incompatible". |
| expected_plugins | every plugin in pack-plugins.txt loaded | Each listed name appears as "Loading [name ". Skipped without the file. |
| mac_extra_args | `-force-d3d11` on the launch command line | Present. Info, not a fail, when absent. |
| launch_mode | app status lastLaunch is modded | `modded`. |
| metal_hud | Metal HUD visible with the modded PEAK (agent) | The agent answers ok. |
| peak_exit | PEAK exits | Gone after the menu step, or after wineserver -k. |
| fps_unticked | Show FPS unticked again (agent) | The agent answers ok. |
| app_quit | app quit | Quit with no app process left. |

Overall status: any failed criterion gives fail (exit 1). A failed options step, or PEAK not reaching `playing`, ends the gate early. Missing preconditions give blocked (exit 2). An unanswered options step gives error (exit 4).

## Results and evidence

- `$JOB/results/G-APP4.json`: criteria, metrics (`plugins_to_load`, `plugins_loaded`, `bepinex_error_lines`, `bepinex_version`, `any_error_lines`, `fps`, `launch_commandline`, `status_launch_launched`), computer_use (options, hud, fpsoff).
- `$JOB/logs/G-APP4/`: `LogOutput-modded.log`, `plugins-loaded.txt`, `bepinex-errors.txt`, `all-error-lines.txt`, `status-launch.json`.
- `$JOB/evidence/G-APP4/`: `options-window.png`, `peak-modded-hud.png`, `options-after.png`.

## Copy back

- `results/G-APP4.json`, `logs/G-APP4/`, `evidence/G-APP4/*.png`, `cu/G-APP4.*`.
- The `LogOutput.log` of the PeakPack profile (`$JOB/appdata/prefix/drive_c/users/*/AppData/Local/PeakPack/profile/BepInEx/LogOutput.log`).

## Paths outside the job dir

None written by this gate.

## If it fails or is blocked

- Blocked, setup not done: run G-APP1 to G-APP3 first.
- Fail, `options_cu`: the options step failed; read the screenshot.
- Fail, `bepinex_started`: the detail shows the last lines of LogOutput.log. Read `logs/G-APP4/LogOutput-modded.log`.
- Fail, `all_plugins` or `no_load_errors`: read `plugins-loaded.txt` and `bepinex-errors.txt`.
- Fail, `expected_plugins`: the detail lists the missing names.
- Fail, `launch_mode`: the app's `lastLaunch` is not modded. Read `status-launch.json`.
- Info, `mac_extra_args`: `-force-d3d11` is not on the command line. Not a failure.
- Fail, `metal_hud`: no HUD. Check the Show FPS setting and the screenshot.
