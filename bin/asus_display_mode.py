#!/usr/bin/env python3
"""ASUS ZenBook Mutter Display Mode Switcher backend module."""

import functools
import json
import re
import sys

try:
    from . import asus_display_mode_core as _core
except ImportError:  # Script execution path: python3 bin/asus_display_mode.py
    import asus_display_mode_core as _core
import dbus

DEFAULT_MAIN_CONNECTOR = _core.DEFAULT_MAIN_CONNECTOR
DEFAULT_SECONDARY_CONNECTOR = _core.DEFAULT_SECONDARY_CONNECTOR
DEFAULT_MAIN_MODE = _core.DEFAULT_MAIN_MODE
DEFAULT_SECONDARY_MODE = _core.DEFAULT_SECONDARY_MODE
SECONDARY_VERTICAL_OFFSET = _core.SECONDARY_VERTICAL_OFFSET
DEFAULT_LOGICAL_HEIGHT = _core.DEFAULT_LOGICAL_HEIGHT

PROFILE_ALL = _core.PROFILE_ALL
PROFILE_MAIN_EXTERNAL = _core.PROFILE_MAIN_EXTERNAL
PROFILE_SCREENPAD_EXTERNAL = _core.PROFILE_SCREENPAD_EXTERNAL
PROFILE_EXTERNAL_ONLY = _core.PROFILE_EXTERNAL_ONLY
PROFILE_MAIN_ONLY = _core.PROFILE_MAIN_ONLY
PROFILE_SCREENPAD_ONLY = _core.PROFILE_SCREENPAD_ONLY

_select_best_mode = _core.select_best_mode
_process_single_pm = _core.process_single_pm
_logical_size_from_mode = _core.logical_size_from_mode

available_profiles = _core.available_profiles
classify_monitor_groups = _core.classify_monitor_groups
detect_current_profile = _core.detect_current_profile
build_logical_monitors = _core.build_logical_monitors
format_profile_label = _core.format_profile_label
get_next_profile = _core.get_next_profile
find_monitor_modes = _core.find_monitor_modes

LEGACY_MODE_TO_PROFILE = {
    1: PROFILE_ALL,
    2: PROFILE_MAIN_ONLY,
    3: PROFILE_SCREENPAD_ONLY,
}

SUPPORTED_PROFILE_IDS = _core.SUPPORTED_PROFILE_IDS


def _mutter_dbus_errors(message="Failed to detect display mode"):
    """Catch Mutter D-Bus failures, emit *message*, then re-raise for callers."""

    def decorator(fn):
        @functools.wraps(fn)
        def wrapper(*args, **kwargs):
            try:
                return fn(*args, **kwargs)
            except dbus.DBusException as exc:
                print(f"{message}: {exc}", file=sys.stderr)
                raise

        return wrapper

    return decorator


def _get_display_config_iface():
    """Return Mutter DisplayConfig interface and current state tuple."""
    bus = dbus.SessionBus()
    obj = bus.get_object("org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig")
    iface = dbus.Interface(obj, "org.gnome.Mutter.DisplayConfig")
    return iface, iface.GetCurrentState()


def _apply_profile(profile_id):
    """Apply a topology-aware profile id through Mutter DisplayConfig."""
    try:
        iface, state = _get_display_config_iface()
        serial, physical_monitors, _, _ = state
        groups = classify_monitor_groups(physical_monitors)
        logical_monitors = build_logical_monitors(profile_id, groups)
        iface.ApplyMonitorsConfig(
            dbus.UInt32(serial),
            dbus.UInt32(2),
            logical_monitors,
            dbus.Dictionary({}, signature="sv"),
        )
        return 0
    except (dbus.DBusException, TypeError, ValueError) as exc:
        print(f"Failed to apply display mode: {exc}", file=sys.stderr)
        return 1


@_mutter_dbus_errors("Failed to plan next display mode")
def _print_next_profile(current_profile):
    """Print next profile id and context-aware label for shell orchestration."""
    _iface, state = _get_display_config_iface()
    _serial, physical_monitors, logical_monitors, _properties = state
    groups = classify_monitor_groups(physical_monitors)
    detected = detect_current_profile(logical_monitors, groups)
    start = current_profile if current_profile else detected
    next_profile = get_next_profile(start, groups)
    label = format_profile_label(next_profile, groups)
    print(f"{next_profile}:{label}")
    return 0


def apply_display_mode(mode_num):
    """Query Mutter DisplayConfig and apply target layout mode."""
    if mode_num not in LEGACY_MODE_TO_PROFILE:
        print(f"Unsupported legacy display mode: {mode_num}", file=sys.stderr)
        return 1
    return _apply_profile(LEGACY_MODE_TO_PROFILE[mode_num])


