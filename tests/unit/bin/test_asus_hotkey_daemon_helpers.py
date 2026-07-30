"""Branch tests for the hotkey-daemon helper modules."""

import importlib
import subprocess
import unittest
from unittest.mock import MagicMock, call, patch

from evdev import ecodes

from tests.unit.bin.attr_helpers import call_attr, get_attr
from tests.unit.bin.hotkey_daemon_test_utils import (
    load_daemon,
    reset_hotkey_daemon_state,
    seed_usable_monitor_topology,
    subprocess_run_responses,
    window_swap_monitor_patches,
)

daemon = load_daemon()
daemon_input = importlib.import_module("asus_hotkey_daemon_input")
daemon_runtime = importlib.import_module("asus_hotkey_daemon_runtime")
daemon_session = importlib.import_module("asus_hotkey_daemon_session")
daemon_topology = importlib.import_module("asus_hotkey_daemon_topology")
daemon_topology_detect = importlib.import_module("asus_hotkey_daemon_topology_detect")
daemon_window_move = importlib.import_module("asus_hotkey_daemon_window_move")
daemon_window_swap = importlib.import_module("asus_hotkey_daemon_window_swap")
hotkey_state = importlib.import_module("asus_hotkey_daemon_state")


class TestAsusHotkeyDaemonDesktopUserHelpers(unittest.TestCase):
    """Branch tests for desktop-user detection helpers."""

    def setUp(self):
        """Clear desktop-user cache between detection tests."""
        hotkey_state.clear_desktop_user_cache()
        hotkey_state.clear_swap_topology_cache()
        daemon_runtime.reset_systemctl_env_cache()

    def tearDown(self):
        """Drop cached desktop-user tuple after each test."""
        hotkey_state.clear_desktop_user_cache()
        hotkey_state.clear_swap_topology_cache()
        daemon_runtime.reset_systemctl_env_cache()

    def test_script_debounce_state_accessors(self):
        """get/set last script times and clear_debounce round-trip under the lock."""
        hotkey_state.clear_debounce()
        hotkey_state.set_last_script_time("/tmp/helper.sh", 12.5)
        self.assertEqual(hotkey_state.get_last_script_times(), {"/tmp/helper.sh": 12.5})
        hotkey_state.clear_debounce()
        self.assertEqual(hotkey_state.get_last_script_times(), {})

    def test_touch_desktop_user_validated_until_paths(self):
        """touch_desktop_user_validated_until no-ops on bad cache and updates tuples."""
        hotkey_state.clear_desktop_user_cache()
        hotkey_state.touch_desktop_user_validated_until(99.0)
        hotkey_state.set_desktop_user_cache(1, "u", "s1", 10.0)
        hotkey_state.touch_desktop_user_validated_until(42.0)
        self.assertEqual(hotkey_state.get_desktop_user_session_id(), "s1")

    @patch("asus_hotkey_daemon_session.subprocess.run")
    def test_detect_desktop_user_reads_loginctl_output(self, mock_run):
        """Test desktop-user detection parses active GUI session output."""
        mock_run.side_effect = subprocess_run_responses(
            (0, "c2 1000 alice seat0\n"), (0, "Type=wayland\nState=active\n"), (0, "Name=alice\nUser=1000\n")
        )
        self.assertEqual(call_attr(daemon_session, "_detect_desktop_user"), (1000, "alice", "c2"))

    @patch("asus_hotkey_daemon_session.subprocess.run", return_value=MagicMock(returncode=1, stdout=""))
    def test_detect_desktop_user_returns_none_when_loginctl_fails(self, _mock_run):
        """Test desktop-user detection returns None when loginctl exits non-zero."""
        self.assertEqual(call_attr(daemon_session, "_detect_desktop_user"), (None, None, None))

    @patch("os.geteuid", return_value=0)
    @patch("shutil.which", return_value="/usr/bin/runuser")
    @patch("asus_hotkey_daemon_session.subprocess.run")
    def test_run_in_desktop_session_uses_runuser_when_root(self, mock_run, _mock_which, _mock_euid):
        """Test desktop-session execution uses runuser for root-owned daemons when available."""
        mock_run.side_effect = subprocess_run_responses(
            (0, "c2 1000 alice seat0\n"),
            (0, "Type=wayland\nState=active\n"),
            (0, "Name=alice\nUser=1000\n"),
            (0, "Type=wayland\n"),
            (0, "Leader=\n"),
            (0, "DISPLAY=:0\n"),
            (0, "", ""),
        )
        daemon_runtime.run_in_desktop_session(["/usr/bin/true"], 2, requires_dbus=True)
        self.assertEqual(
            mock_run.call_args.args[0],
            [
                "runuser",
                "-u",
                "alice",
                "--",
                "env",
                "XDG_RUNTIME_DIR=/run/user/1000",
                "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus",
                "XDG_SESSION_TYPE=wayland",
                "DISPLAY=:0",
                "/usr/bin/true",
            ],
        )

    @patch("os.geteuid", return_value=0)
    @patch("shutil.which", return_value=None)
    @patch("asus_hotkey_daemon_session.subprocess.run")
    def test_run_in_desktop_session_uses_sudo_fallback_when_no_runuser(self, mock_run, _mock_which, _mock_euid):
        """Test desktop-session execution falls back to sudo when runuser is missing."""
        mock_run.side_effect = subprocess_run_responses(
            (0, "c2 1000 alice seat0\n"),
            (0, "Type=wayland\nState=active\n"),
            (0, "Name=alice\nUser=1000\n"),
            (0, "Type=wayland\n"),
            (0, "Leader=\n"),
            (0, "Type=wayland\n"),
            (0, "Leader=\n"),
            (0, "", ""),
        )
        daemon_runtime.run_in_desktop_session(["/usr/bin/true"], 2, requires_dbus=True)
        self.assertEqual(
            mock_run.call_args.args[0],
            [
                "sudo",
                "-u",
                "alice",
                "--",
                "env",
                "XDG_RUNTIME_DIR=/run/user/1000",
                "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus",
                "XDG_SESSION_TYPE=wayland",
                "/usr/bin/true",
            ],
        )

    @patch("os.geteuid", return_value=0)
    @patch("asus_hotkey_daemon_session.subprocess.run")
    def test_run_in_desktop_session_falls_back_when_no_user(self, mock_run, _mock_euid):
        """Test desktop-session execution falls back to a direct subprocess when no desktop user exists."""
        mock_run.side_effect = subprocess_run_responses((1, ""), (0, "", ""))
        daemon_runtime.run_in_desktop_session(["/usr/bin/true"], 2)
        self.assertEqual(mock_run.call_args.args[0], ["/usr/bin/true"])


