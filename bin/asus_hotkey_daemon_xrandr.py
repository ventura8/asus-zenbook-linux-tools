"""xrandr topology parsing helpers for the ASUS hotkey daemon."""

import re
import subprocess

from asus_display_mode_profiles import PROFILE_ALL

_XRANDR_GEOMETRY_RE = re.compile(r"^(\d+)x(\d+)([+-]\d+)([+-]\d+)$")


def split_xrandr_geometry(geom):
    """Parse an xrandr WxH±X±Y token into a monitor dict fragment, or None."""
    if not geom:
        return None
    match = _XRANDR_GEOMETRY_RE.match(geom)
    if match is None:
        return None
    width_text, height_text, x_text, y_text = match.groups()
    return {
        "x": int(x_text),
        "y": int(y_text),
        "width": max(1, int(width_text)),
        "height": max(1, int(height_text)),
        "scale": 1.0,
    }


def find_xrandr_geometry_token(parts):
    """Return the first WxH±X±Y token from an xrandr line split, or None."""
    for token in parts:
        if _XRANDR_GEOMETRY_RE.match(token):
            return token
    return None


def parse_xrandr_connected_line(line):
    """Parse one xrandr connected output line into a monitor dict, or None."""
    if " connected " not in line:
        return None
    parts = line.split()
    if len(parts) < 3:
        return None
    geom = find_xrandr_geometry_token(parts)
    parsed = split_xrandr_geometry(geom) if geom else None
    if parsed is None:
        return None
    parsed["primary"] = "primary" in parts
    return parsed


def mark_first_monitor_primary(monitors):
    """Ensure at least one monitor is marked primary without mutating input."""
    if not monitors:
        return monitors
    result = [dict(monitor) for monitor in monitors]
    if not any(monitor["primary"] for monitor in result):
        result[0]["primary"] = True
    return result


def parse_xrandr_topology_output(output_text):
    """Build a topology map from xrandr --query output."""
    monitors = []
    for line in str(output_text).splitlines():
        parsed = parse_xrandr_connected_line(line)
        if parsed is None:
            continue
        parsed["index"] = len(monitors)
        monitors.append(parsed)
    if not monitors:
        return None, None
    return PROFILE_ALL, mark_first_monitor_primary(monitors)


def detect_xrandr_topology_map(run_in_desktop_session):
    """Detect monitor geometry via xrandr when Mutter topology is unavailable."""
    try:
        result = run_in_desktop_session(["xrandr", "--query"], 2, requires_dbus=False)
    except (OSError, subprocess.TimeoutExpired):
        return None, None
    if result.returncode:
        return None, None
    return parse_xrandr_topology_output(result.stdout)
