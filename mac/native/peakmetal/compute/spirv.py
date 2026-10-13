"""Minimal SPIR-V reader/patcher for Unity's Vulkan compute kernels.

Only what the compute converter needs: names, decorations, types, global variables (resources),
entry point + workgroup size, capabilities, a census of interesting opcodes (atomics, subgroup ops,
OpArrayLength, image ops, barriers), and in-place patching of Binding / DescriptorSet decorations.
Pure Python, no third-party dependencies.
"""
from __future__ import annotations

import struct
from collections import Counter
from dataclasses import dataclass, field

MAGIC = 0x07230203

# --- opcodes -------------------------------------------------------------------------------------
OP_NAME, OP_MEMBER_NAME = 5, 6
OP_EXTENSION, OP_EXT_INST_IMPORT = 10, 11
OP_ENTRY_POINT, OP_EXECUTION_MODE, OP_CAPABILITY = 15, 16, 17
OP_TYPE_VOID, OP_TYPE_BOOL, OP_TYPE_INT, OP_TYPE_FLOAT = 19, 20, 21, 22
OP_TYPE_VECTOR, OP_TYPE_MATRIX, OP_TYPE_IMAGE, OP_TYPE_SAMPLER = 23, 24, 25, 26
OP_TYPE_SAMPLED_IMAGE, OP_TYPE_ARRAY, OP_TYPE_RUNTIME_ARRAY, OP_TYPE_STRUCT = 27, 28, 29, 30
OP_TYPE_POINTER = 32
OP_CONSTANT, OP_SPEC_CONSTANT = 43, 50
OP_VARIABLE, OP_IMAGE_TEXEL_POINTER = 59, 60
OP_ARRAY_LENGTH = 68
OP_DECORATE, OP_MEMBER_DECORATE = 71, 72
OP_EXECUTION_MODE_ID = 331

IMAGE_OPS = {87: "ImageSampleImplicitLod", 88: "ImageSampleExplicitLod", 89: "ImageSampleDrefImplicitLod",
             90: "ImageSampleDrefExplicitLod", 95: "ImageFetch", 96: "ImageGather", 97: "ImageDrefGather",
             98: "ImageRead", 99: "ImageWrite", 103: "ImageQuerySizeLod", 104: "ImageQuerySize",
             105: "ImageQueryLod", 106: "ImageQueryLevels", 107: "ImageQuerySamples"}
ATOMIC_OPS = {227: "AtomicLoad", 228: "AtomicStore", 229: "AtomicExchange", 230: "AtomicCompareExchange",
              231: "AtomicCompareExchangeWeak", 232: "AtomicIIncrement", 233: "AtomicIDecrement",
              234: "AtomicIAdd", 235: "AtomicISub", 236: "AtomicSMin", 237: "AtomicUMin", 238: "AtomicSMax",
              239: "AtomicUMax", 240: "AtomicAnd", 241: "AtomicOr", 242: "AtomicXor"}
