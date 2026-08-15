"""Coverage for window-swap queue, drain, and deferred-worker bookkeeping."""

import importlib
import unittest
from unittest.mock import MagicMock, patch

from evdev import ecodes

from tests.unit.bin.attr_helpers import call_attr
from tests.unit.bin.hotkey_daemon_test_utils import load_daemon, reset_hotkey_daemon_state

daemon = load_daemon()
window_swap = importlib.import_module("asus_hotkey_daemon_window_swap")
hotkey_state = importlib.import_module("asus_hotkey_daemon_state")


class TestAsusHotkeyWindowSwapQueue(unittest.TestCase):
    """Exercise in-flight coalescing and deferred worker start failures."""

    def setUp(self):
        """Reset swap bookkeeping between cases."""
        reset_hotkey_daemon_state(daemon)
        state = call_attr(window_swap, "get_window_swap_state")
        state.clear()
        state.update(
            {
                "in_flight": False,
                "pending": None,
                "draining": False,
                "deferred_active": False,
                "committed_step": None,
            }
        )

    def test_direction_for_monitor_pair_falls_back_to_origin_delta(self):
        """Neighbor-miss uses geometric origin delta between monitors."""
        monitors = [
            {"x": 0, "y": 0, "width": 100, "height": 100, "primary": True},
            {"x": 200, "y": 0, "width": 100, "height": 100, "primary": False},
        ]
        neighbors = [{}, {}]
        direction = call_attr(
            window_swap,
            "_direction_for_monitor_pair",
            monitors,
            0,
            1,
            neighbors,
        )
        self.assertEqual(direction, ecodes.KEY_RIGHT)

    def test_queue_take_and_commit_swap_step(self):
        """Pending queue and committed step round-trip under the lock."""
        ui = MagicMock()
        call_attr(window_swap, "_queue_pending_window_swap", ui, 3)
        pending = call_attr(window_swap, "_take_pending_window_swap")
        self.assertEqual(pending, (ui, 3))
        self.assertIsNone(call_attr(window_swap, "_take_pending_window_swap"))
        self.assertEqual(call_attr(window_swap, "_take_committed_swap_step", 1), 1)
        call_attr(window_swap, "_commit_swap_step", 7)
        self.assertEqual(call_attr(window_swap, "_take_committed_swap_step", 1), 7)

    def test_start_window_swap_worker_runtime_error_clears_in_flight(self):
        """RuntimeError from Thread.start clears in_flight and returns False."""
        state = call_attr(window_swap, "get_window_swap_state")
        state["in_flight"] = True
        worker = MagicMock()
        worker.start.side_effect = RuntimeError("no threads")
        with patch.object(window_swap, "_thread_factory", return_value=worker):
            self.assertFalse(
                call_attr(
                    window_swap,
                    "_start_window_swap_worker",
                    MagicMock(),
                    [{"x": 0, "y": 0, "width": 1, "height": 1}],
                    ecodes.KEY_DOWN,
                    {"x": 0, "y": 0},
                )
            )
        self.assertFalse(state["in_flight"])

    def test_start_deferred_worker_runtime_error_clears_flags(self):
        """Deferred start failure clears deferred_active and in_flight."""
        state = call_attr(window_swap, "get_window_swap_state")
        state["in_flight"] = True
        worker = MagicMock()
        worker.start.side_effect = RuntimeError("no threads")
        with patch.object(window_swap, "_thread_factory", return_value=worker):
            self.assertFalse(
                call_attr(
                    window_swap,
                    "_start_deferred_window_swap_worker",
                    MagicMock(),
                    0,
                    [{"x": 0, "y": 0, "width": 1, "height": 1}, {"x": 1, "y": 0, "width": 1, "height": 1}],
                )
            )
        self.assertFalse(state["deferred_active"])
        self.assertFalse(state["in_flight"])

    def test_window_swap_worker_clears_in_flight(self):
        """Compat worker applies a move then clears in_flight in finally."""
        state = call_attr(window_swap, "get_window_swap_state")
        state["in_flight"] = True
        with patch.object(window_swap, "_apply_window_move", return_value=True):
            call_attr(
                window_swap,
                "window_swap_worker",
                MagicMock(),
                [{"x": 0, "y": 0, "width": 1, "height": 1}],
                ecodes.KEY_DOWN,
                {"x": 0, "y": 0},
            )
        self.assertFalse(state["in_flight"])

    def test_move_window_to_monitor_empty_and_wmctrl_path(self):
        """Empty monitor fails; wmctrl success short-circuits xdotool."""
        self.assertFalse(call_attr(window_swap, "_move_window_to_monitor", None))
        with (
            patch.object(window_swap, "_move_window_via_wmctrl", return_value=True) as wmctrl,
            patch.object(window_swap, "_move_window_via_xdotool") as xdotool,
        ):
            self.assertTrue(call_attr(window_swap, "_move_window_to_monitor", {"x": 10, "y": 20}))
            wmctrl.assert_called_once_with(10, 20)
            xdotool.assert_not_called()

    def test_apply_window_move_kde_and_other_families(self):
        """KDE uses X11 move helpers; unknown family falls back to uinput chord."""
        monitors = [
            {"x": 0, "y": 0, "width": 100, "height": 100, "primary": True},
            {"x": 100, "y": 0, "width": 100, "height": 100, "primary": False},
        ]
        with (
            patch.object(window_swap, "desktop_family_hint", return_value="kde"),
            patch.object(window_swap, "_move_window_to_monitor", return_value=True),
        ):
            self.assertTrue(
                call_attr(
                    window_swap,
                    "_apply_window_move",
                    MagicMock(),
                    monitors,
                    ecodes.KEY_RIGHT,
                    monitors[1],
                )
            )
        with (
            patch.object(window_swap, "desktop_family_hint", return_value="other"),
            patch.object(window_swap, "_emit_window_move", return_value=True) as emit,
        ):
            self.assertTrue(
                call_attr(
                    window_swap,
                    "_apply_window_move",
                    MagicMock(),
                    monitors,
                    ecodes.KEY_RIGHT,
                    monitors[1],
                )
            )
            emit.assert_called_once()

    def test_drain_pending_swap_runs_coalesced_request(self):
        """Drain performs one pending swap then stops when deferred owns the slot."""
        ui = MagicMock()
        state = call_attr(window_swap, "get_window_swap_state")
        state["pending"] = (ui, 2)
        state["deferred_active"] = True
        with patch.object(window_swap, "_perform_window_swap") as perform:
            call_attr(window_swap, "_drain_pending_swap")
            perform.assert_called_once_with(ui, 2)
        self.assertFalse(state["draining"])

    def test_drain_skips_when_already_draining(self):
        """Nested drain is a no-op while draining is already true."""
        state = call_attr(window_swap, "get_window_swap_state")
        state["draining"] = True
        with patch.object(window_swap, "_take_pending_window_swap") as take:
            call_attr(window_swap, "_drain_pending_swap")
            take.assert_not_called()

    def test_clear_in_flight_skips_drain_while_draining(self):
        """clear does not re-enter drain when already draining."""
        state = call_attr(window_swap, "get_window_swap_state")
        state["in_flight"] = True
        state["draining"] = True
        with patch.object(window_swap, "_drain_pending_swap") as drain:
            call_attr(window_swap, "_clear_window_swap_in_flight")
            drain.assert_not_called()
        self.assertFalse(state["in_flight"])

    def test_resolve_monitors_for_deferred_swap(self):
        """Detection retries once; usable cache short-circuits resolve."""
        monitors = [
            {"x": 0, "y": 0, "width": 1, "height": 1},
            {"x": 1, "y": 0, "width": 1, "height": 1},
        ]
        self.assertEqual(call_attr(window_swap, "_monitors_for_deferred_swap", monitors), monitors)
        with (
            patch.object(window_swap, "detect_swap_topology_map", return_value=(None, None, None)),
            patch.object(window_swap, "time") as time_mod,
            patch.object(hotkey_state, "get_last_known_monitors", return_value=[]),
        ):
            time_mod.sleep = MagicMock()
            time_mod.monotonic = MagicMock(return_value=1.0)
            self.assertIsNone(call_attr(window_swap, "_resolve_monitors_for_deferred_swap"))
            time_mod.sleep.assert_called_once()

    def test_deferred_worker_skips_without_topology(self):
        """Deferred worker warns and returns when monitors stay unavailable."""
        with (
            patch.object(window_swap, "_monitors_for_deferred_swap", return_value=None),
            self.assertLogs("asus_hotkey_daemon_window_swap", level="WARNING"),
        ):
            call_attr(window_swap, "_deferred_window_swap_worker", MagicMock(), 0)

    def test_deferred_worker_commits_on_successful_move(self):
        """Successful deferred move commits the next bounce step."""
        monitors = [
            {"x": 0, "y": 0, "width": 100, "height": 100},
            {"x": 100, "y": 0, "width": 100, "height": 100},
        ]
        with (
            patch.object(window_swap, "_monitors_for_deferred_swap", return_value=monitors),
            patch.object(window_swap, "prime_gnome_window_swap_extension"),
            patch.object(
                window_swap,
                "_resolve_swap_direction",
                return_value=(ecodes.KEY_RIGHT, 1, monitors[1]),
            ),
            patch.object(window_swap, "_apply_window_move", return_value=True),
            patch.object(window_swap, "_commit_swap_step") as commit,
        ):
            call_attr(window_swap, "_deferred_window_swap_worker", MagicMock(), 0, monitors)
            commit.assert_called_once_with(1)

    def test_run_cached_window_swap_not_ready_and_move_fail(self):
        """Cached sync path clears in_flight on not-ready or failed move."""
        monitors = [
            {"x": 0, "y": 0, "width": 100, "height": 100},
            {"x": 100, "y": 0, "width": 100, "height": 100},
        ]
        with (
            patch.object(window_swap, "_should_defer_cached_window_swap", return_value=False),
            patch.object(
                window_swap,
                "_resolve_swap_direction",
                return_value=(None, 0, None),
            ),
            self.assertLogs("asus_hotkey_daemon_window_swap", level="WARNING"),
        ):
            self.assertEqual(
                call_attr(window_swap, "_run_cached_window_swap", MagicMock(), 0, monitors),
                0,
            )
        with (
            patch.object(window_swap, "_should_defer_cached_window_swap", return_value=False),
            patch.object(
                window_swap,
                "_resolve_swap_direction",
                return_value=(ecodes.KEY_RIGHT, 1, monitors[1]),
            ),
            patch.object(window_swap, "_apply_window_move", return_value=False),
            self.assertLogs("asus_hotkey_daemon_window_swap", level="WARNING"),
        ):
            self.assertEqual(
                call_attr(window_swap, "_run_cached_window_swap", MagicMock(), 0, monitors),
                0,
            )


if __name__ == "__main__":
    unittest.main()
