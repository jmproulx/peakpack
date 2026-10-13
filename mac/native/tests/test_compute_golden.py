"""Golden check: our Vulkan -> Metal translation vs Unity's own Metal compute shaders (Mac player).

For four shaders, the Vulkan variant from PEAK's Windows resources is translated with
translate.translate_variant and compared field by field with the Metal variant Unity shipped in the
macOS arm64 player. Only the MSL text (the kernel ``code`` blob) is allowed to differ.
"""
import copy, os, sys, unittest
NATIVE = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, NATIVE)
from peakmetal.compute import codec, metalblob, spirv, translate, validate, convert, features

GOLD_MAC = r"C:\Program Files\Unity\Hub\Editor\6000.3.15f1\Editor\Data\PlaybackEngines\MacStandaloneSupport\Variations\macos_arm64_player_nondevelopment_mono\UnityPlayer.app\Contents\Resources\Data\Resources\unity default resources"
GOLD_WIN = r"D:\SteamLibrary\steamapps\common\PEAK\PEAK_Data\Resources\unity default resources"

GOLDEN_SHADERS = [
    "Internal-Skinning",
    "Internal-BlendShape",
    "Internal-VT-TranslationTableReplace",
    "Internal-VT-TranslationTableUpsample",
]

HAVE_DATA = os.path.isfile(GOLD_MAC) and os.path.isfile(GOLD_WIN)
try:
    SPIRV_CROSS = translate.find_spirv_cross()
except FileNotFoundError:
    SPIRV_CROSS = None

_CACHE = {}


def _compute_raws(path):
    """{m_Name: raw object bytes} for every ComputeShader in a file; loaded once per path."""
    if path not in _CACHE:
        import UnityPy
        env = UnityPy.load(path)
        d = {}
        for o in env.objects:
            if o.type.name == "ComputeShader":
                raw = o.get_raw_data()
                d[codec.decode(raw)["m_Name"]] = raw
        _CACHE[path] = d
    return _CACHE[path]


def _single_variant(cs, renderer):
    found = [v for v in cs["variants"] if v["targetRenderer"] == renderer]
    if len(found) != 1:
        raise AssertionError(f"{cs['m_Name']}: expected one variant with targetRenderer {renderer}, "
                             f"found {len(found)}")
    return found[0]


def _norm(x):
    """Normalise decoded data for comparison: bytes -> list of ints, tuples -> lists."""
    if isinstance(x, (bytes, bytearray)):
        return list(x)
    if isinstance(x, (list, tuple)):
        return [_norm(i) for i in x]
    if isinstance(x, dict):
        return {k: _norm(v) for k, v in x.items()}
    return x


RESOURCE_FIELDS = ("cbVariantIndices", "threadGroupSize", "requirements", "builtinSamplers",
                   "cbs", "textures", "inBuffers", "outBuffers")


@unittest.skipUnless(HAVE_DATA and SPIRV_CROSS, "needs Unity golden resources and spirv-cross")
class TestVulkanToMetalGolden(unittest.TestCase):

    def _check(self, name):
        mac_raw = _compute_raws(GOLD_MAC)[name]
        win_raw = _compute_raws(GOLD_WIN)[name]

        golden_cs = codec.decode(mac_raw)
        self.assertEqual(len(golden_cs["variants"]), 1)
        golden = _single_variant(golden_cs, translate.RENDERER_METAL)

        vk = _single_variant(codec.decode(win_raw), translate.RENDERER_VULKAN)

        mv, results = translate.translate_variant(vk, SPIRV_CROSS)

        # every Vulkan unique variant must translate cleanly (no stub fallback)
        n_unique = sum(len(p["uniqueVariants"]) for p in vk["kernels"])
        self.assertEqual(len(results), n_unique)
        bad = [f"{kname}[{ui}] ({kw}): {r.category}: {r.message}"
               for ki, ui, kname, kw, r in results if r.status != "ok"]
        self.assertEqual(bad, [], "kernels that did not translate")

        # variant level
        self.assertEqual(mv["targetRenderer"], 16)
        self.assertEqual(mv["targetLevel"], golden["targetLevel"])
        self.assertEqual(mv["resourcesResolved"], golden["resourcesResolved"])
        self.assertEqual(_norm(mv["constantBuffers"]), _norm(golden["constantBuffers"]))

        # kernel parents
        self.assertEqual(len(mv["kernels"]), len(golden["kernels"]))
        for mk, gk in zip(mv["kernels"], golden["kernels"]):
            with self.subTest(kernel=gk["name"]):
                self.assertEqual(mk["name"], gk["name"])
                self.assertEqual(_norm(mk["variantIndices"]), _norm(gk["variantIndices"]))
                self.assertEqual(mk["globalKeywords"], gk["globalKeywords"])
                self.assertEqual(mk["localKeywords"], gk["localKeywords"])
                self.assertEqual(mk["dynamicKeywords"], gk["dynamicKeywords"])
                self.assertEqual(len(mk["uniqueVariants"]), len(gk["uniqueVariants"]))

                # unique variants: everything but the MSL text must be exact
                for ui, (mu, gu) in enumerate(zip(mk["uniqueVariants"], gk["uniqueVariants"])):
                    with self.subTest(unique=ui):
                        for f in RESOURCE_FIELDS:
                            self.assertEqual(_norm(mu[f]), _norm(gu[f]), f"{f} differs")
                        m_blob = metalblob.decode(mu["code"])
                        g_blob = metalblob.decode(gu["code"])
                        self.assertEqual(m_blob.threadgroup, g_blob.threadgroup)
                        self.assertEqual(list(m_blob.threadgroup), mu["threadGroupSize"])

        # whole object: substitute Unity's own code blobs, then the encoding must be byte-identical
        subst = copy.deepcopy(mv)
        for sk, gk in zip(subst["kernels"], golden["kernels"]):
            for su, gu in zip(sk["uniqueVariants"], gk["uniqueVariants"]):
                su["code"] = gu["code"]
        obj = {"m_Name": name, "variants": [subst]}
        self.assertEqual(codec.encode(obj), mac_raw)

    def test_golden_shaders_present_in_both_sources(self):
        mac = _compute_raws(GOLD_MAC)
        win = _compute_raws(GOLD_WIN)
        for name in GOLDEN_SHADERS:
            with self.subTest(shader=name):
                self.assertIn(name, mac)
                self.assertIn(name, win)
                self.assertIsNotNone(_single_variant(codec.decode(win[name]), translate.RENDERER_VULKAN))

    def test_internal_skinning(self):
        self._check("Internal-Skinning")

    def test_internal_blendshape(self):
        self._check("Internal-BlendShape")

    def test_internal_vt_translation_table_replace(self):
        self._check("Internal-VT-TranslationTableReplace")

    def test_internal_vt_translation_table_upsample(self):
        self._check("Internal-VT-TranslationTableUpsample")


if __name__ == "__main__":
    unittest.main()
