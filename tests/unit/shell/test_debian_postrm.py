"""Unit tests for debian/postrm share leftover cleanup."""

from __future__ import annotations

import shlex
import tempfile
import unittest
from pathlib import Path

from tests.unit.shell.shell_test_utils import PROJECT_ROOT, run_bash_c


class TestDebianPostrmShareCleanup(unittest.TestCase):
    """postrm must remove unpackaged __pycache__ so dpkg can drop empty dirs."""

    @staticmethod
    def _source_postrm() -> str:
        """Return a bash prelude that sources debian/postrm without running main."""
        postrm = shlex.quote(str(PROJECT_ROOT / "debian" / "postrm"))
        return f"set -euo pipefail; ASUS_POSTRM_SOURCE_ONLY=1 source {postrm}; "

    def test_remove_clears_share_bytecode_and_empty_dirs(self) -> None:
        """remove|purge cleans bytecode leftovers under the packaged share tree."""
        with tempfile.TemporaryDirectory() as tmp:
            share = Path(tmp) / "usr" / "share" / "asus-zenbook-linux-tools"
            cache = share / "bin" / "__pycache__"
            cache.mkdir(parents=True)
            (cache / "asus_i18n.cpython-314.pyc").write_bytes(b"\0")
            share_q = shlex.quote(str(share))
            script = (
                f"{self._source_postrm()}"
                f"PKG_SHARE={share_q} _postrm_cleanup_for_action remove"
            )
            proc = run_bash_c(script, timeout=10)
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertFalse(cache.exists())
            self.assertFalse(share.exists())

    def test_upgrade_clears_bytecode_but_keeps_share_layout(self) -> None:
        """upgrade drops __pycache__ without deleting the live packaged tree."""
        with tempfile.TemporaryDirectory() as tmp:
            share = Path(tmp) / "usr" / "share" / "asus-zenbook-linux-tools"
            bin_dir = share / "bin"
            cache = bin_dir / "__pycache__"
            cache.mkdir(parents=True)
            (cache / "asus_i18n.cpython-314.pyc").write_bytes(b"\0")
            kept = bin_dir / "asus_i18n.py"
            kept.write_text("x = 1\n", encoding="utf-8")
            share_q = shlex.quote(str(share))
            script = (
                f"{self._source_postrm()}"
                f"PKG_SHARE={share_q} _postrm_cleanup_for_action upgrade"
            )
            proc = run_bash_c(script, timeout=10)
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertFalse(cache.exists())
            self.assertTrue(kept.is_file())
            self.assertTrue(bin_dir.is_dir())


if __name__ == "__main__":
    unittest.main()
