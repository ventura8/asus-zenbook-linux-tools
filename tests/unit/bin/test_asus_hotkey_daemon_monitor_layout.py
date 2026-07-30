"""Monitor layout, neighbor graph, and focus-geometry unit tests."""

import importlib
import unittest
from unittest.mock import MagicMock, patch

from evdev import ecodes

from tests.unit.bin.attr_helpers import call_attr
from tests.unit.bin.hotkey_daemon_test_utils import load_daemon, reset_hotkey_daemon_state

load_daemon()
monitor = importlib.import_module("asus_hotkey_daemon_monitor")
topology = importlib.import_module("asus_hotkey_daemon_topology")
window_move = importlib.import_module("asus_hotkey_daemon_window_move")
window_swap = importlib.import_module("asus_hotkey_daemon_window_swap")
window_swap_gnome = importlib.import_module("asus_hotkey_daemon_window_swap_gnome")
hotkey_state = importlib.import_module("asus_hotkey_daemon_state")
daemon = importlib.import_module("asus_hotkey_daemon")


class TestAsusHotkeyDaemonMonitorLayout(unittest.TestCase):
    """Monitor layout detection, cycle order, and neighbor graph helpers."""

    def setUp(self):
        """Reset hotkey daemon mutable state before each layout test."""
        reset_hotkey_daemon_state(daemon)
        self.addCleanup(monitor.reset_window_swap_state)

    def test_swap_direction_from_step_two_monitor_cycle(self):
        """Test 2-monitor cycle alternates down/up branches."""
        self.assertEqual(call_attr(topology, "_swap_direction_from_step", 0, 2), (ecodes.KEY_DOWN, 1))
        self.assertEqual(call_attr(topology, "_swap_direction_from_step", 1, 2), (ecodes.KEY_UP, 0))

    def test_find_primary_index_defaults_to_zero_without_primary(self):
        """Test _primary_monitor_index returns 0 when no monitor is marked primary."""
        monitors = [{"primary": False}, {"primary": False}]
        self.assertEqual(call_attr(topology, "_primary_monitor_index", monitors), 0)

    def test_dfs_visit_node_records_unvisited_and_pushes_neighbors(self):
        """Test DFS visit records a fresh node and stacks unvisited neighbors."""
        stack = [0]
        visited = set()
        order = []
        directional = [{1: ecodes.KEY_RIGHT}, {}]
        monitors = [{"x": 0, "y": 0}, {"x": 100, "y": 0}]
        call_attr(topology, "_dfs_visit_node", stack, visited, order, directional, monitors)
        self.assertEqual(order, [0])
        self.assertEqual(visited, {0})
        self.assertEqual(stack, [1])

    def test_monitor_indices_single_and_vertical_layouts(self):
        """Test cycle ordering for single-monitor and vertical multi-monitor layouts."""
        single = [{"x": 0, "y": 0, "width": 100, "height": 100, "primary": True}]
        self.assertEqual(call_attr(topology, "_monitor_indices_in_cycle_order", single), [0])
        vertical = [
            {"x": 0, "y": 0, "width": 1920, "height": 1080, "primary": True},
            {"x": 0, "y": 1200, "width": 1920, "height": 1080, "primary": False},
        ]
        self.assertEqual(call_attr(topology, "_monitor_indices_in_cycle_order", vertical), [0, 1])

    def test_detect_monitor_layout_vertical_from_span_ratio(self):
        """Test layout classifier returns vertical when y-span dominates x-span."""
        monitors = [{"x": 0, "y": 0, "width": 800, "height": 600}, {"x": 50, "y": 2000, "width": 800, "height": 600}]
        self.assertEqual(call_attr(topology, "_detect_monitor_layout", monitors), "vertical")

    def test_mixed_layout_cycle_order_runs_dfs_traversal(self):
        """Test mixed layouts walk the directional neighbor graph via DFS."""
        monitors = [
            {"x": 0, "y": 0, "width": 1000, "height": 1000, "primary": True},
            {"x": 1100, "y": 0, "width": 1000, "height": 1000, "primary": False},
            {"x": 0, "y": 1100, "width": 1000, "height": 1000, "primary": False},
        ]
        directional = call_attr(topology, "_build_directional_neighbors", monitors)
        order = call_attr(topology, "_mixed_layout_cycle_order", monitors, directional)
        self.assertEqual(sorted(order), [0, 1, 2])
        self.assertEqual(len(order), 3)

    def test_monitor_neighbor_candidates_include_up_and_down(self):
        """Test neighbor candidate builder emits up/down edges for stacked monitors."""
        source = {"x": 0, "y": 100, "width": 100, "height": 50}
        above = {"x": 0, "y": 0, "width": 100, "height": 50}
        below = {"x": 0, "y": 200, "width": 100, "height": 50}
        up_keys = [item[0] for item in call_attr(topology, "_monitor_neighbor_candidates", source, above)]
        down_keys = [item[0] for item in call_attr(topology, "_monitor_neighbor_candidates", source, below)]
        self.assertIn(ecodes.KEY_UP, up_keys)
        self.assertIn(ecodes.KEY_DOWN, down_keys)

    def test_refresh_monitors_returns_cached_clone_when_fresh(self):
        """Test _refresh_monitors returns cached monitors when refresh is not due."""
        cached = [{"x": 1, "y": 2, "width": 3, "height": 4, "primary": True}]
        hotkey_state.set_last_known_monitors(cached)
        hotkey_state.set_last_topology_refresh(1000.0)
        result = call_attr(topology, "_refresh_monitors", 1000.5)
        self.assertEqual(result, cached)
        self.assertIsNot(result, cached)

    def test_find_primary_index_prefers_flagged_primary(self):
        """Test _primary_monitor_index returns index of explicitly-primary monitor."""
        monitors = [{"primary": False}, {"primary": True}, {"primary": False}]
        self.assertEqual(call_attr(topology, "_primary_monitor_index", monitors), 1)

    def test_neighbor_sort_key_uses_default_priority_for_unknown_direction(self):
        """Test _neighbor_sort_key falls back to default direction priority 99."""
        directional = [{1: None}, {}]
        monitors = [{"x": 0, "y": 0}, {"x": 10, "y": 20}]
        self.assertEqual(call_attr(topology, "_neighbor_sort_key", directional, monitors, 0, 1), (99, 20, 10))

    def test_dfs_visit_node_short_circuits_when_node_already_visited(self):
        """Test DFS helper exits early when popped node was already visited."""
        stack = [0]
        visited = {0}
        order = []
        directional = [{1: ecodes.KEY_RIGHT}, {}]
        monitors = [{"x": 0, "y": 0}, {"x": 1, "y": 0}]
        call_attr(topology, "_dfs_visit_node", stack, visited, order, directional, monitors)
        self.assertEqual(order, [])
        self.assertEqual(stack, [])

    def test_fill_unreachable_appends_remaining_monitors(self):
        """Test unreachable monitor indices are appended in stable order."""
        monitors = [{"x": 100, "y": 0, "primary": False}, {"x": 0, "y": 0, "primary": True}, {"x": 0, "y": 50, "primary": False}]
        order = [1]
        visited = {1}
        call_attr(topology, "_fill_unreachable", monitors, order, visited)
        self.assertEqual(order, [1, 0, 2])

    def test_monitor_layout_detection_horizontal_vertical_and_mixed(self):
        """Test monitor layout classifier branches for horizontal, vertical, and mixed."""
        horizontal = [{"x": 0, "y": 0, "width": 1920, "height": 1080}, {"x": 1920, "y": 1, "width": 1920, "height": 1080}]
        vertical = [{"x": 0, "y": 0, "width": 1920, "height": 1080}, {"x": 1, "y": 1200, "width": 1920, "height": 1080}]
        mixed = [{"x": 0, "y": 0, "width": 1200, "height": 1200}, {"x": 800, "y": 700, "width": 1200, "height": 1200}]
        self.assertEqual(call_attr(topology, "_detect_monitor_layout", horizontal), "horizontal")
        self.assertEqual(call_attr(topology, "_detect_monitor_layout", vertical), "vertical")
        self.assertEqual(call_attr(topology, "_detect_monitor_layout", mixed), "mixed")


