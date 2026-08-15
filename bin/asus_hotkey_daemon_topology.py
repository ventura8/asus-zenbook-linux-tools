#!/usr/bin/env python3
"""Monitor topology cache and geometry for the ASUS hotkey daemon."""

import logging
import threading
import time

import asus_hotkey_daemon_state as hotkey_state
from asus_hotkey_daemon_threading import _thread_factory
from asus_hotkey_daemon_topology_detect import detect_swap_topology_map
from asus_hotkey_daemon_window_move import _opposite_direction
from asus_hotkey_daemon_window_swap_gnome import (
    _focused_monitor_index,
    prime_gnome_window_swap_extension,
)
from evdev import ecodes

_logger = logging.getLogger(__name__)
_TOPOLOGY_REFRESH_LOCK = threading.Lock()
_TOPOLOGY_REFRESH = {"in_flight": False}


def get_topology_refresh_state():
    """Return topology-refresh bookkeeping dict (live; for tests)."""
    return _TOPOLOGY_REFRESH


def reset_topology_refresh_state():
    """Reset topology async-refresh bookkeeping used by unit tests."""
    with _TOPOLOGY_REFRESH_LOCK:
        _TOPOLOGY_REFRESH["in_flight"] = False


def _swap_direction_from_step(swap_step, monitor_count):
    """Compute the next swap direction key and next step.

    Test/compat API: production hop planning uses `_swap_direction_for_monitors`.
    Unit tests still exercise this helper directly.
    """
    if monitor_count <= 1:
        return ecodes.KEY_DOWN, 0
    if monitor_count >= 3:
        direction_cycle = (ecodes.KEY_DOWN, ecodes.KEY_RIGHT, ecodes.KEY_UP, ecodes.KEY_LEFT)
        return direction_cycle[swap_step % len(direction_cycle)], (swap_step + 1) % len(direction_cycle)
    cycle_length = 2 * (monitor_count - 1)
    phase = swap_step % cycle_length
    direction_key = ecodes.KEY_DOWN if phase < (monitor_count - 1) else ecodes.KEY_UP
    return direction_key, (swap_step + 1) % cycle_length


def get_monitor_signature(monitors):
    """Build a stable signature for topology changes."""
    return tuple(sorted((m["x"], m["y"], m["width"], m["height"], 1 if m["primary"] else 0) for m in monitors))


_DIRECTION_PRIORITY = {
    ecodes.KEY_RIGHT: 0,
    ecodes.KEY_DOWN: 1,
    ecodes.KEY_LEFT: 2,
    ecodes.KEY_UP: 3,
}


def _primary_weight(monitor):
    """Return 0 for primary monitor, 1 for secondary (stable sort tiebreaker)."""
    return 0 if monitor["primary"] else 1


def _neighbor_sort_key(directional, monitors, node_idx, neighbor_idx):
    """Return DFS traversal sort key for a neighbor based on direction and position."""
    return (
        _DIRECTION_PRIORITY.get(directional[node_idx].get(neighbor_idx), 99),
        monitors[neighbor_idx]["y"],
        monitors[neighbor_idx]["x"],
    )


def _dfs_visit_node(stack, visited, order, directional, monitors):
    """Pop one node; if unvisited, record it and push its sorted neighbors."""
    node_idx = stack.pop()
    if node_idx in visited:
        return
    visited.add(node_idx)
    order.append(node_idx)
    neighbors = sorted(
        directional[node_idx],
        key=lambda idx: _neighbor_sort_key(directional, monitors, node_idx, idx),
        reverse=True,
    )
    for neighbor_idx in neighbors:
        if neighbor_idx not in visited:
            stack.append(neighbor_idx)


def _fill_unreachable(monitors, order, visited):
    """Append monitors not yet in order, sorted by geometric position."""
    for idx in sorted(
        range(len(monitors)),
        key=lambda i: (monitors[i]["y"], monitors[i]["x"], _primary_weight(monitors[i])),
    ):
        if idx not in visited:
            order.append(idx)


