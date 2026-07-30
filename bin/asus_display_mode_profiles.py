"""Profile cycle, layout, and labeling for ASUS display mode backend."""

from asus_display_mode_layout import (
    DEFAULT_MAIN_CONNECTOR,
    DEFAULT_MAIN_MODE,
    DEFAULT_SECONDARY_CONNECTOR,
    DEFAULT_SECONDARY_MODE,
    PRIMARY_LOGICAL_INDEX,
    _choose_target_scale,
    _dedupe_connectors,
    _mode_size_source,
    classify_monitor_groups,
    logical_size_from_mode,
)
from asus_i18n import gettext_message, ngettext_message

PROFILE_ALL = "all"
PROFILE_MAIN_EXTERNAL = "main_external"
PROFILE_SCREENPAD_EXTERNAL = "screenpad_external"
PROFILE_EXTERNAL_ONLY = "external_only"
PROFILE_MAIN_ONLY = "main_only"
PROFILE_SCREENPAD_ONLY = "screenpad_only"
SUPPORTED_PROFILE_IDS = {
    PROFILE_ALL,
    PROFILE_MAIN_EXTERNAL,
    PROFILE_SCREENPAD_EXTERNAL,
    PROFILE_EXTERNAL_ONLY,
    PROFILE_MAIN_ONLY,
    PROFILE_SCREENPAD_ONLY,
}

PROFILE_MATRIX = {
    (True, True, True): [
        PROFILE_ALL,
        PROFILE_MAIN_EXTERNAL,
        PROFILE_SCREENPAD_EXTERNAL,
        PROFILE_MAIN_ONLY,
        PROFILE_SCREENPAD_ONLY,
        PROFILE_EXTERNAL_ONLY,
    ],
    (True, True, False): [PROFILE_ALL, PROFILE_MAIN_ONLY, PROFILE_SCREENPAD_ONLY],
    (True, False, True): [PROFILE_ALL, PROFILE_MAIN_ONLY, PROFILE_EXTERNAL_ONLY],
    (True, False, False): [PROFILE_MAIN_ONLY],
    (False, True, True): [PROFILE_SCREENPAD_EXTERNAL, PROFILE_SCREENPAD_ONLY, PROFILE_EXTERNAL_ONLY],
    (False, True, False): [PROFILE_SCREENPAD_ONLY],
    (False, False, True): [PROFILE_EXTERNAL_ONLY],
    # (False, False, False) omitted: no connected displays → no profile cycle.
}


def _apply_target_scales(targets):
    """Attach selected per-target scale values to profile targets."""
    scaled_targets = []
    for monitor in targets:
        monitor_with_scale = dict(monitor)
        monitor_with_scale["scale"] = _choose_target_scale(monitor)
        scaled_targets.append(monitor_with_scale)
    return scaled_targets


def _targets_main_only(groups):
    """Return monitors targeted by main-only profile."""
    return [groups["main"]] if groups["main"] else []


def _targets_screenpad_only(groups):
    """Return monitors targeted by screenpad-only profile."""
    return [groups["screenpad"]] if groups["screenpad"] else []


def _targets_main_external(groups):
    """Return monitors targeted by main-plus-external profile."""
    return ([groups["main"]] if groups["main"] else []) + groups["externals"]


def _targets_screenpad_external(groups):
    """Return monitors targeted by screenpad-plus-external profile."""
    return ([groups["screenpad"]] if groups["screenpad"] else []) + groups["externals"]


def _targets_external_only(groups):
    """Return monitors targeted by external-only profile."""
    return groups["externals"]


def _targets_all(groups):
    """Return monitors targeted by all-displays profile."""
    targets = []
    if groups["main"]:
        targets.append(groups["main"])
    if groups["screenpad"]:
        targets.append(groups["screenpad"])
    targets.extend(groups["externals"])
    return targets


PROFILE_TARGET_BUILDERS = {
    PROFILE_ALL: _targets_all,
    PROFILE_MAIN_EXTERNAL: _targets_main_external,
    PROFILE_SCREENPAD_EXTERNAL: _targets_screenpad_external,
    PROFILE_EXTERNAL_ONLY: _targets_external_only,
    PROFILE_MAIN_ONLY: _targets_main_only,
    PROFILE_SCREENPAD_ONLY: _targets_screenpad_only,
}


def _profile_targets(profile_id, groups):
    """Return monitor list for a profile based on current topology groups."""
    builder = PROFILE_TARGET_BUILDERS.get(profile_id, _targets_all)
    return _apply_target_scales(_dedupe_connectors(builder(groups)))


def available_profiles(groups):
    """Build a deterministic profile cycle based on currently connected monitors."""
    key = (groups["main"] is not None, groups["screenpad"] is not None, bool(groups["externals"]))
    return PROFILE_MATRIX.get(key, [PROFILE_ALL])


def _connector_from_monitor_entry(monitor):
    """Return connector string from a Mutter monitor entry, or None if malformed."""
    if not isinstance(monitor, (list, tuple)) or len(monitor) < 2:
        return None
    return str(monitor[0])


