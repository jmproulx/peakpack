"""PEAK Native.app: Unity's Mac player running PEAK's own Windows data (build-app, verify-app, remove-app).

The recipe is testkit/gates/G-C0.sh assemble(), productised; recipe_version in the manifest is 1.
  build-app   assemble <out>.app from Unity's Mac player (pkg or a Variations folder), PEAK's data (stock, or the
              loose files of a `pm convert` output), Unity's Mac Mono assemblies, and optional Valve libsteam_api
  verify-app  re-hash the files we wrote, check the game files' sizes, report extra files, codesign on macOS
  remove-app  delete a PeakPack native app (and its work cache, and optionally Unity's per-user data)

Never modified: the game folder (only read), anything under Unity's install (only read), the pkg (expanded into
the work cache, never installed). Files cloned from the game are recorded by size only; every other file in the
app (Unity, Steam, converted, our own) is recorded by SHA-256 in Contents/Resources/peakpack-native.json.
"""
import base64
import datetime
import glob
import hashlib
import json
import os
import plistlib
import posixpath
import shutil
import stat
import subprocess
import sys
import zipfile

from . import __version__

# ---- constants (one place) -------------------------------------------------------------------------------------
UNITY_VERSION = "6000.3.15f1"
UNITY_REVISION = "c1aa84e375f6"
UNITY_PKG_NAME = f"UnitySetup-Mac-Mono-Support-for-Editor-{UNITY_VERSION}.pkg"
UNITY_PKG_URL = (f"https://download.unity3d.com/download_unity/{UNITY_REVISION}/MacEditorTargetInstaller/"
                 f"{UNITY_PKG_NAME}")
UNITY_PKG_BYTES = 724929213
UNITY_PKG_MD5_B64 = "gI5nOkoLtZhU0O48yRsAQQ=="   # Unity's release API: "md5-gI5nOkoLtZhU0O48yRsAQQ=="
UNITY_PKG_SIGNER = "Unity Technologies"
STEAM_ZIP_NAME = "Steamworks.NET-Standalone_2024.8.0.zip"   # the version PEAK ships (SDK 1.61)
STEAM_ZIP_SHA256 = "08094d1372c6d793d6b5b87c59f1362a10fe8580acb1db6bfaf081a511f6758c"
STEAM_ZIP_PREFIX = "OSX-Linux-x64/steam_api.bundle/"
STEAM_APP_ID = "3527290"
BUNDLE_ID = "com.peakpack.native"
BUNDLE_NAME = "PEAK Native"
MIN_MACOS = "11.0"
DEFAULT_VARIATION = "macos_arm64_player_nondevelopment_mono"
DEFAULT_OUT = os.path.join("~", "Applications", "PEAK Native.app")
MANIFEST_REL = "Contents/Resources/peakpack-native.json"
MANIFEST_SCHEMA = "peakpack.native_app/1"
RESULT_SCHEMA = "peakpack.native_build/1"
WORK_MARKER = "peakpack-native-work.json"
WORK_SCHEMA = "peakpack.native_work/1"
RECIPE_VERSION = 1
UDR_NAME = "unity default resources"
CODESIGN_DIR_REL = "Contents/_CodeSignature/"
EXIT_OK, EXIT_ERROR, EXIT_ENV, EXIT_PROBLEMS = 0, 1, 2, 3


class AppError(Exception):
    """code 2: environment or usage problem; code 1: a build step failed."""

    def __init__(self, msg, code=EXIT_ENV):
        super().__init__(msg)
        self.code = code


def is_macos():
    return sys.platform == "darwin"


def user_data_paths():
    """Unity's per-user folders for this bundle id and PEAK's company/product (--purge-user-data only)."""
    h = os.path.expanduser("~")
    lib = os.path.join(h, "Library")
    return [
        os.path.join(lib, "Preferences", "unity.LandCrab.PEAK.plist"),
        os.path.join(lib, "Application Support", "unity.LandCrab.PEAK"),
        os.path.join(lib, "Saved Application State", f"{BUNDLE_ID}.savedState"),
        os.path.join(lib, "Caches", BUNDLE_ID),
    ]


def default_work(out):
    if is_macos():
        return os.path.join(os.path.expanduser("~"), "Library", "Caches", "PeakPack", "native")
    return os.path.join(os.path.dirname(os.path.abspath(out)), ".peakpack-native-work")


# ---- small helpers ---------------------------------------------------------------------------------------------
def _abspath(p):
    return os.path.abspath(os.path.expanduser(p))


def _is_within(path, parent):
    a = os.path.normcase(os.path.abspath(path))
    b = os.path.normcase(os.path.abspath(parent))
    try:
        return os.path.commonpath([a, b]) == b
    except ValueError:
        return False


def _rel_to(path, base):
    return os.path.relpath(path, base).replace(os.sep, "/")


def _join_rel(rel, sub):
    if not rel:
        return sub
    if not sub:
        return rel
    return rel + "/" + sub


def _abs_rel(root, rel):
    return os.path.join(root, *rel.split("/")) if rel else root


def _sha256_file(path, chunk=1 << 20):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(chunk), b""):
            h.update(block)
    return h.hexdigest()


