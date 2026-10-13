"""Vulkan -> Metal translation tests for PEAK's own compute shaders (stdlib unittest only).

Inputs are the 21 raw ComputeShader objects dumped from PEAK. Nothing is written except through
translate's own temporary directories.
"""
import os, sys, unittest
NATIVE = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, NATIVE)
from peakmetal.compute import codec, metalblob, metalfix, spirv, translate, validate, convert, features

PEAK_DUMP = r"C:\Users\joshu\PeakMods\MacPort\tools\nativework\compute\peak"

HAVE_PEAK = os.path.isdir(PEAK_DUMP) and any(f.endswith(".raw") for f in os.listdir(PEAK_DUMP))
try:
    SPIRV_CROSS = translate.find_spirv_cross()
except FileNotFoundError:
    SPIRV_CROSS = None
HAVE_METAL = validate.find_metal() is not None

_CONV = {}


def _peak_names():
    return sorted(f[:-4] for f in os.listdir(PEAK_DUMP) if f.endswith(".raw"))


def _peak_raw(name):
    with open(os.path.join(PEAK_DUMP, name + ".raw"), "rb") as f:
        return f.read()


def _by_renderer(cs, renderer):
    return [v for v in cs["variants"] if v["targetRenderer"] == renderer]


def _pairs(lst):
    return [list(x) for x in lst]


def _converted(name):
    """(vulkan variant, converted object bytes, decoded converted object, metal variant, records); cached."""
    if name not in _CONV:
        raw = _peak_raw(name)
        vk = _by_renderer(codec.decode(raw), translate.RENDERER_VULKAN)[0]
        out, recs = convert.convert_object_bytes(raw, SPIRV_CROSS)
        cs = codec.decode(out)
        metal_vars = _by_renderer(cs, translate.RENDERER_METAL)
        if len(metal_vars) != 1:
            raise AssertionError(f"{name}: expected one Metal variant, got {len(metal_vars)}")
        _CONV[name] = (vk, out, cs, metal_vars[0], recs)
    return _CONV[name]


@unittest.skipUnless(HAVE_PEAK, "PEAK_DUMP .raw files not present")
class TestSpirvParse(unittest.TestCase):

    def test_every_peak_vulkan_kernel_parses(self):
        n = 0
        for name in _peak_names():
            vk = _by_renderer(codec.decode(_peak_raw(name)), translate.RENDERER_VULKAN)[0]
            for p in vk["kernels"]:
                for ui, u in enumerate(p["uniqueVariants"]):
                    n += 1
                    with self.subTest(shader=name, kernel=p["name"], unique=ui):
                        m = spirv.parse(bytes(u["code"]))
                        self.assertTrue(m.entry_points)
                        self.assertEqual(m.entry_points[0][0], 5)  # ExecutionModel GLCompute
                        self.assertIsNotNone(m.local_size)
                        self.assertFalse(m.local_size_is_id)
                        self.assertEqual(list(m.local_size), u["threadGroupSize"])
        self.assertGreater(n, 0)


class TestBindingAndSamplers(unittest.TestCase):

    def test_vk_binding_split(self):
        self.assertEqual(translate.vk_binding(0x82800003), (0, 3))
        self.assertEqual(translate.vk_binding(65536), (1, 0))

    def test_inline_sampler_point_clamp(self):
        self.assertEqual(translate.decode_inline_sampler(0x54),
                         "filter::nearest,s_address::clamp_to_edge,t_address::clamp_to_edge,r_address::clamp_to_edge")

    def test_inline_sampler_linear(self):
        self.assertTrue(translate.decode_inline_sampler(0x55).startswith("filter::linear,mip_filter::nearest"))

    def test_inline_sampler_unknown_bits_raise(self):
        with self.assertRaises(translate.TranslateError):
            translate.decode_inline_sampler(0x1000)


