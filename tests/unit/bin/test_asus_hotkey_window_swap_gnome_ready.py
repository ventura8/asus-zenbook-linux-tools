"""GNOME Window Swap D-Bus readiness and priming unit tests."""

import importlib
import unittest
from unittest.mock import MagicMock, patch

from tests.unit.bin.attr_helpers import call_attr, get_attr

window_swap_gnome = importlib.import_module("asus_hotkey_daemon_window_swap_gnome")


class TestAsusHotkeyWindowSwapGnomeReady(unittest.TestCase):
    """D-Bus readiness cache, CLI enable, and prime paths for GNOME swap."""

    def setUp(self):
        """Clear readiness cache between cases."""
        call_attr(window_swap_gnome, "_gnome_window_swap_dbus_cache_set", None, 0.0)

    def test_dbus_ready_cache_hit_and_fast_miss(self):
        """Cache hits return stored readiness; misses stay false on the fast path."""
        call_attr(window_swap_gnome, "_gnome_window_swap_dbus_cache_set", True, 1e18)
        self.assertTrue(call_attr(window_swap_gnome, "_gnome_window_swap_dbus_ready_fast"))
        call_attr(window_swap_gnome, "_gnome_window_swap_dbus_cache_set", False, 1e18)
        self.assertFalse(call_attr(window_swap_gnome, "_gnome_window_swap_dbus_ready_fast"))
        call_attr(window_swap_gnome, "_gnome_window_swap_dbus_cache_set", None, 0.0)
        self.assertFalse(call_attr(window_swap_gnome, "_gnome_window_swap_dbus_ready_fast"))
        self.assertEqual(call_attr(window_swap_gnome, "_gnome_window_swap_dbus_ready_ttl", True), 30)
        self.assertEqual(call_attr(window_swap_gnome, "_gnome_window_swap_dbus_ready_ttl", False), 0.5)

    @patch("asus_hotkey_daemon_window_swap_gnome._mutter_window_swap_call", return_value=0)
    def test_dbus_ready_probe_caches_true(self, _probe):
        """Successful GetFocusedMonitor probe caches ready=True."""
        self.assertTrue(call_attr(window_swap_gnome, "_gnome_window_swap_dbus_ready", attempts=1))
        self.assertTrue(call_attr(window_swap_gnome, "_gnome_window_swap_dbus_ready_fast"))

    @patch("asus_hotkey_daemon_window_swap_gnome._mutter_window_swap_call", return_value=None)
    def test_dbus_ready_probe_caches_false(self, _probe):
        """Failed probe caches ready=False with a short TTL."""
        self.assertFalse(call_attr(window_swap_gnome, "_gnome_window_swap_dbus_ready", attempts=1))
        self.assertFalse(call_attr(window_swap_gnome, "_gnome_window_swap_dbus_ready_fast"))

    @patch("asus_hotkey_daemon_window_swap_gnome.run_in_desktop_session")
    def test_run_gnome_session_cli_status_paths(self, mock_run):
        """Session CLI helper honors OSError/timeout and nonzero exits."""
        mock_run.side_effect = OSError("no session")
        self.assertFalse(call_attr(window_swap_gnome, "_run_gnome_session_cli", ["true"], 1))
        mock_run.side_effect = None
        mock_run.return_value = MagicMock(returncode=1)
        self.assertFalse(call_attr(window_swap_gnome, "_run_gnome_session_cli", ["false"], 1))
        mock_run.return_value = MagicMock(returncode=0)
        self.assertTrue(call_attr(window_swap_gnome, "_run_gnome_session_cli", ["true"], 1))

    @patch("asus_hotkey_daemon_window_swap_gnome.shutil.which", return_value=None)
    @patch("asus_hotkey_daemon_window_swap_gnome._run_gnome_session_cli", return_value=True)
    def test_enable_via_cli_requires_gnome_extensions(self, _cli, _which):
        """Enable fails closed when gnome-extensions is absent."""
        self.assertFalse(call_attr(window_swap_gnome, "_enable_gnome_window_swap_via_cli"))

    @patch("asus_hotkey_daemon_window_swap_gnome.time.sleep")
    @patch("asus_hotkey_daemon_window_swap_gnome._gnome_window_swap_dbus_ready", return_value=False)
    def test_wait_ready_deadline_expires(self, _ready, _sleep):
        """Wait loop returns False when readiness never appears before deadline."""
        with patch("asus_hotkey_daemon_window_swap_gnome.time.monotonic", side_effect=[0.0, 0.05, 3.0]):
            self.assertFalse(call_attr(window_swap_gnome, "_wait_gnome_window_swap_dbus_ready"))

    @patch("asus_hotkey_daemon_window_swap_gnome.desktop_family_hint", return_value="kde")
    def test_prime_skips_non_gnome(self, _family):
        """Priming is a no-op outside GNOME."""
        call_attr(window_swap_gnome, "prime_gnome_window_swap_extension")

    @patch("asus_hotkey_daemon_window_swap_gnome._wait_gnome_window_swap_dbus_ready")
    @patch("asus_hotkey_daemon_window_swap_gnome._enable_gnome_window_swap_via_cli", return_value=True)
    @patch("asus_hotkey_daemon_window_swap_gnome._gnome_window_swap_dbus_ready", return_value=False)
    @patch("asus_hotkey_daemon_window_swap_gnome.desktop_family_hint", return_value="gnome")
    def test_prime_enables_then_waits(self, _family, _ready, enable_cli, wait_ready):
        """When D-Bus is absent, prime enables via CLI then waits briefly."""
        call_attr(window_swap_gnome, "prime_gnome_window_swap_extension")
        enable_cli.assert_called_once()
        wait_ready.assert_called_once()

    def test_list_index_for_mutter_index(self):
        """Mutter index maps to topology list index when present."""
        monitors = [{"index": 2}, {"index": 5}]
        self.assertEqual(call_attr(window_swap_gnome, "_list_index_for_mutter_index", monitors, 5), 1)
        self.assertIsNone(call_attr(window_swap_gnome, "_list_index_for_mutter_index", monitors, 9))
        uuid = get_attr(window_swap_gnome, "_GNOME_WINDOW_SWAP_UUID")
        self.assertIn("asus-window-swap@", uuid)
