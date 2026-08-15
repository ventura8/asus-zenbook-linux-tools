"""Display-mode scale selection, profile targets, and CLI dispatch unit tests."""

import io
import sys
import unittest
from unittest.mock import MagicMock, patch

from tests.unit.bin.display_mode_test_utils import (
    assert_display_mode_main_applies,
    get_display_mode_core_helper,
    load_asus_display_mode_core_module,
    load_asus_display_mode_module,
    patch_mutter_display_config,
    run_display_mode_main_reject,
    sample_builtin_screenpad_state,
)

asus_display_mode = load_asus_display_mode_module()
asus_display_mode_core = load_asus_display_mode_core_module()


class TestAsusDisplayModeScalesAndProfiles(unittest.TestCase):
    """Scale selection, ScreenPad heuristics, and profile-target unit tests."""

    def test_mode_scale_value_handles_invalid_and_valid_values(self):
        """_mode_scale_value handles malformed tuples and positive scales."""
        mode_scale_value = get_display_mode_core_helper(asus_display_mode_core, "_mode_scale_value")

        self.assertIsNone(mode_scale_value(("m", 1, 1, 60.0)))
        self.assertIsNone(mode_scale_value(("m", 1, 1, 60.0, "x")))
        self.assertIsNone(mode_scale_value(("m", 1, 1, 60.0, 0)))
        self.assertEqual(mode_scale_value(("m", 1, 1, 60.0, 1.25)), 1.25)

    def test_supported_scale_values_filters_invalid_values(self):
        """_supported_scale_values keeps only positive numeric scale values."""
        supported_scale_values = get_display_mode_core_helper(asus_display_mode_core, "_supported_scale_values")

        self.assertEqual(supported_scale_values(("m", 1, 1, 60.0, 1.0, [2, 0, "bad", 1.5])), [2.0, 1.5])
        self.assertEqual(supported_scale_values(("m", 1, 1, 60.0, 1.0, "not-a-list")), [])

    def test_extract_supported_scales_returns_sorted_unique_scales(self):
        """_extract_supported_scales returns unique scales in ascending order."""
        extract_supported_scales = get_display_mode_core_helper(asus_display_mode_core, "_extract_supported_scales")

        modes = [
            ("m0", 1, 1, 60.0, 1.0, [2.0, 1.0], {}),
            ("m1", 1, 1, 60.0, 1.5, [1.5, 2.0], {}),
        ]
        self.assertEqual(extract_supported_scales(modes), [1.0, 1.5, 2.0])

    def test_find_scale_for_mode_handles_present_and_missing_mode(self):
        """_find_scale_for_mode returns matching scale and None for missing mode."""
        find_scale_for_mode = get_display_mode_core_helper(asus_display_mode_core, "_find_scale_for_mode")

        modes = [
            ("m0", 1, 1, 60.0, 1.0, [2.0, 1.0], {}),
            ("m1", 1, 1, 60.0, 1.5, [1.5, 2.0], {}),
        ]
        self.assertEqual(find_scale_for_mode(modes, "m1"), 1.5)
        self.assertIsNone(find_scale_for_mode(modes, "missing"))

    def test_preferred_mode_scale_falls_back_to_first_supported_scale(self):
        """_preferred_mode_scale falls back when selected mode scale is unavailable."""
        preferred_mode_scale = get_display_mode_core_helper(asus_display_mode_core, "_preferred_mode_scale")

        modes = [
            ("m0", 1, 1, 60.0, 1.0, [2.0, 1.0], {}),
            ("m1", 1, 1, 60.0, 1.5, [1.5, 2.0], {}),
        ]
        self.assertEqual(preferred_mode_scale(modes, "missing"), 1.0)

    def test_screenpad_detection_and_aspect_ratio_paths(self):
        """ScreenPad classification honors overrides and aspect-ratio tolerance rules."""
        mode_aspect_ratio = get_display_mode_core_helper(asus_display_mode_core, "_mode_aspect_ratio")
        is_screenpad_like_external = get_display_mode_core_helper(asus_display_mode_core, "_is_screenpad_like_external")

        self.assertIsNone(mode_aspect_ratio("invalid"))
        self.assertIsNone(mode_aspect_ratio("0x1100@60"))

        self.assertFalse(is_screenpad_like_external({"connector": asus_display_mode_core.DEFAULT_SECONDARY_CONNECTOR, "mode": "bad"}))
        self.assertFalse(is_screenpad_like_external({"connector": "", "mode": "3840x1100@60.017"}))
        self.assertFalse(is_screenpad_like_external({"connector": "HDMI-1", "mode": "3840x1100@60.017"}))
        self.assertTrue(is_screenpad_like_external({"connector": "DP-2", "mode": "3840x1100@60.017"}))
        self.assertTrue(
            is_screenpad_like_external(
                {
                    "connector": asus_display_mode_core.DEFAULT_SECONDARY_CONNECTOR,
                    "mode": "3840x1100@60.017",
                }
            )
        )
        self.assertFalse(is_screenpad_like_external({"connector": "DP-2", "mode": "3840x1080@60.000"}))
        self.assertFalse(is_screenpad_like_external({"connector": "DP-2", "mode": "2560x1440@60.000"}))
        self.assertFalse(is_screenpad_like_external({"connector": "DP-2", "mode": "5120x1440@60.000"}))
        self.assertFalse(
            is_screenpad_like_external(
                {
                    "connector": asus_display_mode_core.DEFAULT_SECONDARY_CONNECTOR,
                    "mode": "5120x1440@60.000",
                }
            )
        )

    def test_profile_targets_apply_scale_selection_rules(self):
        """Profile target generation applies per-monitor scale selection and de-duplication."""

        def _base_groups():
            return {
                "main": {
                    "connector": "eDP-1",
                    "mode": "3840x2160@60.000",
                    "is_builtin": True,
                    "preferred_scale": 1.25,
                    "supported_scales": [1.0, 1.5],
                    "mode_scales": [1.0, 1.5],
                },
                "screenpad": {
                    "connector": "DP-3",
                    "mode": "3840x1100@60.017",
                    "is_builtin": False,
                    "preferred_scale": None,
                    "supported_scales": [1.5, 2.0],
                    "mode_scales": [1.5, 2.0],
                },
                "externals": [
                    {
                        "connector": "HDMI-1",
                        "mode": "2560x1440@60.000",
                        "is_builtin": False,
                        "preferred_scale": None,
                        "supported_scales": [],
                        "mode_scales": [],
                    },
                    {
                        "connector": "HDMI-1",
                        "mode": "2560x1440@60.000",
                        "is_builtin": False,
                        "preferred_scale": None,
                        "supported_scales": [2.0],
                        "mode_scales": [2.0],
                    },
                ],
            }

        profile_targets = get_display_mode_core_helper(asus_display_mode_core, "_profile_targets")

        with self.subTest(phase="initial"):
            groups = _base_groups()
            targets = profile_targets(asus_display_mode_core.PROFILE_ALL, groups)
            by_connector = {target["connector"]: target for target in targets}
            self.assertEqual(by_connector["eDP-1"]["scale"], 1.25)
            self.assertEqual(by_connector["DP-3"]["scale"], 1.5)
            self.assertEqual(by_connector["HDMI-1"]["scale"], 1.0)
            self.assertEqual(len(targets), 3)

        with self.subTest(phase="union_supported_scales"):
            groups = _base_groups()
            # Union includes DISPLAY_SCALE but selected mode does not → keep preferred.
            groups["main"]["supported_scales"] = [1.0, 1.5, 2.0]
            targets = profile_targets(asus_display_mode_core.PROFILE_ALL, groups)
            by_connector = {target["connector"]: target for target in targets}
            self.assertEqual(by_connector["eDP-1"]["scale"], 1.25)

        with self.subTest(phase="mode_scales"):
            groups = _base_groups()
            groups["main"]["mode_scales"] = [1.0, 1.5, 2.0]
            targets = profile_targets(asus_display_mode_core.PROFILE_ALL, groups)
            by_connector = {target["connector"]: target for target in targets}
            self.assertEqual(by_connector["eDP-1"]["scale"], asus_display_mode_core.DISPLAY_SCALE)

    def test_logical_size_and_height_fallback_branches(self):
        """Logical size helpers return None sentinel on malformed/non-positive results."""
        logical_size_from_mode = asus_display_mode_core.logical_size_from_mode
        logical_height_from_mode = get_display_mode_core_helper(asus_display_mode_core, "_logical_height_from_mode")

        self.assertEqual(logical_size_from_mode("bad", 2.0), (None, None))
        self.assertEqual(logical_size_from_mode("-3840x-1100@60", 2.0), (None, None))
        self.assertEqual(logical_size_from_mode("3840x1100@60", 2.0), (1920, 550))
        self.assertIsNone(logical_height_from_mode("bad", 2.0))
        self.assertIsNone(logical_height_from_mode("3840x1100@60", 0))

    def test_builtin_main_preference_via_classification(self):
        """Classification prefers DEFAULT_MAIN_CONNECTOR when multiple built-ins exist."""
        physical_monitors = [
            (("eDP-2", "VEND", "a"), [("m1", 1, 1, 60.0, 1.0, [], {"is-current": True})], {"is-builtin": True}),
            (("eDP-1", "VEND", "b"), [("m2", 1, 1, 60.0, 1.0, [], {"is-current": True})], {"is-builtin": True}),
        ]
        groups = asus_display_mode.classify_monitor_groups(physical_monitors)
        self.assertEqual(groups["main"]["connector"], "eDP-1")

    def test_dp_external_promoted_when_screenpad_dimensions_match(self):
        """Any supported DP-* with ScreenPad-like dimensions is classified as screenpad."""
        physical_monitors = [
            (("eDP-1", "VEND", "a"), [("m-main", 1, 1, 60.0, 1.0, [], {"is-current": True})], {"is-builtin": True}),
            (("HDMI-1", "VEND", "b"), [("m-ext", 1, 1, 60.0, 1.0, [], {"is-builtin": False})], {"is-builtin": False}),
            (("DP-2", "VEND", "c"), [("3840x1100@60.017", 3840, 1100, 60.0, 1.0, [], {"is-current": True})], {"is-builtin": False}),
        ]
        groups = asus_display_mode.classify_monitor_groups(physical_monitors)
        self.assertEqual(groups["screenpad"]["connector"], "DP-2")
        self.assertEqual([entry["connector"] for entry in groups["externals"]], ["HDMI-1"])

    def test_dp_external_not_promoted_without_screenpad_dimensions(self):
        """DP-* without ScreenPad-like dimensions stays in the externals list."""
        physical_monitors = [
            (("eDP-1", "VEND", "a"), [("m-main", 1, 1, 60.0, 1.0, [], {"is-current": True})], {"is-builtin": True}),
            (("DP-2", "VEND", "c"), [("1920x1080@60.0", 1920, 1080, 60.0, 1.0, [], {"is-current": True})], {"is-builtin": False}),
        ]
        groups = asus_display_mode.classify_monitor_groups(physical_monitors)
        self.assertIsNone(groups["screenpad"])
        self.assertEqual([entry["connector"] for entry in groups["externals"]], ["DP-2"])

    def test_unknown_profile_build_uses_all_targets(self):
        """Unknown profile id falls back to all-target builder path."""
        groups = {
            "main": {"connector": "eDP-1", "mode": "3840x2160@60.000"},
            "screenpad": {"connector": "DP-3", "mode": "3840x1100@60.017"},
            "externals": [{"connector": "HDMI-1", "mode": "2560x1440@60.000"}],
        }
        layout = asus_display_mode.build_logical_monitors("unexpected-profile", groups)
        active = {entry[5][0][0] for entry in layout}
        self.assertEqual(active, {"eDP-1", "DP-3", "HDMI-1"})

    def test_detect_current_profile_handles_malformed_logical_tuple(self):
        """Malformed logical monitor entries are ignored while matching active connectors."""
        groups = {
            "main": {"connector": "eDP-1", "mode": "m1"},
            "screenpad": {"connector": "DP-3", "mode": "m2"},
            "externals": [],
        }
        logical_monitors = [(0, 0, 2.0), (0, 0, 2.0, 0, True, [("eDP-1", "m1", {})])]
        detected = asus_display_mode.detect_current_profile(logical_monitors, groups)
        self.assertEqual(detected, asus_display_mode.PROFILE_MAIN_ONLY)

    def test_detect_current_profile_empty_active_and_nearest_branches(self):
        """Coverage for empty-active fallback and nearest-profile mismatch path."""
        groups = {
            "main": {"connector": "eDP-1", "mode": "m1"},
            "screenpad": {"connector": "DP-3", "mode": "m2"},
            "externals": [{"connector": "HDMI-1", "mode": "m3"}],
        }
        self.assertEqual(asus_display_mode.detect_current_profile([], groups), asus_display_mode.PROFILE_ALL)

        mismatch = [(0, 0, 2.0, 0, True, [("DP-3", "m2", {})])]
        nearest = asus_display_mode.detect_current_profile(mismatch, groups)
        self.assertEqual(nearest, asus_display_mode.PROFILE_SCREENPAD_ONLY)

    def test_label_variants_and_unknown_next_profile(self):
        """Coverage for non-all labels and unknown next-profile input branch."""
        groups = {
            "main": {"connector": "eDP-1", "mode": "m1"},
            "screenpad": None,
            "externals": [{"connector": "HDMI-1", "mode": "m3"}],
        }
        label = asus_display_mode.format_profile_label(asus_display_mode.PROFILE_MAIN_EXTERNAL, groups)
        self.assertEqual(label, "Main display + 1 external display")
        self.assertEqual(asus_display_mode.get_next_profile("unknown", groups), asus_display_mode.PROFILE_ALL)

    def test_available_profiles_with_external_only_topology(self):
        """External-only topology offers a dedicated external_only profile."""
        groups = {"main": None, "screenpad": None, "externals": [{"connector": "HDMI-1", "mode": "m3"}]}
        profiles = asus_display_mode.available_profiles(groups)
        self.assertEqual(profiles, [asus_display_mode.PROFILE_EXTERNAL_ONLY])

    @patch("dbus.SessionBus", side_effect=asus_display_mode.dbus.DBusException("boom"))
    def test_main_detect_reports_dbus_failure(self, _mock_bus):
        """Main --detect command returns non-zero on D-Bus failure."""
        stderr = io.StringIO()
        with (
            patch.object(sys, "argv", ["asus-display-mode.py", "--detect"]),
            patch("sys.stderr", stderr),
        ):
            rc = asus_display_mode.main()
        self.assertEqual(rc, 1)
        self.assertEqual(stderr.getvalue().strip(), "Failed to detect display mode: boom")


