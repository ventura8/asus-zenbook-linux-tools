"""Comprehensive E2E install/uninstall tests with minimal mocking.

Only genuinely unavoidable constraints are mocked:
  - systemctl   — no systemd PID 1 in Docker
  - loginctl    — no systemd-logind in Docker
  - Sound hw    — no real /proc/asound or /dev/snd in Docker

Everything else is real: file I/O via DESTDIR, package-manager detection,
gsettings against the live D-Bus session, all bash utilities.
"""

import os
import py_compile
import shlex
import shutil
import stat
import tempfile
import unittest
from collections.abc import Sequence
from pathlib import Path

from tests.e2e.e2e_utils import run_e2e_command
from tests.e2e.mock.mock_env import build_minimal_mock_env, install_uninstall_mock_systemctl

PROJECT_ROOT = Path(__file__).resolve().parents[3]
INSTALL_SCRIPT = str(PROJECT_ROOT / "install.sh")
UNINSTALL_SCRIPT = str(PROJECT_ROOT / "uninstall.sh")

# Binaries that every install deploys
_WMI_BINS = [
    "asus-hotkey-daemon.py",
    "asus_hotkey_daemon.py",
    "asus_hotkey_daemon_impl.py",
    "asus_hotkey_daemon_input.py",
    "asus_hotkey_daemon_brightness.py",
    "asus_hotkey_daemon_at_proxy.py",
    "asus_hotkey_daemon_osd.py",
    "asus_hotkey_daemon_monitor.py",
    "asus_hotkey_daemon_runtime.py",
    "asus_hotkey_daemon_session.py",
    "asus_hotkey_daemon_topology_detect.py",
    "asus_hotkey_daemon_desktop_family.py",
    "asus_hotkey_daemon_topology.py",
    "asus_hotkey_daemon_threading.py",
    "asus_hotkey_daemon_window_move.py",
    "asus_hotkey_daemon_window_swap_gnome.py",
    "asus_hotkey_daemon_window_swap.py",
    "asus_hotkey_daemon_state.py",
    "asus_hotkey_daemon_xrandr.py",
    "asus_common.py",
    "asus_i18n.py",
    "shared_imports.py",
    "asus-screenshot.sh",
    "asus-control-center.sh",
    "asus-screenpad-toggle.sh",
    "asus-screenpad-brightness.sh",
    "asus-fan-toggle.sh",
    "asus-camera-toggle.sh",
    "asus-display-mode.sh",
    "asus_display_mode.py",
    "asus_display_mode_core.py",
    "asus_display_mode_layout.py",
    "asus_display_mode_profiles.py",
]
# Touchpad listener binaries (see lib/install-components.sh deploy_touchpad_component).
_TOUCHPAD_BINS = ["asus-touchpad-share.py", "asus_touchpad_share.py", "asus_touchpad_share_bounds.py"]
_SOUND_BINS = ["asus-sound-fix.sh", "asus_hda_verb.py"]
_SHARED_LIBS = [
    "asus-session.sh",
    "asus-i18n.sh",
    "asus-common.sh",
    "asus-notif-icons.sh",
    "asus-bootstrap.sh",
    "asus-display-mutter.sh",
    "asus-display-state.sh",
    "asus-display-watchdog.sh",
    "asus-display-osd.sh",
]
_WMI_UNITS = ["asus-hotkey-daemon.service"]
_TOUCHPAD_UNITS = ["asus-touchpad-share.service"]
_SOUND_UNITS = ["asus-sound-fix.service"]
_SOUND_HOOKS = ["asus-sound-fix"]
# Deployed modules that stay non-executable (not in wmi chmod entrypoints).
_BIN_LIBRARY_ONLY = frozenset(
    {
        "asus_common.py",
        "asus_i18n.py",
        "asus_display_mode_core.py",
        "asus_display_mode_layout.py",
        "asus_display_mode_profiles.py",
        "asus_hotkey_daemon_threading.py",
        "asus_hotkey_daemon_window_move.py",
        "asus_hotkey_daemon_xrandr.py",
        "asus_touchpad_share_bounds.py",
        "shared_imports.py",
    }
)


