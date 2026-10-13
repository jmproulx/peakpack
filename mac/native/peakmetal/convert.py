"""Whole-game conversion: every Shader in a COPY of the game's data -> Metal-only, then repack.

    python -I -m peakmetal convert <PEAK_Data/data.unity3d or a serialized file> --out <dir>
        [--mode loose|bundle|both] [--jobs N] [--no-compute] [--only NAME]

Outputs under --out:
    Data/            loose serialized files (mode loose/both)       -> the Mac player's Data folder
    data.unity3d     repacked archive (mode bundle/both)
    msl/<shader>/    every distinct emitted MSL program (for `validate`)
    convert_report.txt, convert_report.json
The input is only read. Nothing is written next to it.
"""
import json
import os
import re
import time
from concurrent.futures import ThreadPoolExecutor

import UnityPy

from . import inject, repack, tools, translate
from .common import program as G
from .common import shader as S


def safe(name):
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", name)[:120]


def check_output_location(src, out):
    """Never write next to the game's files, into a Steam library or into a Unity install: conversion
    always works on a copy elsewhere (the Mac app assembles PEAK Native.app from the output)."""
    o = os.path.normcase(os.path.abspath(out))
    s = os.path.normcase(os.path.dirname(os.path.abspath(src)))
    parts = {p.lower() for p in o.replace("\\", "/").split("/")}
    if o == s or o.startswith(s + os.sep) or "steamapps" in parts or \
            ("unity" in parts and "editor" in parts):
        raise SystemExit(f"refusing to write into {out}: choose a scratch folder outside the game/Unity install")


def dump_msl(tt, out_root, name):
    """Write each distinct Metal program of a converted shader as <out_root>/<shader>/<idx>_<vs|fs>.metal."""
    plats = S.load_platforms(tt)
    pb = plats.get(G.PLATFORM_METAL)
    if not pb:
        return 0
    d = os.path.join(out_root, safe(name))
    os.makedirs(d, exist_ok=True)
    n = 0
    for i in sorted(pb.program_idx):
        pe = pb.program(i)
        m = G.decode_metal(pe.data)
        with open(os.path.join(d, f"{i:05d}_{'vs' if pe.gpu_type == G.METAL_VS else 'fs'}.metal"), "w",
                  encoding="utf-8", newline="\n") as fh:
            fh.write(m.source)
        n += 1
    return n


def convert(src, out, mode="loose", jobs=None, bin_dir=None, msl_version=20100, only=None, compute=True,
            log=print, packer="lz4hc", dump=True):
    t0 = time.time()
    check_output_location(src, out)
    os.makedirs(out, exist_ok=True)
    scratch = os.path.join(out, "tmp")
    tc = tools.Toolchain(bin_dir=bin_dir, scratch=scratch)
    opts = translate.Options(msl_version=msl_version)
    log(f"loading {src}")
    env = UnityPy.load(src)
    log(f"loaded in {time.time() - t0:.0f}s")
    pool = ThreadPoolExecutor(jobs or min(32, os.cpu_count() or 4))
    cache = {}
    reports = []
    for obj in env.objects:
        if obj.type.name != "Shader":
            continue
        tt = obj.read_typetree()
        name = S.shader_name(tt)
        if only and only != name:
            continue
        t1 = time.time()
        rep = inject.ShaderReport(name)
        plats = S.load_platforms(tt)
        if G.PLATFORM_VULKAN not in plats:
            rep.errors["no Vulkan programs in source"] = 1
            reports.append((rep, obj.assets_file.name, 0.0))
            continue
        results = inject.translate_shader(tt, plats, tc, opts, pool, cache)
        inject.build_metal_only(tt, plats, results, rep)
        obj.save_typetree(tt)
        if dump:
            dump_msl(tt, os.path.join(out, "msl"), name)
        reports.append((rep, obj.assets_file.name, time.time() - t1))
        log(f"  {name}: {rep.status} {rep.ok}/{rep.programs} ({rep.metal_bytes / 1e6:.1f} MB Metal)")
    pool.shutdown()

    compute_records = None
    if compute:
        try:
            from .compute import convert as cconv
            log("compute shaders: peakmetal.compute.convert.inject_env")
            compute_records, _ = cconv.inject_env(env, tc.spirv_cross)
        except ImportError as ex:
            log(f"compute shaders skipped ({ex})")

    if mode in ("loose", "both"):
        repack.write_loose(env, os.path.join(out, "Data"), log=log)
    if mode in ("bundle", "both"):
        repack.write_bundle(env, os.path.join(out, "data.unity3d"), packer=packer, log=log)
    write_report(reports, out, src, time.time() - t0, compute_records)
    return reports


def write_report(reports, out, src, secs, compute_records=None):
    from collections import Counter
    st = Counter(r.status for r, _, _ in reports)
    progs = sum(r.programs for r, _, _ in reports)
    ok = sum(r.ok for r, _, _ in reports)
    lines = [f"peakmetal convert report  source={src}  time={secs:.0f}s",
             f"shaders: {len(reports)}  " + "  ".join(f"{k}={v}" for k, v in sorted(st.items())),
             f"programs (Vulkan variants): {ok}/{progs} translated", ""]
    reasons = Counter()
    for r, _, _ in reports:
        for k, v in list(r.unsupported.items()) + list(r.errors.items()):
            reasons[k] += v
    if reasons:
        lines.append("not translated (reason: count):")
        lines += [f"  {v:6d}  {k}" for k, v in reasons.most_common()]
        lines.append("")
    feats = Counter()
    for r, _, _ in reports:
        feats.update(r.features)
    lines.append("features used by emitted stages: " + ", ".join(f"{k}={v}" for k, v in feats.most_common()))
    lines.append("")
    lines.append(f"{'status':11} {'ok/progs':>10} {'MB':>6}  file / shader / notes")
    for r, fname, t in reports:
        notes = []
        if r.unsupported:
            notes.append("unsupported: " + "; ".join(r.unsupported))
        if r.errors:
            notes.append("errors: " + "; ".join(r.errors))
        if r.dropped_subshaders:
            notes.append(f"subshaders emptied (fallback): {r.dropped_subshaders}")
        if r.warnings:
            notes.append(f"warnings: {sum(r.warnings.values())}")
        lines.append(f"{r.status:11} {r.ok:>4}/{r.programs:<5} {r.metal_bytes / 1e6:6.1f}  {fname} / {r.name}"
                     + (("  [" + " | ".join(notes) + "]") if notes else ""))
    if compute_records is not None:
        cst = Counter(x.get("status") for x in compute_records)
        lines += ["", "compute (from peakmetal.compute): " + ", ".join(f"{k}={v}" for k, v in cst.items())]
    with open(os.path.join(out, "convert_report.txt"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    with open(os.path.join(out, "convert_report.json"), "w", encoding="utf-8") as fh:
        json.dump([{"shader": r.name, "file": f, "status": r.status, "programs": r.programs, "ok": r.ok,
                    "unsupported": r.unsupported, "errors": r.errors, "warnings": r.warnings,
                    "features": r.features, "dropped_subshaders": r.dropped_subshaders,
                    "metal_bytes": r.metal_bytes, "seconds": round(t, 2)} for r, f, t in reports], fh, indent=1)
