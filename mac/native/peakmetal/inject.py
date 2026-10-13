"""Rewrite one Shader typetree as Metal-only (platforms == [14]) from its Vulkan programs.

What changes (everything else, including keyword names/indices and pass state, is kept verbatim):
  * platforms=[14], stageCounts=[2], one new LZ4 blob (offsets/lengths) holding MetalVS/MetalFS program
    entries and their parameter entries (identical entries are stored once, like Unity does);
  * progVertex.m_PlayerSubPrograms[g] = MetalVS subprograms (type 23), progFragment = MetalFS (24),
    each with the Vulkan subprogram's m_KeywordIndices and m_ShaderRequirements; m_ParameterBlobIndices
    mirror them; other stages (geometry/hull/domain/raytracing) are emptied;
  * m_CommonParameters of every stage are emptied: Unity merges them into every program of the stage at
    load, and the fragment ones hold D3D11 registers/layouts (wrong for Metal). The progVertex common
    cbuffer members DO belong to the Vulkan programs (e.g. all of UnityPerMaterial in 91 passes), so they
    are merged into our per-program parameter entries first (common_cbuffers/merge_common); every member
    offset is checked against the SPIR-V block layout (0 mismatches over PEAK);
  * progFragment.m_SerializedKeywordStateMask |= progVertex's (Vulkan variants select by the vertex mask;
    our FS subprograms carry the same keyword sets).
A pass with a variant we cannot translate keeps the variants we can; if no variant of a pass translates,
the whole SubShader is emptied so Unity falls back to the next SubShader / Fallback shader.
"""
import hashlib
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Dict, List

from .common import blob as B
from .common import params as P
from .common import program as G
from .common import shader as S
from . import translate as T

SEGMENT_LIMIT = 8 * 1024 * 1024   # largest segment size seen for D3D11 blobs in PEAK (Vulkan uses 16 MiB)


@dataclass
class ShaderReport:
    name: str
    programs: int = 0
    ok: int = 0
    unsupported: Dict[str, int] = field(default_factory=dict)
    errors: Dict[str, int] = field(default_factory=dict)
    warnings: Dict[str, int] = field(default_factory=dict)
    features: Dict[str, int] = field(default_factory=dict)
    dropped_subshaders: List[int] = field(default_factory=list)
    metal_bytes: int = 0

    @property
    def status(self):
        if self.programs == 0:
            return "failure" if self.errors else "empty"     # no Vulkan variants in the build at all
        if self.ok == self.programs:
            return "ok"
        if self.ok == 0:
            return "failure" if self.errors else "unsupported"
        return "partial"


def _bump(d, k):
    d[k] = d.get(k, 0) + 1


def pack_segments(entries, limit=SEGMENT_LIMIT):
    """Unity's segment layout: one segment if everything fits; otherwise segment 0 holds only the entry
    table and entries are packed in order into segments of at most `limit` bytes (reproduces PEAK's
    multi-segment D3D11 blobs exactly with limit=8 MiB and Vulkan with 16 MiB; see tests)."""
    total = 4 + 12 * len(entries) + sum(len(e) for e in entries)
    if total <= limit:
        return [0] * len(entries)
    segs, cur, size = [], 1, 0
    for e in entries:
        if size and size + len(e) > limit:
            cur += 1
            size = 0
        segs.append(cur)
        size += len(e)
    return segs


