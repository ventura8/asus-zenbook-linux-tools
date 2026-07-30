"""E2E tests matching bin/asus-touchpad-share.py."""

import os
import sys
import unittest
from pathlib import Path

from tests.e2e.e2e_utils import run_e2e_command
from tests.e2e.mock.bin.mock_helpers import build_pythonpath_env

PROJECT_ROOT = str(Path(__file__).resolve().parents[4])
BIN_DIR = os.path.join(PROJECT_ROOT, "bin")


class TestAsusTouchpadShareE2E(unittest.TestCase):
    """End-to-end tests for bin/asus-touchpad-share.py."""

    def test_touchpad_device_missing_exit(self):
        """Test asus-touchpad-share.py exits cleanly with code 1 when mock touchpad missing."""
        script_path = os.path.join(BIN_DIR, "asus-touchpad-share.py")
        env = build_pythonpath_env(PROJECT_ROOT)
        env["ASUS_EVDEV_DEVICE_ROOT"] = ""
        proc = run_e2e_command([sys.executable, script_path], env=env, timeout=25)
        self.assertEqual(proc.returncode, 1, "Expected exit code 1 for missing touchpad")
        self.assertIn("Error: No touchpad device found.", proc.stderr)


if __name__ == "__main__":
    unittest.main()