class TestComprehensiveInstall(unittest.TestCase):
    """Comprehensive install/uninstall E2E using minimal mocking."""

    @classmethod
    def setUpClass(cls):
        """Install one shared DESTDIR tree for artifact validation tests."""
        cls._shared_install_tmp = tempfile.mkdtemp()
        cls.addClassCleanup(shutil.rmtree, cls._shared_install_tmp, True)
        cls._shared_install_env, cls._shared_install_dest, _ = build_minimal_mock_env(cls._shared_install_tmp)
        cls._shared_install_env["NONINTERACTIVE_CHOICE"] = "WMI TOUCHPAD SOUND"
        proc = run_e2e_command(["bash", INSTALL_SCRIPT], env=cls._shared_install_env, timeout=30)
        if proc.returncode:
            raise AssertionError(f"Shared DESTDIR install failed: {proc.stderr}")

    def setUp(self):
        self._tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self._tmp, True)

    def _assert_bins_deployed(self, dest: Path, bins: Sequence[str]) -> None:
        bin_dir = dest / "usr/local/bin"
        for b in bins:
            self.assertTrue((bin_dir / b).exists(), f"Missing binary: {b}")
            if b in _BIN_LIBRARY_ONLY:
                self.assertFalse(
                    (bin_dir / b).stat().st_mode & stat.S_IXUSR,
                    f"Library-only binary must not be executable: {b}",
                )
            else:
                self.assertTrue((bin_dir / b).stat().st_mode & stat.S_IXUSR, f"Not executable: {b}")

    def _assert_files_deployed(
        self,
        dest: Path,
        bins: Sequence[str],
        libs: Sequence[str],
        units: Sequence[str],
    ) -> None:
        self._assert_bins_deployed(dest, bins)
        lib_dir = dest / "usr/local/lib/asus-zenbook-linux-tools"
        sys_dir = dest / "etc/systemd/system"
        for lib in libs:
            self.assertTrue((lib_dir / lib).exists(), f"Missing lib: {lib}")
        for u in units:
            self.assertTrue((sys_dir / u).exists(), f"Missing unit: {u}")

    def test_wmi_component_deploys_all_artifacts(self):
        """WMI install deploys all hotkey daemon binaries, shared libs, and unit file."""
        env, dest, _ = build_minimal_mock_env(self._tmp)
        env["NONINTERACTIVE_CHOICE"] = "WMI"
        proc = run_e2e_command(["bash", INSTALL_SCRIPT], env=env, timeout=30)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("WMI Hotkey daemon installed", proc.stdout)
        self._assert_files_deployed(dest, _WMI_BINS, _SHARED_LIBS, _WMI_UNITS)
        for name in (
            "asus-screenpad-on-symbolic",
            "asus-screenpad-toggle-symbolic",
            "asus-camera-on-symbolic",
            "asus-camera-toggle-symbolic",
        ):
            self.assertTrue(
                (dest / "usr/local/share/icons/hicolor/scalable/apps" / f"{name}.svg").is_file(),
                f"Missing keycap symbolic icon: {name}.svg",
            )
            self.assertTrue(
                (dest / "usr/local/share/asus-zenbook-linux-tools/icons" / f"{name}.svg").is_file(),
                f"Missing ScreenPad/camera share icon: {name}.svg",
            )

    def test_touchpad_component_deploys_all_artifacts(self):
        """TOUCHPAD install deploys listener binary and unit file."""
        env, dest, _ = build_minimal_mock_env(self._tmp)
        env["NONINTERACTIVE_CHOICE"] = "TOUCHPAD"
        proc = run_e2e_command(["bash", INSTALL_SCRIPT], env=env, timeout=30)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("Touchpad Share gesture listener installed", proc.stdout)
        self._assert_files_deployed(dest, _TOUCHPAD_BINS, _SHARED_LIBS, _TOUCHPAD_UNITS)

    def test_sound_component_deploys_all_artifacts(self):
        """SOUND install deploys script, unit file, and suspend hook."""
        env, dest, _ = build_minimal_mock_env(self._tmp)
        env["NONINTERACTIVE_CHOICE"] = "SOUND"
        proc = run_e2e_command(["bash", INSTALL_SCRIPT], env=env, timeout=30)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("Sound fix installed", proc.stdout)
        self._assert_files_deployed(dest, _SOUND_BINS, _SHARED_LIBS, _SOUND_UNITS)
        hook = dest / "lib/systemd/system-sleep/asus-sound-fix"
        self.assertTrue(hook.exists(), "Missing suspend hook")
        self.assertTrue(hook.stat().st_mode & stat.S_IXUSR, "Suspend hook not executable")

    def test_full_install_all_components_succeeds(self):
        """Full install of all four components produces all expected artifacts."""
        env, dest, _ = build_minimal_mock_env(self._tmp)
        env["NONINTERACTIVE_CHOICE"] = "WMI TOUCHPAD SOUND GNOME"
        proc = run_e2e_command(["bash", INSTALL_SCRIPT], env=env, timeout=30)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("Installation complete.", proc.stdout)
        all_bins = _WMI_BINS + _TOUCHPAD_BINS + _SOUND_BINS
        all_units = _WMI_UNITS + _TOUCHPAD_UNITS + _SOUND_UNITS
        self._assert_files_deployed(dest, all_bins, _SHARED_LIBS, all_units)

    def test_unit_files_have_required_systemd_directives(self):
        """Installed unit files contain required [Unit], [Service], [Install] sections."""
        dest = self._shared_install_dest
        sys_dir = dest / "etc/systemd/system"
        for unit in _WMI_UNITS + _TOUCHPAD_UNITS + _SOUND_UNITS:
            content = (sys_dir / unit).read_text(encoding="utf-8")
            self.assertIn("[Unit]", content, f"{unit} missing [Unit]")
            self.assertIn("[Service]", content, f"{unit} missing [Service]")
            self.assertIn("[Install]", content, f"{unit} missing [Install]")

    def _assert_keycap_icons_removed(self, dest: Path) -> None:
        """Assert keycap icons are gone from both installed locations."""
        icon_dirs = (
            dest / "usr/local/share/icons/hicolor/scalable/apps",
            dest / "usr/local/share/asus-zenbook-linux-tools/icons",
        )
        icon_names = (
            "asus-screenpad-on-symbolic.svg",
            "asus-screenpad-toggle-symbolic.svg",
            "asus-camera-on-symbolic.svg",
            "asus-camera-toggle-symbolic.svg",
        )
        for icon_dir in icon_dirs:
            for icon_name in icon_names:
                self.assertFalse(
                    (icon_dir / icon_name).exists(),
                    f"Stale icon after uninstall: {icon_name}",
                )

    def _assert_roundtrip_artifacts_removed(self, dest: Path) -> None:
        """Assert WMI/TOUCHPAD/SOUND DESTDIR artifacts are gone after uninstall."""
        bins = _WMI_BINS + _TOUCHPAD_BINS + _SOUND_BINS
        units = _WMI_UNITS + _TOUCHPAD_UNITS + _SOUND_UNITS
        bin_dir = dest / "usr/local/bin"
        for name in bins:
            self.assertFalse((bin_dir / name).exists(), f"Stale artifact after uninstall: {name}")
        lib_dir = dest / "usr/local/lib/asus-zenbook-linux-tools"
        for lib in _SHARED_LIBS:
            self.assertFalse((lib_dir / lib).exists(), f"Stale lib after uninstall: {lib}")
        sys_dir = dest / "etc/systemd/system"
        for unit in units:
            self.assertFalse((sys_dir / unit).exists(), f"Stale unit after uninstall: {unit}")
        hook_dir = dest / "lib/systemd/system-sleep"
        for hook in _SOUND_HOOKS:
            self.assertFalse((hook_dir / hook).exists(), f"Stale hook after uninstall: {hook}")
        self._assert_keycap_icons_removed(dest)

    def test_install_then_uninstall_roundtrip_leaves_no_artifacts(self):
        """Install followed by uninstall leaves the DESTDIR completely clean."""
        env, dest, _ = build_minimal_mock_env(self._tmp)
        env["NONINTERACTIVE_CHOICE"] = "WMI TOUCHPAD SOUND"
        install_proc = run_e2e_command(["bash", INSTALL_SCRIPT], env=env, timeout=30)
        self.assertEqual(install_proc.returncode, 0, install_proc.stderr)
        all_bins = _WMI_BINS + _TOUCHPAD_BINS + _SOUND_BINS
        all_units = _WMI_UNITS + _TOUCHPAD_UNITS + _SOUND_UNITS
        self._assert_files_deployed(dest, all_bins, _SHARED_LIBS, all_units)

        # Uninstall validates that services become inactive after stop.
        (Path(self._tmp) / "uninstall-mock-bin").mkdir(parents=True, exist_ok=True)
        uninstall_systemctl = install_uninstall_mock_systemctl(Path(self._tmp) / "uninstall-mock-bin")

        uninstall_env = dict(env)
        uninstall_env["SKIP_PKG_REMOVE"] = "1"
        uninstall_env["SYSTEMCTL_CMD"] = str(uninstall_systemctl)
        uninstall_env.pop("USER", None)
        uninstall_env.pop("SUDO_USER", None)
        uninstall_proc = run_e2e_command(["bash", UNINSTALL_SCRIPT], env=uninstall_env, timeout=30)
        self.assertEqual(uninstall_proc.returncode, 0, uninstall_proc.stderr)
        self.assertIn("cleanly uninstalled", uninstall_proc.stdout)
        self._assert_roundtrip_artifacts_removed(dest)
        state_root = dest / "var/lib/asus-zenbook-linux-tools"
        self.assertFalse(state_root.exists(), "Install state dir should be removed after uninstall")

    @unittest.skipUnless(
        os.path.exists("/.dockerenv") or os.path.exists("/run/.containerenv"),
        "package manager detection per distro requires a container environment",
    )
    def test_package_manager_detection_per_distro(self):
        """Package manager detection uses the host distro family tool, not Ubuntu mocks."""
        env, _dest, mock_bin = build_minimal_mock_env(self._tmp)
        env.pop("INSTALL_OS_ID", None)
        env.pop("INSTALL_OS_ID_LIKE", None)
        for stub_name in ("apt-get", "apt", "dpkg"):
            stub_path = mock_bin / stub_name
            if stub_path.exists():
                stub_path.unlink()
        detect_cmd = (
            f"source {shlex.quote(INSTALL_SCRIPT)}; "
            "family=$(_detect_os_family); "
            'echo "FAMILY:${family:-NONE}"; '
            "if _has_supported_pkg_manager; then echo TOOL:OK; else echo TOOL:NONE; fi"
        )
        proc = run_e2e_command(["bash", "-c", detect_cmd], env=env, timeout=20)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertRegex(proc.stdout, r"FAMILY:(debian|suse|redhat|arch)")
        self.assertIn("TOOL:OK", proc.stdout)
        self.assertNotIn("TOOL:NONE", proc.stdout)

    def test_installed_shell_scripts_are_valid_bash(self):
        """All installed shell scripts pass bash -n syntax check."""
        dest = self._shared_install_dest
        bin_dir = dest / "usr/local/bin"
        lib_dir = dest / "usr/local/lib/asus-zenbook-linux-tools"
        shell_scripts = list(bin_dir.glob("*.sh")) + list(lib_dir.glob("*.sh"))
        self.assertGreater(len(shell_scripts), 0, "No shell scripts deployed")
        for script in shell_scripts:
            check = run_e2e_command(
                ["bash", "-n", str(script)],
                timeout=20,
                log_name=f"bash-n-{script.name}",
            )
            self.assertEqual(check.returncode, 0, f"bash -n failed for {script.name}: {check.stderr}")

    def test_installed_python_modules_compile(self):
        """All installed product Python modules pass py_compile."""
        dest = self._shared_install_dest
        bin_dir = dest / "usr/local/bin"
        py_files = list(bin_dir.glob("*.py"))
        self.assertGreater(len(py_files), 0, "No Python files deployed")
        with tempfile.TemporaryDirectory() as cdir:
            for py_file in py_files:
                cfile = str(Path(cdir) / f"{py_file.name}c")
                try:
                    py_compile.compile(str(py_file), cfile=cfile, doraise=True)
                except py_compile.PyCompileError as exc:
                    self.fail(f"py_compile failed for {py_file.name}: {exc}")


if __name__ == "__main__":
    unittest.main()
