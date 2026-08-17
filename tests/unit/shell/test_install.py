"""Unit tests for install.sh installer script."""

import os
import shlex
import subprocess
import unittest
from pathlib import Path

from tests.unit.shell.shell_install_test_base import InstallTestBase
from tests.unit.shell.shell_test_utils import (
    assert_shell_source_smoke,
    run_bash_c,
    run_shell_script,
)


class TestInstallScriptUnit(InstallTestBase):
    """Unit tests exercising install.sh execution paths."""

    def _setup_gnome_session_stubs(self, environment: dict, sudo_script_body: str) -> Path:
        """Create loginctl/sudo/id stubs for GNOME-path tests."""
        mock_bin = self._write_stubs(
            {
                "loginctl": (
                    "#!/bin/sh\n"
                    'if [ "$1" = "list-sessions" ]; then\n'
                    "  echo '1'\n"
                    "  exit 0\n"
                    "fi\n"
                    'if [ "$1" = "show-session" ]; then\n'
                    '  if [ "$2" = "1" ]; then\n'
                    '    case "$3" in\n'
                    "      -p)\n"
                    '        case "$4" in\n'
                    "          Type) echo 'wayland' ;;\n"
                    "          State) echo 'active' ;;\n"
                    "          Name) echo 'testuser' ;;\n"
                    "          Seat) echo 'seat0' ;;\n"
                    "        esac\n"
                    "        ;;\n"
                    "    esac\n"
                    "  fi\n"
                    "fi\n"
                    "exit 0\n"
                ),
                "sudo": sudo_script_body,
                "id": ('#!/bin/sh\nif [ "$1" = "-u" ]; then\n  echo 1000\n  exit 0\nfi\nexit 0\n'),
            }
        )

        environment["PATH"] = f"{mock_bin}:{environment['PATH']}"
        return mock_bin

    def test_root_check_fails_on_non_root(self):
        """Installer terminates without root permissions."""
        environment = self._build_install_env(skip_root="0")
        environment["EFFECTIVE_UID_OVERRIDE"] = "1000"
        proc = run_shell_script(self.script_path, env=environment, timeout=20)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Please run as root", proc.stderr)

    def test_install_components_success(self):
        """Deploy WMI and Touchpad components successfully."""
        environment = self._build_install_env("WMI TOUCHPAD")
        proc = run_shell_script(self.script_path, env=environment, timeout=20)
        self.assertEqual(proc.returncode, 0)
        self.assertIn("Installation complete.", proc.stdout)
        self.assertIn("ASUS ZenBook Linux Setup", proc.stdout)
        version = (self.repo_root / "VERSION").read_text(encoding="utf-8").strip()
        self.assertIn(f"v{version}", proc.stdout)
        self.assertTrue((self.bin_dir / "asus-hotkey-daemon.py").exists())
        self.assertTrue((self.bin_dir / "asus_hotkey_daemon.py").exists())
        self.assertTrue((self.bin_dir / "asus_hotkey_daemon_impl.py").exists())
        self.assertTrue((self.bin_dir / "asus_hotkey_daemon_input.py").exists())
        self.assertTrue((self.bin_dir / "asus_hotkey_daemon_monitor.py").exists())
        self.assertTrue((self.bin_dir / "asus_hotkey_daemon_runtime.py").exists())
        self.assertTrue((self.bin_dir / "asus_hotkey_daemon_threading.py").exists())
        self.assertTrue((self.bin_dir / "asus_hotkey_daemon_window_move.py").exists())
        self.assertTrue((self.bin_dir / "asus_hotkey_daemon_state.py").exists())
        self.assertTrue((self.bin_dir / "asus_common.py").exists())
        self.assertTrue((self.bin_dir / "shared_imports.py").exists())
        self.assertTrue((self.bin_dir / "asus_display_mode.py").exists())
        self.assertTrue((self.bin_dir / "asus-display-mode.sh").exists())
        self.assertTrue((self.bin_dir / "asus-touchpad-share.py").exists())
        self.assertTrue((self.dest_dir / "usr/local/lib/asus-zenbook-linux-tools/asus-session.sh").exists())
        self.assertTrue((self.dest_dir / "usr/local/lib/asus-zenbook-linux-tools/asus-common.sh").exists())
        self.assertTrue((self.dest_dir / "usr/local/lib/asus-zenbook-linux-tools/asus-notif-icons.sh").exists())
        self.assertTrue((self.dest_dir / "usr/local/lib/asus-zenbook-linux-tools/asus-bootstrap.sh").exists())
        self.assertTrue((self.dest_dir / "usr/local/lib/asus-zenbook-linux-tools/asus-display-mutter.sh").exists())
        self.assertTrue((self.dest_dir / "usr/local/lib/asus-zenbook-linux-tools/asus-display-state.sh").exists())
        self.assertTrue((self.dest_dir / "usr/local/lib/asus-zenbook-linux-tools/asus-display-watchdog.sh").exists())
        self.assertTrue((self.dest_dir / "usr/local/lib/asus-zenbook-linux-tools/asus-display-osd.sh").exists())
        self.assertTrue((self.sys_dir / "asus-hotkey-daemon.service").exists())
        self.assertTrue((self.sys_dir / "asus-touchpad-share.service").exists())

    def test_full_install_reports_runtime_component_failure(self):
        """Verify the installer reports a GNOME runtime failure instead of claiming full success."""
        environment = self._build_install_env("WMI TOUCHPAD SOUND GNOME")
        environment["SYSTEMCTL_CMD"] = "true"
        environment["DBUS_BUS_ROOT"] = str(Path(self.tmp_dir) / "no-bus")
        self._setup_mock_sound_hardware(environment)

        mock_bin = self._write_stubs({"hda-verb": "#!/bin/sh\nexit 0\n"})
        environment["PATH"] = f"{mock_bin}:{environment['PATH']}"

        proc = run_shell_script(self.script_path, env=environment, timeout=20)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("GNOME configuration failed", proc.stderr)
        self.assertIn("Installation failed with one or more component errors", proc.stderr)

    def test_install_sound_failure_is_reported_and_does_not_mask_other_components(self):
        """Verify sound deployment errors loudly, the install continues to later components, and the overall run fails."""
        environment = self._build_install_env("SOUND GNOME")
        environment["SYSTEMCTL_CMD"] = "true"
        environment["DBUS_BUS_ROOT"] = str(Path(self.tmp_dir) / "no-bus")
        environment["INSTALL_STRICT_COMPONENTS"] = "1"
        self._setup_mock_sound_hardware(environment)

        mock_bin = self._write_stubs({"hda-verb": "#!/bin/sh\nexit 1\n"})
        environment["PATH"] = f"{mock_bin}:{environment['PATH']}"

        proc = run_shell_script(self.script_path, env=environment, timeout=20)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Sound fix installation failed", proc.stderr)
        self.assertIn("GNOME configuration failed", proc.stderr)
        self.assertTrue((self.bin_dir / "asus-sound-fix.sh").exists())
        self.assertTrue((self.bin_dir / "asus_hda_verb.py").exists())
        self.assertTrue((self.sys_dir / "asus-sound-fix.service").exists())

    def test_sound_component_fails_when_service_enable_fails(self):
        """Verify sound install fails when systemd enable --now does not succeed."""
        environment = self._build_install_env("SOUND")
        environment["INSTALL_STRICT_COMPONENTS"] = "1"
        self._setup_mock_sound_hardware(environment)

        mock_bin = self._write_stubs(
            {
                "systemctl": (
                    "#!/bin/sh\n"
                    'if [ "$1" = "daemon-reload" ]; then exit 0; fi\n'
                    'if [ "$1" = "enable" ]; then exit 1; fi\n'
                    'if [ "$1" = "disable" ]; then exit 0; fi\n'
                    "exit 0\n"
                ),
                "hda-verb": "#!/bin/sh\nexit 0\n",
            }
        )
        environment["SYSTEMCTL_CMD"] = str(mock_bin / "systemctl")
        environment["PATH"] = f"{mock_bin}:{environment['PATH']}"

        proc = run_shell_script(self.script_path, env=environment, timeout=20)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Sound fix service activation failed", proc.stderr)

    def test_hotkey_service_keeps_session_dbus_access(self):
        """Verify hotkey unit keeps session D-Bus working (ProtectSystem=no)."""
        environment = self._build_install_env("WMI")
        proc = run_shell_script(self.script_path, env=environment, timeout=20)

        self.assertEqual(proc.returncode, 0)
        service_text = (self.sys_dir / "asus-hotkey-daemon.service").read_text(encoding="utf-8")
        active_lines = [line.strip() for line in service_text.splitlines() if line.strip() and not line.strip().startswith("#")]
        self.assertIn("ProtectSystem=no", active_lines)
        self.assertNotIn("NoNewPrivileges=yes", active_lines)
        self.assertNotIn("ProtectSystem=strict", active_lines)
        self.assertIn("ProtectHome=read-only", active_lines)
        self.assertIn("RuntimeDirectory=asus-zenbook-notif", active_lines)
        self.assertIn("PrivateDevices=no", active_lines)
        self.assertIn("ProtectKernelModules=yes", active_lines)
        self.assertIn("ProtectKernelLogs=yes", active_lines)
        self.assertIn("RestrictNamespaces=yes", active_lines)
        self.assertNotIn("systemd-udev-settle", service_text)

    def test_wmi_component_reports_service_start_failure(self):
        """Verify a failed WMI service startup is surfaced as a component failure instead of a success."""
        environment = self._build_install_env("WMI")
        environment["INSTALL_STRICT_COMPONENTS"] = "1"

        mock_bin = self._write_stubs(
            {
                "systemctl": (
                    "#!/bin/sh\n"
                    'if [ "$1" = "daemon-reload" ]; then exit 0; fi\n'
                    'if [ "$1" = "enable" ]; then exit 0; fi\n'
                    'if [ "$1" = "restart" ]; then exit 1; fi\n'
                    'if [ "$1" = "is-active" ]; then exit 1; fi\n'
                    "exit 0\n"
                )
            }
        )
        environment["SYSTEMCTL_CMD"] = str(mock_bin / "systemctl")
        environment["PATH"] = f"{mock_bin}:{environment['PATH']}"

        proc = run_shell_script(self.script_path, env=environment, timeout=20)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("WMI Hotkey daemon failed to restart", proc.stderr)
        self.assertIn("Installation failed with one or more component errors", proc.stderr)

    def test_package_manager_detection_reports_already_installed_dependencies(self):
        """Verify the installer recognizes an available package manager even when deps are already satisfied."""
        environment = self._build_install_env("WMI TOUCHPAD")
        environment["SKIP_PKG_INSTALL"] = "0"
        # Pin to Debian family so apt-get/dpkg mocks are always exercised, regardless of host distro
        environment["INSTALL_OS_ID"] = "ubuntu"
        self._prepend_apt_stubs(environment, dpkg_query_exit=0)

        proc = run_shell_script(self.script_path, env=environment, timeout=20)
        self.assertEqual(proc.returncode, 0)
        self.assertIn("All system dependencies already installed", proc.stdout)
        self.assertNotIn("No supported package manager detected", proc.stdout)

    def test_install_gnome_without_user_bus_fails_loudly(self):
        """Verify missing GNOME D-Bus context is reported as a hard failure without masking the error."""
        environment = self._build_install_env("GNOME")
        environment["DBUS_BUS_ROOT"] = str(Path(self.tmp_dir) / "no-bus")
        environment["INSTALL_STRICT_COMPONENTS"] = "1"
        proc = run_shell_script(self.script_path, env=environment, timeout=20)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Install scripts and services", proc.stdout)
        self.assertIn("GNOME configuration failed", proc.stderr)

    def test_gnome_component_fails_when_required_backup_state_is_missing(self):
        """Verify GNOME configuration exits non-zero when required backup state is unavailable."""
        environment = self._build_install_env("GNOME")
        environment["DBUS_BUS_ROOT"] = str(Path(self.tmp_dir) / "dbus")
        environment["INSTALL_STRICT_COMPONENTS"] = "1"

        mock_bin = self._setup_gnome_session_stubs(
            environment,
            '#!/bin/sh\nexec "$@"\n',
        )

        self._setup_dbus_session_socket()

        self._write_stubs(
            {"gsettings": ('#!/bin/sh\nif [ "$1" = "get" ]; then\n  echo \'[]\'\n  exit 0\nfi\nexit 0\n')},
            mock_bin=mock_bin,
        )

        proc = run_shell_script(self.script_path, env=environment, timeout=20)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("required backup state was not available", proc.stderr)

    def _run_hanging_gnome_install(self) -> subprocess.CompletedProcess[str]:
        """Run GNOME install with a slow sudo stub and strict component timeouts."""
        environment = self._build_install_env("GNOME")
        environment["DBUS_BUS_ROOT"] = str(Path(self.tmp_dir) / "dbus")
        environment["INSTALL_COMMAND_TIMEOUT"] = "1"
        environment["INSTALL_STRICT_COMPONENTS"] = "1"
        self._setup_gnome_session_stubs(
            environment,
            "#!/bin/sh\nsleep 30\n",
        )
        return run_shell_script(self.script_path, env=environment, timeout=15)

    def test_hanging_gnome_component_fails_quickly(self):
        """Verify GNOME configuration is bounded by timeout and reports failure once."""
        proc = self._run_hanging_gnome_install()
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("GNOME configuration failed", proc.stderr)
        self.assertEqual(proc.stderr.count("GNOME configuration failed"), 1)

    def test_hanging_systemctl_call_fails_quickly(self):
        """Verify service installation is bounded when systemctl hangs."""
        environment = self._build_install_env("SOUND")
        environment["INSTALL_COMMAND_TIMEOUT"] = "1"
        environment["INSTALL_STRICT_COMPONENTS"] = "1"
        environment["PROC_ASOUND_ROOT"] = str(Path(self.tmp_dir) / "empty-asound")
        environment["DEV_SND_ROOT"] = str(Path(self.tmp_dir) / "empty-snd")
        environment["SOUND_FIX_PROBE_TIMEOUT"] = "1"

        mock_bin = self._write_stubs({"systemctl": "#!/bin/sh\nsleep 30\n"})
        environment["SYSTEMCTL_CMD"] = str(mock_bin / "systemctl")
        environment["PATH"] = f"{mock_bin}:{environment['PATH']}"

        # daemon-reload hang (1s + 2s kill-after) then hook cleanup; keep headroom.
        proc = run_shell_script(self.script_path, env=environment, timeout=20)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Sound fix service activation failed", proc.stderr)

    def test_invalid_noninteractive_choice_fails(self):
        """Verify invalid NONINTERACTIVE_CHOICE is rejected with clear error."""
        environment = self._build_install_env("INVALID_COMPONENT")
        proc = run_shell_script(self.script_path, env=environment, timeout=20)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Invalid NONINTERACTIVE_CHOICE", proc.stderr)

    def test_no_tty_without_noninteractive_choice_defaults_to_all(self):
        """Verify missing interactive terminal defaults to a full install attempt and still completes successfully."""
        environment = self._build_install_env(choice=None)
        environment["INSTALL_FAKE_NO_TTY"] = "1"
        self._setup_mock_sound_hardware(environment)

        mock_bin = self._setup_gnome_session_stubs(
            environment,
            "#!/bin/sh\n"
            "# Strip -n, -E, -u <user> flags, then run the remaining command\n"
            "# Also handle VAR=value env assignments before the command\n"
            "while [ $# -gt 0 ]; do\n"
            '  case "$1" in\n'
            "    -n) shift ;;\n"
            "    -u) shift 2 ;;\n"
            "    -E) shift ;;\n"
            "    --) shift; break ;;\n"
            '    *=*) export "$1"; shift ;;\n'
            "    *) break ;;\n"
            "  esac\n"
            "done\n"
            'exec "$@"\n',
        )

        self._setup_dbus_session_socket()

        self._write_stubs(
            {
                "gsettings": ('#!/bin/sh\nif [ "$1" = "get" ]; then\n  echo \'[]\'\n  exit 0\nfi\nexit 0\n'),
                "hda-verb": "#!/bin/sh\nexit 0\n",
            },
            mock_bin=mock_bin,
        )
        environment["DBUS_BUS_ROOT"] = str(Path(self.tmp_dir) / "dbus")

        proc = run_shell_script(self.script_path, env=environment, timeout=20)
        self.assertEqual(proc.returncode, 0)
        self.assertIn("No interactive terminal detected; defaulting to:", proc.stderr)
        self.assertIn("Installation complete.", proc.stdout)


