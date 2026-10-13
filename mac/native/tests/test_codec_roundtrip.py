"""Deliverable 1: byte-exact decode/encode of Unity 6000.3 Shader objects.

For every Shader: typetree read -> write is byte-identical; every program and parameter entry decodes and
re-encodes byte-identically; the whole platform blob re-built from decoded entries and re-compressed with
LZ4HC level 9 gives Unity's exact compressedBlob/offsets/lengths; and the complete object re-serialized
from the re-encoded fields equals the original object bytes.
"""
import os

import pytest
from conftest import (GOLDEN_UDR_MAC, GOLDEN_UDR_WIN, GOLDEN_UER, PEAK_DATA, PEAK_DUMP, iter_dump_dirs, need,
                      shaders)

from peakmetal.common import blob as B
from peakmetal.common import params as P
from peakmetal.common import program as G
from peakmetal.common import shader as S


def _roundtrip_object(o, tt, plats):
    from UnityPy.helpers import TypeTreeHelper
    from UnityPy.streams import EndianBinaryWriter
    raw = o.get_raw_data()
    w = EndianBinaryWriter(endian=o.reader.endian)
    TypeTreeHelper.write_typetree(tt, o._get_typetree_node(), w, o.assets_file)
    assert w.bytes == raw, "typetree read/write not exact"
    for p, pb in plats.items():
        for i, e in enumerate(pb.entries):
            k = pb.kind(i)
            if k == "program":
                pe = G.decode(e)
                assert G.encode(pe) == e
                if p == G.PLATFORM_METAL:
                    assert G.encode_metal(G.decode_metal(pe.data)) == pe.data
            elif k == "params":
                assert P.encode(P.decode(e)) == e
    if not plats:
        return
    tt2 = dict(tt)
    S.store_platforms(tt2, plats, order=list(tt["platforms"]))
    assert bytes(tt2["compressedBlob"]) == bytes(tt["compressedBlob"])
    assert (tt2["offsets"], tt2["compressedLengths"], tt2["decompressedLengths"]) == \
        (tt["offsets"], tt["compressedLengths"], tt["decompressedLengths"])
    w2 = EndianBinaryWriter(endian=o.reader.endian)
    TypeTreeHelper.write_typetree(tt2, o._get_typetree_node(), w2, o.assets_file)
    assert w2.bytes == raw


@pytest.mark.parametrize("path", [GOLDEN_UDR_WIN, GOLDEN_UDR_MAC, GOLDEN_UER])
def test_golden_objects_byte_exact(path):
    items = shaders(path)
    assert items
    for o, tt, plats in items:
        _roundtrip_object(o, tt, plats)


@pytest.mark.skipif(not os.environ.get("PEAKMETAL_SLOW"), reason="set PEAKMETAL_SLOW=1 (loads 1.5 GB)")
def test_peak_objects_byte_exact():
    items = shaders(need(PEAK_DATA))
    assert len(items) == 275
    for o, tt, plats in items:
        _roundtrip_object(o, tt, plats)


def test_peak_dump_entries_byte_exact():
    """All 275 PEAK shaders (decompressed dumps): every entry + every platform blob layout exact."""
    need(PEAK_DUMP)
    n_sh = n_ent = 0
    for name, tt, plats in iter_dump_dirs(PEAK_DUMP):
        n_sh += 1
        for p, pb in plats.items():
            assert B.join(pb.entries, pb.segs) == B.join(*B.split(B.join(pb.entries, pb.segs)))
            for i, e in enumerate(pb.entries):
                k = pb.kind(i)
                if k == "program":
                    pe = G.decode(e)
                    assert G.encode(pe) == e and not pe.extra
                    if p == G.PLATFORM_VULKAN:
                        G.decode_vulkan(pe.data)
                elif k == "params":
                    assert P.encode(P.decode(e)) == e, (name, i)
                n_ent += 1
    assert n_sh == 275 and n_ent > 30000


def test_segment_packing_matches_unity():
    """inject.pack_segments reproduces Unity's multi-segment layouts (URP Lit, GD/FoliageGD):
    8 MiB per segment for D3D11 and 16 MiB for Vulkan, segment 0 = entry table only."""
    from peakmetal import inject
    need(PEAK_DUMP)
    seen = 0
    for name, tt, plats in iter_dump_dirs(PEAK_DUMP):
        for p, pb in plats.items():
            if not pb.segs:
                continue
            limit = (8 if p == G.PLATFORM_D3D11 else 16) * 1024 * 1024
            assert inject.pack_segments(pb.entries, limit) == pb.segs, (name, p)  # single-segment ones too
            seen += max(pb.segs) > 0
    assert seen == 4
