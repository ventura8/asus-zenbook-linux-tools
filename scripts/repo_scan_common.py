"""Shared path constants for repo-wide Python scan helpers."""

from __future__ import annotations

DEBIAN_SHELL_FILES = (
    "debian/postinst",
    "debian/prerm",
    "debian/postrm",
    "debian/asus-zenbook-configure",
)

SKIP_DIR_NAMES = frozenset(
    {
        ".git",
        "node_modules",
        ".ruff_cache",
        ".pytest_cache",
        "reports",
        ".tools",
        "__pycache__",
        ".tmp-tests",
        ".mypy_cache",
        ".tox",
        "htmlcov",
        "artifacts",
        ".cache",
        ".venv",
        ".rpm-build",
    }
)
