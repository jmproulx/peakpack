# Compute shaders

`native/peakmetal/compute/` gives PEAK's 21 `ComputeShader` assets Metal kernels (`targetRenderer` 16),
translated from their Vulkan SPIR-V (`targetRenderer` 21). It uses only the Python standard library plus
`spirv-cross`. UnityPy is needed only by the CLI and by `inject_env` callers.

| Module | Role |
|---|---|
| `codec.py` | Byte-exact decode and encode of the 6000.3 `ComputeShader` object (class 72) |
| `metalblob.py` | Unity's Metal compute `code` blob |
| `spirv.py` | SPIR-V reader: resources, LocalSize, feature census, Binding/DescriptorSet patching |
| `translate.py` | Vulkan variant to Metal variant: slots, MSL, reflection, constant buffers |
| `convert.py` | Per-shader conversion, UnityPy injection, the report, and the CLI |
| `validate.py` | Offline `metal.exe` compile hook. Skips when the Metal Developer Tools are absent |
| `features.py` | Game feature, fallback and priority for each shader |
| `metalfix.py` | Metal-only behaviour Unity compiles into STP, recreated on the Vulkan-derived kernels |

Run it (normally through `pm.py convert`, which converts graphics and compute in one pass; standalone:)

```
tools\venv\Scripts\python.exe -I -c "import sys; sys.path.insert(0, r'native'); from peakmetal.compute import convert; sys.exit(convert.main())" <data.unity3d> --out tools\nativework\compute\out --validate
```

The input is opened read-only. The CLI refuses to write its output inside the input folder, under
`steamapps`, or into the Unity install.

