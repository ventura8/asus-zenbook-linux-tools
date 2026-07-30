#!/usr/bin/env python3
"""Input-device handling for the ASUS hotkey daemon."""

import logging
import select
import sys
import time
from dataclasses import dataclass
from types import SimpleNamespace
from typing import Any

import asus_hotkey_daemon_at_proxy as _at_proxy
import asus_hotkey_daemon_state as hotkey_state
import evdev
from asus_common import close_input_device, find_input_device_path
from asus_hotkey_daemon_brightness import (
    clear_at_modifier_state,
    clear_brightness_dedup_state,
    dispatch_modifier_watch_events,
    dispatch_video_bus_events,
    handle_brightness_source_press,
    open_modifier_watch_devices,
    open_video_bus_devices,
)
from asus_hotkey_daemon_monitor import (
    perform_window_swap,
    prime_gnome_window_swap_extension,
    prime_topology_cache,
)
from asus_hotkey_daemon_osd import (
    arm_display_osd_esc_cooldown,
    display_osd_esc_cooldown_active,
    osd_session_active,
    run_cancel_display_osd,
)
from asus_hotkey_daemon_osd import (
    reset_display_osd_esc_cooldown as _osd_reset_display_esc_cooldown,
)
from asus_hotkey_daemon_runtime import (
    log_script_dispatch_outcome,
    prime_desktop_user_cache,
    run_script_if_exists,
)
from evdev import UInput, ecodes

_logger = logging.getLogger(__name__)

_DISPLAY_SCRIPT = "asus-display-mode.sh"


def clear_brightness_chord_state():
    """Reset Shift tracking and brightness dedupe (unit tests)."""
    clear_at_modifier_state()
    clear_brightness_dedup_state()


def handle_key_press(last_scancode, event_code, ui, swap_step):
    """Handle hardware key press actions based on scancodes and event codes."""
    action, script = _resolve_scancode_action(last_scancode, event_code)
    if action == "swap":
        return perform_window_swap(ui, swap_step)
    if action == "script":
        _dispatch_resolved_script(script)
    return swap_step


def _resolve_scancode_action(last_scancode, event_code):
    """Return ('swap', None), ('script', name), or (None, None) for a press."""
    if last_scancode == 0x9C:
        return "swap", None
    script = hotkey_state.resolve_script_name(last_scancode, event_code)
    if script:
        return "script", script
    return None, None


def _dispatch_resolved_script(script, script_args=None):
    """Dispatch a resolved helper script and log success, debounce, or failure."""
    if script == _DISPLAY_SCRIPT and display_osd_esc_cooldown_active():
        _logger.debug("Skipped display-mode dispatch during post-Esc cooldown")
        return
    script_path = f"{hotkey_state.SCRIPT_BINDIR}/{script}"
    outcome = run_script_if_exists(script_path, script_args)
    log_script_dispatch_outcome(script_path, outcome)


def _open_device():
    """Locate and open the WMI hotkeys input device and secondary keyboard."""
    device_path = find_input_device_path("Asus WMI hotkeys")
    if not device_path:
        sys.exit("Asus WMI hotkeys device not found!")
    try:
        wmi_dev = evdev.InputDevice(device_path)
    except (OSError, ValueError) as exc:
        sys.exit(f"Failed to open hotkeys device {device_path}: {exc}")
    kb_path = find_input_device_path("AT Translated Set 2 keyboard")
    kb_dev = None
    if kb_path:
        try:
            kb_dev = evdev.InputDevice(kb_path)
        except (OSError, ValueError) as exc:
            _logger.warning("Failed to open AT keyboard %s: %s", kb_path, exc)
    return wmi_dev, kb_dev


def _log_and_dispatch_hotkey(last_scancode, event_code, script):
    """Log a captured WMI hotkey and dispatch its helper script."""
    hex_scancode = f"0x{last_scancode:X}" if last_scancode else "None"
    _logger.info(
        "Captured hotkey EV_KEY press: code=%d, last_scancode=%s -> %s",
        event_code,
        hex_scancode,
        script,
    )
    _dispatch_resolved_script(script)


