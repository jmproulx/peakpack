# G-C0: Native smoke (Unity Mac player + PEAK data)

| | |
|---|---|
| Slot | 4 |
| Needs a human | no |
| Expected run time | 60 min (timeout 150 min) |
| Requires | G-B5 |
| Run by | `run_slot.sh` (slot 4) or by hand |

## Purpose

Tests whether PEAK's data runs in a native Mac player. The player is a Unity 6000.3.15f1 arm64 development Mono player, assembled inside the job dir from Unity's Mac support package and PEAK's data.

- **Phase a** runs the stock Windows data. It checks build-target acceptance, main-menu log markers, shader errors (pink is expected), native plugins that fail to load, EOS-absent behaviour and, optionally, HarmonyX on arm64.
- **Phase b** runs the same player with PEAK's Metal shaders converted on this Mac by `native/pm.py`. The converted output is loose files with no `data.unity3d`. The agent checks the menu and a level for visual faults.

Shader errors and missing plugins are recorded as data, not as failures.

## Preconditions

- PEAK's Windows files in `$JOB/game/PEAK` (from G-B5). The gate blocks if `PEAK_Data/data.unity3d` is missing. Both phases need this file, because the converter reads it.
- The Unity Mac Mono support package `UnitySetup-Mac-Mono-Support-for-Editor-6000.3.15f1.pkg` (724,929,213 bytes) in `$JOB/downloads/`. Source: Unity's own server, `https://download.unity3d.com/download_unity/c1aa84e375f6/MacEditorTargetInstaller/UnitySetup-Mac-Mono-Support-for-Editor-6000.3.15f1.pkg`. The hub can download it, or the gate fetches it with `--download` (about 725 MB).
- The package is expanded with `pkgutil --expand-full` into `$JOB/unity/expanded`. It is never installed, and it is never shipped or redistributed.
- Phase b only: a converter environment. The gate needs python3 3.11 or newer with `UnityPy` and `lz4` importable, and a `spirv-cross` binary. The gate detects these and never installs them. If any is missing, phase b is skipped and reported. Existing installs can be named with `PP_CONVERTER_PYTHON`, `PEAKMETAL_SPIRV_CROSS` or `PEAKMETAL_BIN`, or `spirv-cross` can be on PATH. The converter is `native/pm.py`, next to the kit folder (`mac/native/pm.py` in the repo).
- Optional: a BepInEx 5.4.23.x macOS zip (`--bepinex-zip`) for the HarmonyX arm64 check in phase a. Optional: a HarmonyX test plugin DLL (`--harmony-plugin`).
- No Wine and no Steam are used by this gate.
- The player runs in a 1280 x 720 window. In phase a the agent does not click in it. In phase b the agent clicks Play.

## Command

Add `--join-test` only when Joshua is available at his Windows PC (CU-join). The gate fetches Valve's macOS `libsteam_api` (Steamworks.NET 2024.8.0 release zip, SHA-256 pinned in the script) into the job dir; it is never redistributed by us.

```sh
cd "$JOB/kit"
bash testkit/run_gate.sh G-C0 --job-dir "$JOB" [-- <args>]
```

The job file runs it with `-- --run-seconds 150 --download`, plus `--bepinex-zip`, `--harmony-plugin` or `--bundle-variant` when those are used.

