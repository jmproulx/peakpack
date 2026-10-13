"""Write the modified game data: (a) loose serialized files, or (b) a repacked UnityFS data.unity3d.

PEAK ships `PEAK_Data/data.unity3d`, a UnityFS v8 archive (measured: header flags 0x243 = LZ4HC-compressed
directory, directory combined with block info, 16-byte padding before the blocks; 34,798 data blocks of
128 KiB, LZ4HC, 11 stored uncompressed; 85 nodes laid out contiguously in directory order). Nodes are the
player's serialized files (globalgamemanagers, globalgamemanagers.assets, levelN, sharedassetsN.assets,
Resources/unity_builtin_extra) and their `.resS` streams. The `*.resource` files next to it are untouched.

Serialized files are re-written by `save_serialized`, which reproduces Unity's own layout (all 56 unchanged
serialized files of PEAK come out byte-identical), so a changed file differs from the original only in
the objects we changed (Shader / ComputeShader), their object-info entries and the offsets of later data.

Mode `loose` (try first on the Mac, gate G-C0/C1): every archive node becomes a plain file in the output
Data folder (nested paths kept, e.g. Resources/unity_builtin_extra); unchanged nodes are copied byte-for-byte.
`data.unity3d` must then be ABSENT from the player's Data folder (the player only reads loose files when
there is no data.unity3d). Nothing is recompressed, so it is fast and avoids archive-writer risk.

Mode `bundle`: our own streaming UnityFS writer with the same header flags family, 128 KiB blocks,
LZ4 or LZ4HC (stored uncompressed when compression does not help) and the original node order.
"""
import os
import struct
import tempfile

import lz4.block
from UnityPy.files import SerializedFile

BLOCK_SIZE = 128 * 1024           # Unity: 128 KiB blocks, LZ4HC level 12 (max), proved block-by-block on PEAK
PACKERS = {
    # name: (archive flags, block flags). Archive flags: low 6 bits = directory compression,
    # 0x40 directory combined with blocks info, 0x200 = 16-byte padding before the block data.
    "lz4": (0x243, 2),
    "lz4hc": (0x243, 3),
    "none": (0x240, 0),
}


def _obj_data(obj):
    if obj.data is not None:
        return bytes(obj.data)
    obj.reset()
    return obj.reader.read(obj.byte_size)


