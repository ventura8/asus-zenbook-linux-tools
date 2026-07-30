"""Real-system E2E tests for uninstall.sh.

These tests intentionally exercise the host system and are only meant to run
through scripts/run_real_e2e.sh with explicit opt-in.
"""

import os
import unittest

from tests.e2e.e2e_utils import (
    E2E_OWNED_SENTINEL,
    INSTALL_MARKERS,
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


class TestUninstallScriptRealE2E(unittest.TestCase):
    """Real-system smoke tests for uninstall.sh."""

    def setUp(self):
        require_real_system_mode(self)
        if os.geteuid():
            self.skipTest("Real-system uninstaller tests require root")
        if os.environ.get("E2E_REAL_ALLOW_DESTRUCTIVE_UNINSTALL") != "1":
            self.skipTest("Set E2E_REAL_ALLOW_DESTRUCTIVE_UNINSTALL=1 for destructive real uninstall")

    def test_uninstall_real_system(self):
        """Preflight clean host, install with sentinel, then destructive uninstall."""
        timeout_seconds = e2e_test_timeout_seconds(default=120, allow_real=True)
        install_env = dict(
            os.environ,
            SKIP_PKG_INSTALL="1",
            NONINTERACTIVE_CHOICE="WMI TOUCHPAD",
        )
        uninstall_env = dict(os.environ, SKIP_PKG_REMOVE="1")

        assert_host_clean(self)
        self.assertFalse(E2E_OWNED_SENTINEL.is_file())
        host_verified_clean = {"value": False}

        def _cleanup_when_host_not_verified_clean() -> None:
            if host_verified_clean["value"]:
                return
            restore_host_if_dirty(UNINSTALL_SCRIPT, timeout_seconds)

        # Cleanup runs LIFO: register unlink first so restore runs while sentinel exists.
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        E2E_OWNED_SENTINEL.write_text("asus-zenbook-linux-tools-e2e\n", encoding="utf-8")
        self.addCleanup(E2E_OWNED_SENTINEL.unlink, missing_ok=True)
        self.addCleanup(_cleanup_when_host_not_verified_clean)

        install_proc = run_e2e_command(
            ["bash", INSTALL_SCRIPT],
            env=install_env,
            timeout=timeout_seconds,
            allow_real=True,
        )
        self.assertEqual(install_proc.returncode, 0, install_proc.stderr)
        self.assertIn("Installation complete.", install_proc.stdout)

        proc = run_e2e_command(
            ["bash", UNINSTALL_SCRIPT],
            env=uninstall_env,
            timeout=timeout_seconds,
            allow_real=True,
        )

        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("cleanly uninstalled", proc.stdout)

        for path in INSTALL_MARKERS:
            self.assertFalse(path.exists(), f"Expected removed path to be absent: {path}")
        self.assertFalse(STATE_DIR.exists(), f"Expected state directory to be absent: {STATE_DIR}")

        host_verified_clean["value"] = True


if __name__ == "__main__":
    unittest.main()
