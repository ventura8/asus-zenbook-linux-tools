"""Sticky display OSD session detection and Esc cancel unit tests."""

import os
import subprocess
import tempfile
import unittest
from unittest.mock import MagicMock, patch

from evdev import ecodes

from tests.unit.bin.at_keyboard_test_utils import (
    _call,
    _immediate_osd_thread,
    _isolated_display_osd_env,
    _key,
    _osd_prefix_cancel_run,
    _reset_at_keyboard_state,
)
from tests.unit.bin.hotkey_daemon_test_utils import load_daemon

load_daemon()


class TestAsusHotkeyDisplayOsdCancel(unittest.TestCase):
    """Sticky display OSD session detection and Esc cancel paths."""

    def setUp(self):
        """Reset daemon + pending Super chord state."""
        _reset_at_keyboard_state(self)

    def test_esc_without_osd_session_only_forwards(self):
        """Esc with no sticky OSD must forward and must not cancel."""
        kb_ui = MagicMock()
        with _isolated_display_osd_env(), patch("asus_hotkey_daemon_osd._subprocess_run") as cancel_run:
            _call("_handle_esc_key", _key(ecodes.KEY_ESC, 1), kb_ui)
        self.assertTrue(kb_ui.write.called)
        cancel_run.assert_not_called()

    def test_esc_during_osd_forwards_and_cancels(self):
        """Esc during sticky OSD cancels via display-mode; AT Esc is not forwarded."""
        kb_ui = MagicMock()
        with _isolated_display_osd_env() as empty_root:
            prefix = os.path.join(empty_root, "disp")
            with (
                patch.dict(os.environ, {"ASUS_DISPLAY_MODE_STATE_PREFIX": prefix}, clear=False),
                patch("asus_hotkey_daemon_osd._subprocess_run") as cancel_run,
                patch("asus_hotkey_daemon_osd.threading.Thread", side_effect=_immediate_osd_thread),
                self.assertLogs("asus_hotkey_daemon_osd", level="INFO"),
            ):
                cancel_run.return_value = MagicMock(returncode=0, stderr="")
                with open(f"{prefix}.session", "w", encoding="utf-8") as handle:
                    handle.write("1\n")
                _call("_handle_esc_key", _key(ecodes.KEY_ESC, 1), kb_ui)
                _call("_handle_esc_key", _key(ecodes.KEY_ESC, 0), kb_ui)
        cancel_run.assert_called_once()
        esc_writes = [call for call in kb_ui.write.call_args_list if len(call.args) >= 2 and call.args[1] == ecodes.KEY_ESC]
        self.assertFalse(esc_writes)

    def test_display_mode_suppressed_during_post_esc_cooldown(self):
        """Esc cancel must briefly block display-mode re-open from firmware Super+P."""
        self.addCleanup(_call, "reset_display_osd_esc_cooldown")
        _call("_arm_display_osd_esc_cooldown")
        with (
            patch("asus_hotkey_daemon_runtime.is_executable_file", return_value=True),
            patch("asus_hotkey_daemon_runtime.threading.Thread") as mock_thread,
        ):
            _call("_dispatch_resolved_script", "asus-display-mode.sh")
            mock_thread.assert_not_called()
            _call("reset_display_osd_esc_cooldown")
            _call("_dispatch_resolved_script", "asus-display-mode.sh")
            mock_thread.assert_called_once()
            mock_thread.return_value.start.assert_called_once_with()

    def test_esc_cancel_releases_proxy_super(self):
        """Esc cancel must clear pending Super and release proxy modifier ups."""
        kb_ui = MagicMock()
        _call("_start_pending_meta", _key(ecodes.KEY_LEFTMETA, 1), 1.0)
        self._run_esc_with_active_osd_session(kb_ui)
        released_codes = _released_key_codes(kb_ui)
        self.assertIn(ecodes.KEY_LEFTMETA, released_codes)
        self.assertIn(ecodes.KEY_LEFTSHIFT, released_codes)

    def _run_esc_with_active_osd_session(self, kb_ui):
        """Arm a sticky OSD session marker and dispatch Esc cancel."""
        with _osd_prefix_cancel_run() as (prefix, cancel_run):
            cancel_run.return_value = MagicMock(returncode=0, stderr="")
            with open(f"{prefix}.session", "w", encoding="utf-8") as handle:
                handle.write("1\n")
            _call("_handle_esc_key", _key(ecodes.KEY_ESC, 1), kb_ui)

    def test_osd_session_active_respects_state_prefix(self):
        """ASUS_DISPLAY_MODE_STATE_PREFIX.session gates Esc cancel."""
        with _isolated_display_osd_env() as empty_root:
            prefix = os.path.join(empty_root, "disp")
            with patch.dict(os.environ, {"ASUS_DISPLAY_MODE_STATE_PREFIX": prefix}, clear=False):
                self.assertFalse(_call("_osd_session_active"))
                with open(f"{prefix}.session", "w", encoding="utf-8") as handle:
                    handle.write("1\n")
                self.assertTrue(_call("_osd_session_active"))

    def test_osd_session_active_via_ctx_marker(self):
        """`.ctx` alone must count as sticky OSD so Esc can cancel mid-open."""
        with _isolated_display_osd_env() as empty_root:
            prefix = os.path.join(empty_root, "disp")
            with patch.dict(os.environ, {"ASUS_DISPLAY_MODE_STATE_PREFIX": prefix}, clear=False):
                with open(f"{prefix}.ctx", "w", encoding="utf-8") as handle:
                    handle.write("user\nsock\nydotool\n")
                self.assertTrue(_call("_osd_session_active"))

    def test_osd_session_active_via_notif_id_root_glob(self):
        """Without state prefix, NOTIF_ID_ROOT/<uid>/asus-display-mode/state.* is used."""
        with tempfile.TemporaryDirectory() as tmp:
            uid = str(os.getuid())
            session = os.path.join(tmp, uid, "asus-display-mode")
            os.makedirs(session)
            session_file = os.path.join(session, "state.session")
            with open(session_file, "w", encoding="utf-8") as handle:
                handle.write("1\n")
            env_map = {key: value for key, value in os.environ.items() if key != "ASUS_DISPLAY_MODE_STATE_PREFIX"}
            env_map["NOTIF_ID_ROOT"] = tmp
            with patch.dict(os.environ, env_map, clear=True):
                self.assertTrue(_call("_osd_session_active"))

    def test_run_cancel_display_osd_success_and_timeout(self):
        """--cancel-osd worker runs subprocess and logs timeouts at warning."""
        completed = MagicMock()
        completed.returncode = 0
        completed.stderr = ""
        with patch("asus_hotkey_daemon_osd._subprocess_run", return_value=completed) as run:
            _call("_run_cancel_display_osd")
        run.assert_called_once()
        with (
            patch("asus_hotkey_daemon_osd._subprocess_run", side_effect=subprocess.TimeoutExpired(cmd="x", timeout=1)),
            self.assertLogs("asus_hotkey_daemon_osd", level="WARNING"),
        ):
            _call("_run_cancel_display_osd")


def _is_key_release_write(call) -> bool:
    """Return True when *call* is an EV_KEY release write."""
    if len(call.args) < 3:
        return False
    return call.args[0] == ecodes.EV_KEY and call.args[2] == 0


def _released_key_codes(kb_ui):
    """Return EV_KEY release codes written to *kb_ui*."""
    return {c.args[1] for c in kb_ui.write.call_args_list if _is_key_release_write(c)}
