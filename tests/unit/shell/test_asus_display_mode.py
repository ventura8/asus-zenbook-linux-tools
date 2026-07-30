"""Unit tests for bin/asus-display-mode.sh."""

import os
import shlex
import tempfile
import unittest

from tests.unit.shell.display_mode_shell_test_utils import (
    SCRIPT,
    _display_mode_env,
    _flock_serialize_fixture,
    _guaranteed_unused_pid,
    _sticky_osd_env,
    _write_ydotool_logger,
    _ydotool_open_and_tap_lines,
)
from tests.unit.shell.shell_test_utils import (
    run_bash_c,
    run_shell_script,
    terminate_pid_file,
    write_fake_executable,
)


class TestAsusDisplayModeShell(unittest.TestCase):
    """Unit tests for bin/asus-display-mode.sh."""

    def test_ydotool_success_triggers_display_switch(self):
        """When ydotool succeeds, script exits 0 immediately."""
        with tempfile.TemporaryDirectory() as run_root:
            mock_bin = os.path.join(run_root, "mock-bin")
            os.makedirs(mock_bin, exist_ok=True)
            write_fake_executable(os.path.join(mock_bin, "ydotool"), "#!/bin/bash\nexit 0\n")
            env = _display_mode_env(run_root, mock_bin, ASUS_DISPLAY_MODE_IDLE_SECS="1")
            prefix = os.path.join(run_root, "disp")
            try:
                proc = run_shell_script(SCRIPT, env=env)
                self.assertEqual(proc.returncode, 0)
            finally:
                terminate_pid_file(f"{prefix}.wd.pid", "asus-display-mode")

    def test_osd_markers_exist_before_super_down(self):
        """Sticky .session/.ctx must exist before ydotool holds Super (Esc race)."""
        with tempfile.TemporaryDirectory() as run_root:
            mock_bin = os.path.join(run_root, "mock-bin")
            os.makedirs(mock_bin, exist_ok=True)
            prefix = os.path.join(run_root, "disp")
            write_fake_executable(
                os.path.join(mock_bin, "ydotool"),
                (
                    "#!/bin/bash\n"
                    'if echo "$@" | grep -q "125:1"; then\n'
                    f'  test -f "{prefix}.session" && test -f "{prefix}.ctx" || exit 2\n'
                    "fi\n"
                    "exit 0\n"
                ),
            )
            env = _sticky_osd_env(run_root, mock_bin)
            try:
                proc = run_shell_script(SCRIPT, env=env)
                self.assertEqual(proc.returncode, 0)
                self.assertTrue(os.path.isfile(f"{prefix}.session"))
                self.assertTrue(os.path.isfile(f"{prefix}.ctx"))
            finally:
                terminate_pid_file(f"{prefix}.wd.pid", "asus-display-mode")

    def test_sticky_session_second_press_taps_p_only(self):
        """Active OSD session should only tap P on later Display Toggle presses."""
        with tempfile.TemporaryDirectory() as run_root:
            mock_bin = os.path.join(run_root, "mock-bin")
            os.makedirs(mock_bin, exist_ok=True)
            log_path = os.path.join(run_root, "ydotool.log")
            prefix = os.path.join(run_root, "disp")
            _write_ydotool_logger(mock_bin, log_path)
            env = _sticky_osd_env(run_root, mock_bin)
            try:
                first = run_bash_c(f'bash "{SCRIPT}"', env=env, timeout=10)
                second = run_bash_c(f'bash "{SCRIPT}"', env=env, timeout=10)
                self.assertEqual(first.returncode, 0)
                self.assertEqual(second.returncode, 0)
                lines = self._read_stripped_lines(log_path)
                self.assertTrue(self._ydotool_opened_super_session(lines))
                self.assertTrue(self._ydotool_tapped_p_only(lines))
            finally:
                terminate_pid_file(f"{prefix}.wd.pid", "asus-display-mode")

    def test_orphan_session_reopens_sticky_osd(self):
        """Stale .session without a live watchdog must reopen Super+P, not P-only."""
        with tempfile.TemporaryDirectory() as run_root:
            mock_bin = os.path.join(run_root, "mock-bin")
            os.makedirs(mock_bin, exist_ok=True)
            log_path = os.path.join(run_root, "ydotool.log")
            prefix = os.path.join(run_root, "disp")
            _write_ydotool_logger(mock_bin, log_path)
            with open(f"{prefix}.session", "w", encoding="utf-8") as handle:
                handle.write("9999999999\n")
            with open(f"{prefix}.ctx", "w", encoding="utf-8") as handle:
                handle.write("\n\nydotool\n")
            with open(f"{prefix}.wd.pid", "w", encoding="utf-8") as handle:
                handle.write(f"{_guaranteed_unused_pid()}\n")
            env = _sticky_osd_env(run_root, mock_bin)
            try:
                proc = run_bash_c(f'bash "{SCRIPT}"', env=env, timeout=10)
                self.assertEqual(proc.returncode, 0)
                lines = self._read_stripped_lines(log_path)
                self.assertTrue(self._ydotool_opened_super_session(lines))
                self.assertFalse(self._ydotool_tapped_p_only(lines))
            finally:
                terminate_pid_file(f"{prefix}.wd.pid", "asus-display-mode")

    @staticmethod
    def _ydotool_opened_super_session(lines: list[str]) -> bool:
        """True when a log line clears modifiers then holds Super and presses P."""
        return any("42:0" in line and "125:1" in line and "25:1" in line and "25:0" in line for line in lines)

    @staticmethod
    def _ydotool_tapped_p_only(lines: list[str]) -> bool:
        """True when a later log line taps P without holding Super."""
        return any(line.endswith("25:1 25:0") and "125:1" not in line for line in lines)

    def test_non_numeric_idle_and_dup_fail_closed_to_defaults(self):
        """Non-numeric IDLE/DUP overrides fail closed to 2s / 50ms defaults."""
        with tempfile.TemporaryDirectory() as run_root:
            env = _display_mode_env(
                run_root,
                ASUS_DISPLAY_MODE_IDLE_SECS="nope",
                ASUS_DISPLAY_MODE_DUP_MS="x",
                ASUS_DISPLAY_MODE_FLOCK_WAIT_SECS="bad",
            )
            script = f'source "{SCRIPT}" >/dev/null\nprintf "%s %s %s\\n" "$_OSD_IDLE_SECS" "$_DUP_WINDOW_MS" "$_FLOCK_WAIT_SECS"\n'
            proc = run_bash_c(script, env=env, timeout=10)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "2 50 5")

    def test_concurrent_invokes_serialize_via_flock(self):
        """Overlapping display-mode workers must serialize on the state flock."""
        with tempfile.TemporaryDirectory() as run_root:
            env, log_path, prefix, driver = _flock_serialize_fixture(run_root)
            try:
                self._assert_flock_serialized_log(env, log_path, driver, run_root)
            finally:
                terminate_pid_file(f"{prefix}.wd.pid", "asus-display-mode")

    def _assert_flock_serialized_log(self, env, log_path, driver, run_root):
        """Run the flock driver and assert Super-down precedes a later P tap."""
        first = run_bash_c(driver, env=env, timeout=45)
        self.assertEqual(first.returncode, 0)
        with open(log_path, encoding="utf-8") as handle:
            lines = [line.strip() for line in handle]
        opens, taps = _ydotool_open_and_tap_lines(lines)
        self.assertEqual(len(opens), 1)
        self.assertEqual(len(taps), 1)
        self.assertIn("125:1", opens[0])
        self.assertLess(lines.index(opens[0]), lines.index(taps[0]))
        flock_path = os.path.join(run_root, "disp.flock")
        self.assertTrue(os.path.exists(flock_path))

    def test_ydotool_disabled_or_missing_returns_error(self):
        """When all backends are disabled, script returns error without cycling."""
        with tempfile.TemporaryDirectory() as run_root:
            env = _display_mode_env(
                run_root,
                ASUS_DISPLAY_MODE_DISABLE_YDOTOOL="1",
                ASUS_DISPLAY_MODE_DISABLE_XDOTOOL="1",
                ASUS_DISPLAY_MODE_DISABLE_MUTTER_CYCLE="1",
                ASUS_DISPLAY_MODE_DISABLE_SETTINGS="1",
                ASUS_DISPLAY_MODE_FORCE_LOCAL="1",
            )
            proc = run_shell_script(SCRIPT, env=env)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Error:", proc.stderr)

    def test_xdotool_fallback_opens_sticky_super_session(self):
        """On X11, xdotool sticky Super+P is used when ydotool is disabled."""
        with tempfile.TemporaryDirectory() as run_root:
            mock_bin = os.path.join(run_root, "mock-bin")
            os.makedirs(mock_bin, exist_ok=True)
            log_path = os.path.join(run_root, "xdotool.log")
            write_fake_executable(os.path.join(mock_bin, "ydotool"), "#!/bin/bash\nexit 1\n")
            write_fake_executable(
                os.path.join(mock_bin, "xdotool"),
                f'#!/bin/bash\necho "$@" >> {shlex.quote(log_path)}\nexit 0\n',
            )
            prefix = os.path.join(run_root, "disp")
            env = _display_mode_env(
                run_root,
                mock_bin,
                ASUS_DISPLAY_MODE_DISABLE_YDOTOOL="1",
                ASUS_DISPLAY_MODE_FORCE_XDOTOOL="1",
                ASUS_DISPLAY_MODE_DISABLE_MUTTER_CYCLE="1",
                ASUS_DISPLAY_MODE_DISABLE_SETTINGS="1",
                ASUS_DISPLAY_MODE_IDLE_SECS="1",
                DISPLAY=":0",
                XDG_SESSION_TYPE="x11",
            )
            try:
                proc = run_shell_script(SCRIPT, env=env)
                self.assertEqual(proc.returncode, 0)
                with open(log_path, encoding="utf-8") as handle:
                    text = handle.read()
                self.assertIn("keydown Super_L", text)
                self.assertIn("key p", text)
            finally:
                terminate_pid_file(f"{prefix}.wd.pid", "asus-display-mode")

    def _read_stripped_lines(self, log_path: str) -> list[str]:
        """Return all stripped lines from a ydotool/xdotool log file, including empty lines."""
        with open(log_path, encoding="utf-8") as handle:
            return [line.strip() for line in handle]

    def _assert_line_contains(self, lines: list[str], needle: str) -> None:
        """Assert at least one log line contains needle."""
        self.assertTrue(any(needle in line for line in lines))

    def _assert_no_combined_super_shift(self, lines: list[str]) -> None:
        """Assert Super apply and Shift clear are not merged into one ydotool call."""
        # Super apply and Shift clear must be separate ydotool calls.
        combined = any("125:0" in line and "42:0" in line for line in lines)
        self.assertFalse(combined)

    def test_osd_release_clears_shift_and_other_modifiers(self):
        """Idle OSD end must keyup Shift (and peers), not only Super."""
        with tempfile.TemporaryDirectory() as run_root:
            mock_bin = os.path.join(run_root, "mock-bin")
            os.makedirs(mock_bin, exist_ok=True)
            log_path = os.path.join(run_root, "ydotool.log")
            write_fake_executable(
                os.path.join(mock_bin, "ydotool"),
                f'#!/bin/bash\necho "$@" >> {shlex.quote(log_path)}\nexit 0\n',
            )
            prefix = os.path.join(run_root, "disp")
            # Empty user/socket → local ydotool on PATH (FORCE_LOCAL-style).
            with open(f"{prefix}.ctx", "w", encoding="utf-8") as handle:
                handle.write("\n\nydotool\n")
            with open(f"{prefix}.session", "w", encoding="utf-8") as handle:
                handle.write("0\n")
            env = _display_mode_env(run_root, mock_bin)
            env["ASUS_DISPLAY_MODE_WATCHDOG_PREFIX"] = prefix
            try:
                proc = run_bash_c(f'bash "{SCRIPT}" --internal-watchdog', env=env, timeout=10)
                self.assertEqual(proc.returncode, 0)
                lines = self._read_stripped_lines(log_path)
                self._assert_line_contains(lines, "125:0")
                self._assert_line_contains(lines, "42:0")
                self._assert_no_combined_super_shift(lines)
                self.assertFalse(os.path.exists(f"{prefix}.session"))
            finally:
                terminate_pid_file(f"{prefix}.wd.pid", "asus-display-mode")

    def test_xdotool_osd_release_clears_shift(self):
        """xdotool sticky OSD end must keyup Shift_L, not only Super_L."""
        with tempfile.TemporaryDirectory() as run_root:
            mock_bin = os.path.join(run_root, "mock-bin")
            os.makedirs(mock_bin, exist_ok=True)
            log_path = os.path.join(run_root, "xdotool.log")
            write_fake_executable(
                os.path.join(mock_bin, "xdotool"),
                f'#!/bin/bash\necho "$@" >> {shlex.quote(log_path)}\nexit 0\n',
            )
            prefix = os.path.join(run_root, "disp")
            with open(f"{prefix}.ctx", "w", encoding="utf-8") as handle:
                handle.write("\n:0\nxdotool\n")
            with open(f"{prefix}.session", "w", encoding="utf-8") as handle:
                handle.write("0\n")
            env = _display_mode_env(run_root, mock_bin)
            env["ASUS_DISPLAY_MODE_WATCHDOG_PREFIX"] = prefix
            try:
                proc = run_bash_c(f'bash "{SCRIPT}" --internal-watchdog', env=env, timeout=10)
                self.assertEqual(proc.returncode, 0)
                with open(log_path, encoding="utf-8") as handle:
                    text = handle.read()
                self.assertIn("keyup", text)
                self.assertIn("Shift_L", text)
                self.assertIn("Super_L", text)
            finally:
                terminate_pid_file(f"{prefix}.wd.pid", "asus-display-mode")

    def test_cancel_osd_releases_super_hold(self):
        """--cancel-osd must release Super after Esc dismisses the dialog."""
        with tempfile.TemporaryDirectory() as run_root:
            mock_bin = os.path.join(run_root, "mock-bin")
            os.makedirs(mock_bin, exist_ok=True)
            log_path = os.path.join(run_root, "ydotool.log")
            write_fake_executable(
                os.path.join(mock_bin, "ydotool"),
                f'#!/bin/bash\necho "$@" >> {shlex.quote(log_path)}\nexit 0\n',
            )
            prefix = os.path.join(run_root, "disp")
            with open(f"{prefix}.ctx", "w", encoding="utf-8") as handle:
                handle.write("\n\nydotool\n")
            with open(f"{prefix}.session", "w", encoding="utf-8") as handle:
                handle.write("9999999999\n")
            env = _display_mode_env(run_root, mock_bin)
            proc = run_bash_c(f'bash "{SCRIPT}" --cancel-osd', env=env, timeout=10)
            self.assertEqual(proc.returncode, 0)
            with open(log_path, encoding="utf-8") as handle:
                text = handle.read()
            self.assertIn("1:1", text)
            self.assertIn("1:0", text)
            self.assertIn("125:0", text)
            self.assertFalse(os.path.exists(f"{prefix}.session"))
            self.assertFalse(os.path.exists(f"{prefix}.ctx"))
            self.assertFalse(os.path.exists(f"{prefix}.cancel"))

    def test_watchdog_skips_apply_release_during_esc_cancel(self):
        """Idle watchdog must not Super-up (apply) while Esc cancel is in progress."""
        with tempfile.TemporaryDirectory() as run_root:
            mock_bin = os.path.join(run_root, "mock-bin")
            os.makedirs(mock_bin, exist_ok=True)
            log_path = os.path.join(run_root, "ydotool.log")
            write_fake_executable(
                os.path.join(mock_bin, "ydotool"),
                f'#!/bin/bash\necho "$@" >> {shlex.quote(log_path)}\nexit 0\n',
            )
            prefix = os.path.join(run_root, "disp")
            with open(f"{prefix}.ctx", "w", encoding="utf-8") as handle:
                handle.write("user\n/run/ydotoold/socket\nydotool\n")
            with open(f"{prefix}.cancel", "w", encoding="utf-8") as handle:
                handle.write("1\n")
            env = _display_mode_env(run_root, mock_bin)
            env["ASUS_DISPLAY_MODE_WATCHDOG_PREFIX"] = prefix
            script = f'source "{SCRIPT}" >/dev/null\n_watchdog_release_if_idle "{prefix}"\n'
            proc = run_bash_c(script, env=env, timeout=10)
            self.assertEqual(proc.returncode, 0)
            self.assertFalse(os.path.exists(log_path))
            self.assertTrue(os.path.exists(f"{prefix}.ctx"))
            self.assertTrue(os.path.exists(f"{prefix}.cancel"))

    def test_finalize_osd_open_cleans_up_when_watchdog_fails(self):
        """Failed watchdog start must dismiss sticky OSD and clear markers."""
        with tempfile.TemporaryDirectory() as run_root:
            prefix = os.path.join(run_root, "disp")
            with open(f"{prefix}.ctx", "w", encoding="utf-8") as handle:
                handle.write("user\n/run/ydotoold/socket\nydotool\n")
            with open(f"{prefix}.session", "w", encoding="utf-8") as handle:
                handle.write("9999999999\n")
            mock_bin = os.path.join(run_root, "mock-bin")
            os.makedirs(mock_bin, exist_ok=True)
            write_fake_executable(
                os.path.join(mock_bin, "ydotool"),
                "#!/bin/bash\nexit 0\n",
            )
            env = _display_mode_env(run_root, mock_bin)
            script = f'source "{SCRIPT}" >/dev/null\n_ensure_watchdog() {{ return 1; }}\n_finalize_osd_open_with_watchdog "{prefix}"\n'
            proc = run_bash_c(script, env=env, timeout=10)
            self.assertEqual(proc.returncode, 1)
            self.assertFalse(os.path.exists(f"{prefix}.session"))
            self.assertFalse(os.path.exists(f"{prefix}.ctx"))

    def test_display_state_dir_uses_notif_runtime_root(self):
        """Sticky OSD state must not use /run/user (ProtectHome=read-only)."""
        with tempfile.TemporaryDirectory() as run_root:
            notif = os.path.join(run_root, "notif")
            script = f'source "{SCRIPT}" >/dev/null\n_display_state_dir\n'
            env = dict(os.environ)
            env["NOTIF_ID_ROOT"] = notif
            env.pop("ASUS_DISPLAY_MODE_STATE_PREFIX", None)
            proc = run_bash_c(script, env=env)
            self.assertEqual(proc.returncode, 0)
            out = proc.stdout.strip()
            self.assertTrue(out.startswith(notif), out)
            self.assertIn("asus-display-mode", out)
            self.assertNotIn("/run/user", out)


if __name__ == "__main__":
    unittest.main()
