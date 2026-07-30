#!/usr/bin/env python3
"""ASUS ZenBook Touchpad Top-Left Corner Share Gesture Handler."""

import logging
import os
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, replace

import evdev
from evdev import ecodes

try:
    from .asus_common import close_input_device, find_input_device_path, is_executable_file
except ImportError:  # Script execution path: python3 bin/asus_touchpad_share.py
    from asus_common import close_input_device, find_input_device_path, is_executable_file

MAX_TAP_DURATION_S = 0.7
SCREENSHOT_COOLDOWN_S = 1.5
SCREENSHOT_HELPER_TIMEOUT_S = 5
_logger = logging.getLogger(__name__)


def find_touchpad_device_path():
    """Locate primary touchpad device dynamically."""
    return find_input_device_path("touchpad")


def get_abs_axis(device, mt_code, abs_code):
    """Safely fetch max bounds without KeyError/OSError crashes."""
    try:
        info = device.absinfo(mt_code)
        if info:
            return info
    except (KeyError, OSError):
        pass
    try:
        info = device.absinfo(abs_code)
        if info:
            return info
    except (KeyError, OSError):
        pass
    return None


def _screenshot_helper_path():
    """Return the preferred path to asus-screenshot.sh."""
    override = os.environ.get("ASUS_SCREENSHOT_HELPER")
    if override and is_executable_file(override):
        return override
    bindir = os.environ.get("ASUS_BIN_DIR", "/usr/local/bin")
    candidate = os.path.join(bindir, "asus-screenshot.sh")
    if is_executable_file(candidate):
        return candidate
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(here, "asus-screenshot.sh")


def _run_screenshot_helper(helper):
    """Run the screenshot helper subprocess and log failures."""
    try:
        completed = subprocess.run(
            [helper],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=SCREENSHOT_HELPER_TIMEOUT_S,
            check=False,
        )
    except subprocess.TimeoutExpired:
        _logger.warning("Screenshot helper timed out (%s)", helper)
        return
    except OSError as exc:
        _logger.warning("Screenshot helper failed (%s): %s", helper, exc)
        return
    if completed.returncode:
        _logger.warning(
            "Screenshot helper exited with status %s: %s",
            completed.returncode,
            helper,
        )


def trigger_screenshot():
    """Start the multi-DE screenshot helper without blocking the event loop."""
    helper = _screenshot_helper_path()
    try:
        threading.Thread(target=_run_screenshot_helper, args=(helper,), daemon=True).start()
    except RuntimeError as exc:
        _logger.warning("Screenshot helper thread failed (%s): %s", helper, exc)
        raise OSError(f"Failed to start screenshot helper thread for {helper}") from exc


def _update_axis(curr, is_touching, start):
    """Return updated (start, curr) for a single axis."""
    if is_touching and start == -1:
        start = curr
    return start, curr


def process_abs_event(event, is_touching, state):
    """Process absolute position input events."""
    start_x, start_y, curr_x, curr_y = state
    if event.code in (ecodes.ABS_MT_POSITION_X, ecodes.ABS_X):
        start_x, curr_x = _update_axis(event.value, is_touching, start_x)
    elif event.code in (ecodes.ABS_MT_POSITION_Y, ecodes.ABS_Y):
        start_y, curr_y = _update_axis(event.value, is_touching, start_y)
    return start_x, start_y, curr_x, curr_y


def _pick_check(primary, fallback):
    """Return primary if set, else fallback."""
    if primary != -1:
        return primary
    return fallback


def is_corner_gesture(coords, bounds):
    """Check if gesture is in top-left corner within duration limit."""
    start_x, start_y, curr_x, curr_y, duration = coords
    corner_x_max, corner_y_max = bounds
    check_x = _pick_check(curr_x, start_x)
    check_y = _pick_check(curr_y, start_y)
    if check_x < 0 or check_y < 0:
        return False
    return check_x <= corner_x_max and check_y <= corner_y_max and duration < MAX_TAP_DURATION_S


