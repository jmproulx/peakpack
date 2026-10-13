"""Platform-neutral tool discovery, `doctor`, convert's exit codes and convert_summary.json (no game data needed
except where noted; data-dependent tests skip when inputs are absent)."""
import json
import os
import shutil
import stat

import pytest
from conftest import PEAK_UDR, need

from peakmetal import __main__ as cli
from peakmetal import convert, doctor, inject, selftest, tools, translate


@pytest.fixture
def clean_env(monkeypatch, tmp_path):
    for v in (tools.ENV_SPIRV_CROSS, tools.ENV_BIN, tools.ENV_SMOLV, tools.ENV_METAL):
        monkeypatch.delenv(v, raising=False)
    monkeypatch.setenv("PATH", str(tmp_path / "emptypath"))
    monkeypatch.setattr(tools, "PACKAGE_BIN", str(tmp_path / "nobin"))
    return tmp_path


def _fake_exe(d, name="spirv-cross"):
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, tools.exe_names(name)[0])
    with open(p, "wb") as f:
        f.write(b"")
    os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)
    return p


def test_exe_names():
    assert tools.exe_names("spirv-cross")[-1] == "spirv-cross"
    assert (tools.exe_names("x")[0] == "x.exe") == (os.name == "nt")


def test_spirv_cross_discovery_order(clean_env, monkeypatch):
    t = clean_env
    with pytest.raises(tools.ToolError, match="not found"):
        tools.find_spirv_cross()
    on_path = _fake_exe(t / "emptypath")
    assert tools.find_spirv_cross() == (on_path, "PATH")
    pkg = _fake_exe(t / "nobin")
    assert tools.find_spirv_cross() == (pkg, "package bin/")
    legacy = _fake_exe(t / "legacy")
    monkeypatch.setenv(tools.ENV_BIN, str(t / "legacy"))
    assert tools.find_spirv_cross() == (legacy, f"${tools.ENV_BIN}")
    env = _fake_exe(t / "env")
    monkeypatch.setenv(tools.ENV_SPIRV_CROSS, env)
    assert tools.find_spirv_cross() == (env, f"${tools.ENV_SPIRV_CROSS}")
    bd = _fake_exe(t / "bindir")
    assert tools.find_spirv_cross(bin_dir=str(t / "bindir")) == (bd, "--bin-dir")
    ex = _fake_exe(t / "explicit")
    assert tools.find_spirv_cross(explicit=ex) == (ex, "explicit")


def test_env_var_pointing_nowhere_is_an_error(clean_env, monkeypatch):
    _fake_exe(clean_env / "emptypath")                       # must NOT silently fall back to PATH
    monkeypatch.setenv(tools.ENV_SPIRV_CROSS, str(clean_env / "missing" / "spirv-cross"))
    with pytest.raises(tools.ToolError, match=tools.ENV_SPIRV_CROSS):
        tools.find_spirv_cross()


def test_python_smolv_is_default(clean_env):
    _fake_exe(clean_env / "nobin")
    _fake_exe(clean_env / "nobin", "smolv_decode")           # present, but only used when named explicitly
    tc = tools.Toolchain(scratch=str(clean_env / "s"))
    assert tc.smolv_backend.startswith("python")


def test_metal_never_searched_on_path_off_windows(clean_env, monkeypatch):
    _fake_exe(clean_env / "emptypath", "metal")
    monkeypatch.setattr(tools, "IS_WINDOWS", False)
    assert tools.find_metal() is None
    m = _fake_exe(clean_env / "m", "metal")
    monkeypatch.setenv(tools.ENV_METAL, m)
    assert tools.find_metal() == m


def test_no_windows_paths_in_spirv_cross_discovery():
    import inspect
    src = inspect.getsource(tools.find_tool) + inspect.getsource(tools.find_spirv_cross)
    assert "C:\\" not in src and "shaderwork" not in src and ".exe\"" not in src


