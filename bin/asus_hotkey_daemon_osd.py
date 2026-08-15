#!/usr/bin/env python3
"""Sticky display-mode OSD Esc cancel helpers for the hotkey daemon."""

import logging
import math
import os
import subprocess
import threading
import time
from types import SimpleNamespace

import asus_hotkey_daemon_state as hotkey_state

_logger = logging.getLogger(__name__)

_DISPLAY_SCRIPT = "asus-display-mode.sh"
# Patchable alias — never patch ``asus_hotkey_daemon_osd.subprocess.run`` (that
# rebinds stdlib ``subprocess.run`` for every importer of the same module object).
_subprocess_run = subprocess.run
# cancel_in_flight is written by the event thread and _cancel_display_osd_worker.
_ESC_OSD = SimpleNamespace(swallowed_press=False, cancel_in_flight=False)
_OSD_ESC_COOLDOWN = SimpleNamespace(until=0.0)


def _bounded_float_env(name, default, min_value, max_value):
    """Return a finite float from *name*, clamped to [*min_value*, *max_value*]."""
    raw = os.environ.get(name, str(default))
    try:
        value = float(raw)
    except ValueError:
        return default
    if not math.isfinite(value):
        return default
    if value < min_value:
        return min_value
    return min(value, max_value)


def display_osd_esc_cooldown_secs():
    """Return bounded post-Esc cooldown before display-mode may run again."""
    return _bounded_float_env("ASUS_DISPLAY_OSD_ESC_COOLDOWN_SECS", 0.45, 0.1, 2.0)


def display_osd_esc_cooldown_active():
    """Return True while display-mode dispatch is suppressed after Esc cancel."""
    return time.monotonic() < _OSD_ESC_COOLDOWN.until


def arm_display_osd_esc_cooldown():
    """Suppress display-mode opens briefly after Esc dismisses sticky OSD."""
    _OSD_ESC_COOLDOWN.until = time.monotonic() + display_osd_esc_cooldown_secs()


def reset_display_osd_esc_cooldown():
    """Clear post-Esc display-mode dispatch suppression (unit tests)."""
    _OSD_ESC_COOLDOWN.until = 0.0
    _ESC_OSD.cancel_in_flight = False
    _ESC_OSD.swallowed_press = False


def _osd_marker_active(prefix):
    """Return True when sticky OSD .session or .ctx exists for *prefix*."""
    return os.path.isfile(f"{prefix}.session") or os.path.isfile(f"{prefix}.ctx")


def osd_session_active():
    """Return True when a sticky display-mode Super session marker exists."""
    prefix = os.environ.get("ASUS_DISPLAY_MODE_STATE_PREFIX")
    if prefix:
        return _osd_marker_active(prefix)
    root = os.environ.get("NOTIF_ID_ROOT", "/run/asus-zenbook-notif")
    uid = None
    cached = hotkey_state.get_desktop_user_cache()
    if cached is not None:
        uid = cached[0]
    if uid is None:
        uid = os.getuid()
    base = os.path.join(root, str(uid), "asus-display-mode", "state")
    return _osd_marker_active(base)


def _display_mode_cancel_osd_timeout_secs():
    """Return bounded timeout for synchronous display-mode --cancel-osd."""
    return _bounded_float_env("ASUS_DISPLAY_MODE_CANCEL_OSD_TIMEOUT_SECS", 0.5, 0.1, 1.0)


def run_cancel_display_osd():
    """Synchronously invoke display-mode --cancel-osd (Esc+Super-up on OSD backend)."""
    script = f"{hotkey_state.SCRIPT_BINDIR}/{_DISPLAY_SCRIPT}"
    try:
        completed = _subprocess_run(
            [script, "--cancel-osd"],
            check=False,
            timeout=_display_mode_cancel_osd_timeout_secs(),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        _logger.warning("Failed to cancel display OSD: %s", exc)
        return
    if completed.returncode:
        detail = (completed.stderr or "").strip()
        _logger.warning(
            "display-mode --cancel-osd exited %s%s",
            completed.returncode,
            f": {detail}" if detail else "",
        )


def _cancel_display_osd_worker():
    """Run cancel-osd then clear the in-flight Esc cancel guard."""
    try:
        run_cancel_display_osd()
    finally:
        _ESC_OSD.cancel_in_flight = False


def dismiss_sticky_osd_on_esc(kb_ui, release_modifiers):
    """Start async OSD cancel and clear AT-proxy modifiers on the event thread."""
    _logger.info("Esc during sticky display OSD; dismissing via display-mode")
    if not _ESC_OSD.cancel_in_flight:
        _ESC_OSD.cancel_in_flight = True
        try:
            threading.Thread(target=_cancel_display_osd_worker, daemon=True).start()
        except RuntimeError:
            _ESC_OSD.cancel_in_flight = False
    release_modifiers(kb_ui)
    arm_display_osd_esc_cooldown()
    _ESC_OSD.swallowed_press = True


def swallow_esc_followup(event):
    """Swallow Esc release/repeat after a cancelled OSD press; True when handled."""
    if not _ESC_OSD.swallowed_press or event.value not in (0, 2):
        return False
    if not event.value:
        _ESC_OSD.swallowed_press = False
    return True


def handle_esc_key(event, kb_ui, release_modifiers, forward_key):
    """Cancel sticky OSD via same-device Esc+Super-up; do not AT-forward Esc press."""
    if event.value == 1 and osd_session_active():
        dismiss_sticky_osd_on_esc(kb_ui, release_modifiers)
        return
    if swallow_esc_followup(event):
        return
    if event.value == 1:
        _ESC_OSD.swallowed_press = False
    forward_key(kb_ui, event)
