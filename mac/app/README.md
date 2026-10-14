# PEAK (Modded) for Mac

The app Joshua's friends download to play PEAK with his mods on an Apple Silicon Mac. It turns the
MacPort stack into a few clicks:
- the Wine runtime (Wine 11, DXMT and the Steam bridge);
- the friend's own Steam account and copy of PEAK;
- the same signed PeakPack mod pack as on Windows.

Our own code only, under the MIT licence (`../LICENSE`). The app never contains or redistributes Valve,
Apple, Unity or game files. Everything else is fetched at run time from pinned, hash-checked sources, or
by Steam using the friend's own licence.

## For friends

1. **Download** `PEAK-Modded-Mac-<version>.zip` from the link Joshua sends you, open it, and drag
   **PEAK (Modded)** into **Applications**.
2. **Open it.** macOS says it can't check the app. Click **Done**, then open **System Settings → Privacy &
   Security**, scroll down, and click **Open Anyway** next to "PEAK (Modded)". You only do this once.
3. Click **Set Up PEAK**. The app then:
   - checks your Mac (macOS 14 Sonoma or later). If Rosetta is missing, macOS asks to install it: click **Install**;
   - downloads the game engine (about 160 MB) and prepares PEAK's Windows folder (about a minute).
4. **Steam:** open Steam for Mac and sign in with the account that owns PEAK. If you don't have Steam yet,
   the app's **Get Steam** button takes you to steampowered.com.
5. **Get PEAK from Steam**, the only manual step:
   - click **Open Steam Console**. The app copies a line for you and opens Steam's Console;
   - click the box at the bottom of the Console, press **⌘V**, then **Return**.

   Steam downloads PEAK's Windows files (about 1.9 GB) using your account, and the app shows the progress.
6. The app installs the mods and shows **All set**. Click **Play PEAK**. The first time, macOS asks about the
   microphone: click **Allow** for voice chat.
7. **Keep it in the Dock:** right-click the icon → Options → Keep in Dock.

**Every day:** click **PEAK (Modded)**. It updates the mods and starts PEAK. Join Joshua with a room code
or from your Steam friends list.

**More options:** hold **Option** while opening the app, or right-click its Dock icon. You get:
- Play normal PEAK;
- Show FPS;
- Logs;
- Repair;
- Uninstall.

**Something wrong?** Every error screen says what to do next and has **Copy Diagnostics**. Paste the result
into a message to Joshua. It contains no passwords and no account details. Your name and SteamID are
removed from it.

## Design

### Flow

| Moment | What the app does |
|---|---|
| First open | Welcome → **Set Up PEAK** → steps in a sidebar: Check this Mac, Install Rosetta, Get the game engine, Prepare the Windows folder, Sign in to Steam, Get PEAK from Steam, Install the mods → All set |
| Every click | Signed manifest (cached when offline) → ready check (it runs any missing step, e.g. a new engine) → Steam open? → game update check → launcher hold → `PeakPack.exe --headless --launch --launch-method direct --on-sync-fail stop` (status JSON polled every 250 ms) → PEAK runs → the window tucks itself away → the app quits when PEAK exits |
| Sync fails | "Play with the Mods I Have" (`--on-sync-fail installed`) / "Play Normal PEAK" / Close |
| Option-click or Dock click | Options window: Play with Mods, Play Normal PEAK, Show FPS (Metal HUD via `PP_HUD=1`), Logs, Copy Diagnostics, Check for Updates, Re-download PEAK, Repair…, Uninstall… (the same items are in the Dock menu and the PEAK menu) |

**Data** (`~/Library/Application Support/PeakPack`, DESIGN §3.1, INTERFACES §3):

| Path | What |
|---|---|
| `runtime/<id>/` | The active engine and the previous one (kept for rollback) |
| `prefix/` | The Wine prefix |
| `prefix/drive_c/Games/PEAK` | The game |
| `prefix/drive_c/users/<u>/AppData/Local/PeakPack/PeakPack.exe` | PeakPack |
| `prefix/drive_c/PeakPackMac/` | Bridge launcher, forwarder and PeakPack status files |
| `frontend/state.json` | What the app remembers |
| `frontend/status.json` | Machine-readable status (see Test hooks) |

Logs are in `~/Library/Logs/PEAK Modded/`: the app log, `wine/`, `prefix.log`, `peakpack.log` and
`launcher.log`. **Logs** also copies PeakPack's `log.txt`, BepInEx's `LogOutput.log` and PEAK's `Player.log`
into `game/` there.

### Trust

