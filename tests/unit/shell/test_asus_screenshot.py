"""Unit tests for bin/asus-screenshot.sh."""

import os
import shlex
import tempfile
import unittest
from pathlib import Path

from tests.unit.shell.shell_test_utils import (
    bin_script,
    bind_unix_socket,
    fake_id,
    fake_loginctl_active,
    fake_loginctl_no_sessions,
    fake_sudo_passthrough,
    run_shell_script,
    terminate_pid_file,
    write_fake_executable,
)

SCRIPT = bin_script("asus-screenshot.sh")

# UID used in all tests that need a fake user identity
_FAKE_UID = str(os.getuid())


def _fake_gdbus(mock_bin_path, exit_code=0, stderr_text=""):
    """Install a gdbus stub that exits with exit_code and optional stderr output."""
    stderr_write = f"echo {shlex.quote(stderr_text)} >&2\n" if stderr_text else ""
    write_fake_executable(
        os.path.join(mock_bin_path, "gdbus"),
        f"#!/bin/sh\n{stderr_write}exit {exit_code}\n",
    )


def _env_with_mock_bin(mock_bin_path):
    """Return an environment dictionary with mock_bin_path prepended to PATH."""
    return dict(os.environ, PATH=f"{mock_bin_path}:{os.environ.get('PATH', '')}")


def _env_with_bus_root(mock_bin_path, bus_root, **extra):
    """Build env with RUN_USER_ROOT and without legacy bus-root overrides."""
    env = dict(_env_with_mock_bin(mock_bin_path), RUN_USER_ROOT=bus_root, **extra)
    env.pop("BUS_ROOT", None)
    env.pop("DBUS_BUS_ROOT", None)
    return env


