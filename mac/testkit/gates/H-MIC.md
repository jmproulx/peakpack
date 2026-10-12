# H-MIC: Microphone permission (human)

| | |
|---|---|
| Slot | 3 |
| Needs a human | yes: only Joshua can answer the macOS microphone prompt. Without `PP_HUMAN_PRESENT=1` the gate always exits 3. |
| Expected run time | 30 min (no timeout in the job file; the prompt step waits up to 1800 s) |
| Requires | nothing |
| Run by | By hand, with `PP_HUMAN_PRESENT=1`, in parallel with G-X1. `run_slot.sh` (slot 3) only records needs-human. |

## Purpose

Records the macOS microphone permission that PEAK's voice chat needs. Photon Voice opens the microphone under Wine. There is no PeakPack app bundle yet, so macOS attributes the request to whatever started Wine (the hub's tool or Terminal). The gate never clicks Allow, and it cannot read the TCC database. With `PP_HUMAN_PRESENT=1`, the agent watches for the prompt during G-X1. It records the app name and Joshua's decision.

## Preconditions

- Joshua at the iMac (fleet user) when G-X1 starts PEAK.
- `PP_HUMAN_PRESENT=1` set for this run.
- Run in parallel with G-X1 (job file and script header).
- Nothing from the kit is required (job file: `requires: []`). This gate starts no programs.
- Built-in microphone recommended, not AirPods. TUNING.md A1: AirPods drop output to 16 kHz.

## Command

```sh
cd "$JOB/kit"
PP_HUMAN_PRESENT=1 bash testkit/run_gate.sh H-MIC --job-dir "$JOB"
```

No arguments.

Environment: `PP_HUMAN_PRESENT`. Set to 1, the agent waits for Joshua's answer. Unset or any other value, the gate prints the instructions and exits 3 at once.

## What the script does

1. Loads `lib/common.sh` and starts the result. Blocks if this is not macOS.
2. Sets the instruction text (`INSTR`).
3. If `PP_HUMAN_PRESENT` is not 1, skips to step 6.
4. Writes the CU request `prompt` with a timeout of 1800 s and waits for the answer.
5. If the answer is ok: criterion `mic_prompt` pass, with the app and decision. Metrics `prompt_app` and `decision`. The gate ends with exit 0. For any other answer: criterion `mic_prompt` info, and the gate goes on to step 6.
6. Ends with needs-human (exit 3) and prints the instructions. This also happens when the prompt answer was not ok, because there is no other exit path.

## Computer-use steps

### CU-prompt

- **When:** written at the start of the gate when `PP_HUMAN_PRESENT=1`. The agent watches during G-X1. Timeout 1800 s.
- **Actions:**
  1. While G-X1 runs, watch the screen for the macOS microphone prompt.
  2. Do NOT click the prompt. Joshua answers it.
  3. Save a screenshot: `bash testkit/cu.sh "$JOB" shot H-MIC mic-prompt` (goes to `evidence/H-MIC/mic-prompt.png`).
  4. Wait until Joshua has answered.
  5. Read the app name in the prompt and the decision (allowed or denied).
- **Answer ok:** `bash testkit/cu.sh "$JOB" done H-MIC.prompt ok "answered by Joshua" app="<app name>" decision=allowed` (or `decision=denied`).
- **Answer skip** if no prompt appeared within 30 min: `bash testkit/cu.sh "$JOB" done H-MIC.prompt skip "no prompt"`
- **Any other answer** (for example fail) is recorded as info, not as a fail: `bash testkit/cu.sh "$JOB" done H-MIC.prompt fail "<what happened>"`

## Human instructions

Printed by the gate when `PP_HUMAN_PRESENT` is not 1:

1. Joshua is at the iMac (fleet user) when G-X1 starts PEAK.
2. The first time PEAK opens the mic, macOS shows "<app> would like to access the microphone". `<app>` is the program that started Wine (the hub's tool or Terminal), because there is no PeakPack app bundle yet.
3. Joshua clicks Allow. Agents never do. If no prompt appears and voice is silent: System Settings, then Privacy & Security, then Microphone. Switch on that app, then restart PEAK.
4. For the record: which app name the prompt showed, and whether AirPods or the built-in mic were used (TUNING.md A1: use the built-in mic; AirPods drop output to 16 kHz).
5. After the slot, Joshua may switch that app's microphone access off again (System Settings, Privacy & Security, Microphone).

## Pass / fail criteria

| Criterion id | Check | Pass when |
|---|---|---|
| `mic_prompt` | Joshua answered the microphone prompt | Pass when the prompt answer is ok. Info otherwise. The gate never writes a fail for this criterion. |

How the overall status is decided:

- Ok answer: status pass, exit 0.
- Any other answer, or no answer with `PP_HUMAN_PRESENT=1`: status needs-human, exit 3.
- Without `PP_HUMAN_PRESENT=1`: status needs-human, exit 3, and no criteria are written.

## Results and evidence

- `results/H-MIC.json`: status, criteria, CU answer, evidence list, human block.
- On pass only: metrics `prompt_app` and `decision`. The `human` block is set when the gate exits 3, and it holds the instructions.
- `logs/H-MIC/cu-prompt.answer.txt`: a copy of the answer.
- `evidence/H-MIC/mic-prompt.png`.
- `cu/H-MIC.prompt.request` (or `.request.closed`) and `cu/H-MIC.prompt.done`.

## Copy back

- `bash testkit/collect.sh "$JOB"`. It packs `results/`, `logs/`, `evidence/` and `cu/`.
- The H-MIC result is usually copied back together with G-X1.

## Paths outside the job dir

- The macOS microphone permission (TCC) for the app that started Wine. Joshua grants it when the prompt appears. He may switch it off again in System Settings, Privacy & Security, Microphone. The gate cannot read the TCC database. It needs no Full Disk Access.
- The gate writes nothing else outside the job dir.

## If it fails or is blocked

- **Needs a human, without `PP_HUMAN_PRESENT=1`:** the instructions are printed. Run the gate again with the variable set, when Joshua is at the iMac.
- **Needs a human, after a run with the variable set:** the answer was not ok. Joshua must answer the prompt. Then the agent writes the answer with `cu.sh`, or the gate is run again.
- **No prompt appears and voice is silent:** Joshua checks the setting (Human instructions, step 3) and restarts PEAK. The agent does not change the setting.
- **Skip after 30 min:** no prompt appeared. Check the voice step in G-X1.
- **Never click Allow as an agent.**
- The gate does not check that the mic was actually used. It records only the prompt answer.
