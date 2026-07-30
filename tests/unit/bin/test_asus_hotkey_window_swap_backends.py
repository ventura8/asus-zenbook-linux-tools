"""Unit tests for multi-DE window-swap topology and move backends."""

import importlib
import os
import subprocess
import tempfile
import time
import unittest
from unittest.mock import MagicMock, patch

from evdev import ecodes

from tests.unit.bin.attr_helpers import call_attr, get_attr
from tests.unit.bin.hotkey_daemon_test_utils import load_daemon

load_daemon()
daemon_runtime = importlib.import_module("asus_hotkey_daemon_runtime")
daemon_desktop_family = importlib.import_module("asus_hotkey_daemon_desktop_family")
daemon_session = importlib.import_module("asus_hotkey_daemon_session")
daemon_topology_detect = importlib.import_module("asus_hotkey_daemon_topology_detect")
daemon_window_swap = importlib.import_module("asus_hotkey_daemon_window_swap")
daemon_xrandr = importlib.import_module("asus_hotkey_daemon_xrandr")
hotkey_state = importlib.import_module("asus_hotkey_daemon_state")


class TestAsusHotkeyXrandrTopology(unittest.TestCase):
    """Cover xrandr topology parsing and Mutter→xrandr fallback."""

    def setUp(self):
        """Clear desktop-session cache so suite order cannot affect results."""
        hotkey_state.clear_desktop_user_cache()
        self.addCleanup(hotkey_state.clear_desktop_user_cache)

    def test_split_xrandr_geometry_valid_and_invalid(self):
        """Test WxH±X±Y parsing success and invalid fallback."""
        parsed = daemon_xrandr.split_xrandr_geometry("1920x1080+100+200")
        self.assertEqual(parsed["width"], 1920)
        self.assertEqual(parsed["x"], 100)
        self.assertEqual(parsed["y"], 200)
        parsed_neg = daemon_xrandr.split_xrandr_geometry("1920x1080-1920+0")
        self.assertEqual(parsed_neg["x"], -1920)
        self.assertEqual(parsed_neg["y"], 0)
        parsed_neg_y = daemon_xrandr.split_xrandr_geometry("1920x1080+0-1080")
        self.assertEqual(parsed_neg_y["x"], 0)
        self.assertEqual(parsed_neg_y["y"], -1080)
        self.assertIsNone(daemon_xrandr.split_xrandr_geometry("bad"))

    def test_find_xrandr_geometry_token(self):
        """Test geometry token discovery among xrandr line parts."""
        parts = ["HDMI-1", "connected", "primary", "1920x1080+0+0"]
        self.assertEqual(daemon_xrandr.find_xrandr_geometry_token(parts), "1920x1080+0+0")
        parts_neg = ["HDMI-1", "connected", "1920x1080-1920+0"]
        self.assertEqual(daemon_xrandr.find_xrandr_geometry_token(parts_neg), "1920x1080-1920+0")
        self.assertIsNone(daemon_xrandr.find_xrandr_geometry_token(["a", "b"]))

    def test_parse_xrandr_connected_line_variants(self):
        """Test connected-line parsing including primary and reject paths."""
        line = "eDP-1 connected primary 1920x1080+0+0 (normal)"
        parsed = daemon_xrandr.parse_xrandr_connected_line(line)
        self.assertTrue(parsed["primary"])
        self.assertIsNone(daemon_xrandr.parse_xrandr_connected_line("eDP-1 disconnected"))
        self.assertIsNone(daemon_xrandr.parse_xrandr_connected_line("a b"))

    def test_mark_first_monitor_primary_when_missing(self):
        """Test primary marker is forced onto the first monitor when absent."""
        monitors = [{"primary": False, "x": 0}, {"primary": False, "x": 1}]
        out = daemon_xrandr.mark_first_monitor_primary(monitors)
        self.assertTrue(out[0]["primary"])

    def test_parse_xrandr_topology_output_builds_map(self):
        """Test full xrandr --query text becomes a topology map."""
        text = "Screen 0: minimum 1 x 1\neDP-1 connected primary 1920x1080+0+0\nHDMI-1 connected 1920x1080+1920+0\nDP-1 disconnected\n"
        profile, monitors = daemon_xrandr.parse_xrandr_topology_output(text)
        self.assertIsNotNone(profile)
        self.assertEqual(len(monitors), 2)
        self.assertTrue(any(item["primary"] for item in monitors))
        self.assertEqual(daemon_xrandr.parse_xrandr_topology_output("no monitors"), (None, None))

    @patch("os.geteuid", return_value=1000)
    @patch("asus_hotkey_daemon_session._run_command")
    def test_detect_xrandr_topology_map_success_and_errors(self, mock_run, _mock_euid):
        """Test xrandr detector success, nonzero exit, and OSError paths."""
        mock_run.return_value = MagicMock(returncode=0, stdout="eDP-1 connected primary 800x600+0+0\n")
        detect_xrandr = get_attr(daemon_topology_detect, "_detect_xrandr_topology_map")
        profile, monitors = detect_xrandr()
        self.assertIsNotNone(profile)
        self.assertEqual(len(monitors), 1)
        mock_run.return_value = MagicMock(returncode=1, stdout="")
        self.assertEqual(detect_xrandr(), (None, None))
        mock_run.side_effect = OSError("gone")
        self.assertEqual(detect_xrandr(), (None, None))

    @patch("os.geteuid", return_value=1000)
    @patch("asus_hotkey_daemon_session._run_command")
    def test_detect_swap_topology_map_mutter_then_xrandr(self, mock_run, _mock_euid):
        """Test public detect_swap_topology_map prefers Mutter then xrandr."""
        mock_run.return_value = MagicMock(
            returncode=0, stdout='{"profile":"all","monitors":[{"x":0,"y":0,"width":1,"height":1,"primary":true}]}'
        )
        self.assertEqual(daemon_runtime.detect_swap_topology_map()[0], "all")
        mock_run.side_effect = [MagicMock(returncode=1, stdout=""), MagicMock(returncode=0, stdout="eDP-1 connected primary 800x600+0+0\n")]
        self.assertEqual(daemon_runtime.detect_swap_topology_map()[1][0]["x"], 0)
        mock_run.side_effect = None
        mock_run.return_value = MagicMock(returncode=1, stdout="")
        self.assertEqual(daemon_runtime.detect_swap_topology_map(), (None, None, None))
        self.assertEqual(daemon_runtime.detect_swap_topology_map(allow_xrandr=False), (None, None, None))


