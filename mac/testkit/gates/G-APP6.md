# G-APP6: PEAK (Modded).app repair (damaged prefix stamp and runtime file) and uninstall

| | |
|---|---|
| Slot | app (slot-app.job.json) |
| Needs a human | no |
| Expected run time | 25 min (timeout 60 min, see APP-README.md) |
| Requires | G-APP5 |
| Run by | `run_slot.sh` (slot-app) or by hand |

## Purpose

Two things the app must do for a friend who breaks their install.

(a) Repair. The gate damages the app's own data inside the job dir: it removes the prefix stamp and replaces one runtime file. The agent runs PEAK menu > Repair... > Repair. The app must reach `ready` with no problem, restore both, and report `readyToPlay` true.

(b) Uninstall. The agent runs PEAK menu > Uninstall... > Move to Trash. In this test build the app moves its data (`appdata`, with its Logs) into `$JOB/uninstalled/appdata-<epoch>`. The real Trash is privacy-protected and is not tested. The gate checks that the data left its place, the moved copy is complete, the app bundle stays, and Steam's folders did not change.

## Preconditions

- G-APP5 has passed. The app is quit.
- A logged-in GUI session. Rosetta 2 installed.
- Mac Steam: Steam's folders are only listed (names), never opened. Steam need not run for this gate.

## Command

```sh
cd "$JOB/kit"
bash testkit/run_gate.sh G-APP6 --job-dir "$JOB" -- --app-release mac-build-app-0.1.1
```

| Argument | Default | What it does |
|---|---|---|
| `--app-release TAG` | `$PP_APP_RELEASE`, else the job's `APP_RELEASE` | The release tag. |
| `--repair-timeout S` | 1800 | How long the app has to reach `ready` after Repair. |

## What the script does

1. Checks the setup (phase `done` or `ready`), Rosetta 2, the GUI session. Quits the app if it runs.
2. Damage, inside `$JOB/appdata` only:
   - removes `appdata/prefix/peakpack/prefix.json` (the original is copied to `logs/G-APP6/prefix.json.orig`);
   - replaces `appdata/runtime/<id>/share/wine/wine.inf` with one line of text (the original is copied to `logs/G-APP6/wine.inf.orig`, and its SHA-256 is recorded);
   - reads the expected hash from the runtime's `manifest.json` (`files.share/wine/wine.inf`, when it is listed).
