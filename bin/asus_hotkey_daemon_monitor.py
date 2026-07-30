#!/usr/bin/env python3
"""Monitor-swap facade for the ASUS hotkey daemon.

Re-exports topology/window-swap APIs so production and tests can keep importing
from this module. Prefer patching the owning implementation module when a symbol
is called via a local import binding (see tests/unit/bin/hotkey_daemon_test_utils.py).
"""

import shutil
import time

import asus_hotkey_daemon_topology as _topology
import asus_hotkey_daemon_window_swap as _window_swap
import asus_hotkey_daemon_window_swap_gnome as _window_swap_gnome
from asus_hotkey_daemon_desktop_family import desktop_family_hint
from asus_hotkey_daemon_threading import _thread_factory
from asus_hotkey_daemon_topology import (
    get_monitor_signature,
    get_topology_refresh_state,
    prime_topology_cache,
    reset_topology_refresh_state,
)
from asus_hotkey_daemon_topology_detect import detect_swap_topology_map
from asus_hotkey_daemon_window_move import _emit_window_move, _window_move_emitter
from asus_hotkey_daemon_window_swap import (
    _apply_window_move,
    _claim_window_swap_slot,
    _perform_window_swap,
    _resolve_monitors_for_deferred_swap,
    _start_deferred_window_swap_worker,
    _start_window_swap_worker,
    get_window_swap_state,
    perform_window_swap,
    reset_window_swap_state,
    window_swap_worker,
)
from asus_hotkey_daemon_window_swap_gnome import (
    _apply_gnome_window_move,
    _focused_monitor_index,
    _gnome_window_swap_dbus_ready,
    _gnome_window_swap_dbus_ready_fast,
    _mutter_move_focused,
    prime_gnome_window_swap_extension,
)

__all__ = [
    "_apply_gnome_window_move",
    "_apply_window_move",
    "_claim_window_swap_slot",
    "_emit_window_move",
    "_focused_monitor_index",
    "_gnome_window_swap_dbus_ready",
    "_gnome_window_swap_dbus_ready_fast",
    "_mutter_move_focused",
    "_perform_window_swap",
    "_resolve_monitors_for_deferred_swap",
    "_start_deferred_window_swap_worker",
    "_start_window_swap_worker",
    "_thread_factory",
    "_window_move_emitter",
    "desktop_family_hint",
    "detect_swap_topology_map",
    "get_monitor_signature",
    "get_topology_refresh_state",
    "get_window_swap_state",
    "perform_window_swap",
    "prime_gnome_window_swap_extension",
    "prime_topology_cache",
    "reset_topology_refresh_state",
    "reset_window_swap_state",
    "shutil",
    "time",
    "window_swap_worker",
]

_COMPAT_EXPORT_OWNERS = {
    "_bounce_step_leaving_ordered_pos": _topology,
    "_build_directional_neighbors": _topology,
    "_clone_monitors": _topology,
    "_detect_monitor_layout": _topology,
    "_dfs_visit_node": _topology,
    "_direction_between_monitors": _topology,
    "_fill_unreachable": _topology,
    "_mixed_layout_cycle_order": _topology,
    "_monitor_indices_in_cycle_order": _topology,
    "_monitor_neighbor_candidates": _topology,
    "_neighbor_sort_key": _topology,
    "_primary_monitor_index": _topology,
    "_refresh_monitors": _topology,
    "_schedule_topology_refresh": _topology,
    "_swap_direction_from_step": _topology,
    "_topology_refresh_worker": _topology,
    "_clear_window_swap_in_flight": _window_swap,
    "_deferred_window_swap_worker": _window_swap,
    "_monitors_for_deferred_swap": _window_swap,
    "_move_window_geometric": _window_swap,
    "_move_window_via_wmctrl": _window_swap,
    "_move_window_via_xdotool": _window_swap,
    "_neighbor_origin_for_direction": _window_swap,
    "_resolve_swap_direction": _window_swap,
    "_run_cached_window_swap": _window_swap,
    "_should_defer_cached_window_swap": _window_swap,
    "_swap_direction_for_monitors": _window_swap,
    "_usable_monitors_for_swap": _window_swap,
    "_gnome_window_swap_dbus_ready_ttl": _window_swap_gnome,
    "_monitor_index_at_point": _window_swap_gnome,
    "_parse_gdbus_bool": _window_swap_gnome,
    "_parse_gdbus_int": _window_swap_gnome,
    "_parse_xdotool_mouse_point": _window_swap_gnome,
    "_parse_xdotool_window_center": _window_swap_gnome,
}


def __getattr__(name):
    """Resolve compatibility exports from their owning split modules."""
    owner = _COMPAT_EXPORT_OWNERS.get(name)
    if owner is None:
        raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
    return getattr(owner, name)
