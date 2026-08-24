"""Unit tests for LXQt conf snapshot missing vs read-failure behavior."""

from __future__ import annotations

import shlex
import tempfile
import unittest
from pathlib import Path

from tests.unit.shell.shell_test_utils import PROJECT_ROOT, run_bash_c

_LXQT_LIB = PROJECT_ROOT / "lib" / "install-lxqt.sh"


def _source_snapshot(body: str, env: dict | None = None, timeout: int = 5):
    """Source install-lxqt.sh with minimal stubs, then run *body*."""
    stubs = (
        "_asus_ui_label() { printf '%s\\n' \"$1\"; }; "
        "_install_run_as_user() { shift; \"$@\"; }; "
    )
    script = (
        f"set -euo pipefail; {stubs}"
        f"source {shlex.quote(str(_LXQT_LIB))}; {body}"
    )
    return run_bash_c(script, env=env, timeout=timeout)


class TestLxqtSnapshotConf(unittest.TestCase):
    """_lxqt_snapshot_conf must not treat read failures as empty conf."""

    def test_missing_conf_yields_empty_snapshot(self) -> None:
        """Absent path returns success with an empty snapshot file."""
        with tempfile.TemporaryDirectory() as tmp:
            missing = Path(tmp) / "no-such.conf"
            out = Path(tmp) / "out"
            proc = _source_snapshot(
                "snap=$(_lxqt_snapshot_conf testuser "
                f"{shlex.quote(str(missing))}) || exit $?; "
                f"cp -- \"$snap\" {shlex.quote(str(out))}; "
                "_lxqt_rm_tmp \"$snap\"; "
                f"wc -c < {shlex.quote(str(out))}"
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertEqual(proc.stdout.strip(), "0")

    def test_readable_conf_preserves_content(self) -> None:
        """Readable conf is copied into the snapshot."""
        with tempfile.TemporaryDirectory() as tmp:
            conf = Path(tmp) / "globalkeyshortcuts.conf"
            conf.write_text("[Meta%2BP.1]\nExec=foo\n", encoding="utf-8")
            out = Path(tmp) / "out"
            proc = _source_snapshot(
                "snap=$(_lxqt_snapshot_conf testuser "
                f"{shlex.quote(str(conf))}) || exit $?; "
                f"cp -- \"$snap\" {shlex.quote(str(out))}; "
                "_lxqt_rm_tmp \"$snap\""
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertEqual(
                out.read_text(encoding="utf-8"),
                "[Meta%2BP.1]\nExec=foo\n",
            )

    def test_unreadable_existing_path_fails_closed(self) -> None:
        """Present-but-unreadable path (directory) must not yield empty snap."""
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / "not-a-file"
            bad.mkdir()
            proc = _source_snapshot(
                "snap=$(_lxqt_snapshot_conf testuser "
                f"{shlex.quote(str(bad))}) && exit 0; "
                "status=$?; "
                'echo "status=$status"; '
                "exit 0"
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertIn("status=1", proc.stdout)
            self.assertIn("could not read", proc.stderr)


if __name__ == "__main__":
    unittest.main()
