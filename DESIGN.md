# PeakPack: one-click PEAK mods for friends

*Design doc, v0.3, 11 Oct 2026. Code: `C:\Users\joshu\PeakMods\FriendInstaller` (see README.md). v0.2 decisions stand unless a section says otherwise.*

## 1. Recommendation in one paragraph

A small, self-contained Windows app (**PeakPack.exe**) that:

- reads a hash-pinned, **signed manifest** that Joshua publishes on **GitHub Releases** (`jmproulx/peakpack`);
- downloads the listed mods **straight from Thunderstore** (no re-hosting), plus Joshua's own DLLs from his release;
- keeps BepInEx and all mods in its **own folder** (`%LOCALAPPDATA%\PeakPack\profile`), not in the game;
- puts only Doorstop's `winhttp.dll` and a `doorstop_config.ini` with `enabled = false` in the PEAK folder;
- starts modded PEAK through Steam with per-launch Doorstop arguments (**verified on Joshua's real PC, §2.1**);
- ships a tiny in-game **companion plugin** in every pack: lobby revision check + host-controlled live settings (§9).

For the friend:

- **First open** of the downloaded exe installs the app and puts a **"PEAK (Modded)"** icon on the desktop (§6).
- That icon checks for updates, syncs, and starts PEAK with mods in one double-click. **Steam's Play button is always normal PEAK.**
- "Remove PeakPack" returns the game folder to exactly what Steam installed.

For Joshua: keep developing in his own game folder with AutoReload as today; publish with the **Host window** (`PeakPack.exe --host`) or by asking an agent to run the **CLI** (§7).

## 2. Verified facts this design rests on

| Fact | Source |
|---|---|
| PEAK is Steam app **3527290**; Windows only; no Workshop; no official mod support | Steam appdetails; `appmanifest_3527290.acf` |
| `BepInEx-BepInExPack_PEAK` 5.4.75301 (BepInEx 5.4.23.3) ships a PEAK fork of Doorstop 4.4.1. Joshua's own game folder has generic Doorstop **4.4.0** | Inspected the zip; `.doorstop_version` in his folder |
| Doorstop 4 load order (Windows): defaults (`enabled = FALSE`) → `doorstop_config.ini` → **command line** → `DOORSTOP_DISABLE`. Arguments are split with `CommandLineToArgvW`; the value after `--doorstop-target-assembly` is taken whole and **replaces** the ini's value (`load_str_argv` frees the old one). Relative paths resolve against the game folder. `src/windows/config.c` etc. are byte-identical in 4.4.0 and 4.4.1 | NeighTools/UnityDoorstop v4.4.0 `src/windows/config.c` `load_config()`, `init_cmd_args()`, `load_str_argv()`; `src/windows/entrypoint.c` `fix_cwd()` |
| BepInEx 5 root = two levels above the preloader: `Utility.ParentDirectory(DOORSTOP_INVOKE_DLL_PATH, 2)`. Game root comes from the process path | BepInEx v5-lts `BepInEx.Preloader/Entrypoint.cs`, `BepInEx/Paths.cs` |
| r2modman and Gale launch Doorstop-4 games on Windows with `steam.exe -applaunch <id> --doorstop-enabled true --doorstop-target-assembly <profile preloader>` | r2modmanPlus `SteamGameRunner_Windows.ts`, `BepInExGameInstructions.ts`; Gale `profile/launch/platform.rs` |
| Thunderstore install rules; download URLs 302 to `ccdn.thunderstore.io`; no hashes in the API (we pin our own SHA-256); versions immutable; no private packages; no re-uploading others' packages | Thunderstore schema, OpenAPI, wiki |
| GitHub Releases: assets < 2 GiB; `…/releases/latest/download/<asset>` redirects to the latest release's asset | docs.github.com |
| PEAK uses PUN **2.49**; sets player properties `UserID`, `PlatformFamily`, `ProductUserID` and room property `csid`. Its "X joined the expedition." feed is `PlayerConnectionLog` (TMP text, `joinedColor`/`leftColor`/`userColor`, `sfxJoin`/`sfxLeave`, 8 s per line) | `_decompiled` PhotonUnityNetworking `PhotonNetwork.PunVersion`; `NetworkingUtilities.cs`, `Player.cs`, `NetworkConnector.cs`, `PlayerConnectionLog.cs` |

### 2.1 Real-PC test (11 Oct 2026, Joshua's PC, `tools/real-pc-test.ps1`, report in `docs/real-pc-test-2026-10-11.txt`)

Non-destructive: Joshua's game folder already has Doorstop with `enabled = true` targeting his own BepInEx; the test only *overrides* the target on the command line, with a profile under `sandbox\real-pc-test\PeakPack Test Data\` (path with spaces) holding BepInExPack_PEAK's core and a test plugin that logs and quits.

| Check | Result |
|---|---|
| `steam.exe -applaunch 3527290 --doorstop-enabled true --doorstop-target-assembly "<profile with spaces>\BepInEx\core\BepInEx.Preloader.dll"` (exactly what PeakPack runs) | PEAK started in 2.8 s; **BepInEx 5.4.23.3 loaded from the test profile** (`BepInExRootPath = …\PeakPack Test Data\profile\BepInEx`, `GameRootPath = D:\SteamLibrary\steamapps\common\PEAK`); test plugin ran |
| Path with spaces | Arrived in PEAK as **one** argument |
| Joshua's own BepInEx | **Not** loaded (his `LogOutput.log` unchanged) |
| Steam confirmation dialog for custom args | **None.** The script saw no new Steam window in any phase, and Joshua saw no dialog. (Steam users have reported an "attempting to launch with optional parameters" prompt since 2024; it did not appear for `-applaunch` from a program on this PC. Re-check if a friend reports one.) |
| `-applaunch … --doorstop-enabled false` | Plain PEAK, even with his ini at `enabled = true` |
| Game folder before/after | Identical (309 files, path + size + timestamp) |
| Fallback: PEAK.exe started directly with `SteamAppId` set | Inconclusive (BepInEx started, plugin did not run). Not needed, since Steam doesn't prompt; the script's measurement for this phase was fixed afterwards |

Still unverified: whether Steam's "Verify integrity" removes extra files (we don't depend on it; uninstall removes ours).

## 3. Options compared (unchanged from v0.2)

Every existing friend-sync option (Thunderstore modpacks, r2modman profile codes, Gale Profile Sync) requires each friend to install a mod manager. A small custom app is the only way to meet "no mod manager". Gale Profile Sync remains the best off-the-shelf alternative.

## 4. Modded vs normal PEAK

Clean game folder + per-launch arguments (the r2modman/Gale model), now verified on the real PC (§2.1):

- the game folder has only `winhttp.dll` and an ini with `enabled = false`, so **Steam's Play button = normal PEAK**;
- "PEAK (Modded)" passes `--doorstop-enabled true --doorstop-target-assembly <profile>\BepInEx\core\BepInEx.Preloader.dll`;
- PeakPack rewrites the two proxy files before each modded launch (undoes r2modman/Gale overwriting them);
- "Play normal PEAK" passes `--doorstop-enabled false`.

**Joshua's own PC** keeps his manual install (BepInEx in the game folder, `enabled = true`, AutoReload, dev builds). PeakPack never syncs his game folder. The Host window's **"Play as a friend"** uses the same override trick verified in §2.1: it syncs the friend manifest into `%LOCALAPPDATA%\PeakPack-host\friend-view` (with `ManageGameFolder = false`) and launches with `--doorstop-target-assembly` pointing there. His folder is never written. Sync options for host/dev profiles: `Strict = false` keeps extra plugins (`--keep-extra`); `ManageGameFolder = false` never touches the game folder (`--no-game-folder`).

## 5. Architecture

```
Joshua's PC                                         GitHub Releases (jmproulx/peakpack)          Thunderstore
publish.json ─► PublishPipeline (CLI or Host window)   rev-N: manifest.json(.sig), JetpackBoost-<sha8>.dll,   ccdn.thunderstore.io
                 prepare: previous = live manifest      PeakPack.Companion-<sha8>.dll, PeakPack-0.3.0.exe,     (mod zips, pinned by SHA-256)
                 release: gh release create rev-N       PeakPack.exe (stable name for the share link)
                 stamp:   companion + pack-info → his own BepInEx
Friend's PC: "PEAK (Modded)" ─► PeakPack.exe --launch ── HTTPS, host allowlist ──────────────────────────────┘
   verify signature → self-update if newer → sync profile → pack-info.json → write proxy → steam -applaunch … (args)
In game: PeakPack.Companion reads <profile>\BepInEx\PeakPack\pack-info.json → Photon properties → lobby check / live settings
```

