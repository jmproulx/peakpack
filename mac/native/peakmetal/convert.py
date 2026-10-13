"""Whole-game conversion: every Shader AND ComputeShader in a COPY of the game's data -> Metal-only, then repack.

    python -I native/pm.py convert <PEAK_Data/data.unity3d or a serialized file> --out <dir>
        [--mode loose|bundle|both] [--jobs N] [--no-compute] [--only NAME]

Outputs under --out:
    Data/                  loose serialized files (mode loose/both)       -> the Mac player's Data folder
    data.unity3d           repacked archive (mode bundle/both)
    msl/<shader>/          every distinct emitted graphics MSL program (for `validate`)
    msl/_compute/          every translated compute kernel's MSL (for `validate`)
    convert_summary.json   machine-readable result for the test kit / Mac app (schema in README.md)
    convert_report.txt|json, compute_report.txt|json   per-shader / per-kernel detail
The input is only read. Nothing is written next to it.

Exit codes (README.md "Running on macOS"): 0 ok; 1 internal error; 2 environment/usage error; 3 finished, with
fallbacks (see convert_summary.json "problems").
"""
import json
import os
import platform
import re
import sys
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

from . import __version__, inject, repack, tools, translate
from .common import program as G
from .common import shader as S

SUMMARY_NAME = "convert_summary.json"
SUMMARY_SCHEMA = "peakmetal.convert_summary/1"
EXIT_OK, EXIT_ERROR, EXIT_ENV, EXIT_FALLBACKS = 0, 1, 2, 3
NO_VULKAN = "no Vulkan programs in source"


class UsageError(Exception):
    """Bad input/output location or missing environment: exit code 2."""


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
        raise UsageError(f"refusing to write into {out}: choose a scratch folder outside the game/Unity install")


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
            log=print, packer="lz4hc", dump=True, spirv_cross=None, opts=None):
    """Convert and write every output. Returns the summary dict (also written to <out>/convert_summary.json);
    summary["exit_code"] is 0 or 3. Raises UsageError (exit 2) for input / output location / tool problems."""
    t0 = time.time()
    started = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    if not os.path.isfile(src):
        raise UsageError(f"input not found: {src}")
    check_output_location(src, out)
    try:
        import lz4  # noqa: F401  (UnityPy's archive codec; fail early with exit 2)
        import UnityPy
    except ImportError as ex:
        raise UsageError(f"UnityPy/lz4 not importable: {ex}") from ex
    os.makedirs(out, exist_ok=True)
    try:
        tc = tools.Toolchain(bin_dir=bin_dir, scratch=os.path.join(out, "tmp"), spirv_cross=spirv_cross)
        tools.spirv_cross_revision(tc.spirv_cross)          # runs it once: a non-executable binary is exit 2
    except tools.ToolError as ex:
        raise UsageError(str(ex)) from ex
    opts = opts or translate.Options(msl_version=msl_version)
    log(f"loading {src}")
    env = UnityPy.load(src)
    log(f"loaded in {time.time() - t0:.0f}s")
    pool = ThreadPoolExecutor(jobs or min(32, os.cpu_count() or 4))
    cache = {}
    reports = []
    n_msl = 0
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
            rep.unsupported[NO_VULKAN] = 1          # nothing to translate (as on Vulkan: Unity falls back)
            reports.append((rep, obj.assets_file.name, 0.0))
            continue
        results = inject.translate_shader(tt, plats, tc, opts, pool, cache)
        inject.build_metal_only(tt, plats, results, rep)
        obj.save_typetree(tt)
        if dump:
            n_msl += dump_msl(tt, os.path.join(out, "msl"), name)
        reports.append((rep, obj.assets_file.name, time.time() - t1))
        log(f"  {name}: {rep.status} {rep.ok}/{rep.programs} ({rep.metal_bytes / 1e6:.1f} MB Metal)")
    pool.shutdown()

    compute_records = None
    if compute:
        from .compute import convert as cconv
        log("compute shaders: peakmetal.compute.convert.inject_env")
        cdir = os.path.join(out, "msl", "_compute") if dump else None
        if cdir:
            os.makedirs(cdir, exist_ok=True)
        compute_records, _ = cconv.inject_env(env, tc.spirv_cross, msl_version=msl_version, msl_dir=cdir)
        cconv.write_report(compute_records, os.path.join(out, "compute_report.txt"),
                           os.path.join(out, "compute_report.json"),
                           {"input": os.path.basename(src), "msl_version": msl_version, "std": "not validated",
                            "metal_only": True})
        log(f"compute: {len(compute_records)} kernel variants "
            f"({', '.join(f'{k} {v}' for k, v in Counter(r['status'] for r in compute_records).items())})")

    outputs = {"loose_dir": None, "loose_files": 0, "loose_files_reserialized": 0, "bundle": None,
               "bundle_bytes": None, "msl_dir": "msl" if dump else None}
    if mode in ("loose", "both"):
        written = repack.write_loose(env, os.path.join(out, "Data"), log=log)
        outputs.update(loose_dir="Data", loose_files=len(written),
                       loose_files_reserialized=sum(1 for w in written if w[2]))
    if mode in ("bundle", "both"):
        outputs.update(bundle="data.unity3d",
                       bundle_bytes=repack.write_bundle(env, os.path.join(out, "data.unity3d"), packer=packer,
                                                        log=log))
    secs = time.time() - t0
    write_report(reports, out, src, secs, compute_records)
    summary = build_summary(reports, compute_records, src, out, mode, secs, started, tc, outputs, n_msl, opts)
    with open(os.path.join(out, SUMMARY_NAME), "w", encoding="utf-8") as fh:
        json.dump(summary, fh, indent=1)
    log(f"summary: {summary['status']} (exit {summary['exit_code']}) -> {os.path.join(out, SUMMARY_NAME)}")
    return summary