def test_selftest_passes(toolchain):
    checks, r = selftest.run(toolchain, tools.find_metal())
    assert all(ok for _, ok, _ in checks), [c for c in checks if not c[1]]


def test_doctor_no_data_exit_0(toolchain, tmp_path):
    """As the CI bundle runs it: a fresh isolated interpreter, -B, no data."""
    import subprocess
    import sys
    j = tmp_path / "doctor.json"
    pm = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "pm.py")
    p = subprocess.run([sys.executable, "-I", "-B", pm, "doctor", "--json", str(j)], capture_output=True, text=True,
                       cwd=str(tmp_path), env=dict(os.environ, **{tools.ENV_SPIRV_CROSS: toolchain.spirv_cross}))
    assert p.returncode == 0, p.stdout[-2000:] + p.stderr[-2000:]
    rep = json.loads(j.read_text())
    assert rep["schema"] == "peakmetal.doctor/1" and rep["exit_code"] == 0
    mods = set(rep["info"]["third-party modules imported"].split(", "))
    # the bundle's 7 hash-locked packages (import names); nothing from UnityPy's export extras
    assert mods <= {"PIL", "UnityPy", "attr", "attrs", "brotli", "fsspec", "lz4", "tpk_ar"}, mods


def test_doctor_missing_spirv_cross_exit_2(monkeypatch, tmp_path):
    monkeypatch.setenv(tools.ENV_SPIRV_CROSS, str(tmp_path / "nope"))
    assert cli.main(["doctor"]) == 2


def test_doctor_with_unity_golden_data(toolchain):
    need(PEAK_UDR)

    class A:
        data, shader, json, spirv_cross, bin_dir, metal, scratch = PEAK_UDR, None, None, None, None, None, None
    assert doctor.run(A()) == 0


def test_convert_usage_errors(tmp_path, toolchain):
    assert cli.main(["convert", str(tmp_path / "missing.unity3d"), "--out", str(tmp_path / "o")]) == 2
    src = tmp_path / "game" / "data.unity3d"
    src.parent.mkdir()
    src.write_bytes(b"x")
    with pytest.raises(convert.UsageError):
        convert.check_output_location(str(src), str(tmp_path / "game" / "out"))
    with pytest.raises(convert.UsageError):
        convert.check_output_location(str(src), str(tmp_path / "steamapps" / "out"))


class _TC:
    spirv_cross, spirv_cross_found_by, smolv_backend = "/x/spirv-cross", "PATH", "python"


def _summary(reports, compute):
    return convert.build_summary(reports, compute, "in/data.unity3d", "out", "loose", 1.0, "t", _TC(),
                                 {"loose_dir": "Data"}, 3, translate.Options())


def test_summary_schema_and_exit_codes():
    ok = inject.ShaderReport("A", programs=2, ok=2)
    geom = inject.ShaderReport("B", programs=1, ok=0, unsupported={"stage(s) geom": 1})
    novk = inject.ShaderReport("C", unsupported={convert.NO_VULKAN: 1})
    rec = {"shader": "S", "kernel": "k", "keywords": "", "status": "ok", "message": "", "notes": []}
    s = _summary([(ok, "f", 0), (geom, "f", 0), (novk, "f", 0)], [rec])
    assert s["schema"] == convert.SUMMARY_SCHEMA and s["exit_code"] == 0 and s["status"] == "ok"
    assert s["graphics"]["programs_unsupported_by_design"] == 1 and s["problems"] == []
    assert s["compute"]["kernel_variants"] == 1 and s["compute"]["fallback_stubs"] == 0
    json.dumps(s)
    bad = inject.ShaderReport("D", programs=1, ok=0, errors={"ToolError: boom": 1})
    s = _summary([(ok, "f", 0), (bad, "f", 0)], [dict(rec, status="failed", message="x")])
    assert s["exit_code"] == 3 and s["status"] == "completed_with_fallbacks"
    assert {p["kind"] for p in s["problems"]} == {"graphics", "compute"}