class TestAsusHotkeyDaemonMonitorFocusGeometry(unittest.TestCase):
    """Focus geometry, bounce step, and window-move emission helpers."""

    def setUp(self):
        """Reset hotkey daemon mutable state before each focus-geometry test."""
        reset_hotkey_daemon_state(daemon)
        self.addCleanup(monitor.reset_window_swap_state)

    def test_emit_window_move_uses_patched_module_emitter(self):
        """Test _emit_window_move dispatches to patched module emitter when present."""
        patched = MagicMock()
        ui = MagicMock()
        with patch("asus_hotkey_daemon_window_move._window_move_emitter", patched):
            call_attr(window_move, "_emit_window_move", ui, ecodes.KEY_LEFT)
        patched.assert_called_once_with(ui, ecodes.KEY_LEFT)

    def test_clone_monitors_returns_none_for_empty(self):
        """Test monitor clone helper returns None for empty monitor collections."""
        self.assertIsNone(call_attr(topology, "_clone_monitors", []))

    def test_resolve_swap_direction_resets_state_when_no_monitors(self):
        """Test resolve swap direction clears topology state when no monitors are available."""
        hotkey_state.set_swap_topology_signature(("stale",))
        direction, next_step, target = call_attr(window_swap, "_resolve_swap_direction", None, 3)
        self.assertIsNone(direction)
        self.assertEqual(next_step, 3)
        self.assertIsNone(target)
        self.assertIsNone(hotkey_state.get_swap_topology_signature())

    def test_resolve_keeps_step_when_signature_changes_same_count(self):
        """Same monitor count must not rewind bounce step (avoids last-monitor Down no-ops)."""
        monitors_a = [
            {"x": 0, "y": 0, "width": 1920, "height": 1080, "primary": True},
            {"x": 0, "y": 1080, "width": 1920, "height": 1080, "primary": False},
            {"x": 0, "y": 2160, "width": 1920, "height": 1080, "primary": False},
        ]
        monitors_b = [
            {"x": 0, "y": 0, "width": 1920, "height": 1080, "primary": True},
            {"x": 10, "y": 1080, "width": 1920, "height": 1080, "primary": False},
            {"x": 10, "y": 2160, "width": 1920, "height": 1080, "primary": False},
        ]
        original_sig = monitor.get_monitor_signature(monitors_a)
        hotkey_state.set_swap_topology_signature(original_sig)
        with patch("asus_hotkey_daemon_topology._focused_monitor_index", return_value=None):
            direction, next_step, _target = call_attr(window_swap, "_resolve_swap_direction", monitors_b, 2)
            self.assertEqual(next_step, 3)
            self.assertEqual(direction, ecodes.KEY_UP)

    def test_bounce_step_leaving_last_starts_reverse(self):
        """Last ordered position must use reverse-phase step (not forward Down)."""
        self.assertEqual(call_attr(topology, "_bounce_step_leaving_ordered_pos", 2, 3), 2)
        self.assertEqual(call_attr(topology, "_bounce_step_leaving_ordered_pos", 1, 2), 1)
        self.assertEqual(call_attr(topology, "_bounce_step_leaving_ordered_pos", 0, 3), 0)

    def test_parse_xdotool_window_center(self):
        """xdotool geometry text must yield the window center point."""
        text = "Window 1\n  Position: 100,200 (screen: 0)\n  Geometry: 400x300\n"
        self.assertEqual(call_attr(window_swap_gnome, "_parse_xdotool_window_center", text), (300, 350))
        self.assertIsNone(call_attr(window_swap_gnome, "_parse_xdotool_window_center", "bad"))
        proxy = "Window 1\n  Position: -100,-100 (screen: 0)\n  Geometry: 1x1\n"
        self.assertIsNone(call_attr(window_swap_gnome, "_parse_xdotool_window_center", proxy))

    def test_parse_xdotool_mouse_point(self):
        """xdotool mouse shell output must yield the pointer coordinates."""
        self.assertEqual(call_attr(window_swap_gnome, "_parse_xdotool_mouse_point", "X=2011\nY=2500\nSCREEN=0\n"), (2011, 2500))
        self.assertIsNone(call_attr(window_swap_gnome, "_parse_xdotool_mouse_point", "bad"))

    def test_monitor_index_at_point_uses_scale_for_physical_pointer(self):
        """Physical pointer coords must hit logical monitors via scale mapping."""
        monitors = [
            {"x": 0, "y": 0, "width": 1920, "height": 1080, "scale": 2.0, "primary": True},
            {"x": 0, "y": 1080, "width": 1920, "height": 550, "scale": 2.0, "primary": False},
        ]
        self.assertEqual(call_attr(window_swap_gnome, "_monitor_index_at_point", monitors, 100, 2500), 1)
        self.assertEqual(call_attr(window_swap_gnome, "_monitor_index_at_point", monitors, 100, 100), 0)

    def test_monitor_index_at_point_keeps_logical_pointer_unscaled(self):
        """Logical ScreenPad coords must not be remapped through scale=2 onto main."""
        monitors = [
            {"x": 0, "y": 1080, "width": 1920, "height": 550, "scale": 2.0, "primary": False},
            {"x": 0, "y": 0, "width": 1920, "height": 1080, "scale": 2.0, "primary": True},
        ]
        # Exclusive right/bottom edges: use interior ScreenPad logical coords.
        self.assertEqual(call_attr(window_swap_gnome, "_monitor_index_at_point", monitors, 1919, 1629), 0)
        self.assertEqual(call_attr(window_swap_gnome, "_monitor_index_at_point", monitors, 100, 1500), 0)
        self.assertEqual(call_attr(window_swap_gnome, "_monitor_index_at_point", monitors, 100, 500), 1)

    def test_swap_direction_aligns_when_focus_on_last_monitor(self):
        """Focus on the last monitor must hop Up on the first press (step 0)."""
        monitors = [
            {"x": 0, "y": 0, "width": 1920, "height": 1080, "primary": True},
            {"x": 0, "y": 1080, "width": 1920, "height": 1080, "primary": False},
            {"x": 0, "y": 2160, "width": 1920, "height": 1080, "primary": False},
        ]
        with patch("asus_hotkey_daemon_topology._focused_monitor_index", return_value=2):
            direction, next_step, target = call_attr(window_swap, "_swap_direction_for_monitors", monitors, 0)
        self.assertEqual(direction, ecodes.KEY_UP)
        self.assertEqual(next_step, 3)
        self.assertEqual(target["y"], 1080)

    def test_parse_gdbus_bool_and_int(self):
        """gdbus stdout parsers must accept (true,)/(false,)/(N,) forms."""
        self.assertTrue(call_attr(window_swap_gnome, "_parse_gdbus_bool", "(true,)\n"))
        self.assertFalse(call_attr(window_swap_gnome, "_parse_gdbus_bool", "(false,)\n"))
        self.assertIsNone(call_attr(window_swap_gnome, "_parse_gdbus_bool", "bad"))
        self.assertEqual(call_attr(window_swap_gnome, "_parse_gdbus_int", "(2,)\n"), 2)
        self.assertEqual(call_attr(window_swap_gnome, "_parse_gdbus_int", "(-1,)\n"), -1)

    def test_apply_gnome_window_move_retries_opposite_on_edge(self):
        """Mutter edge no-op must retry the opposite direction on the same press."""
        ui = MagicMock()
        with (
            patch("asus_hotkey_daemon_window_swap_gnome._mutter_move_focused", side_effect=[False, True]) as mutter_move,
            patch("asus_hotkey_daemon_window_swap_gnome._emit_window_move") as emit,
            patch("asus_hotkey_daemon_window_swap_gnome.prime_gnome_window_swap_extension"),
        ):
            ok = call_attr(window_swap_gnome, "_apply_gnome_window_move", ui, ecodes.KEY_DOWN)
        self.assertTrue(ok)
        self.assertEqual([call.args[0] for call in mutter_move.call_args_list], [ecodes.KEY_DOWN, ecodes.KEY_UP])
        emit.assert_not_called()

    def test_apply_gnome_window_move_uinput_when_extension_edge_noop(self):
        """When Mutter returns false for both directions, fall back to uinput chords."""
        ui = MagicMock()
        with (
            patch("asus_hotkey_daemon_window_swap_gnome._mutter_move_focused", side_effect=[False, False]),
            patch("asus_hotkey_daemon_window_swap_gnome._emit_window_move", side_effect=[True]) as emit,
            patch("asus_hotkey_daemon_window_swap_gnome.prime_gnome_window_swap_extension"),
        ):
            ok = call_attr(window_swap_gnome, "_apply_gnome_window_move", ui, ecodes.KEY_DOWN)
        self.assertTrue(ok)
        emit.assert_called_once_with(ui, ecodes.KEY_DOWN)


if __name__ == "__main__":
    unittest.main()
