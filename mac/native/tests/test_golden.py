"""Regression against Unity's own Metal programs (editor golden files with Vulkan + Metal of the same
shaders): conventions proved on the golden data, and our Vulkan->Metal translation diffed against them."""
import re

import pytest
from conftest import GOLDEN_UDR_WIN, GOLDEN_UER, shaders

from peakmetal import golden, translate
from peakmetal.common import program as G
from peakmetal.common import shader as S


def _metal_programs(path):
    for o, tt, plats in shaders(path):
        if G.PLATFORM_METAL in plats:
            pb = plats[G.PLATFORM_METAL]
            for i in sorted(pb.program_idx):
                yield tt, pb.program(i)


@pytest.mark.parametrize("path", [GOLDEN_UDR_WIN, GOLDEN_UER])
def test_metal_header_rule(path):
    n = 0
    for tt, pe in _metal_programs(path):
        m = G.decode_metal(pe.data)
        layer = pe.gpu_type == G.METAL_VS and "render_target_array_index" in m.source
        assert m.header == [-267531522, 48, 7, 60, 0, 0, 0, 0, 0, 39 if layer else 37, -1, 0]
        assert m.entry == "xlatMtlMain"
        n += 1
    assert n > 50


@pytest.mark.parametrize("path", [GOLDEN_UDR_WIN, GOLDEN_UER])
def test_vertex_channel_rule(path):
    """Metal VS bind channels are sorted by target and target - 13 == [[ attribute(N) ]]."""
    for tt, pe in _metal_programs(path):
        if pe.gpu_type != G.METAL_VS:
            assert pe.channels == [] and pe.source_map == 0
            continue
        src = G.decode_metal(pe.data).source
        attrs = sorted(int(x) for x in re.findall(r"\[\[ attribute\((\d+)\) \]\]", src))
        assert [t for _, t in pe.channels] == sorted(t for _, t in pe.channels)
        assert attrs == sorted(t - G.CHANNEL_TARGET_ATTRIB0 for _, t in pe.channels)


@pytest.mark.parametrize("path", [GOLDEN_UDR_WIN, GOLDEN_UER])
def test_translation_matches_unity_metal(path, toolchain):
    rows = []
    for o, tt, plats in shaders(path):
        if not plats:
            continue
        rows += list(golden.compare_shader(tt, plats, toolchain, translate.Options(msl_version=20100)))
    c, kinds = golden.summarize(rows)
    # exact structural match except: stereo multiview variants (unsupported by design, stereo is off), the
    # editor-only Scene View "Show Mips" VS (Unity's Metal compiler replaced a texture query by a uniform)
    # and FrameDebugger MS-texture reads (our parameter entry also names an unused sampler)
    bad = golden.unexplained(rows) + [r for r in rows if r["status"] == "error"]
    assert not bad, bad[:5]
    unsupported = [r for r in rows if r["status"] != "ok"]
    assert all("multiview" in r["reason"] for r in unsupported)
    assert c["match"] >= (400 if path == GOLDEN_UER else 90)
