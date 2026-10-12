#!/usr/bin/env python3
"""Write manifest.json (INTERFACES.md section 5) for an assembled runtime tree to stdout.

Usage: manifest.py --runtime DIR --work PP_WORK --pins pins.env --runtime-id ID
Run with `python3 -I` (isolated mode); it only reads files.
"""
import argparse
import datetime
import hashlib
import json
import os
import platform
import re
import subprocess
import sys


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_pins(path):
    pins = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^([A-Z0-9_]+)=(.*)$", line.strip())
            if m:
                pins[m.group(1)] = m.group(2).split("#", 1)[0].strip()
    return pins


def read_kv(path):
    out = {}
    if os.path.isfile(path):
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.strip().split(" ", 1)
                if len(parts) == 2:
                    out[parts[0]] = parts[1]
    return out


def read_text(path, default=""):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return default


def cmd(args):
    try:
        return subprocess.run(args, capture_output=True, text=True, check=False).stdout.strip()
    except OSError:
        return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runtime", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--pins", required=True)
    ap.add_argument("--runtime-id", required=True)
    a = ap.parse_args()

    pins = read_pins(a.pins)
    applied = []
    applied_path = os.path.join(a.work, "src", "APPLIED.txt")
    if os.path.isfile(applied_path):
        with open(applied_path, encoding="utf-8") as f:
            for line in f:
                p = line.split()
                if len(p) >= 3 and p[0] == "patch":
                    applied.append({"file": p[1], "sha256": p[2]})
                elif len(p) >= 4 and p[0] == "extra-dll":
                    applied.append({"extra_dll": p[1], "tree_sha256": p[3]})

    unpinned = read_text(os.path.join(a.work, "UNPINNED.txt"))
    files = {}
    for root, dirs, names in os.walk(a.runtime):
        dirs.sort()
        for n in sorted(names):
            full = os.path.join(root, n)
            rel = os.path.relpath(full, a.runtime).replace(os.sep, "/")
            if rel == "manifest.json" or os.path.islink(full):
                continue
            files[rel] = sha256(full)

    dxmt = read_kv(os.path.join(a.work, "stage", "dxmt", "DXMT-VERSION.txt"))
    dxvk = read_kv(os.path.join(a.work, "stage", "dxvk", "DXVK-VERSION.txt"))
    deps = read_kv(os.path.join(a.work, "deps", "x86_64", "VERSIONS.txt"))
    run_url = ""
    if os.environ.get("GITHUB_RUN_ID"):
        run_url = "%s/%s/actions/runs/%s" % (
            os.environ.get("GITHUB_SERVER_URL", "https://github.com"),
            os.environ.get("GITHUB_REPOSITORY", ""),
            os.environ["GITHUB_RUN_ID"],
        )

    manifest = {
        "schema": 1,
        "runtime_id": a.runtime_id,
        "built_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "pinned": not bool(unpinned),
        "unpinned_inputs": unpinned.splitlines() if unpinned else [],
        "min_macos": pins.get("PP_MACOS_MIN"),
        "arch": "x86_64 (Rosetta 2 on Apple silicon)",
        "builder": {
            "runner": os.environ.get("RUNNER_NAME", platform.node()),
            "runner_label": os.environ.get("PP_RUNNER_LABEL", ""),
            "macos": cmd(["sw_vers", "-productVersion"]),
            "xcode": cmd(["xcodebuild", "-version"]).replace("\n", " "),
            "workflow_run": run_url,
            "git_commit": os.environ.get("GITHUB_SHA", ""),
        },
        "wine": {
            "source": pins.get("CX_TARBALL"),
            "source_url": pins.get("CX_URL"),
            "source_sha256": pins.get("CX_SHA256"),
            "wine_version": read_text(os.path.join(a.work, "wine-version.txt")),
            "patches": applied,
            "configure_args": read_text(os.path.join(a.work, "wine-configure-args.txt")),
            "pe_toolchain": pins.get("PP_PE_TOOLCHAIN"),
            "msync": True,
            "winemac_exports_macdrv_functions": True,
            "winemac_default_visibility": os.environ.get("PP_WINEMAC_EXPORT_ALL", "0") == "1",
        },
        "components": {
            "dxmt": {
                "tag": pins.get("DXMT_TAG"),
                "commit": dxmt.get("dxmt_commit", pins.get("DXMT_COMMIT")),
                "submodules": dxmt.get("dxmt_submodules", ""),
                "llvm": dxmt.get("llvm"),
                "licence": "MIT" if pins.get("DXMT_TAG") == "v0.80" else "LGPL-2.1-or-later",
                "install": "winemetal.{so,dll} builtin; d3d11/dxgi/d3d10core native in lib/peakpack/dxmt",
            },
            "dxvk": {"present": os.path.isdir(os.path.join(a.runtime, "lib", "peakpack", "dxvk")),
                     "version": dxvk.get("dxvk"), "mingw": dxvk.get("mingw"), "licence": "zlib"},
            "moltenvk": {"version": pins.get("MOLTENVK_VERSION"), "sha256": pins.get("MOLTENVK_SHA256"),
                         "licence": "Apache-2.0"},
            "freetype": {"version": deps.get("freetype"), "licence": "FTL"},
            "gnutls": {"version": deps.get("gnutls"), "licence": "LGPL-2.1-or-later"},
            "nettle": {"version": deps.get("nettle"), "licence": "LGPL-3.0-or-later OR GPL-2.0-or-later"},
            "gmp": {"version": deps.get("gmp"), "licence": "LGPL-3.0-or-later OR GPL-2.0-or-later"},
            "libinotify": {"version": pins.get("LIBINOTIFY_VERSION"), "sha256": pins.get("LIBINOTIFY_SHA256"),
                           "licence": "MIT"},
        },
        "toolchain": {
            "llvm_mingw": pins.get("LLVM_MINGW_VERSION"),
            "dxmt_llvm": pins.get("LLVM15_VERSION"),
            "meson": dxmt.get("meson"),
            "xcode": dxmt.get("xcode"),
        },
        "files": files,
        "extra_builtins": [],
    }
    json.dump(manifest, sys.stdout, indent=1, sort_keys=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
