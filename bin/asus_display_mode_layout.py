"""Layout and topology helpers for ASUS display mode backend."""

import os

# Target model defaults for ASUS ZenBook Duo UX582H / OLED Duo series layouts.
DEFAULT_MAIN_CONNECTOR = "eDP-1"
DEFAULT_SECONDARY_CONNECTOR = "DP-3"
DEFAULT_MAIN_MODE = "3840x2160@60.000"
DEFAULT_SECONDARY_MODE = "3840x1100@60.017"
DISPLAY_SCALE = 2.0
SECONDARY_VERTICAL_OFFSET = 1080
DEFAULT_LOGICAL_WIDTH = 1920
DEFAULT_LOGICAL_HEIGHT = 550
PRIMARY_LOGICAL_INDEX = 0
SCREENPAD_ASPECT_TOLERANCE = 0.08


def _is_nonempty_sequence(value):
    """Return True when *value* is a non-empty list or tuple."""
    return isinstance(value, (list, tuple)) and bool(value)


def _valid_mode_identifier(mode_entry):
    """Return mode id when entry is well-formed, otherwise None."""
    if not _is_nonempty_sequence(mode_entry):
        return None
    mode_id = mode_entry[0]
    if not mode_id:
        return None
    return mode_id


def _preferred_or_current_mode_id(valid_modes):
    """Return the first preferred/current mode id from *valid_modes*, or None."""
    for mode in valid_modes:
        props = mode[-1] if isinstance(mode[-1], dict) else {}
        if _is_preferred_or_current(props):
            return mode[0]
    return None


def _valid_mode_entries(modes):
    """Return mode entries that carry a valid mode identifier."""
    return [mode for mode in modes if _valid_mode_identifier(mode) is not None]


def select_best_mode(modes):
    """Find preferred or current mode identifier from mode list."""
    if not modes:
        return None
    valid_modes = _valid_mode_entries(modes)
    if not valid_modes:
        return None
    preferred = _preferred_or_current_mode_id(valid_modes)
    if preferred is not None:
        return preferred
    return valid_modes[0][0]


def _mode_scale_value(mode_entry):
    """Return the scale value from a Mutter mode tuple when available."""
    if not isinstance(mode_entry, (list, tuple)) or len(mode_entry) <= 4:
        return None
    try:
        scale = float(mode_entry[4])
    except (TypeError, ValueError):
        return None
    if scale > 0:
        return scale
    return None


def _mode_entry_has_scale_list(mode_entry):
    """Return True when *mode_entry* has a list of scales at index 5."""
    if mode_entry is None or not isinstance(mode_entry, (list, tuple)):
        return False
    return len(mode_entry) > 5 and isinstance(mode_entry[5], list)


def _supported_scale_values(mode_entry):
    """Return positive supported scale values from a Mutter mode tuple."""
    if not _mode_entry_has_scale_list(mode_entry):
        return []
    values = []
    for scale_value in mode_entry[5]:
        scale = _coerce_positive_scale(scale_value)
        if scale is not None:
            values.append(scale)
    return values


def _coerce_positive_scale(scale_value):
    """Return a positive float scale value, or None when invalid."""
    try:
        scale = float(scale_value)
    except (TypeError, ValueError):
        return None
    if scale <= 0:
        return None
    return scale


def _extract_supported_scales(modes):
    """Return sorted unique supported scales from Mutter mode tuples."""
    scales = set()
    for mode_entry in modes:
        for scale in _supported_scale_values(mode_entry):
            scales.add(scale)
    return sorted(scales)


def _find_scale_for_mode(modes, selected_mode):
    """Return the scale for selected_mode from the mode list, or None if absent."""
    for mode_entry in modes:
        if not mode_entry or mode_entry[0] != selected_mode:
            continue
        return _mode_scale_value(mode_entry)
    return None


def _preferred_mode_scale(modes, selected_mode):
    """Return selected mode scale when known, otherwise first supported scale."""
    scale = _find_scale_for_mode(modes, selected_mode)
    if scale is not None:
        return scale
    supported_scales = _extract_supported_scales(modes)
    if supported_scales:
        return supported_scales[0]
    return None


def _is_preferred_or_current(props):
    """Return whether a mode property dict marks the mode as preferred/current."""
    return props.get("is-preferred") or props.get("is-current")


def _find_mode_entry(modes, selected_mode):
    """Return the Mutter mode tuple for selected_mode, or None when absent."""
    for mode_entry in modes:
        if mode_entry and mode_entry[0] == selected_mode:
            return mode_entry
    return None


