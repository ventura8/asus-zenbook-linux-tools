"""E2E tests matching bin/asus-screenshot.sh."""

import os
import tempfile
import unittest
from pathlib import Path

from tests.e2e.e2e_utils import run_e2e_command
from tests.e2e.mock.mock_env import write_executable

PROJECT_ROOT = str(Path(__file__).resolve().parents[4])
BIN_DIR = os.path.join(PROJECT_ROOT, "bin")


class TestAsusScreenshotE2E(unittest.TestCase):
    """End-to-end tests for bin/asus-screenshot.sh."""

    def test_no_session_exit(self):
        """Test asus-screenshot.sh exits with code 1 when no active logind session is found."""
        script_path = os.path.join(BIN_DIR, "asus-screenshot.sh")
        with tempfile.TemporaryDirectory() as mock_bin_dir:
            loginctl_path = Path(mock_bin_dir) / "loginctl"
            write_executable(loginctl_path, "#!/bin/sh\nexit 0\n")

            env = dict(os.environ, PATH=f"{mock_bin_dir}:{os.environ.get('PATH', '')}")
            proc = run_e2e_command(["bash", script_path], env=env, timeout=20)
            self.assertEqual(proc.returncode, 1)
            self.assertIn("Error: No active graphical session found.", proc.stderr)


if __name__ == "__main__":
    unittest.main()
