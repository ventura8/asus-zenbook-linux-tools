"""Unit tests for lib/asus-common.sh notification replace-ID helpers."""

from __future__ import annotations

import os
import shlex
import tempfile
import unittest
from pathlib import Path

from tests.unit.shell.shell_test_utils import PROJECT_ROOT, bind_unix_socket, run_bash_c, write_fake_executable


class TestAsusCommonNotifications(unittest.TestCase):
    """Ensure notification IDs are parsed and persisted for in-place replaces."""

    def _run_helper(self, body: str, env: dict[str, str] | None = None):
        """Source lib/asus-common.sh and run a bash snippet with optional env overrides."""
        common_lib = shlex.quote(str(PROJECT_ROOT / "lib" / "asus-common.sh"))
        script = f"""
set -euo pipefail
source {common_lib}
{body}
"""
        return run_bash_c(script, env=env, timeout=10)

    def test_extract_notif_id_from_gdbus_uint32(self):
        """gdbus Notify responses yield a non-zero replace ID."""
        proc = self._run_helper('_extract_notif_id "(uint32 42,)"')
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertEqual(proc.stdout.strip(), "42")

    def test_extract_notif_id_rejects_zero(self):
        """A zero notification ID is treated as failure."""
        proc = self._run_helper('_extract_notif_id "(uint32 0,)" || echo rejected')
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertEqual(proc.stdout.strip(), "rejected")

    def test_save_notif_id_persists_for_replace(self):
        """Saved IDs are read back as the next replaces_id value."""
        with tempfile.TemporaryDirectory() as tmp:
            id_file = Path(tmp) / ".asus_notif_fan.id"
            id_file_q = shlex.quote(str(id_file))
            proc = self._run_helper(
                f"""
_save_notif_id '(uint32 77,)' {id_file_q}
echo "$(_get_notif_prev_id {id_file_q})"
"""
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertEqual(proc.stdout.strip(), "77")
            self.assertEqual(id_file.read_text(encoding="utf-8").strip(), "77")

    def test_send_user_notification_reuses_saved_id(self):
        """Second notification passes the previously saved replace ID to gdbus."""
        with tempfile.TemporaryDirectory() as tmp:
            mock_bin = Path(tmp) / "bin"
            runtime = Path(tmp) / "run" / "1000"
            notif_root = Path(tmp) / "notif"
            mock_bin.mkdir()
            runtime.mkdir(parents=True)
            notif_root.mkdir()
            bind_unix_socket(runtime / "bus")
            gdbus_log = Path(tmp) / "gdbus.log"
            gdbus_log_q = shlex.quote(str(gdbus_log))
            write_fake_executable(
                str(mock_bin / "gdbus"),
                f"""#!/bin/sh
printf '%s\\n' "$*" >> {gdbus_log_q}
echo '(uint32 9,)'
""",
            )
            write_fake_executable(
                str(mock_bin / "id"),
                '#!/bin/sh\nif [ "$1" = "-u" ]; then echo 1000; exit 0; fi\necho fakeuser\n',
            )
            write_fake_executable(
                str(mock_bin / "loginctl"),
                """#!/bin/sh
if [ "$1" = "list-sessions" ]; then echo c1 1000 seat0; exit 0; fi
if [ "$1" = "show-session" ]; then
  case "$*" in *Type*) echo x11 ;; *State*) echo active ;; *Name*) echo fakeuser ;; *Seat*) echo seat0 ;; esac
  exit 0
fi
""",
            )
            env = dict(
                os.environ,
                PATH=f"{mock_bin}:{os.environ.get('PATH', '')}",
                RUN_USER_ROOT=str(Path(tmp) / "run"),
                NOTIF_ID_ROOT=str(notif_root),
            )
            env.pop("BUS_ROOT", None)
            env.pop("DBUS_BUS_ROOT", None)
            proc = self._run_helper(
                """
_send_user_notification "Fan" "Mode: Performance" "icon" "fan" "fan" "icon"
_send_user_notification "Fan" "Mode: Quiet" "icon" "fan" "fan" "icon"
""",
                env=env,
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            logged = gdbus_log.read_text(encoding="utf-8")
            lines = [line for line in logged.splitlines() if "Notifications.Notify" in line]
            self.assertGreaterEqual(len(lines), 2, msg=logged)
            self.assertRegex(lines[0], r"ASUS ZenBook 0 ")
            self.assertRegex(lines[1], r"ASUS ZenBook 9 ")
            id_file = notif_root / "1000" / ".asus_notif_fan.id"
            self.assertEqual(id_file.read_text(encoding="utf-8").strip(), "9")


if __name__ == "__main__":
    unittest.main()
