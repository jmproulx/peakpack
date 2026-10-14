# G-APP2: PEAK (Modded).app game step through the app's Steam console flow, then verify, PeakPack and mods

| | |
|---|---|
| Slot | app (slot-app.job.json) |
| Needs a human | no (the agent does the paste). Mode B needs the agent to pick a folder. |
| Expected run time | 75 min (the download is about 1.93 GB; the app verifies, moves, installs PeakPack and syncs mods). Timeout 130 min, see APP-README.md. |
| Requires | G-APP1 |
| Run by | `run_slot.sh` (slot-app) or by hand |

## Purpose

Does the friend's game step. The app asks the friend to paste a command into Steam's Console. Mode A (default) does exactly that: the agent clicks "Open Steam Console", pastes the command the app put on the clipboard, and presses Return. Steam downloads the depot. The app verifies it, moves it into the app's prefix, installs PeakPack and syncs the mods, then shows "All set". The script then checks the installed game against the Windows reference and checks the PeakPack install. It quits the app at the end.

Mode B (`--from-depot DIR` or `--use-existing-depot`) does the same with "Use a PEAK Folder I Already Have..." on a depot that G-B5 already downloaded. The app copies it instead of downloading.

## Preconditions

- G-APP1 has passed: the app is running at its game step, or it is launched again with `--no-autoplay` and setup resumes.
- A logged-in GUI session. Rosetta 2 installed.
- Mac Steam running and signed in under the fleet user (H-STEAM). The app's Console flow needs Steam.
- About 6 GB free on the disk for the download, the verify copy and the prefix.
- Mode B: `$JOB/game/PEAK/PEAK.exe` exists (from G-B5), or `--from-depot DIR` points to a PEAK folder.
- Optional: `expect/peak-win-<version>-*.manifest` for the game's version. Without it the exact-match criterion is skipped.

## Command

```sh
cd "$JOB/kit"
bash testkit/run_gate.sh G-APP2 --job-dir "$JOB" -- --app-release mac-build-app-0.1.1
bash testkit/run_gate.sh G-APP2 --job-dir "$JOB" -- --app-release mac-build-app-0.1.1 --use-existing-depot
```

| Argument | Default | What it does |
|---|---|---|
| `--app-release TAG` | `$PP_APP_RELEASE`, else the job's `APP_RELEASE` | The release tag (used to find the app bundle). |
| `--from-depot DIR` | not set | Mode B: copy the PEAK folder in DIR (it must contain `PEAK.exe`). |
| `--use-existing-depot` | off | Mode B with `$JOB/game/PEAK`. Blocked if it has no `PEAK.exe`. |
| `--timeout-min N` | 100 | How long to wait for the app's phase `done` after the start. |

## What the script does

