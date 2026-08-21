"""E2E tests for install.sh Cinnamon and MATE desktop integration."""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from tests.e2e.e2e_utils import PROJECT_ROOT, run_e2e_command
from tests.e2e.mock.mock_de_env import (
    build_cinnamon_mock_env,
    build_mate_mock_env,
)
from tests.e2e.mock.mock_env import write_executable

INSTALL_SCRIPT = os.path.join(PROJECT_ROOT, "install.sh")


class TestInstallCinnamonMateDesktopE2E(unittest.TestCase):
    """End-to-end tests for Cinnamon and MATE desktop component installation."""

    def test_install_cinnamon_shortcuts(self):
        """Test install configures Cinnamon keybindings."""
        with tempfile.TemporaryDirectory() as tmp:
            env, _dest_dir, mock_bin, _home = build_cinnamon_mock_env(tmp)
            env["NONINTERACTIVE_CHOICE"] = "DESKTOP"
            recorded_calls = Path(tmp) / "cinnamon_gsettings.log"

            write_executable(
                mock_bin / "gsettings",
                "#!/bin/sh\n"
                f'echo "$@" >> "{recorded_calls}"\n'
                'case "$1" in\n'
                '  list-keys) echo "custom-list" ;;\n'
                '  get) echo "@as []" ;;\n'
                '  set|reset) exit 0 ;;\n'
                "esac\n"
                "exit 0\n",
            )

            proc = run_e2e_command(["bash", INSTALL_SCRIPT], env=env, timeout=25)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("Configuring Cinnamon shortcuts", proc.stdout)
            self.assertTrue(recorded_calls.exists())
            calls_content = recorded_calls.read_text(encoding="utf-8")
            self.assertIn("org.cinnamon.desktop.keybindings", calls_content)
            self.assertIn("set org.cinnamon.desktop.keybindings", calls_content)

    def test_install_mate_shortcuts(self):
        """Test install configures MATE keybindings."""
        with tempfile.TemporaryDirectory() as tmp:
            env, _dest_dir, mock_bin, _home = build_mate_mock_env(tmp)
            env["NONINTERACTIVE_CHOICE"] = "DESKTOP"
            recorded_calls = Path(tmp) / "mate_gsettings.log"

            write_executable(
                mock_bin / "gsettings",
                "#!/bin/sh\n"
                f'echo "$@" >> "{recorded_calls}"\n'
                'case "$1" in\n'
                '  list-keys) echo "action" ;;\n'
                '  get) echo "\'\'" ;;\n'
                '  set|reset) exit 0 ;;\n'
                "esac\n"
                "exit 0\n",
            )

            proc = run_e2e_command(["bash", INSTALL_SCRIPT], env=env, timeout=25)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("Configuring MATE shortcuts", proc.stdout)
            self.assertTrue(recorded_calls.exists())
            calls_content = recorded_calls.read_text(encoding="utf-8")
            self.assertIn("org.mate.control-center.keybinding", calls_content)
            self.assertIn("set org.mate.control-center.keybinding", calls_content)


if __name__ == "__main__":
    unittest.main()