def _versions():
    v = {"python": platform.python_version(), "platform": f"{platform.system()} {platform.machine()}"}
    for mod in ("UnityPy", "lz4"):
        m = sys.modules.get(mod)
        v[mod.lower()] = getattr(m, "__version__", None) if m else None
    return v


def build_summary(reports, compute_records, src, out, mode, secs, started, tc, outputs, n_msl, opts):
    """The convert_summary.json document (schema peakmetal.convert_summary/1, documented in README.md)."""
    problems = []
    unsupported, failed = Counter(), Counter()
    for r, fname, _ in reports:
        for k, v in r.unsupported.items():
            unsupported[k] += v
        for k, v in r.errors.items():
            failed[k] += v
            problems.append({"kind": "graphics", "shader": r.name, "file": fname, "count": v, "detail": k})
    graphics = {
        "shaders": len(reports),
        "status_counts": dict(Counter(r.status for r, _, _ in reports)),
        "programs": sum(r.programs for r, _, _ in reports),
        "programs_translated": sum(r.ok for r, _, _ in reports),
        "programs_unsupported_by_design": sum(v for k, v in unsupported.items() if k != NO_VULKAN),
        "programs_failed": sum(failed.values()),
        "unsupported_reasons": dict(unsupported),
        "failure_reasons": dict(failed),
        "metal_bytes": sum(r.metal_bytes for r, _, _ in reports),
        "msl_files": n_msl,
        "features": dict(sum((Counter(r.features) for r, _, _ in reports), Counter())),
    }
    compute = None
    if compute_records is not None:
        cst = Counter(x["status"] for x in compute_records)
        notes = Counter()
        for x in compute_records:
            for n in x["notes"]:
                if n.startswith("STP_BUG_SAT_INF"):
                    notes["STP_BUG_SAT_INF rewrite"] += 1
                elif n.startswith("Metal: keyword set"):
                    notes["STP_FORCE_32BIT_REDUCTION keyword redirect"] += 1
            if x["status"] != "ok":
                problems.append({"kind": "compute", "shader": x["shader"], "kernel": x["kernel"],
                                 "keywords": x["keywords"], "detail": f"{x['status']}: {x['message']} (stub kernel)"})
        compute = {"shaders": len({x["shader"] for x in compute_records}), "kernel_variants": len(compute_records),
                   "status_counts": dict(cst), "fallback_stubs": len(compute_records) - cst.get("ok", 0),
                   "metal_workarounds": dict(notes)}
    code = EXIT_FALLBACKS if problems else EXIT_OK
    return {
        "schema": SUMMARY_SCHEMA,
        "peakmetal_version": __version__,
        "exit_code": code,
        "status": "ok" if code == EXIT_OK else "completed_with_fallbacks",
        "source": os.path.abspath(src), "out": os.path.abspath(out), "mode": mode,
        "started": started, "seconds": round(secs, 1),
        "tools": dict(_versions(), spirv_cross=tc.spirv_cross, spirv_cross_found_by=tc.spirv_cross_found_by,
                      smolv=tc.smolv_backend),
        "options": {"msl_version": opts.msl_version, "depth_textures": opts.depth_textures,
                    "unity_cb_names": opts.unity_cb_names, "framebuffer_fetch": opts.framebuffer_fetch},
        "outputs": outputs,
        "graphics": graphics,
        "compute": compute,
        "problems": problems,
        "reports": {"graphics_txt": "convert_report.txt", "graphics_json": "convert_report.json",
                    "compute_txt": "compute_report.txt" if compute is not None else None,
                    "compute_json": "compute_report.json" if compute is not None else None},
    }


def write_report(reports, out, src, secs, compute_records=None):
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
        lines += ["", "compute (from peakmetal.compute; detail in compute_report.txt): "
                  + ", ".join(f"{k}={v}" for k, v in cst.items())]
    with open(os.path.join(out, "convert_report.txt"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    with open(os.path.join(out, "convert_report.json"), "w", encoding="utf-8") as fh:
        json.dump([{"shader": r.name, "file": f, "status": r.status, "programs": r.programs, "ok": r.ok,
                    "unsupported": r.unsupported, "errors": r.errors, "warnings": r.warnings,
                    "features": r.features, "dropped_subshaders": r.dropped_subshaders,
                    "metal_bytes": r.metal_bytes, "seconds": round(t, 2)} for r, f, t in reports], fh, indent=1)
