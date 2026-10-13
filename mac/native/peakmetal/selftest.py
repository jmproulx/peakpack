"""Built-in synthetic self-test: needs no game or Unity data (the SPIR-V below is hand-assembled here, MIT).

A tiny Unity-style Vulkan program (vertex: one cbuffer `VGlobals<n>`, two attributes, Unity's trailing
`gl_Position.y = -gl_Position.y`; fragment: a depth-compare sample of `_ShadowTex` plus a normal sample of
`_MainTex`, and a plain sample of `_ShadowTex`) goes through the real pipeline (translate_modules -> MSL post-pass -> parameter entries ->
Metal program entry encode/decode). Used by `pm.py doctor` and the tests.
"""
import struct

from . import translate
from .common import params as P
from .common import program as G

# opcodes / enums (SPIR-V 1.0)
_OP = dict(Name=5, MemoryModel=14, EntryPoint=15, ExecutionMode=16, Capability=17, TypeVoid=19, TypeInt=21,
           TypeFloat=22, TypeVector=23, TypeImage=25, TypeSampler=26, TypeSampledImage=27, TypeStruct=30,
           TypePointer=32, TypeFunction=33, Constant=43, Function=54, FunctionEnd=56, Variable=59, Load=61,
           Store=62, AccessChain=65, Decorate=71, MemberDecorate=72, CompositeConstruct=80, CompositeExtract=81,
           SampledImage=86, ImageSampleImplicitLod=87, ImageSampleDrefExplicitLod=90, FNegate=127, FMul=133,
           VectorTimesScalar=142, FAdd=129, Label=248, Return=253)
_BLOCK, _BUILTIN, _LOCATION, _BINDING, _SET, _OFFSET = 2, 11, 30, 33, 34, 35
_UC, _IN, _UNI, _OUT = 0, 1, 2, 3
CB_NAME = "VGlobals1234567890"


class _Asm:
    def __init__(self):
        self.words, self.next = [], 1

    def id(self):
        self.next += 1
        return self.next - 1

    def op(self, name, *operands):
        ops = []
        for o in operands:
            if isinstance(o, str):
                b = o.encode() + b"\0"
                b += b"\0" * (-len(b) % 4)
                ops += list(struct.unpack(f"<{len(b) // 4}I", b))
            else:
                ops.append(o & 0xFFFFFFFF)
        self.words += [((1 + len(ops)) << 16) | _OP[name], *ops]

    def bytes(self):
        return struct.pack(f"<{5 + len(self.words)}I", 0x07230203, 0x00010000, 0, self.next, 0, *self.words)

    def f32(self, x):
        return struct.unpack("<I", struct.pack("<f", x))[0]


def _vertex():
    a = _Asm()
    main, void, fn, f, v2, v4, i32 = (a.id() for _ in range(7))
    st, p_st, ubo, p_in4, p_in2, p_out4, p_out2, p_outf, p_ubo4 = (a.id() for _ in range(9))
    in_pos, in_uv, out_pos, out_uv, c0, c1 = (a.id() for _ in range(6))
    a.op("Capability", 1)
    a.op("MemoryModel", 0, 1)
    a.op("EntryPoint", 0, main, "main", in_pos, in_uv, out_pos, out_uv)
    a.op("Decorate", in_pos, _LOCATION, 0)
    a.op("Decorate", in_uv, _LOCATION, 1)
    a.op("Decorate", out_uv, _LOCATION, 0)
    a.op("Decorate", out_pos, _BUILTIN, 0)
    a.op("Decorate", st, _BLOCK)
    a.op("MemberDecorate", st, 0, _OFFSET, 0)
    a.op("Decorate", ubo, _SET, 0)
    a.op("Decorate", ubo, _BINDING, 0)
    a.op("TypeVoid", void)
    a.op("TypeFunction", fn, void)
    a.op("TypeFloat", f, 32)
    a.op("TypeVector", v2, f, 2)
    a.op("TypeVector", v4, f, 4)
    a.op("TypeInt", i32, 32, 1)
    a.op("Constant", i32, c0, 0)
    a.op("Constant", i32, c1, 1)
    a.op("TypeStruct", st, v4)
    a.op("TypePointer", p_st, _UNI, st)
    a.op("TypePointer", p_ubo4, _UNI, v4)
    a.op("TypePointer", p_in4, _IN, v4)
    a.op("TypePointer", p_in2, _IN, v2)
    a.op("TypePointer", p_out4, _OUT, v4)
    a.op("TypePointer", p_out2, _OUT, v2)
    a.op("TypePointer", p_outf, _OUT, f)
    a.op("Variable", p_st, ubo, _UNI)
    a.op("Variable", p_in4, in_pos, _IN)
    a.op("Variable", p_in2, in_uv, _IN)
    a.op("Variable", p_out4, out_pos, _OUT)
    a.op("Variable", p_out2, out_uv, _OUT)
    lab, pos, sp_, scale, prod, uv, py, ny, ypt = (a.id() for _ in range(9))
    a.op("Function", void, main, 0, fn)
    a.op("Label", lab)
    a.op("Load", v4, pos, in_pos)
    a.op("AccessChain", p_ubo4, sp_, ubo, c0)
    a.op("Load", v4, scale, sp_)
    a.op("FMul", v4, prod, pos, scale)
    a.op("Store", out_pos, prod)
    a.op("Load", v2, uv, in_uv)
    a.op("Store", out_uv, uv)
    a.op("AccessChain", p_outf, ypt, out_pos, c1)          # Unity's Vulkan VS: gl_Position.y = -gl_Position.y
    a.op("Load", f, py, ypt)
    a.op("FNegate", f, ny, py)
    a.op("Store", ypt, ny)
    a.op("Return")
    a.op("FunctionEnd")
    return a.bytes()