| Argument | Default | Meaning |
|---|---|---|
| `--download` | off | Fetch the Unity package from Unity's server if it is missing. Without it, a missing package blocks the gate. |
| `--pkg FILE` | `downloads/UnitySetup-Mac-Mono-Support-for-Editor-6000.3.15f1.pkg` | Use another package file. |
| `--variation NAME` | `macos_arm64_player_development_mono` | Which `Variations/<name>/UnityPlayer.app` to use. |
| `--run-seconds N` | 150 | Longest time each player run may last. |
| `--bepinex-zip ZIP` | none | BepInEx macOS zip, unpacked into `native/`. Used for the phase a HarmonyX check. |
| `--harmony-plugin DLL` | none | HarmonyX test plugin, copied into `BepInEx/plugins`. Only used when the BepInEx zip unpacks. |
| `--phase` | `ab` | Which phases run: `a`, `b` or `ab`. |
| `--converted DIR` | none | Use an existing converter output folder `DIR/Data`. The converter is not run. |
| `--bundle-variant` | off | Phase b converter also writes the repacked `data.unity3d` (`--mode both`). If the phase b main-menu check fails, a third bundle (phase c) runs with that archive. |
| `--jobs N` | none | Passed to `pm.py convert --jobs N`. |

Environment variables read by the script:

- `PP_CONVERTER_PYTHON`: the Python for `pm.py`. If unset, the gate uses the first python3 that `lib/common.sh` finds: the Command Line Tools python3, then `/opt/homebrew/bin/python3`, then `/usr/local/bin/python3`.
- `PEAKMETAL_SPIRV_CROSS`: the path to the `spirv-cross` binary. It is also passed to `pm.py`.
- `PEAKMETAL_BIN`: a folder that holds `spirv-cross`. Used only when `PEAKMETAL_SPIRV_CROSS` is unset. Otherwise the gate uses `spirv-cross` from PATH.
- Shared options from `lib/common.sh`: `PP_CU=none` answers each CU step "skip" at once, and the gate's own screenshots are taken only with `PP_SCREENSHOTS=1` (off by default: no Screen Recording prompt).

## What the script does

1. Loads `lib/common.sh` and `lib/assets.sh` and starts the result. Blocks if this is not macOS.
2. Sets the Unity version (6000.3.15f1), the download URL and the expected package size (724929213 bytes). Reads the arguments.
3. Keeps the Mac awake.
4. Blocks if `game/PEAK/PEAK_Data/data.unity3d` is missing.
5. If the package is missing: fetches it with `--download`, or blocks. A failed download also blocks.
6. Records the package size and SHA-256 (metrics `unity_pkg_bytes`, `unity_pkg_sha256`). Sets the version `unity_player` to "6000.3.15f1 <variation>".
7. Criterion `unity_pkg`: size check (warn if different). Criterion `unity_pkg_sig`: `pkgutil --check-signature`, output in `logs/G-C0/pkg-signature.txt`.
8. Expands the package with `pkgutil --expand-full` into `$JOB/unity/expanded`, if that folder does not exist yet. Errors if the expansion fails. Finds `Variations/<variation>/UnityPlayer.app` and errors if it is missing. Criterion `expanded`. Lists the variations in `logs/G-C0/variations.txt`.
9. Reads the first line of `version.txt` for the bundle's version string.
10. Defines the bundle assembly. For each bundle, it:
    - Copies the Variations `UnityPlayer.app`.
    - Builds the `Data` folder. For stock data, it copies the children of `PEAK_Data` except `Managed` and `Plugins`, and copies `Resources` except its `unity default resources` folder. For converted data, it copies the converter's `Data` folder the same way, except `data.unity3d`. It then copies any other `PEAK_Data` items that are missing (for example `*.resource`, `StreamingAssets`, `boot.config`), and deletes `Data/data.unity3d`. The gate uses APFS clones (`cp -c`) and falls back to plain copies.
    - Copies PEAK's `Managed` assemblies, then copies the Mac player's `mono/Managed/*.dll` over them. The count is recorded. There is no minimum.
    - Copies `MonoBleedingEdge/etc` from the package if present.
    - Writes a minimal `Info.plist` (identifier `com.peakpack.testkit.native`, name "PEAK native smoke"). Returns failure if `plutil -lint` fails.
    - Removes extended attributes, ad-hoc signs the Frameworks dylibs and the app, and verifies the signature. The assembly succeeds only if the plist is valid and the signature verifies. Output goes to `logs/G-C0/codesign.log`.
