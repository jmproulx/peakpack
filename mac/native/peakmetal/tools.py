"""External tool discovery and wrappers (SPIRV-Cross; optional native SMOL-V decoder; optional Apple metal).

Platform-neutral: the same rules on Windows, macOS and Linux; no install paths are hard-coded except the
optional Windows-only Metal Developer Tools location used by `validate`.

spirv-cross (required), first hit wins:
    1. explicit path (CLI --spirv-cross)
    2. --bin-dir DIR                         DIR/spirv-cross[.exe]
    3. $PEAKMETAL_SPIRV_CROSS                full path; if set but not a file -> ToolError (no silent fallback)
    4. $PEAKMETAL_BIN                        DIR/spirv-cross[.exe] (legacy)
    5. <folder of pm.py>/bin/                i.e. a `bin` folder next to the `peakmetal` package (CI bundle)
    6. PATH
  Names tried: "spirv-cross.exe", "spirv-cross" on Windows; "spirv-cross" elsewhere.

SMOL-V: the built-in pure-Python decoder (common/smolv.py, byte-identical to aras-p/smol-v on all 7,335
distinct PEAK/golden streams) is the default. A native `smolv_decode` is used only when named explicitly
($PEAKMETAL_SMOLV_DECODE or Toolchain(smolv_decode=...)).

Apple's metal compiler (optional, `validate` only): explicit path, $PEAKMETAL_METAL, then on Windows only the
Metal Developer Tools default install and PATH. On macOS PATH is NOT searched: /usr/bin/metal is an xcrun shim
that opens an "install the command line developer tools" dialog when Xcode is absent. Friends' Macs never
need it.
"""
import os
import shutil
import subprocess
import tempfile

ENV_SPIRV_CROSS = "PEAKMETAL_SPIRV_CROSS"
ENV_BIN = "PEAKMETAL_BIN"
ENV_SMOLV = "PEAKMETAL_SMOLV_DECODE"
ENV_METAL = "PEAKMETAL_METAL"

_HERE = os.path.dirname(os.path.abspath(__file__))
PACKAGE_BIN = os.path.join(os.path.dirname(_HERE), "bin")      # <native>/bin, next to peakmetal/
DEFAULT_METAL_WIN = r"C:\Program Files\Metal Developer Tools\bin\metal.exe"
IS_WINDOWS = os.name == "nt"


class ToolError(RuntimeError):
    pass


def exe_names(name):
    return [name + ".exe", name] if IS_WINDOWS else [name]


def _in_dir(d, name):
    for n in exe_names(name):
        p = os.path.join(d, n)
        if os.path.isfile(p):
            return p
    return None


def find_tool(name, env, explicit=None, bin_dir=None, search_package_bin=True, search_path=True):
    """Return (path, how_found) or (None, reason). `env` names the variable holding a full path."""
    if explicit:
        if not os.path.isfile(explicit):
            raise ToolError(f"{name}: {explicit} (given explicitly) is not a file")
        return explicit, "explicit"
    if bin_dir:
        p = _in_dir(bin_dir, name)
        if p:
            return p, "--bin-dir"
    v = os.environ.get(env)
    if v:
        if not os.path.isfile(v):
            raise ToolError(f"{name}: ${env}={v} is not a file")
        return v, f"${env}"
    d = os.environ.get(ENV_BIN)
    if d:
        p = _in_dir(d, name)
        if p:
            return p, f"${ENV_BIN}"
    if search_package_bin:
        p = _in_dir(PACKAGE_BIN, name)
        if p:
            return p, "package bin/"
    if search_path:
        for n in exe_names(name):
            p = shutil.which(n)
            if p:
                return p, "PATH"
    return None, "not found"


def find_spirv_cross(explicit=None, bin_dir=None):
    """(path, how_found); raises ToolError when spirv-cross cannot be found."""
    p, how = find_tool("spirv-cross", ENV_SPIRV_CROSS, explicit, bin_dir)
    if not p:
        raise ToolError(f"spirv-cross not found: set ${ENV_SPIRV_CROSS} to the executable, put it in "
                        f"{PACKAGE_BIN} or on PATH (or pass --spirv-cross / --bin-dir)")
    return p, how