def common_cbuffers(ps, stage="progVertex"):
    """A stage's m_CommonParameters constant buffers as params.CBuffer (members by name).

    Unity hoists cbuffer members shared by all variants of a stage into m_CommonParameters (partial
    cbuffers) and merges them into every program's own parameters at load time. PEAK's Vulkan programs
    live in progVertex, so its progVertex common cbuffers belong to them: e.g. 91 passes keep ALL of
    UnityPerMaterial there (the Vulkan entry lists the cbuffer with no members). Typetree -> blob member
    mapping: vector (type, rows=1, cols=m_Dim, 0, m_ArraySize, m_Index); matrix (type, m_RowCount,
    cols 4 - every matrix in PEAK is 4x4 -, 1, m_ArraySize, m_Index)."""
    names = {i: k for k, i in ps["m_NameIndices"]}

    def vec(v):
        return P.Member(names[v["m_NameIndex"]], v["m_Type"], 1, v["m_Dim"], 0, v["m_ArraySize"], v["m_Index"])

    def mat(m):
        return P.Member(names[m["m_NameIndex"]], m["m_Type"], m["m_RowCount"], m.get("m_ColumnCount", 4), 1,
                        m["m_ArraySize"], m["m_Index"])
    out = []
    for cb in ps[stage]["m_CommonParameters"].get("m_ConstantBuffers", []):
        members = [vec(v) for v in cb["m_VectorParams"]] + [mat(m) for m in cb["m_MatrixParams"]]
        structs = [P.Struct(names[st["m_NameIndex"]], st["m_Index"], st["m_ArraySize"], st["m_StructSize"],
                            [vec(v) for v in st["m_VectorMembers"]] + [mat(m) for m in st["m_MatrixMembers"]])
                   for st in cb["m_StructParams"]]
        out.append(P.CBuffer(names[cb["m_NameIndex"]], cb["m_Size"], members, structs))
    return out


def merge_common(vkp: P.Params, commons):
    """Add hoisted members/structs to the program's same-named cbuffers (what Unity does at load)."""
    if not commons:
        return vkp
    by = {c.name: c for c in commons}
    cbs = []
    for c in vkp.cbuffers:
        cc = by.get(c.name)
        if cc is not None and c.name:
            have = {m.name for m in c.members}
            haves = {x.name for x in c.structs}
            c = P.CBuffer(c.name, c.size, c.members + [m for m in cc.members if m.name not in have],
                          c.structs + [x for x in cc.structs if x.name not in haves])
        cbs.append(c)
    return P.Params(cbs, vkp.bindings)


def translate_shader(tt, plats, tc, opts=None, pool: ThreadPoolExecutor = None, cache=None):
    """Translate every Vulkan program of a shader, per pass (the pass's progVertex common cbuffers are
    merged into the program's parameters first). Returns {(si, pi, blob, paramblob): ProgramResult}."""
    vk = plats[G.PLATFORM_VULKAN]
    jobs = {}
    pf = tt["m_ParsedForm"]
    for si, pi, st, g, k, s, pb in S.iter_subprograms(tt):
        if s["m_GpuProgramType"] == G.SPIRV:
            key = (si, pi, s["m_BlobIndex"], pb)
            if key not in jobs:
                jobs[key] = common_cbuffers(pf["m_SubShaders"][si]["m_Passes"][pi])
    cache = {} if cache is None else cache

    def run(key):
        pe_bytes = vk.entries[key[2]]
        pp = merge_common(P.decode(vk.entries[key[3]]), jobs[key])
        pp_bytes = P.encode(pp)
        h = hashlib.sha1(pe_bytes + b"|" + pp_bytes).digest()
        if h in cache:
            return cache[h]
        r = T.translate_program(G.decode(pe_bytes), pp, tc, opts)
        cache[h] = r
        return r

    keys = list(jobs)
    results = list(pool.map(run, keys)) if pool else [run(k) for k in keys]
    return dict(zip(keys, results))


