"""Minimal SPIR-V module reader/patcher (only what the Vulkan -> Metal conversion needs).

Used to: find the entry point and execution model; list descriptor resources with (set, binding) and
their kind (uniform buffer, storage buffer, sampled image, storage image, sampler, combined image
sampler, input attachment); decide which resources the entry point statically uses; rewrite Binding /
DescriptorSet decorations to Metal slots; specialize spec constants to fixed values; and read stage
interface variables (Location, component count) for VS-output/FS-input matching.
"""
import struct
from dataclasses import dataclass, field
from typing import Dict, List, Optional

MAGIC = 0x07230203

# opcodes
OpName, OpMemberName, OpEntryPoint, OpExecutionMode, OpCapability = 5, 6, 15, 16, 17
OpTypeVoid, OpTypeBool, OpTypeInt, OpTypeFloat, OpTypeVector, OpTypeMatrix = 19, 20, 21, 22, 23, 24
OpTypeImage, OpTypeSampler, OpTypeSampledImage, OpTypeArray, OpTypeRuntimeArray = 25, 26, 27, 28, 29
OpTypeStruct, OpTypePointer = 30, 32
OpConstantTrue, OpConstantFalse, OpConstant, OpConstantComposite = 41, 42, 43, 44
OpSpecConstantTrue, OpSpecConstantFalse, OpSpecConstant, OpSpecConstantComposite, OpSpecConstantOp = 48, 49, 50, 51, 52
OpFunction, OpFunctionEnd, OpFunctionCall, OpVariable = 54, 56, 57, 59
OpDecorate, OpMemberDecorate = 71, 72

# decorations
DecSpecId, DecBlock, DecBufferBlock, DecBuiltIn, DecInvariant = 1, 2, 3, 11, 18
DecLocation, DecComponent, DecBinding, DecDescriptorSet, DecInputAttachmentIndex = 30, 31, 33, 34, 43
DecOffset = 35

# storage classes
SC_UniformConstant, SC_Input, SC_Uniform, SC_Output, SC_PushConstant, SC_StorageBuffer = 0, 1, 2, 3, 9, 12

# builtins
BI_Position, BI_Layer, BI_ViewportIndex, BI_FragCoord, BI_VertexIndex, BI_InstanceIndex = 0, 9, 10, 15, 42, 43

EXEC_MODELS = {0: "vert", 1: "tesc", 2: "tese", 3: "geom", 4: "frag", 5: "comp"}

# resource kinds
R_UBO, R_SSBO, R_SAMPLED_IMAGE, R_STORAGE_IMAGE, R_SAMPLER, R_COMBINED, R_INPUT_ATTACHMENT, R_TEXEL_BUFFER = (
    "ubo", "ssbo", "image", "storage_image", "sampler", "combined", "input_attachment", "texel_buffer")


@dataclass
class Resource:
    var_id: int
    kind: str
    set: Optional[int]
    binding: Optional[int]
    name: str = ""
    image_dim: Optional[int] = None      # SPIR-V Dim (0 1D, 1 2D, 2 3D, 3 Cube, 5 Buffer, 6 SubpassData)
    arrayed: int = 0
    depth: int = 0
    ms: int = 0
    input_attachment_index: Optional[int] = None
    used: bool = False


@dataclass
class InterfaceVar:
    var_id: int
    location: Optional[int]
    component: int
    builtin: Optional[int]
    components: int     # vector width of the (element) type
    scalar: str         # 'f32','f16','i32','u32','bool','other'
    array: int = 0


