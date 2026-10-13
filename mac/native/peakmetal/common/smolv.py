"""Pure-Python SMOL-V -> SPIR-V decoder.

Port of the decode path of smol-v (https://github.com/aras-p/smol-v), source/smolv.cpp:
smolv::Decode, smolv::GetDecodedBufferSize, smolv_ReadVarint, smolv_ReadLengthOp,
smolv_RemapOp, smolv_EncodeLen/smolv_DecodeLen, smolv_DecorationExtraOps and the
kSpirvOpData opcode table. The encoder and the stats helpers are not ported.

smol-v is by Aras Pranckevicius, authored 2016-2024, and is dual licensed under the
MIT licence or the public domain (Unlicense); this module is a derivative work of
that code and is distributed under the same terms.

Stream layout (little endian):
    0   u32  "SMOL" magic (0x534D4F4C)
    4   u32  bits 24..31: SMOL-V encoding version (0 or 1); bits 0..23: SPIR-V version
    8   u32  SPIR-V generator magic
    12  u32  SPIR-V bound
    16  u32  SPIR-V schema
    20  u32  decoded SPIR-V size in bytes
    24  ...  encoded instruction stream

Decoded output is byte-identical to smolv::Decode (flags=0) for valid input. Malformed
input raises ValueError. Two deliberate differences from the C code, both only for
malformed input: a varint cut off at the end of the stream is an error (C silently
returns 0), and so is any write past the declared decoded size.
"""

import struct
import sys
from array import array

__all__ = ["decode", "decoded_size", "DECODE_FLAG_USE_20160831_AS_ZERO_VERSION"]

# Decode flag from smolv.h: "version zero" streams use the 2016-08-31 code path
# (Unity 2017-2020 wrote these). Default flags=0 matches smolv::Decode defaults.
DECODE_FLAG_USE_20160831_AS_ZERO_VERSION = 1

_SPIRV_MAGIC = 0x07230203
_SMOL_MAGIC = 0x534D4F4C  # "SMOL"
_SMOL_HEADER_BYTES = 24
_SPIRV_HEADER_WORDS = 5
_M32 = 0xFFFFFFFF

_KNOWN_OPS_V0 = 331  # SpvOpModuleProcessed + 1
_KNOWN_OPS_V1 = 367  # SpvOpGroupNonUniformQuadSwap + 1

_OP_VECTOR_SHUFFLE_COMPACT = 13
_OP_VECTOR_SHUFFLE = 79
_OP_DECORATE = 71
_OP_MEMBER_DECORATE = 72
_OP_LOAD = 61
_OP_ACCESS_CHAIN = 65
_OP_CONTROL_BARRIER = 224
_OP_MEMORY_BARRIER = 225
_OP_LOOP_MERGE = 246
_OP_SELECTION_MERGE = 247
_OP_BRANCH = 249
_OP_BRANCH_CONDITIONAL = 250
_OP_MEMORY_NAMED_BARRIER = 329

