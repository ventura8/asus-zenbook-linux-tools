#!/usr/bin/env python3
"""Fail closed when lint or type suppressions appear in scanned source files.

Policy (AGENTS.md): never silence linters or type checkers with inline comments
or config ignore lists. Fix the underlying code instead.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

from scripts.repo_scan_common import DEBIAN_SHELL_FILES, SKIP_DIR_NAMES

SCAN_EXTENSIONS = frozenset(
    {
        ".py",
        ".sh",
        ".bash",
        ".js",
        ".mjs",
        ".cjs",
        ".yml",
        ".yaml",
        ".toml",
        ".json",
        ".md",
        ".markdown",
    }
)
ROOT_CONFIG_FILES = (
    ".pylintrc",
    ".markdownlint.json",
    ".yamllint",
    "eslint.config.mjs",
    "pyproject.toml",
)
PRUNE_REL_DIRS = frozenset(
    {
        "packaging/arch/pkg",
        "packaging/arch/src",
        "packaging/appimage/AppDir",
        "packaging/flatpak/builddir",
        "packaging/flatpak/repo",
        ".flatpak-builder",
        "packaging/snap/parts",
        "packaging/snap/stage",
        "packaging/snap/prime",
        "debian/asus-zenbook-linux-tools",
        "debian/tmp",
        "debian/.debhelper",
    }
)
CONFIG_BASENAMES = frozenset(ROOT_CONFIG_FILES)

# Built from fragments so this file does not contain the forbidden literals.
INLINE_SUPPRESSION_RE = re.compile(
    "(?i)(?:"
    + "|".join(
        (
            r"#\s*" + "noqa" + r"\b",
            r"#\s*ruff:\s*" + "noqa" + r"\b",
            r"#\s*pylint:\s*" + "disable" + r"(?:-next)?\b",
            r"#\s*type:\s*" + "ignore" + r"\b",
            r"#\s*shellcheck\s+" + "disable" + r"\b",
            "eslint" + r"-" + "disable" + r"(?:-next-line|-line)?\b",
            "yamllint" + r"\s+" + "disable" + r"\b",
            r"#\s*hadolint\s+" + "ignore" + r"\b",
            "pragma:" + r"\s*no\s*cover\b",
            r"#\s*" + "nosec" + r"\b",
            r"#\s*flake8:\s*" + "noqa" + r"\b",
        )
    )
    + ")"
)

# Markdown: only real HTML-comment directives (policy prose may name the token).
MARKDOWN_SUPPRESSION_RE = re.compile(
    r"(?i)<!--\s*" + "markdownlint" + r"-" + "disable" + r"\b"
)

CONFIG_SUPPRESSION_RE = re.compile(
    "(?i)(?:"
    + "|".join(
        (
            "per-file-" + "ignores" + r"\b",
            r"\[tool\.ruff\.lint\.per-file-" + "ignores" + r"\]",
            r"^\s*" + "disable" + r"\s*=",
            r'"code_blocks"\s*:\s*false',
            r'"tables"\s*:\s*false',
            r"""['"]off['"]""",
        )
    )
    + ")"
)


def _should_prune_dir(name: str, rel_posix: str) -> bool:
    """Return True when *name* / *rel_posix* is outside the scan set."""
    if name in SKIP_DIR_NAMES or name.startswith(".venv"):
        return True
    if name.startswith(".rpm-build"):
        return True
    return rel_posix in PRUNE_REL_DIRS


def _child_rel_posix(rel_dir: str, name: str) -> str:
    """Join a walk-relative directory with a child name."""
    if not rel_dir:
        return name
    return f"{rel_dir}/{name}"


def _is_scanned_path(path: Path) -> bool:
    """Return whether *path* is a source/config file we must check."""
    if path.name.startswith("Dockerfile") or path.name.endswith(".Dockerfile"):
        return True
    return path.suffix in SCAN_EXTENSIONS


def os_walk_sorted(root: Path):
    """os.walk wrapper with sorted dir/file names for stable tests."""
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        filenames.sort()
        yield Path(dirpath), dirnames, filenames


def _prune_walk_dirs(root: Path, dirpath: Path, dirnames: list[str]) -> None:
    """Mutate *dirnames* in place to drop pruned children."""
    rel_dir = dirpath.relative_to(root).as_posix()
    if rel_dir == ".":
        rel_dir = ""
    dirnames[:] = [
        name
        for name in dirnames
        if not _should_prune_dir(name, _child_rel_posix(rel_dir, name))
    ]


def _collect_walked_files(root: Path) -> list[Path]:
    """Collect scanned files discovered via os.walk."""
    found: list[Path] = []
    for dirpath, dirnames, filenames in os_walk_sorted(root):
        _prune_walk_dirs(root, dirpath, dirnames)
        for name in filenames:
            path = dirpath / name
            if _is_scanned_path(path):
                found.append(path)
    return found


def _append_required_paths(root: Path, found: list[Path]) -> None:
    """Ensure root configs and Debian scripts are included when present."""
    for rel in (*ROOT_CONFIG_FILES, *DEBIAN_SHELL_FILES):
        path = root / rel
        if path.is_file() and path not in found:
            found.append(path)


def _iter_scanned_files(root: Path) -> list[Path]:
    """Return scanned files under *root* in deterministic order."""
    found = _collect_walked_files(root)
    _append_required_paths(root, found)
    return sorted(found, key=lambda p: p.relative_to(root).as_posix())


def _line_matches_suppression(line: str, path: Path) -> bool:
    """Return True when *line* in *path* contains a forbidden suppression."""
    if path.suffix in {".md", ".markdown"}:
        return bool(MARKDOWN_SUPPRESSION_RE.search(line))
    if INLINE_SUPPRESSION_RE.search(line):
        return True
    return bool(path.name in CONFIG_BASENAMES and CONFIG_SUPPRESSION_RE.search(line))


def find_lint_suppressions(root: Path) -> list[tuple[str, int, str]]:
    """Return (relpath, lineno, stripped_line) for each suppression hit."""
    hits: list[tuple[str, int, str]] = []
    for path in _iter_scanned_files(root):
        rel = path.relative_to(root).as_posix()
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for lineno, line in enumerate(text.splitlines(), start=1):
            if _line_matches_suppression(line, path):
                hits.append((rel, lineno, line.strip()))
    return hits


def main(argv: list[str] | None = None) -> int:
    """CLI entry: scan repo root (cwd) and exit 1 on any suppression."""
    del argv  # unused; kept for test parity with other scripts
    root = Path.cwd()
    hits = find_lint_suppressions(root)
    if not hits:
        print("  ✓ No lint suppressions found.")
        return 0
    print(
        "  ✗ Lint suppressions are forbidden (fix the code; see AGENTS.md):",
        file=sys.stderr,
    )
    for rel, lineno, snippet in hits:
        print(f"    {rel}:{lineno}: {snippet}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
