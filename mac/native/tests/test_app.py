"""build-app / verify-app / remove-app on fake trees (tmp_path). Only the dry-run test reads the real Unity and PEAK
folders (read-only, skipped when absent). Nothing here needs macOS: signing and pkgutil are macOS-only paths and
are exercised through their refusal paths (size and MD5 checks run before any macOS tool)."""
import hashlib
import json
import os
import plistlib
import zipfile

import pytest
from conftest import EDITOR

from peakmetal import __main__ as cli
from peakmetal import app as APP

VAR = "macos_arm64_player_nondevelopment_mono"
REAL_MSS = os.path.join(EDITOR, "PlaybackEngines", "MacStandaloneSupport")
REAL_PEAK = r"D:\SteamLibrary\steamapps\common\PEAK"


def _w(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)
    return path


def _r(path):
    with open(path, "rb") as f:
        return f.read()


def _sha(data):
    return hashlib.sha256(data).hexdigest()


def _snapshot(root):
    out = {}
    for dp, dns, fns in os.walk(root):
        for n in dns + fns:
            p = os.path.join(dp, n)
            out[os.path.relpath(p, root)] = os.path.getmtime(p) if os.path.isfile(p) else "dir"
    return out


@pytest.fixture
def trees(tmp_path):
    """A fake Unity Mac Support folder, a fake PEAK Windows install, a fake converter output and a fake Steam zip."""
    mss = tmp_path / "src" / "MacStandaloneSupport"
    player = mss / "Variations" / VAR / "UnityPlayer.app"
    _w(player / "Contents/MacOS/UnityPlayer", b"MACHO-PLAYER")
    _w(player / "Contents/Frameworks/UnityPlayer.dylib", b"UNITYPLAYER-DYLIB")
    _w(player / "Contents/Frameworks/libmono-native.dylib", b"LIBMONO")
    _w(player / "Contents/Info.plist", b"player-info-to-be-replaced")
    _w(player / "Contents/Resources/Data/Resources/unity default resources", b"MAC-UDR")
    mono = mss / "Variations" / "mono" / "Managed"
    _w(mono / "UnityEngine.CoreModule.dll", b"MAC-CORE")
    _w(mono / "UnityEngine.AIModule.dll", b"MAC-AI")
    _w(mono / "UnityEngine.CoreModule.pdb", b"MAC-CORE-PDB")
    _w(mss / "MonoBleedingEdge" / "etc" / "mono" / "config", b"mono-config")

    game = tmp_path / "PEAK"
    data = game / "PEAK_Data"
    _w(data / "data.unity3d", b"WIN-ARCHIVE")
    _w(data / "Managed" / "Assembly-CSharp.dll", b"WIN-ASM")
    _w(data / "Managed" / "UnityEngine.CoreModule.dll", b"WIN-CORE")
    _w(data / "Managed" / "Photon3Unity3D.dll", b"WIN-PHOTON")
    _w(data / "Plugins" / "x86_64" / "steam_api64.dll", b"WIN-STEAM")
    _w(data / "Resources" / "unity default resources", b"WIN-UDR")
    _w(data / "Resources" / "unity_builtin_extra", b"WIN-EXTRA")
    _w(data / "sharedassets0.assets.resS", b"RESS")
    _w(data / "StreamingAssets" / "a.txt", b"streaming")
    _w(data / "boot.config", b"boot")
    _w(game / "version.txt", b"2.6.b\n82be08a25\n")

    conv = tmp_path / "conv"
    _w(conv / "Data" / "sharedassets0.assets", b"CONVERTED-SA")
    _w(conv / "Data" / "data.unity3d", b"CONV-ARCHIVE")
    _w(conv / "Data" / "Resources" / "unity default resources", b"CONV-UDR")
    _w(conv / "Data" / "Resources" / "converted_extra.bin", b"CONV-RES")
    _w(conv / "convert_summary.json", json.dumps({"schema": "peakpack.convert_summary/1", "status": "ok",
                                                  "exit_code": 0}).encode())

    zip_path = tmp_path / "src" / "Steamworks.NET-Standalone_2024.8.0.zip"
    zip_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path, "w") as z:
        z.writestr("OSX-Linux-x64/steam_api.bundle/Contents/MacOS/libsteam_api.dylib", b"VALVE-DYLIB")
        z.writestr("OSX-Linux-x64/steam_api.bundle/Contents/MacOS/libsteam_api.dylib.meta", b"meta")
        z.writestr("OSX-Linux-x64/steam_api.bundle/Contents/Info.plist", b"valve-info")
        z.writestr("Linux/libsteam_api.so", b"not used")

    return {"root": tmp_path, "mss": str(mss), "game": str(game), "conv": str(conv), "zip": str(zip_path),
            "out": str(tmp_path / "out" / "PEAK Native.app"), "work": str(tmp_path / "work")}


