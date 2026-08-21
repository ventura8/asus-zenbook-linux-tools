"""Unit tests for uninstall.sh uninstaller script."""

import os
import shlex
import shutil
import tempfile
import unittest
from pathlib import Path

from tests.unit.shell.shell_test_utils import (
    assert_shell_source_smoke,
    fake_id,
    fake_loginctl_no_sessions,
    run_shell_script,
    setup_mock_install_tree,
    write_stubs,
)

_DPKG_QUERY_INSTALLED_STUB = '#!/bin/sh\nif [ "$1" = "-W" ]; then\n  printf \'installed\\n\'\n  exit 0\nfi\nexit 0\n'


class TestUninstallScriptUnit(unittest.TestCase):
    """Unit tests exercising uninstall.sh execution paths."""

    SCRIPT_PATH = Path(__file__).resolve().parents[3] / "uninstall.sh"

    def _mock_bin_path(self):
        """Return the mock-bin directory under the temp fixture root."""
        return Path(self.tmp_dir) / "mock-bin"

    def _systemctl_path(self):
        """Return the systemctl stub path inside mock-bin."""
        return self._mock_bin_path() / "systemctl"

    def setUp(self):
        """Stage DESTDIR tree, mock systemctl, and minimal installed payload files."""
        self.tmp_dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp_dir, True)
        self.dest_dir, self.bin_dir, self.sys_dir, self.hook_dir = setup_mock_install_tree(self.tmp_dir)
        for path in (self.dest_dir, self.bin_dir, self.sys_dir, self.hook_dir):
            path.mkdir(parents=True, exist_ok=True)
        self.lib_dir = self.dest_dir / "usr/local/lib/asus-zenbook-linux-tools"
        self.lib_dir.mkdir(parents=True, exist_ok=True)
        self.state_dir = self.dest_dir / "var/lib/asus-zenbook-linux-tools"
        self.state_dir.mkdir(parents=True, exist_ok=True)

        (self.bin_dir / "asus-hotkey-daemon.py").touch()
        (self.bin_dir / "asus_hotkey_daemon.py").touch()
        (self.bin_dir / "asus_hotkey_daemon_impl.py").touch()
        (self.bin_dir / "asus_hotkey_daemon_input.py").touch()
        (self.bin_dir / "asus_hotkey_daemon_monitor.py").touch()
        (self.bin_dir / "asus_hotkey_daemon_runtime.py").touch()
        (self.bin_dir / "asus_hotkey_daemon_state.py").touch()
        (self.bin_dir / "asus_common.py").touch()
        (self.bin_dir / "shared_imports.py").touch()
        (self.bin_dir / "asus_hda_verb.py").touch()
        (self.sys_dir / "asus-hotkey-daemon.service").touch()
        (self.hook_dir / "asus-sound-fix").touch()
        (self.lib_dir / "asus-session.sh").touch()
        (self.lib_dir / "asus-common.sh").touch()
        (self.lib_dir / "asus-notif-icons.sh").touch()
        (self.lib_dir / "asus-bootstrap.sh").touch()
        (self.lib_dir / "asus-display-mutter.sh").touch()
        (self.lib_dir / "asus-display-state.sh").touch()
        (self.lib_dir / "asus-display-watchdog.sh").touch()
        (self.lib_dir / "asus-display-osd.sh").touch()
        (self.lib_dir / "install-gnome.sh").write_text("# legacy leftover\n", encoding="utf-8")

        mock_bin = self._mock_bin_path()
        write_stubs(
            {
                "systemctl": ('#!/bin/sh\nif [ "$1" = "is-active" ]; then exit 3; fi\nexit 0\n'),
            },
            mock_bin,
        )
        fake_loginctl_no_sessions(str(mock_bin))
        fake_id(str(mock_bin))

    def _build_uninstall_env(self, skip_root: str = "1"):
        """Build a DESTDIR uninstall environment with mock systemctl on PATH."""
        environment = os.environ.copy()
        environment["ASUS_TEST_MODE"] = "1"
        environment["SKIP_ROOT_CHECK"] = skip_root
        environment["SKIP_PKG_REMOVE"] = "1"
        environment["DESTDIR"] = str(self.dest_dir)
        environment["SYSTEMCTL_CMD"] = str(self._systemctl_path())
        environment["PATH"] = f"{self._mock_bin_path()}:{environment.get('PATH', '')}"
        return environment

    def _write_apt_remove_stubs(self, mock_bin: Path, log_path: Path, *, stdin_probe: bool) -> None:
        """Install apt-mark/apt-get/apt/dpkg-query stubs that append argv to *log_path*."""
        log_q = shlex.quote(str(log_path))
        apt_get_body = "#!/bin/sh\n"
        if stdin_probe:
            apt_get_body += f'if [ "$(readlink -f /dev/stdin 2>/dev/null)" = "/dev/null" ]; then echo STDIN_DEVNULL >> {log_q}; fi\n'
        apt_get_body += f'echo "$@" >> {log_q}\nexit 0\n'
        write_stubs(
            {
                "apt-mark": f'#!/bin/sh\necho "$@" >> {log_q}\nexit 0\n',
                "apt-get": apt_get_body,
                "apt": f'#!/bin/sh\necho "$@" >> {log_q}\nexit 0\n',
                "dpkg-query": _DPKG_QUERY_INSTALLED_STUB,
            },
            mock_bin,
        )

    def test_root_check_fails_on_non_root(self):
        """Verify uninstaller terminates when executed without root permissions."""
        environment = self._build_uninstall_env(skip_root="0")
        environment["EFFECTIVE_UID_OVERRIDE"] = "1000"
        proc = run_shell_script(self.SCRIPT_PATH, env=environment, timeout=20)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Please run as root", proc.stderr)

    def test_uninstall_clean(self):
        """Verify uninstaller removes installed binaries and systemd unit files cleanly."""
        environment = self._build_uninstall_env()
        proc = run_shell_script(self.SCRIPT_PATH, env=environment, timeout=20)
        self.assertEqual(proc.returncode, 0)
        self.assertIn("cleanly uninstalled", proc.stdout)
        self.assertFalse((self.bin_dir / "asus-hotkey-daemon.py").exists())
        self.assertFalse((self.bin_dir / "asus_hotkey_daemon.py").exists())
        self.assertFalse((self.bin_dir / "asus_hotkey_daemon_impl.py").exists())
        self.assertFalse((self.bin_dir / "asus_hotkey_daemon_input.py").exists())
        self.assertFalse((self.bin_dir / "asus_hotkey_daemon_monitor.py").exists())
        self.assertFalse((self.bin_dir / "asus_hotkey_daemon_runtime.py").exists())
        self.assertFalse((self.bin_dir / "asus_hotkey_daemon_state.py").exists())
        self.assertFalse((self.bin_dir / "asus_common.py").exists())
        self.assertFalse((self.bin_dir / "shared_imports.py").exists())
        self.assertFalse((self.bin_dir / "asus_hda_verb.py").exists())
        self.assertFalse((self.lib_dir / "asus-session.sh").exists())
        self.assertFalse((self.lib_dir / "asus-common.sh").exists())
        self.assertFalse((self.lib_dir / "asus-notif-icons.sh").exists())
        self.assertFalse((self.lib_dir / "asus-bootstrap.sh").exists())
        self.assertFalse((self.lib_dir / "asus-display-mutter.sh").exists())
        self.assertFalse((self.lib_dir / "asus-display-state.sh").exists())
        self.assertFalse((self.lib_dir / "asus-display-watchdog.sh").exists())
        self.assertFalse((self.lib_dir / "asus-display-osd.sh").exists())
        self.assertFalse((self.lib_dir / "install-gnome.sh").exists())
        self.assertFalse((self.sys_dir / "asus-hotkey-daemon.service").exists())
        self.assertFalse((self.hook_dir / "asus-sound-fix").exists())
        self.assertFalse(self.lib_dir.exists())
        self.assertNotIn("not empty", proc.stderr)
        self.assertFalse(self.state_dir.exists())

    def test_uninstall_warns_when_restore_bus_missing(self):
        """Verify uninstaller warns and continues when state directory exists but D-Bus socket is missing."""
        environment = self._build_uninstall_env()
        mock_bin = self._mock_bin_path()
        fake_uid = "4242"
        fake_loginctl_no_sessions(str(mock_bin))
        fake_id(str(mock_bin), uid=fake_uid)
        environment.pop("BUS_ROOT", None)
        environment["DBUS_BUS_ROOT"] = str(Path(self.tmp_dir) / "no-bus")
        # Non-root USER so resolve_fallback_user does not fall through to who/NO_SESSION_USER
        # (Docker coverage-gate runs as root; USER=root skips restore silently).
        environment["USER"] = "asus-test-user"
        environment.pop("SUDO_USER", None)

        state_dir = self.state_dir / fake_uid
        state_dir.mkdir(parents=True, exist_ok=True)

        proc = run_shell_script(self.SCRIPT_PATH, env=environment, timeout=20)

        self.assertEqual(proc.returncode, 0)
        self.assertIn("Warning: Skipping GNOME keybinding restore", proc.stderr)

    def test_uninstall_skips_restore_when_root_fallback_user_missing(self):
        """Verify empty root fallback lookup yields a no-user result instead of a restore failure."""
        environment = self._build_uninstall_env()
        environment["USER"] = "root"
        environment.pop("SUDO_USER", None)

        mock_bin = self._mock_bin_path()
        mock_bin.mkdir(parents=True, exist_ok=True)
        fake_loginctl_no_sessions(str(mock_bin))
        write_stubs(
            {"who": "#!/bin/sh\nexit 0\n"},
            mock_bin,
        )

        state_root = self.state_dir
        state_root.mkdir(parents=True, exist_ok=True)

        proc = run_shell_script(self.SCRIPT_PATH, env=environment, timeout=20)

        self.assertEqual(proc.returncode, 0)
        self.assertIn("cleanly uninstalled", proc.stdout)

    def test_sourcing_script_does_not_run_main(self):
        """Sourcing uninstall.sh should expose functions without triggering uninstall flow."""
        assert_shell_source_smoke(self, str(self.SCRIPT_PATH), "remove_installed_files")

    def test_uninstall_fails_when_service_remains_active(self):
        """Verify uninstall exits non-zero when a service still reports active after stop."""
        environment = self._build_uninstall_env()
        self._systemctl_path().write_text(
            "#!/bin/sh\n"
            'if [ "$1" = "is-active" ]; then\n'
            '  for arg in "$@"; do\n'
            '    if [ "$arg" = "asus-touchpad-share.service" ]; then exit 0; fi\n'
            "  done\n"
            "  exit 3\n"
            "fi\n"
            "exit 0\n",
            encoding="utf-8",
        )
        self._systemctl_path().chmod(0o755)

        proc = run_shell_script(self.SCRIPT_PATH, env=environment, timeout=20)

        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("service remained active after stop", proc.stderr)

    def test_uninstall_accepts_is_active_status_4(self):
        """systemd 259+ returns is-active exit 4 for inactive/not-loaded units."""
        environment = self._build_uninstall_env()
        self._systemctl_path().write_text(
            "#!/bin/sh\n"
            'if [ "$1" = "is-active" ]; then exit 4; fi\n'
            "exit 0\n",
            encoding="utf-8",
        )
        self._systemctl_path().chmod(0o755)

        proc = run_shell_script(self.SCRIPT_PATH, env=environment, timeout=20)

        self.assertEqual(proc.returncode, 0)
        self.assertNotIn("unable to verify service state", proc.stderr)

    def test_uninstall_warns_when_daemon_reload_fails(self):
        """Verify uninstall reports errors when daemon-reload fails after file removal."""
        environment = self._build_uninstall_env()
        self._systemctl_path().write_text(
            "#!/bin/sh\n"
            'if [ "$1" = "is-active" ]; then exit 3; fi\n'
            'if [ "$1" = "daemon-reload" ]; then echo reload denied >&2; exit 1; fi\n'
            "exit 0\n",
            encoding="utf-8",
        )
        self._systemctl_path().chmod(0o755)

        proc = run_shell_script(self.SCRIPT_PATH, env=environment, timeout=20)

        self.assertEqual(proc.returncode, 1)
        self.assertIn("systemctl daemon-reload failed", proc.stderr)
        self.assertIn("daemon-reload after file removal failed; continuing", proc.stderr)
        self.assertIn("uninstall completed with errors", proc.stderr)

    def test_uninstall_ignores_systemctl_transport_errors_in_containers(self):
        """RPM/Docker smoke must uninstall when systemd is not PID 1."""
        environment = self._build_uninstall_env()
        self._systemctl_path().write_text(
            "#!/bin/sh\n"
            "echo \"System has not been booted with systemd as init system (PID 1). Can't operate.\" >&2\n"
            'echo "Failed to connect to system scope bus via local transport: Host is down" >&2\n'
            "exit 1\n",
            encoding="utf-8",
        )
        self._systemctl_path().chmod(0o755)

        proc = run_shell_script(self.SCRIPT_PATH, env=environment, timeout=20)

        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertNotIn("uninstall completed with errors", proc.stderr)

    def test_uninstall_succeeds_when_systemctl_missing(self):
        """openSUSE/RPM smoke containers without systemctl must still uninstall."""
        environment = self._build_uninstall_env()
        # Override with a non-resolvable path: the real host PATH (e.g. /usr/bin)
        # may still have systemctl, so removing SYSTEMCTL_CMD alone is not enough.
        environment["SYSTEMCTL_CMD"] = "/nonexistent/systemctl-not-installed"
        environment["PATH"] = "/usr/bin:/bin"
        proc = run_shell_script(self.SCRIPT_PATH, env=environment, timeout=20)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertNotIn("systemctl command not available", proc.stderr)

    def test_destdir_uninstall_defaults_skip_pkg_remove(self):
        """DESTDIR staged uninstall must not invoke package removal when SKIP_PKG_REMOVE is unset."""
        environment = self._build_uninstall_env()
        environment.pop("SKIP_PKG_REMOVE", None)
        record = self.state_dir / "installed-packages"
        record.write_text("python3-evdev\n", encoding="utf-8")
        remove_log = Path(self.tmp_dir) / "pkg-remove.log"
        mock_bin = self._mock_bin_path()
        self._write_apt_remove_stubs(mock_bin, remove_log, stdin_probe=False)

        proc = run_shell_script(self.SCRIPT_PATH, env=environment, timeout=20)

        self.assertEqual(proc.returncode, 0)
        self.assertNotIn("Removing system dependencies", proc.stdout)
        self.assertTrue(record.is_file())
        self.assertFalse(remove_log.exists())

    def test_uninstall_removes_recorded_dependencies(self):
        """Verify uninstall removes packages listed in the install record file."""
        environment = self._build_uninstall_env()
        environment["SKIP_PKG_REMOVE"] = "0"
        environment["INSTALL_OS_ID"] = "ubuntu"
        environment["INSTALL_OS_ID_LIKE"] = "debian"

        state_root = self.state_dir
        state_root.mkdir(parents=True, exist_ok=True)
        (state_root / "installed-packages").write_text(
            "python3\npython3-evdev\nydotool\n",
            encoding="utf-8",
        )

        remove_log = Path(self.tmp_dir) / "pkg-remove.log"
        mock_bin = self._mock_bin_path()
        self._write_apt_remove_stubs(mock_bin, remove_log, stdin_probe=True)

        proc = run_shell_script(self.SCRIPT_PATH, env=environment, timeout=20)

        self.assertEqual(proc.returncode, 0)
        self.assertIn("Removing system dependencies", proc.stdout)
        self.assertFalse((state_root / "installed-packages").exists())
        remove_text = remove_log.read_text(encoding="utf-8")
        self.assertRegex(remove_text, r"(^|[\s])auto([\s]|$)")
        self.assertIn("autoremove -y", remove_text)
        self.assertNotIn("--purge", remove_text)
        self.assertIn("Dpkg::Use-Pty=0", remove_text)
        self.assertIn("python3-evdev", remove_text)
        self.assertIn("ydotool", remove_text)
        self.assertNotRegex(remove_text, r"(^|[\s/])python3([\s]|$)")
        self.assertIn("STDIN_DEVNULL", remove_text)

    def test_uninstall_revokes_input_group_before_package_removal(self):
        """asus-uinput revoke must run before apt package removal."""
        environment = self._build_uninstall_env()
        environment["SKIP_PKG_REMOVE"] = "0"
        environment["INSTALL_OS_ID"] = "ubuntu"
        environment["INSTALL_OS_ID_LIKE"] = "debian"

        state_root = self.state_dir
        state_root.mkdir(parents=True, exist_ok=True)
        (state_root / "installed-packages").write_text("python3-evdev\n", encoding="utf-8")
        (state_root / "asus-uinput-group-users").write_text("testuser\n", encoding="utf-8")

        order_log = Path(self.tmp_dir) / "uninstall-order.log"
        order_q = shlex.quote(str(order_log))
        mock_bin = self._mock_bin_path()
        write_stubs(
            {
                "gpasswd": f"#!/bin/sh\necho gpasswd >> {order_q}\nexit 0\n",
                "id": (
                    "#!/bin/sh\n"
                    'if [ "$1" = "-nG" ]; then echo asus-uinput; exit 0; fi\n'
                    'if [ "$1" = "-u" ]; then echo 1000; exit 0; fi\n'
                    "exit 0\n"
                ),
                "getent": ('#!/bin/sh\nif [ "$1" = "group" ] && [ "$2" = "asus-uinput" ]; then exit 0; fi\nexit 1\n'),
                "apt-mark": f"#!/bin/sh\necho apt-mark >> {order_q}\nexit 0\n",
                "apt-get": f"#!/bin/sh\necho apt-get >> {order_q}\nexit 0\n",
                "apt": f"#!/bin/sh\necho apt >> {order_q}\nexit 0\n",
                "dpkg-query": _DPKG_QUERY_INSTALLED_STUB,
            },
            mock_bin,
        )

        proc = run_shell_script(self.SCRIPT_PATH, env=environment, timeout=20)
        self.assertEqual(proc.returncode, 0)
        lines = order_log.read_text(encoding="utf-8").splitlines()
        self.assertIn("gpasswd", lines)
        self.assertIn("apt-mark", lines)
        self.assertLess(lines.index("gpasswd"), lines.index("apt-mark"))

    def test_uninstall_preserves_record_when_removal_fails(self):
        """Failed package removal must keep installed-packages for a later retry."""
        environment = self._build_uninstall_env()
        environment["SKIP_PKG_REMOVE"] = "0"
        environment["INSTALL_OS_ID"] = "ubuntu"
        environment["INSTALL_OS_ID_LIKE"] = "debian"

        state_root = self.state_dir
        state_root.mkdir(parents=True, exist_ok=True)
        record = state_root / "installed-packages"
        record.write_text("python3-evdev\nydotool\n", encoding="utf-8")

        write_stubs(
            {
                "apt-mark": "#!/bin/sh\nexit 1\n",
                "apt-get": "#!/bin/sh\nexit 1\n",
                "apt": "#!/bin/sh\nexit 1\n",
                "dpkg-query": _DPKG_QUERY_INSTALLED_STUB,
            },
            self._mock_bin_path(),
        )

        proc = run_shell_script(self.SCRIPT_PATH, env=environment, timeout=20)

        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Dependency removal failed", proc.stderr)
        self.assertTrue(record.exists())
        self.assertEqual(record.read_text(encoding="utf-8"), "python3-evdev\nydotool\n")

    def test_uninstall_skips_dependency_removal_when_requested(self):
        """Verify SKIP_PKG_REMOVE leaves the package record untouched by pkg tools."""
        environment = self._build_uninstall_env()
        environment["SKIP_PKG_REMOVE"] = "1"
        state_root = self.state_dir
        state_root.mkdir(parents=True, exist_ok=True)
        record = state_root / "installed-packages"
        record.write_text("python3-evdev\n", encoding="utf-8")
        remove_log = Path(self.tmp_dir) / "pkg-remove.log"
        mock_bin = self._mock_bin_path()
        self._write_apt_remove_stubs(mock_bin, remove_log, stdin_probe=False)

        proc = run_shell_script(self.SCRIPT_PATH, env=environment, timeout=20)

        self.assertEqual(proc.returncode, 0)
        self.assertNotIn("Removing system dependencies", proc.stdout)
        # SKIP_PKG_REMOVE skips remove_system_deps, so the record is preserved for retry.
        self.assertTrue(record.exists())
        self.assertEqual(record.read_text(encoding="utf-8"), "python3-evdev\n")
        self.assertFalse(remove_log.exists())


if __name__ == "__main__":
    unittest.main()
