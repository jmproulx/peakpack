"""Vulkan (SPIR-V) -> Metal (MSL) translation of Unity 6000.3 ComputeShader variants.

Input is a decoded ``ComputeShaderPlatformVariant`` with ``targetRenderer == 21`` (Vulkan); output is
an equivalent variant with ``targetRenderer == 16`` (Metal) in the exact encoding of Unity's own Metal
compute shaders (see ``metalblob`` and the golden-reference tests).

How each piece maps (every rule is checked against the Mac player's golden compute shaders by
``tests/test_compute_golden.py``):

* Vulkan ``bindPoint`` = ``binding | set << 16 | flags`` (flags in bits 23..31: 0x00800000 image,
  0x02000000 UAV, 0x80000000 storage image; ignored here). Every reflected resource is matched to its
  SPIR-V variable through (set, binding).
* Metal slots are assigned like Unity's HLSLcc Metal backend (``BindingSlotAllocator``):
  UAVs are *reserved* at their HLSL ``u`` register (recovered from SPIR-V names ``*_origX<n>X``),
  buffer UAVs in buffer space, texture UAVs in texture space; then constant buffers, then SRVs
  (in Vulkan binding order, i.e. HLSL register order) take the lowest free slot of their space.
  The SPIR-V Binding/DescriptorSet decorations are rewritten to those slots and SPIRV-Cross is run
  with ``--msl-decoration-binding``.
* Unity "inline" samplers (``builtinSamplers``, e.g. ``sampler_PointClamp``) become MSL
  ``constexpr sampler`` declarations, exactly like HLSLcc does on Metal, and are not reflected.
* ``RWBuffer<T>`` / ``Buffer<T>`` (SPIR-V texel buffers) become ``device T*`` buffers in buffer
  space, as HLSLcc does ("typed buffers are faked using structured buffers").
* ``$Globals`` is called ``CGlobals`` on Vulkan and ``Globals`` on Metal.
* Constant-buffer params keep Vulkan's names/offsets/array/row/col (they equal the SPIR-V Offset
  decorations, which SPIRV-Cross honours), sorted by offset; the type comes from the SPIR-V member
  (Vulkan reflection reports uint as int): 0 float, 1 int, 2 bool, 3 half, 4 short, 5 uint.
* Entry point ``computeMain``; thread-group size from the SPIR-V LocalSize (== reflection).
"""
from __future__ import annotations

import os
import re
import subprocess
import tempfile
from dataclasses import dataclass, field

from . import metalblob, metalfix, spirv

RENDERER_METAL = 16
RENDERER_VULKAN = 21
DEFAULT_MSL_VERSION = 20100        # MSL 2.1 (macOS 10.14+); configurable
MAX_BUFFER_SLOTS = 31
MAX_TEXTURE_SLOTS = 31             # Unity/HLSLcc MAX_RESOURCE_BINDINGS is 32 slots; keep in Metal's 31
MAX_THREADGROUP_MEMORY = 32768
MAX_THREADS_PER_GROUP = 1024

_ORIG_REG = re.compile(r"_origX(\d+)X")
_COUNTER = re.compile(r"(.+)_origX\d+X_counterBuf")

PARAM_FLOAT, PARAM_INT, PARAM_BOOL, PARAM_HALF, PARAM_SHORT, PARAM_UINT = 0, 1, 2, 3, 4, 5


class TranslateError(Exception):
    """Kernel cannot be translated; ``category`` groups failures in the report."""

    def __init__(self, category, msg):
        super().__init__(f"{category}: {msg}")
        self.category = category


@dataclass
class KernelResult:
    status: str                       # ok | unsupported | failed
    kernel: dict | None               # Metal ComputeShaderKernel (uniqueVariant) dict
    msl: str = ""
    category: str = ""
    message: str = ""
    notes: list = field(default_factory=list)
    census: dict = field(default_factory=dict)
    cb_types: dict = field(default_factory=dict)  # cb name -> {member name: param type}


# ------------------------------------------------------------------------------------------------
def find_spirv_cross(explicit=None):
    """Path of spirv-cross, by the package-wide rules in peakmetal.tools (explicit, $PEAKMETAL_SPIRV_CROSS,
    $PEAKMETAL_BIN, <native>/bin, PATH). Raises FileNotFoundError when absent."""
    from .. import tools
    try:
        return tools.find_spirv_cross(explicit)[0]
    except tools.ToolError as ex:
        raise FileNotFoundError(str(ex)) from ex


