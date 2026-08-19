"""Screenshot helper, multitouch, and main-loop paths for touchpad share."""

import importlib
import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from tests.unit.bin.attr_helpers import call_attr

_BIN_DIR = Path(__file__).resolve().parents[3] / "bin"
if str(_BIN_DIR) not in sys.path:
    sys.path.insert(0, str(_BIN_DIR))

touchpad = importlib.import_module("asus_touchpad_share")
touchpad_bounds = importlib.import_module("asus_touchpad_share_bounds")


def _share_bounds():
    """Return a minimal ShareBounds fixture for helper tests."""
    return touchpad_bounds.ShareBounds(bounds=(100.0, 100.0))


class TestAsusTouchpadShareHelpers(unittest.TestCase):
    """Screenshot helper failures, multitouch handling, and main interrupt paths."""

    def test_screenshot_helper_path_override_and_fallback(self):
        """Override path wins; missing bindir falls back beside the module."""
        with (
            patch.dict(os.environ, {"ASUS_SCREENSHOT_HELPER": "/tmp/fake-shot.sh"}, clear=False),
            patch("asus_touchpad_share.is_executable_file", return_value=True),
        ):
            self.assertEqual(call_attr(touchpad, "_screenshot_helper_path"), "/tmp/fake-shot.sh")
        with (
            patch.dict(
                os.environ,
                {"ASUS_BIN_DIR": "/missing-bin", "ASUS_SCREENSHOT_HELPER": ""},
                clear=False,
            ),
            patch("asus_touchpad_share.is_executable_file", return_value=False),
        ):
            path = call_attr(touchpad, "_screenshot_helper_path")
            self.assertTrue(path.endswith("asus-screenshot.sh"))

    @patch("asus_touchpad_share.subprocess.run", side_effect=subprocess.TimeoutExpired(cmd="h", timeout=1))
    def test_run_screenshot_helper_timeout(self, _run):
        """Timeout from the helper is logged and swallowed."""
        with self.assertLogs("asus_touchpad_share", level="WARNING"):
            call_attr(touchpad, "_run_screenshot_helper", "/bin/true")

    @patch("asus_touchpad_share.subprocess.run", side_effect=OSError("exec"))
    def test_run_screenshot_helper_oserror(self, _run):
        """OSError from the helper is logged and swallowed."""
        with self.assertLogs("asus_touchpad_share", level="WARNING"):
            call_attr(touchpad, "_run_screenshot_helper", "/bin/true")

    @patch(
        "asus_touchpad_share.subprocess.run",
        return_value=subprocess.CompletedProcess(["helper"], 7),
    )
    def test_run_screenshot_helper_nonzero(self, _run):
        """Nonzero helper exit is logged and swallowed."""
        with self.assertLogs("asus_touchpad_share", level="WARNING"):
            call_attr(touchpad, "_run_screenshot_helper", "/bin/true")

    @patch("asus_touchpad_share.threading.Thread", side_effect=RuntimeError("no threads"))
    def test_trigger_screenshot_thread_failure(self, _thread):
        """Thread.start failure becomes OSError for Share release handling."""
        with self.assertLogs("asus_touchpad_share", level="WARNING"), self.assertRaises(OSError):
            touchpad.trigger_screenshot()

    def test_is_corner_gesture_negative_coords(self):
        """Unset coordinates reject the corner gesture."""
        self.assertFalse(touchpad_bounds.is_corner_gesture((-1, -1, -1, -1, 0.1), (100.0, 100.0)))

    def test_apply_mt_slot_and_tracking_release(self):
        """ABS_MT_SLOT updates; tracking id -1 drops the active slot."""
        state = touchpad.GestureState()
        state = call_attr(
            touchpad,
            "_apply_mt_slot",
            MagicMock(value=2),
            state,
        )
        self.assertEqual(state.multitouch.mt_slot, 2)
        state = call_attr(
            touchpad,
            "_apply_tracking_id",
            MagicMock(value=9),
            state,
        )
        self.assertIn(9, state.multitouch.active_tracking_ids)
        state = call_attr(
            touchpad,
            "_apply_tracking_id",
            MagicMock(value=-1),
            state,
        )
        self.assertFalse(state.multitouch.active_tracking_ids)

    def test_handle_touch_key_repeat_and_non_zero_release(self):
        """Already-touching presses and value>1 events are no-ops."""
        state = touchpad.GestureState(pointer=touchpad.PointerGesture(is_touching=True, curr_x=1, curr_y=2))
        press = MagicMock(type=touchpad.ecodes.EV_KEY, code=touchpad.ecodes.BTN_TOUCH, value=1)
        share_bounds = _share_bounds()
        self.assertEqual(
            call_attr(touchpad, "_handle_touch_key", press, state, share_bounds),
            (state, share_bounds),
        )
        other = MagicMock(type=touchpad.ecodes.EV_KEY, code=touchpad.ecodes.BTN_TOUCH, value=2)
        self.assertEqual(
            call_attr(touchpad, "_handle_touch_key", other, state, share_bounds),
            (state, share_bounds),
        )

    def test_handle_touch_release_swallows_screenshot_errors(self):
        """Share release logs and continues when trigger_screenshot fails."""
        state = touchpad.GestureState(
            pointer=touchpad.PointerGesture(
                start_x=1,
                start_y=1,
                curr_x=1,
                curr_y=1,
                is_touching=True,
                t_start=10.0,
                t_last=0.0,
            )
        )
        with (
            patch("asus_touchpad_share.time.monotonic", return_value=10.1),
            patch("asus_touchpad_share.trigger_screenshot", side_effect=OSError("boom")),
            self.assertLogs("asus_touchpad_share", level="WARNING"),
        ):
            call_attr(touchpad, "_handle_touch_release", state, _share_bounds())

    @patch("asus_touchpad_share.time.monotonic", return_value=10.0)
    def test_run_event_loop_oserror(self, _mono):
        """OSError from read_loop is logged and re-raised."""
        mock_dev = MagicMock()
        mock_dev.read_loop.side_effect = OSError("device gone")
        with self.assertLogs("asus_touchpad_share", level="ERROR"), self.assertRaises(OSError):
            touchpad.run_event_loop(mock_dev, _share_bounds())

    @patch("asus_touchpad_share.find_touchpad_device_path", return_value="/dev/input/event1")
    @patch("asus_touchpad_share.evdev.InputDevice")
    def test_main_keyboard_interrupt(self, mock_dev_cls, _mock_find):
        """KeyboardInterrupt ends the loop without failing main."""
        mock_dev = MagicMock()
        mock_dev.absinfo.side_effect = KeyError("no axis")
        mock_dev.read_loop.side_effect = KeyboardInterrupt()
        mock_dev_cls.return_value = mock_dev
        touchpad.main()


if __name__ == "__main__":
    unittest.main()