def _build_argv(t, *extra):
    return ["build-app", "--game", t["game"], "--unity-player", t["mss"], "--out", t["out"], "--work", t["work"],
            *extra]


def _pin_steam(monkeypatch, zip_path):
    monkeypatch.setattr(APP, "STEAM_ZIP_SHA256", _sha(_r(zip_path)))


def test_stock_build_layout(trees, capsys):
    t = trees
    rc = cli.main(_build_argv(t))
    assert rc == 0, capsys.readouterr()
    app = t["out"]
    d = os.path.join(app, "Contents", "Resources", "Data")
    # Unity's Mac assemblies overlay PEAK's Windows ones; the .pdb files are not assemblies and are not copied
    assert _r(os.path.join(d, "Managed", "UnityEngine.CoreModule.dll")) == b"MAC-CORE"
    assert _r(os.path.join(d, "Managed", "UnityEngine.AIModule.dll")) == b"MAC-AI"
    assert _r(os.path.join(d, "Managed", "Assembly-CSharp.dll")) == b"WIN-ASM"
    assert _r(os.path.join(d, "Managed", "Photon3Unity3D.dll")) == b"WIN-PHOTON"
    assert not os.path.exists(os.path.join(d, "Managed", "UnityEngine.CoreModule.pdb"))
    assert not os.path.exists(os.path.join(d, "Plugins"))
    assert not os.path.exists(os.path.join(app, "Contents", "PlugIns"))  # no Steam without --steam-zip
    # the Windows default resources are not copied: the Mac player's own stays
    assert _r(os.path.join(d, "Resources", "unity default resources")) == b"MAC-UDR"
    assert _r(os.path.join(d, "Resources", "unity_builtin_extra")) == b"WIN-EXTRA"
    assert _r(os.path.join(d, "data.unity3d")) == b"WIN-ARCHIVE"          # stock keeps the archive
    assert _r(os.path.join(d, "sharedassets0.assets.resS")) == b"RESS"
    assert os.path.isfile(os.path.join(d, "StreamingAssets", "a.txt"))
    assert os.path.isfile(os.path.join(app, "Contents", "MonoBleedingEdge", "etc", "mono", "config"))
    with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
        info = plistlib.load(f)
    assert info == {
        "CFBundleExecutable": "UnityPlayer",
        "CFBundleIdentifier": "com.peakpack.native",
        "CFBundleName": "PEAK Native",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "2.6.b",
        "CFBundleVersion": "1",
        "NSPrincipalClass": "PlayerApplication",
        "NSHighResolutionCapable": True,
        "LSMinimumSystemVersion": "11.0",
    }
    assert _r(os.path.join(app, "Contents", "MacOS", "steam_appid.txt")) == b"3527290\n"
    m = APP.read_manifest(app)
    assert m["schema"] == "peakpack.native_app/1" and m["recipe_version"] == 1
    assert m["counts"]["mac_managed_overlay"] == 2 and m["counts"]["mac_unityengine_assemblies"] == 2
    assert m["game_files"]["Contents/Resources/Data/data.unity3d"] == len(b"WIN-ARCHIVE")
    assert m["files"]["Contents/Info.plist"] == _sha(_r(os.path.join(app, "Contents", "Info.plist")))
    assert "Contents/Resources/peakpack-native.json" not in m["files"]
    assert not os.path.exists(t["out"] + ".previous")
    assert not [p for p in os.listdir(os.path.dirname(app)) if "building" in p]