def vk_binding(bind_point):
    bp = bind_point & 0xFFFFFFFF
    return (bp >> 16) & 0x7F, bp & 0xFFFF


def decode_inline_sampler(state):
    """Unity packed inline sampler state -> MSL constexpr sampler arguments (HLSLcc wording).

    bits 0-1 filter (0 point, 1 linear, 2 trilinear), 2-3 / 4-5 / 6-7 wrap U/V/W
    (0 repeat, 1 clamp, 2 mirror, 3 mirror-once), bit 8 compare (reject: not seen in compute).
    """
    if state & ~0xFF:
        raise TranslateError("inline-sampler", f"unknown sampler state bits {state:#x}")
    filt = state & 3
    wraps = [(state >> s) & 3 for s in (2, 4, 6)]
    args = []
    if filt == 2:
        args.append("filter::linear,mip_filter::linear")
    elif filt == 1:
        args.append("filter::linear,mip_filter::nearest")
    elif filt == 0:
        args.append("filter::nearest")
    else:
        raise TranslateError("inline-sampler", f"bad filter in {state:#x}")
    names = {0: "repeat", 1: "clamp_to_edge", 2: "mirrored_repeat", 3: "mirrored_repeat"}
    args += [f"s_address::{names[wraps[0]]}", f"t_address::{names[wraps[1]]}", f"r_address::{names[wraps[2]]}"]
    return ",".join(args)


class _Slots:
    """HLSLcc BindingSlotAllocator: lowest free slot first; reservations remove a slot."""

    def __init__(self, n, space):
        self.free = list(range(n))
        self.space = space

    def reserve(self, slot):
        if slot not in self.free:
            raise TranslateError("binding", f"{self.space} slot {slot} reserved twice or out of range")
        self.free.remove(slot)
        return slot

    def take(self):
        if not self.free:
            raise TranslateError("binding", f"out of Metal {self.space} slots")
        return self.free.pop(0)


def _param_type(m, tid):
    t = m.types[tid]
    while t[0] in ("vector", "matrix", "array"):
        tid = t[1]
        t = m.types[tid]
    if t[0] == "float":
        return PARAM_HALF if t[1] == 16 else PARAM_FLOAT
    if t[0] == "int":
        if t[1] == 16:
            return PARAM_SHORT
        return PARAM_INT if t[2] else PARAM_UINT
    if t[0] == "bool":
        return PARAM_BOOL
    return None


def _type_size_msl(m, tid):
    """(size, align) of a type in MSL threadgroup memory (vec3 = 16 bytes)."""
    t = m.types[tid]
    k = t[0]
    if k in ("int", "float"):
        s = t[1] // 8
        return s, s
    if k == "bool":
        return 1, 1
    if k == "vector":
        s, _ = _type_size_msl(m, t[1])
        n = 4 if t[2] == 3 else t[2]
        return s * n, s * n
    if k == "matrix":
        cs, ca = _type_size_msl(m, t[1])
        return cs * t[2], ca
    if k == "array":
        es, ea = _type_size_msl(m, t[1])
        es = (es + ea - 1) // ea * ea
        return es * (m.const_int(t[2]) or 0), ea
    if k == "struct":
        off, al = 0, 1
        for mt in t[1]:
            s, a = _type_size_msl(m, mt)
            off = (off + a - 1) // a * a + s
            al = max(al, a)
        return (off + al - 1) // al * al, al
    raise TranslateError("threadgroup-memory", f"unsized type {k}")


def threadgroup_memory(m):
    total = 0
    for v in m.variables.values():
        if v.storage_class == spirv.SC_WORKGROUP:
            s, a = _type_size_msl(m, v.type_id)
            total = (total + 15) // 16 * 16 + s
    return total


# ------------------------------------------------------------------------------------------------
def _split_args(s, angle=False):
    """Split argument text at top-level commas (``angle``: also nest <...>, for declarations)."""
    opn, cls = ("([{<", ")]}>") if angle else ("([{", ")]}")
    out, depth, cur = [], 0, []
    for ch in s:
        if ch in opn:
            depth += 1
        elif ch in cls:
            depth -= 1
        if ch == "," and depth == 0:
            out.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    out.append("".join(cur).strip())
    return out


