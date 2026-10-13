"""Typetree-level codec for a Unity 6000.3 `Shader` object.

The SerializedShader part (m_ParsedForm, keyword names/flags, passes, m_PlayerSubPrograms, ...) is read
and written through UnityPy's typetree reader/writer (UnityPy 1.25.4 ships the 6000.3 Shader type tree);
the per-platform program blobs (`platforms`, `offsets`, `compressedLengths`, `decompressedLengths`,
`compressedBlob`, `stageCounts`) are handled here.

Layout facts (verified on all 275 PEAK shaders and the golden files by tests/test_codec_roundtrip.py):
  * compressedBlob = concat over platforms (in `platforms` order) of concat over segments of LZ4 blocks;
    offsets[p][s] is the byte offset of that block in compressedBlob.
  * SerializedProgram.m_PlayerSubPrograms is a list of 4 groups (one per shader hardware tier slot;
    Unity 6 fills only the last one), each a list of SerializedPlayerSubProgram {m_BlobIndex,
    m_KeywordIndices, m_ShaderRequirements, m_GpuProgramType}; m_ParameterBlobIndices mirrors it.
  * Vulkan: one SPIRV(25) entry holds all stages and is referenced from progVertex only.
    Metal: separate MetalVS(23) entries in progVertex and MetalFS(24) entries in progFragment.
"""
from dataclasses import dataclass, field
from typing import Dict, List

from . import blob as blobmod
from . import params as paramsmod
from . import program as progmod

STAGES = ("progVertex", "progFragment", "progGeometry", "progHull", "progDomain", "progRayTracing")


def iter_subprograms(tt):
    """Yield (si, pi, stage, group, k, subprogram_dict, param_blob_index) for every player sub-program."""
    for si, ss in enumerate(tt["m_ParsedForm"]["m_SubShaders"]):
        for pi, ps in enumerate(ss["m_Passes"]):
            for st in STAGES:
                prog = ps.get(st)
                if not prog:
                    continue
                for g, (subs, pidx) in enumerate(zip(prog["m_PlayerSubPrograms"], prog["m_ParameterBlobIndices"])):
                    for k, (s, pb) in enumerate(zip(subs, pidx)):
                        yield si, pi, st, g, k, s, pb


def platform_types(platform):
    return {4: range(15, 23), 14: (23, 24), 18: (25,), 9: (3, 4, 5), 15: (6, 7, 8), 26: (33,)}.get(platform, ())


@dataclass
class PlatformBlob:
    platform: int
    entries: List[bytes]
    segs: List[int]
    program_idx: set = field(default_factory=set)
    param_idx: set = field(default_factory=set)

    def kind(self, i):
        if i in self.program_idx:
            return "program"
        if i in self.param_idx:
            return "params"
        return "unreferenced"

    def program(self, i) -> progmod.ProgramEntry:
        return progmod.decode(self.entries[i])

    def params(self, i) -> paramsmod.Params:
        return paramsmod.decode(self.entries[i])

    def segments(self):
        return blobmod.join(self.entries, self.segs)


def load_platforms(tt) -> Dict[int, PlatformBlob]:
    blob = bytes(tt["compressedBlob"])
    out = {}
    for i, p in enumerate(tt["platforms"]):
        segs = blobmod.decompress_platform(blob, tt["offsets"][i], tt["compressedLengths"][i],
                                           tt["decompressedLengths"][i])
        entries, eseg = blobmod.split(segs)
        out[p] = PlatformBlob(p, entries, eseg)
    for *_, s, pb in iter_subprograms(tt):
        t = s["m_GpuProgramType"]
        for p, pbk in out.items():
            if t in platform_types(p):
                pbk.program_idx.add(s["m_BlobIndex"])
                pbk.param_idx.add(pb)
    return out


def store_platforms(tt, plats: Dict[int, PlatformBlob], order=None, compress=blobmod.compress_segment):
    """Write PlatformBlobs back into tt (platforms/offsets/lengths/compressedBlob). Returns tt."""
    order = list(order if order is not None else plats.keys())
    blob, offs, cls, dls = [], [], [], []
    pos = 0
    for p in order:
        o, c, d = [], [], []
        for raw in plats[p].segments():
            comp = compress(raw)
            o.append(pos)
            c.append(len(comp))
            d.append(len(raw))
            blob.append(comp)
            pos += len(comp)
        offs.append(o)
        cls.append(c)
        dls.append(d)
    tt["platforms"] = order
    tt["offsets"], tt["compressedLengths"], tt["decompressedLengths"] = offs, cls, dls
    data = b"".join(blob)
    tt["compressedBlob"] = data if isinstance(tt.get("compressedBlob"), (bytes, bytearray)) else list(data)
    return tt


def shader_name(tt):
    return tt["m_ParsedForm"]["m_Name"]
