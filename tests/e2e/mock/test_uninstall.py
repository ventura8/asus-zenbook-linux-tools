"""E2E tests matching uninstall.sh."""

import os
import tempfile
import unittest
from pathlib import Path

from tests.e2e.e2e_utils import assert_root_check, run_e2e_command
from tests.e2e.mock.mock_env import (
    build_uninstall_base_env,
    build_uninstall_missing_bus_env,
    build_uninstall_restore_env,
)

PROJECT_ROOT = str(Path(__file__).resolve().parents[3])
UNINSTALL_SCRIPT = os.path.join(PROJECT_ROOT, "uninstall.sh")


class TestUninstallScriptE2E(unittest.TestCase):
    """End-to-end tests for uninstall.sh script."""

    def test_root_check(self):
        """Test uninstall.sh enforces root check when run as non-root."""
        assert_root_check(self, UNINSTALL_SCRIPT)

    def test_restore_backup_without_bus_warns_and_fails(self):
        """Test uninstall fails when GNOME backup exists but D-Bus socket is missing."""
        with tempfile.TemporaryDirectory() as tmp:
            env, _dest_dir = build_uninstall_missing_bus_env(tmp)

            proc = run_e2e_command(["bash", UNINSTALL_SCRIPT], env=env, timeout=20)

            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("Warning: Skipping GNOME keybinding restore", proc.stderr)
            self.assertIn("uninstall completed with errors", proc.stderr)

    def test_uninstall_without_state_succeeds(self):
        """Test uninstall succeeds cleanly when no backup state exists."""
        with tempfile.TemporaryDirectory() as tmp:
            env, _dest_dir = build_uninstall_base_env(tmp)
            proc = run_e2e_command(["bash", UNINSTALL_SCRIPT], env=env, timeout=20)

            self.assertEqual(proc.returncode, 0)
            self.assertIn("cleanly uninstalled", proc.stdout)

    def test_restore_with_bus_succeeds_and_removes_backup(self):
        """Test uninstall restores keybindings and removes backup directory on success."""
        with tempfile.TemporaryDirectory() as tmp:
            env, _dest_dir, state_dir = build_uninstall_restore_env(tmp)
            proc = run_e2e_command(["bash", UNINSTALL_SCRIPT], env=env, timeout=20)
            self.assertEqual(proc.returncode, 0)
            self.assertIn("Restoring original GNOME keybindings", proc.stdout)
            self.assertFalse(state_dir.exists())

    def test_restore_failure_keeps_backup_for_recovery(self):
        """Test uninstall preserves backup state if gsettings restore fails."""
        with tempfile.TemporaryDirectory() as tmp:
            env, _dest_dir, state_dir = build_uninstall_restore_env(tmp, fail_set=True)
            proc = run_e2e_command(["bash", UNINSTALL_SCRIPT], env=env, timeout=20)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("failed to fully restore GNOME keybindings", proc.stderr)
            self.assertIn("uninstall completed with errors", proc.stderr)
            self.assertTrue(state_dir.exists())


if __name__ == "__main__":
    unittest.main()