def _rewrite_calls(text, name, method, fn):
    """Replace every ``name.method(args)`` with fn(args list)."""
    pat = re.compile(r"\b" + re.escape(name) + r"\." + method + r"\(")
    out, pos = [], 0
    while True:
        mt = pat.search(text, pos)
        if not mt:
            break
        i, depth = mt.end(), 1
        while depth:
            if i >= len(text):
                raise TranslateError("texel-buffer", "unbalanced call")
            depth += {"(": 1, ")": -1}.get(text[i], 0)
            i += 1
        out.append(text[pos:mt.start()])
        out.append(fn(_split_args(text[mt.end():i - 1])))
        pos = i
    out.append(text[pos:])
    return "".join(out)


def _postprocess(msl, inline_samplers, texel_buffers):
    if "kernel void computeMain(" not in msl:
        raise TranslateError("spirv-cross", "entry point computeMain not emitted")
    head, sep, rest = msl.partition("kernel void computeMain(")
    sig, sep2, body = rest.partition(")\n{")
    if not sep2:
        raise TranslateError("spirv-cross", "could not find computeMain body")
    params = _split_args(sig, angle=True)
    decls = []
    for name, state in inline_samplers.items():
        before = len(params)
        params = [p for p in params if not re.fullmatch(r"sampler\s+" + re.escape(name) + r"\s*\[\[sampler\(\d+\)\]\]", p)]
        if len(params) != before:
            decls.append(f"\n    constexpr sampler {name}({decode_inline_sampler(state)});")
    for name, (elem, slot, access) in texel_buffers.items():
        found = False
        for i, p in enumerate(params):
            if re.fullmatch(r"texture_buffer<\w+, access::\w+>\s+" + re.escape(name) + r"\s*\[\[texture\(\d+\)\]\]", p):
                qual = "const device" if access == "read" else "device"
                params[i] = f"{qual} {elem}* {name} [[buffer({slot})]]"
                found = True
        if not found:
            raise TranslateError("texel-buffer", f"declaration of typed buffer {name} not found")
        body = _rewrite_calls(body, name, "write", lambda a, n=name: f"{n}[{a[1]}] = ({a[0]}).x")
        body = _rewrite_calls(body, name, "read", lambda a, n=name, e=elem: f"{e}4({n}[{a[0]}], 0, 0, 1)")
        if re.search(r"\b" + re.escape(name) + r"\.", body) or re.search(r"\b" + re.escape(name) + r"\b", head):
            raise TranslateError("texel-buffer", f"unsupported use of typed buffer {name}")
    return head + sep + ", ".join(params) + sep2 + "".join(decls) + body


def _run_spirv_cross(exe, spv, msl_version, extra=()):
    with tempfile.TemporaryDirectory(prefix="pmcs_") as td:
        src = os.path.join(td, "k.spv")
        dst = os.path.join(td, "k.metal")
        with open(src, "wb") as f:
            f.write(spv)
        cmd = [exe, src, "--msl", "--msl-version", str(msl_version), "--msl-decoration-binding",
               "--rename-entry-point", "main", "computeMain", "comp", "--output", dst, *extra]
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if p.returncode != 0 or not os.path.exists(dst):
            raise TranslateError("spirv-cross", (p.stderr or p.stdout).strip()[:500])
        with open(dst, encoding="utf-8") as f:
            return f.read()