class TestAsusHotkeyWindowMoveBackends(unittest.TestCase):
    """Cover geometric window move helpers and desktop-family selection."""

    def setUp(self):
        """Clear desktop-session cache so suite order cannot affect results."""
        hotkey_state.clear_desktop_user_cache()
        self.addCleanup(hotkey_state.clear_desktop_user_cache)

    def test_neighbor_origin_for_direction(self):
        """Test neighbor origin lookup for a horizontal two-monitor layout."""
        monitors = [
            {"x": 0, "y": 0, "width": 100, "height": 100, "primary": True},
            {"x": 120, "y": 0, "width": 100, "height": 100, "primary": False},
        ]
        origin = call_attr(daemon_window_swap, "_neighbor_origin_for_direction", monitors, ecodes.KEY_RIGHT)
        self.assertEqual(origin, (120, 0))
        self.assertIsNone(call_attr(daemon_window_swap, "_neighbor_origin_for_direction", monitors[:1], ecodes.KEY_RIGHT))
        self.assertIsNone(call_attr(daemon_window_swap, "_neighbor_origin_for_direction", monitors, ecodes.KEY_UP))

    @patch("asus_hotkey_daemon_window_swap.shutil.which", return_value=None)
    def test_move_window_via_wmctrl_missing_binary(self, _mock_which):
        """Test wmctrl backend returns False when the binary is absent."""
        self.assertFalse(call_attr(daemon_window_swap, "_move_window_via_wmctrl", 1, 2))

    @patch("asus_hotkey_daemon_session._run_command")
    @patch("asus_hotkey_daemon_window_swap.shutil.which", return_value="/usr/bin/wmctrl")
    def test_move_window_via_wmctrl_success_and_errors(self, _mock_which, mock_run):
        """Test wmctrl success, nonzero exit, and exception paths."""
        mock_run.return_value = MagicMock(returncode=0)
        self.assertTrue(call_attr(daemon_window_swap, "_move_window_via_wmctrl", 10, 20))
        mock_run.return_value = MagicMock(returncode=1)
        self.assertFalse(call_attr(daemon_window_swap, "_move_window_via_wmctrl", 10, 20))
        mock_run.side_effect = OSError("fail")
        self.assertFalse(call_attr(daemon_window_swap, "_move_window_via_wmctrl", 10, 20))

    @patch("asus_hotkey_daemon_window_swap.shutil.which", return_value=None)
    def test_move_window_via_xdotool_missing_binary(self, _mock_which):
        """Test xdotool backend returns False when the binary is absent."""
        self.assertFalse(call_attr(daemon_window_swap, "_move_window_via_xdotool", 1, 2))

    @patch("asus_hotkey_daemon_session._run_command")
    @patch("asus_hotkey_daemon_window_swap.shutil.which", return_value="/usr/bin/xdotool")
    def test_move_window_via_xdotool_success_and_errors(self, _mock_which, mock_run):
        """Test xdotool success, nonzero exit, and timeout paths."""
        mock_run.return_value = MagicMock(returncode=0)
        self.assertTrue(call_attr(daemon_window_swap, "_move_window_via_xdotool", 3, 4))
        mock_run.return_value = MagicMock(returncode=2)
        self.assertFalse(call_attr(daemon_window_swap, "_move_window_via_xdotool", 3, 4))
        mock_run.side_effect = subprocess.TimeoutExpired(cmd="xdotool", timeout=2)
        self.assertFalse(call_attr(daemon_window_swap, "_move_window_via_xdotool", 3, 4))

    @patch("asus_hotkey_daemon_session._run_command")
    @patch("asus_hotkey_daemon_window_swap.shutil.which")
    def test_move_window_geometric_uses_xdotool_when_wmctrl_missing(self, mock_which, mock_run):
        """Test geometric move tries wmctrl then succeeds via xdotool."""

        def _which(name):
            return "/usr/bin/xdotool" if name == "xdotool" else None

        mock_which.side_effect = _which
        mock_run.return_value = MagicMock(returncode=0)
        monitors = [
            {"x": 0, "y": 0, "width": 100, "height": 100, "primary": True},
            {"x": 120, "y": 0, "width": 100, "height": 100, "primary": False},
        ]
        self.assertTrue(call_attr(daemon_window_swap, "_move_window_geometric", monitors, ecodes.KEY_RIGHT))
        self.assertFalse(call_attr(daemon_window_swap, "_move_window_geometric", monitors, ecodes.KEY_UP))

    def test_family_from_desktop_string_and_hint(self):
        """Test desktop family token mapping and ASUS_DESKTOP_FAMILY override."""
        family_from_desktop = get_attr(daemon_desktop_family, "_family_from_desktop_string")
        self.assertEqual(family_from_desktop("X-Cinnamon:XFCE"), "xfce")
        self.assertEqual(family_from_desktop("X-Cinnamon"), "cinnamon")
        self.assertEqual(family_from_desktop("MATE"), "mate")
        self.assertEqual(family_from_desktop("KDE:Plasma"), "kde")
        self.assertEqual(family_from_desktop("LXQt:ubuntu"), "lxqt")
        self.assertEqual(family_from_desktop("ubuntu:GNOME"), "gnome")
        self.assertEqual(family_from_desktop("i3"), "other")
        with patch.dict("os.environ", {"ASUS_DESKTOP_FAMILY": "kde"}, clear=False):
            self.assertEqual(daemon_runtime.desktop_family_hint(), "kde")
        with (
            patch.dict("os.environ", {"ASUS_DESKTOP_FAMILY": "", "XDG_CURRENT_DESKTOP": "XFCE"}, clear=False),
            patch("asus_hotkey_daemon_desktop_family.hotkey_state.get_desktop_user_session_env", return_value={}),
        ):
            self.assertEqual(daemon_runtime.desktop_family_hint(), "xfce")
        with (
            patch.dict("os.environ", {"ASUS_DESKTOP_FAMILY": "", "XDG_CURRENT_DESKTOP": "LXQt"}, clear=False),
            patch("asus_hotkey_daemon_desktop_family.hotkey_state.get_desktop_user_session_env", return_value={}),
        ):
            self.assertEqual(daemon_runtime.desktop_family_hint(), "lxqt")
        with (
            patch.dict("os.environ", {"ASUS_DESKTOP_FAMILY": "", "XDG_CURRENT_DESKTOP": "ubuntu:GNOME"}, clear=False),
            patch(
                "asus_hotkey_daemon_desktop_family.hotkey_state.get_desktop_user_session_env", return_value={"XDG_CURRENT_DESKTOP": "KDE"}
            ),
        ):
            self.assertEqual(daemon_runtime.desktop_family_hint(), "kde")

    def test_mint_bare_gnome_heuristics_remap(self):
        """Bare ubuntu:GNOME remaps to cinnamon/mate via secondary session hints."""
        clear_cache = get_attr(daemon_runtime, "clear_mint_bare_gnome_cache")
        clear_cache()
        self.addCleanup(clear_cache)
        session_env = {
            "XDG_CURRENT_DESKTOP": "ubuntu:GNOME",
            "XDG_SESSION_DESKTOP": "cinnamon",
        }
        with (
            patch.dict("os.environ", {"ASUS_DESKTOP_FAMILY": "", "XDG_CURRENT_DESKTOP": "ubuntu:GNOME"}, clear=False),
            patch(
                "asus_hotkey_daemon_desktop_family.hotkey_state.get_desktop_user_session_env",
                return_value=session_env,
            ),
        ):
            self.assertEqual(daemon_runtime.desktop_family_hint(), "cinnamon")
        clear_cache()
        mate_env = {
            "XDG_CURRENT_DESKTOP": "GNOME",
            "DESKTOP_SESSION": "mate",
        }
        with (
            patch.dict("os.environ", {"ASUS_DESKTOP_FAMILY": "", "XDG_CURRENT_DESKTOP": "GNOME"}, clear=False),
            patch(
                "asus_hotkey_daemon_desktop_family.hotkey_state.get_desktop_user_session_env",
                return_value=mate_env,
            ),
        ):
            self.assertEqual(daemon_runtime.desktop_family_hint(), "mate")
        clear_cache()
        with (
            patch.dict("os.environ", {"ASUS_DESKTOP_FAMILY": "", "XDG_CURRENT_DESKTOP": "ubuntu:GNOME"}, clear=False),
            patch(
                "asus_hotkey_daemon_desktop_family.hotkey_state.get_desktop_user_session_env",
                return_value={"XDG_CURRENT_DESKTOP": "ubuntu:GNOME"},
            ),
            patch("asus_hotkey_daemon_desktop_family._probe_de_binary_family", return_value=""),
            patch("asus_hotkey_daemon_desktop_family._probe_de_schema_family", return_value=""),
        ):
            self.assertEqual(daemon_runtime.desktop_family_hint(), "gnome")

    def test_mint_bare_gnome_binary_and_schema_probes(self):
        """Binary and gsettings schema probes remap bare GNOME without session tokens."""
        clear_cache = get_attr(daemon_runtime, "clear_mint_bare_gnome_cache")
        clear_cache()
        self.addCleanup(clear_cache)
        with (
            patch.dict("os.environ", {"ASUS_DESKTOP_FAMILY": "", "XDG_CURRENT_DESKTOP": "GNOME"}, clear=False),
            patch(
                "asus_hotkey_daemon_desktop_family.hotkey_state.get_desktop_user_session_env",
                return_value={"XDG_CURRENT_DESKTOP": "GNOME"},
            ),
            patch("asus_hotkey_daemon_desktop_family._executable_path", side_effect=lambda p: p.endswith("/cinnamon")),
        ):
            self.assertEqual(daemon_runtime.desktop_family_hint(), "cinnamon")
        clear_cache()
        with (
            patch.dict("os.environ", {"ASUS_DESKTOP_FAMILY": "", "XDG_CURRENT_DESKTOP": "GNOME"}, clear=False),
            patch(
                "asus_hotkey_daemon_desktop_family.hotkey_state.get_desktop_user_session_env",
                return_value={"XDG_CURRENT_DESKTOP": "GNOME"},
            ),
            patch(
                "asus_hotkey_daemon_desktop_family._executable_path",
                side_effect=lambda p: p.endswith("mate-session"),
            ),
        ):
            self.assertEqual(daemon_runtime.desktop_family_hint(), "mate")
        clear_cache()
        schemas = {
            "org.cinnamon.desktop.keybindings",
            "org.gnome.desktop.interface",
        }
        with (
            patch.dict("os.environ", {"ASUS_DESKTOP_FAMILY": "", "XDG_CURRENT_DESKTOP": "GNOME"}, clear=False),
            patch(
                "asus_hotkey_daemon_desktop_family.hotkey_state.get_desktop_user_session_env",
                return_value={"XDG_CURRENT_DESKTOP": "GNOME"},
            ),
            patch("asus_hotkey_daemon_desktop_family._probe_de_binary_family", return_value=""),
            patch("asus_hotkey_daemon_desktop_family._gsettings_schema_names", return_value=schemas),
        ):
            self.assertEqual(daemon_runtime.desktop_family_hint(), "cinnamon")
        clear_cache()
        mate_schemas = {"org.mate.control-center.keybinding"}
        with (
            patch.dict("os.environ", {"ASUS_DESKTOP_FAMILY": "", "XDG_CURRENT_DESKTOP": "GNOME"}, clear=False),
            patch(
                "asus_hotkey_daemon_desktop_family.hotkey_state.get_desktop_user_session_env",
                return_value={"XDG_CURRENT_DESKTOP": "GNOME"},
            ),
            patch("asus_hotkey_daemon_desktop_family._probe_de_binary_family", return_value=""),
            patch("asus_hotkey_daemon_desktop_family._gsettings_schema_names", return_value=mate_schemas),
        ):
            self.assertEqual(daemon_runtime.desktop_family_hint(), "mate")
        self.assertFalse(call_attr(daemon_desktop_family, "_executable_path", "/nope-$$"))
        with patch("asus_hotkey_daemon_desktop_family.shutil.which", return_value=None):
            self.assertIsNone(call_attr(daemon_desktop_family, "_gsettings_schema_names"))
            self.assertEqual(call_attr(daemon_desktop_family, "_probe_de_schema_family"), "")
        with patch("asus_hotkey_daemon_desktop_family.shutil.which", return_value="/usr/bin/gsettings"):
            with patch(
                "asus_hotkey_daemon_desktop_family.subprocess.run",
                side_effect=OSError("no gsettings bus"),
            ):
                self.assertIsNone(call_attr(daemon_desktop_family, "_gsettings_schema_names"))
            with patch(
                "asus_hotkey_daemon_desktop_family.subprocess.run",
                return_value=MagicMock(stdout="org.mate.control-center.keybinding\n"),
            ):
                names = call_attr(daemon_desktop_family, "_gsettings_schema_names")
        self.assertIn("org.mate.control-center.keybinding", names)

    @patch("asus_hotkey_daemon_session._run_command")
    @patch("asus_hotkey_daemon_window_swap.shutil.which", return_value="/usr/bin/wmctrl")
    def test_apply_window_move_kde_geometric(self, _mock_which, mock_run):
        """Test KDE prefers geometric move via wmctrl when available."""
        mock_run.return_value = MagicMock(returncode=0)
        ui = MagicMock()
        monitors = [
            {"x": 0, "y": 0, "width": 100, "height": 100, "primary": True},
            {"x": 120, "y": 0, "width": 100, "height": 100, "primary": False},
        ]
        with patch.dict("os.environ", {"ASUS_DESKTOP_FAMILY": "kde"}, clear=False):
            self.assertTrue(call_attr(daemon_window_swap, "_apply_window_move", ui, monitors, ecodes.KEY_RIGHT))
        mock_run.assert_called()
        ui.write.assert_not_called()

    @patch("asus_hotkey_daemon_session._run_command")
    @patch("asus_hotkey_daemon_window_swap.shutil.which", return_value="/usr/bin/wmctrl")
    def test_apply_window_move_lxqt_geometric(self, _mock_which, mock_run):
        """Test LXQt prefers geometric move via wmctrl (never uinput chords)."""
        mock_run.return_value = MagicMock(returncode=0)
        ui = MagicMock()
        monitors = [
            {"x": 0, "y": 0, "width": 100, "height": 100, "primary": True},
            {"x": 120, "y": 0, "width": 100, "height": 100, "primary": False},
        ]
        with patch.dict("os.environ", {"ASUS_DESKTOP_FAMILY": "lxqt"}, clear=False):
            self.assertTrue(call_attr(daemon_window_swap, "_apply_window_move", ui, monitors, ecodes.KEY_RIGHT))
        mock_run.assert_called()
        ui.write.assert_not_called()
        with patch.dict("os.environ", {"ASUS_DESKTOP_FAMILY": "lxqt"}, clear=False):
            self.assertTrue(call_attr(daemon_window_swap, "_should_defer_cached_window_swap"))

    @patch("asus_hotkey_daemon_window_swap.shutil.which", return_value=None)
    def test_lxqt_never_uses_gnome_extension_or_uinput(self, _mock_which):
        """LXQt must fail closed on missing tools — no Shell extension or uinput."""
        ui = MagicMock()
        monitors = [
            {"x": 0, "y": 0, "width": 100, "height": 100, "primary": True},
            {"x": 120, "y": 0, "width": 100, "height": 100, "primary": False},
        ]
        with (
            patch.dict("os.environ", {"ASUS_DESKTOP_FAMILY": "lxqt"}, clear=False),
            patch("asus_hotkey_daemon_window_swap._apply_gnome_window_move") as gnome_move,
            patch("asus_hotkey_daemon_window_swap.prime_gnome_window_swap_extension") as prime_ext,
            patch("asus_hotkey_daemon_window_swap._emit_window_move") as emit_chord,
        ):
            moved = call_attr(daemon_window_swap, "_apply_window_move", ui, monitors, ecodes.KEY_RIGHT)
        self.assertFalse(moved)
        ui.write.assert_not_called()
        gnome_move.assert_not_called()
        prime_ext.assert_not_called()
        emit_chord.assert_not_called()

    @patch("asus_hotkey_daemon_window_swap.shutil.which", return_value=None)
    def test_cinnamon_never_uses_gnome_extension_or_uinput(self, _mock_which):
        """Cinnamon must fail closed on missing tools — no Shell extension or uinput."""
        ui = MagicMock()
        monitors = [
            {"x": 0, "y": 0, "width": 100, "height": 100, "primary": True},
            {"x": 120, "y": 0, "width": 100, "height": 100, "primary": False},
        ]
        with (
            patch.dict("os.environ", {"ASUS_DESKTOP_FAMILY": "cinnamon"}, clear=False),
            patch("asus_hotkey_daemon_window_swap._apply_gnome_window_move") as gnome_move,
            patch("asus_hotkey_daemon_window_swap.prime_gnome_window_swap_extension") as prime_ext,
            patch("asus_hotkey_daemon_window_swap._emit_window_move") as emit_chord,
        ):
            moved = call_attr(daemon_window_swap, "_apply_window_move", ui, monitors, ecodes.KEY_RIGHT)
        self.assertFalse(moved)
        ui.write.assert_not_called()
        gnome_move.assert_not_called()
        prime_ext.assert_not_called()
        emit_chord.assert_not_called()

    @patch("asus_hotkey_daemon_window_swap.shutil.which", return_value=None)
    def test_mate_never_uses_gnome_extension_or_uinput(self, _mock_which):
        """MATE must fail closed on missing tools — no Shell extension or uinput."""
        ui = MagicMock()
        monitors = [
            {"x": 0, "y": 0, "width": 100, "height": 100, "primary": True},
            {"x": 120, "y": 0, "width": 100, "height": 100, "primary": False},
        ]
        with (
            patch.dict("os.environ", {"ASUS_DESKTOP_FAMILY": "mate"}, clear=False),
            patch("asus_hotkey_daemon_window_swap._apply_gnome_window_move") as gnome_move,
            patch("asus_hotkey_daemon_window_swap.prime_gnome_window_swap_extension") as prime_ext,
            patch("asus_hotkey_daemon_window_swap._emit_window_move") as emit_chord,
        ):
            moved = call_attr(daemon_window_swap, "_apply_window_move", ui, monitors, ecodes.KEY_RIGHT)
        self.assertFalse(moved)
        ui.write.assert_not_called()
        gnome_move.assert_not_called()
        prime_ext.assert_not_called()
        emit_chord.assert_not_called()

    @patch("asus_hotkey_daemon_session._run_command")
    @patch("asus_hotkey_daemon_window_swap.shutil.which", return_value="/usr/bin/wmctrl")
    def test_apply_window_move_cinnamon_geometric(self, _mock_which, mock_run):
        """Cinnamon uses wmctrl geometric move — never Shell extension/uinput."""
        mock_run.return_value = MagicMock(returncode=0)
        ui = MagicMock()
        monitors = [
            {"x": 0, "y": 0, "width": 100, "height": 100, "primary": True},
            {"x": 120, "y": 0, "width": 100, "height": 100, "primary": False},
        ]
        with patch.dict("os.environ", {"ASUS_DESKTOP_FAMILY": "cinnamon"}, clear=False):
            self.assertTrue(call_attr(daemon_window_swap, "_apply_window_move", ui, monitors, ecodes.KEY_RIGHT))
            self.assertTrue(call_attr(daemon_window_swap, "_should_defer_cached_window_swap"))
        mock_run.assert_called()
        ui.write.assert_not_called()

    @patch("asus_hotkey_daemon_session._run_command")
    @patch("asus_hotkey_daemon_window_swap.shutil.which", return_value="/usr/bin/wmctrl")
    def test_apply_window_move_mate_geometric(self, _mock_which, mock_run):
        """MATE uses wmctrl geometric move — never Shell extension/uinput."""
        mock_run.return_value = MagicMock(returncode=0)
        ui = MagicMock()
        monitors = [
            {"x": 0, "y": 0, "width": 100, "height": 100, "primary": True},
            {"x": 120, "y": 0, "width": 100, "height": 100, "primary": False},
        ]
        with patch.dict("os.environ", {"ASUS_DESKTOP_FAMILY": "mate"}, clear=False):
            self.assertTrue(call_attr(daemon_window_swap, "_apply_window_move", ui, monitors, ecodes.KEY_RIGHT))
            self.assertTrue(call_attr(daemon_window_swap, "_should_defer_cached_window_swap"))
        mock_run.assert_called()
        ui.write.assert_not_called()

    @patch("asus_hotkey_daemon_window_swap.shutil.which", return_value=None)
    def test_apply_window_move_falls_back_to_chord(self, _mock_which):
        """Test chord emission when geometric tools are unavailable."""
        ui = MagicMock()
        with patch.dict("os.environ", {"ASUS_DESKTOP_FAMILY": "gnome"}, clear=False):
            self.assertTrue(call_attr(daemon_window_swap, "_apply_window_move", ui, [], ecodes.KEY_DOWN))
        self.assertTrue(ui.write.called)


