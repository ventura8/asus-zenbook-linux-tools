"""Tests for repo file-size enforcement."""

import io
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import MagicMock

from scripts import check_file_size_limits as size_limits
from scripts.check_file_size_limits import (
    DEFAULT_MAX_LINES,
    _main_from_cli,
    _parse_max_lines_arg,
    _read_line_count,
)
from tests.unit.bin.attr_helpers import call_attr


class CheckFileSizeLimitsTests(unittest.TestCase):
    """Verify the file-size checker flags oversized production and test files."""

    def test_flags_oversized_repo_files(self):
        """The size checker should report oversized files under the tracked production/test scope."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            (root / "bin").mkdir()
            (root / "tests").mkdir()
            (root / "docs").mkdir()
            oversized_bin = root / "bin" / "big.sh"
            oversized_bin.write_text("echo ok\n" * 601, encoding="utf-8")
            oversized_tests = root / "tests" / "test_big.py"
            oversized_tests.write_text("x = 1\n" * 601, encoding="utf-8")
            oversized_docs = root / "docs" / "guide.md"
            oversized_docs.write_text("# docs\n" * 601, encoding="utf-8")
            (root / "install.sh").write_text("#!/bin/sh\n", encoding="utf-8")

            violations = size_limits.check_file_size_limits(root, max_lines=600)

            self.assertEqual(len(violations), 2)
            self.assertIn((oversized_bin.relative_to(root).as_posix(), 601), violations)
            self.assertIn((oversized_tests.relative_to(root).as_posix(), 601), violations)
            self.assertNotIn((oversized_docs.relative_to(root).as_posix(), 601), violations)

    def test_dedupe_symlink_reports_original_path(self):
        """Duplicate resolved paths should report the non-symlink relative path."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            (root / "bin").mkdir()
            target = root / "bin" / "real.py"
            target.write_text("x = 1\n" * 601, encoding="utf-8")
            link = root / "bin" / "link.py"
            link.symlink_to("real.py")
            violations = size_limits.check_file_size_limits(root, max_lines=600)
            paths = [entry[0] for entry in violations]
            # Prefer nonsymlink via _prefer_nonsymlink_path when aliases share a target.
            self.assertEqual(paths, ["bin/real.py"])

    def test_counts_binary_lines_without_utf8_decoding(self):
        """The size checker should count newline bytes in binary files without decoding."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            (root / "scripts").mkdir()
            binary_script = root / "scripts" / "blob.sh"
            binary_script.write_bytes(b"\xff\n\xfe\n")

            violations = size_limits.check_file_size_limits(root, max_lines=1)

            self.assertEqual(violations, [(binary_script.relative_to(root).as_posix(), 2)])

    def test_iter_repo_files_includes_debian_shell_scripts(self):
        """Debian maintainer scripts are included even without a .sh extension."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            debian = root / "debian"
            debian.mkdir()
            postinst = debian / "postinst"
            postinst.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
            (debian / "control").write_text("Source: demo\n", encoding="utf-8")
            files = [path.relative_to(root).as_posix() for path, _resolved in size_limits.iter_repo_files(root)]
            self.assertIn("debian/postinst", files)
            self.assertNotIn("debian/control", files)

    def test_iter_repo_files_includes_docker_shell_scripts(self):
        """CI image helper scripts under docker/ are size-gated like other tooling."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            script_dir = root / "docker" / "images" / "tests" / "scripts"
            script_dir.mkdir(parents=True)
            helper = script_dir / "create-asusci-user.sh"
            helper.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
            (root / "docker" / "images" / "tests" / "ubuntu.Dockerfile").write_text(
                "FROM ubuntu\n",
                encoding="utf-8",
            )
            files = [path.relative_to(root).as_posix() for path, _resolved in size_limits.iter_repo_files(root)]
            self.assertIn("docker/images/tests/scripts/create-asusci-user.sh", files)
            self.assertNotIn("docker/images/tests/ubuntu.Dockerfile", files)

    def test_iter_repo_files_skips_missing_scopes(self):
        """Missing scope directories are ignored while present root installers are included."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            (root / "uninstall.sh").write_text("#!/bin/sh\n", encoding="utf-8")
            files = [path.relative_to(root).as_posix() for path, _resolved in size_limits.iter_repo_files(root)]
            self.assertEqual(files, ["uninstall.sh"])

    def test_read_line_count_surfaces_oserror(self):
        """Unreadable files raise OSError with the relative path context."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            missing = Path(tmp_dir) / "missing-file-size-limits-path"
            with self.assertRaises(OSError) as raised:
                _read_line_count(missing, "missing.py")
            self.assertIn("Failed to read missing.py", str(raised.exception))

    def test_resolve_and_prefer_paths_tolerate_oserror(self):
        """resolve()/is_symlink OSError paths soft-fail for scanned file helpers."""
        boom = MagicMock()
        boom.suffix = ".py"
        boom.resolve.side_effect = OSError("resolve boom")
        boom.is_symlink.side_effect = OSError("symlink boom")
        self.assertIsNone(call_attr(size_limits, "_resolve_scanned_file", boom))
        self.assertFalse(call_attr(size_limits, "_is_scanned_file", boom))
        self.assertIs(call_attr(size_limits, "_prefer_nonsymlink_path", boom, boom), boom)
        entries: list[tuple[Path, Path]] = []
        call_attr(size_limits, "_append_named_resolved_files", [boom], entries)
        self.assertEqual(entries, [])

    def test_parse_max_lines_arg_defaults_when_omitted(self):
        """CLI argument parsing should keep default line limit when no argument is supplied."""
        self.assertEqual(_parse_max_lines_arg([]), DEFAULT_MAX_LINES)

    def test_parse_max_lines_arg_accepts_override(self):
        """CLI argument parsing should accept a numeric max-lines override."""
        self.assertEqual(_parse_max_lines_arg(["800"]), 800)

    def test_parse_max_lines_arg_rejects_invalid_input(self):
        """CLI parsing rejects too many args and non-integer values."""
        with self.assertRaises(ValueError):
            _parse_max_lines_arg(["1", "2"])
        with self.assertRaises(ValueError):
            _parse_max_lines_arg(["nope"])

    def test_main_success_and_violation_paths(self):
        """main() returns 0 when clean and 1 when violations are reported on real trees."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            (root / "bin").mkdir()
            (root / "bin" / "ok.py").write_text("print('ok')\n", encoding="utf-8")
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(size_limits.main(max_lines=10, root=root), 0)
            self.assertIn("within the 10-line limit", out.getvalue())

            (root / "bin" / "big.py").write_text("\n".join(["x"] * 20) + "\n", encoding="utf-8")
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(size_limits.main(max_lines=10, root=root), 1)
            self.assertIn("bin/big.py", out.getvalue())

    def test_main_from_cli_usage_error(self):
        """Invalid CLI args print usage text and exit 2."""
        err = io.StringIO()
        with redirect_stderr(err):
            self.assertEqual(_main_from_cli(["bad"]), 2)
        self.assertIn("Usage:", err.getvalue())
        self.assertIn("Max lines must be an integer", err.getvalue())


if __name__ == "__main__":
    unittest.main()