@_mutter_dbus_errors("Failed to detect display mode")
def detect_current_mode():
    """Detect and print current display mode using Mutter logical monitor state."""
    _iface, state = _get_display_config_iface()
    _serial, physical_monitors, logical_monitors, _properties = state
    groups = classify_monitor_groups(physical_monitors)
    profile_id = detect_current_profile(logical_monitors, groups)
    reverse_map = {v: k for k, v in LEGACY_MODE_TO_PROFILE.items()}
    return reverse_map.get(profile_id, 1)


@_mutter_dbus_errors()
def detect_current_profile_id():
    """Detect and return current topology-aware profile id."""
    _iface, state = _get_display_config_iface()
    _serial, physical_monitors, logical_monitors, _properties = state
    groups = classify_monitor_groups(physical_monitors)
    return detect_current_profile(logical_monitors, groups)


@_mutter_dbus_errors()
def detect_topology_summary():
    """Return active profile id and logical monitor count."""
    _iface, state = _get_display_config_iface()
    _serial, physical_monitors, logical_monitors, _properties = state
    groups = classify_monitor_groups(physical_monitors)
    profile_id = detect_current_profile(logical_monitors, groups)
    return profile_id, len(logical_monitors)


def _mode_entry_for_connector(modes, mode_id):
    """Return the physical mode tuple matching mode_id, or None when absent."""
    for mode_entry in modes:
        if mode_entry and str(mode_entry[0]) == str(mode_id):
            return mode_entry
    return None


def _looks_like_mode_id(mode_token):
    """Return True when *mode_token* looks like WIDTHxHEIGHT or WIDTHxHEIGHT@Hz."""
    return re.fullmatch(r"[0-9]+x[0-9]+(?:@[0-9.]+)?", str(mode_token)) is not None


def _mode_is_current(mode_entry):
    """Return True when a physical mode entry is marked is-current."""
    if not mode_entry or len(mode_entry) < 7:
        return False
    return _props_flag_true(mode_entry[6], "is-current")


def _props_flag_true(props, flag_name):
    """Return True when *props* maps *flag_name* to a truthy value."""
    try:
        items = dict(props).items()
    except (TypeError, ValueError):
        return False
    for key, value in items:
        if str(key) == flag_name:
            return bool(value)
    return False


def _current_mode_entry(modes):
    """Return the is-current mode tuple from *modes*, or None."""
    for mode_entry in modes:
        if _mode_is_current(mode_entry):
            return mode_entry
    return None


def _modes_list(physical_monitor):
    """Return the modes list from a Mutter physical-monitor tuple."""
    if physical_monitor is None or len(physical_monitor) < 2:
        return []
    modes = physical_monitor[1]
    return list(modes) if modes is not None else []


def _resolve_mode_id_match(modes, mode_token):
    """Return a matching mode-id entry when *mode_token* looks like a mode id."""
    if not _looks_like_mode_id(mode_token):
        return None
    return _mode_entry_for_connector(modes, mode_token)


def _resolve_matched_mode(modes, mode_token):
    """Resolve a mode token against *modes*, preferring id then is-current.

    Returns a mode tuple when a matching or current entry is found, the raw
    *mode_token* string when it looks like a mode id but has no entry, or the
    first mode / None when falling back.
    """
    matched = _resolve_mode_id_match(modes, mode_token)
    if matched is not None:
        return matched
    current = _current_mode_entry(modes)
    if current is not None:
        return current
    if _looks_like_mode_id(mode_token):
        return mode_token
    return modes[0] if modes else None


def _physical_monitor_connector(pm):
    """Return connector name from a physical monitor tuple, or None."""
    if not isinstance(pm, (list, tuple)) or not pm:
        return None
    first = pm[0]
    if not isinstance(first, (list, tuple)) or not first:
        return None
    return str(first[0])


def _resolve_mode_from_physical_monitor(pm, connector, mode_token):
    """Return resolved mode for connector on one physical monitor, or None."""
    pm_connector = _physical_monitor_connector(pm)
    if pm_connector is None or pm_connector != connector:
        return None
    return _resolve_matched_mode(_modes_list(pm), mode_token)


def _logical_monitor_connector_token(logical_monitor):
    """Return (connector, mode_or_vendor_token) from a logical monitor entry."""
    if len(logical_monitor) < 6 or not logical_monitor[5]:
        return None, None
    entry = logical_monitor[5][0]
    if not isinstance(entry, (list, tuple)) or len(entry) < 2:
        return None, None
    return str(entry[0]), entry[1]