def _active_connectors(logical_monitors):
    """Extract active connectors from Mutter logical monitor state."""
    active = []
    for logical_monitor in logical_monitors:
        if len(logical_monitor) < 6:
            continue
        for monitor in logical_monitor[5]:
            connector = _connector_from_monitor_entry(monitor)
            if connector is not None:
                active.append(connector)
    return set(active)


def _nearest_profile(active, profiles, groups):
    """Select the nearest matching profile for non-exact active connector sets."""
    best_profile = profiles[0]
    best_score = -1_000_000

    for profile in profiles:
        targets = {mon["connector"] for mon in _profile_targets(profile, groups)}
        overlap = len(active & targets)
        mismatch = abs(len(active) - len(targets))
        score = (overlap * 2) - mismatch
        if score > best_score:
            best_profile = profile
            best_score = score

    return best_profile


def detect_current_profile(logical_monitors, groups):
    """Detect the active profile id from current logical monitor assignments."""
    profiles = available_profiles(groups)
    active = _active_connectors(logical_monitors)

    if not active:
        return profiles[0]

    for profile in profiles:
        targets = {mon["connector"] for mon in _profile_targets(profile, groups)}
        if targets == active:
            return profile

    return _nearest_profile(active, profiles, groups)


def _logical_height_from_mode(mode, scale):
    """Return logical monitor height from a Mutter mode tuple or mode id."""
    return logical_size_from_mode(mode, scale)[1]


def build_logical_monitors(profile_id, groups):
    """Build logical monitor layout tuple list for Mutter DisplayConfig."""
    targets = _profile_targets(profile_id, groups)
    if not targets:
        raise ValueError(f"Profile '{profile_id}' has no available monitors in current topology.")

    logical_monitors = []
    y_offset = 0
    for idx, monitor in enumerate(targets):
        scale = monitor["scale"]
        logical_monitors.append(
            (
                0,
                y_offset,
                scale,
                0,
                idx == PRIMARY_LOGICAL_INDEX,
                [(monitor["connector"], monitor["mode"], {})],
            )
        )
        height = _logical_height_from_mode(_mode_size_source(monitor), scale)
        if height is None:
            connector = monitor.get("connector")
            raise ValueError(f"Unable to resolve logical height for monitor {connector!r}.")
        y_offset += height
    return logical_monitors


def _external_label(ext_count):
    """Return normalized label fragment for external display count."""
    if not ext_count:
        return ""
    template = ngettext_message("%d external display", "%d external displays", ext_count)
    return template % ext_count


def _join_label_parts(*parts):
    """Join non-empty label parts with a plus separator."""
    return " + ".join(part for part in parts if part)


def _all_targets_label(groups, external_label):
    """Build summary label for 'all displays' profile targets."""
    label = _join_label_parts(
        gettext_message("Main display") if groups["main"] else "",
        "ScreenPad" if groups["screenpad"] else "",
        external_label,
    )
    return label if label else gettext_message("Current display layout")


def _format_targets_for_label(profile_id, groups):
    """Build profile-specific context description used in notifications."""
    ext_count = len(groups["externals"])
    external_label = _external_label(ext_count)
    simple_labels = {
        PROFILE_MAIN_ONLY: gettext_message("Main display only"),
        PROFILE_SCREENPAD_ONLY: gettext_message("ScreenPad only"),
        PROFILE_EXTERNAL_ONLY: ngettext_message(
            "%d external display only",
            "%d external displays only",
            ext_count,
        )
        % ext_count,
        PROFILE_MAIN_EXTERNAL: _join_label_parts(gettext_message("Main display"), external_label),
        PROFILE_SCREENPAD_EXTERNAL: _join_label_parts("ScreenPad", external_label),
    }
    label = simple_labels.get(profile_id)
    if label:
        return label
    return _all_targets_label(groups, external_label)


def format_profile_label(profile_id, groups):
    """Return a human-readable label for a profile in current topology."""
    if profile_id == PROFILE_ALL:
        return gettext_message("All displays (%s)") % _format_targets_for_label(profile_id, groups)
    return _format_targets_for_label(profile_id, groups)


def get_next_profile(current_profile, groups):
    """Return next profile id from deterministic connected-topology cycle."""
    profiles = available_profiles(groups)
    if current_profile not in profiles:
        return profiles[0]
    next_idx = (profiles.index(current_profile) + 1) % len(profiles)
    return profiles[next_idx]


def find_monitor_modes(physical_monitors):
    """Find main and secondary monitor connectors and preferred modes."""
    groups = classify_monitor_groups(physical_monitors)
    main_conn = DEFAULT_MAIN_CONNECTOR
    main_mode = DEFAULT_MAIN_MODE
    sec_conn = DEFAULT_SECONDARY_CONNECTOR
    sec_mode = DEFAULT_SECONDARY_MODE

    main_monitor = groups.get("main")
    screenpad_monitor = groups.get("screenpad")

    if isinstance(main_monitor, dict):
        main_conn = main_monitor["connector"]
        main_mode = main_monitor["mode"]
    if isinstance(screenpad_monitor, dict):
        sec_conn = screenpad_monitor["connector"]
        sec_mode = screenpad_monitor["mode"]

    return main_conn, main_mode, sec_conn, sec_mode