# ------------------------------------------------------------------------------------------------
def translate_kernel(vk: dict, spirv_cross: str, msl_version=DEFAULT_MSL_VERSION) -> KernelResult:
    """Translate one Vulkan ComputeShaderKernel (a uniqueVariants entry)."""
    notes = []
    try:
        m = spirv.parse(bytes(vk["code"]))
    except spirv.SpirvError as e:
        return KernelResult("failed", None, category="spirv-parse", message=str(e))
    cen = spirv.census(m)
    try:
        if not m.entry_points or m.entry_points[0][0] != 5:
            raise TranslateError("spirv", "no GLCompute entry point")
        if m.local_size_is_id or m.local_size is None:
            raise TranslateError("threadgroup", "workgroup size is a specialization constant")
        tg = tuple(m.local_size)
        if list(tg) != list(vk["threadGroupSize"]):
            raise TranslateError("threadgroup", f"SPIR-V LocalSize {tg} != reflection {vk['threadGroupSize']}")
        if tg[0] * tg[1] * tg[2] > MAX_THREADS_PER_GROUP:
            raise TranslateError("threadgroup", f"{tg} exceeds {MAX_THREADS_PER_GROUP} threads")
        tgm = threadgroup_memory(m)
        cen["threadgroup_memory"] = tgm
        if tgm > MAX_THREADGROUP_MEMORY:
            raise TranslateError("threadgroup-memory", f"{tgm} bytes > {MAX_THREADGROUP_MEMORY}")
        if cen["image_texel_pointer"]:
            raise TranslateError("image-atomics", "texture atomics need MSL 3.1 / emulation")
        if cen["array_length"]:
            raise TranslateError("buffer-length", "OpArrayLength needs a buffer-size buffer Unity does not bind")
        if cen["subgroup_ops"]:
            notes.append("subgroup ops -> Metal simdgroup ops (Apple GPUs: 32-wide)")

        by_binding = {(v.set, v.binding): v for v in m.variables.values() if v.binding is not None}

        def var_of(entry):
            key = vk_binding(entry["bindPoint"])
            v = by_binding.get(key)
            if v is None:
                raise TranslateError("reflection", f"{entry['name']}: no SPIR-V variable at set/binding {key}")
            return v

        def base_type(v):
            tid = m.strip_type(v.type_id)[0]
            return tid, m.types[tid]

        def is_texel_buffer(t):
            return t[0] == "image" and t[2] == 5

        def reg_of(v):
            tid = m.strip_type(v.type_id)[0]
            for s in (v.name, m.names.get(tid, "")):
                mt = _ORIG_REG.search(s or "")
                if mt:
                    return int(mt.group(1))
            return None

        bufs = _Slots(MAX_BUFFER_SLOTS, "buffer")
        texs = _Slots(MAX_TEXTURE_SLOTS, "texture")
        smps = _Slots(16, "sampler")
        slot = {}          # id(entry) -> metal slot
        assign = {}        # var id -> (0, slot)
        covered = set()
        texel = {}         # var name in MSL -> (elem type, slot, access)

        # append/consume counters: Vulkan reflects them as extra UAVs '<buf>_origX<n>X_counterBuf';
        # Metal (HLSLcc) gives them the first free buffer slot after everything else and encodes it in
        # the owner's bindPoint as (slot + 1) << 16, without a reflection entry of their own.
        counters = {}
        for e in vk["outBuffers"]:
            mt = _COUNTER.fullmatch(e["name"])
            if mt:
                owner = [o for o in vk["outBuffers"] if o["name"] == mt.group(1)]
                if len(owner) != 1:
                    raise TranslateError("reflection", f"counter {e['name']} has no owner buffer")
                counters[id(e)] = (e, owner[0])

        # 1. UAVs at their HLSL register
        deferred = []
        for e in vk["outBuffers"]:
            if id(e) in counters:
                continue
            v = var_of(e)
            covered.add(v.id)
            _, t = base_type(v)
            space = texs if (t[0] == "image" and not is_texel_buffer(t)) else bufs
            r = reg_of(v)
            if r is None:
                deferred.append((e, v, space))
                continue
            slot[id(e)] = space.reserve(r)
            assign[v.id] = (0, slot[id(e)])
        # 2. constant buffers in register (binding) order
        for e in sorted(vk["cbs"], key=lambda e: vk_binding(e["bindPoint"])):
            v = var_of(e)
            covered.add(v.id)
            slot[id(e)] = bufs.take()
            assign[v.id] = (0, slot[id(e)])
        # 3. inline samplers (become constexpr; give SPIRV-Cross a slot meanwhile)
        inline = {}
        for s in vk["builtinSamplers"]:
            key = vk_binding(s["bindPoint"])
            v = by_binding.get(key)
            if v is None:
                raise TranslateError("reflection", f"inline sampler {s['sampler']:#x}: no variable at {key}")
            covered.add(v.id)
            assign[v.id] = (0, smps.take())
            inline[v.name] = s["sampler"]
            decode_inline_sampler(s["sampler"])
        # 4. SRVs (textures + read-only buffers) in binding order
        srvs = [(e, "textures") for e in vk["textures"]] + [(e, "inBuffers") for e in vk["inBuffers"]]
        for e, kind in sorted(srvs, key=lambda x: vk_binding(x[0]["bindPoint"])):
            v = var_of(e)
            covered.add(v.id)
            _, t = base_type(v)
            if t[0] == "image" and not is_texel_buffer(t):
                slot[id(e)] = texs.take()
            else:
                slot[id(e)] = bufs.take()
            assign[v.id] = (0, slot[id(e)])
            if e["samplerBindPoint"] != -1:
                raise TranslateError("sampler", f"{e['name']}: separate texture samplers not implemented")
        for e, v, space in deferred:
            slot[id(e)] = space.take()
            assign[v.id] = (0, slot[id(e)])
            notes.append(f"UAV {e['name']} has no _origX register; took {space.space} slot {slot[id(e)]}")
        counter_bits = {}
        for e, owner in sorted(counters.values(), key=lambda x: x[1]["name"]):
            v = var_of(e)
            covered.add(v.id)
            cs = bufs.take()
            assign[v.id] = (0, cs)
            counter_bits[id(owner)] = (cs + 1) << 16
            notes.append(f"append/consume counter of {owner['name']} -> buffer slot {cs}")

        # texel buffers -> device buffers
        for e in vk["outBuffers"] + vk["inBuffers"] + vk["textures"]:
            if id(e) in counters:
                continue
            v = var_of(e)
            _, t = base_type(v)
            if is_texel_buffer(t):
                elem = m.type_name(t[1])
                access = "read" if e in vk["textures"] or e in vk["inBuffers"] else "write"
                texel[v.name] = (elem, slot[id(e)], access)
                notes.append(f"typed buffer {e['name']} -> device {elem}* (buffer space)")
                if t[7] not in (0, 3, 24, 33):  # Unknown, R32f, R32i, R32ui
                    raise TranslateError("texel-buffer", f"{e['name']}: format {spirv.IMAGE_FORMATS.get(t[7])}")

        # every bound resource must be reflected
        for v in m.variables.values():
            if v.binding is not None and v.id not in covered:
                raise TranslateError("reflection", f"SPIR-V resource {v.name or v.id} is not in Unity's reflection")

        patched = spirv.patch_bindings(bytes(vk["code"]), assign)
        extra = ["--msl-texture-buffer-native"] if texel else []
        msl = _run_spirv_cross(spirv_cross, patched, msl_version, extra)
        msl = _postprocess(msl, inline, texel)
        msl, n_satinf = metalfix.fix_sat_inf(msl)
        if n_satinf:
            notes.append(f"STP_BUG_SAT_INF: {n_satinf} saturate(x * +-INF) rewritten to (x > 0 / x < 0) ? 1 : 0 "
                         "(Unity's Metal define; fast-math has no INF)")
        rw_fmt = {}
        for e in vk["outBuffers"]:
            if id(e) not in counters:
                v = var_of(e)
                _, t = base_type(v)
                if t[0] == "image":
                    rw_fmt[v.name] = (e["name"], spirv.IMAGE_FORMATS.get(t[7], t[7]))
        for mt in re.finditer(r"(texture\w*<\w+), access::read_write> (\w+) ", msl):
            uname, fmt = rw_fmt.get(mt.group(2), (mt.group(2), "?"))
            notes.append(f"read_write texture {uname} ({mt.group(1)}>, SPIR-V format {fmt}): Metal needs "
                         "read-write texture tier 2 for the bound RenderTexture format")

        # CB member types for the variant-level constantBuffers
        cb_types = {}
        for e in vk["cbs"]:
            v = var_of(e)
            tid, t = base_type(v)
            types = {}
            for name, mt, off, _ in spirv.struct_members(m, tid):
                pt = _param_type(m, mt)
                types[name] = pt
                mm = re.match(r"hlslcc_mtx\d+x\d+(.+)", name)
                if mm:
                    types[mm.group(1)] = pt
            cb_types[e["name"]] = types

        def res(e):
            return {"name": metal_cb_name(e["name"]) if e in vk["cbs"] else e["name"],
                    "generatedName": e["generatedName"], "bindPoint": slot[id(e)] | counter_bits.get(id(e), 0),
                    "samplerBindPoint": -1, "texDimension": e["texDimension"], "resType": e["resType"]}

        out = {
            "cbVariantIndices": list(vk["cbVariantIndices"]),
            "cbs": [res(e) for e in vk["cbs"]],
            "textures": [res(e) for e in vk["textures"]],
            "builtinSamplers": [],
            "inBuffers": [res(e) for e in vk["inBuffers"]],
            "outBuffers": [res(e) for e in vk["outBuffers"] if id(e) not in counters],
            "code": metalblob.MetalComputeBlob(msl, tg).encode(),
            "threadGroupSize": list(tg),
            "requirements": vk["requirements"],
        }
        return KernelResult("ok", out, msl, notes=notes, census=cen, cb_types=cb_types)
    except TranslateError as e:
        status = "unsupported" if e.category in ("image-atomics", "buffer-length", "threadgroup-memory",
                                                   "texel-buffer", "sampler", "inline-sampler") else "failed"
        return KernelResult(status, None, category=e.category, message=str(e), notes=notes, census=cen)