def _fragment():
    a = _Asm()
    main, void, fn, f, v2, v4, img, smp, simg = (a.id() for _ in range(9))
    p_img, p_smp, p_in2, p_out4, shadow, maintex, sampler, in_uv, out_col, half, zero = (a.id() for _ in range(11))
    a.op("Capability", 1)
    a.op("MemoryModel", 0, 1)
    a.op("EntryPoint", 4, main, "main", in_uv, out_col)
    a.op("ExecutionMode", main, 7)                          # OriginUpperLeft
    a.op("Decorate", in_uv, _LOCATION, 0)
    a.op("Decorate", out_col, _LOCATION, 0)
    for var, binding in ((shadow, 1), (maintex, 3), (sampler, 2)):
        a.op("Decorate", var, _SET, 0)
        a.op("Decorate", var, _BINDING, binding)
    a.op("TypeVoid", void)
    a.op("TypeFunction", fn, void)
    a.op("TypeFloat", f, 32)
    a.op("TypeVector", v2, f, 2)
    a.op("TypeVector", v4, f, 4)
    a.op("TypeImage", img, f, 1, 0, 0, 0, 1, 0)            # 2D, Depth=0 (as Unity's Vulkan programs), sampled
    a.op("TypeSampler", smp)
    a.op("TypeSampledImage", simg, img)
    a.op("TypePointer", p_img, _UC, img)
    a.op("TypePointer", p_smp, _UC, smp)
    a.op("TypePointer", p_in2, _IN, v2)
    a.op("TypePointer", p_out4, _OUT, v4)
    a.op("Constant", f, half, a.f32(0.5))
    a.op("Constant", f, zero, a.f32(0.0))
    a.op("Variable", p_img, shadow, _UC)
    a.op("Variable", p_img, maintex, _UC)
    a.op("Variable", p_smp, sampler, _UC)
    a.op("Variable", p_in2, in_uv, _IN)
    a.op("Variable", p_out4, out_col, _OUT)
    lab, uv, t0, s0, si0, d, t1, si1, c, out, c2, csum = (a.id() for _ in range(12))
    a.op("Function", void, main, 0, fn)
    a.op("Label", lab)
    a.op("Load", v2, uv, in_uv)
    a.op("Load", img, t0, shadow)
    a.op("Load", smp, s0, sampler)
    a.op("SampledImage", simg, si0, t0, s0)
    a.op("ImageSampleDrefExplicitLod", f, d, si0, uv, half, 2, zero)     # SampleCmpLevelZero
    a.op("Load", img, t1, maintex)
    a.op("SampledImage", simg, si1, t1, s0)
    a.op("ImageSampleImplicitLod", v4, c, si1, uv)
    a.op("ImageSampleImplicitLod", v4, c2, si0, uv)                       # plain sample of the depth texture
    a.op("FAdd", v4, csum, c, c2)
    a.op("VectorTimesScalar", v4, out, csum, d)
    a.op("Store", out_col, out)
    a.op("Return")
    a.op("FunctionEnd")
    return a.bytes()