| What | Checked by |
|---|---|
| Runtime tarball | It must match the SHA-256 baked into the app (`kit/mac-kit.json`) **and** the release's `SHA256SUMS`. The signed manifest's `platforms.mac.runtime` replaces the baked pin once FriendInstaller publishes it (proposal in `proposals/`). An unsigned or malformed pin never changes it |
| Signed manifest | `manifest.json` + `.sig`: ECDSA P-256/SHA-256 with the same public key as the Windows app. A unit test verifies the real rev-5 files |
| PeakPack.exe | Comes from the signed manifest's `app` entry (URL + SHA-256). After that, PeakPack updates and verifies itself and the mods exactly as on Windows. The app never downloads mods itself |
| Downloads | Every download is HTTPS-only, with every redirect hop checked against `github.com` / `githubusercontent.com`. It resumes (`.part` + Range). URLSession downloads carry no quarantine flag, so there's no Gatekeeper prompt |
| Wine | Always started as `bash -c '. pp-env.sh; pp_env …; exec wine'` (INTERFACES §4). `WINEDLLOVERRIDES` can only be `winhttp=n,b`, and only for PeakPack |

### Getting the game: decision and evidence

| Option | Verdict | Evidence |
|---|---|---|
| (a) Something Steam or our bridge can trigger | **None is legitimate** | `steam://open/console` only shows the console. No URL or command line runs `download_depot` (MacPort DESIGN §5.4). `steam://install/3527290` is the macOS install path, and PEAK has no macOS depot. Our bridge exposes only the public `ISteam*` interfaces; installing another platform's depot would need Steam's private `IClientAppManager`, which is reverse-engineered and a Steamworks-licence/SSA risk. Writing Steam's config files is off-limits |
| (b) steamcmd | **No gain** | It needs its own username, password and Steam Guard login in Terminal.app; hosting its prompt would mean our process sees the keystrokes. It is Intel-only (the Homebrew cask says it "requires Rosetta 2"). We found no source for QR or mobile-approval login |
| **(c) Guided paste (implemented, default)** | One paste + Return | It runs Valve's own client with the friend's own login. The app copies `download_depot 3527290 3527291` (it writes the clipboard and never reads it) and opens `steam://open/console`. It shows a drawn diagram of the input box (not a Valve screenshot). It watches `console_log.txt` read-only for `Depot download complete : "<path>" (manifest <id>)`, and shows progress from the size of `depot_3527291`. After 90 s it offers "Didn't start?" help. It then verifies the folder (required files, `version.txt`, size) and moves it into the prefix (a same-volume rename) |
| (d) DepotDownloader 3.4.0 `-qr` | Listed only | A third-party client (GPL-2, .NET), with QR login in the Steam mobile app. It is only allowed with Joshua's explicit OK |

### Game updates

**Detection** (read-only, best first):
1. The public manifest id of depot 3527291 in Mac Steam's own PICS cache (`appcache/appinfo.vdf`, v39/v40/v41 formats), compared with the id recorded at download.
2. The signed pack's `gameVersion`, compared with `version.txt`.
3. A manual **Re-download PEAK**.

**Applying an update:**
- The installed copy is **cloned** with APFS clonefile (instant, no extra space) to where `download_depot` writes, so Steam can reuse unchanged files.
- The installed copy in the prefix is untouched until the new folder verifies.
- Then it swaps: old → `PEAK.old`, new → `PEAK`, then `PEAK.old` is deleted.
- If anything fails or the friend cancels, the old playable copy stays and only our clone is removed.

### Launch path (the testkit G-D2 contract)

- `peakpack_steam_launcher.exe --no-launch` keeps the bridge advertised as "Steam running". Launcher 0.2.0+ warms the auth ticket before this, which protects PEAK's one-shot EOS login.
- Then PeakPack starts PEAK.exe directly.
- How the app knows when PEAK has quit depends on the runtime:
  - If the installed runtime's `manifest.json` has `launcher.holdUntilExit` (pp2+), the app adds `--hold-until-exit PEAK.exe`, and the launcher exits with the game (exit 125 if the game never started).
  - Otherwise (pp1), the app watches for `PEAK.exe` with pgrep, then runs `wineserver -k` on our prefix only.

### Self-update with rollback

**App:**
- It checks the `mac-build-app-*` prereleases (GitHub API, at most every 6 h, or from the menu). A newer `platforms.mac.minFrontEnd` in the signed pack forces the update before play.
- It downloads the zip and verifies it against the release's `SHA256SUMS`. It unzips with `ditto`, then checks the bundle id and version and runs `codesign --verify --deep --strict`.
- A small watchdog script swaps the bundle after the app quits, keeping the old one in `frontend/app-backup/`, and starts the new version.
- The new version must report a healthy start within 90 s, or the old one is put back and reopened.
- This needs the app in Applications. A translocated copy (opened from Downloads) is told to move.