def save_serialized(sf, align=16):
    """Re-serialize a SerializedFile (format 22) preserving Unity's layout, so an unchanged file comes out
    byte-identical (all 56 serialized files in PEAK's data.unity3d, tests/test_repack.py) and a changed file
    differs only in the changed objects, their object-info entries and the shift of later data.
    Differences from UnityPy's SerializedFile.save() (which re-packs in path-id order with 8-byte alignment):
    object data keeps the original file order and 16-byte alignment, object infos keep the original
    metadata order, and bytes between objects that belong to no object (e.g. 522 KB of stripped data in
    Resources/unity_builtin_extra) and after the last object are carried over verbatim."""
    from UnityPy.streams import EndianBinaryWriter
    header = sf.header
    if header.version < 22:
        return sf.save()
    orig = sf.reader.bytes
    base = header.data_offset
    objs = list(sf.objects.values())                          # metadata order as read
    data_order = sorted(objs, key=lambda o: o.byte_start)     # original data order
    data_writer = EndianBinaryWriter(endian=header.endian)
    pos = {}
    prev_end = base                                            # original absolute end of previous object
    for o in data_order:
        start = o.byte_start
        pad_end = prev_end + (-(prev_end - base)) % align       # where alignment alone would put it
        data_writer.align_stream(align)
        if start > pad_end:                                    # bytes owned by no object: keep them
            data_writer.write(orig[pad_end:start])
        d = _obj_data(o)
        pos[o.path_id] = (data_writer.Position, len(d))
        data_writer.write(d)
        prev_end = start + o.byte_size
    if prev_end < len(orig):                                   # trailing bytes after the last object
        data_writer.write(orig[prev_end:])

    meta = EndianBinaryWriter(endian=header.endian)
    meta.write_string_to_null(sf.unity_version)
    meta.write_int(sf._m_target_platform)
    meta.write_boolean(sf._enable_type_tree)
    meta.write_int(len(sf.types))
    for typ in sf.types:
        typ.write(sf, meta, False)
    meta.write_int(len(objs))
    for o in objs:
        if sf.big_id_enabled:
            meta.write_long(o.path_id)
        else:
            meta.align_stream()
            meta.write_long(o.path_id)
        off, ln = pos[o.path_id]
        meta.write_long(off)
        meta.write_u_int(ln)
        meta.write_int(o.type_id)
    meta.write_int(len(sf.script_types))
    for st in sf.script_types:
        st.write(header, meta)
    meta.write_int(len(sf.externals))
    for ex in sf.externals:
        ex.write(header, meta)
    meta.write_int(len(sf.ref_types))
    for rt in sf.ref_types:
        rt.write(sf, meta, True)
    meta.write_string_to_null(sf.userInformation)

    w = EndianBinaryWriter()
    header_size = 16 + 4 + 28
    metadata_size = meta.Length
    data_offset = header_size + metadata_size
    data_offset += (16 - data_offset % 16) % 16
    file_size = data_offset + data_writer.Length
    w.write_u_int(0)
    w.write_u_int(0)
    w.write_u_int(header.version)
    w.write_u_int(0)
    w.write_boolean(">" == header.endian)
    w.write_bytes(header.reserved)
    w.write_u_int(metadata_size)
    w.write_long(file_size)
    w.write_long(data_offset)
    w.write_long(sf.unknown)
    w.write_bytes(meta.bytes)
    w.write_bytes(b"\0" * (data_offset - w.Length))
    w.write_bytes(data_writer.bytes)
    return w.bytes


def node_bytes(f, writer="unity"):
    if isinstance(f, SerializedFile):
        if f.is_changed:
            return save_serialized(f) if writer == "unity" else f.save()
        return f.reader.bytes
    return f.bytes