def _forward_wmi_key(ui, event_code, value, wmi_grabbed=True):
    """Replay an unmapped WMI key through the virtual keyboard when grabbed."""
    if ui is None or not wmi_grabbed:
        return
    try:
        ui.write(ecodes.EV_KEY, event_code, value)
        ui.syn()
    except OSError:
        _logger.debug("Failed to forward WMI key code=%d value=%d", event_code, value)


def _brightness_forwarder(ui, allow):
    """Return a forward_key(code, value) callback for brightness filtering."""

    def _forward(event_code, value):
        _forward_wmi_key(ui, event_code, value, wmi_grabbed=allow)

    return _forward


def _handle_wmi_key_press(last_scancode, event_code, ui, swap_step, wmi_grabbed=True):
    """Handle one WMI EV_KEY press; return (last_scancode, swap_step)."""
    action, script = _resolve_scancode_action(last_scancode, event_code)
    if action == "swap":
        return None, perform_window_swap(ui, swap_step)
    if action == "script":
        _log_and_dispatch_hotkey(last_scancode, event_code, script)
        return None, swap_step
    forward = _brightness_forwarder(ui, wmi_grabbed)
    if handle_brightness_source_press(event_code, forward):
        return None, swap_step
    # Unmapped WMI keys (e.g. touchpad/touchscreen toggle) must reach the desktop.
    _forward_wmi_key(ui, event_code, 1, wmi_grabbed=wmi_grabbed)
    _forward_wmi_key(ui, event_code, 0, wmi_grabbed=wmi_grabbed)
    return None, swap_step


def _process_hotkey_event(event, last_scancode, ui, swap_step, wmi_grabbed=True):
    """Handle one event from the WMI hotkeys device; return updated state."""
    if event.type == ecodes.EV_MSC and event.code == ecodes.MSC_SCAN:
        return event.value, swap_step
    if event.type == ecodes.EV_KEY and event.value == 1:
        return _handle_wmi_key_press(last_scancode, event.code, ui, swap_step, wmi_grabbed=wmi_grabbed)
    return last_scancode, swap_step


def _synthetic_hotkey_codes():
    """Return EV_KEY codes required for synthetic window-swap / display chords."""
    return [
        ecodes.KEY_LEFTMETA,
        ecodes.KEY_LEFTSHIFT,
        ecodes.KEY_DOWN,
        ecodes.KEY_UP,
        ecodes.KEY_RIGHT,
        ecodes.KEY_LEFT,
        ecodes.KEY_TOUCHPAD_TOGGLE,
        ecodes.KEY_TOUCHPAD_ON,
        ecodes.KEY_TOUCHPAD_OFF,
        ecodes.KEY_F8,
    ]


def _build_input_capabilities(wmi_dev):
    """Return uinput EV_KEY caps: synthetic chords plus WMI-forwarded codes."""
    key_codes = list(_synthetic_hotkey_codes())
    try:
        wmi_keys = wmi_dev.capabilities().get(ecodes.EV_KEY, [])
    except OSError:
        wmi_keys = []
    for code in wmi_keys:
        if code not in key_codes:
            key_codes.append(code)
    return {ecodes.EV_KEY: key_codes}


def _build_keyboard_capabilities(kb_dev):
    """Return uinput capabilities cloned from the physical AT keyboard."""
    caps = kb_dev.capabilities()
    return {ev: codes for ev, codes in caps.items() if ev != ecodes.EV_SYN}


def _ungrab_and_close_input_device(dev):
    """Ungrab then close one input device; tolerate None and OSError."""
    if dev is None:
        return
    try:
        dev.ungrab()
    except OSError:
        pass
    close_input_device(dev)


def _close_runtime_devices(ui, wmi_dev, kb_dev=None, kb_ui=None, extra_devs=None):
    """Close virtual and physical input devices safely."""
    _ungrab_and_close_input_device(wmi_dev)
    _ungrab_and_close_input_device(kb_dev)
    for dev in extra_devs or ():
        _ungrab_and_close_input_device(dev)
    close_input_device(kb_ui)
    close_input_device(ui)


def _grab_device(dev, label):
    """Exclusive-grab one input device; log success or failure."""
    try:
        dev.grab()
        _logger.info("Grabbed exclusive access on %s (%s)", label, dev.path)
        return True
    except OSError as exc:
        _logger.warning("Failed to grab exclusive access on %s: %s", label, exc)
        return False


