#!/usr/bin/env python3
"""Shared state for the ASUS hotkey daemon implementation."""

import os
import threading

_last_script_times = {}
_LAST_SCRIPT_TIMES_LOCK = threading.Lock()
# Workers replace monitors atomically; do not mutate lists in place.
_SWAP_TOPOLOGY = {
    "signature": None,
    "monitors": None,
    "refresh": 0.0,
    "refreshed_live": False,
    "source": None,
}
_SWAP_TOPOLOGY_LOCK = threading.Lock()
_TOPOLOGY_REFRESH_SECONDS = 2.0
_SCRIPT_DEBOUNCE_SECONDS = 0.3
# Display Toggle sticky OSD must cycle as fast as native Super+P taps.
_DISPLAY_MODE_DEBOUNCE_SECONDS = 0.05
_SCREENPAD_BRIGHTNESS_DEBOUNCE_SECONDS = 0.08
_DESKTOP_USER_CACHE_SECONDS = 2.0
_DESKTOP_USER = {"cache": None, "session_env": None}
_DESKTOP_USER_LOCK = threading.Lock()
SCRIPT_BINDIR = os.environ.get("SCRIPT_BINDIR", "/usr/local/bin")
_DISPLAY_MODE_SCRIPT = "asus-display-mode.sh"
_SCREENPAD_BRIGHTNESS_SCRIPT = "asus-screenpad-brightness.sh"
_SCRIPT_MAP = {
    0x5C: "asus-control-center.sh",
    0x68: "asus-control-center.sh",
    0x6A: "asus-screenpad-toggle.sh",
    0x85: "asus-camera-toggle.sh",
    0x86: "asus-control-center.sh",
    0x88: "asus-control-center.sh",
    0x9D: "asus-fan-toggle.sh",
    0xBF: "asus-screenshot.sh",
    0xCC: "asus-control-center.sh",
}
_CODE_SCRIPT_MAP = {
    148: "asus-control-center.sh",
    156: "asus-control-center.sh",
    212: "asus-camera-toggle.sh",
    227: _DISPLAY_MODE_SCRIPT,
    482: "asus-fan-toggle.sh",
    570: "asus-control-center.sh",
    634: "asus-screenshot.sh",
}


def get_swap_topology_signature():
    """Return the cached monitor topology signature, or None."""
    with _SWAP_TOPOLOGY_LOCK:
        return _SWAP_TOPOLOGY["signature"]


def set_swap_topology_signature(signature):
    """Store the monitor topology signature used to detect layout changes."""
    with _SWAP_TOPOLOGY_LOCK:
        _SWAP_TOPOLOGY["signature"] = signature


def get_last_known_monitors():
    """Return the cached monitor list (shared; may be None).

    Callers must copy before mutating. Use set_last_known_monitors to replace.
    """
    with _SWAP_TOPOLOGY_LOCK:
        return _SWAP_TOPOLOGY["monitors"]


def set_last_known_monitors(monitors):
    """Replace the cached monitor list (pass a fresh list; do not mutate)."""
    with _SWAP_TOPOLOGY_LOCK:
        _SWAP_TOPOLOGY["monitors"] = monitors


def get_last_topology_refresh():
    """Return the monotonic timestamp of the last topology refresh schedule."""
    with _SWAP_TOPOLOGY_LOCK:
        return _SWAP_TOPOLOGY["refresh"]


def set_last_topology_refresh(timestamp):
    """Store the monotonic timestamp of the last topology refresh schedule."""
    with _SWAP_TOPOLOGY_LOCK:
        _SWAP_TOPOLOGY["refresh"] = timestamp


def get_last_topology_refreshed_live():
    """Return True when the cache was seeded from a live topology detect."""
    with _SWAP_TOPOLOGY_LOCK:
        return _SWAP_TOPOLOGY["refreshed_live"]


def set_last_topology_refreshed_live(refreshed_live):
    """Record whether the monitor cache came from a live topology detect."""
    with _SWAP_TOPOLOGY_LOCK:
        _SWAP_TOPOLOGY["refreshed_live"] = refreshed_live


def get_last_topology_source():
    """Return the last topology detect source label (e.g. mutter/xrandr)."""
    with _SWAP_TOPOLOGY_LOCK:
        return _SWAP_TOPOLOGY["source"]


def set_last_topology_source(source):
    """Store the last topology detect source label."""
    with _SWAP_TOPOLOGY_LOCK:
        _SWAP_TOPOLOGY["source"] = source


def get_monitor_refresh_state():
    """Return (monitors, refresh_timestamp) under one lock acquisition."""
    with _SWAP_TOPOLOGY_LOCK:
        return _SWAP_TOPOLOGY["monitors"], _SWAP_TOPOLOGY["refresh"]


def apply_detected_topology(monitors, source, now=None):
    """Store a live topology detection result under one lock acquisition."""
    with _SWAP_TOPOLOGY_LOCK:
        _SWAP_TOPOLOGY["monitors"] = monitors
        _SWAP_TOPOLOGY["refreshed_live"] = True
        _SWAP_TOPOLOGY["source"] = source
        if now is not None:
            _SWAP_TOPOLOGY["refresh"] = now


