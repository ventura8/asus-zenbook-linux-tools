#!/usr/bin/env python3
"""Desktop session resolution helpers for the ASUS hotkey daemon."""

import os
import shutil
import subprocess
import threading
import time

import asus_hotkey_daemon_state as hotkey_state

_SYSTEMCTL_ENV_STATE = {
    "skip_until": None,
    "user": None,
    "blob": None,
    "blob_valid": False,
    "blob_expires": None,
}  # systemctl env negative-cache
_SYSTEMCTL_ENV_LOCK = threading.Lock()
_PROC_ENVIRON_MAX_BYTES = 1024 * 1024


def reset_systemctl_env_cache():
    """Reset systemctl --user show-environment cache to defaults (tests)."""
    with _SYSTEMCTL_ENV_LOCK:
        _SYSTEMCTL_ENV_STATE["skip_until"] = None
        _SYSTEMCTL_ENV_STATE["user"] = None
        _SYSTEMCTL_ENV_STATE["blob"] = None
        _SYSTEMCTL_ENV_STATE["blob_valid"] = False
        _SYSTEMCTL_ENV_STATE["blob_expires"] = None


def _resolve_session_bus_root() -> str:
    """Resolve session D-Bus socket root (BUS_ROOT → DBUS_BUS_ROOT → RUN_USER_ROOT → /run/user)."""
    for key in ("BUS_ROOT", "DBUS_BUS_ROOT", "RUN_USER_ROOT"):
        value = os.environ.get(key, "").strip()
        if value:
            return value
    return "/run/user"


def _parse_loginctl_property_lines(stdout):
    """Parse key=value lines from loginctl show-session stdout."""
    values = {}
    for line in stdout.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def _run_loginctl_show_session(session_id, property_names):
    """Run loginctl show-session for *property_names*, or None on failure."""
    command = ["loginctl", "show-session", session_id]
    for name in property_names:
        command.extend(["-p", name])
    try:
        return subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=False,
            timeout=1,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None


def _loginctl_show_session_properties(session_id, property_names):
    """Return stripped loginctl show-session values for property_names, or None on failure."""
    if not session_id or not property_names:
        return None
    result = _run_loginctl_show_session(session_id, property_names)
    if result is None or result.returncode:
        return None
    return _parse_loginctl_property_lines(result.stdout)


def _loginctl_show_session_value(session_id, property_name):
    """Return a stripped loginctl show-session property value, or None on failure."""
    values = _loginctl_show_session_properties(session_id, [property_name])
    if values is None:
        return None
    return values.get(property_name)


def _is_active_gui_session(session_id):
    """Return whether session_id is an active X11/Wayland GUI session."""
    values = _loginctl_show_session_properties(session_id, ["Type", "State"])
    if values is None:
        return False
    session_type = values.get("Type")
    session_state = values.get("State")
    return session_state == "active" and session_type in {"x11", "wayland"}


def _is_desktop_uid(uid):
    """Return whether uid belongs to a non-system desktop user."""
    return uid >= 1000


def _parse_uid_username(username, uid_text):
    """Return (uid, username) when the values describe a desktop user."""
    if not username or username == "root":
        return None
    if not str(uid_text).isdigit():
        return None
    uid = int(uid_text)
    if not _is_desktop_uid(uid):
        return None
    return uid, username


def _user_from_gui_session(session_id):
    """Return (uid, username) for a GUI session, or None when unsuitable."""
    values = _loginctl_show_session_properties(session_id, ["Name", "User"])
    if values is None:
        return None
    return _parse_uid_username(values.get("Name"), values.get("User"))


