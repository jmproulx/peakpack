"""Offline MSL compile validation with Apple's Metal Developer Tools for Windows (metal.exe).

Internal use on the build PC only (Apple's licence): never shipped, never run on CI. If metal.exe
is absent every call reports ``skipped`` so tests and the converter degrade gracefully.
"""
from __future__ import annotations

import os
import subprocess
import tempfile
from dataclasses import dataclass

DEFAULT_STD = "macos-metal2.1"     # matches translate.DEFAULT_MSL_VERSION; see README-compute.md


@dataclass
class CompileResult:
    status: str        # pass | fail | skipped
    log: str = ""


def find_metal(explicit=None):
    """Apple's metal compiler or None: same rules as peakmetal.tools.find_metal (explicit, $PEAKMETAL_METAL,
    then the Windows Metal Developer Tools install; PATH is never searched on macOS)."""
    from .. import tools
    return tools.find_metal(explicit)


def compile_msl(msl: str, std: str = DEFAULT_STD, metal=None, timeout=120) -> CompileResult:
    exe = find_metal(metal)
    if exe is None:
        return CompileResult("skipped", "metal.exe not installed")
    with tempfile.TemporaryDirectory(prefix="pmcs_metal_") as td:
        src = os.path.join(td, "k.metal")
        with open(src, "w", encoding="utf-8", newline="\n") as f:
            f.write(msl)
        p = subprocess.run([exe, "-c", f"-std={std}", src, "-o", os.path.join(td, "k.air")],
                           capture_output=True, text=True, timeout=timeout)
        log = (p.stderr + p.stdout).replace(src, "<kernel>")
        return CompileResult("pass" if p.returncode == 0 else "fail", log.strip())
