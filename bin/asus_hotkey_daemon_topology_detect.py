#!/usr/bin/env python3
"""Display topology detection for the ASUS hotkey daemon."""

import json
import subprocess

import asus_hotkey_daemon_state as hotkey_state
from asus_display_mode_profiles import (
    PROFILE_ALL,
    PROFILE_MAIN_ONLY,
    PROFILE_SCREENPAD_ONLY,
    SUPPORTED_PROFILE_IDS,
)
from asus_hotkey_daemon_session import run_in_desktop_session
from asus_hotkey_daemon_xrandr import detect_xrandr_topology_map as _detect_xrandr_topology_map_impl


def _normalize_detected_profile(profile_text):
    """Normalize profile detection output across supported forms."""
    normalized = str(profile_text).strip()
    if normalized in SUPPORTED_PROFILE_IDS:
        return normalized
    if normalized == "1":
        return PROFILE_ALL
    if normalized == "2":
        return PROFILE_MAIN_ONLY
    if normalized == "3":
        return PROFILE_SCREENPAD_ONLY
    return None


def _run_display_mode_backend(flag, timeout, parse_stdout, error_value=None):
    """Invoke the display-mode backend CLI and parse stdout via *parse_stdout*."""
    script_path = f"{hotkey_state.SCRIPT_BINDIR}/asus_display_mode.py"
    try:
        result = run_in_desktop_session(["python3", script_path, flag], timeout, requires_dbus=True)
    except (OSError, subprocess.TimeoutExpired):
        return error_value
    if result.returncode:
        return error_value
    return parse_stdout(result.stdout)


def _detect_display_profile():
    """Return the detected display profile id from the display-mode backend."""
    return _run_display_mode_backend("--detect", 2, _normalize_detected_profile)


def _parse_topology_output(output_text):
    """Parse '<profile>:<count>' output from the display-mode backend."""
    text = str(output_text).strip()
    if ":" not in text:
        return None, None
    profile_text, count_text = text.split(":", 1)
    profile_id = _normalize_detected_profile(profile_text)
    if profile_id is None:
        return None, None
    try:
        count = int(count_text)
    except ValueError:
        return None, None
    if count <= 0:
        return None, None
    return profile_id, count


def _detect_swap_topology():
    """Detect current display profile and active monitor count."""
    return _run_display_mode_backend("--detect-topology", 2, _parse_topology_output, (None, None))


def _parse_monitor_geometry(monitor):
    """Parse geometry fields from a topology monitor dict, or None on failure."""
    try:
        x_pos = int(monitor["x"])
        y_pos = int(monitor["y"])
        width = max(1, int(monitor.get("width", 1)))
        height = max(1, int(monitor.get("height", 1)))
        scale = float(monitor.get("scale", 1.0) or 1.0)
    except (KeyError, TypeError, ValueError):
        return None
    if scale <= 0:
        scale = 1.0
    return {
        "x": x_pos,
        "y": y_pos,
        "width": width,
        "height": height,
        "scale": scale,
        "primary": bool(monitor.get("primary", False)),
    }


def _optional_monitor_index(monitor, entry):
    """Copy optional Mutter index onto *entry* when present and valid."""
    index_raw = monitor.get("index")
    if index_raw is None:
        return
    try:
        entry["index"] = int(index_raw)
    except (TypeError, ValueError):
        pass


def _parse_monitor_entry(monitor):
    """Parse one monitor entry from a topology-map payload."""
    if not isinstance(monitor, dict):
        return None
    entry = _parse_monitor_geometry(monitor)
    if entry is None:
        return None
    _optional_monitor_index(monitor, entry)
    return entry


def _normalize_topology_payload(payload):
    """Return a profile and monitor list when the payload is well formed."""
    if not isinstance(payload, dict):
        return None, None
    profile_id = _normalize_detected_profile(payload.get("profile"))
    monitors = payload.get("monitors")
    if profile_id is None or not isinstance(monitors, list):
        return None, None
    return profile_id, monitors


def _collect_parsed_monitors(monitors):
    """Return parsed monitor data for a list of monitor payloads."""
    parsed = []
    for monitor in monitors:
        parsed_entry = _parse_monitor_entry(monitor)
        if parsed_entry is not None:
            parsed.append(parsed_entry)
    return parsed


def _parse_topology_map_payload(payload):
    """Normalize a parsed topology-map payload into profile and monitor data."""
    profile_id, monitors = _normalize_topology_payload(payload)
    if profile_id is None or monitors is None:
        return None, None
    parsed_monitors = _collect_parsed_monitors(monitors)
    if not parsed_monitors:
        return None, None
    return profile_id, parsed_monitors


def _parse_topology_map_output(output_text):
    """Parse JSON topology-map output emitted by the display-mode backend."""
    try:
        payload = json.loads(str(output_text).strip())
    except (TypeError, ValueError, json.JSONDecodeError):
        return None, None
    return _parse_topology_map_payload(payload)


def _topology_map_xrandr_fallback(allow_xrandr):
    """Return xrandr topology as (profile, monitors, source) when allowed."""
    if not allow_xrandr:
        return None, None, None
    xrandr = _detect_xrandr_topology_map()
    if xrandr[0] is not None and xrandr[1] is not None:
        return xrandr[0], xrandr[1], "xrandr"
    return None, None, None


def _detect_xrandr_topology_map():
    """Detect monitor geometry via xrandr when Mutter topology is unavailable."""
    return _detect_xrandr_topology_map_impl(run_in_desktop_session)


def detect_swap_topology_map(allow_xrandr=True):
    """Detect the current display profile and logical monitor coordinates.

    Prefer Mutter logical geometry. When *allow_xrandr* is False, skip the
    xrandr fallback so a prior Mutter cache is not replaced with physical
    pixels (different signature resets the window-swap bounce step).
    """
    mutter = _run_display_mode_backend("--detect-topology-map", 5, _parse_topology_map_output, (None, None))
    if mutter[0] is not None and mutter[1] is not None:
        return mutter[0], mutter[1], "mutter"
    return _topology_map_xrandr_fallback(allow_xrandr)
