"""Deliverable 2: parameter-entry grammar (all binding kinds, struct params, global block)."""
import collections

from conftest import PEAK_DUMP, iter_dump_dirs, need

from peakmetal.common import params as P


def test_synthetic_roundtrip_all_kinds():
    p = P.Params(
        [P.CBuffer("", 0, [P.Member("UNITY_RUNTIME_INSTANCING_ARRAY_SIZE", 1, 1, 1, 0, 0, 0x04000000)]),
         P.CBuffer("UnityInstancing_PerDraw0", 288, [],
                   [P.Struct("unity_Builtins0Array", 0, 2, 144,
                             [P.Member("unity_ObjectToWorldArray", 0, 4, 4, 1, 0, 0),
                              P.Member("unity_WorldToObjectArray", 0, 4, 4, 1, 0, 64)])]),
         P.CBuffer("UnityPerMaterial", 32, [P.Member("_BaseColor", 0, 1, 4, 0, 0, 0)])],
        [P.Binding("_MainTex", P.KIND_TEXTURE, 0, (-1, 2)),
         P.Binding("UnityPerMaterial", P.KIND_CBUFFER, 1, (0,)),
         P.Binding("unity_ParticleInstanceData", P.KIND_BUFFER, 2, (0,)),
         P.Binding("_xyBufferRW", P.KIND_UAV, 3, (3,)),
         P.Binding("", P.KIND_SAMPLER, 7, (0x155,))])
    b = P.encode(p)
    assert P.decode(b) == p
    assert P.encode(P.decode(b)) == b


def test_peak_param_kinds_census():
    """Every PEAK parameter entry (D3D11 + Vulkan) decodes and re-encodes exactly; record the census the
    earlier prototype could not parse (kinds 2/3/4, struct params, global block = header variants)."""
    need(PEAK_DUMP)
    c = collections.Counter()
    for name, tt, plats in iter_dump_dirs(PEAK_DUMP):
        for p, pb in plats.items():
            for i in pb.param_idx:
                e = pb.entries[i]
                d = P.decode(e)
                assert P.encode(d) == e
                c["entries"] += 1
                for b in d.bindings:
                    c[("kind", b.kind)] += 1
                if d.cbuffers[0].members:
                    c["global_block"] += 1
                if any(cb.structs for cb in d.cbuffers):
                    c["struct"] += 1
    assert c[("kind", 2)] > 0 and c[("kind", 3)] > 0 and c[("kind", 4)] > 0
    assert c["struct"] > 4000 and c["global_block"] > 300


def test_inline_sampler_states_match_golden_and_dxbc():
    """State bits -> MSL constexpr samplers, exactly as Unity's own Metal programs spell them (golden
    uer/000_Unlit_Preview3DVolume and the *_VT previews); 0x155 is a comparison sampler (DXBC
    dcl_sampler mode_comparison on all 544 PEAK uses)."""
    from peakmetal.translate import inline_sampler_msl as f
    assert f("custom_point_clamp_sampler", 0x54) == \
        "constexpr sampler custom_point_clamp_sampler(filter::nearest,address::clamp_to_edge);"
    assert f("custom_linear_clamp_sampler", 0x55) == \
        "constexpr sampler custom_linear_clamp_sampler(filter::linear,mip_filter::nearest,address::clamp_to_edge);"
    assert f("custom_trilinear_clamp_sampler", 0x56) == \
        "constexpr sampler custom_trilinear_clamp_sampler(filter::linear,mip_filter::linear,address::clamp_to_edge);"
    assert f("_vt_cacheSampler_trilinear_clamp_aniso4", 0x456) == (
        "constexpr sampler _vt_cacheSampler_trilinear_clamp_aniso4(filter::linear,mip_filter::linear,"
        "max_anisotropy(4),address::clamp_to_edge);")
    assert f("s", 0x155).startswith("constexpr sampler s(compare_func::greater_equal,filter::linear,")
    assert f("s", 0x0) == "constexpr sampler s(filter::nearest,address::repeat);"
