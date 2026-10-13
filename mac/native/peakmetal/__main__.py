"""peakmetal CLI. Run from the `native` folder:  python -I -m peakmetal <command> ...

  inspect   <file> [--shader NAME]              list shaders/platforms/program counts (or one shader in detail)
  roundtrip <file> [--shader NAME]              byte-exact decode/encode check (typetree, blobs, entries, LZ4)
  translate <file> --shader NAME --out DIR      translate one shader, write MSL + parameter dumps
  golden    <file> [<file> ...]                 translate Unity's golden Vulkan programs, diff vs Unity's Metal
  convert   <data.unity3d|file> --out DIR [--mode loose|bundle|both] [--jobs N] [--no-compute] [--only NAME]
  validate  <msl dir> [--metal PATH] [--std macos-metal2.1] [--report FILE]
Tool paths: --bin-dir or PEAKMETAL_BIN (smolv_decode, spirv-cross); --metal or PEAKMETAL_METAL.
"""
import argparse
import collections
import os
import sys
import time

from . import __version__


def _load(path):
    import UnityPy
    return UnityPy.load(path)


def _shaders(env, only=None):
    from .common import shader as S
    for obj in env.objects:
        if obj.type.name == "Shader":
            tt = obj.read_typetree()
            if only is None or S.shader_name(tt) == only:
                yield obj, tt


def cmd_inspect(a):
    from .common import params as P
    from .common import program as G
    from .common import shader as S
    env = _load(a.file)
    for obj, tt in _shaders(env, a.shader):
        plats = S.load_platforms(tt)
        desc = ", ".join(f"{G.PLATFORM_NAMES.get(p, p)}: {len(pb.program_idx)} programs/{len(pb.entries)} entries"
                         for p, pb in plats.items())
        print(f"{obj.assets_file.name}  {S.shader_name(tt)}  [{desc}]")
        if a.shader:
            for si, pi, st, g, k, s, pbi in S.iter_subprograms(tt):
                t = s["m_GpuProgramType"]
                p = next((pp for pp, pb in plats.items() if t in S.platform_types(pp)), None)
                pe = plats[p].program(s["m_BlobIndex"])
                print(f"  ss{si}/p{pi}/{st}/g{g} {G.GPU_PROGRAM_TYPES.get(t, t)} blob={s['m_BlobIndex']} "
                      f"params={pbi} kw={pe.keywords}")
                if a.params:
                    print("    " + P.describe(plats[p].params(pbi)).replace("\n", "\n    "))


def cmd_roundtrip(a):
    from UnityPy.helpers import TypeTreeHelper
    from UnityPy.streams import EndianBinaryWriter
    from .common import blob as B
    from .common import params as P
    from .common import program as G
    from .common import shader as S
    env = _load(a.file)
    c = collections.Counter()
    bad = []
    for obj, tt in _shaders(env, a.shader):
        name = S.shader_name(tt)
        raw = obj.get_raw_data()
        w = EndianBinaryWriter(endian=obj.reader.endian)
        TypeTreeHelper.write_typetree(tt, obj._get_typetree_node(), w, obj.assets_file)
        ok_tt = w.bytes == raw
        plats = S.load_platforms(tt)
        ok_entries = True
        for p, pb in plats.items():
            for i, e in enumerate(pb.entries):
                k = pb.kind(i)
                if k == "program":
                    pe = G.decode(e)
                    ok_entries &= G.encode(pe) == e
                    if p == G.PLATFORM_METAL:
                        ok_entries &= G.encode_metal(G.decode_metal(pe.data)) == pe.data
                    if p == G.PLATFORM_VULKAN:
                        G.decode_vulkan(pe.data)
                elif k == "params":
                    ok_entries &= P.encode(P.decode(e)) == e
        # full re-encode of the blob (entries -> segments -> LZ4HC level 9) must give Unity's exact bytes
        tt2 = dict(tt)
        S.store_platforms(tt2, plats, order=list(tt["platforms"]))
        ok_blob = (bytes(tt2["compressedBlob"]) == bytes(tt["compressedBlob"]) and
                   tt2["offsets"] == tt["offsets"] and tt2["compressedLengths"] == tt["compressedLengths"] and
                   tt2["decompressedLengths"] == tt["decompressedLengths"])
        w2 = EndianBinaryWriter(endian=obj.reader.endian)
        TypeTreeHelper.write_typetree(tt2, obj._get_typetree_node(), w2, obj.assets_file)
        ok_all = w2.bytes == raw
        for k, v in (("typetree", ok_tt), ("entries", ok_entries), ("blob", ok_blob), ("object", ok_all)):
            c[(k, v)] += 1
        if not (ok_tt and ok_entries and ok_blob and ok_all):
            bad.append(name)
    for k, v in sorted(c.items(), key=str):
        print(f"{k[0]:9} {'exact' if k[1] else 'DIFF':6} {v}")
    if bad:
        print("not exact:", bad[:50])
    return 1 if bad else 0


