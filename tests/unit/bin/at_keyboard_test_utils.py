"""Shared helpers for AT keyboard, sticky OSD, and WMI/input unit tests."""

import contextlib
import importlib
import os
import tempfile
from unittest.mock import MagicMock, patch

from evdev import ecodes

from tests.unit.bin.hotkey_daemon_test_utils import load_daemon, reset_hotkey_daemon_state

daemon = load_daemon()
daemon_input = importlib.import_module("asus_hotkey_daemon_input")
daemon_at_proxy = importlib.import_module("asus_hotkey_daemon_at_proxy")
daemon_runtime = importlib.import_module("asus_hotkey_daemon_runtime")
daemon_brightness = importlib.import_module("asus_hotkey_daemon_brightness")

_AT_PROXY_CALLS = {
    "_reset_pending_meta": "reset_pending_meta",
    "_handle_at_key_event": "handle_at_key_event",
    "_start_pending_meta": "start_pending_meta",
    "_expire_pending_meta": "expire_pending_meta",
    "_forward_event": "forward_event",
    "_forward_key_now": "forward_key_now",
    "_handle_at_event": "handle_at_event",
    "_handle_meta_key_event": "handle_meta_key_event",
    "_handle_esc_key": "handle_esc_on_at",
    "_flush_pending_meta": "flush_pending_meta",
    "_complete_pending_meta_up": "complete_pending_meta_up",
    "pending_meta_buffered": "pending_meta_buffered",
}


def _call(name, *args, **kwargs):
    """Call an input or at_proxy helper by legacy test name."""
    proxy_name = _AT_PROXY_CALLS.get(name)
    if proxy_name is not None:
        return getattr(daemon_at_proxy, proxy_name)(*args, **kwargs)
    return getattr(daemon_input, name)(*args, **kwargs)


def _key(code, value, event_type=None):
    """Build a minimal key event mock."""
    event = MagicMock()
    event.type = ecodes.EV_KEY if event_type is None else event_type
    event.code = code
    event.value = value
    return event


def _screenpad_sysfs_path(path):
    """Return True when *path* is a ScreenPad brightness sysfs candidate."""
    return "asus_screenpad" in path or "asus::screenpad" in path


def _screenpad_isfile_side_effect(present):
    """Mock isfile for ScreenPad sysfs paths only; delegate other paths."""
    real_isfile = os.path.isfile

    def side_effect(path):
        if _screenpad_sysfs_path(path):
            return present
        return real_isfile(path)

    return side_effect


def _screenpad_access_side_effect(writable):
    """Mock access for ScreenPad sysfs paths only; delegate other paths."""
    real_access = os.access

    def side_effect(path, mode):
        if _screenpad_sysfs_path(path):
            return writable
        return real_access(path, mode)

    return side_effect


def _reset_at_keyboard_state(test_case):
    """Reset daemon state and pending Super chord for AT/OSD unit tests."""
    reset_hotkey_daemon_state(daemon)
    _call("_reset_pending_meta")
    test_case.addCleanup(_call, "_reset_pending_meta")


@contextlib.contextmanager
def _isolated_display_osd_env():
    """Use empty temp dirs for display OSD state env vars; restore afterward."""
    with tempfile.TemporaryDirectory() as tmp:
        empty_root = os.path.join(tmp, "empty")
        os.makedirs(empty_root, exist_ok=True)
        with patch.dict(os.environ, {"ASUS_DISPLAY_MODE_STATE_PREFIX": empty_root, "NOTIF_ID_ROOT": empty_root}, clear=False):
            yield empty_root


@contextlib.contextmanager
def _osd_prefix_cancel_run(*extra_patches):
    """Yield (prefix, cancel_run) under an isolated sticky-OSD state prefix."""
    with _isolated_display_osd_env() as empty_root:
        prefix = os.path.join(empty_root, "disp")
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.dict(os.environ, {"ASUS_DISPLAY_MODE_STATE_PREFIX": prefix}, clear=False))
            cancel_run = stack.enter_context(patch("asus_hotkey_daemon_osd._subprocess_run"))
            # Run Esc cancel workers inline so asserts are not racing a real Thread.
            stack.enter_context(
                patch(
                    "asus_hotkey_daemon_osd.threading.Thread",
                    side_effect=_immediate_osd_thread,
                )
            )
            for patcher in extra_patches:
                stack.enter_context(patcher)
            yield prefix, cancel_run


def _immediate_osd_thread(target=None, args=(), kwargs=None, **_options):
    """Thread stand-in that runs *target* synchronously on start()."""
    thread = MagicMock()

    def _start():
        if target is not None:
            target(*(args or ()), **(kwargs or {}))

    thread.start.side_effect = _start
    return thread
