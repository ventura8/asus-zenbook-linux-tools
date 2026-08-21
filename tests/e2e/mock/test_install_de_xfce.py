"""E2E tests for install.sh XFCE desktop integration."""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from tests.e2e.e2e_utils import PROJECT_ROOT, run_e2e_command
from tests.e2e.mock.mock_de_env import build_xfce_mock_env
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
                'case "$1" in\n'
                '  -c)\n'
                '    case "$3" in\n'
                "      -p)\n"
                '        if [ "$5" = "-s" ] || [ "$5" = "--set" ]; then exit 0; fi\n'
                '        if [ "$5" = "-r" ] || [ "$5" = "--reset" ]; then exit 0; fi\n'
                '        if [ "$5" = "-n" ] || [ "$5" = "--create" ]; then exit 0; fi\n'
                '        if [ "$#" -le 4 ]; then echo "mock_val"; exit 0; fi\n'
                "        ;;\n"
                "      -l|--list) exit 0 ;;\n"
                "    esac\n"
                "    ;;\n"
                "  --version) echo 'xfconf-query 4.18.0'; exit 0 ;;\n"
                "  *) exit 1 ;;\n"
                "esac\n"
                "exit 1\n",
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
