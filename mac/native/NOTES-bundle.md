# Converter bundle: contract between `native/` (peakmetal) and the CI bundle team

Owner of this file: the peakmetal sub-lead (native/). The CI team owns `native/packaging/` and `native/ci/`;
peakmetal never writes there. Put questions and requests in "Open" at the end of this file.

Status: **implemented** (peakmetal 0.2.0, 12 Oct 2026). Mirrored in `README.md` → "Running on macOS", which
also documents the `convert_summary.json` schema for the G-C0 gate.

## Entry point

```
<python> -I <bundle>/native/pm.py <command> [args]
```

`pm.py` puts its own folder on `sys.path`, so `-I` (isolated mode) is fine and recommended. No `.pth`, no
`pip install` of peakmetal itself. Commands the Mac app / test kit use:

| Command | Purpose |
|---|---|
| `doctor [--data FILE] [--json FILE]` | Versions of python / UnityPy / lz4 / spirv-cross, tool discovery, and a self-test (built-in synthetic shader; with `--data`, a real translate + inject + golden diff on Unity's own shaders) |
| `convert <PEAK_Data/data.unity3d> --out DIR [--mode loose\|bundle\|both] [--jobs N]` | Whole game: graphics + compute shaders → Metal, loose files and/or archive, `DIR/convert_summary.json` |

## Layout expected inside the bundle

```
<bundle>/native/pm.py
<bundle>/native/peakmetal/...          (our MIT code, copied as is; no Landfall or Unity data)
<bundle>/native/bin/spirv-cross        (macOS arm64 build; found automatically when it sits here)
```

## Environment variables

| Variable | Read by | Meaning |
|---|---|---|
| `PEAKMETAL_SPIRV_CROSS` | peakmetal | Full path of the `spirv-cross` executable. Highest priority after the CLI's `--spirv-cross`. If set but not a file, peakmetal fails with exit code 2 (no silent fallback) |
| `PEAKMETAL_BIN` | peakmetal | Legacy: a folder holding `spirv-cross` (and optionally `smolv_decode`) |
| `PEAKMETAL_SMOLV_DECODE` | peakmetal | Optional native SMOL-V decoder. Default: the built-in pure-Python decoder (byte-identical); the bundle does **not** need it |
| `PEAKMETAL_METAL` | peakmetal | Apple's `metal` compiler, for `validate` only. Never needed on a friend's Mac; peakmetal never searches PATH for `metal` on macOS (the `/usr/bin/metal` shim would pop up an Xcode install dialog) |
| `PP_CONVERTER_PYTHON` | test kit / Mac app (not peakmetal) | The interpreter used to run `pm.py`; point it at the bundle's `python3` |

spirv-cross discovery order: `--spirv-cross` → `--bin-dir` → `$PEAKMETAL_SPIRV_CROSS` → `$PEAKMETAL_BIN` →
`<dir of pm.py>/bin/` → `PATH`. On Windows the names tried are `spirv-cross.exe` then `spirv-cross`; elsewhere
only `spirv-cross`. No hard-coded install paths.

## Python and packages

- Python: **minimum 3.10** (the floor of the pinned lz4 4.4.5 / Pillow 12.3.0 / fsspec 2026.9.0; peakmetal itself
  parses as 3.8, UnityPy 1.25.4 needs 3.9 for `functools.cache`). Tested on 3.13.14 on this PC; the bundle's
  **CPython 3.13.16 is fine**. `doctor` fails with exit 2 below 3.10. (The G-C0 gate's `>= 3.11` is stricter, harmless.)
- pip set: **agreed with `packaging/requirements.lock`** (seven packages, `--no-deps`), the versions this PC's
  tests ran with. `import UnityPy` imports lz4, brotli, fsspec, attrs, PIL and tpk_ar eagerly, so all seven are
  required; UnityPy's other declared deps (texture2ddecoder, etcpak, astc-encoder-py, fmod_toolkit, archspec)
  are only imported by `UnityPy.export`, which peakmetal never calls. `doctor` lists the third-party modules
  actually imported, so the bundle smoke can assert the set.

```
UnityPy==1.25.4  lz4==4.4.5  brotli==1.2.0  pillow==12.3.0  attrs==26.1.0  fsspec==2026.9.0  tpk_ar==0.2.4
```

## Stable Python API used by `packaging/smoke.py`

`peakmetal.tools.Toolchain()` (no arguments: env + `bin/` + PATH discovery), its `.spirv_cross` attribute and
`.cross(spv_bytes, args) -> str`. These stay; anything else may change. New: `peakmetal.tools.find_spirv_cross()`
returns `(path, how_found)` or raises `tools.ToolError`.

## spirv-cross

KhronosGroup/SPIRV-Cross tag **`vulkan-sdk-1.4.363.0`** (commit `f11ba9f0b21ba8fc15153d50a2a1ae31ab1cf8f7`, as in
`packaging/pins.env`; the build this PC's tests and the 16,174-program validation used). Only the CLI is needed (`spirv-cross` executable; `--msl`). No other version has been
validated; a different version can change the emitted MSL.

## Exit codes (`convert`, `doctor`)

| Code | Meaning |
|---|---|
| 0 | Success. `convert`: outputs written; every shader program translated or deliberately left out (geometry stage, stereo multiview, no Vulkan programs in the build); every compute kernel translated |
| 1 | Unexpected internal error (Python traceback on stderr) |
| 2 | Environment or usage error: input missing, refused output location, spirv-cross not found / not runnable, UnityPy or lz4 missing |
| 3 | `convert`: completed and outputs written, but some programs/kernels failed and got a fallback (see `convert_summary.json` → `problems`); `doctor`: a self-test check failed |

## Open

- (none)

## Answers to the bundle team (peakmetal sub-lead, 12 Oct 2026)

1. Layout: agreed. Both discovery paths are covered by `tests/test_portability.py` (env var, package `bin/`,
   `$PEAKMETAL_BIN`, PATH, set-but-missing env var = error).
2. `pm doctor` with no arguments: needs no data, network or Xcode; exits 0 when python >= 3.10, UnityPy + lz4
   import and spirv-cross runs. It never searches PATH for `metal` on macOS. Verified here with `python -I -B
   pm.py doctor` (also as a test, in a fresh interpreter). `--json FILE` writes `peakmetal.doctor/1` if you want
   to archive it.
3. Nothing is written inside the bundle: doctor's scratch is a `tempfile.TemporaryDirectory` under `TMPDIR`
   (removed on exit); `convert` writes only under `--out`. `pm --help` exits 0.
4. `peakmetal/` stays `.py`-only. New files in this change: `peakmetal/doctor.py`, `peakmetal/selftest.py`,
   `peakmetal/compute/metalfix.py` (the synthetic self-test SPIR-V is assembled in Python, no data files).
5. Ack: `peakmetal.__version__` is now **0.2.0**; bump `NT_VERSION` when you sync.

Files to sync into the bundle (the whole tree is `.py`): `native/pm.py` and every `native/peakmetal/**/*.py`
(28 files: `__init__ __main__ convert doctor golden inject repack selftest spirv tools translate validate`,
`common/{__init__ binio blob params program shader smolv}`, `compute/{__init__ codec convert features metalblob
metalfix spirv translate validate}`). Not `tests/`, not the READMEs.

## Requests from the bundle team

(Appended by the CI bundle team, 12 Oct 2026. Our files: `packaging/` and `ci/`; details in `packaging/README.md`.)

1. **Layout: agreed as written above.** The binary ships at `native/bin/spirv-cross`; `bin/pm` additionally sets
   `PEAKMETAL_SPIRV_CROSS` to it and runs `python/bin/python3 -I -B native/pm.py "$@"`. `check/smoke.py` asserts
   `Toolchain()` finds it both with the variable and without it (package `bin/` discovery).
2. **`doctor` with no arguments must exit 0 on the CI runner** (macos-15 arm64): no game data, no network, no
   Xcode `metal`, under `env -i HOME=<tmp> TMPDIR=<tmp> PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=en_US.UTF-8`.
   The build fails otherwise. `--data` is never passed in CI.
3. **Nothing may be written inside the bundle** while running (scratch only under `TMPDIR`; no `.pyc`, logs or
   caches next to the code). `verify_bundle.sh` re-checks every file against `FILES.sha256` after running
   `smoke.py`, `pm --help` and `pm doctor`. The interpreter runs with `-I -B`; `.pyc` are precompiled
   (hash-checked). Also: `pm --help` must exit 0.
4. **`peakmetal/` must stay `.py`-only** (plus `pm.py`): the build refuses any other file in the copied tree, as a
   guard against data ever shipping. If you need a non-Python resource file, tell us here and we will allow
   that exact name.
5. Any converter change that should reach a Mac means a new bundle: we bump `NT_VERSION` in `packaging/pins.env`
   (MANIFEST.json records the SHA-256 of every converter file, so a bundle always says which code it has).
