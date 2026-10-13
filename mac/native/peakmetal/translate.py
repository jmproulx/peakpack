"""Vulkan (SMOL-V SPIR-V) program -> Unity Metal programs (MSL + Metal parameter entries).

One Unity Vulkan program entry holds every stage of a variant; it becomes one MetalVS (23) and one
MetalFS (24) program entry, each with its own parameter entry. Conventions, and where each was proved:

  entry point     `xlatMtlMain` (all 486 golden Unity Metal programs)
  header          F00DCAFE,48,7,60,0x5,{37|39},-1,0; word 9 = 39 iff a VS writes
                  [[render_target_array_index]] (0 mispredictions over 486 golden programs)
  vertex inputs   [[attribute(L)]] = SPIR-V Location L; bind-channel target = 13 + L; Metal channel list
                  sorted by target; sourceMap identical to Vulkan (648/648 golden channels)
  y-flip          Unity's Vulkan VS ends with `gl_Position.y = -gl_Position.y`; Unity's Metal VS has no
                  flip, so SPIRV-Cross --flip-vert-y cancels it (golden Metal: no y negation anywhere)
  frag outputs    `[[ color(rp_output_remap_N) ]]` + `constant uint32_t rp_output_remap_mask
                  [[ function_constant(1) ]]` (247/247 golden FS; format strings in UnityShaderCompiler.exe)
  base instance   SV_InstanceID/SV_VertexID exclude base instance/vertex on Unity Metal:
                  `has_base_vertex_instance [[ function_constant(4) ]]` (golden + compiler strings)
  inline samplers Unity Metal uses `constexpr sampler` (golden: 10 cases) with HLSLcc's exact syntax;
                  state bits decoded from golden pairs + DXBC dcl_sampler comparison mode
  framebuffer     `[[ color(rp_input_remap_N), function_constant(has_framebuffer_fetch) ]]` with a texture
  fetch           fallback `function_constant(has_no_framebuffer_fetch)`; constants 0 and 2 (compiler
                  strings only: no golden program uses framebuffer fetch -> UNVERIFIED on a Mac)
  slots           buffers/textures/samplers compacted per stage from 0 (golden: per-stage compaction)
  params          cbuffer layouts copied from the Vulkan entry (offsets are the SPIR-V std140 offsets the
                  MSL uses); textures keep Vulkan `dim`; samplerIndex = Metal sampler slot
"""
import re
from dataclasses import dataclass, field
from typing import Dict, List, Optional

from . import spirv as sp
from .common import params as P
from .common import program as G

STAGE_BIT = {"vert": 0x04, "frag": 0x08, "geom": 0x10}
MAX_SAMPLERS = 16
MAX_BUFFER_SLOT = 26        # 27 = Unity's VRR buffer slot; vertex streams also live in the buffer table
MAX_TEXTURES = 128
INSTANCING_SPEC_NAME = "UNITY_RUNTIME_INSTANCING_ARRAY_SIZE"
INSTANCING_MAX_BYTES = 65536
CAP_MULTIVIEW = 4439

WRAP = {0: "repeat", 1: "clamp_to_edge", 2: "mirrored_repeat", 3: "mirrored_repeat"}  # HLSLcc: MirrorOnce->mirrored


class Unsupported(Exception):
    pass


@dataclass
class StageResult:
    model: str
    msl: str
    params: P.Params
    source_map: int = 0
    channels: list = field(default_factory=list)
    header_word9: int = 37
    features: set = field(default_factory=set)
    warnings: List[str] = field(default_factory=list)
    spirv: Optional[bytes] = None


@dataclass
class ProgramResult:
    status: str                      # ok | unsupported | error
    reason: str = ""
    stages: Dict[str, StageResult] = field(default_factory=dict)
    warnings: List[str] = field(default_factory=list)


