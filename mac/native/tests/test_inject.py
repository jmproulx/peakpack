"""Deliverables 4/5: Metal-only rewrite of whole Shader objects, re-serialization, re-read."""
import UnityPy
from conftest import GOLDEN_UDR_WIN, GOLDEN_UER, need

from peakmetal import inject, repack, translate
from peakmetal.common import params as P
from peakmetal.common import program as G
from peakmetal.common import shader as S


def _convert_file(path, toolchain):
    env = UnityPy.load(need(path))   # fresh copy: we mutate it
    sf = None
    before, reports = {}, {}
    for o in env.objects:
        if o.type.name != "Shader":
            continue
        tt = o.read_typetree()
        if G.PLATFORM_VULKAN not in tt["platforms"]:
            continue
        name = S.shader_name(tt)
        plats = S.load_platforms(tt)
        res = inject.translate_shader(tt, plats, toolchain, translate.Options(msl_version=20100))
        # Vulkan variants that translated must reappear as Metal VS/FS with identical keyword indices
        before[o.path_id] = [(si, pi, st, g, sorted(s["m_KeywordIndices"]), s["m_ShaderRequirements"])
                             for si, pi, st, g, k, s, pb in S.iter_subprograms(tt)
                             if s["m_GpuProgramType"] == 25 and res[(si, pi, s["m_BlobIndex"], pb)].status == "ok"]
        rep = inject.ShaderReport(name)
        inject.build_metal_only(tt, plats, res, rep)
        o.save_typetree(tt)
        reports[o.path_id] = rep
        sf = o.assets_file
    return env, sf, before, reports


def _check_metal_only(tt, before):
    assert tt["platforms"] == [G.PLATFORM_METAL] and tt["stageCounts"] == [2]
    plats = S.load_platforms(tt)
    pb = plats[G.PLATFORM_METAL]
    vs = set()
    for si, pi, st, g, k, s, pbi in S.iter_subprograms(tt):
        t = s["m_GpuProgramType"]
        assert (st, t) in (("progVertex", 23), ("progFragment", 24))
        pe = pb.program(s["m_BlobIndex"])
        assert pe.gpu_type == t
        m = G.decode_metal(pe.data)
        assert m.entry == "xlatMtlMain" and m.header[:4] == [-267531522, 48, 7, 60]
        P.decode(pb.entries[pbi])
        if t == 23:
            vs.add((si, pi, g, tuple(sorted(s["m_KeywordIndices"])), s["m_ShaderRequirements"]))
    # every translated Vulkan variant keeps its keyword indices / requirements on the Metal side
    want = {(si, pi, g, tuple(kw), req) for si, pi, st, g, kw, req in before}
    assert vs == want
    for ss in tt["m_ParsedForm"]["m_SubShaders"]:
        for ps in ss["m_Passes"]:
            for st in S.STAGES:
                assert not any(ps[st]["m_CommonParameters"].values())
            assert set(ps["progVertex"]["m_SerializedKeywordStateMask"]) <= \
                set(ps["progFragment"]["m_SerializedKeywordStateMask"])
    return len(vs), len(want)


def test_inject_default_resources_and_reread(toolchain):
    env, sf, before, reports = _convert_file(GOLDEN_UDR_WIN, toolchain)
    data = repack.save_serialized(sf)
    env2 = UnityPy.load(data)
    n = 0
    for o in env2.objects:
        if o.type.name == "Shader" and o.path_id in before:
            got, want = _check_metal_only(o.read_typetree(), before[o.path_id])
            assert got == want
            n += 1
    assert n == 6


def test_inject_editor_resources(toolchain):
    env, sf, before, reports = _convert_file(GOLDEN_UER, toolchain)
    assert all(r.status in ("ok", "partial") for r in reports.values())
    env2 = UnityPy.load(repack.save_serialized(sf))
    n = 0
    for o in env2.objects:
        if o.type.name == "Shader" and o.path_id in before:
            _check_metal_only(o.read_typetree(), before[o.path_id])
            n += 1
    assert n == 95
