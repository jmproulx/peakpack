"""`pm.py doctor`: environment report and self-test.

    python -I native/pm.py doctor [--data FILE|DIR] [--shader NAME] [--json FILE] [--spirv-cross PATH]

Without --data (the CI bundle check runs it this way: no game data, no network, no Xcode) it reports python,
UnityPy, lz4 and spirv-cross, and translates a built-in synthetic Unity-style program (selftest.py, our own
hand-assembled SPIR-V; no game or Unity data). Writes nothing except an optional --json report and temp files
under the system temp directory.

With --data it also runs the real pipeline on Unity's own shaders. Pass PEAK's `PEAK_Data` folder (or its
`Resources/unity default resources`, ~6 MB, shipped with every PEAK install): those Unity built-in shaders carry
Vulkan AND Unity's own Metal programs, so the Metal we generate is diffed against Unity's (same structural diff
as `golden`), then injected Metal-only and re-read; one ComputeShader is converted too. Any serialized file or
data.unity3d works (golden diff only where the file has Metal programs).

Exit code: 0 all checks passed, 2 environment problem (python too old, UnityPy/lz4 missing, spirv-cross not
found or not runnable), 3 a self-test check failed.
"""
import json
import os
import platform
import sys
import time

from . import __version__

MIN_PYTHON = (3, 10)


class _Report:
    def __init__(self):
        self.info, self.checks = {}, []

    def check(self, name, ok, detail="", env=False):
        self.checks.append({"name": name, "ok": bool(ok), "detail": detail, "environment": env})
        print(f"  [{'ok' if ok else 'FAIL'}] {name}" + (f": {detail}" if detail and not ok else ""))
        return ok

    def set(self, key, value):
        self.info[key] = value
        print(f"  {key}: {value}")


def _third_party_modules():
    std = getattr(sys, "stdlib_module_names", ())
    tops = {m.split(".")[0] for m in list(sys.modules)}
    return sorted(t for t in tops if t and not t.startswith("_") and t not in std and t != "peakmetal")


def _resolve_data(path):
    """A PEAK_Data folder (or the game folder) -> its `Resources/unity default resources`; a file -> itself."""
    if os.path.isdir(path):
        for cand in (os.path.join(path, "Resources", "unity default resources"),
                     os.path.join(path, "PEAK_Data", "Resources", "unity default resources")):
            if os.path.isfile(cand):
                return cand
        raise FileNotFoundError(f"no Resources/unity default resources under {path}")
    if not os.path.isfile(path):
        raise FileNotFoundError(path)
    return path


def run(args):
    t0 = time.time()
    rep = _Report()
    print(f"peakmetal {__version__} doctor")
    rep.set("peakmetal", __version__)
    rep.set("python", f"{platform.python_version()} ({sys.executable})")
    rep.set("platform", f"{platform.system()} {platform.machine()} {platform.release()}")
    env_ok = rep.check(f"python >= {MIN_PYTHON[0]}.{MIN_PYTHON[1]}", sys.version_info[:2] >= MIN_PYTHON,
                       platform.python_version(), env=True)
    try:
        import lz4
        import UnityPy
        rep.set("UnityPy", getattr(UnityPy, "__version__", "?"))
        rep.set("lz4", getattr(lz4, "__version__", "?"))
        rep.check("import UnityPy, lz4", True, env=True)
    except ImportError as ex:
        env_ok = rep.check("import UnityPy, lz4", False, str(ex), env=True) and env_ok
        UnityPy = None

    from . import tools
    tc = None
    try:
        tc = tools.Toolchain(spirv_cross=args.spirv_cross, bin_dir=args.bin_dir, scratch=getattr(args, "scratch", None))
        rep.set("spirv-cross", f"{tc.spirv_cross} (found by {tc.spirv_cross_found_by})")
        rep.set("spirv-cross --revision", tools.spirv_cross_revision(tc.spirv_cross) or "?")
        rep.set("smol-v decoder", tc.smolv_backend)
        rep.check("spirv-cross runs", True, env=True)
    except tools.ToolError as ex:
        env_ok = rep.check("spirv-cross found and runs", False, str(ex), env=True) and env_ok
    metal = tools.find_metal(args.metal)
    rep.set("metal compiler (optional, validation only)", metal or "not used")

    if tc is not None:
        from . import selftest
        print("synthetic self-test (built-in program, no game data):")
        checks, _ = selftest.run(tc, metal)
        for name, ok, detail in checks:
            rep.check(name, ok, detail)

    if args.data and tc is not None and UnityPy is not None:
        _data_checks(rep, tc, args, UnityPy)

    rep.set("third-party modules imported", ", ".join(_third_party_modules()))
    failed = [c for c in rep.checks if not c["ok"]]
    code = 0 if not failed else (2 if any(c["environment"] for c in failed) else 3)
    rep.set("result", "ok" if code == 0 else f"{len(failed)} check(s) failed")
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump({"schema": "peakmetal.doctor/1", "exit_code": code, "seconds": round(time.time() - t0, 1),
                       "info": rep.info, "checks": rep.checks}, fh, indent=1)
    return code