def _sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def _canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def fingerprint(inputs):
    return _sha256_bytes(_canonical({"inputs": inputs, "recipe_version": RECIPE_VERSION}).encode("utf-8"))


def _utc_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _retry_rw(func, path, *_):
    try:
        os.chmod(path, stat.S_IRWXU)
    except OSError:
        pass
    func(path)


def _rmtree(path):
    if os.path.islink(path) or os.path.isfile(path):
        os.remove(path)
    elif os.path.isdir(path):
        if sys.version_info >= (3, 12):
            shutil.rmtree(path, onexc=_retry_rw)
        else:
            shutil.rmtree(path, onerror=_retry_rw)


def _rmtree_if(path):
    if os.path.lexists(path):
        _rmtree(path)


def _clone(src, dst):
    """APFS clone (cp -c) on macOS, otherwise a plain copy. Symlinks stay symlinks."""
    if is_macos():
        r = subprocess.run(["cp", "-c", "-R", src, dst], capture_output=True)
        if r.returncode == 0 and os.path.lexists(dst):
            return
        _rmtree_if(dst)
    if os.path.islink(src):
        os.symlink(os.readlink(src), dst)
    elif os.path.isdir(src):
        shutil.copytree(src, dst, symlinks=True)
    else:
        shutil.copy2(src, dst)


def _run(cmd, what, check=True):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if check and r.returncode != 0:
        tail = ((r.stderr or "") + (r.stdout or "")).strip()[-400:]
        raise AppError(f"{what} failed (exit {r.returncode}): {tail}", EXIT_ERROR)
    return r


def _write_json(path, obj):
    if not path:
        return
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, indent=1, sort_keys=True)
        f.write("\n")


def _entries(src):
    """(sub, abs path, is_symlink, size) for a file, a symlink or every file below a folder ('' = src itself)."""
    if os.path.islink(src):
        return [("", src, True, 0)]
    if os.path.isfile(src):
        return [("", src, False, os.path.getsize(src))]
    out = []
    for dp, dns, fns in os.walk(src):
        for n in dns:
            p = os.path.join(dp, n)
            if os.path.islink(p):
                out.append((_rel_to(p, src), p, True, 0))
        for n in fns:
            p = os.path.join(dp, n)
            if os.path.islink(p):
                out.append((_rel_to(p, src), p, True, 0))
            else:
                out.append((_rel_to(p, src), p, False, os.path.getsize(p)))
    return out


# ---- the converted/game/Unity inputs ---------------------------------------------------------------------------
def _check_game(game):
    if not os.path.isdir(game):
        raise AppError(f"--game is not a folder: {game}")
    data = os.path.join(game, "PEAK_Data")
    if not os.path.isfile(os.path.join(data, "data.unity3d")):
        raise AppError(f"{data} has no data.unity3d: --game must be PEAK's Windows install folder")
    if not os.path.isdir(os.path.join(data, "Managed")):
        raise AppError(f"{data} has no Managed/ folder: --game must be PEAK's Windows install folder")


def _game_version(game):
    p = os.path.join(game, "version.txt")
    if not os.path.isfile(p):
        return None
    with open(p, encoding="utf-8", errors="replace") as f:
        line = f.readline()
    return line.replace("\r", "").replace(" ", "").strip() or None


def _check_converted(conv):
    if not os.path.isdir(os.path.join(conv, "Data")):
        raise AppError(f"--converted has no Data/ folder (expected a `pm convert` output): {conv}")
    summ_path = os.path.join(conv, "convert_summary.json")
    info = {"dir": conv, "summary_sha256": None, "warnings": []}
    if os.path.isfile(summ_path):
        info["summary_sha256"] = _sha256_file(summ_path)
        try:
            with open(summ_path, encoding="utf-8") as f:
                status = json.load(f).get("status")
        except (OSError, ValueError):
            status = None
        if status not in (None, "ok"):
            info["warnings"].append(f"convert_summary.json status is {status!r}: some shaders fell back")
    return info


def _check_steam_zip(path):
    if not os.path.isfile(path):
        raise AppError(f"--steam-zip not found: {path}")
    sha = _sha256_file(path)
    if sha != STEAM_ZIP_SHA256:
        raise AppError(f"{os.path.basename(path)} SHA-256 is {sha}; expected {STEAM_ZIP_SHA256} "
                       f"(Steamworks.NET 2024.8.0). Not the file the recipe pins.")
    try:
        with zipfile.ZipFile(path) as z:
            infos = [i for i in z.infolist()
                     if i.filename.startswith(STEAM_ZIP_PREFIX) and not i.is_dir() and not i.filename.endswith(".meta")]
            dylib = [i for i in infos if i.filename == STEAM_ZIP_PREFIX + "Contents/MacOS/libsteam_api.dylib"]
    except zipfile.BadZipFile as ex:
        raise AppError(f"--steam-zip is not a zip file: {ex}")
    if not infos or not dylib:
        raise AppError(f"{os.path.basename(path)} has no {STEAM_ZIP_PREFIX}Contents/MacOS/libsteam_api.dylib")
    return {"path": path, "sha256": sha, "files": len(infos), "bytes": sum(i.file_size for i in infos),
            "dylib_size": dylib[0].file_size, "bundle": None}