class TestAsusHotkeyRuntimeSessionEnv(unittest.TestCase):
    """Cover remaining runtime session/env helper branches for coverage."""

    def setUp(self):
        """Import runtime and clear desktop-user cache."""
        self.runtime = importlib.import_module("asus_hotkey_daemon_runtime")
        self.session = importlib.import_module("asus_hotkey_daemon_session")
        hotkey_state.clear_desktop_user_cache()
        self.addCleanup(hotkey_state.clear_desktop_user_cache)

    def test_exec_script_oserror_is_logged(self):
        """Test helper script OSError path logs a warning."""
        with (
            patch("asus_hotkey_daemon_runtime.subprocess.run", side_effect=OSError("gone")),
            self.assertLogs("asus_hotkey_daemon_runtime", level="WARNING"),
        ):
            call_attr(self.runtime, "_exec_script", "/missing-helper")

    def test_loginctl_show_session_value_errors(self):
        """Test loginctl property helper handles timeout and nonzero exit."""
        with patch("asus_hotkey_daemon_session.subprocess.run", side_effect=subprocess.TimeoutExpired(cmd="loginctl", timeout=1)):
            self.assertIsNone(call_attr(self.session, "_loginctl_show_session_value", "1", "Type"))
        with patch("asus_hotkey_daemon_session.subprocess.run", return_value=MagicMock(returncode=1, stdout="")):
            self.assertIsNone(call_attr(self.session, "_loginctl_show_session_value", "1", "Type"))

    def test_cached_desktop_user_valid_expiry_and_inactive(self):
        """Test cache validation rejects expired and inactive sessions."""
        cached = (1000, "user", "1", 0.0)
        self.assertIsNone(call_attr(self.session, "_cached_desktop_user_valid", cached))
        inactive_stdout = "State=closing\nType=x11\n"
        hotkey_state.set_desktop_user_cache(1000, "user", "1", time.monotonic() + 60, {"session_env": {"DISPLAY": ":0"}})
        with patch("asus_hotkey_daemon_session.subprocess.run", return_value=MagicMock(returncode=0, stdout=inactive_stdout)):
            cached_live = (1000, "user", "1", time.monotonic() + 60)
            self.assertIsNone(call_attr(self.session, "_cached_desktop_user_valid", cached_live))

    def test_read_proc_environ_value_from_temp_file(self):
        """Test /proc environ reader via ASUS_PROC_ENVIRON_ROOT override."""
        with tempfile.TemporaryDirectory() as tmp:
            pid_dir = os.path.join(tmp, "1")
            os.makedirs(pid_dir)
            path = os.path.join(pid_dir, "environ")
            with open(path, "wb") as handle:
                handle.write(b"DISPLAY=:1\x00WAYLAND_DISPLAY=wayland-0\x00")
            with patch.dict("os.environ", {"ASUS_PROC_ENVIRON_ROOT": tmp}, clear=False):
                self.assertEqual(call_attr(self.session, "_read_proc_environ_value", 1, "DISPLAY"), ":1")
                self.assertIsNone(call_attr(self.session, "_read_proc_environ_value", 1, "MISSING"))
            with patch.dict("os.environ", {"ASUS_PROC_ENVIRON_ROOT": "/missing"}, clear=False):
                self.assertIsNone(call_attr(self.session, "_read_proc_environ_value", 1, "DISPLAY"))

    def test_session_leader_and_merge_environ(self):
        """Test leader PID parsing and environ merge helpers."""
        with patch.object(self.session, "_loginctl_show_session_value", return_value="abc"):
            self.assertIsNone(call_attr(self.session, "_session_leader_pid", "1"))
        with patch.object(self.session, "_loginctl_show_session_value", return_value="42"):
            self.assertEqual(call_attr(self.session, "_session_leader_pid", "1"), 42)
        env = {"XDG_RUNTIME_DIR": "/run/user/1"}
        self.assertIs(call_attr(self.session, "_merge_leader_environ", env, None), env)
        with patch.object(self.session, "_read_proc_environ_value", return_value=":0"):
            out = call_attr(self.session, "_merge_leader_environ", {}, 7)
            self.assertEqual(out.get("DISPLAY"), ":0")

    def test_desktop_session_env_sets_type(self):
        """Test desktop session env includes Type when loginctl returns it."""
        with (
            patch.object(self.session, "_loginctl_show_session_value", return_value="wayland"),
            patch.object(self.session, "_session_leader_pid", return_value=None),
            patch.object(self.session, "_merge_systemctl_environ", side_effect=lambda env, *_a, **_k: env),
        ):
            env = call_attr(self.session, "_desktop_session_env", 1000, "1", "alice")
        self.assertEqual(env.get("XDG_SESSION_TYPE"), "wayland")

    def test_merge_systemctl_environ_fills_display(self):
        """Leader-empty sessions still pick up DISPLAY from systemctl --user."""
        env = {"XDG_RUNTIME_DIR": "/run/user/1000"}
        blob = "DISPLAY=:0\nWAYLAND_DISPLAY=wayland-0\n"
        with patch.object(self.session, "_fetch_systemctl_user_env_blob", return_value=blob):
            out = call_attr(self.session, "_merge_systemctl_environ", env, "alice", 1000)
        self.assertEqual(out.get("DISPLAY"), ":0")
        self.assertEqual(out.get("WAYLAND_DISPLAY"), "wayland-0")

    def test_cached_desktop_user_invalid_without_display(self):
        """Cache entries missing DISPLAY/WAYLAND must not be reused."""
        hotkey_state.clear_desktop_user_cache()
        hotkey_state.set_desktop_user_cache(
            1000,
            "alice",
            "42",
            time.monotonic() + 60,
            {"session_env": {"XDG_RUNTIME_DIR": "/run/user/1000"}},
        )
        cached = hotkey_state.get_desktop_user_cache()
        cached_valid = get_attr(self.session, "_cached_desktop_user_valid")
        self.assertIsNone(cached_valid(cached))
        hotkey_state.clear_desktop_user_cache()


if __name__ == "__main__":
    unittest.main()
