"""Unit tests for the display-mode backend."""

import io
import sys
import unittest
from unittest.mock import MagicMock, patch

from tests.unit.bin.display_mode_test_utils import (
    assert_display_mode_main_applies,
    four_monitor_topology_state,
    load_asus_display_mode_core_module,
    load_asus_display_mode_module,
    patch_mutter_display_config,
    run_display_mode_main_reject,
    sample_builtin_screenpad_state,
)

asus_display_mode = load_asus_display_mode_module()
asus_display_mode_core = load_asus_display_mode_core_module()


class TestAsusDisplayModePy(unittest.TestCase):
    """Test suite for asus-display-mode.py module."""

    def test_classify_monitor_groups(self):
        """Test grouping of main, ScreenPad, and external monitors."""
        physical_monitors = [
            (
                ("DP-3", "BOE", "0x085f"),
                [("3840x1100@60.017", 3840, 1100, 60.0, 2.0, [], {"is-preferred": True})],
                {"is-builtin": False},
            ),
            (
                ("HDMI-1", "DELL", "0x1111"),
                [("2560x1440@60.000", 2560, 1440, 60.0, 1.0, [], {"is-current": True})],
                {"is-builtin": False},
            ),
            (
                ("eDP-1", "SDC", "0x415f"),
                [("3840x2160@60.000", 3840, 2160, 60.0, 2.0, [], {"is-current": True})],
                {"is-builtin": True},
            ),
        ]
        groups = asus_display_mode.classify_monitor_groups(physical_monitors)
        self.assertEqual(groups["main"]["connector"], "eDP-1")
        self.assertEqual(groups["screenpad"]["connector"], "DP-3")
        self.assertEqual(len(groups["externals"]), 1)
        self.assertEqual(groups["externals"][0]["connector"], "HDMI-1")

    def test_available_profiles_with_screenpad_and_external(self):
        """Test deterministic profile order for main + ScreenPad + external topology."""
        groups = {
            "main": {"connector": "eDP-1", "mode": "m1"},
            "screenpad": {"connector": "DP-3", "mode": "m2"},
            "externals": [{"connector": "HDMI-1", "mode": "m3"}],
        }
        profiles = asus_display_mode.available_profiles(groups)
        self.assertEqual(
            profiles,
            [
                asus_display_mode.PROFILE_ALL,
                asus_display_mode.PROFILE_MAIN_EXTERNAL,
                asus_display_mode.PROFILE_SCREENPAD_EXTERNAL,
                asus_display_mode.PROFILE_MAIN_ONLY,
                asus_display_mode.PROFILE_SCREENPAD_ONLY,
                asus_display_mode.PROFILE_EXTERNAL_ONLY,
            ],
        )

    def test_build_logical_monitors_uses_profile_targets(self):
        """Test building logical monitor config for profile-based modes."""
        groups = {
            "main": {"connector": "eDP-1", "mode": "3840x2160@60.000"},
            "screenpad": {"connector": "DP-3", "mode": "3840x1100@60.017"},
            "externals": [{"connector": "HDMI-1", "mode": "2560x1440@60.000"}],
        }
        all_layout = asus_display_mode.build_logical_monitors(asus_display_mode.PROFILE_ALL, groups)
        self.assertEqual(len(all_layout), 3)

        main_external = asus_display_mode.build_logical_monitors(asus_display_mode.PROFILE_MAIN_EXTERNAL, groups)
        self.assertEqual(len(main_external), 2)

        screenpad_only = asus_display_mode.build_logical_monitors(asus_display_mode.PROFILE_SCREENPAD_ONLY, groups)
        self.assertEqual(len(screenpad_only), 1)
        self.assertEqual(screenpad_only[0][5][0][0], "DP-3")

        external_only = asus_display_mode.build_logical_monitors(asus_display_mode.PROFILE_EXTERNAL_ONLY, groups)
        self.assertEqual(len(external_only), 1)
        self.assertEqual(external_only[0][5][0][0], "HDMI-1")

    def test_build_logical_monitors_computes_adjacent_offsets(self):
        """Test profile layouts use mode-derived adjacent Y offsets."""
        groups = {
            "main": {"connector": "eDP-1", "mode": "3840x2160@60.000", "scale": 2.0},
            "screenpad": {
                "connector": "DP-3",
                "mode": "3840x1100@60.017",
                "scale": 2.0,
            },
            "externals": [{"connector": "HDMI-1", "mode": "2560x1440@60.000", "scale": 1.0}],
        }
        layout = asus_display_mode.build_logical_monitors(asus_display_mode.PROFILE_SCREENPAD_EXTERNAL, groups)
        self.assertEqual(layout[0][1], 0)
        self.assertEqual(layout[1][1], 1100)

    def test_detect_current_profile_exact_match(self):
        """Test profile detection from active logical monitor connector set."""
        groups = {
            "main": {"connector": "eDP-1", "mode": "m1"},
            "screenpad": {"connector": "DP-3", "mode": "m2"},
            "externals": [{"connector": "HDMI-1", "mode": "m3"}],
        }
        logical_monitors = [
            (0, 0, 2.0, 0, True, [("eDP-1", "m1", {})]),
            (0, 1080, 2.0, 0, False, [("HDMI-1", "m3", {})]),
        ]
        detected = asus_display_mode.detect_current_profile(logical_monitors, groups)
        self.assertEqual(detected, asus_display_mode.PROFILE_MAIN_EXTERNAL)

    def test_get_next_profile_wraps(self):
        """Test profile cycle wraps correctly at the end of available profile order."""
        groups = {
            "main": {"connector": "eDP-1", "mode": "m1"},
            "screenpad": {"connector": "DP-3", "mode": "m2"},
            "externals": [],
        }
        nxt = asus_display_mode.get_next_profile(asus_display_mode.PROFILE_SCREENPAD_ONLY, groups)
        self.assertEqual(nxt, asus_display_mode.PROFILE_ALL)

    def test_format_profile_label_external_count(self):
        """Test context-aware profile labels include external display count."""
        groups = {
            "main": {"connector": "eDP-1", "mode": "m1"},
            "screenpad": {"connector": "DP-3", "mode": "m2"},
            "externals": [
                {"connector": "HDMI-1", "mode": "m3"},
                {"connector": "DP-1", "mode": "m4"},
            ],
        }
        label = asus_display_mode.format_profile_label(asus_display_mode.PROFILE_ALL, groups)
        self.assertEqual(
            label,
            "All displays (Main display + ScreenPad + 2 external displays)",
        )

        external_only = asus_display_mode.format_profile_label(
            asus_display_mode.PROFILE_EXTERNAL_ONLY,
            groups,
        )
        self.assertEqual(external_only, "2 external displays only")

    def test_select_best_mode_falls_back_to_first(self):
        """Test _select_best_mode falls back to first mode when no flags are present."""
        modes = [
            ("m0", 1, 1, 60, 1.0, [], {}),
            ("m1", 1, 1, 60, 1.0, [], {}),
        ]
        select_best_mode = asus_display_mode_core.select_best_mode
        self.assertEqual(select_best_mode(modes), "m0")

    def test_select_best_mode_skips_malformed_entries(self):
        """Test select_best_mode ignores empty ids and malformed tuples."""
        select_best_mode = asus_display_mode_core.select_best_mode
        modes = [
            ("", 1, 1, 60, 1.0, [], {}),
            ("m1", 1, 1, 60, 1.0, [], {"is-preferred": True}),
        ]
        self.assertEqual(select_best_mode(modes), "m1")
        self.assertIsNone(select_best_mode([(), ("", 1, 1, 60, 1.0, [], {})]))

    def test_process_single_pm_marks_edp_as_builtin(self):
        """Test _process_single_pm treats eDP connectors as built-in displays."""
        pm = (("eDP-2", "Panel", "id"), [("m0", 1, 1, 60.0, 1.0, [], {})], {})
        process_single_pm = asus_display_mode_core.process_single_pm
        monitor = process_single_pm(pm)
        self.assertEqual(monitor["connector"], "eDP-2")
        self.assertEqual(monitor["mode"], "m0")
        self.assertTrue(monitor["is_builtin"])

    def test_apply_display_mode(self):
        """Test apply_display_mode legacy mode mapping calls Mutter D-Bus interface."""
        with patch_mutter_display_config(sample_builtin_screenpad_state()) as mock_iface:
            asus_display_mode.apply_display_mode(2)
            mock_iface.ApplyMonitorsConfig.assert_called_once()


