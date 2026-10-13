"""Which game feature each of PEAK's 21 ComputeShaders serves, and the fallback if it can't run.

Sources: Unity 6000.3.15f1 built-in packages (render-pipelines.core 17.3, visualeffectgraph 17.3),
PEAK's decompiled Assembly-CSharp (tools/nativework/compute/kernel_sources.txt and runtime_usage.txt).

``needed_without_grd_stp``: still dispatched when the MacPreset mod has disabled both the GPU Resident
Drawer and STP (upscalingFilter -> Linear).
"""

GRD = "GPU Resident Drawer"
OCC = "GPU occlusion culling (GPU Resident Drawer)"
STP = "STP upscaler"
VFX = "VFX Graph"

FALLBACK_GRD = "MacPreset: disable the GPU Resident Drawer at runtime"
FALLBACK_OCC = "MacPreset: disable GPU occlusion culling, or the whole GPU Resident Drawer"
FALLBACK_STP = "MacPreset: upscalingFilter -> Linear/Auto (URP also falls back to Auto when STP is unsupported)"
FALLBACK_VFX = "none at engine level: affected VFX Graph effects stop simulating/sorting; disable the effect via a mod"

FEATURES = {
    # name: (feature, source, fallback, needed_without_grd_stp, remark)
    "InstanceDataBufferCopyKernels": (GRD, "core GPUDriven", FALLBACK_GRD, False, ""),
    "InstanceDataBufferUploadKernels": (GRD, "core GPUDriven", FALLBACK_GRD, False, ""),
    "InstanceTransformUpdateKernels": (GRD, "core GPUDriven", FALLBACK_GRD, False, ""),
    "InstanceWindDataUpdateKernels": (GRD, "core GPUDriven", FALLBACK_GRD, False, ""),
    "InstanceOcclusionCullingKernels": (OCC, "core GPUDriven", FALLBACK_OCC, False, ""),
    "OccluderDepthPyramidKernels": (OCC, "core GPUDriven", FALLBACK_OCC, False, ""),
    "OcclusionCullingDebug": (OCC + " debug view", "core GPUDriven", FALLBACK_OCC, False, "debug only"),
    "StpSetup": (STP, "core STP", FALLBACK_STP, False,
                 "Unity's Metal build defines STP_FORCE_32BIT_REDUCTION and STP_BUG_SAT_INF; the Vulkan-derived "
                 "kernels lack both (16-bit reduction; relies on INF under fast-math): verify on device"),
    "StpPreTaa": (STP, "core STP", FALLBACK_STP, False, "STP_BUG_SAT_INF not applied (see StpSetup)"),
    "StpTaa": (STP, "core STP", FALLBACK_STP, False, "STP_BUG_SAT_INF not applied (see StpSetup)"),
    "VFXCopyBuffer": (VFX, "visualeffectgraph", FALLBACK_VFX, True, "VFXManager system shader"),
    "VFXPrefixSum": (VFX, "visualeffectgraph", FALLBACK_VFX, True, "VFXManager system shader"),
    "VFXFillIndirectArgs": (VFX, "visualeffectgraph", FALLBACK_VFX, True, "VFXManager system shader"),
    "Sort": (VFX + " particle sorting", "visualeffectgraph", FALLBACK_VFX, True,
             "Unity's Metal build uses USE_ALTERNATE_BITONIC_NETWORK ('BitonicSort128 doesn't behave as "
             "expected' on Metal); the Vulkan-derived kernels use the default network: verify on device"),
    "UpdateStrips": (VFX + " particle strips", "visualeffectgraph", FALLBACK_VFX, True, ""),
    "GenSdfRayMap": (VFX + " SDF baker (MeshToSDFBaker)", "visualeffectgraph", FALLBACK_VFX, True,
                     "no game C# references it; only reachable from VFX assets/tools"),
    "VrsTexture": ("Variable Rate Shading image (URP VRS)", "core VRS",
                   "none needed: URP skips VRS when the device lacks shading-rate-image support (logs an error, full-rate shading)", True,
                   "only dispatched if Unity reports shading-rate-image support on Metal (to verify on device)"),
    "ProbeVolumeSamplingDebugPositionNormal": ("APV probe-sampling debug view", "URP/core ProbeVolume",
                                               "debug only", False, "debug only"),
    "LightVolumeRayTrace": ("PEAK LightVolume bake (level generation)", "PEAK (no source)",
                            "pre-baked light volumes in the shipped levels; only rebaked by the LevelGeneration "
                            "console command / PropGrouper", True, ""),
    "LightVolumeUnifiedRTShader": ("PEAK LightVolume bake (unified ray tracing, compute backend)",
                                   "PEAK / core UnifiedRayTracing", "as LightVolumeRayTrace", True, ""),
    "GrassGeometryCompute": ("PEAK GrassRenderer", "PEAK (no source)", "none needed", False,
                             "dead code in PEAK 2.6.b: GrassRenderer.Render() is never called "
                             "(GrassRenderer.cs:51/84, kernel field never assigned)"),
}

PRIORITY = ["InstanceDataBufferCopyKernels", "InstanceDataBufferUploadKernels", "InstanceTransformUpdateKernels",
            "InstanceWindDataUpdateKernels", "InstanceOcclusionCullingKernels", "OccluderDepthPyramidKernels",
            "OcclusionCullingDebug", "StpSetup", "StpPreTaa", "StpTaa", "Sort", "VFXPrefixSum",
            "VFXFillIndirectArgs", "VFXCopyBuffer", "UpdateStrips", "GenSdfRayMap", "VrsTexture",
            "ProbeVolumeSamplingDebugPositionNormal", "LightVolumeRayTrace", "LightVolumeUnifiedRTShader",
            "GrassGeometryCompute"]


def feature_of(name):
    return FEATURES.get(name, ("unknown", "unknown", "unknown", True, ""))