11. Records Unity's per-user folders that did not exist before the job (see Paths outside the job dir). Both phases use the same bundle id.
12. Sets the cleanup to stop any `UnityPlayer` process under `$JOB/native`.
13. Defines the player run. It starts the player and waits 45 s, then takes the screenshot `native-<tag>-45s`. Only phase a uses `run_bepinex.sh`, and only when BepInEx was unpacked. Player log: `logs/G-C0/<tag>-player.log`.
14. Defines the finish. It waits while the player runs, up to `--run-seconds`. Records `<tag>_alive_after_s` and `<tag>_still_running`. Takes the screenshot `native-<tag>-end`, then stops the player.
15. Defines the analysis. It writes the criteria and metrics with a prefix (`a_`, `b_` or `c_`): `player_log` (fail if there is no log at all), `build_target`, `main_menu` (pass with at least 2 of the 3 markers), the shader error lines, the DllNotFound list, crash markers (metric only) and whether the airport scene was reached (metric `reached_airport`).

**Phase a** (unless `--phase b`):

16. Assembles `native/a-stock/PEAK.app` from the stock data. Criterion `a_assemble`. Records `mac_unityengine_assemblies` and `exe_archs`.
17. With `--bepinex-zip`: unpacks the zip into `native/` with `ditto`. If that works, it creates `BepInEx/plugins`, copies G-D2's pack plugins if that profile exists (with a note), copies the `--harmony-plugin` DLL if one was given, ad-hoc signs the BepInEx dylibs, and records version `bepinex_mac`.
18. Runs the phase a player.
19. CU-look (see below). Its answer is recorded but no criterion uses it.
20. Finishes the run and runs the analysis with prefix `a_`. Writes `logs/G-C0/eos-lines.txt` (lines matching EOS or Epic, first 20). Criteria `a_dllnotfound` (info) and `a_eos_absent` (info).
21. HarmonyX check (criterion `a_harmonyx_arm64`). With BepInEx: copies `LogOutput.log` to `LogOutput-native.log`, counts Harmony error lines and "] Loading [" lines (metrics `harmony_error_lines`, `native_plugins_loaded`). Pass if "Chainloader startup complete" is present and there are no Harmony errors. Without BepInEx: skip.

**Phase b** (unless `--phase a`):

22. Chooses the converter output folder, `native/convert`:
    - With `--converted DIR`: uses `DIR` if `DIR/Data` exists. Otherwise criterion `b_converter` fails.
    - If `native/convert/Data` already exists: reuses it without running the converter. No `b_convert` criterion is written.
    - Otherwise checks the environment: `pm.py` present, python 3.11 or newer, `UnityPy` and `lz4` importable (`python -I`), and a `spirv-cross` binary found. Records metric `converter_python`. If anything is missing, criterion `b_converter` is skip with the list, and phase b stops here.
    - Otherwise runs `pm.py convert` on `game/PEAK/PEAK_Data/data.unity3d`, with `--mode loose` (or `both` with `--bundle-variant`) and `--jobs` if given. Output goes to `native/convert`. Log `logs/G-C0/convert.log`. Records `convert_s` and `convert_exit`. Copies `convert_report.txt` into the logs. Criterion `b_convert`: pass if the exit code is 0 and `Data` exists; fail otherwise.
23. If the converted `Data` exists, assembles `native/b-converted/PEAK.app` from it. Criteria `b_assemble` (pass if the assembly succeeds) and `b_no_archive` (fail if a `data.unity3d` is in the bundle, pass if not).
24. Runs the phase b player. No BepInEx in this phase.
25. CU-menu (see below). Each answer key with a value is recorded as metric `b_visual_<key>`.
26. Finishes the run and runs the analysis with prefix `b_`. Criterion `b_visual`: info for an ok answer, fail for a fail answer, skip for skip or timeout.
27. With `--bundle-variant`, if `b_main_menu` failed and `native/convert/data.unity3d` exists: assembles `native/c-bundle/PEAK.app` from stock data, removes its `data.unity3d`, copies in the converter's `data.unity3d`, and ad-hoc signs it. Runs the player (no BepInEx), finishes, and runs the analysis with prefix `c_`.
28. If phase b was skipped by the environment check, notes "phase b not run (converter environment missing); phase a results stand alone".
29. Writes the result JSON and exits.

