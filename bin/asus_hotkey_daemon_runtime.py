#!/usr/bin/env python3
"""Runtime helpers for the ASUS hotkey daemon."""

import logging
import subprocess
import threading
import time

import asus_hotkey_daemon_desktop_family as _desktop_family
import asus_hotkey_daemon_session as _session
import asus_hotkey_daemon_state as hotkey_state
import asus_hotkey_daemon_topology_detect as _topology_detect
from asus_common import find_input_device_path, is_executable_file
from asus_hotkey_daemon_desktop_family import clear_mint_bare_gnome_cache, desktop_family_hint
from asus_hotkey_daemon_session import (
    prime_desktop_user_cache,
    reset_systemctl_env_cache,
    run_in_desktop_session,
)
from asus_hotkey_daemon_topology_detect import detect_swap_topology_map

_logger = logging.getLogger(__name__)

__all__ = [
    "clear_mint_bare_gnome_cache",
    "desktop_family_hint",
    "detect_swap_topology_map",
    "find_device_path",
    "log_script_dispatch_outcome",
    "prime_desktop_user_cache",
    "reset_systemctl_env_cache",
    "run_in_desktop_session",
    "run_script_if_exists",
]

_COMPAT_EXPORT_OWNERS = {
    "_cached_desktop_user_valid": _session,
    "_desktop_session_env": _session,
    "_detect_desktop_user": _session,
    "_fetch_systemctl_user_env_blob": _session,
    "_loginctl_show_session_value": _session,
    "_merge_leader_environ": _session,
    "_merge_systemctl_environ": _session,
    "_read_proc_environ_value": _session,
    "_session_leader_pid": _session,
    "_detect_display_profile": _topology_detect,
    "_detect_swap_topology": _topology_detect,
    "_detect_xrandr_topology_map": _topology_detect,
    "_normalize_detected_profile": _topology_detect,
    "_parse_topology_map_output": _topology_detect,
    "_parse_topology_output": _topology_detect,
    "_family_from_desktop_string": _desktop_family,
    "_probe_de_binary_family": _desktop_family,
    "_probe_de_schema_family": _desktop_family,
}


def __getattr__(name):
    """Resolve compatibility exports from their owning split modules."""
    owner = _COMPAT_EXPORT_OWNERS.get(name)
    if owner is None:
        raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
    return getattr(owner, name)


def find_device_path():
    """Locate the ASUS WMI hotkeys input device."""
    return find_input_device_path("Asus WMI hotkeys")


def _is_debounced(script_path):
    """Return True when repeated script execution should be suppressed."""
    now = time.monotonic()
    return not hotkey_state.claim_script_slot(
        script_path,
        now,
        hotkey_state.get_script_debounce_seconds(script_path),
    )


def _exec_script(script_path, script_args=None):
    """Run a helper script and log failures."""
    command = [script_path]
    if script_args:
        command.extend(script_args)
    try:
        result = subprocess.run(
            command,
            check=False,
            timeout=5,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if result.returncode:
            _logger.warning("Helper script exited with status %d: %s", result.returncode, script_path)
    except subprocess.TimeoutExpired:
        _logger.warning("Helper script timed out after 5 s: %s", script_path)
    except OSError as exc:
        _logger.warning("Helper script failed to execute %s: %s", script_path, exc)


def _start_script_worker_impl(script_path, script_args=None):
    """Launch helper execution on a daemon thread."""
    worker = threading.Thread(
        target=_exec_script,
        args=(script_path, script_args),
        daemon=True,
    )
    worker.start()
    return worker


_script_worker_factory = _start_script_worker_impl


def _start_script_worker(script_path, script_args=None):
    """Launch helper execution on a daemon thread via a patchable worker factory."""
    return _script_worker_factory(script_path, script_args)


def run_script_if_exists(script_path, script_args=None):
    """Start a helper script worker when the path is executable and not debounced.

    Returns \"started\", \"debounced\", or \"missing\".
    """
    if not is_executable_file(script_path):
        return "missing"
    if _is_debounced(script_path):
        return "debounced"
    _start_script_worker(script_path, script_args)
    return "started"


def log_script_dispatch_outcome(script_path, outcome):
    """Log started/debounced/missing outcomes for a helper dispatch."""
    if outcome == "started":
        _logger.info("Dispatched helper script successfully: %s", script_path)
        return
    if outcome == "debounced":
        _logger.debug("Skipped debounced helper script: %s", script_path)
        return
    _logger.warning("Failed to dispatch helper script: %s", script_path)
