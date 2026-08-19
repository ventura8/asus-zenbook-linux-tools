"""Unit tests for install selection accent resolution and ncurses TUI logic."""

from __future__ import annotations

import io
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

import asus_install_selection_accent as accent
import asus_install_selection_tui as tui
import asus_install_selection_version as tui_version
from asus_install_selection_accent import (
    DEFAULT_ACCENT_RGB,
    format_accent_rgb,
    gnome_accent_name_to_rgb,
    nearest_ansi16,
    parse_rgb_text,
    resolve_accent_rgb,
    rgb_from_env,
)
from asus_install_selection_tui import (
    EXIT_CANCEL,
    EXIT_ERROR,
    EXIT_OK,
    ChecklistModel,
    MouseHitLayout,
    build_default_model,
    default_message,
    default_title,
    draw_checklist,
    handle_key,
    handle_mouse_click,
    main,
    parse_args,
    run_scripted,
    truncate_label,
    wrap_text,
    write_selection,
)

from tests.unit.bin.attr_helpers import call_attr

PROJECT_ROOT = Path(__file__).resolve().parents[3]


class TestInstallSelectionAccent(unittest.TestCase):
    """Accent RGB parsing and DE enum mapping."""

    def test_parse_rgb_and_hex(self) -> None:
        """CSV and hex accents parse to clamped RGB."""
        self.assertEqual(parse_rgb_text("10, 20, 30"), (10, 20, 30))
        self.assertEqual(parse_rgb_text("#3584e4"), (53, 132, 228))
        self.assertEqual(parse_rgb_text("3584e4"), (53, 132, 228))
        self.assertIsNone(parse_rgb_text(""))
        self.assertIsNone(parse_rgb_text("not-a-color"))
        self.assertIsNone(gnome_accent_name_to_rgb("unknown"))

    def test_gnome_enum_and_env_override(self) -> None:
        """GNOME enum maps; env override wins in resolve_accent_rgb."""
        self.assertEqual(gnome_accent_name_to_rgb("orange"), (237, 91, 0))
        self.assertEqual(rgb_from_env({"ASUS_TUI_ACCENT_RGB": "1 2 3"}), (1, 2, 3))
        self.assertIsNone(rgb_from_env({"ASUS_TUI_ACCENT_RGB": "1 2"}))
        self.assertIsNone(rgb_from_env({}))
        self.assertEqual(
            resolve_accent_rgb({"ASUS_TUI_ACCENT_RGB": "#010203"}),
            (1, 2, 3),
        )
        self.assertEqual(format_accent_rgb(DEFAULT_ACCENT_RGB), "53 132 228")
        self.assertEqual(nearest_ansi16((0, 0, 255)), 4)

    def test_run_capture_and_de_readers(self) -> None:
        """gsettings/kreadconfig paths and subprocess failure handling."""
        self.assertEqual(call_attr(accent, "_run_capture", ["false"]), "")
        with patch("asus_install_selection_accent.subprocess.run", side_effect=OSError):
            self.assertEqual(call_attr(accent, "_run_capture", ["gsettings"]), "")
        with patch(
            "asus_install_selection_accent.subprocess.run",
            side_effect=subprocess.TimeoutExpired("x", 1),
        ):
            self.assertEqual(call_attr(accent, "_run_capture", ["gsettings"]), "")
        completed = MagicMock(returncode=0, stdout="blue\n")
        with patch("asus_install_selection_accent.subprocess.run", return_value=completed):
            self.assertEqual(call_attr(accent, "_run_capture", ["gsettings"]), "blue")
        with patch("asus_install_selection_accent.shutil.which", return_value=None):
            self.assertIsNone(accent.read_gnome_accent_rgb())
            self.assertIsNone(accent.read_kde_accent_rgb())
        with (
            patch("asus_install_selection_accent.shutil.which", return_value="/bin/gsettings"),
            patch("asus_install_selection_accent._run_capture", return_value="'teal'"),
        ):
            self.assertEqual(accent.read_gnome_accent_rgb(), (33, 144, 164))
        with (
            patch("asus_install_selection_accent.shutil.which", return_value="/bin/gsettings"),
            patch("asus_install_selection_accent._run_capture", return_value=""),
        ):
            self.assertIsNone(accent.read_gnome_accent_rgb())

    def test_kde_reader_and_family_resolve(self) -> None:
        """KDE AccentColor parse and family-based resolve fallbacks."""

        def which_side(name: str) -> str | None:
            return "/usr/bin/kreadconfig6" if name == "kreadconfig6" else None

        with (
            patch("asus_install_selection_accent.shutil.which", side_effect=which_side),
            patch("asus_install_selection_accent._run_capture", return_value="10,20,30"),
        ):
            self.assertEqual(accent.read_kde_accent_rgb(), (10, 20, 30))
        with (
            patch("asus_install_selection_accent.shutil.which", side_effect=which_side),
            patch("asus_install_selection_accent._run_capture", return_value=""),
        ):
            self.assertIsNone(accent.read_kde_accent_rgb())
        with patch("asus_install_selection_accent.read_gnome_accent_rgb", return_value=(1, 2, 3)):
            self.assertEqual(resolve_accent_rgb({}, prefer_family="gnome"), (1, 2, 3))
        with (
            patch("asus_install_selection_accent.read_gnome_accent_rgb", return_value=None),
            patch("asus_install_selection_accent.read_kde_accent_rgb", return_value=(9, 8, 7)),
        ):
            self.assertEqual(resolve_accent_rgb({}, prefer_family="kde"), (9, 8, 7))
            self.assertEqual(resolve_accent_rgb({}, prefer_family="xfce"), (9, 8, 7))
        with (
            patch("asus_install_selection_accent.read_gnome_accent_rgb", return_value=None),
            patch("asus_install_selection_accent.read_kde_accent_rgb", return_value=None),
        ):
            self.assertEqual(resolve_accent_rgb({}, prefer_family="other"), DEFAULT_ACCENT_RGB)
            self.assertEqual(resolve_accent_rgb({}, prefer_family="gnome"), DEFAULT_ACCENT_RGB)


