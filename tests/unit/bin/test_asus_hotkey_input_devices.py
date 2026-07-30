"""WMI device lifecycle and ScreenPad brightness chord unit tests."""

import importlib
import unittest
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from evdev import ecodes

from tests.unit.bin.at_keyboard_test_utils import (
    _call,
    _key,
    _osd_prefix_cancel_run,
    _reset_at_keyboard_state,
    _screenpad_access_side_effect,
    _screenpad_isfile_side_effect,
    daemon_brightness,
    daemon_input,
)
from tests.unit.bin.attr_helpers import call_attr


class TestAsusHotkeyInputDeviceLifecycle(unittest.TestCase):
    """WMI/AT device open, close, and event-dispatch lifecycle paths."""

    def setUp(self):
        """Reset daemon + pending Super chord state."""
        _reset_at_keyboard_state(self)

    def test_log_and_dispatch_hotkey_and_wmi_script_press(self):
        """WMI script presses log and dispatch via _handle_wmi_key_press."""
        with (
            patch("asus_hotkey_daemon_runtime.is_executable_file", return_value=True),
            patch("asus_hotkey_daemon_runtime.threading.Thread") as mock_thread,
            self.assertLogs("asus_hotkey_daemon_input", level="INFO"),
        ):
            sc, step = _call("_handle_wmi_key_press", 133, 1, MagicMock(), 0)
        mock_thread.assert_called_once()
        self.assertIsNone(sc)
        self.assertEqual(step, 0)

    def test_process_hotkey_event_ignores_non_press(self):
        """Non-MSC / non-press EV_KEY events keep scancode and swap step."""
        event = MagicMock()
        event.type = ecodes.EV_KEY
        event.code = ecodes.KEY_A
        event.value = 0
        sc, step = _call("_process_hotkey_event", event, 16, MagicMock(), 3)
        self.assertEqual(sc, 16)
        self.assertEqual(step, 3)

    def test_open_device_wmi_and_keyboard_open_errors(self):
        """WMI open failure exits; AT keyboard open failure soft-skips."""
        with (
            patch("asus_hotkey_daemon_input.find_input_device_path", side_effect=["/dev/wmi", "/dev/kb"]),
            patch("asus_hotkey_daemon_input.evdev.InputDevice", side_effect=OSError("busy")),
            self.assertRaises(SystemExit),
        ):
            _call("_open_device")
        wmi = MagicMock()
        with (
            patch("asus_hotkey_daemon_input.find_input_device_path", side_effect=["/dev/wmi", "/dev/kb"]),
            patch("asus_hotkey_daemon_input.evdev.InputDevice", side_effect=[wmi, OSError("kb")]),
            self.assertLogs("asus_hotkey_daemon_input", level="WARNING") as log_ctx,
        ):
            opened_wmi, opened_kb = _call("_open_device")
        self.assertIs(opened_wmi, wmi)
        self.assertIsNone(opened_kb)
        self.assertTrue(any("Failed to open AT keyboard" in line for line in log_ctx.output))

    def test_build_input_capabilities_tolerates_wmi_oserror(self):
        """WMI capabilities OSError yields synthetic key codes only."""
        wmi = MagicMock()
        wmi.capabilities.side_effect = OSError("gone")
        caps = _call("_build_input_capabilities", wmi)
        self.assertIn(ecodes.EV_KEY, caps)
        self.assertIn(ecodes.KEY_LEFTMETA, caps[ecodes.EV_KEY])

    def test_close_runtime_devices_swallows_ungrab_oserror(self):
        """ungrab OSError during close is ignored."""
        wmi = MagicMock()
        wmi.ungrab.side_effect = OSError("already")
        kb = MagicMock()
        kb.ungrab.side_effect = OSError("already")
        with patch("asus_hotkey_daemon_input.close_input_device") as closer:
            _call("_close_runtime_devices", MagicMock(), wmi, kb, MagicMock())
        self.assertGreaterEqual(closer.call_count, 2)

    def test_forward_and_flush_syn_oserrors(self):
        """Proxy write/syn OSErrors are swallowed with debug logs."""
        kb_ui = MagicMock()
        kb_ui.write.side_effect = OSError("write")
        with self.assertLogs("asus_hotkey_daemon_at_proxy", level="DEBUG"):
            _call("_forward_event", kb_ui, _key(ecodes.KEY_A, 1))
        kb_ui = MagicMock()
        kb_ui.syn.side_effect = OSError("syn")
        _call("_start_pending_meta", _key(ecodes.KEY_LEFTMETA, 1), 1.0)
        with self.assertLogs("asus_hotkey_daemon_at_proxy", level="DEBUG"):
            _call("_flush_pending_meta", kb_ui)
        kb_ui = MagicMock()
        kb_ui.syn.side_effect = OSError("syn2")
        with self.assertLogs("asus_hotkey_daemon_at_proxy", level="DEBUG"):
            _call("_forward_key_now", kb_ui, _key(ecodes.KEY_B, 1))

    def test_complete_pending_meta_human_flush_path(self):
        """Meta-up without a fast Super+P flushes the human chord."""
        kb_ui = MagicMock()
        _call("_start_pending_meta", _key(ecodes.KEY_LEFTMETA, 1), 1.0)
        _call("_complete_pending_meta_up", kb_ui, 1.2)
        self.assertTrue(kb_ui.write.called)

    def test_handle_at_key_routes_esc(self):
        """AT KEY_ESC is routed through _handle_esc_key."""
        kb_ui = MagicMock()
        with patch("asus_hotkey_daemon_osd._subprocess_run") as cancel_run:
            _call("_handle_at_key_event", _key(ecodes.KEY_ESC, 1), kb_ui, 1.0)
        self.assertTrue(kb_ui.write.called)
        cancel_run.assert_not_called()

    def test_esc_during_osd_drops_pending_meta_without_flush(self):
        """Esc during sticky OSD must drop buffered Super+P, not forward it."""
        kb_ui = MagicMock()
        at_proxy = importlib.import_module("asus_hotkey_daemon_at_proxy")
        cancel_run = self._esc_during_osd_with_pending_meta(kb_ui, at_proxy)
        cancel_run.assert_called_once()
        self.assertFalse(_call("pending_meta_buffered"))
        self.assertFalse(_key_writes(kb_ui, ecodes.KEY_P))
        self.assertFalse(_meta_keydown_writes(kb_ui))

    def _esc_during_osd_with_pending_meta(self, kb_ui, at_proxy):
        """Buffer Super+P under an active OSD session, then Esc-cancel."""
        with _osd_prefix_cancel_run(self.assertLogs("asus_hotkey_daemon_osd", level="INFO")) as (
            prefix,
            cancel_run,
        ):
            cancel_run.return_value = MagicMock(returncode=0, stderr="")
            with open(f"{prefix}.session", "w", encoding="utf-8") as handle:
                handle.write("1\n")
            _call("_start_pending_meta", _key(ecodes.KEY_LEFTMETA, 1), 1.0)
            call_attr(
                at_proxy,
                "buffer_or_flush_non_meta",
                _key(ecodes.KEY_P, 1),
                kb_ui,
                1.01,
            )
            kb_ui.write.reset_mock()
            _call("_handle_at_key_event", _key(ecodes.KEY_ESC, 1), kb_ui, 1.02)
        return cancel_run

    def test_open_keyboard_proxy_ungrab_oserror_is_ignored(self):
        """UInput failure ignores secondary ungrab OSError."""
        kb_dev = MagicMock()
        kb_dev.name = "AT keyboard"
        kb_dev.capabilities.return_value = {ecodes.EV_KEY: [ecodes.KEY_A]}
        kb_dev.ungrab.side_effect = OSError("race")
        with (
            patch("asus_hotkey_daemon_input.UInput", side_effect=OSError("no uinput")),
            self.assertLogs("asus_hotkey_daemon_input", level="WARNING"),
        ):
            self.assertIsNone(_call("_open_keyboard_proxy", kb_dev))
        kb_dev.ungrab.assert_called_once()

    def test_dispatch_ready_fd_marks_wmi_gone_on_read_error(self):
        """WMI read OSError drops the fd and flags wmi_gone."""
        wmi_dev = MagicMock()
        wmi_dev.read.side_effect = OSError("gone")
        loop_state = SimpleNamespace(
            dev_map={1: wmi_dev},
            wmi_fd=1,
            kb_fd=None,
            kb_ui=None,
            ui=MagicMock(),
            last_scancode=None,
            swap_step=0,
            wmi_gone=False,
            mod_fds=set(),
            video_fds=set(),
        )
        _call("_dispatch_ready_fd", 1, loop_state)
        self.assertTrue(loop_state.wmi_gone)
        self.assertNotIn(1, loop_state.dev_map)


