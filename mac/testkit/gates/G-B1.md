# G-B1: Rosetta probe talks to Mac Steam (T1/T2)

| | |
|---|---|
| Slot | 1 |
| Needs a human | only if Mac Steam is not running (the gate then exits needs-human, exit 3). Otherwise no. |
| Expected run time | 3 min (timeout 10 min) |
| Requires | H-STEAM |
| Run by | `run_slot.sh` (slot 1), or by hand with `run_gate.sh` |

## Purpose

Loads Mac Steam's `steamclient.dylib` in an x86_64 probe under Rosetta 2. It checks that the logged-in Steam account answers: client interface, logged on, a real SteamID, app id 3527290 and an auth session ticket. While the probe holds the connection, the hub's agent checks that Mac Steam shows "Playing PEAK".

## Preconditions

- Rosetta 2 installed (P0 detects it). Without it the gate is blocked (exit 2).
- `steamclient.dylib` in the Steam client folder (H-STEAM bootstraps it). Without it the gate is blocked.
- Mac Steam running (only the `steam_osx` process is checked; no Steam login or config file is read). This gate's `BLoggedOn` is the proof of a signed-in account. If Steam is not running, the gate exits needs-human (exit 3).
- One of these probe sources, or the gate is blocked:
  - Xcode CLT and the Steam test kit. The Steam team's `t1_t2_rosetta_probe.sh` builds the probe with clang.
  - A prebuilt `steam_client_probe-macos-x86_64` in the Steam test kit (`probe/`), or in the kit's `probes/out/` folder.
- The hub's computer-use tools are ready. Mac Steam's window must be visible during the hold.

## Command

```sh
cd "$JOB/kit"
bash testkit/run_gate.sh G-B1 --job-dir "$JOB" -- --hold 90
```

| Argument | Default | Meaning |
|---|---|---|
| `--hold SECONDS` | `90` | How long the probe keeps its connection. The agent check gets `hold - 20` seconds. |
| `--steam-dir DIR` | `$STEAM_MACOS_DIR` | Steam client folder that holds `steamclient.dylib` |

## What the script does

1. Starts the gate, checks that it runs on a Mac, and reads the arguments.
2. Blocks if Rosetta 2 is missing or `steamclient.dylib` is missing.
3. Exits needs-human if Mac Steam is not running. The hub may start it with `open -a Steam` and re-run G-B1.
4. Ensures the Steam test kit is available. If it is not, it notes that and continues.
5. Chooses a mode:
   - **Path A** (CLT and test kit): runs `t1_t2_rosetta_probe.sh` in the background with `--hold`. Logs go to `logs/G-B1/t1_t2/`, output to `t1_t2.out`.
   - **Path B** (no CLT): looks for a prebuilt probe. If none is found, the gate is blocked. Otherwise it copies the probe to the gate's temp folder and checks it is x86_64. If not, the gate ends with error (exit 4). It then runs the probe in the background under `arch -x86_64`, with `STEAM_COMPAT_CLIENT_INSTALL_PATH` set to the Steam client folder and `--lib <steamclient.dylib> --hold <seconds>`. Output goes to `logs/G-B1/probe.log`.
6. Waits 12 seconds, then takes the screenshot `steam-during-probe`.
7. Requests the agent check `playing`, with a timeout of `hold - 20` seconds.
8. Waits for the probe to finish and records its exit code as `probe_exit`.
9. If the probe wrote no log, the gate ends with error (exit 4).
10. Copies the probe log to `probe-copy.log` and reads its RESULT lines.
11. Records the criteria for load, client, logged on, SteamID, app id, ticket and ticket callback. The persona name is not stored. Only `persona_present` (true or false) is recorded.
12. Records `playing_peak` from the agent's answer.
13. Ends the gate. If the gate stops early, the background probe is killed.

## Computer-use steps

### CU-playing

- **When:** about 12 seconds after the probe starts, while it holds the connection. The request is written to `cu/G-B1.playing.request`. Use `bash testkit/cu.sh "$JOB" wait` to see it.
- **Timeout:** `hold - 20` seconds. That is 70 s with the default `--hold 90`.
- **Actions** (run from `$JOB/kit`):
  1. Click the Steam window, or its Dock icon, to bring it forward.
  2. Open the Friends list: Friends > Show Friends List, or the friends icon at the bottom right.
  3. Find your own entry. Look for "Playing PEAK" or "In-Game PEAK".
  4. Save a screenshot: `bash testkit/cu.sh "$JOB" shot G-B1 steam-playing-peak` (saves `evidence/G-B1/steam-playing-peak.png`).
  5. Click nothing else in Steam.