**Runtime:**
- A new pin unpacks to `runtime/<id>` next to the old one.
- The state switches only after `pp-create-prefix.sh` has updated the prefix with it.
- If the prefix rejects it, the previous engine is re-applied.
- Two engines are kept.

### Look and feel

- AppKit lifecycle with SwiftUI views and standard controls.
- SF Symbols from the macOS 12 set.
- A sidebar material, system colours (light and dark), and a standard About panel and menus.
- An original icon drawn in code (`scripts/make_icon.swift`).
- Plain-English copy throughout.
- Every failure is a `FriendError`: a heading, the next step, action buttons, Details and Copy Diagnostics.

### Minimum macOS

- **The app opens on macOS 12 Monterey** (`LSMinimumSystemVersion` 12.0). That is the floor for SwiftUI 3 and URLSession async.
- **PEAK itself needs macOS 14 Sonoma**, because DXMT needs it (`mac/runtime/build/pins.env` `PP_MACOS_MIN=14.0`).
- So on 12–13 the first setup step explains this plainly and offers **Open Software Update**, instead of macOS refusing to open the app.
- Every M1/M2 MacBook Air can run 14 or later.
- The app is universal (arm64 + x86_64). Intel Macs are allowed but untested.

### Signing

- Ad-hoc today, but already with the hardened runtime, the `audio-input` entitlement (PEAK's microphone is attributed to this app, because Wine is its child process) and `NSMicrophoneUsageDescription`.
- With an Apple Developer ID, set the `MAC_DEVID_*` / `MAC_NOTARY_*` repo secrets. `scripts/notarize.sh` then re-signs, notarises and staples in CI. No code changes are needed, and the "Open Anyway" step disappears.

## Build and CI

- `.github/workflows/mac-app.yml` runs on changes to `mac/app/**`, or manually.
- On `macos-15` it runs:
  - `swift test` (unit tests for pins, hashes, signatures, downloads, state, Steam console/appinfo parsing, the setup plan, the Wine command contract, updates and diagnostics);
  - `scripts/build_app.sh`, a universal build with an ad-hoc signature, the icon and the x86_64-only Rosetta helper;
  - bundle checks (nothing third-party inside);
  - `--print-status`;
  - a GUI smoke test (the window opens on the welcome screen).
- `publish=true` creates the prerelease `mac-build-app-<VERSION>` with `--prerelease --latest=false`, then checks that `releases/latest` is still a `rev-N` pack release. The version comes from `VERSION`.

## Test hooks (used by `mac/testkit` gates G-APP1…6)

| Hook | What |
|---|---|
| `--data-dir DIR` | All data, state and logs under DIR (`DIR/Logs`). No "move to Applications" prompt |
| `--no-autoplay`, `--options` | Don't start PEAK by itself / open the options window |
| `--skip-update-check` | No GitHub API call at start |
| `--uninstall-to DIR` | Uninstall moves files into DIR instead of the Trash, because the Trash is privacy-protected for scripts |
| `--print-status` | One JSON object of probes, the state and the last status file. No GUI, no network, no prompts |
| `frontend/status.json` | Kept up to date: `phase` (welcome, setup, done, ready, launching, playing, error, message), `step`, `stepState`, `progress`, `problem{code,heading,advice}`, `runtimeId`, `game`, `packRevision`, `lastLaunch`. No personal data |

## Files

| Path | What |
|---|---|
| `kit/mac-kit.json` | Embedded pins: runtime tag/asset/SHA-256, manifest URL + public key, game ids, minimum macOS |
| `Sources/PeakModdedCore/` | Pure logic: pins, hashes, signature, downloader, state, Steam console and appinfo parsing, setup plan, Wine commands, self-update script |
| `Sources/PeakModded/` | App: `AppModel` (flows), `Services/` (runtime, prefix, game, mods, launch, update, maintenance), `UI/` |
| `Tests/PeakModdedCoreTests/` | Unit tests. Fixtures: the real rev-5 manifest + signature, the pp1 `SHA256SUMS` |
| `Helpers/RosettaCheck/` | x86_64-only helper app. Opening it makes macOS offer its own Rosetta install |
| `packaging/` | `Info.plist`, entitlements, NOTICE |
| `scripts/` | `build_app.sh`, `make_icon.swift`, `notarize.sh` |
| `proposals/` | Change requests for other owners (FriendInstaller) |