def _sorted_monitor_indices_linear(monitors, axis):
    """Return monitor indices sorted for horizontal or vertical linear layouts."""
    if axis == "horizontal":
        return sorted(
            range(len(monitors)),
            key=lambda idx: (monitors[idx]["x"], monitors[idx]["y"], _primary_weight(monitors[idx])),
        )
    return sorted(
        range(len(monitors)),
        key=lambda idx: (monitors[idx]["y"], monitors[idx]["x"], _primary_weight(monitors[idx])),
    )


def _monitor_indices_in_cycle_order(monitors, directional=None):
    """Return monitor indices in a stable order for horizontal, vertical, and mixed layouts."""
    count = len(monitors)
    if count <= 1:
        return list(range(count))
    layout = _detect_monitor_layout(monitors)
    if layout in {"horizontal", "vertical"}:
        return _sorted_monitor_indices_linear(monitors, layout)
    if directional is None:
        directional = _build_directional_neighbors(monitors)
    return _mixed_layout_cycle_order(monitors, directional)


def _monitor_axis_spans(monitors):
    """Return x/y spans of monitor origin coordinates."""
    x_values = [monitor["x"] for monitor in monitors]
    y_values = [monitor["y"] for monitor in monitors]
    return max(x_values) - min(x_values), max(y_values) - min(y_values)


def _monitor_jitter_tolerance(monitors):
    """Return layout jitter tolerance in pixels derived from monitor sizes."""
    avg_width = sum(monitor["width"] for monitor in monitors) / len(monitors)
    avg_height = sum(monitor["height"] for monitor in monitors) / len(monitors)
    return max(16, int(min(avg_width, avg_height) * 0.06))


def _detect_monitor_layout(monitors):
    """Classify the monitor arrangement as horizontal, vertical, or mixed."""
    x_span, y_span = _monitor_axis_spans(monitors)
    tolerance = _monitor_jitter_tolerance(monitors)
    if y_span <= tolerance < x_span:
        return "horizontal"
    if x_span <= tolerance < y_span:
        return "vertical"
    if x_span > (y_span * 1.35):
        return "horizontal"
    if y_span > (x_span * 1.35):
        return "vertical"
    return "mixed"


def _primary_monitor_index(monitors):
    """Return the primary monitor index, defaulting to 0."""
    for idx, monitor in enumerate(monitors):
        if monitor.get("primary"):
            return idx
    return 0


def _mixed_layout_cycle_order(monitors, directional):
    """Return a deterministic traversal order for non-linear monitor layouts."""
    order = []
    stack = [_primary_monitor_index(monitors)]
    visited = set()
    while stack:
        _dfs_visit_node(stack, visited, order, directional, monitors)
    if len(order) != len(monitors):
        _fill_unreachable(monitors, order, visited)
    return order


def _monitor_edges(monitor):
    """Return monitor edges as (left, right, top, bottom)."""
    left = monitor["x"]
    top = monitor["y"]
    return left, left + monitor["width"], top, top + monitor["height"]


def _monitor_neighbor_candidates(source, target):
    """Return candidate directional edges from one monitor to another."""
    dx = target["x"] - source["x"]
    dy = target["y"] - source["y"]
    src_left, src_right, src_top, src_bottom = _monitor_edges(source)
    dst_left, dst_right, dst_top, dst_bottom = _monitor_edges(target)
    vertical_overlap = max(0, min(src_bottom, dst_bottom) - max(src_top, dst_top))
    horizontal_overlap = max(0, min(src_right, dst_right) - max(src_left, dst_left))
    candidates = []
    if dst_left >= src_right:
        candidates.append((ecodes.KEY_RIGHT, dst_left - src_right, -vertical_overlap, abs(dy)))
    if dst_right <= src_left:
        candidates.append((ecodes.KEY_LEFT, src_left - dst_right, -vertical_overlap, abs(dy)))
    if dst_top >= src_bottom:
        candidates.append((ecodes.KEY_DOWN, dst_top - src_bottom, -horizontal_overlap, abs(dx)))
    if dst_bottom <= src_top:
        candidates.append((ecodes.KEY_UP, src_top - dst_bottom, -horizontal_overlap, abs(dx)))
    return candidates