def _extract_steam(zip_path, work):
    """Extract only the macOS steam_api.bundle (no *.meta) into work/steam. Returns the bundle folder."""
    d = os.path.join(work, "steam")
    _rmtree_if(d)
    os.makedirs(d)
    with zipfile.ZipFile(zip_path) as z:
        for info in z.infolist():
            name = info.filename
            if not name.startswith(STEAM_ZIP_PREFIX) or info.is_dir() or name.endswith(".meta"):
                continue
            target = os.path.normpath(os.path.join(d, *name.split("/")))
            if not target.startswith(d + os.sep):
                raise AppError(f"unsafe path in the Steamworks zip: {name}", EXIT_ERROR)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with z.open(info) as src, open(target, "wb") as dst:
                shutil.copyfileobj(src, dst)
            mode = (info.external_attr >> 16) & 0o777
            if mode:
                os.chmod(target, mode)
    return os.path.join(d, *STEAM_ZIP_PREFIX.rstrip("/").split("/"))


def verify_pkg(path):
    """Unity's pkg: size, MD5 (Unity's release API), and Unity's signature (macOS only). Returns SHA-256."""
    size = os.path.getsize(path)
    if size != UNITY_PKG_BYTES:
        raise AppError(f"{path} is {size} bytes; {UNITY_PKG_NAME} is {UNITY_PKG_BYTES} bytes. Not the file "
                       f"Unity published. Download it again from {UNITY_PKG_URL}")
    md5 = hashlib.md5(usedforsecurity=False)
    sha = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            md5.update(block)
            sha.update(block)
    want = base64.b64decode(UNITY_PKG_MD5_B64)
    if md5.digest() != want:
        raise AppError(f"{path} MD5 is {md5.hexdigest()}; expected {want.hex()} (Unity's {UNITY_PKG_NAME})")
    r = subprocess.run(["pkgutil", "--check-signature", path], capture_output=True, text=True)
    if r.returncode != 0 or UNITY_PKG_SIGNER not in (r.stdout + r.stderr):
        raise AppError(f"{path} is not signed by {UNITY_PKG_SIGNER} (pkgutil --check-signature)")
    return sha.hexdigest()


def find_variations(root):
    """The folder that holds Variations/: root itself, root/Variations, or a Variations under MacStandaloneSupport."""
    if not os.path.isdir(root):
        return None
    direct = os.path.join(root, "Variations")
    if os.path.isdir(direct):
        return direct
    # Any Variations folder that holds a macOS Mono player: the editor layout has it under MacStandaloneSupport,
    # the expanded 6000.3 pkg under TargetSupport.pkg.tmp/Payload/Variations (seen on the iMac, slot 4).
    for dp, dns, _fns in os.walk(root):
        if os.path.basename(dp) == "Variations" and any(
                d.startswith("macos_") and d.endswith("_mono")
                and os.path.isfile(os.path.join(dp, d, "UnityPlayer.app", "Contents", "Info.plist")) for d in dns):
            return dp
    return None


def _player_binary_sha(player):
    for rel in ("Contents/Frameworks/UnityPlayer.dylib", "Contents/MacOS/UnityPlayer"):
        p = os.path.join(player, *rel.split("/"))
        if os.path.isfile(p):
            return _sha256_file(p)
    return None


def _expand_pkg(pkg, expanded):
    """pkgutil --expand-full into a partial folder, then rename. Never installs."""
    _rmtree_if(expanded)
    partial = f"{expanded}.partial-{os.getpid()}"
    _rmtree_if(partial)
    os.makedirs(os.path.dirname(expanded), exist_ok=True)
    r = subprocess.run(["pkgutil", "--expand-full", pkg, partial], capture_output=True, text=True)
    if r.returncode != 0:
        _rmtree_if(partial)
        raise AppError(f"pkgutil --expand-full failed: {(r.stderr or r.stdout).strip()[-300:]}", EXIT_ERROR)
    os.rename(partial, expanded)
    with open(os.path.join(expanded, ".peakpack-expanded-ok"), "w", encoding="utf-8") as f:
        f.write(_utc_now() + "\n")
    return expanded


