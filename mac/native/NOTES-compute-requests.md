# Compute team: requests to and from the graphics team

## Open (compute -> graphics)

1. **MSL language standard.** Translated compute MSL is generated with SPIRV-Cross `--msl-version 20100`
   and validated with `metal -c -std=macos-metal2.1`. All 199 PEAK kernel variants also compile with
   `metal3.0`/`metal3.1`. When you settle the `-std` that matches Unity 6000.3's Mac player (runtime
   `MTLCompileOptions.languageVersion`), note it here and I'll switch `translate.DEFAULT_MSL_VERSION`
   and `validate.DEFAULT_STD` to it. Also useful: whether the player compiles with fast-math on (STP's Metal
   build relies on `STP_BUG_SAT_INF`, which the Vulkan-derived kernels lack).
2. **Assembly.** `peakmetal.compute.convert.inject_env(env, spirv_cross)` rewrites every ComputeShader of a
   UnityPy environment *in memory* (Metal-only variants, like Unity's Mac build) and returns the touched
   serialized files. Call it on the same environment you inject graphics shaders into, then save once.
   The 21 PEAK ComputeShaders live in `globalgamemanagers.assets` (18), `sharedassets1.assets` (2) and
   `sharedassets4.assets` (1).
3. **No `common\` helpers needed yet.** The compute package has its own SPIR-V reader (`compute/spirv.py`,
   pure Python, also patches Binding/DescriptorSet decorations). Feel free to reuse it.

## Graphics -> compute (answers)

- **Item 1 (MSL std): `macos-metal2.1`, SPIRV-Cross `--msl-version 20100`.** Evidence: all 427 distinct golden
  Metal programs Unity itself generated (editor `unity editor resources` + `unity default resources`) compile
  with Apple metal 32023.850 under every std from `macos-metal2.1` up to `metal3.2`, and 217 fail under
  `macos-metal2.0` (`[[ invariant ]]` needs 2.1). Unity's compiler also emits `#if __METAL_VERSION__ >= 230`
  guards (UnityShaderCompiler.exe strings), i.e. it expects to be compiled below 2.3 on some targets. The
  graphics `validate` command uses `-std=macos-metal2.1` by default (`--std` overrides). Report:
  tools/nativework/metalstd/report.txt.
- **Fast math:** no offline evidence of the player's `MTLCompileOptions.fastMathEnabled` (Metal's default is
  YES). Validate both ways if a kernel is sensitive; we'll confirm at G-C1 on the Mac.
- **Item 2 (assembly):** ack. `python -I -m peakmetal convert` will call
  `peakmetal.compute.convert.inject_env(env, spirv_cross)` on the same UnityPy environment before saving,
  when importable (skip with `--no-compute`).

## Closed

- Item 1: compute already uses `--msl-version 20100` / `-std=macos-metal2.1` (translate.DEFAULT_MSL_VERSION,
  validate.DEFAULT_STD). All 199 PEAK kernel variants pass at macos-metal2.1, metal3.0 and metal3.1.
  Fast-math sensitivity (STP_BUG_SAT_INF) stays an on-device check at G-C1.
