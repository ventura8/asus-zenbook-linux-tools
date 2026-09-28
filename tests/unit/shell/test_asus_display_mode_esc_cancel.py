"""Esc cancel of the sticky display OSD (bin/asus-display-mode.sh --cancel-osd).

The hotkey daemon kills --cancel-osd after ASUS_DISPLAY_MODE_CANCEL_OSD_TIMEOUT_SECS.
A multi-call dismiss was killed before Super-up / flag cleanup on real hardware,
leaving Super latched and a stale ``.cancel`` that blocked the idle watchdog.
"""

import os
import shlex
import tempfile
import time
import unittest

from tests.unit.shell.display_mode_shell_test_utils import SCRIPT, _display_mode_env
from tests.unit.shell.shell_test_utils import run_bash_c, write_fake_executable

_SUPER_AND_MODIFIER_UPS = "125:0 126:0 42:0 54:0 29:0 97:0 56:0 100:0"


def _logging_stub(mock_bin: str, name: str, log_path: str) -> None:
    """Install a PATH stub that appends one line per invocation (its argv)."""
    write_fake_executable(
        os.path.join(mock_bin, name),
        f'#!/bin/bash\necho "$*" >> {shlex.quote(log_path)}\nexit 0\n',
    )


def _write_marker(path: str, text: str) -> None:
    """Write one sticky-OSD marker file."""
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def _read_lines(path: str) -> list[str]:
    """Return the stub log lines (empty when the stub never ran)."""
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as handle:
        return [line.strip() for line in handle if line.strip()]


class TestDisplayOsdEscCancel(unittest.TestCase):
    """Esc must dismiss the monitor popup without applying, within one injection."""

    def _run_cancel(self, backend: str, stub: str) -> tuple[list[str], str]:
        """Run --cancel-osd for *backend* with a logging *stub*; return log lines + prefix."""
        with tempfile.TemporaryDirectory() as run_root:
            mock_bin = os.path.join(run_root, "mock-bin")
            os.makedirs(mock_bin, exist_ok=True)
            log_path = os.path.join(run_root, f"{stub}.log")
            _logging_stub(mock_bin, stub, log_path)
            prefix = os.path.join(run_root, "disp")
            _write_marker(f"{prefix}.ctx", f"\n:0\n{backend}\n")
            _write_marker(f"{prefix}.session", "9999999999\n")
            proc = run_bash_c(
                f'bash "{SCRIPT}" --cancel-osd',
                env=_display_mode_env(run_root, mock_bin),
                timeout=10,
                log_name=f"esc-cancel-{backend}",
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            for suffix in ("session", "ctx", "cancel"):
                self.assertFalse(os.path.exists(f"{prefix}.{suffix}"), suffix)
            return _read_lines(log_path), prefix

    def test_ydotool_dismiss_is_one_ordered_injection(self):
        """Esc press/release precede Super-up in a single fast ydotool call."""
        lines, _prefix = self._run_cancel("ydotool", "ydotool")
        self.assertEqual(lines, [f"key -d 2 1:1 1:0 {_SUPER_AND_MODIFIER_UPS}"])

    def test_xdotool_dismiss_keeps_super_down_until_after_escape(self):
        """xdotool must not --clearmodifiers (that releases Super before Escape)."""
        lines, _prefix = self._run_cancel("xdotool", "xdotool")
        self.assertEqual(len(lines), 1, lines)
        self.assertNotIn("--clearmodifiers", lines[0])
        self.assertTrue(lines[0].startswith("key Escape keyup Super_L Super_R"), lines[0])


class TestDisplayOsdStaleCancelFlag(unittest.TestCase):
    """A .cancel left by a killed --cancel-osd must not block the watchdog forever."""

    def _cancel_state(self, age_secs: float) -> tuple[int, bool]:
        """Return (_osd_cancel_in_progress status, flag still present) for a flag *age_secs* old."""
        with tempfile.TemporaryDirectory() as run_root:
            prefix = os.path.join(run_root, "disp")
            flag = f"{prefix}.cancel"
            _write_marker(flag, "1\n")
            stamp = time.time() - age_secs
            os.utime(flag, (stamp, stamp))
            proc = run_bash_c(
                f'source "{SCRIPT}" >/dev/null; _osd_cancel_in_progress "{prefix}"',
                env=_display_mode_env(run_root),
                timeout=10,
                log_name="esc-cancel-stale-flag",
            )
            return proc.returncode, os.path.exists(flag)

    def test_fresh_cancel_flag_is_in_progress(self):
        """A just-written flag still blocks the idle watchdog's apply-release."""
        self.assertEqual(self._cancel_state(0), (0, True))

    def test_stale_cancel_flag_is_dropped(self):
        """A flag older than _OSD_CANCEL_STALE_SECS is removed and not in progress."""
        self.assertEqual(self._cancel_state(30), (1, False))

    def test_missing_cancel_flag_is_not_in_progress(self):
        """No flag means no cancel in progress."""
        with tempfile.TemporaryDirectory() as run_root:
            prefix = os.path.join(run_root, "disp")
            proc = run_bash_c(
                f'source "{SCRIPT}" >/dev/null; _osd_cancel_in_progress "{prefix}"',
                env=_display_mode_env(run_root),
                timeout=10,
                log_name="esc-cancel-no-flag",
            )
        self.assertEqual(proc.returncode, 1)


if __name__ == "__main__":
    unittest.main()
