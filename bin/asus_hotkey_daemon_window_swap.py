#!/usr/bin/env python3
"""Window swap orchestration for the ASUS hotkey daemon."""

import logging
import shutil
import subprocess
import threading
import time

import asus_hotkey_daemon_state as hotkey_state
from asus_hotkey_daemon_desktop_family import desktop_family_hint
from asus_hotkey_daemon_session import run_in_desktop_session
from asus_hotkey_daemon_threading import _thread_factory
from asus_hotkey_daemon_topology import (
    _align_swap_step_to_focus,
    _apply_detected_monitors,
    _bounce_src_dst,
    _build_directional_neighbors,
    _clone_monitors,
    _direction_between_monitors,
    _monitor_indices_in_cycle_order,
    _primary_monitor_index,
    _refresh_monitors,
    get_monitor_signature,
)
from asus_hotkey_daemon_topology_detect import detect_swap_topology_map
from asus_hotkey_daemon_window_move import _emit_window_move
from asus_hotkey_daemon_window_swap_gnome import (
    _WINDOW_SWAP_DBUS_READY,
    _WINDOW_SWAP_DBUS_READY_LOCK,
    _apply_gnome_window_move,
    _gnome_window_swap_dbus_ready_fast,
    prime_gnome_window_swap_extension,
)

_logger = logging.getLogger(__name__)
_WINDOW_SWAP_LOCK = threading.Lock()
_WINDOW_SWAP = {
    "in_flight": False,
    "committed_step": None,
    "pending": None,
    "draining": False,
    "deferred_active": False,
}


def reset_window_swap_state():
    """Reset window-swap async bookkeeping used by unit tests."""
    with _WINDOW_SWAP_LOCK:
        _WINDOW_SWAP["in_flight"] = False
        _WINDOW_SWAP["committed_step"] = None
        _WINDOW_SWAP["pending"] = None
        _WINDOW_SWAP["draining"] = False
        _WINDOW_SWAP["deferred_active"] = False
    with _WINDOW_SWAP_DBUS_READY_LOCK:
        _WINDOW_SWAP_DBUS_READY["ready"] = None
        _WINDOW_SWAP_DBUS_READY["expires"] = 0.0


def get_window_swap_state():
    """Return window-swap bookkeeping dict (live; for tests)."""
    return _WINDOW_SWAP


def _direction_for_monitor_pair(monitors, src_idx, dst_idx, neighbors):
    """Return a move key using the neighbor graph, with origin-delta fallback."""
    direction = neighbors[src_idx].get(dst_idx)
    if direction is not None:
        return direction
    return _direction_between_monitors(monitors[src_idx], monitors[dst_idx])


def _swap_direction_for_monitors(monitors, current_step, attempts=3):
    """Return next swap direction/step/target (Nones when <2 monitors)."""
    if not monitors or len(monitors) < 2:
        return None, current_step, None
    neighbors = _build_directional_neighbors(monitors)
    ordered_indices = _monitor_indices_in_cycle_order(monitors, neighbors)
    current_step = _align_swap_step_to_focus(monitors, current_step, ordered_indices, attempts=attempts)
    src_idx, dst_idx, next_step = _bounce_src_dst(ordered_indices, current_step)
    if src_idx is None or dst_idx is None:
        return None, current_step, None
    direction = _direction_for_monitor_pair(monitors, src_idx, dst_idx, neighbors)
    return direction, next_step, monitors[dst_idx]


def _signature_monitor_count(signature):
    """Return how many monitors a topology signature describes."""
    if not signature:
        return 0
    return len(signature)


def _resolve_swap_direction(monitors, current_step, attempts=3):
    """Return a window-swap key, next step, and destination monitor dict."""
    if not monitors:
        hotkey_state.set_swap_topology_signature(None)
        return None, current_step, None
    topology_signature = get_monitor_signature(monitors)
    previous = hotkey_state.get_swap_topology_signature()
    if topology_signature != previous:
        hotkey_state.set_swap_topology_signature(topology_signature)
        if _signature_monitor_count(previous) != _signature_monitor_count(topology_signature):
            current_step = 0
    return _swap_direction_for_monitors(monitors, current_step, attempts=attempts)


