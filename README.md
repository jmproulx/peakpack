# PeakPack

A one-file Windows app that gives friends the host's exact PEAK mod set, with no mod manager to learn.
Friends double-click **"PEAK (Modded)"** on their desktop to update the mods and play with them.
Starting PEAK from Steam is still the normal, unmodded game.

Design, verified facts, the real-PC test, the unsigned-exe walkthrough and the decisions are in [DESIGN.md](DESIGN.md).

> Status (v0.3): tested end to end against a sandbox fake game, and the launch method is verified against the real
> PEAK install (`docs/real-pc-test-2026-10-11.txt`). Nothing has been published yet; the release pipeline is ready
> and dry-run tested for `jmproulx/peakpack`.

## Layout

```
src/PeakPack.Core       manifest, Thunderstore resolver, downloader (HTTPS allowlist + SHA-256), installer, game-folder Doorstop
                        proxy, Steam locator, launcher, shortcuts/self-install, uninstall, self-update, signing,
                        PackDiff (plain-language changes), PublishPipeline (prepare / release via gh / stamp)
src/PeakPack.App        PeakPack.exe: the friend window (WinForms, single-file, self-contained) + the Host window (--host)
src/PeakPack.Cli        PeakPack.Cli.exe: headless publisher (scan / publish / prepare / release / stamp / keygen) + friend commands
src/PeakPack.Companion  in-game companion plugin (BepInEx 5): lobby revision check + live settings. Builds only where PEAK is installed
tools/                  sandbox, GUI, host, v3 and real-PC test scripts; make-icon.ps1; publish-release.ps1
examples/               first-pack.publish.json (InfiniteJetpack + JetpackBoost), publish.example.json, manifest.example.json
docs/                   screenshots (before/after), real-PC test report
```

## Build

```powershell
$dn = "C:\Program Files\dotnet\dotnet.exe"
& $dn build FriendInstaller.sln
& $dn build src\PeakPack.Companion -c Release              # needs PEAK installed (reads its DLLs, never writes the game folder)
& $dn publish src\PeakPack.App -c Release -o publish-out   # the friend exe: one ~50 MB file
```

## Tests (sandbox; never the real game, except the explicit real-PC test)

```powershell
powershell -ExecutionPolicy Bypass -File tools\make-sandbox.ps1            # fake PEAK.exe that logs its arguments
powershell -ExecutionPolicy Bypass -File tools\sandbox-test.ps1            # 39 v0.2 end-to-end checks (downloads real packages)
powershell -ExecutionPolicy Bypass -File tools\v3-test.ps1                 # v0.3: pack-info, update check, host options, self-install
                                                                           #   without Mark-of-the-Web, pipeline dry run, stamp, lobby logic
powershell -ExecutionPolicy Bypass -File tools\v4-test.ps1                 # v0.4: live updates via the real PeakPack.exe --hot-update,
                                                                           #   refusals, consent -> pack-info, hotfix dry run, IlScan
powershell -ExecutionPolicy Bypass -File tools5-test.ps1                 # v0.5: Mac/Wine mode (simulated), headless CLI, cockpit bundle, live-update hardening
powershell -ExecutionPolicy Bypass -File tools\v5-test.ps1                 # v0.5: Mac/Wine mode (simulated), headless CLI, cockpit bundle,
                                                                           #   live-update hardening, release revision safety
powershell -ExecutionPolicy Bypass -File tools\gui-selftest.ps1 -Published # friend window at 100/125/150 %: screenshots in sandbox\shots\<scale>
powershell -ExecutionPolicy Bypass -File tools\host-selftest.ps1           # Host window at 100/125/150 % with a dry-run publish
powershell -ExecutionPolicy Bypass -File tools\shortcut-launch-test.ps1    # runs the created desktop shortcut before/after a new publish
powershell -ExecutionPolicy Bypass -File tools\real-pc-test.ps1 -AlsoVanilla   # REAL game, non-destructive; PEAK must be closed
```

## Publishing (Joshua)

