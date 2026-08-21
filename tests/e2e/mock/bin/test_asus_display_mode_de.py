"""E2E tests matching bin/asus-display-mode.sh across all supported desktop environments."""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from tests.e2e.e2e_utils import run_e2e_command
from tests.e2e.mock.mock_de_env import (
    build_cinnamon_mock_env,
    build_kde_mock_env,
    build_lxqt_mock_env,
    build_mate_mock_env,
    build_xfce_mock_env,
)
from tests.e2e.mock.mock_env import (
    build_install_mock_env,
    write_executable,
)

PROJECT_ROOT = str(Path(__file__).resolve().parents[4])
DISPLAY_MODE_SCRIPT = os.path.join(PROJECT_ROOT, "bin", "asus-display-mode.sh")


class TestAsusDisplayModeMultiDEE2E(unittest.TestCase):
    """End-to-end tests for bin/asus-display-mode.sh across desktop environments."""

    def test_cancel_osd_flag(self):
        """Test asus-display-mode.sh --cancel-osd executes cleanly without active session."""
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, NOTIF_ID_ROOT=str(Path(tmp) / "notif"))
            proc = run_e2e_command(["bash", DISPLAY_MODE_SCRIPT, "--cancel-osd"], env=env, timeout=20)
            self.assertEqual(proc.returncode, 0)

    def test_kde_display_settings_fallback(self):
        """Test asus-display-mode.sh falls back to systemsettings kcm_kscreen on KDE."""
        with tempfile.TemporaryDirectory() as tmp:
            env, _dest_dir, mock_bin, _home = build_kde_mock_env(tmp)
            env["NOTIF_ID_ROOT"] = str(Path(tmp) / "notif")
            env["ASUS_DISPLAY_MODE_DISABLE_YDOTOOL"] = "1"
            env["ASUS_DISPLAY_MODE_DISABLE_XDOTOOL"] = "1"
            recorded_calls = Path(tmp) / "kscreen_calls.log"

            write_executable(
                mock_bin / "systemsettings",
                f'#!/bin/sh\necho "$@" >> "{recorded_calls}"\nexit 0\n',
            )

            proc = run_e2e_command(["bash", DISPLAY_MODE_SCRIPT], env=env, timeout=25)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertTrue(recorded_calls.exists())
            content = recorded_calls.read_text(encoding="utf-8")
            self.assertIn("kcm_kscreen", content)

    def test_xfce_display_settings_fallback(self):
        """Test asus-display-mode.sh falls back to xfce4-display-settings on XFCE."""
        with tempfile.TemporaryDirectory() as tmp:
            env, _dest_dir, mock_bin, _home = build_xfce_mock_env(tmp)
            env["NOTIF_ID_ROOT"] = str(Path(tmp) / "notif")
            env["ASUS_DISPLAY_MODE_DISABLE_YDOTOOL"] = "1"
            env["ASUS_DISPLAY_MODE_DISABLE_XDOTOOL"] = "1"
            recorded_calls = Path(tmp) / "xfce_calls.log"

            write_executable(
                mock_bin / "xfce4-display-settings",
                f'#!/bin/sh\necho "$@" >> "{recorded_calls}"\nexit 0\n',
            )

            proc = run_e2e_command(["bash", DISPLAY_MODE_SCRIPT], env=env, timeout=25)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertTrue(recorded_calls.exists())

    def test_lxqt_display_settings_fallback(self):
        """Test asus-display-mode.sh falls back to lxqt-config-monitor on LXQt."""
        with tempfile.TemporaryDirectory() as tmp:
            env, _dest_dir, mock_bin, _home = build_lxqt_mock_env(tmp)
            env["NOTIF_ID_ROOT"] = str(Path(tmp) / "notif")
            env["ASUS_DISPLAY_MODE_DISABLE_YDOTOOL"] = "1"
            env["ASUS_DISPLAY_MODE_DISABLE_XDOTOOL"] = "1"
            recorded_calls = Path(tmp) / "lxqt_calls.log"

            write_executable(
                mock_bin / "lxqt-config-monitor",
                f'#!/bin/sh\necho "$@" >> "{recorded_calls}"\nexit 0\n',
            )

            proc = run_e2e_command(["bash", DISPLAY_MODE_SCRIPT], env=env, timeout=25)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertTrue(recorded_calls.exists())

    def test_cinnamon_display_settings_fallback(self):
        """Test asus-display-mode.sh falls back to cinnamon-settings display on Cinnamon."""
        with tempfile.TemporaryDirectory() as tmp:
            env, _dest_dir, mock_bin, _home = build_cinnamon_mock_env(tmp)
            env["NOTIF_ID_ROOT"] = str(Path(tmp) / "notif")
            env["ASUS_DISPLAY_MODE_DISABLE_YDOTOOL"] = "1"
            env["ASUS_DISPLAY_MODE_DISABLE_XDOTOOL"] = "1"
            recorded_calls = Path(tmp) / "cinnamon_calls.log"

            write_executable(
                mock_bin / "cinnamon-settings",
                f'#!/bin/sh\necho "$@" >> "{recorded_calls}"\nexit 0\n',
            )

            proc = run_e2e_command(["bash", DISPLAY_MODE_SCRIPT], env=env, timeout=25)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertTrue(recorded_calls.exists())
            self.assertIn("display", recorded_calls.read_text(encoding="utf-8"))

    def test_mate_display_settings_fallback(self):
        """Test asus-display-mode.sh falls back to mate-display-properties on MATE."""
        with tempfile.TemporaryDirectory() as tmp:
            env, _dest_dir, mock_bin, _home = build_mate_mock_env(tmp)
            env["NOTIF_ID_ROOT"] = str(Path(tmp) / "notif")
            env["ASUS_DISPLAY_MODE_DISABLE_YDOTOOL"] = "1"
            env["ASUS_DISPLAY_MODE_DISABLE_XDOTOOL"] = "1"
            recorded_calls = Path(tmp) / "mate_calls.log"

            write_executable(
                mock_bin / "mate-display-properties",
                f'#!/bin/sh\necho "$@" >> "{recorded_calls}"\nexit 0\n',
            )

            proc = run_e2e_command(["bash", DISPLAY_MODE_SCRIPT], env=env, timeout=25)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertTrue(recorded_calls.exists())

    def test_gnome_display_settings_fallback(self):
        """Test asus-display-mode.sh falls back to gnome-control-center display on GNOME."""
        with tempfile.TemporaryDirectory() as tmp:
            env, _dest_dir, mock_bin = build_install_mock_env(tmp)
            env["NOTIF_ID_ROOT"] = str(Path(tmp) / "notif")
            env["XDG_CURRENT_DESKTOP"] = "GNOME"
            env["ASUS_DISPLAY_MODE_DISABLE_YDOTOOL"] = "1"
            env["ASUS_DISPLAY_MODE_DISABLE_XDOTOOL"] = "1"
            recorded_calls = Path(tmp) / "gnome_calls.log"

            write_executable(
                mock_bin / "gnome-control-center",
                f'#!/bin/sh\necho "$@" >> "{recorded_calls}"\nexit 0\n',
            )

            proc = run_e2e_command(["bash", DISPLAY_MODE_SCRIPT], env=env, timeout=25)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertTrue(recorded_calls.exists())
            self.assertIn("display", recorded_calls.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