def _resolve_unity(src, work, dry, variation):
    info = {"kind": None, "path": src, "pkg_sha256": None, "variations": None, "mss": None,
            "player": None, "variation": variation, "binary_sha256": None, "expanded": None,
            "overlay_dlls": []}
    if src.lower().endswith(".pkg"):
        if not is_macos():
            raise AppError("a .pkg needs macOS (pkgutil). On this PC pass the folder that holds Variations/ "
                           "(the Windows editor's MacStandaloneSupport folder)")
        if not os.path.isfile(src):
            raise AppError(f"--unity-player not found: {src}")
        info["kind"] = "pkg"
        info["pkg_sha256"] = verify_pkg(src)
        expanded = os.path.join(work, f"unity-{UNITY_VERSION}", "expanded")
        info["expanded"] = expanded
        # reuse an expansion only when it is marked complete (written after pkgutil exited 0)
        marked = os.path.isfile(os.path.join(expanded, ".peakpack-expanded-ok"))
        root = find_variations(expanded) if os.path.isdir(expanded) and marked else None
        if root is None and not dry:
            root = find_variations(_expand_pkg(src, expanded))
            if root is None:
                raise AppError("the expanded Unity pkg has no Variations folder with a macOS Mono player", EXIT_ERROR)
    elif os.path.isdir(src):
        info["kind"] = "dir"
        root = find_variations(src)
        if root is None:
            raise AppError(f"no Variations/ folder under {src} (expect the MacStandaloneSupport folder "
                           "or an expanded Unity pkg)")
    else:
        raise AppError(f"--unity-player is neither a .pkg nor a folder: {src}")
    if root is not None:
        info["variations"] = root
        info["mss"] = os.path.dirname(root)
        player = os.path.join(root, variation, "UnityPlayer.app")
        if not os.path.isdir(player):
            avail = sorted(v for v in os.listdir(root) if os.path.isdir(os.path.join(root, v, "UnityPlayer.app")))
            raise AppError(f"variation {variation!r} not in {root}; available: {', '.join(avail) or 'none'}")
        info["player"] = player
        overlay_dir = os.path.join(root, "mono", "Managed")
        if not os.path.isdir(overlay_dir):
            raise AppError(f"{overlay_dir} is missing: the Mac Mono assemblies are required")
        info["overlay_dlls"] = sorted(n for n in os.listdir(overlay_dir)
                                      if n.lower().endswith(".dll") and os.path.isfile(os.path.join(overlay_dir, n)))
        info["binary_sha256"] = _player_binary_sha(player)
    return info


# ---- assembly --------------------------------------------------------------------------------------------------
class _Assembler:
    """Every write goes through here so that dry runs count exactly what a real build copies.
    origin[rel] = "game" (cloned from PEAK: manifest records the size) or "hash" (manifest records SHA-256)."""

    def __init__(self, root, dry, base):
        self.root = root
        self.dry = dry
        self.base = base            # where existing files are looked up when dry (the real root otherwise)
        self.origin = {}
        self.placed = set()
        self.cats = {}              # category -> [files, bytes, kind]

    def _abs(self, rel):
        return _abs_rel(self.root, rel)

    def stat(self, cat, kind, files, nbytes):
        c = self.cats.setdefault(cat, [0, 0, kind])
        c[0] += files
        c[1] += nbytes

    def exists(self, rel):
        if rel in self.placed:
            return True
        return os.path.lexists(_abs_rel(self.root if not self.dry else self.base, rel))

    def _forget(self, rel):
        pre = rel + "/"
        for k in [k for k in self.origin if k == rel or k.startswith(pre)]:
            del self.origin[k]

    def mkdir(self, rel):
        self.placed.add(rel)
        if not self.dry:
            os.makedirs(self._abs(rel), exist_ok=True)

    def remove(self, rel):
        if not self.dry:
            _rmtree_if(self._abs(rel))
        self._forget(rel)

    def tree(self, src, rel, cat, kind):
        ents = _entries(src)
        self.stat(cat, kind, sum(1 for e in ents if not e[2]), sum(e[3] for e in ents))
        self.placed.add(rel)
        if self.dry:
            return
        dst = self._abs(rel)
        if rel:
            _rmtree_if(dst)
            self._forget(rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        _clone(src, dst)
        for sub, _p, islink, _n in ents:
            if not islink:
                self.origin[_join_rel(rel, sub)] = kind

    def write(self, rel, data, cat):
        self.stat(cat, "hash", 1, len(data))
        self.placed.add(rel)
        if self.dry:
            return
        p = self._abs(rel)
        _rmtree_if(p)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(data)
        self._forget(rel)
        self.origin[rel] = "hash"


def _resources(asm, src, rel, cat, kind):
    for child in sorted(os.listdir(src)):
        if child == UDR_NAME:
            continue
        asm.tree(os.path.join(src, child), f"{rel}/{child}", cat, kind)


def _assemble(asm, ctx):
    """G-C0 assemble(): ctx has game, player, mss, variations, overlay_dlls, converted (dir or None), steam, info."""
    game_data = os.path.join(ctx["game"], "PEAK_Data")
    data = "Contents/Resources/Data"
    asm.tree(ctx["player"], "", "player", "hash")
    asm.mkdir(f"{data}/Managed")
    asm.mkdir(f"{data}/Resources")
    if ctx["converted"] is None:
        for e in sorted(os.listdir(game_data)):
            if e in ("Managed", "Plugins"):
                continue
            src = os.path.join(game_data, e)
            if e == "Resources":
                _resources(asm, src, f"{data}/Resources", "game_data", "game")
                continue
            asm.tree(src, f"{data}/{e}", "game_data", "game")
    else:
        conv_data = os.path.join(ctx["converted"], "Data")
        for e in sorted(os.listdir(conv_data)):
            if e in ("Managed", "Plugins", "data.unity3d"):
                continue
            src = os.path.join(conv_data, e)
            if e == "Resources":
                _resources(asm, src, f"{data}/Resources", "converted", "hash")
                continue
            asm.tree(src, f"{data}/{e}", "converted", "hash")
        # the archive's companions (*.resource, StreamingAssets, json, boot.config) come from the game
        for e in sorted(os.listdir(game_data)):
            if e in ("Managed", "Plugins", "Resources", "data.unity3d"):
                continue
            if not asm.exists(f"{data}/{e}"):
                asm.tree(os.path.join(game_data, e), f"{data}/{e}", "game_data", "game")
        asm.remove(f"{data}/data.unity3d")
    # Managed: PEAK's assemblies, then Unity's Mac assemblies on top (the Mac ones win)
    game_managed = os.path.join(game_data, "Managed")
    overlay = ctx["overlay_dlls"]
    overlay_names = set(overlay)
    for e in sorted(os.listdir(game_managed)):
        if e in overlay_names:
            continue
        asm.tree(os.path.join(game_managed, e), f"{data}/Managed/{e}", "game_managed", "game")
    overlay_dir = os.path.join(ctx["variations"], "mono", "Managed")
    for n in overlay:
        asm.tree(os.path.join(overlay_dir, n), f"{data}/Managed/{n}", "mono_overlay", "hash")
    etc = os.path.join(ctx["mss"], "MonoBleedingEdge", "etc")
    if os.path.isdir(etc):
        asm.tree(etc, "Contents/MonoBleedingEdge/etc", "mono_etc", "hash")
    info = {
        "CFBundleExecutable": "UnityPlayer",
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleName": BUNDLE_NAME,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": ctx["game_version"] or "0",
        "CFBundleVersion": "1",
        "NSPrincipalClass": "PlayerApplication",
        "NSHighResolutionCapable": True,
        "LSMinimumSystemVersion": MIN_MACOS,
    }
    asm.write("Contents/Info.plist", plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=True), "generated")
    steam = ctx["steam"]
    if steam is not None:
        dylib = "Contents/MacOS/libsteam_api.dylib"
        if asm.dry:
            n, nb, d = steam["files"], steam["bytes"], steam["dylib_size"]
            asm.stat("steam", "hash", 2 * n + 2, 2 * nb + 2 * d)
            asm.placed.update({"Contents/PlugIns/steam_api64.bundle", "Contents/PlugIns/steam_api.bundle",
                               "Contents/PlugIns/libsteam_api64.dylib", "Contents/Frameworks/libsteam_api64.dylib"})
        else:
            sb = steam["bundle"]
            asm.tree(sb, "Contents/PlugIns/steam_api64.bundle", "steam", "hash")
            asm.tree(sb, "Contents/PlugIns/steam_api.bundle", "steam", "hash")
            asm.tree(os.path.join(sb, *dylib.split("/")), "Contents/PlugIns/libsteam_api64.dylib", "steam", "hash")
            asm.tree(os.path.join(sb, *dylib.split("/")), "Contents/Frameworks/libsteam_api64.dylib", "steam", "hash")
    asm.write("Contents/MacOS/steam_appid.txt", (STEAM_APP_ID + "\n").encode("ascii"), "generated")


