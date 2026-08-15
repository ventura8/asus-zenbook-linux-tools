"""Unit tests for bin/asus-control-center.sh."""

import os
import shutil
import tempfile
import time
import unittest
from pathlib import Path

from tests.unit.shell.shell_test_utils import (
    bin_script,
    bind_unix_socket,
    fake_id,
    fake_loginctl_active,
    fake_sudo_passthrough,
    run_shell_script,
    terminate_pid_file,
    write_fake_executable,
)

SCRIPT = bin_script("asus-control-center.sh")

_MOCK_USER_ID = str(os.getuid())


class TestAsusControlCenterUnit(unittest.TestCase):
    """Unit test suite for asus-control-center.sh helper script."""

    def _install_sleep_stub(self, name: str) -> None:
        """Install a long-lived settings stub and register PID cleanup."""
        pid_file = os.path.join(self.tmp_dir, f"{name}.pid")
        write_fake_executable(
            os.path.join(self.mock_bin, name),
            f"#!/bin/sh\necho $$ > '{pid_file}'\nexec sleep 30\n",
        )
        self.addCleanup(terminate_pid_file, pid_file)

    def setUp(self):
        """Create isolated fake session tooling and environment for control-center tests."""
        self.tmp_dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp_dir, ignore_errors=True)
        self.mock_bin = os.path.join(self.tmp_dir, "bin")
        os.makedirs(self.mock_bin, exist_ok=True)

        fake_id(self.mock_bin, uid=_MOCK_USER_ID)
        fake_sudo_passthrough(self.mock_bin)
        self._install_sleep_stub("gnome-control-center")
        self._install_sleep_stub("systemsettings")
        write_fake_executable(
            os.path.join(self.mock_bin, "systemsettings5"),
            "#!/bin/sh\nexit 1\n",
        )
        write_fake_executable(
            os.path.join(self.mock_bin, "xfce4-settings-manager"),
            "#!/bin/sh\nexit 1\n",
        )
        self._install_sleep_stub("lxqt-config")
        write_fake_executable(
            os.path.join(self.mock_bin, "systemctl"),
            "#!/bin/sh\nexit 0\n",
        )

        user_dir = os.path.join(self.tmp_dir, _MOCK_USER_ID)
        os.makedirs(user_dir, exist_ok=True)
        bus_path = os.path.join(user_dir, "bus")
        if os.path.exists(bus_path):
            os.unlink(bus_path)
        self.sock = bind_unix_socket(Path(bus_path), listen=1)
        self.assertIsNotNone(self.sock)
        self.addCleanup(self.sock.close)

        self.env = os.environ.copy()
        # Keep core utils but prefer mocks over real DE settings binaries.
        self.env["PATH"] = f"{self.mock_bin}:/usr/bin:/bin"
        self.env["RUN_USER_ROOT"] = self.tmp_dir
        self.env["ASUS_LAUNCH_CHECK_SECS"] = "0.05"
        self.env["ASUS_DESKTOP_FAMILY"] = "gnome"
        self.env.pop("BUS_ROOT", None)
        self.env.pop("DBUS_BUS_ROOT", None)

    def test_main_no_session_fails(self):
        """Verify script failure when no graphical session exists."""
        write_fake_executable(
            os.path.join(self.mock_bin, "loginctl"),
            "#!/bin/sh\nexit 0\n",
        )
        res = run_shell_script(SCRIPT, env=self.env)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("No active graphical session found", res.stderr)

    def test_main_success(self):
        """Verify successful launch when session and bus socket are ready."""
        fake_loginctl_active(self.mock_bin)
        gdbus_log = os.path.join(self.tmp_dir, "gdbus.log")
        write_fake_executable(
            os.path.join(self.mock_bin, "gdbus"),
            f'#!/bin/sh\necho "$@" >> "{gdbus_log}"\nexit 0\n',
        )
        res = run_shell_script(SCRIPT, env=self.env)
        self.assertEqual(res.returncode, 0)
        with open(gdbus_log, encoding="utf-8") as handle:
            logged = handle.read()
        self.assertIn("org.gnome.Settings", logged)
        self.assertIn("org.freedesktop.Application.Activate", logged)

    def test_no_bus_socket_fails(self):
        """Verify failure when DBUS bus socket is absent."""
        fake_loginctl_active(self.mock_bin)
        env = self.env.copy()
        env["RUN_USER_ROOT"] = os.path.join(self.tmp_dir, "nonexistent")
        res = run_shell_script(SCRIPT, env=env)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("D-Bus session socket not found", res.stderr)

    def test_gdbus_failure_fallback_success(self):
        """Verify fallback to settings app executable when gdbus fails."""
        fake_loginctl_active(self.mock_bin)
        write_fake_executable(
            os.path.join(self.mock_bin, "gdbus"),
            "#!/bin/sh\nexit 1\n",
        )
        pid_file = os.path.join(self.tmp_dir, "gnome-control-center.pid")
        res = run_shell_script(SCRIPT, env=self.env)
        self.assertEqual(res.returncode, 0)
        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline and not os.path.isfile(pid_file):
            time.sleep(0.05)
        self.assertTrue(os.path.isfile(pid_file), msg="settings-app stub PID file missing")
        with open(pid_file, encoding="utf-8") as handle:
            pid_text = handle.read().strip()
        self.assertTrue(pid_text.isdigit(), msg=f"invalid settings stub PID: {pid_text!r}")

    def test_launch_failure_propagates_nonzero(self):
        """Verify launch failure returns non-zero when gdbus and fallback fail."""
        fake_loginctl_active(self.mock_bin)
        write_fake_executable(
            os.path.join(self.mock_bin, "gdbus"),
            "#!/bin/sh\nexit 1\n",
        )
        write_fake_executable(
            os.path.join(self.mock_bin, "gnome-control-center"),
            "#!/bin/sh\nexit 1\n",
        )
        write_fake_executable(
            os.path.join(self.mock_bin, "systemsettings"),
            "#!/bin/sh\nexit 1\n",
        )
        write_fake_executable(
            os.path.join(self.mock_bin, "xfce4-settings-manager"),
            "#!/bin/sh\nexit 1\n",
        )
        write_fake_executable(
            os.path.join(self.mock_bin, "lxqt-config"),
            "#!/bin/sh\nexit 1\n",
        )
        # Stub sh so _run_as_user's `sh -c command -v` probe fails before gio launch.
        write_fake_executable(
            os.path.join(self.mock_bin, "sh"),
            ('#!/bin/sh\nif [ "$1" = "-c" ] && printf "%s" "$2" | grep -q "command -v"; then\n  exit 1\nfi\nexec /bin/sh "$@"\n'),
        )
        write_fake_executable(
            os.path.join(self.mock_bin, "gio"),
            "#!/bin/sh\nexit 1\n",
        )
        desktop_dir = os.path.join(self.tmp_dir, "desktop")
        os.makedirs(desktop_dir, exist_ok=True)
        with open(os.path.join(desktop_dir, "org.gnome.Settings.desktop"), "w", encoding="utf-8") as handle:
            handle.write("[Desktop Entry]\nName=Settings\n")
        env = self.env.copy()
        env["DESKTOP_DIR"] = desktop_dir
        res = run_shell_script(SCRIPT, env=env)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Error: gio launch failed for", res.stderr)

    def test_lxqt_skips_gdbus_activate_and_launches_lxqt_config(self):
        """LXQt must skip GNOME Activate and launch lxqt-config."""
        fake_loginctl_active(self.mock_bin)
        gdbus_log = os.path.join(self.tmp_dir, "gdbus.log")
        write_fake_executable(
            os.path.join(self.mock_bin, "gdbus"),
            f'#!/bin/sh\necho "$@" >> "{gdbus_log}"\nexit 0\n',
        )
        env = self.env.copy()
        env["ASUS_DESKTOP_FAMILY"] = "lxqt"
        pid_file = os.path.join(self.tmp_dir, "lxqt-config.pid")
        res = run_shell_script(SCRIPT, env=env)
        self.assertEqual(res.returncode, 0)
        if os.path.isfile(gdbus_log):
            with open(gdbus_log, encoding="utf-8") as handle:
                logged = handle.read()
            self.assertNotIn("org.freedesktop.Application.Activate", logged)
        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline and not os.path.isfile(pid_file):
            time.sleep(0.05)
        self.assertTrue(os.path.isfile(pid_file), msg="lxqt-config stub PID file missing")

    def test_cinnamon_skips_gdbus_activate_and_launches_cinnamon_settings(self):
        """Cinnamon must skip GNOME Activate and launch cinnamon-settings."""
        fake_loginctl_active(self.mock_bin)
        gdbus_log = os.path.join(self.tmp_dir, "gdbus.log")
        write_fake_executable(
            os.path.join(self.mock_bin, "gdbus"),
            f'#!/bin/sh\necho "$@" >> "{gdbus_log}"\nexit 0\n',
        )
        self._install_sleep_stub("cinnamon-settings")
        env = self.env.copy()
        env["ASUS_DESKTOP_FAMILY"] = "cinnamon"
        pid_file = os.path.join(self.tmp_dir, "cinnamon-settings.pid")
        res = run_shell_script(SCRIPT, env=env)
        self.assertEqual(res.returncode, 0)
        if os.path.isfile(gdbus_log):
            with open(gdbus_log, encoding="utf-8") as handle:
                logged = handle.read()
            self.assertNotIn("org.freedesktop.Application.Activate", logged)
        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline and not os.path.isfile(pid_file):
            time.sleep(0.05)
        self.assertTrue(os.path.isfile(pid_file), msg="cinnamon-settings stub PID file missing")

    def test_mate_skips_gdbus_activate_and_launches_mate_control_center(self):
        """MATE must skip GNOME Activate and launch mate-control-center."""
        fake_loginctl_active(self.mock_bin)
        gdbus_log = os.path.join(self.tmp_dir, "gdbus.log")
        write_fake_executable(
            os.path.join(self.mock_bin, "gdbus"),
            f'#!/bin/sh\necho "$@" >> "{gdbus_log}"\nexit 0\n',
        )
        self._install_sleep_stub("mate-control-center")
        env = self.env.copy()
        env["ASUS_DESKTOP_FAMILY"] = "mate"
        pid_file = os.path.join(self.tmp_dir, "mate-control-center.pid")
        res = run_shell_script(SCRIPT, env=env)
        self.assertEqual(res.returncode, 0)
        if os.path.isfile(gdbus_log):
            with open(gdbus_log, encoding="utf-8") as handle:
                logged = handle.read()
            self.assertNotIn("org.freedesktop.Application.Activate", logged)
        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline and not os.path.isfile(pid_file):
            time.sleep(0.05)
        self.assertTrue(os.path.isfile(pid_file), msg="mate-control-center stub PID file missing")


if __name__ == "__main__":
    unittest.main()