class TestAsusHotkeyDaemonTopologyHelpers(unittest.TestCase):
    """Branch tests for topology parsing and monitor movement helpers."""

    def setUp(self):
        """Reset shared hotkey daemon state before topology helper tests."""
        reset_hotkey_daemon_state(daemon)

    def test_normalize_detected_profile_handles_all_supported_values(self):
        """Test profile normalization covers all known alias values."""
        normalize = get_attr(daemon_topology_detect, "_normalize_detected_profile")
        self.assertEqual(normalize("all"), "all")
        self.assertEqual(normalize("main_external"), "main_external")
        self.assertEqual(normalize("screenpad_external"), "screenpad_external")
        self.assertEqual(normalize("external_only"), "external_only")
        self.assertEqual(normalize("main_only"), "main_only")
        self.assertEqual(normalize("screenpad_only"), "screenpad_only")

    def test_parse_topology_output_and_topology_map_payload(self):
        """Test topology parsing handles both plain-text and JSON payloads."""
        parse_topology = get_attr(daemon_topology_detect, "_parse_topology_output")
        self.assertEqual(parse_topology("external_only:4"), ("external_only", 4))
        self.assertEqual(parse_topology("bad"), (None, None))
        parse_map = get_attr(daemon_topology_detect, "_parse_topology_map_output")
        self.assertEqual(
            parse_map('{"profile":"all","monitors":[{"x":0,"y":0,"width":1920,"height":1080,"primary":true}]}'),
            ("all", [{"x": 0, "y": 0, "width": 1920, "height": 1080, "scale": 1.0, "primary": True}]),
        )
        self.assertEqual(parse_map("not-json"), (None, None))

    def test_emit_window_move_helper(self):
        """Test window-move emission helper."""
        ui = MagicMock()
        call_attr(daemon_window_move, "_emit_window_move", ui, ecodes.KEY_RIGHT)
        self.assertEqual(ui.write.call_count, 8)
        ui.write.assert_has_calls(
            [
                call(ecodes.EV_KEY, ecodes.KEY_LEFTMETA, 1),
                call(ecodes.EV_KEY, ecodes.KEY_LEFTSHIFT, 1),
                call(ecodes.EV_KEY, ecodes.KEY_RIGHT, 1),
                call(ecodes.EV_SYN, ecodes.SYN_REPORT, 0),
                call(ecodes.EV_KEY, ecodes.KEY_RIGHT, 0),
                call(ecodes.EV_KEY, ecodes.KEY_LEFTSHIFT, 0),
                call(ecodes.EV_KEY, ecodes.KEY_LEFTMETA, 0),
                call(ecodes.EV_SYN, ecodes.SYN_REPORT, 0),
            ]
        )

    def test_emit_window_move_oserror_returns_false(self):
        """OSError from the emitter is logged and soft-fails the move."""
        ui = MagicMock()
        ui.write.side_effect = OSError("uinput gone")
        with self.assertLogs(daemon_window_move.__name__, level="WARNING"):
            self.assertFalse(call_attr(daemon_window_move, "_emit_window_move", ui, ecodes.KEY_UP))

    def test_monitor_neighbor_helpers(self):
        """Test directional neighbor helpers for monitor topology."""
        monitors = [
            {"x": 0, "y": 0, "width": 1920, "height": 1080, "primary": True},
            {"x": 1920, "y": 0, "width": 1920, "height": 1080, "primary": False},
        ]
        self.assertEqual(
            call_attr(daemon_topology, "_monitor_neighbor_candidates", monitors[0], monitors[1]), [(ecodes.KEY_RIGHT, 0, -1080, 0)]
        )
        directional = call_attr(daemon_topology, "_build_directional_neighbors", monitors)
        self.assertIn(1, directional[0])
        self.assertEqual(call_attr(daemon_topology, "_direction_between_monitors", monitors[0], monitors[1]), ecodes.KEY_RIGHT)


