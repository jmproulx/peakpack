# G-A2-lite: Short performance run

| | |
|---|---|
| Slot | 1 |
| Needs a human | no (only if Mac Steam is not running: the gate exits 3 until H-STEAM has run) |
| Expected run time | 15 min (timeout 35 min) |
| Requires | G-A1, G-B5 |
| Run by | `run_slot.sh` (slot 1) or by hand |

## Purpose

Measures PEAK's frame rate on the Mac in a short solo run. PEAK starts fullscreen through the Steam bridge with the Metal HUD on. The agent takes the game from the main menu to the Shore. The HUD FPS is read every 30 seconds for the Shore time (2 minutes by default). Memory pressure and swap are sampled for the whole run. This is the lite form of G-A2. The CrossOver comparison is skipped.

## Preconditions

- Mac Steam running (H-STEAM). The gate checks only that the process runs. If it is not running, the gate exits 3 with "Run H-STEAM, then re-run G-A2-lite."
- Rosetta 2 installed. The gate blocks if it is missing. It never installs it.
- G-A1 done. If the runtime is missing from the job dir, the gate fetches and unpacks it. It blocks if that fails.
- PEAK's Windows files in `$JOB/game/PEAK` (from G-B5). The gate blocks if `PEAK.exe` is not there.
- The Steam launcher `peakpack_steam_launcher.exe` in the bridge folder. The gate blocks if it is missing.
- With `--modded` only: `PeakPack.exe`. The gate downloads the newest pack release if it is not already in `downloads/`.
- The screen is free for the whole run (job file: "ours for the whole slot"). The agent clicks and reads the screen.

## Command

```sh
cd "$JOB/kit"
bash testkit/run_gate.sh G-A2-lite --job-dir "$JOB" [-- <args>]
```

The job file runs it with `-- --minutes 2`.

| Argument | Default | Meaning |
|---|---|---|
| `--modded` | off | Start PEAK through PeakPack.exe (`--headless --launch`) instead of starting PEAK.exe through the bridge launcher. The script header says G-D2 must come first. The script itself only checks that PeakPack.exe is available. |
| `--minutes N` | 2 | Time to stay on the Shore. The FPS step timeout is N x 60 + 180 seconds. Other arguments are ignored. |

No gate-specific environment variables are read. The gate sets `PP_HUD=1` itself for the launch. Shared options from `lib/common.sh`: `PP_CU=none` answers every CU step "skip" at once, and the gate's own screenshot is taken only with `PP_SCREENSHOTS=1` (off by default: no Screen Recording prompt).

## What the script does

1. Loads `lib/common.sh` and `lib/assets.sh` and starts the result. Blocks if this is not macOS.
2. Reads `--modded` and `--minutes`.
3. Blocks if Rosetta 2 is missing. Exits 3 if Mac Steam is not running.
4. Keeps the Mac awake (`caffeinate`).
5. Makes sure the runtime, the test kit and the bridge are present. Blocks if the runtime or the launcher is missing. Errors if the Wine prefix cannot be created.
6. Blocks if PEAK is not in the job dir. Copies the launcher and `steamclient64.dll` into `drive_c/PeakPackTests` in the prefix.
7. Starts the samplers for the whole run:
   - `pp-sample.sh` every 10 s, to `logs/G-A2-lite/pp-sample.csv`.
   - A loop that records `kern.memorystatus_vm_pressure_level` every 10 s, to `pressure-level.csv`.
   - If the test kit has `mac/t12_memsample.sh`, that script runs every 10 s, to `logs/G-A2-lite/t12/`.
8. Launches PEAK with `-force-d3d11 -screen-width 1440 -screen-height 900 -screen-fullscreen 1 -window-mode borderless`, with `PP_HUD=1`.
   - Default: the launcher starts `PEAK.exe` with those arguments.
   - `--modded`: the launcher starts with `--no-launch`. The script waits 8 s, then runs `PeakPack.exe --headless --launch`. The screen arguments are not passed on this path. PEAK uses its saved resolution, and the gate records a note saying so.
9. Criterion `started`: waits up to 300 s for "Steam runtime manager initialized" in Player.log. If it does not appear, the gate ends now with status fail.
10. CU-menu (see below). Records the menu FPS as metric `fps_main_menu`. A `fail` answer records `reached_menu` as fail and ends the gate now. A skip or a timeout records nothing, and the script goes on.
11. CU-shore (see below). Records metrics `reached_airport` and `reached_level_1` from Player.log. The step passes by itself once Player.log shows "Update current scene: Level_1".
12. Criterion `reached_shore`: pass for an ok answer or the automatic pass. Fail for any other answer, including skip or timeout. If it fails, the FPS step does not run.
13. CU-fps (only after `reached_shore` passed). Records metrics `fps_readings`, `fps_avg`, `fps_min` and `fps_samples`. Criterion `fps_floor` checks the lowest reading. A `fail` answer records criterion `run_ok` as fail.
14. Records `vs_crossover` as skip. It is always skip.
15. Checks whether PEAK.exe is still running (metric `peak_alive_at_end`). Takes the screenshot `a2-end`. Copies Player.log into `logs/G-A2-lite/`.
16. Stops the samplers and Wine.
17. Counts crash markers in the Player.log copy (metric `crash_markers`). Criterion `no_crash`.
18. Reads `pp-sample.csv`: sample count, lowest free memory %, swap growth (largest swap value minus the first sample), peak RSS and Wine RSS. Reads `pressure-level.csv` for the highest level (metric `pressure_level_max`). Criteria `mem_pressure` and `swap_growth`.
19. Copies the last 6 lines of `t12.out` to `t12-summary.txt`, writes the result JSON and exits.

