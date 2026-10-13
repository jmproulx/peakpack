"""Self-containment smoke test for the PeakPack native-tools bundle (MIT).

Run with the BUNDLED interpreter, isolated:  <root>/python/bin/python3 -I -B smoke.py <root>
(check/verify_bundle.sh does this). Needs no network, no PEAK/Unity data, nothing installed.

Checks: interpreter version and prefix are the bundle's; sys.path and every imported module stay
inside the bundle; the installed distributions are exactly MANIFEST.json's; UnityPy/lz4 work; the
bundled spirv-cross (native/bin/spirv-cross) turns a tiny hand-built SPIR-V module into MSL through
peakmetal's own Toolchain, found both via PEAKMETAL_SPIRV_CROSS and by peakmetal's own discovery.
Uses only the API that native/NOTES-bundle.md declares stable (tools.Toolchain, .spirv_cross, .cross).
"""
import json
import os
import platform
import struct
import sys


def fail(msg):
    print("smoke: FAIL: " + msg, file=sys.stderr)
    sys.exit(1)


def inside(path, root):
    path = os.path.realpath(path)
    return path == root or path.startswith(root + os.sep)


def tiny_spirv():
    """Minimal valid SPIR-V 1.0 compute module: void main() {} with LocalSize 1 1 1."""
    def op(code, *operands):
        return [((1 + len(operands)) << 16) | code, *operands]

    main = struct.unpack("<I", b"main")[0]
    words = [0x07230203, 0x00010000, 0, 5, 0]           # magic, version 1.0, generator, bound, schema
    words += op(17, 1)                                   # OpCapability Shader
    words += op(14, 0, 1)                                # OpMemoryModel Logical GLSL450
    words += op(15, 5, 1, main, 0)                       # OpEntryPoint GLCompute %1 "main"
    words += op(16, 1, 17, 1, 1, 1)                      # OpExecutionMode %1 LocalSize 1 1 1
    words += op(19, 2)                                   # %2 = OpTypeVoid
    words += op(33, 3, 2)                                # %3 = OpTypeFunction %2
    words += op(54, 2, 1, 0, 3)                          # %1 = OpFunction %2 None %3
    words += op(248, 4)                                  # %4 = OpLabel
    words += op(253)                                     # OpReturn
    words += op(56)                                      # OpFunctionEnd
    return struct.pack("<%dI" % len(words), *words)


def main():
    if len(sys.argv) != 2:
        fail("usage: smoke.py <bundle root>")
    root = os.path.realpath(sys.argv[1])
    with open(os.path.join(root, "MANIFEST.json"), encoding="utf-8") as f:
        manifest = json.load(f)
    report = {}

    # 1. Interpreter: the bundle's own, isolated.
    want_py = manifest["python"]["version"]
    if platform.python_version() != want_py:
        fail("python %s, manifest says %s" % (platform.python_version(), want_py))
    if not sys.flags.isolated:
        fail("not running under python -I")
    for name, value in (("sys.prefix", sys.prefix), ("sys.base_prefix", sys.base_prefix),
                        ("sys.executable", sys.executable)):
        if not inside(value, root):
            fail("%s outside the bundle: %s" % (name, value))
    outside = [p for p in sys.path if p and not inside(p, root)]
    if outside:
        fail("sys.path entries outside the bundle: %r" % outside)
    if platform.machine() != "arm64":
        fail("machine %s, expected arm64" % platform.machine())
    report["python"] = platform.python_version()

    # 2. Installed distributions are exactly the locked set (pip/setuptools removed after install).
    from importlib import metadata

    def norm(n):
        return n.lower().replace("_", "-").replace(".", "-")

    have = {norm(d.metadata["Name"]): d.version for d in metadata.distributions()}
    want = {norm(p["name"]): p["version"] for p in manifest["python_packages"]}
    if have != want:
        fail("installed distributions %r != manifest %r" % (sorted(have.items()), sorted(want.items())))
    report["packages"] = have

    # 3. The libraries the converter imports, from inside the bundle, working.
    import lz4.block
    import UnityPy
    import UnityPy.files  # noqa: F401
    import UnityPy.streams  # noqa: F401
    from UnityPy.helpers import TypeTreeHelper  # noqa: F401
    import brotli  # noqa: F401
    import fsspec  # noqa: F401
    import attrs  # noqa: F401
    import tpk_ar  # noqa: F401

    if UnityPy.__version__ != want.get("unitypy"):
        fail("UnityPy %s != locked %s" % (UnityPy.__version__, want.get("unitypy")))
    blob = bytes(range(256)) * 64
    if lz4.block.decompress(lz4.block.compress(blob, mode="high_compression", compression=9)) != blob:
        fail("lz4 round trip")
    UnityPy.load()  # empty environment: exercises the import graph without any game data

    # 4. peakmetal's Toolchain drives the bundled spirv-cross (same call path as `convert`).
    sys.path.insert(0, os.path.join(root, "native"))
    from peakmetal import tools

    bundled = os.path.realpath(os.path.join(root, "native", "bin", "spirv-cross"))
    tc = tools.Toolchain()  # PEAKMETAL_SPIRV_CROSS as set by bin/pm (and by verify_bundle.sh)
    if os.path.realpath(tc.spirv_cross) != bundled:
        fail("Toolchain picked %s, expected the bundled %s" % (tc.spirv_cross, bundled))
    msl = tc.cross(tiny_spirv(), ["--msl", "--msl-version", "20100"])
    if "kernel void main0" not in msl:
        fail("unexpected spirv-cross output:\n" + msl[:400])
    report["spirv_cross"] = tc.spirv_cross

    # Without any variable (python3 -I native/pm.py run directly, NOTES-bundle.md): native/bin/ next to pm.py.
    env_value = os.environ.pop("PEAKMETAL_SPIRV_CROSS", None)
    try:
        found = tools.Toolchain().spirv_cross
    except Exception as exc:  # noqa: BLE001 - report any discovery failure
        fail("spirv-cross not found without PEAKMETAL_SPIRV_CROSS: %s" % exc)
    finally:
        if env_value is not None:
            os.environ["PEAKMETAL_SPIRV_CROSS"] = env_value
    if os.path.realpath(found) != bundled:
        fail("without PEAKMETAL_SPIRV_CROSS, Toolchain picked %s, expected %s" % (found, bundled))

    stray = sorted({getattr(m, "__file__", None) for m in list(sys.modules.values())} - {None})
    stray = [p for p in stray if not inside(p, root)]
    if stray:
        fail("modules loaded from outside the bundle: %r" % stray)

    print("smoke: OK " + json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