def write_loose(env, out_dir, only_changed=False, log=print):
    bundle = env.file
    written = []
    for name, f in bundle.files.items():
        if only_changed and not (isinstance(f, SerializedFile) and f.is_changed):
            continue
        path = os.path.join(out_dir, *name.split("/"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        data = node_bytes(f)
        with open(path, "wb") as fh:
            fh.write(data)
        written.append((name, len(data), isinstance(f, SerializedFile) and f.is_changed))
    if log:
        log(f"loose: wrote {len(written)} files to {out_dir} ({sum(1 for w in written if w[2])} re-serialized)")
    return written


def _compress(raw, block_flag):
    if block_flag == 0:
        return raw, 0
    hc = block_flag == 3
    c = lz4.block.compress(raw, mode="high_compression" if hc else "default", compression=12 if hc else 0,
                           store_size=False)
    if len(c) >= len(raw):
        return raw, 0
    return c, block_flag


def _raw_blocks(nodes, directory):
    """Concatenate node data and cut it into BLOCK_SIZE pieces (blocks span node boundaries)."""
    buf = b""                                               # carry-over (< BLOCK_SIZE) between nodes
    for name, flags, data in nodes:
        directory.append((name, flags, len(data)))
        mv = memoryview(data)
        i = 0
        if buf:
            need = BLOCK_SIZE - len(buf)
            buf += bytes(mv[:need])
            i = need
            if len(buf) < BLOCK_SIZE:
                continue
            yield buf
            buf = b""
        while len(mv) - i >= BLOCK_SIZE:
            yield bytes(mv[i:i + BLOCK_SIZE])
            i += BLOCK_SIZE
        buf = bytes(mv[i:])
    if buf:
        yield buf


def write_bundle(env, out_path, packer="lz4hc", log=print, nodes=None, jobs=None):
    """Stream a UnityFS archive with the original node order/flags. `nodes`: optional
    [(name, flags, bytes)] (default: every node of env.file, changed serialized files re-written).
    With packer lz4hc and an unmodified environment this reproduces PEAK's data.unity3d byte-for-byte
    (1,504,357,874 bytes; tests/test_repack.py with PEAKMETAL_SLOW=1)."""
    from concurrent.futures import ThreadPoolExecutor
    from itertools import islice
    arch_flags, block_flag = PACKERS[packer]
    bundle = env.file
    if nodes is None:   # lazily: one node's bytes in memory at a time (the Mac may have 8 GB)
        nodes = ((name, f.flags, node_bytes(f)) for name, f in bundle.files.items())
    directory = []
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    blocks = []
    with tempfile.TemporaryFile(dir=os.path.dirname(os.path.abspath(out_path))) as tmp, \
            ThreadPoolExecutor(jobs or os.cpu_count() or 4) as pool:
        it = _raw_blocks(nodes, directory)
        while True:
            batch = list(islice(it, 256))                   # bounded memory, order preserved
            if not batch:
                break
            for raw, (c, fl) in zip(batch, pool.map(lambda b: _compress(b, block_flag), batch)):
                tmp.write(c)
                blocks.append((len(raw), len(c), fl))
        info = bytearray(b"\0" * 16)                         # uncompressed data hash (unused by the player)
        info += struct.pack(">i", len(blocks))
        for u, c, fl in blocks:
            info += struct.pack(">IIH", u, c, fl)
        info += struct.pack(">i", len(directory))
        off = 0
        for name, flags, size in directory:
            info += struct.pack(">qqI", off, size, flags) + name.encode("utf-8") + b"\0"
            off += size
        info = bytes(info)
        cinfo = lz4.block.compress(info, mode="high_compression", compression=12, store_size=False)
        head = bytearray(b"UnityFS\0" + struct.pack(">I", bundle.version) +
                         bundle.version_player.encode() + b"\0" + bundle.version_engine.encode() + b"\0")
        size_pos = len(head)
        head += struct.pack(">qIII", 0, len(cinfo), len(info), arch_flags)
        head += b"\0" * ((-len(head)) % 16)                  # header alignment (archive version >= 7)
        head += cinfo
        if arch_flags & 0x200:
            head += b"\0" * ((-len(head)) % 16)
        total = len(head) + tmp.tell()
        struct.pack_into(">q", head, size_pos, total)
        tmp.seek(0)
        with open(out_path, "wb") as fh:
            fh.write(head)
            while True:
                chunk = tmp.read(1 << 24)
                if not chunk:
                    break
                fh.write(chunk)
    if log:
        log(f"bundle: wrote {out_path} ({total / 1e6:.1f} MB, {len(blocks)} blocks, packer {packer})")
    return total


def read_directory(path):
    """(header dict, blocks, nodes) of a UnityFS file - used by tests to compare with the original."""
    with open(path, "rb") as f:
        data = f.read(1 << 20)
    p = data.index(b"\0") + 1
    ver = struct.unpack_from(">I", data, p)[0]
    p += 4
    e = data.index(b"\0", p)
    pv = data[p:e].decode()
    p = e + 1
    e = data.index(b"\0", p)
    ev = data[p:e].decode()
    p = e + 1
    size, csize, usize, flags = struct.unpack_from(">qIII", data, p)
    p += 20
    p += (-p) % 16
    info = lz4.block.decompress(data[p:p + csize], uncompressed_size=usize)
    q = 16
    nb = struct.unpack_from(">i", info, q)[0]
    q += 4
    blocks = [struct.unpack_from(">IIH", info, q + 10 * i) for i in range(nb)]
    q += 10 * nb
    nn = struct.unpack_from(">i", info, q)[0]
    q += 4
    nodes = []
    for _ in range(nn):
        off, sz, fl = struct.unpack_from(">qqI", info, q)
        q += 20
        e = info.index(b"\0", q)
        nodes.append((off, sz, fl, info[q:e].decode()))
        q = e + 1
    return {"version": ver, "player": pv, "engine": ev, "size": size, "flags": flags}, blocks, nodes
