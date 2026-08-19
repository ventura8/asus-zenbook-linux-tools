"""Ncurses install component checklist with mouse and OS accent theming."""

from __future__ import annotations

import argparse
import curses
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path

from asus_i18n import gettext_message
from asus_install_selection_accent import (
    format_accent_rgb,
    nearest_ansi16,
    resolve_accent_rgb,
)
from asus_install_selection_version import resolve_display_version

EXIT_OK = 0
EXIT_CANCEL = 1
EXIT_ERROR = 2


@dataclass
class ChecklistModel:
    """Mutable checklist state for keyboard/mouse handling."""

    tags: list[str]
    labels: list[str]
    selected: list[bool]
    focus: int = 0
    title: str = ""
    message_lines: list[str] = field(default_factory=list)

    @property
    def item_count(self) -> int:
        """Number of checklist items."""
        return len(self.tags)

    @property
    def ok_index(self) -> int:
        """Focus index of the Ok button."""
        return self.item_count

    @property
    def cancel_index(self) -> int:
        """Focus index of the Cancel button."""
        return self.item_count + 1

    @property
    def max_focus(self) -> int:
        """Highest valid focus index."""
        return self.cancel_index

    def move_focus(self, delta: int) -> None:
        """Move focus by delta with wrap."""
        count = self.max_focus + 1
        self.focus = (self.focus + delta) % count

    def toggle_focus_item(self) -> None:
        """Toggle checkbox when focus is on an item row."""
        if 0 <= self.focus < self.item_count:
            self.selected[self.focus] = not self.selected[self.focus]

    def selected_tags(self) -> list[str]:
        """Return tags currently checked."""
        return [tag for tag, on in zip(self.tags, self.selected, strict=True) if on]


@dataclass(frozen=True)
class MouseHitLayout:
    """Geometry used to map mouse clicks to checklist actions."""

    item_spans: tuple[tuple[int, int], ...]
    ok_row: int
    ok_col: int
    cancel_col: int
    ok_width: int = 4
    cancel_width: int = 8

    def item_index_at_row(self, row: int) -> int | None:
        """Return checklist item index for a screen row, if any."""
        for index, (start, end) in enumerate(self.item_spans):
            if start <= row < end:
                return index
        return None


def wrap_text(text: str, width: int) -> list[str]:
    """Soft-wrap text on spaces to at most ``width`` columns."""
    if width <= 0:
        return [text] if text else [""]
    words = text.split()
    if not words:
        return [""]
    return _wrap_words(words, width)


def _wrap_words(words: list[str], width: int) -> list[str]:
    lines: list[str] = []
    current = words[0]
    for word in words[1:]:
        candidate = f"{current} {word}"
        if len(candidate) <= width:
            current = candidate
            continue
        lines.append(current)
        current = word
    lines.append(current)
    return lines


@dataclass(frozen=True)
class _ItemDraw:
    """Parameters for drawing one checklist item block."""

    tag: str
    mark: str
    desc_lines: list[str]
    inner: int
    attr: int


def _component_descriptions() -> list[str]:
    """Localized multi-line descriptions shown under each component tag."""
    return [
        gettext_message(
            "Installs the WMI hotkey daemon for ScreenPad brightness, fan Quiet/"
            "Balanced/Performance, camera privacy, and window swap across monitors.",
        ),
        gettext_message(
            "Installs the touchpad Share gesture listener so a top-left corner tap "
            "opens your desktop screenshot tool (GNOME, Spectacle, and peers).",
        ),
        gettext_message(
            "Installs the speaker amplifier fix and a suspend/resume hook so supported ZenBook audio recovers after boot and after sleep.",
        ),
        gettext_message(
            "Adds Display Toggle, MyASUS Settings, and Share keyboard shortcuts for GNOME, KDE Plasma, XFCE, LXQt, Cinnamon, or MATE.",
        ),
    ]


def build_default_model(
    *,
    desktop_on: bool,
    title: str,
    message: str,
) -> ChecklistModel:
    """Build the four-component checklist with detailed descriptions."""
    tags = ["WMI", "TOUCHPAD", "SOUND", "DESKTOP"]
    selected = [True, True, True, desktop_on]
    lines = list(message.splitlines())
    return ChecklistModel(
        tags=tags,
        labels=_component_descriptions(),
        selected=selected,
        title=title,
        message_lines=lines,
    )