def _maybe_update_neighbor(nearest, direction_key, score, dst_idx):
    """Remember the best known neighbor candidate for a direction key."""
    existing = nearest.get(direction_key)
    if existing is None or score < existing[0]:
        nearest[direction_key] = (score, dst_idx)


def _build_neighbor_map_for_source(src_idx, source, monitors):
    """Return the best directional neighbor mapping for one source monitor."""
    nearest = {}
    for dst_idx, target in enumerate(monitors):
        if src_idx == dst_idx:
            continue
        for direction_key, primary_gap, overlap_rank, secondary_gap in _monitor_neighbor_candidates(source, target):
            score = (primary_gap, overlap_rank, secondary_gap)
            _maybe_update_neighbor(nearest, direction_key, score, dst_idx)
    return nearest


def _resolve_pair_choice(src_idx, dst_idx, direction_key, score):
    """Normalize one directional candidate to a pair-choice tuple."""
    low_idx, high_idx = sorted((src_idx, dst_idx))
    if src_idx == low_idx:
        direction_from_low = direction_key
    else:
        direction_from_low = _opposite_direction(direction_key)
    pair_key = (low_idx, high_idx)
    candidate_rank = (score, src_idx, direction_key)
    return pair_key, candidate_rank, direction_from_low


def _merge_pair_choice(pair_choices, pair_key, candidate_rank, direction_from_low):
    """Keep only the strongest directional candidate for one monitor pair."""
    existing = pair_choices.get(pair_key)
    if existing is None or candidate_rank < existing[0]:
        pair_choices[pair_key] = (candidate_rank, direction_from_low)


def _build_directional_neighbors(monitors):
    """Build directional nearest-neighbor graph between logical monitors."""
    directional = [{} for _ in monitors]
    pair_choices = {}

    for src_idx, source in enumerate(monitors):
        nearest = _build_neighbor_map_for_source(src_idx, source, monitors)
        for direction_key, (score, dst_idx) in nearest.items():
            pair_key, candidate_rank, direction_from_low = _resolve_pair_choice(src_idx, dst_idx, direction_key, score)
            _merge_pair_choice(pair_choices, pair_key, candidate_rank, direction_from_low)

    for (low_idx, high_idx), (_candidate_rank, direction_from_low) in pair_choices.items():
        directional[low_idx][high_idx] = direction_from_low
        directional[high_idx][low_idx] = _opposite_direction(direction_from_low)

    return directional


def _direction_between_monitors(source, target):
    """Map two monitor coordinates to the best directional window-move key."""
    dx = target["x"] - source["x"]
    dy = target["y"] - source["y"]
    if abs(dx) > abs(dy):
        return ecodes.KEY_RIGHT if dx >= 0 else ecodes.KEY_LEFT
    return ecodes.KEY_DOWN if dy >= 0 else ecodes.KEY_UP


def _get_monitor_refresh_state():
    """Return the cached monitor state values used by topology refresh logic."""
    return hotkey_state.get_monitor_refresh_state()


def _should_refresh_monitors(now, last_known_monitors, last_topology_refresh):
    """Return True when the cached monitor topology should be refreshed."""
    return last_known_monitors is None or (now - last_topology_refresh) >= hotkey_state.get_topology_refresh_seconds()


def _update_monitor_cache(detected_monitors, fallback_monitors):
    """Cache the latest topology data and return cloned monitor state."""
    if detected_monitors:
        refreshed_monitors = [dict(monitor) for monitor in detected_monitors]
        hotkey_state.set_last_known_monitors(refreshed_monitors)
        return _clone_monitors(refreshed_monitors)
    return _clone_monitors(fallback_monitors)


def _remember_topology_refresh(now):
    """Update shared topology-refresh state for the current refresh cycle."""
    hotkey_state.set_last_topology_refresh(now)


def _apply_detected_monitors(detected_monitors, source, now=None):
    """Store a live topology detection result in the shared monitor cache."""
    hotkey_state.apply_detected_topology(
        [dict(monitor) for monitor in detected_monitors],
        source,
        now,
    )


