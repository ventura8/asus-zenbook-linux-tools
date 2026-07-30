"""Normalize coverage report paths to product-relative keys.

Used by scripts/coverage/gates.sh Python coverage gates so percent and
missing-file checks share identical path-normalization keys.
"""

from __future__ import annotations

import os


def _rel_after_product_prefix(path: str) -> str | None:
    """Return path from a segment-boundary product prefix, else None."""
    for prefix in ("bin/", "tools/", "scripts/"):
        idx = path.find(prefix)
        if idx < 0:
            continue
        if idx and path[idx - 1] != "/":
            continue
        return path[idx:]
    return None


def to_product_rel(path: str) -> str:
    """Return a stable product-relative key for a coverage file path."""
    path = path.replace("\\", "/")
    prefixed = _rel_after_product_prefix(path)
    if prefixed is not None:
        return prefixed
    base = os.path.basename(path)
    if base in {"shared_imports.py", "sitecustomize.py"}:
        return base
    if path.startswith("./"):
        return path[2:]
    return path