def _codesign_frameworks(app):
    """Ad-hoc sign Unity's own dylibs. Valve's libsteam_api64.dylib keeps Valve's signature."""
    _run(["xattr", "-cr", app], "xattr -cr", check=False)
    for d in sorted(glob.glob(os.path.join(app, "Contents", "Frameworks", "*.dylib"))):
        if os.path.basename(d) == "libsteam_api64.dylib":
            continue
        _run(["codesign", "--force", "-s", "-", d], f"codesign {os.path.basename(d)}")


def _manifest(app, asm, ctx, fp, signed, warnings):
    files, games, links = {}, {}, {}
    for dp, dns, fns in os.walk(app):
        for n in dns:
            p = os.path.join(dp, n)
            if os.path.islink(p):
                links[_rel_to(p, app)] = os.readlink(p)
        for n in fns:
            p = os.path.join(dp, n)
            rel = _rel_to(p, app)
            if rel == MANIFEST_REL or rel.startswith(CODESIGN_DIR_REL):
                continue
            if os.path.islink(p):
                links[rel] = os.readlink(p)
            elif asm.origin.get(rel) == "game":
                games[rel] = os.path.getsize(p)
            else:
                files[rel] = _sha256_file(p)
    counts = {cat: c[0] for cat, c in sorted(asm.cats.items())}
    counts.update({
        "hashed_files": len(files),
        "game_size_only": len(games),
        "symlinks": len(links),
        "mac_managed_overlay": len(ctx["overlay_dlls"]),
        "mac_unityengine_assemblies": sum(1 for n in ctx["overlay_dlls"] if n.startswith("UnityEngine")),
    })
    return {
        "schema": MANIFEST_SCHEMA,
        "recipe_version": RECIPE_VERSION,
        "tool_version": __version__,
        "created": _utc_now(),
        "fingerprint": fp,
        "inputs": ctx["inputs"],
        "signed": signed,
        "counts": counts,
        "warnings": warnings,
        "files": files,
        "game_files": games,
        "symlinks": links,
    }