def _origin_for_neighbor_key(monitors, neighbor_map, direction_key):
    """Return (x, y) for the first neighbor matching *direction_key*."""
    for target_idx, key in neighbor_map.items():
        if key != direction_key:
            continue
        target = monitors[target_idx]
        return target["x"], target["y"]
    return None


def _neighbor_origin_for_direction(monitors, direction_key, neighbors=None):
    """Return origin of the first neighbor matching direction_key, or None."""
    if not monitors or len(monitors) < 2:
        return None
    graph = neighbors if neighbors is not None else _build_directional_neighbors(monitors)
    source = _primary_monitor_index(monitors)
    return _origin_for_neighbor_key(monitors, graph[source], direction_key)


def _move_window_via_wmctrl(x_pos, y_pos):
    """Move the active window with wmctrl when available."""
    if not shutil.which("wmctrl"):
        return False
    try:
        result = run_in_desktop_session(
            ["wmctrl", "-r", ":ACTIVE:", "-e", f"0,{x_pos},{y_pos},-1,-1"],
            2,
            requires_dbus=True,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return not result.returncode


def _move_window_via_xdotool(x_pos, y_pos):
    """Move the active window with xdotool when available."""
    if not shutil.which("xdotool"):
        return False
    try:
        result = run_in_desktop_session(
            ["xdotool", "getactivewindow", "windowmove", str(x_pos), str(y_pos)],
            2,
            requires_dbus=True,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return not result.returncode


def _move_window_to_monitor(monitor):
    """Move the focused window to the origin of *monitor* via X11 tools."""
    if not monitor:
        return False
    x_pos, y_pos = monitor["x"], monitor["y"]
    if _move_window_via_wmctrl(x_pos, y_pos):
        return True
    return _move_window_via_xdotool(x_pos, y_pos)


def _move_window_geometric(monitors, direction_key):
    """Move the focused window to a neighbor monitor via X11 window tools."""
    origin = _neighbor_origin_for_direction(monitors, direction_key)
    if origin is None:
        return False
    x_pos, y_pos = origin
    if _move_window_via_wmctrl(x_pos, y_pos):
        return True
    return _move_window_via_xdotool(x_pos, y_pos)


def _apply_window_move(ui, monitors, direction_key, target_monitor=None, attempts=3):
    """Move on kde/xfce/lxqt/cinnamon/mate via wmctrl/xdotool; GNOME prefers Mutter."""
    family = desktop_family_hint()
    if family in {"kde", "xfce", "lxqt", "cinnamon", "mate"}:
        if _move_window_to_monitor(target_monitor):
            return True
        return _move_window_geometric(monitors, direction_key)
    if family == "gnome":
        return _apply_gnome_window_move(ui, direction_key, attempts=attempts)
    return _emit_window_move(ui, direction_key)


def window_swap_worker(ui, monitors, direction_key, target_monitor):
    """Run window move off the hotkey thread and clear the in-flight guard.

    Test/compat API: production deferred hops use `_start_deferred_window_swap_worker`.
    """
    try:
        _apply_window_move(ui, monitors, direction_key, target_monitor)
    finally:
        _clear_window_swap_in_flight()


def _queue_pending_window_swap(ui, swap_step):
    """Remember one coalesced swap request while another move is in flight."""
    with _WINDOW_SWAP_LOCK:
        _WINDOW_SWAP["pending"] = (ui, int(swap_step))


def _take_pending_window_swap():
    """Return one pending (ui, step), clear the queue, and clear in_flight when empty.

    When pending is None and no deferred worker owns the slot, clear in_flight
    under the same lock acquisition so a press cannot queue between unlock and
    clearing the in-flight flag.
    """
    with _WINDOW_SWAP_LOCK:
        pending = _WINDOW_SWAP.get("pending")
        _WINDOW_SWAP["pending"] = None
        if pending is None and not _WINDOW_SWAP.get("deferred_active"):
            _WINDOW_SWAP["in_flight"] = False
        return pending


def _drain_pending_swap():
    """Iteratively drain coalesced pending swaps without recursive clear."""
    with _WINDOW_SWAP_LOCK:
        if _WINDOW_SWAP.get("draining"):
            return
        _WINDOW_SWAP["draining"] = True
    try:
        while True:
            pending = _take_pending_window_swap()
            if pending is None:
                return
            ui, step = pending
            _perform_window_swap(ui, step)
            with _WINDOW_SWAP_LOCK:
                deferred_active = bool(_WINDOW_SWAP.get("deferred_active"))
            if deferred_active:
                # Worker owns in_flight; completion clears and drains again.
                return
    finally:
        with _WINDOW_SWAP_LOCK:
            _WINDOW_SWAP["draining"] = False


def _clear_window_swap_in_flight():
    """Clear in-flight; drain pending swaps unless already draining."""
    with _WINDOW_SWAP_LOCK:
        _WINDOW_SWAP["in_flight"] = False
        if _WINDOW_SWAP.get("draining"):
            return
    _drain_pending_swap()


def _take_committed_swap_step(current_step):
    """Return a worker-committed step when present, else *current_step*."""
    with _WINDOW_SWAP_LOCK:
        committed = _WINDOW_SWAP.get("committed_step")
        if committed is None:
            return int(current_step)
        _WINDOW_SWAP["committed_step"] = None
        return int(committed)


def _commit_swap_step(next_step):
    """Publish the next bounce step from a deferred worker."""
    with _WINDOW_SWAP_LOCK:
        _WINDOW_SWAP["committed_step"] = int(next_step)


def _start_window_swap_worker(ui, monitors, direction_key, target_monitor):
    """Start a background window-swap worker; return False when start fails.

    Test/compat API wrapping `window_swap_worker` (see that docstring).
    """
    worker = _thread_factory(
        target=window_swap_worker,
        args=(ui, monitors, direction_key, target_monitor),
        daemon=True,
    )
    try:
        worker.start()
    except RuntimeError:
        _clear_window_swap_in_flight()
        return False
    return True


def _resolve_monitors_for_deferred_swap():
    """Detect topology on a worker thread and return usable monitors or None."""
    for _attempt in range(2):
        _profile, detected, source = detect_swap_topology_map(allow_xrandr=True)
        if detected:
            _apply_detected_monitors(detected, source, time.monotonic())
        monitors = _clone_monitors(hotkey_state.get_last_known_monitors())
        if _monitors_are_usable(monitors):
            return monitors
        if not _attempt:
            time.sleep(0.05)
    return None


def _monitors_for_deferred_swap(seed_monitors):
    """Reuse event-thread monitors when usable; otherwise detect off-thread."""
    if _monitors_are_usable(seed_monitors):
        return seed_monitors
    return _resolve_monitors_for_deferred_swap()


def _deferred_window_swap_worker(ui, swap_step, monitors=None):
    """Perform one swap hop off the event thread (reuse monitors when provided)."""
    try:
        monitors = _monitors_for_deferred_swap(monitors)
        if monitors is None:
            _logger.warning("Window swap skipped: monitor topology unavailable")
            return
        # Prime only when GNOME; keep attempts=1 so a missing D-Bus object falls
        # through to uinput quickly instead of multi-second retry stacks.
        prime_gnome_window_swap_extension()
        direction_key, next_step, target = _resolve_swap_direction(monitors, swap_step, attempts=1)
        if not _window_swap_ready(direction_key, target, monitors):
            _logger.warning("Window swap skipped: monitor topology unavailable")
            return
        # Advance bounce step only after a successful move (failed first hop used
        # to look like a no-op while step still advanced for the next press).
        if _apply_window_move(ui, monitors, direction_key, target, attempts=1):
            _commit_swap_step(next_step)
    finally:
        with _WINDOW_SWAP_LOCK:
            _WINDOW_SWAP["deferred_active"] = False
        _clear_window_swap_in_flight()


def _start_deferred_window_swap_worker(ui, swap_step, monitors=None):
    """Start deferred detect+swap worker; return False when start fails."""
    worker = _thread_factory(
        target=_deferred_window_swap_worker,
        args=(ui, swap_step, monitors),
        daemon=True,
    )
    with _WINDOW_SWAP_LOCK:
        _WINDOW_SWAP["deferred_active"] = True
    try:
        worker.start()
    except RuntimeError:
        with _WINDOW_SWAP_LOCK:
            _WINDOW_SWAP["deferred_active"] = False
        _clear_window_swap_in_flight()
        return False
    return True


def _monitors_are_usable(monitors):
    """Return True when topology has at least two monitors."""
    return bool(monitors) and len(monitors) >= 2


def _usable_monitors_for_swap():
    """Return cached monitors; stale cache triggers refresh via _refresh_monitors only.

    Reads the topology monitor cache without locking against async topology
    workers, so the event thread may briefly see a snapshot from before a
    refresh completes.
    """
    return _refresh_monitors(time.monotonic())


def _window_swap_ready(direction_key, target, monitors):
    """Return True when direction, target, and topology are swap-ready."""
    if direction_key is None or target is None:
        return False
    return _monitors_are_usable(monitors)


def _claim_window_swap_slot():
    """Mark swap in-flight; return False when another swap is already running."""
    with _WINDOW_SWAP_LOCK:
        if _WINDOW_SWAP["in_flight"]:
            return False
        _WINDOW_SWAP["in_flight"] = True
        return True


def _should_defer_cached_window_swap():
    """Return True when a cached hop must leave the hotkey event thread."""
    family = desktop_family_hint()
    if family in {"kde", "xfce", "lxqt", "cinnamon", "mate"}:
        return True
    return family == "gnome" and not _gnome_window_swap_dbus_ready_fast()


def _run_cached_window_swap(ui, current_step, monitors):
    """Resolve and apply one swap hop using already-usable *monitors*.

    Sync only for GNOME when the Window Swap extension is already ready.
    Defer kde/xfce/lxqt/cinnamon/mate (wmctrl/xdotool) and GNOME-not-ready paths so the
    hotkey event thread never blocks on subprocess or extension enable / D-Bus waits.
    """
    if _should_defer_cached_window_swap():
        # Pass already-usable monitors so the worker skips Mutter re-detect
        # (that 5s path made deferred hops take tens of seconds).
        _start_deferred_window_swap_worker(ui, current_step, monitors)
        return current_step
    direction_key, next_step, target = _resolve_swap_direction(monitors, current_step, attempts=1)
    if not _window_swap_ready(direction_key, target, monitors):
        _clear_window_swap_in_flight()
        _logger.warning("Window swap skipped: monitor topology unavailable")
        return current_step
    try:
        # Topology is already cached — apply on this call so the first Fn press
        # moves immediately (async worker made the first press look like a no-op
        # when the move failed after the bounce step had already advanced).
        moved = _apply_window_move(ui, monitors, direction_key, target, attempts=1)
    finally:
        _clear_window_swap_in_flight()
    if not moved:
        _logger.warning("Window swap move failed")
        return current_step
    return next_step


def _perform_window_swap(ui, swap_step):
    """Perform one swap gesture step that traverses all active monitors."""
    current_step = _take_committed_swap_step(swap_step)
    if not _claim_window_swap_slot():
        # Coalesce: do not drop presses while detect/move is still running.
        _queue_pending_window_swap(ui, current_step)
        return current_step
    monitors = _usable_monitors_for_swap()
    if not _monitors_are_usable(monitors):
        _start_deferred_window_swap_worker(ui, current_step)
        return current_step
    return _run_cached_window_swap(ui, current_step, monitors)


def perform_window_swap(ui, swap_step):
    """Public entry: claim the swap slot before running one hop."""
    return _perform_window_swap(ui, swap_step)