def metal_cb_name(name):
    return "Globals" if name == "CGlobals" else name


STUB_MSL = """#include <metal_stdlib>
using namespace metal;
// peakmetal: kernel '{name}' could not be translated ({why}); dispatch is a no-op.
kernel void computeMain(uint3 tid [[thread_position_in_grid]])
{{
}}
"""


def stub_kernel(vk: dict, name: str, why: str) -> dict:
    """A no-op Metal kernel with no resources, so FindKernel/Dispatch still succeed."""
    tg = tuple(vk["threadGroupSize"])
    msl = STUB_MSL.format(name=name, why=re.sub(r"[^\w .:/-]", "", why)[:120])
    return {"cbVariantIndices": [], "cbs": [], "textures": [], "builtinSamplers": [], "inBuffers": [],
            "outBuffers": [], "code": metalblob.MetalComputeBlob(msl, tg).encode(),
            "threadGroupSize": list(tg), "requirements": vk["requirements"]}


def translate_variant(vk_variant: dict, spirv_cross: str, msl_version=DEFAULT_MSL_VERSION,
                      on_failure="stub", log=None):
    """Return (metal_variant, [(kernel index, unique-variant index, kernel name, keywords, KernelResult)])."""
    if vk_variant["targetRenderer"] != RENDERER_VULKAN:
        raise ValueError("expected a Vulkan (21) variant")
    results = []
    kernels = []
    cb_types = {}
    for ki, parent in enumerate(vk_variant["kernels"]):
        uv = []
        for ui, u in enumerate(parent["uniqueVariants"]):
            r = translate_kernel(u, spirv_cross, msl_version)
            kw = " | ".join(s or "<none>" for s, i in parent["variantIndices"] if i == ui)
            results.append((ki, ui, parent["name"], kw, r))
            if log:
                log(ki, ui, parent["name"], kw, r)
            if r.status == "ok":
                uv.append(r.kernel)
                for cbn, types in r.cb_types.items():
                    cb_types.setdefault(cbn, {}).update(types)
            elif on_failure == "stub":
                uv.append(stub_kernel(u, parent["name"], r.message))
            else:
                raise TranslateError(r.category, f"{parent['name']}: {r.message}")
        kernels.append({**parent, "uniqueVariants": uv,
                        "variantIndices": [tuple(x) for x in parent["variantIndices"]]})
    cbs = []
    for cb in vk_variant["constantBuffers"]:
        types = cb_types.get(cb["name"], {})
        params = []
        for p in sorted(cb["params"], key=lambda p: (p["offset"], p["name"])):
            t = types.get(p["name"])
            params.append({**p, "type": p["type"] if t is None else t})
        cbs.append({"name": metal_cb_name(cb["name"]), "byteSize": cb["byteSize"], "params": params})
    return {"targetRenderer": RENDERER_METAL, "targetLevel": 0, "kernels": kernels,
            "constantBuffers": cbs, "resourcesResolved": vk_variant["resourcesResolved"]}, results
