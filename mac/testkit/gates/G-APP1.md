# G-APP1: PEAK (Modded).app, download, verify, first run up to the game step

| | |
|---|---|
| Slot | app (slot-app.job.json) |
| Needs a human | only if Rosetta 2 is missing (exit 3, Joshua installs it). Or Mac Steam is not signed in: the app waits at its steam step over 3 min (exit 3). |
| Expected run time | 25 min (timeout 60 min, see APP-README.md) |
| Requires | H-STEAM |
| Run by | `run_slot.sh` (slot-app) or by hand |

## Purpose

Downloads the modded app release, checks it, starts it the way a friend would (the welcome screen, then "Set Up PEAK") and lets its own setup run up to the game step. The game step is where the app waits for the Steam console paste, which is G-APP2. The app is left running for G-APP2.

## Preconditions

- Network access to github.com for the release assets.
- A logged-in GUI session (`launchctl managername` prints Aqua). Otherwise the gate is blocked.
- Rosetta 2 installed. Otherwise the gate exits needs-human. The kit never clicks the macOS install prompt.
- A new job dir with no `appdata/` in it. A welcome screen is needed; the gate fails if the app was already set up.
- The release tag: `--app-release mac-build-app-<version>`, or env `PP_APP_RELEASE`. Without either, the gate is blocked.
- Mac Steam is signed in under the fleet user for the app's steam step. The app opens Steam itself if it is not running.

## Command

```sh
cd "$JOB/kit"
bash testkit/run_gate.sh G-APP1 --job-dir "$JOB" -- --app-release mac-build-app-0.1.1 [--setup-timeout 1800]
```

| Argument | Default | What it does |
|---|---|---|
| `--app-release TAG` | `$PP_APP_RELEASE`, else the job's `APP_RELEASE` | The release tag. Saved to `job.env`. |
| `--setup-timeout S` | 1800 | Time limit for the app's setup to reach the game step. |

## What the script does

1. Resolves the release tag and saves it. Blocked if there is none.
2. Downloads `SHA256SUMS` and `PEAK-Modded-Mac-<version>.zip` from `https://github.com/jmproulx/peakpack/releases/download/<tag>/`. Verifies the zip's SHA-256 against its `SHA256SUMS` line. Unpacks it with `ditto -x -k` into `$JOB/apps/PEAK (Modded).app`. A mismatch fails the gate. A download failure blocks it.
3. Static checks: `codesign --verify --deep --strict`; `lipo -archs` for arm64 and x86_64 (only with the Command Line Tools installed, else skipped); `Info.plist` `LSMinimumSystemVersion` is 12.0; `NSMicrophoneUsageDescription` is present; `PEAK Modded --version` prints a version; `--print-status --data-dir $JOB/appdata` prints JSON with `schema` 1 and a `nextStep` key (saved as `logs/G-APP1/print-status-fresh.json`).
4. Requires the GUI session and Rosetta 2.
5. Starts the app with `open -n "PEAK (Modded).app" --args --data-dir $JOB/appdata --skip-update-check --uninstall-to $JOB/uninstalled --no-autoplay`. Waits up to 60 s for phase `welcome`.
6. Computer-use step CU-welcome: the agent clicks "Set Up PEAK".
7. Polls `frontend/status.json` every 3 s. Records the seconds spent in each step (`step_<name>_s`). Fails at once on phase `error`. Finishes needs-human if the step `steam` is not done for over 3 min. Waits until step `game` with stepState `waiting-for-user`, up to 30 min.
8. Records the runtime id, the prefix stamp `appdata/prefix/peakpack/prefix.json`, and whether the status has a problem.
9. Leaves the app running. Nothing is quit.

## Computer-use steps

### CU-welcome

When the request appears (`$JOB/cu/G-APP1.welcome.request`, timeout 600 s), the agent:

1. Takes the screenshot `app-welcome` (before the click).
2. Clicks "Set Up PEAK" (bottom right of the welcome window). Clicks nothing else.
3. Answers ok once the setup screen has started, or fail with what it shows.

Screenshot: `bash testkit/cu.sh "$JOB" shot G-APP1 app-welcome`

Answers: `bash testkit/cu.sh "$JOB" done G-APP1.welcome ok "setup started"` or `... fail "<what you see>"`.

Never type credentials. Never click a macOS prompt (Rosetta, microphone, files). If one appears, screenshot it as `dialog-<n>` and answer fail with its text.

## Pass / fail criteria

