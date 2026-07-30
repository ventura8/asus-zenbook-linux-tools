"""AT keyboard Super+P filter and related input-path unit tests."""

import itertools
import unittest
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from evdev import ecodes

from tests.unit.bin.at_keyboard_test_utils import (
    _call,
    _key,
    _reset_at_keyboard_state,
    daemon_at_proxy,
    daemon_runtime,
)
from tests.unit.bin.hotkey_daemon_test_utils import load_daemon

load_daemon()


class TestAsusHotkeyAtKeyboardProxy(unittest.TestCase):
    """AT keyboard Super+P buffering, WMI forward paths, and proxy open/grab."""

    def setUp(self):
        """Reset daemon + pending Super chord state."""
        _reset_at_keyboard_state(self)

    def test_dispatch_resolved_script_outcomes(self):
        """Test started/debounced/missing dispatch logging branches."""
        with (
            patch("asus_hotkey_daemon_runtime.is_executable_file", return_value=True),
            patch("asus_hotkey_daemon_runtime.threading.Thread", return_value=MagicMock()),
            patch("asus_hotkey_daemon_runtime.time.monotonic", return_value=1.0),
            self.assertLogs("asus_hotkey_daemon_runtime", level="INFO"),
        ):
            _call("_dispatch_resolved_script", "asus-display-mode.sh")
        debounce_times = itertools.chain([2.0, 2.01], itertools.repeat(2.01))
        with (
            patch("asus_hotkey_daemon_runtime.is_executable_file", return_value=True),
            patch("asus_hotkey_daemon_runtime.threading.Thread", return_value=MagicMock()),
            patch("asus_hotkey_daemon_runtime.time.monotonic", side_effect=lambda: next(debounce_times)),
            self.assertLogs("asus_hotkey_daemon_runtime", level="DEBUG"),
        ):
            daemon_runtime.run_script_if_exists("/usr/local/bin/asus-fan-toggle.sh")
            _call("_dispatch_resolved_script", "asus-fan-toggle.sh")
        with (
            patch("asus_hotkey_daemon_runtime.is_executable_file", return_value=False),
            self.assertLogs("asus_hotkey_daemon_runtime", level="WARNING"),
        ):
            _call("_dispatch_resolved_script", "asus-display-mode.sh")

    def test_forward_wmi_key_none_ui_and_oserror(self):
        """Test WMI forward no-ops on None ui and swallows write OSError."""
        _call("_forward_wmi_key", None, ecodes.KEY_A, 1)
        ui = MagicMock()
        ui.write.side_effect = OSError("broken")
        _call("_forward_wmi_key", ui, ecodes.KEY_A, 1)
        ui.write.assert_called()

    def test_human_super_hold_is_forwarded(self):
        """Test slow Super+P (human) flushes the buffered chord to the proxy."""
        kb_ui = MagicMock()
        t0 = 100.0
        _call("_handle_at_key_event", _key(ecodes.KEY_LEFTMETA, 1), kb_ui, t0)
        _call("_handle_at_key_event", _key(ecodes.KEY_P, 1), kb_ui, t0 + 0.01)
        _call("_handle_at_key_event", _key(ecodes.KEY_P, 0), kb_ui, t0 + 0.02)
        _call("_handle_at_key_event", _key(ecodes.KEY_LEFTMETA, 0), kb_ui, t0 + 0.2)
        write_codes = [call.args[1] for call in kb_ui.write.call_args_list if call.args]
        self.assertIn(ecodes.KEY_LEFTMETA, write_codes)
        self.assertIn(ecodes.KEY_P, write_codes)

    def test_non_p_during_pending_flushes(self):
        """Test a non-P key during pending Super flushes as human input."""
        kb_ui = MagicMock()
        t0 = 50.0
        _call("_handle_at_key_event", _key(ecodes.KEY_LEFTMETA, 1), kb_ui, t0)
        _call("_handle_at_key_event", _key(ecodes.KEY_A, 1), kb_ui, t0 + 0.01)
        self.assertTrue(kb_ui.write.called)

    def test_expire_pending_meta_flushes_old_buffer(self):
        """Test pending Super buffer expires after the firmware window."""
        kb_ui = MagicMock()
        t0 = 10.0
        _call("_start_pending_meta", _key(ecodes.KEY_LEFTMETA, 1), t0)
        _call("_expire_pending_meta", kb_ui, t0 + 1.0)
        self.assertTrue(kb_ui.write.called)

    def test_forward_key_now_and_event_none_ui(self):
        """Test forward helpers tolerate a missing keyboard proxy."""
        event = _key(ecodes.KEY_A, 1)
        _call("_forward_event", None, event)
        _call("_forward_key_now", None, event)
        kb_ui = MagicMock()
        _call("_forward_key_now", kb_ui, event)
        kb_ui.syn.assert_called()

    def test_handle_at_event_non_key_while_pending(self):
        """Test non-EV_KEY events are buffered while Super is pending."""
        kb_ui = MagicMock()
        _call("_start_pending_meta", _key(ecodes.KEY_LEFTMETA, 1), 1.0)
        syn = _key(0, 0, event_type=ecodes.EV_SYN)
        with patch("asus_hotkey_daemon_at_proxy.time.monotonic", return_value=1.0):
            _call("_handle_at_event", syn, kb_ui)
        kb_ui.write.assert_not_called()
        self.assertTrue(daemon_at_proxy.pending_meta_buffered())

    def test_handle_at_event_non_key_without_pending(self):
        """Test non-EV_KEY events are forwarded when no Super buffer exists."""
        kb_ui = MagicMock()
        syn = _key(0, 0, event_type=ecodes.EV_SYN)
        _call("_handle_at_event", syn, kb_ui)
        kb_ui.write.assert_called()
        self.assertFalse(daemon_at_proxy.pending_meta_buffered())

    def test_meta_while_not_pending_forwards(self):
        """Test Meta key while not starting a chord still forwards."""
        kb_ui = MagicMock()
        _call("_handle_meta_key_event", _key(ecodes.KEY_LEFTMETA, 0), kb_ui, 1.0)
        kb_ui.write.assert_called()

    def test_open_keyboard_proxy_grab_failure(self):
        """Test keyboard proxy creation aborts when device grab fails."""
        kb_dev = MagicMock()
        kb_dev.name = "AT keyboard"
        kb_dev.grab.side_effect = OSError("busy")
        with self.assertLogs("asus_hotkey_daemon_input", level="WARNING") as log_ctx:
            self.assertIsNone(_call("_open_keyboard_proxy", kb_dev))
        self.assertTrue(any("Failed to grab exclusive access on AT keyboard" in line for line in log_ctx.output))

    @patch("asus_hotkey_daemon_input.UInput", side_effect=OSError("no uinput"))
    def test_open_keyboard_proxy_uinput_failure_ungrabs(self, _mock_uinput):
        """Test UInput failure ungrabs the AT keyboard device."""
        kb_dev = MagicMock()
        kb_dev.name = "AT keyboard"
        kb_dev.capabilities.return_value = {ecodes.EV_KEY: [ecodes.KEY_A]}
        with self.assertLogs("asus_hotkey_daemon_input", level="WARNING") as log_ctx:
            self.assertIsNone(_call("_open_keyboard_proxy", kb_dev))
        kb_dev.ungrab.assert_called_once()
        self.assertTrue(any("Failed to create AT keyboard proxy" in line for line in log_ctx.output))

    def test_open_keyboard_proxy_none_device(self):
        """Test None AT device returns None without creating a proxy."""
        self.assertIsNone(_call("_open_keyboard_proxy", None))

    def test_device_map_with_and_without_keyboard(self):
        """Test event-loop device map includes optional keyboard fd."""
        wmi = MagicMock(fd=1)
        kb = MagicMock(fd=2)
        dev_map, wmi_fd, kb_fd = _call("_device_map", wmi, kb)
        self.assertEqual(wmi_fd, 1)
        self.assertEqual(kb_fd, 2)
        self.assertEqual(set(dev_map), {1, 2})
        dev_map, wmi_fd, kb_fd = _call("_device_map", wmi, None)
        self.assertIsNone(kb_fd)
        self.assertEqual(set(dev_map), {1})

    def test_dispatch_ready_fd_routes_keyboard(self):
        """Test ready-fd dispatch routes AT keyboard events to the filter."""
        kb_dev = MagicMock()
        kb_dev.read.return_value = [_key(ecodes.KEY_A, 1)]
        loop_state = SimpleNamespace(
            dev_map={2: kb_dev}, wmi_fd=1, kb_fd=2, kb_ui=MagicMock(), ui=MagicMock(), last_scancode=None, swap_step=0
        )
        _call("_dispatch_ready_fd", 2, loop_state)
        loop_state.kb_ui.write.assert_called()

    def test_dispatch_ready_fd_ignores_unknown_fd(self):
        """Test ready-fd dispatch no-ops when fd is absent from dev_map."""
        loop_state = SimpleNamespace(dev_map={}, wmi_fd=1, kb_fd=2, kb_ui=MagicMock(), ui=MagicMock(), last_scancode=None, swap_step=0)
        _call("_dispatch_ready_fd", 99, loop_state)
        loop_state.kb_ui.write.assert_not_called()

    @patch("asus_hotkey_daemon_input.select.select")
    def test_event_loop_tick_expires_pending(self, mock_select):
        """Test event loop tick expires stale Super buffers."""
        mock_select.return_value = ([], [], [])
        kb_ui = MagicMock()
        _call("_start_pending_meta", _key(ecodes.KEY_LEFTMETA, 1), 1.0)
        loop_state = SimpleNamespace(
            dev_map={1: MagicMock()}, wmi_fd=1, kb_fd=None, kb_ui=kb_ui, ui=MagicMock(), last_scancode=None, swap_step=0
        )
        with patch("asus_hotkey_daemon_input.time.monotonic", return_value=2.0):
            _call("_event_loop_tick", loop_state)
        kb_ui.write.assert_called()