# Unit-test aliases for helpers moved into asus_hotkey_daemon_osd.
_run_cancel_display_osd = run_cancel_display_osd
_osd_session_active = osd_session_active
_arm_display_osd_esc_cooldown = arm_display_osd_esc_cooldown
_display_osd_esc_cooldown_active = display_osd_esc_cooldown_active


def reset_display_osd_esc_cooldown():
    """Clear post-Esc cooldown (re-export for unit tests / state reset)."""
    _osd_reset_display_esc_cooldown()


def _open_keyboard_proxy(kb_dev):
    """Grab AT keyboard and create a uinput proxy; return proxy or None."""
    if kb_dev is None:
        return None
    if not _grab_device(kb_dev, kb_dev.name):
        return None
    try:
        return UInput(_build_keyboard_capabilities(kb_dev), name="asus-at-keyboard-proxy")
    except (evdev.uinput.UInputError, OSError) as exc:
        _logger.warning("Failed to create AT keyboard proxy: %s", exc)
        try:
            kb_dev.ungrab()
        except OSError:
            pass
        return None


def _device_map(wmi_dev, kb_dev, extra_devs=None):
    """Return (dev_map, wmi_fd, kb_fd) for the event loop."""
    watched = [wmi_dev]
    if kb_dev is not None:
        watched.append(kb_dev)
    if extra_devs:
        watched.extend(extra_devs)
    kb_fd = None if kb_dev is None else kb_dev.fd
    return {d.fd: d for d in watched}, wmi_dev.fd, kb_fd


def _dispatch_wmi_events(events, loop_state):
    """Apply WMI hotkey events to loop state."""
    for event in events:
        loop_state.last_scancode, loop_state.swap_step = _process_hotkey_event(
            event,
            loop_state.last_scancode,
            loop_state.ui,
            loop_state.swap_step,
            wmi_grabbed=loop_state.wmi_grabbed,
        )


def _dispatch_kb_events(events, loop_state):
    """Proxy AT keyboard events through the virtual keyboard."""
    for event in events:
        _at_proxy.handle_at_event(event, loop_state.kb_ui)


def _dispatch_mod_watch_events(events, _loop_state):
    """Update Shift from an un-grabbed typing keyboard (ASUE i2c)."""
    dispatch_modifier_watch_events(events)


def _dispatch_video_events(events, loop_state):
    """Filter Video Bus brightness; always allow uinput forward when grabbed."""
    forward = _brightness_forwarder(loop_state.ui, True)
    dispatch_video_bus_events(events, forward)


def _mark_fd_gone(fd, loop_state):
    """Drop a failed fd; clear keyboard chord/modifier state; flag WMI loss."""
    is_kb = fd == loop_state.kb_fd
    is_mod = fd in loop_state.mod_fds
    dev = loop_state.dev_map.pop(fd, None)
    _ungrab_and_close_input_device(dev)
    if is_kb:
        loop_state.kb_fd = None
        close_input_device(loop_state.kb_ui)
        loop_state.kb_ui = None
        _at_proxy.reset_pending_meta()
    loop_state.mod_fds.discard(fd)
    loop_state.video_fds.discard(fd)
    if is_kb or is_mod:
        # Drop held Shift/Super and brightness chord state so later presses use
        # the normal main-panel path after ASUE/AT keyboards disappear.
        clear_brightness_chord_state()
    if fd == loop_state.wmi_fd:
        loop_state.wmi_fd = None
        loop_state.wmi_gone = True


def _read_ready_fd_events(fd, loop_state):
    """Return pending events for *fd*, or None when the device is gone."""
    dev = loop_state.dev_map.get(fd)
    if dev is None:
        return None
    try:
        return list(dev.read())
    except BlockingIOError:
        # Spurious readiness / EAGAIN — do not treat as device loss.
        return []
    except OSError:
        _mark_fd_gone(fd, loop_state)
        return None


def _handler_for_fd(fd, loop_state):
    """Return the event dispatcher for *fd*, or None when unknown."""
    if fd == loop_state.wmi_fd:
        return _dispatch_wmi_events
    if fd == loop_state.kb_fd:
        return _dispatch_kb_events
    if fd in getattr(loop_state, "mod_fds", ()):
        return _dispatch_mod_watch_events
    if fd in getattr(loop_state, "video_fds", ()):
        return _dispatch_video_events
    return None


