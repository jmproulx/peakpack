"""Compile-check emitted MSL with Apple's Metal compiler.

Windows: Metal Developer Tools for Windows (`C:\\Program Files\\Metal Developer Tools\\bin\\metal.exe`;
licensed for internal use on this PC only - never copied or redistributed, not run on CI).
macOS: `xcrun -sdk macosx metal`. If no compiler is found the command reports "skipped" and exits 0.

Default `-std=macos-metal2.1`: the oldest standard under which all 427 distinct Metal programs Unity
itself generated (editor golden files) compile; every std up to metal3.2 also passes
(tools/nativework/metalstd/report.txt).
"""
import os
import subprocess
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

from . import tools

DEFAULT_STD = "macos-metal2.1"


def iter_msl(root):
    for d, _, files in os.walk(root):
        for f in sorted(files):
            if f.endswith(".metal"):
                yield os.path.join(d, f)


def compile_one(metal, path, std, air_dir):
    out = os.path.join(air_dir, str(abs(hash(path))) + ".air") if air_dir else ("NUL" if os.name == "nt" else "/dev/null")
    r = subprocess.run([metal, "-c", f"-std={std}", "-o", out, path], capture_output=True, text=True)
    err = (r.stderr or "").strip()
    warnings = err.count(" warning: ")
    first = next((ln for ln in err.splitlines() if " error: " in ln), "") if r.returncode else ""
    if air_dir and os.path.exists(out):
        try:
            os.remove(out)
        except OSError:
            pass
    return path, r.returncode == 0, first, warnings, err


def run(root, metal=None, std=DEFAULT_STD, jobs=None, air_dir=None, log=print, report_path=None):
    metal = tools.find_metal(metal)
    if not metal:
        log("validate: Metal compiler not found (install Metal Developer Tools for Windows or Xcode); skipped")
        return {"skipped": True}
    files = list(iter_msl(root))
    if air_dir:
        os.makedirs(air_dir, exist_ok=True)
    log(f"validate: {len(files)} MSL files with {metal} -std={std}")
    res = []
    with ThreadPoolExecutor(jobs or min(32, (os.cpu_count() or 4))) as ex:
        for r in ex.map(lambda p: compile_one(metal, p, std, air_dir), files):
            res.append(r)
    ok = sum(1 for r in res if r[1])
    cats = Counter()
    examples = {}
    for p, good, first, w, err in res:
        if not good:
            key = first.split(" error: ", 1)[-1][:120] if first else "unknown"
            cats[key] += 1
            examples.setdefault(key, (p, err[:1500]))
    summary = {"skipped": False, "files": len(files), "ok": ok, "failed": len(files) - ok,
               "warnings": sum(r[3] for r in res), "categories": cats.most_common(), "std": std}
    lines = [f"metal validate: {ok}/{len(files)} compiled (-std={std}), {summary['warnings']} warnings"]
    for k, v in cats.most_common(30):
        lines.append(f"  {v:6d}  {k}")
        lines.append(f"          e.g. {examples[k][0]}")
    text = "\n".join(lines)
    log(text)
    if report_path:
        with open(report_path, "w", encoding="utf-8") as fh:
            fh.write(text + "\n\n")
            for k, (p, err) in examples.items():
                fh.write(f"=== {k}\n{p}\n{err}\n\n")
    return summary