class TestInstallSelectionTuiLogic(unittest.TestCase):
    """Keyboard/mouse state machine without a live terminal."""

    def test_scripted_confirm_and_cancel(self) -> None:
        """Enter confirms selection; Esc cancels."""
        model = build_default_model(desktop_on=True, title="t", message="m")
        self.assertEqual(run_scripted(model, "\n"), EXIT_OK)
        self.assertEqual(model.selected_tags(), ["WMI", "TOUCHPAD", "SOUND", "DESKTOP"])
        model2 = build_default_model(desktop_on=False, title="t", message="m")
        self.assertEqual(run_scripted(model2, "\x1b"), EXIT_CANCEL)
        self.assertEqual(run_scripted(model2, "z\n"), EXIT_OK)

    def test_scripted_uncheck_all_confirms_empty_selection(self) -> None:
        """Unchecking every component then Ok yields an empty selection."""
        model = build_default_model(desktop_on=True, title="t", message="m")
        self.assertEqual(run_scripted(model, " j j j \n"), EXIT_OK)
        self.assertEqual(model.selected_tags(), [])

    def test_space_toggles_and_mouse_ok(self) -> None:
        """Space toggles focus item; mouse Ok/Cancel and miss paths."""
        model = ChecklistModel(tags=["WMI"], labels=["x"], selected=[True], focus=0)
        handle_key(model, ord(" "))
        self.assertFalse(model.selected[0])
        layout = MouseHitLayout(item_spans=((5, 8),), ok_row=10, ok_col=2, cancel_col=10)
        self.assertEqual(handle_mouse_click(model, layout, 10, 3), "ok")
        self.assertEqual(handle_mouse_click(model, layout, 10, 11), "cancel")
        self.assertIsNone(handle_mouse_click(model, layout, 10, 20))
        self.assertIsNone(handle_mouse_click(model, layout, 4, 2))
        self.assertIsNone(handle_mouse_click(model, layout, 5, 2))
        self.assertTrue(model.selected[0])

    def test_focus_nav_and_enter_cancel(self) -> None:
        """Arrow/j/k navigation and Enter on Cancel."""
        model = ChecklistModel(tags=["WMI", "SOUND"], labels=["a", "b"], selected=[True, True], focus=0)
        self.assertEqual(model.ok_index, 2)
        self.assertEqual(model.cancel_index, 3)
        handle_key(model, ord("j"))
        self.assertEqual(model.focus, 1)
        handle_key(model, ord("k"))
        self.assertEqual(model.focus, 0)
        model.focus = model.cancel_index
        self.assertEqual(handle_key(model, 10), "cancel")

    def test_truncate_wrap_and_cli_main(self) -> None:
        """Truncate/wrap helpers and CLI --script-keys write output."""
        self.assertEqual(truncate_label("abcdef", 4), "a...")
        self.assertEqual(truncate_label("abc", 10), "abc")
        self.assertEqual(truncate_label("abcdef", 0), "")
        self.assertEqual(truncate_label("abcdef", 2), "ab")
        self.assertEqual(truncate_label("one two three", 10), "one...")
        self.assertEqual(wrap_text("one two three", 7), ["one two", "three"])
        self.assertEqual(wrap_text("", 8), [""])
        self.assertEqual(wrap_text("solo", 0), ["solo"])
        model = build_default_model(desktop_on=True, title="t", message="m")
        self.assertIn("WMI hotkey daemon", model.labels[0])
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "choice.txt"
            status = main(["--script-keys", "\n", "--output", str(out), "--desktop-on"])
            self.assertEqual(status, EXIT_OK)
            self.assertIn("WMI", out.read_text(encoding="utf-8"))

    def test_defaults_parse_and_write_stdout(self) -> None:
        """default title/message, argparse, and stdout selection write."""
        expected_version = f"v{(PROJECT_ROOT / 'VERSION').read_text(encoding='utf-8').strip()}"
        with patch.dict("os.environ", {}, clear=True):
            self.assertIn(expected_version, default_title())
            self.assertIn(expected_version, default_message())
        with patch.dict("os.environ", {"ASUS_DISPLAY_VERSION": "v9.9.9"}, clear=False):
            self.assertIn("v9.9.9", default_title())
            self.assertIn("v9.9.9", default_message())
        args = parse_args(["--desktop-on", "--title", "T", "--message", "M"])
        self.assertTrue(args.desktop_on)
        buf = io.StringIO()
        with patch("sys.stdout", buf):
            write_selection(None, ["WMI", "SOUND"])
        self.assertEqual(buf.getvalue(), "WMI\nSOUND\n")

    def test_draw_checklist_with_mock_window(self) -> None:
        """draw_checklist paints via a fake curses window."""
        win = MagicMock()
        win.getmaxyx.return_value = (40, 80)
        model = build_default_model(desktop_on=True, title="Setup", message="line1\nline2")
        model.focus = model.ok_index
        layout = draw_checklist(win, model, 0)
        self.assertIsInstance(layout, MouseHitLayout)
        self.assertEqual(len(layout.item_spans), 4)
        win.refresh.assert_called()
        win.addstr.side_effect = tui.curses.error("overflow")
        call_attr(tui, "_addstr", win, 0, 0, "x")

    def test_draw_checklist_buttons_distinct_on_24x80(self) -> None:
        """On a standard 24x80 terminal, item text and buttons use different rows."""
        win = MagicMock()
        win.getmaxyx.return_value = (24, 80)
        long_desc = (
            "Installs the WMI hotkey daemon for ScreenPad brightness, "
            "fan Quiet/Balanced/Performance, camera privacy, and window swap."
        )
        model = ChecklistModel(
            tags=["WMI", "TOUCHPAD", "SOUND", "DESKTOP"],
            labels=[long_desc] * 4,
            selected=[True, True, True, True],
            focus=0,
            title="Choose components",
            message_lines=["Installing tools.", "Space selects. Enter confirms."],
        )
        layout = draw_checklist(win, model, 0)
        self.assertEqual(layout.ok_row, 22)
        for start, end in layout.item_spans:
            self.assertLess(start, layout.ok_row)
            self.assertLessEqual(end, layout.ok_row)

    def test_accent_pair_ansi_fallback(self) -> None:
        """Accent pair uses nearest ANSI color when palette is not mutable."""
        with patch.dict("os.environ", {"ASUS_TUI_FORCE_PLAIN": "1"}, clear=False):
            self.assertEqual(call_attr(tui, "_init_accent_pair", MagicMock(), (1, 2, 3)), 0)
        with (
            patch("asus_install_selection_tui.curses.has_colors", return_value=True),
            patch("asus_install_selection_tui.curses.can_change_color", return_value=False),
            patch("asus_install_selection_tui._start_color_safe"),
            patch("asus_install_selection_tui.curses.init_pair") as init_pair,
        ):
            pair = call_attr(tui, "_init_accent_pair", MagicMock(), (0, 0, 255))
            self.assertEqual(pair, 1)
            init_pair.assert_called()

    def test_accent_pair_custom_requires_more_than_16_colors(self) -> None:
        """Custom slot 16 needs COLORS > 16; 16-color terminals use ANSI fallback."""
        with (
            patch("asus_install_selection_tui.curses.has_colors", return_value=True),
            patch("asus_install_selection_tui.curses.can_change_color", return_value=True),
            patch.object(tui.curses, "COLORS", 17, create=True),
            patch("asus_install_selection_tui._start_color_safe"),
            patch("asus_install_selection_tui._init_color_pair_custom") as custom,
        ):
            self.assertEqual(call_attr(tui, "_init_accent_pair", MagicMock(), (10, 20, 30)), 1)
            custom.assert_called()
        with (
            patch("asus_install_selection_tui.curses.has_colors", return_value=True),
            patch("asus_install_selection_tui.curses.can_change_color", return_value=True),
            patch.object(tui.curses, "COLORS", 16, create=True),
            patch("asus_install_selection_tui._start_color_safe"),
            patch("asus_install_selection_tui._init_color_pair_custom") as custom,
            patch("asus_install_selection_tui.curses.init_pair") as init_pair,
            patch("asus_install_selection_tui.nearest_ansi16", return_value=4) as nearest,
        ):
            self.assertEqual(call_attr(tui, "_init_accent_pair", MagicMock(), (10, 20, 30)), 1)
            custom.assert_not_called()
            nearest.assert_called_once_with((10, 20, 30))
            init_pair.assert_called_once_with(1, 4, -1)

    def test_accent_pair_dispatch_helpers(self) -> None:
        """Mouse/key dispatch helpers for Ok and resize."""
        model = ChecklistModel(tags=["WMI"], labels=["x"], selected=[True], focus=0)
        layout = MouseHitLayout(item_spans=((1, 2),), ok_row=5, ok_col=1, cancel_col=8)
        with patch(
            "asus_install_selection_tui.curses.getmouse",
            return_value=(0, 2, 5, 0, tui.curses.BUTTON1_CLICKED),
        ):
            self.assertEqual(call_attr(tui, "_dispatch_curses_key", model, tui.curses.KEY_MOUSE, layout), "ok")
        with patch("asus_install_selection_tui.curses.getmouse", side_effect=tui.curses.error("no")):
            self.assertIsNone(call_attr(tui, "_read_mouse_action", model, layout))
        self.assertIsNone(call_attr(tui, "_dispatch_curses_key", model, tui.curses.KEY_RESIZE, layout))
        self.assertEqual(run_scripted(model, ""), EXIT_OK)

    def test_curses_loop_cancel_and_run_ui_error(self) -> None:
        """Interactive loop Esc path and curses.wrapper failure."""
        model = build_default_model(desktop_on=False, title="t", message="m")
        stdscr = MagicMock()
        stdscr.getch.side_effect = [27]
        with (
            patch("asus_install_selection_tui.curses.curs_set"),
            patch("asus_install_selection_tui.draw_checklist", return_value=MouseHitLayout((), 1, 1, 2)),
            patch("asus_install_selection_tui._init_accent_pair", return_value=0),
            patch("asus_install_selection_tui._enable_mouse"),
        ):
            self.assertEqual(call_attr(tui, "_curses_loop", stdscr, model), EXIT_CANCEL)
        with patch("asus_install_selection_tui.curses.wrapper", side_effect=tui.curses.error("tty")):
            self.assertEqual(call_attr(tui, "_run_ui", model, ""), EXIT_ERROR)
        with patch("asus_install_selection_tui.curses.mousemask", side_effect=tui.curses.error("m")):
            call_attr(tui, "_enable_mouse")
        with (
            patch("asus_install_selection_tui.curses.start_color"),
            patch("asus_install_selection_tui.curses.use_default_colors", side_effect=tui.curses.error("d")),
        ):
            call_attr(tui, "_start_color_safe")

    def test_resolve_display_version_formats_env_override(self) -> None:
        """ASUS_DISPLAY_VERSION without a v prefix is formatted for display."""
        with patch.dict("os.environ", {"ASUS_DISPLAY_VERSION": "1.2.3"}, clear=False):
            self.assertEqual(tui_version.resolve_display_version(), "v1.2.3")

    def test_read_project_version_skips_invalid_utf8(self) -> None:
        """Unreadable VERSION files fall through to the next candidate."""
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / "VERSION"
            bad.write_bytes(b"\xff\xfe")
            good = PROJECT_ROOT / "VERSION"
            with patch.dict("os.environ", {"INSTALL_SOURCE_DIR": tmp}, clear=False):
                self.assertEqual(
                    tui_version.read_project_version(),
                    good.read_text(encoding="utf-8").strip(),
                )


if __name__ == "__main__":
    unittest.main()