- **Answer ok** (shows PEAK):
  `bash testkit/cu.sh "$JOB" done G-B1.playing ok "Playing PEAK shown"`
- **Answer fail** (shows Online or no game):
  `bash testkit/cu.sh "$JOB" done G-B1.playing fail "<what it showed>"`

## Pass / fail criteria

| Criterion id | Check | Pass when |
|---|---|---|
| `t1_load` | `steamclient.dylib` loads in an x86_64 process under Rosetta | The probe's `load` result is ok |
| `t1_client` | `CreateInterface(SteamClient021)` | The probe's `client` result is ok |
| `t1_logged_on` | `BLoggedOn` | `logged_on` is 1 |
| `t1_steamid` | Real SteamID returned | Non-zero. The detail shows only the last four digits. |
| `t1_appid` | App id 3527290 | `appid` equals the PEAK app id |
| `t2_ticket` | Auth session ticket returned | `ticket_len` is above 0 |
| `t2_ticket_cb` | `GetAuthSessionTicketResponse` is OK | `ticket_callback_result` is 1 (k_EResultOK) |
| `playing_peak` | Mac Steam shows "Playing PEAK" during the hold (agent) | Agent answers ok. Agent answers fail gives fail. Any other result gives skip. |

Status: any fail gives fail. A skip on `playing_peak` is recorded but is not a fail. Blocked (exit 2) when Rosetta 2 is missing, `steamclient.dylib` is missing, or no probe is available. Needs-human (exit 3) when Mac Steam is not running. Error (exit 4) when the prebuilt probe is not x86_64 or no probe log is written.

## Results and evidence

- `results/G-B1.json`: status, exit code, criteria, metrics, computer-use record and notes.
- Metrics: `method` (`t1_t2-script` or `prebuilt-probe`), `probe_exit`, `persona_present` (true or false), `export_Steam_IsKnownInterface`, `export_Steam_NotifyMissingInterface`.
- Logs in `logs/G-B1/`:
  - Path A: `t1_t2.out` and `t1_t2/probe.log`.
  - Path B: `probe.log`.
  - Both: `probe-copy.log` and `console.log`.
- The logs contain the SteamID and the persona name. The results JSON only says whether they are valid.
- Evidence in `evidence/G-B1/`: `steam-during-probe.png` (snap) and `steam-playing-peak.png` (agent step).
- Computer-use files in `cu/`: `G-B1.playing.request` and `G-B1.playing.done`.

## Copy back

- `results/G-B1.json`
- `logs/G-B1/` (contains the SteamID and persona; they stay in the logs)
- `evidence/G-B1/`
- The answer files `cu/G-B1.playing.*`

## Paths outside the job dir

Reads only.

- `steamclient.dylib` in the Steam client folder (`--steam-dir`). The probe loads it.
- The probe connects to the running Mac Steam client.
- Steam records "Playing PEAK" on the account while the probe holds the connection. This is server-side and expected (`slot1.job.json`).

Writes stay in the job dir.

## If it fails or is blocked

- Rosetta 2 missing: blocked. The hub or Joshua installs it with `softwareupdate --install-rosetta` (P0 message). This kit never installs it.
- `steamclient.dylib` missing: blocked. Run H-STEAM first.
- Mac Steam not running: needs-human. Run `open -a Steam` as `fleet`, then re-run G-B1. A sign-in window means Joshua is needed.
- No CLT and no prebuilt probe: blocked. Either the hub installs the CLT (Joshua's call, see P0), or CI adds the prebuilt probe to `peakpack-steam-tests-*` (`NOTES-for-lead.md` R2). Both are named in the script message.
- Prebuilt probe is not x86_64: error (exit 4).
- No probe log: error (exit 4). Check `logs/G-B1/probe.log` or `t1_t2.out`.
- `t1_logged_on` fails: the detail shows `logged_on` and `connected`. Mac Steam is not logged in to the account. Check H-STEAM.
- `playing_peak` fails: Steam shows no game. Look at `evidence/G-B1/steam-playing-peak.png`.
- `playing_peak` skips: no agent answer before the timeout, or the agent skipped.
- The slot continues after this gate fails (`on_fail: continue` in `slot1.job.json`).
