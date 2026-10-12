# G-B5: PEAK Windows depot via download_depot

| | |
|---|---|
| Slot | 1 |
| Needs a human | only if Mac Steam is not running (exit 3). Then run H-STEAM first. |
| Expected run time | 30 min (timeout 100 min) |
| Requires | H-STEAM |
| Run by | `run_slot.sh` (slot 1) or by hand |

## Purpose

Gets PEAK's Windows depot (app 3527290, depot 3527291) only from Valve's own Steam client. The hub's agent types `download_depot` into Mac Steam's console. The script then checks the files and moves the depot into the job dir. When the version matches a known build, every file's SHA-256 is compared with a Windows reference install.

## Preconditions

- H-STEAM has passed: Mac Steam is running and signed in under the fleet user. If Steam is not running, the gate exits needs-human.
- Mac Steam's console can be opened. The script runs `open steam://open/console` when Steam is running, unless `PP_OPEN_CONSOLE=0`.
- Computer use is available for the console step. With `PP_CU=none` the step is skipped and the gate is blocked.
- About 1.93 GB free for the download (the reference build 2.6.b is 1,930,336,210 bytes).
- Optional, early start: the slot runner can pre-announce the download at slot start (`early_cu` key `G-B5.download`, timeout 5400 s). The download then runs in Steam while other gates run.
- Optional, exact match: `expect/peak-win-<version>-*.manifest` for the game's version. The only reference listed in the script comments is 2.6.b.

## Command

```sh
cd "$JOB/kit"
bash testkit/run_gate.sh G-B5 --job-dir "$JOB" [-- <args>]
```

| Argument | Default | What it does |
|---|---|---|
| `--from-dir DIR` | not set | Verifies an existing depot folder instead of downloading. The folder must contain `PEAK.exe`. It is moved into the job dir unless `--copy` is given. |
| `--copy` | off | Copies the depot instead of moving it. Steam's folder is left in place. |
| `--timeout-min N` | 90 | How long to wait for the download, in minutes. This is also the computer-use request timeout (N x 60 s). |

## What the script does

1. Starts the gate. Stops if not on macOS. Starts caffeinate (process assertion only).
2. Chooses the source. If `$JOB/game/PEAK/PEAK.exe` already exists, it only verifies that folder. If `--from-dir` is given, it verifies that folder. Otherwise it needs Mac Steam running (exit 3 if not).
3. Notes the current size of Steam's `console_log.txt`, so only new lines count.
4. Opens `steam://open/console` if no answer exists yet and `PP_OPEN_CONSOLE` is not 0. Waits 3 s.
5. Takes the screenshot `b5-before-download`.
6. Asks for the download (`cu_request download`). The request waits up to 90 min, or the `--timeout-min` value. It also accepts the download by itself as soon as `Depot download complete` appears in the new lines of `console_log.txt`.
7. Records the wait time. Saves the matching console lines (`depot` or `download_depot`, last 40) to `logs/G-B5/steam-console-excerpt.txt`.
8. Reads the path and manifest id from the agent's answer. If the path is missing, it reads them from the console excerpt.
9. Finds the depot. It uses the reported path if `PEAK.exe` is there. Otherwise it looks in `steamapps/content/app_3527290/depot_3527291` under both Steam layouts. If no `PEAK.exe` is found, the gate fails.
10. For a Steam download, records the depot path in `state/outside-paths.tsv` as created-by-us.
11. Checks `PEAK.exe`, `UnityPlayer.dll`, `PEAK_Data/Plugins/x86_64/steam_api64.dll` and `PEAK_Data/Managed/Assembly-CSharp.dll`. Reads `version.txt`: line 1 is the version, line 2 is the revision.
12. Hashes every file except these: the `BepInEx` folder, `doorstop_config.ini`, `winhttp.dll`, `.doorstop_version`, `output_log.txt`, `Player*.log`, and `PEAK_Data` cache folders. Writes `logs/G-B5/peak-mac.manifest` (SHA-256, size, path for each file).
13. Checks the file count (at least 200) and total size (1.5 to 3 GB).
14. If `expect/peak-win-<version>-*.manifest` exists, compares the manifest line by line with it. Otherwise the check is skipped.
15. If `PEAK.exe` passed, moves the depot to `$JOB/game/PEAK` (copies it with `--copy`). After a move, removes the parent `app_3527290` folder if the job created it and it is now empty. Only a failed `peak_exe` check stops this step. Other failed checks still move the depot.
16. Records any `3527291_*.manifest` files in Steam's depotcache that did not exist before the job, as outside paths.
17. Records the version, revision and file count, then writes the results JSON.