@dataclass(frozen=True)
class PointerGesture:
    """Pointer position and touch timing for Share gesture detection."""

    start_x: int = -1
    start_y: int = -1
    curr_x: int = -1
    curr_y: int = -1
    is_touching: bool = False
    t_start: float = 0.0
    t_last: float = 0.0


@dataclass(frozen=True)
class MultiTouchGesture:
    """Multitouch slot tracking; second contact cancels Share."""

    mt_slot: int = 0
    slot_tracking: frozenset = frozenset()
    active_tracking_ids: frozenset = frozenset()
    multi_touch_cancelled: bool = False


@dataclass(frozen=True)
class GestureState:
    """Track touch gesture state across events with named fields."""

    pointer: PointerGesture = PointerGesture()
    multitouch: MultiTouchGesture = MultiTouchGesture()


def _replace_pointer(state, **kwargs):
    return replace(state, pointer=replace(state.pointer, **kwargs))


def _replace_multitouch(state, **kwargs):
    return replace(state, multitouch=replace(state.multitouch, **kwargs))


def _handle_touch_release(state, bounds):
    """Evaluate released touch and fire screenshot if corner gesture matched."""
    now = time.monotonic()
    duration = now - state.pointer.t_start
    coords = (
        state.pointer.start_x,
        state.pointer.start_y,
        state.pointer.curr_x,
        state.pointer.curr_y,
        duration,
    )
    t_last = state.pointer.t_last
    if state.multitouch.multi_touch_cancelled:
        return t_last
    if is_corner_gesture(coords, bounds) and (now - t_last) > SCREENSHOT_COOLDOWN_S:
        try:
            trigger_screenshot()
            t_last = now
        except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
            _logger.warning("Share gesture screenshot failed: %s", exc)
    return t_last


def _is_touch_key(event):
    """Return True when event reports physical touch contact (BTN_TOUCH only)."""
    return event.type == ecodes.EV_KEY and event.code == ecodes.BTN_TOUCH


def _apply_mt_slot(event, state):
    """Select the multitouch slot for subsequent ABS_MT_TRACKING_ID events."""
    return _replace_multitouch(state, mt_slot=event.value)


def _tracking_multi_touch_cancelled(prior_cancelled, tracking_id, prior_ids, active_ids):
    """Return True when a second distinct contact should cancel Share."""
    if prior_cancelled or len(active_ids) > 1:
        return True
    return tracking_id >= 0 and bool(prior_ids) and tracking_id not in prior_ids


def _apply_tracking_id(event, state):
    """Update slot→tracking map; cancel when a second contact appears."""
    tracking_id = event.value
    slots = dict(state.multitouch.slot_tracking)
    prior_ids = frozenset(slots.values())
    if tracking_id < 0:
        slots.pop(state.multitouch.mt_slot, None)
    else:
        slots[state.multitouch.mt_slot] = tracking_id
    slot_tracking = frozenset(slots.items())
    ids = frozenset(slots.values())
    cancelled = _tracking_multi_touch_cancelled(
        state.multitouch.multi_touch_cancelled, tracking_id, prior_ids, ids
    )
    return _replace_multitouch(
        state,
        slot_tracking=slot_tracking,
        active_tracking_ids=ids,
        multi_touch_cancelled=cancelled,
    )