def spirv_cross_revision(path):
    """SPIRV-Cross has no --version; `--revision` prints the git revision when built with CMake."""
    try:
        r = subprocess.run([path, "--revision"], capture_output=True, text=True, timeout=30)
        return (r.stdout or r.stderr).strip().splitlines()[0] if (r.stdout or r.stderr).strip() else ""
    except (OSError, subprocess.SubprocessError) as ex:
        raise ToolError(f"spirv-cross at {path} does not run: {ex}") from ex


class Toolchain:
    def __init__(self, bin_dir=None, scratch=None, use_python_smolv=None, spirv_cross=None, smolv_decode=None):
        """Defaults need no arguments (environment, package bin/ and PATH discovery).
        use_python_smolv: None = pure-Python decoder unless a native one is named explicitly (argument or
        $PEAKMETAL_SMOLV_DECODE); True/False forces the choice."""
        self.spirv_cross, self.spirv_cross_found_by = find_spirv_cross(spirv_cross, bin_dir)
        native = smolv_decode or os.environ.get(ENV_SMOLV) or None
        if use_python_smolv is False and not native:
            native, _ = find_tool("smolv_decode", ENV_SMOLV, None, bin_dir)
        if native and not os.path.isfile(native):
            raise ToolError(f"smolv_decode {native} is not a file")
        self.smolv_exe = native
        self.scratch = scratch or tempfile.mkdtemp(prefix="peakmetal_")
        os.makedirs(self.scratch, exist_ok=True)
        self._py_smolv = None
        if use_python_smolv is None:
            use_python_smolv = not native
        if use_python_smolv:
            from .common import smolv as _sm
            self._py_smolv = _sm
        elif not native:
            raise ToolError("native smolv_decode requested but not found")

    @property
    def smolv_backend(self):
        return "python (peakmetal.common.smolv)" if self._py_smolv is not None else f"native {self.smolv_exe}"

    def smolv_decode(self, data: bytes, tag="s") -> bytes:
        if self._py_smolv is not None:
            return self._py_smolv.decode(data)
        fd, src = tempfile.mkstemp(suffix=".smolv", dir=self.scratch)
        os.close(fd)
        dst = src[:-6] + ".spv"
        try:
            with open(src, "wb") as f:
                f.write(data)
            r = subprocess.run([self.smolv_exe, src, dst], capture_output=True, text=True)
            if r.returncode:
                raise ToolError("smolv_decode: " + (r.stderr or r.stdout).strip())
            with open(dst, "rb") as f:
                return f.read()
        finally:
            for p in (src, dst):
                try:
                    os.remove(p)
                except OSError:
                    pass

    def cross(self, spv: bytes, args) -> str:
        fd, src = tempfile.mkstemp(suffix=".spv", dir=self.scratch)
        os.close(fd)
        dst = src[:-4] + ".metal"
        try:
            with open(src, "wb") as f:
                f.write(spv)
            r = subprocess.run([self.spirv_cross, src, *args, "--output", dst], capture_output=True, text=True)
            if r.returncode or not os.path.exists(dst):
                raise ToolError("spirv-cross: " + (r.stderr or r.stdout).strip()[-800:])
            with open(dst, encoding="utf-8") as f:
                return f.read()
        finally:
            for p in (src, dst):
                try:
                    os.remove(p)
                except OSError:
                    pass


def find_metal(explicit=None):
    """Apple's metal compiler or None (validation is optional; see the module docstring)."""
    for p in (explicit, os.environ.get(ENV_METAL)):
        if p and os.path.isfile(p):
            return p
    if IS_WINDOWS:
        if os.path.isfile(DEFAULT_METAL_WIN):
            return DEFAULT_METAL_WIN
        return shutil.which("metal.exe")
    return None