class TestInstallOsFamilyMapping(InstallTestBase):
    """Unit tests focused on distro-family mapping logic used by install.sh."""

    def _detect_os_family(self, os_id: str, os_like: str = "") -> subprocess.CompletedProcess[str]:
        """Return detected OS family for a provided os-release identity override."""
        environment = os.environ.copy()
        environment["INSTALL_OS_ID"] = os_id
        environment["INSTALL_OS_ID_LIKE"] = os_like
        script = shlex.quote(str(self.script_path))
        return run_bash_c(
            f'source {script}; if family=$(_detect_os_family); then printf "%s\\n" "$family"; else printf "\\n"; fi',
            env=environment,
            timeout=10,
        )

    def test_derivative_os_ids_map_to_expected_families(self):
        """Verify major distro derivatives map to their expected package-manager families."""
        expected_family = {
            "linuxmint": "debian",
            "pop": "debian",
            "kali": "debian",
            "rocky": "redhat",
            "almalinux": "redhat",
            "centos": "redhat",
            "amzn": "redhat",
            "sles": "suse",
            "suse": "suse",
            "manjaro": "arch",
            "endeavouros": "arch",
            "artix": "arch",
            "steamos": "arch",
        }

        for os_id, family in expected_family.items():
            with self.subTest(os_id=os_id):
                proc = self._detect_os_family(os_id)
                self.assertEqual(proc.returncode, 0)
                self.assertEqual(proc.stdout.strip(), family)

    def test_id_like_fallback_maps_to_expected_family(self):
        """Verify ID_LIKE is used when the primary ID is unknown."""
        proc = self._detect_os_family("steamdeck", "arch")
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "arch")


