#!/usr/bin/env python3
"""Rewrite Docker /workspace prefixes in exported kcov shard metadata."""

from __future__ import annotations

import sys
from pathlib import Path

_TEXT_SUFFIXES = {".json", ".xml", ".js", ".html", ".css"}


def _should_scan(path: Path) -> bool:
    if path.suffix in _TEXT_SUFFIXES:
        return True
    return path.parent.name == "metadata"


def _rewrite_file(path: Path, needle: bytes, replacement: bytes) -> bool:
    data = path.read_bytes()
    if needle not in data:
        return False
    path.write_bytes(data.replace(needle, replacement))
    return True


def rewrite_tree(runs_dir: Path, repo_root: str) -> int:
    """Replace b'/workspace' with repo_root bytes under runs_dir. Return files changed."""
    needle = b"/workspace"
    replacement = repo_root.encode()
    changed = 0
    for path in runs_dir.rglob("*"):
        if not path.is_file() or not _should_scan(path):
            continue
        if _rewrite_file(path, needle, replacement):
            changed += 1
    return changed


def _usage() -> None:
    print(
        "Usage: rewrite_kcov_workspace_prefix.py <runs-dir> <repo-root>",
        file=sys.stderr,
    )


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        _usage()
        return 2
    runs_dir = Path(argv[1])
    repo_root = argv[2].rstrip("/")
    if not runs_dir.is_dir():
        print(f"  ✗ Missing kcov runs dir: {runs_dir}", file=sys.stderr)
        return 1
    if not repo_root:
        print("  ✗ Empty repo root for kcov path rewrite", file=sys.stderr)
        return 1
    rewrite_tree(runs_dir, repo_root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