class TestAsusHotkeyDaemonSwapHelpers(unittest.TestCase):
    """Branch tests for swap-direction and script-resolution helpers."""

    def setUp(self):
        """Reset shared hotkey daemon state before swap helper tests."""
        reset_hotkey_daemon_state(daemon)
        self._focus_patch = patch("asus_hotkey_daemon_topology._focused_monitor_index", return_value=None)
        self._focus_patch.start()
        self.addCleanup(self._focus_patch.stop)

    def test_refresh_monitors_and_swap_direction_helpers(self):
        """Test monitor refresh returns cache and swap-direction helpers resolve correctly."""
        monitors = [{"x": 0, "y": 0, "width": 1920, "height": 1080, "primary": True}]
        self.addCleanup(reset_hotkey_daemon_state, daemon)
        hotkey_state.set_last_known_monitors(monitors)
        hotkey_state.set_last_topology_refresh(100.0)
        self.assertEqual(call_attr(daemon_topology, "_refresh_monitors", 100.5)[0]["x"], 0)
        self.assertEqual(call_attr(daemon_window_swap, "_swap_direction_for_monitors", monitors, 0)[:2], (None, 0))
        self.assertEqual(call_attr(daemon_window_swap, "_resolve_swap_direction", monitors, 0)[:2], (None, 0))

    def test_swap_direction_uses_topology_order_instead_of_current_monitor_anchor(self):
        """Test swap traversal follows the stable topology order rather than the current monitor anchor."""
        monitors = [
            {"x": 0, "y": 0, "width": 1920, "height": 1080, "primary": True},
            {"x": 0, "y": 1080, "width": 1920, "height": 1080, "primary": False},
            {"x": 0, "y": 2160, "width": 1920, "height": 1080, "primary": False},
        ]
        self.assertEqual(call_attr(daemon_window_swap, "_swap_direction_for_monitors", monitors, 0)[:2], (ecodes.KEY_DOWN, 1))

    def test_swap_direction_horizontal_three_monitors_uses_full_cycle(self):
        """Test horizontal 3-monitor layouts traverse across all monitors and back."""
        monitors = [
            {"x": 0, "y": -1, "width": 1920, "height": 1080, "primary": True},
            {"x": 1920, "y": 1, "width": 1920, "height": 1080, "primary": False},
            {"x": 3840, "y": 0, "width": 1920, "height": 1080, "primary": False},
        ]
        self.assertEqual(call_attr(daemon_window_swap, "_swap_direction_for_monitors", monitors, 0)[:2], (ecodes.KEY_RIGHT, 1))
        self.assertEqual(call_attr(daemon_window_swap, "_swap_direction_for_monitors", monitors, 1)[:2], (ecodes.KEY_RIGHT, 2))
        self.assertEqual(call_attr(daemon_window_swap, "_swap_direction_for_monitors", monitors, 2)[:2], (ecodes.KEY_LEFT, 3))
        self.assertEqual(call_attr(daemon_window_swap, "_swap_direction_for_monitors", monitors, 3)[:2], (ecodes.KEY_LEFT, 0))

    def test_cycle_order_horizontal_is_stable_with_small_y_jitter(self):
        """Test horizontal cycle ordering keeps left-to-right order under y-axis jitter."""
        monitors = [
            {"x": 0, "y": 3, "width": 1920, "height": 1080, "primary": True},
            {"x": 1920, "y": -2, "width": 1920, "height": 1080, "primary": False},
            {"x": 3840, "y": 1, "width": 1920, "height": 1080, "primary": False},
        ]
        self.assertEqual(call_attr(daemon_topology, "_monitor_indices_in_cycle_order", monitors), [0, 1, 2])

    def test_cycle_order_mixed_layout_includes_all_monitors(self):
        """Test mixed layout ordering remains deterministic and includes every monitor once."""
        monitors = [
            {"x": 0, "y": 0, "width": 1920, "height": 1080, "primary": True},
            {"x": 1920, "y": 0, "width": 1920, "height": 1080, "primary": False},
            {"x": 0, "y": 1080, "width": 1920, "height": 1080, "primary": False},
        ]
        order = call_attr(daemon_topology, "_monitor_indices_in_cycle_order", monitors)
        self.assertEqual(order[0], 0)
        self.assertCountEqual(order, [0, 1, 2])
        self.assertEqual(len(order), 3)

    def test_resolve_script_and_input_capabilities(self):
        """Test script resolution and input-capability layout."""
        self.assertEqual(hotkey_state.resolve_script_name(None, 227), "asus-display-mode.sh")
        self.assertIsNone(hotkey_state.resolve_script_name(56, 0))
        self.assertEqual(hotkey_state.resolve_script_name(106, 0), "asus-screenpad-toggle.sh")
        self.assertEqual(hotkey_state.resolve_script_name(None, 156), "asus-control-center.sh")
        wmi_dev = MagicMock()
        wmi_dev.capabilities.return_value = {ecodes.EV_KEY: [ecodes.KEY_TOUCHPAD_TOGGLE, 999]}
        caps = call_attr(daemon_input, "_build_input_capabilities", wmi_dev)[ecodes.EV_KEY]
        self.assertIn(ecodes.KEY_LEFTMETA, caps)
        self.assertIn(999, caps)