3. Starts the app with `--options --no-autoplay`. Waits for phase `ready`, `setup` or `error`.
4. Computer-use step CU-repair: the agent runs Repair. Waits up to `--repair-timeout` for phase `ready`.
5. Checks the stamp is back, the runtime file has its original hash (and the manifest's hash when it has one), there is no problem, and `--print-status` says `readyToPlay` true.
6. Records the Steam listings (content, downloading and depotcache folders, names only) and the top level of `~/Library/Application Support` and `~/Library/Preferences`.
7. Computer-use step CU-uninstall: the agent runs Uninstall... > Move to Trash.
8. Waits up to 300 s for `appdata` to disappear. Checks the moved copy in `uninstalled/appdata-*` has `runtime/` and `prefix/`, and reads its status phase if present. Checks the app bundle is still in `$JOB/apps`. Compares the Steam listings with the ones before. Records the home listings as info.
9. Quits the app.

## Computer-use steps

### CU-repair

When the request appears (`$JOB/cu/G-APP6.repair.request`, timeout 600 s):

1. Opens the PEAK menu in the menu bar > Repair... The confirmation alert opens. Takes `repair-alert`.
2. Clicks "Repair" (not "Cancel").
3. Waits until the app shows ready with no error. Takes `repair-done`.
4. Answers ok, or fail with what it shows. If macOS asks for an administrator password, does not type it; takes `dialog-1`, answers fail with its text.

Screenshots: `bash testkit/cu.sh "$JOB" shot G-APP6 repair-alert`, `... shot G-APP6 repair-done`

Answer: `bash testkit/cu.sh "$JOB" done G-APP6.repair ok "ready after repair"`.

### CU-uninstall

When the request appears (`$JOB/cu/G-APP6.uninstall.request`, timeout 600 s):

1. Opens the PEAK menu > Uninstall... The alert opens. Takes `uninstall-alert`.
2. Clicks "Move to Trash" (not "Cancel"). This test build moves the data into the job folder.
3. Waits until the app shows its message screen or its window closes. Takes `uninstall-done`.
4. Answers ok, or fail with what it shows.

Screenshots: `bash testkit/cu.sh "$JOB" shot G-APP6 uninstall-alert`, `... shot G-APP6 uninstall-done`

Answer: `bash testkit/cu.sh "$JOB" done G-APP6.uninstall ok "moved to trash (test build)"`.

Never click a macOS prompt. Never touch Steam.

## Pass / fail criteria

| Criterion id | Check | Pass when |
|---|---|---|
| tampered | damage done inside the job's app data | Pass after the damage. |
| phase_before_repair | (metric) the phase when the app opened | Recorded. |
| cu_repair | agent started Repair and saw ready | The agent answers ok. |
| repair_ready | app reaches phase ready after Repair | Phase `ready` within the repair timeout. |
| prefix_stamp_restored | prefix stamp is back | `appdata/prefix/peakpack/prefix.json` exists. |
| runtime_file_restored | share/wine/wine.inf has its original SHA-256 | Hash equals the saved original. |
| runtime_manifest_match | share/wine/wine.inf matches manifest.json | Hash equals the manifest entry. Skipped when the manifest lists no sha256 for it. |
| no_problem | status has no problem after Repair | No `problem.code`. |
| ready_to_play | `--print-status` says readyToPlay true | `readyToPlay` is `true`. |
| cu_uninstall | agent started the uninstall | The agent answers ok. |
| appdata_removed | app data folder gone after Uninstall | `appdata` no longer exists. |
| uninstalled_copy | moved copy has runtime/ and prefix/ | `uninstalled/appdata-*/runtime` and `/prefix` exist. |
| uninstall_message | app shows phase message after Uninstall | Info unless the moved status says `message`. |
| bundle_kept | app bundle still in the job dir | `PEAK Modded` executable exists. |
| steam_untouched | Steam listings unchanged | Content, downloading and depotcache listings match the before-listing. |
| home_listing | top level of ~/Library Application Support and Preferences | Info only: listed when changed. |
| app_quit | app quit after Uninstall | Quit. |

Overall status: any failed criterion gives fail (exit 1). Missing preconditions give blocked (exit 2). Unanswered CU steps give error (exit 4).

## Results and evidence

- `$JOB/results/G-APP6.json`: criteria, metrics (`phase_before_repair`), versions (`repair_target_original_sha256`), computer_use (repair and uninstall answers).
- `$JOB/logs/G-APP6/`: `prefix.json.orig`, `wine.inf.orig`, `print-status-after-repair.json`, `steam-before.txt`, `steam-after.txt`, `appsupport-before/after.txt`, `prefs-before/after.txt`.
- `$JOB/evidence/G-APP6/`: `repair-alert.png`, `repair-done.png`, `uninstall-alert.png`, `uninstall-done.png`.

## Copy back

- `results/G-APP6.json`, `logs/G-APP6/`, `evidence/G-APP6/*.png`, `cu/G-APP6.*`.
- `$JOB/uninstalled/appdata-*/Logs/` and `frontend/status.json` (the moved copy, if present).

## Paths outside the job dir

- None created. The Steam listings are only read as names. The home listings are read as names and reported as info.
- The Trash is not used in test mode, and the gate does not look into it.

## If it fails or is blocked

- Blocked, no prefix stamp or runtime file: run G-APP1 to G-APP5 first.
- Fail, `cu_repair`: read the repair screenshot. Do not run Repair by script.
- Fail, `repair_ready`: the detail has the phase and problem. Read `appdata/Logs/` (the repair log is in there).
- Fail, `runtime_file_restored`: the runtime file was not reinstalled. Repair reinstalls the runtime when files are damaged; check the app's log.
- Fail, `appdata_removed`: the uninstall did not run or was cancelled. Read the uninstall screenshot.
- Fail, `uninstalled_copy`: the moved copy is incomplete. Read the detail.
- Fail, `steam_untouched`: the listings changed. Check whether Steam itself wrote to them (Steam can run in the background); the detail lists the first differing lines.
- Info, `home_listing`: a top-level entry under ~/Library changed. Look at the diff in `logs/G-APP6/`.
