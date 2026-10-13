"""Per-sub-program parameter entries ("parameter blobs") inside a Unity 6000.3 platform blob.

Grammar (proved by byte-exact decode/encode of every parameter entry in PEAK's data.unity3d and in the
editor's golden files; see tests/test_params.py):

    u32 magic 0x0C0A75BA
    u32 nCB
    nCB x ConstantBuffer        # cb[0] is ALWAYS the unnamed "global" block (name "", size 0): it holds
                                # specialization/function constants (e.g. UNITY_RUNTIME_INSTANCING_ARRAY_SIZE)
    u32 nBind
    nBind x Binding

    ConstantBuffer = string name, u32 size, u32 nMembers, nMembers x Member, u32 nStructs, nStructs x Struct
    Member         = string name, u32 type, u32 rows, u32 cols, u32 isMatrix, u32 arraySize, u32 index
                     type: 0 float, 1 int, 2 uint/bool-ish (Unity ShaderParamType); index = byte offset in the
                     cbuffer (for cb[0] members: (stageMask << 24) | constant id)
    Struct         = string name, u32 index, u32 arraySize, u32 structSize, u32 nMembers, nMembers x Member
                     (UnityInstancing_* cbuffers: e.g. unity_Builtins0Array[2] of {ObjectToWorld, WorldToObject})
    Binding        = string name, u32 kind, payload by kind:
        0 texture : u32 index, i32 samplerIndex, u32 dim         (dim: Unity TextureDimension, +multisample bit?)
        1 cbuffer : u32 index, u32 arraySize
        2 buffer  : u32 index, u32 arraySize                     (StructuredBuffer / ByteAddressBuffer SRV)
        3 UAV     : u32 index, u32 originalIndex
        4 sampler : u32 index, u32 samplerState                  (inline/standalone SamplerState; name is "")
    Index encoding: Vulkan = (stageMask << 24) | (set << 16) | binding, stageMask 0x04 VS, 0x08 FS, 0x10 GS
    (any stage bits combine); D3D11/Metal = plain register/slot.
"""
from dataclasses import dataclass, field
from typing import List, Tuple

from .binio import FormatError, Reader, Writer

MAGIC = 0x0C0A75BA

KIND_TEXTURE, KIND_CBUFFER, KIND_BUFFER, KIND_UAV, KIND_SAMPLER = 0, 1, 2, 3, 4
KIND_NAMES = {0: "texture", 1: "cbuffer", 2: "buffer", 3: "uav", 4: "sampler"}

PARAM_FLOAT, PARAM_INT, PARAM_UINT = 0, 1, 2


@dataclass
class Member:
    name: str
    type: int
    rows: int
    cols: int
    is_matrix: int
    array_size: int
    index: int

    def words(self):
        return [self.type, self.rows, self.cols, self.is_matrix, self.array_size, self.index]


@dataclass
class Struct:
    name: str
    index: int
    array_size: int
    struct_size: int
    members: List[Member] = field(default_factory=list)


@dataclass
class CBuffer:
    name: str
    size: int
    members: List[Member] = field(default_factory=list)
    structs: List[Struct] = field(default_factory=list)


@dataclass
class Binding:
    name: str
    kind: int
    index: int
    # kind 0: (samplerIndex(i32), dim); 1/2: (arraySize,); 3: (originalIndex,); 4: (samplerState,)
    extra: Tuple[int, ...] = ()

    @property
    def sampler_index(self):
        return self.extra[0] if self.kind == KIND_TEXTURE else None


@dataclass
class Params:
    cbuffers: List[CBuffer] = field(default_factory=list)  # cbuffers[0] = global block
    bindings: List[Binding] = field(default_factory=list)

    @property
    def globals(self):
        return self.cbuffers[0]

    def cbuffer(self, name):
        for c in self.cbuffers:
            if c.name == name:
                return c
        return None


def _member(r):
    name = r.string()
    return Member(name, *r.u32s(6))


def decode(buf) -> Params:
    r = Reader(buf)
    if r.u32() != MAGIC:
        raise FormatError("parameter entry without magic")
    ncb = r.u32()
    if ncb == 0 or ncb > 4096:
        raise FormatError(f"implausible cbuffer count {ncb}")
    cbs = []
    for _ in range(ncb):
        name = r.string()
        size, n = r.u32(), r.u32()
        mem = [_member(r) for _ in range(n)]
        ns = r.u32()
        structs = []
        for _ in range(ns):
            sname = r.string()
            idx, arr, ssize, nm = r.u32s(4)
            structs.append(Struct(sname, idx, arr, ssize, [_member(r) for _ in range(nm)]))
        cbs.append(CBuffer(name, size, mem, structs))
    if cbs[0].name != "" or cbs[0].size != 0 or cbs[0].structs:
        raise FormatError(f"first cbuffer is not the global block: {cbs[0].name!r}")
    nb = r.u32()
    binds = []
    for _ in range(nb):
        name = r.string()
        kind = r.u32()
        if kind == KIND_TEXTURE:
            idx, samp, dim = r.u32(), r.i32(), r.u32()
            binds.append(Binding(name, kind, idx, (samp, dim)))
        elif kind in (KIND_CBUFFER, KIND_BUFFER, KIND_UAV, KIND_SAMPLER):
            idx, x = r.u32(), r.u32()
            binds.append(Binding(name, kind, idx, (x,)))
        else:
            raise FormatError(f"unknown binding kind {kind} for {name!r}")
    if not r.at_end():
        raise FormatError(f"{r.end - r.pos} trailing bytes in parameter entry")
    return Params(cbs, binds)


def _w_member(w, m):
    w.string(m.name)
    w.u32s(m.words())


def encode(p: Params) -> bytes:
    w = Writer()
    w.u32(MAGIC)
    w.u32(len(p.cbuffers))
    for c in p.cbuffers:
        w.string(c.name)
        w.u32(c.size)
        w.u32(len(c.members))
        for m in c.members:
            _w_member(w, m)
        w.u32(len(c.structs))
        for s in c.structs:
            w.string(s.name)
            w.u32s([s.index, s.array_size, s.struct_size, len(s.members)])
            for m in s.members:
                _w_member(w, m)
    w.u32(len(p.bindings))
    for b in p.bindings:
        w.string(b.name)
        w.u32(b.kind)
        w.u32(b.index)
        if b.kind == KIND_TEXTURE:
            w.i32(b.extra[0])
            w.u32(b.extra[1])
        else:
            w.u32(b.extra[0])
    return w.getvalue()


def empty() -> Params:
    return Params([CBuffer("", 0)], [])


def describe(p: Params) -> str:
    out = []
    for i, c in enumerate(p.cbuffers):
        if i == 0 and not c.members:
            continue
        ms = ", ".join(f"{m.name}@{m.index:#x}" for m in c.members)
        ss = "".join(f" struct {s.name}[{s.array_size}]x{s.struct_size}@{s.index}" for s in c.structs)
        out.append(f"cb {c.name or '<global>'}({c.size}): {ms}{ss}")
    for b in p.bindings:
        out.append(f"bind {KIND_NAMES.get(b.kind, b.kind)} {b.name or '<unnamed>'} #{b.index:#x} {b.extra}")
    return "\n".join(out)
