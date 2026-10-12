# G-A2-CX: CrossOver baseline (optional)

| | |
|---|---|
| Slot | 4 |
| Needs a human | yes: installing the CrossOver trial, accepting its licence and signing Steam in inside the bottle are Joshua's call. Without `--fps` the gate always exits 3. |
| Expected run time | 1 min (timeout 5 min) |
| Requires | nothing |
| Run by | `run_slot.sh` (slot 4) records needs-human. Run by hand with `--fps` after the CrossOver run. |

## Purpose

Records a CrossOver baseline for G-A2's "90 % of CrossOver" criterion. The gate never installs CrossOver and never runs PEAK. Without `--fps` it only detects whether CrossOver is installed and prints the steps for Joshua or the hub. After those steps are done, a second run with `--fps <readings>` records the baseline numbers. The gate does not compare them with G-A2-lite. G-A2-lite's `vs_crossover` criterion is always skip.

## Preconditions

- Mac (the gate checks this).
- Nothing from the kit is required (job file: `requires: []`).
- For the baseline run, which is done by hand and not by this gate: the CrossOver 26 trial and a bottle with Steam and PEAK in it. Joshua decides. The full steps are in the Human instructions below.
- The gate looks only at `/Applications/CrossOver.app` and `~/Applications/CrossOver.app`.

## Command

```sh
cd "$JOB/kit"
bash testkit/run_gate.sh G-A2-CX --job-dir "$JOB" [-- <args>]
```

| Argument | Default | Meaning |
|---|---|---|
| `--fps LIST` | none | Comma-separated CrossOver HUD readings on the Shore, on the same route as G-A2-lite. Example: `--fps 58,60,57`. With this argument the gate records the baseline. |

No environment variables are read.

## What the script does

1. Loads `lib/common.sh` and starts the result. Blocks if this is not macOS.
2. Reads `--fps`.
3. Looks for `CrossOver.app` in `/Applications` and `~/Applications`. If both exist, the last one found is used.
4. With `--fps`:
   - Computes the average, the lowest reading and the count with awk.
   - Records metrics `cx_fps_avg`, `cx_fps_min`, `cx_fps_samples`.
   - Records version `crossover` (`CFBundleShortVersionString` from the app's Info), blank if the app was not found.
   - Criterion `baseline`: pass. The gate does not check the values.
   - Stores `CX_FPS_AVG` in `$JOB/job.env`.
   - Ends with status pass.
5. Without `--fps`:
   - If CrossOver is not found: criterion `crossover` as info ("no (optional)"). Exits 3 with the steps.
   - If CrossOver is found: criterion `crossover` as info (the app path). Exits 3 with the same steps and the note "CrossOver present; the baseline run needs Steam sign-in inside the bottle".

## Computer-use steps

None. This gate makes no `cu_request` call. Its measuring steps are human steps, listed under Human instructions.

## Human instructions

Printed by the gate when it runs without `--fps`:

1. Joshua (or the hub with his OK): install the CrossOver 26 trial for the fleet user only (`~/Applications`), and accept the licence.
2. In CrossOver: create a new Windows 10 64-bit bottle named `peak-baseline`. Install Steam (Windows) into it. Joshua signs in (Steam Guard).
3. Install PEAK in that bottle (or point its library at a copy of the depot from G-B5). Set D3DMetal OFF and DXMT ON in the bottle's settings, as CrossOver describes. Turn the Metal HUD on.
4. Launch PEAK with `-force-d3d11 -screen-width 1440 -screen-height 900 -screen-fullscreen 1 -window-mode borderless`.
5. Use the same route as G-A2-lite: main menu, then solo, then the Shore. Read the HUD FPS every 30 s for 2 minutes. Take screenshots `cx-fps-<n>.png`.
6. Re-run: `bash run_gate.sh G-A2-CX --job-dir <job> -- --fps <readings>`.
7. Cleanup: delete the bottle (CrossOver, then Bottle, then Delete) and quit CrossOver. Uninstalling CrossOver is Joshua's call.

To keep the screenshots in the copy back, save them with `bash testkit/cu.sh "$JOB" shot G-A2-CX cx-fps-<n>`. The gate does not read them.

## Pass / fail criteria

| Criterion id | Check | Pass when |
|---|---|---|
| `crossover` | CrossOver installed (only without `--fps`) | Info only. The detail is the app path, or "no (optional)". |
| `baseline` | CrossOver baseline recorded (only with `--fps`) | Pass, always. The readings are recorded, not checked. |

How the overall status is decided:

- Without `--fps`: status needs-human, exit 3. No pass or fail is written.
- With `--fps`: status pass, exit 0. The gate has no fail path.

## Results and evidence

- `results/G-A2-CX.json`: status (needs-human or pass), criteria, metrics, notes.
- With `--fps`: metrics `cx_fps_avg`, `cx_fps_min`, `cx_fps_samples`. Version `crossover` (blank if CrossOver was not found).
- `$JOB/job.env` (not in the result file): `CX_FPS_AVG`.
- `logs/G-A2-CX/`: console output only. The gate writes no files there.

## Copy back

- `bash testkit/collect.sh "$JOB"`. It packs `results/G-A2-CX.json` with the rest of the job's results.
- Any screenshots saved under `evidence/G-A2-CX/`.
- The `--fps` readings are the only baseline data the gate records.

## Paths outside the job dir

- Reads `/Applications/CrossOver.app` and `~/Applications/CrossOver.app` (read only, for the version).
- The gate writes nothing outside the job dir.
- The human steps (installing CrossOver, creating the bottle, signing in to Steam) write outside it. Those are Joshua's actions. Cleanup is listed in step 7 above.

## If it fails or is blocked

- **Needs a human, CrossOver not installed:** this is optional. Joshua decides. Do not install it.
- **Needs a human, CrossOver present:** the baseline run needs a Steam sign-in inside the bottle. Joshua does that.
- **Readings are not numbers:** the gate does not check them. Empty or non-numeric values give blank metrics, and `baseline` still passes. Check `results/G-A2-CX.json`.
- **`cx_fps_min`** is the lowest reading. `cx_fps_avg` is shown to one decimal place.
- **G-A2-lite is not updated:** this gate does not change its `vs_crossover` criterion. Compare the two runs by hand.
