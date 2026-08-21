#!/usr/bin/env python3
"""Enforce a maximum line-count limit for production and test files.

Policy: files over the limit must be split into smaller modules. Do not strip comments,
blank lines, or spacing to pass the gate — that violates project agent rules (see AGENTS.md).
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

from scripts.repo_scan_common import DEBIAN_SHELL_FILES, SKIP_DIR_NAMES

DEFAULT_MAX_LINES = 600
DEFAULT_SCOPE = ("bin", "lib", "tests", "tools", "scripts", "gnome", "docker")
SCANNED_FILE_EXTENSIONS = (
    ".py",
    ".sh",
    ".bash",
    ".js",
    ".md",
    ".yml",
    ".yaml",
    ".toml",
    ".ini",
    ".cfg",
)
ROOT_LEVEL_FILES = ("install.sh", "uninstall.sh", "shared_imports.py", "sitecustomize.py")
ARCH_STAGING_REL_DIRS = frozenset(
    {
        "packaging/arch/pkg",
        "packaging/arch/src",
    }
)


def _resolve_scanned_file(path: Path) -> Path | None:
    """Return resolved path when *path* is a regular scanned file, else None."""
    try:
        resolved = path.resolve()
    except OSError:
        return None
    if resolved.is_file() and path.suffix in SCANNED_FILE_EXTENSIONS:
        return resolved
    return None


def _is_scanned_file(path: Path) -> bool:
    """Return whether *path* is a regular file with a tracked extension."""
    return _resolve_scanned_file(path) is not None


def _prefer_nonsymlink_path(prior: Path, path: Path) -> Path:
    """Prefer a non-symlink path when both resolve to the same target."""
    try:
        if prior.is_symlink() and not path.is_symlink():
            return path
    except OSError:
        pass
    return prior


def _dedupe_resolved_paths(entries: list[tuple[Path, Path]]) -> list[tuple[Path, Path]]:
    """Return sorted unique (original, resolved) pairs keyed by resolved path."""
    seen: dict[Path, tuple[Path, Path]] = {}
    for original, resolved in entries:
        if resolved in seen:
            prior_original, _ = seen[resolved]
            preferred = _prefer_nonsymlink_path(prior_original, original)
            seen[resolved] = (preferred, resolved)
            continue
        seen[resolved] = (original, resolved)
    return sorted(seen.values(), key=lambda item: item[0].as_posix())


def _append_named_files(root: Path, relatives: tuple[str, ...], candidates: list[Path]) -> bool:
    """Append existing root-relative files; return True when any were found."""
    found = False
    for relative in relatives:
        candidate = root / relative
        if candidate.is_file():
            candidates.append(candidate)
            found = True
    return found


def _collect_root_and_debian_files(root: Path, candidates: list[Path]) -> bool:
    """Append root-level and Debian maintainer scripts into *candidates*."""
    found = _append_named_files(root, ROOT_LEVEL_FILES, candidates)
    if _append_named_files(root, DEBIAN_SHELL_FILES, candidates):
        found = True
    return found


def _append_named_resolved_files(named: list[Path], entries: list[tuple[Path, Path]]) -> None:
    """Append (original, resolved) pairs for existing named files into *entries*."""
    for candidate in named:
        try:
            resolved = candidate.resolve()
        except OSError:
            continue
        if resolved.is_file():
            entries.append((candidate, resolved))


def iter_repo_files(root: Path) -> list[tuple[Path, Path]]:
    """Return (original, resolved) filesystem files under the production/test scope."""
    entries: list[tuple[Path, Path]] = []
    found_scope = False
    for scope in DEFAULT_SCOPE:
        scope_path = root / scope
        if not scope_path.exists():
            continue
        found_scope = True
        entries.extend(_iter_scope_file_entries(scope_path, root))
    named: list[Path] = []
    if _collect_root_and_debian_files(root, named):
        found_scope = True
    _append_named_resolved_files(named, entries)
    if not found_scope:
        raise OSError(f"No scoped directories or root files found under {root}")
    return _dedupe_resolved_paths(entries)


def _should_prune_dir(relative_posix: str, name: str) -> bool:
    """Return True when a directory should be skipped while walking."""
    child = f"{relative_posix}/{name}" if relative_posix else name
    if child in ARCH_STAGING_REL_DIRS:
        return True
    if name in SKIP_DIR_NAMES:
        return True
    if name.startswith(".venv"):
        return True
    return name.startswith(".rpm-build")


def _prune_walk_dirs(relative_posix: str, dirnames: list[str]) -> None:
    """Mutate dirnames in-place to drop pruned walk directories."""
    dirnames[:] = [
        name for name in dirnames if not _should_prune_dir(relative_posix, name)
    ]


def _iter_scope_file_entries(scope_path: Path, root: Path) -> list[tuple[Path, Path]]:
    """Return (original, resolved) scanned files within one repository scope path."""
    files: list[tuple[Path, Path]] = []
    for dirpath, dirnames, filenames in os.walk(scope_path, topdown=True):
        parent = Path(dirpath)
        rel_parent = parent.relative_to(root).as_posix()
        _prune_walk_dirs(rel_parent, dirnames)
        for name in filenames:
            candidate = parent / name
            resolved = _resolve_scanned_file(candidate)
            if resolved is not None:
                files.append((candidate, resolved))
    return files


def _read_line_count(path: Path, relative_path: str) -> int:
    """Read file content and return normalized line count for policy checks."""
    try:
        with path.open("rb") as handle:
            content = handle.read()
    except OSError as exc:
        raise OSError(f"Failed to read {relative_path}: {exc}") from exc
    return content.count(b"\n") + (1 if content and not content.endswith(b"\n") else 0)


def check_file_size_limits(root: Path, max_lines: int = DEFAULT_MAX_LINES) -> list[tuple[str, int]]:
    """Return a list of (relative_path, line_count) for files exceeding the limit."""
    violations: list[tuple[str, int]] = []
    for path, resolved in iter_repo_files(root):
        relative_path = path.relative_to(root).as_posix()
        line_count = _read_line_count(resolved, relative_path)
        if line_count > max_lines:
            violations.append((relative_path, line_count))
    return violations


def main(max_lines: int = DEFAULT_MAX_LINES, root: Path | None = None) -> int:
    """CLI entrypoint for enforcing the repo file size policy."""
    check_root = Path(__file__).resolve().parents[1] if root is None else Path(root).resolve()
    violations = check_file_size_limits(check_root, max_lines=max_lines)
    if violations:
        print(f"Files exceeding the {max_lines}-line limit:")
        for relative_path, line_count in violations:
            print(f"- {relative_path}: {line_count} lines")
        print(
            "Fix by splitting into smaller modules; do not delete comments, docstrings, or blank lines to pass (see AGENTS.md).",
            file=sys.stderr,
        )
        return 1
    print(f"All production and test files are within the {max_lines}-line limit.")
    return 0


def _parse_max_lines_arg(argv: list[str]) -> int:
    """Parse an optional max-lines CLI argument."""
    if not argv:
        return DEFAULT_MAX_LINES
    if len(argv) != 1:
        raise ValueError("Expected at most one optional max-lines argument.")
    try:
        max_lines = int(argv[0])
    except ValueError as exc:
        raise ValueError("Max lines must be an integer.") from exc
    if max_lines <= 0:
        raise ValueError("Max lines must be a positive integer.")
    return max_lines


def _main_from_cli(argv: list[str]) -> int:
    """Parse CLI args and execute the file-size limit check."""
    try:
        return main(max_lines=_parse_max_lines_arg(argv))
    except ValueError as err:
        print(f"Usage: {Path(__file__).name} [max_lines]", file=sys.stderr)
        print(f"Error: {err}", file=sys.stderr)
        return 2
    except OSError as err:
        print(f"Error: {err}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(_main_from_cli(sys.argv[1:]))
