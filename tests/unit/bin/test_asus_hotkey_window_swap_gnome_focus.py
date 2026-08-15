"""GNOME Window Swap focus, xdotool, and MoveFocused path coverage."""

import importlib
import subprocess
import unittest
from unittest.mock import MagicMock, patch

from evdev import ecodes

from tests.unit.bin.attr_helpers import call_attr

window_swap_gnome = importlib.import_module("asus_hotkey_daemon_window_swap_gnome")


class TestAsusHotkeyWindowSwapGnomeFocus(unittest.TestCase):
    """Exercise focus hints, monitor hit-testing, and Mutter move helpers."""

    def setUp(self):
        """Clear D-Bus readiness cache between cases."""
        call_attr(window_swap_gnome, "_gnome_window_swap_dbus_cache_set", None, 0.0)

    @patch("asus_hotkey_daemon_window_swap_gnome.shutil.which", return_value=None)
    def test_run_xdotool_query_missing_binary(self, _which):
        """Missing xdotool returns None without invoking the session."""
        self.assertIsNone(call_attr(window_swap_gnome, "_run_xdotool_query", ["getmouselocation"]))

    @patch("asus_hotkey_daemon_window_swap_gnome.shutil.which", return_value="/usr/bin/xdotool")
    @patch(
        "asus_hotkey_daemon_window_swap_gnome.run_in_desktop_session",
        side_effect=OSError("no session"),
    )
    def test_run_xdotool_query_oserror(self, _run, _which):
        """Session OSError soft-fails to None."""
        self.assertIsNone(call_attr(window_swap_gnome, "_run_xdotool_query", ["getmouselocation"]))

    @patch("asus_hotkey_daemon_window_swap_gnome.shutil.which", return_value="/usr/bin/xdotool")
    @patch(
        "asus_hotkey_daemon_window_swap_gnome.run_in_desktop_session",
        side_effect=subprocess.TimeoutExpired(cmd="xdotool", timeout=2),
    )
    def test_run_xdotool_query_timeout(self, _run, _which):
        """Session timeout soft-fails to None."""
        self.assertIsNone(call_attr(window_swap_gnome, "_run_xdotool_query", ["getmouselocation"]))

    @patch("asus_hotkey_daemon_window_swap_gnome.shutil.which", return_value="/usr/bin/xdotool")
    @patch("asus_hotkey_daemon_window_swap_gnome.run_in_desktop_session")
    def test_run_xdotool_query_nonzero_and_success(self, mock_run, _which):
        """Nonzero exit is None; success returns stdout."""
        mock_run.return_value = MagicMock(returncode=1, stdout="X=1\nY=2\n")
        self.assertIsNone(call_attr(window_swap_gnome, "_run_xdotool_query", ["getmouselocation"]))
        mock_run.return_value = MagicMock(returncode=0, stdout="X=1\nY=2\n")
        self.assertEqual(
            call_attr(window_swap_gnome, "_run_xdotool_query", ["getmouselocation"]),
            "X=1\nY=2\n",
        )

    def test_parse_mouse_point_incomplete(self):
        """Mouse parse requires both X and Y tokens."""
        self.assertIsNone(call_attr(window_swap_gnome, "_parse_xdotool_mouse_point", "X=10\n"))
        self.assertEqual(
            call_attr(window_swap_gnome, "_parse_xdotool_mouse_point", "X=10\nY=20\n"),
            (10, 20),
        )

    @patch("asus_hotkey_daemon_window_swap_gnome._run_xdotool_query", return_value=None)
    def test_focused_and_pointer_none(self, _query):
        """Focus helpers return None when xdotool query fails."""
        self.assertIsNone(call_attr(window_swap_gnome, "_focused_window_point"))
        self.assertIsNone(call_attr(window_swap_gnome, "_pointer_point"))

    @patch(
        "asus_hotkey_daemon_window_swap_gnome._run_xdotool_query",
        return_value="Position: 10,20\nGeometry: 100x40\n",
    )
    def test_focused_window_point_parses_center(self, _query):
        """Window geometry stdout yields the window center."""
        self.assertEqual(call_attr(window_swap_gnome, "_focused_window_point"), (60, 40))

    @patch("asus_hotkey_daemon_window_swap_gnome._focused_window_point", return_value=(1, 2))
    @patch("asus_hotkey_daemon_window_swap_gnome._pointer_point")
    def test_focus_hint_prefers_window(self, pointer, _window):
        """Window geometry wins over pointer fallback."""
        self.assertEqual(call_attr(window_swap_gnome, "_focus_hint_point"), (1, 2))
        pointer.assert_not_called()

    @patch("asus_hotkey_daemon_window_swap_gnome._focused_window_point", return_value=None)
    @patch("asus_hotkey_daemon_window_swap_gnome._pointer_point", return_value=(9, 8))
    def test_focus_hint_falls_back_to_pointer(self, _pointer, _window):
        """Pointer is used when window geometry is unavailable."""
        self.assertEqual(call_attr(window_swap_gnome, "_focus_hint_point"), (9, 8))


