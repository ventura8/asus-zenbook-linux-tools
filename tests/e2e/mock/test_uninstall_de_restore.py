"""E2E tests for uninstall.sh multi-desktop shortcut restoration."""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from tests.e2e.e2e_utils import PROJECT_ROOT, run_e2e_command
from tests.e2e.mock.mock_de_env import (
    build_cinnamon_mock_env,
    build_kde_mock_env,
    build_lxqt_mock_env,
    build_mate_mock_env,
    build_xfce_mock_env,
)
from tests.e2e.mock.mock_env import (
    MOCK_UID,
    install_uninstall_mock_systemctl,
    write_executable,
)

UNINSTALL_SCRIPT = os.path.join(PROJECT_ROOT, "uninstall.sh")


class TestUninstallDesktopRestoreE2E(unittest.TestCase):
    """End-to-end tests for uninstall.sh desktop shortcut restoration across DEs."""

    def test_restore_kde_shortcuts(self):
        """Test uninstall restores KDE shortcuts from backup directory."""
        with tempfile.TemporaryDirectory() as tmp:
            env, dest_dir, mock_bin, _home = build_kde_mock_env(tmp)
            install_uninstall_mock_systemctl(mock_bin)
            recorded_calls = Path(tmp) / "kwriteconfig_calls.log"
            write_executable(
                mock_bin / "kwriteconfig6",
                f'#!/bin/sh\necho "$@" >> "{recorded_calls}"\nexit 0\n',
            )

            state_dir = dest_dir / f"var/lib/asus-zenbook-linux-tools/{MOCK_UID}"
            kde_dir = state_dir / "kde"
            kde_dir.mkdir(parents=True, exist_ok=True)
            (state_dir / "desktop_family").write_text("kde\n", encoding="utf-8")
            (kde_dir / "kde_backend").write_text("kglobalshortcutsrc\n", encoding="utf-8")
            (kde_dir / "orig_kde_kscreen_launch").write_text("Meta+P,none,Switch Display\n", encoding="utf-8")
            (kde_dir / "orig_kde_kscreen_friendly").write_text("Switch Display\n", encoding="utf-8")

            proc = run_e2e_command(["bash", UNINSTALL_SCRIPT], env=env, timeout=25)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("cleanly uninstalled", proc.stdout)
            self.assertTrue(recorded_calls.exists())
            calls_content = recorded_calls.read_text(encoding="utf-8")
            self.assertIn("kscreen", calls_content)
            self.assertIn("Meta+P", calls_content)
            self.assertFalse((kde_dir / "orig_kde_kscreen_launch").exists())

    def test_restore_xfce_shortcuts(self):
        """Test uninstall restores XFCE shortcuts from backup directory."""
        with tempfile.TemporaryDirectory() as tmp:
            env, dest_dir, mock_bin, _home = build_xfce_mock_env(tmp)
            install_uninstall_mock_systemctl(mock_bin)
            recorded_calls = Path(tmp) / "xfconf_calls.log"
            write_executable(
                mock_bin / "xfconf-query",
                f'#!/bin/sh\necho "$@" >> "{recorded_calls}"\nexit 0\n',
            )

            state_dir = dest_dir / f"var/lib/asus-zenbook-linux-tools/{MOCK_UID}"
            state_dir.mkdir(parents=True, exist_ok=True)
            (state_dir / "desktop_family").write_text("xfce\n", encoding="utf-8")
            (state_dir / "target_user").write_text("mockuser\n", encoding="utf-8")
            (state_dir / "xfce_bus_path").write_text("/run/user/1000/bus\n", encoding="utf-8")
            (state_dir / "orig_xfce_xf86display").write_text("xfce4-display-settings\n", encoding="utf-8")
            (state_dir / "orig_xfce_super_f12").write_text("xfce4-settings-manager\n", encoding="utf-8")
            (state_dir / "orig_xfce_super_shift_s").write_text("xfce4-screenshooter\n", encoding="utf-8")

            proc = run_e2e_command(["bash", UNINSTALL_SCRIPT], env=env, timeout=25)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("cleanly uninstalled", proc.stdout)
            self.assertTrue(recorded_calls.exists())
            calls_content = recorded_calls.read_text(encoding="utf-8")
            self.assertIn("xfce4-display-settings", calls_content)
            self.assertFalse((state_dir / "orig_xfce_xf86display").exists())

    def test_restore_lxqt_shortcuts(self):
        """Test uninstall restores LXQt shortcuts from backup directory."""
        with tempfile.TemporaryDirectory() as tmp:
            env, dest_dir, mock_bin, home_dir = build_lxqt_mock_env(tmp)
            install_uninstall_mock_systemctl(mock_bin)
            state_dir = dest_dir / f"var/lib/asus-zenbook-linux-tools/{MOCK_UID}"
            state_dir.mkdir(parents=True, exist_ok=True)
            (state_dir / "desktop_family").write_text("lxqt\n", encoding="utf-8")
            (state_dir / "target_user").write_text("mockuser\n", encoding="utf-8")
            (state_dir / "orig_lxqt_xf86display.section").write_text("XF86Display.1\n", encoding="utf-8")
            orig_section = (
                "[XF86Display.1]\n"
                "Comment=Display Mode\n"
                "Enabled=true\n"
                "Exec=lxqt-config-monitor\n"
                "Shortcut=XF86Display\n"
            )
            (state_dir / "orig_lxqt_xf86display").write_text(orig_section, encoding="utf-8")

            proc = run_e2e_command(["bash", UNINSTALL_SCRIPT], env=env, timeout=25)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("cleanly uninstalled", proc.stdout)
            conf_dest = home_dir / ".config" / "lxqt" / "globalkeyshortcuts.conf"
            self.assertTrue(conf_dest.exists())
            self.assertIn("[XF86Display.1]", conf_dest.read_text(encoding="utf-8"))
            self.assertIn("Exec=lxqt-config-monitor", conf_dest.read_text(encoding="utf-8"))
            self.assertFalse((state_dir / "orig_lxqt_xf86display").exists())

    def test_restore_cinnamon_shortcuts(self):
        """Test uninstall restores Cinnamon shortcuts from backup directory."""
        with tempfile.TemporaryDirectory() as tmp:
            env, dest_dir, mock_bin, _home = build_cinnamon_mock_env(tmp)
            install_uninstall_mock_systemctl(mock_bin)
            recorded_calls = Path(tmp) / "cinnamon_gsettings.log"
            write_executable(
                mock_bin / "gsettings",
                f'#!/bin/sh\necho "$@" >> "{recorded_calls}"\nexit 0\n',
            )

            state_dir = dest_dir / f"var/lib/asus-zenbook-linux-tools/{MOCK_UID}"
            state_dir.mkdir(parents=True, exist_ok=True)
            (state_dir / "desktop_family").write_text("cinnamon\n", encoding="utf-8")
            (state_dir / "target_user").write_text("mockuser\n", encoding="utf-8")
            (state_dir / "orig_cinnamon_custom_list").write_text("['custom0']\n", encoding="utf-8")
            (state_dir / "orig_cinnamon_video_outputs").write_text("['<Super>p']\n", encoding="utf-8")
            slot_backup = (
                "binding=['XF86Display']\n"
                "command=cinnamon-settings display\n"
                "name=Display\n"
            )
            (state_dir / "orig_cinnamon_xf86display").write_text(slot_backup, encoding="utf-8")

            proc = run_e2e_command(["bash", UNINSTALL_SCRIPT], env=env, timeout=25)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("cleanly uninstalled", proc.stdout)
            self.assertTrue(recorded_calls.exists())
            calls_content = recorded_calls.read_text(encoding="utf-8")
            self.assertIn("set org.cinnamon.desktop.keybindings", calls_content)
            self.assertFalse((state_dir / "orig_cinnamon_xf86display").exists())

    def test_restore_mate_shortcuts(self):
        """Test uninstall restores MATE shortcuts from backup directory."""
        with tempfile.TemporaryDirectory() as tmp:
            env, dest_dir, mock_bin, _home = build_mate_mock_env(tmp)
            install_uninstall_mock_systemctl(mock_bin)
            recorded_calls = Path(tmp) / "mate_gsettings.log"
            write_executable(
                mock_bin / "gsettings",
                f'#!/bin/sh\necho "$@" >> "{recorded_calls}"\nexit 0\n',
            )

            state_dir = dest_dir / f"var/lib/asus-zenbook-linux-tools/{MOCK_UID}"
            state_dir.mkdir(parents=True, exist_ok=True)
            (state_dir / "desktop_family").write_text("mate\n", encoding="utf-8")
            (state_dir / "target_user").write_text("mockuser\n", encoding="utf-8")
            slot_backup = (
                "action=mate-display-properties\n"
                "binding=XF86Display\n"
                "name=Display\n"
            )
            (state_dir / "orig_mate_xf86display").write_text(slot_backup, encoding="utf-8")

            proc = run_e2e_command(["bash", UNINSTALL_SCRIPT], env=env, timeout=25)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("cleanly uninstalled", proc.stdout)
            self.assertTrue(recorded_calls.exists())
            calls_content = recorded_calls.read_text(encoding="utf-8")
            self.assertIn("set org.mate.control-center.keybinding", calls_content)
            self.assertFalse((state_dir / "orig_mate_xf86display").exists())


if __name__ == "__main__":
    unittest.main()
