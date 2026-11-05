"""E2E tests for install.sh XFCE desktop integration."""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from tests.e2e.e2e_utils import PROJECT_ROOT, run_e2e_command
from tests.e2e.mock.mock_de_env import XFCONF_STUB_CASE_ARMS, build_xfce_mock_env
from tests.e2e.mock.mock_env import write_executable

INSTALL_SCRIPT = os.path.join(PROJECT_ROOT, "install.sh")


class TestInstallXfceDesktopE2E(unittest.TestCase):
    """End-to-end tests for XFCE desktop component installation."""

    def test_install_xfce_shortcuts(self):
        """Test install configures XFCE keyboard shortcuts via xfconf-query."""
        with tempfile.TemporaryDirectory() as tmp:
            env, _dest_dir, mock_bin, _home = build_xfce_mock_env(tmp)
            env["NONINTERACTIVE_CHOICE"] = "DESKTOP"
            recorded_calls = Path(tmp) / "xfconf_calls.log"

            write_executable(
                mock_bin / "xfconf-query",
                "#!/bin/sh\n"
                f'echo "$@" >> "{recorded_calls}"\n'
                + XFCONF_STUB_CASE_ARMS
                + "  *) exit 1 ;;\nesac\nexit 1\n",
            )

            proc = run_e2e_command(["bash", INSTALL_SCRIPT], env=env, timeout=25)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("Configuring XFCE shortcuts", proc.stdout)
            self.assertTrue(recorded_calls.exists())
            calls_content = recorded_calls.read_text(encoding="utf-8")
            self.assertIn("xfce4-keyboard-shortcuts", calls_content)
            self.assertIn("/commands/custom/", calls_content)
            self.assertIn("asus-display-mode.sh", calls_content)


if __name__ == "__main__":
    unittest.main()
