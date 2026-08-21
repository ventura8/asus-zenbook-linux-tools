"""Unit tests for lint file discovery prune rules."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from tests.unit.shell.shell_test_utils import run_bash_c

_REPO_ROOT = Path(__file__).resolve().parents[3]
_RUN_LINTS = _REPO_ROOT / "scripts/run-lints.sh"


def _extract_find_repo_files_definition(lints_path: Path) -> str:
    """Extract _find_repo_files from run-lints.sh by brace matching."""
    text = lints_path.read_text(encoding="utf-8")
    marker = "_find_repo_files()"
    start = text.index(marker)
    brace = text.index("{", start)
    depth = 0
    for index, char in enumerate(text[brace:], start=brace):
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start : index + 1]
    raise AssertionError("_find_repo_files body not found in run-lints.sh")


_FIND_REPO_FILES_DEF = _extract_find_repo_files_definition(_RUN_LINTS)


class TestRunLintsPrune(unittest.TestCase):
    """_find_repo_files must skip release build staging trees."""

    def test_find_repo_files_skips_rpm_build_and_arch_pkg(self) -> None:
        """Staged RPM/Arch payload copies must not be linted as product sources."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            repo = Path(tmp_dir) / "repo"
            repo.mkdir()
            real_js = repo / "gnome" / "ext" / "extension.js"
            real_js.parent.mkdir(parents=True)
            real_js.write_text("// real\n", encoding="utf-8")
            staged_js = (
                repo
                / ".rpm-build-rpm-fedora-44"
                / "BUILDROOT"
                / "usr/share/gnome/extension.js"
            )
            staged_js.parent.mkdir(parents=True)
            staged_js.write_text("// staged\n", encoding="utf-8")
            nested_staged_js = (
                repo
                / "build"
                / ".rpm-build-rpm-fedora-44"
                / "BUILDROOT"
                / "usr/share/gnome/extension.js"
            )
            nested_staged_js.parent.mkdir(parents=True)
            nested_staged_js.write_text("// nested staged\n", encoding="utf-8")
            arch_pkg_js = (
                repo
                / "packaging"
                / "arch"
                / "pkg"
                / "asus-zenbook-linux-tools"
                / "usr/share/gnome/extension.js"
            )
            arch_pkg_js.parent.mkdir(parents=True)
            arch_pkg_js.write_text("// pkg\n", encoding="utf-8")
            arch_src_js = (
                repo
                / "packaging"
                / "arch"
                / "src"
                / "asus-zenbook-linux-tools"
                / "usr/share/gnome/extension.js"
            )
            arch_src_js.parent.mkdir(parents=True)
            arch_src_js.write_text("// src\n", encoding="utf-8")
            snippet = f"""
{_FIND_REPO_FILES_DEF}
cd '{repo}'
mapfile -t hits < <(_find_repo_files -name 'extension.js')
printf '%s\\n' "${{hits[@]}}"
"""
            proc = run_bash_c(snippet, timeout=15)
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            lines = [line for line in proc.stdout.splitlines() if line.strip()]
            self.assertEqual(len(lines), 1, msg=lines)
            self.assertTrue(lines[0].endswith("gnome/ext/extension.js"), msg=lines[0])
