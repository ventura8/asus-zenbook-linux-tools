"""Resolve install selection dialog version labels from VERSION or env."""

from __future__ import annotations

import os
from pathlib import Path


def _version_file_candidates() -> list[Path]:
    """Build ordered VERSION file search paths."""
    candidates: list[Path] = []
    install_src = os.environ.get("INSTALL_SOURCE_DIR", "").strip()
    if install_src:
        candidates.append(Path(install_src) / "VERSION")
    candidates.append(Path(__file__).resolve().parents[1] / "VERSION")
    candidates.append(Path("/usr/share/asus-zenbook-linux-tools/VERSION"))
    return candidates


def _read_version_file(path: Path) -> str | None:
    """Return stripped VERSION text when the path is readable UTF-8."""
    if not path.is_file():
        return None
    try:
        text = path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeError):
        return None
    return text or None


def read_project_version() -> str:
    """Return the semver from the first readable VERSION file candidate."""
    for path in _version_file_candidates():
        text = _read_version_file(path)
        if text:
            return text
    return "unknown"


def format_display_version(raw: str) -> str:
    """Format a raw VERSION value for display."""
    if raw == "unknown" or not raw:
        return "unknown"
    if raw.startswith("v"):
        return raw
    return f"v{raw}"


def resolve_display_version() -> str:
    """Resolve the dialog version from env or the canonical VERSION file."""
    env_version = os.environ.get("ASUS_DISPLAY_VERSION", "").strip()
    if env_version:
        return format_display_version(env_version)
    return format_display_version(read_project_version())