def clear_swap_topology_cache():
    """Reset all swap-topology cache fields (unit tests / daemon reset)."""
    with _SWAP_TOPOLOGY_LOCK:
        _SWAP_TOPOLOGY["signature"] = None
        _SWAP_TOPOLOGY["monitors"] = None
        _SWAP_TOPOLOGY["refresh"] = 0.0
        _SWAP_TOPOLOGY["refreshed_live"] = False
        _SWAP_TOPOLOGY["source"] = None


def clear_debounce():
    """Reset last script execution timestamps."""
    with _LAST_SCRIPT_TIMES_LOCK:
        _last_script_times.clear()


def get_last_script_times():
    """Return a copy of the debouncing timestamps for helper scripts."""
    with _LAST_SCRIPT_TIMES_LOCK:
        return dict(_last_script_times)


def set_last_script_time(script_path, timestamp):
    """Record the last execution timestamp for a helper script."""
    with _LAST_SCRIPT_TIMES_LOCK:
        _last_script_times[script_path] = timestamp


def claim_script_slot(script_path, now, debounce_seconds):
    """Atomically claim a debounce slot; return False when still within window."""
    with _LAST_SCRIPT_TIMES_LOCK:
        last_time = _last_script_times.get(script_path, 0.0)
        if now - last_time < debounce_seconds:
            return False
        _last_script_times[script_path] = now
        return True


def get_script_map():
    """Return a copy of the mapping from hotkey scancodes to helper scripts."""
    return dict(_SCRIPT_MAP)


def get_code_script_map():
    """Return a copy of the mapping from hotkey event codes to helper scripts."""
    return dict(_CODE_SCRIPT_MAP)


def resolve_script_name(last_scancode, event_code):
    """Return the helper script name for a scancode/event-code pair."""
    if last_scancode in _SCRIPT_MAP:
        return _SCRIPT_MAP[last_scancode]
    return _CODE_SCRIPT_MAP.get(event_code)


def get_topology_refresh_seconds():
    """Return the debounce interval for topology refreshes."""
    return _TOPOLOGY_REFRESH_SECONDS


def get_script_debounce_seconds(script_path=None):
    """Return the debounce interval for repeated helper script launches."""
    if script_path and script_path.endswith(_DISPLAY_MODE_SCRIPT):
        return _DISPLAY_MODE_DEBOUNCE_SECONDS
    if script_path and script_path.endswith(_SCREENPAD_BRIGHTNESS_SCRIPT):
        return _SCREENPAD_BRIGHTNESS_DEBOUNCE_SECONDS
    return _SCRIPT_DEBOUNCE_SECONDS


def get_desktop_user_cache_seconds():
    """Return the desktop-user cache time-to-live in seconds."""
    return _DESKTOP_USER_CACHE_SECONDS


def get_desktop_user_cache():
    """Return cached (uid, username, session_id, expires_at, validated_until), or None."""
    with _DESKTOP_USER_LOCK:
        entry = _DESKTOP_USER["cache"]
        if isinstance(entry, tuple):
            return entry
        return None


def get_desktop_user_session_id():
    """Return cached session id when a desktop-user cache entry exists."""
    with _DESKTOP_USER_LOCK:
        entry = _DESKTOP_USER["cache"]
        if not isinstance(entry, tuple):
            return None
        values = list(entry)
        if len(values) < 3:
            return None
        return values[2]


def set_desktop_user_cache(uid, username, session_id, expires_at, cache_options=None):
    """Store a desktop-user cache entry with optional session env / validated_until."""
    cache_options = cache_options or {}
    session_env = cache_options.get("session_env")
    validated_until = cache_options.get("validated_until", expires_at)
    with _DESKTOP_USER_LOCK:
        _DESKTOP_USER["cache"] = (uid, username, session_id, expires_at, validated_until)
        _DESKTOP_USER["session_env"] = session_env


def touch_desktop_user_validated_until(validated_until):
    """Refresh validated_until on the current desktop-user cache entry."""
    with _DESKTOP_USER_LOCK:
        entry = _DESKTOP_USER["cache"]
        if not isinstance(entry, tuple):
            return
        values = list(entry)
        if len(values) < 4:
            return
        uid, username, session_id, expires_at = values[0], values[1], values[2], values[3]
        _DESKTOP_USER["cache"] = (uid, username, session_id, expires_at, validated_until)


def get_desktop_user_session_env():
    """Return cached desktop session env for requires_dbus helpers, or None."""
    with _DESKTOP_USER_LOCK:
        return _DESKTOP_USER["session_env"]


def clear_desktop_user_cache():
    """Clear the cached desktop-user entry."""
    with _DESKTOP_USER_LOCK:
        _DESKTOP_USER["cache"] = None
        _DESKTOP_USER["session_env"] = None