# Opcode table, indexed by SPIR-V opcode: (hasResult, hasType, deltaFromResult, varRest).
# Generated from the kSpirvOpData table in smolv.cpp.
_OP_INFO = (
    (0, 0, 0, 0),  # 0 Nop
    (1, 1, 0, 0),  # 1 Undef
    (0, 0, 0, 0),  # 2 SourceContinued
    (0, 0, 0, 1),  # 3 Source
    (0, 0, 0, 0),  # 4 SourceExtension
    (0, 0, 0, 0),  # 5 Name
    (0, 0, 0, 0),  # 6 MemberName
    (0, 0, 0, 0),  # 7 String
    (0, 0, 0, 1),  # 8 Line
    (1, 1, 0, 0),  # 9 #9
    (0, 0, 0, 0),  # 10 Extension
    (1, 0, 0, 0),  # 11 ExtInstImport
    (1, 1, 0, 1),  # 12 ExtInst
    (1, 1, 2, 1),  # 13 VectorShuffleCompact - new in SMOLV
    (0, 0, 0, 1),  # 14 MemoryModel
    (0, 0, 0, 1),  # 15 EntryPoint
    (0, 0, 0, 1),  # 16 ExecutionMode
    (0, 0, 0, 1),  # 17 Capability
    (1, 1, 0, 0),  # 18 #18
    (1, 0, 0, 1),  # 19 TypeVoid
    (1, 0, 0, 1),  # 20 TypeBool
    (1, 0, 0, 1),  # 21 TypeInt
    (1, 0, 0, 1),  # 22 TypeFloat
    (1, 0, 0, 1),  # 23 TypeVector
    (1, 0, 0, 1),  # 24 TypeMatrix
    (1, 0, 0, 1),  # 25 TypeImage
    (1, 0, 0, 1),  # 26 TypeSampler
    (1, 0, 0, 1),  # 27 TypeSampledImage
    (1, 0, 0, 1),  # 28 TypeArray
    (1, 0, 0, 1),  # 29 TypeRuntimeArray
    (1, 0, 0, 1),  # 30 TypeStruct
    (1, 0, 0, 1),  # 31 TypeOpaque
    (1, 0, 0, 1),  # 32 TypePointer
    (1, 0, 0, 1),  # 33 TypeFunction
    (1, 0, 0, 1),  # 34 TypeEvent
    (1, 0, 0, 1),  # 35 TypeDeviceEvent
    (1, 0, 0, 1),  # 36 TypeReserveId
    (1, 0, 0, 1),  # 37 TypeQueue
    (1, 0, 0, 1),  # 38 TypePipe
    (0, 0, 0, 1),  # 39 TypeForwardPointer
    (1, 1, 0, 0),  # 40 #40
    (1, 1, 0, 0),  # 41 ConstantTrue
    (1, 1, 0, 0),  # 42 ConstantFalse
    (1, 1, 0, 0),  # 43 Constant
    (1, 1, 9, 0),  # 44 ConstantComposite
    (1, 1, 0, 1),  # 45 ConstantSampler
    (1, 1, 0, 0),  # 46 ConstantNull
    (1, 1, 0, 0),  # 47 #47
    (1, 1, 0, 0),  # 48 SpecConstantTrue
    (1, 1, 0, 0),  # 49 SpecConstantFalse
    (1, 1, 0, 0),  # 50 SpecConstant
    (1, 1, 9, 0),  # 51 SpecConstantComposite
    (1, 1, 0, 0),  # 52 SpecConstantOp
    (1, 1, 0, 0),  # 53 #53
    (1, 1, 0, 1),  # 54 Function
    (1, 1, 0, 0),  # 55 FunctionParameter
    (0, 0, 0, 0),  # 56 FunctionEnd
    (1, 1, 9, 0),  # 57 FunctionCall
    (1, 1, 0, 0),  # 58 #58
    (1, 1, 0, 1),  # 59 Variable
    (1, 1, 0, 0),  # 60 ImageTexelPointer
    (1, 1, 1, 1),  # 61 Load
    (0, 0, 2, 1),  # 62 Store
    (0, 0, 0, 0),  # 63 CopyMemory
    (0, 0, 0, 0),  # 64 CopyMemorySized
    (1, 1, 0, 1),  # 65 AccessChain
    (1, 1, 0, 0),  # 66 InBoundsAccessChain
    (1, 1, 0, 0),  # 67 PtrAccessChain
    (1, 1, 0, 0),  # 68 ArrayLength
    (1, 1, 0, 0),  # 69 GenericPtrMemSemantics
    (1, 1, 0, 0),  # 70 InBoundsPtrAccessChain
    (0, 0, 0, 1),  # 71 Decorate
    (0, 0, 0, 1),  # 72 MemberDecorate
    (1, 0, 0, 0),  # 73 DecorationGroup
    (0, 0, 0, 0),  # 74 GroupDecorate
    (0, 0, 0, 0),  # 75 GroupMemberDecorate
    (1, 1, 0, 0),  # 76 #76
    (1, 1, 1, 1),  # 77 VectorExtractDynamic
    (1, 1, 2, 1),  # 78 VectorInsertDynamic
    (1, 1, 2, 1),  # 79 VectorShuffle
    (1, 1, 9, 0),  # 80 CompositeConstruct
    (1, 1, 1, 1),  # 81 CompositeExtract
    (1, 1, 2, 1),  # 82 CompositeInsert
    (1, 1, 1, 0),  # 83 CopyObject
    (1, 1, 0, 0),  # 84 Transpose
    (1, 1, 0, 0),  # 85 #85
    (1, 1, 0, 0),  # 86 SampledImage
    (1, 1, 2, 1),  # 87 ImageSampleImplicitLod
    (1, 1, 2, 1),  # 88 ImageSampleExplicitLod
    (1, 1, 3, 1),  # 89 ImageSampleDrefImplicitLod
    (1, 1, 3, 1),  # 90 ImageSampleDrefExplicitLod
    (1, 1, 2, 1),  # 91 ImageSampleProjImplicitLod
    (1, 1, 2, 1),  # 92 ImageSampleProjExplicitLod
    (1, 1, 3, 1),  # 93 ImageSampleProjDrefImplicitLod
    (1, 1, 3, 1),  # 94 ImageSampleProjDrefExplicitLod
    (1, 1, 2, 1),  # 95 ImageFetch
    (1, 1, 3, 1),  # 96 ImageGather
    (1, 1, 3, 1),  # 97 ImageDrefGather
    (1, 1, 2, 1),  # 98 ImageRead
    (0, 0, 3, 1),  # 99 ImageWrite
    (1, 1, 1, 0),  # 100 Image
    (1, 1, 1, 0),  # 101 ImageQueryFormat
    (1, 1, 1, 0),  # 102 ImageQueryOrder
    (1, 1, 2, 0),  # 103 ImageQuerySizeLod
    (1, 1, 1, 0),  # 104 ImageQuerySize
    (1, 1, 2, 0),  # 105 ImageQueryLod
    (1, 1, 1, 0),  # 106 ImageQueryLevels
    (1, 1, 1, 0),  # 107 ImageQuerySamples
    (1, 1, 0, 0),  # 108 #108
    (1, 1, 1, 0),  # 109 ConvertFToU
    (1, 1, 1, 0),  # 110 ConvertFToS
    (1, 1, 1, 0),  # 111 ConvertSToF
    (1, 1, 1, 0),  # 112 ConvertUToF
    (1, 1, 1, 0),  # 113 UConvert
    (1, 1, 1, 0),  # 114 SConvert
    (1, 1, 1, 0),  # 115 FConvert
    (1, 1, 1, 0),  # 116 QuantizeToF16
    (1, 1, 1, 0),  # 117 ConvertPtrToU
    (1, 1, 1, 0),  # 118 SatConvertSToU
    (1, 1, 1, 0),  # 119 SatConvertUToS
    (1, 1, 1, 0),  # 120 ConvertUToPtr
    (1, 1, 1, 0),  # 121 PtrCastToGeneric
    (1, 1, 1, 0),  # 122 GenericCastToPtr
    (1, 1, 1, 1),  # 123 GenericCastToPtrExplicit
    (1, 1, 1, 0),  # 124 Bitcast
    (1, 1, 0, 0),  # 125 #125
    (1, 1, 1, 0),  # 126 SNegate
    (1, 1, 1, 0),  # 127 FNegate
    (1, 1, 2, 0),  # 128 IAdd
    (1, 1, 2, 0),  # 129 FAdd
    (1, 1, 2, 0),  # 130 ISub
    (1, 1, 2, 0),  # 131 FSub
    (1, 1, 2, 0),  # 132 IMul
    (1, 1, 2, 0),  # 133 FMul
    (1, 1, 2, 0),  # 134 UDiv
    (1, 1, 2, 0),  # 135 SDiv
    (1, 1, 2, 0),  # 136 FDiv
    (1, 1, 2, 0),  # 137 UMod
    (1, 1, 2, 0),  # 138 SRem
    (1, 1, 2, 0),  # 139 SMod
    (1, 1, 2, 0),  # 140 FRem
    (1, 1, 2, 0),  # 141 FMod
    (1, 1, 2, 0),  # 142 VectorTimesScalar
    (1, 1, 2, 0),  # 143 MatrixTimesScalar
    (1, 1, 2, 0),  # 144 VectorTimesMatrix
    (1, 1, 2, 0),  # 145 MatrixTimesVector
    (1, 1, 2, 0),  # 146 MatrixTimesMatrix
    (1, 1, 2, 0),  # 147 OuterProduct
    (1, 1, 2, 0),  # 148 Dot
    (1, 1, 2, 0),  # 149 IAddCarry
    (1, 1, 2, 0),  # 150 ISubBorrow
    (1, 1, 2, 0),  # 151 UMulExtended
    (1, 1, 2, 0),  # 152 SMulExtended
    (1, 1, 0, 0),  # 153 #153
    (1, 1, 1, 0),  # 154 Any
    (1, 1, 1, 0),  # 155 All
    (1, 1, 1, 0),  # 156 IsNan
    (1, 1, 1, 0),  # 157 IsInf
    (1, 1, 1, 0),  # 158 IsFinite
    (1, 1, 1, 0),  # 159 IsNormal
    (1, 1, 1, 0),  # 160 SignBitSet
    (1, 1, 2, 0),  # 161 LessOrGreater
    (1, 1, 2, 0),  # 162 Ordered
    (1, 1, 2, 0),  # 163 Unordered
    (1, 1, 2, 0),  # 164 LogicalEqual
    (1, 1, 2, 0),  # 165 LogicalNotEqual
    (1, 1, 2, 0),  # 166 LogicalOr
    (1, 1, 2, 0),  # 167 LogicalAnd
    (1, 1, 1, 0),  # 168 LogicalNot
    (1, 1, 3, 0),  # 169 Select
    (1, 1, 2, 0),  # 170 IEqual
    (1, 1, 2, 0),  # 171 INotEqual
    (1, 1, 2, 0),  # 172 UGreaterThan
    (1, 1, 2, 0),  # 173 SGreaterThan
    (1, 1, 2, 0),  # 174 UGreaterThanEqual
    (1, 1, 2, 0),  # 175 SGreaterThanEqual
    (1, 1, 2, 0),  # 176 ULessThan
    (1, 1, 2, 0),  # 177 SLessThan
    (1, 1, 2, 0),  # 178 ULessThanEqual
    (1, 1, 2, 0),  # 179 SLessThanEqual
    (1, 1, 2, 0),  # 180 FOrdEqual
    (1, 1, 2, 0),  # 181 FUnordEqual
    (1, 1, 2, 0),  # 182 FOrdNotEqual
    (1, 1, 2, 0),  # 183 FUnordNotEqual
    (1, 1, 2, 0),  # 184 FOrdLessThan
    (1, 1, 2, 0),  # 185 FUnordLessThan
    (1, 1, 2, 0),  # 186 FOrdGreaterThan
    (1, 1, 2, 0),  # 187 FUnordGreaterThan
    (1, 1, 2, 0),  # 188 FOrdLessThanEqual
    (1, 1, 2, 0),  # 189 FUnordLessThanEqual
    (1, 1, 2, 0),  # 190 FOrdGreaterThanEqual
    (1, 1, 2, 0),  # 191 FUnordGreaterThanEqual
    (1, 1, 0, 0),  # 192 #192
    (1, 1, 0, 0),  # 193 #193
    (1, 1, 2, 0),  # 194 ShiftRightLogical
    (1, 1, 2, 0),  # 195 ShiftRightArithmetic
    (1, 1, 2, 0),  # 196 ShiftLeftLogical
    (1, 1, 2, 0),  # 197 BitwiseOr
    (1, 1, 2, 0),  # 198 BitwiseXor
    (1, 1, 2, 0),  # 199 BitwiseAnd
    (1, 1, 1, 0),  # 200 Not
    (1, 1, 4, 0),  # 201 BitFieldInsert
    (1, 1, 3, 0),  # 202 BitFieldSExtract
    (1, 1, 3, 0),  # 203 BitFieldUExtract
    (1, 1, 1, 0),  # 204 BitReverse
    (1, 1, 1, 0),  # 205 BitCount
    (1, 1, 0, 0),  # 206 #206
    (1, 1, 0, 0),  # 207 DPdx
    (1, 1, 0, 0),  # 208 DPdy
    (1, 1, 0, 0),  # 209 Fwidth
    (1, 1, 0, 0),  # 210 DPdxFine
    (1, 1, 0, 0),  # 211 DPdyFine
    (1, 1, 0, 0),  # 212 FwidthFine
    (1, 1, 0, 0),  # 213 DPdxCoarse
    (1, 1, 0, 0),  # 214 DPdyCoarse
    (1, 1, 0, 0),  # 215 FwidthCoarse
    (1, 1, 0, 0),  # 216 #216
    (1, 1, 0, 0),  # 217 #217
    (0, 0, 0, 0),  # 218 EmitVertex
    (0, 0, 0, 0),  # 219 EndPrimitive
    (0, 0, 0, 0),  # 220 EmitStreamVertex
    (0, 0, 0, 0),  # 221 EndStreamPrimitive
    (1, 1, 0, 0),  # 222 #222
    (1, 1, 0, 0),  # 223 #223
    (0, 0, 3, 0),  # 224 ControlBarrier
    (0, 0, 2, 0),  # 225 MemoryBarrier
    (1, 1, 0, 0),  # 226 #226
    (1, 1, 0, 0),  # 227 AtomicLoad
    (0, 0, 0, 0),  # 228 AtomicStore
    (1, 1, 0, 0),  # 229 AtomicExchange
    (1, 1, 0, 0),  # 230 AtomicCompareExchange
    (1, 1, 0, 0),  # 231 AtomicCompareExchangeWeak
    (1, 1, 0, 0),  # 232 AtomicIIncrement
    (1, 1, 0, 0),  # 233 AtomicIDecrement
    (1, 1, 0, 0),  # 234 AtomicIAdd
    (1, 1, 0, 0),  # 235 AtomicISub
    (1, 1, 0, 0),  # 236 AtomicSMin
    (1, 1, 0, 0),  # 237 AtomicUMin
    (1, 1, 0, 0),  # 238 AtomicSMax
    (1, 1, 0, 0),  # 239 AtomicUMax
    (1, 1, 0, 0),  # 240 AtomicAnd
    (1, 1, 0, 0),  # 241 AtomicOr
    (1, 1, 0, 0),  # 242 AtomicXor
    (1, 1, 0, 0),  # 243 #243
    (1, 1, 0, 0),  # 244 #244
    (1, 1, 0, 0),  # 245 Phi
    (0, 0, 2, 1),  # 246 LoopMerge
    (0, 0, 1, 1),  # 247 SelectionMerge
    (1, 0, 0, 0),  # 248 Label
    (0, 0, 1, 0),  # 249 Branch
    (0, 0, 3, 1),  # 250 BranchConditional
    (0, 0, 0, 0),  # 251 Switch
    (0, 0, 0, 0),  # 252 Kill
    (0, 0, 0, 0),  # 253 Return
    (0, 0, 0, 0),  # 254 ReturnValue
    (0, 0, 0, 0),  # 255 Unreachable
    (0, 0, 0, 0),  # 256 LifetimeStart
    (0, 0, 0, 0),  # 257 LifetimeStop
    (1, 1, 0, 0),  # 258 #258
    (1, 1, 0, 0),  # 259 GroupAsyncCopy
    (0, 0, 0, 0),  # 260 GroupWaitEvents
    (1, 1, 0, 0),  # 261 GroupAll
    (1, 1, 0, 0),  # 262 GroupAny
    (1, 1, 0, 0),  # 263 GroupBroadcast
    (1, 1, 0, 0),  # 264 GroupIAdd
    (1, 1, 0, 0),  # 265 GroupFAdd
    (1, 1, 0, 0),  # 266 GroupFMin
    (1, 1, 0, 0),  # 267 GroupUMin
    (1, 1, 0, 0),  # 268 GroupSMin
    (1, 1, 0, 0),  # 269 GroupFMax
    (1, 1, 0, 0),  # 270 GroupUMax
    (1, 1, 0, 0),  # 271 GroupSMax
    (1, 1, 0, 0),  # 272 #272
    (1, 1, 0, 0),  # 273 #273
    (1, 1, 0, 0),  # 274 ReadPipe
    (1, 1, 0, 0),  # 275 WritePipe
    (1, 1, 0, 0),  # 276 ReservedReadPipe
    (1, 1, 0, 0),  # 277 ReservedWritePipe
    (1, 1, 0, 0),  # 278 ReserveReadPipePackets
    (1, 1, 0, 0),  # 279 ReserveWritePipePackets
    (0, 0, 0, 0),  # 280 CommitReadPipe
    (0, 0, 0, 0),  # 281 CommitWritePipe
    (1, 1, 0, 0),  # 282 IsValidReserveId
    (1, 1, 0, 0),  # 283 GetNumPipePackets
    (1, 1, 0, 0),  # 284 GetMaxPipePackets
    (1, 1, 0, 0),  # 285 GroupReserveReadPipePackets
    (1, 1, 0, 0),  # 286 GroupReserveWritePipePackets
    (0, 0, 0, 0),  # 287 GroupCommitReadPipe
    (0, 0, 0, 0),  # 288 GroupCommitWritePipe
    (1, 1, 0, 0),  # 289 #289
    (1, 1, 0, 0),  # 290 #290
    (1, 1, 0, 0),  # 291 EnqueueMarker
    (1, 1, 0, 0),  # 292 EnqueueKernel
    (1, 1, 0, 0),  # 293 GetKernelNDrangeSubGroupCount
    (1, 1, 0, 0),  # 294 GetKernelNDrangeMaxSubGroupSize
    (1, 1, 0, 0),  # 295 GetKernelWorkGroupSize
    (1, 1, 0, 0),  # 296 GetKernelPreferredWorkGroupSizeMultiple
    (0, 0, 0, 0),  # 297 RetainEvent
    (0, 0, 0, 0),  # 298 ReleaseEvent
    (1, 1, 0, 0),  # 299 CreateUserEvent
    (1, 1, 0, 0),  # 300 IsValidEvent
    (0, 0, 0, 0),  # 301 SetUserEventStatus
    (0, 0, 0, 0),  # 302 CaptureEventProfilingInfo
    (1, 1, 0, 0),  # 303 GetDefaultQueue
    (1, 1, 0, 0),  # 304 BuildNDRange
    (1, 1, 2, 1),  # 305 ImageSparseSampleImplicitLod
    (1, 1, 2, 1),  # 306 ImageSparseSampleExplicitLod
    (1, 1, 3, 1),  # 307 ImageSparseSampleDrefImplicitLod
    (1, 1, 3, 1),  # 308 ImageSparseSampleDrefExplicitLod
    (1, 1, 2, 1),  # 309 ImageSparseSampleProjImplicitLod
    (1, 1, 2, 1),  # 310 ImageSparseSampleProjExplicitLod
    (1, 1, 3, 1),  # 311 ImageSparseSampleProjDrefImplicitLod
    (1, 1, 3, 1),  # 312 ImageSparseSampleProjDrefExplicitLod
    (1, 1, 2, 1),  # 313 ImageSparseFetch
    (1, 1, 3, 1),  # 314 ImageSparseGather
    (1, 1, 3, 1),  # 315 ImageSparseDrefGather
    (1, 1, 1, 0),  # 316 ImageSparseTexelsResident
    (0, 0, 0, 0),  # 317 NoLine
    (1, 1, 0, 0),  # 318 AtomicFlagTestAndSet
    (0, 0, 0, 0),  # 319 AtomicFlagClear
    (1, 1, 0, 0),  # 320 ImageSparseRead
    (1, 1, 0, 0),  # 321 SizeOf
    (1, 1, 0, 0),  # 322 TypePipeStorage
    (1, 1, 0, 0),  # 323 ConstantPipeStorage
    (1, 1, 0, 0),  # 324 CreatePipeFromPipeStorage
    (1, 1, 0, 0),  # 325 GetKernelLocalSizeForSubgroupCount
    (1, 1, 0, 0),  # 326 GetKernelMaxNumSubgroups
    (1, 1, 0, 0),  # 327 TypeNamedBarrier
    (1, 1, 0, 1),  # 328 NamedBarrierInitialize
    (0, 0, 2, 1),  # 329 MemoryNamedBarrier
    (1, 1, 0, 0),  # 330 ModuleProcessed
    (0, 0, 0, 1),  # 331 ExecutionModeId
    (0, 0, 0, 1),  # 332 DecorateId
    (1, 1, 1, 1),  # 333 GroupNonUniformElect
    (1, 1, 1, 1),  # 334 GroupNonUniformAll
    (1, 1, 1, 1),  # 335 GroupNonUniformAny
    (1, 1, 1, 1),  # 336 GroupNonUniformAllEqual
    (1, 1, 1, 1),  # 337 GroupNonUniformBroadcast
    (1, 1, 1, 1),  # 338 GroupNonUniformBroadcastFirst
    (1, 1, 1, 1),  # 339 GroupNonUniformBallot
    (1, 1, 1, 1),  # 340 GroupNonUniformInverseBallot
    (1, 1, 1, 1),  # 341 GroupNonUniformBallotBitExtract
    (1, 1, 1, 1),  # 342 GroupNonUniformBallotBitCount
    (1, 1, 1, 1),  # 343 GroupNonUniformBallotFindLSB
    (1, 1, 1, 1),  # 344 GroupNonUniformBallotFindMSB
    (1, 1, 1, 1),  # 345 GroupNonUniformShuffle
    (1, 1, 1, 1),  # 346 GroupNonUniformShuffleXor
    (1, 1, 1, 1),  # 347 GroupNonUniformShuffleUp
    (1, 1, 1, 1),  # 348 GroupNonUniformShuffleDown
    (1, 1, 1, 1),  # 349 GroupNonUniformIAdd
    (1, 1, 1, 1),  # 350 GroupNonUniformFAdd
    (1, 1, 1, 1),  # 351 GroupNonUniformIMul
    (1, 1, 1, 1),  # 352 GroupNonUniformFMul
    (1, 1, 1, 1),  # 353 GroupNonUniformSMin
    (1, 1, 1, 1),  # 354 GroupNonUniformUMin
    (1, 1, 1, 1),  # 355 GroupNonUniformFMin
    (1, 1, 1, 1),  # 356 GroupNonUniformSMax
    (1, 1, 1, 1),  # 357 GroupNonUniformUMax
    (1, 1, 1, 1),  # 358 GroupNonUniformFMax
    (1, 1, 1, 1),  # 359 GroupNonUniformBitwiseAnd
    (1, 1, 1, 1),  # 360 GroupNonUniformBitwiseOr
    (1, 1, 1, 1),  # 361 GroupNonUniformBitwiseXor
    (1, 1, 1, 1),  # 362 GroupNonUniformLogicalAnd
    (1, 1, 1, 1),  # 363 GroupNonUniformLogicalOr
    (1, 1, 1, 1),  # 364 GroupNonUniformLogicalXor
    (1, 1, 1, 1),  # 365 GroupNonUniformQuadBroadcast
    (1, 1, 1, 1),  # 366 GroupNonUniformQuadSwap
)

