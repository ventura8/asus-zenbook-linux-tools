"""E2E tests matching ScreenPad shell utilities."""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from tests.e2e.e2e_utils import run_e2e_command
from tests.e2e.mock.mock_env import (
    build_install_mock_env,
    write_executable,
)

PROJECT_ROOT = str(Path(__file__).resolve().parents[4])
SCREENPAD_TOGGLE_SCRIPT = os.path.join(PROJECT_ROOT, "bin", "asus-screenpad-toggle.sh")
SCREENPAD_BRIGHTNESS_SCRIPT = os.path.join(PROJECT_ROOT, "bin", "asus-screenpad-brightness.sh")


class TestAsusScreenPadE2E(unittest.TestCase):
    """End-to-end tests for ScreenPad toggle and brightness utilities."""

    def test_screenpad_brightness_get_and_set(self):
        """Test asus-screenpad-brightness.sh get and set commands with sysfs backlight."""
        with tempfile.TemporaryDirectory() as tmp:
            env, dest_dir, mock_bin = build_install_mock_env(tmp)
            backlight_dir = Path(tmp) / "sys" / "class" / "backlight" / "asus_screenpad"
            backlight_dir.mkdir(parents=True, exist_ok=True)
            brightness_node = backlight_dir / "brightness"
            max_brightness_node = backlight_dir / "max_brightness"

            brightness_node.write_text("100\n", encoding="utf-8")
            max_brightness_node.write_text("255\n", encoding="utf-8")

            state_dir = dest_dir / "var" / "lib" / "asus-zenbook-linux-tools"
            state_dir.mkdir(parents=True, exist_ok=True)
            notif_dir = Path(tmp) / "notif"
            notif_dir.mkdir(parents=True, exist_ok=True)

            env["SYS_CLASS_ROOT"] = str(Path(tmp) / "sys" / "class")
            env["STATE_DIR"] = str(state_dir)
            env["NOTIF_ID_ROOT"] = str(notif_dir)
            write_executable(mock_bin / "notify-send", "#!/bin/sh\nexit 0\n")

            proc_get = run_e2e_command(
                ["bash", SCREENPAD_BRIGHTNESS_SCRIPT, "get"],
                env=env,
                timeout=20,
            )
            self.assertEqual(proc_get.returncode, 0, proc_get.stderr)
            self.assertIn("100", proc_get.stdout)

            proc_set = run_e2e_command(
                ["bash", SCREENPAD_BRIGHTNESS_SCRIPT, "set", "150"],
                env=env,
                timeout=20,
            )
            self.assertEqual(proc_set.returncode, 0, proc_set.stderr)
            self.assertEqual(brightness_node.read_text(encoding="utf-8").strip(), "150")

    def test_screenpad_brightness_invalid_arg_exit(self):
        """Test asus-screenpad-brightness.sh exits with error when given invalid argument."""
        proc = run_e2e_command(["bash", SCREENPAD_BRIGHTNESS_SCRIPT, "invalid-arg"], timeout=20)
        self.assertEqual(proc.returncode, 1)


if __name__ == "__main__":
    unittest.main()