# ---- manifest / ownership --------------------------------------------------------------------------------------
def read_manifest(app):
    p = os.path.join(app, *MANIFEST_REL.split("/"))
    if not os.path.isfile(p):
        return None
    try:
        with open(p, encoding="utf-8") as f:
            m = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(m, dict) or m.get("schema") != MANIFEST_SCHEMA:
        return None
    return m


def _bundle_id(app):
    p = os.path.join(app, "Contents", "Info.plist")
    try:
        with open(p, "rb") as f:
            return plistlib.load(f).get("CFBundleIdentifier")
    except Exception:  # any unreadable or damaged plist means "not ours" (expat errors are not ValueErrors)
        return None


def _is_our_app(app):
    return os.path.isdir(app) and read_manifest(app) is not None and _bundle_id(app) == BUNDLE_ID


def _ensure_work(work):
    os.makedirs(work, exist_ok=True)
    marker = os.path.join(work, WORK_MARKER)
    if not os.path.isfile(marker):
        _write_json(marker, {"schema": WORK_SCHEMA, "created": _utc_now(), "tool_version": __version__})


def _swap(building, out):
    prev = out + ".previous"
    _rmtree_if(prev)
    had = os.path.lexists(out)
    if had:
        os.rename(out, prev)
    try:
        os.rename(building, out)
    except OSError:
        if had:
            os.rename(prev, out)
        raise
    if had:
        _rmtree_if(prev)


# ---- build-app -------------------------------------------------------------------------------------------------
def _counts_bytes(asm):
    hash_b = sum(c[1] for c in asm.cats.values() if c[2] == "hash")
    game_b = sum(c[1] for c in asm.cats.values() if c[2] == "game")
    return hash_b, game_b


def _build(a):
    game = _abspath(a.game)
    _check_game(game)
    out = _abspath(a.out or DEFAULT_OUT)
    if not out.lower().endswith(".app") or os.path.basename(out) == ".app":
        raise AppError("--out must be a .app bundle path, e.g. ~/Applications/PEAK Native.app")
    work = _abspath(a.work) if a.work else default_work(out)
    for label, p in (("--out", out), ("--work", work)):
        if _is_within(p, game):
            raise AppError(f"{label} is inside the game folder ({game}); the game folder is never written")
    dry = bool(a.dry_run)
    variation = a.variation or DEFAULT_VARIATION
    warnings = []
    game_version = _game_version(game)
    dat = os.stat(os.path.join(game, "PEAK_Data", "data.unity3d"))
    conv = _check_converted(_abspath(a.converted)) if a.converted else None
    if conv:
        warnings.extend(conv["warnings"])
    steam = _check_steam_zip(_abspath(a.steam_zip)) if a.steam_zip else None
    if steam is None:
        warnings.append("no --steam-zip: Steam will not initialise in the native player")
    unity = _resolve_unity(_abspath(a.unity_player), work, dry, variation)
    if not dry:
        _ensure_work(work)
    inputs = {
        "game_dir": game,
        "game_version": game_version,
        "data_unity3d": {"size": dat.st_size, "mtime_ns": dat.st_mtime_ns},
        "unity_player": {"kind": unity["kind"], "path": unity["path"], "sha256": unity["pkg_sha256"]},
        "variation": variation,
        "unity_player_binary_sha256": unity["binary_sha256"],
        "converted": ({"dir": conv["dir"], "summary_sha256": conv["summary_sha256"]} if conv else None),
        "steam_zip_sha256": steam["sha256"] if steam else None,
    }
    fp = fingerprint(inputs)

    existing = None
    if os.path.lexists(out):
        if not _is_our_app(out):
            raise AppError(f"{out} exists and is not a PeakPack native app: refusing to replace it "
                           "(move or remove it first)")
        existing = read_manifest(out)
    up_to_date = existing is not None and existing.get("fingerprint") == fp and not a.force
    result = {"schema": RESULT_SCHEMA, "game": game, "game_version": game_version, "out": out, "work": work,
              "variation": variation, "unity_player": {k: unity[k] for k in ("kind", "path", "pkg_sha256",
                                                                            "binary_sha256", "expanded")},
              "converted": conv["dir"] if conv else None, "steam_zip": steam["path"] if steam else None,
              "fingerprint": fp, "dry_run": dry, "warnings": warnings, "counts": {}, "bytes": {}}

    if up_to_date:
        result["status"] = "dry_run" if dry else "up_to_date"
        result["would"] = "up_to_date"
        if dry:
            print(f"dry run: {out} is up to date (fingerprint {fp[:12]}); a real run would write nothing")
        else:
            print(f"up to date: {out} (fingerprint {fp[:12]}); nothing changed")
        _write_json(a.json, result)
        return EXIT_OK

    ctx = {"game": game, "game_version": game_version, "player": unity["player"], "mss": unity["mss"],
           "variations": unity["variations"], "overlay_dlls": unity["overlay_dlls"], "converted": conv["dir"]
           if conv else None, "inputs": inputs, "steam": steam}
    if dry:
        if unity["player"] is None:
            result.update(status="dry_run", would="build", counts={},
                          note="the pkg is not expanded yet; the file plan is known after expansion")
            print(_plan_text(result, None))
            _write_json(a.json, result)
            return EXIT_OK
        asm = _Assembler(os.path.join(work, "dry-run.app"), dry=True, base=unity["player"])
        _assemble(asm, ctx)
        hash_b, game_b = _counts_bytes(asm)
        result.update(status="dry_run", would="rebuild" if existing else "build",
                      counts={cat: c[0] for cat, c in sorted(asm.cats.items())}, bytes={"copied": hash_b,
                                                                                         "game_cloned": game_b})
        result["counts"].update({"mac_unityengine_assemblies": sum(1 for n in ctx["overlay_dlls"]
                                                                   if n.startswith("UnityEngine")),
                                 "mac_managed_overlay": len(ctx["overlay_dlls"])})
        if existing:
            result["existing"] = "stale (fingerprint differs; will be replaced)"
        print(_plan_text(result, asm))
        _write_json(a.json, result)
        return EXIT_OK

    os.makedirs(os.path.dirname(out), exist_ok=True)
    building = f"{out}.building-{os.getpid()}"
    _rmtree_if(building)
    try:
        if steam is not None:
            steam["bundle"] = _extract_steam(steam["path"], work)
        asm = _Assembler(building, dry=False, base=building)
        _assemble(asm, ctx)
        signed = is_macos()
        if signed:
            _codesign_frameworks(building)
        m = _manifest(building, asm, ctx, fp, signed, warnings)
        _write_json(os.path.join(building, *MANIFEST_REL.split("/")), m)
        if signed:
            _run(["codesign", "--force", "-s", "-", building], "codesign app")
            _run(["codesign", "--verify", "--deep", "--strict", building], "codesign --verify")
    except BaseException:
        _rmtree_if(building)
        raise
    status = "rebuilt" if existing is not None else "built"
    try:
        _swap(building, out)
    except BaseException:
        _rmtree_if(building)
        raise
    hash_b, game_b = _counts_bytes(asm)
    result.update(status=status, counts=m["counts"], bytes={"copied": hash_b, "game_cloned": game_b},
                  signed=signed)
    print(f"{status}: {out}")
    print(f"  files hashed: {len(m['files'])}, game files (size only): {len(m['game_files'])}, "
          f"symlinks: {len(m['symlinks'])}, signed: {signed}")
    print(f"  Mac assemblies: {m['counts']['mac_managed_overlay']} overlaid ("
          f"{m['counts']['mac_unityengine_assemblies']} UnityEngine), copied {hash_b / 1e6:.1f} MB, "
          f"game data cloned {game_b / 1e6:.1f} MB")
    for w in warnings:
        print(f"  warning: {w}")
    _write_json(a.json, result)
    return EXIT_OK


