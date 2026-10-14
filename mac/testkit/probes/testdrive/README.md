# PeakPack TestDrive (test only)

BepInEx 5 plugin (`com.peakpack.testdrive`, MIT, ours) for the Mac test kit's `G-A2-lite --test-drive`.
It is **never part of the pack and never sent to friends**: the gate copies `PeakPack.TestDrive.dll` (from the
Steam test kit tarball) into the TEST prefix's PeakPack profile for one run and removes it afterwards.

It replaces held keys (the hub's computer-use agent cannot hold W or move the mouse):

1. Main menu: presses Continue on PEAK's first-launch microphone chooser if it shows (selection unchanged), then
   waits for the kit's go file `BepInEx/config/peakpack.testdrive.go` (written after the gate's main-menu step).
2. Presses Play Solo (`MainMenu.playSoloButton`, offline mode; `StartMode = Host` presses `hostButton` instead) and
   advances only when the active scene IS `Airport`, loading is done and the scout has spawned.
3. Calls `AirportCheckInKiosk.StartGame(Ascent)` (what the boarding pass's Start button calls: an RPC to the master
   client). If no island load starts within 30 s, calls `LoadIslandMaster(Ascent, RunSettings)` directly; if that
   does not load either, it fails with the Photon state (in room, offline, master client) in the line.
4. On the island (`GameHandler.IsInGameplayScene`, loading done, scout fully conscious, beach wake-up over):
   walks forward with a slow look left/right and a short hop every 6 s for `WalkSeconds`, through a Harmony postfix
   on `CharacterInput.Sample` (only for the local character, only while walking).

Config `BepInEx/config/com.peakpack.testdrive.cfg`: `[TestDrive] WalkSeconds` (0 = off, the default),
`GoWaitSeconds` (900), `StageTimeoutSeconds` (600), `Ascent` (0), `StartMode` (`Solo` or `Host`).

Log lines start with `TESTDRIVE` and go to `BepInEx/PeakPack/testdrive.log` (flushed at once; BepInEx's
LogOutput.log is buffered, so 0.1.0's lines arrived late or not at all) and to the BepInEx log: `active`,
`stage=<menu|waitgo|start|airport|kiosk|levelload|island|walk|done> scene= loading= local= in_room= offline= master=`,
`scene_loaded name=`, `wait stage= t=` (every 15 s while a stage waits), `first_time_continue`, `go=file|timeout`,
`button_found`, `button_clicked`, `airport_ready`, `kiosk_found`, `kiosk_start_called`, `load_island_master_called`,
`level_load_requested`, `island_awake`, `island_ready`, `walk_start`, `walk_progress t= dist=`, `walk_end seconds= dist=`,
or `fail stage=<stage> reason=...` / `inert ...`.

Safety (ScoutmasterMode DESIGN §11b rules): no compile-time reference to Assembly-CSharp, so its IL cannot reference
a non-public game member (nothing for IlScan to find); every game member is resolved by name at startup (missing ->
inert); hooks check `Live` first and run their work in a `NoInlining` method inside try/catch; any failure logs one
line, removes the Harmony patch and leaves the game vanilla.

Build: .NET SDK, packages as for the HarmonyX probe (`NuGet.Config`), built by `mac-steam-tests.yml`.
