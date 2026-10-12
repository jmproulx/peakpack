# Runtime licences: what we ship, what we fetch, what we owe

*12 Oct 2026, runtime team. Not legal advice: it records the facts and the obligations we follow. The runtime's own `LICENSES/` folder (made by `build/collect_licenses.sh`) holds the texts and `NOTICE.md`/`SOURCES.md`.*

## 1. Components

| Component | Version / pin | Licence | Ship or fetch | How it's linked | Obligations we meet |
|---|---|---|---|---|---|
| **Wine** (CodeWeavers CrossOver 26.3.0 source release) | Wine 11.0 + CX changes; tarball SHA-256 `ac99c8ca…6872` | LGPL-2.1-or-later | **Ship** (our build, in the runtime tarball) | Separate binaries, `.so` unixlibs and PE DLLs; the user can replace any of them | (1) **Source:** the unchanged CrossOver tarball in release `mac-build-src-cx26.3.0`, plus per build `peakpack-runtime-src-<id>.tar.xz` (our patches, build scripts, configure args). (2) Licence text and notices in `LICENSES/wine/`. (3) Written offer in `SOURCES.md`. (4) No restriction on reverse engineering or modification. (5) Relinking: everything is dynamic, and the build scripts are published |
| **DXMT** | v0.80, commit `589adb78…` | **MIT** (v0.80 is the last MIT release; newer is LGPL-2.1-or-later) | **Ship** (our build) | `winemetal.so`/`.dll` builtins; d3d11/dxgi/d3d10core native DLLs | MIT: keep the notice (`LICENSES/dxmt/`). If we move to LGPL `main`: the same source duty as Wine, already covered by the source bundle (DXMT source at the exact commit) |
| **LLVM** (statically linked into `winemetal.so`) | 15.0.7, SHA-256 `8b5fcb24…eac6` | Apache-2.0 WITH LLVM-exception | Ship (inside winemetal.so) | Static | The LLVM exception waives the notice requirement for compiled object code; we include `LICENSES/llvm/LICENSE.TXT` anyway |
| **DXVK** (CrossOver's copy) | 1.10.3 | zlib/libpng | Ship (our build) | Native DLLs in `lib/peakpack/dxvk` | Keep the notice; don't misrepresent the origin; mark altered versions (we don't alter it) |
| **MoltenVK** | v1.4.2 binary (Khronos release, thinned to x86_64), gh digest `f95765a6…024e` | Apache-2.0 | Ship (repackaged binary) | dylib | Licence text included; NOTICE says it was modified (thinned with `lipo`, install name changed) |
| **FreeType** | 2.13.3 (from the CX tarball) | FTL (dual-licensed with GPLv2; we choose FTL) | Ship | dylib, dlopened | Credit in the docs: "Portions of this software are copyright © The FreeType Project (www.freetype.org)". `NOTICE.md` + `LICENSES/freetype/` |
| **GnuTLS** | 3.8.3 (CX tarball) | LGPL-2.1-or-later | Ship | dylib, dlopened | LGPL source: the same tarball; text in `LICENSES/gnutls/` |
| **Nettle** | 3.10 (CX tarball) | LGPL-3.0-or-later OR GPL-2.0-or-later (we take LGPL-3) | Ship | dylib | LGPL-3 §4: source, a replaceable library, licence text. It's a separate dylib, so a user can replace it (no TiVo issue: nothing we ship is signed or locked) |
| **GMP** | 6.3.0 (CX tarball) | LGPL-3.0-or-later OR GPL-2.0-or-later | Ship | dylib | Same as Nettle |
| **libinotify-kqueue** | 20240724 | MIT | Ship | dylib (linked by wineserver) | Notice |
| **winetricks** | — | LGPL-2.1 | **Not used** | — | — |
| **Whisky `Libraries.tar.gz`** (G-A1 baseline only) | v3.1.1 | Mixed (Wine LGPL, DXMT MIT, DXVK zlib) | **Fetched** on the test Mac only, never shipped | — | — |
| **D3DMetal / GPTK** | — | Apple SLA | **Never shipped or fetched by us**; optional friend import | — | — |
| **Steam bridge** (`lsteamclient`, Steam team) | Proton commit (pinned by the Steam team) | **Steamworks SDK licence** (not open source); Proton's other parts are BSD-3 | Built binaries are shipped (decision 10a.1); **sources fetched at build time, never committed or published** | Wine builtin injected with `--extra-dll-dir` | Our source bundle records only a **tree hash** for injected DLLs and never copies `mac/runtime/steam/` (`make_source_bundle.sh`). That code isn't LGPL-derived from Wine in the copying sense: it uses Wine's public builtin interfaces, the same as Proton. Steam team to confirm in their docs |
| **Our scripts** (`mac/runtime/**`) | — | The PeakPack repo's licence (decided by Joshua/main) | Published in the repo and in each source bundle | — | — |

## 2. Build-only tools (not shipped)

These tools are used only to build the runtime and are not shipped:

- llvm-mingw 20260826 (Apache-2.0 WITH LLVM-exception, with mingw-w64 runtime licences). The mingw-w64 CRT and winpthreads code is compiled into PE DLLs; it's ZPL/MIT-style, with no source duty beyond notices, which come with the Wine notice set.
- meson (Apache-2.0), ninja (Apache-2.0), CMake (BSD-3), Xcode/Apple clang (Apple), Homebrew autotools/bison/flex (GPL, with exceptions for generated parsers), mingw-w64 GCC (GPL with the runtime library exception), shellcheck and yamllint (CI lint only).

## 3. Rules the pipeline enforces

1. **Every shipped binary has a source path.** `pins.env` pins every input. A release build refuses unpinned inputs (`PP_ALLOW_UNPINNED`, publish guard in the workflow).
2. **Same release, same source.** Each `mac-build-runtime-<id>` prerelease carries `peakpack-runtime-src-<id>.tar.xz`, and its `SOURCES.md` links the unchanged CrossOver tarball mirror.
3. **The CrossOver mirror stays up** as long as any runtime that uses it is downloadable (and at least three years after the last one, per the written offer).
4. **Nothing proprietary goes into a source bundle or release:** no Steamworks SDK sources, no D3DMetal, no Steam or PEAK files.
5. **Replaceability:** every LGPL component stays a separate file. The runtime is unsigned, and `manifest.json` lists the hash of every file, so a friend can swap in a rebuilt library. The front end must not refuse a modified runtime in a way that blocks this; it may warn.
