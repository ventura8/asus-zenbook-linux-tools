#!/usr/bin/env python3
"""Implementation loader for the ASUS hotkey daemon."""

import importlib.util
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
# Append only so bin/ and the repo root cannot shadow the standard library.
if SCRIPT_DIR not in sys.path:
    sys.path.append(SCRIPT_DIR)
if REPO_ROOT not in sys.path:
    sys.path.append(REPO_ROOT)


def resolve_shared_imports_path() -> str:
    """Prefer installed bin copy, then checkout root (install deploys beside the daemon)."""
    candidates = (
        os.path.join(SCRIPT_DIR, "shared_imports.py"),
        os.path.join(REPO_ROOT, "shared_imports.py"),
    )
    for path in candidates:
        if os.path.isfile(path):
            return path
    raise ImportError("Unable to locate shared_imports.py beside the daemon or at the repository root")


SHARED_IMPORTS_PATH = resolve_shared_imports_path()


def _existing_shared_imports_module():
    """Return a cached shared_imports module when it matches SHARED_IMPORTS_PATH."""
    existing = sys.modules.get("shared_imports")
    if existing is None or not getattr(existing, "__file__", None):
        return None
    try:
        same = os.path.samefile(existing.__file__, SHARED_IMPORTS_PATH)
    except OSError:
        return None
    if same:
        return existing
    return None


def _restore_shared_imports_slot(previous):
    """Restore or clear sys.modules['shared_imports'] after a failed load."""
    if previous is None:
        sys.modules.pop("shared_imports", None)
        return
    sys.modules["shared_imports"] = previous


def _load_shared_imports():
    """Reuse an already-loaded shared_imports module when present."""
    reused = _existing_shared_imports_module()
    if reused is not None:
        return reused
    _shared_spec = importlib.util.spec_from_file_location("shared_imports", SHARED_IMPORTS_PATH)
    if _shared_spec is None or _shared_spec.loader is None:
        raise ImportError(f"Unable to load shared_imports from {SHARED_IMPORTS_PATH}")
    module = importlib.util.module_from_spec(_shared_spec)
    previous = sys.modules.get("shared_imports")
    sys.modules["shared_imports"] = module
    try:
        _shared_spec.loader.exec_module(module)
    except BaseException:
        _restore_shared_imports_slot(previous)
        raise
    return module


shared_imports = _load_shared_imports()

IMPLEMENTATION_PATH = os.path.join(SCRIPT_DIR, "asus_hotkey_daemon_impl.py")


def _load_implementation_module():
    """Load the real implementation module from disk and expose its API."""
    return shared_imports.load_module_from_path("_asus_hotkey_daemon_impl", IMPLEMENTATION_PATH)


_impl_module = _load_implementation_module()

SCRIPT_BINDIR = _impl_module.SCRIPT_BINDIR
clear_debounce = _impl_module.clear_debounce
find_device_path = _impl_module.find_device_path
handle_key_press = _impl_module.handle_key_press
main = _impl_module.main
perform_window_swap = _impl_module.perform_window_swap
prime_topology_cache = _impl_module.prime_topology_cache
run_script_if_exists = _impl_module.run_script_if_exists

__all__ = list(getattr(_impl_module, "__all__", []))


if __name__ == "__main__":
    raise SystemExit(_impl_module.main())
