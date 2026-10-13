"""Byte-exact codec and Metal blob tests for peakmetal.compute (stdlib unittest only).

Data sources are opened read-only; nothing is written. Tests skip when a source is absent.
"""
import os, sys, unittest
NATIVE = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, NATIVE)
from peakmetal.compute import codec, metalblob, spirv, translate, validate, convert, features

GOLD_MAC = r"C:\Program Files\Unity\Hub\Editor\6000.3.15f1\Editor\Data\PlaybackEngines\MacStandaloneSupport\Variations\macos_arm64_player_nondevelopment_mono\UnityPlayer.app\Contents\Resources\Data\Resources\unity default resources"
GOLD_WIN = r"D:\SteamLibrary\steamapps\common\PEAK\PEAK_Data\Resources\unity default resources"
PEAK_DUMP = r"C:\Users\joshu\PeakMods\MacPort\tools\nativework\compute\peak"

HAVE_MAC = os.path.isfile(GOLD_MAC)
HAVE_WIN = os.path.isfile(GOLD_WIN)
HAVE_PEAK = os.path.isdir(PEAK_DUMP) and any(f.endswith(".raw") for f in os.listdir(PEAK_DUMP))

_CACHE = {}


def _gold(path):
    """[(m_Name, UnityPy object, raw bytes)] for every ComputeShader in a file; loaded once."""
    if path not in _CACHE:
        import UnityPy
        env = UnityPy.load(path)
        items = []
        for o in env.objects:
            if o.type.name == "ComputeShader":
                raw = o.get_raw_data()
                items.append((codec.decode(raw)["m_Name"], o, raw))
        _CACHE[path] = items
    return _CACHE[path]


def _peak_raws():
    """[(name, raw bytes)] for every PEAK_DUMP .raw file (the .code file in that folder is ignored)."""
    out = []
    for fn in sorted(os.listdir(PEAK_DUMP)):
        if fn.endswith(".raw"):
            with open(os.path.join(PEAK_DUMP, fn), "rb") as f:
                out.append((fn[:-4], f.read()))
    return out


def _all_raws():
    out = []
    if HAVE_MAC:
        out += [("MAC:" + n, raw) for n, _, raw in _gold(GOLD_MAC)]
    if HAVE_WIN:
        out += [("WIN:" + n, raw) for n, _, raw in _gold(GOLD_WIN)]
    if HAVE_PEAK:
        out += [("PEAK:" + n, raw) for n, raw in _peak_raws()]
    return out


def _norm(x):
    """Normalise decoded data for comparison: bytes -> list of ints, tuples -> lists."""
    if isinstance(x, (bytes, bytearray)):
        return list(x)
    if isinstance(x, (list, tuple)):
        return [_norm(i) for i in x]
    if isinstance(x, dict):
        return {k: _norm(v) for k, v in x.items()}
    return x


class TestCodecRoundTrip(unittest.TestCase):

    @unittest.skipUnless(HAVE_MAC, "Unity Mac golden resources not installed")
    def test_gold_mac_byte_exact(self):
        items = _gold(GOLD_MAC)
        self.assertEqual(len(items), 9)
        for name, _, raw in items:
            with self.subTest(shader=name):
                self.assertEqual(codec.encode(codec.decode(raw)), raw)

    @unittest.skipUnless(HAVE_WIN, "PEAK Windows golden resources not installed")
    def test_gold_win_byte_exact(self):
        items = _gold(GOLD_WIN)
        self.assertEqual(len(items), 9)
        for name, _, raw in items:
            with self.subTest(shader=name):
                self.assertEqual(codec.encode(codec.decode(raw)), raw)

    @unittest.skipUnless(HAVE_PEAK, "PEAK_DUMP .raw files not present")
    def test_peak_dump_byte_exact(self):
        raws = _peak_raws()
        self.assertEqual(len(raws), 21)
        for name, raw in raws:
            with self.subTest(shader=name):
                self.assertEqual(codec.encode(codec.decode(raw)), raw)

    def test_truncated_input_raises(self):
        raws = _all_raws()
        if not raws:
            self.skipTest("no compute shader data available")
        for label, raw in raws:
            with self.subTest(shader=label):
                with self.assertRaises(codec.CodecError):
                    codec.decode(raw[:-1])

    def test_trailing_bytes_raise(self):
        raws = _all_raws()
        if not raws:
            self.skipTest("no compute shader data available")
        for label, raw in raws:
            with self.subTest(shader=label):
                with self.assertRaises(codec.CodecError):
                    codec.decode(raw + b"\0\0\0\0")

    @unittest.skipUnless(HAVE_MAC, "Unity Mac golden resources not installed")
    def test_gold_mac_matches_unitypy_typetree(self):
        for name, o, raw in _gold(GOLD_MAC):
            with self.subTest(shader=name):
                ours = _norm(codec.decode(raw))
                theirs = _norm(o.read_typetree())
                self.assertEqual(ours, theirs)


class TestMetalBlob(unittest.TestCase):

    @unittest.skipUnless(HAVE_MAC, "Unity Mac golden resources not installed")
    def test_all_mac_metal_kernels_round_trip(self):
        count = 0
        for name, _, raw in _gold(GOLD_MAC):
            cs = codec.decode(raw)
            for v in cs["variants"]:
                if v["targetRenderer"] != 16:
                    continue
                for p in v["kernels"]:
                    for k in p["uniqueVariants"]:
                        count += 1
                        with self.subTest(shader=name, kernel=p["name"], n=count):
                            blob = metalblob.decode(k["code"])
                            self.assertEqual(blob.encode(), k["code"])
                            self.assertEqual(blob.threadgroup, tuple(k["threadGroupSize"]))
                            self.assertEqual(blob.flag, 1)
                            self.assertIn("kernel void computeMain(", blob.msl)
        self.assertEqual(count, 66)

    def test_zero_threadgroup_rejected(self):
        with self.assertRaises(metalblob.MetalBlobError):
            metalblob.MetalComputeBlob("x", (0, 1, 1)).encode()

    def test_oversized_threadgroup_rejected(self):
        with self.assertRaises(metalblob.MetalBlobError):
            metalblob.MetalComputeBlob("x", (0x10000, 1, 1)).encode()

    def test_nul_in_msl_rejected(self):
        with self.assertRaises(metalblob.MetalBlobError):
            metalblob.MetalComputeBlob("kernel void computeMain(){}\0", (1, 1, 1)).encode()


if __name__ == "__main__":
    unittest.main()
