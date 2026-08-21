"""E2E tests for install.sh KDE Plasma desktop integration."""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from tests.e2e.e2e_utils import PROJECT_ROOT, run_e2e_command
from tests.e2e.mock.mock_de_env import build_kde_mock_env
from tests.e2e.mock.mock_env import write_executable

INSTALL_SCRIPT = os.path.join(PROJECT_ROOT, "install.sh")


class TestInstallKdeDesktopE2E(unittest.TestCase):
    """End-to-end tests for KDE desktop component installation."""

    def test_install_kde_shortcuts_with_kwriteconfig(self):
        """Test install configures KDE shortcuts using kwriteconfig."""
        with tempfile.TemporaryDirectory() as tmp:
            env, _dest_dir, mock_bin, _home = build_kde_mock_env(tmp, has_kwriteconfig=True)
            env["NONINTERACTIVE_CHOICE"] = "DESKTOP"
            recorded_calls = Path(tmp) / "kwriteconfig_calls.log"

            write_executable(
                mock_bin / "kwriteconfig6",
                f'#!/bin/sh\necho "$@" >> "{recorded_calls}"\nexit 0\n',
            )

            proc = run_e2e_command(["bash", INSTALL_SCRIPT], env=env, timeout=25)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("Configure KDE Plasma shortcuts", proc.stdout)
            self.assertTrue(recorded_calls.exists())
            calls_content = recorded_calls.read_text(encoding="utf-8")
            self.assertIn("asus-display-mode.desktop", calls_content)
            self.assertIn("--file", calls_content)
            self.assertIn("kglobalshortcutsrc", calls_content)
            self.assertIn("--group", calls_content)
            self.assertIn("--key", calls_content)
            self.assertIn("_launch", calls_content)

    def test_install_kde_missing_bus_fails_closed(self):
        """Test install fails closed with error when session bus is missing."""
        with tempfile.TemporaryDirectory() as tmp:
            env, _dest_dir, _mock_bin, _home = build_kde_mock_env(tmp, has_kwriteconfig=True)
            env["NONINTERACTIVE_CHOICE"] = "DESKTOP"
            env["DBUS_BUS_ROOT"] = os.path.join(tmp, "no-bus")
            env["RUN_USER_ROOT"] = os.path.join(tmp, "no-bus")
            env["BUS_ROOT"] = os.path.join(tmp, "no-bus")

            proc = run_e2e_command(["bash", INSTALL_SCRIPT], env=env, timeout=25)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("desktop D-Bus session not found", proc.stderr + proc.stdout)


if __name__ == "__main__":
    unittest.main()
