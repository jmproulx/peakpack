"""Little-endian binary reader/writer used by every Unity shader codec in this package.

Strings in Unity's shader blobs are `u32 length + bytes`, padded with zeros to a 4-byte boundary.
"""
import struct


class FormatError(ValueError):
    """Input does not match the expected Unity 6000.3 layout."""


class Reader:
    __slots__ = ("buf", "pos", "end")

    def __init__(self, buf, pos=0, end=None):
        self.buf = buf
        self.pos = pos
        self.end = len(buf) if end is None else end

    def need(self, n):
        if self.pos + n > self.end:
            raise FormatError(f"read of {n} bytes at {self.pos} past end {self.end}")

    def u32(self):
        self.need(4)
        v = struct.unpack_from("<I", self.buf, self.pos)[0]
        self.pos += 4
        return v

    def i32(self):
        self.need(4)
        v = struct.unpack_from("<i", self.buf, self.pos)[0]
        self.pos += 4
        return v

    def u32s(self, n):
        self.need(4 * n)
        v = struct.unpack_from(f"<{n}I", self.buf, self.pos)
        self.pos += 4 * n
        return list(v)

    def raw(self, n):
        self.need(n)
        v = bytes(self.buf[self.pos:self.pos + n])
        self.pos += n
        return v

    def align4(self):
        self.pos = (self.pos + 3) & ~3

    def string(self, limit=1 << 16):
        n = self.u32()
        if n > limit:
            raise FormatError(f"string length {n} at {self.pos - 4} exceeds {limit}")
        s = self.raw(n)
        pad = (-n) % 4
        self.need(pad)
        self.pos += pad
        try:
            return s.decode("utf-8")
        except UnicodeDecodeError as ex:
            raise FormatError(f"non-UTF-8 string at {self.pos}") from ex

    def at_end(self):
        return self.pos == self.end


class Writer:
    __slots__ = ("parts",)

    def __init__(self):
        self.parts = []

    def u32(self, v):
        self.parts.append(struct.pack("<I", v & 0xFFFFFFFF))

    def i32(self, v):
        self.parts.append(struct.pack("<i", v))

    def u32s(self, vs):
        self.parts.append(struct.pack(f"<{len(vs)}I", *[v & 0xFFFFFFFF for v in vs]))

    def raw(self, b):
        self.parts.append(bytes(b))

    def string(self, s):
        b = s.encode("utf-8")
        self.parts.append(struct.pack("<I", len(b)) + b + b"\0" * ((-len(b)) % 4))

    def pad4(self):
        n = sum(len(p) for p in self.parts)
        if n % 4:
            self.parts.append(b"\0" * (4 - n % 4))

    def getvalue(self):
        return b"".join(self.parts)


def u32_at(buf, off):
    return struct.unpack_from("<I", buf, off)[0]
