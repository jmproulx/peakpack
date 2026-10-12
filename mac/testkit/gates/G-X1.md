# G-X1: Cross-play Mac to Windows (human)

| | |
|---|---|
| Slot | 3 |
| Needs a human | yes: Joshua at the iMac, and the pilot friend on Windows with their own Steam account. Without `PP_HUMAN_PRESENT=1` the gate exits 3 with the instructions. |
| Expected run time | 60 min (no timeout in the job file; the gate's own text says about 45 min; the step timeouts add up to 125 min at most) |
| Requires | G-D2 |
| Run by | By hand, with `PP_HUMAN_PRESENT=1`, once both people are ready. `run_slot.sh` (slot 3) only records needs-human. |

## Purpose

Tests cross-play between the modded PEAK on the Mac and PEAK on Windows, with a second player. The steps cover room-code joins both ways, Steam friends-list joins both ways, voice with the built-in microphone, the PeakPack companion's lobby check, and four networked mods: heli (HeliPilot), glider (ElytraGlider), item tuner (ItemTuner) and scoutmaster (ScoutmasterMode). Each step is a human judgement that the agent records. The gate starts the modded PEAK and, at the end, runs the Steam team's checklist on the Player.log.

## Preconditions

- G-D2 passed in this job (modded PEAK works on the Mac). The gate checks only that the mods are synced in the job's prefix (the BepInEx Preloader is present).
- Mac Steam running and signed in with Joshua's account (H-STEAM). The gate exits 3 if Steam is not running.
- The runtime, PEAK in the job dir (G-B5), and `PeakPack.exe` (downloaded if needed).
- The friend's Windows PC has PeakPack synced to the same pack revision. PeakPack shows the revision. The Mac's revision is in `results/G-D2.json`, metric `installed_revision`. The friend has their own Steam account.
- Joshua at the iMac for voice. He speaks and listens, and he answers the macOS microphone prompt (see H-MIC).
- `PP_HUMAN_PRESENT=1` set, once both people are ready.
- The hub's agent drives the Mac and takes the screenshots. No credentials change hands.
- H-MIC runs in parallel.

## Command

```sh
cd "$JOB/kit"
PP_HUMAN_PRESENT=1 bash testkit/run_gate.sh G-X1 --job-dir "$JOB"
```

No arguments.

Environment: `PP_HUMAN_PRESENT`. Set to 1, the gate runs the session. Unset or any other value, the gate prints the instructions and exits 3 at once.

## What the script does

1. Loads `lib/common.sh` and `lib/assets.sh` and starts the result. Blocks if this is not macOS.
2. Sets the instruction text (`INSTR`).
3. If `PP_HUMAN_PRESENT` is not 1: needs-human, exit 3, with the instructions. The gate stops here.
4. Exits needs-human if Mac Steam is not running.
5. Keeps the Mac awake. Blocks if the runtime is not available. Makes the test kit and the bridge available (their output is hidden, and their status is not checked). Errors if the Wine prefix cannot be created. Blocks if PEAK is not in the job dir, or if `PeakPack.exe` is not available.
6. Blocks if the mods are not synced in the prefix (the BepInEx Preloader is missing from the PeakPack folder).
7. Sets the cleanup to stop Wine when the gate ends.
8. Copies the launcher and `steamclient64.dll` into `drive_c/PeakPackTests` in the prefix.
9. Starts the launcher with `--no-launch --hold-ms 9000000` in the background (log `C:\PeakPackTests\launcher-x1.log`). Waits 8 s.
10. Runs `PeakPack.exe --headless --launch --launch-method direct --game-dir C:\Games\PEAK` with `winhttp=n,b` overrides. Status goes to `x1-launch.json`.
11. Waits up to 300 s for "Steam runtime manager initialized" in Player.log. If it does not appear, the gate ends with status fail: "modded PEAK did not start (no Steam line in Player.log)".
12. Runs the five CU steps in this order: `lobby`, `steamjoin`, `voice`, `companion`, `mods`. Each step writes one criterion with the same name. Ok gives pass. Fail gives fail. Skip or timeout gives skip. The steps run in sequence whatever the earlier answers were.
13. Records the mods metrics (`mod_heli`, `mod_glider`, `mod_itemtuner`, `mod_scoutmaster`) from the `mods` answer, where they are present.
14. Copies Player.log into `logs/G-X1/`.
15. If the test kit has `mac/t6_t14_checklist.sh`: runs it on the Player.log copy, writes `logs/G-X1/t6_t14_checklist.txt`, and adds a note with how many T6 to T8 markers were found.
16. Writes the result JSON and exits.

## Computer-use steps

Each step is requested in turn. The agent answers with `cu.sh done`. The first line of the answer is ok, fail or skip. Values for the script go after the note, as key=value arguments.

### CU-lobby

- **When:** after PEAK starts. Timeout 1800 s.
- **Actions** (with Joshua and the friend on a call):
  1. On the Mac, choose Play and host a lobby. Read out the room code. The friend joins by that code from Windows.
  2. Take a screenshot with both scouts visible: `bash testkit/cu.sh "$JOB" shot G-X1 x1-a-mac-host`.
  3. Leave. The friend hosts. The Mac joins with the friend's code.
  4. Take a screenshot: `bash testkit/cu.sh "$JOB" shot G-X1 x1-b-mac-joined`.
- **Answer ok** when both directions worked: `bash testkit/cu.sh "$JOB" done G-X1.lobby ok "room code both ways"`
- **Answer fail:** `bash testkit/cu.sh "$JOB" done G-X1.lobby fail "<which direction failed, and the message>"`

### CU-steamjoin

- **When:** after CU-lobby. Timeout 1800 s.
- **Actions:**
  1. The friend right-clicks the Mac account in their Steam friends list and chooses Join Game, while the Mac hosts. Screenshot: `bash testkit/cu.sh "$JOB" shot G-X1 x1-c`.
  2. The Mac joins the friend from Mac Steam's friends list (Join Game). Screenshot: `bash testkit/cu.sh "$JOB" shot G-X1 x1-d`.
  3. Pressing the in-game invite button on the Mac is expected to do nothing. Record it if it crashes.
- **Answer ok:** `bash testkit/cu.sh "$JOB" done G-X1.steamjoin ok "both directions"`
- **Answer fail:** `bash testkit/cu.sh "$JOB" done G-X1.steamjoin fail "<details>"`

### CU-voice

- **When:** after CU-steamjoin. Timeout 900 s.
- **Actions:**
  1. Joshua speaks near the iMac's built-in microphone. The friend confirms they hear him.
  2. The friend speaks. Joshua confirms he hears them on the Mac.
  3. If a macOS microphone prompt appears, leave it for Joshua (H-MIC). Do not click it.
- **Answer ok** if both directions are audible: `bash testkit/cu.sh "$JOB" done G-X1.voice ok "audible both ways"`
- **Answer fail:** `bash testkit/cu.sh "$JOB" done G-X1.voice fail "<direction that failed>"`

### CU-companion

- **When:** after CU-voice. Timeout 600 s.
- **Actions:**
  1. In the shared lobby, check that there is no pack or version mismatch notice on either side.
  2. Screenshot: `bash testkit/cu.sh "$JOB" shot G-X1 x1-e-lobby-check`.
- **Answer ok:** `bash testkit/cu.sh "$JOB" done G-X1.companion ok "no mismatch"`
- **Answer fail:** `bash testkit/cu.sh "$JOB" done G-X1.companion fail "<message shown>"`

### CU-mods

- **When:** after CU-companion. Timeout 2400 s.
- **Actions:**
  1. Start a run together.
  2. For each mod (heli, glider, itemtuner, scoutmaster): one player uses it and the other confirms it looks right. No desync, no teleporting, and items are consistent.
  3. Screenshot each mod: `bash testkit/cu.sh "$JOB" shot G-X1 x1-mod-<name>`. The script does not fix `<name>`. Use the answer keys below: heli, glider, itemtuner, scoutmaster.
- **Answer ok, with each mod's result:** `bash testkit/cu.sh "$JOB" done G-X1.mods ok "all four consistent" heli=ok glider=ok itemtuner=ok scoutmaster=ok`
- **Answer fail, with the per-mod results:** `bash testkit/cu.sh "$JOB" done G-X1.mods fail "<what failed>" heli=ok glider=fail itemtuner=ok scoutmaster=ok`
- The criterion depends only on ok or fail. The per-mod values are recorded as metrics `mod_<name>` and are not checked. Answer fail if any mod misbehaves.

## Human instructions

Printed by the gate when `PP_HUMAN_PRESENT` is not 1:

- **Before:** G-D2 passed in this job. The friend's Windows PC has PeakPack synced to the same pack revision. PeakPack shows the revision. The Mac's is in `results/G-D2.json`, metric `installed_revision`.
- **People:** Joshua at the iMac (fleet user), who speaks and listens for the voice test and answers the macOS microphone prompt. The pilot friend on Windows with their own Steam account. The hub's agent drives the Mac and takes screenshots.
1. Joshua tells the hub "G-X1 go". The hub re-runs: `PP_HUMAN_PRESENT=1 bash run_gate.sh G-X1 --job-dir <job>`, and H-MIC with `PP_HUMAN_PRESENT=1` in parallel.
2. The agent hosts a lobby on the Mac. The friend joins by room code. Then the reverse: the friend hosts, and the Mac joins.
3. Steam join both ways. The friend uses Join Game on the Mac account in their Steam friends list. Then the Mac joins the friend from Mac Steam's friends list. The in-game invite button on the Mac does nothing. That is expected (T11).
4. Voice both ways with the built-in microphone (not AirPods).
5. The PeakPack companion's lobby check shows the same revision on both sides, with no mismatch warning.
6. Networked mods: heli (HeliPilot), glider (ElytraGlider), item tuner (ItemTuner), scoutmaster (ScoutmasterMode). Each is used by one player and seen correctly by the other.
- **Pass:** everything above works, with no desync.
- **Copy back:** `results/G-X1.json`, `logs/G-X1/`, `evidence/G-X1/`.

## Pass / fail criteria

| Criterion id | Check | Pass when |
|---|---|---|
| `lobby` | room-code join works both ways | Pass on ok. Fail on fail. Skip on skip or timeout. |
| `steamjoin` | Steam friends-list join works both ways | Pass on ok. Fail on fail. Skip on skip or timeout. |
| `voice` | voice works both ways (built-in mic) | Pass on ok. Fail on fail. Skip on skip or timeout. |
| `companion` | companion lobby check: same pack revision, no mismatch | Pass on ok. Fail on fail. Skip on skip or timeout. |
| `mods` | networked mods behave the same on both sides | Pass on ok. Fail on fail. Skip on skip or timeout. The per-mod values are recorded, not checked. |

There is no criterion for "no desync" or for the launch. A launch failure ends the gate with status fail, before any step runs.

How the overall status is decided (from `lib/common.sh`):

- Any step fails: status fail, exit 1.
- Otherwise, any step passes: status pass, exit 0.
- Only skips (for example, every step timed out): status error, exit 4.
- A skipped step does not block a pass. If only some steps were answered ok, the gate can still report pass. Check all five criteria in `results/G-X1.json`.

## Results and evidence

- `results/G-X1.json`: status, criteria, CU answers, evidence list, notes.
- Metrics: `mod_heli`, `mod_glider`, `mod_itemtuner`, `mod_scoutmaster` (strings, from the `mods` answer, where given).
- Versions: `runtime_id`, `steam_tests`, `peakpack_exe_sha256`, and the other version keys set by the runtime and test kit setup.
- `logs/G-X1/`: `Player.log` (a copy), `launcher.out`, `peakpack-launch.out`, `t6_t14_checklist.txt` (if the checklist ran), `cu-<step>.answer.txt` for each step.
- In the prefix: `drive_c/PeakPackTests/launcher-x1.log` and `x1-launch.json`.
- `evidence/G-X1/`: `x1-a-mac-host.png`, `x1-b-mac-joined.png`, `x1-c.png`, `x1-d.png`, `x1-e-lobby-check.png`, and one `x1-mod-<name>.png` per mod.
- `cu/`: the requests and answers for the five steps.

## Copy back

- `results/G-X1.json`, `logs/G-X1/` and `evidence/G-X1/` (from the job file).
- `bash testkit/collect.sh "$JOB"` also packs `cu/` and `state/`.
- The H-MIC result is copied back with this one.

## Paths outside the job dir

- `/tmp/.wine-<uid>/server-*`: the Wine server socket of the prefix. `cleanup.sh` removes it.
- Mac Steam and Joshua's account are used as they are. Steam-side records of playtime and "Playing PEAK" on his account are expected.
- The macOS microphone permission (TCC) for the app that started Wine. This is covered in H-MIC. Joshua may switch it off again afterwards.
- The friend's Windows PC is outside the Mac and outside the kit.

## If it fails or is blocked

- **Needs a human, without `PP_HUMAN_PRESENT=1`:** run the gate by hand with the variable set, when both people are ready.
- **Needs a human, Mac Steam not running:** run H-STEAM.
- **Blocked, "mods are not synced in this job's prefix":** run G-D2 in this job first.
- **Blocked, PEAK not in the job dir (G-B5), runtime not available (G-A1), or `PeakPack.exe` not available:** run the missing gate, then re-run.
- **Error, prefix creation failed:** the prefix could not be made.
- **Fail, "modded PEAK did not start":** check `logs/G-X1/peakpack-launch.out` and `prefix/drive_c/PeakPackTests/launcher-x1.log` (and `x1-launch.json`). The gate copies Player.log only at the end, so read the live log in the prefix.
- **A step fails:** the agent's message says what failed. The other steps still run.
- **A step times out:** it is recorded as skip. The other steps still run.
- **Desync or teleporting:** the gate has no check for it. The agent answers `fail` on the step where it happens.
- **Error (exit 4):** every step was skipped, or the watchdog or a signal stopped the gate. Wine is stopped by the cleanup.
- **The Steam invite button crashes on the Mac:** record it in the answer. The job file says the button is expected to do nothing.