class TestAsusHotkeyScreenpadBrightnessChords(unittest.TestCase):
    """Shift/Video Bus brightness chords and ScreenPad helper dispatch."""

    def setUp(self):
        """Reset daemon + pending Super chord state."""
        _reset_at_keyboard_state(self)

    @patch(
        "asus_hotkey_daemon_input.select.select",
        side_effect=[([1], [], []), AssertionError("select called too many times")],
    )
    def test_run_event_loop_exits_when_wmi_gone(self, _mock_select):
        """Event loop raises SystemExit after WMI device loss."""
        wmi = MagicMock(fd=1, path="/dev/wmi", name="WMI")
        wmi.read.side_effect = OSError("gone")
        with self.assertRaises(SystemExit) as ctx:
            _call("_run_event_loop", wmi, None, MagicMock(), None)
        self.assertIn("WMI hotkey device lost", str(ctx.exception))

    def test_plain_wmi_brightness_is_forwarded(self):
        """Without Alt/Shift, WMI brightness is forwarded for the main panel."""
        ui = MagicMock()
        daemon_input.clear_brightness_chord_state()
        last, step = _call("_handle_wmi_key_press", None, ecodes.KEY_BRIGHTNESSUP, ui, 0, True)
        self.assertIsNone(last)
        self.assertEqual(step, 0)
        self.assertGreaterEqual(ui.write.call_count, 2)

    @patch("asus_hotkey_daemon_runtime.is_executable_file", return_value=True)
    @patch("asus_hotkey_daemon_brightness.is_executable_file", return_value=True)
    @patch(
        "asus_hotkey_daemon_brightness.os.path.isfile",
        side_effect=_screenpad_isfile_side_effect(True),
    )
    @patch(
        "asus_hotkey_daemon_brightness.os.access",
        side_effect=_screenpad_access_side_effect(True),
    )
    @patch("asus_hotkey_daemon_runtime.threading.Thread")
    def test_shift_brightness_up_dispatches_screenpad_helper(self, mock_thread_cls, _a, _f, _exec, _runtime_exec):
        """Shift held on modifier watch + brightness up dispatches screenpad helper."""
        mock_thread_cls.return_value = MagicMock()
        ui = MagicMock()
        daemon_input.clear_brightness_chord_state()
        daemon_brightness.dispatch_modifier_watch_events([_key(ecodes.KEY_LEFTSHIFT, 1)])
        self.addCleanup(daemon_brightness.dispatch_modifier_watch_events, [_key(ecodes.KEY_LEFTSHIFT, 0)])
        self.addCleanup(daemon_input.clear_brightness_chord_state)
        _call("_handle_wmi_key_press", None, ecodes.KEY_BRIGHTNESSUP, ui, 0, True)
        ui.write.assert_not_called()
        self.assertEqual(mock_thread_cls.call_args.kwargs.get("args"), ("/usr/local/bin/asus-screenpad-brightness.sh", ["up"]))

    @patch("asus_hotkey_daemon_runtime.is_executable_file", return_value=True)
    @patch("asus_hotkey_daemon_brightness.is_executable_file", return_value=True)
    @patch(
        "asus_hotkey_daemon_brightness.os.path.isfile",
        side_effect=_screenpad_isfile_side_effect(True),
    )
    @patch(
        "asus_hotkey_daemon_brightness.os.access",
        side_effect=_screenpad_access_side_effect(True),
    )
    @patch("asus_hotkey_daemon_runtime.threading.Thread")
    def test_shift_brightness_down_dispatches_helper(self, mock_thread_cls, _a, _f, _exec, _runtime_exec):
        """Shift held on modifier watch + brightness down dispatches screenpad down."""
        mock_thread_cls.return_value = MagicMock()
        ui = MagicMock()
        daemon_input.clear_brightness_chord_state()
        daemon_brightness.dispatch_modifier_watch_events([_key(ecodes.KEY_LEFTSHIFT, 1)])
        self.addCleanup(daemon_brightness.dispatch_modifier_watch_events, [_key(ecodes.KEY_LEFTSHIFT, 0)])
        self.addCleanup(daemon_input.clear_brightness_chord_state)
        _call("_handle_wmi_key_press", None, ecodes.KEY_BRIGHTNESSDOWN, ui, 0, True)
        ui.write.assert_not_called()
        self.assertEqual(mock_thread_cls.call_args.kwargs.get("args"), ("/usr/local/bin/asus-screenpad-brightness.sh", ["down"]))

    def test_alt_brightness_does_not_dispatch_screenpad_helper(self):
        """Alt must not trigger ScreenPad brightness (Alt+F4 collision on F4)."""
        ui = MagicMock()
        daemon_input.clear_brightness_chord_state()
        alt = _key(ecodes.KEY_LEFTALT, 1)
        self.assertFalse(daemon_brightness.update_at_modifier_state(alt))
        daemon_brightness.dispatch_modifier_watch_events([alt])
        self.addCleanup(daemon_brightness.dispatch_modifier_watch_events, [_key(ecodes.KEY_LEFTALT, 0)])
        self.addCleanup(daemon_input.clear_brightness_chord_state)
        _call("_handle_wmi_key_press", None, ecodes.KEY_BRIGHTNESSUP, ui, 0, True)
        self.assertGreaterEqual(ui.write.call_count, 2)

    def test_video_bus_brightness_forward_and_mod_dispatch(self):
        """Video Bus plain brightness forwards; mod fd updates Shift state."""
        daemon_input.clear_brightness_chord_state()
        ui = MagicMock()
        loop_state = SimpleNamespace(
            ui=ui,
            kb_ui=None,
            wmi_fd=1,
            kb_fd=None,
            mod_fds={3},
            video_fds={4},
            wmi_grabbed=True,
            wmi_gone=False,
            swap_step=0,
            last_scancode=None,
            dev_map={},
        )
        bright = _key(ecodes.KEY_BRIGHTNESSUP, 1)
        video_dev = MagicMock()
        video_dev.read.return_value = [bright]
        loop_state.dev_map[4] = video_dev
        _call("_dispatch_ready_fd", 4, loop_state)
        self.assertGreaterEqual(ui.write.call_count, 2)
        daemon_input.clear_brightness_chord_state()
        ui.reset_mock()
        mod_dev = MagicMock()
        mod_dev.read.return_value = [_key(ecodes.KEY_LEFTSHIFT, 1)]
        loop_state.dev_map[3] = mod_dev
        _call("_dispatch_ready_fd", 3, loop_state)
        self.addCleanup(daemon_input.clear_brightness_chord_state)
        self.addCleanup(daemon_brightness.dispatch_modifier_watch_events, [_key(ecodes.KEY_LEFTSHIFT, 0)])
        self.assertTrue(daemon_brightness.brightness_modifier_held())

    def test_wmi_and_video_brightness_deduped(self):
        """Near-simultaneous WMI + Video Bus brightness only forwards once."""
        daemon_input.clear_brightness_chord_state()
        ui = MagicMock()
        _call("_handle_wmi_key_press", None, ecodes.KEY_BRIGHTNESSUP, ui, 0, True)
        first_writes = ui.write.call_count
        self.assertGreaterEqual(first_writes, 2)
        daemon_brightness.handle_brightness_source_press(ecodes.KEY_BRIGHTNESSUP, lambda code, value: ui.write(ecodes.EV_KEY, code, value))
        self.assertEqual(ui.write.call_count, first_writes)

    @patch(
        "asus_hotkey_daemon_brightness.os.path.isfile",
        side_effect=_screenpad_isfile_side_effect(False),
    )
    @patch(
        "asus_hotkey_daemon_brightness.os.access",
        side_effect=_screenpad_access_side_effect(False),
    )
    def test_shift_brightness_forwards_without_screenpad_node(self, _access, _isfile):
        """Shift+brightness must not swallow when ScreenPad sysfs is absent."""
        ui = MagicMock()
        daemon_input.clear_brightness_chord_state()
        daemon_brightness.dispatch_modifier_watch_events([_key(ecodes.KEY_LEFTSHIFT, 1)])
        self.addCleanup(daemon_brightness.dispatch_modifier_watch_events, [_key(ecodes.KEY_LEFTSHIFT, 0)])
        self.addCleanup(daemon_input.clear_brightness_chord_state)
        _call("_handle_wmi_key_press", None, ecodes.KEY_BRIGHTNESSUP, ui, 0, True)
        self.assertGreaterEqual(ui.write.call_count, 2)

    @patch("asus_hotkey_daemon_runtime.is_executable_file", return_value=True)
    @patch("asus_hotkey_daemon_brightness.is_executable_file", return_value=True)
    @patch(
        "asus_hotkey_daemon_brightness.os.path.isfile",
        side_effect=_screenpad_isfile_side_effect(True),
    )
    @patch(
        "asus_hotkey_daemon_brightness.os.access",
        side_effect=_screenpad_access_side_effect(True),
    )
    @patch("asus_hotkey_daemon_runtime.threading.Thread")
    def test_at_shift_brightness_swallows_and_dispatches(self, mock_thread_cls, _a, _f, _exec, _runtime_exec):
        """AT Shift + AT brightness up is swallowed and dispatches the helper."""
        mock_thread_cls.return_value = MagicMock()
        kb_ui = MagicMock()
        daemon_input.clear_brightness_chord_state()
        self.addCleanup(daemon_input.clear_brightness_chord_state)
        self.addCleanup(_call, "_handle_at_key_event", _key(ecodes.KEY_LEFTSHIFT, 0), MagicMock(), 1.3)
        _call("_handle_at_key_event", _key(ecodes.KEY_LEFTSHIFT, 1), kb_ui, 1.0)
        kb_ui.reset_mock()
        _call("_handle_at_key_event", _key(ecodes.KEY_BRIGHTNESSUP, 1), kb_ui, 1.1)
        kb_ui.write.assert_not_called()
        _call("_handle_at_key_event", _key(ecodes.KEY_BRIGHTNESSUP, 0), kb_ui, 1.2)
        kb_ui.write.assert_not_called()
        self.assertEqual(
            mock_thread_cls.call_args.kwargs.get("args"),
            ("/usr/local/bin/asus-screenpad-brightness.sh", ["up"]),
        )

    def test_modifier_watch_excludes_at_keyboard_name(self):
        """AT and proxy keyboard names are never watched for Shift."""
        self.assertFalse(call_attr(daemon_brightness, "_is_modifier_watch_keyboard", "AT Translated Set 2 keyboard"))
        self.assertFalse(call_attr(daemon_brightness, "_is_modifier_watch_keyboard", "asus-at-keyboard-proxy"))
        self.assertTrue(call_attr(daemon_brightness, "_is_modifier_watch_keyboard", "ASUE1406:00 04F3:3101 Keyboard"))

    def test_screenpad_sysfs_candidates_and_video_bus_open(self):
        """ScreenPad path discovery and Video Bus / modifier-watch open paths."""
        with patch.dict("os.environ", {"ASUS_SCREENPAD_NODE": "/tmp/fake-sp-$$"}, clear=False):
            paths = list(call_attr(daemon_brightness, "_screenpad_sysfs_candidates"))
        self.assertEqual(paths, ["/tmp/fake-sp-$$"])
        with patch.dict("os.environ", {"ASUS_SCREENPAD_NODE": "", "SYS_CLASS_ROOT": "/tmp/sys-$$"}, clear=False):
            paths = list(call_attr(daemon_brightness, "_screenpad_sysfs_candidates"))
            self.assertIn("/tmp/sys-$$/backlight/asus_screenpad/brightness", paths)
            self.assertIn("/tmp/sys-$$/leds/asus::screenpad/brightness", paths)
            # Must stay inside the fixture: host ZenBooks have a real writable node.
            self.assertFalse(call_attr(daemon_brightness, "screenpad_node_writable"))

        good = MagicMock()
        good.name = "ASUE Keyboard"
        good.path = "/dev/input/event9"
        good.capabilities.return_value = {ecodes.EV_KEY: [ecodes.KEY_LEFTSHIFT]}
        bad = MagicMock()
        bad.name = "AT Translated Set 2 keyboard"
        bad.capabilities.return_value = {ecodes.EV_KEY: [ecodes.KEY_LEFTSHIFT]}
        path_list = ["/dev/good", "/dev/bad", "/dev/err"]
        with (
            patch(
                "asus_hotkey_daemon_brightness.list_evdev_device_paths",
                return_value=path_list,
            ),
            patch(
                "asus_hotkey_daemon_brightness.evdev.InputDevice",
                side_effect=[good, bad, OSError("gone")],
            ),
            patch("asus_hotkey_daemon_brightness.close_input_device") as closer,
        ):
            opened = call_attr(daemon_brightness, "open_modifier_watch_devices")
        self.assertEqual(opened, [good])
        closer.assert_called()
        good2 = MagicMock()
        good2.name = "ASUE Keyboard"
        good2.path = "/dev/input/event9"
        good2.capabilities.return_value = {ecodes.EV_KEY: [ecodes.KEY_LEFTSHIFT]}
        with (
            patch(
                "asus_hotkey_daemon_brightness.list_evdev_device_paths",
                return_value=["/dev/good"],
            ),
            patch("asus_hotkey_daemon_brightness.evdev.InputDevice", return_value=good2),
            patch("asus_hotkey_daemon_brightness.close_input_device"),
        ):
            paths = call_attr(daemon_brightness, "list_modifier_watch_keyboard_paths")
        self.assertEqual(paths, ["/dev/input/event9"])

        video = MagicMock()
        video.name = "Video Bus"
        grab_fail = MagicMock()
        grab_fail.name = "Video Bus"
        grab_fail.grab.side_effect = OSError("busy")
        with (
            patch(
                "asus_hotkey_daemon_brightness.find_all_input_device_paths",
                return_value=["/dev/v1", "/dev/v2", "/dev/v3"],
            ),
            patch(
                "asus_hotkey_daemon_brightness.evdev.InputDevice",
                side_effect=[video, grab_fail, OSError("missing")],
            ),
            patch("asus_hotkey_daemon_brightness.close_input_device"),
            self.assertLogs("asus_hotkey_daemon_brightness", level="INFO"),
        ):
            grabbed = call_attr(daemon_brightness, "open_video_bus_devices")
        self.assertEqual(grabbed, [video])

        ui = MagicMock()
        daemon_brightness.dispatch_video_bus_events(
            [_key(ecodes.KEY_BRIGHTNESSUP, 1), _key(ecodes.KEY_A, 1)],
            lambda code, value: ui.write(ecodes.EV_KEY, code, value),
        )
        self.assertGreaterEqual(ui.write.call_count, 1)
        self.assertFalse(
            call_attr(daemon_brightness, "_device_has_modifier_keys", MagicMock(capabilities=MagicMock(side_effect=OSError())))
        )
        held = call_attr(daemon_brightness, "try_handle_at_brightness_event", _key(ecodes.KEY_BRIGHTNESSUP, 2))
        self.assertFalse(held)


def _key_writes(kb_ui, key_code):
    """Return write calls whose second arg matches *key_code*."""
    return [call for call in kb_ui.write.call_args_list if len(call.args) >= 2 and call.args[1] == key_code]


def _meta_keydown_writes(kb_ui):
    """Return Super key-down write calls from *kb_ui*."""
    meta_codes = (ecodes.KEY_LEFTMETA, ecodes.KEY_RIGHTMETA)
    return [call for call in kb_ui.write.call_args_list if len(call.args) >= 3 and call.args[1] in meta_codes and call.args[2] == 1]


if __name__ == "__main__":
    unittest.main()