def _topology_refresh_worker():
    """Fetch topology off the hotkey thread and update the shared cache."""
    try:
        allow_xrandr = hotkey_state.get_last_topology_source() != "mutter"
        _profile, detected_monitors, source = detect_swap_topology_map(allow_xrandr=allow_xrandr)
        if detected_monitors:
            _apply_detected_monitors(detected_monitors, source)
    finally:
        with _TOPOLOGY_REFRESH_LOCK:
            _TOPOLOGY_REFRESH["in_flight"] = False


def _schedule_topology_refresh(now):
    """Kick a background topology refresh when one is not already running."""
    with _TOPOLOGY_REFRESH_LOCK:
        if _TOPOLOGY_REFRESH["in_flight"]:
            return
        _TOPOLOGY_REFRESH["in_flight"] = True
    # Stamp refresh time before start so a fast worker cannot clear in_flight
    # and leave last_topology_refresh stale for the next schedule check.
    _remember_topology_refresh(now)
    worker = _thread_factory(target=_topology_refresh_worker, daemon=True)
    try:
        worker.start()
    except RuntimeError:
        with _TOPOLOGY_REFRESH_LOCK:
            _TOPOLOGY_REFRESH["in_flight"] = False


def _refresh_monitors(now):
    """Return cached monitors and schedule a nonblocking topology refresh when stale."""
    last_known_monitors, last_topology_refresh = _get_monitor_refresh_state()
    if _should_refresh_monitors(now, last_known_monitors, last_topology_refresh):
        _schedule_topology_refresh(now)
    return _clone_monitors(last_known_monitors)


def prime_topology_cache():
    """Synchronously seed monitor topology before the hotkey event loop."""
    prime_gnome_window_swap_extension()
    now = time.monotonic()
    # Retry once: Mutter D-Bus can miss on the first probe right after login /
    # daemon start, leaving the first window-swap press on the deferred path.
    for _attempt in range(2):
        _profile, detected_monitors, source = detect_swap_topology_map(allow_xrandr=True)
        if detected_monitors:
            _apply_detected_monitors(detected_monitors, source, now)
            return
        if not _attempt:
            time.sleep(0.05)
    _schedule_topology_refresh(now)


def _clone_monitors(monitors):
    """Return a shallow copy of monitor data or None for empty state."""
    if not monitors:
        return None
    return [dict(monitor) for monitor in monitors]


def _bounce_src_dst(ordered, step):
    """Return (src_idx, dst_idx, next_step) for a bounce traversal of *ordered*."""
    count = len(ordered)
    if count <= 1:
        return None, None, 0
    cycle_length = 2 * (count - 1)
    phase = step % cycle_length
    if phase < (count - 1):
        return ordered[phase], ordered[phase + 1], (step + 1) % cycle_length
    reverse_phase = phase - (count - 1)
    src_idx = ordered[count - 1 - reverse_phase]
    dst_idx = ordered[count - 2 - reverse_phase]
    return src_idx, dst_idx, (step + 1) % cycle_length


def _bounce_step_leaving_ordered_pos(ordered_pos, count):
    """Return bounce step whose source is *ordered_pos* (reverse at the end)."""
    if count <= 1:
        return 0
    # Last monitor has no forward neighbor — start the reverse hop immediately
    # so the first press is not a GNOME Super+Shift+Down no-op.
    if ordered_pos >= count - 1:
        return count - 1
    if ordered_pos <= 0:
        return 0
    return ordered_pos


def _align_swap_step_to_focus(monitors, current_step, ordered, attempts=3):
    """Realign bounce step when focus is not on the hop's expected source."""
    focused_idx = _focused_monitor_index(monitors, attempts=attempts)
    if focused_idx is None:
        return current_step
    src_idx, _dst_idx, _next_step = _bounce_src_dst(ordered, current_step)
    if src_idx == focused_idx:
        return current_step
    try:
        ordered_pos = ordered.index(focused_idx)
    except ValueError:
        return current_step
    return _bounce_step_leaving_ordered_pos(ordered_pos, len(ordered))
