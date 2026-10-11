# PeakPack: one-click PEAK mods for friends

*Design doc, 11 Oct 2026. Prototype: `C:\Users\joshu\PeakMods\FriendInstaller` (see README.md).*

## 1. Recommendation in one paragraph

Build a small, self-contained Windows app (**PeakPack.exe**) that:

- reads a hash-pinned, signed **manifest** that Joshua publishes on GitHub Releases;
- downloads the listed mods **straight from Thunderstore**, plus Joshua's own DLLs from his release;
- keeps BepInEx and all mods in its **own folder** (`%LOCALAPPDATA%\PeakPack\profile`), not in the game;
- puts only Doorstop's `winhttp.dll` and a `doorstop_config.ini` with `enabled = false` in the PEAK folder;
- starts modded PEAK through Steam with per-launch Doorstop arguments.

For the friend that means:

- **Starting PEAK from Steam is always normal PEAK.** The **"PEAK (Modded)"** desktop shortcut checks for updates, syncs and launches with mods in one double-click.
- Nothing ever has to be switched back.
- "Remove everything" returns the game folder to exactly what Steam installed.

Every existing friend-sync option (Thunderstore modpacks, r2modman profile codes, Gale Profile Sync) requires each friend to install a mod manager. I found no maintained standalone installer for BepInEx games, so a small custom app is the only way to meet the "no mod manager" requirement.

## 2. Verified facts this design rests on

| Fact | Source |
|---|---|
| PEAK is Steam app **3527290**; Windows only (no Mac/Linux build); no Steam Workshop; no official mod support | Steam appdetails API; `appmanifest_3527290.acf` in Joshua's library |
| `BepInEx-BepInExPack_PEAK` 5.4.75301 (BepInEx 5.4.23.3) ships a PEAK fork of **Doorstop 4.4.1** (`.doorstop_version` = `4.4.1PEAK`, adds `[Extra] bypass_vulkan`). Zip layout: `BepInExPack_PEAK/{winhttp.dll, doorstop_config.ini, .doorstop_version, BepInEx/core/*, BepInEx/config/BepInEx.cfg}` | Inspected the zip; thunderstore.io/c/peak/p/BepInEx/BepInExPack_PEAK |
| Doorstop 4 load order: built-in defaults (`enabled = FALSE`, no target) â†’ `doorstop_config.ini` if present (a *missing key* defaults to `true`) â†’ **command line** (`--doorstop-enabled`, `--doorstop-target-assembly`, â€¦) â†’ `DOORSTOP_DISABLE` env var. **The command line overrides the ini.** | NeighTools/UnityDoorstop `src/windows/config.c` `load_config()`, `src/config/common.c` `init_config_defaults()` |
| BepInEx 5 takes its root from the preloader's location: `bepinPath = ParentDirectory(DOORSTOP_INVOKE_DLL_PATH, 2)`. So a preloader at `<profile>\BepInEx\core\` means plugins and config come from `<profile>\BepInEx\â€¦`, while the game root comes from the process path | BepInEx/BepInEx v5-lts `BepInEx.Preloader/Entrypoint.cs`, `BepInEx/Paths.cs` |
| r2modman and Gale both launch on Windows with `steam.exe -applaunch <appid> --doorstop-enabled true --doorstop-target-assembly <profile>\BepInEx\core\BepInEx.Preloader.dll` for Doorstop 4 | r2modmanPlus `BepInExGameInstructions.ts`, `SteamGameRunner_Windows.ts`; Gale `src-tauri/src/profile/launch/{platform,mod_loader}.rs` |
| Thunderstore BepInEx install rules: `plugins`, `patchers`, `core`, `monomod` â†’ `BepInEx/<route>/<Namespace-Name>/`; `config` â†’ `BepInEx/config/` (no subfolder); loose files â†’ `plugins/<Namespace-Name>/` | Thunderstore schema `api/experimental/schema/dev/latest`; r2modman `ecosystem.json` and wiki |
| Thunderstore download URLs 302-redirect to `ccdn.thunderstore.io/live/repository/packages/<ns>-<name>-<ver>.zip`. The API publishes **no file hashes**, so we compute and pin our own SHA-256. Versions are immutable (a re-upload needs a version bump) | Live headers; Thunderstore OpenAPI; wiki |
| Thunderstore has **no unlisted/private packages**. Its rules forbid re-uploading other authors' packages, and forbid packages that download and run external code (so an auto-updater plugin can't be listed there) | wiki.thunderstore.io moderation/global-rules |
| Gale "Profile Sync" (beta): the owner pushes, subscribers pull (automatically on launch), but **every friend must install Gale** | github.com/Kesomannen/gale/wiki/Profile-sync |
| GitHub Releases: files under 2 GiB, no total-size or bandwidth limit stated; `â€¦/releases/latest/download/<asset>` redirects to the latest release | docs.github.com about-releases, linking-to-releases |
| SmartScreen: unsigned files start with zero reputation for every new version; **EV certificates no longer bypass SmartScreen**; Artifact (Trusted) Signing costs $9.99/mo, and **individuals must be in the US or Canada** | learn.microsoft.com smartscreen-reputation; azure artifact-signing quickstart/FAQ |

