# G-APP5: PEAK (Modded).app "Play Normal PEAK": vanilla launch, no BepInEx

| | |
|---|---|
| Slot | app (slot-app.job.json) |
| Needs a human | no |
| Expected run time | 10 min (timeout 20 min, see APP-README.md) |
| Requires | G-APP4 |
| Run by | `run_slot.sh` (slot-app) or by hand |

## Purpose

The vanilla launch from the app's options window. Checks (as the vanilla part of G-D2): PEAK starts with Steam initialised, BepInEx does not start (its `LogOutput.log` is not rewritten), the vanilla Player.log has no BepInEx, Doorstop or Chainloader text, and the app's status says `lastLaunch` is `vanilla`.

## Preconditions

- G-APP4 has passed (the app is quit or at its options window; the gate opens it fresh).
- A logged-in GUI session. Rosetta 2 installed. Mac Steam signed in under fleet.

## Command

```sh
cd "$JOB/kit"
bash testkit/run_gate.sh G-APP5 --job-dir "$JOB" -- --app-release mac-build-app-0.1.1
```

| Argument | Default | What it does |
|---|---|---|
| `--app-release TAG` | `$PP_APP_RELEASE`, else the job's `APP_RELEASE` | The release tag. |
| `--launch-timeout S` | 300 | How long to wait for PEAK's Steam line and for playing. |

## What the script does

1. Checks the setup (phase `done` or `ready`), Rosetta 2, the GUI session.
2. Starts the app with `--options --no-autoplay`. Waits for phase `ready` (180 s).
3. Notes the modification time of BepInEx's `LogOutput.log` (0 if absent). Takes the time for the Player.log check.
4. Computer-use step CU-playnormal: the agent clicks "Play Normal PEAK".
5. Waits for phase `launching` then `playing`. Checks a PEAK.exe process runs (within 120 s).
6. Waits up to `--launch-timeout` for "Steam runtime manager initialized" in the new Player.log. Copies it to `logs/G-APP5/Player-vanilla.log`.
7. Compares the modification time of `LogOutput.log` with the value before. Checks the vanilla Player.log has no BepInEx, Doorstop or Chainloader text. Checks the app's `lastLaunch` is `vanilla`.
8. Ends PEAK as in G-APP3 (CU-quit, with the wineserver -k fallback after 60 s).
9. Quits the app.

## Computer-use steps

### CU-playnormal

When the request appears (`$JOB/cu/G-APP5.playnormal.request`, timeout 300 s):

1. Takes `options-before-click`.
2. Clicks "Play Normal PEAK" (the button without mods). Does not tick or untick anything, and does not click "Play with Mods".
3. Answers ok.

Screenshot: `bash testkit/cu.sh "$JOB" shot G-APP5 options-before-click`

Answer: `bash testkit/cu.sh "$JOB" done G-APP5.playnormal ok "Play Normal PEAK clicked"`.

### CU-quit

As in G-APP3 (`G-APP5.quit`, 60 s, with the same fallback).

## Pass / fail criteria

| Criterion id | Check | Pass when |
|---|---|---|
| options_ready | app opens with phase ready | Phase `ready` within 180 s. |
| playnormal_cu | agent clicked Play Normal PEAK | The agent answers ok. |
| vanilla_playing | app reports phase playing (vanilla) | Phase `playing`. |
| peak_process | a PEAK.exe process runs | Found within 120 s. |
| vanilla_started | Player.log has "Steam runtime manager initialized" | Rewritten after the click, within the launch timeout. |
| vanilla_no_bepinex | BepInEx did not start (LogOutput.log untouched) | Its modification time is unchanged. |
| vanilla_player_log | no BepInEx/Doorstop/Chainloader lines in the vanilla Player.log | None found. |
| last_launch | app status lastLaunch is vanilla | `vanilla`. |
| peak_exit | PEAK exits | Gone after the menu step, or after wineserver -k. |
| app_quit | app quit | Quit with no app process left. |

Overall status: any failed criterion gives fail (exit 1). PEAK not reaching `playing` ends the gate early. Missing preconditions give blocked (exit 2). An unanswered options step gives error (exit 4).

## Results and evidence

- `$JOB/results/G-APP5.json`: criteria, metrics, computer_use (playnormal and quit answers).
- `$JOB/logs/G-APP5/`: `Player-vanilla.log`, `console.log`.
- `$JOB/evidence/G-APP5/`: `options-before-click.png`.

## Copy back

- `results/G-APP5.json`, `logs/G-APP5/`, `evidence/G-APP5/*.png`, `cu/G-APP5.*`.
- `$JOB/appdata/Logs/`.

## Paths outside the job dir

None written by this gate.

## If it fails or is blocked

- Fail, `vanilla_no_bepinex`: the vanilla launch rewrote `LogOutput.log`. Read the file in the PeakPack profile. Check whether the app used the modded launch path.
- Fail, `vanilla_player_log`: read `logs/G-APP5/Player-vanilla.log`.
- Fail, `vanilla_started`: check Mac Steam is running and signed in under fleet, and read `appdata/Logs/`.
- Fail, `last_launch`: the app did not record a vanilla launch. Read its status and log.