# smolv_RemapOp: an involution that swaps rarely used opcodes with the common ones so the
# common ones fit in a short varint.
_REMAP = {
    0: 71, 71: 0,      # Nop <-> Decorate
    1: 61, 61: 1,      # Undef <-> Load
    2: 62, 62: 2,      # SourceContinued <-> Store
    3: 65, 65: 3,      # Source <-> AccessChain
    4: 79, 79: 4,      # SourceExtension <-> VectorShuffle
    7: 72, 72: 7,      # String <-> MemberDecorate
    8: 248, 248: 8,    # Line <-> Label
    9: 59, 59: 9,      # (9) <-> Variable
    10: 133, 133: 10,  # Extension <-> FMul
    11: 129, 129: 11,  # ExtInstImport <-> FAdd
    14: 32, 32: 14,    # MemoryModel <-> TypePointer
    15: 127, 127: 15,  # EntryPoint <-> FNegate
}

# smolv_DecodeLen: extra amount added to the (already +1 adjusted) length for these ops.
_LEN_ADJUST = {
    _OP_VECTOR_SHUFFLE: 4,
    _OP_VECTOR_SHUFFLE_COMPACT: 4,
    _OP_DECORATE: 2,
    _OP_LOAD: 3,
    _OP_ACCESS_CHAIN: 3,
}

