"""Real-system E2E tests for ASUS CLI utilities.

These tests intentionally exercise the host system and are only meant to run
through scripts/run_real_e2e.sh with explicit opt-in.
"""

from __future__ import annotations

import os
import unittest

from tests.e2e.e2e_utils import (
    PROJECT_ROOT,
    e2e_test_timeout_seconds,
    require_real_system_mode,
    run_e2e_command,
)

DISPLAY_MODE_SCRIPT = os.path.join(PROJECT_ROOT, "bin", "asus-display-mode.sh")
CONTROL_CENTER_SCRIPT = os.path.join(PROJECT_ROOT, "bin", "asus-control-center.sh")
SCREENSHOT_SCRIPT = os.path.join(PROJECT_ROOT, "bin", "asus-screenshot.sh")


class TestToolsRealE2E(unittest.TestCase):
    """Real-system smoke tests for CLI utilities."""

    def setUp(self):
        require_real_system_mode(self)
        if os.geteuid():
            self.skipTest("Real-system CLI tests require root")

    def test_display_mode_cancel_osd_real(self):
        """Test asus-display-mode.sh --cancel-osd runs cleanly on real host."""
        timeout_seconds = e2e_test_timeout_seconds(default=30, allow_real=True)
        proc = run_e2e_command(
            ["bash", DISPLAY_MODE_SCRIPT, "--cancel-osd"],
            timeout=timeout_seconds,
            allow_real=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)


if __name__ == "__main__":
    unittest.main()
