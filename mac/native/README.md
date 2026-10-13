# peakmetal: PEAK shaders → Metal (Track C, graphics)

`native/peakmetal/` converts every graphics `Shader` in a **copy** of PEAK's data (Unity 6000.3.15f1,
URP 17.3) to Metal-only shaders that Unity's macOS player can load, and writes the game data back
either as loose files or as a repacked `data.unity3d`. It runs on each friend's Mac from their own files
(no derived data leaves the machine). Compute shaders are the compute team's `peakmetal/compute/`
(see `README-compute.md`); `convert` calls it on the same environment.

Requirements: Python 3.11+ with UnityPy 1.25.4 and lz4; `spirv-cross` (Khronos, Vulkan SDK 1.4.363
sources); optionally the native `smolv_decode` (a byte-identical pure-Python SMOL-V decoder is
built in); optionally Apple's `metal` compiler for `validate`.

## Commands

Run from `native\` (on this PC the venv has a `.pth` so `-m` works under `-I`; anywhere else use the
launcher `python -I native/pm.py <command> ...`, which is identical):

```
python -I -m peakmetal inspect   <data.unity3d|serialized file> [--shader NAME [--params]]
python -I -m peakmetal roundtrip <file> [--shader NAME]        # byte-exact codec check
python -I -m peakmetal translate <file> --shader NAME --out DIR # one shader -> MSL + parameter dumps
python -I -m peakmetal golden    <unity editor resources> <unity default resources>
python -I -m peakmetal convert   <PEAK_Data/data.unity3d> --out DIR [--mode loose|bundle|both]
                                 [--packer lz4hc|lz4|none] [--jobs N] [--only NAME] [--no-compute]
python -I -m peakmetal validate  DIR/msl [--metal PATH] [--std macos-metal2.1] [--report FILE]
```

Tool paths: `--bin-dir` or `PEAKMETAL_BIN` (dir with `spirv-cross`, `smolv_decode`),
`PEAKMETAL_SPIRV_CROSS`, `PEAKMETAL_SMOLV_DECODE`, `--metal` / `PEAKMETAL_METAL`. `convert` refuses to
write next to its input, into a Steam library or into a Unity editor install.

`convert` output: `DIR/Data/` (loose files), `DIR/data.unity3d` (bundle), `DIR/msl/<shader>/*.metal`
(every distinct program, for `validate`), `DIR/convert_report.txt|json` (per-shader status).

Tests (pytest; inputs read-only, skip when absent):
`..\tools\venv\Scripts\python.exe -I -m pytest tests -q` (about 3 min). `PEAKMETAL_SLOW=1` adds the
whole-`data.unity3d` tests (object round trip, serialized-file writer, archive rewrite; about 15 min).

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

Pipeline per Vulkan program: SMOL-V → SPIR-V → resource analysis (static use from the entry point) →
merge the pass's progVertex common cbuffers → Metal slot assignment per stage → SPIR-V patch (Binding =
Metal slot, spec constants → constants, Position `Invariant`) → SPIRV-Cross `--msl --msl-version 20100
--msl-decoration-binding` (VS `--flip-vert-y`; FS `--msl-pad-fragment-output`, `--msl-shader-input` to
widen FS inputs to the VS output width) → MSL post-pass (Unity conventions below) → program entries.

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
| MSL compiles | All golden Unity Metal programs compile under `-std=macos-metal2.1` and newer (217 fail under 2.0: `invariant`), so 2.1 is the default std. Our MSL: all 456 golden translations and all PEAK programs compile (see Status) |
| Serialized files | `repack.save_serialized` reproduces all 56 PEAK serialized files byte-for-byte when unchanged (UnityPy's own `save()` does not: it re-orders and aligns to 8, Unity aligns to 16 and leaves 522 KB of orphan data in `unity_builtin_extra`) |
| Archive | `write_bundle` (LZ4HC **level 12**, 128 KiB blocks, flags 0x243, original node order) re-creates PEAK's `data.unity3d` **byte-for-byte** (1,504,357,874 bytes) from the unmodified data |

## Status on PEAK (this PC)

`convert` on a read-only `data.unity3d`: 275 shaders → 266 ok, 8 empty (no Vulkan variants in the
build: XR/deferred/occlusion debug shaders), 1 unsupported (`Hidden/VR/BlitFromTex2DToTexArraySlice`,
the only geometry stage; its SubShader is emptied so Unity falls back). 8,399/8,400 Vulkan programs
translated, no warnings. 21 compute shaders via `peakmetal.compute` (199 kernel variants ok). Report:
`tools/nativework/convert_report.txt` (`cb_members_undescribed` = SPIR-V blocks declare members the
parameter entry does not name, e.g. the full UnityPerDraw layout; identical to what Unity's Vulkan
runtime gets, informational). Whole run (load, translate, compute, loose + LZ4HC archive): ~6 min on
this 32-thread PC. `validate` (Metal Developer Tools for Windows, metal 32023.850,
`-std=macos-metal2.1`): **16,174 / 16,174 distinct MSL programs compile** (1,686 warnings, all
`-Wunused-variable`); the framebuffer-fetch programs also compile under macos-metal2.3/2.4 and
metal3.0/3.2 (fetch path enabled). Every converted shader re-reads as Metal-only from both outputs, and
the archive's nodes equal the loose files byte-for-byte.

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
- **cbuffer names** keep Vulkan's `VGlobals<hash>` / `PGlobals<hash>` (Unity Metal would say
  `VGlobals`/`FGlobals`); the runtime binds by the parameter entries, so this should not matter.
- **Depth-compare textures** are declared `texture2d` and cast with SPIRV-Cross's `spvDepthCast`
  (compiles; Unity declares `depth2d`).
- **Framebuffer fetch** and **base-vertex** paths follow Unity's compiler strings but have no golden
  program to diff against.
- `half` precision: SPIRV-Cross emits `float` everywhere (Unity's HLSLcc may use `half`); correct, maybe
  slower on Apple GPUs.
- Unnamed SPIR-V members (`_m0`) are cosmetic (S11).
- The `.pth` that makes `-m peakmetal` work under `-I` exists only in this PC's venv; the Mac app should
  use `pm.py` or put `native/` on `sys.path`.