BARRIER_OPS = {224: "ControlBarrier", 225: "MemoryBarrier"}
DERIVATIVE_OPS = set(range(207, 216))  # OpDPdx .. OpFwidthCoarse
# OpGroupNonUniform* (333..366) and the KHR/AMD subgroup extensions
SUBGROUP_OPS = {333: "GroupNonUniformElect", 334: "GroupNonUniformAll", 335: "GroupNonUniformAny",
                336: "GroupNonUniformAllEqual", 337: "GroupNonUniformBroadcast",
                338: "GroupNonUniformBroadcastFirst", 339: "GroupNonUniformBallot",
                340: "GroupNonUniformInverseBallot", 341: "GroupNonUniformBallotBitExtract",
                342: "GroupNonUniformBallotBitCount", 343: "GroupNonUniformBallotFindLSB",
                344: "GroupNonUniformBallotFindMSB", 345: "GroupNonUniformShuffle",
                346: "GroupNonUniformShuffleXor", 347: "GroupNonUniformShuffleUp",
                348: "GroupNonUniformShuffleDown", 349: "GroupNonUniformIAdd", 350: "GroupNonUniformFAdd",
                351: "GroupNonUniformIMul", 352: "GroupNonUniformFMul", 353: "GroupNonUniformSMin",
                354: "GroupNonUniformUMin", 355: "GroupNonUniformFMin", 356: "GroupNonUniformSMax",
                357: "GroupNonUniformUMax", 358: "GroupNonUniformFMax", 359: "GroupNonUniformBitwiseAnd",
                360: "GroupNonUniformBitwiseOr", 361: "GroupNonUniformBitwiseXor",
                362: "GroupNonUniformLogicalAnd", 363: "GroupNonUniformLogicalOr",
                364: "GroupNonUniformLogicalXor", 365: "GroupNonUniformQuadBroadcast",
                366: "GroupNonUniformQuadSwap", 4421: "SubgroupBallotKHR",
                4422: "SubgroupFirstInvocationKHR", 4428: "SubgroupAllKHR", 4429: "SubgroupAnyKHR",
                4430: "SubgroupAllEqualKHR", 4432: "SubgroupReadInvocationKHR"}

# --- enums ---------------------------------------------------------------------------------------
SC_UNIFORM_CONSTANT, SC_INPUT, SC_UNIFORM, SC_OUTPUT, SC_WORKGROUP = 0, 1, 2, 3, 4
SC_PRIVATE, SC_FUNCTION, SC_PUSH_CONSTANT, SC_STORAGE_BUFFER = 6, 7, 9, 12

DEC_BLOCK, DEC_BUFFER_BLOCK, DEC_ROW_MAJOR, DEC_COL_MAJOR = 2, 3, 4, 5
DEC_ARRAY_STRIDE, DEC_MATRIX_STRIDE, DEC_BUILTIN = 6, 7, 11
DEC_NON_WRITABLE, DEC_NON_READABLE = 24, 25
DEC_BINDING, DEC_DESCRIPTOR_SET, DEC_OFFSET = 33, 34, 35

EXEC_LOCAL_SIZE, EXEC_LOCAL_SIZE_ID = 17, 38

DIM_NAMES = {0: "1D", 1: "2D", 2: "3D", 3: "Cube", 4: "Rect", 5: "Buffer", 6: "SubpassData"}
IMAGE_FORMATS = {0: "Unknown", 1: "Rgba32f", 2: "Rgba16f", 3: "R32f", 4: "Rgba8", 5: "Rgba8Snorm",
                 6: "Rg32f", 7: "Rg16f", 8: "R11fG11fB10f", 9: "R16f", 10: "Rgba16", 11: "Rgb10A2",
                 12: "Rg16", 13: "Rg8", 14: "R16", 15: "R8", 16: "Rgba16Snorm", 17: "Rg16Snorm",
                 18: "Rg8Snorm", 19: "R16Snorm", 20: "R8Snorm", 21: "Rgba32i", 22: "Rgba16i",
                 23: "Rgba8i", 24: "R32i", 25: "Rg32i", 26: "Rg16i", 27: "Rg8i", 28: "R16i", 29: "R8i",
                 30: "Rgba32ui", 31: "Rgba16ui", 32: "Rgba8ui", 33: "R32ui", 34: "Rgb10a2ui",
                 35: "Rg32ui", 36: "Rg16ui", 37: "Rg8ui", 38: "R16ui", 39: "R8ui", 40: "R64ui", 41: "R64i"}