def cmd_translate(a):
    from .common import params as P
    from .common import shader as S
    from . import inject, tools, translate
    env = _load(a.file)
    os.makedirs(a.out, exist_ok=True)
    tc = tools.Toolchain(bin_dir=a.bin_dir, scratch=os.path.join(a.out, "tmp"))
    for obj, tt in _shaders(env, a.shader):
        plats = S.load_platforms(tt)
        res = inject.translate_shader(tt, plats, tc, translate.Options(msl_version=a.msl_version))
        for (si, pj, bi, pi), r in res.items():
            base = os.path.join(a.out, f"ss{si}_pass{pj}_b{bi}_p{pi}")
            if r.status != "ok":
                print(f"blob {bi}: {r.status}: {r.reason}")
                continue
            for model, st in r.stages.items():
                with open(f"{base}_{model}.metal", "w", encoding="utf-8", newline="\n") as fh:
                    fh.write(st.msl)
                with open(f"{base}_{model}.params.txt", "w", encoding="utf-8") as fh:
                    fh.write(P.describe(st.params) + "\n")
            print(f"blob {bi}: ok {r.warnings or ''}")


def cmd_golden(a):
    from .common import shader as S
    from . import golden, tools, translate
    tc = tools.Toolchain(bin_dir=a.bin_dir)
    rows = []
    for f in a.files:
        env = _load(f)
        for obj, tt in _shaders(env):
            if not tt["platforms"]:
                continue
            plats = S.load_platforms(tt)
            for r in golden.compare_shader(tt, plats, tc, translate.Options(msl_version=a.msl_version)):
                r["shader"] = S.shader_name(tt)
                rows.append(r)
                if r["diffs"] or r["status"] != "ok":
                    print(f"{r['shader']} {r['key'][:3]} {r['status']} {r['reason']} {r['diffs'][:3]}")
    c, kinds = golden.summarize(rows)
    print("golden:", dict(c), "diff kinds:", dict(kinds))


def cmd_convert(a):
    from . import convert
    convert.convert(a.file, a.out, mode=a.mode, jobs=a.jobs, bin_dir=a.bin_dir, msl_version=a.msl_version,
                    only=a.only, compute=not a.no_compute, packer=a.packer)


def cmd_validate(a):
    from . import validate
    s = validate.run(a.dir, metal=a.metal, std=a.std, jobs=a.jobs, report_path=a.report)
    return 0 if s.get("skipped") or s.get("failed", 0) == 0 else 1


def main(argv=None):
    ap = argparse.ArgumentParser(prog="peakmetal", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", action="version", version=__version__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p, tools_=True):
        if tools_:
            p.add_argument("--bin-dir")
            p.add_argument("--msl-version", type=int, default=20100)
        return p

    p = sub.add_parser("inspect")
    p.add_argument("file")
    p.add_argument("--shader")
    p.add_argument("--params", action="store_true")
    p.set_defaults(fn=cmd_inspect)
    p = sub.add_parser("roundtrip")
    p.add_argument("file")
    p.add_argument("--shader")
    p.set_defaults(fn=cmd_roundtrip)
    p = common(sub.add_parser("translate"))
    p.add_argument("file")
    p.add_argument("--shader", required=True)
    p.add_argument("--out", required=True)
    p.set_defaults(fn=cmd_translate)
    p = common(sub.add_parser("golden"))
    p.add_argument("files", nargs="+")
    p.set_defaults(fn=cmd_golden)
    p = common(sub.add_parser("convert"))
    p.add_argument("file")
    p.add_argument("--out", required=True)
    p.add_argument("--mode", choices=("loose", "bundle", "both"), default="loose")
    p.add_argument("--packer", choices=("lz4hc", "lz4", "none"), default="lz4hc")
    p.add_argument("--jobs", type=int)
    p.add_argument("--only")
    p.add_argument("--no-compute", action="store_true")
    p.set_defaults(fn=cmd_convert)
    p = sub.add_parser("validate")
    p.add_argument("dir")
    p.add_argument("--metal")
    p.add_argument("--std", default="macos-metal2.1")
    p.add_argument("--jobs", type=int)
    p.add_argument("--report")
    p.set_defaults(fn=cmd_validate)
    a = ap.parse_args(argv)
    t0 = time.time()
    rc = a.fn(a) or 0
    print(f"[{a.cmd} done in {time.time() - t0:.0f}s]", file=sys.stderr)
    return rc


if __name__ == "__main__":
    sys.exit(main())
