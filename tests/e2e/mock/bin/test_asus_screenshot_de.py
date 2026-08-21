"""E2E tests matching bin/asus-screenshot.sh across all supported desktop environments."""

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
from tests.e2e.mock.mock_env import (
    build_install_mock_env,
    write_executable,
)

PROJECT_ROOT = str(Path(__file__).resolve().parents[4])
SCREENSHOT_SCRIPT = os.path.join(PROJECT_ROOT, "bin", "asus-screenshot.sh")


class TestAsusScreenshotMultiDEE2E(unittest.TestCase):
    """End-to-end tests for bin/asus-screenshot.sh across desktop environments."""

    def _verify_de_screenshot_launch(
        self,
        env_factory: Callable[[str], tuple[dict[str, str], Path, Path, Path]],
        binary_name: str,
    ) -> None:
        """Helper to test launching DE-specific screenshot binaries."""
        verify_mocked_de_launcher(self, SCREENSHOT_SCRIPT, env_factory, binary_name)

    def test_gnome_screenshot_dbus(self):
        """Test asus-screenshot.sh triggers GNOME ShowScreenshotUI via D-Bus."""
        verify_mocked_gdbus_action(self, SCREENSHOT_SCRIPT, "ShowScreenshotUI")

    def test_kde_screenshot_spectacle(self):
        """Test asus-screenshot.sh launches Spectacle on KDE."""
        self._verify_de_screenshot_launch(build_kde_mock_env, "spectacle")

    def test_xfce_screenshot_screenshooter(self):
        """Test asus-screenshot.sh launches xfce4-screenshooter on XFCE."""
        self._verify_de_screenshot_launch(build_xfce_mock_env, "xfce4-screenshooter")

    def test_lxqt_screenshot_screengrab(self):
        """Test asus-screenshot.sh launches screengrab on LXQt."""
        self._verify_de_screenshot_launch(build_lxqt_mock_env, "screengrab")

    def test_cinnamon_screenshot_gnome_screenshot(self):
        """Test asus-screenshot.sh launches gnome-screenshot on Cinnamon."""
        self._verify_de_screenshot_launch(build_cinnamon_mock_env, "gnome-screenshot")

    def test_mate_screenshot_mate_screenshot(self):
        """Test asus-screenshot.sh launches mate-screenshot on MATE."""
        self._verify_de_screenshot_launch(build_mate_mock_env, "mate-screenshot")

    def test_portal_screenshot_fallback(self):
        """Test asus-screenshot.sh falls back to FreeDesktop Portal when specific DE tools fail."""
        with tempfile.TemporaryDirectory() as tmp:
            env, _dest_dir, mock_bin = build_install_mock_env(tmp)
            env["XDG_CURRENT_DESKTOP"] = "UnknownDE"
            env["ASUS_SCREENSHOT_DISABLE_KEYCHORD"] = "1"
            recorded_calls = Path(tmp) / "portal_calls.log"

            write_executable(
                mock_bin / "gdbus",
                "#!/bin/sh\n"
                f'echo "$@" >> "{recorded_calls}"\n'
                'for arg in "$@"; do\n'
                '  if [ "$arg" = "org.freedesktop.portal.Desktop" ]; then exit 0; fi\n'
                "done\n"
                "exit 1\n",
            )

            proc = run_e2e_command(["bash", SCREENSHOT_SCRIPT], env=env, timeout=25)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertTrue(recorded_calls.exists())
            content = recorded_calls.read_text(encoding="utf-8")
            self.assertIn("org.freedesktop.portal.Desktop", content)


if __name__ == "__main__":
    unittest.main()
