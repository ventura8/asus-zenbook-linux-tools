"""E2E tests matching install.sh."""

import os
import tempfile
import unittest
from pathlib import Path

from tests.e2e.e2e_utils import assert_root_check, run_e2e_command
from tests.e2e.mock.mock_env import (
    MOCK_UID,
    build_install_gsettings_script,
    build_install_mock_env,
    build_minimal_mock_env,
    gsettings_key_exists_command,
    mock_install_env_base,
    write_executable,
)

PROJECT_ROOT = str(Path(__file__).resolve().parents[3])
INSTALL_SCRIPT = os.path.join(PROJECT_ROOT, "install.sh")


class TestInstallScriptE2E(unittest.TestCase):
    """End-to-end tests for install.sh script."""

    def test_root_check(self):
        """Test install.sh enforces root check when run as non-root."""
        assert_root_check(self, INSTALL_SCRIPT)

    def test_gsettings_key_exists(self):
        """Test _gsettings_key_exists helper handles present and missing keys."""
        with tempfile.TemporaryDirectory() as tmp:
            env, _, _mock_bin = build_install_mock_env(tmp)
            bus_path = str(Path(env["DBUS_BUS_ROOT"]) / str(MOCK_UID) / "bus")

            present_proc = run_e2e_command(
                gsettings_key_exists_command(
                    INSTALL_SCRIPT,
                    bus_path,
                    "org.gnome.shell.keybindings",
                    "show-screenshot-ui",
                ),
                env=env,
                timeout=20,
            )
            self.assertEqual(present_proc.returncode, 0)

            missing_proc = run_e2e_command(
                gsettings_key_exists_command(
                    INSTALL_SCRIPT,
                    bus_path,
                    "org.gnome.shell.keybindings",
                    "nonexistent_key_xyz",
                ),
                env=env,
                timeout=20,
            )
            self.assertNotEqual(missing_proc.returncode, 0)

    def test_switch_video_mode_optional_when_missing(self):
        """Test whether the switch-video-mode gsettings key exists when optional."""
        with tempfile.TemporaryDirectory() as tmp:
            env, _, mock_bin = build_install_mock_env(tmp)
            write_executable(
                mock_bin / "gsettings",
                build_install_gsettings_script(include_switch_video_mode=False),
            )
            bus_path = str(Path(env["DBUS_BUS_ROOT"]) / str(MOCK_UID) / "bus")

            present_proc = run_e2e_command(
                gsettings_key_exists_command(
                    INSTALL_SCRIPT,
                    bus_path,
                    "org.gnome.settings-daemon.plugins.media-keys",
                    "control-center",
                ),
                env=env,
                timeout=20,
            )
            self.assertEqual(present_proc.returncode, 0)

            missing_proc = run_e2e_command(
                gsettings_key_exists_command(
                    INSTALL_SCRIPT,
                    bus_path,
                    "org.gnome.settings-daemon.plugins.media-keys",
                    "switch-video-mode",
                ),
                env=env,
                timeout=20,
            )
            self.assertNotEqual(missing_proc.returncode, 0)

    def test_gnome_install_succeeds_without_switch_video_mode(self):
        """GNOME install completes when switch-video-mode key is absent."""
        with tempfile.TemporaryDirectory() as tmp:
            env, _, mock_bin = build_install_mock_env(tmp)
            write_executable(
                mock_bin / "gsettings",
                build_install_gsettings_script(include_switch_video_mode=False),
            )
            env["NONINTERACTIVE_CHOICE"] = "GNOME"
            install_proc = run_e2e_command(["bash", INSTALL_SCRIPT], env=env, timeout=30)
            self.assertEqual(install_proc.returncode, 0, install_proc.stderr)
            self.assertIn("Installation complete.", install_proc.stdout)

    def test_gnome_choice_without_dbus_bus_fails_loudly(self):
        """Test GNOME install branch fails loudly when no user D-Bus socket exists."""
        with tempfile.TemporaryDirectory() as tmp:
            dest_dir = Path(tmp) / "dest"
            env = {
                "ASUS_TEST_MODE": "1",
                "SKIP_ROOT_CHECK": "1",
                "SKIP_PKG_INSTALL": "1",
                "NONINTERACTIVE_CHOICE": "GNOME",
                "DESTDIR": str(dest_dir),
                "SYSTEMCTL_CMD": "true",
                "DBUS_BUS_ROOT": str(Path(tmp) / "no-bus"),
            }
            merged = dict(os.environ, **env)
            merged.pop("BUS_ROOT", None)
            proc = run_e2e_command(["bash", INSTALL_SCRIPT], env=merged, timeout=25)

            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("Install scripts and services", proc.stdout)
            self.assertIn("GNOME configuration failed", proc.stderr)

    def test_invalid_noninteractive_choice_exits_nonzero(self):
        """Test invalid noninteractive component selection fails with clear error."""
        with tempfile.TemporaryDirectory() as tmp:
            dest_dir = Path(tmp) / "dest"
            env = {
                "ASUS_TEST_MODE": "1",
                "SKIP_ROOT_CHECK": "1",
                "SKIP_PKG_INSTALL": "1",
                "NONINTERACTIVE_CHOICE": "INVALID_COMPONENT",
                "DESTDIR": str(dest_dir),
                "SYSTEMCTL_CMD": "true",
            }
            proc = run_e2e_command(["bash", INSTALL_SCRIPT], env=dict(os.environ, **env), timeout=25)

            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("Invalid NONINTERACTIVE_CHOICE", proc.stderr)

    def test_no_tty_without_noninteractive_choice_defaults_to_all(self):
        """Test installer defaults to all components when no TTY is available."""
        with tempfile.TemporaryDirectory() as tmp:
            env, dest_dir, _ = build_minimal_mock_env(tmp)
            env.pop("NONINTERACTIVE_CHOICE", None)
            env["INSTALL_FAKE_NO_TTY"] = "1"
            proc = run_e2e_command(["bash", INSTALL_SCRIPT], env=env, timeout=30)

            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("No interactive terminal detected", proc.stderr)
            self.assertTrue((dest_dir / "usr/local/bin/asus-hotkey-daemon.py").exists())
            self.assertTrue((dest_dir / "usr/local/lib/asus-zenbook-linux-tools/asus-bootstrap.sh").exists())

    def test_wmi_touchpad_gnome_success_installs_expected_artifacts(self):
        """Test mock-backed WMI+TOUCHPAD+GNOME install succeeds and deploys assets."""
        with tempfile.TemporaryDirectory() as tmp:
            env, dest_dir, _mock_bin = build_minimal_mock_env(tmp)
            env["NONINTERACTIVE_CHOICE"] = "WMI TOUCHPAD GNOME"

            proc = run_e2e_command(["bash", INSTALL_SCRIPT], env=env, timeout=30)
            self.assertEqual(proc.returncode, 0)
            self.assertIn("Installation complete.", proc.stdout)
            self.assertTrue((dest_dir / "usr/local/bin/asus-hotkey-daemon.py").exists())
            self.assertTrue((dest_dir / "usr/local/bin/asus-touchpad-share.py").exists())
            self.assertTrue((dest_dir / f"var/lib/asus-zenbook-linux-tools/{MOCK_UID}/target_user").exists())

    def test_sound_component_failure_fails_installation(self):
        """Test SOUND-only install fails clearly when hardware probe cannot succeed."""
        with tempfile.TemporaryDirectory() as tmp:
            dest_dir = Path(tmp) / "dest"
            proc_asound_root = Path(tmp) / "proc" / "asound"
            dev_snd_root = Path(tmp) / "dev" / "snd"
            proc_asound_root.mkdir(parents=True, exist_ok=True)
            dev_snd_root.mkdir(parents=True, exist_ok=True)
            env = mock_install_env_base(
                NONINTERACTIVE_CHOICE="SOUND",
                DESTDIR=str(dest_dir),
                PROC_ASOUND_ROOT=str(proc_asound_root),
                DEV_SND_ROOT=str(dev_snd_root),
                SYSTEMCTL_CMD="true",
            )
            proc = run_e2e_command(["bash", INSTALL_SCRIPT], env=env, timeout=20)

            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("Sound fix installation failed", proc.stderr)
            self.assertIn("Installation failed with one or more component errors", proc.stderr)

    def test_strict_wmi_service_failure_exits_nonzero(self):
        """Test strict component mode surfaces WMI service restart failures."""
        with tempfile.TemporaryDirectory() as tmp:
            dest_dir = Path(tmp) / "dest"
            env = mock_install_env_base(
                NONINTERACTIVE_CHOICE="WMI",
                DESTDIR=str(dest_dir),
                SYSTEMCTL_CMD="false",
                INSTALL_STRICT_COMPONENTS="1",
            )
            proc = run_e2e_command(["bash", INSTALL_SCRIPT], env=env, timeout=20)

            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("WMI Hotkey daemon failed to restart", proc.stderr)


if __name__ == "__main__":
    unittest.main()
