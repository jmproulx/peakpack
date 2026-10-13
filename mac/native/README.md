# peakmetal: PEAK shaders → Metal (Track C, graphics)

`native/peakmetal/` converts every graphics `Shader` **and** every `ComputeShader` in a **copy** of PEAK's data
(Unity 6000.3.15f1, URP 17.3) to Metal-only shaders that Unity's macOS player can load, and writes the game data
back either as loose files or as a repacked `data.unity3d`. It runs on each friend's Mac from their own files
(no derived data leaves the machine). Compute shaders are the compute team's `peakmetal/compute/` (see
`README-compute.md`); `convert` runs both on the same environment in one pass.

Requirements: Python **3.10+** (tested on 3.13; the CI bundle ships CPython 3.13.16) with UnityPy 1.25.4 and its
import-time dependencies (exact set below); `spirv-cross` (KhronosGroup/SPIRV-Cross `vulkan-sdk-1.4.363.0`).
Nothing else: the SMOL-V decoder is pure Python by default; Apple's `metal` compiler is only for `validate`.

## Commands

```
python -I native/pm.py doctor    [--data PEAK_Data|FILE] [--json FILE]   # environment + self-test
python -I native/pm.py convert   <PEAK_Data/data.unity3d> --out DIR [--mode loose|bundle|both]
                                 [--packer lz4hc|lz4|none] [--jobs N] [--only NAME] [--no-compute]
python -I native/pm.py validate  DIR/msl [--metal PATH] [--std macos-metal2.1] [--report FILE]
python -I native/pm.py inspect   <data.unity3d|serialized file> [--shader NAME [--params]]
python -I native/pm.py roundtrip <file> [--shader NAME]        # byte-exact codec check
python -I native/pm.py translate <file> --shader NAME --out DIR # one shader -> MSL + parameter dumps
python -I native/pm.py golden    <unity editor resources> <unity default resources>
```

