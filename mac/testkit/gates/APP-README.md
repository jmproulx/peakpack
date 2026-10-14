# PEAK (Modded).app gates: G-APP1 to G-APP6

These six gates test the macOS app `PEAK (Modded).app` the way a friend uses it: download it, start it, let it set up,
download the game through the app's Steam console flow, play the modded game, play the vanilla game, repair it, and
uninstall it. They are one chain. Each gate uses the same job dir and the app's own data under `$JOB/appdata`.

Release: prerelease `mac-build-app-<version>` of `jmproulx/peakpack`, assets `PEAK-Modded-Mac-<version>.zip` and
`SHA256SUMS`. Pass the tag as `--app-release mac-build-app-<version>` (or env `PP_APP_RELEASE`). G-APP1 saves it to
the job's `job.env`, and the later gates read it from there.

## The gates

| Gate | Purpose | Needs a human | Machine time (expected) | Timeout (watchdog) |
|---|---|---|---|---|
| **G-APP1** | Download, verify, unzip the app. Static checks. First run: welcome screen, Set Up PEAK (CU), setup up to the game step. The app is left running. | Only if Rosetta 2 is missing (exit 3), or Mac Steam is not signed in (steam step over 3 min, exit 3) | 25 min | 60 min |
| **G-APP2** | Game step. Mode A: Steam console paste (CU), wait for the app's "All set", verify the game against the Windows reference, check PeakPack and the mods, quit the app. Mode B: an existing PEAK folder (CU). | No | 75 min (about 1.93 GB download) | 130 min (100 min wait) |
| **G-APP3** | Daily launch as a Dock click (no `--no-autoplay`): PEAK starts modded, Steam initialised, main menu (CU), PEAK ends from its menu (CU), the app quits by itself. | No | 10 min | 20 min |
| **G-APP4** | Options window: Show FPS on, Play with Mods (CU). Every pack plugin loads, no BepInEx errors, Metal HUD fps (CU). PEAK ends, Show FPS off (CU), app quit. | No | 15 min | 30 min |
| **G-APP5** | Options window: Play Normal PEAK (CU). Steam initialised, BepInEx does not start, vanilla Player.log clean. PEAK ends, app quit. | No | 10 min | 20 min |
| **G-APP6** | Damage inside the job's app data only, then Repair (CU): the stamp and runtime file come back, readyToPlay. Then Uninstall (CU, "Move to Trash" = moved into `uninstalled/` in test mode): data gone, copy complete, bundle kept, Steam untouched. | No | 25 min | 60 min |

Total expected machine time: about 160 min (plus H-STEAM). The six timeouts add up to 320 min. The slot file (`slot-app.job.json`)
states these limits in `timeout_min`, but `run_slot.sh` does not pass them on (see "Known limits").

## Order and dependencies

```
H-STEAM -> G-APP1 -> G-APP2 -> G-APP3 -> G-APP4 -> G-APP5 -> G-APP6
```

Each gate `requires` the one before it, as in `slot-app.job.json`: `run_slot.sh` records a gate as blocked when its
requirement did not pass. G-APP1 requires H-STEAM. G-APP1 leaves the app running at the game step. G-APP2 quits it at
the end. G-APP3 starts it like a Dock click; the app quits when PEAK does. G-APP4 and G-APP5 open it with `--options`,
so it stays open after PEAK. G-APP5 and G-APP6 quit it at the end.

In the options window (app 0.1.2 and later), **Check for Updates** and **Re-download PEAK** are entries in the **More ▾** menu, not visible buttons. No CU step clicks them.

Run one gate by hand with `bash testkit/run_gate.sh G-APP3 --job-dir "$JOB" -- --app-release mac-build-app-0.1.5`.

## What a friend does differently

- **The download.** A friend's browser or Safari sets the quarantine flag, so macOS shows "Open Anyway" once. The kit
  downloads with `curl`, which sets no quarantine flag, so there is no Gatekeeper dialog. This is intended. The kit
  does not test the quarantine path.
- **Optional manual check (needs-human, not run by the kit).** To test the quarantine path, Joshua or the hub can copy
  a quarantined copy of the app (downloaded with a browser) and open it by hand. Right-click > Open, or "Open Anyway"
  in Privacy & Security, may ask for an administrator password. The agent must never type that password, and never
  click Allow on any privacy prompt. This is not a gate.
- **The game step.** A friend pastes the command into Steam's Console. The kit does the same with the agent (G-APP2
  mode A). The kit does not type the command itself: the app puts it on the clipboard, and the agent pastes it.
- **Steam.** A friend's Steam is signed in. The kit needs the same. It never reads Steam's login or config files.
- **Repair and uninstall.** A friend uses the Trash. The test build moves the app data to `$JOB/uninstalled/` (the Trash is
  privacy-protected, so the kit cannot check it).

## Privacy

- No `screencapture` unless `PP_SCREENSHOTS=1`. Screenshots are taken by the agent with `cu.sh shot`, or by the kit only
  when that flag is set. `snap()` is a no-op otherwise.
- No `osascript`, no AppleScript, no Accessibility, no `tccutil`, no `defaults write`, no `sudo`.
- The clipboard is written by the app, never read by the kit.
- Steam's login and config files are never read. The only Steam file read is `logs/console_log.txt`, read-only, from a
  byte offset, looking for `Depot download complete`. The Steam folder listings (G-APP6) are names only.
- SteamIDs and persona names stay in `logs/`. The results JSON records that they were valid.
- The Microphone prompt from PEAK must not be clicked (neither Allow nor Don't Allow). The agent takes it as
  `dialog-<n>` and says so in its answer (G-APP3 CU-mainmenu, and the other steps).
- Everything the app writes goes under `$JOB/appdata`, `$JOB/apps` and `$JOB/uninstalled`. Anything outside the job dir is
  listed in the gate results, as the kit does for Steam.

## Known limits (for the lead)

- `run_gate.sh` has a default timeout per gate in `gate_timeout_default`, and it has no entries for `G-APP1` to
  `G-APP6` (the default is 30 min). `run_slot.sh` does not pass a gate's `timeout_min` to `run_gate.sh`. The slot file
  therefore states the intended limits, but the watchdog uses the default until `run_gate.sh` gets these entries
  (G-APP2 needs about 130 min).
- `cleanup.sh` and `lib/common.sh: outside_candidates()` do not know the app's paths yet. Anything the app writes under
  `~/Library` on the first run has to be added there before cleanup can remove it.
- The app's exact file names (`runtime/<id>/share/wine/wine.inf`, `PeakPackMac/status-launch.json`, `manifest.json` entry
  keys, the `progress` value) are taken from the contract in the task, not from a running app. The first run is the test.