## Computer-use steps

### CU-download

When the request appears:

- With the slot runner, the request is pre-announced at slot start. The agent can write the answer early. The script then uses it at once and does not wait.
- Otherwise it appears when the script reaches the download step, as `$JOB/cu/G-B5.download.request`. Watch for it with `bash testkit/cu.sh "$JOB" wait`.

Steps:

1. Open Mac Steam's Console view. The script runs `open steam://open/console`. If the Console view is not visible, use the fallback below.
2. Click the input line at the bottom of the Console view.
3. Type exactly `download_depot 3527290 3527291` and press Return.
4. Take the screenshot `b5-console-started` (command below).
5. Wait until the console prints `Depot download complete : "<path>" (manifest <id>)`. The download is about 1.93 GB. Wait up to 90 min, or the `--timeout-min` value.
6. Take the screenshot `b5-console-complete`.
7. Answer ok with the path and manifest (command below).
8. If an error line appears instead, take `b5-console-error` and answer fail with the message.
9. Never type credentials. Never quit or reconfigure Steam. Do not click Allow on any macOS privacy prompt.

Screenshots:

```sh
bash testkit/cu.sh "$JOB" shot G-B5 b5-console-started
bash testkit/cu.sh "$JOB" shot G-B5 b5-console-complete
bash testkit/cu.sh "$JOB" shot G-B5 b5-console-error    # only on an error line
```

Timeout: 90 min (5400 s) by default, or `--timeout-min` x 60 s.

If the script sees the completion line in `console_log.txt` first, it accepts the download without your answer. You can still take the screenshots and answer. The script then reads path and manifest from the console excerpt.

Answers:

```sh
bash testkit/cu.sh "$JOB" done G-B5.download ok "complete" path="<path>" manifest=<id>
bash testkit/cu.sh "$JOB" done G-B5.download fail "<message>"
```

Use the path exactly as it appears in quotes in the console line.

Fallback if the Console view did not open with `open steam://open/console`:

- Click Steam in the Dock, then find the Console view.
- Or, in Safari, type `steam://open/console` in the address bar. Allow it to open Steam. This is the browser's open-app prompt. Do not approve any macOS privacy prompt.

## Pass / fail criteria

