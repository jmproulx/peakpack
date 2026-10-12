# G-B0: steamclient.dylib x86_64 slice and exports (T0)

| | |
|---|---|
| Slot | 1 |
| Needs a human | no |
| Expected run time | 1 min (timeout 5 min) |
| Requires | nothing |
| Run by | `run_slot.sh` (slot 1), or by hand with `run_gate.sh` |

## Purpose

Checks that Mac Steam's `steamclient.dylib` has an x86_64 slice and the exports the kit needs: `CreateInterface` and four `Steam_` functions. It is read only towards Steam. A missing x86_64 slice blocks Track B2, so the result must be reported first.

## Preconditions

- Mac Steam is installed and has been started once, so `steamclient.dylib` exists in the Steam client folder (H-STEAM). Without it the gate is blocked (exit 2).
- Optional: Xcode Command Line Tools (CLT).
  - With the CLT and the Steam test kit, the gate runs the Steam team's `t0_steamclient_dylib.sh` unchanged. The test kit comes from the release asset `peakpack-steam-tests-*`, or from the repo copy. Kit assets are checked against SHA256SUMS.
  - Without the CLT, the gate uses its own fallback (see step 5).

## Command

```sh
cd "$JOB/kit"
bash testkit/run_gate.sh G-B0 --job-dir "$JOB"
```

| Argument | Default | Meaning |
|---|---|---|
| `--steam-dir DIR` | `$STEAM_MACOS_DIR` | Steam client folder that holds `steamclient.dylib` |

## What the script does

1. Starts the gate and checks that it runs on a Mac. Reads `--steam-dir`.
2. If `steamclient.dylib` is missing, the gate ends blocked (exit 2).
3. Records the SHA-256 and size of the dylib, the Steam client version, the `file` output (`logs/G-B0/file.txt`), the `codesign -dv` output (`logs/G-B0/codesign.txt`) and a signing summary metric.
4. **Path A** (CLT present and test kit found): runs `t0_steamclient_dylib.sh` unchanged, with logs in `logs/G-B0/t0/` and output in `t0.out`. Records its exit code as `t0_exit`. Reads its PASS lines for the x86_64 slice and each export. Then ends the gate.
5. **Path B** (no CLT, or no test kit): records method `fallback-od-grep`. Reads the Mach-O header with `od` and `dd`.
   - Fat file: finds the x86_64 slice (CPU type 16777223) and copies it to the gate's temp folder.
   - Thin file: uses the whole file if it is x86_64.
   - Records the slice list as metric `archs`.
6. If there is no x86_64 slice, `x86_64_slice` fails and the gate ends.
7. Searches the slice for each required symbol name (`_CreateInterface` and so on). A required name that is missing fails. Optional names are info.
8. Deletes the temporary slice and ends the gate.

Required exports: `CreateInterface`, `Steam_BGetCallback`, `Steam_FreeLastCallback`, `Steam_GetAPICallResult`, `Steam_ReleaseThreadLocalMemory`.
Optional exports: `Steam_IsKnownInterface`, `Steam_NotifyMissingInterface`.

## Computer-use steps

None. This gate takes no screenshots.

## Pass / fail criteria

| Criterion id | Check | Pass when |
|---|---|---|
| `x86_64_slice` | x86_64 slice present | The dylib has an x86_64 slice. Fail otherwise. |
| `export_CreateInterface` | Required export | Present. Fail otherwise. |
| `export_Steam_BGetCallback` | Required export | Present. Fail otherwise. |
| `export_Steam_FreeLastCallback` | Required export | Present. Fail otherwise. |
| `export_Steam_GetAPICallResult` | Required export | Present. Fail otherwise. |
| `export_Steam_ReleaseThreadLocalMemory` | Required export | Present. Fail otherwise. |
| `export_Steam_IsKnownInterface` | Optional export | Info only. Present or absent. |
| `export_Steam_NotifyMissingInterface` | Optional export | Info only. Present or absent. |

Path A checks exports with the Steam test script (exact `nm` check). Path B searches symbol names as strings in the slice. That check is approximate. It is not a parsed export table.

Status: any fail gives fail. Blocked (exit 2) when there is no `steamclient.dylib`. Info criteria do not change the status.

## Results and evidence

- `results/G-B0.json`: status, exit code, criteria, metrics, versions and notes.
- Metrics: `dylib_sha256`, `dylib_bytes`, `steam_client_version`, `file_type`, `signing`, `method`. Path B also records `archs`. Path A also records `t0_exit`.
- Versions: `steam_client` (if readable).
- Logs in `logs/G-B0/`: `console.log`, `file.txt`, `codesign.txt`. Path A also writes `t0.out` and `t0/`.
- Evidence: none.

## Copy back

- `results/G-B0.json`
- `logs/G-B0/`

## Paths outside the job dir

Reads only.

- `$STEAM_MACOS_DIR/steamclient.dylib`, or the path given with `--steam-dir`. Path A's Steam test script reads it too.

Writes stay in the job dir. The temporary x86_64 slice is removed at the end.

## If it fails or is blocked

- No `steamclient.dylib`: blocked. Run H-STEAM first. Mac Steam must be installed and started once.
- `x86_64_slice` fails: the dylib has no Intel slice. Track B2 is blocked until an arm64 Wine exists (script message). Report this prominently. `slot1.job.json` says the same.
- A required export fails:
  - Path A: read `logs/G-B0/t0.out`.
  - Path B: the check is approximate. Re-run with the CLT for the exact `nm` check (script note).
- An optional export is absent: info only. The script says patch 0001 copes.
- Path B was used: the CLT is optional. Installing it is the hub's or Joshua's call (see the G-B1 script message and P0).