CAPABILITY_NAMES = {0: "Matrix", 1: "Shader", 9: "Float16", 10: "Float64", 11: "Int64",
                    12: "Int64Atomics", 22: "Int16", 39: "Int8", 49: "StorageImageExtendedFormats",
                    50: "ImageQuery", 51: "DerivativeControl", 55: "StorageImageReadWithoutFormat",
                    56: "StorageImageWriteWithoutFormat", 61: "GroupNonUniform", 62: "GroupNonUniformVote",
                    63: "GroupNonUniformArithmetic", 64: "GroupNonUniformBallot",
                    65: "GroupNonUniformShuffle", 66: "GroupNonUniformShuffleRelative",
                    67: "GroupNonUniformClustered", 68: "GroupNonUniformQuad", 4423: "SubgroupBallotKHR",
                    4431: "SubgroupVoteKHR", 4433: "StorageBuffer16BitAccess",
                    4434: "UniformAndStorageBuffer16BitAccess", 4435: "StoragePushConstant16",
                    4436: "StorageInputOutput16", 5008: "Float16ImageAMD", 5009: "ImageGatherBiasLodAMD",
                    5013: "FragmentMaskAMD", 5015: "ImageReadWriteLodAMD", 46: "SampledBuffer",
                    47: "ImageBuffer", 37: "ImageCubeArray", 34: "Sampled1D", 43: "Image1D",
                    48: "ImageMSArray", 54: "InterpolationFunction", 44: "SampledCubeArray",
                    45: "SampledRect", 4447: "AtomicStorageOps", 6033: "AtomicFloat32AddEXT",
                    5297: "VulkanMemoryModel", 6025: "AtomicFloat32MinMaxEXT", 5568: "ShaderClockKHR"}


class SpirvError(ValueError):
    pass


@dataclass
class Variable:
    id: int
    name: str
    storage_class: int
    type_id: int            # pointee type
    set: int | None = None
    binding: int | None = None
    builtin: int | None = None
    non_writable: bool = False
    non_readable: bool = False
    # word index of the literal in the decoration instruction, for patching
    binding_word: int | None = None
    set_word: int | None = None


@dataclass
class Module:
    words: list
    names: dict = field(default_factory=dict)
    member_names: dict = field(default_factory=dict)        # (struct id, idx) -> name
    decorations: dict = field(default_factory=dict)         # id -> {dec: [literals]}
    member_decorations: dict = field(default_factory=dict)  # (id, idx) -> {dec: [literals]}
    types: dict = field(default_factory=dict)               # id -> tuple
    constants: dict = field(default_factory=dict)           # id -> (type id, value words)
    variables: dict = field(default_factory=dict)           # id -> Variable
    capabilities: list = field(default_factory=list)
    extensions: list = field(default_factory=list)
    ext_imports: list = field(default_factory=list)
    entry_points: list = field(default_factory=list)        # (model, id, name, interface ids)
    local_size: tuple | None = None
    local_size_is_id: bool = False
    op_counts: Counter = field(default_factory=Counter)
    image_ops_by_type: Counter = field(default_factory=Counter)  # image var type id hints

    # ---------------------------------------------------------------- helpers
    def name_of(self, i):
        return self.names.get(i, f"_{i}")

    def const_int(self, cid):
        c = self.constants.get(cid)
        if c is None:
            return None
        return c[1][0]

    def strip_type(self, tid):
        """Follow arrays (non-runtime) to the element type; returns (elem type id, dims list)."""
        dims = []
        t = self.types.get(tid)
        while t and t[0] == "array":
            dims.append(self.const_int(t[2]))
            tid = t[1]
            t = self.types.get(tid)
        return tid, dims

    def type_name(self, tid):
        t = self.types.get(tid)
        if t is None:
            return f"?{tid}"
        k = t[0]
        if k == "void":
            return "void"
        if k == "bool":
            return "bool"
        if k == "int":
            return ("int" if t[2] else "uint") + ("" if t[1] == 32 else str(t[1]))
        if k == "float":
            return {16: "half", 32: "float", 64: "double"}[t[1]]
        if k == "vector":
            return f"{self.type_name(t[1])}{t[2]}"
        if k == "matrix":
            col = self.types[t[1]]
            return f"{self.type_name(col[1])}{t[2]}x{col[2]}"
        if k == "array":
            return f"{self.type_name(t[1])}[{self.const_int(t[2])}]"
        if k == "runtime_array":
            return f"{self.type_name(t[1])}[]"
        if k == "struct":
            return self.name_of(tid)
        if k == "image":
            return f"image{DIM_NAMES.get(t[2], t[2])}{'Array' if t[4] else ''}<{self.type_name(t[1])}>"
        if k == "sampler":
            return "sampler"
        if k == "sampled_image":
            return f"sampled<{self.type_name(t[1])}>"
        if k == "pointer":
            return f"ptr<{self.type_name(t[2])}>"
        return k