class TestAsusDisplayModeTopologyCli(unittest.TestCase):
    """Additional cases split from TestAsusDisplayModePy for pylint R0904."""

    def test_detect_current_profile_id(self):
        """Test --detect profile path identifies current topology-aware profile."""
        state = sample_builtin_screenpad_state()
        logical = list(state[2])
        logical.append((0, 1080, 2.0, 0, False, [("DP-3", "3840x1100@60.017", {})]))
        state = (state[0], state[1], logical, state[3])
        with patch_mutter_display_config(state):
            profile = asus_display_mode.detect_current_profile_id()
        self.assertEqual(profile, asus_display_mode.PROFILE_ALL)

    def test_detect_topology_summary(self):
        """Test topology summary returns detected profile and active logical monitor count."""
        state = sample_builtin_screenpad_state()
        physical = list(state[1])
        physical.append(
            (
                ("HDMI-1", "DELL"),
                [("2560x1440@60.000", 2560, 1440, 60.0, 1.0, [], {"is-current": True})],
                {"is-builtin": False},
            )
        )
        logical = list(state[2])
        logical.extend(
            [
                (0, 1080, 2.0, 0, False, [("DP-3", "3840x1100@60.017", {})]),
                (0, 1630, 2.0, 0, False, [("HDMI-1", "2560x1440@60.000", {})]),
            ]
        )
        state = (state[0], physical, logical, state[3])
        with patch_mutter_display_config(state):
            profile, count = asus_display_mode.detect_topology_summary()
        self.assertEqual(profile, asus_display_mode.PROFILE_ALL)
        self.assertEqual(count, 3)

    @patch("dbus.SessionBus")
    def test_detect_topology_map(self, mock_bus_cls):
        """Test topology map includes per-logical-monitor coordinates and connectors."""
        mock_bus = MagicMock()
        mock_bus_cls.return_value = mock_bus
        mock_iface = MagicMock()
        mock_iface.GetCurrentState.return_value = (
            1,
            [
                (("eDP-1", "SDC"), [("3840x2160@60.000", 3840, 2160, 60.0, 2.0, [], {"is-current": True})], {"is-builtin": True}),
            ],
            [
                (0, 0, 2.0, 0, True, [("eDP-1", "3840x2160@60.000", {})]),
                (1920, 0, 1.0, 0, False, [("HDMI-1", "2560x1440@60.000", {})]),
            ],
            {},
        )
        with patch("dbus.Interface", return_value=mock_iface):
            topology = asus_display_mode.detect_topology_map()
        self.assertEqual(topology["profile"], asus_display_mode.PROFILE_MAIN_ONLY)
        self.assertEqual(topology["count"], 2)
        self.assertEqual(topology["monitors"][1]["x"], 1920)
        self.assertEqual(topology["monitors"][1]["width"], 2560)
        self.assertEqual(topology["monitors"][1]["height"], 1440)
        self.assertEqual(topology["monitors"][1]["connectors"], ["HDMI-1"])

    @patch("dbus.SessionBus")
    def test_detect_topology_map_resolves_spec_shaped_logical_monitors(self, mock_bus_cls):
        """Mutter connector-spec logical entries must use is-current physical modes."""
        mock_bus = MagicMock()
        mock_bus_cls.return_value = mock_bus
        mock_iface = MagicMock()
        mock_iface.GetCurrentState.return_value = (
            1,
            [
                (
                    ("eDP-1", "SDC", "0x415f", "0x00000000"),
                    [("3840x2160@60.000", 3840, 2160, 60.0, 2.0, [], {"is-current": True})],
                    {"is-builtin": True},
                ),
                (
                    ("DP-3", "BOE", "0x085f", "0x00000000"),
                    [("3840x1100@60.017", 3840, 1100, 60.0, 2.0, [], {"is-current": True})],
                    {"is-builtin": False},
                ),
            ],
            [
                (0, 0, 2.0, 0, True, [("eDP-1", "SDC", "0x415f", "0x00000000")]),
                (0, 1080, 2.0, 0, False, [("DP-3", "BOE", "0x085f", "0x00000000")]),
            ],
            {},
        )
        with patch("dbus.Interface", return_value=mock_iface):
            topology = asus_display_mode.detect_topology_map()
        self.assertEqual(topology["monitors"][0]["height"], 1080)
        self.assertEqual(topology["monitors"][1]["height"], 550)
        self.assertEqual(topology["monitors"][0]["connectors"], ["eDP-1"])
        self.assertEqual(topology["monitors"][1]["connectors"], ["DP-3"])

    @staticmethod
    def _three_monitor_next_state():
        """Mutter state with built-in, ScreenPad, and one external monitor."""
        state = sample_builtin_screenpad_state()
        return (
            state[0],
            state[1]
            + [
                (
                    ("HDMI-1", "DELL"),
                    [("2560x1440@60.000", 2560, 1440, 60.0, 1.0, [], {"is-current": True})],
                    {"is-builtin": False},
                ),
            ],
            state[2]
            + [
                (0, 1080, 2.0, 0, False, [("DP-3", "3840x1100@60.017", {})]),
                (0, 2160, 2.0, 0, False, [("HDMI-1", "2560x1440@60.000", {})]),
            ],
            state[3],
        )

    def test_main_next_prints_profile_and_label(self):
        """Test --next emits 'profile:label' pair for shell orchestration."""
        stdout = io.StringIO()
        with (
            patch_mutter_display_config(self._three_monitor_next_state()),
            patch.object(sys, "argv", ["asus-display-mode.py", "--next", "all"]),
            patch("sys.stdout", stdout),
        ):
            rc = asus_display_mode.main()
        self.assertEqual(rc, 0)
        self.assertIn("main_external", stdout.getvalue().strip())

    def test_main_detect_topology_prints_summary(self):
        """Test --detect-topology emits 'profile:count' output for hotkey daemon."""
        stdout = io.StringIO()
        with (
            patch_mutter_display_config(four_monitor_topology_state()),
            patch.object(sys, "argv", ["asus-display-mode.py", "--detect-topology"]),
            patch("sys.stdout", stdout),
        ):
            rc = asus_display_mode.main()
        self.assertEqual(rc, 0)
        body = stdout.getvalue().strip()
        self.assertRegex(body, r"^[^:]+:4$")

    def test_main_detect_topology_map_prints_json(self):
        """Test --detect-topology-map emits JSON payload for hotkey daemon traversal."""
        stdout = io.StringIO()
        state = sample_builtin_screenpad_state()
        state = (
            state[0],
            state[1]
            + [
                (
                    ("HDMI-1", "DELL"),
                    [("2560x1440@60.000", 2560, 1440, 60.0, 1.0, [], {"is-current": True})],
                    {"is-builtin": False},
                ),
            ],
            state[2]
            + [
                (1920, 0, 1.0, 0, False, [("HDMI-1", "2560x1440@60.000", {})]),
            ],
            state[3],
        )
        with (
            patch_mutter_display_config(state),
            patch.object(sys, "argv", ["asus-display-mode.py", "--detect-topology-map"]),
            patch("sys.stdout", stdout),
        ):
            rc = asus_display_mode.main()
        self.assertEqual(rc, 0)
        self.assertIn('"profile":', stdout.getvalue().strip())

    def test_main(self):
        """Test main entrypoint parsing sys.argv."""
        assert_display_mode_main_applies(
            self,
            ["asus-display-mode.py", "2"],
            sample_builtin_screenpad_state(),
        )

    def test_main_rejects_invalid_arg(self):
        """Test invalid CLI argument exits with an error without invoking apply_display_mode."""
        run_display_mode_main_reject(self, ["asus-display-mode.py", "not-a-number"], "Invalid mode argument.")

    def test_main_rejects_missing_arg(self):
        """Test missing CLI argument exits with an error without invoking apply_display_mode."""
        run_display_mode_main_reject(self, ["asus-display-mode.py"], "Invalid mode argument.")

    @patch("dbus.SessionBus", side_effect=asus_display_mode.dbus.DBusException("boom"))
    def test_apply_display_mode_reports_dbus_exception(self, _mock_bus):
        """Test apply_display_mode reports Mutter D-Bus failures and returns non-zero."""
        stderr = io.StringIO()
        with patch("sys.stderr", stderr):
            rc = asus_display_mode.apply_display_mode(1)
        self.assertEqual(rc, 1)
        self.assertEqual(stderr.getvalue().strip(), "Failed to apply display mode: boom")