| Criterion id | Check | Pass when |
|---|---|---|
| app_tag | app release tag | A valid `mac-build-app-*` tag is in use. |
| app_download | app zip downloaded and matches its SHA256SUMS | SHA-256 equals the `SHA256SUMS` entry. A mismatch or an unlisted zip is fail. |
| app_bundle | `PEAK (Modded).app` unpacked into the job dir | The executable exists after `ditto`. |
| codesign | `codesign --verify --deep --strict` | Exit 0. |
| lipo_archs | executable has arm64 and x86_64 slices | Both present. Skipped without the CLT. |
| min_macos | `LSMinimumSystemVersion` is 12.0 | Exactly `12.0`. |
| mic_usage | `NSMicrophoneUsageDescription` present | The key exists. |
| version_cli | `--version` prints a version | Exit 0 and a non-empty first line. |
| print_status | `--print-status` JSON: schema 1 and nextStep | Exit 0, schema `1`, key `nextStep` present. |
| gui_session | running in the GUI session | Via `gate_require_gui`: otherwise blocked. |
| first_run_welcome | the welcome screen appears within 60 s | Phase `welcome` is reached. |
| cu_welcome | agent clicked Set Up PEAK | The agent answers ok. |
| setup_error | setup runs without an error | Phase never becomes `error`. |
| setup_to_game | the app reaches the game step | Step `game`, stepState `waiting-for-user`, within the setup timeout. |
| runtime_id | runtime id reported | `runtimeId` is not empty. |
| prefix_stamp | Wine prefix stamp exists | `appdata/prefix/peakpack/prefix.json` exists. |
| no_problem | status has no problem | No `problem.code`. |

Overall status: any failed criterion gives fail (exit 1). Rosetta missing or a long steam wait gives needs-human (exit 3). A missing release tag or a missing GUI session gives blocked (exit 2). A timeout gives error (exit 4).

## Results and evidence

- `$JOB/results/G-APP1.json`: criteria, metrics (`step_<name>_s`, `time_to_game_s`, `app_min_macos`), versions (`app_release`, `app_zip_sha256`, `app_version`, `app_runtime_id`, `app_macos_min`), computer_use (the welcome answer).
- `$JOB/logs/G-APP1/`: `console.log`, `codesign.txt`, `version.out`, `print-status-fresh.json`.
- `$JOB/evidence/G-APP1/`: `app-welcome.png` (agent, via cu.sh shot).
- The app's own logs: `$JOB/appdata/Logs/` (`PEAK Modded.log`, `prefix.log`, `launcher.log`, ...).

## Copy back

- `results/G-APP1.json`, `logs/G-APP1/`, `evidence/G-APP1/*.png`, `cu/G-APP1.*`.
- `$JOB/appdata/Logs/`, `$JOB/appdata/frontend/status.json`, `state.json`.
- Or `bash testkit/collect.sh "$JOB"`.

## Paths outside the job dir

- Steam: nothing is written by this gate. The app's steam step may start Steam (Steam writes its own files; the kit does not read them).
- Anything the app writes under `~/Library` is unknown until the first run. Note it in the result (`notes`) and in APP-README.md, and list it in the slot's outside_paths once seen.
- The Wine server socket `/tmp/.wine-<uid>/` for the app's prefix stays while the app runs. G-APP6 stops it.

## If it fails or is blocked

- Blocked, no release tag: pass `--app-release mac-build-app-<version>` or set `PP_APP_RELEASE`.
- Blocked, no GUI session: run the kit from the logged-in desktop session (see the README).
- Blocked, download failed: check the network to github.com and that the release exists.
- Fail, `app_download` (mismatch): the release's zip does not match SHA256SUMS. Do not run the app. Report it.
- Fail, `codesign`, `min_macos`, `version_cli`, `print_status`: read `logs/G-APP1/codesign.txt`, `version.out` and `print-status-fresh.json`.
- Needs-human, Rosetta missing: Joshua installs Rosetta 2 with macOS's own prompt, then re-run.
- Needs-human, steam step over 3 min: Mac Steam is not running or not signed in under fleet. Joshua signs in (H-STEAM), then re-run. Setup resumes.
- Fail, `first_run_welcome`: the job already has `appdata/`. Use a new job dir.
- Fail, `setup_error`: read `problem.code` and `problem.heading` (in the detail), and `appdata/Logs/`.
- Fail, `setup_to_game`: read the last step in the detail, and the step timings in the metrics.
