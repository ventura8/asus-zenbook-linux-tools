"""Unit tests for debian/prerm packaged uninstall status and cleanup."""

from __future__ import annotations

import shlex
import tempfile
import unittest
from pathlib import Path

from tests.unit.shell.shell_test_utils import PROJECT_ROOT, run_bash_c


class TestDebianPrermTeardown(unittest.TestCase):
    """prerm must preserve uninstall exit status and clean up bytecode."""

    def test_prerm_preserves_uninstall_failure_code_and_cleans_bytecode(self) -> None:
        """Non-zero uninstall status is preserved and bytecode is cleaned."""
        with tempfile.TemporaryDirectory() as tmp:
            share = Path(tmp) / "usr" / "share" / "asus-zenbook-linux-tools"
            cache = share / "bin" / "__pycache__"
            cache.mkdir(parents=True)
            (cache / "daemon.cpython-314.pyc").write_bytes(b"\0")

            uninstall_sh = share / "uninstall.sh"
            uninstall_sh.write_text("#!/bin/sh\nexit 42\n", encoding="utf-8")
            uninstall_sh.chmod(0o755)

            prerm = shlex.quote(str(PROJECT_ROOT / "debian" / "prerm"))
            share_q = shlex.quote(str(share))
            uninst_q = shlex.quote(str(uninstall_sh))

            cmd = f"PKG_SHARE={share_q} UNINSTALL_SH={uninst_q} bash {prerm} remove"
            proc = run_bash_c(cmd, timeout=10)
            self.assertEqual(proc.returncode, 42)
            self.assertFalse(cache.exists())
            self.assertIn("Error: packaged uninstall teardown failed", proc.stderr)

    def test_prerm_success_cleans_bytecode_and_exits_zero(self) -> None:
        """Successful uninstall exits zero and cleans bytecode."""
        with tempfile.TemporaryDirectory() as tmp:
            share = Path(tmp) / "usr" / "share" / "asus-zenbook-linux-tools"
            cache = share / "bin" / "__pycache__"
            cache.mkdir(parents=True)
            (cache / "daemon.cpython-314.pyc").write_bytes(b"\0")

            uninstall_sh = share / "uninstall.sh"
            uninstall_sh.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            uninstall_sh.chmod(0o755)

            prerm = shlex.quote(str(PROJECT_ROOT / "debian" / "prerm"))
            share_q = shlex.quote(str(share))
            uninst_q = shlex.quote(str(uninstall_sh))

            cmd = f"PKG_SHARE={share_q} UNINSTALL_SH={uninst_q} bash {prerm} remove"
            proc = run_bash_c(cmd, timeout=10)
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertFalse(cache.exists())

    def test_prerm_missing_uninstall_fails_closed(self) -> None:
        """Missing uninstall helper fails closed with non-zero exit."""
        with tempfile.TemporaryDirectory() as tmp:
            share = Path(tmp) / "usr" / "share" / "asus-zenbook-linux-tools"
            share.mkdir(parents=True)
            uninstall_sh = share / "missing_uninstall.sh"

            prerm = shlex.quote(str(PROJECT_ROOT / "debian" / "prerm"))
            share_q = shlex.quote(str(share))
            uninst_q = shlex.quote(str(uninstall_sh))

            cmd = f"PKG_SHARE={share_q} UNINSTALL_SH={uninst_q} bash {prerm} remove"
            proc = run_bash_c(cmd, timeout=10)
            self.assertEqual(proc.returncode, 1)
            self.assertIn("Error: packaged uninstall helper missing", proc.stderr)


if __name__ == "__main__":
    unittest.main()
