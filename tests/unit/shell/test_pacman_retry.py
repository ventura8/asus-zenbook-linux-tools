"""Unit tests for Arch/Manjaro pacman-retry CI helper."""

import os
import tempfile
import unittest
from pathlib import Path

from tests.unit.shell.shell_test_utils import run_shell_script, write_stubs

_REPO_ROOT = Path(__file__).resolve().parents[3]
_PACMAN_RETRY = _REPO_ROOT / "docker/images/tests/scripts/pacman-retry.sh"

_PACMAN_STUB = r"""#!/bin/sh
state="${PACMAN_STUB_STATE}"
log="${PACMAN_STUB_LOG}"
: >>"$log"
case "$1" in
    -Syy)
        printf 'resync\n' >>"$log"
        exit 0
        ;;
    -Syu|-S)
        n=0
        if [ -f "$state" ]; then
            n=$(cat "$state")
        fi
        fail_times="${PACMAN_STUB_FAIL_TIMES:-0}"
        if [ "$n" -lt "$fail_times" ]; then
            echo $((n + 1)) >"$state"
            echo "error: failed retrieving file 'elfutils-0.195-8-x86_64.pkg.tar.zst'" >&2
            printf 'fail %s\n' "$1" >>"$log"
            exit 1
        fi
        printf 'ok %s\n' "$1" >>"$log"
        exit 0
        ;;
esac
echo "unexpected pacman args: $*" >&2
exit 2
"""


class TestPacmanRetry(unittest.TestCase):
    """Retry pacman transactions after rolling-mirror 404s."""

    def _run_retry(self, tmp: Path, fail_times: int, extra_env=None, args=None):
        """Run pacman-retry.sh with a stub pacman that fails *fail_times* times."""
        mock_bin = write_stubs({"pacman": _PACMAN_STUB}, tmp / "bin")
        env = os.environ.copy()
        env["PATH"] = f"{mock_bin}:{env.get('PATH', '')}"
        env["PACMAN_RETRY_SLEEP"] = "0"
        env["PACMAN_STUB_STATE"] = str(tmp / "syu_fails")
        env["PACMAN_STUB_LOG"] = str(tmp / "pacman.log")
        env["PACMAN_STUB_FAIL_TIMES"] = str(fail_times)
        if extra_env:
            env.update(extra_env)
        retry_args = ["-Syu", "--noconfirm"] if args is None else args
        return run_shell_script(_PACMAN_RETRY, env=env, timeout=10, args=retry_args)

    def test_retries_then_succeeds_after_mirror_404(self):
        """Two 404s then a hit: refresh DBs between attempts and exit 0."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp = Path(tmp_dir)
            proc = self._run_retry(tmp, fail_times=2)
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            log = (tmp / "pacman.log").read_text(encoding="utf-8")
            self.assertIn("fail -Syu", log)
            self.assertIn("resync", log)
            self.assertIn("ok -Syu", log)
            self.assertIn("pacman-retry: attempt 1/3 failed", proc.stderr)

    def test_fails_closed_after_max_attempts(self):
        """Exhausted retries must fail closed (do not swallow the last 404)."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp = Path(tmp_dir)
            proc = self._run_retry(tmp, fail_times=9, extra_env={"PACMAN_RETRY_MAX": "3"})
            self.assertEqual(proc.returncode, 1, msg=proc.stdout)
            self.assertIn("failed after 3 attempts", proc.stderr)
            log = (tmp / "pacman.log").read_text(encoding="utf-8")
            self.assertEqual(log.count("fail -Syu"), 3)
            self.assertNotIn("ok -Syu", log)

    def test_missing_args_fails_closed(self):
        """Calling the helper with no pacman argv is a usage error."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp = Path(tmp_dir)
            proc = self._run_retry(tmp, fail_times=0, args=[])
            self.assertEqual(proc.returncode, 2, msg=proc.stderr)
            self.assertIn("missing pacman arguments", proc.stderr)

    def test_invalid_retry_max_clamps_to_three(self):
        """Non-positive PACMAN_RETRY_MAX still runs the default three attempts."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp = Path(tmp_dir)
            proc = self._run_retry(tmp, fail_times=9, extra_env={"PACMAN_RETRY_MAX": "0"})
            self.assertEqual(proc.returncode, 1, msg=proc.stdout)
            self.assertIn("failed after 3 attempts", proc.stderr)