class TestAsusHotkeyDaemonExtended(unittest.TestCase):
    """Additional branch tests for hotkey daemon helpers."""

    def setUp(self):
        """Reset daemon state before each test."""
        reset_hotkey_daemon_state(daemon)

    @patch("asus_hotkey_daemon_runtime.find_input_device_path", return_value=None)
    def test_find_device_path_returns_none_when_no_matching_input(self, _mock_find_input):
        """Test find_device_path returns None when no matching input device is found."""
        self.assertIsNone(daemon.find_device_path())

    @patch("asus_hotkey_daemon_input.find_input_device_path", return_value=None)
    def test_open_device_exits_when_not_found(self, _mock_find):
        """Test _open_device exits when no WMI device path is detected."""
        with self.assertRaises(SystemExit):
            call_attr(daemon_input, "_open_device")

    def test_process_hotkey_event_updates_scancode(self):
        """Test EV_MSC scan event updates last_scancode in state tuple."""
        event = MagicMock()
        event.type = ecodes.EV_MSC
        event.code = ecodes.MSC_SCAN
        event.value = 136
        sc, toggle = call_attr(daemon_input, "_process_hotkey_event", event, None, MagicMock(), False)
        self.assertEqual(sc, 136)
        self.assertFalse(toggle)

    def test_perform_window_swap_profile_driven_direction(self):
        """Test perform_window_swap follows coordinate path while traversing back."""
        mock_ui = MagicMock()
        monitors = [
            {"x": 0, "y": 0, "width": 1920, "height": 1080, "primary": True},
            {"x": 0, "y": 1080, "width": 1920, "height": 550, "primary": False},
            {"x": 0, "y": 1630, "width": 1920, "height": 720, "primary": False},
        ]
        self.addCleanup(reset_hotkey_daemon_state, daemon)
        seed_usable_monitor_topology(monitors)
        with window_swap_monitor_patches(move_return=False):
            res = daemon.perform_window_swap(mock_ui, 2)
        self.assertEqual(res, 3)
        mock_ui.write.assert_any_call(ecodes.EV_KEY, ecodes.KEY_UP, 1)

    def test_normalize_detected_profile_legacy_values(self):
        """Test profile normalization supports legacy numeric detect outputs."""
        normalize = get_attr(daemon_topology_detect, "_normalize_detected_profile")
        self.assertEqual(normalize("1"), "all")
        self.assertEqual(normalize("2"), "main_only")
        self.assertEqual(normalize("3"), "screenpad_only")
        self.assertIsNone(normalize("unexpected"))

    @patch("asus_hotkey_daemon_session._run_command")
    def test_detect_display_profile_success(self, mock_run):
        """Test _detect_display_profile parses backend detect output."""
        mock_run.return_value = MagicMock(returncode=0, stdout="external_only\n")
        detect = get_attr(daemon_topology_detect, "_detect_display_profile")
        self.assertEqual(detect(), "external_only")

    @patch("asus_hotkey_daemon_session._run_command", side_effect=subprocess.TimeoutExpired(cmd="x", timeout=2))
    def test_detect_display_profile_timeout(self, _mock_run):
        """Test _detect_display_profile returns None when backend detect times out."""
        self.assertIsNone(call_attr(daemon_topology_detect, "_detect_display_profile"))

    @patch("asus_hotkey_daemon_session._run_command")
    def test_detect_swap_topology_success(self, mock_run):
        """Test topology detection parses profile and monitor count from backend output."""
        mock_run.return_value = MagicMock(returncode=0, stdout="external_only:4\n")
        self.assertEqual(call_attr(daemon_topology_detect, "_detect_swap_topology"), ("external_only", 4))

    def test_parse_topology_output_invalid(self):
        """Test malformed topology output fails gracefully."""
        parse_topology = get_attr(daemon_topology_detect, "_parse_topology_output")
        self.assertEqual(parse_topology("garbage"), (None, None))
        self.assertEqual(parse_topology("all:not-a-number"), (None, None))

    def test_parse_topology_map_output(self):
        """Test topology-map parser accepts valid JSON payload and rejects bad data."""
        parse_topology_map = get_attr(daemon_topology_detect, "_parse_topology_map_output")
        profile, monitors = parse_topology_map(
            '{"profile":"all","count":3,"monitors":[{"x":0,"y":0,"width":1920,"height":1080,"primary":true}]}'
        )
        self.assertEqual(profile, "all")
        self.assertEqual(monitors, [{"x": 0, "y": 0, "width": 1920, "height": 1080, "scale": 1.0, "primary": True}])
        self.assertEqual(parse_topology_map("not-json"), (None, None))

    @patch("asus_hotkey_daemon_topology.detect_swap_topology_map", return_value=(None, None, None))
    def test_perform_window_swap_uses_cached_topology_when_map_fails(self, _mock_detect_map):
        """Test cached monitor topology is used when live topology-map detection fails."""
        self.addCleanup(reset_hotkey_daemon_state, daemon)
        seed_usable_monitor_topology(
            [
                {"x": 0, "y": 0, "width": 1920, "height": 1080, "primary": True},
                {"x": 0, "y": 1080, "width": 1920, "height": 1080, "primary": False},
                {"x": 0, "y": 2160, "width": 1920, "height": 1080, "primary": False},
            ]
        )
        mock_ui = MagicMock()
        with window_swap_monitor_patches(move_return=False):
            result = daemon.perform_window_swap(mock_ui, 0)
        self.assertEqual(result, 1)
        mock_ui.write.assert_any_call(ecodes.EV_KEY, ecodes.KEY_DOWN, 1)

    def test_swap_direction_from_step_cycle(self):
        """Test swap direction cycles down then up across monitor count."""
        direction_fn = get_attr(daemon_topology, "_swap_direction_from_step")
        down_key, state1 = direction_fn(0, 3)
        self.assertEqual(down_key, ecodes.KEY_DOWN)
        self.assertEqual(state1, 1)
        up_key, state2 = direction_fn(2, 3)
        self.assertEqual(up_key, ecodes.KEY_UP)
        self.assertEqual(state2, 3)

    @patch("evdev.list_devices")
    @patch("evdev.InputDevice", side_effect=OSError("Permission denied"))
    def test_find_device_path_oserror(self, mock_input_device, mock_list_devices):
        """Test find_device_path ignores devices that raise OSError."""
        listed = "/dev/input/event0"
        mock_list_devices.return_value = [listed]
        path = daemon.find_device_path()
        self.assertIsNone(path)
        mock_input_device.assert_called_with(listed)

    @patch("asus_hotkey_daemon_input.find_input_device_path", return_value=None)
    def test_main_no_device_exit(self, _mock_find):
        """Test main exits when find_device_path returns None."""
        with self.assertRaises(SystemExit):
            daemon.main()


