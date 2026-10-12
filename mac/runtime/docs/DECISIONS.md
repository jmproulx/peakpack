# Runtime decisions (Track A, workstream A2)

*12 Oct 2026, runtime team. Evidence is from the CrossOver 26.3 tarball, inspected on Joshua's PC (`tools/runtimework/cx/`), and from upstream repos read through the web. Each decision has a revisit trigger, tied to a gate in DESIGN §7.*

## D1. Wine source: CodeWeavers' CrossOver 26.3.0 LGPL sources

**Chosen:** `crossover-sources-26.3.0.tar.gz`, SHA-256 `ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872`. We build `sources/wine` ourselves.

**What the tarball contains** (from listing all 50,394 entries, plus key files):

| Item | Finding |
|---|---|
| `sources/wine/VERSION` | **Wine 11.0**, the same base as CrossOver 26 itself |
| msync | `server/msync.c`, `dlls/ntdll/unix/msync.c`. Enabled by `WINEMSYNC=1`, with `WINEMSYNC_QLIMIT` |
| DXMT/D3DMetal glue | `dlls/winemac.drv/d3dmetal.c` exports `DECLSPEC_EXPORT struct macdrv_functions_t macdrv_functions` (24 entries, 192 bytes). The code comment says "D3DMetal/DXMT both call it" |
| CrossOver hacks | 36 distinct "CrossOver Hack / CW Hack" markers. Examples: Mac Edit menu, `CX_ROOT` hooks, a compat DB loader |
| Other sources | DXVK **1.10.3** (CodeWeavers' copy, with its cxlab CI recipe), MoltenVK 1.2.10, vkd3d 1.18, FreeType 2.13.3, GnuTLS 3.8.3, Nettle 3.10, GMP 6.3.0, GStreamer, glib |
| Not included | DXMT, LLVM, D3DMetal (proprietary), build scripts for Wine itself |

**Why this source and not Gcenx or the Whisky repack:**

1. **DXMT works with it without hacks.**
   - DXMT v0.80's `winemetal_unix.c` does `dlsym(RTLD_DEFAULT, "macdrv_functions")`. It expects a 10-function table plus `struct macdrv_win_data {hwnd, cocoa_window, cocoa_view, client_cocoa_view}`.
   - CrossOver's table and struct start with exactly those fields, in that order.
   - Upstream Wine and Gcenx builds hide every winemac symbol: notpop counted 0 exported text symbols in Gcenx 11.0. They need `-fvisibility=default` rebuilds or forks (DXMT issue #170, PR #166).
2. **msync is built in.** Upstream Wine 11 and Gcenx's MacPorts ports have no msync patch (Gcenx Portfiles show none).
3. **It matches the benchmark.** G-A2 compares against CrossOver 26 (Wine 11.0 + DXMT). Starting from the same Wine minimises the delta that we have to explain.
4. **It's the B2 build tree.** The Steam bridge needs a configured tree of the exact runtime. Whisky's `Libraries.tar.gz` and Gcenx's tarballs have no winegcc/winebuild.
5. **Licence.** The tarball is CodeWeavers' LGPL source offer. We mirror it unchanged and publish our patches (none so far).
6. **Prior art.** `frankea/winecx-gptk` builds a CrossOver-26.3-derived Wine on GitHub Actions. Gcenx's MacPorts ports supply the configure flag set.

**Rejected or kept as fallback:**
- *Gcenx `wine-stable-11.0_1`* (SHA-256 `b50dc50e…2388`): a binary only, with no public build scripts (no workflows in `macOS_Wine_builds` or `macports-wine`), no msync, and hidden winemac symbols.
- *Whisky `Libraries.tar.gz` v3.1.1* (SHA-256 `01f3a1b4…81ccf3`, matches the gh digest): kept in `pins.env` as the **G-A1 quick baseline** only.

**Revisit if** G-A1 shows DXMT failing to find `macdrv_functions`:
1. Apply `patches/wine/optional/0001-ntdll-load-unixlibs-RTLD_GLOBAL.patch` through the workflow input `optional_patches`.
2. If that isn't enough, set `PP_WINEMAC_EXPORT_ALL=1`. This rebuilds `winemac.so` with `-fvisibility=default`; makedep puts `$(CFLAGS)` last, so it overrides `-fvisibility=hidden` for unix objects only.

**Mirror:**
- The primary URL is media.codeweavers.com. Research agents saw it return 403 and fail to resolve.
- `fetch_verify` falls back to `mac-build-src-cx26.3.0`, a prerelease in `jmproulx/peakpack` that main uploads once from the copy on Joshua's PC.

## D2. Build host and toolchain

| Choice | Value | Evidence / reason |
|---|---|---|
| Runner | **`macos-15-intel`** (x86_64, native). Fallback input: `macos-15` (arm64) with Rosetta, where scripts re-exec under `arch -x86_64` | `macos-13` was retired by 4 Dec 2025. `macos-15-intel` exists until the macOS 15 image retires (autumn 2027); `macos-26-intel` also exists. `macos-14` retires 2 Nov 2026. winecx-gptk uses arm64 + Rosetta, which our scripts also support |
| Unix compiler | Apple clang `-arch x86_64`, `MACOSX_DEPLOYMENT_TARGET=14.0` | DXMT needs macOS 14+ (Sonoma). Deps are built from source for 14.0, which avoids Homebrew bottles tied to the runner's macOS |
| PE compiler | **llvm-mingw 20260826** (LLVM 23.1.0; gh digest `48bedd16…6a7f`, same as Gcenx's Portfile), `--with-mingw=llvm-mingw` | Gcenx's choice. DXMT's CI also uses llvm-mingw. Switch: `PP_PE_TOOLCHAIN=mingw-gcc`; winecx-gptk saw an llvm-built `kernelbase.dll` stall Windows-Steam login, which matters only for B1 |
| PE archs | `--enable-archs=i386,x86_64` (new WoW64) | 32-bit PE support without 32-bit macOS code. Needed for B1 (Windows Steam is 32-bit) and for 32-bit helper installers |
| Dependencies | GMP, Nettle, GnuTLS, FreeType **from the same CrossOver tarball**; libinotify-kqueue 20240724; MoltenVK v1.4.2 (Khronos binary, thinned to x86_64) | One pinned source covers most deps. GnuTLS is built with included libtasn1/unistring and without p11-kit/idn, so the dylib chain is just GMP → Nettle → GnuTLS |
| inotify | **`--with-inotify` via libinotify-kqueue** (Gcenx does the same) | Wine's `ReadDirectoryChangesW` needs it. This is the **main risk in DESIGN §3.4**: AutoReload's FileSystemWatcher for live update (G-D3) |
| Off | gstreamer, ffmpeg, sdl, x11, wayland, cups, krb5, gettext, tests, winemenubuilder | Smaller, fewer dylibs. Cost: no Media Foundation video (see TUNING.md check V1) and no SDL controller backend (IOHID remains) |
| Bundling | Every dylib gets an `@rpath/<leaf>` install name. `wineserver` gets rpath `@loader_path/../lib`. The launcher sets `DYLD_FALLBACK_LIBRARY_PATH=<rt>/lib:/usr/lib` because Wine `dlopen`s **bare sonames** (configure stores the `otool -L` leaf, e.g. `libfreetype.6.dylib`). Every modified Mach-O has its signature removed | Mach-O load commands are verified free of build paths (`assert_no_build_paths`, `verify_runtime.sh`) |

## D3. DXMT: build v0.80 (MIT) ourselves; LGPL `main` is a tuning axis

- **Pin:** tag `v0.80`, commit `589adb780354b461645b29999cefaf533594ee99` (annotated tag object `bc484001…5394`, 23 Apr 2026). It is fetched by commit with submodules.
- **Build recipe** (DXMT CI at v0.80):
  - LLVM **15.0.7** source (SHA-256 `8b5fcb24…eac6`, from Homebrew's `llvm@15`; GitHub publishes no digest), built for x86_64-darwin with `LLVM_TARGETS_TO_BUILD=""`;
  - meson 1.10.0, llvm-mingw, `build-win64.txt`;
  - `-Dwine_install_path=<our wine-dev install>` (it uses `bin/winebuild` and `lib/wine`);
  - Xcode 16.x for the Metal toolchain. Xcode 26 needs `-downloadComponent MetalToolchain`.
- **`-Dwine_builtin_dll=false`:**
  - d3d11/dxgi/d3d10core become native-style DLLs, and `pp-backend.sh` copies them into system32 with **PEAK.exe-scoped** `native,builtin` overrides. Other programs keep wined3d, and the backend can be switched per prefix.
  - Builtin-marked copies in system32 would be redirected to Wine's own d3d11.
  - `winemetal.dll` and `.so` are always builtins in `lib/wine`.
- **Why build instead of using `dxmt-v0.80-builtin.tar.gz`** (gh digest `8f260e36…529d`): the prebuilt one is compiled against 3Shain's Wine 8.16 tree. Building against our tree keeps `winemetal` consistent with our winebuild and lets us move to a newer DXMT without changing method. The prebuilt is pinned for an A/B check at G-A1.
- **Licence:** v0.80 is the last MIT release, and later releases are LGPL-2.1+. Both are fine for us: LGPL only adds source publication, which our pipeline already does.
- **Candidate B for G-A2:**
  - DXMT `main` at or after `e40c9d7a` (5 Oct 2026), which fixes #220: `CopySubresourceRegion` 2D→3D, where Unity's colour-grading LUT renders black. Main HEAD on 12 Oct is `186a2327`.
  - The v0.74 notes also list a Unity hang fix, and #179 (Unity 6 input, `EnableMouseInPointer`) is a Wine-side issue.
  - Move to B if PEAK shows black or garbled post-processing or input issues on v0.80.

## D4. DXVK fallback: CrossOver's DXVK 1.10.3, built on Linux

- It comes from the same tarball (pinned by `CX_SHA256`) and is built with mingw-w64 GCC (posix threads) on `ubuntu-24.04`, mirroring CodeWeavers' cxlab CI. x64 only.
- MoltenVK v1.4.2 (gh digest `f95765a6…024e`) is newer than CrossOver's 1.2.10. The swap is deliberate (bug fixes, Metal 3). If DXVK misbehaves, the TUNING row "MoltenVK 1.2.10 from the CX tarball" is a source build away.
- Gcenx's DXVK-macOS (`v1.10.3-20230507-repack-builtin`, gh digest `810b1e5c…6f00`) ships **no dxgi.dll**. That is why the `dxvk-nodxgi` backend exists.

## D5. Prefix defaults

- win10; mscoree/mshtml disabled (Unity ships its own Mono; PeakPack is self-contained .NET 10); no menu builder.
- RetinaMode off and 96 DPI. RetinaMode is read only from the global Mac Driver key; this was verified in source.
- coreaudio audio driver.
- PEAK-scoped Mac keys use the **game profile** (left Command = Ctrl, left Option = Alt). Wine's default is Command = Alt and Option = characters, verified in `keyboard.c` (`kVK_Command → VK_LMENU`). DESIGN §3.3 assumed Command = Ctrl was already Wine's default; that assumption was wrong, so the prefix now sets it.
- User folders are sandboxed (real folders, not Mac-home links), so there are no TCC prompts for Desktop/Documents/Downloads (G-D1 approvals).
- `WINEDLLOVERRIDES` is unset by `pp_env`. Graphics overrides live only in `AppDefaults\PEAK.exe`, because the env var would beat them.

## D6. CI shape

- One macOS job does deps → Wine → DXMT → assemble → SDK → source bundle → verify. Keeping it in one job avoids shipping GB-sized trees between jobs; it should stay inside GitHub's 6 h job limit, but that is unmeasured.
- One Linux job builds DXVK.
- Publishing is manual: `workflow_dispatch` with `publish=true` creates a prerelease `mac-build-runtime-<id>` with `--latest=false`, and is refused if any input is unpinned.
- See `ci/PROPOSAL.md`.
