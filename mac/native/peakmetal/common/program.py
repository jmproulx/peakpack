"""Program entries of a Unity 6000.3 platform blob, plus the Metal and Vulkan program-data payloads.

Program entry (verified by byte-exact re-encode of every program entry of PEAK + golden files):

    u32 magic 0x0C0A75BA
    u32 gpuProgramType               (D3D11 15..22, Metal 23 VS / 24 FS, Vulkan 25, ...)
    u32 statsALU, statsTEX, statsFlow, statsTempRegister   (0 for Metal/Vulkan)
    u32 nKeywords, nKeywords x string     (keyword names of this variant, global keyword order)
    u32 dataLength, data, pad to 4
    u32 sourceMap, u32 nChannels, nChannels x (u32 source, u32 target)   (vertex bind channels; VS only)
    [any further u32 words are kept verbatim in .extra]

Bind-channel targets on Metal/Vulkan are 13 + vertex attribute location (proved on the golden files:
see tests/test_golden_conventions.py); source is Unity's ShaderChannel (0 pos, 1 normal, 2 tangent,
3 color, 4..11 texcoord0..7, 12 blendweight, 13 blendindices).
"""
import struct
from dataclasses import dataclass, field
from typing import List, Tuple

from .binio import FormatError, Reader, Writer
from .params import MAGIC

GPU_PROGRAM_TYPES = {
    0: "Unknown", 1: "GLLegacy", 2: "GLES31AEP", 3: "GLES31", 4: "GLES3", 5: "GLES", 6: "GLCore32",
    7: "GLCore41", 8: "GLCore43", 9: "DX9VertexSM20", 10: "DX9VertexSM30", 11: "DX9PixelSM20",
    12: "DX9PixelSM30", 13: "DX10Level9Vertex", 14: "DX10Level9Pixel", 15: "DX11VertexSM40",
    16: "DX11VertexSM50", 17: "DX11PixelSM40", 18: "DX11PixelSM50", 19: "DX11GeometrySM40",
    20: "DX11GeometrySM50", 21: "DX11HullSM50", 22: "DX11DomainSM50", 23: "MetalVS", 24: "MetalFS",
    25: "SPIRV", 26: "ConsoleVS", 27: "ConsoleFS", 28: "ConsoleHS", 29: "ConsoleDS", 30: "ConsoleGS",
    31: "RayTracing", 32: "PS5NGGC", 33: "DXIL",
}
METAL_VS, METAL_FS, SPIRV = 23, 24, 25

# ShaderCompilerPlatform values used by Shader.platforms
PLATFORM_D3D11, PLATFORM_GLES3, PLATFORM_METAL, PLATFORM_GLCORE, PLATFORM_VULKAN, PLATFORM_D3D12 = 4, 9, 14, 15, 18, 26
PLATFORM_NAMES = {4: "D3D11", 9: "GLES3", 14: "Metal", 15: "GLCore", 18: "Vulkan", 26: "D3D12"}

CHANNEL_TARGET_ATTRIB0 = 13


@dataclass
class ProgramEntry:
    gpu_type: int
    stats: Tuple[int, int, int, int]
    keywords: List[str]
    data: bytes
    source_map: int = 0
    channels: List[Tuple[int, int]] = field(default_factory=list)
    extra: List[int] = field(default_factory=list)
    pad: bytes = b""     # bytes used to pad data to 4 (always zero so far; kept for exactness)


