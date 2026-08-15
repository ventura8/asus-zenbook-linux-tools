#!/usr/bin/env python3
"""ScreenPad brightness chord helpers for the ASUS hotkey daemon."""

import logging
import os
import time
from types import SimpleNamespace

import asus_hotkey_daemon_state as hotkey_state
import evdev
from asus_common import (
    close_input_device,
    find_all_input_device_paths,
    is_executable_file,
    list_evdev_device_paths,
)
from asus_hotkey_daemon_runtime import log_script_dispatch_outcome, run_script_if_exists
from evdev import ecodes

_logger = logging.getLogger(__name__)

_SCREENPAD_BRIGHTNESS_SCRIPT = "asus-screenpad-brightness.sh"
_AT_MODIFIER_STATE = SimpleNamespace(held=set())
_BRIGHTNESS_DEDUP = SimpleNamespace(at=0.0, code=None)
_SWALLOWED_AT_BRIGHTNESS = SimpleNamespace(codes=set())
_BRIGHTNESS_DEDUP_SECS = 0.08
_BRIGHTNESS_MODIFIER_CODES = frozenset(
    (
        ecodes.KEY_LEFTSHIFT,
        ecodes.KEY_RIGHTSHIFT,
    )
)
_AT_KEYBOARD_NAME = "AT Translated Set 2 keyboard"
_PROXY_KEYBOARD_NAME = "asus-at-keyboard-proxy"


def clear_at_modifier_state():
    """Clear tracked Shift state (unit tests / device loss)."""
    _AT_MODIFIER_STATE.held.clear()
    _SWALLOWED_AT_BRIGHTNESS.codes.clear()


def clear_brightness_dedup_state():
    """Clear WMI/Video Bus brightness dedupe (unit tests)."""
    _BRIGHTNESS_DEDUP.at = 0.0
    _BRIGHTNESS_DEDUP.code = None


def update_at_modifier_state(event):
    """Track Shift downs from watched keyboards; return True when handled."""
    if event.code not in _BRIGHTNESS_MODIFIER_CODES:
        return False
    if event.value:
        _AT_MODIFIER_STATE.held.add(event.code)
    else:
        _AT_MODIFIER_STATE.held.discard(event.code)
    return True


def brightness_modifier_held():
    """Return True when Shift is held on a watched keyboard."""
    return bool(_AT_MODIFIER_STATE.held)


def screenpad_brightness_direction(event_code):
    """Return up/down for a brightness key code, or None."""
    if event_code == ecodes.KEY_BRIGHTNESSUP:
        return "up"
    if event_code == ecodes.KEY_BRIGHTNESSDOWN:
        return "down"
    return None


def is_brightness_key(event_code):
    """Return True when *event_code* is a brightness up/down key."""
    return screenpad_brightness_direction(event_code) is not None


def _screenpad_sysfs_candidates():
    """Yield possible ScreenPad brightness sysfs paths."""
    override = os.environ.get("ASUS_SCREENPAD_NODE")
    if override:
        yield override
        return
    root = os.environ.get("SYS_CLASS_ROOT", "/sys/class")
    yield os.path.join(root, "backlight", "asus_screenpad", "brightness")
    yield os.path.join(root, "leds", "asus::screenpad", "brightness")


def screenpad_node_writable():
    """Return True when a writable ScreenPad brightness sysfs node exists."""
    for path in _screenpad_sysfs_candidates():
        if os.path.isfile(path) and os.access(path, os.W_OK):
            return True
    return False


def screenpad_brightness_ready():
    """Return True when the helper exists and ScreenPad sysfs is writable."""
    script_path = f"{hotkey_state.SCRIPT_BINDIR}/{_SCREENPAD_BRIGHTNESS_SCRIPT}"
    return is_executable_file(script_path) and screenpad_node_writable()


def dispatch_screenpad_brightness(direction):
    """Dispatch asus-screenpad-brightness.sh with up/down; return outcome."""
    script_path = f"{hotkey_state.SCRIPT_BINDIR}/{_SCREENPAD_BRIGHTNESS_SCRIPT}"
    outcome = run_script_if_exists(script_path, [direction])
    log_script_dispatch_outcome(script_path, outcome)
    return outcome


def try_screenpad_brightness_chord(event_code):
    """Swallow brightness while Shift held when ScreenPad control is ready."""
    direction = screenpad_brightness_direction(event_code)
    if direction is None or not brightness_modifier_held():
        return False
    if not screenpad_brightness_ready():
        return False
    _logger.info(
        "Shift+brightness chord; dispatching %s %s",
        _SCREENPAD_BRIGHTNESS_SCRIPT,
        direction,
    )
    outcome = dispatch_screenpad_brightness(direction)
    return outcome in ("started", "debounced")


