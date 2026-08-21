"""E2E tests matching bin/asus-camera-toggle.sh and bin/asus-fan-toggle.sh."""

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
CAMERA_SCRIPT = os.path.join(PROJECT_ROOT, "bin", "asus-camera-toggle.sh")
FAN_SCRIPT = os.path.join(PROJECT_ROOT, "bin", "asus-fan-toggle.sh")


class TestAsusCameraFanToggleE2E(unittest.TestCase):
    """End-to-end tests for camera and fan toggles."""

    def test_camera_toggle_state_transition(self):
        """Test asus-camera-toggle.sh toggles state from 0 to 1 and notifies."""
        with tempfile.TemporaryDirectory() as tmp:
            env, _dest_dir, mock_bin = build_install_mock_env(tmp)
            sys_platform = Path(tmp) / "sys" / "devices" / "platform" / "asus-nb-wmi"
            sys_platform.mkdir(parents=True, exist_ok=True)
            cam_node = sys_platform / "camera"
            cam_node.write_text("0\n", encoding="utf-8")

            recorded_notifications = Path(tmp) / "notify.log"
            write_executable(
                mock_bin / "notify-send",
                f'#!/bin/sh\necho "$@" >> "{recorded_notifications}"\nexit 0\n',
            )

            env["SYS_PLATFORM_ROOT"] = str(Path(tmp) / "sys" / "devices" / "platform")

            proc = run_e2e_command(["bash", CAMERA_SCRIPT], env=env, timeout=25)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(cam_node.read_text(encoding="utf-8").strip(), "1")
            self.assertTrue(recorded_notifications.exists())

    def test_camera_toggle_missing_node_exit(self):
        """Test asus-camera-toggle.sh exits with code 1 when camera sysfs node is missing."""
        with tempfile.TemporaryDirectory() as tmp:
            env, _dest_dir, _mock_bin = build_install_mock_env(tmp)
            env["SYS_PLATFORM_ROOT"] = str(Path(tmp) / "nonexistent")

            proc = run_e2e_command(["bash", CAMERA_SCRIPT], env=env, timeout=20)
            self.assertEqual(proc.returncode, 1)

    def test_fan_toggle_policy_cycle(self):
        """Test asus-fan-toggle.sh cycles throttle_thermal_policy from 0 to 1 and notifies."""
        with tempfile.TemporaryDirectory() as tmp:
            env, _dest_dir, mock_bin = build_install_mock_env(tmp)
            sys_platform = Path(tmp) / "sys" / "devices" / "platform" / "asus-nb-wmi"
            sys_platform.mkdir(parents=True, exist_ok=True)
            fan_node = sys_platform / "throttle_thermal_policy"
            fan_node.write_text("0\n", encoding="utf-8")

            recorded_notifications = Path(tmp) / "fan_notify.log"
            write_executable(
                mock_bin / "notify-send",
                f'#!/bin/sh\necho "$@" >> "{recorded_notifications}"\nexit 0\n',
            )

            env["SYS_PLATFORM_ROOT"] = str(Path(tmp) / "sys" / "devices" / "platform")
            env["ASUS_FAN_USE_PPD"] = "0"

            proc = run_e2e_command(["bash", FAN_SCRIPT], env=env, timeout=25)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(fan_node.read_text(encoding="utf-8").strip(), "1")
            self.assertTrue(recorded_notifications.exists())


if __name__ == "__main__":
    unittest.main()