def _handle_touch_key(event, state, bounds):
    """Handle a BTN_TOUCH event; return updated state tuple."""
    if event.value == 1:
        if state.pointer.is_touching:
            return state
        # Keep last ABS coordinates so a single-frame tap still has a position.
        return GestureState(
            pointer=PointerGesture(
                is_touching=True,
                t_start=time.monotonic(),
                t_last=state.pointer.t_last,
                start_x=state.pointer.curr_x,
                start_y=state.pointer.curr_y,
                curr_x=state.pointer.curr_x,
                curr_y=state.pointer.curr_y,
            ),
            multitouch=MultiTouchGesture(
                mt_slot=state.multitouch.mt_slot,
                slot_tracking=state.multitouch.slot_tracking,
                active_tracking_ids=state.multitouch.active_tracking_ids,
                multi_touch_cancelled=False,
            ),
        )
    if not event.value:
        t_last = state.pointer.t_last
        if state.pointer.is_touching:
            t_last = _handle_touch_release(state, bounds)
        return GestureState(
            pointer=PointerGesture(
                curr_x=state.pointer.curr_x,
                curr_y=state.pointer.curr_y,
                is_touching=False,
                t_start=state.pointer.t_start,
                t_last=t_last,
            ),
            multitouch=MultiTouchGesture(
                mt_slot=state.multitouch.mt_slot,
                slot_tracking=frozenset(),
                active_tracking_ids=frozenset(),
                multi_touch_cancelled=False,
            ),
        )
    return state


def _dispatch_abs_event(event, state):
    """Handle ABS events including multi-touch tracking IDs."""
    if event.code == ecodes.ABS_MT_SLOT:
        return _apply_mt_slot(event, state)
    if event.code == ecodes.ABS_MT_TRACKING_ID:
        return _apply_tracking_id(event, state)
    start_x, start_y, curr_x, curr_y = process_abs_event(
        event,
        state.pointer.is_touching,
        (
            state.pointer.start_x,
            state.pointer.start_y,
            state.pointer.curr_x,
            state.pointer.curr_y,
        ),
    )
    return _replace_pointer(
        state,
        start_x=start_x,
        start_y=start_y,
        curr_x=curr_x,
        curr_y=curr_y,
    )


def _dispatch_event(event, state, bounds):
    """Dispatch one event; return updated state tuple."""
    if event.type == ecodes.EV_ABS:
        return _dispatch_abs_event(event, state)
    if _is_touch_key(event):
        return _handle_touch_key(event, state, bounds)
    return state


def run_event_loop(dev, bounds):
    """Run the touch event loop."""
    state = GestureState()
    try:
        for event in dev.read_loop():
            state = _dispatch_event(event, state, bounds)
    except OSError as exc:
        _logger.error("Touchpad read loop failed: %s", exc)
        raise


def _open_touchpad(device_path):
    """Open the touchpad InputDevice or exit on error."""
    try:
        return evdev.InputDevice(device_path)
    except (OSError, ValueError) as e:
        sys.exit(f"Failed to open touchpad device {device_path}: {e}")


def _get_axis_range(abs_axis, default_min, default_max):
    """Extract (min, max) bounds from an AbsInfo object or return defaults."""
    if not abs_axis:
        return default_min, default_max
    return getattr(abs_axis, "min", default_min), getattr(abs_axis, "max", default_max)


def _compute_bounds(dev):
    """Return (corner_x_max, corner_y_max) as min + 20% of the touchpad range."""
    abs_x = get_abs_axis(dev, ecodes.ABS_MT_POSITION_X, ecodes.ABS_X)
    abs_y = get_abs_axis(dev, ecodes.ABS_MT_POSITION_Y, ecodes.ABS_Y)

    min_x, max_x = _get_axis_range(abs_x, 0, 4000)
    min_y, max_y = _get_axis_range(abs_y, 0, 3000)

    corner_x = min_x + 0.20 * (max_x - min_x)
    corner_y = min_y + 0.20 * (max_y - min_y)
    return (corner_x, corner_y)


def _release_input_resources(dev):
    """Release the physical touchpad device after event handling."""
    close_input_device(dev)


def main():
    """Main event loop for processing touchpad share gesture events."""
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    device_path = find_touchpad_device_path()
    if not device_path:
        sys.exit("Error: No touchpad device found.")

    dev = _open_touchpad(device_path)
    try:
        try:
            run_event_loop(dev, _compute_bounds(dev))
        except KeyboardInterrupt:
            pass
    finally:
        _release_input_resources(dev)


if __name__ == "__main__":
    main()