One-time (done): signing key at `C:\Users\joshu\PeakPack-keys\peakpack-signing.pem` (keep it out of git, back it up);
its public key and the manifest URL are in `src/PeakPack.App/pack.config.json`; `publish.json` lives at
`%LOCALAPPDATA%\PeakPack-publisher\publish.json` (start from `examples/first-pack.publish.json`).

**Window:** `PeakPack.exe --host` (pick mods, own builds, see what friends will get, write a changelog line, Publish, Play as a friend).

**Headless / agent:**

```powershell
$cli = "src\PeakPack.Cli\bin\Debug\net10.0-windows\PeakPack.Cli.exe"
$cfg = "$env:LOCALAPPDATA\PeakPack-publisher\publish.json"
& $cli prepare --config $cfg                                   # stage rev N+1 and list what friends will get
& $cli release --config $cfg --notes "..." --dry-run           # print the exact gh command, upload nothing
& $cli release --config $cfg --notes "..." --stamp "D:\SteamLibrary\steamapps\common\PEAK\BepInEx"   # upload + update own lobby check
# or: .\tools\publish-release.ps1 -Config $cfg [-DryRun]
```

**Testing with friends (v0.4, DESIGN.md section 17):**

```powershell
& $cli lobby snapshot                                       # ask everyone in your lobby for fresh logs (or Ctrl+F9 in game)
#   -> D:\SteamLibrary\steamapps\common\PEAK\BepInEx\PeakPack-remote-logs\<friend>.log and _lobby.txt
& $cli hotfix --mod HeliPilot --dll <new build> --notes "..."             # dry run: checks the DLL, shows the release
& $cli hotfix --mod HeliPilot --dll <new build> --notes "..." --publish   # release + tell the lobby (live update in a test lobby)
& $cli hotfix --mod HeliPilot --rollback --publish                        # republish the previous build
```

`release` needs the GitHub CLI logged in (found at `%LOCALAPPDATA%\Programs\gh\bin\gh.exe` or on PATH) and the repo to exist.

## Friend commands (headless, for testing)

```powershell
$o = @('--game-dir','sandbox\PEAK','--data-dir','sandbox\data')
& $cli install --manifest out\manifest.json --allow-local @o [--public-key <base64>] [--adopt] [--keep-extra] [--no-game-folder]
& $cli check --manifest out\manifest.json --allow-local @o      # "Update available: revision 1 -> 2, 2 mods changed"
& $cli launch --modded --method dry @o [--no-proxy]
& $cli status @o
& $cli uninstall @o --shortcut-dir sandbox\shortcuts
& $cli selfinstall --exe <PeakPack.exe> --data-dir D --shortcut-dir S --game-dir G
```

The GUI takes the same test overrides: `--game-dir`, `--data-dir`, `--manifest`, `--public-key`, `--allow-local`, `--shortcut-dir`,
`--launch-method steam|direct|dry`, `--ui-scale 1.25`, `--no-self-install`, plus `--screenshot`, `--selftest DIR`, `--selftest-open DIR NAME`.
A test data dir without `--shortcut-dir` creates no shortcuts and no registry entry, and never self-installs.

## What friends get

1. A link: `https://github.com/jmproulx/peakpack/releases/latest/download/PeakPack.exe` (the message to send with it is in DESIGN.md §10).
2. First open: the app installs itself to `%LOCALAPPDATA%\PeakPack\`, puts **PEAK (Modded)** on the desktop and in the Start Menu
   (plus **PeakPack** in the Start Menu), and shows what's in the pack. **Install** downloads BepInEx and the mods into
   `%LOCALAPPDATA%\PeakPack\profile\`. Only `winhttp.dll` and a `doorstop_config.ini` with `enabled = false` go into the PEAK folder.
3. From then on: **PEAK (Modded)** = check for updates, sync, `steam.exe -applaunch 3527290 --doorstop-enabled true --doorstop-target-assembly …`.
   Steam's Play button = normal PEAK. In a lobby, the companion says if someone's pack revision differs.
