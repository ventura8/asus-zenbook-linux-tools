"""Unit tests for E2E command helper timeout handling."""

import os
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tests.e2e.e2e_utils import run_e2e_command


class TestE2EUtils(unittest.TestCase):
    """Validate timeout parsing behavior in E2E helpers."""

    def setUp(self):
        """Create an isolated temp log directory outside the repository tree."""
        self._log_dir = tempfile.mkdtemp(prefix="e2e-log-")
        self.addCleanup(shutil.rmtree, self._log_dir, ignore_errors=True)

    def _env_with_log_dir(self, **extra: str) -> dict[str, str]:
        """Return a copy of os.environ with E2E_LOG_DIR pointed at the temp log root."""
        env = os.environ.copy()
        env["E2E_LOG_DIR"] = self._log_dir
        env.update(extra)
        return env

    def test_invalid_env_timeout_raises_assertion(self):
        """Non-numeric E2E_TEST_TIMEOUT must raise the existing assertion format."""
        with (
            patch.dict(os.environ, {"E2E_TEST_TIMEOUT": "abc"}, clear=False),
            self.assertRaisesRegex(AssertionError, r"Invalid timeout budget: abcs"),
        ):
            run_e2e_command(["true"], timeout=None, env=self._env_with_log_dir())

    def test_valid_env_timeout_is_accepted(self):
        """Numeric E2E_TEST_TIMEOUT within bounds is used when timeout is omitted."""
        with patch.dict(os.environ, {"E2E_TEST_TIMEOUT": "25"}, clear=False):
            proc = run_e2e_command(["true"], timeout=None, env=self._env_with_log_dir())
        self.assertEqual(proc.returncode, 0)

    def test_run_e2e_command_writes_stable_log_file(self):
        """E2E runs tee captured output under E2E_LOG_DIR with a stable basename."""
        proc = run_e2e_command(["true"], env=self._env_with_log_dir(), log_name="unit-true")
        self.assertEqual(proc.returncode, 0)
        log_path = Path(self._log_dir) / "unit-true.log"
        self.assertTrue(log_path.is_file())
        self.assertIn("# true", log_path.read_text(encoding="utf-8"))

    def test_zero_env_timeout_raises_assertion(self):
        """Zero E2E_TEST_TIMEOUT is rejected by the budget validator."""
        with (
            patch.dict(os.environ, {"E2E_TEST_TIMEOUT": "0"}, clear=False),
            self.assertRaisesRegex(AssertionError, r"Invalid timeout budget: 0s"),
        ):
            run_e2e_command(["true"], timeout=None, env=self._env_with_log_dir())

    def test_negative_env_timeout_raises_assertion(self):
        """Negative E2E_TEST_TIMEOUT is rejected by the budget validator."""
        with (
            patch.dict(os.environ, {"E2E_TEST_TIMEOUT": "-1"}, clear=False),
            self.assertRaisesRegex(AssertionError, r"Invalid timeout budget: -1s"),
        ):
            run_e2e_command(["true"], timeout=None, env=self._env_with_log_dir())

    def test_string_command_is_rejected(self):
        """Shell strings must not be passed where argv sequences are required."""
        with self.assertRaisesRegex(TypeError, "sequence of argv tokens"):
            run_e2e_command("true", env=self._env_with_log_dir())


if __name__ == "__main__":
    unittest.main()
