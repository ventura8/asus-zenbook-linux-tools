"""E2E tests matching bin/asus-touchpad-share.py across desktop environments."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

from tests.e2e.e2e_utils import run_e2e_command
from tests.e2e.mock.bin.mock_helpers import build_pythonpath_env
from tests.e2e.mock.mock_env import write_executable

PROJECT_ROOT = str(Path(__file__).resolve().parents[4])
TOUCHPAD_SCRIPT = os.path.join(PROJECT_ROOT, "bin", "asus-touchpad-share.py")


class TestAsusTouchpadShareMultiDEE2E(unittest.TestCase):
    """End-to-end tests for bin/asus-touchpad-share.py across desktop environments."""

    def test_missing_touchpad_device_exit(self):
        """Test asus-touchpad-share.py exits cleanly when no touchpad device is found."""
        env = build_pythonpath_env(PROJECT_ROOT)
        env["ASUS_EVDEV_DEVICE_ROOT"] = ""
        proc = run_e2e_command([sys.executable, TOUCHPAD_SCRIPT], env=env, timeout=25)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("Error: No touchpad device found.", proc.stderr)

    def test_touchpad_share_helper_dispatch(self):
        """Test asus-touchpad-share.py resolves and dispatches asus-screenshot.sh."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            recorded_calls = Path(tmp_dir) / "screenshot_called.log"
            mock_helper = Path(tmp_dir) / "mock-screenshot.sh"
            write_executable(mock_helper, f'#!/bin/sh\necho "called" >> "{recorded_calls}"\nexit 0\n')

            env = build_pythonpath_env(PROJECT_ROOT)
            env["PYTHONPATH"] = f"{os.path.join(PROJECT_ROOT, 'bin')}:{env.get('PYTHONPATH', '')}"
            env["ASUS_SCREENSHOT_HELPER"] = str(mock_helper)

            cmd = [
                sys.executable,
                "-c",
                (
                    "import asus_touchpad_share; "
                    "helper = asus_touchpad_share._screenshot_helper_path(); "
                    "asus_touchpad_share._run_screenshot_helper(helper)"
                ),
            ]
            proc = run_e2e_command(cmd, env=env, timeout=25)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertTrue(recorded_calls.exists())
            self.assertIn("called", recorded_calls.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
