#!/usr/bin/env python3
"""pe_check.py <lib/wine dir> [root.dll ...]   (no roots: x86_64 defaults + i386 WoW64 set)

Static check of the Wine PE DLL tree that the loader needs to start a process:
for every root (default: ntdll.dll kernel32.dll kernelbase.dll start.exe wineboot.exe
cmd.exe conhost.exe services.exe winedevice.exe explorer.exe rpcss.exe) and, recursively,
each DLL it imports or delay-imports:
  * the file exists in x86_64-windows,
  * the COFF machine is AMD64 (0x8664),
  * the DOS stub carries the "Wine builtin DLL" marker (without it Wine ignores the file
    and the load fails with STATUS_DLL_NOT_FOUND, c0000135),
  * if a matching x86_64-unix/<name>.so is expected it is reported when present.
api-ms-win-* / ext-ms-* names are API sets resolved by ntdll and are only listed.
Exit 0 when everything resolves, 1 otherwise. Standard library only.
"""
import os
import struct
import sys

BUILTIN = b"Wine builtin DLL"
FAKE = b"Wine placeholder DLL"
DEFAULT_ROOTS = ["ntdll.dll", "kernel32.dll", "kernelbase.dll", "start.exe", "wineboot.exe",
                 "cmd.exe", "conhost.exe", "services.exe", "winedevice.exe", "explorer.exe",
                 "rpcss.exe", "wow64.dll", "wow64win.dll", "wow64cpu.dll"]
# 32-bit side used by WoW64 processes (wineboot --init runs a 32-bit rundll32 for syswow64).
I386_ROOTS = ["ntdll.dll", "kernel32.dll", "kernelbase.dll", "rundll32.exe", "setupapi.dll",
              "start.exe", "cmd.exe"]
ARCHES = [("x86_64-windows", 0x8664, DEFAULT_ROOTS), ("i386-windows", 0x014C, I386_ROOTS)]


def parse(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:2] != b"MZ":
        raise ValueError("no MZ header")
    lfanew = struct.unpack_from("<I", data, 0x3C)[0]
    if data[lfanew:lfanew + 4] != b"PE\0\0":
        raise ValueError("no PE signature")
    machine, nsec = struct.unpack_from("<HH", data, lfanew + 4)
    opt_size = struct.unpack_from("<H", data, lfanew + 20)[0]
    opt = lfanew + 24
    magic = struct.unpack_from("<H", data, opt)[0]
    dd = opt + (112 if magic == 0x20B else 96)
    ndd = struct.unpack_from("<I", data, dd - 4)[0]
    dirs = [struct.unpack_from("<II", data, dd + 8 * i) for i in range(min(ndd, 16))]
    secs = []
    so = opt + opt_size
    for i in range(nsec):
        vsize, va, rsize, rptr = struct.unpack_from("<IIII", data, so + 40 * i + 8)
        secs.append((va, max(vsize, rsize), rptr))

    def off(rva):
        for va, size, ptr in secs:
            if va <= rva < va + size:
                return rva - va + ptr
        return None

    def cstr(rva):
        o = off(rva)
        if o is None:
            return None
        e = data.index(b"\0", o)
        return data[o:e].decode("ascii", "replace")

    names = []
    if len(dirs) > 1 and dirs[1][0]:
        o = off(dirs[1][0])
        while o is not None:
            fields = struct.unpack_from("<IIIII", data, o)
            if not any(fields):
                break
            n = cstr(fields[3])
            if n:
                names.append(n)
            o += 20
    delay = []
    if len(dirs) > 13 and dirs[13][0]:
        o = off(dirs[13][0])
        while o is not None:
            fields = struct.unpack_from("<IIIIIIII", data, o)
            if not any(fields):
                break
            n = cstr(fields[1])
            if n:
                delay.append(n)
            o += 32
    marker = "builtin" if BUILTIN in data[0x40:0x80] else ("placeholder" if FAKE in data[0x40:0x80] else "none")
    return machine, marker, names, delay


def check_arch(base, pe_name, want_machine, roots):
    pe_dir = os.path.join(base, pe_name)
    so_dir = os.path.join(base, "x86_64-unix")
    print(f"== {pe_name}")
    if not os.path.isdir(pe_dir):
        print(f"FAIL {pe_dir} missing")
        return [f"MISSING {pe_name}"]
    present = {n.lower(): n for n in os.listdir(pe_dir)}
    seen, queue, bad, apisets = set(), list(roots), [], set()
    while queue:
        name = queue.pop(0)
        key = name.lower()
        if key in seen:
            continue
        seen.add(key)
        if key.startswith(("api-ms-win-", "ext-ms-")):
            apisets.add(key)
            continue
        if key not in present:
            bad.append(f"MISSING {pe_name}/{name}")
            print(f"FAIL {name}: not in {pe_name}")
            continue
        try:
            machine, marker, imps, delay = parse(os.path.join(pe_dir, present[key]))
        except Exception as e:  # noqa: BLE001 - report and keep going
            bad.append(f"BADPE {pe_name}/{name}")
            print(f"FAIL {name}: {e}")
            continue
        so = os.path.exists(os.path.join(so_dir, os.path.splitext(present[key])[0] + ".so"))
        ok = machine == want_machine and marker == "builtin"
        print(f"{'PASS' if ok else 'FAIL'} {name}: machine=0x{machine:04x} marker={marker}"
              f" unixlib={'yes' if so else 'no'} imports={','.join(imps) or '-'}"
              f" delay={','.join(delay) or '-'}")
        if not ok:
            bad.append(f"{pe_name}/{name} machine=0x{machine:04x} marker={marker}")
        queue.extend(imps)
        queue.extend(delay)
    if apisets:
        print("api sets (resolved by ntdll):", ",".join(sorted(apisets)))
    print(f"{pe_name}: checked {len(seen) - len(apisets)} PE files, {len(bad)} problem(s)")
    return bad


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    base = sys.argv[1]
    bad = []
    if len(sys.argv) > 2:
        bad += check_arch(base, "x86_64-windows", 0x8664, sys.argv[2:])
    else:
        for pe_name, machine, roots in ARCHES:
            bad += check_arch(base, pe_name, machine, roots)
    for b in bad:
        print("  " + b)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
