#!/usr/bin/env python3
"""AT keyboard Super+P firmware-chord filtering for the hotkey daemon."""

import logging
import time
from types import SimpleNamespace

import asus_hotkey_daemon_state as hotkey_state
from asus_hotkey_daemon_brightness import (
    try_handle_at_brightness_event,
    update_at_modifier_state,
)
from asus_hotkey_daemon_osd import (
    display_osd_esc_cooldown_active,
    handle_esc_key,
    osd_session_active,
)
from asus_hotkey_daemon_runtime import log_script_dispatch_outcome, run_script_if_exists
from evdev import ecodes

_logger = logging.getLogger(__name__)

_FIRMWARE_SUPER_P_SECS = 0.05
_DISPLAY_SCRIPT = "asus-display-mode.sh"
_PENDING_META = SimpleNamespace(events=[], started_at=0.0, saw_p=False)


def _dispatch_display_script():
    """Dispatch asus-display-mode.sh unless post-Esc cooldown is active."""
    if display_osd_esc_cooldown_active():
        _logger.debug("Skipped display-mode dispatch during post-Esc cooldown")
        return
    script_path = f"{hotkey_state.SCRIPT_BINDIR}/{_DISPLAY_SCRIPT}"
    outcome = run_script_if_exists(script_path)
    log_script_dispatch_outcome(script_path, outcome)


def is_meta_key(code):
    """Return True when *code* is Left or Right Super."""
    return code in (ecodes.KEY_LEFTMETA, ecodes.KEY_RIGHTMETA)


def reset_pending_meta():
    """Clear the buffered Super chord state."""
    _PENDING_META.events = []
    _PENDING_META.started_at = 0.0
    _PENDING_META.saw_p = False


def pending_meta_buffered() -> bool:
    """Return True when a Super chord buffer has one or more events."""
    return bool(_PENDING_META.events)


def release_proxy_modifier_keys(kb_ui):
    """Drop buffered Super chords and release modifiers on the AT uinput proxy."""
    reset_pending_meta()
    if kb_ui is None:
        return
    for code in (
        ecodes.KEY_LEFTMETA,
        ecodes.KEY_RIGHTMETA,
        ecodes.KEY_LEFTSHIFT,
        ecodes.KEY_RIGHTSHIFT,
        ecodes.KEY_LEFTCTRL,
        ecodes.KEY_RIGHTCTRL,
        ecodes.KEY_LEFTALT,
        ecodes.KEY_RIGHTALT,
    ):
        try:
            kb_ui.write(ecodes.EV_KEY, code, 0)
        except OSError:
            _logger.debug("Failed to release proxy modifier code=%d", code)
    try:
        kb_ui.syn()
    except OSError:
        _logger.debug("Failed to sync keyboard proxy after modifier release")


def forward_event(kb_ui, event):
    """Write one input event to the keyboard proxy."""
    if kb_ui is None:
        return
    try:
        kb_ui.write(event.type, event.code, event.value)
    except OSError:
        _logger.debug(
            "Failed to forward AT event type=%d code=%d value=%d",
            event.type,
            event.code,
            event.value,
        )


def flush_pending_meta(kb_ui):
    """Forward any buffered Super-chord events and clear pending state."""
    events = list(_PENDING_META.events)
    reset_pending_meta()
    for event in events:
        forward_event(kb_ui, event)
    if kb_ui is not None and events:
        try:
            kb_ui.syn()
        except OSError:
            _logger.debug("Failed to sync keyboard proxy after flush")


def swallow_firmware_super_p():
    """Drop the buffered firmware Super+P chord and run the display script."""
    reset_pending_meta()
    _logger.info("Swallowed firmware Super+P; dispatching %s", _DISPLAY_SCRIPT)
    _dispatch_display_script()


def pending_age(now):
    """Return seconds since the buffered Super-down, or 0 when idle."""
    if not _PENDING_META.events:
        return 0.0
    return now - _PENDING_META.started_at


