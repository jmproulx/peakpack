"""Byte-exact codec for Unity 6000.3 ``ComputeShader`` (class 72) object data.

Layout (from the 6000.3.15f1 type tree, ComputeShaderPlatformVariant v2 / KernelParent v3 /
Kernel v2; little-endian; ``A`` = align the stream to 4 bytes afterwards)::

    ComputeShader
      string m_Name (A)
      vector<ComputeShaderPlatformVariant> variants
        int targetRenderer          # GfxDeviceRenderer: 2 D3D11, 16 Metal, 18 D3D12, 21 Vulkan
        int targetLevel
        vector<ComputeShaderKernelParent> kernels
          string name (A)
          vector<ComputeShaderKernel> uniqueVariants
            vector<u32> cbVariantIndices (A)
            vector<Resource> cbs, textures
            vector<{u32 sampler; int bindPoint}> builtinSamplers (A)
            vector<Resource> inBuffers, outBuffers
            vector<u8> code (A)
            staticvector<u32> threadGroupSize      # u32 count (3) + values
            s64 requirements
          vector<pair<string (A), u32>> variantIndices
          vector<string (A)> globalKeywords, localKeywords, dynamicKeywords
        vector<ComputeShaderCB> constantBuffers
          string name (A); int byteSize
          vector<{string name (A); int type; u32 offset, arraySize, rowCount, colCount}> params
        bool resourcesResolved (A)
      Resource = {string name (A); string generatedName (A); int bindPoint, samplerBindPoint,
                  texDimension, resType}

Every string is u32 length + bytes, then aligned. Because every element ends on a 4-byte boundary the
array-level align flags never add padding; the encoder still aligns where the type tree says so.

The decoded form is plain dicts/lists using the type-tree field names (the same shape UnityPy's
``read_typetree`` returns, with ``code`` as ``bytes``), so callers can mix both.
"""
from __future__ import annotations

import struct

__all__ = ["decode", "encode", "CodecError"]


class CodecError(ValueError):
    pass


class _R:
    __slots__ = ("b", "p")

    def __init__(self, b: bytes):
        self.b = b
        self.p = 0

    def need(self, n):
        if self.p + n > len(self.b):
            raise CodecError(f"truncated at {self.p} (+{n} > {len(self.b)})")

    def i32(self):
        self.need(4)
        v = struct.unpack_from("<i", self.b, self.p)[0]
        self.p += 4
        return v

    def u32(self):
        self.need(4)
        v = struct.unpack_from("<I", self.b, self.p)[0]
        self.p += 4
        return v

    def i64(self):
        self.need(8)
        v = struct.unpack_from("<q", self.b, self.p)[0]
        self.p += 8
        return v

    def align(self):
        self.p = (self.p + 3) & ~3

    def raw(self, n):
        self.need(n)
        v = self.b[self.p:self.p + n]
        self.p += n
        return v

    def count(self, elem_min=1):
        n = self.u32()
        if n * elem_min > len(self.b) - self.p:
            raise CodecError(f"implausible array count {n} at {self.p - 4}")
        return n

    def string(self):
        n = self.count()
        s = self.raw(n).decode("utf-8")
        self.align()
        return s


class _W:
    __slots__ = ("parts", "n")

    def __init__(self):
        self.parts = []
        self.n = 0

    def put(self, b):
        self.parts.append(b)
        self.n += len(b)

    def i32(self, v):
        self.put(struct.pack("<i", v))

    def u32(self, v):
        self.put(struct.pack("<I", v))

    def i64(self, v):
        self.put(struct.pack("<q", v))

    def align(self):
        pad = -self.n % 4
        if pad:
            self.put(b"\0" * pad)

    def string(self, s):
        b = s.encode("utf-8")
        self.u32(len(b))
        self.put(b)
        self.align()

    def bytes(self):
        return b"".join(self.parts)


_RES_INT_FIELDS = ("bindPoint", "samplerBindPoint", "texDimension", "resType")


def _rd_resource(r):
    d = {"name": r.string(), "generatedName": r.string()}
    for k in _RES_INT_FIELDS:
        d[k] = r.i32()
    return d


def _wr_resource(w, d):
    w.string(d["name"])
    w.string(d.get("generatedName", ""))
    for k in _RES_INT_FIELDS:
        w.i32(d[k])


def _rd_res_list(r):
    return [_rd_resource(r) for _ in range(r.count(24))]


def _wr_res_list(w, lst):
    w.u32(len(lst))
    for d in lst:
        _wr_resource(w, d)
    w.align()


