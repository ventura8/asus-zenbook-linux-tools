"""Write the install checklist selection to a validated temp-dir output file."""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

_DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
_FILE_FLAGS = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW


def safe_output_path(path: Path) -> Path:
    """Resolve ``--output`` and require a non-symlink path inside the temp dir.

    The installer passes a ``mktemp`` file; anything else (traversal, symlinks,
    paths outside ``tempfile.gettempdir()``) is rejected.
    """
    base = Path(tempfile.gettempdir()).resolve()
    if path.is_symlink():
        raise ValueError(f"refusing symlink output path: {path}")
    resolved = path.resolve()
    if resolved == base or not resolved.is_relative_to(base):
        raise ValueError(f"output path must be inside {base}: {path}")
    return resolved


def _open_dir_chain(base: Path, parts: tuple[str, ...]) -> int:
    """Open ``base`` then each directory in ``parts`` without following symlinks."""
    fd = os.open(base, _DIR_FLAGS)
    try:
        for part in parts:
            next_fd = os.open(part, _DIR_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = next_fd
    except OSError:
        os.close(fd)
        raise
    return fd


def _write_pinned(resolved: Path, body: str) -> None:
    """Write ``body`` relative to a pinned temp-dir descriptor (no symlink hops)."""
    base = Path(tempfile.gettempdir()).resolve()
    rel = resolved.relative_to(base).parts
    dir_fd = _open_dir_chain(base, rel[:-1])
    try:
        file_fd = os.open(rel[-1], _FILE_FLAGS, 0o600, dir_fd=dir_fd)
    finally:
        os.close(dir_fd)
    with os.fdopen(file_fd, "w", encoding="utf-8") as out:
        out.write(body)


def write_selection(path: Path | None, tags: list[str]) -> None:
    """Write selected tags one per line (stdout when ``path`` is None)."""
    body = "\n".join(tags)
    if body:
        body += "\n"
    if path is None:
        sys.stdout.write(body)
        return
    _write_pinned(safe_output_path(path), body)