class TestAsusHotkeyDaemonTopologyFailures(unittest.TestCase):
    """Topology detect/parse failure paths and single-monitor swap guards."""

    def setUp(self):
        """Reset daemon state before each test."""
        reset_hotkey_daemon_state(daemon)

    @patch("asus_hotkey_daemon_topology_detect.run_in_desktop_session", side_effect=OSError("fail"))
    def test_detect_display_profile_oserror_returns_none(self, _mock_run):
        """Test detect_display_profile returns None on OSError from desktop session."""
        self.assertIsNone(call_attr(daemon_topology_detect, "_detect_display_profile"))

    @patch("asus_hotkey_daemon_topology_detect.run_in_desktop_session", return_value=MagicMock(returncode=1, stdout=""))
    def test_detect_display_profile_nonzero_returns_none(self, _mock_run):
        """Test detect_display_profile returns None when command exits non-zero."""
        self.assertIsNone(call_attr(daemon_topology_detect, "_detect_display_profile"))

    @patch("asus_hotkey_daemon_topology_detect.run_in_desktop_session", side_effect=OSError("fail"))
    def test_detect_swap_topology_oserror_returns_none_pair(self, _mock_run):
        """Test detect_swap_topology returns (None, None) on OSError."""
        self.assertEqual(call_attr(daemon_topology_detect, "_detect_swap_topology"), (None, None))

    @patch("asus_hotkey_daemon_topology_detect.run_in_desktop_session", return_value=MagicMock(returncode=1, stdout=""))
    def test_detect_swap_topology_nonzero_returns_none_pair(self, _mock_run):
        """Test detect_swap_topology returns (None, None) when command exits non-zero."""
        self.assertEqual(call_attr(daemon_topology_detect, "_detect_swap_topology"), (None, None))

    def test_parse_monitor_entry_invalid_types_return_none(self):
        """Test parse_topology_map_output gracefully handles non-dict and bad-field monitor entries."""
        parse_topology_map_output = get_attr(daemon_topology_detect, "_parse_topology_map_output")
        self.assertEqual(parse_topology_map_output('{"profile":"all","monitors":["not-a-dict"]}'), (None, None))
        self.assertEqual(parse_topology_map_output('{"profile":"all","monitors":[{"x":"bad","y":0}]}'), (None, None))

    def test_normalize_topology_payload_invalid_returns_none_pair(self):
        """Test parse_topology_map_output returns (None, None) for non-dict payload and bad profile."""
        parse_topology_map_output = get_attr(daemon_topology_detect, "_parse_topology_map_output")
        self.assertEqual(parse_topology_map_output('"not-a-dict"'), (None, None))
        self.assertEqual(parse_topology_map_output('{"profile":"not-valid-profile","monitors":[]}'), (None, None))

    def test_parse_topology_map_payload_empty_monitors_returns_none_pair(self):
        """Test parse_topology_map_output returns (None, None) when monitor list is empty."""
        parse_topology_map_output = get_attr(daemon_topology_detect, "_parse_topology_map_output")
        self.assertEqual(parse_topology_map_output('{"profile":"all","monitors":[]}'), (None, None))

    def test_swap_direction_from_step_single_monitor(self):
        """Test swap_direction_from_step with a single monitor always returns KEY_DOWN and step 0."""
        key, step = call_attr(daemon_topology, "_swap_direction_from_step", 0, 1)
        self.assertEqual(key, ecodes.KEY_DOWN)
        self.assertEqual(step, 0)

    def test_find_primary_index_fallback_when_no_primary(self):
        """Test perform_window_swap works correctly when no monitor is marked primary."""
        monitors = [
            {"x": 0, "y": 0, "width": 1920, "height": 1080, "primary": False},
            {"x": 1920, "y": 0, "width": 1920, "height": 1080, "primary": False},
            {"x": 0, "y": 1080, "width": 1920, "height": 1080, "primary": False},
        ]
        self.addCleanup(reset_hotkey_daemon_state, daemon)
        seed_usable_monitor_topology(monitors)
        mock_ui = MagicMock()
        with window_swap_monitor_patches(move_return=False):
            result = daemon.perform_window_swap(mock_ui, 0)
        self.assertEqual(result, 1)
        mock_ui.write.assert_any_call(ecodes.EV_KEY, ecodes.KEY_DOWN, 1)


if __name__ == "__main__":
    unittest.main()