# Ops that still get zig-decoded IDs in the 2016-08-31 ("before zero") code path.
_BEFORE_ZERO_ZIG_OPS = frozenset((
    _OP_CONTROL_BARRIER, _OP_MEMORY_BARRIER, _OP_LOOP_MERGE, _OP_SELECTION_MERGE,
    _OP_BRANCH, _OP_BRANCH_CONDITIONAL, _OP_MEMORY_NAMED_BARRIER,
))

_NOINFO = (0, 0, 0, 0)

# array typecode with 4-byte items (SPIR-V words)
_WORD_TC = "I" if array("I").itemsize == 4 else "L"
_LITTLE_ENDIAN = sys.byteorder == "little"


def _decoration_extra_ops(dec):
    """smolv_DecorationExtraOps: number of extra operands, or -1 if the length is encoded."""
    if dec == 0 or 2 <= dec <= 5:  # RelaxedPrecision, Block..ColMajor
        return 0
    if 29 <= dec <= 37:  # Stream..XfbStride
        return 1
    return -1


def _zig_decode(u):
    """smolv_ZigDecode, result as a uint32 bit pattern."""
    return ((u >> 1) ^ _M32) if (u & 1) else (u >> 1)


def _read_varint(d, p):
    """smolv_ReadVarint, general case. Returns (value, next_pos)."""
    v = 0
    shift = 0
    n = len(d)
    while True:
        if p >= n:
            raise ValueError("SMOL-V: truncated varint")
        b = d[p]
        p += 1
        v |= (b & 127) << shift
        shift += 7
        if not (b & 128):
            return v & _M32, p


