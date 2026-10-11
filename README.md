# PeakPack (prototype)

A one-file Windows app that gives friends the host's exact PEAK mod set, with no mod manager to learn.
Friends double-click **"PEAK (Modded)"** on their desktop to update the mods and play with them.
Starting PEAK from Steam is still the normal, unmodded game.

The design, the options considered and the open decisions are in [DESIGN.md](DESIGN.md).

> Prototype status: it works end to end against a **sandbox fake game**. It has **not** been run against a
> real PEAK install, and nothing has been published anywhere. `pack.config.json` still has a placeholder manifest URL.

## Layout

```
src/PeakPack.Core   library: manifest, Thunderstore resolver, downloader (HTTPS allowlist + SHA-256), installer,
                    game-folder Doorstop proxy, Steam locator, launcher, shortcuts, uninstall, self-update, signing
src/PeakPack.App    PeakPack.exe: the friend GUI (WinForms, single-file, self-contained)
src/PeakPack.Cli    PeakPack.Cli.exe: Joshua's publisher (scan / publish / keygen), plus headless friend commands for testing
tools/              sandbox + test scripts, publish-release.ps1 (GitHub upload, never run)
examples/           publish.example.json
```

## Build

The .NET 10 SDK is at `C:\Program Files\dotnet` (it may not be on PATH):

```powershell
$dn = "C:\Program Files\dotnet\dotnet.exe"
& $dn build FriendInstaller.sln
# The friend exe: one ~49 MB file that needs nothing else installed
& $dn publish src\PeakPack.App -c Release -o publish-out
```

## Run the tests against the sandbox (never the real game)

```powershell
powershell -ExecutionPolicy Bypass -File tools\make-sandbox.ps1            # sandbox\PEAK with a fake PEAK.exe that logs its arguments
powershell -ExecutionPolicy Bypass -File tools\sandbox-test.ps1            # 39 end-to-end checks (CLI); downloads real packages from Thunderstore
powershell -ExecutionPolicy Bypass -File tools\gui-selftest.ps1 -Published # drives the real GUI: Install -> Play Modded -> Play normal; screenshots in sandbox\shots
powershell -ExecutionPolicy Bypass -File tools\shortcut-launch-test.ps1    # "double-clicks" the created shortcut, before and after a new publish
```

`sandbox-test.ps1` covers:

- publish
- install
- an idempotent re-sync
- an update (add, remove and change mods, strict cleanup, repairing a deleted file, keeping a friend's edited config)
- tamper detection (an edited manifest fails the signature check; a swapped file fails the SHA-256 check; a host that isn't allowed is refused)
- the modded and vanilla launch arguments
- repairing the proxy after r2modman or Gale overwrites it
- taking over a foreign BepInEx install (backed up, never deleted)
- uninstall, ending with **the game folder's file list identical to before**

All test state lives in `sandbox\` (gitignored).

## Using the CLI by hand

```powershell
$cli = "src\PeakPack.Cli\bin\Debug\net10.0-windows\PeakPack.Cli.exe"
& $cli locate                                                   # where Steam and PEAK are (read-only)
& $cli scan --plugins "<PEAK>\BepInEx\plugins" --out publish.json   # identify installed mods by hash (read-only)
& $cli keygen --out C:\somewhere-private\peakpack-signing.pem   # prints the public key for pack.config.json
& $cli publish --config publish.json --out out                  # writes out\manifest.json (+ .sig) and the custom files

# friend actions, headless, always with overrides in testing:
$o = @('--game-dir','sandbox\PEAK','--data-dir','sandbox\data')
& $cli install --manifest out\manifest.json --allow-local @o [--public-key <base64>] [--adopt]
& $cli launch --modded --method dry @o     # prints: steam.exe -applaunch 3527290 --doorstop-enabled true --doorstop-target-assembly <profile>\BepInEx\core\BepInEx.Preloader.dll
& $cli status @o
& $cli uninstall @o --shortcut-dir sandbox\shortcuts
```

The GUI takes the same test overrides: `--game-dir`, `--data-dir`, `--manifest`, `--public-key`, `--allow-local`,
`--shortcut-dir` and `--launch-method steam|direct|dry`. It also takes `--screenshot out.png` and `--selftest <dir>`.
Without `--shortcut-dir`, a test data dir creates **no** shortcuts and no registry entry.
`--allow-local` (local manifest and files) exists only for testing. Friends' copies use the HTTPS manifest URL built in from `pack.config.json`.

## What friends get (real use)

1. Joshua edits `src/PeakPack.App/pack.config.json` (manifest URL and public key), publishes the exe, and shares it.
2. The friend runs `PeakPack.exe` and clicks **Install**. PEAK is found automatically through Steam's `libraryfolders.vdf`.
3. The app copies itself to `%LOCALAPPDATA%\PeakPack\` and installs BepInEx and the mods into `%LOCALAPPDATA%\PeakPack\profile\`.
   It puts only `winhttp.dll` and a `doorstop_config.ini` with `enabled = false` in the PEAK folder.
   It creates the **PEAK (Modded)** desktop and Start Menu shortcuts and an Installed Apps entry for uninstalling.
4. From then on: **PEAK (Modded)** = check for updates, sync, then `steam.exe -applaunch 3527290 --doorstop-enabled true --doorstop-target-assembly ...`.
   No window appears when nothing needs downloading. The Steam Play button = normal PEAK.