## Computer-use steps

### CU-look (phase a)

- **When:** 45 s after the phase a player starts. One request. Timeout 120 s.
- **Actions:**
  1. Find the window titled "PEAK native smoke" (stock data).
  2. Save a screenshot: `bash testkit/cu.sh "$JOB" shot G-C0 native-a-window` (goes to `evidence/G-C0/native-a-window.png`).
  3. Describe what you see: black, pink or magenta surfaces (expected, because there are no Metal shaders yet), a recognisable PEAK main menu (even if pink), an error dialog, or nothing.
  4. Do not click in the window.
- **Answer ok:** `bash testkit/cu.sh "$JOB" done G-C0.look ok "<description>"`
- **Answer skip** if nothing appeared: `bash testkit/cu.sh "$JOB" done G-C0.look skip "nothing appeared"`
- Any answer is data, not a failure. No criterion uses it.

### CU-menu (phase b)

- **When:** 45 s after the phase b player starts. One request. Timeout 240 s.
- **Actions:**
  1. When the main menu shows, save a screenshot: `bash testkit/cu.sh "$JOB" shot G-C0 native-b-menu`.
  2. Click Play and wait for the Airport lobby (up to 2 minutes). Save a screenshot: `bash testkit/cu.sh "$JOB" shot G-C0 native-b-level`. Unlike CU-look, the agent clicks in this window.
  3. Check each of these: an upside-down or mirrored image (y orientation); objects drawn through each other (depth); washed-out or too dark colours (sRGB); black or garbled full-screen copies (framebuffer fetch, CoreCopy); flickering or repeated objects (instancing); pink or missing materials.
  4. Answer ok, with the values for each check:
     `bash testkit/cu.sh "$JOB" done G-C0.menu ok "<note>" menu=yes level=yes yflip=ok depth=ok srgb=ok fbfetch=ok instancing=ok missing=none`
     - `menu` and `level`: `yes` or `no`.
     - `yflip`, `depth`, `srgb`, `fbfetch`, `instancing`: `ok` or `bad`.
     - `missing`: `none`, or a list of what is missing.
  5. Answer fail if the game crashed or stayed black: `bash testkit/cu.sh "$JOB" done G-C0.menu fail "<what happened>"`
- The result of this step is not a criterion on its own. The values only feed the `b_visual_*` metrics. The step result feeds `b_visual`: ok gives pass ("renders without crash or black screen"), fail gives fail, skip or timeout gives skip.

### CU-lobby (phase b): Steam lobby WITHOUT EOS (key finding)

EOS sign-in is what creates PEAK's online player id, and EOS is absent here (observe only, nothing is stubbed). This step shows whether hosting still works.

1. After CU-menu you should be in the Airport. If you are not, click **Play** on the main menu now and wait up to 2 minutes.
2. Save a screenshot: `bash testkit/cu.sh "$JOB" shot G-C0 native-b-lobby`.
3. Note any error, "offline" or connection message the game shows.
4. Answer: `bash testkit/cu.sh "$JOB" done G-C0.lobby ok "" hosted=<yes|no> message=<text or none>`, or `fail "<what happened>"`.

The verdict comes from PEAK's own log line `Lobby Created: <id>` (SteamLobbyHandler). The agent's answer is the cross-check.

### CU-join (phase b, only with `--join-test`): needs Joshua