def truncate_label(text: str, max_len: int) -> str:
    """Truncate with ellipsis at a word boundary when possible."""
    if max_len <= 0:
        return ""
    if len(text) <= max_len:
        return text
    if max_len <= 3:
        return text[:max_len]
    body = text[: max_len - 3]
    if " " in body:
        body = body.rsplit(" ", 1)[0]
    return f"{body}..."


def _enter_action(model: ChecklistModel) -> str:
    if model.focus == model.cancel_index:
        return "cancel"
    return "ok"


def handle_key(model: ChecklistModel, key: int) -> str | None:
    """Apply one keycode; return ``ok``, ``cancel``, or None to continue."""
    if key == 27:
        return "cancel"
    if key in (curses.KEY_ENTER, 10, 13):
        return _enter_action(model)
    if key in (curses.KEY_UP, ord("k")):
        model.move_focus(-1)
        return None
    if key in (curses.KEY_DOWN, ord("j")):
        model.move_focus(1)
        return None
    _handle_space(model, key)
    return None


def _handle_space(model: ChecklistModel, key: int) -> None:
    if key == ord(" "):
        model.toggle_focus_item()


def _click_buttons(layout: MouseHitLayout, row: int, col: int) -> str | None:
    if row != layout.ok_row:
        return None
    if layout.ok_col <= col < layout.ok_col + layout.ok_width:
        return "ok"
    if layout.cancel_col <= col < layout.cancel_col + layout.cancel_width:
        return "cancel"
    return None


def handle_mouse_click(
    model: ChecklistModel,
    layout: MouseHitLayout,
    row: int,
    col: int,
) -> str | None:
    """Handle a BUTTON1 click; return action or None."""
    button = _click_buttons(layout, row, col)
    if button is not None:
        return button
    index = layout.item_index_at_row(row)
    if index is None:
        return None
    model.focus = index
    model.toggle_focus_item()
    return None


def _force_plain() -> bool:
    return os.environ.get("ASUS_TUI_FORCE_PLAIN", "") == "1"


def _start_color_safe() -> None:
    curses.start_color()
    try:
        curses.use_default_colors()
    except curses.error:
        pass


def _init_color_pair_custom(rgb: tuple[int, int, int], pair: int) -> None:
    curses.init_color(
        16,
        rgb[0] * 1000 // 255,
        rgb[1] * 1000 // 255,
        rgb[2] * 1000 // 255,
    )
    curses.init_pair(pair, 16, -1)


def _init_accent_pair(_stdscr: curses.window, rgb: tuple[int, int, int]) -> int:
    """Create color pair 1 for accent; return pair number (0 if unavailable)."""
    if _force_plain() or not curses.has_colors():
        return 0
    _start_color_safe()
    pair = 1
    # Color index 16 requires COLORS > 16 (indices are 0..COLORS-1).
    if curses.can_change_color() and curses.COLORS > 16:
        _init_color_pair_custom(rgb, pair)
        return pair
    curses.init_pair(pair, nearest_ansi16(rgb), -1)
    return pair


def _addstr(win: curses.window, y: int, x: int, text: str, attr: int = 0) -> None:
    try:
        win.addstr(y, x, text, attr)
    except curses.error:
        pass


