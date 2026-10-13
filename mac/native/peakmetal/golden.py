"""Regression against Unity's own Metal output.

The editor's `unity editor resources` (95 shaders) and `unity default resources` (6 shaders) carry D3D11,
Vulkan AND Metal programs compiled by Unity from the same source. We translate their Vulkan programs with
our pipeline and compare with Unity's Metal programs for the same (subshader, pass, keyword set):

  exact:      Metal header words; VS bind channels (sourceMap + (source, target) list, sorted by target);
              entry name; set of Unity function constants declared; texture names/dims bound per stage
  semantic:   every uniform Unity's Metal program binds (cbuffer members, textures) is bound by ours;
              textures that Unity samples with a sampler get one from us too
Differences that are expected and not errors: cbuffer *names*/grouping (Unity Metal keeps HLSL cbuffers,
Vulkan merges them into VGlobals<hash>/PGlobals<hash>, and we inherit the Vulkan layout), member offsets.
"""
import re
from collections import Counter

from .common import params as P
from .common import program as G
from .common import shader as S
from . import translate as T

FC_RE = re.compile(r"\[\[\s*function_constant\((\d+)\)\s*\]\]")


def _common_textures(ps, stage):
    names = {i: k for k, i in ps["m_NameIndices"]}
    return {names.get(t["m_NameIndex"], "?") for t in ps[stage]["m_CommonParameters"].get("m_TextureParams", [])}


def _common_members(ps, stage):
    names = {i: k for k, i in ps["m_NameIndices"]}
    out = set()
    for cb in ps[stage]["m_CommonParameters"].get("m_ConstantBuffers", []):
        for v in cb.get("m_VectorParams", []) + cb.get("m_MatrixParams", []):
            out.add(names.get(v["m_NameIndex"], "?"))
    return out


def _members(p: P.Params):
    out = set()
    for c in p.cbuffers[1:]:
        out |= {m.name for m in c.members}
        for s in c.structs:
            out.add(s.name)
    return out


def compare_shader(tt, plats, tc, opts=None, limit=None):
    """Yield one dict per matched (Metal golden, our translation) stage pair."""
    if 14 not in plats or 18 not in plats:
        return
    mtl, vk = plats[14], plats[18]
    golden = {}
    for si, pi, st, g, k, s, pb in S.iter_subprograms(tt):
        if s["m_GpuProgramType"] in (23, 24):
            golden[(si, pi, st, tuple(sorted(s["m_KeywordIndices"])))] = (s, pb)
    n = 0
    for si, pi, st, g, k, s, pb in S.iter_subprograms(tt):
        if s["m_GpuProgramType"] != 25:
            continue
        kw = tuple(sorted(s["m_KeywordIndices"]))
        ps = tt["m_ParsedForm"]["m_SubShaders"][si]["m_Passes"][pi]
        from . import inject
        vkp = inject.merge_common(vk.params(pb), inject.common_cbuffers(ps))
        r = T.translate_program(vk.program(s["m_BlobIndex"]), vkp, tc, opts)
        for model, stage, gt in (("vert", "progVertex", 23), ("frag", "progFragment", 24)):
            gk = (si, pi, stage, kw)
            if gk not in golden:
                continue
            gs, gpb = golden[gk]
            gpe = mtl.program(gs["m_BlobIndex"])
            gm = G.decode_metal(gpe.data)
            gp = mtl.params(gpb)
            row = {"key": (si, pi, stage, kw), "status": r.status, "reason": r.reason, "diffs": []}
            if r.status != "ok":
                yield row
                continue
            ours = r.stages[model]
            d = row["diffs"]
            hdr = list(gm.header)
            our_hdr = [-267531522, 48, 7, 60, 0, 0, 0, 0, 0, ours.header_word9, -1, 0]
            if hdr != our_hdr:
                d.append(f"header {hdr} != ours {our_hdr}")
            if model == "vert":
                if gpe.source_map != ours.source_map:
                    d.append(f"sourceMap {gpe.source_map} != {ours.source_map}")
                if list(map(tuple, gpe.channels)) != list(map(tuple, ours.channels)):
                    d.append(f"channels {gpe.channels} != {ours.channels}")
            gfc = set(FC_RE.findall(gm.source))
            ofc = set(FC_RE.findall(ours.msl))
            if gfc != ofc:
                d.append(f"function constants {sorted(gfc)} != ours {sorted(ofc)}")
            gtex = {b.name: b for b in gp.bindings if b.kind == P.KIND_TEXTURE}
            otex = {b.name: b for b in ours.params.bindings if b.kind == P.KIND_TEXTURE}
            # Unity hoists textures shared by all variants into m_CommonParameters (applies to every platform)
            gnames = set(gtex) | (_common_textures(ps, stage) & {b.name for b in vk.params(pb).bindings})
            if gnames != set(otex):
                d.append(f"textures golden {sorted(gnames)} != ours {sorted(otex)}")
            for nme in set(gtex) & set(otex):
                if gtex[nme].extra[1] != otex[nme].extra[1]:
                    d.append(f"texture {nme} dim {gtex[nme].extra[1]} != {otex[nme].extra[1]}")
                if (gtex[nme].extra[0] >= 0) != (otex[nme].extra[0] >= 0):
                    d.append(f"texture {nme} sampler {gtex[nme].extra[0]} vs ours {otex[nme].extra[0]}")
            gmem = _members(gp)
            omem = _members(ours.params)
            missing = {m for m in gmem - omem if not m.startswith("unity_Stereo")}
            if missing:
                d.append(f"uniforms bound by Unity but not by us: {sorted(missing)}")
            row["extra_uniforms"] = sorted(omem - gmem - _common_members(ps, stage))
            yield row
            n += 1
        if limit and n >= limit:
            return


def summarize(rows):
    c = Counter()
    kinds = Counter()
    for r in rows:
        if r["status"] != "ok":
            c[r["status"]] += 1
            continue
        c["match" if not r["diffs"] else "diff"] += 1
        for d in r["diffs"]:
            kinds[d.split(" ")[0]] += 1
    return c, kinds


# Differences explained in README "Translation vs Unity's own Metal": Unity's Metal compiler replaced a VS texture
# query by a uniform (editor-only Scene View "Show Mips"); FrameDebugger MS-texture reads where our parameter entry
# also names the (unused) sampler.
EXPLAINED_PREFIXES = ("textures golden [] != ours ['_MainTex']", "texture _MainTex sampler -1")


def unexplained(rows):
    """Rows (translated OK) whose diffs are not all explained differences."""
    return [r for r in rows if r["status"] == "ok" and r["diffs"] and not all(
        d.startswith(EXPLAINED_PREFIXES) for d in r["diffs"])]
