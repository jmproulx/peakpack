"""Fidelity passes: depth-compare textures -> depth2d, Unity's VGlobals/FGlobals cbuffer names, and the compute
Metal workarounds (STP_BUG_SAT_INF rewrite, STP_FORCE_32BIT_REDUCTION keyword redirect)."""
import os
import re
import subprocess

import pytest
from conftest import WORK

from peakmetal import tools, translate
from peakmetal.common import params as P
from peakmetal.compute import metalfix

_HEAD = "#include <metal_stdlib>\nusing namespace metal;\n\n" + "".join(
    f"template <typename T>\nstatic inline {d}<T> spvDepthCast({t}<T> t)\n{{\n"
    f"    return reinterpret_cast<thread const {d}<T> &>(t);\n}}\n\n"
    for d, t in (("depth2d", "texture2d"), ("depthcube", "texturecube")))


def _fs(params, body):
    return (_HEAD + f"fragment xlatMtlMain_out xlatMtlMain(xlatMtlMain_in in [[stage_in]], {params})\n{{\n"
            f"    xlatMtlMain_out out = {{}};\n{body}\n    return out;\n}}\n")


def test_depth_texture_rewrite():
    msl = _fs("texture2d<float> _5 [[texture(0)]], sampler _6 [[sampler(0)]]",
              "    float d = spvDepthCast(_5).sample_compare(_6, in.uv, 0.5);\n"
              "    float4 c = _5.sample(_6, in.uv);\n    uint w = _5.get_width();")
    f = set()
    out = translate.depth_textures(msl, f)
    assert "depth2d<float> _5 [[texture(0)]]" in out and "spvDepthCast" not in out
    assert "_5.sample_compare(" in out and "float4(_5.sample(_6, in.uv))" in out and "_5.get_width()" in out
    assert f == {"depth_texture"}


def test_depth_texture_kept_when_used_otherwise():
    msl = _fs("texture2d<float> _5 [[texture(0)]], texturecube<float> _7 [[texture(1)]], sampler _6 [[sampler(0)]]",
              "    float d = spvDepthCast(_5).sample_compare(_6, in.uv, 0.5);\n"
              "    float4 g = _5.gather(_6, in.uv, int2(0), component::y);\n"
              "    float e = spvDepthCast(_7).sample_compare(_6, in.dir, 0.5);")
    out = translate.depth_textures(msl, set())
    assert "texture2d<float> _5" in out and "spvDepthCast(_5)" in out          # gather: unchanged
    assert "depthcube<float> _7" in out and "spvDepthCast(_7)" not in out
    assert "static inline depth2d<T> spvDepthCast" in out                      # helper still needed


def test_cb_renames():
    B = P.Binding
    assert translate._cb_renames([B("VGlobals123", 1, 0), B("UnityPerDraw", 1, 1)]) == {"VGlobals123": "VGlobals"}
    assert translate._cb_renames([B("PGlobals9", 1, 0)]) == {"PGlobals9": "FGlobals"}
    assert translate._cb_renames([B("VGlobals1", 1, 0), B("VGlobals2", 1, 1)]) == {}        # would collide
    assert translate._cb_renames([B("VGlobals1", 1, 0), B("VGlobals", 1, 1)]) == {}
    assert translate._cb_renames([None, B("VGlobalsX", 1, 0)]) == {}


def test_sat_inf_statement_form():
    src = ("    u_xlat7 = a + b;\n    u_xlat7 *= as_type<float>(-8388608);\n    u_xlat9 = 2.0;\n"
           "    u_xlat7 = fast::clamp(u_xlat7, 0.0, 1.0);\n    o = u_xlat7;\n"
           "    v.x *= as_type<float>(2139095040);\n    v.x = fast::clamp(v.x, 0.0, 1.0);\n")
    out, n = metalfix.fix_sat_inf(src)
    assert n == 2 and "as_type<float>" not in out and "fast::clamp" not in out
    assert "u_xlat7 = ((u_xlat7) < 0.0 ? 1.0 : 0.0);" in out and "v.x = ((v.x) > 0.0 ? 1.0 : 0.0);" in out
    assert out.index("u_xlat9 = 2.0;") > out.index("u_xlat7 = ((u_xlat7)")


def test_sat_inf_left_alone_when_product_is_reused():
    src = "    u *= as_type<float>(-8388608);\n    w = u * 2.0;\n    u = fast::clamp(u, 0.0, 1.0);\n"
    assert metalfix.fix_sat_inf(src) == (src, 0)


def test_sat_inf_inline_form():
    src = ("float a = fast::clamp((precise::max(abs(p.x), abs(p.y)) - 1.0) * as_type<float>(0xff800000u /* -inf */), "
           "0.0, 1.0); float b = fast::clamp(x, 0.0, 1.0);")
    out, n = metalfix.fix_sat_inf(src)
    assert n == 1 and "0xff800000u" not in out and "fast::clamp(x, 0.0, 1.0)" in out
    assert "(((precise::max(abs(p.x), abs(p.y)) - 1.0)) < 0.0 ? 1.0 : 0.0)" in out


def test_force_32bit_redirect():
    k = {"name": "StpSetup", "variantIndices": [("", 0), ("UNITY_DEVICE_SUPPORTS_NATIVE_16BIT", 1),
                                                ("A", 2), ("A UNITY_DEVICE_SUPPORTS_NATIVE_16BIT B", 3), ("A B", 4)]}
    ch = metalfix.force_32bit("StpSetup", [k])
    assert dict(k["variantIndices"]) == {"": 0, "UNITY_DEVICE_SUPPORTS_NATIVE_16BIT": 0, "A": 2,
                                         "A UNITY_DEVICE_SUPPORTS_NATIVE_16BIT B": 4, "A B": 4}
    assert len(ch) == 2 and metalfix.force_32bit("Sort", [k]) == []


STP_RAW = os.path.join(WORK, "compute", "peak", "StpSetup.raw")


def test_stp_setup_on_peak_data():
    if not os.path.isfile(STP_RAW):
        pytest.skip("PEAK compute dumps absent")
    from peakmetal.compute import codec, convert
    sc = tools.find_spirv_cross()[0]
    cs = codec.decode(open(STP_RAW, "rb").read())
    new, recs = convert.convert_shader(cs, sc)
    mv = new["variants"][-1]
    assert mv["targetRenderer"] == 16 and all(r["status"] == "ok" for r in recs)
    vi = dict(mv["kernels"][0]["variantIndices"])
    for kw, i in vi.items():
        if metalfix.KW_NATIVE_16BIT in kw.split():
            assert i == vi[" ".join(w for w in kw.split() if w != metalfix.KW_NATIVE_16BIT)]
    from peakmetal.compute import metalblob
    for u in mv["kernels"][0]["uniqueVariants"]:
        msl = metalblob.decode(bytes(u["code"])).msl
        assert not re.search(r"as_type<float>\((-8388608|2139095040|0x[f7]f800000u)", msl)
    metal = tools.find_metal()
    if metal:
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            src = os.path.join(td, "k.metal")
            open(src, "w").write(metalblob.decode(bytes(mv["kernels"][0]["uniqueVariants"][0]["code"])).msl)
            p = subprocess.run([metal, "-c", "-std=macos-metal2.1", "-o", os.path.join(td, "k.air"), src],
                               capture_output=True, text=True)
            assert p.returncode == 0, p.stderr[-500:]
