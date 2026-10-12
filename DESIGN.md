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

### 9.3 Why not stream code into running games

AutoReload works for Joshua because he's a developer watching his own log. Doing it to friends would mean:

- **Mods must support unloading.** Most Thunderstore mods don't clean up Harmony patches, spawned objects or event handlers; reloading them mid-game leaks or crashes. Only Joshua's own mods would qualify, and only if written carefully.
- **Mid-match desync.** Players would briefly run different code in the same run (physics, items, RPC signatures).
- **Security.** It turns "download a signed manifest at launch" into "a running game accepts new code from the network". Even with signatures, it's a much larger attack surface, and Thunderstore's rules forbid plugins that download and run code.
- **Benefit is small.** Restarting PEAK from the icon takes ~30 s and is exactly the tested path.

If Joshua ever wants it: an opt-in "dev lobby" mode for his own mods only, where the companion offers *"Joshua published rev 8. Restart now?"* is the safe version. Not worth building now.

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
- The companion accepts network values only for whitelisted, typed, range-clamped settings from the signed pack, and never writes them to disk.
- `pack-info.json` and the companion only read local files and Photon properties. No downloads, no code loading.

## 12. Game updates breaking mods

The app compares PEAK's `version.txt` with the pack's `gameVersion` and says so in the status line ("PEAK has updated since this pack was made…"). Friends can always play normal PEAK. Joshua's fix is a normal publish.

## 13. Licensing

PeakPack never redistributes other authors' mods: friends download from Thunderstore's own URLs. Joshua hosts only his own DLLs, the companion, and the app. BepInEx/Doorstop (LGPL) also come from Thunderstore.

## 14. Platforms

Out of scope by Joshua's decision (11 Oct 2026): all friends are on Windows with Steam. No Mac, Steam Deck or Linux support is planned.

## 15. Status (v0.3)

**Works and tested:**

- Real PC: launch method verified (§2.1).
- `tools/sandbox-test.ps1`: the 39 v0.2 end-to-end checks.
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
