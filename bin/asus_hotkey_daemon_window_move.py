"""Uinput window-move chord helpers for the ASUS hotkey daemon."""

import logging

from evdev import ecodes

_logger = logging.getLogger(__name__)


def _emit_window_move_impl(ui, direction_key):
    """Emit one Super+Shift+Arrow key combination."""
    ui.write(ecodes.EV_KEY, ecodes.KEY_LEFTMETA, 1)
    ui.write(ecodes.EV_KEY, ecodes.KEY_LEFTSHIFT, 1)
    ui.write(ecodes.EV_KEY, direction_key, 1)
    ui.write(ecodes.EV_SYN, ecodes.SYN_REPORT, 0)
    ui.write(ecodes.EV_KEY, direction_key, 0)
    ui.write(ecodes.EV_KEY, ecodes.KEY_LEFTSHIFT, 0)
    ui.write(ecodes.EV_KEY, ecodes.KEY_LEFTMETA, 0)
    ui.write(ecodes.EV_SYN, ecodes.SYN_REPORT, 0)


_window_move_emitter = _emit_window_move_impl


def _emit_window_move(ui, direction_key):
    """Emit one Super+Shift+Arrow key combination via a patchable emitter."""
    try:
        _window_move_emitter(ui, direction_key)
    except OSError as exc:
        _logger.warning("Failed to emit window-move chord (key=%s): %s", direction_key, exc)
        return False
    return True


def _opposite_direction(direction_key):
    """Return the opposite directional key for a monitor edge."""
    return {
        ecodes.KEY_UP: ecodes.KEY_DOWN,
        ecodes.KEY_DOWN: ecodes.KEY_UP,
        ecodes.KEY_LEFT: ecodes.KEY_RIGHT,
        ecodes.KEY_RIGHT: ecodes.KEY_LEFT,
    }[direction_key]
