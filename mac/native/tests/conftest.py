"""Shared fixtures for the graphics converter tests (pytest; run from native/:
    ..\\tools\\venv\\Scripts\\python.exe -I -m pytest tests -q
Inputs are read-only: the Unity editor's golden files and PEAK's data.unity3d (or the decompressed dumps
under tools/nativework, made by tools/nativework/scratch/dump_all.py). Missing inputs -> tests skip."""
import os
import sys

import pytest

NATIVE = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
REPO = os.path.abspath(os.path.join(NATIVE, ".."))
sys.path.insert(0, NATIVE)

EDITOR = r"C:\Program Files\Unity\Hub\Editor\6000.3.15f1\Editor\Data"
GOLDEN_UDR_WIN = os.path.join(EDITOR, "Resources", "unity default resources")
GOLDEN_UER = os.path.join(EDITOR, "Resources", "unity editor resources")
GOLDEN_UDR_MAC = os.path.join(EDITOR, "PlaybackEngines", "MacStandaloneSupport", "Variations",
                              "macos_arm64_player_nondevelopment_mono", "UnityPlayer.app", "Contents", "Resources",
                              "Data", "Resources", "unity default resources")
PEAK_DATA = r"D:\SteamLibrary\steamapps\common\PEAK\PEAK_Data\data.unity3d"
WORK = os.path.join(REPO, "tools", "nativework")
PEAK_DUMP = os.path.join(WORK, "peakdump")
PEAK_UDR = os.path.join(os.path.dirname(PEAK_DATA), "Resources", "unity default resources")

# Dev-PC convenience only (the package itself never looks in tools/): if no spirv-cross is configured
# ($PEAKMETAL_SPIRV_CROSS, $PEAKMETAL_BIN, native/bin, PATH), use the one built on Joshua's PC.
_DEV_SPIRV_CROSS = os.path.join(REPO, "tools", "shaderwork", "bin",
                                "spirv-cross.exe" if os.name == "nt" else "spirv-cross")
if os.path.isfile(_DEV_SPIRV_CROSS) and not os.environ.get("PEAKMETAL_SPIRV_CROSS"):
    from peakmetal import tools as _tools
    if _tools.find_tool("spirv-cross", _tools.ENV_SPIRV_CROSS)[0] is None:
        os.environ["PEAKMETAL_SPIRV_CROSS"] = _DEV_SPIRV_CROSS


def need(path):
    if not os.path.exists(path):
        pytest.skip(f"missing input {path}")
    return path


_ENV = {}


def load_env(path):
    import UnityPy
    need(path)
    if path not in _ENV:
        _ENV[path] = UnityPy.load(path)
    return _ENV[path]


def shaders(path):
    from peakmetal.common import shader as S
    env = load_env(path)
    out = []
    for o in env.objects:
        if o.type.name == "Shader":
            tt = o.read_typetree()
            out.append((o, tt, S.load_platforms(tt) if tt["platforms"] else {}))
    return out


@pytest.fixture(scope="session")
def toolchain(tmp_path_factory):
    from peakmetal import tools
    try:
        return tools.Toolchain(scratch=str(tmp_path_factory.mktemp("tc")))
    except tools.ToolError as ex:
        pytest.skip(str(ex))


def iter_dump_dirs(root):
    """(name, typetree json, {platform: PlatformBlob}) for decompressed dumps (dump_all.py layout)."""
    import glob
    import json
    from peakmetal.common import blob, shader as S
    for d in sorted(glob.glob(os.path.join(root, "*"))):
        tt = json.load(open(os.path.join(d, "full.json")))
        plats = {}
        for pi, p in enumerate(tt["platforms"]):
            segs = [open(os.path.join(d, f"{p}_{s}.bin"), "rb").read() for s in range(len(tt["offsets"][pi]))]
            ents, eseg = blob.split(segs)
            plats[p] = S.PlatformBlob(p, ents, eseg)
        for *_, s, pbi in S.iter_subprograms(tt):
            for p, pb in plats.items():
                if s["m_GpuProgramType"] in S.platform_types(p):
                    pb.program_idx.add(s["m_BlobIndex"])
                    pb.param_idx.add(pbi)
        yield os.path.basename(d), tt, plats
