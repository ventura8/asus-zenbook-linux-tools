"""Helper and CLI edge coverage for asus_display_mode.py."""

import io
import sys
import unittest
from unittest.mock import patch

import asus_display_mode

from tests.unit.bin.attr_helpers import call_attr


class TestAsusDisplayModeHelpers(unittest.TestCase):
    """Cover mode-resolution helpers and unsupported CLI branches."""

    def test_apply_display_mode_unsupported(self):
        """Unsupported legacy mode numbers fail closed with stderr."""
        stderr = io.StringIO()
        with patch("sys.stderr", stderr):
            self.assertEqual(asus_display_mode.apply_display_mode(99), 1)
        self.assertIn("Unsupported legacy display mode", stderr.getvalue())

    def test_mode_entry_and_props_helpers(self):
        """Mode matching, props flags, and empty physical-monitor modes."""
        modes = [("1920x1080", 1920, 1080, 60.0, 1.0, [], {"is-current": True})]
        self.assertIsNone(call_attr(asus_display_mode, "_mode_entry_for_connector", modes, "nope"))
        self.assertEqual(
            call_attr(asus_display_mode, "_mode_entry_for_connector", modes, "1920x1080")[0],
            "1920x1080",
        )
        self.assertFalse(call_attr(asus_display_mode, "_mode_is_current", None))
        self.assertFalse(call_attr(asus_display_mode, "_mode_is_current", ("id",)))
        self.assertFalse(call_attr(asus_display_mode, "_props_flag_true", object(), "is-current"))
        self.assertFalse(call_attr(asus_display_mode, "_props_flag_true", {"other": True}, "is-current"))
        self.assertTrue(call_attr(asus_display_mode, "_props_flag_true", {"is-current": 1}, "is-current"))
        self.assertIsNone(call_attr(asus_display_mode, "_current_mode_entry", [("id", 1, 1, 1, 1, [], {})]))
        self.assertEqual(call_attr(asus_display_mode, "_modes_list", None), [])
        self.assertEqual(call_attr(asus_display_mode, "_modes_list", (("eDP-1",), None)), [])

    def test_resolve_matched_mode_fallbacks(self):
        """Vendor tokens fall back to is-current or first mode / raw id."""
        current = ("1920x1080", 1920, 1080, 60.0, 1.0, [], {"is-current": True})
        self.assertEqual(
            call_attr(asus_display_mode, "_resolve_matched_mode", [current], "BOE"),
            current,
        )
        self.assertEqual(
            call_attr(asus_display_mode, "_resolve_matched_mode", [], "1920x1080"),
            "1920x1080",
        )
        first = ("800x600", 800, 600, 60.0, 1.0, [], {})
        self.assertEqual(call_attr(asus_display_mode, "_resolve_matched_mode", [first], "BOE"), first)
        self.assertIsNone(call_attr(asus_display_mode, "_resolve_matched_mode", [], "BOE"))

    def test_physical_and_logical_connector_tokens(self):
        """Malformed physical/logical monitor tuples yield None connectors."""
        self.assertIsNone(call_attr(asus_display_mode, "_physical_monitor_connector", None))
        self.assertIsNone(call_attr(asus_display_mode, "_physical_monitor_connector", []))
        self.assertIsNone(call_attr(asus_display_mode, "_physical_monitor_connector", ((),)))
        self.assertIsNone(call_attr(asus_display_mode, "_physical_monitor_connector", ((),)))
        self.assertEqual(
            call_attr(asus_display_mode, "_physical_monitor_connector", (("eDP-1", "BOE"), [])),
            "eDP-1",
        )
        self.assertEqual(
            call_attr(asus_display_mode, "_logical_monitor_connector_token", (0, 0, 1.0, 0, True)),
            (None, None),
        )
        self.assertEqual(
            call_attr(
                asus_display_mode,
                "_logical_monitor_connector_token",
                (0, 0, 1.0, 0, True, [None]),
            ),
            (None, None),
        )
        self.assertEqual(
            call_attr(
                asus_display_mode,
                "_logical_monitor_connector_token",
                (0, 0, 1.0, 0, True, [("eDP-1", "BOE")]),
            ),
            ("eDP-1", "BOE"),
        )

    def test_resolve_logical_monitor_mode_none_paths(self):
        """Missing connector / unresolved vendor token returns None."""
        self.assertIsNone(
            call_attr(
                asus_display_mode,
                "_resolve_logical_monitor_mode",
                [],
                (0, 0, 1.0, 0, True),
            )
        )
        logical = (0, 0, 1.0, 0, True, [("eDP-1", "BOE")])
        self.assertIsNone(call_attr(asus_display_mode, "_resolve_logical_monitor_mode", [], logical))
        self.assertEqual(
            call_attr(
                asus_display_mode,
                "_resolve_logical_monitor_mode",
                [],
                (0, 0, 1.0, 0, True, [("eDP-1", "1920x1080")]),
            ),
            "1920x1080",
        )

    def test_logical_monitor_payload_too_short(self):
        """Short logical-monitor tuples are skipped."""
        self.assertIsNone(call_attr(asus_display_mode, "_logical_monitor_payload", (0, 0), [], 0))

    def test_run_detect_command_type_error(self):
        """TypeError from detect runners prints and returns 1."""
        stderr = io.StringIO()
        with patch("sys.stderr", stderr):
            rc = call_attr(
                asus_display_mode,
                "_run_detect_command",
                lambda: (_ for _ in ()).throw(TypeError("bad")),
            )
        self.assertEqual(rc, 1)
        self.assertIn("Failed to detect display mode", stderr.getvalue())

    def test_run_next_rejects_unknown_profile(self):
        """--next rejects unknown profile ids."""
        stderr = io.StringIO()
        with patch("sys.stderr", stderr), self.assertRaises(SystemExit) as exc:
            call_attr(asus_display_mode, "_run_next", ["not-a-profile"])
        self.assertEqual(exc.exception.code, 1)
        self.assertIn("Invalid profile id", stderr.getvalue())

    def test_main_rejects_unknown_legacy_mode(self):
        """Numeric CLI modes outside the legacy map exit with invalid mode."""
        stderr = io.StringIO()
        with (
            patch.object(sys, "argv", ["asus-display-mode.py", "99"]),
            patch("sys.stderr", stderr),
            self.assertRaises(SystemExit) as exc,
        ):
            asus_display_mode.main()
        self.assertEqual(exc.exception.code, 1)
        self.assertEqual(stderr.getvalue().strip(), "Invalid mode argument.")


if __name__ == "__main__":
    unittest.main()