class TestInstallGnomeHelpers(InstallTestBase):
    """Unit tests for GNOME keybinding list helpers."""

    def _drop(self, merged: str, path: str) -> str:
        """Run install-gnome _drop_keybinding_path against merged/path via bash -c."""
        gnome = self.repo_root / "lib" / "install-gnome.sh"
        shared = self.repo_root / "lib" / "install-shared.sh"
        script = (
            f"set -euo pipefail; source {shlex.quote(str(shared))}; "
            f"source {shlex.quote(str(gnome))}; "
            f"_drop_keybinding_path {shlex.quote(merged)} {shlex.quote(path)}"
        )
        proc = run_bash_c(script, timeout=10)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout.strip()

    def test_drop_keybinding_path_handles_spaced_and_unspaced_lists(self):
        """Drop works for spaced, unspaced, and single-entry GNOME lists."""
        self.assertEqual(self._drop("['a', 'b']", "a"), "['b']")
        self.assertEqual(self._drop("['a','b']", "a"), "['b']")
        self.assertEqual(self._drop("['a']", "a"), "[]")
        self.assertEqual(self._drop("['a', 'b']", "missing"), "['a', 'b']")


class TestInstallSharedHelpers(InstallTestBase):
    """Unit tests for shared install helper functions."""

    def test_install_lib_file_replaces_symlink_to_source(self):
        """Verify helper install replaces a dest symlink that points at the source."""
        shared = self.repo_root / "lib" / "install-shared.sh"
        source = Path(self.tmp_dir) / "source.sh"
        dest_dir = Path(self.tmp_dir) / "libdir"
        dest = dest_dir / "helper.sh"
        source.write_text("#!/bin/sh\necho ok\n", encoding="utf-8")
        dest_dir.mkdir(parents=True, exist_ok=True)
        dest.symlink_to(source)
        shared_q = shlex.quote(str(shared))
        source_q = shlex.quote(str(source))
        dest_q = shlex.quote(str(dest))
        script = (
            f"set -euo pipefail; source {shared_q}; "
            f"_install_resolved_lib_file {source_q} {dest_q}; "
            f"if [ -L {dest_q} ]; then echo STILL_LINK; exit 1; fi"
        )
        proc = run_bash_c(script, timeout=10)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(dest.is_symlink())
        self.assertEqual(dest.read_text(encoding="utf-8"), source.read_text(encoding="utf-8"))

    def test_print_next_step_allows_unset_counters_under_nounset(self):
        """Configure helpers must print progress when install.sh never planned steps."""
        shared = self.repo_root / "lib" / "install-shared.sh"
        shared_q = shlex.quote(str(shared))
        script = (
            f"set -euo pipefail; unset INSTALL_STEP_CURRENT INSTALL_STEP_TOTAL; "
            f"source {shared_q}; _install_print_next_step 'Configure test'"
        )
        proc = run_bash_c(script, timeout=10)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "[1/1] Configure test")


class TestInstallScriptSourcing(InstallTestBase):
    """Smoke tests for sourcing install.sh without executing main."""

    def test_sourcing_script_does_not_run_main(self):
        """Sourcing install.sh should expose helper functions without triggering installer execution."""
        assert_shell_source_smoke(self, str(self.script_path), "install_system_deps")


if __name__ == "__main__":
    unittest.main()
