"""Unity 6000.3 Metal compute kernel ``code`` blob (ComputeShaderKernel.code, targetRenderer 16).

Layout, proven on all 66 Metal compute kernels in the 6000.3.15f1 macOS arm64 player's
'unity default resources' (Internal-Skinning, Internal-BlendShape, Internal-VT-*)::

    u32 magic        = 0xDEADCAFE
    u32 version      = 2
    u32 sourceOffset = 20          # byte offset of the MSL text
    u16 threadGroupX, threadGroupY, threadGroupZ
    u16 flag         = 1           # always 1 in every golden kernel (meaning unknown; kept)
    char msl[]       # MSL source, entry point 'kernel void computeMain(...)'
    char 0           # single terminating nul

Unlike graphics programs (0xF00DCAFE header + entry name), the compute blob carries no entry
name: Unity looks up 'computeMain'.
"""
from __future__ import annotations

import struct
from dataclasses import dataclass

MAGIC = 0xDEADCAFE
VERSION = 2
HEADER_SIZE = 20
ENTRY_NAME = "computeMain"


class MetalBlobError(ValueError):
    pass


@dataclass
class MetalComputeBlob:
    msl: str
    threadgroup: tuple
    flag: int = 1
    version: int = VERSION

    def encode(self) -> bytes:
        tx, ty, tz = self.threadgroup
        for t in (tx, ty, tz):
            if not 0 < t < 0x10000:
                raise MetalBlobError(f"threadgroup size {self.threadgroup} does not fit u16")
        src = self.msl.encode("utf-8")
        if b"\0" in src:
            raise MetalBlobError("MSL contains a nul byte")
        return struct.pack("<III4H", MAGIC, self.version, HEADER_SIZE, tx, ty, tz, self.flag) + src + b"\0"


def decode(code: bytes) -> MetalComputeBlob:
    code = bytes(code)
    if len(code) < HEADER_SIZE + 1:
        raise MetalBlobError("blob too small")
    magic, version, off, tx, ty, tz, flag = struct.unpack_from("<III4H", code)
    if magic != MAGIC:
        raise MetalBlobError(f"bad magic {magic:#x}")
    if off != HEADER_SIZE:
        raise MetalBlobError(f"unexpected source offset {off}")
    if code[-1] != 0 or code.find(b"\0", off) != len(code) - 1:
        raise MetalBlobError("MSL must be followed by exactly one terminating nul")
    return MetalComputeBlob(code[off:-1].decode("utf-8"), (tx, ty, tz), flag, version)


def is_metal_blob(code) -> bool:
    return len(code) >= 4 and struct.unpack_from("<I", bytes(code[:4]))[0] == MAGIC
