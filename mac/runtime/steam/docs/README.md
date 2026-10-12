# PeakPack for Mac: Steam bridge (Track B2)

*Owner: Steam bridge team (`mac/runtime/steam/`, locally `C:\Users\joshu\PeakMods\MacPort\runtime\steam\`). State: 12 Oct 2026. Contract with the runtime team: `../../INTERFACES.md`; our requests to them: `../REQUESTS-to-runtime.md`.*

The Windows build of PEAK runs in our Wine runtime under Rosetta. This bridge lets it talk to the **real Mac Steam client** (the player's own login and licence checks, unmodified) the same way Valve's Proton does on Linux.

## 1. Architecture

```
PEAK.exe (Windows x86_64, our Wine, Rosetta)
 └ steam_api64.dll (PEAK's own, SDK 1.61)
     reads HKCU\Software\Valve\Steam\ActiveProcess\SteamClientDll64
     └► C:\Program Files (x86)\Steam\steamclient64.dll   OUR forwarder: 40 PE export forwarders, no code, no imports
         └► lsteamclient.dll   Wine builtin PE: Valve's Proton lsteamclient + our 3 patches
             └► lsteamclient.so   Wine unixlib, x86_64 Mach-O, UNSIGNED
                 └ dlopen ► $STEAM_COMPAT_CLIENT_INSTALL_PATH/steamclient.dylib  (Mac Steam's own, x86_64 slice)
                     └ IPC ► Mac Steam client (arm64), logged in by the player

peakpack_steam_launcher.exe (ours, started by the front end inside Wine)
  writes ActiveProcess {pid = itself (kept alive), SteamClientDll64}, SteamPath/SteamExe, HKLM InstallPath,
  Apps\3527290 {Installed=1, Running=1, Updating=0}; sets SteamAppId = SteamGameId = 3527290 (and
  STEAM_COMPAT_CLIENT_INSTALL_PATH if given); starts PEAK.exe [args] [+connect_lobby <id>]; waits; resets Running/pid.
```

**What each part does**

- **`steam_api64.dll` (Valve's, untouched).** It loads the client DLL named by `ActiveProcess\SteamClientDll64` and resolves `CreateInterface`, `Steam_BGetCallback`, `Steam_FreeLastCallback`, `Steam_GetAPICallResult`, `Steam_ReleaseThreadLocalMemory`, `Steam_IsKnownInterface`, `Steam_NotifyMissingInterface` and the `Breakpad_*` functions.
- **`steamclient64.dll` (ours).** It forwards exactly the 40 names that Valve's Windows `steamclient64.dll` exports and that `lsteamclient.dll` also exports. The one exception is `Breakpad_SteamSendMiniDump`, which lsteamclient lacks. See `src/forwarder/EXPORTS.txt`.
- **`lsteamclient` (Valve's).** It converts every interface between the Windows and Mac ABIs:
  - SDK 0.99u to 1.65;
  - callback structs: pack(8) to pack(4);
  - MSVC `this`/struct-return to the Itanium ABI.

  Valve's macOS code path already existed. Our patches fix the few places where it did not build or work on macOS.

## 2. Decision record

Joshua's decisions are binding (DESIGN.md §10a; Steam lead brief, 12 Oct 2026):

1. Fetch Valve's `lsteamclient` sources **at build time** from a **pinned, hash-checked** Proton commit. **Never redistribute the sources**, and never commit them. **Ship the built bridge** to friends.
2. Write our own scripts and patches. **NotProton (GPL-3) is a reference only**: none of its code, scripts or patch text is used. We read its diff only to learn which ~70 lines needed changing.
3. **Hard line:**
   - no Steam emulator;
   - no DRM bypass;
   - no ownership spoofing;
   - never modify, patch or wrap the Steam client.

   The real Mac Steam client does the login and the licence checks. NotProton's "Steam Play enablement", which modifies Steam, is **not** adopted.
4. Get game files only through **Valve's own tools**: Mac Steam `download_depot 3527290 3527291`, or Valve `steamcmd +@sSteamCmdForcePlatformType windows`. DepotDownloader is not used.
5. CI runs in the existing repo `jmproulx/peakpack` under `mac/`, on GitHub macOS runners. Built binaries are assets of `mac-build-*` prereleases, never marked latest. Nothing is pushed until main has confirmed it with Joshua.

## 3. Files

| Path | What |
|---|---|
| `build/proton-pin.env` | The pin: Proton tag `proton-11.0-2e`, commit `bc896217ffcd67f892f952b010f898fe7bd0f0a1`, tarball SHA-256 `be18d77a…b077` (93,595,375 bytes), lsteamclient tree digest `bf5eb856…d987` (3,133 files) |
| `build/fetch_lsteamclient.sh` | Downloads (or `--tarball`) and verifies the tarball hash (warning only) and the tree digest (hard). Extracts only `lsteamclient/`, refuses links, applies `patches/*.patch`, and stages the full tree plus the PE-only view under `$PP_WORK/steam/` |
| `build/build_lsteamclient.sh` | Steps `fetch`, `pe`, `unix`, `collect` (and `all`). Builds `lsteamclient.dll` through Wine's build system and `lsteamclient.so` with `clang++ -arch x86_64`, verifies them, and writes `$PP_WORK/steam/out/` |
| `build/check_lsteamclient_zig.sh` | Compile-only check of all 263 sources with Zig against Wine headers. Runs on any OS, including Windows git-bash |
| `build/package_bridge.sh` | Release tarballs: bridge binaries plus licences (no sources), and a separate test tarball |
| `patches/0001-unixlib-macos-host-client.patch` | `NOMINMAX`; default `steamclient.dylib` path; `dlerror()` in the load error; `Steam_IsKnownInterface`/`Steam_NotifyMissingInterface` made optional |
| `patches/0002-steamclient-main-win64-vtables.patch` | 64-bit: keep vtables (and their RTTI locator slot) and interface objects inside `lsteamclient.dll`; never copy them into the forwarder |
| `patches/0003-steam-input-macos-keycode.patch` | macOS branch for Steam Input's VK→native key helper (returns 0) |
| `src/forwarder/` | `steamclient64.def`, `forwarder.c` (entry point only), `.rc`, `build_forwarder.sh`, `verify_forwarder.py`, `EXPORTS.txt` |
| `src/launcher/` | `peakpack_steam_launcher.c`, `build_launcher.sh` |
| `tests/probe/` | `steam_abi_min.h` (our own minimal ABI description), `steam_client_probe.c` (T1/T2 on macOS, T3 in Wine), `steam_api_probe.c` (T4) |
| `tests/mac/` | Gate scripts `t0`, `t1_t2`, `t3_t5`, `t5_check_player_log`, `t6_t14_checklist`, `t12_memsample`, `t16`, plus `lib.sh` |
| `tests/pc_launcher_test.sh` | Safe launcher test on a Windows PC that has a real Steam install |
| `tests/depot_manifest.sh` | Read-only file manifest of a PEAK install, for T15 |
| `ci/mac-steam-bridge.yml` | Draft workflow (Mode B), not pushed |

### 3.1 Why these patches (all written by us)

Measured against the pinned tree. Its `lsteamclient/` is byte-identical to `164e0ccd…`, the commit NotProton was diffed against.

- **NOMINMAX.** In Wine 11's `windef.h`, `min`/`max` are macros in C++ too, so `std::max` in `collapse_path()` breaks. We define `NOMINMAX` in `unixlib.cpp` only, because no other file uses `std::min`/`std::max`.
- **Optional `Steam_IsKnownInterface` / `Steam_NotifyMissingInterface`.**
  - Upstream fails the whole init if either export is missing.
  - With our patch, a missing `IsKnownInterface` reports "known", so `CreateInterface` still decides, and a missing `NotifyMissingInterface` is a no-op.
  - A WARN line (`warn+steamclient`) records which export is missing.
  - T0 shows whether Mac Steam exports them.
- **dylib path.** Upstream already uses `$STEAM_COMPAT_CLIENT_INSTALL_PATH/steamclient.dylib` on macOS. When the variable is unset, we try the stock path under `$HOME` before the old `DYLD` fallback, and we print `dlerror()` on failure.
- **64-bit vtables and RTTI.**
  - Upstream copies some vtables and the `SteamClient` object into the `.data` section of a loaded Valve `steamclient.dll`, for old 32-bit games such as Mafia II.
  - Our `steamclient64.dll` has no such section.
  - On x86_64, `init_rtti()` stores each vtable's RTTI locator in slot `[-1]` as offsets relative to `lsteamclient.dll`, and a copy would lose that slot.
  - So on `_WIN64` the original vtable and heap memory are always used. 32-bit behaviour is unchanged.
- **Steam Input keycodes.** Upstream `#error`s on anything that is not Linux. On macOS we return 0 (no native key). PEAK does not use Steam Input glyph lookups that need it.

**Checked on this PC:**
- The patches apply cleanly to the pinned tree.
- All **263 sources compile**, checked with `build/check_lsteamclient_zig.sh` against CrossOver 26.3's Wine 11.0 headers:
  - 219 C++ unix sources as `x86_64-macos`;
  - 44 C PE sources as `x86_64-windows-gnu`.
- The real link happens on the Mac/CI, against `ntdll.so`.

## 4. Building

### 4.1 Mode A: inside the runtime build (preferred; one `RUNTIME_ID` = one ABI)

```sh
export PP_WORK=…                                   # same as the runtime build
mac/runtime/steam/build/fetch_lsteamclient.sh      # stages $PP_WORK/steam/extra-dlls/lsteamclient (PE-only view)
mac/runtime/build/build_wine.sh --extra-dll-dir "$PP_WORK/steam/extra-dlls"
mac/runtime/steam/build/build_lsteamclient.sh unix collect     # C++ unix half + checks → $PP_WORK/steam/out
mac/runtime/build/add_builtin.sh "$PP_WORK/dist/runtime" "$PP_WORK/steam/out/lsteamclient.dll" "$PP_WORK/steam/out/lsteamclient.so"
```

Wine 11's makedep cannot compile C++, which is why the PE-only view and our own unix build exist (`REQUESTS-to-runtime.md` R1).

### 4.2 Mode B: against a published SDK (our draft workflow, or a Mac)

```sh
export PP_WORK=~/peakpack-build RUNTIME_ID=pp1-cx26.3.0
# unpack peakpack-wine-sdk-$RUNTIME_ID.tar.xz to $PP_WORK/sdk and the runtime tarball to $PP_WORK/dist/runtime
export PATH=$PP_WORK/tools/llvm-mingw/bin:$PATH    # llvm-mingw from mac/runtime/build/pins.env
NTDLL_SO=$PP_WORK/dist/runtime/lib/wine/x86_64-unix/ntdll.so \
  mac/runtime/steam/build/build_lsteamclient.sh all --sdk "$PP_WORK/sdk/wine-sdk"
```

- `PE_MODE=makedep` is the default. It adds the module to `SUBDIRS`, reruns `tools/makedep -C` and runs `make dlls/lsteamclient/all`, with no reconfigure.
- `PE_MODE=reconfigure` runs the runtime team's `make_makefiles` + `autoreconf` + `config.status --recheck` sequence instead.

### 4.3 The forwarder, launcher and probes (any OS)

```sh
ZIG=…/zig src/forwarder/build_forwarder.sh          # or PE_CC=x86_64-w64-mingw32-clang WINDRES=x86_64-w64-mingw32-windres
ZIG=…/zig src/launcher/build_launcher.sh
python -I src/forwarder/verify_forwarder.py src/forwarder/out/steamclient64.dll --spec $PP_WORK/steam/src/lsteamclient/lsteamclient.spec
zig cc -target x86_64-windows-gnu -O1 -o tests/probe/out/steam_client_probe.exe tests/probe/steam_client_probe.c -ladvapi32
zig cc -target x86_64-windows-gnu -O1 -o tests/probe/out/steam_api_probe.exe tests/probe/steam_api_probe.c
clang -arch x86_64 -O1 -o steam_client_probe tests/probe/steam_client_probe.c          # macOS, T1/T2
```

**Built on Joshua's PC (Zig 0.17.0), 12 Oct 2026:**

| File | Size | SHA-256 | Notes |
|---|---|---|---|
| `steamclient64.dll` | 6,656 bytes | `2adf24bf…9dc6` | Reproducible. No imports. 40 forwarders, 12 to implemented lsteamclient functions and 28 to Wine stubs (the same set as Proton) |
| `peakpack_steam_launcher.exe` | 90,112 bytes | `8402a758…60c4b` | — |

The probes build for `x86_64-windows` and `x86_64-macos` with `-Wall -Wextra`.

### 4.4 Release (CI, after main and Joshua confirm)

`build/package_bridge.sh` produces two tarballs:

- `peakpack-steam-bridge-<RUNTIME_ID>-<sha12>.tar.xz`, laid out as in runtime §3: `lib/wine/x86_64-{windows,unix}/lsteamclient.*`, `share/peakpack/steam/{steamclient64.dll,peakpack_steam_launcher.exe}`, `LICENSES/`, `SHA256SUMS`, `build-info.txt`;
- `peakpack-steam-tests-…tar.xz`.

The workflow refuses to package if any `.c`/`.cpp`/`.h` would end up in the bridge tarball. Tag: `mac-build-steam-<RUNTIME_ID>-<sha12>`, `--prerelease --latest=false`.

**Files for main's push proposal:**
- everything under `mac/runtime/steam/` except the `.gitignore`d outputs;
- `.github/workflows/mac-steam-bridge.yml`, from `ci/mac-steam-bridge.yml`.

## 5. The launcher

```
peakpack_steam_launcher.exe [--appid 3527290] [--steam-dir 'C:\Program Files (x86)\Steam'] [--client-dll …]
    [--forwarder-src …] [--no-install] [--steam-client-dir /Users/…/MacOS] [--language english]
    [--connect-lobby <id>] [--cwd …] [--log …] [--dry-run] [--registry-root Software\PeakPackTest
    [--delete-test-root]] [--no-launch [--hold-ms N]] [--keep-registry]  --  <game.exe> [game args…]
```

- **Arguments after `--` reach the game unchanged** (Doorstop args, `-force-d3d11`). They are re-quoted with the MSVC rules. `--connect-lobby` appends `+connect_lobby <id>`.
- **Working directory:** the game exe's folder.
- **Exit code:** the game's. The launcher's own errors are 120 usage, 121 refused, 122 registry, 123 launch and 124 install.
- **Safety:**
  - Outside Wine, it refuses to touch the real registry (exit 121) and refuses to copy the forwarder into any folder that contains `steam.exe`.
  - `--registry-root` must be under `Software\` and not under `Software\Valve`. It redirects every write to `HKCU\<root>\{HKCU,HKLM,HKLM32}\…`.
- **A first argument starting with `steam://`** is logged and ignored (exit 0), in case something runs `SteamExe`.

**Tested on this PC** (`tests/pc_launcher_test.sh`, 14/14 PASS):
- it refuses real mode outside Wine;
- it refuses a test root under Valve;
- the dry-run plan for PEAK is complete, including `+connect_lobby` and Doorstop args;
- with `cmd.exe` as the game under the test root and a fake Steam dir, the exit code (7) and the `SteamAppId`/`SteamGameId`/`STEAM_COMPAT_CLIENT_INSTALL_PATH` environment reach the game;
- the registry layout is correct, `pid`/`Running` are reset, and the test root is deleted;
- the real `HKCU\Software\Valve\Steam\ActiveProcess` is unchanged.

The Windows probes were run only with `--dry-run`. They refuse to run outside Wine (exit 7) and do not even read the real Valve keys there.

## 6. Licensing

- **Valve's lsteamclient:** Steamworks SDK licence (`lsteamclient/LICENSE`, shipped as `LICENSES/lsteamclient-Steamworks-SDK-LICENSE.txt`).
  - Not open source, and it has a no-reverse-engineering clause.
  - We fetch it at build time from Valve's public repo, at a pinned and hashed commit.
  - It is never committed: `$PP_WORK/steam/` gets a `*` `.gitignore`, and `.gitignore` here catches stray copies.
  - It is never put in a source tarball or release. Only the built `lsteamclient.dll/.so` ship.
  - This is Joshua's decision (§2), and the risk is low but not zero. GE-Proton ships such binaries openly.
- **Proton (repo root) and `steam_helper`:** BSD-3-Clause, Valve. Our launcher follows `steam_helper`'s design only; no code is copied, and it is credited in `NOTICE-steam-bridge.md`.
- **`cxx.h`:** LGPL-2.1, from Wine, compiled into `lsteamclient.dll`. Its source is available from the Proton commit and the runtime's Wine sources.
- **Wine headers and import libraries:** LGPL, covered by the runtime's source bundle.
- **Our code** (scripts, patches, forwarder, launcher, probes, tests): `LICENSE-PeakPack-steam.txt`, **MIT as proposed**.
  - The repo has no licence yet; Joshua confirms.
  - Our patch files contain small context excerpts of Valve's files, as any diff does. Patches apply only to the fetched sources.
- **NotProton:** GPL-3, reference only; nothing is copied.

## 7. Gates G-B0 … G-B6 (DESIGN §7): exactly what to run

Run these in the `peaktest` user on the M1 iMac/MacBook, with Mac Steam running and logged in by Joshua.

**Setup:**
- Copy `mac/runtime/steam/tests/` there (or unpack `peakpack-steam-tests-*.tar.xz`).
- Make one folder `$B` with `steamclient64.dll`, `peakpack_steam_launcher.exe`, `steam_client_probe.exe`, `steam_api_probe.exe`, `lsteamclient.dll` and `lsteamclient.so`.

**Rules for every run:**
- Every script writes `logs-…/summary.txt`. Copy the logs back to the PC.
- No script starts, stops or modifies Steam.

| Gate | Tests | Run | Pass |
|---|---|---|---|
| **G-B0** | T0 | `tests/mac/t0_steamclient_dylib.sh` | `x86_64` slice present, and the 5 required `Steam_*`/`CreateInterface` exports. Records the optional two, the signing and the Steam build |
| **G-B1** | T1, T2 | `tests/mac/t1_t2_rosetta_probe.sh --hold 30` (needs CLT and Rosetta) | Loads under Rosetta; `logged_on=1`; real SteamID; app id 3527290; ticket plus `GetAuthSessionTicketResponse` OK. **Manual:** Mac Steam shows "Playing PEAK" during the hold |
| **G-B2** | T3, T4, T5 | `tests/mac/t3_t5_wine_bridge.sh --runtime <rt> --prefix <pfx> --bridge $B --install-bridge --game 'C:\Games\PEAK' --t5` | **T3:** SteamID and ticket through forwarder → lsteamclient → dylib. **T4:** `RestartAppIfNecessary=0`, `IsSteamRunning=1`, `InitEx=0` (OK), SteamID, app id, ticket via manual dispatch. **T5:** `Player.log` has `Steam runtime manager initialized: True` and the persona |
| **G-B3** | T6–T10 | Play with Joshua's Windows PC. Then `tests/mac/t5_check_player_log.sh --wineprefix <pfx>` and `tests/mac/t6_t14_checklist.sh <Player.log>` | **T6:** `Lobby Created:`/`Entered Steam Lobby:` with valid IDs. **T7:** `Successfully got user token`, no `Failed to authenticate:`. **T8:** joins work both ways (friends list and `--connect-lobby <id>`). **T9:** `Received User Stats from Steam` (no unlocks). **T10:** avatars visible |
| **G-B4** | T11–T14, T16 | **T11:** press the invite-friends kiosk and the pause-menu invite. **T12:** `tests/mac/t12_memsample.sh --duration-min 60` during play. **T13:** switch Mac Steam to beta, update, rerun G-B1 and G-B2-T5. **T14:** quit Mac Steam mid-game, then restart it. **T16:** `tests/mac/t16_unsigned_unixlib.sh --runtime <rt> --prefix <pfx> --bridge $B` | **T11:** no crash. **T12:** swap growth < 1 GB, memory pressure not red. **T13:** still passes. **T14:** no hard crash. **T16:** quarantined unsigned `.so` loads; a signed copy fails (or record it if it loads) |
| **G-B5** | T15 | **(b)** In Mac Steam open `steam://open/console`, then run `download_depot 3527290 3527291`. **(a)** Valve steamcmd for macOS: `steamcmd +@sSteamCmdForcePlatformType windows +login <user> +app_update 3527290 validate +quit`. Joshua types the login and Steam Guard code. For each, run `tests/depot_manifest.sh <dir> peak-mac.manifest` and compare with `tests/depot_manifest.sh 'D:/SteamLibrary/steamapps/common/PEAK' peak-win.manifest` (read-only, same build ID) | `diff` is empty; the build ID matches the Windows install; Steam Guard flow works. DepotDownloader is not used |
| **G-B6** | B1 fallback | Not this bridge. Install Windows Steam in a **separate** test prefix of our runtime, then do 10 cold starts with `steam.exe -no-cef-sandbox -cef-single-process -noverifyfiles` (needs the webhelper wrapper, DESIGN §5.1). Count successful logins, try a PEAK lobby, and run `t12_memsample.sh` in parallel | ≥ 9/10 logins, the lobby works, memory recorded. Otherwise drop B1 |

**Before G-B2:** if T3 fails with an unresolved unix call, check `warn+steamclient` in `logs/t3.log`.
- `unable to load native steamclient library … : <dlerror>` comes from our patch 0001.
- `native steamclient lacks Steam_IsKnownInterface` is only a warning.

## 8. Known risks and open items

- **Untested until the first Mac/CI run:**
  - makedep's handling of our PE-only view (`PE_MODE=makedep`);
  - the `lsteamclient.so` link against `ntdll.so` without `-undefined dynamic_lookup` (`LSC_ALLOW_UNDEFINED=1` is there for diagnosis);
  - finding the unixlib by name for a PE `Makefile.in` without `UNIXLIB`.

  G-B2 T3 covers all three.
- **Licence choice.** MIT is proposed for our code, and Joshua needs to confirm it.
- **PEAK's auth path.** It differs from the research note: PEAK's Photon uses `CustomAuthenticationType.None`, and the Steam session ticket goes to the **EOS Connect** login (`Successfully got user token` / `Failed to authenticate:`). Joshua's own Windows `Player.log` already shows one `Failed to authenticate: ConnectExternalTokenValidationFailed`, so G-B3 T7 needs a Windows baseline run as well.
- **Overlay.** It is absent, so the invite buttons do nothing (T11). Players join through the Mac Steam friends list or `--connect-lobby`.
- **Pin bumps.** To move to a newer Proton:
  1. download the new tag;
  2. run `fetch_lsteamclient.sh --tarball … --no-patch` with the new values;
  3. recompute the two hashes (formula in `proton-pin.env`);
  4. re-apply or refresh the patches, run `check_lsteamclient_zig.sh`, then rerun G-B1/G-B2.
