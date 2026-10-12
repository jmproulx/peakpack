# H-STEAM: Mac Steam signed in

| | |
|---|---|
| Slot | 1 |
| Needs a human | only if Steam is not signed in (Joshua signs in once and ticks Remember me) |
| Expected run time | 1 min (timeout 3 min) |
| Requires | nothing |
| Run by | `run_slot.sh` (slot 1), or by hand with `run_gate.sh` |

## Purpose

Checks that Mac Steam is installed, running and signed in under the macOS user `fleet`. It reads Steam's login files first. If they do not confirm a login and Steam is running, it asks the hub's agent to look at the Steam window. It never starts, stops or changes Steam, and it never types credentials.

## Preconditions

- `Steam.app` in `/Applications` or `~/Applications`. Without it the gate is blocked (exit 2).
- The kit is set up at `$JOB/kit`.
- Runs as macOS user `fleet` on the iMac.
- For the agent check: Steam is running and the hub's computer-use tools can see and control the screen.
- On the first run, Joshua has signed in to Mac Steam once (human step, see below).

## Command

```sh
cd "$JOB/kit"
bash testkit/run_gate.sh H-STEAM --job-dir "$JOB"
```

No arguments.

## What the script does

1. Starts the gate and checks that it runs on a Mac.
2. Checks that `Steam.app` is in `/Applications` or `~/Applications` (`steam_app`). If not, the gate ends blocked (exit 2).
3. Checks that `steamclient.dylib` exists in the Steam client folder (`steam_boot`, info).
4. Checks whether `steam_osx` is running (`steam_running`, info).
5. Reads the login state (`steam_login_state`). Records the first word as metric `login_state` and the rest as `login_evidence`. `steam_login` passes when the state starts with `yes`. Otherwise it is info.
6. Records the Steam client version as `steam_client`, if readable.
7. Takes a screenshot named `h-steam-screen` with the kit's snap helper.
8. If a login is shown in the files, the gate ends pass.
9. If Steam is running and no login is shown, requests the agent check `signed_in` (300 s timeout). An answer of ok passes the gate (`steam_login_cu`). Any other answer records info and continues.
10. Otherwise the gate ends needs-human (exit 3) with the sign-in steps for Joshua in `human.instructions`. If the state starts with `unknown remembered`, the message says the hub may open Steam with `open -a Steam` and re-run the gate. Joshua is needed only if a sign-in window then appears.

## Computer-use steps

### CU-signed_in

- **When:** Steam is running and the files do not show a login. The request is written to `cu/H-STEAM.signed_in.request`. Use `bash testkit/cu.sh "$JOB" wait` to see it.
- **Timeout:** 300 s.
- **Actions** (run from `$JOB/kit`):
  1. Click the Steam icon in the Dock to bring its window to the front.
  2. Look at the window. A signed-in window shows the Store or Library, with the account name at the top right. A sign-in window or a Steam Guard prompt means not signed in.
  3. Save a screenshot: `bash testkit/cu.sh "$JOB" shot H-STEAM steam-window` (saves `evidence/H-STEAM/steam-window.png`).
  4. Type no credentials. Click nothing on any macOS prompt.
- **Answer ok** (signed in):
  `bash testkit/cu.sh "$JOB" done H-STEAM.signed_in ok "account signed in"`
- **Answer fail** (sign-in window or Steam Guard prompt):
  `bash testkit/cu.sh "$JOB" done H-STEAM.signed_in fail "sign-in window shown"`

## Pass / fail criteria

| Criterion id | Check | Pass when |
|---|---|---|
| `steam_app` | Steam.app installed | Found. Not found sets blocked (exit 2). |
| `steam_boot` | Client bootstrapped | `steamclient.dylib` exists. Info otherwise. |
| `steam_running` | `steam_osx` running | Running. Info otherwise. |
| `steam_login` | Account logged in (files) | Login state starts with `yes`. Info otherwise. |
| `steam_login_cu` | Agent sees a signed-in window | The agent answers ok. Info otherwise. Written only when Steam runs and the files show no login. |

Status: pass when the files show a login, or the agent answers ok. Blocked (exit 2) when `Steam.app` is missing. Needs-human (exit 3) when Steam is not signed in or not running. No criterion sets fail directly.

## Results and evidence

- `results/H-STEAM.json`: status, exit code, criteria, metrics, versions, computer-use record and the human instructions when needs-human.
- Metrics: `login_state` (first word, for example `yes` or `unknown`), `login_evidence`.
- Versions: `steam_client` (if readable).
- Logs in `logs/H-STEAM/`: `console.log`.
- Evidence in `evidence/H-STEAM/`: `h-steam-screen.png` (snap), `steam-window.png` (agent step, if run).
- Computer-use files in `cu/`: `H-STEAM.signed_in.request` and `H-STEAM.signed_in.done`.

## Copy back

- `results/H-STEAM.json`
- `logs/H-STEAM/`
- `evidence/H-STEAM/`
- The answer files `cu/H-STEAM.signed_in.*`

## Paths outside the job dir

Reads only. The gate does not start, stop or change Steam.

- `/Applications/Steam.app` and `~/Applications/Steam.app`: existence and version.
- The Mac Steam client folder: `steamclient.dylib` existence.
- Steam's login files, `registry.vdf` and `loginusers.vdf`.
- The running process list (`steam_osx`).

## If it fails or is blocked

- `Steam.app` missing: blocked (exit 2). The hub installs Steam from store.steampowered.com/about. That install needs no sign-in. Re-run H-STEAM after it.
- Not signed in: needs-human (exit 3). Relay the printed instructions to Joshua. He signs in with his own account, approves Steam Guard, ticks Remember me and leaves Steam running. Then re-run H-STEAM and continue with `run_slot.sh --from G-B0` (from `slot1.job.json`).
- Remembered login but Steam not running: the hub may run `open -a Steam` and re-run H-STEAM. Joshua is needed only if a sign-in window appears.
- The agent sees a sign-in window or a Steam Guard prompt (answer fail): needs-human. Do not type credentials. Joshua signs in.
- No answer within 300 s: the script treats it as not confirmed, so the gate is needs-human.
- Never quit Steam. Never click Allow on a macOS privacy prompt.
