"""Deliverable 5: serialized-file writer fidelity and the UnityFS archive writer."""
import os

import pytest
import UnityPy
from conftest import GOLDEN_UDR_MAC, GOLDEN_UDR_WIN, GOLDEN_UER, PEAK_DATA, need

from peakmetal import repack


def test_unchanged_player_file_is_byte_identical():
    """Player-format file (no type trees, like every file in PEAK's data.unity3d)."""
    env = UnityPy.load(need(GOLDEN_UDR_MAC))
    assert repack.save_serialized(env.file) == env.file.reader.bytes


@pytest.mark.parametrize("path", [GOLDEN_UDR_WIN, GOLDEN_UER])
def test_editor_files_with_typetrees_reread_identically(path):
    """Editor files embed type trees; UnityPy re-encodes the type-tree string table differently, so we only
    require that every object comes back with identical data (PEAK's player files have no type trees)."""
    env = UnityPy.load(need(path))
    sf = env.file
    env2 = UnityPy.load(repack.save_serialized(sf))
    a = {o.path_id: o.get_raw_data() for o in env.objects}
    b = {o.path_id: o.get_raw_data() for o in env2.objects}
    assert a == b


@pytest.mark.skipif(not os.environ.get("PEAKMETAL_SLOW"), reason="set PEAKMETAL_SLOW=1 (loads 1.5 GB)")
def test_all_peak_serialized_files_byte_identical():
    from UnityPy.files import SerializedFile
    env = UnityPy.load(need(PEAK_DATA))
    n = 0
    for name, f in env.file.files.items():
        if isinstance(f, SerializedFile):
            assert repack.save_serialized(f) == f.reader.bytes, name
            n += 1
    assert n == 56


def test_bundle_roundtrip_small(tmp_path):
    """Write a UnityFS archive from synthetic nodes; UnityPy and our directory reader read it back."""
    class _B:
        version, version_player, version_engine = 8, "5.x.x", "6000.3.15f1"

    class _Env:
        file = _B()
    nodes = [("a", 4, os.urandom(300000)), ("b.resS", 0, b"x" * 1000), ("Resources/c", 4, os.urandom(5))]
    out = tmp_path / "data.unity3d"
    repack.write_bundle(_Env(), str(out), packer="lz4hc", nodes=iter(nodes), log=None)
    hdr, blocks, dirs = repack.read_directory(str(out))
    assert hdr["flags"] == 0x243 and hdr["size"] == out.stat().st_size
    assert [(n, f) for _, _, f, n in dirs] == [(n, f) for n, f, _ in nodes]
    env = UnityPy.load(str(out))
    for (name, flags, data) in nodes:
        f = env.file.files[name]
        assert (f.bytes if hasattr(f, "bytes") and not callable(getattr(f, "save", None)) else f.bytes) == data


@pytest.mark.skipif(not os.environ.get("PEAKMETAL_SLOW"), reason="set PEAKMETAL_SLOW=1 (1.5 GB, minutes)")
def test_unmodified_peak_archive_rewrites_byte_identical(tmp_path):
    """Our UnityFS writer (LZ4HC level 12, 128 KiB blocks, flags 0x243) re-creates data.unity3d exactly."""
    env = UnityPy.load(need(PEAK_DATA))
    out = tmp_path / "data.unity3d"
    repack.write_bundle(env, str(out), packer="lz4hc", log=None)
    with open(PEAK_DATA, "rb") as a, open(out, "rb") as b:
        while True:
            x, y = a.read(1 << 24), b.read(1 << 24)
            assert x == y
            if not x:
                break