## Computer-use steps

### CU-menu

- **When:** right after PEAK logs "Steam runtime manager initialized". Timeout 300 s.
- **Actions:**
  1. Wait for the main menu. The window is fullscreen and the Metal HUD shows FPS at the top right.
  2. Save a screenshot: `bash testkit/cu.sh "$JOB" shot G-A2-lite a2-01-main-menu` (goes to `evidence/G-A2-lite/a2-01-main-menu.png`).
  3. Read the FPS from the HUD.
  4. Answer ok: `bash testkit/cu.sh "$JOB" done G-A2-lite.menu ok "main menu reached" fps=<number>`
  5. If a crash dialog or a black screen stays for 60 s, answer fail: `bash testkit/cu.sh "$JOB" done G-A2-lite.menu fail "<what you see>"`

### CU-shore

- **When:** right after CU-menu, if the menu did not fail. Timeout 600 s.
- **Automatic pass:** every 5 s the script checks Player.log. Once it contains "Update current scene: Level_1", the step is recorded as ok with the note "condition met without an answer file (auto)". No answer is needed for that.
- **Scene markers:** "Update current scene: Airport" is the airport lobby. "Update current scene: Level_1" is the island, whose first biome is the Shore.
- **Actions:**
  1. In the main menu choose Play. Pick a solo or offline option if PEAK offers one. Otherwise host a private lobby and invite nobody.
  2. In the airport lobby, walk (W, mouse to steer) to the boarding desk or kiosk. Press E to start the expedition. Confirm if asked.
  3. Wait until the island has loaded and your scout stands on the beach.
  4. Screenshots: `bash testkit/cu.sh "$JOB" shot G-A2-lite a2-02-lobby` in the lobby, and `bash testkit/cu.sh "$JOB" shot G-A2-lite a2-03-shore` on the Shore.
  5. Answer ok: `bash testkit/cu.sh "$JOB" done G-A2-lite.shore ok "standing on the Shore"`
  6. Answer fail: `bash testkit/cu.sh "$JOB" done G-A2-lite.shore fail "<where it got stuck>"`
- Never open the Steam overlay or invite friends. Exact menu wording may differ. Follow what PEAK shows.

### CU-fps

- **When:** only if `reached_shore` passed (ok or automatic). Timeout is N x 60 + 180 s. With the default `--minutes 2` that is 300 s.
- **Actions:**
  1. Stay on the Shore for the Shore time (2 minutes by default). Look around and walk slowly along the beach.
  2. Every 30 s, read the Metal HUD FPS and save a screenshot: `bash testkit/cu.sh "$JOB" shot G-A2-lite a2-fps-1`, then `a2-fps-2`, and so on.
  3. Answer ok: `bash testkit/cu.sh "$JOB" done G-A2-lite.fps ok "<notes>" fps=58,60,57,59 min=57 notes="<stutter, hitches, artefacts>"`
  4. Answer fail if the game crashes or freezes: `bash testkit/cu.sh "$JOB" done G-A2-lite.fps fail "<what happened>"`
- The script reads only `fps=`. It computes the average and the lowest value itself, so `min=` is ignored. Pass the readings as a key=value argument after the note, as shown.

## Pass / fail criteria

| Criterion id | Check | Pass when |
|---|---|---|
| `started` | PEAK started with Steam initialised | "Steam runtime manager initialized" appears in Player.log within 300 s. Otherwise fail, and the gate ends. |
| `reached_menu` | main menu reached (agent) | Written only on a fail answer, which ends the gate. Never pass. Skip and timeout write nothing. |
| `reached_shore` | solo game reached the Shore (agent) | Pass on ok or the automatic Level_1 pass. Fail on any other answer. |
| `run_ok` | no crash or freeze on the Shore (agent) | Written only on a fail answer. Never pass. |
| `fps_floor` | lowest HUD FPS on the Shore is 30 or more | Pass if the lowest reading is 30 or more. Fail if below. Skip if the answer has no readings. |
| `vs_crossover` | average FPS at least 90 % of CrossOver | Always skip. It needs G-A2-CX, which this gate does not read. |
| `no_crash` | PEAK still running at the end, no crash markers | Pass if PEAK.exe is running and the Player.log copy has zero crash markers. Otherwise fail. |
| `mem_pressure` | memory pressure never red | Pass if the highest level is 1 to 3. Fail if level 4 (critical) was seen, or if `pp-sample.csv` is missing. Skip if there are no level readings. |
| `swap_growth` | swap growth under 1 GB | Pass if growth is under 1024 MB. Fail otherwise. Not written if `pp-sample.csv` is missing. |