@dataclass
class Module:
    words: List[int]
    insts: List[tuple] = field(default_factory=list)  # (offset_in_words, opcode, wordcount)

    @classmethod
    def from_bytes(cls, b):
        if len(b) % 4 or len(b) < 20:
            raise ValueError("SPIR-V length not a multiple of 4")
        words = list(struct.unpack(f"<{len(b) // 4}I", b))
        if words[0] != MAGIC:
            raise ValueError("not SPIR-V")
        m = cls(words)
        m._index()
        return m

    def to_bytes(self):
        return struct.pack(f"<{len(self.words)}I", *self.words)

    def _index(self):
        self.insts = []
        p, w = 5, self.words
        while p < len(w):
            wc, op = w[p] >> 16, w[p] & 0xFFFF
            if wc == 0:
                raise ValueError(f"zero word count at {p}")
            self.insts.append((p, op, wc))
            p += wc

    def ops(self, opcode):
        for p, op, wc in self.insts:
            if op == opcode:
                yield p, self.words[p + 1:p + wc]

    @staticmethod
    def string(operands, start=0):
        b = struct.pack(f"<{len(operands) - start}I", *operands[start:])
        s = b.split(b"\0", 1)[0].decode("utf-8", "replace")
        return s, start + len(s) // 4 + 1

    # ---------------------------------------------------------------- analysis
    def analyze(self):
        w = self.words
        self.names, self.decos, self.types, self.ptrs, self.vars = {}, {}, {}, {}, {}
        self.member_offsets = {}  # struct type id -> {member index: byte offset}
        self.entry = None
        self.exec_modes = []
        self.capabilities = []
        self.functions = {}  # id -> (start_inst_index, end_inst_index)
        self.spec_consts = {}  # id -> (opcode, operands)
        cur_fn = None
        for k, (p, op, wc) in enumerate(self.insts):
            o = w[p + 1:p + wc]
            if op == OpName:
                self.names[o[0]] = self.string(o, 1)[0]
            elif op == OpEntryPoint:
                if self.entry is None:
                    name, nxt = self.string(o, 2)
                    self.entry = {"model": o[0], "id": o[1], "name": name, "interface": list(o[nxt:])}
            elif op == OpExecutionMode:
                self.exec_modes.append(list(o))
            elif op == OpCapability:
                self.capabilities.append(o[0])
            elif op == OpDecorate:
                self.decos.setdefault(o[0], []).append((o[1], list(o[2:])))
            elif op == OpMemberDecorate and o[2] == DecOffset:
                self.member_offsets.setdefault(o[0], {})[o[1]] = o[3]
            elif op in (OpTypeVoid, OpTypeBool, OpTypeInt, OpTypeFloat, OpTypeVector, OpTypeMatrix, OpTypeImage,
                        OpTypeSampler, OpTypeSampledImage, OpTypeArray, OpTypeRuntimeArray, OpTypeStruct):
                self.types[o[0]] = (op, list(o[1:]))
            elif op == OpTypePointer:
                self.ptrs[o[0]] = (o[1], o[2])
            elif op == OpVariable and cur_fn is None:
                self.vars[o[1]] = (o[0], o[2])  # type ptr, storage class
            elif op in (OpSpecConstant, OpSpecConstantTrue, OpSpecConstantFalse, OpSpecConstantComposite,
                        OpSpecConstantOp):
                self.spec_consts[o[1]] = (op, list(o))
            elif op == OpFunction:
                cur_fn = o[1]
                self.functions[cur_fn] = [k, None]
            elif op == OpFunctionEnd:
                self.functions[cur_fn][1] = k
                cur_fn = None
        return self

    @property
    def model(self):
        return EXEC_MODELS.get(self.entry["model"], str(self.entry["model"]))

    def deco(self, id_, d):
        for dd, args in self.decos.get(id_, ()):
            if dd == d:
                return args
        return None

    def _strip_arrays(self, tid):
        arr = 0
        while self.types.get(tid, (None,))[0] in (OpTypeArray, OpTypeRuntimeArray):
            arr += 1
            tid = self.types[tid][1][0]
        return tid, arr

    def resources(self) -> Dict[int, Resource]:
        out = {}
        for vid, (ptr, sc) in self.vars.items():
            if sc not in (SC_UniformConstant, SC_Uniform, SC_StorageBuffer):
                continue
            pointee = self.ptrs[ptr][1]
            base, _ = self._strip_arrays(pointee)
            op, args = self.types.get(base, (None, []))
            r = Resource(vid, "", (self.deco(vid, DecDescriptorSet) or [None])[0],
                         (self.deco(vid, DecBinding) or [None])[0], self.names.get(vid, ""))
            if sc == SC_StorageBuffer or (sc == SC_Uniform and self.deco(base, DecBufferBlock) is not None):
                r.kind = R_SSBO
            elif sc == SC_Uniform:
                r.kind = R_UBO
            elif op == OpTypeSampler:
                r.kind = R_SAMPLER
            elif op in (OpTypeImage, OpTypeSampledImage):
                img = self.types[args[0]][1] if op == OpTypeSampledImage else args
                # OpTypeImage operands: sampledType, Dim, Depth, Arrayed, MS, Sampled, Format
                r.image_dim, r.depth, r.arrayed, r.ms = img[1], img[2], img[3], img[4]
                sampled = img[5]
                if op == OpTypeSampledImage:
                    r.kind = R_COMBINED
                elif img[1] == 6:
                    r.kind = R_INPUT_ATTACHMENT
                    r.input_attachment_index = (self.deco(vid, DecInputAttachmentIndex) or [None])[0]
                elif img[1] == 5:
                    r.kind = R_TEXEL_BUFFER
                elif sampled == 2:
                    r.kind = R_STORAGE_IMAGE
                else:
                    r.kind = R_SAMPLED_IMAGE
            else:
                continue
            out[vid] = r
        self._mark_used(out)
        return out

    def _reachable_functions(self):
        w = self.words
        seen, todo = set(), [self.entry["id"]]
        while todo:
            f = todo.pop()
            if f in seen or f not in self.functions:
                continue
            seen.add(f)
            a, b = self.functions[f]
            for p, op, wc in self.insts[a:b + 1]:
                if op == OpFunctionCall:
                    todo.append(w[p + 3])
        return seen

    def _mark_used(self, res):
        """Static use: any reference to the variable id inside a function reachable from the entry point.
        Word-level scan; a literal that happens to equal a variable id can only over-approximate."""
        ids = set(res)
        w = self.words
        for f in self._reachable_functions():
            a, b = self.functions[f]
            for p, op, wc in self.insts[a:b + 1]:
                for x in w[p + 1:p + wc]:
                    if x in ids:
                        res[x].used = True

    def block_offsets(self, var_id):
        """Byte offsets of the top-level members of a UBO/SSBO block variable (sorted)."""
        pointee = self.ptrs[self.vars[var_id][0]][1]
        base, _ = self._strip_arrays(pointee)
        return sorted(self.member_offsets.get(base, {}).values())

    def interface(self, storage_class) -> List[InterfaceVar]:
        out = []
        for vid in self.entry["interface"]:
            if vid not in self.vars or self.vars[vid][1] != storage_class:
                continue
            pointee = self.ptrs[self.vars[vid][0]][1]
            base, arr = self._strip_arrays(pointee)
            comps, scalar = 1, "other"
            op, args = self.types.get(base, (None, []))
            if op == OpTypeVector:
                comps = args[1]
                op, args = self.types[args[0]]
            if op == OpTypeFloat:
                scalar = "f%d" % args[0]
            elif op == OpTypeInt:
                scalar = ("i" if args[1] else "u") + str(args[0])
            elif op == OpTypeBool:
                scalar = "bool"
            loc = self.deco(vid, DecLocation)
            comp = self.deco(vid, DecComponent)
            bi = self.deco(vid, DecBuiltIn)
            out.append(InterfaceVar(vid, loc[0] if loc else None, comp[0] if comp else 0, bi[0] if bi else None,
                                    comps, scalar, arr))
        return out

    # ---------------------------------------------------------------- patching
    def set_decoration(self, id_, d, value):
        """Set an existing single-literal decoration (Binding/DescriptorSet/...) in place."""
        for p, op, wc in self.insts:
            if op == OpDecorate and self.words[p + 1] == id_ and self.words[p + 2] == d:
                self.words[p + 3] = value
                return True
        return False

    def add_decoration(self, id_, d, *args):
        """Insert OpDecorate after the last existing annotation (keeps the module layout valid)."""
        last = max((i for i, (p, op, wc) in enumerate(self.insts) if op in (OpDecorate, OpMemberDecorate)),
                   default=None)
        if last is None:
            raise ValueError("module has no annotation section")
        p, op, wc = self.insts[last]
        new = [((3 + len(args)) << 16) | OpDecorate, id_, d, *args]
        self.words[p + wc:p + wc] = new
        self._index()

    def make_position_invariant(self):
        """Decorate the Position output Invariant (Unity's Metal VS always emits [[ position, invariant ]];
        SPIRV-Cross then emits [[position, invariant]])."""
        w = self.words
        for p, op, wc in self.insts:
            if op == OpDecorate and w[p + 2] == DecBuiltIn and w[p + 3] == BI_Position:
                tgt = w[p + 1]
                if not any(op2 == OpDecorate and w[p2 + 1] == tgt and w[p2 + 2] == DecInvariant
                           for p2, op2, _ in self.insts):
                    self.add_decoration(tgt, DecInvariant)
                return True
            if op == OpMemberDecorate and w[p + 3] == DecBuiltIn and w[p + 4] == BI_Position:
                st, mem = w[p + 1], w[p + 2]
                if not any(op2 == OpMemberDecorate and w[p2 + 1] == st and w[p2 + 2] == mem and
                           w[p2 + 3] == DecInvariant for p2, op2, _ in self.insts):
                    self.words[p + wc:p + wc] = [(4 << 16) | OpMemberDecorate, st, mem, DecInvariant]
                    self._index()
                return True
        return False

    def specialize(self, values: Dict[int, int]):
        """Turn spec constants into constants (values: SpecId -> value; unknown ids keep their default)
        and drop their SpecId decorations. OpSpecConstantOp is left as is (SPIRV-Cross folds it)."""
        w = self.words
        id_to_spec = {}
        for p, op, wc in self.insts:
            if op == OpDecorate and w[p + 2] == DecSpecId:
                id_to_spec[w[p + 1]] = w[p + 3]
        for p, op, wc in self.insts:
            if op == OpSpecConstant:
                sid = id_to_spec.get(w[p + 2])
                if sid is not None and sid in values and wc == 4:
                    w[p + 3] = values[sid] & 0xFFFFFFFF
                w[p] = (wc << 16) | OpConstant
            elif op == OpSpecConstantTrue:
                w[p] = (wc << 16) | OpConstantTrue
            elif op == OpSpecConstantFalse:
                w[p] = (wc << 16) | OpConstantFalse
            elif op == OpSpecConstantComposite:
                w[p] = (wc << 16) | OpConstantComposite
        # remove SpecId decorations (rebuild word list without them)
        keep = []
        for p, op, wc in self.insts:
            if op == OpDecorate and w[p + 2] == DecSpecId:
                continue
            keep.extend(w[p:p + wc])
        self.words = w[:5] + keep
        self._index()
        return id_to_spec

    def spec_constant_defaults(self):
        """SpecId -> (result id, default literal, opcode) for scalar spec constants."""
        w = self.words
        id_to_spec = {}
        for p, op, wc in self.insts:
            if op == OpDecorate and w[p + 2] == DecSpecId:
                id_to_spec[w[p + 1]] = w[p + 3]
        out = {}
        for p, op, wc in self.insts:
            if op in (OpSpecConstant, OpSpecConstantTrue, OpSpecConstantFalse) and w[p + 2] in id_to_spec:
                val = w[p + 3] if op == OpSpecConstant else int(op == OpSpecConstantTrue)
                out[id_to_spec[w[p + 2]]] = (w[p + 2], val, op)
        return out