def _list_loginctl_session_ids():
    """Return session ids from loginctl list-sessions, or an empty list."""
    try:
        result = subprocess.run(
            ["loginctl", "list-sessions", "--no-legend"],
            capture_output=True,
            text=True,
            check=False,
            timeout=1,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if result.returncode:
        return []
    session_ids = []
    for line in result.stdout.splitlines():
        parts = line.split()
        if parts:
            session_ids.append(parts[0])
    return session_ids


def _desktop_user_from_session(session_id):
    """Return desktop user for an active GUI session, otherwise None."""
    if not _is_active_gui_session(session_id):
        return None
    return _user_from_gui_session(session_id)


def _detect_desktop_user(resolve_deadline=None):
    """Return the active GUI desktop user tuple or (None, None, None).

    When *resolve_deadline* is set (monotonic clock), stop probing sessions once
    that deadline has passed so loginctl work stays within the caller's budget.
    """
    for session_id in _list_loginctl_session_ids():
        if resolve_deadline is not None and time.monotonic() >= resolve_deadline:
            break
        parsed = _desktop_user_from_session(session_id)
        if parsed is not None:
            uid, username = parsed
            return uid, username, session_id
    return None, None, None


def _session_env_has_display(env):
    """Return True when env includes DISPLAY or WAYLAND_DISPLAY."""
    return bool(env) and bool(env.get("DISPLAY") or env.get("WAYLAND_DISPLAY"))


def _unpack_desktop_user_cache(cached):
    """Normalize cache tuples to (uid, username, session_id, expires_at, validated_until)."""
    uid, username, session_id, expires_at = cached[:4]
    validated_until = cached[4] if len(cached) > 4 else 0.0
    return uid, username, session_id, expires_at, validated_until


def _cached_desktop_user_valid(cached):
    """Return (uid, username) when a cache entry is unexpired and still active."""
    uid, username, session_id, expires_at, validated_until = _unpack_desktop_user_cache(cached)
    now = time.monotonic()
    if now >= expires_at:
        return None
    if not _session_env_has_display(hotkey_state.get_desktop_user_session_env()):
        return None
    if now < validated_until:
        return uid, username
    if not _is_active_gui_session(session_id):
        return None
    hotkey_state.touch_desktop_user_validated_until(now + hotkey_state.get_desktop_user_cache_seconds())
    return uid, username


def _resolve_desktop_user(deadline=None):
    """Return (uid, username), reusing a short-lived cache when still valid."""
    cached = hotkey_state.get_desktop_user_cache()
    if cached is not None:
        valid = _cached_desktop_user_valid(cached)
        if valid is not None:
            return valid
    uid, username, session_id = _detect_desktop_user(resolve_deadline=deadline)
    if uid is None or username is None:
        hotkey_state.clear_desktop_user_cache()
        return None, None
    expires_at = time.monotonic() + hotkey_state.get_desktop_user_cache_seconds()
    session_env = _desktop_session_env(uid, session_id, username, deadline=deadline)
    hotkey_state.set_desktop_user_cache(
        uid,
        username,
        session_id,
        expires_at,
        {"session_env": session_env, "validated_until": expires_at},
    )
    return uid, username


def prime_desktop_user_cache():
    """Warm desktop-user + session-env cache before the first window-swap press."""
    if os.geteuid():
        return
    _resolve_desktop_user()


def _run_command(command, timeout):
    """Run a command with the standard subprocess arguments used by desktop-session helpers."""
    return subprocess.run(
        command,
        capture_output=True,
        text=True,
        check=False,
        timeout=timeout,
        stdin=subprocess.DEVNULL,
    )


def _trim_proc_environ_raw(raw):
    """Trim a truncated environ blob to the last complete NUL-terminated entry."""
    if len(raw) < _PROC_ENVIRON_MAX_BYTES:
        return raw
    last_nul = raw.rfind(b"\0")
    if last_nul < 0:
        return raw
    return raw[:last_nul]


def _environ_value_for_key(raw, key):
    """Return the decoded value for *key* from a NUL-separated environ blob."""
    prefix = f"{key}=".encode()
    for entry in raw.split(b"\0"):
        if entry.startswith(prefix):
            return entry[len(prefix) :].decode("utf-8", errors="replace")
    return None


def _read_proc_environ_value(pid, key):
    """Return one KEY=value from $ASUS_PROC_ENVIRON_ROOT/<pid>/environ (default /proc)."""
    root = os.environ.get("ASUS_PROC_ENVIRON_ROOT", "/proc")
    environ_path = f"{root}/{pid}/environ"
    try:
        with open(environ_path, "rb") as handle:
            raw = handle.read(_PROC_ENVIRON_MAX_BYTES)
    except OSError:
        return None
    return _environ_value_for_key(_trim_proc_environ_raw(raw), key)


def _session_leader_pid(session_id):
    """Return the loginctl Leader PID for session_id, or None."""
    leader = _loginctl_show_session_value(session_id, "Leader")
    if leader is None or not str(leader).isdigit():
        return None
    return int(leader)


def _session_display_keys():
    """Keys copied from leader environ / systemctl --user show-environment."""
    return ("DISPLAY", "WAYLAND_DISPLAY", "XDG_CURRENT_DESKTOP", "XDG_SESSION_TYPE")


def _merge_leader_environ(env, leader):
    """Copy DISPLAY/WAYLAND/XDG_* values from a session leader environ into env."""
    if leader is None:
        return env
    for key in _session_display_keys():
        value = _read_proc_environ_value(leader, key)
        if value:
            env[key] = value
    return env


def _parse_env_blob_value(blob, key):
    """Return value for KEY= from a show-environment blob, or None."""
    prefix = f"{key}="
    for line in str(blob).splitlines():
        if line.startswith(prefix):
            return line[len(prefix) :]
    return None


def _timeout_until(deadline, minimum=0.05):
    """Return seconds remaining until *deadline*, floored to *minimum*."""
    return max(float(minimum), float(deadline) - time.monotonic())


def _systemctl_env_timeout_secs(deadline=None):
    """Return capped timeout for systemctl --user show-environment."""
    raw = os.environ.get("ASUS_SYSTEMCTL_ENV_TIMEOUT_SECS", "1")
    try:
        base = min(5.0, max(0.1, float(raw)))
    except (TypeError, ValueError):
        base = 1.0
    if deadline is None:
        return base
    return min(base, _timeout_until(deadline))


def _desktop_session_resolve_budget_secs(timeout):
    """Bounded seconds for desktop-user/session resolution (not the command)."""
    return min(5.0, max(0.1, float(timeout)))


def _systemctl_env_skip_seconds():
    """Return how long failed systemctl env lookups stay skipped."""
    return hotkey_state.get_desktop_user_cache_seconds()


def _mark_systemctl_env_skip():
    """Negative-cache systemctl env lookups until a short retry deadline."""
    with _SYSTEMCTL_ENV_LOCK:
        state = _SYSTEMCTL_ENV_STATE
        state["skip_until"] = time.monotonic() + _systemctl_env_skip_seconds()
        state["blob"] = None
        state["blob_valid"] = False
        state["blob_expires"] = None


def _systemctl_env_skip_blocks_fetch(state):
    """Return True when skip window is active (clears expired skip)."""
    skip_until = state.get("skip_until")
    if skip_until is None:
        return False
    if time.monotonic() < skip_until:
        return True
    state["skip_until"] = None
    return False


def _systemctl_env_blob_from_cache(state, username):
    """Return (need_fetch, blob) from cached state for *username*."""
    if state.get("user") != username or not state.get("blob_valid"):
        return True, None
    blob_expires = state.get("blob_expires")
    if blob_expires is not None and time.monotonic() >= blob_expires:
        state["blob"] = None
        state["blob_valid"] = False
        state["blob_expires"] = None
        return True, None
    return False, state.get("blob")


def _cached_systemctl_env_blob(username):
    """Return (need_fetch, blob) for systemctl show-environment cache."""
    with _SYSTEMCTL_ENV_LOCK:
        state = _SYSTEMCTL_ENV_STATE
        if _systemctl_env_skip_blocks_fetch(state):
            return False, None
        return _systemctl_env_blob_from_cache(state, username)


def _invoke_systemctl_show_environment(username, uid, deadline=None):
    """Run systemctl --user show-environment via runuser and cache stdout."""
    bus_root = _resolve_session_bus_root()
    command = [
        "runuser",
        "-u",
        username,
        "--",
        "env",
        f"XDG_RUNTIME_DIR={bus_root}/{uid}",
        "systemctl",
        "--user",
        "show-environment",
    ]
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=False,
            timeout=_systemctl_env_timeout_secs(deadline),
        )
    except (OSError, subprocess.TimeoutExpired):
        _mark_systemctl_env_skip()
        return None
    if result.returncode:
        _mark_systemctl_env_skip()
        return None
    with _SYSTEMCTL_ENV_LOCK:
        state = _SYSTEMCTL_ENV_STATE
        state["user"] = username
        state["blob"] = result.stdout
        state["blob_valid"] = True
        state["blob_expires"] = time.monotonic() + hotkey_state.get_desktop_user_cache_seconds()
    return result.stdout