def _rd_kernel(r):
    k = {"cbVariantIndices": [r.u32() for _ in range(r.count(4))]}
    r.align()
    k["cbs"] = _rd_res_list(r)
    k["textures"] = _rd_res_list(r)
    k["builtinSamplers"] = [{"sampler": r.u32(), "bindPoint": r.i32()} for _ in range(r.count(8))]
    r.align()
    k["inBuffers"] = _rd_res_list(r)
    k["outBuffers"] = _rd_res_list(r)
    n = r.count()
    k["code"] = bytes(r.raw(n))
    r.align()
    k["threadGroupSize"] = [r.u32() for _ in range(r.count(4))]
    k["requirements"] = r.i64()
    return k


def _wr_kernel(w, k):
    w.u32(len(k["cbVariantIndices"]))
    for v in k["cbVariantIndices"]:
        w.u32(v)
    w.align()
    _wr_res_list(w, k["cbs"])
    _wr_res_list(w, k["textures"])
    w.u32(len(k["builtinSamplers"]))
    for s in k["builtinSamplers"]:
        w.u32(s["sampler"])
        w.i32(s["bindPoint"])
    w.align()
    _wr_res_list(w, k["inBuffers"])
    _wr_res_list(w, k["outBuffers"])
    code = bytes(k["code"])
    w.u32(len(code))
    w.put(code)
    w.align()
    w.u32(len(k["threadGroupSize"]))
    for v in k["threadGroupSize"]:
        w.u32(v)
    w.i64(k["requirements"])


def _rd_strings(r):
    return [r.string() for _ in range(r.count(4))]


def _wr_strings(w, lst):
    w.u32(len(lst))
    for s in lst:
        w.string(s)
    w.align()


def _rd_parent(r):
    p = {"name": r.string()}
    p["uniqueVariants"] = [_rd_kernel(r) for _ in range(r.count(40))]
    r.align()
    vi = []
    for _ in range(r.count(8)):
        s = r.string()
        vi.append((s, r.u32()))
    r.align()
    p["variantIndices"] = vi
    p["globalKeywords"] = _rd_strings(r)
    p["localKeywords"] = _rd_strings(r)
    p["dynamicKeywords"] = _rd_strings(r)
    return p


def _wr_parent(w, p):
    w.string(p["name"])
    w.u32(len(p["uniqueVariants"]))
    for k in p["uniqueVariants"]:
        _wr_kernel(w, k)
    w.align()
    w.u32(len(p["variantIndices"]))
    for s, i in p["variantIndices"]:
        w.string(s)
        w.u32(i)
    w.align()
    _wr_strings(w, p["globalKeywords"])
    _wr_strings(w, p["localKeywords"])
    _wr_strings(w, p["dynamicKeywords"])


_PARAM_FIELDS = ("offset", "arraySize", "rowCount", "colCount")


def _rd_cb(r):
    cb = {"name": r.string(), "byteSize": r.i32()}
    params = []
    for _ in range(r.count(24)):
        p = {"name": r.string(), "type": r.i32()}
        for f in _PARAM_FIELDS:
            p[f] = r.u32()
        params.append(p)
    r.align()
    cb["params"] = params
    return cb


def _wr_cb(w, cb):
    w.string(cb["name"])
    w.i32(cb["byteSize"])
    w.u32(len(cb["params"]))
    for p in cb["params"]:
        w.string(p["name"])
        w.i32(p["type"])
        for f in _PARAM_FIELDS:
            w.u32(p[f])
    w.align()


def _rd_variant(r):
    v = {"targetRenderer": r.i32(), "targetLevel": r.i32()}
    v["kernels"] = [_rd_parent(r) for _ in range(r.count(24))]
    r.align()
    v["constantBuffers"] = [_rd_cb(r) for _ in range(r.count(12))]
    r.align()
    b = r.raw(1)[0]
    if b > 1:
        raise CodecError(f"bad bool {b} at {r.p - 1}")
    v["resourcesResolved"] = bool(b)
    r.align()
    return v


def _wr_variant(w, v):
    w.i32(v["targetRenderer"])
    w.i32(v["targetLevel"])
    w.u32(len(v["kernels"]))
    for p in v["kernels"]:
        _wr_parent(w, p)
    w.align()
    w.u32(len(v["constantBuffers"]))
    for cb in v["constantBuffers"]:
        _wr_cb(w, cb)
    w.align()
    w.put(b"\x01" if v["resourcesResolved"] else b"\x00")
    w.align()


def decode(data: bytes) -> dict:
    """Decode ComputeShader object bytes. Raises CodecError unless every byte is consumed."""
    r = _R(bytes(data))
    cs = {"m_Name": r.string()}
    cs["variants"] = [_rd_variant(r) for _ in range(r.count(16))]
    r.align()
    if r.p != len(r.b):
        raise CodecError(f"{len(r.b) - r.p} trailing bytes after ComputeShader '{cs['m_Name']}'")
    return cs


def encode(cs: dict) -> bytes:
    w = _W()
    w.string(cs["m_Name"])
    w.u32(len(cs["variants"]))
    for v in cs["variants"]:
        _wr_variant(w, v)
    w.align()
    return w.bytes()
