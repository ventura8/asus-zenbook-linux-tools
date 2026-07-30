"""Resolve desktop OS accent color to RGB for the install selection TUI."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from typing import Final

DEFAULT_ACCENT_RGB: Final[tuple[int, int, int]] = (53, 132, 228)  # GNOME blue #3584e4

_GNOME_ACCENT_HEX: Final[dict[str, str]] = {
    "blue": "#3584e4",
    "teal": "#2190a4",
    "green": "#3a944a",
    "yellow": "#c88800",
    "orange": "#ed5b00",
    "red": "#e62d42",
    "pink": "#d56199",
    "purple": "#9141ac",
    "slate": "#6f8396",
}

_RGB_TRIPLE = re.compile(r"^\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*$")
_HEX_COLOR = re.compile(r"^#?([0-9A-Fa-f]{6})$")
_GNOME_FAMILIES = frozenset({"", "gnome", "cinnamon", "mate", "ubuntu"})
_KDE_FAMILIES = frozenset({"", "kde"})


def clamp_channel(value: int) -> int:
    """Clamp one 8-bit color channel."""
    return max(0, min(255, int(value)))


def parse_rgb_csv(text: str) -> tuple[int, int, int] | None:
    """Parse ``R,G,B`` into an RGB triple."""
    match = _RGB_TRIPLE.match(text)
    if not match:
        return None
    return (
        clamp_channel(int(match.group(1))),
        clamp_channel(int(match.group(2))),
        clamp_channel(int(match.group(3))),
    )


def parse_rgb_hex(text: str) -> tuple[int, int, int] | None:
    """Parse ``#RRGGBB`` / ``RRGGBB`` into an RGB triple."""
    match = _HEX_COLOR.match(text)
    if not match:
        return None
    hex_body = match.group(1)
    return (
        int(hex_body[0:2], 16),
        int(hex_body[2:4], 16),
        int(hex_body[4:6], 16),
    )


def parse_rgb_text(raw: str) -> tuple[int, int, int] | None:
    """Parse ``R,G,B`` or ``#RRGGBB`` / ``RRGGBB`` into an RGB triple."""
    text = raw.strip().strip("'\"")
    if not text:
        return None
    return parse_rgb_csv(text) or parse_rgb_hex(text)


def gnome_accent_name_to_rgb(name: str) -> tuple[int, int, int] | None:
    """Map a GNOME accent-color enum token to RGB."""
    key = name.strip().strip("'\"").lower()
    hex_value = _GNOME_ACCENT_HEX.get(key)
    if hex_value is None:
        return None
    return parse_rgb_text(hex_value)


def _rgb_from_spaced_env(raw: str) -> tuple[int, int, int] | None:
    parts = raw.split()
    if len(parts) != 3 or not all(part.isdigit() for part in parts):
        return None
    return (
        clamp_channel(int(parts[0])),
        clamp_channel(int(parts[1])),
        clamp_channel(int(parts[2])),
    )


def _env_raw_accent(env: dict[str, str] | None) -> str:
    source = env if env is not None else os.environ
    return source.get("ASUS_TUI_ACCENT_RGB", "").strip()


def _is_spaced_rgb(raw: str) -> bool:
    return " " in raw and "," not in raw and not raw.startswith("#")


def rgb_from_env(env: dict[str, str] | None = None) -> tuple[int, int, int] | None:
    """Read ``ASUS_TUI_ACCENT_RGB`` (``R G B`` or ``R,G,B`` / hex)."""
    raw = _env_raw_accent(env)
    if not raw:
        return None
    if _is_spaced_rgb(raw):
        return _rgb_from_spaced_env(raw)
    return parse_rgb_text(raw)


def _run_capture(argv: list[str], timeout: float = 2.0) -> str:
    """Run a command and return stripped stdout, or empty on failure."""
    try:
        completed = subprocess.run(
            argv,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
            stdin=subprocess.DEVNULL,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if completed.returncode:
        return ""
    return completed.stdout.strip()


def read_gnome_accent_rgb() -> tuple[int, int, int] | None:
    """Read GNOME/Cinnamon accent via gsettings when available."""
    if shutil.which("gsettings") is None:
        return None
    raw = _run_capture(
        ["gsettings", "get", "org.gnome.desktop.interface", "accent-color"],
    )
    if not raw:
        return None
    return gnome_accent_name_to_rgb(raw)


def _kreadconfig_bin() -> str | None:
    for name in ("kreadconfig6", "kreadconfig5"):
        path = shutil.which(name)
        if path:
            return path
    return None


def read_kde_accent_rgb() -> tuple[int, int, int] | None:
    """Read Plasma AccentColor from kdeglobals when available."""
    kread = _kreadconfig_bin()
    if kread is None:
        return None
    raw = _run_capture(
        [kread, "--file", "kdeglobals", "--group", "General", "--key", "AccentColor"],
    )
    if not raw:
        return None
    return parse_rgb_text(raw)


def _try_gnome_then_kde() -> tuple[int, int, int] | None:
    return read_gnome_accent_rgb() or read_kde_accent_rgb()


def _accent_from_gnome_family(family: str) -> tuple[int, int, int] | None:
    if family not in _GNOME_FAMILIES:
        return None
    return read_gnome_accent_rgb()


def _accent_from_kde_family(family: str) -> tuple[int, int, int] | None:
    if family not in _KDE_FAMILIES:
        return None
    return read_kde_accent_rgb()


def _accent_from_family(family: str) -> tuple[int, int, int] | None:
    found = _accent_from_gnome_family(family) or _accent_from_kde_family(family)
    if found is not None:
        return found
    if family in _GNOME_FAMILIES | _KDE_FAMILIES:
        return None
    return _try_gnome_then_kde()


def resolve_accent_rgb(
    env: dict[str, str] | None = None,
    *,
    prefer_family: str = "",
) -> tuple[int, int, int]:
    """Resolve accent RGB: env override → DE readers → default blue."""
    from_env = rgb_from_env(env)
    if from_env is not None:
        return from_env
    family = (prefer_family or "").strip().lower()
    return _accent_from_family(family) or DEFAULT_ACCENT_RGB


def format_accent_rgb(rgb: tuple[int, int, int]) -> str:
    """Format RGB as ``R G B`` for shell env."""
    return f"{rgb[0]} {rgb[1]} {rgb[2]}"


def nearest_ansi16(rgb: tuple[int, int, int]) -> int:
    """Map RGB to a rough curses/ANSI 0–7 color index."""
    palette = (
        (0, 0, 0),
        (205, 0, 0),
        (0, 205, 0),
        (205, 205, 0),
        (0, 0, 238),
        (205, 0, 205),
        (0, 205, 205),
        (229, 229, 229),
    )
    best_idx = 4
    best_dist = 1 << 30
    for idx, (pr, pg, pb) in enumerate(palette):
        dist = (rgb[0] - pr) ** 2 + (rgb[1] - pg) ** 2 + (rgb[2] - pb) ** 2
        if dist < best_dist:
            best_dist = dist
            best_idx = idx
    return best_idx
