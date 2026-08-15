"""Unit tests for tools/make_fake_loginctl.py."""

import io
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

from tools import make_fake_loginctl


class TestMakeFakeLoginctl(unittest.TestCase):
    """Validate generated loginctl stub behavior."""

    def _write_stub(self, tmp: str) -> Path:
        make_fake_loginctl.main([tmp])
        return Path(tmp) / "loginctl"

    def test_main_rejects_missing_target_dir(self):
        """Generator exits non-zero when target directory argument is absent."""
        err = io.StringIO()
        with redirect_stderr(err), self.assertRaises(SystemExit) as raised:
            make_fake_loginctl.main([])
        self.assertEqual(raised.exception.code, 1)
        self.assertIn("Usage:", err.getvalue())

    def test_main_rejects_nonexistent_target_dir(self):
        """Generator exits non-zero with a path-specific error when the dir is missing."""
        err = io.StringIO()
        with tempfile.TemporaryDirectory() as tmp:
            missing = str(Path(tmp) / "missing-dir")
            with redirect_stderr(err), self.assertRaises(SystemExit) as raised:
                make_fake_loginctl.main([missing])
        self.assertEqual(raised.exception.code, 1)
        self.assertIn("Error: target directory does not exist:", err.getvalue())
        self.assertNotIn("Usage:", err.getvalue())

    def test_show_session_rejects_unknown_property(self):
        """Generated stub exits non-zero for unsupported show-session properties."""
        with tempfile.TemporaryDirectory() as tmp:
            loginctl = self._write_stub(tmp)
            proc = subprocess.run(
                [str(loginctl), "show-session", "c1", "-p", "Unknown"],
                capture_output=True,
                text=True,
                check=False,
                timeout=30,
            )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("unsupported show-session property", proc.stderr)

    def test_unsupported_command_exits_nonzero(self):
        """Generated stub rejects commands other than list-sessions and show-session."""
        with tempfile.TemporaryDirectory() as tmp:
            loginctl = self._write_stub(tmp)
            proc = subprocess.run(
                [str(loginctl), "terminate-session", "c1"],
                capture_output=True,
                text=True,
                check=False,
                timeout=30,
            )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("unsupported loginctl command", proc.stderr)

    def test_generated_stub_is_executable(self):
        """Generator writes an executable loginctl stub."""
        with tempfile.TemporaryDirectory() as tmp:
            loginctl = self._write_stub(tmp)
            self.assertTrue(os.access(loginctl, os.X_OK))

    def test_current_user_mode_lists_invoking_uid(self):
        """--current-user stub reports the invoking uid/username."""
        with tempfile.TemporaryDirectory() as tmp:
            make_fake_loginctl.main(["--current-user", tmp])
            loginctl = Path(tmp) / "loginctl"
            proc = subprocess.run(
                [str(loginctl), "list-sessions"],
                capture_output=True,
                text=True,
                check=False,
                timeout=30,
            )
        self.assertEqual(proc.returncode, 0)
        self.assertIn(str(os.getuid()), proc.stdout)

    def test_module_main_guard_invokes_main(self):
        """Running the module as __main__ executes main()."""
        with tempfile.TemporaryDirectory() as tmp:
            generator = Path(make_fake_loginctl.__file__)
            subprocess.run([sys.executable, str(generator), tmp], check=True, timeout=30)
            self.assertTrue((Path(tmp) / "loginctl").is_file())


if __name__ == "__main__":
    unittest.main()
