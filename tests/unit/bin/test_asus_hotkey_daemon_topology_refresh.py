"""Topology-refresh tests for monitor helpers in the hotkey daemon."""

import importlib
import unittest
from unittest.mock import MagicMock, patch

from tests.unit.bin.attr_helpers import call_attr
from tests.unit.bin.hotkey_daemon_test_utils import (
    load_daemon,
    patch_sync_daemon_threads,
    reset_hotkey_daemon_state,
)

daemon = load_daemon()
monitor = importlib.import_module("asus_hotkey_daemon_monitor")
topology = importlib.import_module("asus_hotkey_daemon_topology")
window_swap = importlib.import_module("asus_hotkey_daemon_window_swap")
window_swap_gnome = importlib.import_module("asus_hotkey_daemon_window_swap_gnome")
hotkey_state = importlib.import_module("asus_hotkey_daemon_state")


def _reset_topology_refresh_test_state() -> None:
    """Reset monitor worker state and hotkey topology cache between tests."""
    reset_hotkey_daemon_state(daemon)


class TestAsusHotkeyDaemonAsyncTopology(unittest.TestCase):
    """Nonblocking topology refresh scheduling and deferred-worker helpers."""

    def setUp(self):
        """Reset shared topology refresh worker state before each test."""
        _reset_topology_refresh_test_state()

    def tearDown(self):
        """Restore topology worker state after each async refresh test."""
        _reset_topology_refresh_test_state()

    def _refresh_state(self):
        """Return the monitor module topology refresh worker state dict."""
        return monitor.get_topology_refresh_state()

    def test_schedule_topology_refresh_skips_when_in_flight(self):
        """Test schedule helper does not start another worker while one is running."""
        state = self._refresh_state()
        state["in_flight"] = True
        with patch.object(topology, "_thread_factory") as mock_thread:
            call_attr(topology, "_schedule_topology_refresh", 12.0)
        mock_thread.assert_not_called()

    def test_schedule_topology_refresh_starts_worker_when_idle(self):
        """Test schedule helper starts a daemon worker when none is in flight."""
        state = self._refresh_state()
        state["in_flight"] = False
        fake_thread = MagicMock()
        with patch.object(topology, "_thread_factory", return_value=fake_thread) as mock_thread:
            call_attr(topology, "_schedule_topology_refresh", 33.0)
        mock_thread.assert_called_once()
        fake_thread.start.assert_called_once()
        self.assertEqual(hotkey_state.get_last_topology_refresh(), 33.0)
        self.assertTrue(state["in_flight"])

    def test_topology_refresh_worker_updates_cache_and_clears_in_flight(self):
        """Test background worker caches topology and clears the in-flight flag."""
        monitors = [{"x": 0, "y": 0, "width": 1, "height": 1, "primary": True}]
        state = self._refresh_state()
        state["in_flight"] = True
        with patch("asus_hotkey_daemon_topology.detect_swap_topology_map", return_value=("all", monitors, "mutter")):
            call_attr(topology, "_topology_refresh_worker")
        self.assertEqual(hotkey_state.get_last_known_monitors(), monitors)
        self.assertTrue(hotkey_state.get_last_topology_refreshed_live())
        self.assertEqual(hotkey_state.get_last_topology_source(), "mutter")
        self.assertFalse(state["in_flight"])

    def test_topology_refresh_worker_preserves_live_when_detect_empty(self):
        """Test failed refresh keeps prior live cache flag and clears in-flight."""
        state = self._refresh_state()
        state["in_flight"] = True
        hotkey_state.set_last_topology_refreshed_live(True)
        hotkey_state.set_last_topology_source("mutter")
        with patch("asus_hotkey_daemon_topology.detect_swap_topology_map", return_value=(None, None, None)):
            call_attr(topology, "_topology_refresh_worker")
        self.assertTrue(hotkey_state.get_last_topology_refreshed_live())
        self.assertEqual(hotkey_state.get_last_topology_source(), "mutter")
        self.assertFalse(state["in_flight"])

    def test_refresh_monitors_schedules_when_stale(self):
        """Test _refresh_monitors schedules async refresh when cache is stale."""
        cached = [{"x": 1, "y": 2, "width": 3, "height": 4, "primary": True}]
        hotkey_state.set_last_known_monitors(cached)
        hotkey_state.set_last_topology_refresh(0.0)
        # Patch detect: ImmediateThread runs the worker inline and must not hit host Mutter.
        with (
            patch("asus_hotkey_daemon_topology.detect_swap_topology_map", return_value=(None, None, None)),
            patch_sync_daemon_threads() as threads,
        ):
            result = call_attr(topology, "_refresh_monitors", 50.0)
        self.assertEqual(len(threads), 1)
        self.assertEqual(hotkey_state.get_last_topology_refresh(), 50.0)
        self.assertEqual(result, cached)

    def test_prime_topology_cache_seeds_synchronously(self):
        """Startup prime must populate the cache before the event loop runs."""
        monitors = [{"x": 0, "y": 0, "width": 100, "height": 100, "primary": True}]
        hotkey_state.set_last_known_monitors(None)
        with (
            patch("asus_hotkey_daemon_topology.detect_swap_topology_map", return_value=("all", monitors, "mutter")),
            patch.object(topology, "_thread_factory") as mock_thread,
            patch("asus_hotkey_daemon_topology.prime_gnome_window_swap_extension"),
        ):
            monitor.prime_topology_cache()
        self.assertEqual(hotkey_state.get_last_known_monitors(), monitors)
        self.assertEqual(hotkey_state.get_last_topology_source(), "mutter")
        self.assertTrue(hotkey_state.get_last_topology_refreshed_live())
        mock_thread.assert_not_called()

    def test_prime_topology_cache_schedules_when_detect_empty(self):
        """When sync detect fails, prime falls back to async refresh."""
        hotkey_state.set_last_known_monitors(None)
        with (
            patch(
                "asus_hotkey_daemon_topology.detect_swap_topology_map",
                return_value=(None, None, None),
            ) as detect,
            patch_sync_daemon_threads() as threads,
            patch("asus_hotkey_daemon_topology.time.sleep"),
            patch("asus_hotkey_daemon_topology.prime_gnome_window_swap_extension"),
        ):
            monitor.prime_topology_cache()
        # Two sync probes + one ImmediateThread worker probe.
        self.assertEqual(detect.call_count, 3)
        self.assertEqual(len(threads), 1)
        self.assertIsNone(hotkey_state.get_last_known_monitors())

    def test_prime_topology_cache_retries_then_seeds(self):
        """Prime must retry once when the first Mutter probe is empty."""
        monitors = [{"x": 0, "y": 0, "width": 100, "height": 100, "primary": True}]
        hotkey_state.set_last_known_monitors(None)
        with (
            patch(
                "asus_hotkey_daemon_topology.detect_swap_topology_map",
                side_effect=[(None, None, None), ("all", monitors, "mutter")],
            ),
            patch.object(topology, "_thread_factory") as mock_thread,
            patch("asus_hotkey_daemon_topology.time.sleep"),
            patch("asus_hotkey_daemon_topology.prime_gnome_window_swap_extension"),
        ):
            monitor.prime_topology_cache()
        self.assertEqual(hotkey_state.get_last_known_monitors(), monitors)
        mock_thread.assert_not_called()

    def test_perform_window_swap_keeps_step_when_move_fails(self):
        """Failed moves must not advance bounce step (first press looked like a no-op)."""
        monitors = [
            {"x": 0, "y": 0, "width": 1920, "height": 1080, "primary": True},
            {"x": 0, "y": 1080, "width": 1920, "height": 1080, "primary": False},
        ]
        self.addCleanup(monitor.reset_window_swap_state)
        hotkey_state.set_last_known_monitors(monitors)
        monitor.reset_window_swap_state()
        with (
            patch.object(window_swap, "_thread_factory"),
            patch("asus_hotkey_daemon_window_swap._apply_window_move", return_value=False),
        ):
            step = monitor.perform_window_swap(MagicMock(), 0)
        self.assertEqual(step, 0)

    def test_deferred_window_swap_commits_step_only_on_success(self):
        """Deferred detect+swap must commit next_step only after a successful move."""
        monitors = [
            {"x": 0, "y": 0, "width": 1920, "height": 1080, "primary": True},
            {"x": 0, "y": 1080, "width": 1920, "height": 1080, "primary": False},
        ]
        self.addCleanup(monitor.reset_window_swap_state)
        monitor.reset_window_swap_state()
        with (
            patch("asus_hotkey_daemon_window_swap._resolve_monitors_for_deferred_swap", return_value=monitors),
            patch("asus_hotkey_daemon_window_swap._apply_window_move", return_value=False),
        ):
            call_attr(window_swap, "_deferred_window_swap_worker", MagicMock(), 0)
        swap_state = monitor.get_window_swap_state()
        self.assertIsNone(swap_state.get("committed_step"))
        self.assertFalse(swap_state["in_flight"])

    def test_dbus_not_ready_uses_short_negative_ttl(self):
        """False readiness must expire quickly so the next press can re-probe."""
        self.assertEqual(call_attr(window_swap_gnome, "_gnome_window_swap_dbus_ready_ttl", True), 30)
        self.assertEqual(call_attr(window_swap_gnome, "_gnome_window_swap_dbus_ready_ttl", False), 0.5)

    def test_deferred_cached_swap_passes_usable_monitors(self):
        """When topology is already cached, defer must pass monitors (no re-detect)."""
        monitors = [
            {"x": 0, "y": 0, "width": 1920, "height": 1080, "primary": True},
            {"x": 0, "y": 1080, "width": 1920, "height": 1080, "primary": False},
        ]
        self.addCleanup(monitor.reset_window_swap_state)
        hotkey_state.set_last_known_monitors(monitors)
        monitor.reset_window_swap_state()
        with (
            patch("asus_hotkey_daemon_window_swap.desktop_family_hint", return_value="gnome"),
            patch("asus_hotkey_daemon_window_swap._gnome_window_swap_dbus_ready_fast", return_value=False),
            patch(
                "asus_hotkey_daemon_window_swap._start_deferred_window_swap_worker",
                return_value=True,
            ) as start_deferred,
        ):
            ui = MagicMock()
            step = call_attr(window_swap, "_run_cached_window_swap", ui, 0, monitors)
        start_deferred.assert_called_once_with(ui, 0, monitors)
        self.assertEqual(step, 0)

    def test_monitors_for_deferred_reuses_seed(self):
        """Usable seed monitors must skip off-thread topology detect."""
        monitors = [
            {"x": 0, "y": 0, "width": 1920, "height": 1080, "primary": True},
            {"x": 0, "y": 1080, "width": 1920, "height": 1080, "primary": False},
        ]
        with patch("asus_hotkey_daemon_window_swap._resolve_monitors_for_deferred_swap") as resolve:
            result = call_attr(window_swap, "_monitors_for_deferred_swap", monitors)
        self.assertEqual(result, monitors)
        resolve.assert_not_called()

    def test_usable_monitors_schedules_refresh_when_empty(self):
        """Empty cache must schedule async refresh via _refresh_monitors."""
        hotkey_state.set_last_known_monitors(None)
        with (
            patch("asus_hotkey_daemon_topology.detect_swap_topology_map", return_value=(None, None, None)),
            patch_sync_daemon_threads() as threads,
        ):
            result = call_attr(window_swap, "_usable_monitors_for_swap")
        self.assertIsNone(result)
        self.assertEqual(len(threads), 1)

    def test_perform_window_swap_defers_when_cache_empty(self):
        """Empty cache must start a deferred detect+swap worker (no event-thread sleep)."""
        self.addCleanup(monitor.reset_window_swap_state)
        hotkey_state.set_last_known_monitors(None)
        monitor.reset_window_swap_state()
        with (
            patch.object(topology, "_thread_factory") as mock_thread,
            patch("asus_hotkey_daemon_window_swap._start_deferred_window_swap_worker", return_value=True) as start_deferred,
        ):
            step = monitor.perform_window_swap(MagicMock(), 0)
        start_deferred.assert_called_once()
        mock_thread.assert_called_once()
        self.assertEqual(step, 0)

    def test_perform_window_swap_coalesces_pending_while_in_flight(self):
        """Overlapping presses must queue one pending swap and drain on clear."""
        monitor.reset_window_swap_state()
        self.addCleanup(monitor.reset_window_swap_state)
        ui = MagicMock()
        with patch("asus_hotkey_daemon_window_swap._claim_window_swap_slot", return_value=False):
            step = monitor.perform_window_swap(ui, 3)
        self.assertEqual(step, 3)
        self.assertEqual(monitor.get_window_swap_state().get("pending"), (ui, 3))
        with patch("asus_hotkey_daemon_window_swap._perform_window_swap") as mock_swap:
            call_attr(window_swap, "_clear_window_swap_in_flight")
        mock_swap.assert_called_once_with(ui, 3)
        swap_state = monitor.get_window_swap_state()
        self.assertIsNone(swap_state.get("pending"))
        self.assertFalse(swap_state["in_flight"])


if __name__ == "__main__":
    unittest.main()
