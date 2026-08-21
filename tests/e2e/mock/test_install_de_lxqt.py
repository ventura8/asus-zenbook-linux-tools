"""E2E tests for install.sh LXQt desktop integration."""

from __future__ import annotations

import os
import tempfile
import unittest

from tests.e2e.e2e_utils import PROJECT_ROOT, run_e2e_command
from tests.e2e.mock.mock_de_env import build_lxqt_mock_env

INSTALL_SCRIPT = os.path.join(PROJECT_ROOT, "install.sh")


class TestInstallLxqtDesktopE2E(unittest.TestCase):
    """End-to-end tests for LXQt desktop component installation."""

    def test_install_lxqt_shortcuts(self):
        """Test install configures LXQt global shortcuts file."""
        with tempfile.TemporaryDirectory() as tmp:
            env, _dest_dir, _mock_bin, home = build_lxqt_mock_env(tmp)
            env["NONINTERACTIVE_CHOICE"] = "DESKTOP"

            proc = run_e2e_command(["bash", INSTALL_SCRIPT], env=env, timeout=25)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("Configuring LXQt Global Keys", proc.stdout)

            conf_path = home / ".config" / "lxqt" / "globalkeyshortcuts.conf"
            self.assertTrue(conf_path.exists())
            content = conf_path.read_text(encoding="utf-8")
            self.assertIn("asus-display-mode.sh", content)


if __name__ == "__main__":
    unittest.main()