`pm.py` puts its own folder on `sys.path`, so it works under `-I` from any working directory (on this PC the
venv also has a `.pth`, so `python -I -m peakmetal ...` works from `native\`). Every command that runs
spirv-cross accepts `--spirv-cross PATH` and `--bin-dir DIR`. `convert` refuses to write next to its input, into
a Steam library or into a Unity editor install.

On this PC spirv-cross lives in `tools\shaderwork\bin` (the package never looks there by itself): set
`PEAKMETAL_SPIRV_CROSS=C:\Users\joshu\PeakMods\MacPort\tools\shaderwork\bin\spirv-cross.exe`, or pass
`--spirv-cross`. The tests do this automatically (`tests/conftest.py`).

Tests (pytest; inputs read-only, skip when absent):
`..\tools\venv\Scripts\python.exe -I -m pytest tests -q` (about 3 min). `PEAKMETAL_SLOW=1` adds the
whole-`data.unity3d` tests (object round trip, serialized-file writer, archive rewrite; about 15 min).

## build-app / verify-app / remove-app (PEAK Native.app)

Assembles `PEAK Native.app`: Unity's Mac player (Mono, arm64) running PEAK's own Windows data. The recipe is
`testkit/gates/G-C0.sh` `assemble()`, productised in `peakmetal/app.py` (constants at the top; `recipe_version` 1).

```
python -I native/pm.py build-app --game "<PEAK folder>" --unity-player <pkg|MacStandaloneSupport folder>
    [--variation macos_arm64_player_nondevelopment_mono] [--converted DIR] [--steam-zip ZIP]
    [--out "~/Applications/PEAK Native.app"] [--work DIR] [--force] [--dry-run] [--json FILE]
python -I native/pm.py verify-app  APP
python -I native/pm.py remove-app  APP [--keep-cache] [--work DIR] [--purge-user-data] [--dry-run]
```

- `--unity-player` is Unity's `UnitySetup-Mac-Mono-Support-for-Editor-6000.3.15f1.pkg` (macOS only: size, MD5 and
  the `Unity Technologies` signature are checked, then `pkgutil --expand-full` into the work folder, never installed),
  or any folder that holds `Variations/` (the Windows editor's `PlaybackEngines/MacStandaloneSupport`).
- `--converted DIR` (a `pm convert` output with `Data/`) replaces PEAK's `Data/` files; the game's other companions
  (`*.resource`, `StreamingAssets`, json, `boot.config`) are taken from the game, and no `data.unity3d` is written.
  Without it the stock `PEAK_Data` is used.
- `--steam-zip` (Steamworks.NET 2024.8.0, SHA-256 pinned) installs Valve's macOS `libsteam_api` unmodified.
  Optional: without it the build warns that Steam will not initialise.
- `--work` (default `~/Library/Caches/PeakPack/native` on macOS, else `<out parent>/.peakpack-native-work`) holds
  the expanded pkg and the extracted Steam bundle; it is marked with `peakpack-native-work.json`.

**What it writes:** only `--out` (built in `<out>.building-<pid>`, then swapped in; an existing app is kept until
the new one is complete) and `--work`. Inside the app, `Contents/Resources/peakpack-native.json` is the manifest:
schema `peakpack.native_app/1`, the fingerprint (SHA-256 of the canonical JSON of the inputs and `recipe_version`),
the inputs (game path and version, `data.unity3d` size and mtime, the pkg SHA-256 or folder, variation, the
UnityPlayer binary SHA-256, converted dir and `convert_summary.json` SHA-256, Steam zip SHA-256), and every file:
SHA-256 for files from Unity, Steam, the converter or written by us, and size only for files cloned from the game.
A second run with the same fingerprint prints `up to date` and touches nothing (`--force` rebuilds).
On macOS: `xattr -cr`, ad-hoc signing of Unity's dylibs and the app, then `codesign --verify --deep --strict`.

**What it never touches:** the game folder (read only; `--out` and `--work` may not be inside it), Unity's install
(read only), Valve's signature on `libsteam_api`, and anything outside `--out`/`--work` (`--dry-run` writes nothing,
and `--json` writes only the file you name).

`verify-app` re-hashes the manifest's files, checks the game files' sizes, lists missing, changed and extra files,
and runs `codesign` on macOS. Exit 0 ok, 3 problems, 2 not a PeakPack app (no manifest).

`remove-app` refuses anything whose manifest or `CFBundleIdentifier` (`com.peakpack.native`) does not match. It
deletes the app, leftover `.previous` and `.building-*` folders, and the work cache (only if it has the marker;
`--keep-cache` keeps it). `--purge-user-data` (opt-in: PEAK's saves may live there) also deletes Unity's per-user
folders for `unity.LandCrab.PEAK` and the `com.peakpack.native` state and cache, printing each path. It never touches
the game folder.

Exit codes as the rest of the CLI: 0 ok (also `up to date`), 1 a build step failed, 2 environment or usage problem
(refused inputs, a bad pkg, a Steam zip that is not the pinned file, or an existing folder that is not our app).

## Running on macOS (contract for the CI bundle and the test kit)

Kept in sync with `NOTES-bundle.md` (the coordination file with the bundle team).

- **Entry point:** `<python> -I -B <bundle>/native/pm.py <command>`. No install step, no `.pth`. peakmetal is
  `.py` files only and writes nothing next to its code (scratch goes to the output folder or the system temp dir).
- **spirv-cross discovery** (first hit wins; same rules on every OS): `--spirv-cross PATH` → `--bin-dir DIR` →
  `$PEAKMETAL_SPIRV_CROSS` (full path; set-but-missing is an error, never a silent fallback) → `$PEAKMETAL_BIN`
  (folder, legacy) → `<folder of pm.py>/bin/` → `PATH`. Names tried: `spirv-cross` (plus `spirv-cross.exe` first
  on Windows). No hard-coded install paths.
- **Other variables:** `PEAKMETAL_SMOLV_DECODE` (optional native SMOL-V decoder; default pure Python, byte-identical
  on all 7,335 distinct PEAK/golden streams); `PEAKMETAL_METAL` (Apple `metal`, `validate` only; on macOS PATH is
  never searched, because `/usr/bin/metal` is an xcrun shim that opens an Xcode-install dialog).
  `PP_CONVERTER_PYTHON` is read by the test kit / Mac app (which interpreter runs `pm.py`), not by peakmetal.
- **Python:** 3.10 is the floor of the pinned packages (lz4 4.4.5, Pillow 12.3.0, fsspec 2026.9.0); peakmetal's own
  code parses as 3.8, UnityPy 1.25.4 needs 3.9 (`functools.cache`). Tested on 3.13.14 (this PC); the bundle uses
  3.13.16. The G-C0 gate's `>= 3.11` check is stricter than needed and harmless.
- **Packages** (exactly `packaging/requirements.lock`, installed `--no-deps`): `UnityPy==1.25.4 lz4==4.4.5
  brotli==1.2.0 pillow==12.3.0 attrs==26.1.0 fsspec==2026.9.0 tpk_ar==0.2.4`. `import UnityPy` imports all seven;
  UnityPy's texture/audio export extras (texture2ddecoder, etcpak, astc-encoder-py, fmod_toolkit, archspec) are
  never imported. `doctor` prints the third-party modules it imported (on this PC: PIL, UnityPy, attr, attrs,
  brotli, fsspec, lz4, tpk_ar).
- **`doctor`** with no arguments needs no game or Unity data, no network and no Xcode: it reports versions and tool
  discovery, then runs a built-in synthetic Unity-style program (hand-assembled SPIR-V in `selftest.py`, our own
  MIT code) through the real pipeline (11 checks: translation, entry point, invariant position, y-flip,
  attributes, cbuffer naming, `rp_output_remap`, depth2d, slots, Metal program round trip; plus a `metal` compile
  when a compiler is configured). With `--data <PEAK_Data>` it also converts the Unity built-in shaders in
  `PEAK_Data/Resources/unity default resources` (shipped with every PEAK install; they carry Vulkan **and**
  Unity's own Metal programs), diffs our Metal against Unity's (on this PC: 93 stage pairs match, 7 explained,
  24 stereo-multiview variants skipped by design), injects Metal-only, re-reads, and converts one ComputeShader.
  Nothing from the game or Unity is committed; tests generate everything at run time.
- **Exit codes** (`convert`, `doctor`, and every other command): `0` success; `1` unexpected internal error
  (traceback on stderr); `2` environment/usage error (input missing, refused output location, spirv-cross missing
  or not runnable, UnityPy/lz4 missing, python too old); `3` `convert` finished and wrote all outputs but some
  programs/kernels needed a fallback (listed in `problems`), or a `doctor` self-test check failed.

### `convert` outputs and `convert_summary.json` (for G-C0)

`DIR/Data/` (loose files; mode loose/both), `DIR/data.unity3d` (mode bundle/both), `DIR/msl/<shader>/*.metal` and
`DIR/msl/_compute/*.metal` (every distinct graphics program and compute kernel, for `validate`),
`DIR/convert_report.txt|json` (per graphics shader), `DIR/compute_report.txt|json` (per kernel variant), and
**`DIR/convert_summary.json`**, schema `peakmetal.convert_summary/1`:

| Key | Meaning |
|---|---|
| `schema` | `"peakmetal.convert_summary/1"` (a breaking change bumps the number) |
| `peakmetal_version`, `started`, `seconds`, `source`, `out`, `mode` | run identity |
| `exit_code` | `0` or `3`, same as the process exit code (codes 1 and 2 never write a summary) |
| `status` | `"ok"` or `"completed_with_fallbacks"` |
| `tools` | `python`, `platform`, `unitypy`, `lz4`, `spirv_cross` (path), `spirv_cross_found_by`, `smolv` |
| `options` | `msl_version`, `depth_textures`, `unity_cb_names`, `framebuffer_fetch` |
| `outputs` | `loose_dir` (`"Data"` or null), `loose_files`, `loose_files_reserialized`, `bundle` (`"data.unity3d"` or null), `bundle_bytes`, `msl_dir` |
| `graphics` | `shaders`, `status_counts` (ok / empty / partial / unsupported / failure), `programs`, `programs_translated`, `programs_unsupported_by_design`, `programs_failed`, `unsupported_reasons`, `failure_reasons`, `metal_bytes`, `msl_files`, `features` |
| `compute` | `shaders`, `kernel_variants`, `status_counts`, `fallback_stubs`, `metal_workarounds` (null with `--no-compute`) |
| `problems` | list of `{kind: "graphics" or "compute", shader, ..., detail}`; empty exactly when `exit_code` is 0 |
| `reports` | file names of the detailed reports |

"Unsupported by design" (not a problem): geometry-stage programs (the VR blit; its SubShader is emptied so Unity
falls back), stereo-multiview variants, shaders with no Vulkan programs in the build. A gate should pass on
`exit_code == 0` (or accept `3` and read `problems`) with `outputs.loose_dir == "Data"`.

## Architecture

| Module | Role |
|---|---|
| `common/binio.py` | LE reader/writer, Unity aligned strings |
| `common/blob.py` | Per-platform blob container: entry table + LZ4 segments |
| `common/program.py` | Program entries; Metal (`F00DCAFE`) and Vulkan (SMOL-V) program data |
| `common/params.py` | Parameter entries: cbuffers, struct params, global block, binding kinds 0–4 |
| `common/shader.py` | Typetree helpers: decompress/recompress platforms, walk `m_PlayerSubPrograms` |
| `common/smolv.py` | Pure-Python SMOL-V decoder (port of aras-p/smol-v, MIT) |
| `spirv.py` | SPIR-V reader/patcher: resources, static use, bindings, spec constants, invariance |
| `translate.py` | One Vulkan program → MetalVS + MetalFS (MSL + parameter entries) |
| `inject.py` | One Shader typetree → Metal-only (keyword indices unchanged) |
| `repack.py` | Unity-faithful serialized-file writer; loose output; UnityFS writer |
| `convert.py` | Whole game: load, translate (thread pool), inject, compute, repack, report |
| `validate.py` | Apple `metal -c` over every emitted MSL; skips cleanly without the compiler |
| `golden.py` | Diff our translation of Unity's golden Vulkan programs against Unity's own Metal |
| `tools.py` | Platform-neutral tool discovery (spirv-cross, optional smolv_decode / metal) and wrappers |
| `doctor.py`, `selftest.py` | `doctor`: environment report, synthetic self-test (hand-assembled SPIR-V), optional real-data golden check |
| `compute/` | ComputeShaders (README-compute.md); `compute/metalfix.py` recreates Unity's Metal-only STP code |

Pipeline per Vulkan program: SMOL-V → SPIR-V → resource analysis (static use from the entry point) →
merge the pass's progVertex common cbuffers → Metal slot assignment per stage → SPIR-V patch (Binding =
Metal slot, spec constants → constants, Position `Invariant`) → SPIRV-Cross `--msl --msl-version 20100
--msl-decoration-binding` (VS `--flip-vert-y`; FS `--msl-pad-fragment-output`, `--msl-shader-input` to
widen FS inputs to the VS output width) → MSL post-pass (Unity conventions below: depth textures,
inline samplers, function constants, base vertex/instance, framebuffer fetch) → program entries.

## Format and conventions: what is proven, and how

Golden references: the editor's `unity editor resources` (95 shaders) and `unity default resources`
(6) carry D3D11, Vulkan **and** Metal programs of the same shaders; the Mac player's `unity default
resources` has the same Metal programs (byte-identical to the editor's). `unity_builtin_extra` holds 206
shaders with no compiled programs (not usable as a reference).

| Fact | Evidence |
|---|---|
| Shader object codec is byte-exact | `roundtrip`: all 275 PEAK + 107 golden objects. Typetree read/write exact; every entry re-encodes exactly; rebuilding the blob and recompressing with **LZ4HC level 9** gives Unity's exact `compressedBlob`/offsets/lengths; the whole object re-serializes identically |
| Blob layout | Segment 0 = `u32 n, n×(offset, length, segment)` + entries; entries packed in order. Large blobs: segment 0 = table only, then segments ≤ 8 MiB (D3D11) / 16 MiB (Vulkan); `pack_segments` reproduces all 550 PEAK platform blobs, including the 4 multi-segment ones (URP Lit, GD/FoliageGD) |
| Parameter grammar | `cbuffers[0]` is the unnamed global block (spec constants, e.g. `UNITY_RUNTIME_INSTANCING_ARRAY_SIZE` at `stage<<24 \| id`) = the "header variants 5–11"; members `type, rows, cols, isMatrix, arraySize, index`; struct params (`UnityInstancing_*`, `unity_DOTSVisibleInstances`); bindings kind 0 texture (index, samplerIndex, dim), 1 cbuffer, 2 buffer, 3 UAV, 4 inline sampler (unnamed, state word). All 13,390 PEAK parameter entries (and 19,596 program entries) and all golden ones decode/encode exactly |
| Metal program header | `F00DCAFE,48,7,60,0,0,0,0,0,w9,-1,0` + `xlatMtlMain\0` + MSL (no NUL after the source). `w9` = 39 iff a VS writes `render_target_array_index`, else 37: 0 mispredictions over 486 golden programs |
| Vertex inputs | bind-channel target = 13 + `[[attribute(N)]]` = 13 + SPIR-V Location; sourceMap identical to Vulkan; Metal list sorted by target (648/648 golden channels, 283/283 VS) |
| y-flip | Unity's Vulkan VS ends with a negation of `gl_Position.y` (checked in all 8,399 translated PEAK VS); Unity's Metal VS has none; `--flip-vert-y` cancels it |
| Function constants | From the golden MSL **and** the format strings in `UnityShaderCompiler.exe`: 0 `rp_input_remap_mask`, 1 `rp_output_remap_mask`, 2 `has_framebuffer_fetch`, 3 `has_vrr_api`, 4 `has_base_vertex_instance`, 5 `has_lod_query`. Outputs `[[color(rp_output_remap_N)]]`, `rp_output_remap_N = (mask >> 4N) & 0xF` (golden shows N=0; 4-bit fields inferred from the `& 0xF`) |
| SV_InstanceID / SV_VertexID | Unity Metal subtracts `base_instance`/`base_vertex` under `has_base_vertex_instance` (golden + compiler strings); we emit the same |
| Inline samplers | Unity Metal uses `constexpr sampler` with HLSLcc's exact syntax (golden). State bits: 0-1 filter, 2-7 wrap U/V/W (0 repeat, 1 clamp), bit 8 compare (all 544 PEAK uses of `0x155` are `mode_comparison` in the DXBC), bits 9-11 log2 aniso (golden `0x456` = aniso 4); compare is `greater_equal` (reversed Z, HLSLcc) |
| Framebuffer fetch | Only `Hidden/CoreSRP/CoreCopy` (4 programs). Unity's scheme (compiler strings): fallback texture under `has_no_framebuffer_fetch` (PEAK's own entry names it `hlslcc_fbinput_0`) + `[[color(rp_input_remap_K), function_constant(has_framebuffer_fetch)]]` guarded by `__METAL_VERSION__ >= 230`. **No golden Metal program uses it: unverified on a Mac** |
| Common parameters | Unity merges `m_CommonParameters` into every program of a stage at load. PEAK's progVertex common cbuffers belong to the Vulkan programs (e.g. **all** of `UnityPerMaterial` in 91 passes); we merge them, then empty every stage's common params (the fragment ones are D3D11 registers). Every resulting member offset coincides with a SPIR-V block member offset (0 mismatches) |
| Metal slots | Golden compacts buffers/textures/samplers per stage from 0. We do the same; combined image-samplers share an index. S1: Vulkan sampler bindings up to 25 are a texture+sampler binding space; per-stage compaction gives ≤ 16 samplers everywhere (max is what D3D11 had) – no merging needed |
| Translation vs Unity's own Metal | `golden`: 533 of 550 golden stage pairs match exactly (header, channels, function constants, textures/dims/sampler presence, every uniform Unity binds is bound by us); 24 are stereo-multiview variants (skipped by design); 17 explained (Unity's compiler replaced a VS texture query with a uniform in an editor-only shader; an unused sampler named on MS-texture reads) |
| Depth-compare textures | Unity's HLSLcc declares a texture `depth2d<float, access::sample >` when the DXBC uses it with a comparison sampler (`sample_c`, `sample_c_lz`, `gather4_c`; HLSLcc `decode.cpp` MarkTextureAsShadow, per register; `toMetalDeclaration.cpp`). SPIRV-Cross keeps `texture2d<float>` and wraps every Dref call in `spvDepthCast()`, and the Dref sites are exactly the `sample_c` sites, so the post-pass applies HLSLcc's rule: the texture becomes `depth2d`/`depthcube`/`..._array`, casts are removed, plain reads are widened with `float4(...)` (HLSLcc drops the swizzle there too). Textures used any other way keep the cast (none in PEAK). PEAK: 3,729 stages, 0 casts left. No golden Metal program samples with comparison (0 of 427), so this rests on HLSLcc's source, not a golden diff |
| cbuffer names | Unity's Vulkan globals blocks are `VGlobals<n>` / `PGlobals<n>` (decimal suffix); Unity's Metal programs call them `VGlobals` (VS) and `FGlobals` (FS) (golden: 109 VS / 68 FS parameter entries, no other spelling; layouts differ per shader, so same-name/different-layout is normal for the Metal runtime). `m_NameIndices` never lists them (only `$Globals`). We rename when the name stays unique in the stage (always, in PEAK). The MSL itself has no names (PEAK's SPIR-V is stripped), so only the parameter entries change |
| `half` precision | Evaluated, not adopted. 6,377 of 7,769 PEAK Vulkan programs carry `RelaxedPrecision` (min16float); none use real 16-bit types. Unity's HLSLcc would emit `half` temporaries for those on Metal, but the golden built-ins use no min16float and contain 0 `half` (0 of 427), so nothing can be diffed. SPIRV-Cross 1.4.363 has no MSL option that honours `RelaxedPrecision` (`spirv_msl.cpp` never reads the decoration), and a home-made float→half retyping of SPIR-V is a large unverifiable change. `float` is at least as precise; the cost is GPU speed/registers on Apple GPUs (S10, measure on the Mac) |
| MSL compiles | All golden Unity Metal programs compile under `-std=macos-metal2.1` and newer (217 fail under 2.0: `invariant`), so 2.1 is the default std. Our MSL: all 456 golden translations and all PEAK programs compile (see Status) |
| Serialized files | `repack.save_serialized` reproduces all 56 PEAK serialized files byte-for-byte when unchanged (UnityPy's own `save()` does not: it re-orders and aligns to 8, Unity aligns to 16 and leaves 522 KB of orphan data in `unity_builtin_extra`) |
| Archive | `write_bundle` (LZ4HC **level 12**, 128 KiB blocks, flags 0x243, original node order) re-creates PEAK's `data.unity3d` **byte-for-byte** (1,504,357,874 bytes) from the unmodified data |

## Status on PEAK (this PC)

`pm.py convert --mode both` on the read-only `data.unity3d` (12 Oct 2026, peakmetal 0.2.0, pure-Python SMOL-V,
exit 0, `convert_summary.json` status `ok`, no problems): 275 shaders → 266 ok, 8 empty (no Vulkan variants in
the build: XR/deferred/occlusion debug shaders), 1 unsupported (`Hidden/VR/BlitFromTex2DToTexArraySlice`, the only
geometry stage; its SubShader is emptied so Unity falls back). **8,399/8,400 Vulkan programs** translated, no
warnings; 3,729 stages use `depth2d`; every globals cbuffer renamed. **21 compute shaders, 199/199 kernel
variants** (STP workarounds: 32 sat-INF rewrites, 32 keyword sets redirected to 32-bit kernels). Report:
`tools/nativework/convert_out/` (`cb_members_undescribed` = SPIR-V blocks declare members the parameter entry does
not name, e.g. the full UnityPerDraw layout; identical to what Unity's Vulkan runtime gets, informational). Whole run
(load, translate, compute, loose + LZ4HC archive): **302 s** on this 32-thread PC. `validate` (Metal Developer
Tools for Windows, metal 32023.850, `-std=macos-metal2.1`): **16,373 / 16,373 distinct MSL files compile** (16,174
graphics + 199 compute; 1,724 warnings, all `-Wunused-variable`). The converted archive re-reads with every Shader
Metal-only and every ComputeShader Metal-only, and its nodes equal the loose files byte-for-byte.
`golden` (editor resources): 533 of 550 stage pairs match, 17 explained, 24 stereo-multiview skipped (unchanged by
the depth2d/cbuffer passes). Tests: 128 pass, 4 skip (648 subtests).

## Which output to try first on the Mac (G-C0 / G-C1)

1. **Loose files first.** Copy `DIR/Data/*` into `PEAK Native.app/Contents/Resources/Data/` and make sure
   there is **no** `data.unity3d` there (the player only reads loose files when it is absent). Copy the
   game's `*.resource` files too. Nothing is recompressed; unchanged files are the archive's own bytes.
2. If the player insists on the archive, use `DIR/data.unity3d` (`--mode bundle`, LZ4HC like Unity's; the
   writer is proven exact on the unmodified archive).

## Verified offline vs needs the Mac

Offline (this PC): codec exactness, parameter grammar, conventions vs golden, translation consistency
(MSL slots = parameter entries = bind channels; VS/FS `[[user()]]` interfaces match by name and type),
MSL compilation with Apple's compiler, re-read of every converted shader, archive/loose writers.

Needs the Mac (G-C0/C1): that the player accepts Metal-only shaders injected into Windows data;
rendering correctness (y orientation, depth, sRGB); instancing batch sizes; framebuffer fetch path
(CoreCopy); runtime pipeline compile time (S10); interaction with the Mac player's own `unity default
resources`.

## Open issues and risks

- **Instancing.** `UNITY_RUNTIME_INSTANCING_ARRAY_SIZE` (a Vulkan spec constant) is fixed to
  64 KiB / struct size so the arrays cover any batch Unity's Metal runtime fills (Unity's own Metal
  programs index these arrays through an unbounded pointer). The parameter entries keep Unity's declared
  size (array 2). Check batching on the Mac.
- **Stereo:** multiview variants are skipped (stereo is off); stereo-instancing variants translate.
- **Framebuffer fetch** and **base-vertex** paths follow Unity's compiler strings but have no golden
  program to diff against.
- **depth2d** follows HLSLcc's rule (no golden program to diff). If a shadow map ever showed as black/white on
  the Mac, `translate.Options(depth_textures=False)` restores the old `texture2d` + `spvDepthCast` form.
- **cbuffer names** now match Unity Metal (`VGlobals`/`FGlobals`); `Options(unity_cb_names=False)` restores the
  Vulkan names if the Mac player ever disagrees.
- `half` precision: not adopted (see conventions); performance check on the Mac.
- **Compute:** VFX `Sort` lacks Unity's Metal-only alternate bitonic network (cannot be recreated offline;
  README-compute.md). STP's Metal defines are recreated.
- Unnamed SPIR-V members (`_m0`) are cosmetic (S11).
- Closed in this round: tool discovery is platform-neutral (no `.exe`, Windows or `tools/` paths); `pm.py`
  is the entry point everywhere (the PC venv's `.pth` is a convenience only); `convert` covers graphics + compute
  with one exit code and `convert_summary.json`; `doctor` exists.
