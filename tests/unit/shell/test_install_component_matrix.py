"""Combinatorial install component selection matrix tests."""

from __future__ import annotations

import shutil
import unittest
from pathlib import Path

from tests.unit.shell.shell_install_test_base import InstallTestBase
from tests.unit.shell.shell_test_utils import run_shell_script

_COMPONENTS = ("WMI", "TOUCHPAD", "SOUND", "DESKTOP")
_WMI_BIN = "asus-hotkey-daemon.py"
_TOUCHPAD_BIN = "asus-touchpad-share.py"
_SOUND_BIN = "asus-sound-fix.sh"
_WMI_UNIT = "asus-hotkey-daemon.service"
_TOUCHPAD_UNIT = "asus-touchpad-share.service"
_SOUND_UNIT = "asus-sound-fix.service"
_SHARED_LIB = "asus-bootstrap.sh"
_DESKTOP_STATE = Path("var/lib/asus-zenbook-linux-tools/1000/target_user")


def _choice_from_mask(mask: int) -> str:
    selected = [_COMPONENTS[index] for index in range(4) if mask & (1 << index)]
    return " ".join(selected)


class TestInstallComponentMatrix(InstallTestBase):
    """Exercise all sixteen component subsets via NONINTERACTIVE_CHOICE."""

    @property
    def lib_dir(self) -> Path:
        """DESTDIR library install path for shared helpers."""
        return self.dest_dir / "usr/local/lib/asus-zenbook-linux-tools"

    def _fresh_install_tree(self) -> None:
        """Remove prior DESTDIR artifacts so each matrix cell starts clean."""
        shutil.rmtree(self.dest_dir, ignore_errors=True)
        self.dest_dir.mkdir(parents=True, exist_ok=True)
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self.sys_dir.mkdir(parents=True, exist_ok=True)
        self.hook_dir.mkdir(parents=True, exist_ok=True)

    def _prepare_environment(self, mask: int) -> dict:
        environment = self._build_install_env(_choice_from_mask(mask) if mask else "")
        if mask & 0x4:
            self._setup_sound_install_stubs(environment)
        if mask & 0x8:
            self._setup_gnome_install_stubs(environment)
        return environment

    def _assert_empty_matrix_install(self, stdout: str) -> None:
        """Empty selection is a no-op with no numbered steps or artifacts."""
        self.assertIn("No components were selected. Nothing was installed.", stdout)
        self.assertNotIn("ASUS ZenBook Linux Tools is ready to use.", stdout)
        self.assertNotIn("[1/", stdout)
        self.assertFalse((self.bin_dir / _WMI_BIN).exists())
        self.assertFalse((self.lib_dir / _SHARED_LIB).exists())

    def _assert_selected_matrix_install(self, stdout: str, mask: int) -> None:
        """Selected components deploy matching artifacts and dynamic [n/m] steps."""
        self.assertIn("Install scripts and services", stdout)
        self.assertIn("Installation complete.", stdout)
        self.assertTrue((self.lib_dir / _SHARED_LIB).exists())
        self.assertNotRegex(stdout, r"\[\d+/4\]")
        self.assertEqual((self.bin_dir / _WMI_BIN).exists(), bool(mask & 0x1))
        self.assertEqual((self.sys_dir / _WMI_UNIT).exists(), bool(mask & 0x1))
        self.assertEqual((self.bin_dir / _TOUCHPAD_BIN).exists(), bool(mask & 0x2))
        self.assertEqual((self.sys_dir / _TOUCHPAD_UNIT).exists(), bool(mask & 0x2))
        self.assertEqual((self.bin_dir / _SOUND_BIN).exists(), bool(mask & 0x4))
        self.assertEqual((self.sys_dir / _SOUND_UNIT).exists(), bool(mask & 0x4))
        self.assertEqual((self.dest_dir / _DESKTOP_STATE).exists(), bool(mask & 0x8))
        expected_steps = 1 + int(bool(mask & 0x8))
        self.assertRegex(stdout, rf"\[1/{expected_steps}\]")
        self._assert_desktop_second_step(stdout, expected_steps, mask)

    def _assert_desktop_second_step(self, stdout: str, expected_steps: int, mask: int) -> None:
        """DESKTOP adds a second numbered configure step."""
        if mask & 0x8:
            self.assertRegex(stdout, rf"\[2/{expected_steps}\]")

    def _run_matrix_cell(self, mask: int) -> None:
        """Install one component mask and assert DESTDIR artifacts."""
        self._fresh_install_tree()
        environment = self._prepare_environment(mask)
        proc = run_shell_script(self.script_path, env=environment, timeout=30)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        if mask == 0:
            self._assert_empty_matrix_install(proc.stdout)
            return
        self._assert_selected_matrix_install(proc.stdout, mask)

    def test_all_sixteen_component_combinations(self):
        """Every subset (including none) installs only the selected artifacts."""
        for mask in range(16):
            with self.subTest(mask=mask, choice=_choice_from_mask(mask)):
                self._run_matrix_cell(mask)

    def test_none_token_matches_empty_selection(self):
        """Explicit none token is a successful no-op install."""
        environment = self._build_install_env("none")
        proc = run_shell_script(self.script_path, env=environment, timeout=20)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("No components were selected. Nothing was installed.", proc.stdout)
        self.assertFalse((self.bin_dir / _WMI_BIN).exists())


class TestInstallDynamicProgress(InstallTestBase):
    """Dynamic step totals when package install is enabled."""

    def test_wmi_only_with_pkg_install_uses_two_steps(self):
        """Deps + scripts print [1/2] and [2/2] when SKIP_PKG_INSTALL is unset."""
        environment = self._build_install_env("WMI")
        environment["SKIP_PKG_INSTALL"] = "0"
        environment["INSTALL_OS_ID"] = "ubuntu"
        self._prepend_apt_stubs(environment, dpkg_query_exit=0)

        proc = run_shell_script(self.script_path, env=environment, timeout=20)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertRegex(proc.stdout, r"\[1/2\] Install system dependencies")
        self.assertRegex(proc.stdout, r"\[2/2\] Install scripts and services")
        self.assertNotRegex(proc.stdout, r"\[3/")


if __name__ == "__main__":
    unittest.main()