def _fetch_systemctl_user_env_blob(username, uid, deadline=None):
    """Return show-environment stdout for username, or None on failure."""
    need_fetch, cached = _cached_systemctl_env_blob(username)
    if not need_fetch:
        return cached
    if not shutil.which("runuser"):
        _mark_systemctl_env_skip()
        return None
    return _invoke_systemctl_show_environment(username, uid, deadline=deadline)


def _apply_blob_env_keys(env, blob):
    """Copy missing session display keys from a show-environment blob."""
    for key in _session_display_keys():
        if env.get(key):
            continue
        value = _parse_env_blob_value(blob, key)
        if value:
            env[key] = value


def _merge_systemctl_environ(env, username, uid, deadline=None):
    """Fill missing DISPLAY/WAYLAND/XDG_* from systemctl --user show-environment."""
    if not username:
        return env
    blob = _fetch_systemctl_user_env_blob(username, uid, deadline=deadline)
    if blob:
        _apply_blob_env_keys(env, blob)
    return env


def _desktop_session_env(uid, session_id, username=None, deadline=None):
    """Return DISPLAY/WAYLAND/XDG_* values for the desktop session when known."""
    bus_root = _resolve_session_bus_root()
    env = {
        "XDG_RUNTIME_DIR": f"{bus_root}/{uid}",
        "DBUS_SESSION_BUS_ADDRESS": f"unix:path={bus_root}/{uid}/bus",
    }
    session_type = _loginctl_show_session_value(session_id, "Type") if session_id else None
    if session_type:
        env["XDG_SESSION_TYPE"] = session_type
    leader = _session_leader_pid(session_id) if session_id else None
    env = _merge_leader_environ(env, leader)
    return _merge_systemctl_environ(env, username, uid, deadline=deadline)


