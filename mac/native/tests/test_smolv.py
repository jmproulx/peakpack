"""SMOL-V decoder tests: peakmetal.common.smolv against the reference smolv_decode.exe.

Stream sources are read-only: the Vulkan SMOL-V streams inside the PEAK and golden dumps.
Tests skip (pytest.skip) when the reference exe, the dump directories or the dump helper
are missing. Run from the native dir:
    <python> -I -m pytest tests/test_smolv.py -q
"""
import functools
import hashlib
import os
import random
import struct
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
NATIVE = os.path.dirname(HERE)  # parent of tests/
sys.path.insert(0, NATIVE)

from peakmetal.common import smolv  # noqa: E402

SMOLV_EXE = r"C:\Users\joshu\PeakMods\MacPort\tools\shaderwork\bin\smolv_decode.exe"
SCRATCH = r"C:\Users\joshu\PeakMods\MacPort\tools\nativework\scratch"
DUMP_ROOTS = {
    "peakdump": r"C:\Users\joshu\PeakMods\MacPort\tools\nativework\peakdump",
    "golden_uer": r"C:\Users\joshu\PeakMods\MacPort\tools\nativework\golden\uer",
}
VULKAN_PLATFORM = 18
SPIRV_MAGIC = struct.pack("<I", 0x07230203)
N_SAMPLES = 50
PREFERRED_NAMES = ("Universal_Render_Pipeline_Lit", "GD_FoliageGD")


def _load_streams():
    """Distinct (root, dir, slot, smolv bytes) over both dump roots, sorted by content hash."""
    if not os.path.isfile(SMOLV_EXE):
        pytest.skip("smolv_decode.exe not found")
    missing = [p for p in DUMP_ROOTS.values() if not os.path.isdir(p)]
    if missing:
        pytest.skip("dump directories missing: %s" % ", ".join(missing))
    if not os.path.isfile(os.path.join(SCRATCH, "golden_iter.py")):
        pytest.skip("scratch dump helper golden_iter.py missing")
    sys.path.insert(0, SCRATCH)
    try:
        from golden_iter import iter_dumps, program
    except ImportError as ex:
        pytest.skip("cannot import golden_iter: %s" % ex)

    seen = {}
    for label, root in DUMP_ROOTS.items():
        for name, _tt, plats in iter_dumps(root):
            pb = plats.get(VULKAN_PLATFORM)
            if pb is None:
                continue
            for i in sorted(pb.program_idx):
                vk = program.decode_vulkan(pb.program(i).data)
                for slot, data in vk.streams:
                    key = hashlib.sha256(data).hexdigest()
                    if key not in seen:
                        seen[key] = (label, name, slot, data)
    if not seen:
        pytest.skip("no Vulkan SMOL-V streams found in dumps")
    return [(key,) + seen[key] for key in sorted(seen)]


@functools.lru_cache(maxsize=1)
def _samples():
    """About N_SAMPLES streams: half from each root, plus the largest preferred-name streams."""
    streams = _load_streams()
    rng = random.Random(20260412)
    by_root = {label: [s for s in streams if s[1] == label] for label in DUMP_ROOTS}
    chosen = []
    for label in DUMP_ROOTS:
        pool = by_root[label]
        k = min(len(pool), N_SAMPLES // 2)
        chosen += rng.sample(pool, k)
    for pref in PREFERRED_NAMES:
        cands = [s for s in streams if pref in s[2]]
        if cands:
            chosen.append(max(cands, key=lambda s: len(s[4])))
    uniq = {s[0]: s for s in chosen}
    return [uniq[k] for k in sorted(uniq)]


def _reference_decode(smolv_bytes, tmp_path):
    src = tmp_path / "in.smolv"
    dst = tmp_path / "out.spv"
    src.write_bytes(smolv_bytes)
    r = subprocess.run([SMOLV_EXE, str(src), str(dst)], capture_output=True, timeout=120)
    assert r.returncode == 0, "smolv_decode.exe failed: %r" % r.stderr[-400:]
    return dst.read_bytes()


def _sample_ids():
    return list(range(N_SAMPLES))


@pytest.mark.parametrize("idx", _sample_ids())
def test_decode_matches_reference_exe(idx, tmp_path):
    samples = _samples()
    if idx >= len(samples):
        pytest.skip("only %d sample streams available" % len(samples))
    key, label, name, slot, data = samples[idx]
    if not os.path.isfile(SMOLV_EXE):
        pytest.skip("smolv_decode.exe not found")
    got = smolv.decode(data)
    assert got[:4] == SPIRV_MAGIC, "SPIR-V magic missing in %s/%s" % (label, name)
    assert len(got) == smolv.decoded_size(data)
    want = _reference_decode(data, tmp_path)
    assert got == want, "%s/%s slot %d: output differs from smolv_decode.exe" % (label, name, slot)


def test_spirv_magic_on_all_samples():
    samples = _samples()
    if not samples:
        pytest.skip("no sample streams")
    for key, label, name, slot, data in samples:
        out = smolv.decode(data)
        assert out[:4] == SPIRV_MAGIC, "bad magic for %s/%s" % (label, name)
        assert len(out) % 4 == 0 and len(out) >= 20


# --- synthetic streams: no dump files needed ------------------------------------------

def _stream(body, decoded_size, smol_version=1, spirv_version=0x00010000):
    hdr = struct.pack("<4s I I I I I", b"LOMS", (smol_version << 24) | spirv_version, 0, 1, 0,
                      decoded_size)
    return hdr + body


def test_empty_module_decodes_to_header_only():
    out = smolv.decode(_stream(b"", 20))
    assert out == struct.pack("<5I", 0x07230203, 0x00010000, 0, 1, 0)
    assert smolv.decoded_size(_stream(b"", 20)) == 20


def test_single_name_instruction_is_exact():
    # packed length+opcode varint 0x05 = OpName (5) with length 1 (word count of the op itself)
    out = smolv.decode(_stream(b"\x05", 24))
    assert out == struct.pack("<6I", 0x07230203, 0x00010000, 0, 1, 0, 0x00010005)


def test_bad_header_raises_value_error():
    with pytest.raises(ValueError):
        smolv.decode(b"not smol-v data at all")
    assert smolv.decoded_size(b"not smol-v data at all") == 0


def test_truncated_varint_raises_value_error():
    with pytest.raises(ValueError):
        smolv.decode(_stream(b"\x85", 24))


def test_size_mismatch_raises_value_error():
    # declares 28 bytes of output but the stream only produces 24
    with pytest.raises(ValueError):
        smolv.decode(_stream(b"\x05", 28))
