#!/usr/bin/env python3
"""GNOME Window Swap extension helpers for the ASUS hotkey daemon."""

import re
import shutil
import subprocess
import threading
import time

from asus_hotkey_daemon_desktop_family import desktop_family_hint
from asus_hotkey_daemon_session import run_in_desktop_session
from asus_hotkey_daemon_window_move import _emit_window_move, _opposite_direction
from evdev import ecodes

_GNOME_WINDOW_SWAP_UUID = "asus-window-swap@ventura8.github.com"
_WINDOW_SWAP_DBUS_READY_LOCK = threading.Lock()
_WINDOW_SWAP_DBUS_READY = {"ready": None, "expires": 0.0}
_WINDOW_SWAP_DBUS_READY_TTL_SECS = 30
_WINDOW_SWAP_DBUS_NOT_READY_TTL_SECS = 0.5
_WINDOW_SWAP_PRIME_DEADLINE_SECS = 2


_XDOTOOL_POSITION_RE = re.compile(r"Position:\s*(-?\d+),(-?\d+)")
_XDOTOOL_GEOMETRY_RE = re.compile(r"Geometry:\s*(\d+)x(\d+)")
_XDOTOOL_MOUSE_X_RE = re.compile(r"(?:^|\n)X=(-?\d+)")
_XDOTOOL_MOUSE_Y_RE = re.compile(r"(?:^|\n)Y=(-?\d+)")


def _parse_xdotool_window_center(stdout_text):
    """Return (cx, cy) from xdotool getwindowgeometry output, or None."""
    pos_match = _XDOTOOL_POSITION_RE.search(str(stdout_text))
    geo_match = _XDOTOOL_GEOMETRY_RE.search(str(stdout_text))
    if pos_match is None or geo_match is None:
        return None
    left, top = int(pos_match.group(1)), int(pos_match.group(2))
    width, height = int(geo_match.group(1)), int(geo_match.group(2))
    if not _usable_window_geometry(left, top, width, height):
        return None
    return left + width // 2, top + height // 2


def _usable_window_geometry(left, top, width, height):
    """Return False for Wayland 1x1 proxy windows at off-screen placeholders."""
    if width <= 1 or height <= 1:
        return False
    return left > -50 and top > -50


def _parse_xdotool_mouse_point(stdout_text):
    """Return (x, y) from xdotool getmouselocation --shell output, or None."""
    x_match = _XDOTOOL_MOUSE_X_RE.search(str(stdout_text))
    y_match = _XDOTOOL_MOUSE_Y_RE.search(str(stdout_text))
    if x_match is None or y_match is None:
        return None
    return int(x_match.group(1)), int(y_match.group(1))


def _run_xdotool_query(args):
    """Run an xdotool query in the desktop session; return stdout or None."""
    if not shutil.which("xdotool"):
        return None
    try:
        result = run_in_desktop_session(["xdotool", *args], 2, requires_dbus=True)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode:
        return None
    return result.stdout


def _focused_window_point():
    """Best-effort focused-window center via xdotool (X11/XWayland only)."""
    stdout = _run_xdotool_query(["getactivewindow", "getwindowgeometry"])
    if stdout is None:
        return None
    return _parse_xdotool_window_center(stdout)


def _pointer_point():
    """Best-effort pointer position via xdotool (works on GNOME Wayland)."""
    stdout = _run_xdotool_query(["getmouselocation", "--shell"])
    if stdout is None:
        return None
    return _parse_xdotool_mouse_point(stdout)


def _focus_hint_point():
    """Prefer real window geometry; fall back to pointer (Wayland-safe)."""
    window_point = _focused_window_point()
    if window_point is not None:
        return window_point
    return _pointer_point()


def _point_in_monitor(monitor, point_x, point_y, scale):
    """Return True when the point lies inside *monitor* scaled by *scale*.

    Right and bottom edges are exclusive so shared edges match only the
    adjacent monitor according to the intended boundary convention.
    """
    left = monitor["x"] * scale
    top = monitor["y"] * scale
    right = left + monitor["width"] * scale
    bottom = top + monitor["height"] * scale
    return left <= point_x < right and top <= point_y < bottom


def _logical_layout_bounds(monitors):
    """Return (min_left, min_top, max_right, max_bottom) of the layout."""
    if not monitors:
        return 0, 0, 0, 0
    first = monitors[0]
    min_left = first["x"]
    min_top = first["y"]
    max_right = first["x"] + first["width"]
    max_bottom = first["y"] + first["height"]
    for monitor in monitors[1:]:
        min_left = min(min_left, monitor["x"])
        min_top = min(min_top, monitor["y"])
        max_right = max(max_right, monitor["x"] + monitor["width"])
        max_bottom = max(max_bottom, monitor["y"] + monitor["height"])
    return min_left, min_top, max_right, max_bottom


def _point_outside_logical_layout(monitors, point_x, point_y):
    """Return True when the point is outside the unscaled logical bounding box."""
    min_left, min_top, max_right, max_bottom = _logical_layout_bounds(monitors)
    if point_x < min_left or point_y < min_top:
        return True
    return point_x >= max_right or point_y >= max_bottom


