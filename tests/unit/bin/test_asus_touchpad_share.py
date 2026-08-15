"""Unit tests matching bin/asus-touchpad-share.py."""

import itertools
import subprocess
import sys
import time
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

import shared_imports
from tests.unit.bin.attr_helpers import call_attr

PROJECT_ROOT = Path(__file__).resolve().parents[3]
BIN_DIR = PROJECT_ROOT / "bin"


def load_touchpad():
    """Load asus_touchpad_share from the underscore module path."""
    module_path = BIN_DIR / "asus_touchpad_share.py"
    if str(BIN_DIR) not in sys.path:
        sys.path.insert(0, str(BIN_DIR))
    existing = sys.modules.get("asus_touchpad_share")
    if existing is not None and getattr(existing, "__file__", None) == str(module_path):
        return existing
    return shared_imports.load_module_from_path("asus_touchpad_share", str(module_path))


touchpad = load_touchpad()


class TestAsusTouchpadShare(unittest.TestCase):
    """Unit tests for bin/asus-touchpad-share.py functions."""

    def test_hyphen_entrypoint_symlink_targets_underscore_module(self):
        """CLI hyphen symlink must resolve to the underscore Python module."""
        hyphen_path = BIN_DIR / "asus-touchpad-share.py"
        self.assertTrue(hyphen_path.is_symlink())
        self.assertEqual(hyphen_path.resolve(), (BIN_DIR / "asus_touchpad_share.py").resolve())

    def test_is_corner_gesture_valid(self):
        """Test is_corner_gesture detects tap in top-left corner under 0.7s."""
        bounds = (1000.0, 800.0)
        coords = (100, 100, 100, 100, 0.3)
        self.assertTrue(touchpad.is_corner_gesture(coords, bounds))

    def test_is_corner_gesture_invalid_coords(self):
        """Test is_corner_gesture rejects tap outside top-left corner."""
        bounds = (1000.0, 800.0)
        coords_out = (1200, 400, 1200, 400, 0.3)
        self.assertFalse(touchpad.is_corner_gesture(coords_out, bounds))
        coords_center = (500, 400, 500, 400, 0.3)
        self.assertFalse(touchpad.is_corner_gesture(coords_center, (400.0, 300.0)))

    def test_is_corner_gesture_invalid_duration(self):
        """Test is_corner_gesture rejects tap exceeding duration threshold."""
        bounds = (1000.0, 800.0)
        coords = (100, 100, 100, 100, 0.9)
        self.assertFalse(touchpad.is_corner_gesture(coords, bounds))

    def test_process_abs_event(self):
        """Test process_abs_event updates X touch coordinates."""
        mock_event = MagicMock()
        mock_event.code = touchpad.ecodes.ABS_X
        mock_event.value = 350
        state = (-1, -1, -1, -1)
        start_x, _, curr_x, _ = touchpad.process_abs_event(mock_event, True, state)
        self.assertEqual(start_x, 350)
        self.assertEqual(curr_x, 350)

    def test_trigger_screenshot(self):
        """Test trigger_screenshot invokes the multi-DE screenshot helper."""
        with patch("asus_touchpad_share.subprocess.run") as mock_run:
            mock_run.return_value = subprocess.CompletedProcess(["helper"], 0)
            touchpad.trigger_screenshot()
            time.sleep(0.05)
            screenshot_calls = [call for call in mock_run.call_args_list if call.args and "asus-screenshot.sh" in call.args[0][0]]
            self.assertEqual(len(screenshot_calls), 1)

    @patch("evdev.list_devices")
    @patch("evdev.InputDevice")
    def test_find_touchpad_device_path_success(self, mock_input_device, mock_list_devices):
        """Test find_touchpad_device_path locates touchpad device."""
        mock_list_devices.return_value = ["/dev/input/event1"]
        mock_dev = MagicMock()
        mock_dev.name = "ASUS Touchpad"
        mock_input_device.return_value = mock_dev
        path = touchpad.find_touchpad_device_path()
        self.assertEqual(path, "/dev/input/event1")

    @patch("evdev.list_devices", return_value=[])
    def test_find_touchpad_device_path_none(self, _mock_list_devices):
        """Test find_touchpad_device_path returns None when no touchpad is found."""
        path = touchpad.find_touchpad_device_path()
        self.assertIsNone(path)

    def test_get_abs_axis_mt(self):
        """Test get_abs_axis returns info for multi-touch axis."""
        mock_dev = MagicMock()
        mock_info = MagicMock()
        mock_dev.absinfo.side_effect = lambda code: mock_info if code == touchpad.ecodes.ABS_MT_POSITION_X else None
        res = touchpad.get_abs_axis(mock_dev, touchpad.ecodes.ABS_MT_POSITION_X, touchpad.ecodes.ABS_X)
        self.assertEqual(res, mock_info)

    def test_get_abs_axis_fallback(self):
        """Test get_abs_axis falls back to single-touch axis."""
        mock_dev = MagicMock()
        mock_info = MagicMock()

        def mock_absinfo(code):
            if code == touchpad.ecodes.ABS_MT_POSITION_X:
                raise KeyError("no mt")
            if code == touchpad.ecodes.ABS_X:
                return mock_info
            return None

        mock_dev.absinfo.side_effect = mock_absinfo
        res = touchpad.get_abs_axis(mock_dev, touchpad.ecodes.ABS_MT_POSITION_X, touchpad.ecodes.ABS_X)
        self.assertEqual(res, mock_info)

    def test_get_abs_axis_none(self):
        """Test get_abs_axis returns None when neither axis exists."""
        mock_dev = MagicMock()
        mock_dev.absinfo.side_effect = KeyError("no axis")
        res = touchpad.get_abs_axis(mock_dev, touchpad.ecodes.ABS_MT_POSITION_X, touchpad.ecodes.ABS_X)
        self.assertIsNone(res)

    def test_pick_check_precedence(self):
        """Test _pick_check prefers primary, then fallback."""
        self.assertEqual(call_attr(touchpad, "_pick_check", 12, 34), 12)
        self.assertEqual(call_attr(touchpad, "_pick_check", -1, 34), 34)

    def test_get_axis_range_defaults(self):
        """Test _get_axis_range returns defaults when axis metadata is absent."""
        self.assertEqual(call_attr(touchpad, "_get_axis_range", None, 0, 4000), (0, 4000))

    def test_compute_bounds_uses_axis_min_max(self):
        """Test _compute_bounds uses configured axis ranges instead of static defaults."""
        mock_dev = MagicMock()
        axis_x = MagicMock(min=100, max=5100)
        axis_y = MagicMock(min=50, max=3050)

        def absinfo_side(code):
            if code == touchpad.ecodes.ABS_MT_POSITION_X:
                return axis_x
            if code == touchpad.ecodes.ABS_MT_POSITION_Y:
                return axis_y
            raise KeyError(code)

        mock_dev.absinfo.side_effect = absinfo_side
        corner_x, corner_y = call_attr(touchpad, "_compute_bounds", mock_dev)
        self.assertEqual(corner_x, 1100.0)
        self.assertEqual(corner_y, 650.0)

    @patch("asus_touchpad_share.subprocess.run")
    @patch("asus_touchpad_share.time.monotonic", side_effect=itertools.count(10.0, 0.2))
    def test_run_event_loop_gesture(self, _mock_time, mock_run):
        """Test run_event_loop processes touch release and triggers gesture."""
        mock_run.return_value = subprocess.CompletedProcess(["helper"], 0)
        mock_dev = MagicMock()
        event1 = MagicMock()
        event1.type = touchpad.ecodes.EV_KEY
        event1.code = touchpad.ecodes.BTN_TOUCH
        event1.value = 1
        event2 = MagicMock()
        event2.type = touchpad.ecodes.EV_ABS
        event2.code = touchpad.ecodes.ABS_X
        event2.value = 100
        event3 = MagicMock()
        event3.type = touchpad.ecodes.EV_ABS
        event3.code = touchpad.ecodes.ABS_Y
        event3.value = 100
        event4 = MagicMock()
        event4.type = touchpad.ecodes.EV_KEY
        event4.code = touchpad.ecodes.BTN_TOUCH
        event4.value = 0
        mock_dev.read_loop.return_value = [event1, event2, event3, event4]
        bounds = (1000.0, 800.0)
        touchpad.run_event_loop(mock_dev, bounds)
        time.sleep(0.05)
        screenshot_calls = [call for call in mock_run.call_args_list if call.args and "asus-screenshot.sh" in str(call.args[0])]
        self.assertEqual(len(screenshot_calls), 1)

    @patch("asus_touchpad_share.time.monotonic", return_value=10.0)
    def test_multi_touch_cancels_corner_gesture(self, _mock_time):
        """A second active tracking ID cancels Share before BTN_TOUCH release."""
        mock_dev = MagicMock()
        events = []
        for event_type, code, value in (
            (touchpad.ecodes.EV_ABS, touchpad.ecodes.ABS_MT_TRACKING_ID, 1),
            (touchpad.ecodes.EV_KEY, touchpad.ecodes.BTN_TOUCH, 1),
            (touchpad.ecodes.EV_ABS, touchpad.ecodes.ABS_X, 100),
            (touchpad.ecodes.EV_ABS, touchpad.ecodes.ABS_Y, 100),
            (touchpad.ecodes.EV_ABS, touchpad.ecodes.ABS_MT_TRACKING_ID, 2),
            (touchpad.ecodes.EV_KEY, touchpad.ecodes.BTN_TOUCH, 0),
        ):
            events.append(MagicMock(type=event_type, code=code, value=value))
        mock_dev.read_loop.return_value = events

        with patch("asus_touchpad_share.trigger_screenshot") as mock_screenshot:
            touchpad.run_event_loop(mock_dev, (1000.0, 800.0))

        mock_screenshot.assert_not_called()

    @patch("asus_touchpad_share.time.monotonic", return_value=10.0)
    def test_handle_touch_key_cooldown_blocks_retrigger(self, _mock_time):
        """Test _handle_touch_key suppresses screenshot when cooldown has not elapsed."""
        state = touchpad.GestureState(
            pointer=touchpad.PointerGesture(
                curr_x=100,
                curr_y=100,
                is_touching=True,
                t_start=10.0,
                t_last=9.5,
            )
        )
        event = MagicMock(type=touchpad.ecodes.EV_KEY, code=touchpad.ecodes.BTN_TOUCH, value=0)
        with patch("asus_touchpad_share.subprocess.run") as mock_run:
            call_attr(touchpad, "_handle_touch_key", event, state, (1000.0, 800.0))
            mock_run.assert_not_called()

    @patch("evdev.InputDevice", side_effect=OSError("permission denied"))
    def test_open_touchpad_exit_message(self, _mock_input_device):
        """Test _open_touchpad exits with a meaningful open-device error."""
        with self.assertRaises(SystemExit) as exc:
            call_attr(touchpad, "_open_touchpad", "/dev/input/event9")
        self.assertIn("Failed to open touchpad device", str(exc.exception))

    @patch("asus_touchpad_share.find_touchpad_device_path", return_value=None)
    def test_main_no_device_exit(self, _mock_find):
        """Test main exits when find_touchpad_device_path returns None."""
        with self.assertRaises(SystemExit):
            touchpad.main()

    @patch("asus_touchpad_share.find_touchpad_device_path", return_value="/dev/input/event1")
    @patch("evdev.InputDevice")
    def test_main_success(self, mock_dev_cls, _mock_find):
        """Test main successfully initializes bounds and runs event loop."""
        mock_dev = MagicMock()
        mock_dev.absinfo.side_effect = KeyError("no axis")
        mock_dev.read_loop.return_value = iter([])
        mock_dev_cls.return_value = mock_dev
        touchpad.main()
        mock_dev.read_loop.assert_called_once()


if __name__ == "__main__":
    unittest.main()