def test_converted_build_has_no_archive_and_takes_companions_from_game(trees, capsys):
    t = trees
    rc = cli.main(_build_argv(t, "--converted", t["conv"]))
    assert rc == 0, capsys.readouterr()
    app = t["out"]
    d = os.path.join(app, "Contents", "Resources", "Data")
    assert not os.path.exists(os.path.join(d, "data.unity3d"))     # the converter's archive is never used
    assert _r(os.path.join(d, "sharedassets0.assets")) == b"CONVERTED-SA"
    assert _r(os.path.join(d, "Resources", "converted_extra.bin")) == b"CONV-RES"
    assert _r(os.path.join(d, "sharedassets0.assets.resS")) == b"RESS"   # companion from the game
    assert os.path.isfile(os.path.join(d, "StreamingAssets", "a.txt"))
    assert os.path.isfile(os.path.join(d, "boot.config"))
    assert _r(os.path.join(d, "Resources", "unity default resources")) == b"MAC-UDR"   # not the converter's copy
    assert not os.path.exists(os.path.join(d, "Plugins"))
    assert _r(os.path.join(d, "Managed", "UnityEngine.CoreModule.dll")) == b"MAC-CORE"
    m = APP.read_manifest(app)
    assert m["inputs"]["converted"]["summary_sha256"] == _sha(_r(os.path.join(t["conv"], "convert_summary.json")))
    assert m["files"]["Contents/Resources/Data/sharedassets0.assets"] == _sha(b"CONVERTED-SA")
    assert m["game_files"]["Contents/Resources/Data/sharedassets0.assets.resS"] == len(b"RESS")
    assert "Contents/Resources/Data/data.unity3d" not in m["game_files"]


def test_steam_zip_installs_valve_library_without_meta(trees, monkeypatch, capsys):
    t = trees
    _pin_steam(monkeypatch, t["zip"])
    rc = cli.main(_build_argv(t, "--steam-zip", t["zip"]))
    assert rc == 0, capsys.readouterr()
    app = t["out"]
    for rel in ("Contents/Frameworks/libsteam_api64.dylib", "Contents/PlugIns/libsteam_api64.dylib"):
        assert _r(os.path.join(app, rel)) == b"VALVE-DYLIB"
    assert os.path.isdir(os.path.join(app, "Contents", "PlugIns", "steam_api64.bundle"))
    assert os.path.isdir(os.path.join(app, "Contents", "PlugIns", "steam_api.bundle"))
    for dp, _dn, fns in os.walk(app):
        assert not any(f.endswith(".meta") for f in fns)
    assert APP.read_manifest(app)["inputs"]["steam_zip_sha256"] == _sha(_r(t["zip"]))


def test_steam_zip_with_wrong_sha_is_refused(trees, capsys):
    t = trees
    rc = cli.main(_build_argv(t, "--steam-zip", t["zip"]))
    assert rc == 2
    assert "SHA-256" in capsys.readouterr().err
    assert not os.path.exists(t["out"])


def test_idempotent_second_run_touches_nothing(trees, capsys):
    t = trees
    assert cli.main(_build_argv(t)) == 0
    app = t["out"]
    watched = [os.path.join(app, "Contents", "Info.plist"), os.path.join(app, *APP.MANIFEST_REL.split("/")),
               os.path.join(app, "Contents", "MacOS", "UnityPlayer")]
    before = {p: os.stat(p).st_mtime_ns for p in watched}
    before_all = _snapshot(app)
    capsys.readouterr()
    rj = os.path.join(t["root"], "result.json")
    assert cli.main(_build_argv(t, "--json", rj)) == 0
    assert "up to date" in capsys.readouterr().out
    assert {p: os.stat(p).st_mtime_ns for p in watched} == before
    assert _snapshot(app) == before_all
    with open(rj, encoding="utf-8") as f:
        assert json.load(f)["status"] == "up_to_date"


def test_force_rebuilds_and_input_change_rebuilds(trees, capsys):
    t = trees
    assert cli.main(_build_argv(t)) == 0
    rj = os.path.join(t["root"], "force.json")
    assert cli.main(_build_argv(t, "--force", "--json", rj)) == 0
    with open(rj, encoding="utf-8") as f:
        assert json.load(f)["status"] == "rebuilt"
    # a changed game version is a different fingerprint: rebuilt without --force
    with open(os.path.join(t["game"], "version.txt"), "wb") as f:
        f.write(b"2.7.a\n")
    assert cli.main(_build_argv(t, "--json", rj)) == 0
    with open(rj, encoding="utf-8") as f:
        assert json.load(f)["status"] == "rebuilt"
    with open(os.path.join(t["out"], "Contents", "Info.plist"), "rb") as f:
        assert plistlib.load(f)["CFBundleShortVersionString"] == "2.7.a"
    assert not os.path.exists(t["out"] + ".previous")


