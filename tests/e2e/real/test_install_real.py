"""Real-system E2E tests for install.sh.

These tests intentionally exercise the host system and are only meant to run
through scripts/run_real_e2e.sh with explicit opt-in.
"""

import os
import unittest
from pathlib import Path

from tests.e2e.e2e_utils import (
    E2E_OWNED_SENTINEL,
    PROJECT_ROOT,
    STATE_DIR,
    assert_host_clean,
    e2e_test_timeout_seconds,
    require_real_system_mode,
    restore_host_if_dirty,
    run_e2e_command,
)

INSTALL_SCRIPT = os.path.join(PROJECT_ROOT, "install.sh")
UNINSTALL_SCRIPT = os.path.join(PROJECT_ROOT, "uninstall.sh")


class TestInstallScriptRealE2E(unittest.TestCase):
    """Real-system smoke tests for install.sh."""

    def setUp(self):
        require_real_system_mode(self)
        if os.geteuid():
            self.skipTest("Real-system installer tests require root")

    def test_install_wmi_touchpad_components(self):
        """Install WMI and TOUCHPAD components on the real host setup."""
        timeout_seconds = e2e_test_timeout_seconds(default=120, allow_real=True)
        env = dict(
            os.environ,
            SKIP_PKG_INSTALL="1",
            NONINTERACTIVE_CHOICE="WMI TOUCHPAD",
        )

        assert_host_clean(self)
        # Cleanup runs LIFO: register unlink first so restore_host_if_dirty runs
        # while the sentinel still exists, then the sentinel is removed.
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        E2E_OWNED_SENTINEL.write_text("asus-zenbook-linux-tools-e2e\n", encoding="utf-8")
        self.addCleanup(E2E_OWNED_SENTINEL.unlink, missing_ok=True)
        self.addCleanup(restore_host_if_dirty, UNINSTALL_SCRIPT, timeout_seconds)
        proc = run_e2e_command(
            ["bash", INSTALL_SCRIPT],
            env=env,
            timeout=timeout_seconds,
            allow_real=True,
        )

        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("Installation complete.", proc.stdout)
        self.assertTrue(Path("/usr/local/bin/asus-hotkey-daemon.py").is_file())
        self.assertTrue(Path("/usr/local/bin/asus-touchpad-share.py").is_file())
        self.assertTrue(Path("/etc/systemd/system/asus-hotkey-daemon.service").is_file())
        self.assertTrue(Path("/etc/systemd/system/asus-touchpad-share.service").is_file())


if __name__ == "__main__":
    unittest.main()