1. Ask Joshua, on his Windows PC with PEAK running (his own Steam account), to open his Steam friends list, right-click the Mac's account and choose **Join Game**, or to type the room code from the Mac's pause menu.
2. Wait until he is in, or reports an error (up to 10 minutes).
3. Save a screenshot on the Mac: `bash testkit/cu.sh "$JOB" shot G-C0 native-b-join`.
4. Answer: `... done G-C0.join ok "" joined=<yes|no> windows_message=<what Joshua saw> mac_message=<what the Mac showed>`, or `skip "Joshua not available"`.

Nobody types credentials anywhere.

## Human instructions

Not needed. This gate never exits 3. Missing converter tools give a skip, not a human step.

## Pass / fail criteria

| Criterion id | Check | Pass when |
|---|---|---|
| `unity_pkg` | package size matches DESIGN §6.1 (724929213 bytes) | Pass when the size matches. Warn (not a failure) otherwise. |
| `unity_pkg_sig` | package signature valid | Pass if `pkgutil --check-signature` succeeds. Fail otherwise. |
| `expanded` | package expanded into the job dir, not installed | Pass when `Variations/<variation>/UnityPlayer.app` exists. If the expansion fails, the gate ends as error and this criterion is not written. |
| `a_assemble` | phase a bundle assembled, `Info.plist` valid, ad-hoc signature verifies | Pass when assembly succeeds. Fail otherwise (see `codesign.log`). |
| `a_build_target` | stock data accepted by the Mac player | Pass if there is no "created for another build target" line. Fail with the count otherwise. |
| `a_main_menu` | game scripts reach the main menu (phase a) | Pass with at least 2 of the 3 markers in the log. Fail otherwise. |
| `a_player_log` | the phase a player wrote a log | Fail only, when there is no log at all. Never pass. The gate goes on to phase b. |
| `a_dllnotfound` | native plugins that failed to load | Info only. Always recorded. |
| `a_eos_absent` | EOS-absent behaviour recorded | Info only. Always recorded. |
| `a_harmonyx_arm64` | BepInEx + HarmonyX on arm64 (phase a) | Pass if "Chainloader startup complete" is present and there are no Harmony errors. Fail if `LogOutput.log` is missing, or the line is missing, or errors are found. Skip when BepInEx did not run. |
| `b_converter` | converter environment present | Skip, with the list of missing items, when the environment is missing (phase b stops). Fail if `--converted DIR` has no `Data` folder. Never pass. |
| `b_convert` | converter produced loose `Data` files | Pass if the converter exits 0 and `Data` exists. Fail otherwise. Written only when the converter ran. |
| `b_assemble` | phase b bundle assembled and signed | Pass when assembly succeeds. Fail otherwise. |
| `b_no_archive` | no `data.unity3d` in the phase b bundle | Pass when it is absent. Fail when it is present. |
| `b_build_target`, `b_main_menu`, `b_player_log` | the same checks as phase a, for the converted bundle | As for `a_`. |
| `a_eos_absent`, `b_eos_absent` | every EOS/Epic/Sanction/UserManager line recorded (`logs/G-C0/<phase>_eos-lines.txt`; metrics `*_eos_line_count`, `*_eos_first_lines`, `*_eos_library_missing`) | Info (observe only) |
| `a_steam_init`, `b_steam_init` | `Steam runtime manager initialized: True` in Player.log (Valve libsteam_api from Steamworks.NET 2024.8.0 in PlugIns; `steam_appid.txt` + `SteamAppId`) | Pass when True. Fail when False. Info when not logged. |
| `b_lobby_create` | **key finding:** `Lobby Created: <id>` in Player.log after hosting, without EOS (metrics `b_lobby_created/entered/joining/errors`, `b_lobby_lines`; `logs/G-C0/b_lobby-lines.txt`, `b_photon-lines.txt`) | Pass when the line is there. Fail when the agent hosted and there is no line. Skip when the step could not run. |
| `b_lobby_join` | **key finding:** Joshua's Windows PC joins the Mac's lobby (`--join-test`) | Pass on joined=yes. Fail on joined=no. Skip when not requested or Joshua is not available. |
| `b_visual` | agent's visual check (CU-menu) | Info when ok. Fail when fail. Skip when skip or timeout. Never pass. |
| `c_build_target`, `c_main_menu`, `c_player_log` | the same checks for the `--bundle-variant` run | Only written with `--bundle-variant` when `b_main_menu` failed. |

