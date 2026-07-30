"""Shared helpers for mocked E2E daemon tests."""

from __future__ import annotations

import os


def build_pythonpath_env(project_root: str) -> dict[str, str]:
    """Return subprocess environment with the project path on PYTHONPATH."""
    env = dict(os.environ)
    existing_pythonpath = env.get("PYTHONPATH", "")
    path_parts = [project_root]
    if existing_pythonpath:
        path_parts.append(existing_pythonpath)
    env["PYTHONPATH"] = ":".join(path_parts)
    return env