def _data_checks(rep, tc, args, UnityPy):
    from . import golden, inject, translate
    from .common import program as G
    from .common import shader as S
    try:
        path = _resolve_data(args.data)
    except FileNotFoundError as ex:
        rep.check("--data readable", False, str(ex), env=True)
        return
    print(f"real data: {path}")
    env = UnityPy.load(path)
    opts = translate.Options()
    n_sh = n_ok = 0
    rows = []
    for obj in env.objects:
        if obj.type.name != "Shader":
            continue
        tt = obj.read_typetree()
        name = S.shader_name(tt)
        if args.shader and name != args.shader:
            continue
        if not tt["platforms"] or G.PLATFORM_VULKAN not in tt["platforms"]:
            continue
        plats = S.load_platforms(tt)
        if G.PLATFORM_METAL in plats:
            rows += [dict(r, shader=name) for r in golden.compare_shader(tt, plats, tc, opts)]
        results = inject.translate_shader(tt, plats, tc, opts)
        report = inject.ShaderReport(name)
        inject.build_metal_only(tt, plats, results, report)
        back = S.load_platforms(tt)
        metal_ok = list(back) == [G.PLATFORM_METAL] and all(
            G.decode_metal(back[G.PLATFORM_METAL].program(i).data).entry == "xlatMtlMain"
            for i in back[G.PLATFORM_METAL].program_idx)
        n_sh += 1
        good = metal_ok and not report.errors and (report.ok > 0 or report.programs == 0)   # unsupported = by design
        n_ok += good
        if not good:
            rep.check(f"{name}: translate + inject Metal-only", False, f"{report.status} {report.errors}")
        if args.shader is None and n_sh >= 6:
            break
    rep.check(f"translate + inject + re-read ({n_ok}/{n_sh} shaders)", n_sh > 0 and n_ok == n_sh,
              "no shader with Vulkan programs in this file" if not n_sh else "")
    if rows:
        c, kinds = golden.summarize(rows)
        bad = golden.unexplained(rows)
        rep.set("golden diff vs Unity's own Metal", f"{dict(c)}")
        rep.check(f"generated Metal matches Unity's Metal structurally ({c.get('match', 0)} stage pairs)",
                  not bad and c.get("match", 0) > 0, "; ".join(f"{r['shader']}: {r['diffs'][:2]}" for r in bad[:3]))
    css = sorted((o for o in env.objects if o.type.name == "ComputeShader"), key=lambda o: o.byte_size)
    if css:
        from .compute import codec as CC
        from .compute import convert as CCV
        for obj in css:                      # the smallest ComputeShader that has a Vulkan variant
            raw = obj.get_raw_data()
            try:
                cs = CC.decode(raw)
            except Exception:  # noqa: BLE001 - not decodable by this codec version; try the next one
                continue
            if [v["targetRenderer"] for v in cs["variants"]].count(21) != 1:
                continue
            try:
                new, recs = CCV.convert_object_bytes(raw, tc.spirv_cross)
                out = CC.decode(new)
                ok = [v["targetRenderer"] for v in out["variants"]] == [16] and all(r["status"] == "ok" for r in recs)
                rep.check(f"compute {cs['m_Name']}: {len(recs)} kernel variant(s) -> Metal", ok)
            except Exception as ex:  # noqa: BLE001 - reported
                rep.check(f"compute {cs['m_Name']} conversion", False, f"{type(ex).__name__}: {ex}")
            break