def _string(words, i):
    """Decode a nul-terminated literal string starting at word i; returns (str, next word index)."""
    out = bytearray()
    while True:
        w = words[i]
        i += 1
        for s in (0, 8, 16, 24):
            c = (w >> s) & 0xFF
            if c == 0:
                return out.decode("utf-8", "replace"), i
            out.append(c)


def parse(data: bytes) -> Module:
    if len(data) < 20 or len(data) % 4:
        raise SpirvError("not a SPIR-V module (size)")
    words = list(struct.unpack(f"<{len(data) // 4}I", data))
    if words[0] != MAGIC:
        raise SpirvError(f"bad SPIR-V magic {words[0]:#x}")
    m = Module(words=words)
    i = 5
    n = len(words)
    while i < n:
        wc, op = words[i] >> 16, words[i] & 0xFFFF
        if wc == 0 or i + wc > n:
            raise SpirvError(f"bad instruction at word {i}")
        a = words[i + 1:i + wc]
        m.op_counts[op] += 1
        if op == OP_NAME:
            m.names[a[0]] = _string(words, i + 2)[0]
        elif op == OP_MEMBER_NAME:
            m.member_names[(a[0], a[1])] = _string(words, i + 3)[0]
        elif op == OP_CAPABILITY:
            m.capabilities.append(a[0])
        elif op == OP_EXTENSION:
            m.extensions.append(_string(words, i + 1)[0])
        elif op == OP_EXT_INST_IMPORT:
            m.ext_imports.append(_string(words, i + 2)[0])
        elif op == OP_ENTRY_POINT:
            name, j = _string(words, i + 3)
            m.entry_points.append((a[0], a[1], name, words[j:i + wc]))
        elif op == OP_EXECUTION_MODE and a[1] == EXEC_LOCAL_SIZE:
            m.local_size = tuple(a[2:5])
        elif op == OP_EXECUTION_MODE_ID and a[1] == EXEC_LOCAL_SIZE_ID:
            m.local_size = tuple(a[2:5])
            m.local_size_is_id = True
        elif op == OP_DECORATE:
            d = m.decorations.setdefault(a[0], {})
            d[a[1]] = list(a[2:])
            if a[1] in (DEC_BINDING, DEC_DESCRIPTOR_SET):
                d[("word", a[1])] = i + 3
        elif op == OP_MEMBER_DECORATE:
            m.member_decorations.setdefault((a[0], a[1]), {})[a[2]] = list(a[3:])
        elif op == OP_TYPE_VOID:
            m.types[a[0]] = ("void",)
        elif op == OP_TYPE_BOOL:
            m.types[a[0]] = ("bool",)
        elif op == OP_TYPE_INT:
            m.types[a[0]] = ("int", a[1], a[2])
        elif op == OP_TYPE_FLOAT:
            m.types[a[0]] = ("float", a[1])
        elif op == OP_TYPE_VECTOR:
            m.types[a[0]] = ("vector", a[1], a[2])
        elif op == OP_TYPE_MATRIX:
            m.types[a[0]] = ("matrix", a[1], a[2])
        elif op == OP_TYPE_IMAGE:
            # sampled type, dim, depth, arrayed, ms, sampled(1 = sampled, 2 = storage), format
            m.types[a[0]] = ("image",) + tuple(a[1:8])
        elif op == OP_TYPE_SAMPLER:
            m.types[a[0]] = ("sampler",)
        elif op == OP_TYPE_SAMPLED_IMAGE:
            m.types[a[0]] = ("sampled_image", a[1])
        elif op == OP_TYPE_ARRAY:
            m.types[a[0]] = ("array", a[1], a[2])
        elif op == OP_TYPE_RUNTIME_ARRAY:
            m.types[a[0]] = ("runtime_array", a[1])
        elif op == OP_TYPE_STRUCT:
            m.types[a[0]] = ("struct", list(a[1:]))
        elif op == OP_TYPE_POINTER:
            m.types[a[0]] = ("pointer", a[1], a[2])
        elif op in (OP_CONSTANT, OP_SPEC_CONSTANT):
            m.constants[a[1]] = (a[0], list(a[2:]))
        elif op == OP_VARIABLE:
            ptr = m.types.get(a[0])
            if ptr is not None and ptr[1] != SC_FUNCTION:
                m.variables[a[1]] = Variable(a[1], "", a[2], ptr[2])
        i += wc
    for vid, v in m.variables.items():
        v.name = m.names.get(vid, "")
        d = m.decorations.get(vid, {})
        if DEC_BINDING in d:
            v.binding = d[DEC_BINDING][0]
            v.binding_word = d[("word", DEC_BINDING)]
        if DEC_DESCRIPTOR_SET in d:
            v.set = d[DEC_DESCRIPTOR_SET][0]
            v.set_word = d[("word", DEC_DESCRIPTOR_SET)]
        if DEC_BUILTIN in d:
            v.builtin = d[DEC_BUILTIN][0]
        v.non_writable = DEC_NON_WRITABLE in d
        v.non_readable = DEC_NON_READABLE in d
    return m