def _cached_session_id():
    """Return the session id from the desktop-user cache when present."""
    return hotkey_state.get_desktop_user_session_id()


def _session_env_for_sudo(uid, session_id, username, cached_session, deadline=None):
    """Return session env for dbus sudo runs, refreshing when display keys missing."""
    if _session_env_has_display(cached_session):
        return cached_session
    return _desktop_session_env(uid, session_id, username, deadline=deadline)


def _build_sudo_command(username, command, requires_dbus=False, session_env=None):
    """Build a runuser/sudo-based command for running a command as the desktop user."""
    if shutil.which("runuser"):
        sudo_command = ["runuser", "-u", username, "--"]
    else:
        sudo_command = ["sudo", "-u", username, "--"]
    if requires_dbus:
        sudo_command.append("env")
        for key, value in (session_env or {}).items():
            sudo_command.append(f"{key}={value}")
    sudo_command.extend(command)
    return sudo_command


def _cached_desktop_session_env():
    """Return cached desktop session env dict when present on the cache entry."""
    return hotkey_state.get_desktop_user_session_env()


def run_in_desktop_session(command, timeout, requires_dbus=False):
    """Run a command in the desktop user's context when root."""
    cmd_timeout = float(timeout)
    if os.geteuid():
        return _run_command(command, cmd_timeout)
    resolve_deadline = time.monotonic() + _desktop_session_resolve_budget_secs(cmd_timeout)
    uid, username = _resolve_desktop_user(deadline=resolve_deadline)
    if uid is None or username is None:
        return _run_command(command, cmd_timeout)
    session_env = None
    if requires_dbus:
        session_env = _session_env_for_sudo(
            uid,
            _cached_session_id(),
            username,
            _cached_desktop_session_env(),
            deadline=resolve_deadline,
        )
    sudo_command = _build_sudo_command(
        username,
        command,
        requires_dbus=requires_dbus,
        session_env=session_env,
    )
    return _run_command(sudo_command, cmd_timeout)