def synthetic_program():
    """(spirv modules, Vulkan program entry, Vulkan parameter entry) of the synthetic program."""
    pe = G.ProgramEntry(G.SPIRV, (0, 0, 0, 0), [], b"", source_map=0x9, channels=[(0, 13), (3, 14)])
    vkp = P.Params([P.CBuffer("", 0), P.CBuffer(CB_NAME, 16, [P.Member("_Scale", 0, 1, 4, 0, 0, 0)])], [
        P.Binding(CB_NAME, P.KIND_CBUFFER, 0, (0,)),
        P.Binding("_ShadowTex", P.KIND_TEXTURE, 1, (2, 2)),
        P.Binding("_MainTex", P.KIND_TEXTURE, 3, (2, 2)),
    ])
    return [_vertex(), _fragment()], pe, vkp


def run(tc, metal=None):
    """Translate the synthetic program. Returns (checks: list of (name, ok, detail), ProgramResult)."""
    spvs, pe, vkp = synthetic_program()
    r = translate.translate_modules(spvs, pe, vkp, tc, translate.Options())
    checks = [("translate", r.status == "ok" and not r.warnings, r.reason or "; ".join(r.warnings))]
    if r.status != "ok":
        return checks, r
    vs, fs = r.stages["vert"], r.stages["frag"]
    checks += [
        ("entry point xlatMtlMain", "vertex xlatMtlMain_out xlatMtlMain(" in vs.msl
         and "fragment xlatMtlMain_out xlatMtlMain(" in fs.msl, ""),
        ("position invariant", "[[position, invariant]]" in vs.msl.replace(" ", "").replace(",invariant", ", invariant"),
         ""),
        ("y-flip cancelled", "Invert Y-axis for Metal" in vs.msl, ""),
        ("attributes = locations", "[[attribute(0)]]" in vs.msl and "[[attribute(1)]]" in vs.msl
         and vs.channels == [(0, 13), (3, 14)], ""),
        ("cbuffer VGlobals<n> -> VGlobals", [c.name for c in vs.params.cbuffers[1:]] == ["VGlobals"]
         and any(b.name == "VGlobals" and b.kind == P.KIND_CBUFFER for b in vs.params.bindings), ""),
        ("rp_output_remap", "[[color(rp_output_remap_0)]]" in fs.msl, ""),
        ("depth-compare texture -> depth2d", "depth2d<float>" in fs.msl and "spvDepthCast" not in fs.msl
         and ".sample_compare(" in fs.msl and "float4(_" in fs.msl, ""),
        ("textures + sampler slots", sorted((b.name, b.index, b.extra) for b in fs.params.bindings
                                            if b.kind == P.KIND_TEXTURE)
         == [("_MainTex", 1, (0, 2)), ("_ShadowTex", 0, (0, 2))], ""),
    ]
    for model, st in (("vert", vs), ("frag", fs)):
        mp = G.MetalProgram([-267531522, 48, 7, 60, 0, 0, 0, 0, 0, st.header_word9, -1, 0], "xlatMtlMain", st.msl)
        back = G.decode_metal(G.encode_metal(mp))
        checks.append((f"{model} Metal program round trip", back.source == st.msl and back.entry == "xlatMtlMain",
                       ""))
    if metal:
        import os
        import subprocess
        import tempfile
        with tempfile.TemporaryDirectory(prefix="pm_selftest_") as td:
            for model, st in (("vert", vs), ("frag", fs)):
                src = os.path.join(td, model + ".metal")
                with open(src, "w", encoding="utf-8", newline="\n") as fh:
                    fh.write(st.msl)
                p = subprocess.run([metal, "-c", "-std=macos-metal2.1", "-o", os.path.join(td, model + ".air"), src],
                                   capture_output=True, text=True)
                checks.append((f"{model} compiles (metal -std=macos-metal2.1)", p.returncode == 0,
                               p.stderr.strip()[-300:]))
    return checks, r