def inline_sampler_msl(name, state):
    """Unity inline sampler state -> MSL constexpr sampler, in UnityShaderCompiler/HLSLcc syntax.
    bits 0-1 filter (0 point, 1 linear, 2 trilinear), 2-3/4-5/6-7 wrap U/V/W (0 repeat, 1 clamp,
    2 mirror, 3 mirror-once), bit 8 compare, bits 9-11 log2(anisotropy)."""
    filt = state & 3
    wu, wv, ww = (state >> 2) & 3, (state >> 4) & 3, (state >> 6) & 3
    cmp_ = (state >> 8) & 1
    aniso = 1 << ((state >> 9) & 7)
    s = f"constexpr sampler {name}("
    if cmp_:
        s += "compare_func::greater_equal,"   # Unity Metal uses reversed Z
    s += ("filter::linear,mip_filter::linear," if filt == 2 else
          "filter::linear,mip_filter::nearest," if filt == 1 else "filter::nearest,")
    if aniso > 1:
        s += f"max_anisotropy({aniso}),"
    if WRAP[wu] == WRAP[wv] == WRAP[ww]:
        s += f"address::{WRAP[wu]}"
    else:
        s += f"s_address::{WRAP[wu]},t_address::{WRAP[wv]},r_address::{WRAP[ww]}"
    return s + ");"


def _key(b: P.Binding):
    return ((b.index >> 16) & 0xFF, b.index & 0xFFFF)


@dataclass
class Options:
    msl_version: int = 20100
    framebuffer_fetch: bool = True   # emit Unity's has_framebuffer_fetch dual path for input attachments
    depth_textures: bool = True      # textures used with depth-compare ops -> depth2d<float> (HLSLcc's rule)
    unity_cb_names: bool = True      # VGlobals<n>/PGlobals<n> -> VGlobals/FGlobals (Unity Metal's names)


def translate_program(pe: G.ProgramEntry, vkp: P.Params, tc, opts: Options = None) -> ProgramResult:
    """One Unity Vulkan program entry (SMOL-V streams) -> MetalVS + MetalFS stage results."""
    try:
        spvs = [tc.smolv_decode(sm) for _, sm in G.decode_vulkan(pe.data).streams]
    except Exception as ex:  # noqa: BLE001 - reported per program
        return ProgramResult("error", f"{type(ex).__name__}: {ex}")
    return translate_modules(spvs, pe, vkp, tc, opts)


def translate_modules(spvs, pe: G.ProgramEntry, vkp: P.Params, tc, opts: Options = None) -> ProgramResult:
    """Decoded SPIR-V modules of one program (any order) -> stage results. `pe` supplies the VS bind channels
    (sourceMap, channels); `vkp` the Vulkan parameter entry with the pass's common cbuffers merged."""
    opts = opts or Options()
    res = ProgramResult("ok")
    try:
        mods = {}
        for spv in spvs:
            m = sp.Module.from_bytes(spv).analyze()
            if m.model in mods:
                raise Unsupported(f"two {m.model} stages")
            mods[m.model] = m
        if any(CAP_MULTIVIEW in m.capabilities for m in mods.values()):
            raise Unsupported("stereo multiview variant (SPV_KHR_multiview; stereo is off on Mac)")
        other = sorted(set(mods) - {"vert", "frag"})
        if other:
            raise Unsupported("stage(s) " + ",".join(other) + " (Metal has no geometry/tessellation stage here)")
        if "vert" not in mods or "frag" not in mods:
            raise Unsupported(f"stages {sorted(mods)} (need vert+frag)")
        spec_values = _instancing_spec(vkp)
        vs_out = {v.location: v for v in mods["vert"].interface(sp.SC_Output) if v.location is not None}
        for model in ("vert", "frag"):
            res.stages[model] = _stage(model, mods[model], pe, vkp, tc, opts, spec_values, vs_out)
    except Unsupported as ex:
        return ProgramResult("unsupported", str(ex))
    except Exception as ex:  # noqa: BLE001 - reported per program
        return ProgramResult("error", f"{type(ex).__name__}: {ex}")
    for st in res.stages.values():
        res.warnings += [f"{st.model}: {w}" for w in st.warnings]
    res.warnings += interface_mismatches(res.stages["vert"].msl, res.stages["frag"].msl)
    return res