| Criterion id | Check | Pass when |
|---|---|---|
| download | download_depot finished (Valve's client) | The agent answers ok, or the completion line is seen in `console_log.txt`. An agent answer of fail gives fail. |
| peak_exe | PEAK.exe present | `PEAK.exe` exists in the depot. A fail here also stops the move. |
| has_UnityPlayer.dll | UnityPlayer.dll present | File exists. |
| has_steam_api64.dll | PEAK_Data/Plugins/x86_64/steam_api64.dll present | File exists. |
| has_Assembly-CSharp.dll | PEAK_Data/Managed/Assembly-CSharp.dll present | File exists. |
| version_txt | version.txt readable | The first line is not empty. The detail shows the version and revision. |
| size | file count and size plausible (>= 200 files, 1.5-3 GB) | At least 200 files, and total bytes from 1,500,000,000 to 3,000,000,000. |
| exact_match | every file matches the Windows reference install | The Mac manifest matches `expect/peak-win-<version>-*.manifest` line for line. Skipped when no reference exists. |
| placed | depot moved into the job dir (or copied) | The move or copy succeeds. Not recorded if the depot was already in place, or if `peak_exe` failed. |

Overall status:

- Any failed criterion makes the gate fail (exit 1). A failed `download` ends the gate at once.
- Otherwise it passes (exit 0). Skipped checks do not fail it.
- Blocked (exit 2): `PP_CU=none` and no depot was found, or `--from-dir` has no `PEAK.exe`.
- Needs-human (exit 3): Mac Steam is not running.
- Error (exit 4): no answer within the timeout, or a timeout or signal from `run_gate.sh`.
- Fail (exit 1): the download reports complete but no depot folder with `PEAK.exe` is found.

## Results and evidence

- `$JOB/results/G-B5.json`: status, exit_code, reason, timings, versions, criteria, metrics, computer_use (the download answer), evidence, human, notes.
- Versions: `peak_version`, `peak_revision`, `peak_files`.
- Metrics: `source` (`already-in-job`, `from-dir` or `download_depot`), `download_wait_s`, `depot_manifest_id`, `steam_depot_path`, `files`, `bytes`, `reference` (when compared).
- `$JOB/logs/G-B5/`: `console.log`, `steam-console-excerpt.txt` (download branch), `peak-mac.manifest` (hash of every depot file), `manifest.diff` (only on a mismatch), `mv.err` (only on a failed move), `cu-download.answer.txt` (when an answer file existed).
- `$JOB/evidence/G-B5/`: `b5-before-download.png` (script), `b5-console-started.png`, `b5-console-complete.png`, `b5-console-error.png` (agent, when needed).

## Copy back

- `results/G-B5.json`.
- All of `logs/G-B5/`, including `peak-mac.manifest` and the console excerpt.
- `evidence/G-B5/*.png`.
- The `cu/G-B5.download.*` request and answer files, if present.
- Any screenshot the agent saved outside the job dir.
- Or run `bash testkit/collect.sh "$JOB"`.

## Paths outside the job dir

Steam content folder (the download writes here). The same `steamapps/content/app_3527290` exists under both layouts:

- `~/Library/Application Support/Steam/steamapps/content/app_3527290`
- `~/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamapps/content/app_3527290`

The gate moves `depot_3527291` out of this folder. It removes the empty `app_3527290` folder only if the job created it. With `--copy`, nothing is moved or removed.

Steam depotcache (written by Steam during the download):

- `depotcache/3527291_*.manifest` under `~/Library/Application Support/Steam/depotcache` and under the `Steam.AppBundle/Steam/Contents/MacOS/depotcache` layout.
- Only new files are recorded in `state/outside-paths.tsv`. `cleanup.sh` removes them.

Other paths:

- `steamapps/downloading/3527290` (both layouts) is in the pre-job snapshot, because Steam may use it during a download. This gate does not write there itself.
- Steam's `logs/console_log.txt` under `~/Library/Application Support/Steam/logs/`: read only. The gate reads only lines added after it started.
- Steam itself is never modified or quit.
- `cleanup.sh` removes only what did not exist before the job. The pre-job state is in `state/preexisting.tsv`.

## If it fails or is blocked

- Needs-human, Mac Steam not running: run H-STEAM (Joshua signs in once if needed), then re-run G-B5.
- Blocked, `PP_CU=none`: no agent answered the console step. Re-run with computer use on.
- Error, no answer within the timeout: check the Steam console and the screen. If the download is still running, re-run with a larger `--timeout-min`.
- Fail, `download` (error line): read `logs/G-B5/steam-console-excerpt.txt` and the `b5-console-error` screenshot.
- Fail, no depot folder found: Steam wrote the depot somewhere the script did not look. Find `depot_3527291` in the Steam folders above, then re-run with `--from-dir <path>` to verify it.
- Fail, `peak_exe`: the move did not happen. Check the download and re-run.
- Fail, `has_*`, `version_txt` or `size`: the depot is likely incomplete or wrong. These fails do not stop the move, so check `$JOB/game/PEAK` before re-running.
- Fail, `exact_match`: read `logs/G-B5/manifest.diff`. It counts the differing lines.
- Skip, `exact_match`: there is no reference for this version. The skip message says to regenerate it with `depot_manifest.sh`.
- Fail, `placed`: read `logs/G-B5/mv.err`.