def _plan_text(result, asm):
    lines = ["PEAK Native build plan (dry run: nothing written)",
             f"  game:         {result['game']} (version {result['game_version'] or 'unknown'})",
             f"  unity player: {result['variation']} from {result['unity_player']['path']}"]
    up = result["unity_player"]
    if up["kind"] == "pkg":
        lines.append(f"  unity pkg:    verified (size, MD5, signature); sha256 {up['pkg_sha256']}")
        if up["binary_sha256"] is None:
            lines.append(f"                not expanded yet: would expand to {up['expanded']}")
    lines.append(f"  data:         {'converted ' + result['converted'] if result['converted'] else 'stock (PEAK_Data)'}")
    lines.append(f"  steam:        {result['steam_zip'] or 'not given (Steam will not initialise)'}")
    lines.append(f"  destination:  {result['out']}")
    lines.append(f"  work cache:   {result['work']}")
    if asm is not None:
        for cat, c in sorted(asm.cats.items()):
            kind = "game (size only)" if c[2] == "game" else "hashed"
            lines.append(f"  {cat:16} {c[0]:6} files  {c[1] / 1e6:10.1f} MB  {kind}")
        lines.append(f"  Mac assemblies: {result['counts']['mac_managed_overlay']} overlaid, "
                     f"{result['counts']['mac_unityengine_assemblies']} UnityEngine.*")
        hash_b, game_b = _counts_bytes(asm)
        how = "APFS-cloned" if is_macos() else "copied (not macOS: no clones)"
        lines.append(f"  total: {hash_b / 1e6:.1f} MB copied, {game_b / 1e6:.1f} MB game data {how}")
    for w in result["warnings"]:
        lines.append(f"  warning: {w}")
    lines.append(f"  existing app: {result.get('existing', 'none')}")
    lines.append(f"  -> would {result.get('would')}")
    return "\n".join(lines)


def run_build(a):
    try:
        return _build(a)
    except AppError as ex:
        print(f"peakmetal build-app: error: {ex}", file=sys.stderr)
        return ex.code
    except OSError as ex:
        print(f"peakmetal build-app: error: {ex}", file=sys.stderr)
        return EXIT_ERROR


# ---- verify-app ------------------------------------------------------------------------------------------------
def _safe_rel(root, rel):
    if not isinstance(rel, str) or not rel or posixpath.isabs(rel) or "\\" in rel or ".." in rel.split("/"):
        return None
    return os.path.join(root, *rel.split("/"))


