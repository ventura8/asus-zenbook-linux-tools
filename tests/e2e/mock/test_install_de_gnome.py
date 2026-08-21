"""E2E tests for install.sh GNOME desktop integration."""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from tests.e2e.e2e_utils import PROJECT_ROOT, run_e2e_command
from tests.e2e.mock.mock_env import (
    MOCK_UID,
    build_install_mock_env,
    write_executable,
)

INSTALL_SCRIPT = os.path.join(PROJECT_ROOT, "install.sh")


class TestInstallGnomeDesktopE2E(unittest.TestCase):
    """End-to-end tests for GNOME desktop component installation."""

    def test_install_gnome_keybindings_and_backup(self):
        """Test install configures GNOME shortcuts and generates backup state."""
        with tempfile.TemporaryDirectory() as tmp:
            env, dest_dir, mock_bin = build_install_mock_env(tmp)
            env["NONINTERACTIVE_CHOICE"] = "DESKTOP"
            env["XDG_CURRENT_DESKTOP"] = "GNOME"

            recorded_commands = Path(tmp) / "gsettings_calls.log"
            write_executable(
                mock_bin / "gsettings",
                "#!/bin/sh\n"
                f'echo "$@" >> "{recorded_commands}"\n'
                'case "$1" in\n'
                "  list-keys)\n"
                '    case "$2" in\n'
                "      org.gnome.shell.keybindings) echo show-screenshot-ui ;;\n"
                "      org.gnome.settings-daemon.plugins.media-keys)\n"
                "        printf 'control-center\\ncustom-keybindings\\nswitch-video-mode\\n' ;;\n"
                "      org.gnome.mutter.keybindings) echo switch-monitor ;;\n"
                "      *) exit 1 ;;\n"
                "    esac ;;\n"
                '  get) echo "['"'"'<Super>p'"'"']" ;;\n'
                "  set|reset) exit 0 ;;\n"
                "esac\n"
                "exit 0\n",
            )

            proc = run_e2e_command(["bash", INSTALL_SCRIPT], env=env, timeout=25)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("Configure GNOME shortcuts", proc.stdout)

            self.assertTrue(recorded_commands.exists())
            calls_content = recorded_commands.read_text(encoding="utf-8")
            self.assertIn("org.gnome.settings-daemon.plugins.media-keys", calls_content)
            self.assertIn("org.gnome.shell.keybindings", calls_content)
            self.assertIn("set ", calls_content)

            state_dir = dest_dir / f"var/lib/asus-zenbook-linux-tools/{MOCK_UID}"
            self.assertTrue(state_dir.exists())
            self.assertEqual(
                (state_dir / "orig_show_screenshot_ui").read_text(encoding="utf-8").strip(),
                "['<Super>p']",
            )
            self.assertEqual(
                (state_dir / "orig_control_center").read_text(encoding="utf-8").strip(),
                "['<Super>p']",
            )
            self.assertEqual(
                (state_dir / "orig_switch_video_mode").read_text(encoding="utf-8").strip(),
                "['<Super>p']",
            )
            self.assertEqual(
                (state_dir / "orig_switch_monitor").read_text(encoding="utf-8").strip(),
                "['<Super>p']",
            )

    def test_install_gnome_fails_when_no_bus(self):
        """Test install fails with error code when requested DESKTOP cannot find session D-Bus."""
        with tempfile.TemporaryDirectory() as tmp:
            env, _dest_dir, _mock_bin = build_install_mock_env(tmp)
            env["NONINTERACTIVE_CHOICE"] = "DESKTOP"
            env["XDG_CURRENT_DESKTOP"] = "GNOME"
            env["DBUS_BUS_ROOT"] = str(Path(tmp) / "no-bus")

            proc = run_e2e_command(["bash", INSTALL_SCRIPT], env=env, timeout=25)
            self.assertEqual(proc.returncode, 1)
            self.assertIn("GNOME configuration failed: desktop D-Bus session not found", proc.stderr)


if __name__ == "__main__":
    unittest.main()