class TestAsusHotkeyWindowSwapGnomeMutter(unittest.TestCase):
    """Mutter D-Bus readiness, focus index, and MoveFocused helpers."""

    def setUp(self):
        """Clear D-Bus readiness cache between cases."""
        call_attr(window_swap_gnome, "_gnome_window_swap_dbus_cache_set", None, 0.0)

    def test_logical_layout_bounds_empty_and_multi(self):
        """Empty monitors yield zeros; multi-monitor expands the box."""
        self.assertEqual(call_attr(window_swap_gnome, "_logical_layout_bounds", []), (0, 0, 0, 0))
        monitors = [
            {"x": 0, "y": 0, "width": 100, "height": 50},
            {"x": 100, "y": -10, "width": 80, "height": 60},
        ]
        self.assertEqual(
            call_attr(window_swap_gnome, "_logical_layout_bounds", monitors),
            (0, -10, 180, 50),
        )

    def test_point_outside_and_scale_hit(self):
        """Outside-layout detection and scale-1 skip during scaled hit-test."""
        monitors = [
            {"x": 0, "y": 0, "width": 100, "height": 100, "scale": 1.0},
            {"x": 100, "y": 0, "width": 100, "height": 100, "scale": 2.0},
        ]
        self.assertTrue(call_attr(window_swap_gnome, "_point_outside_logical_layout", monitors, -1, 0))
        self.assertTrue(call_attr(window_swap_gnome, "_point_outside_logical_layout", monitors, 0, 200))
        self.assertFalse(call_attr(window_swap_gnome, "_point_outside_logical_layout", monitors, 50, 50))
        self.assertIsNone(call_attr(window_swap_gnome, "_monitor_index_for_scale", monitors, 50, 50, True))
        self.assertEqual(
            call_attr(window_swap_gnome, "_monitor_index_at_point", monitors, 50, 50),
            0,
        )
        self.assertEqual(
            call_attr(window_swap_gnome, "_monitor_index_at_point", monitors, 150, 50),
            1,
        )
        # Outside logical box: scaled hit-test can still map onto monitor 1.
        self.assertEqual(
            call_attr(window_swap_gnome, "_monitor_index_at_point", monitors, 250, 50),
            1,
        )

    def test_parse_gdbus_helpers(self):
        """gdbus bool/int parsers reject malformed stdout."""
        self.assertIsNone(call_attr(window_swap_gnome, "_parse_gdbus_int", "nope"))
        self.assertEqual(call_attr(window_swap_gnome, "_parse_gdbus_int", "(3,)"), 3)
        self.assertTrue(call_attr(window_swap_gnome, "_parse_gdbus_bool", "(true,)"))
        self.assertFalse(call_attr(window_swap_gnome, "_parse_gdbus_bool", "(false,)"))
        self.assertIsNone(call_attr(window_swap_gnome, "_parse_gdbus_bool", "x"))

    def test_gdbus_command_with_args(self):
        """MoveFocused argv includes direction tokens."""
        command = call_attr(window_swap_gnome, "_gdbus_window_swap_command", "MoveFocused", ["down"])
        self.assertIn("MoveFocused", command[-2])
        self.assertEqual(command[-1], "down")

    @patch(
        "asus_hotkey_daemon_window_swap_gnome.run_in_desktop_session",
        side_effect=OSError("gone"),
    )
    def test_invoke_gdbus_oserror(self, _run):
        """gdbus invoke soft-fails on OSError."""
        self.assertIsNone(call_attr(window_swap_gnome, "_invoke_gdbus_window_swap", ["gdbus"]))

    @patch("asus_hotkey_daemon_window_swap_gnome.run_in_desktop_session")
    def test_invoke_gdbus_nonzero_and_success(self, mock_run):
        """Nonzero exit is None; success returns stdout."""
        mock_run.return_value = MagicMock(returncode=1, stdout="(1,)")
        self.assertIsNone(call_attr(window_swap_gnome, "_invoke_gdbus_window_swap", ["gdbus"]))
        mock_run.return_value = MagicMock(returncode=0, stdout="(1,)")
        self.assertEqual(call_attr(window_swap_gnome, "_invoke_gdbus_window_swap", ["gdbus"]), "(1,)")

    @patch("asus_hotkey_daemon_window_swap_gnome.time.sleep")
    @patch("asus_hotkey_daemon_window_swap_gnome.shutil.which", return_value="/usr/bin/gdbus")
    @patch(
        "asus_hotkey_daemon_window_swap_gnome._invoke_gdbus_window_swap",
        side_effect=[None, "(0,)"],
    )
    def test_mutter_call_retries_then_succeeds(self, _invoke, _which, sleep_mock):
        """Failed first attempt sleeps then retries."""
        self.assertEqual(
            call_attr(window_swap_gnome, "_mutter_window_swap_call", "GetFocusedMonitor", attempts=2),
            "(0,)",
        )
        sleep_mock.assert_called_once()

    @patch("asus_hotkey_daemon_window_swap_gnome.time.sleep")
    @patch(
        "asus_hotkey_daemon_window_swap_gnome._gnome_window_swap_dbus_ready",
        side_effect=[False, True],
    )
    def test_wait_ready_succeeds_on_second_probe(self, _ready, _sleep):
        """Wait loop returns True once readiness appears before deadline."""
        with patch(
            "asus_hotkey_daemon_window_swap_gnome.time.monotonic",
            side_effect=[0.0, 0.05, 0.1, 0.15],
        ):
            self.assertTrue(call_attr(window_swap_gnome, "_wait_gnome_window_swap_dbus_ready"))

    @patch("asus_hotkey_daemon_window_swap_gnome.desktop_family_hint", return_value="gnome")
    @patch("asus_hotkey_daemon_window_swap_gnome._gnome_window_swap_dbus_ready", return_value=True)
    @patch("asus_hotkey_daemon_window_swap_gnome._enable_gnome_window_swap_via_cli")
    def test_prime_returns_when_already_ready(self, enable_cli, _ready, _family):
        """Prime skips enable when D-Bus is already available."""
        call_attr(window_swap_gnome, "prime_gnome_window_swap_extension")
        enable_cli.assert_not_called()

    @patch("asus_hotkey_daemon_window_swap_gnome.desktop_family_hint", return_value="gnome")
    @patch("asus_hotkey_daemon_window_swap_gnome._gnome_window_swap_dbus_ready", return_value=False)
    @patch("asus_hotkey_daemon_window_swap_gnome._enable_gnome_window_swap_via_cli", return_value=False)
    @patch("asus_hotkey_daemon_window_swap_gnome._wait_gnome_window_swap_dbus_ready")
    def test_prime_stops_when_enable_fails(self, wait_ready, _enable, _ready, _family):
        """Failed CLI enable does not wait for readiness."""
        call_attr(window_swap_gnome, "prime_gnome_window_swap_extension")
        wait_ready.assert_not_called()

    def test_list_index_for_mutter_index(self):
        """Mutter index maps via monitor.index field or list position."""
        monitors = [{"index": 2}, {"index": 5}]
        self.assertEqual(call_attr(window_swap_gnome, "_list_index_for_mutter_index", monitors, 5), 1)
        self.assertEqual(call_attr(window_swap_gnome, "_list_index_for_mutter_index", monitors, 0), 0)
        self.assertIsNone(call_attr(window_swap_gnome, "_list_index_for_mutter_index", monitors, 9))

    @patch("asus_hotkey_daemon_window_swap_gnome._mutter_window_swap_call", return_value=None)
    def test_mutter_focused_monitor_missing(self, _call):
        """Missing GetFocusedMonitor stdout yields None."""
        self.assertIsNone(call_attr(window_swap_gnome, "_mutter_focused_monitor_index", 2))

    @patch("asus_hotkey_daemon_window_swap_gnome._mutter_window_swap_call", return_value="bad")
    def test_mutter_focused_monitor_bad_int(self, _call):
        """Malformed GetFocusedMonitor stdout yields None."""
        self.assertIsNone(call_attr(window_swap_gnome, "_mutter_focused_monitor_index", 2))

    @patch("asus_hotkey_daemon_window_swap_gnome._mutter_window_swap_call", return_value="(9,)")
    def test_mutter_focused_monitor_out_of_range(self, _call):
        """Out-of-range Mutter index yields None."""
        self.assertIsNone(call_attr(window_swap_gnome, "_mutter_focused_monitor_index", 2))

    def test_focused_monitor_index_paths(self):
        """Empty monitors, Mutter map, and xdotool geometry fallback."""
        self.assertIsNone(call_attr(window_swap_gnome, "_focused_monitor_index", []))
        monitors = [
            {"x": 0, "y": 0, "width": 100, "height": 100, "index": 0},
            {"x": 100, "y": 0, "width": 100, "height": 100, "index": 1},
        ]
        with patch.object(window_swap_gnome, "_mutter_focused_monitor_index", return_value=1):
            self.assertEqual(call_attr(window_swap_gnome, "_focused_monitor_index", monitors), 1)
        with (
            patch.object(window_swap_gnome, "_mutter_focused_monitor_index", return_value=None),
            patch.object(window_swap_gnome, "_focused_window_point", return_value=None),
        ):
            self.assertIsNone(call_attr(window_swap_gnome, "_focused_monitor_index", monitors))
        with (
            patch.object(window_swap_gnome, "_mutter_focused_monitor_index", return_value=None),
            patch.object(window_swap_gnome, "_focused_window_point", return_value=(150, 10)),
        ):
            self.assertEqual(call_attr(window_swap_gnome, "_focused_monitor_index", monitors), 1)

    def test_mutter_move_and_uinput_fallback(self):
        """MoveFocused parsing and dual-direction uinput fallback."""
        self.assertIsNone(call_attr(window_swap_gnome, "_mutter_move_focused", 999))
        with patch.object(window_swap_gnome, "_mutter_window_swap_call", return_value=None):
            self.assertIsNone(call_attr(window_swap_gnome, "_mutter_move_focused", ecodes.KEY_DOWN))
        with patch.object(window_swap_gnome, "_mutter_window_swap_call", return_value="(true,)"):
            self.assertTrue(call_attr(window_swap_gnome, "_mutter_move_focused", ecodes.KEY_DOWN))
        with patch.object(
            window_swap_gnome,
            "_mutter_move_focused",
            side_effect=[False, True],
        ) as move:
            self.assertTrue(call_attr(window_swap_gnome, "_try_mutter_move_both_directions", ecodes.KEY_DOWN))
            self.assertEqual(move.call_count, 2)
        with patch.object(window_swap_gnome, "_mutter_move_focused", return_value=None):
            self.assertIsNone(call_attr(window_swap_gnome, "_try_mutter_move_both_directions", ecodes.KEY_DOWN))
        with patch.object(window_swap_gnome, "_emit_window_move", side_effect=[False, True]) as emit:
            self.assertTrue(call_attr(window_swap_gnome, "_uinput_move_both_directions", MagicMock(), ecodes.KEY_DOWN))
            self.assertEqual(emit.call_count, 2)


if __name__ == "__main__":
    unittest.main()