def _brightness_event_is_duplicate(event_code):
    """True when WMI and Video Bus emit the same brightness key nearly together."""
    now = time.monotonic()
    if _BRIGHTNESS_DEDUP.code == event_code and now - _BRIGHTNESS_DEDUP.at < _BRIGHTNESS_DEDUP_SECS:
        return True
    _BRIGHTNESS_DEDUP.at = now
    _BRIGHTNESS_DEDUP.code = event_code
    return False


def handle_brightness_source_press(event_code, forward_key):
    """Filter one brightness key; *forward_key(code, value)* for main panel."""
    if not is_brightness_key(event_code):
        return False
    if _brightness_event_is_duplicate(event_code):
        return True
    if try_screenpad_brightness_chord(event_code):
        return True
    forward_key(event_code, 1)
    forward_key(event_code, 0)
    return True


def _release_swallowed_at_brightness(event_code):
    """True when a prior AT brightness down was chord-swallowed."""
    if event_code not in _SWALLOWED_AT_BRIGHTNESS.codes:
        return False
    _SWALLOWED_AT_BRIGHTNESS.codes.discard(event_code)
    return True


def _handle_at_brightness_keydown(event_code):
    """Swallow AT brightness key-down for Shift+ScreenPad or cross-source dedupe."""
    if _brightness_event_is_duplicate(event_code):
        _SWALLOWED_AT_BRIGHTNESS.codes.add(event_code)
        return True
    if not try_screenpad_brightness_chord(event_code):
        return False
    _SWALLOWED_AT_BRIGHTNESS.codes.add(event_code)
    return True


def try_handle_at_brightness_event(event):
    """Filter AT brightness keys for Shift+ScreenPad; True when swallowed."""
    if not is_brightness_key(event.code):
        return False
    if event.value == 1:
        return _handle_at_brightness_keydown(event.code)
    if not event.value:
        return _release_swallowed_at_brightness(event.code)
    held = event.value == 2
    return held and event.code in _SWALLOWED_AT_BRIGHTNESS.codes


def dispatch_modifier_watch_events(events):
    """Update Shift state from an un-grabbed typing keyboard."""
    for event in events:
        if event.type == ecodes.EV_KEY:
            update_at_modifier_state(event)


def dispatch_video_bus_events(events, forward_key):
    """Filter Video Bus brightness keys using the ScreenPad chord rules."""
    for event in events:
        if event.type != ecodes.EV_KEY or event.value != 1:
            continue
        handle_brightness_source_press(event.code, forward_key)


def _device_has_modifier_keys(dev):
    """Return True when *dev* reports Left Shift."""
    try:
        keys = set(dev.capabilities().get(ecodes.EV_KEY, []))
    except OSError:
        return False
    return ecodes.KEY_LEFTSHIFT in keys


def _is_modifier_watch_keyboard(name):
    """Return True for physical keyboards that may carry Shift (not AT/proxy)."""
    label = (name or "").lower()
    # ZenBook UX582HS typing keys arrive on i2c ASUE* Keyboard, not AT.
    return "keyboard" in label and _AT_KEYBOARD_NAME.lower() not in label and _PROXY_KEYBOARD_NAME.lower() not in label


def list_modifier_watch_keyboard_paths():
    """Return paths of non-AT keyboards that can supply Shift state."""
    return _iter_modifier_watch_devices(close_after=True)


def _try_open_modifier_watch(path, close_after):
    """Open one modifier-watch keyboard, returning a path or device (or None)."""
    try:
        dev = evdev.InputDevice(path)
    except (OSError, ValueError):
        return None
    name = getattr(dev, "name", "")
    usable = _is_modifier_watch_keyboard(name) and _device_has_modifier_keys(dev)
    if not usable:
        close_input_device(dev)
        return None
    if close_after:
        path_out = dev.path
        close_input_device(dev)
        return path_out
    return dev


def _iter_modifier_watch_devices(*, close_after):
    """Return opened modifier keyboards (or path strings when close_after)."""
    devices = []
    for path in list_evdev_device_paths():
        item = _try_open_modifier_watch(path, close_after)
        if item is not None:
            devices.append(item)
    return devices


def open_modifier_watch_devices():
    """Open modifier keyboards without grab (compositor keeps receiving keys)."""
    opened = []
    for dev in _iter_modifier_watch_devices(close_after=False):
        _logger.info("Watching modifiers on %s (%s)", dev.name, getattr(dev, "path", "?"))
        opened.append(dev)
    return opened


def open_video_bus_devices():
    """Open and exclusive-grab all Video Bus devices for brightness filtering."""
    opened = []
    for path in find_all_input_device_paths("Video Bus"):
        try:
            dev = evdev.InputDevice(path)
        except (OSError, ValueError) as exc:
            _logger.warning("Failed to open Video Bus %s: %s", path, exc)
            continue
        try:
            dev.grab()
        except OSError as exc:
            _logger.warning("Failed to grab Video Bus %s: %s", path, exc)
            close_input_device(dev)
            continue
        _logger.info("Grabbed exclusive access on %s (%s)", dev.name, path)
        opened.append(dev)
    return opened