def decode(buf) -> ProgramEntry:
    r = Reader(buf)
    if r.u32() != MAGIC:
        raise FormatError("program entry without magic")
    t = r.u32()
    stats = tuple(r.u32s(4))
    nkw = r.u32()
    if nkw > 4096:
        raise FormatError(f"implausible keyword count {nkw}")
    kws = [r.string(1024) for _ in range(nkw)]
    ln = r.u32()
    data = r.raw(ln)
    padn = (-ln) % 4
    pad = r.raw(padn)
    sm, nch = r.u32(), r.u32()
    if nch > 64:
        raise FormatError(f"implausible channel count {nch}")
    ch = [tuple(r.u32s(2)) for _ in range(nch)]
    rest = (r.end - r.pos)
    if rest % 4:
        raise FormatError("unaligned program entry tail")
    extra = r.u32s(rest // 4)
    return ProgramEntry(t, stats, kws, data, sm, ch, extra, pad)


def encode(p: ProgramEntry) -> bytes:
    w = Writer()
    w.u32(MAGIC)
    w.u32(p.gpu_type)
    w.u32s(list(p.stats))
    w.u32(len(p.keywords))
    for k in p.keywords:
        w.string(k)
    w.u32(len(p.data))
    w.raw(p.data)
    padn = (-len(p.data)) % 4
    w.raw(p.pad if len(p.pad) == padn else b"\0" * padn)
    w.u32(p.source_map)
    w.u32(len(p.channels))
    for s, t in p.channels:
        w.u32s([s, t])
    w.u32s(p.extra)
    return w.getvalue()


# ---------------------------------------------------------------- Metal program data

METAL_MAGIC = 0xF00DCAFE
METAL_HEADER_WORDS = 12


@dataclass
class MetalProgram:
    """Metal program data: 12 x i32 header, entry-point name, MSL source.

    header[0]  0xF00DCAFE
    header[1]  byte offset of the entry name (48)
    header[2]  7  (constant in every golden 6000.3 program; see tests/test_golden_conventions.py)
    header[3]  byte offset of the MSL source (48 + len(name) + 1)
    header[4..8] 0
    header[9]  feature/flags word (37; 39 when the program uses instance-id/amplification - see analysis)
    header[10] -1
    header[11] 0
    """
    header: List[int]
    entry: str
    source: str


def decode_metal(data: bytes) -> MetalProgram:
    if len(data) < 48 or struct.unpack_from("<I", data, 0)[0] != METAL_MAGIC:
        raise FormatError("not a Metal program (no F00DCAFE)")
    hdr = list(struct.unpack_from("<12i", data, 0))
    noff, soff = hdr[1], hdr[3]
    nend = data.index(b"\0", noff)
    entry = data[noff:nend].decode("ascii")
    src = data[soff:].decode("utf-8")  # runs to the end of the data, no NUL (golden-verified)
    return MetalProgram(hdr, entry, src)


def encode_metal(m: MetalProgram) -> bytes:
    name = m.entry.encode("ascii") + b"\0"
    hdr = list(m.header)
    hdr[0] = struct.unpack("<i", struct.pack("<I", METAL_MAGIC))[0]
    hdr[1] = 48
    hdr[3] = 48 + len(name)
    return struct.pack("<12i", *hdr) + name + m.source.encode("utf-8")


# ---------------------------------------------------------------- Vulkan program data

SMOLV_MAGIC = b"LOMS"


@dataclass
class VulkanProgram:
    """Vulkan program data: 176-byte header, then one SMOL-V stream per stage.

    header word 0: flags (0x02000060; 0x02000070 seen on instanced variants)
    words 1..18: 9 x (offset, length) stage slots into the program data (0,0 = absent)
    word 19: 1;  words 20..27: 32-byte hash;  words 28..43: 0
    """
    header: bytes
    streams: List[Tuple[int, bytes]]  # (slot, smolv bytes)
    body: bytes  # full data (kept for byte-exact re-encode)


VK_HEADER_SIZE = 176
VK_SLOTS = 9


def decode_vulkan(data: bytes) -> VulkanProgram:
    if len(data) < VK_HEADER_SIZE:
        raise FormatError("Vulkan program data too short")
    words = struct.unpack_from(f"<{VK_HEADER_SIZE // 4}I", data, 0)
    streams = []
    for s in range(VK_SLOTS):
        off, ln = words[1 + 2 * s], words[2 + 2 * s]
        if ln:
            if off + ln > len(data) or data[off:off + 4] != SMOLV_MAGIC:
                raise FormatError(f"slot {s} ({off},{ln}) is not a SMOL-V stream")
            streams.append((s, data[off:off + ln]))
    return VulkanProgram(data[:VK_HEADER_SIZE], streams, data)