class TestAsusDisplayModeCliDispatch(unittest.TestCase):
    """CLI argument validation and profile-apply dispatch unit tests."""

    def test_main_next_and_apply_profile_require_arguments(self):
        """Main enforces required arguments for command handler paths."""
        stderr = io.StringIO()
        with (
            patch.object(sys, "argv", ["asus-display-mode.py", "--next"]),
            patch("sys.stderr", stderr),
            self.assertRaises(SystemExit) as next_exc,
        ):
            asus_display_mode.main()
        self.assertEqual(next_exc.exception.code, 1)
        self.assertEqual(stderr.getvalue().strip(), "Invalid mode argument.")

        stderr = io.StringIO()
        with (
            patch.object(sys, "argv", ["asus-display-mode.py", "--apply-profile"]),
            patch("sys.stderr", stderr),
            self.assertRaises(SystemExit) as apply_exc,
        ):
            asus_display_mode.main()
        self.assertEqual(apply_exc.exception.code, 1)
        self.assertEqual(stderr.getvalue().strip(), "Invalid mode argument.")

    def test_main_apply_profile_dispatch(self):
        """Main dispatches --apply-profile through command handlers."""
        assert_display_mode_main_applies(
            self,
            ["asus-display-mode.py", "--apply-profile", "all"],
            sample_builtin_screenpad_state(),
        )

    def test_main_apply_profile_rejects_unknown_profile_id(self):
        """Main rejects unknown --apply-profile ids before backend apply call."""
        run_display_mode_main_reject(
            self,
            ["asus-display-mode.py", "--apply-profile", "unknown-profile"],
            "Invalid profile id: unknown-profile",
        )

    def test_build_logical_monitors_raises_for_missing_targets(self):
        """Invalid profile/topology combinations raise ValueError."""
        with self.assertRaises(ValueError):
            asus_display_mode.build_logical_monitors(
                asus_display_mode.PROFILE_SCREENPAD_ONLY,
                {"main": {"connector": "eDP-1", "mode": "m1"}, "screenpad": None, "externals": []},
            )

    def test_invalid_mode_raises_in_layout(self):
        """Invalid mode strings fail closed before advancing layout offsets."""
        groups = {
            "main": None,
            "screenpad": {"connector": "DP-3", "mode": "invalid"},
            "externals": [{"connector": "HDMI-1", "mode": "2560x1440@60.000"}],
        }
        with self.assertRaises(ValueError):
            asus_display_mode.build_logical_monitors(asus_display_mode.PROFILE_SCREENPAD_EXTERNAL, groups)

    def test_find_monitor_modes_uses_defaults_without_monitors(self):
        """find_monitor_modes falls back to default connector and mode constants."""
        main_conn, main_mode, sec_conn, sec_mode = asus_display_mode.find_monitor_modes([])
        self.assertEqual(main_conn, asus_display_mode.DEFAULT_MAIN_CONNECTOR)
        self.assertEqual(main_mode, asus_display_mode.DEFAULT_MAIN_MODE)
        self.assertEqual(sec_conn, asus_display_mode.DEFAULT_SECONDARY_CONNECTOR)
        self.assertEqual(sec_mode, asus_display_mode.DEFAULT_SECONDARY_MODE)

    @patch("dbus.SessionBus")
    def test_detect_current_mode_maps_profile_to_legacy_value(self, _mock_bus_cls):
        """detect_current_mode maps topology profile ids to legacy numeric values."""
        mock_iface = MagicMock()
        mock_iface.GetCurrentState.return_value = sample_builtin_screenpad_state()
        with patch("dbus.Interface", return_value=mock_iface):
            self.assertEqual(asus_display_mode.detect_current_mode(), 2)

    @patch("dbus.SessionBus", side_effect=asus_display_mode.dbus.DBusException("boom"))
    def test_detect_current_mode_propagates_dbus_error(self, _mock_bus_cls):
        """detect_current_mode prints and re-raises when Mutter DisplayConfig fails."""
        stderr = io.StringIO()
        with patch("sys.stderr", stderr), self.assertRaises(asus_display_mode.dbus.DBusException):
            asus_display_mode.detect_current_mode()
        self.assertEqual(stderr.getvalue().strip(), "Failed to detect display mode: boom")

    def test_main_detect_success_path(self):
        """Main --detect success path returns zero and prints profile id."""
        stdout = io.StringIO()
        state = (
            1,
            [
                (("eDP-1", "SDC"), [("3840x2160@60.000", 3840, 2160, 60.0, 2.0, [], {"is-current": True})], {"is-builtin": True}),
                (("DP-3", "BOE"), [("3840x1100@60.017", 3840, 1100, 60.0, 2.0, [], {"is-preferred": True})], {"is-builtin": False}),
                (("HDMI-1", "DELL"), [("2560x1440@60.000", 2560, 1440, 60.0, 1.0, [], {"is-current": True})], {"is-builtin": False}),
            ],
            [
                (0, 0, 2.0, 0, True, [("eDP-1", "3840x2160@60.000", {})]),
                (0, 1080, 2.0, 0, False, [("DP-3", "3840x1100@60.017", {})]),
                (0, 2160, 2.0, 0, False, [("HDMI-1", "2560x1440@60.000", {})]),
            ],
            {},
        )
        with (
            patch_mutter_display_config(state),
            patch.object(sys, "argv", ["asus-display-mode.py", "--detect"]),
            patch("sys.stdout", stdout),
        ):
            rc = asus_display_mode.main()
        self.assertEqual(rc, 0)
        self.assertEqual(stdout.getvalue().strip(), "all")

    @patch("dbus.SessionBus", side_effect=asus_display_mode.dbus.DBusException("boom"))
    def test_main_next_reports_dbus_failure(self, _mock_bus):
        """Main --next returns non-zero when next-profile planning fails over D-Bus."""
        stderr = io.StringIO()
        with (
            patch.object(sys, "argv", ["asus-display-mode.py", "--next", "all"]),
            patch("sys.stderr", stderr),
        ):
            rc = asus_display_mode.main()
        self.assertEqual(rc, 1)
        self.assertEqual(stderr.getvalue().strip(), "Failed to plan next display mode: boom")


if __name__ == "__main__":
    unittest.main()