def test_failed_rebuild_leaves_the_existing_app_untouched(trees, monkeypatch, capsys):
    t = trees
    assert cli.main(_build_argv(t)) == 0
    app = t["out"]
    before = _snapshot(app)
    before_manifest = _r(os.path.join(app, *APP.MANIFEST_REL.split("/")))
    with open(os.path.join(t["game"], "version.txt"), "wb") as f:
        f.write(b"9.9.z\n")

    def boom(*_a, **_k):
        raise APP.AppError("simulated failure", APP.EXIT_ERROR)

    monkeypatch.setattr(APP, "_assemble", boom)
    assert cli.main(_build_argv(t)) == 1
    assert _snapshot(app) == before
    assert _r(os.path.join(app, *APP.MANIFEST_REL.split("/"))) == before_manifest
    assert not [p for p in os.listdir(os.path.dirname(app)) if "building" in p or p.endswith(".previous")]


def test_existing_app_that_is_not_ours_is_not_replaced(trees, capsys):
    t = trees
    os.makedirs(t["out"])
    with open(os.path.join(t["out"], "keep.txt"), "w") as f:
        f.write("mine")
    rc = cli.main(_build_argv(t))
    assert rc == 2
    assert os.path.isfile(os.path.join(t["out"], "keep.txt"))


def test_verify_ok_then_detects_modified_hashed_file(trees, capsys):
    t = trees
    assert cli.main(_build_argv(t)) == 0
    app = t["out"]
    assert cli.main(["verify-app", app]) == 0
    capsys.readouterr()
    with open(os.path.join(app, "Contents", "Info.plist"), "ab") as f:
        f.write(b"tamper")
    assert cli.main(["verify-app", app]) == 3
    assert "changed: Contents/Info.plist" in capsys.readouterr().out


def test_verify_detects_game_size_change_and_extra_file(trees, capsys):
    t = trees
    assert cli.main(_build_argv(t)) == 0
    app = t["out"]
    with open(os.path.join(app, "Contents", "Resources", "Data", "sharedassets0.assets.resS"), "ab") as f:
        f.write(b"!")
    with open(os.path.join(app, "Contents", "Resources", "junk.txt"), "w") as f:
        f.write("x")
    assert cli.main(["verify-app", app]) == 3
    out = capsys.readouterr().out
    assert "changed: Contents/Resources/Data/sharedassets0.assets.resS" in out
    assert "extra: Contents/Resources/junk.txt" in out


def test_verify_refuses_a_folder_that_is_not_ours(tmp_path, capsys):
    (tmp_path / "Some.app" / "Contents").mkdir(parents=True)
    assert cli.main(["verify-app", str(tmp_path / "Some.app")]) == 2


def test_remove_refuses_a_folder_without_manifest(tmp_path, capsys):
    fake = tmp_path / "Other.app"
    _w(str(fake / "Contents" / "Info.plist"), b"x")
    assert cli.main(["remove-app", str(fake)]) == 2
    assert fake.exists()


def test_remove_deletes_app_and_cache_and_leftovers(trees, capsys):
    t = trees
    assert cli.main(_build_argv(t)) == 0
    app = t["out"]
    os.makedirs(app + ".previous")
    os.makedirs(app + ".building-4242")
    assert os.path.isfile(os.path.join(t["work"], APP.WORK_MARKER))
    assert cli.main(["remove-app", app, "--work", t["work"]]) == 0
    assert not os.path.exists(app)
    assert not os.path.exists(app + ".previous")
    assert not os.path.exists(app + ".building-4242")
    assert not os.path.exists(t["work"])


def test_remove_keep_cache_keeps_work(trees, capsys):
    t = trees
    assert cli.main(_build_argv(t)) == 0
    assert cli.main(["remove-app", t["out"], "--work", t["work"], "--keep-cache"]) == 0
    assert not os.path.exists(t["out"])
    assert os.path.isdir(t["work"])


