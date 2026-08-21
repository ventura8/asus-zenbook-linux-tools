"""E2E tests matching bin/asus-hotkey-daemon.py across desktop environments."""

from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path

from tests.e2e.e2e_utils import run_e2e_command
from tests.e2e.mock.bin.mock_helpers import build_pythonpath_env

PROJECT_ROOT = str(Path(__file__).resolve().parents[4])
HOTKEY_DAEMON_SCRIPT = os.path.join(PROJECT_ROOT, "bin", "asus-hotkey-daemon.py")


class TestAsusHotkeyDaemonMultiDEE2E(unittest.TestCase):
    """End-to-end tests for bin/asus-hotkey-daemon.py across desktop environments."""

    def _verify_daemon_de_family(self, de_name: str) -> None:
        """Helper to run hotkey daemon under a specified DE environment."""
        env = build_pythonpath_env(PROJECT_ROOT)
        env["ASUS_EVDEV_DEVICE_ROOT"] = ""
        env["XDG_CURRENT_DESKTOP"] = de_name
        proc = run_e2e_command([sys.executable, HOTKEY_DAEMON_SCRIPT], env=env, timeout=25)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("Asus WMI hotkeys device not found!", proc.stderr)

    def test_daemon_missing_device_exit(self):
        """Test asus-hotkey-daemon.py exits with error when WMI device is not found."""
        env = build_pythonpath_env(PROJECT_ROOT)
        env["ASUS_EVDEV_DEVICE_ROOT"] = ""
        proc = run_e2e_command([sys.executable, HOTKEY_DAEMON_SCRIPT], env=env, timeout=25)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("Asus WMI hotkeys device not found!", proc.stderr)

    def test_daemon_de_family_kde(self):
        """Test hotkey daemon environment handling on KDE Plasma."""
        self._verify_daemon_de_family("KDE")

    def test_daemon_de_family_xfce(self):
        """Test hotkey daemon environment handling on XFCE."""
        self._verify_daemon_de_family("XFCE")

    def test_daemon_de_family_lxqt(self):
        """Test hotkey daemon environment handling on LXQt."""
        self._verify_daemon_de_family("LXQt")

    def test_daemon_de_family_cinnamon(self):
        """Test hotkey daemon environment handling on Cinnamon."""
        self._verify_daemon_de_family("Cinnamon")

    def test_daemon_de_family_mate(self):
        """Test hotkey daemon environment handling on MATE."""
        self._verify_daemon_de_family("MATE")

    def test_daemon_de_family_gnome(self):
        """Test hotkey daemon environment handling on GNOME."""
        self._verify_daemon_de_family("GNOME")


if __name__ == "__main__":
    unittest.main()