Tests: `tools\venv\Scripts\python.exe -I -m unittest discover -s native\tests -p "test_compute*.py" -v`.
They need the Mac and Windows golden `unity default resources` files and the dumps in
`tools\nativework\compute\peak\`.

## Unity's Metal compute encoding (proven against the golden references)

The golden references come from the 6000.3.15f1 macOS arm64 player's `unity default resources`:
Internal-Skinning, Internal-BlendShape, Internal-VT-TranslationTableReplace and Internal-VT-TranslationTableUpsample,
66 Metal kernels in all. The same four shaders appear with Vulkan variants in PEAK's Windows `unity default resources`.
`unity_builtin_extra` and `unity editor resources` contain no Metal compute shaders.

- **Object.** `ComputeShaderPlatformVariant` v2, `KernelParent` v3, `Kernel` v2. The layout is in the
  `codec.py` docstring. Strings and the `code` byte vector are 4-byte aligned. Each kernel parent holds
  `uniqueVariants`, and `variantIndices` maps a keyword string to the index of a unique variant.
- **`code` blob.** The layout is `u32 0xDEADCAFE`, `u32 2`, `u32 20` (source offset), `u16 tgX, tgY, tgZ`,
  `u16 1`, then MSL and one terminating `\0`. The entry point is `kernel void computeMain(...)`; the blob stores no
  entry name. The threadgroup size appears both here and in `threadGroupSize`. `targetLevel` is 0.
- **Slots.** Unity's HLSLcc `BindingSlotAllocator` assigns them as follows:
  1. Each UAV is reserved at its HLSL `u` register. Buffer UAVs go in the buffer space and texture UAVs in the texture space.
  2. Constant buffers then take the lowest free buffer slot, in register order.
  3. SRVs come next, in register order: buffers take buffer slots and textures take texture slots.
  
  On Vulkan the `u` register survives in SPIR-V names as `*_origX<n>X`.
  The Vulkan `bindPoint` is `binding | set << 16 | flags`, where the flags sit in bits 23 to 31.
- **Reflection.** The `cbs`, `textures`, `inBuffers` and `outBuffers` entries keep Vulkan's names, order,
  `texDimension` and `resType`. `bindPoint` becomes the Metal slot and `samplerBindPoint` is -1.
  `requirements` and `cbVariantIndices` are copied unchanged.
- **Constant buffers.** `$Globals` is `CGlobals` on Vulkan and `Globals` on Metal. Params are sorted by offset.
  Their types come from the SPIR-V member type, because Vulkan reflection reports uint as int:
  0 float, 1 int, 2 bool, 3 half, 4 short, 5 uint. `byteSize` and the offsets equal Vulkan's.
  SPIRV-Cross honours the SPIR-V `Offset` decorations, so the MSL struct layout matches.
- **Inline samplers.** Each entry in `builtinSamplers` (for example `sampler_PointClamp`, state `0x54`) becomes a
  `constexpr sampler` in the MSL with HLSLcc's wording, and is not reflected. The state bits decode as filter (bits 0–1)
  and wrap U/V/W (bits 2–7).
- **Typed buffers.** `RWBuffer<T>` (a SPIR-V texel buffer) becomes `device T*` in the buffer space,
  as HLSLcc does it.
- **Append/consume counters** (by HLSLcc source; no golden example exists). The counter takes the first free buffer slot
  after all other resources. The owner's `bindPoint` becomes `slot | (counterSlot + 1) << 16`, and the separate
  Vulkan `*_counterBuf` reflection entry is dropped.

**Proof.** `tests/test_compute_golden.py` translates the four golden Vulkan shaders and compares the
result with Unity's own Metal variants. Every field matches exactly apart from the MSL text: all reflection entries,
bind points, entry order, constant buffers (names, types, order, sizes), threadgroup sizes and requirements.
With Unity's own code blobs substituted, the encoded object is byte-identical to the golden one.

## Status on PEAK (see `tools\nativework\compute\compute_report.txt`)

- **Translation.** All 199 Vulkan kernel variants across the 21 shaders translate, and all 199 compile with
  `metal -std=macos-metal2.1`, `metal3.0` and `metal3.1`. On older standards, one OccluderDepthPyramid variant fails with
  `macos-metal1.2`/`2.0`.
- **Features used.**
  - No kernel uses subgroup or wave ops, image atomics or `OpArrayLength`.
  - Buffer atomics (`InterlockedAdd`/`Min`) map to Metal `atomic_*` functions.
  - Two kernels use `read_write` textures: OccluderDepthPyramid `_DstDepth` (R32Float, tier 1) and LightVolume `lightMap`
    (RGBA32Float, tier 2). M1 supports both.
- **Fallback.** If a kernel ever fails, the injector puts in a no-op stub kernel, so `FindKernel` and `Dispatch` still work.
  The report then names the fallback: the MacPreset mod can disable the GPU Resident Drawer and STP.
- **Still dispatched with both GRD and STP disabled.** The VFX Graph system shaders (Sort, VFXPrefixSum,
  VFXFillIndirectArgs, VFXCopyBuffer, UpdateStrips), GenSdfRayMap, VrsTexture (only if the device reports VRS)
  and PEAK's LightVolume bakers (only on a rebake). GrassGeometryCompute is dead code in PEAK 2.6.b.

## Metal-only shader code, recreated offline (`metalfix.py`)

Unity's Mac build compiles some compute shaders with `SHADER_API_METAL` branches that the Vulkan build (our
source) does not have. Sources: the URP/core and VFX Graph packages shipped with the 6000.3.15f1 editor.

- **STP_BUG_SAT_INF: done.** `StpCommon.hlsl` defines it on Metal because fast-math (Metal's default) has no
  INF. Without it, STP computes `StpGtZero(x) = saturate(x * +INF)` and `StpSigned(x) = saturate(x * -INF)`.
  With it, they become `(x > 0) ? 1 : 0` and `(x < 0) ? 1 : 0`. `fix_sat_inf` rewrites exactly the multiply by a
  literal ±INF whose only use is a `[0, 1]` clamp. It handles both MSL shapes: the HLSLcc-style statement pair
  in the 32-bit variants, and the inline `fast::clamp(e * as_type<float>(0xff800000u), 0.0, 1.0)` in the 16-bit
  ones. In PEAK it fires only in StpSetup: 32 of 32 variants, one site each. No ±INF literal remains. Every
  rewritten kernel compiles. It runs on every kernel; nothing else matches.
- **STP_FORCE_32BIT_REDUCTION: done, by picking an existing kernel.** On desktop Metal, StpSetup keeps a
  32-bit reduction even in its 16-bit build. The Vulkan build has no such kernel. `force_32bit` therefore
  points each keyword set that contains `UNITY_DEVICE_SUPPORTS_NATIVE_16BIT` at the 32-bit kernel of the same
  set (the `STP_32BIT` variant). That variant is full precision throughout, so it also has the 32-bit
  reduction. This applies to StpSetup, StpPreTaa and StpTaa, 32 keyword sets in all. It also keeps the half-precision
  ±INF constants (`STP_INFP_H`) off the Mac. The cost is that STP runs at fp32 on Apple GPUs. The unused
  16-bit kernels stay in the data, so the indices are stable.
- **VFX Sort, USE_ALTERNATE_BITONIC_NETWORK: not fixable offline; needs the Mac.** `Sort.compute` enables a
  different bitonic network on Metal, because "BitonicSort128 doesn't behave as expected, actual cause isn't
  identified yet". The alternate network changes the algorithm: when `subStep == step`, it adds
  `index1 += step - 2*lsb - 1` and sets `reverse = false`. The network is compiled out of every non-Metal
  build. No PEAK kernel, variant or keyword contains it: the Vulkan `Sort` has 12 kernels, each with one
  variant and no keywords. Recreating it means hand-rewriting the sort loop in 10 HLSLcc-shaped kernels, with
  no golden output to check the result against. The underlying bug is unexplained and may be specific to
  HLSLcc's Metal output, which we do not use. Both networks sort correctly in principle. So the action is a
  G-C1 check: watch sorted transparent VFX for flicker or wrong order. `features.py` lists the fallback, which
  is to disable sorting or the effect.
- **Fast math:** MSL 2.1 has no per-file fast-math switch. SPIRV-Cross's `#pragma metal fp math_mode` needs
  MSL 3.2, and Unity's runtime chooses `MTLCompileOptions`. With the STP rewrite above, the only kernels known
  to depend on INF behave the same with fast math on or off.

## Risks to check on a Mac

- VFX particle sorting (`Sort` without Unity's alternate bitonic network on Metal; see above).
- Nothing has been loaded by a real Mac player yet.
- The player's runtime fast-math setting is not confirmed offline (it no longer matters for STP).