def check_app(app):
    """(manifest, problems). A problem is {kind, path, detail}."""
    m = read_manifest(app)
    if m is None:
        raise AppError(f"{app} has no PeakPack native manifest ({MANIFEST_REL})")
    problems = []
    for rel, digest in sorted(m.get("files", {}).items()):
        p = _safe_rel(app, rel)
        if p is None:
            problems.append({"kind": "manifest", "path": rel, "detail": "path escapes the app"})
        elif not os.path.isfile(p) or os.path.islink(p):
            problems.append({"kind": "missing", "path": rel, "detail": ""})
        elif _sha256_file(p) != digest:
            problems.append({"kind": "changed", "path": rel, "detail": "SHA-256 differs"})
    for rel, size in sorted(m.get("game_files", {}).items()):
        p = _safe_rel(app, rel)
        if p is None:
            problems.append({"kind": "manifest", "path": rel, "detail": "path escapes the app"})
        elif not os.path.isfile(p):
            problems.append({"kind": "missing", "path": rel, "detail": "game file"})
        elif os.path.getsize(p) != size:
            problems.append({"kind": "changed", "path": rel, "detail": f"size {os.path.getsize(p)} != {size}"})
    for rel, target in sorted(m.get("symlinks", {}).items()):
        p = _safe_rel(app, rel)
        if p is None or not os.path.islink(p):
            problems.append({"kind": "missing", "path": rel, "detail": "symlink"})
        elif os.readlink(p) != target:
            problems.append({"kind": "changed", "path": rel, "detail": "symlink target differs"})
    known = set(m.get("files", {})) | set(m.get("game_files", {})) | set(m.get("symlinks", {})) | {MANIFEST_REL}
    for dp, dns, fns in os.walk(app):
        for n in list(dns) + list(fns):
            p = os.path.join(dp, n)
            if not (os.path.islink(p) or os.path.isfile(p)):
                continue
            rel = _rel_to(p, app)
            if rel.startswith(CODESIGN_DIR_REL) or n == ".DS_Store" or rel in known:
                continue
            problems.append({"kind": "extra", "path": rel, "detail": "not in the manifest"})
    if is_macos():
        r = subprocess.run(["codesign", "--verify", "--deep", "--strict", app], capture_output=True, text=True)
        if r.returncode != 0:
            problems.append({"kind": "codesign", "path": ".", "detail": (r.stderr or r.stdout).strip()[-300:]})
    return m, problems


def run_verify(a):
    try:
        app = _abspath(a.app)
        if not os.path.isdir(app) or read_manifest(app) is None:
            raise AppError(f"{app} is not a PeakPack native app (no manifest, or an unknown schema)")
        m, problems = check_app(app)
    except AppError as ex:
        print(f"peakmetal verify-app: error: {ex}", file=sys.stderr)
        return ex.code
    except OSError as ex:
        print(f"peakmetal verify-app: error: {ex}", file=sys.stderr)
        return EXIT_ERROR
    print(f"{app}: {len(m.get('files', {}))} hashed files, {len(m.get('game_files', {}))} game files, "
          f"fingerprint {m.get('fingerprint', '')[:12]}")
    for p in problems:
        print(f"  {p['kind']}: {p['path']}" + (f" ({p['detail']})" if p["detail"] else ""))
    if not problems:
        print("ok: every file matches the manifest" + (" and codesign verifies" if is_macos() else
                                                       " (codesign skipped: not macOS)"))
        return EXIT_OK
    print(f"{len(problems)} problem(s)")
    return EXIT_PROBLEMS


# ---- remove-app ------------------------------------------------------------------------------------------------
def run_remove(a):
    try:
        app = _abspath(a.app)
        if not _is_our_app(app):
            raise AppError(f"{app} is not a PeakPack native app (no manifest or wrong bundle id): refusing to delete")
        targets = [("app", app)]
        prev = app + ".previous"
        if os.path.lexists(prev):
            targets.append(("leftover", prev))
        for b in sorted(glob.glob(glob.escape(app) + ".building-*")):
            targets.append(("leftover", b))
        work = _abspath(a.work) if a.work else default_work(app)
        if not a.keep_cache:
            if os.path.isfile(os.path.join(work, WORK_MARKER)):
                targets.append(("work cache", work))
            elif os.path.lexists(work):
                print(f"left alone (not a PeakPack work cache, no {WORK_MARKER}): {work}")
        if a.purge_user_data:
            for p in user_data_paths():
                if os.path.lexists(p):
                    targets.append(("user data", p))
        for kind, p in targets:
            if a.dry_run:
                print(f"would remove {kind}: {p}")
            else:
                _rmtree_if(p)
                print(f"removed {kind}: {p}")
        if a.dry_run:
            print("dry run: nothing removed")
        return EXIT_OK
    except AppError as ex:
        print(f"peakmetal remove-app: error: {ex}", file=sys.stderr)
        return ex.code
    except OSError as ex:
        print(f"peakmetal remove-app: error: {ex}", file=sys.stderr)
        return EXIT_ERROR