How the overall status is decided (from `lib/common.sh`):

- Any criterion fails: status fail, exit 1. That includes `a_assemble`, `a_build_target`, `a_main_menu`, `a_harmonyx_arm64`, `unity_pkg_sig`, the `b_` and `c_` checks, and `a_player_log`.
- Otherwise, any criterion passes: status pass, exit 0.
- Only info, warn or skip results: status error, exit 4.
- A skipped phase b (missing converter) does not fail the gate. Its skip is recorded, and the phase a results decide the status.
- The job file's pass text for phase b includes "renders without crash/black screen (agent)". The script never writes `b_visual` as pass. An ok answer gives info. So a phase b pass depends on `b_assemble`, `b_no_archive`, `b_build_target` and `b_main_menu`, not on the visual check.

## Results and evidence

- `results/G-C0.json`: status, criteria, metrics, CU answers, evidence list, notes.
- Metrics:
  - Package and phase a: `unity_pkg_bytes`, `unity_pkg_sha256`, `mac_unityengine_assemblies`, `exe_archs`, `a_alive_after_s`, `a_still_running`, `a_build_target_errors`, `a_main_menu_markers`, `a_shader_error_lines`, `a_dllnotfound_unique`, `a_dllnotfound_list`, `a_crash_markers`, `a_reached_airport`.
  - With BepInEx: `harmony_error_lines`, `native_plugins_loaded`.
  - Phase b (when the converter ran): `converter_python`, `convert_s`, `convert_exit`, and the `b_` versions of the analysis metrics, `b_alive_after_s`, `b_still_running`, plus `b_visual_<key>` for each visual answer key.
  - Phase c (with `--bundle-variant`): the `c_` versions of the analysis metrics.
- Versions: `unity_player`, and `bepinex_mac` when `--bepinex-zip` is given.
- `logs/G-C0/`:
  - Package and build: `pkg-signature.txt`, `pkgutil.log`, `variations.txt`, `codesign.log`, `bepinex-unzip.log` (BepInEx only).
  - Phase a: `a-run.out`, `a-player.log`, `a_shader-errors.txt`, `a_dllnotfound.txt`, `eos-lines.txt`, `LogOutput-native.log` (BepInEx only).
  - Phase b: `convert.log`, `convert_report.txt` (if the converter wrote one), `b-run.out`, `b-player.log`, `b_shader-errors.txt`, `b_dllnotfound.txt`.
  - Phase c: `c-run.out`, `c-player.log`, `c_shader-errors.txt`, `c_dllnotfound.txt`.
  - CU answers: `cu-look.answer.txt`, `cu-menu.answer.txt`.
- `evidence/G-C0/`: `native-a-45s.png`, `native-a-window.png`, `native-a-end.png`, `native-b-45s.png`, `native-b-menu.png`, `native-b-level.png`, `native-b-end.png`. Phase c adds `native-c-45s.png` and `native-c-end.png`.
- `native/` in the job dir: `a-stock/PEAK.app`, `b-converted/PEAK.app`, `c-bundle/PEAK.app` (phase c only), and `convert/` (the converter output: `Data/`, and `data.unity3d` with `--bundle-variant`).
- `cu/`: the `G-C0.look` and `G-C0.menu` requests and answers.

## Copy back

- `bash testkit/collect.sh "$JOB"` packs `results/`, `logs/`, `evidence/`, `cu/` and `state/` (see `slot1.job.json`, copy_back).
- Do not copy the Unity package, `$JOB/unity`, or `$JOB/native` (the app bundles and the converter output). The copy-back list does not include them.

