# Job spec template (PeakPack for Mac → Mac fleet hub)

A job spec is a JSON file. The hub reads it to plan a slot, and `run_slot.sh` reads the same file to run it. `slot1.job.json` is the reference example. Copy it, then change the fields below.

## Required fields

| Field | Meaning | Read by `run_slot.sh` |
|---|---|---|
| `schema` | Always `"peakpack-mac-job/1"` | no |
| `slot`, `title` | Short id (used in the default job id) and a one-line description | `slot` |
| `job_id` | The hub's id, or `"auto"` (the hub should pick it and pass `--job-id`) | yes |
| `machine` | Host, macOS user (`fleet`), screen use, what must already be there | no |
| `release.repo`, `release.tag` | `jmproulx/peakpack` and the `mac-build-runtime-*` tag; assets are verified against that release's `SHA256SUMS` | `release.tag` |
| `kit.source_archive`, `kit.path_in_archive`, `kit.setup` | Where the kit comes from: the source archive at the same tag, folder `peakpack-<tag>/mac/testkit` | no |
| `time_budget_min`, `expected_machine_min` | The slot length to book, and the sum of the gates' expected times | no |
| `early_cu[]` | `{key, timeout_s, instruction}`: CU steps announced at slot start, so long manual steps run in parallel (G-B5's depot download) | yes |
| `run_order[]` | Gate ids, in order | yes |
| `gates[]` | One object per gate (below) | `id`, `args`, `requires[]` |
| `human_steps[]` | `{who, when, what, gate}`: everything a person must do | no |
| `outside_paths[]` | Every path written outside the job dir, and how it is cleaned | no |
| `copy_back` | `collect.sh` command, the file to copy, its contents | no |
| `cleanup` | `cleanup.sh` command, what it removes and what it leaves | no |
| `direct_shell_needed` | `"none"`, or the gate and the reason | no |

## Gate object

```json
{
  "id": "G-B2",
  "title": "Steam bridge in Wine: T3, T4, T5",
  "doc": "testkit/gates/G-B2.md",
  "command": "bash testkit/run_gate.sh G-B2 --job-dir $JOB -- --t5-seconds 240",
  "args": "--t5-seconds 240",
  "requires": ["G-A1", "G-B5"],
  "needs_human": false,
  "computer_use": ["mainmenu"],
  "expected_min": 10,
  "timeout_min": 30,
  "pass": "one-line summary of the pass criteria (the full list is in the .md and the result JSON)",
  "on_fail": "continue"
}
```

Field notes:

- `args` is passed after `--` to the gate script. Use plain flags only; they are word-split.
- `requires`: gates whose `results/<id>.json` must say `pass`. Otherwise `run_slot.sh` records this gate as `blocked` without running it.
- `needs_human`: `false`, `true`, or a string saying when and why.
- `computer_use`: the step ids the gate may request. Each is described in `gates/<id>.md`, section `CU-<step>`.
- `timeout_min`: the watchdog limit in `run_gate.sh`. The defaults live there; `--timeout-min` overrides them.

## Checklist for a new slot

1. **Gates.** Pick the gates and their order. Put the gates that only need Steam first (P0, H-STEAM, G-B0, G-B1). Start the depot download as `early_cu`. Run the Wine gates after G-A1.
2. **Times.** Add up `expected_min` and keep the slot about 1.5× that. Slot 1: 115 min of machine time in a 180-minute booking.
3. **People.** List every human action in `human_steps`. Run human gates only when `PP_HUMAN_PRESENT=1` is set for them. Without it they exit 3 with instructions, which the hub relays.
4. **Paths.** Copy `outside_paths` from slot 1 and add any new ones. Any new path outside the job dir must also be added to `lib/common.sh: outside_candidates()` and `cleanup.sh: allowed_outside()`. Otherwise cleanup will not remove it.
5. **Validate.** Check the file parses: `awk -f testkit/lib/json_flat.awk testkit/<slot>.job.json > /dev/null`. Then do a dry run with `bash testkit/run_slot.sh testkit/<slot>.job.json --no-cu --job-id dryrun` and clean up with `cleanup.sh`.

## What the hub sends back

- `copyback/peakpack-<job>-results.tar.gz` and its `.sha256`.
- `run_slot-console.txt`, which `collect.sh` packs too.
- The output of `cleanup.sh`, the "cleanup of …" report. The hub relays it, or saves it with `--report FILE`.
- Anything a human was asked to do, and their answer. For example: "Joshua signed in at 09:12" or "the microphone prompt named Terminal".
