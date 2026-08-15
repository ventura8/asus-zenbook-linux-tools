"""Desktop-family settings tests for bin/asus-display-mode.sh."""

import os
import shlex
import tempfile
import unittest
from pathlib import Path

from tests.unit.shell.display_mode_shell_test_utils import (
    SCRIPT,
    _current_username,
    _display_mode_env,
)
from tests.unit.shell.shell_test_utils import run_bash_c, write_fake_executable


class TestAsusDisplayModeDeSettings(unittest.TestCase):
    """Verify desktop-family display settings fallbacks."""

    def test_open_family_display_settings_lxqt(self):
        """LXQt family opens lxqt-config-monitor via settings helper."""
        with tempfile.TemporaryDirectory() as run_root:
            mock_bin = os.path.join(run_root, "mock-bin")
            os.makedirs(mock_bin, exist_ok=True)
            log_path = os.path.join(run_root, "lxqt-monitor.log")
            write_fake_executable(
                os.path.join(mock_bin, "lxqt-config-monitor"),
                f"#!/bin/sh\necho ran >> {shlex.quote(log_path)}\nexit 0\n",
            )
            user = _current_username()
            script = f'source "{SCRIPT}" >/dev/null\n_open_family_display_settings {shlex.quote(user)} "unix:path=/tmp/bus" lxqt\n'
            env = _display_mode_env(run_root, mock_bin)
            proc = run_bash_c(script, env=env, timeout=10)
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertTrue(os.path.isfile(log_path), msg="lxqt-config-monitor was not invoked")

    def test_lxqt_fallback_skips_mutter_cycle(self):
        """LXQt fallback opens settings and never cycles Mutter profiles."""
        with tempfile.TemporaryDirectory() as run_root:
            mock_bin = os.path.join(run_root, "mock-bin")
            os.makedirs(mock_bin, exist_ok=True)
            settings_log = os.path.join(run_root, "settings.log")
            mutter_log = os.path.join(run_root, "mutter.log")
            write_fake_executable(
                os.path.join(mock_bin, "lxqt-config-monitor"),
                f"#!/bin/sh\necho settings >> {shlex.quote(settings_log)}\nexit 0\n",
            )
            user = _current_username()
            script = (
                f'source "{SCRIPT}" >/dev/null\n'
                f"_cycle_mutter_display_mode() {{ "
                f"echo mutter >> {shlex.quote(mutter_log)}; return 0; }}\n"
                f'_resolve_cycle_user() {{ printf "%s\\n" {shlex.quote(user)}; }}\n'
                f'asus_desktop_family() {{ printf "lxqt\\n"; }}\n'
                f"_try_fallback_backends\n"
            )
            env = _display_mode_env(run_root, mock_bin)
            proc = run_bash_c(script, env=env, timeout=10)
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertTrue(os.path.isfile(settings_log), msg="lxqt-config-monitor not opened")
            self.assertFalse(os.path.isfile(mutter_log), msg="Mutter cycle must not run on LXQt")

    def test_open_family_display_settings_cinnamon(self):
        """Cinnamon family opens cinnamon-settings display."""
        with tempfile.TemporaryDirectory() as run_root:
            mock_bin = os.path.join(run_root, "mock-bin")
            os.makedirs(mock_bin, exist_ok=True)
            log_path = os.path.join(run_root, "cinnamon-display.log")
            write_fake_executable(
                os.path.join(mock_bin, "cinnamon-settings"),
                f"#!/bin/sh\nprintf '%s\\n' \"$*\" >> {shlex.quote(log_path)}\nexit 0\n",
            )
            user = _current_username()
            script = f'source "{SCRIPT}" >/dev/null\n_open_family_display_settings {shlex.quote(user)} "unix:path=/tmp/bus" cinnamon\n'
            env = _display_mode_env(run_root, mock_bin)
            proc = run_bash_c(script, env=env, timeout=10)
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertTrue(os.path.isfile(log_path), msg="cinnamon-settings was not invoked")
            self.assertIn("display", Path(log_path).read_text(encoding="utf-8"))

    def test_cinnamon_fallback_skips_mutter_cycle(self):
        """Cinnamon fallback opens settings and never cycles Mutter profiles."""
        with tempfile.TemporaryDirectory() as run_root:
            mock_bin = os.path.join(run_root, "mock-bin")
            os.makedirs(mock_bin, exist_ok=True)
            settings_log = os.path.join(run_root, "settings.log")
            mutter_log = os.path.join(run_root, "mutter.log")
            write_fake_executable(
                os.path.join(mock_bin, "cinnamon-settings"),
                f"#!/bin/sh\necho settings >> {shlex.quote(settings_log)}\nexit 0\n",
            )
            user = _current_username()
            script = (
                f'source "{SCRIPT}" >/dev/null\n'
                f"_cycle_mutter_display_mode() {{ "
                f"echo mutter >> {shlex.quote(mutter_log)}; return 0; }}\n"
                f'_resolve_cycle_user() {{ printf "%s\\n" {shlex.quote(user)}; }}\n'
                f'asus_desktop_family() {{ printf "cinnamon\\n"; }}\n'
                f"_try_fallback_backends\n"
            )
            env = _display_mode_env(run_root, mock_bin)
            proc = run_bash_c(script, env=env, timeout=10)
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertTrue(os.path.isfile(settings_log), msg="cinnamon-settings not opened")
            self.assertFalse(os.path.isfile(mutter_log), msg="Mutter cycle must not run on Cinnamon")

    def test_open_family_display_settings_mate(self):
        """MATE family opens mate-display-properties."""
        with tempfile.TemporaryDirectory() as run_root:
            mock_bin = os.path.join(run_root, "mock-bin")
            os.makedirs(mock_bin, exist_ok=True)
            log_path = os.path.join(run_root, "mate-display.log")
            write_fake_executable(
                os.path.join(mock_bin, "mate-display-properties"),
                f"#!/bin/sh\necho ran >> {shlex.quote(log_path)}\nexit 0\n",
            )
            user = _current_username()
            script = f'source "{SCRIPT}" >/dev/null\n_open_family_display_settings {shlex.quote(user)} "unix:path=/tmp/bus" mate\n'
            env = _display_mode_env(run_root, mock_bin)
            proc = run_bash_c(script, env=env, timeout=10)
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertTrue(os.path.isfile(log_path), msg="mate-display-properties was not invoked")

    def test_mate_fallback_skips_mutter_cycle(self):
        """MATE fallback opens settings and never cycles Mutter profiles."""
        with tempfile.TemporaryDirectory() as run_root:
            mock_bin = os.path.join(run_root, "mock-bin")
            os.makedirs(mock_bin, exist_ok=True)
            settings_log = os.path.join(run_root, "settings.log")
            mutter_log = os.path.join(run_root, "mutter.log")
            write_fake_executable(
                os.path.join(mock_bin, "mate-display-properties"),
                f"#!/bin/sh\necho settings >> {shlex.quote(settings_log)}\nexit 0\n",
            )
            user = _current_username()
            script = (
                f'source "{SCRIPT}" >/dev/null\n'
                f"_cycle_mutter_display_mode() {{ "
                f"echo mutter >> {shlex.quote(mutter_log)}; return 0; }}\n"
                f'_resolve_cycle_user() {{ printf "%s\\n" {shlex.quote(user)}; }}\n'
                f'asus_desktop_family() {{ printf "mate\\n"; }}\n'
                f"_try_fallback_backends\n"
            )
            env = _display_mode_env(run_root, mock_bin)
            proc = run_bash_c(script, env=env, timeout=10)
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertTrue(os.path.isfile(settings_log), msg="mate-display-properties not opened")
            self.assertFalse(os.path.isfile(mutter_log), msg="Mutter cycle must not run on MATE")


if __name__ == "__main__":
    unittest.main()