## Paths outside the job dir

Unity's per-user folders for the LandCrab/PEAK player. The gate checks these seven paths before the first player run:

- `~/Library/Preferences/unity.LandCrab.PEAK.plist`
- `~/Library/Application Support/unity.LandCrab.PEAK`
- `~/Library/Application Support/LandCrab`
- `~/Library/Saved Application State/com.peakpack.testkit.native.savedState`
- `~/Library/Caches/com.peakpack.testkit.native`
- `~/Library/Caches/LandCrab`
- `~/Library/Logs/LandCrab`

The gate records each path that did not exist before the job started in `state/outside-paths.tsv`. `cleanup.sh` removes the recorded paths if they are present. Paths that existed before the job are left alone.

The converter runs from `mac/native/pm.py`. Its output stays in the job dir. Python, UnityPy, lz4 and spirv-cross are not installed by the gate, and they are outside the job dir.

## If it fails or is blocked

- **Blocked, PEAK's Windows files not in the job dir:** run G-B5. Phase b also needs `data.unity3d`.
- **Blocked, package not in `downloads/`:** the hub downloads the URL above, or re-run with `--download`.
- **Blocked, download failed:** retry, or have the hub download the package.
- **Error, `pkgutil --expand-full` failed:** see `logs/G-C0/pkgutil.log`.
- **Error, no `Variations/<variation>/UnityPlayer.app`:** see `logs/G-C0/variations.txt`. Check `--variation`.
- **Fail, `unity_pkg_sig`:** stop and report it to Joshua. Do not install the package.
- **Fail, `a_assemble`:** see `logs/G-C0/codesign.log`.
- **Fail, `a_player_log`:** phase a wrote no log, so it crashed before logging. See `logs/G-C0/a-run.out`. Unlike earlier versions, the gate goes on to phase b.
- **Fail, `a_build_target` or `a_main_menu`:** see `a-player.log`, and the CU-look answer and `native-a-end.png`.
- **Skip, `b_converter` with a list:** the list names what is missing (python, UnityPy or lz4, spirv-cross, or `pm.py`). Point `PP_CONVERTER_PYTHON`, `PEAKMETAL_SPIRV_CROSS` or `PEAKMETAL_BIN` at existing installs. The kit never installs them. Phase a results stand alone.
- **Fail, `b_converter`:** the folder given to `--converted` has no `Data` folder.
- **Fail, `b_convert`:** see the exit code in the criterion, `logs/G-C0/convert.log` and `convert_report.txt`.
- **Stale converter output:** if `native/convert/Data` already exists, the converter does not run, and no `b_convert` criterion is written. Delete `native/convert` to force a new conversion.
- **Fail, `b_assemble` or `b_no_archive`:** see `codesign.log`. A `data.unity3d` in the phase b bundle is a fail.
- **Fail, `b_visual`:** the agent answered fail, meaning the menu or the level was black or the game crashed. The answer and its note are in `cu-menu.answer.txt`. Ok answers only give info.
- **Phase c** runs only with `--bundle-variant`, and only if `b_main_menu` failed and the converter wrote `data.unity3d`.
- **Fail, `a_harmonyx_arm64`:** `LogOutput.log` is missing (Doorstop did not inject), or Harmony errors were found. Check `LogOutput-native.log`.
- **Skip, `a_harmonyx_arm64` (mislabelled):** the text says "no --bepinex-zip given" even when a zip was given but `ditto` could not unpack it. Check `logs/G-C0/bepinex-unzip.log`.
- **`--harmony-plugin` has no effect** unless the BepInEx zip unpacks.
- **Player still running at the end:** not a failure. The `*_still_running` metric shows it. The gate stops the player.
- **Watchdog timeout (150 min) or a signal:** the gate ends as error (exit 4) and stops the players.