def _blank_pm_result():
    """Return an empty process_single_pm result dictionary."""
    return {
        "connector": "",
        "mode": None,
        "mode_entry": None,
        "is_builtin": False,
        "supported_scales": [],
        "mode_scales": [],
        "preferred_scale": None,
    }


def _pm_spec_connector(pm):
    """Return connector string from a physical monitor tuple, or None."""
    if not isinstance(pm, (list, tuple)) or len(pm) < 2:
        return None
    spec = pm[0]
    if not _is_nonempty_sequence(spec):
        return None
    return str(spec[0])


def _pm_is_builtin(pm, conn):
    """Return whether a physical monitor entry is a built-in panel."""
    properties = pm[2] if len(pm) > 2 and isinstance(pm[2], dict) else {}
    return bool(properties.get("is-builtin", False)) or conn.startswith("eDP")


def process_single_pm(pm):
    """Extract connector name, mode, and whether monitor is built-in."""
    conn = _pm_spec_connector(pm)
    if conn is None:
        return _blank_pm_result()
    modes = pm[1] if isinstance(pm[1], list) else []
    selected = select_best_mode(modes)
    mode_entry = _find_mode_entry(modes, selected)
    return {
        "connector": conn,
        "mode": selected,
        "mode_entry": mode_entry,
        "is_builtin": _pm_is_builtin(pm, conn),
        "supported_scales": _extract_supported_scales(modes),
        "mode_scales": _supported_scale_values(mode_entry),
        "preferred_scale": _preferred_mode_scale(modes, selected),
    }


def _dedupe_connectors(monitors):
    """Return unique monitor dictionaries while preserving connector order."""
    seen = set()
    ordered = []
    for monitor in monitors:
        conn = monitor["connector"]
        if conn in seen:
            continue
        seen.add(conn)
        ordered.append(monitor)
    return ordered


def _choose_main(current_main, candidate):
    """Prefer default main connector when multiple built-in panels are present."""
    if current_main is None:
        return candidate
    if candidate["connector"] == DEFAULT_MAIN_CONNECTOR:
        return candidate
    return current_main


def _try_assign_screenpad(monitor, groups):
    """Assign *monitor* as ScreenPad when the slot is free and it matches."""
    if groups["screenpad"] is not None:
        return False
    connector = str(monitor.get("connector", "") or "")
    matched = _matches_screenpad_connector(connector) or _is_screenpad_like_external(monitor)
    if not matched:
        return False
    groups["screenpad"] = monitor
    return True


def _append_non_builtin_monitor(monitor, groups):
    """Attach non-builtin monitor to ScreenPad or external group."""
    if _try_assign_screenpad(monitor, groups):
        return
    groups["externals"].append(monitor)


def _matches_screenpad_connector(connector):
    """Return whether connector matches configured ScreenPad output names."""
    if not connector:
        return False
    if connector == DEFAULT_SECONDARY_CONNECTOR:
        return True
    override = os.environ.get("ASUS_SCREENPAD_CONNECTOR", "").strip()
    return bool(override) and connector == override


def _physical_size_from_mode_id_string(mode_id, fallback):
    """Parse WIDTHxHEIGHT@Hz mode-id strings (default constants and legacy callers)."""
    try:
        resolution = str(mode_id).split("@", 1)[0]
        width_text, height_text = resolution.split("x", 1)
        width = int(width_text)
        height = int(height_text)
    except (ValueError, TypeError):
        return fallback
    if width <= 0 or height <= 0:
        return fallback
    return width, height


def _physical_size_from_mode_tuple(mode, fallback):
    """Return validated width/height from a Mutter mode tuple."""
    if len(mode) < 3:
        return fallback
    try:
        width = int(mode[1])
        height = int(mode[2])
    except (TypeError, ValueError):
        return fallback
    if width <= 0 or height <= 0:
        return fallback
    return width, height


def _physical_size_from_mode(mode, fallback):
    """Return validated physical dimensions from a Mutter mode tuple or mode-id string."""
    if isinstance(mode, (tuple, list)):
        return _physical_size_from_mode_tuple(mode, fallback)
    if isinstance(mode, str):
        return _physical_size_from_mode_id_string(mode, fallback)
    return fallback


def _mode_size_source(monitor):
    """Return mode tuple or mode id string used for physical dimension lookups."""
    mode_entry = monitor.get("mode_entry")
    if mode_entry is not None:
        return mode_entry
    return monitor.get("mode")