@unittest.skipUnless(HAVE_PEAK and SPIRV_CROSS, "needs PEAK_DUMP and spirv-cross")
class TestConvertPeak(unittest.TestCase):

    def test_convert_every_peak_shader_to_metal_only(self):
        names = _peak_names()
        self.assertEqual(len(names), 21)
        for name in names:
            with self.subTest(shader=name):
                vk, out, cs, metal, recs = _converted(name)
                self.assertEqual(codec.encode(cs), out)
                self.assertEqual([v["targetRenderer"] for v in cs["variants"]], [translate.RENDERER_METAL])

                n_unique = sum(len(p["uniqueVariants"]) for p in vk["kernels"])
                self.assertEqual(len(recs), n_unique)
                bad = [f"{r['kernel']}[{r['variant_index']}]: {r['status']} {r['category']} {r['message']}"
                       for r in recs if r["status"] != "ok"]
                self.assertEqual(bad, [])

                # keyword map unchanged, except STP's 16-bit sets -> 32-bit kernels (metalfix.force_32bit)
                want = [{"name": p["name"], "variantIndices": list(p["variantIndices"])} for p in vk["kernels"]]
                redirected = metalfix.force_32bit(name, want)
                self.assertEqual(bool(redirected), name in metalfix.FORCE_32BIT_SHADERS)
                self.assertEqual([(p["name"], _pairs(p["variantIndices"])) for p in metal["kernels"]],
                                 [(p["name"], _pairs(p["variantIndices"])) for p in want])

    def test_grass_geometry_counter_encoded_in_bindpoint(self):
        _, _, _, metal, _ = _converted("GrassGeometryCompute")
        geo = []
        for p in metal["kernels"]:
            for u in p["uniqueVariants"]:
                for e in u["outBuffers"]:
                    self.assertFalse(e["name"].endswith("_counterBuf"), e["name"])
                    if e["name"] == "GeometryBuffer":
                        geo.append(e)
        self.assertTrue(geo, "GeometryBuffer not found in Metal outBuffers")
        for e in geo:
            self.assertNotEqual(e["bindPoint"] >> 16, 0)

    def test_vfx_fill_indirect_args_msl_uses_device_buffer(self):
        _, _, _, metal, _ = _converted("VFXFillIndirectArgs")
        msls = [metalblob.decode(u["code"]).msl for p in metal["kernels"] for u in p["uniqueVariants"]]
        self.assertTrue(msls)
        for msl in msls:
            self.assertIn("device uint* outputIndirectArgs", msl)
            self.assertNotIn("texture_buffer", msl)

    def test_inline_samplers_become_constexpr(self):
        count = 0
        for name in _peak_names():
            vk, _, _, metal, _ = _converted(name)
            for vp, mp in zip(vk["kernels"], metal["kernels"]):
                for ui, (vu, mu) in enumerate(zip(vp["uniqueVariants"], mp["uniqueVariants"])):
                    if not vu["builtinSamplers"]:
                        continue
                    count += 1
                    with self.subTest(shader=name, kernel=vp["name"], unique=ui):
                        self.assertEqual(mu["builtinSamplers"], [])
                        self.assertIn("constexpr sampler", metalblob.decode(mu["code"]).msl)
        self.assertGreater(count, 0, "no PEAK kernel with inline samplers was found")


class TestMetalCompile(unittest.TestCase):

    @unittest.skipIf(HAVE_METAL, "metal.exe is installed, so compile_msl does not skip")
    def test_compile_reports_skipped_without_metal(self):
        self.assertEqual(validate.compile_msl("kernel void computeMain(){}").status, "skipped")

    @unittest.skipUnless(HAVE_METAL, "metal.exe not installed")
    def test_valid_kernel_passes(self):
        msl = ("#include <metal_stdlib>\nusing namespace metal;\n"
               "kernel void computeMain(uint3 t [[thread_position_in_grid]]) {}\n")
        r = validate.compile_msl(msl)
        self.assertEqual(r.status, "pass", r.log)

    @unittest.skipUnless(HAVE_METAL, "metal.exe not installed")
    def test_invalid_kernel_fails(self):
        r = validate.compile_msl("kernel void computeMain(){ int x = ; }")
        self.assertEqual(r.status, "fail")

    @unittest.skipUnless(HAVE_METAL and HAVE_PEAK and SPIRV_CROSS, "needs metal.exe, PEAK_DUMP and spirv-cross")
    def test_first_unique_of_each_kernel_compiles(self):
        for name in ("StpTaa", "Sort", "InstanceOcclusionCullingKernels"):
            _, _, _, metal, _ = _converted(name)
            for p in metal["kernels"]:
                msl = metalblob.decode(p["uniqueVariants"][0]["code"]).msl
                with self.subTest(shader=name, kernel=p["name"]):
                    r = validate.compile_msl(msl, validate.DEFAULT_STD)
                    self.assertEqual(r.status, "pass", r.log[:800])


if __name__ == "__main__":
    unittest.main()
