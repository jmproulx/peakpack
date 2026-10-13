"""Launcher that works under `python -I` (isolated mode puts neither the cwd nor this folder on sys.path):
    python -I native/pm.py <command> ...     ==   python -I -m peakmetal <command> ...
`python -I -m peakmetal` itself needs this folder on sys.path, e.g. a .pth file in the venv's site-packages
(tools/venv/Lib/site-packages/peakmetal-native.pth on Joshua's PC)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from peakmetal.__main__ import main  # noqa: E402

sys.exit(main())
