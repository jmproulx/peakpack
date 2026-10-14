# PeakPack TestDrive (test only)

BepInEx 5 plugin (`com.peakpack.testdrive`, MIT, ours) for the Mac test kit's `G-A2-lite --test-drive`.
It is **never part of the pack and never sent to friends**: the gate copies `PeakPack.TestDrive.dll` (from the
Steam test kit tarball) into the TEST prefix's PeakPack profile for one run and removes it afterwards.

It replaces held keys (the hub's computer-use agent cannot hold W or move the mouse):

1. Main menu: presses Continue on PEAK's first-launch microphone chooser if it shows (selection unchanged), then
   waits for the kit's go file `BepInEx/config/peakpack.testdrive.go` (written after the gate's main-menu step).
2. Presses Play Solo (`MainMenu.playSoloButton`, offline mode), waits in the Airport until loading is done.
3. Calls `AirportCheckInKiosk.StartGame(Ascent)` (what the boarding pass's Start does).
4. On the island (`GameHandler.IsInGameplayScene`, loading done, scout fully conscious, beach wake-up over):
   walks forward with a slow look left/right and a short hop every 6 s for `WalkSeconds`, through a Harmony postfix
   on `CharacterInput.Sample` (only for the local character, only while walking).

Config `BepInEx/config/com.peakpack.testdrive.cfg`: `[TestDrive] WalkSeconds` (0 = off, the default),
`GoWaitSeconds` (900), `StageTimeoutSeconds` (600), `Ascent` (0).

Log lines in LogOutput.log start with `TESTDRIVE`: `active`, `stage=<menu|waitgo|solo|airport|kiosk|island|walk|done>`,
`first_time_continue`, `go=file|timeout`, `solo_clicked`, `kiosk_start`, `island_ready`, `walk_start`,
`walk_progress t= dist=`, `walk_end seconds= dist=`, or `fail stage=<stage> reason=...` / `inert ...`.

Safety (ScoutmasterMode DESIGN §11b rules): no compile-time reference to Assembly-CSharp, so its IL cannot reference
a non-public game member (nothing for IlScan to find); every game member is resolved by name at startup (missing ->
inert); hooks check `Live` first and run their work in a `NoInlining` method inside try/catch; any failure logs one
line, removes the Harmony patch and leaves the game vanilla.

Build: .NET SDK, packages as for the HarmonyX probe (`NuGet.Config`), built by `mac-steam-tests.yml`.
