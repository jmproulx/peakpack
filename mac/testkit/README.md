# PeakPack for Mac: non-interactive Mac test kit

*`mac/testkit/` in `jmproulx/peakpack` (locally `C:\Users\joshu\PeakMods\MacPort\testkit\`). Kit version: see `VERSION`. MIT licence.*

This kit runs the DESIGN §7 gates on the **M1 iMac** under the macOS user **`fleet`**, driven by Joshua's Mac fleet hub. Nobody connects to the Mac. The hub's machine-running agent:

1. downloads the kit;
2. runs our scripts in our slot (the screen is ours during the slot);
3. performs the **computer-use (CU) steps** the scripts ask for, such as clicking in Steam or PEAK, reading the screen and taking screenshots;
4. copies results back.

Joshua ideally does **one** thing: sign in to Mac Steam under `fleet` once (gate H-STEAM).

## Files

| Path | What |
|---|---|
| `run_gate.sh <gate> [--job-dir DIR] [--release TAG] [-- args]` | Runs one gate with a watchdog. Writes `results/<gate>.json`, `logs/<gate>/`, `evidence/<gate>/` |
| `run_slot.sh <slot.job.json>` | Runs a slot's gates in order. Skips a gate as *blocked* when a required gate did not pass. Pre-announces early CU steps. Writes `results/summary.{json,txt}` |
| `cu.sh <job> list\|show\|wait\|done\|shot` | The agent's side of the CU handshake |
| `collect.sh <job>` | Builds `copyback/peakpack-<job>-results.tar.gz` (results, logs, evidence, CU answers, state) |
| `cleanup.sh <job> [--dry-run]` | Stops our processes, removes what the job created outside the job dir (only what did not exist before), then deletes the job dir |
| `gates/<gate>.sh`, `gates/<gate>.md` | One script per gate, plus its documentation: purpose, command, CU steps, criteria, copy-back |
| `lib/common.sh`, `lib/assets.sh`, `lib/json_flat.awk` | Results/JSON, detection, CU handshake; release download and verification, Wine helpers; a JSON reader in POSIX awk |
| `slot1.job.json`, `slot3.job.json`, `slot4.job.json` | Job specs in the hub's form. Slot 1 is the main one (about 2 h of machine time) |
| `JOBSPEC-TEMPLATE.md` | How a job spec is built, for new slots |
| `probes/d3d11_clear.c` | D3D11 clear/present/read-back probe for G-A1 (CI builds it; see `NOTES-for-lead.md`) |
| `expect/peak-win-2.6.b-build25739797.manifest` | Per-file SHA-256 reference of PEAK 2.6.b (Windows depot), for G-B5 |
| `NOTES-for-lead.md` | Requests to the runtime/Steam/CI/PeakPack owners, and open questions |
| `gates/X-SLEEP.sh`, `tests/runner_restart_test.sh` | Kit self-test, in no slot: CI checks that stopping a `run_gate` and starting a new one in the same job dir never touches the new run. `run_gate` takes a per-gate runner lock (a second runner waits up to 60 s, then exits 4) and gives each gate a private PID file |
| `slot-app.job.json`, `lib/app.sh`, `gates/G-APP*.sh`, `gates/APP-README.md` | The PEAK (Modded).app slot (written by the Mac app lead): app release `mac-build-app-*`, its own data in `$JOB/appdata` |

## Gates

| Gate | Slot | What it shows | Needs a human | Machine time (timeout) |
|---|---|---|---|---|
| **P0** | 1 | Preflight. Reports macOS, arch, Rosetta, CLT, disk, Steam, screencapture and network. Never installs anything | no | 3 min (10) |
| **H-STEAM** | 1 | Mac Steam is running (never reads login/config files; G-B1 proves the login) | only if a sign-in window appears | 1 min (3) |
| **G-B0** | 1 | T0: `steamclient.dylib` has an x86_64 slice and the exports lsteamclient needs | no | 1 min (5) |
| **G-B1** | 1 | T1/T2: an x86_64 probe under Rosetta gets the SteamID, the logged-on state and an auth ticket. Mac Steam shows "Playing PEAK" | no | 3 min (10) |
| **G-A1** | 1 | Runtime boots. Release assets verified; prefix in the job dir; wineboot, `cmd`, `reg`, `regedit`; D3D11 through DXMT | no | 20 min (60) |
| **G-B5** | 1 | T15: game files via Mac Steam `download_depot 3527290 3527291` (CU), verified against the Windows reference, moved into the job dir | no | 30 min (100) |
| **G-B2** | 1 | T3–T5: bridge in Wine (forwarder, PEAK's `steam_api64.dll`, PEAK itself). Main menu renders (DXMT proof) | no | 10 min (40) |
| **G-D2** | 1 | PeakPack in the prefix: `--sync`; the modded launch loads every pack plugin; the vanilla launch has no BepInEx | no | 20 min (45) |
| **G-A2-lite** | 1 | Short performance run: Metal HUD, solo to the Shore, 2 min. Memory sampled every 10 s | no | 15 min (50) |
| **G-X1** | 3 | Cross-play with a friend: room code, Steam join, voice, companion, networked mods | **yes** (Joshua and a friend) | 60 min (150) |
| **H-MIC** | 3 | Microphone prompt for voice | **yes** (privacy decision) | with G-X1 |
| **G-C0** | 4 | Native smoke with the Unity Mac player: (a) stock data, (b) shaders converted on the Mac | no | 60 min (150) |
| **G-A2-CX** | 4 (optional) | CrossOver baseline for G-A2's 90 % criterion | **yes** (trial and licence are Joshua's call) | detect only |
| **G-APP1…G-APP6** | app slot | PEAK (Modded).app (prerelease `mac-build-app-*`): first run and setup, game step (Steam console paste or an existing PEAK folder) with PeakPack and mods, daily launch, modded/vanilla options, repair, uninstall. Details in `gates/APP-README.md` | no (computer use for clicks and the console paste) | 45 / 130 / 30 / 30 / 25 / 60 min (timeouts) |

The exact pass/fail criteria are in each `gates/<gate>.md` and in `results/<gate>.json → criteria[]`.

## How a slot runs

```sh
JOB=~/peakpack-test/slot1-20261013-0900          # the hub picks the job id
mkdir -p "$JOB/kit"
curl -fsSL https://github.com/jmproulx/peakpack/archive/refs/tags/mac-testkit-0.3.11.tar.gz \
  | tar -xz -C "$JOB/kit" --strip-components=2 peakpack-mac-testkit-0.3.11/mac
cd "$JOB/kit"
launchctl managername                     # must print Aqua (the logged-in desktop session), see below
bash testkit/run_slot.sh testkit/slot1.job.json --job-dir "$JOB" --release mac-build-runtime-pp1-cx26.3.0 > "$JOB/run_slot-console.txt" 2>&1 &
bash testkit/cu.sh "$JOB" wait            # repeat: do the step in gates/<gate>.md, then answer it
bash testkit/cu.sh "$JOB" done G-B5.download ok "complete" path="/Users/fleet/…/depot_3527291" manifest=123
# when run_slot has finished:
bash testkit/collect.sh "$JOB"           # copy back $JOB/copyback/peakpack-<job>-results.tar.gz
bash testkit/cleanup.sh "$JOB"           # removes the job dir, the kit and what the job created
```

**Standalone use.** The kit also works when handed over as a tarball of `testkit/` alone. It then takes the Steam team's gate scripts from the release asset `peakpack-steam-tests-*.tar.xz` instead of `../runtime/steam/tests`.

**Invocation.** Always run scripts as `bash <script>`. Exec bits may not survive a Windows checkout.

**Exit codes** (every gate, and `run_gate.sh`):

| Code | Meaning |
|---|---|
| 0 | pass |
| 1 | fail |
| 2 | blocked: a precondition is missing |
| 3 | needs-human: the printed instructions are also in `results/<gate>.json → human.instructions` |
| 4 | error, including a watchdog timeout |

## Computer-use handshake

Some steps need eyes and hands: typing in Steam's console, driving PEAK's menus, reading the Metal HUD. A gate asks for one by writing two things:

- the file `$JOB/cu/<gate>.<step>.request`, with key=value lines, `---`, then the instruction;
- the line `[CU-REQUEST] <gate>.<step> …` in its console.

It then waits, up to the timeout written in the request. The agent:

1. Reads the request with `cu.sh <job> show <gate>.<step>`, together with `gates/<gate>.md` section **CU-&lt;step&gt;**.
2. Does the steps.
3. Saves screenshots with `cu.sh <job> shot <gate> <name>`. They go to `evidence/<gate>/<name>.png`.
4. Answers with `cu.sh <job> done <gate>.<step> ok|fail|skip "note" key=value…`. The note is optional: `done G-A2-lite.menu ok fps=58` also works.

How answers are handled:

- **Pre-answers.** An answer written before the request appears is accepted at once. `run_slot.sh` pre-announces the long G-B5 depot download, so it runs in Steam while other gates run.
- **Re-runs.** An answer consumed by an earlier run of the same gate is archived, so a re-run asks again.
- **`--no-cu`** (`PP_CU=none`) answers every request "skip" at once. This is for script-only dry runs.

Rules for the agent, in every gate:

- Never type a password or a Steam Guard code.
- Never click **Allow** on a macOS privacy prompt (microphone, files). Leave it for Joshua and take a screenshot.
- Never quit, update or reconfigure Steam.
- Never open the Steam overlay or invite anyone, except in G-X1.
- If an unexpected dialog appears (a crash reporter or "wine wants to…"), take a screenshot named `dialog-<n>` and describe it in the next answer.

## Results

`results/<gate>.json` (schema 1) contains:

- `gate`, `title`, `status`, `exit_code`, `reason`;
- `started`, `finished`, `duration_s`, `job_id`, `kit_version`, `release`;
- `versions{}`: macOS, build, arch, runtime_id, wine, steam_client, peak_version, pack_revision, peakpack_app, …;
- `criteria[]`: `{id, result: pass|fail|skip|info|warn, check, detail}`;
- `metrics{}`;
- `computer_use[]`: each step's answer;
- `evidence[]`: every log and screenshot path, relative to the job dir;
- `human{needed, instructions}`;
- `notes[]`.

Privacy: SteamIDs and persona names stay in `logs/`. The JSON only records that they were valid (the last 4 digits of the SteamID).

## Where things are written

**No macOS prompts by default:** the kit never runs `screencapture` unless `PP_SCREENSHOTS=1`, because it would raise the Screen Recording prompt. It opens `steam://open/console` only when computer-use steps run (not with `--no-cu`). Evidence screenshots are the hub's job. See NOTES-for-lead.md, "macOS prompts".

**Steam test kit:** the probes and Steam test scripts come from the tests-only prerelease that the slot file pins under `steam_tests.tag` (currently `mac-build-steam-tests-1.2.1`, built by CI `mac-steam-tests.yml`). They are verified against that release's SHA256SUMS, and `PP_STEAM_TESTS_TAG` overrides the pin. Without a pin, the kit uses the runtime release's tests package with the kit's newer sources laid over it.

**PeakPack.exe source:** `releases/latest` by default. A slot file's `peakpack.tag` (or `PP_PEAKPACK_TAG`) selects a `mac-build-peakpack-*` or `rev-*` release instead, for example the test build `mac-build-peakpack-0.4.3-test`. The exe is verified against that release's SHA256SUMS, and the copy in the prefix is replaced whenever it differs. Recorded as `peakpack_source` and `peakpack_exe_sha256`.

**GUI session:** run the kit inside the logged-in desktop (Aqua) session: Terminal on the desktop, `open -a Terminal $JOB/run.command`, or `launchctl asuser`. From a remote shell, Wine cannot open windows, so G-A1, G-B2, G-D2, G-A2-lite, G-C0 and G-X1 end blocked (exit 2).

Everything goes under the job dir. The default is `~/peakpack-test/<job-id>/`; any dedicated folder works with `--job-dir` (not `/` or `~`), and the kit writes its marker file there. `cleanup.sh` deletes only folders with the marker, inside `~/peakpack-test` unless `PP_ALLOW_ANY_JOB_DIR=1`:

| Folder | Contents |
|---|---|
| `kit/` | The kit itself |
| `downloads/` | Release assets, PeakPack.exe, the Unity pkg |
| `runtime/` | The unpacked runtime |
| `steam-tests/` | The Steam team's test scripts |
| `bridge/` | Bridge files for the Steam tests |
| `prefix/` | The Wine prefix (`WINEPREFIX`) |
| `game/PEAK/` | The depot |
| `unity/`, `native/` | G-C0 |
| `results/`, `logs/`, `evidence/`, `cu/`, `state/`, `tmp/` (`TMPDIR`), `copyback/` | Gate output and working files |

**Paths outside the job dir.** Each is recorded in `state/outside-paths.tsv`, and `state/preexisting.tsv` says what existed before the job. `cleanup.sh` removes only paths on a fixed allow-list, and only if they did not exist before.

| Path | Who writes it | Cleanup |
|---|---|---|
| `~/Library/Application Support/Steam/steamapps/content/app_3527290` (or the same under `Steam.AppBundle/Steam/Contents/MacOS/steamapps/`), and `…/downloading/3527290` | Mac Steam, for our `download_depot` (G-B5) | G-B5 moves the depot into the job dir and removes the empty folder; `cleanup.sh` removes any rest |
| `~/Library/Application Support/Steam/…/depotcache/3527291_*.manifest` | Mac Steam during the download | Removed if new |
| `~/Library/Application Support/Steam/logs/console_log.txt` | Steam (only read by G-B5) | Untouched |
| `/tmp/.wine-<uid>/server-<dev>-<inode>` | wineserver, for our prefix | Removed (only our prefix's entry) |
| `~/Library/Preferences/unity.LandCrab.PEAK.plist`, `~/Library/Application Support/{unity.LandCrab.PEAK,LandCrab}`, `~/Library/Saved Application State/com.peakpack.testkit.native.savedState`, `~/Library/Caches/{com.peakpack.testkit.native,LandCrab}`, `~/Library/Logs/LandCrab` | The Unity Mac player (G-C0 only) | Removed if new |
| macOS microphone permission (TCC) for the app that started Wine | Joshua, in G-X1/H-MIC | Joshua may switch it off afterwards |
| Rosetta AOT cache (`/var/db/oah`), Metal shader caches in the per-user temp dir | macOS | System-managed; not touched |
| Steam playtime / "Playing PEAK" on Joshua's account | Steam (server side) | Expected |

Nothing is installed: no Rosetta, CLT, Homebrew or pip packages, no launch agents, no settings changes. Steam is never started, stopped or modified. G-B5 runs `open steam://open/console` only when Steam is already running; set `PP_OPEN_CONSOLE=0` to leave that to the agent too. Every gate keeps the Mac awake while it runs with `caffeinate -w <pid>`, a process assertion that is gone when the gate exits.

## Gates that need direct shell access

**None.** Every gate is a non-interactive script with machine-readable results. Everything that needs eyes or hands goes through the CU handshake. Two cases where direct shell access would *help* but is not required:

- **A G-B2/T3 failure inside lsteamclient.** The useful next step is a logs-mode rerun with `WINEDEBUG=+steamclient,+seh,+loaddll`. That can be added as a gate argument in a follow-up kit version and run as another job. It is not interactive debugging.
- **A Wine or PEAK hang.** `sample`/`spindump` on the process would help. Both are scriptable, so a later kit version can add `--diagnose` to capture them automatically on timeout.

## Static checks (run on Joshua's PC)

- `bash -n` on every script.
- `shellcheck -S warning -x -s bash` on every script: clean.
- A framework self-test in a scratch HOME on git-bash covered: result JSON (validated with PowerShell `ConvertFrom-Json`), the CU handshake, a watchdog timeout and a crash, `run_slot` dependency blocking, `collect.sh`, and `cleanup.sh` including its refusal of unsafe paths.
- `probes/d3d11_clear.c` builds warning-free with `-Wall -Wextra` (Zig/mingw). It ran correctly on Windows (device, flip-discard swap chain, read-back OK).