def test_remove_dry_run_removes_nothing(trees, capsys):
    t = trees
    assert cli.main(_build_argv(t)) == 0
    before = _snapshot(t["root"])
    assert cli.main(["remove-app", t["out"], "--work", t["work"], "--dry-run"]) == 0
    assert _snapshot(t["root"]) == before
    assert "would remove app" in capsys.readouterr().out


def test_remove_purges_user_data_only_when_asked(trees, monkeypatch, capsys):
    t = trees
    assert cli.main(_build_argv(t)) == 0
    user = [str(t["root"] / "userdata" / n) for n in ("prefs.plist", "appsupport", "savedstate", "cache")]
    _w(user[0], b"p")
    _w(os.path.join(user[1], "save.dat"), b"s")
    _w(os.path.join(user[2], "x"), b"x")
    _w(os.path.join(user[3], "y"), b"y")
    monkeypatch.setattr(APP, "user_data_paths", lambda: list(user))
    assert cli.main(["remove-app", t["out"], "--work", t["work"]]) == 0      # no flag: user data stays
    assert all(os.path.exists(p) for p in user)
    assert cli.main(_build_argv(t)) == 0
    assert cli.main(["remove-app", t["out"], "--work", t["work"], "--purge-user-data", "--dry-run"]) == 0
    assert all(os.path.exists(p) for p in user)
    assert os.path.isdir(t["out"])                                          # dry run removed nothing
    capsys.readouterr()
    assert cli.main(["remove-app", t["out"], "--work", t["work"], "--purge-user-data"]) == 0
    assert not any(os.path.exists(p) for p in user)
    out = capsys.readouterr().out
    for p in user:
        assert p in out
    assert os.path.isdir(t["game"])          # the game folder is never touched


def test_dry_run_writes_nothing(trees, capsys):
    t = trees
    before = _snapshot(t["root"])
    assert cli.main(_build_argv(t, "--dry-run", "--converted", t["conv"])) == 0
    assert _snapshot(t["root"]) == before
    assert not os.path.exists(t["out"]) and not os.path.exists(t["work"])
    assert "would build" in capsys.readouterr().out


def test_dry_run_counts_steam_without_extracting(trees, monkeypatch, capsys):
    t = trees
    _pin_steam(monkeypatch, t["zip"])
    rj = os.path.join(t["root"], "steam-plan.json")
    assert cli.main(_build_argv(t, "--dry-run", "--steam-zip", t["zip"], "--json", rj)) == 0
    with open(rj, encoding="utf-8") as f:
        plan = json.load(f)
    assert plan["counts"]["steam"] == 2 * 2 + 2     # two bundles of two files, two dylib copies
    assert plan["steam_zip"] == t["zip"]
    assert not os.path.exists(t["work"])            # the zip is not extracted by a dry run


def test_pkg_on_non_macos_is_a_usage_error(trees, monkeypatch, capsys):
    t = trees
    monkeypatch.setattr(APP, "is_macos", lambda: False)
    pkg = _w(str(t["root"] / "UnitySetup-Mac-Mono-Support-for-Editor-6000.3.15f1.pkg"), b"pkg")
    rc = cli.main(["build-app", "--game", t["game"], "--unity-player", pkg, "--out", t["out"], "--work", t["work"]])
    assert rc == 2
    assert "macOS" in capsys.readouterr().err


def test_pkg_with_wrong_size_or_md5_is_refused_before_any_macos_tool(trees, monkeypatch, capsys):
    t = trees
    monkeypatch.setattr(APP, "is_macos", lambda: True)
    pkg = _w(str(t["root"] / "fake.pkg"), b"not unity")
    argv = ["build-app", "--game", t["game"], "--unity-player", pkg, "--out", t["out"], "--work", t["work"]]
    assert cli.main(argv) == 2
    assert "bytes" in capsys.readouterr().err
    monkeypatch.setattr(APP, "UNITY_PKG_BYTES", os.path.getsize(pkg))
    assert cli.main(argv) == 2
    assert "MD5" in capsys.readouterr().err
    assert not os.path.exists(t["work"])


def test_missing_variation_lists_the_available_ones(trees, capsys):
    t = trees
    rc = cli.main(_build_argv(t, "--variation", "macos_arm64_player_development_mono"))
    assert rc == 2
    assert "available" in capsys.readouterr().err