def _draw_frame(win: curses.window, height: int, width: int, title: str, pair: int) -> None:
    win.erase()
    attr = curses.color_pair(pair) | curses.A_BOLD if pair else curses.A_BOLD
    _addstr(win, 0, 0, "┌" + "─" * (width - 2) + "┐")
    label = truncate_label(f" {title} ", width - 2)
    _addstr(win, 0, max(1, (width - len(label)) // 2), label, attr)
    for row in range(1, height - 1):
        _addstr(win, row, 0, "│" + " " * (width - 2) + "│")
    _addstr(win, height - 1, 0, "└" + "─" * (width - 2) + "┘")


def _layout_rows(model: ChecklistModel, inner: int) -> tuple[int, int, list[list[str]]]:
    """Return message_row0, item_row0, and wrapped description lines per item."""
    message_row0 = 2
    item_row0 = message_row0 + len(model.message_lines) + 1
    desc_width = max(8, inner - 4)
    wrapped = [wrap_text(label, desc_width) for label in model.labels]
    return message_row0, item_row0, wrapped


def _draw_one_item(win: curses.window, row: int, item: _ItemDraw) -> int:
    """Draw one checklist item; return next free row."""
    header = truncate_label(f"{item.mark} {item.tag}", item.inner)
    _addstr(win, row, 2, header, item.attr)
    row += 1
    for line in item.desc_lines:
        _addstr(win, row, 6, truncate_label(line, max(0, item.inner - 4)), item.attr)
        row += 1
    return row + 1


@dataclass(frozen=True)
class _ItemsPaint:
    """Shared paint context for the item list."""

    item_row0: int
    inner: int
    accent: int
    wrapped: list[list[str]]
    max_row: int


def _clip_desc_lines(desc_lines: list[str], row: int, max_row: int) -> list[str]:
    """Keep description lines that fit after the header within max_row."""
    first_desc = row + 1
    if first_desc > max_row:
        return []
    return desc_lines[: max_row - first_desc + 1]


def _item_mark_and_attr(model: ChecklistModel, idx: int, accent: int) -> tuple[str, int]:
    """Return checklist mark text and focus attribute for one item."""
    mark = "[x]" if model.selected[idx] else "[ ]"
    attr = accent if idx == model.focus else 0
    return mark, attr


def _draw_items(
    win: curses.window,
    model: ChecklistModel,
    paint: _ItemsPaint,
) -> tuple[tuple[int, int], ...]:
    """Draw items clipped above max_row; return start/end spans (end exclusive)."""
    spans: list[tuple[int, int]] = []
    row = paint.item_row0
    for idx, tag in enumerate(model.tags):
        if row > paint.max_row:
            break
        start = row
        mark, attr = _item_mark_and_attr(model, idx, paint.accent)
        desc = _clip_desc_lines(paint.wrapped[idx], row, paint.max_row)
        row = _draw_one_item(
            win,
            row,
            _ItemDraw(tag, mark, desc, paint.inner, attr),
        )
        spans.append((start, min(row - 1, paint.max_row + 1)))
    return tuple(spans)


def _paint_message(
    win: curses.window,
    model: ChecklistModel,
    message_row0: int,
    inner: int,
) -> None:
    for offset, line in enumerate(model.message_lines):
        _addstr(win, message_row0 + offset, 2, truncate_label(line, inner))


def _draw_buttons(
    win: curses.window,
    model: ChecklistModel,
    ok_row: int,
    width: int,
    accent: int,
) -> tuple[int, int]:
    ok_label = "<Ok>"
    cancel_label = "<Cancel>"
    gap = 4
    total = len(ok_label) + gap + len(cancel_label)
    start = max(2, (width - total) // 2)
    cancel_col = start + len(ok_label) + gap
    ok_attr = accent if model.focus == model.ok_index else 0
    cancel_attr = accent if model.focus == model.cancel_index else 0
    _addstr(win, ok_row, start, ok_label, ok_attr)
    _addstr(win, ok_row, cancel_col, cancel_label, cancel_attr)
    return start, cancel_col


def _accent_attr(pair: int) -> int:
    if pair:
        return curses.color_pair(pair) | curses.A_BOLD
    return curses.A_BOLD


def _checklist_hit_layout(
    spans: tuple[tuple[int, int], ...],
    ok_row: int,
    ok_col: int,
    cancel_col: int,
) -> MouseHitLayout:
    return MouseHitLayout(
        item_spans=spans,
        ok_row=ok_row,
        ok_col=ok_col,
        cancel_col=cancel_col,
        ok_width=len("<Ok>"),
        cancel_width=len("<Cancel>"),
    )


def draw_checklist(
    win: curses.window,
    model: ChecklistModel,
    pair: int,
) -> MouseHitLayout:
    """Draw model and return mouse hit-test layout."""
    height, width = win.getmaxyx()
    _draw_frame(win, height, width, model.title, pair)
    inner = width - 4
    message_row0, item_row0, wrapped = _layout_rows(model, inner)
    _paint_message(win, model, message_row0, inner)
    accent = _accent_attr(pair)
    # Reserve the bottom content row for Ok/Cancel so descriptions never share it.
    ok_row = max(1, height - 2)
    max_item_row = max(item_row0, ok_row - 1)
    spans = _draw_items(
        win,
        model,
        _ItemsPaint(item_row0, inner, accent, wrapped, max_item_row),
    )
    ok_col, cancel_col = _draw_buttons(win, model, ok_row, width, accent)
    win.refresh()
    return _checklist_hit_layout(spans, ok_row, ok_col, cancel_col)


def _script_char_to_key(char: str) -> int | None:
    mapping = {
        "\x1b": 27,
        "\n": 10,
        " ": ord(" "),
        "j": ord("j"),
        "k": ord("k"),
    }
    return mapping.get(char)


def run_scripted(model: ChecklistModel, keys: str) -> int:
    """Drive the state machine from a script string (no curses)."""
    for char in keys:
        key = _script_char_to_key(char)
        if key is None:
            continue
        action = handle_key(model, key)
        if action == "ok":
            return EXIT_OK
        if action == "cancel":
            return EXIT_CANCEL
    return EXIT_OK


def _enable_mouse() -> None:
    try:
        curses.mousemask(curses.ALL_MOUSE_EVENTS | curses.REPORT_MOUSE_POSITION)
        curses.mouseinterval(0)
    except curses.error:
        pass


def _read_mouse_action(model: ChecklistModel, layout: MouseHitLayout) -> str | None:
    try:
        _id, x, y, _z, button = curses.getmouse()
    except curses.error:
        return None
    if not (button & curses.BUTTON1_CLICKED or button & curses.BUTTON1_PRESSED):
        return None
    return handle_mouse_click(model, layout, y, x)


def _dispatch_curses_key(
    model: ChecklistModel,
    key: int,
    layout: MouseHitLayout,
) -> str | None:
    """Map one curses key/mouse event to an action."""
    if key == curses.KEY_MOUSE:
        return _read_mouse_action(model, layout)
    if key == curses.KEY_RESIZE:
        return None
    return handle_key(model, key)


def _curses_loop(stdscr: curses.window, model: ChecklistModel) -> int:
    """Run the interactive ncurses event loop until Ok or Cancel."""
    curses.curs_set(0)
    stdscr.keypad(True)
    rgb = resolve_accent_rgb(prefer_family=os.environ.get("ASUS_DESKTOP_FAMILY", ""))
    os.environ["ASUS_TUI_ACCENT_RGB"] = format_accent_rgb(rgb)
    pair = _init_accent_pair(stdscr, rgb)
    _enable_mouse()
    while True:
        layout = draw_checklist(stdscr, model, pair)
        action = _dispatch_curses_key(model, stdscr.getch(), layout)
        if action == "ok":
            return EXIT_OK
        if action == "cancel":
            return EXIT_CANCEL


def write_selection(path: Path | None, tags: list[str]) -> None:
    """Write selected tags one per line."""
    body = "\n".join(tags)
    if body:
        body += "\n"
    if path is None:
        sys.stdout.write(body)
        return
    path.write_text(body, encoding="utf-8")


def default_title() -> str:
    """Build the localized dialog title including VERSION."""
    version = resolve_display_version()
    return gettext_message("ASUS ZenBook Linux Setup %s") % version


def default_message() -> str:
    """Build the localized multi-line dialog message body."""
    version = resolve_display_version()
    first = gettext_message("Installing ASUS ZenBook Linux Tools %s.") % version
    second = gettext_message(
        "Select only the components you use. Unselected services and shortcuts will not be installed.",
    )
    keys = gettext_message("Space selects a component. Enter confirms. Esc cancels.")
    return f"{first}\n\n{second}\n\n{keys}"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Parse CLI arguments for the checklist entrypoint."""
    parser = argparse.ArgumentParser(description="ASUS install component checklist")
    parser.add_argument("--output", type=Path, help="Write selected tags to this file")
    parser.add_argument("--title", default="", help="Dialog title")
    parser.add_argument("--message", default="", help="Dialog message")
    parser.add_argument("--desktop-on", action="store_true", help="Pre-select DESKTOP")
    parser.add_argument("--script-keys", default="", help="Headless key sequence")
    return parser.parse_args(argv)


def _run_ui(model: ChecklistModel, script: str) -> int:
    """Run scripted or curses UI and return an exit status."""
    if script:
        return run_scripted(model, script)
    try:
        return curses.wrapper(lambda stdscr: _curses_loop(stdscr, model))
    except curses.error:
        return EXIT_ERROR


def main(argv: list[str] | None = None) -> int:
    """CLI entry: run checklist and write selected tags."""
    args = parse_args(argv)
    model = build_default_model(
        desktop_on=args.desktop_on,
        title=args.title or default_title(),
        message=args.message or default_message(),
    )
    script = args.script_keys or os.environ.get("ASUS_TUI_SCRIPT_KEYS", "")
    status = _run_ui(model, script)
    if status == EXIT_OK:
        write_selection(args.output, model.selected_tags())
    return status


if __name__ == "__main__":
    raise SystemExit(main())