How the overall status is decided (from `lib/common.sh`):

- Any criterion fails: status fail, exit 1.
- Otherwise, any criterion passes: status pass, exit 0.
- Only skip or info results: status error, exit 4.
- A skip does not block a pass. For example, `fps_floor` can be skipped and the gate still passes. Check the criteria list in the result.
- If `started` or `reached_menu` fails, the gate ends there with that status.

## Results and evidence

- `results/G-A2-lite.json`: status, criteria, metrics, CU answers, evidence list, notes.
- Metrics: `unity_args`, `hud`, `modded`, `start_to_steam_s`, `fps_main_menu`, `reached_airport`, `reached_level_1`, `menu_to_shore_s`, `shore_seconds`, `fps_readings`, `fps_avg`, `fps_min`, `fps_samples`, `peak_alive_at_end`, `crash_markers`, `samples`, `mem_free_min_pct`, `peak_rss_max_mb`, `wine_rss_max_mb`, `swap_growth_mb`, `pressure_level_max`.
- Versions: `runtime_id`, `runtime_built_at` (if the manifest exists), `steam_tests`, and `peakpack_exe_sha256` with `--modded`.
- `logs/G-A2-lite/`: Player.log copy; `pp-sample.csv` (the gate reads column 2 as free %, column 3 as swap, column 4 as PEAK RSS and column 5 as Wine RSS); `pressure-level.csv`; `t12/`, `t12.out` and `t12-summary.txt`; `launcher.out`; `peak-wine.out` (or `peakpack-launch.out` with `--modded`); `cu-<step>.answer.txt`; `wine/` (Wine and DXMT logs).
- `evidence/G-A2-lite/`: `a2-01-main-menu.png`, `a2-02-lobby.png`, `a2-03-shore.png`, `a2-fps-<n>.png`, `a2-end.png`.
- In the prefix: `drive_c/PeakPackTests/launcher-a2.log` and, with `--modded`, `a2-launch.json`.
- `cu/`: the requests and answers.

## Copy back

- `bash testkit/collect.sh "$JOB"`. It packs `results/`, `logs/`, `evidence/`, `cu/` and `state/` (see `slot1.job.json`, copy_back).
- Also relay the agent's screenshots if they were saved somewhere else, and the run_slot console output.

## Paths outside the job dir

- `/tmp/.wine-<uid>/server-*`: the Wine server socket of the prefix. `cleanup.sh` removes it.
- Metal shader caches and Rosetta translations: managed by macOS. They are not removed.
- The gate writes nothing else outside the job dir.

## If it fails or is blocked

- **Blocked, Rosetta 2 missing:** report it. The kit never installs it.
- **Needs a human, Mac Steam not running:** run H-STEAM, then re-run this gate.
- **Blocked, runtime not available:** G-A1 failed, or its download failed. Re-run G-A1.
- **Blocked, launcher missing from the runtime:** the runtime is incomplete. Re-run G-A1.
- **Blocked, PEAK not in the job dir:** run G-B5.
- **Error, prefix creation failed:** see `logs/G-A2-lite/create-prefix.log`.
- **Blocked, PeakPack.exe not available (`--modded`):** see `logs/G-A2-lite/curl.log`.
- **Fail, `started`:** PEAK did not log Steam within 300 s. Check `peak-wine.out` (or `launcher.out` and `peakpack-launch.out`). The gate copies Player.log only at the end, so read the live log at `prefix/drive_c/users/<user>/AppData/LocalLow/LandCrab/PEAK/Player.log`.
- **Fail, `reached_menu`:** the agent's note says what happened. The gate ends early, so the memory and crash criteria are missing from the result.
- **Fail, `reached_shore`:** the note says where it got stuck. The FPS step does not run. The remaining checks still run.
- **Skip, `fps_floor`:** the FPS answer had no readings. Re-run and give `fps=...` after the note.
- **Fail, `fps_floor`:** the lowest reading is below 30. Check `fps_readings` and the screenshots.
- **Fail, `run_ok` or `no_crash`:** a crash or freeze. Check the crash markers and the Player.log copy.
- **Fail, `mem_pressure`:** level 4 was seen. **Fail, `swap_growth`:** swap grew by 1024 MB or more.
- **Error (exit 4), "interrupted":** the 35 min watchdog or a signal stopped the gate. The cleanup step stops Wine and the samplers.
- **A menu timeout (300 s)** does not fail the gate. The run goes on to the Shore step.