def test_out_inside_game_folder_is_refused(trees, capsys):
    t = trees
    rc = cli.main(["build-app", "--game", t["game"], "--unity-player", t["mss"],
                   "--out", os.path.join(t["game"], "Native.app"), "--work", t["work"]])
    assert rc == 2
    assert not os.path.exists(os.path.join(t["game"], "Native.app"))


def test_converted_folder_without_data_is_refused(trees, capsys):
    t = trees
    rc = cli.main(_build_argv(t, "--converted", str(t["root"] / "nothing")))
    assert rc == 2


@pytest.mark.skipif(not (os.path.isdir(REAL_MSS) and os.path.isdir(REAL_PEAK)),
                    reason="real Unity 6000.3.15f1 Mac support and PEAK install not present")
def test_real_folders_dry_run_plan(tmp_path, capsys):
    rj = str(tmp_path / "plan.json")
    rc = cli.main(["build-app", "--game", REAL_PEAK, "--unity-player", REAL_MSS,
                   "--out", str(tmp_path / "out" / "PEAK Native.app"), "--work", str(tmp_path / "work"),
                   "--dry-run", "--json", rj])
    assert rc == 0, capsys.readouterr()
    with open(rj, encoding="utf-8") as f:
        plan = json.load(f)
    assert plan["variation"] == APP.DEFAULT_VARIATION
    assert plan["unity_player"]["binary_sha256"]
    # the Mac folder holds 80 UnityEngine .dll and 80 .pdb: the recipe overlays the .dll files only
    assert plan["counts"]["mac_unityengine_assemblies"] == 80
    assert plan["counts"]["mac_managed_overlay"] == 80
    assert plan["bytes"]["game_cloned"] > 1_000_000_000
    assert not (tmp_path / "out").exists() and not (tmp_path / "work").exists()


def test_player_without_info_plist_and_with_another_binary_name(trees, capsys):
    """Unity 6000.3's pkg ships UnityPlayer.app without Info.plist; the built bundle's Info.plist names the real binary."""
    t = trees
    player = os.path.join(t["mss"], "Variations", VAR, "UnityPlayer.app")
    os.remove(os.path.join(player, "Contents", "Info.plist"))
    os.rename(os.path.join(player, "Contents", "MacOS", "UnityPlayer"), os.path.join(player, "Contents", "MacOS", "PEAKPlayer"))
    assert APP.player_exe(player) == "PEAKPlayer"
    rc = cli.main(_build_argv(t))
    assert rc == 0, capsys.readouterr()
    with open(os.path.join(t["out"], "Contents", "Info.plist"), "rb") as f:
        info = plistlib.load(f)
    assert info["CFBundleExecutable"] == "PEAKPlayer"
    assert info["CFBundleIdentifier"] == "com.peakpack.native"
    assert info["NSHighResolutionCapable"] is True and info["LSMinimumSystemVersion"]
    assert _r(os.path.join(t["out"], "Contents", "MacOS", "PEAKPlayer")) == b"MACHO-PLAYER"


def test_find_variations_in_expanded_pkg_layout_without_info_plist(tmp_path):
    var = tmp_path / "expanded" / "TargetSupport.pkg.tmp" / "Payload" / "Variations"
    _w(var / VAR / "UnityPlayer.app" / "Contents" / "MacOS" / "UnityPlayer", b"\xcf\xfa\xed\xfe")
    _w(var / VAR / "UnityPlayer.app" / "Contents" / "Frameworks" / "UnityPlayer.dylib", b"D")
    _w(var / "mono" / "Managed" / "UnityEngine.dll", b"M")
    assert APP.find_variations(str(tmp_path / "expanded")) == str(var)


def test_player_exe_detection(tmp_path):
    macos = tmp_path / "P.app" / "Contents" / "MacOS"
    assert APP.player_exe(str(tmp_path / "P.app")) is None
    _w(macos / "libfoo.dylib", b"\xcf\xfa\xed\xfe")
    _w(macos / "steam_appid.txt", b"3527290")
    assert APP.player_exe(str(tmp_path / "P.app")) is None
    _w(macos / "Player", b"\xcf\xfa\xed\xfe....")
    assert APP.player_exe(str(tmp_path / "P.app")) == "Player"
