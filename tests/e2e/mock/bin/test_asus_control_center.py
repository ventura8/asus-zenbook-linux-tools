"""E2E tests matching bin/asus-control-center.sh across all supported desktop environments."""

from __future__ import annotations

import os
import tempfile
import unittest
from collections.abc import Callable
from pathlib import Path

from tests.e2e.e2e_utils import run_e2e_command
from tests.e2e.mock.bin.mock_helpers import (
    verify_mocked_de_launcher,
    verify_mocked_gdbus_action,
)
from tests.e2e.mock.mock_de_env import (
    build_cinnamon_mock_env,
    build_kde_mock_env,
    build_lxqt_mock_env,
    build_mate_mock_env,
    build_xfce_mock_env,
)
from tests.e2e.mock.mock_env import write_executable

PROJECT_ROOT = str(Path(__file__).resolve().parents[4])
CONTROL_CENTER_SCRIPT = os.path.join(PROJECT_ROOT, "bin", "asus-control-center.sh")


class TestAsusControlCenterE2E(unittest.TestCase):
    """End-to-end tests for bin/asus-control-center.sh across desktop environments."""

    def _verify_de_settings_launch(
        self,
        env_factory: Callable[[str], tuple[dict[str, str], Path, Path, Path]],
        binary_name: str,
    ) -> None:
        """Helper to test launching DE-specific settings manager binaries."""
        verify_mocked_de_launcher(self, CONTROL_CENTER_SCRIPT, env_factory, binary_name)

    def test_usage_error_on_extra_arguments(self):
        """Test asus-control-center.sh exits with code 2 when invoked with extra arguments."""
        proc = run_e2e_command(["bash", CONTROL_CENTER_SCRIPT, "--invalid-flag"], timeout=20)
        self.assertEqual(proc.returncode, 2)
        self.assertIn("Usage:", proc.stderr)

    def test_no_session_exit(self):
        """Test asus-control-center.sh exits with code 1 when no active logind session is found."""
        with tempfile.TemporaryDirectory() as mock_bin_dir:
            loginctl_path = Path(mock_bin_dir) / "loginctl"
            write_executable(loginctl_path, "#!/bin/sh\nexit 0\n")

            env = dict(os.environ, PATH=f"{mock_bin_dir}:{os.environ.get('PATH', '')}")
            proc = run_e2e_command(["bash", CONTROL_CENTER_SCRIPT], env=env, timeout=20)
            self.assertEqual(proc.returncode, 1)
            self.assertIn("Error: No active graphical session found.", proc.stderr)

    def test_gnome_control_center_gdbus_activate(self):
        """Test asus-control-center.sh triggers GNOME Settings GDBus activate."""
        verify_mocked_gdbus_action(self, CONTROL_CENTER_SCRIPT, "org.gnome.Settings")

    def test_kde_control_center_launch(self):
        """Test asus-control-center.sh launches systemsettings on KDE."""
        self._verify_de_settings_launch(build_kde_mock_env, "systemsettings")

    def test_xfce_control_center_launch(self):
        """Test asus-control-center.sh launches xfce4-settings-manager on XFCE."""
        self._verify_de_settings_launch(build_xfce_mock_env, "xfce4-settings-manager")

    def test_lxqt_control_center_launch(self):
        """Test asus-control-center.sh launches lxqt-config on LXQt."""
        self._verify_de_settings_launch(build_lxqt_mock_env, "lxqt-config")

    def test_cinnamon_control_center_launch(self):
        """Test asus-control-center.sh launches cinnamon-settings on Cinnamon."""
        self._verify_de_settings_launch(build_cinnamon_mock_env, "cinnamon-settings")

    def test_mate_control_center_launch(self):
        """Test asus-control-center.sh launches mate-control-center on MATE."""
        self._verify_de_settings_launch(build_mate_mock_env, "mate-control-center")


if __name__ == "__main__":
    unittest.main()
