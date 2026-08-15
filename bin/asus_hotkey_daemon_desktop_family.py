#!/usr/bin/env python3
"""Desktop family hints for the ASUS hotkey daemon."""

import os
import shutil
import subprocess
import threading

import asus_hotkey_daemon_state as hotkey_state

_MINT_BARE_GNOME_STATE = {"cache": None}
_MINT_BARE_GNOME_LOCK = threading.Lock()


def _family_from_desktop_string(desktop):
    """Map an XDG_CURRENT_DESKTOP string to a coarse desktop family."""
    desktop = desktop.lower()
    rules = (
        (("xfce",), "xfce"),
        (("kde", "plasma"), "kde"),
        (("lxqt",), "lxqt"),
        (("cinnamon",), "cinnamon"),
        (("mate",), "mate"),
        (("gnome", "ubuntu", "pop"), "gnome"),
    )
    for tokens, family in rules:
        if any(token in desktop for token in tokens):
            return family
    return "other"


def _token_cinnamon_or_mate(text):
    """Return cinnamon/mate when *text* contains those tokens."""
    lowered = (text or "").lower()
    if "cinnamon" in lowered:
        return "cinnamon"
    if "mate" in lowered:
        return "mate"
    return ""


def _executable_path(path):
    """Return True when *path* is an executable regular file."""
    return os.path.isfile(path) and os.access(path, os.X_OK)


def _probe_de_binary_family():
    """Classify Mint-like DEs via binaries when gnome-shell is absent."""
    if _executable_path("/usr/bin/gnome-shell"):
        return ""
    if _executable_path("/usr/bin/cinnamon"):
        return "cinnamon"
    for path in ("/usr/bin/mate-session", "/usr/bin/mate-panel"):
        if _executable_path(path):
            return "mate"
    return ""


def _gsettings_schema_names():
    """Return the set of gsettings schema names, or None on failure."""
    gsettings = shutil.which("gsettings")
    if not gsettings:
        return None
    try:
        completed = subprocess.run(
            [gsettings, "list-schemas"],
            check=False,
            capture_output=True,
            text=True,
            timeout=2,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return set((completed.stdout or "").split())


def _probe_de_schema_family():
    """Best-effort gsettings schema probe for cinnamon/mate."""
    schemas = _gsettings_schema_names()
    if not schemas:
        return ""
    if "org.cinnamon.desktop.keybindings" in schemas:
        return "cinnamon"
    if "org.mate.control-center.keybinding" in schemas:
        return "mate"
    return ""


def _session_desktop_probe_texts(session_env):
    """Collect session desktop hint strings for Mint bare-GNOME probes."""
    env = session_env or {}
    keys = ("XDG_SESSION_DESKTOP", "DESKTOP_SESSION")
    return [env.get(key) or os.environ.get(key, "") for key in keys]


def _compute_mint_bare_gnome_family(session_env):
    """Probe session/desktop signals for Mint cinnamon/mate under bare GNOME."""
    for text in _session_desktop_probe_texts(session_env):
        hit = _token_cinnamon_or_mate(text)
        if hit:
            return hit
    for probe in (_probe_de_binary_family, _probe_de_schema_family):
        hit = probe()
        if hit:
            return hit
    return ""


def _mint_bare_gnome_family(session_env=None):
    """Remap bare GNOME/ubuntu:GNOME to cinnamon/mate when secondary signals hit."""
    with _MINT_BARE_GNOME_LOCK:
        cached = _MINT_BARE_GNOME_STATE["cache"]
        if cached is not None:
            return cached
        hit = _compute_mint_bare_gnome_family(session_env)
        _MINT_BARE_GNOME_STATE["cache"] = hit
        return hit


def clear_mint_bare_gnome_cache():
    """Reset Mint bare-GNOME heuristic cache (tests)."""
    with _MINT_BARE_GNOME_LOCK:
        _MINT_BARE_GNOME_STATE["cache"] = None


def _session_xdg_current_desktop(session_env):
    """Resolve XDG_CURRENT_DESKTOP from session env, then process environ."""
    desktop = session_env.get("XDG_CURRENT_DESKTOP")
    if desktop:
        return desktop
    return os.environ.get("XDG_CURRENT_DESKTOP", "")


def desktop_family_hint():
    """Return a coarse desktop family hint for window-move backend selection."""
    override = os.environ.get("ASUS_DESKTOP_FAMILY", "").strip()
    if override:
        return _family_from_desktop_string(override)
    session_env = hotkey_state.get_desktop_user_session_env() or {}
    family = _family_from_desktop_string(_session_xdg_current_desktop(session_env))
    if family != "gnome":
        return family
    remapped = _mint_bare_gnome_family(session_env)
    if remapped:
        return remapped
    return family