_USER_RE = re.compile(r"^\s*(\w+(?:<[^>]*>)?)\s+(\w+)\s*\[\[user\((\w+)\)[^\]]*\]\];", re.M)


def interface_mismatches(vs_msl, fs_msl):
    """Metal links VS outputs to FS inputs by [[user(name)]]: every FS input must be written by the VS
    with the same type, or pipeline creation fails on the Mac. Returns problems (empty = OK)."""
    def users(msl, struct):
        i = msl.find(f"struct {struct}")
        if i < 0:
            return {}
        body = msl[i:msl.index("};", i)]
        return {u: t for t, _, u in _USER_RE.findall(body)}
    vo = users(vs_msl, "xlatMtlMain_out")
    fi = users(fs_msl, "xlatMtlMain_in")
    out = []
    for u, t in fi.items():
        if u not in vo:
            out.append(f"interface: FS input {u} not written by VS")
        elif vo[u] != t:
            out.append(f"interface: {u} VS {vo[u]} != FS {t}")
    return out


def _instancing_spec(vkp):
    """Spec constants listed in the Vulkan global block -> fixed values for Metal.
    UNITY_RUNTIME_INSTANCING_ARRAY_SIZE sizes the UnityInstancing_* struct arrays; Unity's own Metal
    programs index those through an unbounded pointer, so we size the arrays to cover a 64 KiB buffer."""
    vals = {}
    for m in vkp.cbuffers[0].members:
        if m.name == INSTANCING_SPEC_NAME:
            biggest = max((s.struct_size for c in vkp.cbuffers for s in c.structs
                           if c.name.startswith("UnityInstancing")), default=16)
            vals[m.index & 0xFFFF] = max(2, INSTANCING_MAX_BYTES // max(biggest, 1))
    return vals


def _stage(model, mod: sp.Module, pe, vkp: P.Params, tc, opts, spec_values, vs_out) -> StageResult:
    warnings, features = [], set()
    res = mod.resources()
    by_key = {}
    for b in vkp.bindings:
        by_key.setdefault(_key(b), []).append(b)

    def binding_for(r, kinds):
        for b in by_key.get((r.set or 0, r.binding or 0), []):
            if b.kind in kinds:
                return b
        return None

    used = [r for r in res.values() if r.used]
    # order resources the way the Vulkan parameter entry lists them (stable, mirrors Unity's order)
    order = {id(b): i for i, b in enumerate(vkp.bindings)}

    def ordkey(r):
        b = binding_for(r, (0, 1, 2, 3, 4))
        return (order.get(id(b), 1 << 20) if b else 1 << 20, r.binding or 0, r.var_id)

    used.sort(key=ordkey)

    # ---- inline samplers (kind 4) become constexpr samplers; texture-paired samplers get slots
    inline = {}
    for r in used:
        if r.kind == sp.R_SAMPLER:
            b = binding_for(r, (P.KIND_SAMPLER,))
            if b is not None:
                inline[r.var_id] = b.extra[0]
    buf_slot, tex_slot, smp_slot = 0, 0, 0
    slot_of = {}   # var_id -> metal slot
    # combined image samplers share one decoration binding -> same texture and sampler slot
    for r in used:
        if r.kind == sp.R_COMBINED:
            k = max(tex_slot, smp_slot)
            slot_of[r.var_id] = k
            tex_slot, smp_slot = k + 1, k + 1
    for r in used:
        if r.kind in (sp.R_UBO, sp.R_SSBO):
            slot_of[r.var_id] = buf_slot
            buf_slot += 1
        elif r.kind in (sp.R_SAMPLED_IMAGE, sp.R_STORAGE_IMAGE, sp.R_TEXEL_BUFFER, sp.R_INPUT_ATTACHMENT):
            slot_of[r.var_id] = tex_slot
            tex_slot += 1
    for r in used:
        if r.kind == sp.R_SAMPLER and r.var_id not in inline:
            slot_of[r.var_id] = smp_slot
            smp_slot += 1
    inline_slot = {}
    for vid in inline:      # temporary slots; removed from the signature by the MSL post-pass
        inline_slot[vid] = smp_slot
        slot_of[vid] = smp_slot
        smp_slot += 1
    n_real_samplers = smp_slot - len(inline)
    if n_real_samplers > MAX_SAMPLERS:
        raise Unsupported(f"{model}: {n_real_samplers} samplers > {MAX_SAMPLERS}")
    if buf_slot - 1 > MAX_BUFFER_SLOT:
        raise Unsupported(f"{model}: buffer slot {buf_slot - 1} > {MAX_BUFFER_SLOT}")
    if tex_slot > MAX_TEXTURES:
        raise Unsupported(f"{model}: {tex_slot} textures")

    # ---- Metal parameter entry
    params = P.empty()
    cb_rename = (_cb_renames([binding_for(r, (P.KIND_CBUFFER,)) for r in used if r.kind == sp.R_UBO])
                 if opts.unity_cb_names else {})
    vsampler_to_metal = {}  # Vulkan sampler (set,binding) -> metal sampler slot
    for r in used:
        if r.kind == sp.R_SAMPLER and r.var_id not in inline:
            vsampler_to_metal[(r.set or 0, r.binding or 0)] = slot_of[r.var_id]
    for r in used:
        slot = slot_of.get(r.var_id)
        if r.kind == sp.R_UBO:
            b = binding_for(r, (P.KIND_CBUFFER,))
            if b is None:
                warnings.append(f"UBO set={r.set} binding={r.binding} has no Vulkan parameter entry")
                continue
            cb = vkp.cbuffer(b.name)
            if cb is None:
                warnings.append(f"cbuffer {b.name} layout missing")
                continue
            offs = set(mod.block_offsets(r.var_id))
            bad = [m.name for m in cb.members if m.index not in offs] + \
                  [s.name for s in cb.structs if s.index not in offs]
            if bad:   # every described member must start at a member offset of the SPIR-V block
                warnings.append(f"cbuffer {cb.name}: {len(bad)} members not at a SPIR-V member offset "
                                f"({', '.join(bad[:3])})")
            unused = len(offs) - len({m.index for m in cb.members} | {s.index for s in cb.structs})
            if unused > 0:
                features.add("cb_members_undescribed")
            name = cb_rename.get(cb.name, cb.name)
            params.cbuffers.append(P.CBuffer(name, cb.size, list(cb.members), list(cb.structs)))
            params.bindings.append(P.Binding(name, P.KIND_CBUFFER, slot, b.extra))
        elif r.kind == sp.R_SSBO:
            b = binding_for(r, (P.KIND_BUFFER, P.KIND_UAV))
            if b is None:
                warnings.append(f"SSBO set={r.set} binding={r.binding} has no Vulkan parameter entry")
                continue
            extra = b.extra if b.kind == P.KIND_BUFFER else (slot,)
            params.bindings.append(P.Binding(b.name, b.kind, slot, extra))
        elif r.kind in (sp.R_SAMPLED_IMAGE, sp.R_COMBINED, sp.R_INPUT_ATTACHMENT, sp.R_TEXEL_BUFFER):
            b = binding_for(r, (P.KIND_TEXTURE,))
            if b is None:
                warnings.append(f"texture set={r.set} binding={r.binding} has no Vulkan parameter entry")
                continue
            samp, dim = b.extra
            if r.kind == sp.R_COMBINED:
                msamp = slot
            elif samp == -1 or samp == 0xFFFFFFFF:
                msamp = -1
            else:
                sk = ((samp >> 16) & 0xFF, samp & 0xFFFF)
                msamp = vsampler_to_metal.get(sk, -1)
                if msamp == -1:
                    warnings.append(f"texture {b.name}: sampler binding {sk} not used by this stage")
            params.bindings.append(P.Binding(b.name, P.KIND_TEXTURE, slot, (msamp, dim)))
            if r.kind == sp.R_INPUT_ATTACHMENT:
                features.add("fbfetch")
        elif r.kind == sp.R_STORAGE_IMAGE:
            b = binding_for(r, (P.KIND_UAV, P.KIND_TEXTURE))
            if b is None:
                warnings.append(f"storage image set={r.set} binding={r.binding} has no parameter entry")
                continue
            params.bindings.append(P.Binding(b.name, b.kind, slot, (slot,) if b.kind == P.KIND_UAV else b.extra))
        elif r.kind == sp.R_SAMPLER and r.var_id not in inline:
            # paired texture sampler: Unity binds the texture's sampler at the texture's samplerIndex
            if not any(bb.kind == P.KIND_TEXTURE and bb.extra[0] == slot for bb in params.bindings):
                warnings.append(f"sampler binding {r.binding} not referenced by any texture")

    # ---- patch SPIR-V: bindings -> metal slots, spec constants -> constants
    for vid, slot in slot_of.items():
        if not mod.set_decoration(vid, sp.DecBinding, slot):
            mod.add_decoration(vid, sp.DecBinding, slot)
        mod.set_decoration(vid, sp.DecDescriptorSet, 0)
    spec_defaults = mod.spec_constant_defaults()
    unknown_specs = sorted(set(spec_defaults) - set(spec_values))
    if unknown_specs:
        warnings.append(f"spec constants {unknown_specs} fixed to their defaults")
    mod.specialize(spec_values)
    if model == "vert" and not mod.make_position_invariant():
        warnings.append("no Position output to mark invariant")

    args = ["--msl", "--msl-version", str(opts.msl_version), "--msl-decoration-binding",
            "--rename-entry-point", "main", "xlatMtlMain", model]
    if model == "vert":
        args.append("--flip-vert-y")
    else:
        args.append("--msl-pad-fragment-output")
        for v in mod.interface(sp.SC_Input):
            if v.location is None or v.builtin is not None:
                continue
            o = vs_out.get(v.location)
            if o is None:
                warnings.append(f"FS input location {v.location} not written by VS")
            elif o.components > v.components and v.component == 0 and o.component == 0:
                fmt = "any32" if o.scalar in ("f32", "i32", "u32") else "other"
                args += ["--msl-shader-input", str(v.location), fmt, str(o.components)]
    spv = mod.to_bytes()
    msl = tc.cross(spv, args)
    if opts.depth_textures:
        msl = depth_textures(msl, features)
    msl, word9 = _postprocess(msl, model, {slot_of[v]: st for v, st in inline.items()}, mod, features, slot_of)

    st = StageResult(model, msl, params, header_word9=word9, features=features, warnings=warnings, spirv=spv)
    if model == "vert" and not has_unity_yflip(msl):
        warnings.append("Unity's Vulkan y-flip not found before SPIRV-Cross's --flip-vert-y")
    if model == "vert":
        st.source_map = pe.source_map
        st.channels = sorted(pe.channels, key=lambda c: c[1])
        locs = {v.location for v in mod.interface(sp.SC_Input) if v.location is not None and v.builtin is None}
        targets = {t - G.CHANNEL_TARGET_ATTRIB0 for _, t in pe.channels}
        if not locs <= targets:
            warnings.append(f"vertex inputs {sorted(locs - targets)} have no bind channel")
    return st


_GLOBALS_RE = re.compile(r"^(VGlobals|PGlobals)\d+$")
_UNITY_GLOBALS = {"VGlobals": "VGlobals", "PGlobals": "FGlobals"}


def _cb_renames(bindings):
    """Unity's Vulkan globals blocks are VGlobals<n> / PGlobals<n> (decimal suffix); Unity's Metal programs name
    them VGlobals (VS) and FGlobals (FS) (golden: 109 VS / 68 FS parameter entries, no other spelling). The
    runtime binds by the parameter entry; m_NameIndices never lists these names. Renamed only when the new name
    stays unique within the stage."""
    names = [b.name for b in bindings if b is not None]
    out = {}
    for n in names:
        m = _GLOBALS_RE.match(n)
        if m:
            out[n] = _UNITY_GLOBALS[m.group(1)]
    new = list(out.values()) + [n for n in names if n not in out]
    if len(set(new)) != len(new):
        return {}
    return out


_DEPTH_TYPES = {"texture2d": "depth2d", "texture2d_array": "depth2d_array", "texturecube": "depthcube",
                "texturecube_array": "depthcube_array"}
_DEPTH_PARAM_RE = re.compile(r"\b(texture2d|texture2d_array|texturecube|texturecube_array)<float((?:, access::\w+)?)> "
                             r"(\w+) \[\[texture\(\d+\)")
_DEPTH_CAST_HELPER_RE = re.compile(r"template <typename T>\nstatic inline depth\w*<T> spvDepthCast\([^)]*\)\n\{\n"
                                   r"[^}]*\}\n\n")
_DEPTH_CAST_USE_RE = re.compile(r"spvDepthCast\((?!texture\w*<T> t\))")
_DEPTH_OK_USE_RE = r"\.(?:sample|read|get_width|get_height|get_depth|get_num_mip_levels|get_array_size)\("


def depth_textures(msl, features):
    """Unity's HLSLcc declares a texture `depth2d<float, access::sample >` when the DXBC uses it with a comparison
    sampler (sample_c / sample_c_lz / gather4_c; decode.cpp MarkTextureAsShadow, per register). SPIRV-Cross keeps
    `texture2d<float>` and wraps every Dref call in `spvDepthCast(tex)`; the Dref uses are exactly the sample_c
    sites, so we apply HLSLcc's rule: an entry-point texture that appears in spvDepthCast() becomes depthXX<float>.
    Its non-compare reads return a scalar on a depth texture; like HLSLcc (which drops the swizzle), the value is
    the depth, so we widen it with float4(...). Textures used any other way (gather, passed to functions) keep
    texture2d + spvDepthCast, which also compiles."""
    sig = _SIG_RE.search(msl)
    if not sig or "spvDepthCast(" not in msl:
        return msl
    body = msl[sig.end():]
    changed = []
    for m in _DEPTH_PARAM_RE.finditer(sig.group(3)):
        kind, access, name = m.groups()
        cast = f"spvDepthCast({name})"
        if cast not in body:
            continue
        rest = re.sub(re.escape(cast), "", body)
        rest = re.sub(r"(?<![A-Za-z0-9_])" + re.escape(name) + _DEPTH_OK_USE_RE, "", rest)
        if re.search(r"(?<![A-Za-z0-9_])" + re.escape(name) + r"(?![A-Za-z0-9_])", rest):
            continue
        body = body.replace(cast, name)
        body = _wrap_calls(body, name, ("sample", "read"), "float4(", ")")
        changed.append((m.group(0), m.group(0).replace(f"{kind}<float", f"{_DEPTH_TYPES[kind]}<float", 1)))
    if not changed:
        return msl
    head = msl[:sig.end()]
    for old, new in changed:
        head = head.replace(old, new, 1)
    msl = head + body
    if not _DEPTH_CAST_USE_RE.search(msl):
        msl = _DEPTH_CAST_HELPER_RE.sub("", msl)
    features.add("depth_texture")
    return msl


def _wrap_calls(text, name, methods, pre, post):
    """name.method(...) -> pre + name.method(...) + post, with balanced-parenthesis matching."""
    pat = re.compile(r"(?<![A-Za-z0-9_])" + re.escape(name) + r"\.(?:" + "|".join(methods) + r")\(")
    out, pos = [], 0
    while True:
        m = pat.search(text, pos)
        if not m:
            break
        depth, j = 1, m.end()
        while depth and j < len(text):
            depth += {"(": 1, ")": -1}.get(text[j], 0)
            j += 1
        if text[:m.start()].endswith(pre) and text[j:].startswith(post):    # already wrapped by SPIRV-Cross
            out.append(text[pos:j])
        else:
            out.append(text[pos:m.start()] + pre + text[m.start():j] + post)
        pos = j
    out.append(text[pos:])
    return "".join(out)


_YFLIP_TAIL = "out.gl_Position.y = -(out.gl_Position.y);    // Invert Y-axis for Metal"


def has_unity_yflip(msl):
    """True if, right before SPIRV-Cross's own --flip-vert-y line, the shader negates gl_Position.y
    (Unity's Vulkan convention): either `out.gl_Position.y = -out.gl_Position.y;` or via a temporary
    `float _N = -out.gl_Position.y; out.gl_Position.y = _N;`."""
    i = msl.rfind(_YFLIP_TAIL)
    if i < 0:
        return False
    body = msl[:i].rstrip().split("\n")
    last = [ln.strip() for ln in body if "gl_Position" in ln]
    if not last:
        return False
    if last[-1] == "out.gl_Position.y = -out.gl_Position.y;":
        return True
    m = re.fullmatch(r"out\.gl_Position\.y = (_\d+);", last[-1])
    return bool(m and len(last) >= 2 and last[-2] == f"float {m.group(1)} = -out.gl_Position.y;")


_SIG_RE = re.compile(r"^(vertex|fragment) (\S+) xlatMtlMain\((.*)\)\s*$", re.M)


def _split_params(sig):
    out, depth, cur = [], 0, ""
    for ch in sig:
        if ch in "([<":
            depth += 1
        elif ch in ")]>":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def _postprocess(msl, model, inline, mod, features, slot_of):
    """Apply Unity's Metal conventions to SPIRV-Cross output. Returns (msl, header word 9)."""
    head_decls, body_pre, fb_reads = [], [], {}
    if model == "frag":
        outs = sorted({int(x) for x in re.findall(r"\[\[color\((\d+)\)", msl)})
        if outs:
            msl = re.sub(r"\[\[color\((\d+)\)", r"[[color(rp_output_remap_\1)", msl)
            head_decls.append("constant uint32_t rp_output_remap_mask [[ function_constant(1) ]];")
            for n in outs:
                head_decls.append(f"constant const uint rp_output_remap_{n} = (rp_output_remap_mask >> {4 * n}) & 0xF;")
    m = _SIG_RE.search(msl)
    if not m:
        raise ValueError("entry point signature not found in SPIRV-Cross output")
    plist = _split_params(m.group(3))

    # inline samplers -> constexpr samplers at the top of the entry function
    if inline:
        keep = []
        names = {}
        for p in plist:
            mm = re.match(r"sampler (\w+) \[\[sampler\((\d+)\)\]\]$", p)
            if mm:
                names[int(mm.group(2))] = mm.group(1)
            keep.append(p)
        state_by_slot = inline  # metal sampler slot -> Unity inline sampler state
        newp = []
        for p in keep:
            mm = re.match(r"sampler (\w+) \[\[sampler\((\d+)\)\]\]$", p)
            if mm and int(mm.group(2)) in state_by_slot:
                body_pre.append("    " + inline_sampler_msl(mm.group(1), state_by_slot[int(mm.group(2))]))
                features.add("constexpr_sampler")
                continue
            newp.append(p)
        plist = newp

    word9 = 37
    if model == "vert":
        if "[[render_target_array_index]]" in msl.replace(" ", "") or "render_target_array_index" in msl:
            word9 = 39
            features.add("layer")
        for builtin, var, base_attr, base_var in (("instance_id", "gl_InstanceIndex", "base_instance",
                                                    "mtl_BaseInstance"),
                                                   ("vertex_id", "gl_VertexIndex", "base_vertex", "mtl_BaseVertex")):
            for i, p in enumerate(plist):
                mm = re.match(r"uint (\w+) \[\[" + builtin + r"\]\]$", p)
                if mm:
                    plist.insert(i + 1, f"uint {base_var} [[ {base_attr}, function_constant(has_base_vertex_instance) ]]")
                    body_pre.append(f"    if(has_base_vertex_instance)\n        {mm.group(1)} = {mm.group(1)} - {base_var};")
                    features.add("base_" + builtin)
                    break
        if any(f.startswith("base_") for f in features):
            head_decls.append("constant bool has_base_vertex_instance [[ function_constant(4) ]];")
    else:
        if "fbfetch" in features:
            plist, fb_decls, fb_pre, fb_reads = _framebuffer_fetch(plist, msl, mod, slot_of)
            head_decls += fb_decls
            body_pre += fb_pre

    sig = f"{m.group(1)} {m.group(2)} xlatMtlMain({', '.join(plist)})"
    tail = msl[m.end():]
    if model == "frag" and "fbfetch" in features and fb_reads:
        tail = _wrap_reads(tail, fb_reads)
    msl = msl[:m.start()] + sig + tail
    if body_pre:
        i = msl.index("{", msl.index(sig) + len(sig))
        msl = msl[:i + 1] + "\n" + "\n".join(body_pre) + msl[i + 1:]
    if head_decls:
        anchor = "using namespace metal;\n"
        i = msl.index(anchor) + len(anchor)
        msl = msl[:i] + "\n" + "\n".join(head_decls) + "\n" + msl[i:]
    return msl, word9


def _framebuffer_fetch(plist, msl, mod, slot_of):
    """SPIRV-Cross (without --msl-framebuffer-fetch) emits each input attachment as
    `texture2d[_ms]<T> NAME [[texture(N)]]` read at gl_FragCoord. Unity's Metal convention (format strings in
    UnityShaderCompiler.exe; Unity names the fallback texture hlslcc_fbinput_K in the parameter entry, as
    PEAK's Vulkan entry does): keep the texture under function_constant(has_no_framebuffer_fetch) and add
    `T4 hlslcc_fbfetch_K [[ color(rp_input_remap_K), function_constant(has_framebuffer_fetch) ]]`.
    Unity guards color() inputs with `#if __METAL_VERSION__ >= 230`; we do the same with macros that drop
    the input below 2.3, so the program compiles under any -std (fallback path only)."""
    res = mod.resources()
    decls = ["constant uint32_t rp_input_remap_mask [[ function_constant(0) ]];",
             "constant bool has_framebuffer_fetch [[ function_constant(2) ]];",
             "constant bool has_no_framebuffer_fetch = !has_framebuffer_fetch;"]
    pre, reads = [], {}
    newp = list(plist)
    for r in res.values():
        if r.kind != sp.R_INPUT_ATTACHMENT or not r.used:
            continue
        slot = slot_of.get(r.var_id)
        k = r.input_attachment_index or 0
        for i, p in enumerate(newp):
            mm = re.match(r"(texture2d(?:_ms)?<(\w+)(?:, [^>]*)?>) (\w+) \[\[texture\(" + str(slot) + r"\)\]\]$", p)
            if not mm:
                continue
            ttype, scal, name = mm.group(1), mm.group(2), mm.group(3)
            newp[i] = (f"{ttype} {name} [[texture({slot}), function_constant(has_no_framebuffer_fetch)]] "
                       f"HLSLCC_FBFETCH_PARAM({scal}4, {k})")
            decls.append(f"constant const uint rp_input_remap_{k} = (rp_input_remap_mask >> {4 * k}) & 0xF;")
            reads[name] = k
            break
    decls += ["#if __METAL_VERSION__ >= 230",
              "#define HLSLCC_FBFETCH_PARAM(T, k) , T hlslcc_fbfetch_##k [[ color(rp_input_remap_##k), "
              "function_constant(has_framebuffer_fetch) ]]",
              "#define HLSLCC_FBFETCH(k, fallback) (has_framebuffer_fetch ? hlslcc_fbfetch_##k : (fallback))",
              "#else",
              "#define HLSLCC_FBFETCH_PARAM(T, k)",
              "#define HLSLCC_FBFETCH(k, fallback) (fallback)",
              "#endif"]
    return newp, decls, pre, reads


def _wrap_reads(text, reads):
    """name.read(...) -> HLSLCC_FBFETCH(k, name.read(...)) with balanced-parenthesis matching."""
    for name, k in reads.items():
        out, pos = [], 0
        pat = re.compile(r"(?<![A-Za-z0-9_])" + re.escape(name) + r"\.read\(")
        while True:
            m = pat.search(text, pos)
            if not m:
                break
            depth, j = 1, m.end()
            while depth and j < len(text):
                depth += {"(": 1, ")": -1}.get(text[j], 0)
                j += 1
            out.append(text[pos:m.start()] + f"HLSLCC_FBFETCH({k}, {text[m.start():j]})")
            pos = j
        out.append(text[pos:])
        text = "".join(out)
    return text