def _monitor_scale_value(monitor, scale_from_monitor):
    """Return the scale to apply when hit-testing *monitor*."""
    if not scale_from_monitor:
        return 1.0
    return float(monitor.get("scale") or 1.0)


def _monitor_index_for_scale(monitors, point_x, point_y, scale_from_monitor):
    """Return monitor index using logical scale 1 or each monitor's scale field."""
    for idx, monitor in enumerate(monitors):
        scale = _monitor_scale_value(monitor, scale_from_monitor)
        if scale_from_monitor and scale == 1.0:
            continue
        if _point_in_monitor(monitor, point_x, point_y, scale):
            return idx
    return None


def _monitor_index_at_point(monitors, point_x, point_y):
    """Return monitor index containing the point (logical, then scale-mapped)."""
    logical_idx = _monitor_index_for_scale(monitors, point_x, point_y, False)
    if logical_idx is not None:
        return logical_idx
    # xdotool on GNOME Wayland often already reports Mutter *logical* pixels
    # (ScreenSize). Scaling those by 2.0 falsely maps ScreenPad coords onto the
    # main display — only apply scale when the point is outside logical bounds.
    if not _point_outside_logical_layout(monitors, point_x, point_y):
        return None
    return _monitor_index_for_scale(monitors, point_x, point_y, True)


def _direction_name(direction_key):
    """Return the AsusWindowSwap D-Bus direction token for *direction_key*."""
    return {
        ecodes.KEY_DOWN: "down",
        ecodes.KEY_UP: "up",
        ecodes.KEY_LEFT: "left",
        ecodes.KEY_RIGHT: "right",
    }.get(direction_key)


def _parse_gdbus_bool(stdout_text):
    """Parse gdbus ``(true,)`` / ``(false,)`` stdout into bool or None."""
    text = str(stdout_text).strip().lower()
    if text.startswith("(true"):
        return True
    if text.startswith("(false"):
        return False
    return None


def _parse_gdbus_int(stdout_text):
    """Parse gdbus ``(N,)`` stdout into int or None."""
    match = re.search(r"\((-?\d+),\)", str(stdout_text))
    if match is None:
        return None
    return int(match.group(1))


def _gdbus_window_swap_command(method_name, args=None):
    """Build gdbus argv for one AsusWindowSwap method call."""
    command = [
        "gdbus",
        "call",
        "--session",
        "--dest",
        "org.gnome.Shell",
        "--object-path",
        "/org/gnome/Shell/Extensions/AsusWindowSwap",
        "--method",
        f"org.gnome.Shell.Extensions.AsusWindowSwap.{method_name}",
    ]
    if args:
        command.extend(args)
    return command


def _invoke_gdbus_window_swap(command):
    """Run one gdbus window-swap call; return stdout or None."""
    try:
        result = run_in_desktop_session(command, 2, requires_dbus=True)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode:
        return None
    return result.stdout


def _mutter_window_swap_call(method_name, args=None, attempts=3):
    """Call AsusWindowSwap extension method; return stdout or None when missing.

    *attempts* caps gdbus retries (default 3 for async/deferred callers; pass 1
    for synchronous event-thread callers to avoid blocking).
    """
    if not shutil.which("gdbus"):
        return None
    command = _gdbus_window_swap_command(method_name, args)
    for attempt in range(max(1, attempts)):
        stdout = _invoke_gdbus_window_swap(command)
        if stdout is not None:
            return stdout
        if attempt < attempts - 1:
            time.sleep(0.05)
    return None


def _gnome_window_swap_dbus_ready_ttl(ready):
    """Positive readiness keeps a long TTL; misses expire quickly for re-probe."""
    if ready:
        return _WINDOW_SWAP_DBUS_READY_TTL_SECS
    return _WINDOW_SWAP_DBUS_NOT_READY_TTL_SECS


def _gnome_window_swap_dbus_ready(attempts=3):
    """Probe AsusWindowSwap D-Bus readiness and cache the result with TTL."""
    ready = _mutter_window_swap_call("GetFocusedMonitor", attempts=attempts) is not None
    _gnome_window_swap_dbus_cache_set(
        ready,
        time.monotonic() + _gnome_window_swap_dbus_ready_ttl(ready),
    )
    return ready


def _gnome_window_swap_dbus_cache_get(now):
    """Return cached readiness under lock, or None when expired/unknown."""
    with _WINDOW_SWAP_DBUS_READY_LOCK:
        cached = _WINDOW_SWAP_DBUS_READY.get("ready")
        expires = _WINDOW_SWAP_DBUS_READY.get("expires", 0.0)
        if cached is not None and now < expires:
            return cached
    return None


def _gnome_window_swap_dbus_cache_set(ready, expires):
    """Store readiness probe result under lock."""
    with _WINDOW_SWAP_DBUS_READY_LOCK:
        _WINDOW_SWAP_DBUS_READY["ready"] = ready
        _WINDOW_SWAP_DBUS_READY["expires"] = expires