def _check_header(d):
    """smolv_CheckSmolHeader. Returns the SMOL-V encoding version, or None if invalid."""
    if len(d) < _SMOL_HEADER_BYTES:
        return None
    magic, ver = struct.unpack_from("<II", d, 0)
    if magic != _SMOL_MAGIC:
        return None
    spirv_version = ver & 0x00FFFFFF
    if spirv_version < 0x00010000 or spirv_version > 0x00010600:
        return None  # only SPIR-V 1.0 through 1.6
    smol_version = ver >> 24
    if smol_version > 1:
        return None
    return smol_version


def decoded_size(data):
    """smolv::GetDecodedBufferSize: decoded SPIR-V size in bytes, or 0 if the header is invalid."""
    data = bytes(data) if not isinstance(data, bytes) else data
    if _check_header(data) is None:
        return 0
    return struct.unpack_from("<I", data, 20)[0]


def decode(data, flags=0):
    """Decode a SMOL-V stream to SPIR-V bytes (little endian).

    Raises ValueError if the header is invalid or the stream is malformed.
    """
    d = data if isinstance(data, bytes) else bytes(data)
    n = len(d)
    smol_version = _check_header(d)
    if smol_version is None:
        raise ValueError("not a SMOL-V stream (bad header)")
    size = struct.unpack_from("<I", d, 20)[0]
    if size < _SPIRV_HEADER_WORDS * 4 or size % 4:
        raise ValueError("SMOL-V: bad decoded size %d" % size)
    nwords = size >> 2

    before_zero = smol_version == 0 and (flags & DECODE_FLAG_USE_20160831_AS_ZERO_VERSION) != 0
    known_ops = _KNOWN_OPS_V0 if smol_version == 0 else _KNOWN_OPS_V1
    op_info = _OP_INFO
    remap = _REMAP
    len_adjust = _LEN_ADJUST
    before_zero_zig = _BEFORE_ZERO_ZIG_OPS
    read_varint = _read_varint
    zig = _zig_decode
    word_tc = _WORD_TC

    out = array(word_tc, bytes(size))  # zero-filled output words
    # SPIR-V header: magic, version (SMOL-V version byte stripped), generator, bound, schema
    version, generator, bound, schema = struct.unpack_from("<4I", d, 4)
    out[0] = _SPIRV_MAGIC
    out[1] = version & 0x00FFFFFF
    out[2] = generator
    out[3] = bound
    out[4] = schema
    o = _SPIRV_HEADER_WORDS
    pos = _SMOL_HEADER_BYTES

    prev_result = 0
    prev_decorate = 0

    try:
        while pos < n:
            # smolv_ReadLengthOp: packed (length, opcode) varint
            b = d[pos]
            pos += 1
            if b < 128:
                val = b
            else:
                val, pos = read_varint(d, pos - 1)
            op = ((val >> 4) & 0xFFF0) | (val & 0xF)
            length = ((val >> 20) << 4) | ((val >> 4) & 0xF)
            op = remap.get(op, op)
            # smolv_DecodeLen (length was stored minus one, with per-op offsets removed)
            length = (length + 1 + len_adjust.get(op, 0)) & _M32

            was_swizzle = op == _OP_VECTOR_SHUFFLE_COMPACT
            if was_swizzle:
                op = _OP_VECTOR_SHUFFLE
            out[o] = ((length << 16) | op) & _M32
            o += 1

            ioffs = 1
            if op < known_ops:
                has_result, has_type, delta_count, var_rest = op_info[op]
            else:
                has_result, has_type, delta_count, var_rest = _NOINFO

            if has_type:
                b = d[pos]
                pos += 1
                if b < 128:
                    val = b
                else:
                    val, pos = read_varint(d, pos - 1)
                out[o] = val
                o += 1
                ioffs += 1

            if has_result:
                b = d[pos]
                pos += 1
                if b < 128:
                    val = b
                else:
                    val, pos = read_varint(d, pos - 1)
                val = (prev_result + zig(val)) & _M32
                out[o] = val
                o += 1
                prev_result = val
                ioffs += 1

            if op == _OP_DECORATE or op == _OP_MEMBER_DECORATE:
                # target ID, relative to the previous decorate target
                val, pos = read_varint(d, pos)
                if not before_zero:
                    val = zig(val)
                val = (prev_decorate + val) & _M32
                out[o] = val
                o += 1
                prev_decorate = val
                ioffs += 1

            if op == _OP_MEMBER_DECORATE and not before_zero:
                # Member decorations: count byte, then per member (index, decoration, [length], operands)
                if pos >= n:
                    raise ValueError("SMOL-V: truncated MemberDecorate")
                count = d[pos]
                pos += 1
                prev_index = 0
                prev_offset = 0
                for m in range(count):
                    val, pos = read_varint(d, pos)
                    member_index = (val + prev_index) & _M32
                    prev_index = member_index

                    member_dec, pos = read_varint(d, pos)
                    extra = _decoration_extra_ops(member_dec)
                    if extra == -1:
                        member_len, pos = read_varint(d, pos)
                        member_len = (member_len + 4) & _M32
                    else:
                        member_len = 4 + extra

                    if m != 0:
                        # first member's header was already written with the instruction
                        out[o] = ((member_len << 16) | _OP_MEMBER_DECORATE) & _M32
                        o += 1
                        out[o] = prev_decorate
                        o += 1
                    out[o] = member_index
                    o += 1
                    out[o] = member_dec
                    o += 1
                    if member_dec == 35:  # Offset: running sum, length must be 5
                        if member_len != 5:
                            raise ValueError("SMOL-V: bad Offset decoration length")
                        val, pos = read_varint(d, pos)
                        val = (val + prev_offset) & _M32
                        out[o] = val
                        o += 1
                        prev_offset = val
                    else:
                        for _ in range(4, member_len):
                            val, pos = read_varint(d, pos)
                            out[o] = val
                            o += 1
                continue

            # IDs relative to the current/previous result ID
            zig_vals = True
            if before_zero:
                zig_vals = op in before_zero_zig
            i = 0
            while i < delta_count and ioffs < length:
                b = d[pos]
                pos += 1
                if b < 128:
                    val = b
                else:
                    val, pos = read_varint(d, pos - 1)
                if zig_vals:
                    val = zig(val)
                out[o] = (prev_result - val) & _M32
                o += 1
                i += 1
                ioffs += 1

            if was_swizzle and length <= 9:
                # compact shuffle: one byte holds up to four 2-bit component selectors
                if pos >= n:
                    raise ValueError("SMOL-V: truncated VectorShuffleCompact")
                swizzle = d[pos]
                pos += 1
                if length > 5:
                    out[o] = (swizzle >> 6) & 3
                    o += 1
                if length > 6:
                    out[o] = (swizzle >> 4) & 3
                    o += 1
                if length > 7:
                    out[o] = (swizzle >> 2) & 3
                    o += 1
                if length > 8:
                    out[o] = swizzle & 3
                    o += 1
            elif var_rest:
                # remaining operands as varints
                while ioffs < length:
                    b = d[pos]
                    pos += 1
                    if b < 128:
                        val = b
                    else:
                        val, pos = read_varint(d, pos - 1)
                    out[o] = val
                    o += 1
                    ioffs += 1
            else:
                # remaining operands as raw little-endian words
                k = length - ioffs
                if k > 0:
                    nbytes = 4 * k
                    if pos + nbytes > n:
                        raise ValueError("SMOL-V: truncated instruction")
                    if o + k > nwords:
                        raise ValueError("SMOL-V: decoded data overflows declared size")
                    chunk = array(word_tc)
                    chunk.frombytes(d[pos:pos + nbytes])
                    if not _LITTLE_ENDIAN:
                        chunk.byteswap()
                    out[o:o + k] = chunk
                    o += k
                    pos += nbytes
    except IndexError:
        raise ValueError("SMOL-V: truncated or overflowing stream") from None

    if o != nwords:
        raise ValueError("SMOL-V: decoded %d words, header declares %d" % (o, nwords))
    if not _LITTLE_ENDIAN:
        out.byteswap()
    return out.tobytes()
