"""sitecustomize hook for display-mode shell tests (copy onto PYTHONPATH as sitecustomize.py)."""

from __future__ import annotations

import importlib.util
import os
import runpy
import sys
from pathlib import Path

_SELF_PATH = Path(__file__).resolve()


def _upstream_sitecustomize_candidate(entry: str) -> Path | None:
    """Return a sitecustomize.py path under *entry* when it exists and is not self."""
    if not entry:
        return None
    candidate = Path(entry).resolve() / "sitecustomize.py"
    if not candidate.is_file():
        return None
    if candidate.resolve() == _SELF_PATH:
        return None
    return candidate


def _load_sitecustomize_module(candidate: Path) -> bool:
    """Load *candidate* as ``_upstream_sitecustomize``; return True on success."""
    spec = importlib.util.spec_from_file_location("_upstream_sitecustomize", candidate)
    if spec is None or spec.loader is None:
        return False
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return True


def _chain_upstream_sitecustomize() -> None:
    """Run the next sitecustomize.py on sys.path before this test hook."""
    for entry in sys.path:
        candidate = _upstream_sitecustomize_candidate(entry)
        if candidate is None:
            continue
        if _load_sitecustomize_module(candidate):
            return


_chain_upstream_sitecustomize()

_startup = os.environ.get("ASUS_DISPLAY_MODE_DBUS_STARTUP")
if os.environ.get("ASUS_DISPLAY_MODE_SHELL_TEST") == "1":
    if not _startup:
        raise SystemExit("ASUS_DISPLAY_MODE_DBUS_STARTUP must be set when ASUS_DISPLAY_MODE_SHELL_TEST=1")
    startup_path = Path(_startup)
    if not startup_path.is_file():
        raise SystemExit(f"ASUS_DISPLAY_MODE_DBUS_STARTUP is not a readable file: {_startup}")
    runpy.run_path(str(startup_path), run_name="display_mode_shell_dbus_startup")