def build_metal_only(tt, plats, results, report: ShaderReport, compress=B.compress_segment):
    entries, index = [], {}

    def add(b):
        if b not in index:
            index[b] = len(entries)
            entries.append(b)
        return index[b]

    emitted = {}
    counted = {}
    for key, r in results.items():
        uniq = key[2:]                     # count each Vulkan program once even if several passes use it
        first = uniq not in counted
        counted[uniq] = True
        report.programs += first
        if r.status == "ok":
            report.ok += first
            ids = {}
            for model, gpu in (("vert", G.METAL_VS), ("frag", G.METAL_FS)):
                st = r.stages[model]
                mp = G.MetalProgram([-267531522, 48, 7, 60, 0, 0, 0, 0, 0, st.header_word9, -1, 0],
                                    "xlatMtlMain", st.msl)
                pe = G.ProgramEntry(gpu, (0, 0, 0, 0), _keywords_of(plats, key), G.encode_metal(mp),
                                    st.source_map if model == "vert" else 0,
                                    st.channels if model == "vert" else [])
                ids[model] = (add(G.encode(pe)), add(P.encode(st.params)))
                for f in st.features:
                    _bump(report.features, f)
            emitted[key] = ids
            for w in r.warnings if first else ():
                _bump(report.warnings, w[:90])
        elif not first:
            pass
        elif r.status == "unsupported":
            _bump(report.unsupported, r.reason)
        else:
            _bump(report.errors, r.reason[:200])

    pf = tt["m_ParsedForm"]
    for si, ss in enumerate(pf["m_SubShaders"]):
        any_pass_empty = False
        for pi, ps in enumerate(ss["m_Passes"]):
            v, f = ps["progVertex"], ps["progFragment"]
            ngroups = len(v["m_PlayerSubPrograms"])
            nv = [[] for _ in range(ngroups)]
            nvi = [[] for _ in range(ngroups)]
            nf = [[] for _ in range(ngroups)]
            nfi = [[] for _ in range(ngroups)]
            had_vk = False
            for g, (subs, pidx) in enumerate(zip(v["m_PlayerSubPrograms"], v["m_ParameterBlobIndices"])):
                for s, pb in zip(subs, pidx):
                    if s["m_GpuProgramType"] != G.SPIRV:
                        continue
                    had_vk = True
                    ids = emitted.get((si, pi, s["m_BlobIndex"], pb))
                    if not ids:
                        continue
                    for model, tgt, tgti, gpu in (("vert", nv, nvi, G.METAL_VS), ("frag", nf, nfi, G.METAL_FS)):
                        tgt[g].append({"m_BlobIndex": ids[model][0], "m_KeywordIndices": list(s["m_KeywordIndices"]),
                                       "m_ShaderRequirements": s["m_ShaderRequirements"], "m_GpuProgramType": gpu})
                        tgti[g].append(ids[model][1])
            if had_vk and not any(nv):
                any_pass_empty = True
            v["m_PlayerSubPrograms"], v["m_ParameterBlobIndices"] = nv, nvi
            f["m_PlayerSubPrograms"], f["m_ParameterBlobIndices"] = nf, nfi
            f["m_SerializedKeywordStateMask"] = sorted(set(f["m_SerializedKeywordStateMask"]) |
                                                       set(v["m_SerializedKeywordStateMask"]))
            for stn in S.STAGES:
                prog = ps[stn]
                prog["m_CommonParameters"] = {k: [] for k in prog["m_CommonParameters"]}
                if stn not in ("progVertex", "progFragment"):
                    prog["m_PlayerSubPrograms"] = [[] for _ in prog["m_PlayerSubPrograms"]]
                    prog["m_ParameterBlobIndices"] = [[] for _ in prog["m_ParameterBlobIndices"]]
        if any_pass_empty:
            report.dropped_subshaders.append(si)
            for ps in ss["m_Passes"]:
                for stn in S.STAGES:
                    ps[stn]["m_PlayerSubPrograms"] = [[] for _ in ps[stn]["m_PlayerSubPrograms"]]
                    ps[stn]["m_ParameterBlobIndices"] = [[] for _ in ps[stn]["m_ParameterBlobIndices"]]

    if not entries:
        entries.append(P.encode(P.empty()))   # keep a valid (empty-ish) blob
    segs = pack_segments(entries)
    pbm = S.PlatformBlob(G.PLATFORM_METAL, entries, segs)
    S.store_platforms(tt, {G.PLATFORM_METAL: pbm}, order=[G.PLATFORM_METAL], compress=compress)
    tt["stageCounts"] = [2]
    report.metal_bytes = sum(len(e) for e in entries)
    return tt


def _keywords_of(plats, key):
    return G.decode(plats[G.PLATFORM_VULKAN].entries[key[2]]).keywords