def _dispatch_ready_fd(fd, loop_state):
    """Dispatch all pending events from one ready file descriptor."""
    events = _read_ready_fd_events(fd, loop_state)
    if events is None:
        return
    handler = _handler_for_fd(fd, loop_state)
    if handler is not None:
        handler(events, loop_state)


def _event_loop_tick(loop_state):
    """Wait for one select cycle and dispatch ready fds."""
    ready, _, _ = select.select(loop_state.dev_map.keys(), [], [], 0.05)
    if loop_state.kb_ui is not None:
        _at_proxy.expire_pending_meta(loop_state.kb_ui, time.monotonic())
    for fd in ready:
        _dispatch_ready_fd(fd, loop_state)


@dataclass(frozen=True)
class EventLoopOptions:
    """Explicit options for the WMI/AT select event loop."""

    wmi_grabbed: bool = False
    mod_devs: tuple[Any, ...] = ()
    video_devs: tuple[Any, ...] = ()


def _new_event_loop_state(wmi_dev, kb_dev, ui, kb_ui, *, options=None):
    """Build mutable state for the WMI/AT/select loop."""
    opts = options if options is not None else EventLoopOptions()
    mod_list = list(opts.mod_devs)
    video_list = list(opts.video_devs)
    extra = mod_list + video_list
    dev_map, wmi_fd, kb_fd = _device_map(wmi_dev, kb_dev, extra_devs=extra)
    return SimpleNamespace(
        ui=ui,
        kb_ui=kb_ui,
        swap_step=0,
        last_scancode=None,
        dev_map=dev_map,
        wmi_fd=wmi_fd,
        kb_fd=kb_fd,
        mod_fds={d.fd for d in mod_list},
        video_fds={d.fd for d in video_list},
        wmi_gone=False,
        wmi_grabbed=bool(opts.wmi_grabbed),
    )


def _run_event_loop(wmi_dev, kb_dev, ui, kb_ui, *, options=None):
    """Process WMI hotkeys; proxy AT keyboard while filtering firmware Super+P."""
    _at_proxy.reset_pending_meta()
    loop_state = _new_event_loop_state(wmi_dev, kb_dev, ui, kb_ui, options=options)
    while True:
        _event_loop_tick(loop_state)
        if loop_state.wmi_gone:
            raise SystemExit("WMI hotkey device lost; exiting for systemd restart")


def main():
    """Main event loop for processing hardware hotkeys."""
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    # Warm session env before topology so Mutter D-Bus detect can succeed at startup.
    prime_desktop_user_cache()
    prime_gnome_window_swap_extension()
    prime_topology_cache()
    wmi_dev = kb_dev = kb_ui = ui = None
    extra_devs = ()
    wmi_grabbed = False
    mod_devs = ()
    video_devs = ()
    try:
        wmi_dev, kb_dev = _open_device()
        mod_devs = open_modifier_watch_devices()
        video_devs = open_video_bus_devices()
        extra_devs = list(mod_devs) + list(video_devs)
        wmi_grabbed = _grab_device(wmi_dev, wmi_dev.name)
        kb_ui = _open_keyboard_proxy(kb_dev)
        ui = UInput(_build_input_capabilities(wmi_dev))
    except (evdev.uinput.UInputError, OSError) as exc:
        extra_devs = list(mod_devs) + list(video_devs)
        _close_runtime_devices(ui, wmi_dev, kb_dev, kb_ui, extra_devs=extra_devs)
        raise SystemExit(
            f"Failed to initialize virtual input device: {exc}. Ensure uinput support is enabled and /dev/uinput is accessible."
        ) from exc
    except Exception:
        extra_devs = list(mod_devs) + list(video_devs)
        _close_runtime_devices(ui, wmi_dev, kb_dev, kb_ui, extra_devs=extra_devs)
        raise
    try:
        _run_event_loop(
            wmi_dev,
            kb_dev,
            ui,
            kb_ui,
            options=EventLoopOptions(
                wmi_grabbed=wmi_grabbed,
                mod_devs=tuple(mod_devs),
                video_devs=tuple(video_devs),
            ),
        )
    finally:
        _close_runtime_devices(ui, wmi_dev, kb_dev, kb_ui, extra_devs=extra_devs)
