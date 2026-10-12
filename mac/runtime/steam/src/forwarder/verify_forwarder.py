"""Verify the PeakPack steamclient64.dll forwarder (read-only).

Part of PeakPack for Mac (runtime/steam). MIT licence (see docs/README.md).

Checks: x86_64 PE DLL, no imports, every export is a forwarder to
lsteamclient.<same name>, the export set equals steamclient64.def, and the
names steam_api64.dll 1.61 resolves from the client are all present.
Optionally compares against an lsteamclient.spec (--spec) and a real
lsteamclient.dll (--lsteamclient) to make sure every forward target exists.

Usage: python -I verify_forwarder.py out/steamclient64.dll [--spec lsteamclient.spec]
                                    [--lsteamclient lsteamclient.dll] [--write-exports FILE]
"""
import argparse
import hashlib
import os
import re
import sys

import pefile

# Resolved by steam_api64.dll (SDK 1.61, as shipped with PEAK) with GetProcAddress
# on the client DLL (tools/steamwork/pe_inspect_steam.txt).
REQUIRED = [
    "CreateInterface", "Steam_BGetCallback", "Steam_FreeLastCallback",
    "Steam_GetAPICallResult", "Steam_ReleaseThreadLocalMemory",
    "Steam_IsKnownInterface", "Steam_NotifyMissingInterface",
    "Breakpad_SteamMiniDumpInit", "Breakpad_SteamSetAppID", "Breakpad_SteamSetSteamID",
    "Breakpad_SteamWriteMiniDumpSetComment",
    "Breakpad_SteamWriteMiniDumpUsingExceptionInfoWithBuildId",
]


def def_exports(path):
    names = {}
    for line in open(path, encoding="utf-8"):
        m = re.match(r"\s+(\w+)\s*=\s*([\w.]+)", line)
        if m:
            names[m.group(1)] = m.group(2)
    return names


def spec_exports(path):
    out = {}
    for line in open(path, encoding="utf-8"):
        line = line.split("#", 1)[0].strip()
        m = re.match(r"(?:\d+|@)\s+(\w+)\s+(?:-\S+\s+)*(\w+)", line)
        if m:
            kind, name = m.group(1), m.group(2)
            if "-private" not in line:
                out[name] = kind
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dll")
    ap.add_argument("--def", dest="deffile",
                    default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "steamclient64.def"))
    ap.add_argument("--spec")
    ap.add_argument("--lsteamclient")
    ap.add_argument("--write-exports")
    a = ap.parse_args()

    errors = []
    pe = pefile.PE(a.dll)
    if pe.FILE_HEADER.Machine != 0x8664:
        errors.append("machine is not x86_64")
    if not pe.is_dll():
        errors.append("not a DLL")
    imports = [e.dll.decode() for e in getattr(pe, "DIRECTORY_ENTRY_IMPORT", [])]
    if imports:
        errors.append(f"unexpected imports: {imports}")

    exports = {}
    for s in pe.DIRECTORY_ENTRY_EXPORT.symbols:
        name = (s.name or b"").decode()
        fwd = (s.forwarder or b"").decode()
        exports[name] = fwd
        if fwd != f"lsteamclient.{name}":
            errors.append(f"{name}: forwarder is {fwd!r}, want 'lsteamclient.{name}'")

    want = def_exports(a.deffile)
    if set(want) != set(exports):
        errors.append(f"export set differs from .def: missing {sorted(set(want) - set(exports))}, "
                      f"extra {sorted(set(exports) - set(want))}")
    for r in REQUIRED:
        if r not in exports:
            errors.append(f"required export missing: {r}")

    if a.spec:
        spec = spec_exports(a.spec)
        for name in exports:
            if name not in spec:
                errors.append(f"{name} is not exported by lsteamclient.spec")
        impl = [n for n in exports if spec.get(n) == "cdecl"]
        stub = [n for n in exports if spec.get(n) == "stub"]
        print(f"lsteamclient.spec: {len(impl)} forwarded names implemented, {len(stub)} are Wine stubs")
    if a.lsteamclient:
        lpe = pefile.PE(a.lsteamclient)
        lnames = {(s.name or b"").decode() for s in lpe.DIRECTORY_ENTRY_EXPORT.symbols}
        for name in exports:
            if name not in lnames:
                errors.append(f"{name} not exported by {a.lsteamclient}")

    data = open(a.dll, "rb").read()
    print(f"file: {a.dll}")
    print(f"size: {len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()}")
    print(f"timestamp: {pe.FILE_HEADER.TimeDateStamp}  imports: {imports or 'none'}")
    print(f"exports ({len(exports)}):")
    lines = [f"  {s.ordinal:3d} {(s.name or b'').decode():60s} -> {(s.forwarder or b'').decode()}"
             for s in pe.DIRECTORY_ENTRY_EXPORT.symbols]
    print("\n".join(lines))
    if a.write_exports:
        with open(a.write_exports, "w", encoding="utf-8", newline="\n") as f:
            f.write(f"# steamclient64.dll exports; sha256 {hashlib.sha256(data).hexdigest()}\n")
            f.write("\n".join(lines) + "\n")
    if errors:
        print("FAIL:\n  " + "\n  ".join(errors))
        return 1
    print("OK: all exports forward to lsteamclient.<name>; required steam_api64 1.61 names present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