def struct_members(m: Module, sid):
    """[(name, type id, offset, decorations)] for a struct type."""
    t = m.types[sid]
    out = []
    for idx, mt in enumerate(t[1]):
        md = m.member_decorations.get((sid, idx), {})
        out.append((m.member_names.get((sid, idx), f"_m{idx}"), mt, md.get(DEC_OFFSET, [None])[0], md))
    return out


def all_members_non_writable(m: Module, sid):
    t = m.types.get(sid)
    if not t or t[0] != "struct":
        return False
    return all(DEC_NON_WRITABLE in m.member_decorations.get((sid, i), {}) for i in range(len(t[1])))


def patch_bindings(data: bytes, assignment: dict) -> bytes:
    """Return a copy of the module with Binding/DescriptorSet of the given variable ids rewritten.

    ``assignment`` maps variable id -> (descriptor set, binding).
    """
    m = parse(data)
    w = list(m.words)
    for vid, (dset, binding) in assignment.items():
        v = m.variables[vid]
        if v.binding_word is None or v.set_word is None:
            raise SpirvError(f"variable {v.name or vid} has no Binding/DescriptorSet decoration")
        w[v.binding_word] = binding
        w[v.set_word] = dset
    return struct.pack(f"<{len(w)}I", *w)


def census(m: Module) -> dict:
    """Feature census used for the per-kernel report."""
    oc = m.op_counts
    return {
        "capabilities": sorted(CAPABILITY_NAMES.get(c, str(c)) for c in m.capabilities),
        "extensions": list(m.extensions),
        "subgroup_ops": {SUBGROUP_OPS[o]: c for o, c in oc.items() if o in SUBGROUP_OPS},
        "atomic_ops": {ATOMIC_OPS[o]: c for o, c in oc.items() if o in ATOMIC_OPS},
        "image_texel_pointer": oc.get(OP_IMAGE_TEXEL_POINTER, 0),
        "array_length": oc.get(OP_ARRAY_LENGTH, 0),
        "image_ops": {IMAGE_OPS[o]: c for o, c in oc.items() if o in IMAGE_OPS},
        "barriers": {BARRIER_OPS[o]: c for o, c in oc.items() if o in BARRIER_OPS},
        "derivatives": sum(c for o, c in oc.items() if o in DERIVATIVE_OPS),
        "workgroup_vars": [m.name_of(v.id) for v in m.variables.values() if v.storage_class == SC_WORKGROUP],
    }
