"""Helpers for loading repository-local Python modules by file path."""

import importlib.util
import os
import sys


def load_module_from_path(module_name, module_path):
    """Load a module from an explicit file path."""
    spec = importlib.util.spec_from_file_location(module_name, module_path)
    if spec is None or spec.loader is None:
        raise ImportError(f"Unable to load module {module_name} from {module_path}")

    prior_module = sys.modules.get(module_name)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    load_succeeded = False
    try:
        spec.loader.exec_module(module)
        load_succeeded = True
    finally:
        if not load_succeeded:
            if prior_module is None:
                sys.modules.pop(module_name, None)
            else:
                sys.modules[module_name] = prior_module
    return module


def load_asus_common():
    """Load the shared ASUS helper module from the local install tree or source tree."""
    loaded_module = sys.modules.get("asus_common")
    if loaded_module is not None:
        return loaded_module

    script_dir = os.path.dirname(os.path.abspath(__file__))
    candidate_paths = [
        os.path.join(script_dir, "asus_common.py"),
        os.path.join(script_dir, "bin", "asus_common.py"),
    ]

    for module_path in candidate_paths:
        if os.path.isfile(module_path):
            return load_module_from_path("asus_common", module_path)

    searched = ", ".join(candidate_paths)
    raise FileNotFoundError(f"Unable to locate asus_common.py; searched: {searched}")
