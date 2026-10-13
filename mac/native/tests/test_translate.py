"""Deliverable 3: Vulkan -> Metal translation of PEAK programs, checked for internal consistency
(MSL resource slots == Metal parameter entries == bind channels) and compiled with Apple's compiler when
it is installed. Covers the 9 shaders whose Vulkan sampler bindings reach 25 (S1), the framebuffer-fetch
shader (S3), instancing (UNITY_RUNTIME_INSTANCING_ARRAY_SIZE), inline samplers and the geometry shader (S6)."""
import os
import re
import subprocess

import pytest
from conftest import PEAK_DUMP, iter_dump_dirs, need

from peakmetal import tools, translate, validate
from peakmetal.common import params as P
from peakmetal.common import program as G
from peakmetal.common import shader as S

HEAVY = ("Universal_Render_Pipeline_Lit", "W_Peak_Rock", "W_Peak_Ice", "W_Peak_Glass", "W_Peak_Waterfall",
         "W_Peak_Petrified_Rock", "GD_Water-GD", "_Lava", "Screen_Scanline", "CoreSRP_CoreCopy",
         "SmokeParticleSimple", "VR_BlitFromTex2DToTexArraySlice", "W_Peak_Standard")
PER_SHADER = 6


def _programs():
    need(PEAK_DUMP)
    for name, tt, plats in iter_dump_dirs(PEAK_DUMP):
        if not any(h in name for h in HEAVY) or G.PLATFORM_VULKAN not in plats:
            continue
        vk = plats[G.PLATFORM_VULKAN]
        seen = []
        for si, pi, st, g, k, s, pb in S.iter_subprograms(tt):
            if s["m_GpuProgramType"] == G.SPIRV and (s["m_BlobIndex"], pb) not in seen:
                seen.append((s["m_BlobIndex"], pb))
        for b, pb in seen[:PER_SHADER] + seen[-PER_SHADER:]:
            yield name, vk.program(b), vk.params(pb)


def _sig(msl):
    m = re.search(r"^(?:vertex|fragment) \S+ xlatMtlMain\((.*)\)\s*$", msl, re.M)
    assert m, "no entry point"
    sig = m.group(1)
    return ({int(x) for x in re.findall(r"\[\[buffer\((\d+)\)\]\]", sig)},
            {int(x) for x in re.findall(r"\[\[texture\((\d+)\)", sig)},
            {int(x) for x in re.findall(r"\[\[sampler\((\d+)\)\]\]", sig)})


@pytest.fixture(scope="module")
def results(toolchain):
    out = []
    for name, pe, pp in _programs():
        out.append((name, pe, translate.translate_program(pe, pp, toolchain, translate.Options(msl_version=20100))))
    assert len(out) > 60
    return out


def test_statuses(results):
    for name, pe, r in results:
        if "VR_BlitFromTex2DToTexArraySlice" in name:
            assert r.status == "unsupported" and "geom" in r.reason      # S6: geometry stage -> fallback
        else:
            assert r.status == "ok", (name, r.reason)
            assert not r.warnings, (name, r.warnings)


def test_slots_match_parameter_entries(results):
    for name, pe, r in results:
        for model, st in r.stages.items():
            bufs, texs, smps = _sig(st.msl)
            pb = {b.index for b in st.params.bindings if b.kind in (P.KIND_CBUFFER, P.KIND_BUFFER)}
            pt = {b.index for b in st.params.bindings if b.kind == P.KIND_TEXTURE}
            ps = {b.extra[0] for b in st.params.bindings if b.kind == P.KIND_TEXTURE and b.extra[0] >= 0}
            assert pb == bufs, (name, model)
            assert pt == texs, (name, model)
            assert ps <= smps, (name, model)                  # every texture sampler slot exists in the MSL
            assert all(s < translate.MAX_SAMPLERS for s in smps), (name, model, smps)   # S1
            assert max(bufs, default=0) <= translate.MAX_BUFFER_SLOT
            assert not any(b.kind == P.KIND_SAMPLER for b in st.params.bindings)  # inline -> constexpr
            assert not st.params.cbuffers[0].members                              # spec constants fixed


def test_vertex_conventions(results):
    for name, pe, r in results:
        if r.status != "ok":
            continue
        vs, fs = r.stages["vert"], r.stages["frag"]
        attrs = sorted(int(x) for x in re.findall(r"\[\[attribute\((\d+)\)\]\]", vs.msl))
        assert attrs == sorted(t - 13 for _, t in vs.channels), name
        assert [t for _, t in vs.channels] == sorted(t for _, t in vs.channels)
        assert "[[position, invariant]]" in vs.msl
        assert translate.has_unity_yflip(vs.msl)       # Unity's Vulkan flip, then SPIRV-Cross cancels it
        assert "rp_output_remap_mask [[ function_constant(1) ]]" in fs.msl
        assert re.search(r"\[\[color\(rp_output_remap_0\)\]\]", fs.msl)
        if "instance_id" in vs.msl:
            assert "has_base_vertex_instance [[ function_constant(4) ]]" in vs.msl


def test_framebuffer_fetch(results):
    fb = [r for name, pe, r in results if "CoreSRP_CoreCopy" in name]
    assert fb and all("fbfetch" in r.stages["frag"].features for r in fb)
    for r in fb:
        msl = r.stages["frag"].msl
        assert "rp_input_remap_mask [[ function_constant(0) ]]" in msl
        assert "has_framebuffer_fetch [[ function_constant(2) ]]" in msl
        assert "HLSLCC_FBFETCH(0, " in msl
        assert any(b.name == "hlslcc_fbinput_0" for b in r.stages["frag"].params.bindings)


def test_compile_with_apple_metal(results, tmp_path):
    metal = tools.find_metal()
    if not metal:
        pytest.skip("Apple metal compiler not installed")
    for i, (name, pe, r) in enumerate(results):
        for model, st in r.stages.items():
            f = tmp_path / f"{i}_{model}.metal"
            f.write_text(st.msl, encoding="utf-8")
            for std in (validate.DEFAULT_STD, "metal3.0"):
                p = subprocess.run([metal, "-c", f"-std={std}", "-o", os.devnull if os.name != "nt" else "NUL",
                                    str(f)], capture_output=True, text=True)
                assert p.returncode == 0, (name, model, std, p.stderr[-800:])