class TestAsusScreenshotUnit(unittest.TestCase):
    """Unit tests for bin/asus-screenshot.sh."""

    def test_no_session_exits_1(self):
        """Exits 1 with error when loginctl returns no sessions."""
        with tempfile.TemporaryDirectory() as mock_bin:
            fake_loginctl_no_sessions(mock_bin)
            proc = run_shell_script(SCRIPT, env=_env_with_mock_bin(mock_bin))
        self.assertEqual(proc.returncode, 1)
        self.assertIn("No active graphical session found", proc.stderr)

    def test_unknown_uid_exits_1(self):
        """Exits 1 when session user is not resolvable to a UID."""
        with tempfile.TemporaryDirectory() as mock_bin:
            fake_loginctl_active(mock_bin, session_details={"suser": "__no_such_user_xyz__"})
            proc = run_shell_script(SCRIPT, env=_env_with_mock_bin(mock_bin))
        self.assertEqual(proc.returncode, 1)
        self.assertIn("Could not determine UID", proc.stderr)

    def test_no_bus_socket_exits_1(self):
        """Exits 1 when session and UID are found but D-Bus socket is absent."""
        with (
            tempfile.TemporaryDirectory() as mock_bin,
            tempfile.TemporaryDirectory() as bus_root,
        ):
            fake_loginctl_active(mock_bin)
            fake_id(mock_bin, uid=_FAKE_UID)
            env = _env_with_bus_root(mock_bin, bus_root)
            proc = run_shell_script(SCRIPT, env=env)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("D-Bus socket", proc.stderr)

    def test_gdbus_success_exits_0(self):
        """Exits 0 when session, UID, bus socket, and gdbus all succeed."""
        with (
            tempfile.TemporaryDirectory() as mock_bin,
            tempfile.TemporaryDirectory() as bus_root,
        ):
            fake_loginctl_active(mock_bin)
            fake_id(mock_bin, uid=_FAKE_UID)
            _fake_gdbus(mock_bin, exit_code=0)
            fake_sudo_passthrough(mock_bin)
            bus_path = Path(bus_root) / _FAKE_UID / "bus"
            bus_path.parent.mkdir(parents=True, exist_ok=True)
            bind_unix_socket(bus_path)
            env = _env_with_bus_root(
                mock_bin,
                bus_root,
                ASUS_DESKTOP_FAMILY="gnome",
            )
            proc = run_shell_script(SCRIPT, env=env)
        self.assertEqual(proc.returncode, 0)

    def test_gdbus_failure_exits_nonzero_and_reports_error(self):
        """Exits non-zero when the GNOME screenshot gdbus request fails."""
        with (
            tempfile.TemporaryDirectory() as mock_bin,
            tempfile.TemporaryDirectory() as bus_root,
        ):
            fake_loginctl_active(mock_bin)
            fake_id(mock_bin, uid=_FAKE_UID)
            _fake_gdbus(mock_bin, exit_code=2, stderr_text="gdbus failed")
            fake_sudo_passthrough(mock_bin)
            bus_path = Path(bus_root) / _FAKE_UID / "bus"
            bus_path.parent.mkdir(parents=True, exist_ok=True)
            bind_unix_socket(bus_path)
            env = _env_with_bus_root(
                mock_bin,
                bus_root,
                ASUS_DESKTOP_FAMILY="gnome",
                ASUS_SCREENSHOT_DISABLE_KEYCHORD="1",
            )
            proc = run_shell_script(SCRIPT, env=env)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("gdbus failed", proc.stderr)

    def test_ydotool_success_does_not_reopen_via_gdbus(self):
        """Successful ydotool chord must not call ShowScreenshotUI again (Esc reopen bug)."""
        with (
            tempfile.TemporaryDirectory() as mock_bin,
            tempfile.TemporaryDirectory() as bus_root,
            tempfile.TemporaryDirectory() as log_dir,
        ):
            fake_loginctl_active(mock_bin)
            fake_id(mock_bin, uid=_FAKE_UID)
            fake_sudo_passthrough(mock_bin)
            gdbus_log = Path(log_dir) / "gdbus.log"
            write_fake_executable(
                os.path.join(mock_bin, "gdbus"),
                f"#!/bin/sh\nprintf '%s\\n' \"$*\" >> {shlex.quote(str(gdbus_log))}\nexit 1\n",
            )
            write_fake_executable(
                os.path.join(mock_bin, "ydotool"),
                "#!/bin/sh\nexit 0\n",
            )
            write_fake_executable(
                os.path.join(mock_bin, "systemctl"),
                "#!/bin/sh\nexit 0\n",
            )
            write_fake_executable(
                os.path.join(mock_bin, "gsettings"),
                "#!/bin/sh\necho \"['<Print>']\"\nexit 0\n",
            )
            bus_path = Path(bus_root) / _FAKE_UID / "bus"
            bus_path.parent.mkdir(parents=True, exist_ok=True)
            bind_unix_socket(bus_path)
            ydotool_sock = Path(bus_root) / _FAKE_UID / ".ydotool_socket"
            bind_unix_socket(ydotool_sock)
            env = _env_with_bus_root(mock_bin, bus_root, ASUS_DESKTOP_FAMILY="gnome")
            proc = run_shell_script(SCRIPT, env=env)
            self.assertEqual(proc.returncode, 0)
            gdbus_text = gdbus_log.read_text(encoding="utf-8") if gdbus_log.is_file() else ""
            # Initial D-Bus attempts only — never re-open via ShowScreenshotUI after ydotool.
            self.assertEqual(gdbus_text.count("ShowScreenshotUI"), 1)
            self.assertEqual(gdbus_text.count("InteractiveScreenshot"), 1)

    def test_desktop_launcher_success_exits_0(self):
        """DE fallback launchers exit 0 when the stub stays alive past launch check."""
        cases = (
            ("spectacle", "kde"),
            ("screengrab", "lxqt"),
            ("gnome-screenshot", "cinnamon"),
            ("mate-screenshot", "mate"),
        )
        for stub_binary, family in cases:
            with (
                self.subTest(stub_binary=stub_binary, family=family),
                tempfile.TemporaryDirectory() as mock_bin,
                tempfile.TemporaryDirectory() as bus_root,
            ):
                fake_loginctl_active(mock_bin)
                fake_id(mock_bin, uid=_FAKE_UID)
                fake_sudo_passthrough(mock_bin)
                pid_file = os.path.join(bus_root, f"{stub_binary}.pid")
                write_fake_executable(
                    os.path.join(mock_bin, stub_binary),
                    f"#!/bin/sh\necho $$ > {shlex.quote(pid_file)}\nexec sleep 30\n",
                )
                bus_path = Path(bus_root) / _FAKE_UID / "bus"
                bus_path.parent.mkdir(parents=True, exist_ok=True)
                bind_unix_socket(bus_path)
                env = _env_with_bus_root(
                    mock_bin,
                    bus_root,
                    ASUS_DESKTOP_FAMILY=family,
                    ASUS_LAUNCH_CHECK_SECS="0.05",
                )
                try:
                    proc = run_shell_script(SCRIPT, env=env, timeout=15)
                finally:
                    terminate_pid_file(pid_file)
                self.assertEqual(proc.returncode, 0)


if __name__ == "__main__":
    unittest.main()