### Manifest (schema 1; v0.3 fields are optional, so v0.2 apps still read new manifests)

v0.2 fields plus: `hostName`, `packId` (stable slug for the lobby check), `changelog[]` (last 20, newest first), `lobby { mismatchPolicy: warn|block, liveSettings[{plugin, section, key}] }`, and per package/file `title` + `description` (friendly name and one line "what it does", from `modInfo` in publish.json or Thunderstore's own description). The manifest is still pure data: **no field can run a command or script**.

v0.6 adds three more optional, signed fields (details and rules in §18.9). Schema stays 1: every app so far, including the shipped Windows PeakPack 0.4.2, skips unknown members, and `tools/pins-compat-test.ps1` proves it with the rev-5 exe itself.

| Field | Shape | Filled by the publisher from | Used by |
|---|---|---|---|
| `platforms.mac.runtime` | `{ id, tag, asset, sha256, size }` | publish.json `mac.runtime.tag` → that `mac-build-runtime-*` prerelease's `SHA256SUMS` + asset size | Mac front end (runtime pin; falls back to its embedded pin) |
| `platforms.mac.frontEnd` | `{ version, tag, zip, sha256 }` | publish.json `mac.frontEnd.tag` → that `mac-build-app-*` prerelease's `SHA256SUMS` | Mac front end (self-update pin) |
| `gameDepot` (top level) | `{ appId, depotId, manifestId, buildId }` (ids as decimal strings) | publish.json `gameDepot: "auto"` → `<gameDir>\..\..\appmanifest_<appid>.acf` (read-only; left out if unreadable) | Mac front end ("PEAK has an update") |

Windows PeakPack never acts on them, and friends' `Validate()` deliberately doesn't check them (a bad Mac pin must never stop a Windows sync). The publisher checks them (`ValidateForPublish`) and refuses to publish on any problem.

### Sync (`Installer.SyncAsync`), idempotent

As v0.2, plus: honours `SyncOptions(Strict, ManageGameFolder, ShortcutName)`; writes `profile\BepInEx\PeakPack\pack-info.json` (pack id, revision, host name, shortcut name, lobby policy, live-setting whitelist) and `installed-manifest.json` (so the next check can say exactly what changed: `PackDiff`).

## 6. Friend experience

**First time:**

1. Joshua sends `https://github.com/jmproulx/peakpack/releases/latest/download/PeakPack.exe` (one ~50 MB file, nothing else to install).
2. Browser warning, then SmartScreen, once (§10 has exactly what to click).
3. **First open installs the app**: it writes itself to `%LOCALAPPDATA%\PeakPack\PeakPack.exe`, creates **Desktop "PEAK (Modded)"** (PEAK.exe's icon), **Start Menu → PeakPack → "PEAK (Modded)" and "PeakPack"** (the app window), and an Installed Apps entry, then restarts from the installed copy. The downloaded file is never needed again. (A desktop "PeakPack" icon is optional, `desktopAppShortcut`, off by default: one icon on the desktop keeps it obvious.)
4. Welcome page: status "Not installed yet: click Install to download 2 mods (about 1 MB)", what will happen in three bullets, and **what's in the pack and why** (friendly names + one-line descriptions, helpers collapsed). One **Install** button.
5. Done page: **"All set. Your desktop now has a "PEAK (Modded)" icon"** with a picture of that icon, and **Play now / Close**.

**Every time after:** double-click **PEAK (Modded)**.

- Up to date: no window; PEAK starts in about half a second.
- Update published: a small progress window, then PEAK starts.
- Offline or failed: a native task dialog: "Play with the mods I have" / "Play normal PEAK" / Cancel, with details.

**Opening the PeakPack window later** shows one status line in the style of Windows Update:

| Status | When |
|---|---|
| **Ready to play** (green) | up to date: "You have Joshua's mods, pack revision 7, checked just now." |
| **Update available: 2 mods changed** (amber) | "Added Infinite Glider · Updated Jetpack Boost (new build). Play with mods updates automatically, or click Update now." |
| **Not installed yet** (blue) | first run |
| **Something went wrong** (red) | plain heading (e.g. "Can't reach the internet") + what to do + "Copy details" for Joshua |
| PEAK is running / PEAK has updated since this pack was made / Steam would start PEAK with mods | the special cases, each with one sentence of advice |

The two main actions are native command links: **Play with mods** ("Same as the PEAK (Modded) icon on your desktop") and **Play normal PEAK** ("No mods. Same as pressing Play in Steam."). One muted line restates the rule: mods only load from PeakPack; Steam = normal PEAK; to join Joshua's games, play with mods.

**Look:** classic Windows installer layout (white header with title and app icon, a thin PEAK-orange line under it, system face colour, Segoe UI, standard buttons right-aligned in a bottom bar, native command links, ListView with groups, TaskDialogs). No gradients, emoji or oversized cards. The app icon is original (navy badge, two-tone mountain with snow cap, orange pack crate; `tools/make-icon.ps1`); the desktop "PEAK (Modded)" shortcut uses PEAK.exe's own icon.

**DPI:** all sizes are in 96-DPI units multiplied by the scale (`DeviceDpi/96`, or `--ui-scale` for screenshots); fonts are created in pixels; `AutoScaleMode.None`, rebuilt on `DpiChanged`. Screenshots at 100/125/150 % in `docs/screenshots/after/`.

## 7. Joshua's workflow (recommended)

**Normal week:**

1. Develop in his own game folder exactly as now (`dotnet build -p:Deploy=true`, AutoReload hot-reloads his DLL). PeakPack never touches that folder.
2. When a build is worth sharing: open **PeakPack Host** (`PeakPack.exe --host`), check "What friends will get" (+/- list in plain words), type one changelog line, **Publish**. Optionally **Play as a friend** first to test exactly the friend set.
3. Friends get it the next time they start PEAK (Modded). Their in-game lobby check tells them if they're behind.

**Or by talking to an agent** (everything is headless):

```powershell
$cli = "C:\Users\joshu\PeakMods\FriendInstaller\src\PeakPack.Cli\bin\Debug\net10.0-windows\PeakPack.Cli.exe"
$cfg = "$env:LOCALAPPDATA\PeakPack-publisher\publish.json"
& $cli prepare --config $cfg                         # build rev N+1 into staging, print what friends will get
& $cli release --config $cfg --notes "Glider added" --dry-run    # print the exact gh command
& $cli release --config $cfg --notes "Glider added" --stamp "D:\SteamLibrary\steamapps\common\PEAK\BepInEx"
```

Recommendation: use the **Host window** for routine publishes (the diff preview and the confirmation make mistakes unlikely); use an agent when he wants something done for him ("add InfiniteGlider, pin it, publish"). Both edit the same `publish.json` and run the same pipeline. A management UI isn't strictly needed, but it's the safer default because it shows exactly what friends will get before anything goes out.

**One-time setup (done in v0.3 prep):** signing key `C:\Users\joshu\PeakPack-keys\peakpack-signing.pem` (outside any repo; public key baked into `pack.config.json`); manifest URL `https://github.com/jmproulx/peakpack/releases/latest/download/manifest.json`; `publish.json` at `%LOCALAPPDATA%\PeakPack-publisher\publish.json` (copy of `examples/first-pack.publish.json`). **Not done (by design): creating the repo, pushing, publishing.**

**The pipeline in detail** (`PublishPipeline`, shared by CLI and Host window):

1. *Previous revision* = the live manifest at the manifest URL (what friends really have); a 404 means first publish; else the last local release in `<work>\current`. Network errors stop the publish rather than guess a revision.
2. *Prepare* into `<work>\staging`: resolve and pin, copy own DLLs with content-addressed names, include the companion, sign, add the stable `PeakPack.exe`, check problems (unsigned, no repo, no app exe, asset URLs not matching the release).
3. *Release*: `gh release create rev-N <assets> --repo jmproulx/peakpack --title … --notes <changelog + plain change list> --latest`. Only after success is staging copied to `<work>\current` and `<work>\history\rev-N`.
4. *Stamp* (optional): companion + `pack-info.json` into his own `BepInEx`, so his game announces revision N in lobbies.

Every release carries `PeakPack.exe`, so the share link never breaks. **Never create a non-pack release marked "latest"** in this repo: `latest/download/manifest.json` must always resolve to a pack release.

## 8. Hosting plan

GitHub Releases on the public repo `jmproulx/peakpack` (app source included), one release per revision (`rev-N`). The manifest URL never changes; custom files use immutable per-revision URLs (`…/releases/download/rev-N/…`), so a friend who fetched rev 7 while rev 8 went up still gets rev 7's files. Mods always come from Thunderstore.

## 9. Multiplayer: lobby check, live settings, and "can it stream updates?"

### 9.1 What Joshua actually gets

| Ask | Verdict | What happens |
|---|---|---|
| (a) Code and mod changes reach friends | **Yes, at next launch** | The PEAK (Modded) icon syncs before every start. Publishing takes seconds; friends just restart PEAK from the icon. |
| (b) Know when someone is behind | **Yes, implemented** (companion) | In the lobby, a line in PEAK's own feed: *"Joshua's expedition uses mod pack rev 7. You have rev 6. Restart PEAK from the PEAK (Modded) icon to update."* The host sees *"Sam has mod pack rev 6. Yours is rev 7."* or *"Sam joined without the mod pack."* (the latter only if the pack says mods are required). Optional `mismatchPolicy: block` makes an outdated player leave after 10 s. |
| (c) Live settings from host to friends | **Yes, implemented** (companion) | BepInEx config values whitelisted in the signed pack (e.g. JetpackBoost `ThrustMultiplier`, `ForwardPush`) follow the lobby host's values within about a second, including when he tunes them in game with his hotkeys. Friends get *"Using Joshua's settings for JetpackBoost."* Their own values come back when they leave; their config file is never left with the host's values. |
| Live **code** updates into friends' running games (AutoReload-style) | **Not recommended; not built** | See 9.3. |

### 9.2 How the companion works (`src/PeakPack.Companion`, ~300 lines, BepInEx 5, netstandard2.1, embedded PDB)

- Reads `<BepInEx root>\PeakPack\pack-info.json` (written by every sync; for the host by `stamp`). No file → does nothing.
- Every player sets Photon **player** properties `pp.pack`, `pp.rev`. The lobby host (Photon master client) also sets **room** properties `pp.pack`, `pp.rev`, `pp.cfg` (live-setting values). Keys are prefixed to avoid PEAK's own (`UserID`, `PlatformFamily`, `ProductUserID`, `csid`).
- Joiners are checked once their character exists (OnJoinedRoom is too early: they're still loading). The host checks each joiner 12 s after they enter (time for their properties to arrive), and reports each thing once per lobby.
- Notices are **PEAK's own UI**: lines added to `PlayerConnectionLog` (the "X joined the expedition." feed) with the game's TMP text, its `leftColor`/`joinedColor`, player names in `userColor`, the game's join/leave sounds, and its 8-second fade. Wording follows the feed's short, plain tone. No IMGUI, no custom boxes. If a game update renames the private `AddMessage`, notices fall back to the log only.
- Live settings: only keys in **this player's own signed pack** are applied, parsed as the entry's type and clamped to its allowed range. While the host's values are active, that mod's config file doesn't auto-save, and the player's own values are remembered in `BepInEx\PeakPack\live-originals.txt`. They're restored (and saved) on leaving, on becoming host, on unload, and on the next start after a crash in a lobby. (A mod that calls `Config.Save()` itself while in the lobby could still write the host's values; the next restore puts the player's back.)
- **Reload-safe:** no Harmony patches, no static game state; `OnDestroy` unregisters the Photon callbacks and restores settings; the originals file also covers AutoReload starting the new instance before the old one is destroyed. Builds with an embedded PDB for AutoReload.
- Reviewed against the decompiled PUN 2.49 / PEAK / BepInEx APIs (all names and signatures confirmed); six issues found in review were fixed (repeat warnings on setting changes, block timer not cancelled, late properties not re-checked, log-source leak, feed retry loop, host values reaching disk via another save).
- Limitation: Photon lets any player in a room set room properties, so a modified client could push different values *for whitelisted keys only*, within their allowed ranges. Fine among friends; documented.
- Logic is unit-tested without Unity (`tools/LobbyCheckTests`, 38 checks). In-game behaviour still needs a real two-player session to confirm (not testable in the sandbox).

### 9.3 Streaming code into running games

v0.3 recommended against it as a default, and that still holds. v0.4 adds it as an **opt-in test lobby for Joshua's own reload-safe mods only** (section 17), because live playtesting with friends needs it. The concerns below are why it is off by default and fenced in.

- **Mods must support unloading.** Most Thunderstore mods don't clean up Harmony patches, spawned objects or event handlers. Only Joshua's own mods marked reload-safe qualify, and the hotfix tool checks each build for `OnDestroy` and an embedded PDB.
- **Mid-match desync.** Players briefly run different code in the same run.
- **Security.** A running game must never accept code from the network. In v0.4 the lobby event carries only a revision number. The friend's own PeakPack app fetches the manifest from its built-in URL and verifies the signature with its built-in key.
- **Restarting is still the tested path.** Everything that isn't reload-safe falls back to "restart from the PEAK (Modded) icon".

## 10. Unsigned exe: exactly what happens

Sources: Microsoft Learn (SmartScreen reputation, Smart App Control), Google Chrome help (download warnings), Eric Lawrence's MOTW/SmartScreen write-ups; plus our own test of the Mark-of-the-Web mechanics (`tools/v3-test.ps1`). Exact browser wording changes over time.

| Moment | What the friend sees | Why |
|---|---|---|
| Downloading `PeakPack.exe` in **Edge** | "PeakPack.exe isn't commonly downloaded. Make sure you trust PeakPack.exe before you open it." → click **…** → **Keep** → **Show more** → **Keep anyway** | Edge SmartScreen: new unsigned file with no reputation |
| Downloading in **Chrome** | "Suspicious download blocked" (or "uncommon download") → **Download suspicious file**; on the full-page variant pick **"I'm willing to accept the risk"** (or "I trust the site") → **Download** | Safe Browsing: uncommon executable |
| First double-click of the downloaded file | **"Windows protected your PC"** → **More info** → **Run anyway** | Windows SmartScreen checks files with Mark-of-the-Web (ZoneId 3) launched from Explorer; unsigned + new = no reputation. Every new exe version starts at zero again |
| PeakPack installs itself | Nothing | The app writes its bytes to `%LOCALAPPDATA%\PeakPack\PeakPack.exe` as a **new file**, like any installer writes its payload. Tested: `File.Copy` (v0.2) carried the Mark-of-the-Web over; the v0.3 byte copy does not |
| Every later launch (desktop icon, Start Menu) | **Nothing** | The installed copy has no Mark-of-the-Web, so SmartScreen doesn't check it |
| Self-updates | **Nothing** | Downloaded by PeakPack itself (HttpClient, no MOTW), hash-pinned in the signed manifest |
| Opening the downloaded file again | SmartScreen may ask again (behaviour differs between Windows versions) | It still carries MOTW. Tell friends they can delete it after setup |
| **Windows 11 Smart App Control** on (clean installs only, after its evaluation period) | **Blocked, no "Run anyway"** | SAC requires a signature or cloud reputation, regardless of MOTW. The only fixes are turning SAC off (Windows Security → App & browser control) or signing |
| Antivirus | Usually nothing; occasionally a machine-learning false positive (e.g. `Trojan:Win32/Wacatac.B!ml`) on unsigned single-file .NET apps | Heuristics. Self-copy to AppData and rename-on-update look installer-like. If it happens, submit at microsoft.com/wdsi/filesubmission ("Software developer", "Incorrectly detected"); the limit is 50 MB, so submit the exe itself |

**Message for friends** (put next to the link):

> 1. Download PeakPack.exe. If the browser warns, keep it (Edge: … → Keep → Show more → Keep anyway; Chrome: Download suspicious file).
> 2. Open it. If Windows says "Windows protected your PC", click **More info → Run anyway**. That's the only time.
> 3. Click **Install**. You'll get a **PEAK (Modded)** icon on your desktop: use it whenever you play with me. Steam's Play button is still normal PEAK.

Signing options are unchanged from v0.2: Microsoft Artifact (Trusted) Signing ($9.99/mo; individuals in the US or Canada only), Certum Open Source (~€69 + yearly), SignPath Foundation (free for OSI open source built in public CI). With the repo public including source, SignPath is now a realistic free option. EV certificates no longer skip SmartScreen.

## 11. Security model

As v0.2 (signed manifest, SHA-256 pinning, HTTPS host allowlist with per-hop redirect checks, zip-slip protection, no code execution from the manifest, no admin rights, hash-checked game-folder deletion), plus:

- **Real signing key** created outside the repo (`C:\Users\joshu\PeakPack-keys\peakpack-signing.pem`, gitignored pattern `*.pem`); public key baked into `pack.config.json`. Back it up (USB stick). Losing it means a new app build for everyone.
- The pipeline **refuses a real release that isn't signed**.
- **Verification (0.4.3):** on Windows, .NET's ECDsa (CNG). Under Wine, a managed P-256 verifier with the same strictness, because Wine's ncrypt.dll can't be relied on (§18.10).
- The companion accepts network values only for whitelisted, typed, range-clamped settings from the signed pack, and never writes them to disk.
- `pack-info.json` and the companion only read local files and Photon properties. No downloads, no code loading.

## 12. Game updates breaking mods

The app compares PEAK's `version.txt` with the pack's `gameVersion` and says so in the status line ("PEAK has updated since this pack was made…"). Friends can always play normal PEAK. Joshua's fix is a normal publish.

## 13. Licensing

PeakPack never redistributes other authors' mods: friends download from Thunderstore's own URLs. Joshua hosts only his own DLLs, the companion, and the app. BepInEx/Doorstop (LGPL) also come from Thunderstore.

## 14. Platforms

Out of scope by Joshua's decision (11 Oct 2026): all friends are on Windows with Steam. No Mac, Steam Deck or Linux support is planned.

## 15. Status (v0.3; v0.4 in section 17)

**Works and tested:**

- Real PC: launch method verified (§2.1).
- `tools/sandbox-test.ps1`: the 38 v0.2 end-to-end checks.
- `tools/v3-test.ps1`: friendly manifest fields, changelog, companion inclusion, pack-info, update check with plain-language changes, `--keep-extra` / `--no-game-folder`, self-install without Mark-of-the-Web and correct shortcuts, pipeline dry run (exact gh command, stable PeakPack.exe, refusal without signature), host stamp, LobbyCheck unit tests.
- `tools/gui-selftest.ps1 -Published`: drives the real window at 100/125/150 % (welcome, done, ready, update available, error), checks shortcuts → installed copy, no MOTW, launch arguments.
- `tools/host-selftest.ps1`: Host window at 100/125/150 % with a dry-run publish.

**Not done / not tested:**

- The companion in a real multiplayer lobby (needs two players). The sandbox can't run Unity/Photon.
- Uninstall's real desktop/registry writes are still only exercised with test overrides.
- Not code-signed. Smart App Control blocks it on PCs where SAC is on.
- No localization (English only).

## 16. Decisions for Joshua

1. **Publish v0.3 + the first pack** to `jmproulx/peakpack` (main session runs it with him; commands in README).
2. **Back up the signing key** somewhere safe.
3. **Lobby policy:** `warn` (default) or `block` outdated players?
4. **Live settings:** JetpackBoost's thrust and forward push follow the host. Add more keys?
5. **modsRequiredToJoin:** set to false for the first pack (both mods are client-side; vanilla friends can join). Turn on when a mod needs everyone.
6. **Signing later?** SignPath (free, public repo) is worth trying once the pack is in regular use.
7. **Test lobby (v0.4):** turn it on for playtest sessions, and mark which of his mods are reload-safe (ScoutmasterMode, HeliPilot, JetpackBoost, ElytraGlider all have OnDestroy + embedded PDB builds? the hotfix tool checks each build). Keep it off for normal play.
8. **Log sharing default:** on (explained in the installer), as requested. Friends can turn it off at any time.
9. **Host id:** host one lobby with the v0.4 companion installed (it writes `host-id.txt`), then publish, so friends only relay to him.

## 17. Testing with friends (v0.4): remote logs, live updates, hotfixes

Goal: Joshua playtests his own mods (ScoutmasterMode, HeliPilot v2, JetpackBoost, ElytraGlider) with friends. When a friend says "I can't see the helicopter", Joshua or an agent can read the friend's logs, push a fix, and have it load in the friend's running game.

### 17.1 Remote diagnostics (opt-in, on by default, explained)

- **Consent:** the installer's welcome page has a plain checkbox, on by default: *"Share PEAK error logs with Joshua while I'm in his lobby"*. The note under it says what is shared, with whom, and how to turn it off. The same switch is on the main window and takes effect immediately (the companion re-reads `pack-info.json` every 2 s). Joshua can also turn the feature off for the whole pack (`lobby.diagnostics`).
- **What is sent:**
  - every log line from Joshua's own mods and PeakPack;
  - errors and exceptions from any mod, taken from BepInEx;
  - errors and exceptions from Unity's own log (`Application.logMessageReceivedThreaded`, because Unity errors don't reach LogOutput.log here);
  - errors from the end of `Player.log` (`Application.consoleLogPath`, opened shared, last 256 KB);
  - a header with the pack id and revision, PEAK, Unity and BepInEx versions, and the full mod list with versions.
- **Scrubbing:** the Windows profile path, user name and PC name are replaced by `%USERPROFILE%`, `<user>` and `<pc>` before anything leaves the PC.
- **Who receives it:** only the lobby host (Photon master client), and only if the room's pack id matches the friend's signed pack AND the master's Photon user id is in `lobby.hostIds` from the signed manifest.
  - The host's companion records its own id in `BepInEx\PeakPack\host-id.txt`, and the publisher puts it into the next manifest automatically.
  - Until that has happened once, **nothing is relayed** (the publisher prints a note). So the first release has log sharing effectively off until Joshua hosts once with the v0.4 companion and publishes again.
  - Limit: Photon user ids are claimed by the client, not authenticated, so a deliberately modded client could impersonate Joshua's id. The worst it gets is a scrubbed error log and mod list. It can never push code, because live updates are verified against the signed manifest.
  - The host only accepts logs from players whose companion runs the same pack. It also caps 400K characters per sender and 1.2M in total per minute, and stops writing at 50 MB in the folder.
- **Transport:**
  - Photon event 172, targeted to the master only, as 3,000-character chunks.
  - Rate-limited to about 8 KB/s per friend, with a bounded queue (60 chunks) and 60 KB per snapshot.
  - The host drops anything over 400K characters per sender per minute and rotates files at 2 MB.
  - Event codes 171-173 carry a "PPK1" tag; PEAK itself uses 1-4 and 18, Photon 200+.
- **When:**
  - a snapshot when the friend's character first appears in the host's lobby, then new relevant lines as they happen;
  - a fresh snapshot whenever the host asks: **Ctrl+F9** in game, "Request logs from everyone" in the Host window, or `PeakPack.Cli lobby snapshot`.
  - Friends see a native notice either way: *"Joshua asked for your PEAK logs to fix a mod. Sending them now."* or *"... Sharing is off in PeakPack."*
- **On Joshua's PC:** `D:\SteamLibrary\steamapps\common\PEAK\BepInEx\PeakPack-remote-logs\<friend>.log`, plus `_lobby.txt` (who sent what, pack revision, file). This is plain text for an agent to read.
- **Limits:** a lobby member could send junk under their own name, so a prankster could fill a log file, but only bounded and only under `PeakPack-remote-logs` with a sanitized file name. Nothing received is ever executed.

### 17.2 Live updates of Joshua's own mods (opt-in "test lobby", default off)

- **Two switches, both needed:**
  - Joshua turns on **"Test lobby: live updates for my mods"** (`lobby.testLobby`) and marks his builds **reload-safe** (`customFiles[].reloadSafe`). The publisher then adds Hamunii AutoReload to the friends' pack.
  - Each friend ticks **"Test lobby: let Joshua update his own mods while I play"** (off by default).
- **Flow:**
  1. Joshua publishes a hotfix, a normal signed pack release (17.3).
  2. His companion sends event 173 *"revision N"*.
  3. A friend's companion checks that the sender is the verified host and that N is newer than its own revision. It then starts the friend's own installed `PeakPack.exe --hot-update`, after checking that the exe sits next to the profile.
  4. The app does everything security-relevant with the same tested Core code as normal syncs:
     - manifest from its built-in URL;
     - ECDSA signature checked with the built-in key (an unsigned manifest is never applied);
     - allowlisted hosts and SHA-256 pins.
  5. Only `hotReload` files may change. These are Joshua's own reload-safe `.dll`s under `plugins/`. Any other difference means **"restart-needed"** and nothing is touched: Thunderstore packages, BepInEx, configs, a removed mod, or a non-reload-safe build.
  6. The new DLL is written in place, exactly what Joshua's `-p:Deploy=true` copy does, so AutoReload sees the change and hot-loads it.
  7. The previous build is kept, and the revision, installed manifest and `pack-info.json` move to N, so the lobby check matches the host.
  8. The companion shows *"Joshua updated Scoutmaster Mode."*
- **Restart fallback:** friends who didn't opt in, packs that aren't test lobbies, and non-reload-safe changes get *"Joshua published mod pack rev N. Restart PEAK from the PEAK (Modded) icon to get it."*
- **Rollback:**
  - friend side: "Undo Joshua's last live update" in the app (`PeakPack.exe --hot-rollback`) puts the previous build back, and AutoReload loads it again;
  - host side: `hotfix --mod X --rollback` republishes the previous build from the release history as a new revision.
  - The next normal start from the icon always brings the friend to the latest revision.
- **Why the app, not the companion, verifies and swaps:**
  - Unity's Mono has no dependable ECDSA;
  - it keeps the in-game plugin small;
  - it keeps one audited code path for downloads, signatures, hashes and file writes;
  - the lobby can at most trigger an update check, never supply a URL or code.
- **Risks, honestly:**
  - **Desync mid-round:** for a few seconds, players run different builds. Use it between rounds or in the Airport.
  - **Unclean unloading:** a mod whose `OnDestroy` misses something (a Harmony patch, a spawned object, a static event) can double-apply or leak until restart. AutoReload never truly unloads old assemblies, so memory grows a little with each update. If mod A depends on reloaded mod B, A keeps the first B (AutoReload limitation).
  - **Bad builds:** a crashing build hits every opted-in friend at once. Undo and `--rollback` exist for that.
  - **Default off**, and only Joshua's signed own builds. Third-party code is never applied live.

### 17.3 One-command hotfix (agents)

```powershell
$cli = "C:\Users\joshu\PeakMods\FriendInstaller\src\PeakPack.Cli\bin\Debug\net10.0-windows\PeakPack.Cli.exe"
& $cli hotfix --mod ScoutmasterMode --dll C:\Users\joshu\PeakMods\ScoutmasterMode\bin\Release\ScoutmasterMode.dll            # dry run
& $cli hotfix --mod ScoutmasterMode --dll C:\Users\joshu\PeakMods\ScoutmasterMode\bin\Release\ScoutmasterMode.dll --publish  # real
& $cli hotfix --mod ScoutmasterMode --rollback --publish                                                                        # previous build
& $cli lobby snapshot                                                                                                           # fresh logs
```

`hotfix` does the following:

1. Finds the mod in `publish.json` by id, short name, title or DLL name.
2. Checks the build: managed, `[BepInPlugin]`, `OnDestroy`, embedded PDB. A build that fails is published as restart-only.
3. Keeps the exact bytes under `<work>\builds`, bumps the mod's version, and sets the changelog line.
4. Runs the normal pipeline: `gh release create rev-N ... --latest`, with the stable `PeakPack.exe`, so friends' links stay intact. It's a **dry run unless `--publish`**.
5. After a real release: saves `publish.json`, stamps Joshua's game (pack-info + companion), and drops a `hot-update` command for his companion, which announces revision N to the lobby.

The Host window has the same thing as "Publish hotfix..." and "Roll back to previous build" on the Own builds tab.

### 17.4 The live loop: friend reports a bug -> fix running in their game

1. **Friend:** "I can't see the helicopter." (Joshua is hosting with the companion; the friend has log sharing on, the default.)
2. **Agent (on Joshua's PC):** `PeakPack.Cli lobby snapshot`, wait ~5 s, then read `D:\SteamLibrary\steamapps\common\PEAK\BepInEx\PeakPack-remote-logs\_lobby.txt` and `<friend>.log`. These contain the friend's revision, mod versions, HeliPilot's own log lines, and Unity errors (e.g. a missing shader or asset bundle exception).
3. **Agent:** fixes HeliPilot, `dotnet build -c Release` (the mod's own IlScan check runs), then optionally tests in Joshua's own game (`-p:Deploy=true` + AutoReload).
4. **Agent:** `PeakPack.Cli hotfix --mod HeliPilot --dll <new build> --notes "Fix invisible helicopter for clients"` (dry run, check the output), then the same with `--publish` once Joshua says go.
5. **Friends:**
   - those who opted in to test-lobby updates: their PeakPack verifies and swaps the DLL, AutoReload loads it, and they see *"Joshua updated Heli Pilot."*;
   - everyone else: *"Joshua published mod pack rev N. Restart PEAK from the PEAK (Modded) icon to get it."*
6. **Agent:** `lobby snapshot` again to confirm the error is gone. If the fix made things worse: `hotfix --mod HeliPilot --rollback --publish`.

**Tested in the sandbox** (`tools/v4-test.ps1`, the real installed `PeakPack.exe --hot-update` as the companion starts it):

- applied, undo and re-apply;
- refusals that leave every file untouched: non-reload-safe build, Thunderstore change, friend opted out, wrong key, tampered manifest, test lobby off;
- consent switches reaching `pack-info.json`;
- hotfix dry run (exact gh command, stable PeakPack.exe, nothing saved or announced);
- DLL reload-safety checks on the real JetpackBoost build;
- lobby command files;
- companion IlScan;
- 107 unit checks of the lobby and diagnostics logic.

**Not tested:** anything inside PEAK. Photon events between real players, AutoReload swapping a DLL under a running game, and the in-game notices all need Joshua and a friend in a real lobby.

## 18. PeakPack on Mac (v0.5): Wine mode, headless CLI, Mac key defaults

Context: `C:\Users\joshu\PeakMods\MacPort\DESIGN.md` (Track D). Mac friends run the **same Windows PeakPack.exe** inside our Wine prefix. A native "PEAK (Modded).app" front end drives it. Windows behaviour is unchanged by everything in this section.

### 18.1 Wine mode in PeakPack (built)

- **Detection (`Platform.cs`):** `ntdll` exports `wine_get_version` only under Wine; `wine_get_host_version` returns `Darwin` on macOS. For sandbox tests, `PEAKPACK_FAKE_PLATFORM=wine-mac` simulates it, and a simulated platform never writes the registry.
- **Doorstop under Wine:** `winhttp.dll` in the game folder only loads if Wine prefers the native DLL. Before every modded launch, PeakPack sets `HKCU\Software\Wine\AppDefaults\PEAK.exe\DllOverrides` `winhttp = native,builtin`. This is the prefix's own registry, it survives Steam relaunching PEAK, and it's per app. Processes PeakPack starts also get `WINEDLLOVERRIDES=winhttp=n,b`. The front end can set the same variable on its `wine` calls as a backup.
- **Skipped under Wine:**
  - `.lnk` shortcuts;
  - the Installed Apps entry;
  - first-run self-install and self-relocation.

  The front end owns all of these (Dock icon, install folder, removal).
- **Signed `platforms.mac` manifest section** (publish.json `mac`):
  - `extraArgs`: Mac-only game arguments, e.g. `-force-d3d11` for the DXMT path. Validation refuses anything that isn't a plain `-flag`, and anything containing "doorstop".
  - `files`: Mac config defaults, always `ifMissing` and only under `config/`. A friend's own settings are never overwritten. A Mac file with the same path as a Windows file replaces it on Mac (`PackManifest.FilesFor(platform)`).
  - `minFrontEnd`: informational, for the front end.
  - The publisher uploads the Mac files as release assets named `mac-<id>-<sha8>-<file>`.
- **Headless CLI** (`PeakPack.exe --headless …`, `Headless.cs`). No window ever opens; it writes a JSON status file (atomic; poll it for progress) and returns an exit code:

  | Command | Does |
  |---|---|
  | `--headless --status` | check the signed manifest: "Not installed yet" / "Ready to play" / "Update available: …" |
  | `--headless --sync [--adopt]` | install/update exactly like the PEAK (Modded) shortcut |
  | `--headless --launch [--vanilla] [--on-sync-fail stop\|installed\|vanilla]` | sync, then start PEAK modded (or normal) |
  | options | `--status-out <file>` (default `%LOCALAPPDATA%\PeakPack\headless-status.json`) |

  - Exit codes: 0 ok · 1 failed (`problem.heading/advice/details`) · 2 PEAK not found · 3 foreign mod loader (rerun with `--adopt`) · 4 PEAK already running · 5 not installed.
  - Status fields: `state` (working/done/failed), `step`, `message`, `progress`, `platform`, `appVersion`, `installedRevision`, `latestRevision`, `changes`, `launched`, `commandLine`, `problem`, `exitCode`.

### 18.2 Mac key defaults (shipped as `platforms.mac.files`, next revision)

Mac laptops have no Insert/Delete (forward)/Home/End/PageUp/PageDown/numpad, and F1-F12 need Fn. Each pair keeps its meaning (`]`/`[` = up/down, `=`/`-` = more/less).

**Collision checks use these lists:**

- **PEAK's default keyboard bindings** (extracted from `PEAK_Data/data.unity3d`, 12 Oct 2026):
  - 1-9 (hotbar), W A S D, E, Q, R, V;
  - G (ScrollBackward), T (ScrollForward);
  - `` ` `` (backquote), Tab (UnselectSlot), Space, Enter, Escape, arrow keys, LeftCtrl, LeftShift.
- **Reserved by Joshua's mods:**
  - ItemTuner F;
  - ScoutmasterMode X (catch-up teleport), C (hold for the ability wheel), B (Weeping Angel blink), as of ScoutmasterMode e24e482.
- **Free for Mac defaults** (not used by PEAK or any mod's default): H, P, Y, Z, U, I, J, K, L, M, N, O and the punctuation `[ ] ; ' , . / \ - =`.

| Mod (config file) | Setting | Windows | Mac |
|---|---|---|---|
| JetpackBoost (`com.joshua.jetpackboost.cfg`) | [Keys] ThrustUp / ThrustDown | PageUp / PageDown | `]` RightBracket / `[` LeftBracket |
| | [Keys] ForwardUp / ForwardDown | End / Home | `;` Semicolon / `'` Quote |
| ElytraGlider (`com.joshua.elytraglider.cfg`) | [Keys] CyclePreset / ToggleElytra | Insert / Delete | P / Y |
| | [Keys] ToggleReadout | NumpadPeriod | `.` Period |
| | [Keys] LiftUp / LiftDown | Numpad + / - | `=` Equals / `-` Minus |
| | [Keys] BoostUp / BoostDown | Numpad * / / | `\` Backslash / `/` Slash |
| HeliPilot (`com.joshua.helipilot.cfg`) | [Controls] ToggleControlKey | F8 | H |
| | [Controls] InvertScrollZoom | false | **true** (natural scrolling) |
| | [Debug] DebugSummonKey / DebugFlareKey / DebugDumpKey (still behind EnableDebugKeys = false) | F9 / F9 / F10 | Z / Z (+Shift) / U |
| ItemTuner (`com.joshua.itemtuner.cfg`) | [Debug] LogLayout | true | false (same as Windows friends) |
| *later* ScoutBots | [Keys] SpawnBots / ToggleHunter | F4 / F1 | N / J |
| *later* ScoutmasterMode | [Debug] F5 / F6 / F7 / F11 / F3 (debug keys off by default) | | I / K / Comma / M / O |
| Companion (host only, Joshua on Windows) | [Host] RequestLogsKey (+Ctrl) | F9 | unchanged |

Unchanged because they already work on a Mac: ItemTuner `F`, HeliPilot flight keys (only while piloting), ScoutmasterMode `X`, `C`, `B`.

Risks:

- **Intentional, safe overlap:** HeliPilot's `[Rope] RopeKey` is **G**, which PEAK also uses for ScrollBackward. This is safe, as verified by the HeliPilot agent: PEAK samples ScrollBackward only while `playerMovementActive`, and HeliPilot forces that false while piloting or riding, which is the only time the rope key does anything. Keep G. HeliPilot 0.3.3 also blocks hotbar switching while flying.
- Checked against the real PEAK list above (12 Oct 2026): H, P, Y, Z, U are free. Re-check this list after PEAK updates.
- Punctuation positions assume a US layout.
- If Wine maps Command to Ctrl, HeliPilot's "down" (LeftCtrl) is Command on Mac.

### 18.3 Live-update hardening (helps Windows too; built)

- **`HotUpdater`:**
  - The undo record (`rollback\last.json` plus backups) is written **before** any DLL is replaced.
  - If a replacement fails partway, the files already replaced are restored, state, manifest and pack-info stay at the old revision, and the result is "failed: … the previous builds were put back".
  - Temp names in the fallback path are unique.
- **The result now lists `plugins`** (`guid|version|plugins/…dll`, read from each new DLL). The companion no longer says "updated" when the files are written; it waits until the new builds are **running**:
  1. Before starting PeakPack it snapshots `Chainloader.PluginInfos`. A plugin counts as loaded when its GUID maps to a **new** PluginInfo with a live instance and the expected version. AutoReload replaces the PluginInfo on every reload.
  2. Not loaded after 6 s (e.g. Wine on macOS: no file-change events reach AutoReload's FileSystemWatcher): the companion queues the reload itself. It adds the plugin's path to AutoReload's own queue (`pendingReloads`, the dictionary its watcher fills, found with a cached AccessTools handle) using the same path spelling as the watcher.
  3. Still not loaded after 25 s: a native notice says *"Joshua updated Heli Pilot. Restart PEAK from the PEAK (Modded) icon to load it."* It never claims success that didn't happen.
  4. An older PeakPack app that doesn't report `plugins` gets the old behaviour (notice on file write).
- **Fixed false assumption:** AutoReload listens to Changed/Created only, **not Renamed**. The locked-file fallback (rename) therefore relies on step 2.
- **Version:** app and companion are now **0.4.1**, so friends' PeakPack self-updates to the hardened code with the next revision.

### 18.4 HeliPilot cockpit bundle (next revision)

- `customFiles` can ship any file into a mod's plugin folder: `plugins/Joshua-HeliPilot/HeliPilot_cockpit.bundle` sits next to `HeliPilot.dll`, which is where HeliPilot looks.
- Its loader matches case-insensitively; if the bundle is missing or broken it logs and falls back to the built-in cockpit.
- Source: `_quarantine\HeliPilot_cockpit.bundle` (sha256 0bb047d7…, identical to Joshua's deployed copy).
- Not shipped: the `.manifest` and `HeliPilot_cockpit_mac.bundle` (that one is for the future native track).
- A bundle change is never applied live (not a .dll): it's a restart update.
- Staged for revision 4 with HeliPilot 0.3.2, under `%LOCALAPPDATA%\PeakPack-publisher\builds\next\`.

### 18.5 One repo, two kinds of releases

- MacPort CI lives in `jmproulx/peakpack` under `mac/`; its releases are `mac-build-*` **prereleases, never Latest**.
- Friends' apps read `releases/latest/download/manifest.json`, so "latest" must always be the newest `rev-N`.
- The pipeline:
  - always passes `--latest` for pack releases;
  - takes the **higher** of the live and the locally released revision (a misplaced "latest" can't make it reuse a revision);
  - after every real release, **checks that the friends' link serves the new revision**, with a loud warning if not.
- Hotfixes use the same pipeline.

### 18.6 Spec: the native Mac front end ("PEAK (Modded).app")

A thin wrapper; all mod logic stays in the Windows PeakPack inside the prefix. Built later by MacPort CI (`mac/`).

- **Layout (inside the prefix):** install PeakPack as `C:\users\<u>\AppData\Local\PeakPack\PeakPack.exe` (the Windows default data folder, **not** `C:\PeakPack`). Then:
  - self-update works;
  - the companion's live-update check finds `PeakPack.exe` next to the profile;
  - `pack-info.json` gets `appExe` automatically.
- **Calls** (always with `WINEPREFIX=<prefix>`, `WINEDLLOVERRIDES=winhttp=n,b`, and the runtime's `wine64`):

  | UI | Command |
  |---|---|
  | App start | `wine PeakPack.exe --headless --status --status-out C:\…\status.json` → show "Ready to play" / "Update available" / "Not installed yet" |
  | Click (Dock) | `--headless --launch --on-sync-fail stop` → on exit 1, show `problem.heading`/`advice` with **Play with the mods I have** (`--on-sync-fail installed`) / **Play normal PEAK** (`--vanilla`) / Cancel |
  | Option-click > Play normal PEAK | `--headless --launch --vanilla` |
  | First setup | `--headless --sync` (exit 3 → ask, then `--adopt`) |
  | Options (log sharing, test-lobby live updates) | the Windows app's switches; until a Mac UI exists: `PeakPack.exe` (window) under Wine, or a later `--headless --set-option` |
  | Logs | open `…\PeakPack\log.txt` and `…\profile\BepInEx\LogOutput.log` |

- **Progress:** poll the status file every 250 ms while `state` is `working` (`message`, `progress`).
- **Errors:** never parse the log. Use the exit code and `problem`.
- **Launch path:**
  - B1 (Windows Steam in the prefix): PeakPack's normal `steam.exe -applaunch` inside the prefix.
  - B2 (bridge): `--launch-method direct` (PeakPack starts `PEAK.exe` with `SteamAppId`/`SteamGameId`; already built).
  - Mac extra args come from the signed manifest automatically.
- **Updates:**
  - mods: every click (PeakPack);
  - PeakPack.exe: self-updates from the manifest's `app` entry;
  - the front end and the Wine runtime: from the `mac-build-*` prereleases and `mac-kit.json`, owned by MacPort. When the signed manifest carries `platforms.mac.runtime` / `platforms.mac.frontEnd` (§18.9), those pins win.
- **Signature:** every pack file is verified by PeakPack exactly as on Windows. The front end must not download mods itself.

### 18.7 Tests and review (v0.5)

- `tools/v5-test.ps1`, 56 checks, sandbox, simulated Mac via `PEAKPACK_FAKE_PLATFORM=wine-mac`:
  - Mac args and config defaults in the signed manifest;
  - a Windows friend never gets Mac files, while a Mac friend's Mac files replace the Windows ones;
  - ifMissing keeps a friend's edit;
  - Mac launch carries `-force-d3d11` and the (simulated) Wine DLL override, with no registry write in the simulation;
  - Windows is unchanged;
  - headless status, error and exit codes;
  - no shortcuts under Wine;
  - the cockpit bundle lands next to HeliPilot.dll;
  - live-update result lists plugins;
  - a failed mid-replace is undone;
  - a bundle change is restart-only;
  - bad Mac entries are refused;
  - a release never reuses a revision when "latest" is stale.
- All earlier suites still pass (sandbox 38, v3 40, v4 37, friend GUI 23, Host GUI self-test OK).
- A code review found 14 issues. Fixed:
  - a network timeout in headless mode reported as "existing mods" (exit 3);
  - a half-written file not restored, and temp files left behind;
  - rollback backups deleted after a failed restore;
  - a 404 on "latest" with no local record restarting at revision 1 (now refused unless `--first-publish`);
  - the companion's update check not guarded and only running inside a lobby;
  - headless self-update reporting "done" while the new copy was still working (it now waits and returns the new copy's exit code);
  - Mac-section changes not treated as restart-only;
  - a missing local mod list described as "Couldn't write a file".
- Still open, low priority:
  - AutoReload's queue might reload a DLL twice in a narrow race;
  - `PEAKPACK_FAKE_PLATFORM` is honoured in release builds (only matters if someone sets it on Windows);
  - a Wine build without `wine_get_host_version` would be treated as Linux.
- **Not tested:** anything under real Wine or macOS, and AutoReload inside a running PEAK. Those are MacPort gates G-D2 and G-D3.

### 18.8 For the Mac test kit (R6, R7) and revision 5

**R6:**

- **(a)** Every pack release now also carries **`PeakPack.exe.sha256`** (`<sha256>  PeakPack.exe`, `sha256sum -c` format) next to `PeakPack.exe`.
- **(b)** `--headless --launch --launch-method direct --game-dir <dir> --status-out <file>` works as one command. `--game-dir` and `--launch-method` are global options that every mode reads. v5-test check E runs exactly this combination (with `--data-dir`/`--manifest` overrides) under simulated Wine.
- **(c)** The status file uses **camelCase** keys (the same JSON options as the manifest), including nested `problem.heading/advice/details`. It's written atomically (`.tmp` then rename) at every step. The kit can stop falling back to PascalCase. Schema (`state` is the field to poll):

  | Key | Type | Meaning |
  |---|---|---|
  | `state` | `working` \| `done` \| `failed` | poll until not `working` |
  | `step` | `check` \| `sync` \| `launch` \| `start` | current step (`start` = PeakPack itself couldn't start) |
  | `message` | string | one line for the UI ("Ready to play", "Downloading HeliPilot…") |
  | `progress` | number 0-1 or absent | sync progress |
  | `platform` | string | "Windows", "Wine on macOS" (+ " (simulated)" in tests) |
  | `appVersion` | string | PeakPack version |
  | `installedRevision` / `latestRevision` | int / int or absent | pack revisions |
  | `changes` | string[] | what this run changed or what an update would change |
  | `launched` | `modded` \| `vanilla` or absent | set when PEAK was started |
  | `commandLine` | string or absent | the exact launch command |
  | `problem` | `{heading, advice, details}` or absent | on failure |
  | `exitCode` | int | same as the process exit code (0 ok, 1 failed, 2 no PEAK, 3 foreign loader, 4 PEAK running, 5 not installed) |

- **(d)** **PeakPack.exe has never run under real Wine.** Not Wine 11, not any version. G-D2 is the first time, so treat it as a G-D2 risk.
  - It's a self-contained .NET 10 single-file WinForms exe. Its native libraries are compressed inside and extracted to `%TEMP%` on start.
  - Mitigation in 0.4.2: `--headless`, `--hot-update` and `--hot-rollback` now run before any WinForms initialisation, so these paths need no GDI+/comctl32.
  - Things to watch in G-D2: .NET's single-file extraction and memory mapping under Wine, TLS 1.3/HTTP via Wine's schannel (downloads from github.com and thunderstore.io), the `ntdll` export lookup, and the `HKCU\Software\Wine` write. If .NET fails under Wine 11, the fallback is a `--self-contained` multi-file build; that's a build switch, not code.

**R7:** `mac/testkit/expect/pack-plugins.txt` lists the plugin names that pack revision 4 must load on Mac:

- AutoReload, InfinityJetpack (InfiniteJetpack's real BepInEx name), JetpackBoost, HeliPilot, ElytraGlider, ItemTuner, PeakPack Companion.
- One per line, exactly as BepInEx logs `Loading [<name> <version>]`; `#` lines carry GUID, version and source.
- It's generated from the real DLLs by `PeakPack.Cli expect-plugins --manifest <manifest.json> --platform mac --out mac/testkit/expect/pack-plugins.txt`. Regenerate after each revision. Rev 5 adds `PeakPack MacPreset` on Mac.

**Mac-only plugins:** `platforms.mac.files` now also takes files under `plugins/<folder>/`, enforced like any pack file, signed, installed only on Mac, and removed by strict mode on Windows. Config files there stay ifMissing.

**Revision 5 (staged, dry run):**

- Heli Pilot 0.3.2 → 0.3.3 (scroll-zoom no longer switches hotbar slots; cockpit bundle bytes unchanged).
- + Mac preset (Mac only) 0.1.0 (`plugins/PeakPack-MacPreset/PeakPack.MacPreset.dll`).
- Friend app 0.4.2.
- The companion is pinned to the exact rev-4 build (`builds\next5\PeakPack.Companion.dll`, fb520826, same code as the source). Builds made before the reproducibility fix differ byte-wise from today's identical source, and pinning avoids a pointless "new build" for friends and for Joshua's installed copy. Back-to-back builds now reproduce exactly (36d498c3 twice).

**Fixed in this round, found by the extended tests:**

- A mistyped or missing `--previous` path used to mean "first publish" (revision 1, which friends refuse). It now falls back to the guarded live/local revision.
- `publish`'s "Changes since previous" now also lists Mac-only plugins.

**Test counts at this point:** sandbox 38, v3 40, v4 37, v5 79 (new: Mac-only plugin, validation, sha256 asset, expect-plugins), friend GUI 23, Host GUI self-test OK.

### 18.9 Signed Mac pins and gameDepot (v0.6, optional)

From the Mac app lead's proposal (`mac/app/proposals/friendinstaller-platforms-mac.md`). Three additive manifest fields move what the Mac front end installs outside PeakPack (its Wine runtime and its own self-update) under Joshua's signature, and make "PEAK has an update" exact. Schema stays 1. The Mac front end already reads all three when present (`mac/app/Sources/PeakModdedCore/PackManifest.swift`).

**publish.json keys** (all optional and independent; example in `docs/mac-pins.publish.example.json`). Not in Joshua's publish.json yet: he adds them when a Mac runtime or app build should reach friends.

```json
"gameDepot": "auto",
"mac": {
  "runtime":  { "tag": "mac-build-runtime-pp2-cx26.3.0" },
  "frontEnd": { "tag": "mac-build-app-0.2.0" }
}
```

**What the publisher does** (`MacPins.cs`, called from `Publisher.PublishAsync`, so `prepare`, `release --dry-run` and `publish` all do it):

- `mac.runtime.tag`: reads the release from `api.github.com/repos/<githubRepo>/releases/tags/<tag>`, then its `SHA256SUMS`. It takes the line for `peakpack-runtime-<id>-x86_64.tar.xz` (`id` = the tag minus `mac-build-runtime-`) and the asset's size from the release. That fills `platforms.mac.runtime { id, tag, asset, sha256, size }`.
- `mac.frontEnd.tag`: the same for `mac-build-app-<version>`, line `PEAK-Modded-Mac-<version>.zip`. That fills `platforms.mac.frontEnd { version, tag, zip, sha256 }`.
- `gameDepot: "auto"`: reads `<gameDir>\..\..\appmanifest_3527290.acf` (or an explicit `.acf` path). It takes only `appid`, `buildid` and `InstalledDepots/<appid+1>/manifest` (or the only installed depot). Nothing else from the file (such as `LastOwner`) is ever used. If the file is missing or unreadable, `gameDepot` is left out with a log line; that is not a refusal. If Steam says an update is pending (`StateFlags` not 4), a note is printed and the installed build is recorded.
- "What friends will get" prints the pinned values (runtime id, asset, sha256, size and tag; app version, zip, sha256 and tag; depot, manifest and build).
- Only the publisher may call `api.github.com`. The friend app's download allowlist is unchanged.

**Refusals** (prepare/publish fails, nothing is signed or written):

- The release is missing (404, mistyped tag), a draft, or **not a prerelease**; GitHub answers with another tag; or the answer isn't release JSON.
- There's no `SHA256SUMS` asset, no line for the expected asset, the asset isn't in the release, or its size is 0.
- The tag doesn't start with `mac-build-runtime-` / `mac-build-app-`.
- `githubRepo` isn't set.
- `frontEnd.version` is older than `mac.minFrontEnd`: friends would be told to update to a build that doesn't qualify.
- Any schema rule fails (`PackManifest.ValidateForPublish`):
  - runtime: `id` matches `^pp[0-9]+-cx[0-9.]+$`; `tag` = `mac-build-runtime-` + `id`; `asset` ends in `.tar.xz` with no `/` or `\`; `sha256` is 64 hex characters; `size` > 0 when present;
  - frontEnd: `version` is dotted (`0.2.0`, optional `-suffix`); `tag` = `mac-build-app-` + `version`; `zip` ends in `.zip` with no `/` or `\`; `sha256` is 64 hex characters;
  - gameDepot: `appId` = the manifest's `gameAppId`; `depotId` > 0; `manifestId` and `buildId` are decimal ids (written as strings).

**Friends' apps:**

- `PackManifest.Validate()` doesn't check the pins, so a bad Mac pin can never stop a Windows sync. The Mac front end applies the same rules itself and falls back to its embedded pin.
- Live-update planning (`HotUpdater.Plan`) ignores `runtime` and `frontEnd`: they change nothing PeakPack installs, so they never force a restart. Changed launch args or Mac files still do.
- `PackDiff` (the "Update available: N mods changed" text) is unchanged. Pins are not mods.

**Windows compatibility** (`tools/pins-compat-test.ps1`, 18 checks). It runs the **shipped rev-5 PeakPack.exe 0.4.2**, byte-identical to rev-5's `app.sha256`, against the rev-5 manifest with the three fields added, signed with a throwaway key:

- `--headless --status` gives the same result as for the unmodified manifest, on Windows and simulated Mac.
- `--headless --sync` installs revision 5 on both platforms (same HeliPilot SHA-256; Mac preset only on Mac), then reports "Ready to play".
- Negative controls fail as they should: the same file with schema 99 ("too old"), and a wrong key.
- Why it works: `PackManifest.JsonOptions` has never set `UnmappedMemberHandling`, so System.Text.Json skips unknown members. The companion never reads the manifest; it reads `pack-info.json`, which PeakPack writes from fixed fields, with Unity's `JsonUtility`, which also ignores unknown fields.

**Unit tests:** `tools/ManifestPinsTests` (`dotnet run --project tools/ManifestPinsTests`; `-- --live` also resolves the real `mac-build-runtime-pp1-cx26.3.0` read-only). It has 110 checks:

- schema present/absent, round-trip, JSON names and types matching the Swift decoder;
- every validation rule, publisher side and friend side;
- `SHA256SUMS` formats;
- GitHub resolution refusals (canned answers, no network);
- the `.acf` reader, including the guarantee that it never leaks `LastOwner`;
- live-update planning;
- an offline end-to-end `PublishAsync` with a local loader and a throwaway key: the keys absent give the old manifest and no GitHub calls; the keys present give fields covered by the signature; refusals write no manifest or signature;
- publish.json load/save: an existing publish.json gains no new keys when the Host window saves it.

### 18.10 Manifest signatures under Wine: managed P-256 verifier (app 0.4.3)

**Bug (first real Mac test, M1 iMac, Wine 11 + DXMT runtime pp1):**

- PeakPack 0.4.2, byte-identical to rev-5, failed `--headless --status` at step `check` with "The mod list's signature is invalid". The same exe and manifest verify on Windows.
- curl.log was empty, so the download was fine. `PeakPack.exe --headless --sync` hit the same `SecurityException` in `Installer.LoadManifestAsync`.

**Exact path:**

- `ManifestSigner.Verify` called `ECDsa.Create()` (`ECDsaWrapper` over CNG `ECDsaCng`), then `ImportSubjectPublicKeyInfo`, then `VerifyData(SHA-256, IEEE P1363)`.
- The native calls, seen in a stack trace on Windows: `ECDsaCng.ImportParameters`, then `ECCng.ImportKeyBlob`, then `CngKey.Import`, which is **`NCryptImportKey`** (ncrypt.dll, Microsoft Software KSP). Then `VerifyData` hashes with BCrypt and calls **`NCryptVerifySignature`**.
- `tools/SignatureTests` shows that ncrypt.dll is loaded only by the platform verifier. Wine's ncrypt is partial.
- 0.4.2 caught `CryptographicException` and `FormatException` and returned false, so an NCrypt *failure* and a real `false` looked the same: "signature invalid".
- A key CNG can't import surfaces as `PlatformNotSupportedException` wrapping a `CryptographicException` (0x80090027 "The parameter is incorrect"). 0.4.2 didn't catch that.

**Fix:**

- `P256Verifier.cs`: a managed P-256 ECDSA **verifier only** (no signing, ~120 lines, `System.Numerics.BigInteger`, affine arithmetic, Shamir's trick, about 40-60 ms per check). Its only native dependency is `SHA256.HashData`, which every file download already relies on.
- `ManifestSigner.Verify` uses it when `Platform.IsWine` (real or simulated). **Windows keeps the platform verifier.** Its only change there: the key must be exactly the SubjectPublicKeyInfo (no trailing bytes), and `PlatformNotSupportedException` also counts as "not verified".
- Both are equally strict:
  - the key is SPKI id-ecPublicKey/prime256v1 with an uncompressed point on the curve;
  - the signature is exactly 64 bytes `r||s` (DER refused);
  - 1 ≤ r, s < n;
  - R is not infinity and R.x mod n = r.
  - No skip flag exists.
- BouncyCastle was not used: it would add about 6 MB to a single-file exe for one verify. Its MIT licence would have been fine.
- **Diagnostics** (log.txt):
  - Windows failure: the exception type, HRESULT and message (and the inner exception).
  - Under Wine, every check logs one line: `signature check: managed P-256 valid|INVALID; platform verifier says: …`. The platform result is for diagnosis only; it never decides. A managed failure logs its reason (`signature doesn't match`, `r or s out of range`, wrong length, bad key).

**Tests** (`tools/SignatureTests`, 48 checks, random count via `-- --random N`):

- The managed curve constants equal CNG's explicit nistP256 parameters. Curve sanity: n·G = ∞, (n−1)·G = −G, and so on.
- RFC 6979 A.2.5 (P-256, SHA-256): the managed scalar multiply turns the RFC private key into the RFC public point. "sample" and "test" are valid on both verifiers; swapped messages are invalid.
- Edge cases: r/s = 0, n, n+1 and 2^256−1; swapped r/s; 63/65/0-byte and DER signatures; an off-curve, compressed, (0,0) or trailing-byte key are all invalid on both. The high-S twin is valid on both (plain ECDSA).
- Random: 1000 keys and messages signed by .NET, plus bit-flipped signature, bit-flipped message, appended byte and wrong key. That is 4997 vectors with 0 disagreements.
- The real rev-5 `manifest.json` + `.sig` (`tools/SignatureTests/fixtures/rev-5`, byte-identical to the release assets, `-text`) with the real public key from `pack.config.json`: valid on both. Tampered copies (one bit, a newline, CRLF, revision 6, bit flips in r/s, another key, an unrelated signature) are invalid on both.
- `ManifestSigner.Verify` on the Windows path, and on the Wine path in a child process with `PEAKPACK_FAKE_PLATFORM=wine-mac`. The managed path verifies rev-5 without loading ncrypt.dll.
- Not included: NIST CAVP `SigVer.rsp`. It wasn't downloaded in this session; add it to `fixtures/` when wanted.

**Release:** app **0.4.3**, staged (not published) at `sandbox\staged-0.4.3\PeakPack.exe` (+ `.sha256`). With its embedded key, it reports "Not installed yet" for the live rev-5 manifest on Windows and on simulated Mac. Mac friends only get it with the next pack revision Joshua approves (the manifest's `app` entry). Until then the Mac front end installs 0.4.2.
