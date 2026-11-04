"""Temp-file fixture for module-loader failure tests."""

from __future__ import annotations

import tempfile
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path


@contextmanager
def failing_module_path() -> Iterator[Path]:
    """Yield the path of a temporary module that raises RuntimeError on import."""
    with tempfile.TemporaryDirectory() as tmp_dir:
        bad_module = Path(tmp_dir) / "bad_module.py"
        bad_module.write_text("raise RuntimeError('boom')\n", encoding="utf-8")
        yield bad_module