Not verified, needs a real-world check:

- **Does Steam show a confirmation dialog for `-applaunch` with custom arguments?** It is known to for `steam://run/<id>//<args>`, which is why we don't use that. r2modman and Gale use `-applaunch` and I found no reports of a prompt, but no primary source either. This is the first thing to try on Joshua's PC.
- **Does Steam's "Verify integrity of game files" leave extra files like `winhttp.dll` in place?** Community consensus says yes: it only restores depot files and ignores extras. I found no explicit Valve statement. Either way, our uninstall removes our files itself, so we don't depend on Verify.

## 3. Options compared

| Option | Friend installs a manager? | Auto-updates | Joshua's custom DLLs | Verdict |
|---|---|---|---|---|
| **Thunderstore modpack** (manifest + deps uploaded as a package) | Yes, any manager | Through the manager | Only if uploaded publicly | Public only, so not suited to unreleased DLLs. A fine *complement* later. |
| **r2modman / TMM profile code** | Yes | No (a one-off snapshot); the importer skips `.dll` files from codes | No | No |
| **Gale Profile Sync** | Yes (Gale; friends don't need a login) | Yes, on launch | Profile import skips DLLs (same r2z format) | Best existing option, but breaks the "no manager" requirement |
| **Thunderstore CLI (tcli)** | No, but it's a CLI | No | No | Stale (last release Jun 2024); not friend-friendly |
| **Steam Workshop** | n/a | n/a | n/a | PEAK doesn't support it |
| **Zip of the game folder / .bat / `irm â€¦ \| iex` one-liner** | No | No (or re-run) | Yes | No vanilla switch; a PowerShell one-liner is scary for non-technical friends and runs remote script code; redistributing others' mods in a zip is a licensing problem |
| **In-game auto-updater BepInEx plugin only** | No, but someone must install BepInEx first | Yes | Yes | It can't update BepInEx or itself while loaded, has no UI before the game window, and Thunderstore rules forbid listing it. Doesn't solve the first install or vanilla switching |
| **Custom app (PeakPack)** | **No** | **Yes, every launch (silent)** | **Yes** | **Recommended** |
| Hybrid: app + an updater plugin that syncs at game start | No | Yes | Yes | No benefit over syncing in the shortcut before launch. A tiny plugin is still useful for *lobby checks* (Â§9) |

## 4. Switching between modded and normal PEAK (first-class requirement)

### 4.1 Options

| Approach | How you play vanilla | Risk for a non-technical friend | Verdict |
|---|---|---|---|
| **A. Clean game folder + per-launch args** (r2modman/Gale model). BepInEx and mods live in `%LOCALAPPDATA%\PeakPack\profile`. The game folder has only `winhttp.dll` and an ini with `enabled = false`. "PEAK (Modded)" passes `--doorstop-enabled true --doorstop-target-assembly <profile preloader>` | Just start PEAK from Steam (or "Play normal PEAK" in the app) | **None.** Modded is opt-in per launch and nothing stays switched on | **Recommended, implemented** |
| B. BepInEx in the game folder; flip `enabled` in the ini | Toggle in the app | Sticky: friends forget they're modded, and Steam launches stay modded | No |
| C. Rename `winhttp.dll` on and off | Toggle | Sticky, same as B; also breaks if Steam or AV interferes | No |
| D. A separate copy of the game folder | Launch the copy | Steamworks games launched from a copied folder typically get relaunched by Steam from the original install. ~GBs of disk; updates diverge | No |
| E. Steam launch options (`--doorstop-enabled false`) | Edit launch options | Requires friends to edit Steam settings | No |

Why A works (verified in source, Â§2):

- Doorstop reads the ini (`enabled = false` â†’ plain Steam launches load nothing).
- It then parses the command line, which wins.
- BepInEx locates its plugins and config relative to the preloader we pass, so the game folder never needs a `BepInEx\` folder.

PeakPack also:

- rewrites the two proxy files before each modded launch, which undoes r2modman or Gale overwriting them;
- passes `--doorstop-enabled false` explicitly for "Play normal PEAK".

r2modman's own Doorstop-4 vanilla launch passes the Doorstop-3 name `--doorstop-enable false`, which Doorstop 4 ignores. We use the correct name.

### 4.2 What the friend sees

- **Desktop "PEAK (Modded)"** (PEAK's icon) = with mods.
- **Steam's Play button** = normal PEAK. Nothing to remember.
- The PeakPack window has two big buttons, **Play Modded** and **Play normal PEAK**. It shows which mode the last launch from the app used, and states "Starting PEAK from Steam = normal PEAK".
  - The app can also tell whether a game start really loaded BepInEx: BepInEx rewrites `profile\BepInEx\LogOutput.log` on every modded start (helper `Launcher.LastModdedStartUtc` exists; not yet shown in the UI).
  - If the game-folder ini somehow says enabled, the window reports "Steam launch = WITH mods (unexpected)" and the next sync fixes it.

### 4.3 Remove everything

"Remove everything" (in the app, and in Windows' Installed Apps via `PeakPack.exe --uninstall`) does the following:

- Deletes `winhttp.dll` and `doorstop_config.ini` from the PEAK folder, **only if they still match the SHA-256 we recorded when writing them**. A file someone else replaced is reported, never blindly deleted.
- Deletes the profile, cache, state, shortcuts and registry entry. The running exe deletes itself after it exits.
- **Tested: the sandbox game folder's file list is identical before install and after uninstall.**
- If a friend already had a manual BepInEx install, setup asks first, then *moves* it to `%LOCALAPPDATA%\PeakPack-backups\â€¦` with a README. Uninstall never deletes that backup and tells the friend where it is.
- Steam "Verify integrity" restores changed game files but (per community consensus, Â§2) does not remove extra files like `winhttp.dll`. That's why uninstall must do it, and does.

### 4.4 Joshua's own PC

Joshua currently has BepInEx installed directly in `D:\SteamLibrary\steamapps\common\PEAK` with `enabled = true`, so Steam launches are modded. **It was not changed.** Moving to the same model later would mean:

- his Steam launches are vanilla too;
- he tests exactly what friends get.

Two catches must be addressed first:

1. Host-only mods (PEAK_Unlimited) aren't in the friend manifest, so he'd want a "host profile" mode that also installs `hostOnly`.
2. PeakPack's strict mode deletes unmanaged plugins, which would clobber dev builds of HeliPilot copied into the profile. A host/dev mode needs a "keep unmanaged plugins" switch, or a dev folder that is left alone.

Until then he can keep his manual install. If he runs the friend app on his own PC, it will detect his BepInEx install as "foreign" and ask before backing it up.

## 5. Architecture (as prototyped)

```
Joshua's PC                                   GitHub Releases (public repo)            Thunderstore
publish.json â”€â–º PeakPack.Cli publish â”€â–º out\  â”€â–º rev-N: manifest.json, .sig,           ccdn.thunderstore.io
   (scan can draft it from a plugins folder)      HeliPilot-<sha8>.dll, PeakPack-x.y.exe   (mod zips, pinned by SHA-256)
                                                            â”‚                                 â”‚
Friend's PC: "PEAK (Modded)" â”€â–º PeakPack.exe --launch â”€â”€â”€â”€â”€â”€â”´â”€â”€ HTTPS, host allowlist â”€â”€â”€â”€â”€â”€â”€â”€â”˜
   â”œâ”€ verify manifest signature (ECDSA P-256, public key baked into the exe)
   â”œâ”€ self-update if manifest.app is newer (hash-pinned)
   â”œâ”€ sync %LOCALAPPDATA%\PeakPack\profile\BepInEx to the manifest (download â†’ verify SHA-256 â†’ extract)
   â”œâ”€ write PEAK\winhttp.dll + PEAK\doorstop_config.ini (enabled=false)
   â””â”€ steam.exe -applaunch 3527290 --doorstop-enabled true --doorstop-target-assembly <profile>\BepInEx\core\BepInEx.Preloader.dll
```

### Manifest (`manifest.json`, schema 1, example in `examples/manifest.example.json`)

```jsonc
{
  "schema": 1, "packName": "Joshua's PEAK mods", "revision": 7, "published": "â€¦", "gameAppId": 3527290,
  "gameVersion": "2.6.b", "notes": "Added HeliPilot!", "modsRequiredToJoin": true,
  "app":    { "version": "0.2.0", "url": "PeakPack-0.2.0.exe", "sha256": "â€¦", "size": 51699433 },
  "loader": { "id": "BepInEx-BepInExPack_PEAK-5.4.75301", "url": "https://thunderstore.io/package/download/BepInEx/BepInExPack_PEAK/5.4.75301/", "sha256": "â€¦", "size": 670172 },
  "packages": [ { "id": "PEAKModding-PEAKLib_Core-1.7.2", "url": "https://thunderstore.io/package/download/â€¦", "sha256": "â€¦", "size": 118064,
                  "reason": "requested", "tags": ["All Clients"] }, â€¦ ],     // fully resolved and pinned (a lock file)
  "files": [ { "id": "Joshua-HeliPilot", "version": "0.1.0", "path": "plugins/Joshua-HeliPilot/HeliPilot.dll",
               "url": "https://github.com/<you>/peak-pack/releases/download/rev-7/Joshua-HeliPilot-a057a3d7-HeliPilot.dll",
               "sha256": "â€¦", "overwrite": "always" },                        // or "ifMissing" for default configs
             â€¦ ],
  "hostOnly": ["glarmer-PEAK_Unlimited"]                                      // informational, never installed
}
```

The manifest is pure data. **There is no field that can run a command or script.**

### Sync algorithm (`Installer.SyncAsync`), idempotent

The steps run in this order:

1. Refuse a game folder that isn't PEAK, or one with someone else's loader (unless the friend says yes â†’ back it up).
2. If the loader changed or is missing, extract the pack: `BepInEx/core` â†’ profile; `BepInEx.cfg` only if missing; proxy files â†’ `profile\loader\`.
3. Remove packages that are gone, have a changed version, or are missing files. Removal deletes their `<route>/<Namespace-Name>` folders.
4. Install missing packages using the Thunderstore layout rules. A package's `config/` files are written only if missing, so friend tweaks survive.
5. Write or update Joshua's files (`always` = enforce the hash; `ifMissing` = seed once). Delete files dropped from the manifest.
6. **Strict mode:** anything in `plugins/` or `patchers/` that the manifest doesn't own is deleted. That guarantees "exactly the host's set".
7. Write the two game-folder proxy files and save `state.json` (installed files, game-folder file hashes, revision, last launch).

Downloads are cached by SHA-256, so re-syncs and repairs don't re-download. Dependency resolution happens **at publish time**: every dependency string names a version, the highest required version wins, explicit pins win, and any `BepInExPack*` dependency becomes the PEAK pack. Friends just install the pinned list. That gives deterministic installs, everyone matches the host, and no Thunderstore API calls happen on friends' PCs.

## 6. Friend experience, step by step

**First time (about a minute):**

1. Joshua sends a link to `PeakPack.exe` (one file, ~49 MB, no .NET install needed).
2. The friend downloads and double-clicks it. Unsigned, it will show SmartScreen's "Windows protected your PC". The friend clicks **More info â†’ Run anyway** (Â§10; Joshua's message should say this).
3. A window: "Joshua's PEAK mods: this sets up Joshua's PEAK modsâ€¦ your normal PEAK stays exactly as it is" with one orange **Install** button. PEAK is found automatically (registry â†’ Steam `libraryfolders.vdf` â†’ `appmanifest_3527290.acf`). Only if that fails does it ask for the folder, and it validates that `PEAK.exe` is there.
4. Progress bar while it downloads BepInEx and the mods. Done: "All set! Use 'PEAK (Modded)' on your desktopâ€¦". Shortcuts are created on the desktop and in the Start Menu, plus an Installed Apps entry.
5. The window now shows **Play Modded**, **Play normal PEAK**, the mod list, "Check for updates", "Open mods folder" and "Remove everythingâ€¦".

**Every time after:** double-click **PEAK (Modded)**.

- Up to date: no window at all. It checks, then PEAK starts in about 0.5 s (measured in the sandbox).
- Joshua published an update: a small "Downloading HeliPilotâ€¦" window appears, then PEAK starts (about 2 s for a small update in the sandbox).
- PEAK is already running: "Close it first".
- Offline, or the update failed: a plain-English message with **Yes** = play with the mods you already have, **No** = play normal PEAK, **Cancel**.
- PEAK updated since Joshua's pack was made: the window notes the version mismatch and suggests normal PEAK until Joshua updates.

**Normal PEAK:** start it from Steam as always, or use "Play normal PEAK".

**Uninstall:** Installed Apps â†’ PeakPack â†’ Uninstall, or "Remove everythingâ€¦" in the window. The PEAK folder goes back to exactly vanilla.

## 7. Joshua's publish workflow, step by step

One-time setup:

1. Create a **public** GitHub repo, e.g. `peak-pack` (release assets in private repos need auth).
2. Create a signing key outside any repo: `PeakPack.Cli keygen --out C:\Users\joshu\PeakPack-keys\peakpack-signing.pem`. It prints the public key.
3. Put the manifest URL (`https://github.com/<you>/peak-pack/releases/latest/download/manifest.json`) and the public key into `src/PeakPack.App/pack.config.json`. Build: `dotnet publish src\PeakPack.App -c Release -o publish-out`. Share `publish-out\PeakPack.exe`. This is the only time an exe is handed out by hand; later app versions ship through self-update.
4. Draft `publish.json` from his own working install. `PeakPack.Cli scan --plugins D:\â€¦\PEAK\BepInEx\plugins` identifies each DLL's Thunderstore package and version **by SHA-256**. Mods tagged "Host Only" go into `hostOnly`, and unknown DLLs (HeliPilot) become `customFiles`.
   - Tested read-only on his real folder: it found AutoReload 1.0.2, InfiniteGlider 0.0.2 and InfiniteJetpack 1.0.1, put PEAK_Unlimited 4.0.1 into hostOnly, and listed HeliPilot as custom.

Every update (one command):

5. Edit `publish.json` (add or remove a mod, bump a pin, point at a new HeliPilot build).
6. `.\tools\publish-release.ps1 -Config publish.json -Repo <you>/peak-pack` does two things:
   - runs `publish`, which resolves dependencies, downloads and SHA-256-pins every zip, copies custom files with content-addressed names, signs, and prints a +/- diff against the last revision;
   - creates GitHub release `rev-N` marked latest, using `gh`.
7. Friends get the update the next time they double-click the shortcut. Optionally Joshua posts "pack rev N" in the group chat.

## 8. Hosting plan (free)

- **GitHub Releases on a public repo**, one release per revision (`rev-N`).
  - The manifest URL friends' apps use never changes: `â€¦/releases/latest/download/manifest.json`.
  - Inside the manifest, custom files use **immutable** per-revision URLs (`assetBaseUrl: â€¦/releases/download/rev-{revision}/`). A friend who fetched rev 7's manifest just as rev 8 went up still downloads rev 7's files, so hashes never race.
- Mods are always downloaded from **Thunderstore's own URLs**. We host only Joshua's files.
- Alternatives:
  - Cloudflare R2 (free tier, but needs a custom domain to avoid r2.dev rate limits).
  - GitHub Pages (fine for JSON; Releases are recommended for binaries).
  - `raw.githubusercontent.com` (5-minute cache) also works for the manifest.
  - The host allowlist would need the chosen host added.

## 9. Multiplayer: mismatches and vanilla friends

- PEAK uses Photon PUN. Matchmaking separates **game versions**, not mod sets. A vanilla friend *can* join a modded lobby.
  - Host-only mods (e.g. PEAK_Unlimited, tagged "Host Only") are fine.
  - Mods tagged "All Clients" (and most gameplay mods with RPCs or items, possibly HeliPilot) need everyone to run them. Otherwise expect desyncs or missing features.
- The publisher records each package's Thunderstore side tag and sets `modsRequiredToJoin`: true if any mod is "All Clients", or if any custom DLL is included. Joshua can override it in `publish.json`. The app then shows "To join Joshua's games, use Play Modded" next to the buttons.
- Everyone on the same pack revision is guaranteed by construction: the shortcut syncs before every launch, and the window shows "Pack revision N".
- **In-game check (optional next step):**
  - Add an existing verifier mod to the pack: `LengSword-BetterModVerifier` (host whitelist, exact-match mode, optional kick) or `Jaz-ModSync`. Both are "All Clients".
  - Or write a ~50-line plugin, "PeakPackBeacon", that publishes the pack revision as a Photon player property, so the host sees "Sam: no mods / old pack".
  - Either way, friends get it automatically because it's just another manifest entry.

## 10. Windows SmartScreen, antivirus and signing

- **Unsigned (free):** the first download shows browser and SmartScreen warnings ("not commonly downloaded", "Windows protected your PC â†’ More info â†’ Run anyway").
  - With a handful of friends, reputation never builds, and every new exe version resets it.
  - Mitigation built in: **only the first exe ever goes through a browser.** Self-updates are downloaded by PeakPack itself over HTTPS and hash-verified. Files written this way carry no Mark-of-the-Web, so updates don't re-trigger SmartScreen.
  - Windows 11 Smart App Control (if a friend has it on) can block unsigned apps outright.
- **Signing options:**

  | Option | Cost | Catch |
  |---|---|---|
  | Microsoft Artifact (Trusted) Signing | $9.99/mo | Joshua must be in the **US or Canada** as an individual; reputation is per publisher, so it builds faster |
  | Certum Open Source Code Signing | ~â‚¬69 + yearly | Requires an open-source project; reports on SmartScreen acceptance are mixed |
  | SignPath Foundation | Free | For OSI-licensed open-source projects built in public CI; manual approval per release |

  EV certificates no longer skip SmartScreen, so they aren't worth the premium.
- **Antivirus:** single-file or self-extracting .NET exes occasionally trip Defender heuristics (e.g. "Wacatac" false positives). If it happens, submit at microsoft.com/wdsi/filesubmission ("software developer").
- **Alternatives:**
  - A zip with `.bat`: same MOTW warnings, plus extraction steps.
  - `irm <url> | iex`: no SmartScreen prompt, but asks non-technical friends to paste a command that runs remote code. Not recommended.
- **Size:** the self-contained single-file WinForms exe is **49 MB** (WinForms can't be trimmed). If that matters:
  - framework-dependent would be ~1 MB, but friends would need the .NET Desktop Runtime (no);
  - a NativeAOT build with a raw Win32 or a small native-UI library could get to ~5â€“10 MB, for 1â€“2 days of extra work.

## 11. Security model

- **Trust root:** the manifest. It's fetched over HTTPS from the URL baked into the exe, and **ECDSA-signed** with Joshua's private key; the public key is baked into the exe.
  - A compromised GitHub account or a swapped file can't push a manifest friends will accept.
  - Signed manifests can't be rolled back to an older revision.
- **Every file is SHA-256-pinned** in the manifest and verified before use. Mismatches are rejected. Tested: tampered manifest, tampered hosted DLL.
- **Host allowlist with redirects checked hop by hop:** thunderstore.io and its CDNs, github.com and its asset hosts, raw/gist.githubusercontent.com. HTTPS only. Local files are allowed only with the test flag `--allow-local`.
- **No code execution from the manifest:** no scripts, no installers, no "run after download". Zip entries and manifest paths are normalized and confined (zip-slip protection). Manifest files can only land under `plugins/`, `patchers/` or `config/`.
- **No admin rights,** all per-user. The game folder gets only the two proxy files, and deletion is hash-checked.
- **Self-update** uses the same hash pinning, and only replaces the installed copy in `%LOCALAPPDATA%\PeakPack`.
- **Residual risks:**
  - A malicious Thunderstore mod version that Joshua chooses to include. Pinning means friends get exactly what he vetted, never a later upload.
  - Joshua's PC or private key being compromised. Keep the key outside the repo, maybe on a USB stick.

## 12. Game updates breaking mods

- PEAK updates arrive through Steam for everyone at once. BepInEx mods may break until their authors update.
- The friend can always play normal PEAK: the Steam button, or "No" in the failure prompt.
- The app notices `version.txt` differs from the pack's `gameVersion` and says so.
- Joshua's fix is a normal publish with updated versions (`scan` can also re-detect his updated install). The friend's next shortcut launch picks it up.
- Possible later: a manifest flag to block modded launch ("pack paused, PEAK updated"), set by Joshua with one publish.

## 13. Licensing

- PeakPack **never redistributes other authors' mods**. The manifest points at Thunderstore's download URLs, and each friend downloads directly from Thunderstore, the same as any mod manager does. Only hashes and version numbers are stored.
  - This matters because some PEAK mods are GPL-3.0 (PEAK_Unlimited), some MIT, and some have **no licence**, which means no redistribution right.
  - It also complies with Thunderstore's "don't re-upload others' packages" rule.
- Joshua's own DLLs (HeliPilot) are his to host.
- The BepInEx pack (BepInEx and Doorstop are both LGPL-licensed) is likewise downloaded from Thunderstore, not rehosted.

## 14. Mac, Steam Deck, Linux

- PEAK has **no Mac build**. Mac players use CrossOver, Whisky or GeForce NOW; out of scope.
- **Steam Deck / Linux (Proton):** PeakPack is a Windows app. Workable path: run PeakPack.exe once under Proton as a non-Steam game so it sets up a profile, then set PEAK's Steam launch option to `WINEDLLOVERRIDES="winhttp=n,b" %command% --doorstop-enabled true --doorstop-target-assembly Z:\â€¦\BepInEx.Preloader.dll`. That's fiddly.
  - Simpler for a Deck friend: Gale on Linux (native) with Profile Sync, or a later `--deck` mode that installs in-folder with `enabled = true`.
  - BepInEx docs require the `winhttp` DLL override under Proton.

## 15. Prototype status

**Works and tested (sandbox only; fake `PEAK.exe` that logs its arguments):**

- Publisher:
  - `scan` (identifies mods by hash; tested read-only against Joshua's real plugins folder; auto-detects Host Only);
  - `publish` (dependency resolution, e.g. PEAKLib_Core â†’ MonoDetour_BepInEx_5 â†’ MonoDetour, plus SoftDependencyFix; SHA-256 pinning; custom files; signing; +/- diff; revision bump);
  - `keygen`.
- Installer, via `tools/sandbox-test.ps1` (**39/39 checks pass**). Real Thunderstore downloads covering:
  - layout rules (plugins, patchers, core); idempotent re-sync;
  - update: add, remove, change; strict removal of unmanaged plugins; repair of deleted files; friend-edited configs preserved;
  - signature and hash tamper rejection; allowlist refusal;
  - modded and vanilla launch arguments; proxy repair after an r2modman/Gale-style overwrite;
  - foreign-loader backup and takeover; uninstall leaving the game folder byte-for-byte file-list identical.
- GUI:
  - `tools/gui-selftest.ps1` drives the real window: Install â†’ shortcuts created â†’ Play Modded â†’ Play normal, with screenshots.
  - `tools/shortcut-launch-test.ps1` runs the created desktop shortcut's exact command line, before and after a new publish. It confirmed the silent update and launch.
- Self-update: v0.1.0 â†’ v0.2.0 via the manifest `app` entry; restarted and launched.

**Not done / not tested:**

- Never run against the real game or real Steam. Still to check:
  - Steam's behaviour with `-applaunch` args (dialog or not; argument quoting with spaces in the profile path);
  - that BepInEx really loads from the profile folder in PEAK (expected, per source and r2modman/Gale practice).
- Uninstall's interactive confirmation dialogs and the real desktop, Start Menu and registry writes were not exercised; tests use `--shortcut-dir`.
- No in-game mismatch beacon; no host/dev mode; no `--deck` mode; no code signing; the exe has no custom icon.
- GUI polish: no "what's new" list. Error texts are plain but could be friendlier. The app is not localized.
- No automated unit tests beyond the scripts. `Resolver` edge cases (dependency cycles, missing deps) only produce warnings.

## 16. Decisions for Joshua

1. **Hosting:** GitHub Releases on a public repo (recommended, free)? What account and repo name?
2. **Code signing:**
   - Stay unsigned and tell friends "More info â†’ Run anyway" once (free; self-updates avoid repeat prompts)?
   - Or pay $9.99/mo for Artifact Signing (only if he's in the US or Canada)?
   - Or make PeakPack open-source to qualify for SignPath or Certum?
3. **Manifest signing:** on (recommended) and where to keep the private key.
4. **Strictness:** delete anything friends add to plugins (exact match, recommended), or allow extras?
5. **Dependency policy:** highest-required versions (default, matches r2modman) or always-latest dependencies?
6. **Who's in the pack:** confirm the client mods (AutoReload, InfiniteJetpack, InfiniteGlider, HeliPilot?) vs host-only (PEAK_Unlimited). Is HeliPilot "everyone needs it"?
7. **Naming and branding:** app name ("PeakPack"), shortcut name ("PEAK (Modded)"), pack name and icon.
8. **His own machine:** keep the manual install, or move to the clean-folder model later (needs a host/dev mode, Â§4.4)?
9. **Exe size:** accept 49 MB, or invest in a NativeAOT build later?
10. **Lobby check:** add BetterModVerifier or ModSync to the pack, or have a small PeakPackBeacon plugin written?
11. **Steam Deck/Linux friends:** are there any? That decides whether a `--deck` mode is needed.