def _gnome_window_swap_dbus_ready_fast():
    """Cached readiness only for the hotkey event thread (no sync probe).

    Cache misses are treated as not ready so the sync path defers to
    `_start_deferred_window_swap_worker` instead of blocking on gdbus.
    """
    now = time.monotonic()
    cached = _gnome_window_swap_dbus_cache_get(now)
    if cached is not None:
        return cached
    return False


def _run_gnome_session_cli(command, timeout_secs):
    """Run a session CLI and return True only on exit status 0."""
    try:
        completed = run_in_desktop_session(command, timeout_secs, requires_dbus=True)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return completed is not None and not completed.returncode


def _allow_gnome_user_extensions():
    """Clear the global GNOME user-extensions kill switch (best-effort)."""
    # disable-user-extensions=true leaves AsusWindowSwap INITIALIZED with no
    # D-Bus object — ShowOsd and MoveFocused both fail until this is false.
    return _run_gnome_session_cli(
        ["gsettings", "set", "org.gnome.shell", "disable-user-extensions", "false"],
        3,
    )


def _enable_gnome_window_swap_via_cli():
    """Enable the window-swap UUID; honor CLI exit status (fail closed)."""
    _allow_gnome_user_extensions()
    if not shutil.which("gnome-extensions"):
        return False
    return _run_gnome_session_cli(
        ["gnome-extensions", "enable", _GNOME_WINDOW_SWAP_UUID],
        3,
    )


def _wait_gnome_window_swap_dbus_ready():
    """Poll with single-shot probes until ready or the prime deadline elapses."""
    deadline = time.monotonic() + _WINDOW_SWAP_PRIME_DEADLINE_SECS
    while time.monotonic() < deadline:
        if _gnome_window_swap_dbus_ready(attempts=1):
            return True
        time.sleep(0.1)
    return False


def prime_gnome_window_swap_extension():
    """Load the GNOME Window Swap extension when gsettings lists it but Shell has not."""
    if desktop_family_hint() != "gnome":
        return
    if _gnome_window_swap_dbus_ready(attempts=1):
        return
    if not _enable_gnome_window_swap_via_cli():
        return
    _wait_gnome_window_swap_dbus_ready()


def _list_index_for_mutter_index(monitors, mutter_idx):
    """Map Meta monitor index to an index in the topology *monitors* list."""
    for idx, monitor in enumerate(monitors):
        listed = monitor.get("index")
        if listed is not None and int(listed) == mutter_idx:
            return idx
    if 0 <= mutter_idx < len(monitors):
        return mutter_idx
    return None


def _mutter_focused_monitor_index(monitor_count, attempts=3):
    """Return Mutter focus monitor index, or None when unavailable."""
    stdout = _mutter_window_swap_call("GetFocusedMonitor", attempts=attempts)
    if stdout is None:
        return None
    index = _parse_gdbus_int(stdout)
    if index is None or index < 0 or index >= monitor_count:
        return None
    return index


def _focused_monitor_index(monitors, attempts=3):
    """Return focused monitor index via Mutter extension, else X11 geometry."""
    if not monitors:
        return None
    mutter_idx = _mutter_focused_monitor_index(len(monitors), attempts=attempts)
    if mutter_idx is not None:
        list_idx = _list_index_for_mutter_index(monitors, mutter_idx)
        if list_idx is not None:
            return list_idx
    point = _focused_window_point()
    if point is None:
        return None
    return _monitor_index_at_point(monitors, point[0], point[1])


def _mutter_move_focused(direction_key, attempts=3):
    """Move focused window via extension; True/False moved, None if unavailable."""
    name = _direction_name(direction_key)
    if name is None:
        return None
    stdout = _mutter_window_swap_call("MoveFocused", [name], attempts=attempts)
    if stdout is None:
        return None
    return _parse_gdbus_bool(stdout)


def _try_mutter_move_both_directions(direction_key, attempts=3):
    """Try planned direction then opposite; True/False moved, None if D-Bus unavailable."""
    moved = _mutter_move_focused(direction_key, attempts=attempts)
    if moved is True:
        return True
    if moved is None:
        return None
    return _mutter_move_focused(_opposite_direction(direction_key), attempts=attempts) is True


def _uinput_move_both_directions(ui, direction_key):
    """Emit Super+Shift+Arrow for planned direction, then opposite."""
    opposite = _opposite_direction(direction_key)
    if _emit_window_move(ui, direction_key):
        return True
    return _emit_window_move(ui, opposite)


def _apply_gnome_window_move(ui, direction_key, attempts=3):
    """Move on GNOME via Mutter extension (edge-aware); fall back to uinput.

    Does not prime the extension here — priming can block the hotkey thread.
    Callers that need priming must run it on a deferred worker first.
    """
    result = _try_mutter_move_both_directions(direction_key, attempts=attempts)
    if result is True:
        return True
    if result is False:
        return _uinput_move_both_directions(ui, direction_key)
    return _emit_window_move(ui, direction_key)