def expire_pending_meta(kb_ui, now):
    """Flush a pending Super buffer that exceeded the firmware chord window."""
    if _PENDING_META.events and pending_age(now) > _FIRMWARE_SUPER_P_SECS:
        flush_pending_meta(kb_ui)


def start_pending_meta(event, now):
    """Begin buffering a possible firmware Super+P chord."""
    _PENDING_META.events = [event]
    _PENDING_META.started_at = now
    _PENDING_META.saw_p = False


def complete_pending_meta_up(kb_ui, now):
    """Resolve Meta-up: swallow firmware chord or forward human chord."""
    if _PENDING_META.saw_p and pending_age(now) <= _FIRMWARE_SUPER_P_SECS:
        swallow_firmware_super_p()
        return
    flush_pending_meta(kb_ui)


def handle_meta_while_pending(event, kb_ui, now):
    """Handle a Meta key event while a Super chord is already pending."""
    _PENDING_META.events.append(event)
    if not event.value:
        complete_pending_meta_up(kb_ui, now)


def buffer_or_flush_non_meta(event, kb_ui, now):
    """Buffer P during a fast Super chord; otherwise flush as human input."""
    # Only a KEY_P press arms saw_p. Releases must stay buffered (not flush) so
    # firmware Super+P is still swallowed on Meta-up instead of hard-cycling.
    if event.code == ecodes.KEY_P and pending_age(now) <= _FIRMWARE_SUPER_P_SECS:
        _PENDING_META.events.append(event)
        if event.value == 1:
            _PENDING_META.saw_p = True
        return
    _PENDING_META.events.append(event)
    # Append first so flush forwards buffered Super-down before this key (do not drop it).
    flush_pending_meta(kb_ui)


def handle_pending_or_forward(event, kb_ui, now):
    """Buffer during pending Super chord, else forward the key."""
    if _PENDING_META.events:
        buffer_or_flush_non_meta(event, kb_ui, now)
        return
    forward_key_now(kb_ui, event)


def forward_key_now(kb_ui, event):
    """Forward one key event and sync the keyboard proxy."""
    forward_event(kb_ui, event)
    if kb_ui is not None:
        try:
            kb_ui.syn()
        except OSError:
            _logger.debug("Failed to sync keyboard proxy after forward")


def handle_esc_on_at(event, kb_ui):
    """Cancel sticky OSD via same-device Esc+Super-up; do not AT-forward Esc press."""
    handle_esc_key(event, kb_ui, release_proxy_modifier_keys, forward_key_now)


def handle_meta_key_event(event, kb_ui, now):
    """Handle Left/Right Super for firmware Super+P filtering."""
    if event.value == 1 and not _PENDING_META.events:
        start_pending_meta(event, now)
        return
    if _PENDING_META.events:
        handle_meta_while_pending(event, kb_ui, now)
        return
    forward_key_now(kb_ui, event)


def handle_at_key_event(event, kb_ui, now):
    """Filter AT EV_KEY events; swallow firmware Super+P and Shift+brightness."""
    expire_pending_meta(kb_ui, now)
    update_at_modifier_state(event)
    if is_meta_key(event.code):
        handle_meta_key_event(event, kb_ui, now)
        return
    if event.code == ecodes.KEY_ESC:
        # Sticky OSD Esc: drop any buffered Super+P (do not flush/forward — that
        # races ydotool Esc dismiss and re-opens Mutter's monitor dialog).
        if osd_session_active():
            reset_pending_meta()
        else:
            flush_pending_meta(kb_ui)
        handle_esc_on_at(event, kb_ui)
        return
    if try_handle_at_brightness_event(event):
        return
    handle_pending_or_forward(event, kb_ui, now)


def handle_at_event(event, kb_ui):
    """Proxy one AT keyboard event, filtering firmware Super+P."""
    if event.type == ecodes.EV_KEY:
        handle_at_key_event(event, kb_ui, time.monotonic())
        return
    expire_pending_meta(kb_ui, time.monotonic())
    if _PENDING_META.events:
        _PENDING_META.events.append(event)
        return
    forward_event(kb_ui, event)