def _resolve_logical_monitor_mode(physical_monitors, logical_monitor):
    """Resolve a Mutter mode tuple or id for one logical monitor from physical state.

    Newer Mutter builds embed the monitor *spec* ``(connector, vendor, product,
    serial)`` in logical monitors instead of ``(connector, mode_id, props)``.
    When the second field is not a mode id, fall back to the connector's
    ``is-current`` physical mode so topology heights stay correct.
    """
    connector, mode_token = _logical_monitor_connector_token(logical_monitor)
    if connector is None:
        return None
    for pm in physical_monitors:
        resolved = _resolve_mode_from_physical_monitor(pm, connector, mode_token)
        if resolved is not None:
            return resolved
    if _looks_like_mode_id(mode_token):
        return mode_token
    return None


def _logical_monitor_payload(logical_monitor, physical_monitors, mutter_index):
    """Convert one Mutter logical monitor tuple to a JSON-serializable payload."""
    if len(logical_monitor) < 6:
        return None
    connectors = []
    for mon in logical_monitor[5]:
        if not isinstance(mon, (list, tuple)) or len(mon) < 1:
            continue
        connectors.append(str(mon[0]))
    mode = _resolve_logical_monitor_mode(physical_monitors, logical_monitor)
    width, height = _logical_size_from_mode(mode, logical_monitor[2])
    return {
        "index": int(mutter_index),
        "x": int(logical_monitor[0]),
        "y": int(logical_monitor[1]),
        "width": int(width),
        "height": int(height),
        "scale": float(logical_monitor[2]),
        "primary": bool(logical_monitor[4]),
        "connectors": connectors,
    }


@_mutter_dbus_errors()
def detect_topology_map():
    """Return active profile id and logical monitor geometry map."""
    _iface, state = _get_display_config_iface()
    _serial, physical_monitors, logical_monitors, _properties = state
    groups = classify_monitor_groups(physical_monitors)
    profile_id = detect_current_profile(logical_monitors, groups)

    monitors = []
    for mutter_index, logical_monitor in enumerate(logical_monitors):
        payload = _logical_monitor_payload(logical_monitor, physical_monitors, mutter_index)
        if payload is None:
            continue
        monitors.append(payload)

    return {
        "profile": profile_id,
        "count": len(monitors),
        "monitors": monitors,
    }


def _run_detect_command(runner):
    """Run a detect CLI action; D-Bus silent, TypeError/ValueError to stderr."""
    try:
        runner()
        return 0
    except dbus.DBusException:
        return 1
    except (TypeError, ValueError) as exc:
        print(f"Failed to detect display mode: {exc}", file=sys.stderr)
        return 1


def _run_detect():
    """Handle --detect CLI command."""
    return _run_detect_command(lambda: print(detect_current_profile_id()))


def _run_detect_topology():
    """Handle --detect-topology CLI command."""

    def _print_topology():
        profile_id, monitor_count = detect_topology_summary()
        print(f"{profile_id}:{monitor_count}")

    return _run_detect_command(_print_topology)


def _run_detect_topology_map():
    """Handle --detect-topology-map CLI command."""
    return _run_detect_command(lambda: print(json.dumps(detect_topology_map(), separators=(",", ":"))))


def _run_next(args):
    """Handle --next CLI command."""
    if not args:
        print("Invalid mode argument.", file=sys.stderr)
        raise SystemExit(1)
    profile_id = args[0]
    if profile_id not in SUPPORTED_PROFILE_IDS:
        print(f"Invalid profile id: {profile_id}", file=sys.stderr)
        raise SystemExit(1)
    try:
        return _print_next_profile(profile_id)
    except dbus.DBusException:
        return 1


def _run_apply_profile(args):
    """Handle --apply-profile CLI command."""
    if not args:
        print("Invalid mode argument.", file=sys.stderr)
        raise SystemExit(1)
    profile_id = args[0]
    if profile_id not in SUPPORTED_PROFILE_IDS:
        print(f"Invalid profile id: {profile_id}", file=sys.stderr)
        raise SystemExit(1)
    return _apply_profile(profile_id)


COMMAND_HANDLERS = {
    "--detect": lambda _args: _run_detect(),
    "--detect-topology": lambda _args: _run_detect_topology(),
    "--detect-topology-map": lambda _args: _run_detect_topology_map(),
    "--next": _run_next,
    "--apply-profile": _run_apply_profile,
}


def main():
    """Main entrypoint for asus-display-mode.py."""
    if len(sys.argv) < 2:
        print("Invalid mode argument.", file=sys.stderr)
        raise SystemExit(1)

    cmd = sys.argv[1]
    if cmd in COMMAND_HANDLERS:
        return COMMAND_HANDLERS[cmd](sys.argv[2:])

    try:
        mode_num = int(cmd)
    except ValueError as exc:
        print("Invalid mode argument.", file=sys.stderr)
        raise SystemExit(1) from exc

    if mode_num not in LEGACY_MODE_TO_PROFILE:
        print("Invalid mode argument.", file=sys.stderr)
        raise SystemExit(1)

    return apply_display_mode(mode_num)


if __name__ == "__main__":
    raise SystemExit(main())
