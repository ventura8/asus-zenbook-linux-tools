"""Tests for product-file discovery helpers in scripts/coverage/gates.sh."""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from tests.unit.shell.shell_test_utils import run_shell_argv

REPO_ROOT = Path(__file__).resolve().parents[3]
GATES_SH = REPO_ROOT / "scripts" / "coverage" / "gates.sh"
COMMON_SH = REPO_ROOT / "scripts" / "coverage" / "common.sh"


def _nonempty_stdout_lines(stdout: str) -> list[str]:
    """Return non-blank lines from *stdout*."""
    return [line for line in stdout.splitlines() if line.strip()]


def _run_gate_helper(repo_root: Path, helper: str) -> list[str]:
    """Source coverage helpers under *repo_root* and print one listing helper."""
    script = f"""
set -euo pipefail
# shellcheck source=scripts/coverage/common.sh
source {COMMON_SH.as_posix()!r}
# shellcheck source=scripts/coverage/gates.sh
source {GATES_SH.as_posix()!r}
export KCOV_REPO_ROOT={repo_root.as_posix()!r}
{helper}
"""
    env = os.environ.copy()
    env["KCOV_REPO_ROOT"] = str(repo_root)
    proc = run_shell_argv(["bash", "-c", script], env=env, timeout=30)
    if proc.returncode:
        raise AssertionError(proc.stderr or proc.stdout or f"exit {proc.returncode}")
    return _nonempty_stdout_lines(proc.stdout)


class ProductGatesDiscoveryTests(unittest.TestCase):
    """New product modules under bin/lib/tools must appear in coverage discovery."""

    def _seed_product_tree(self, root: Path) -> None:
        """Create minimal product dirs plus required helper Python modules."""
        (root / "bin").mkdir()
        (root / "lib").mkdir()
        (root / "tools").mkdir()
        (root / "scripts").mkdir()
        (root / "shared_imports.py").write_text("x = 1\n", encoding="utf-8")
        (root / "sitecustomize.py").write_text("x = 1\n", encoding="utf-8")
        (root / "scripts" / "check_file_size_limits.py").write_text("x = 1\n", encoding="utf-8")
        (root / "install.sh").write_text("#!/bin/sh\n", encoding="utf-8")
        (root / "uninstall.sh").write_text("#!/bin/sh\n", encoding="utf-8")

    def test_python_discovery_includes_new_bin_module_and_skips_symlink(self):
        """Find-based Python listing picks up new modules and skips CLI symlinks."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            self._seed_product_tree(root)
            (root / "bin" / "asus_new_helper.py").write_text("VALUE = 1\n", encoding="utf-8")
            (root / "bin" / "asus-hotkey-daemon.py").symlink_to("asus_new_helper.py")
            (root / "tools" / "new_tool.py").write_text("VALUE = 2\n", encoding="utf-8")

            listed = _run_gate_helper(root, "_list_product_python_files")
            self.assertIn("bin/asus_new_helper.py", listed)
            self.assertIn("tools/new_tool.py", listed)
            self.assertIn("shared_imports.py", listed)
            self.assertIn("scripts/check_file_size_limits.py", listed)
            self.assertIn("sitecustomize.py", listed)
            self.assertNotIn("bin/asus-hotkey-daemon.py", listed)

            include = _run_gate_helper(root, "_python_coverage_include_pattern")
            self.assertEqual(len(include), 1)
            parts = include[0].split(",")
            self.assertIn("bin/asus_new_helper.py", parts)
            self.assertIn("tools/new_tool.py", parts)
            self.assertNotIn("bin/asus-hotkey-daemon.py", parts)

    def test_shell_discovery_includes_new_bin_and_lib_helpers(self):
        """Find-based shell listing picks up new product helpers under bin/ and lib/."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            self._seed_product_tree(root)
            (root / "bin" / "asus-new-toggle.sh").write_text("#!/bin/sh\n", encoding="utf-8")
            (root / "lib" / "asus-new-lib.sh").write_text("#!/bin/sh\n", encoding="utf-8")

            listed = _run_gate_helper(root, "_list_product_shell_scripts")
            self.assertIn("bin/asus-new-toggle.sh", listed)
            self.assertIn("lib/asus-new-lib.sh", listed)
            self.assertIn("install.sh", listed)
            self.assertIn("uninstall.sh", listed)

    def test_python_files_below_uses_shared_product_relpath(self):
        """Percent-below gate keys paths via scripts/coverage/product_relpath.py."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            json_path = root / "coverage.json"
            json_path.write_text(
                '{"files": {"/abs/bin/asus_new_helper.py": {"summary": {"percent_covered": 50.0}},'
                ' "/abs/tools/new_tool.py": {"summary": {"percent_covered": 95.0}}}}\n',
                encoding="utf-8",
            )
            listed = _run_gate_helper(
                root,
                f"_python_files_below_from_json {json_path.as_posix()!r} 90",
            )
            self.assertEqual(listed, ["bin/asus_new_helper.py=50%"])


if __name__ == "__main__":
    unittest.main(failfast=True)
