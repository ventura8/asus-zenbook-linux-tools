"""The lint driver must fail when a step's linter fails without its own exit."""

from __future__ import annotations

import subprocess
import textwrap
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]


class TestLintWaveFailurePropagation(unittest.TestCase):
    """A failing linter inside a step must stop that step and fail the wave."""

    def _run_mode(self, mode: str) -> subprocess.CompletedProcess[str]:
        """Run the wave selector with a step whose linter fails mid-body."""
        script = textwrap.dedent(
            """\
            set -euo pipefail
            source scripts/run-lints-waves.sh
            failing_linter_step() {
                false
                echo "STEP CONTINUED"
            }
            LINT_WAVE1_STEPS=(failing_linter_step)
            LINT_WAVE2_STEPS=(failing_linter_step)
            _run_selected_lint_waves
            echo "DRIVER CONTINUED"
            """
        )
        return subprocess.run(
            ["bash", "-c", script],
            cwd=REPO_ROOT,
            env={"ASUS_LINT_WAVE": mode, "PATH": "/usr/bin:/bin"},
            capture_output=True,
            text=True,
            timeout=20,
            check=False,
        )

    def test_failing_linter_fails_every_wave_mode(self) -> None:
        """No mode may print a pass line or continue past a failing linter."""
        for mode in ("cheap", "heavy", "all"):
            with self.subTest(mode=mode):
                proc = self._run_mode(mode)
                self.assertNotEqual(proc.returncode, 0, proc.stdout)
                self.assertNotIn("STEP CONTINUED", proc.stdout)
                self.assertNotIn("DRIVER CONTINUED", proc.stdout)

    def test_driver_never_calls_waves_in_a_conditional(self) -> None:
        """`||` around the wave call disables errexit inside every step subshell."""
        for rel in ("scripts/run-lints.sh", "scripts/run-lints-waves.sh"):
            text = (REPO_ROOT / rel).read_text(encoding="utf-8")
            code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
            self.assertNotIn("_run_selected_lint_waves ||", code, rel)
            self.assertNotIn('LINT_WAVE1_STEPS[@]}" ||', code, rel)


if __name__ == "__main__":
    unittest.main()
