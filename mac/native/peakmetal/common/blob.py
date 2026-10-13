"""Per-platform program blob container of a Unity 6000.3 Shader.

A platform's blob is stored as one or more LZ4 *segments* (Shader.offsets / compressedLengths /
decompressedLengths are per platform, per segment, into Shader.compressedBlob). Decompressed:

    segment 0:  u32 count, count x (u32 offset, u32 length, u32 segment), then entry bytes
    segment k:  entry bytes only
    entry i lives at segments[segment_i][offset_i : offset_i + length_i]

Entries are program entries (common.program) or parameter entries (common.params); which is which is
only known from the Shader's typetree (m_BlobIndex vs m_ParameterBlobIndices), see common.shader.

Layout rule used by Unity (verified by byte-exact rebuild of every PEAK and golden platform blob,
tests/test_codec_roundtrip.py): entries are packed in index order, contiguously, each segment starting
right after the table (segment 0) or at 0; no padding between entries.
"""
import struct

import lz4.block

from .binio import FormatError


def split(segments):
    """Decompressed segments -> (entries, entry_segment_list)."""
    s0 = segments[0]
    if len(s0) < 4:
        raise FormatError("segment 0 too short")
    n = struct.unpack_from("<I", s0, 0)[0]
    if 4 + 12 * n > len(s0):
        raise FormatError(f"entry table of {n} entries exceeds segment 0")
    entries, segs = [], []
    for i in range(n):
        off, ln, seg = struct.unpack_from("<3I", s0, 4 + 12 * i)
        if seg >= len(segments) or off + ln > len(segments[seg]):
            raise FormatError(f"entry {i} ({off},{ln},{seg}) out of range")
        entries.append(bytes(segments[seg][off:off + ln]))
        segs.append(seg)
    return entries, segs


def join(entries, segs=None):
    """Inverse of split(). segs gives the segment of each entry (default: all in segment 0)."""
    if segs is None:
        segs = [0] * len(entries)
    nseg = (max(segs) + 1) if segs else 1
    table = [struct.pack("<I", len(entries))]
    pos = [4 + 12 * len(entries)] + [0] * (nseg - 1)
    bodies = [[] for _ in range(nseg)]
    for e, s in zip(entries, segs):
        table.append(struct.pack("<3I", pos[s], len(e), s))
        bodies[s].append(e)
        pos[s] += len(e)
    out = [b"".join(table) + b"".join(bodies[0])]
    out += [b"".join(b) for b in bodies[1:]]
    return out


def decompress_platform(compressed_blob, offsets, clens, dlens):
    return [lz4.block.decompress(compressed_blob[o:o + c], uncompressed_size=d)
            for o, c, d in zip(offsets, clens, dlens)]


def compress_segment(raw):
    """LZ4 block (no size prefix). Unity uses LZ4HC; any valid LZ4 block decodes identically."""
    return lz4.block.compress(raw, mode="high_compression", compression=9, store_size=False)