def _mode_aspect_ratio(mode):
    """Parse and return width/height aspect ratio from a mode tuple or id string."""
    dimensions = _physical_size_from_mode(mode, None)
    if dimensions is None:
        return None
    width, height = dimensions
    return width / height


def _aspect_within_screenpad_tolerance(mode):
    """Return whether mode aspect ratio matches the ScreenPad reference."""
    monitor_aspect = _mode_aspect_ratio(mode)
    expected_aspect = _mode_aspect_ratio(DEFAULT_SECONDARY_MODE)
    if monitor_aspect is None or expected_aspect is None:
        return False
    return abs(monitor_aspect - expected_aspect) <= SCREENPAD_ASPECT_TOLERANCE


def _height_matches_screenpad_reference(mode):
    """Return whether mode height equals the ScreenPad reference height exactly."""
    dimensions = _physical_size_from_mode(mode, None)
    expected = _physical_size_from_mode(DEFAULT_SECONDARY_MODE, None)
    if dimensions is None or expected is None:
        return False
    return dimensions[1] == expected[1]


def _width_matches_screenpad_reference(mode):
    """Return whether mode width equals the ScreenPad reference width exactly."""
    dimensions = _physical_size_from_mode(mode, None)
    expected = _physical_size_from_mode(DEFAULT_SECONDARY_MODE, None)
    if dimensions is None or expected is None:
        return False
    return dimensions[0] == expected[0]


def _screenpad_dimensions_match(mode):
    """Return whether mode matches ScreenPad aspect and exact width/height."""
    return (
        _aspect_within_screenpad_tolerance(mode) and _height_matches_screenpad_reference(mode) and _width_matches_screenpad_reference(mode)
    )


def _is_screenpad_like_external(monitor):
    """Return whether an external monitor should be treated as ScreenPad-like."""
    connector = str(monitor.get("connector", "") or "")
    if not connector:
        return False
    if not connector.startswith("DP-"):
        return False
    return _screenpad_dimensions_match(_mode_size_source(monitor))


def _fallback_target_scale(monitor):
    """Return preferred/supported/default scale when DISPLAY_SCALE is unavailable."""
    preferred = monitor.get("preferred_scale")
    if preferred is not None:
        return preferred
    supported_scales = monitor.get("supported_scales", [])
    if supported_scales:
        return supported_scales[0]
    if monitor.get("is_builtin"):
        return DISPLAY_SCALE
    return 1.0


def _choose_target_scale(monitor):
    """Select monitor scale: built-in prefers DISPLAY_SCALE when supported."""
    mode_scales = monitor.get("mode_scales", [])
    if monitor.get("is_builtin") and DISPLAY_SCALE in mode_scales:
        return DISPLAY_SCALE
    return _fallback_target_scale(monitor)


def _builtin_main_loser(previous, monitor, chosen):
    """Return the built-in monitor displaced when choosing a new main."""
    if previous is None:
        return None
    if chosen is not previous:
        return previous
    if monitor is not chosen:
        return monitor
    return None


def _place_builtin_monitor(monitor, groups):
    """Place a built-in monitor into main, demoting the prior main to ScreenPad."""
    previous = groups["main"]
    chosen = _choose_main(previous, monitor)
    groups["main"] = chosen
    loser = _builtin_main_loser(previous, monitor, chosen)
    if loser is not None and groups["screenpad"] is None:
        groups["screenpad"] = loser


def classify_monitor_groups(physical_monitors):
    """Classify connected displays into main, ScreenPad, and external groups."""
    groups = {"main": None, "screenpad": None, "externals": []}

    for pm in physical_monitors:
        monitor = process_single_pm(pm)
        if monitor["mode"] is None:
            continue
        if monitor["is_builtin"]:
            _place_builtin_monitor(monitor, groups)
            continue
        _append_non_builtin_monitor(monitor, groups)

    groups["externals"] = _dedupe_connectors(groups["externals"])
    return groups


def logical_size_from_mode(mode, scale):
    """Return logical monitor width/height, or (None, None) when unresolved."""
    dimensions = _physical_size_from_mode(mode, None)
    if dimensions is None:
        return None, None

    width, height = dimensions
    try:
        logical_width = round(width / float(scale))
        logical_height = round(height / float(scale))
    except (TypeError, ValueError, ZeroDivisionError):
        return None, None

    if logical_width <= 0 or logical_height <= 0:
        return None, None
    return logical_width, logical_height
