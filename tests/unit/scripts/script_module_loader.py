"""Load a scripts/*.py module by path without requiring packaging."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import ModuleType


def _scripts_module_path(relative_parts: tuple[str, ...]) -> Path:
    """Resolve ``scripts/<relative_parts...>`` from the repository root."""
    return Path(__file__).resolve().parents[3].joinpath(*relative_parts)


def _ensure_dir_on_sys_path(directory: Path) -> None:
    """Prepend *directory* to ``sys.path`` when missing."""
    directory_s = str(directory)
    if directory_s not in sys.path:
        sys.path.insert(0, directory_s)


def _exec_module_from_path(module_name: str, module_path: Path) -> ModuleType:
    """Load and execute *module_path* as *module_name*."""
    spec = importlib.util.spec_from_file_location(module_name, module_path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {module_path}")
    prior_module = sys.modules.get(module_name)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        if prior_module is None:
            sys.modules.pop(module_name, None)
        else:
            sys.modules[module_name] = prior_module
        raise
    return module


def load_scripts_module(module_name: str, relative_parts: tuple[str, ...]) -> ModuleType:
    """Load ``scripts/<relative_parts...>`` as *module_name* (idempotent)."""
    module_path = _scripts_module_path(relative_parts)
    existing = sys.modules.get(module_name)
    if existing is not None and getattr(existing, "__file__", None) == str(module_path):
        return existing
    _ensure_dir_on_sys_path(module_path.parent)
    return _exec_module_from_path(module_name, module_path)
