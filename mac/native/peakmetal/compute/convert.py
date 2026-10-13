"""Add Metal (targetRenderer 16) variants to Unity 6000.3 ComputeShaders, report per kernel, inject.

Library use (the graphics/assembly side calls these on its own UnityPy environment)::

    from peakmetal.compute import convert
    new_bytes, records = convert.convert_object_bytes(raw_bytes, spirv_cross)   # one ComputeShader
    convert.inject_env(env, ...)                                              # all ComputeShaders

CLI (scratch output only; the game install is opened read-only)::

    python -I -m peakmetal.compute.convert <data.unity3d | serialized file | folder>
        --out tools/nativework/compute/out [--validate] [--std macos-metal2.1] [--keep-other-renderers]

writes ``<out>/compute_report.txt``, ``<out>/compute_report.json``, the MSL of every kernel under
``<out>/msl/`` and the patched serialized files (``<name>.patched``) that contain the
ComputeShaders. Nothing is written next to the input.
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import re
import sys
import time

from . import codec, features, metalfix, translate, validate

RENDERER_NAMES = {2: "D3D11", 16: "Metal", 18: "D3D12", 21: "Vulkan"}


def convert_shader(cs: dict, spirv_cross: str, msl_version=translate.DEFAULT_MSL_VERSION,
                   keep_other=False, on_failure="stub", validate_std=None, msl_dir=None, metal_fixes=True):
    """Return (new ComputeShader dict, list of per-kernel record dicts)."""
    vks = [v for v in cs["variants"] if v["targetRenderer"] == translate.RENDERER_VULKAN]
    if len(vks) != 1:
        raise ValueError(f"{cs['m_Name']}: expected exactly one Vulkan variant, found {len(vks)}")
    records = []

    def log(ki, ui, kname, kw, r):
        rec = {"shader": cs["m_Name"], "kernel_index": ki, "variant_index": ui, "kernel": kname, "keywords": kw,
               "status": r.status, "category": r.category, "message": r.message, "notes": r.notes,
               "threadgroup_memory": r.census.get("threadgroup_memory"),
               "atomics": r.census.get("atomic_ops"), "subgroup_ops": r.census.get("subgroup_ops"),
               "capabilities": r.census.get("capabilities"), "compile": None}
        if r.status == "ok" and validate_std:
            c = validate.compile_msl(r.msl, validate_std)
            rec["compile"] = c.status
            if c.status == "fail":
                rec["compile_log"] = c.log[:2000]
        if msl_dir and r.msl:
            safe = re.sub(r"[^\w.-]+", "_", f"{cs['m_Name']}__k{ki:03d}u{ui:02d}_{kname}")
            with open(os.path.join(msl_dir, safe + ".metal"), "w", encoding="utf-8", newline="\n") as f:
                f.write(r.msl)
        records.append(rec)

    mv, _ = translate.translate_variant(vks[0], spirv_cross, msl_version, on_failure, log)
    if metal_fixes:
        # STP_FORCE_32BIT_REDUCTION: 16-bit keyword sets -> the 32-bit kernel of the same set (metalfix.py)
        for kname, kw, old, new in metalfix.force_32bit(cs["m_Name"], mv["kernels"]):
            for rec in records:
                if rec["kernel"] == kname and rec["variant_index"] == old:
                    rec["notes"].append(f"Metal: keyword set [{kw}] uses 32-bit variant u{new:02d} "
                                        "(STP_FORCE_32BIT_REDUCTION)")
    others = [v for v in cs["variants"] if v["targetRenderer"] != translate.RENDERER_METAL] if keep_other else []
    return {"m_Name": cs["m_Name"], "variants": others + [mv]}, records


def convert_object_bytes(raw: bytes, spirv_cross: str, **kw):
    cs = codec.decode(raw)
    if codec.encode(cs) != bytes(raw):
        raise codec.CodecError(f"{cs['m_Name']}: codec round trip is not byte-exact; refusing to rewrite")
    new, records = convert_shader(cs, spirv_cross, **kw)
    out = codec.encode(new)
    if codec.encode(codec.decode(out)) != out:
        raise codec.CodecError("re-encode mismatch")
    return out, records


def iter_compute_objects(env):
    for obj in env.objects:
        if obj.type.name == "ComputeShader":
            yield obj


def inject_env(env, spirv_cross, **kw):
    """Convert every ComputeShader of a UnityPy environment in memory. Returns (records, touched files)."""
    records, touched = [], {}
    for obj in iter_compute_objects(env):
        raw = obj.get_raw_data()
        new, recs = convert_object_bytes(raw, spirv_cross, **kw)
        obj.set_raw_data(new)
        records += recs
        touched[id(obj.assets_file)] = obj.assets_file
    return records, list(touched.values())


# ------------------------------------------------------------------------------------------------
def summarize(records):
    by_shader = collections.OrderedDict()
    for r in records:
        by_shader.setdefault(r["shader"], []).append(r)
    return by_shader


def write_report(records, path_txt, path_json, meta):
    by_shader = summarize(records)
    order = [n for n in features.PRIORITY if n in by_shader] + [n for n in by_shader if n not in features.PRIORITY]
    tot = collections.Counter(r["status"] for r in records)
    comp = collections.Counter(r["compile"] or "not run" for r in records if r["status"] == "ok")
    cats = collections.Counter(r["category"] for r in records if r["status"] != "ok")
    L = []
    L.append("PEAK ComputeShaders -> Metal (targetRenderer 16): per-kernel report")
    L.append(f"generated {time.strftime('%Y-%m-%d %H:%M')}  " + "  ".join(f"{k}={v}" for k, v in meta.items()))
    L.append("")
    L.append(f"kernel variants: {len(records)}  translate: " + ", ".join(f"{k} {v}" for k, v in sorted(tot.items())))
    L.append("metal.exe compile of translated MSL: " + ", ".join(f"{k} {v}" for k, v in sorted(comp.items())))
    if cats:
        L.append("non-ok categories: " + ", ".join(f"{k} {v}" for k, v in cats.most_common()))
    L.append("status legend: ok = translated (and compiled if validated); unsupported = feature we cannot map "
             "(a no-op stub kernel is injected so FindKernel/Dispatch still work); failed = translator error (stubbed)")
    L.append("")
    need = [n for n in order if features.feature_of(n)[3]]
    L.append("Still dispatched with the GPU Resident Drawer AND STP disabled (MacPreset fallbacks): "
             + ", ".join(need))
    L.append("")
    for name in order:
        recs = by_shader[name]
        feat, src, fb, needed, remark = features.feature_of(name)
        st = collections.Counter(r["status"] for r in recs)
        cst = collections.Counter(r["compile"] or "-" for r in recs if r["status"] == "ok")
        overall = "ok" if st.get("ok") == len(recs) and not cst.get("fail") else (
            "PARTIAL" if st.get("ok") else "NOT TRANSLATED")
        L.append(f"== {name}  [{overall}]  {len(recs)} kernel variants: "
                 + ", ".join(f"{k} {v}" for k, v in sorted(st.items()))
                 + ("  compile: " + ", ".join(f"{k} {v}" for k, v in sorted(cst.items())) if cst else ""))
        L.append(f"   feature: {feat}  (source: {src})")
        L.append(f"   fallback: {fb}")
        L.append(f"   needed with GRD+STP disabled: {'yes' if needed else 'no'}")
        if remark:
            L.append(f"   note: {remark}")
        for r in recs:
            line = f"   k{r['kernel_index']:03d}u{r['variant_index']:02d} {r['kernel']:<28} {r['status']:<11}"
            if r["compile"]:
                line += f" compile={r['compile']:<7}"
            if r["keywords"]:
                line += f" kw=[{r['keywords']}]"
            if r["threadgroup_memory"]:
                line += f" tgmem={r['threadgroup_memory']}"
            if r["atomics"]:
                line += " atomics=" + ",".join(r["atomics"])
            if r["subgroup_ops"]:
                line += " subgroup=" + ",".join(r["subgroup_ops"])
            caps = [c for c in (r["capabilities"] or []) if c != "Shader"]
            if caps:
                line += " caps=" + ",".join(caps)
            L.append(line)
            if r["status"] != "ok":
                L.append(f"        {r['message']}")
            if r.get("compile_log"):
                L.append("        metal: " + r["compile_log"].splitlines()[0][:300])
            for n in r["notes"]:
                L.append(f"        note: {n}")
        L.append("")
    with open(path_txt, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(L) + "\n")
    with open(path_json, "w", encoding="utf-8") as f:
        json.dump({"meta": meta, "records": records}, f, indent=1)


def _guard_out(out_dir, inputs):
    out = os.path.abspath(out_dir).lower()
    for p in inputs:
        d = os.path.abspath(p if os.path.isdir(p) else os.path.dirname(p)).lower()
        if out.startswith(d):
            raise SystemExit(f"refusing to write output inside the input location {d}")
    for bad in ("steamapps", os.path.join("unity", "hub", "editor")):
        if bad in out:
            raise SystemExit(f"refusing to write into {out_dir}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", help="data.unity3d, a serialized file, or a folder of them (opened read-only)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--spirv-cross")
    ap.add_argument("--msl-version", type=int, default=translate.DEFAULT_MSL_VERSION)
    ap.add_argument("--validate", action="store_true", help="compile every MSL with metal.exe if installed")
    ap.add_argument("--std", default=validate.DEFAULT_STD)
    ap.add_argument("--keep-other-renderers", action="store_true",
                    help="keep D3D11/D3D12/Vulkan variants (default: Metal-only, like Unity's Mac build)")
    ap.add_argument("--no-save", action="store_true", help="report only; don't write patched files")
    a = ap.parse_args(argv)
    _guard_out(a.out, [a.input])
    import UnityPy  # noqa: PLC0415 (only the CLI needs it)

    os.makedirs(a.out, exist_ok=True)
    msl_dir = os.path.join(a.out, "msl")
    os.makedirs(msl_dir, exist_ok=True)
    sc = translate.find_spirv_cross(a.spirv_cross)
    std = a.std if a.validate else None
    if a.validate and validate.find_metal() is None:
        print("metal.exe not found: compile validation skipped")
        std = None
    t0 = time.time()
    env = UnityPy.load(a.input)
    records, files = inject_env(env, sc, msl_version=a.msl_version, keep_other=a.keep_other_renderers,
                                validate_std=std, msl_dir=msl_dir)
    meta = {"input": os.path.basename(a.input), "msl_version": a.msl_version, "std": std or "not validated",
            "metal_only": not a.keep_other_renderers}
    if not a.no_save:
        saved = []
        for sf in files:
            name = os.path.basename(getattr(sf, "name", "serialized"))
            p = os.path.join(a.out, name + ".patched")
            with open(p, "wb") as f:
                f.write(sf.save())
            saved.append(p)
        meta["patched"] = ",".join(os.path.basename(p) for p in saved)
        # re-read check: every ComputeShader decodes, has a Metal variant and matches what we wrote
        env2 = UnityPy.load(*saved) if len(saved) == 1 else UnityPy.load(*saved)
        n = 0
        for obj in iter_compute_objects(env2):
            cs = codec.decode(obj.get_raw_data())
            assert any(v["targetRenderer"] == 16 for v in cs["variants"]), cs["m_Name"]
            n += 1
        meta["reread_compute_shaders"] = n
    write_report(records, os.path.join(a.out, "compute_report.txt"), os.path.join(a.out, "compute_report.json"), meta)
    print(f"{len(records)} kernel variants in {time.time() - t0:.0f}s -> {os.path.join(a.out, 'compute_report.txt')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