1. Resolves the release tag. Chooses mode A or B. In mode B, checks the folder's `PEAK.exe` (blocked if missing). Checks Rosetta 2 and the GUI session.
2. Makes sure the app bundle is present (`ensure_app`). If the app is running, uses it. Otherwise starts it with `--no-autoplay`.
3. If the app is already at phase `done` or `ready`, skips the game step and says so in the notes. Otherwise waits up to 15 min for step `game` with stepState `waiting-for-user`.
4. Notes the size of Steam's `console_log.txt`, so only lines added later count.
5. Computer-use step CU-paste (mode A) or CU-folder (mode B).
6. Polls the status every 5 s until phase `done`, `error`, or the wait limit. Records the highest progress, the time to step `mods`, and the time to `done`. It also reads `console_log.txt` from the offset only for the line `Depot download complete` (read-only, nothing else in Steam's files is read).
7. Checks the installed game in `$JOB/appdata/prefix/drive_c/Games/PEAK`. Hashes every file with the same pipeline and exclusions as G-B5. Compares with the reference manifest when `version.txt` matches one.
8. Checks the PeakPack install (`AppData\Local\PeakPack\PeakPack.exe`), the BepInEx core in the profile, and `packRevision` in `frontend/state.json`.
9. Checks Steam's `app_3527290` content folder. Fails if `depot_3527291` is still there. Records the new depotcache entries for `cleanup.sh`.
10. Quits the app with `app_quit`.

## Computer-use steps

### CU-paste (mode A)

When the request appears (`$JOB/cu/G-APP2.paste.request`, timeout 900 s):

1. Takes `app-console-guide` (before the paste).
2. Clicks the app's "Open Steam Console" button. Steam's Console view opens.
3. Clicks the input box at the very bottom of the Console view, presses Cmd+V (the app has put `download_depot 3527290 3527291` on the clipboard), then presses Return.
4. Takes `steam-console-pasted` (after Return).
5. Answers ok. The script then waits for the download; the agent need not stay.

Screenshots: `bash testkit/cu.sh "$JOB" shot G-APP2 app-console-guide` and `... shot G-APP2 steam-console-pasted`

Answer: `bash testkit/cu.sh "$JOB" done G-APP2.paste ok "pasted and Return pressed"` or `... fail "<what you see>"`.

Never type credentials. Type nothing else. Do not quit Steam. Never click a macOS prompt.

### CU-folder (mode B)

When the request appears (`$JOB/cu/G-APP2.folder.request`, timeout 900 s):

1. In the app's game step, clicks the "More" menu next to "Open Steam Console" and chooses "Use a PEAK Folder I Already Have...".
2. In the standard folder picker, chooses exactly the folder named in the request. Does not choose another folder.
3. Takes `app-folder-picked`.
4. Answers ok once the app starts copying the folder.

Screenshot: `bash testkit/cu.sh "$JOB" shot G-APP2 app-folder-picked`

Answer: `bash testkit/cu.sh "$JOB" done G-APP2.folder ok "copy started"` or `... fail "<what you see>"`.

## Pass / fail criteria

| Criterion id | Check | Pass when |
|---|---|---|
| game_step | app waits at its game step | Step `game`, stepState `waiting-for-user`, within 15 min. (Not recorded when the app was already done.) |
| cu_source | the game source step answered ok | The agent answers ok (CU-paste or CU-folder). |
| setup_done | app reaches phase done ("All set") | Phase `done` within the wait. |
| no_problem | status has no problem | No `problem.code`. |
| manifest_id | status `game.manifestId` is a number | Mode A only: a number. Mode B is info. |
| manifest_match | Steam's console manifest equals the app's | Mode A: the ids match (info when the completion line was not seen). |
| game_files | PEAK.exe, UnityPlayer.dll, steam_api64.dll, Assembly-CSharp.dll | All four are in `drive_c/Games/PEAK`. |
| size | file count and size plausible | At least 200 files, and 1.5 to 3 GB (the same as G-B5). |
| exact_match | every installed file matches the Windows reference | Line-for-line match with `expect/peak-win-<version>-*.manifest`. Skipped with no reference. |
| peakpack_exe | PeakPack.exe installed | `AppData\Local\PeakPack\PeakPack.exe` exists. |
| profile_bepinex | BepInEx core in the profile | `profile/BepInEx/core/BepInEx.Preloader.dll` exists. |
| state_pack_revision | frontend/state.json has packRevision | The key exists. |
| steam_content | Steam's content folder is gone or empty | No `depot_3527291` left in either Steam layout. Info when other entries remain. |
| app_quit | app quit at the end | `app_quit` returns with no app process left. |

Overall status: any failed criterion gives fail (exit 1). A missing Rosetta 2 or a missing mode-B folder gives blocked (exit 2). No GUI session gives blocked. A timeout or unanswered CU gives error (exit 4).

## Results and evidence

- `$JOB/results/G-APP2.json`: criteria, metrics (`game_mode`, `max_progress`, `time_to_mods_s`, `console_done_after_s`, `time_to_done_s`, `depot_manifest_id`, `files`, `bytes`), versions (`peak_version`, `peak_revision`, `pack_revision`), computer_use (paste or folder answer), evidence.
- `$JOB/logs/G-APP2/`: `console.log`, `console-line.txt` (mode A), `peak-app.manifest` (every file's SHA-256), `manifest.diff` (only on a mismatch), `ref.manifest`.
- `$JOB/evidence/G-APP2/`: `app-console-guide.png`, `steam-console-pasted.png` or `app-folder-picked.png`.
- The app's logs: `$JOB/appdata/Logs/`.

## Copy back

- `results/G-APP2.json`, `logs/G-APP2/`, `evidence/G-APP2/*.png`, `cu/G-APP2.*`.
- `$JOB/appdata/frontend/status.json`, `state.json`, `$JOB/appdata/Logs/`.

## Paths outside the job dir

- Steam's `steamapps/content/app_3527290` (both layouts, see G-B5). The app moves the depot out. This gate checks that it is gone or empty, and does not remove it.
- Steam's `depotcache/3527291_*.manifest` (both layouts). Only new files are recorded in `state/outside-paths.tsv`, and `cleanup.sh` removes them.
- Steam's `logs/console_log.txt`: read-only, from a byte offset. No other Steam file is read.
- The clipboard is written by the app, never read by the kit.

## If it fails or is blocked

- Blocked, no PEAK.exe in mode B: run G-B5 first, or pass `--from-depot DIR`.
- Blocked, no app release tag or missing bundle: run G-APP1 first.
- Fail, `game_step` or `cu_source`: read the step and progress in the detail. For a fail answer, read the screenshots.
- Fail, `setup_done`: the detail has the phase and step. A phase `error` gives the problem code and heading. Read `appdata/Logs/`.
- Fail, `game_files`: the detail lists the missing files. The depot is incomplete or was not moved in.
- Fail, `exact_match`: read `logs/G-APP2/manifest.diff`. A file the app writes into the game folder (outside the BepInEx folder and the excluded files) shows up here. Decide if the exclusions need changing (a decision for the lead, not the agent).
- Fail, `steam_content`: the depot is still in Steam's content folder. The app did not move it; check the Steam folders and the app's log.
- Info, `manifest_match`: the completion line was not seen; the app's manifest id is still checked by `manifest_id`.
- Timeout (exit 4): the download may still be running. Re-run with `--timeout-min` a larger value (the app keeps its state, so the setup resumes).
