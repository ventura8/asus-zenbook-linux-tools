"""Helpers for reusing hotkey-daemon test state setup."""

import contextlib
import importlib
import importlib.util
import os
import sys
import time
from unittest.mock import MagicMock, patch

try:
    import asus_hotkey_daemon_state as _fallback_hotkey_state
except ModuleNotFoundError:
    from bin import asus_hotkey_daemon_state as _fallback_hotkey_state

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
BIN_DIR = os.path.join(PROJECT_ROOT, "bin")


def subprocess_run_responses(*entries: tuple[int, str] | tuple[int, str, str]):
    """Build sequential subprocess.run return values for runuser/sudo style tests.

    After the scripted replies are consumed, further calls get returncode=1 so a
    leftover topology/xrandr worker cannot raise StopIteration mid-suite.
    """
    mocks = []
    for entry in entries:
        returncode = entry[0]
        stdout = entry[1] if len(entry) > 1 else ""
        stderr = entry[2] if len(entry) > 2 else ""
        mocks.append(MagicMock(returncode=returncode, stdout=stdout, stderr=stderr))

    def _next_response(*_args, **_kwargs):
        if mocks:
            return mocks.pop(0)
        return MagicMock(returncode=1, stdout="", stderr="")

    return _next_response


def exec_module_from_spec(module_name: str, path: str):
    """Create, register, and execute a module from path; pop on failure."""
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"Unable to load module {path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = mod
    load_succeeded = False
    try:
        spec.loader.exec_module(mod)
        load_succeeded = True
    finally:
        if not load_succeeded:
            sys.modules.pop(module_name, None)
    return mod


_exec_module_from_spec = exec_module_from_spec


def load_daemon():
    """Load asus_hotkey_daemon public API module dynamically."""
    path = os.path.join(BIN_DIR, "asus_hotkey_daemon.py")
    existing = sys.modules.get("asus_hotkey_daemon")
    if existing is not None and getattr(existing, "__file__", None) == path:
        return existing
    return exec_module_from_spec("asus_hotkey_daemon", path)


def _candidate_state_modules():
    """Yield loaded hotkey-state module candidates in preference order."""
    for name in ("asus_hotkey_daemon_state", "bin.asus_hotkey_daemon_state"):
        candidate = sys.modules.get(name)
        if candidate is not None:
            yield candidate


def _module_dir(module):
    """Return absolute directory of module.__file__, or None."""
    path = getattr(module, "__file__", None)
    if not path:
        return None
    return os.path.dirname(os.path.abspath(path))


def _state_module_beside_daemon(daemon_module):
    """Prefer a state module whose file sits next to daemon_module."""
    daemon_dir = _module_dir(daemon_module)
    if daemon_dir is None:
        return None
    for candidate in _candidate_state_modules():
        if _module_dir(candidate) == daemon_dir:
            return candidate
    return None


def _hotkey_state_module(daemon_module=None):
    """Return the live hotkey-state module used by the daemon stack."""
    if daemon_module is None:
        return sys.modules.get("asus_hotkey_daemon_state", _fallback_hotkey_state)
    beside = _state_module_beside_daemon(daemon_module)
    if beside is not None:
        return beside
    bound = getattr(daemon_module, "asus_hotkey_daemon_state", None)
    if bound is not None:
        return bound
    raise RuntimeError("Unable to resolve hotkey state module for the provided daemon module")


def _invoke_reset_hooks(module, names, *, exclusive: bool) -> bool:
    """Call named callables on *module*; stop after first hit when exclusive."""
    if module is None:
        return False
    called = False
    for name in names:
        fn = getattr(module, name, None)
        if not callable(fn):
            continue
        fn()
        called = True
        if exclusive:
            return True
    return called


def reset_hotkey_daemon_state(daemon_module):
    """Reset the shared hotkey-daemon state used across unit tests."""
    hotkey_state = _hotkey_state_module(daemon_module)
    daemon_module.clear_debounce()
    input_mod = sys.modules.get("asus_hotkey_daemon_input")
    # Prefer chord clear; fall back to modifier-only clear (first-match exclusive).
    _invoke_reset_hooks(
        input_mod,
        ("clear_brightness_chord_state", "clear_at_modifier_state"),
        exclusive=True,
    )
    bright_mod = sys.modules.get("asus_hotkey_daemon_brightness")
    _invoke_reset_hooks(
        bright_mod,
        ("clear_at_modifier_state", "clear_brightness_dedup_state"),
        exclusive=False,
    )
    osd_mod = sys.modules.get("asus_hotkey_daemon_osd")
    if not _invoke_reset_hooks(osd_mod, ("reset_display_osd_esc_cooldown",), exclusive=True):
        _invoke_reset_hooks(input_mod, ("reset_display_osd_esc_cooldown",), exclusive=True)
    at_mod = sys.modules.get("asus_hotkey_daemon_at_proxy")
    _invoke_reset_hooks(at_mod, ("reset_pending_meta",), exclusive=True)
    if not hasattr(hotkey_state, "clear_swap_topology_cache"):
        raise AttributeError("hotkey state missing clear_swap_topology_cache")
    hotkey_state.clear_swap_topology_cache()
    hotkey_state.clear_desktop_user_cache()
    monitor = sys.modules.get("asus_hotkey_daemon_monitor")
    _invoke_reset_hooks(
        monitor,
        ("reset_topology_refresh_state", "reset_window_swap_state"),
        exclusive=False,
    )


def seed_usable_monitor_topology(monitors, *, daemon_module=None):
    """Seed topology monitor cache so swap paths skip live topology refresh."""
    if BIN_DIR not in sys.path:
        sys.path.insert(0, BIN_DIR)
    monitor = importlib.import_module("asus_hotkey_daemon_monitor")
    hotkey_state = _hotkey_state_module(daemon_module)
    cloned = [dict(item) for item in monitors]
    hotkey_state.set_last_known_monitors(cloned)
    hotkey_state.set_last_topology_refresh(time.monotonic())
    hotkey_state.set_swap_topology_signature(monitor.get_monitor_signature(cloned))
    hotkey_state.set_last_topology_refreshed_live(True)
    hotkey_state.set_last_topology_source("unit-test")


# Concrete errors inline workers may raise; keep BLE001 clean (no bare Exception).
_IMMEDIATE_THREAD_ERRORS = (
    AssertionError,
    AttributeError,
    LookupError,
    OSError,
    RuntimeError,
    TypeError,
    ValueError,
)


class _ImmediateThread:
    """Run Thread targets synchronously on start() for deterministic unit tests."""

    def __init__(self, target=None, args=(), kwargs=None, **options):
        """Accept Thread-compatible kwargs; run *target* inline on start()."""
        self._target = target
        self._args = args or ()
        self._kwargs = kwargs or {}
        self.daemon = options.get("daemon")
        self.name = options.get("name")
        self._finished = True
        self._exc = None

    @property
    def recorded_exception(self):
        """Return the exception raised by the inline target, if any."""
        return self._exc

    def start(self):
        """Run the target immediately and record any caught exception."""
        self._finished = False
        self._exc = None
        try:
            if self._target is not None:
                try:
                    self._target(*self._args, **self._kwargs)
                except _IMMEDIATE_THREAD_ERRORS as exc:
                    self._exc = exc
        finally:
            self._finished = True

    def join(self, timeout=None):
        """Match Thread.join: joins are no-ops; do not re-raise target exceptions."""
        del timeout

    def is_alive(self):
        """Return False after the inline target finishes."""
        return not self._finished


def assert_immediate_thread_clean(thread):
    """Re-raise inline worker failures captured by _ImmediateThread."""
    exc = getattr(thread, "recorded_exception", None)
    if exc is not None:
        raise exc


def _attach_recorded_context(exc, recorded):
    """Attach *recorded* as ``__context__`` when *exc* has none."""
    if exc is None or exc.__context__ is not None:
        return
    exc.__context__ = recorded


class _SyncDaemonThreadPatch:
    """Patch monitor threads inline and assert worker failures on exit."""

    def __init__(self):
        self._instances = []
        self._patches = []

    def __enter__(self):
        def factory(*args, **kwargs):
            thread = _ImmediateThread(*args, **kwargs)
            self._instances.append(thread)
            return thread

        self._patches = [
            patch("asus_hotkey_daemon_topology._thread_factory", side_effect=factory),
            patch("asus_hotkey_daemon_window_swap._thread_factory", side_effect=factory),
        ]
        for thread_patch in self._patches:
            thread_patch.__enter__()
        return self._instances

    def __exit__(self, exc_type, exc, tb):
        try:
            for thread_patch in reversed(self._patches):
                thread_patch.__exit__(exc_type, exc, tb)
            return False
        finally:
            self._raise_recorded_worker_failures(exc_type, exc)

    def _raise_recorded_worker_failures(self, exc_type, exc):
        """Re-raise or attach recorded worker exceptions after the patch exits."""
        for thread in self._instances:
            recorded = getattr(thread, "recorded_exception", None)
            if recorded is None:
                continue
            if exc_type is None:
                raise recorded
            _attach_recorded_context(exc, recorded)


def patch_sync_daemon_threads():
    """Patch monitor topology/worker threads to run inline."""
    return _SyncDaemonThreadPatch()


def patch_sync_window_swap_worker():
    """Patch window-swap worker start to run synchronously (unit tests)."""

    def _sync_start(ui, monitors, direction_key, target_monitor):
        swap = sys.modules["asus_hotkey_daemon_window_swap"]
        swap.window_swap_worker(ui, monitors, direction_key, target_monitor)
        return True

    return patch(
        "asus_hotkey_daemon_window_swap._start_window_swap_worker",
        side_effect=_sync_start,
    )


def _window_swap_command_returncode(name, *, wmctrl_ok, xdotool_ok):
    """Return a stub returncode for a window-swap external move command name."""
    if name.endswith("wmctrl"):
        return 0 if wmctrl_ok else 1
    if name.endswith("xdotool"):
        return 0 if xdotool_ok else 1
    return 1


def _window_swap_run_command(command, timeout=None, *, wmctrl_ok=True, xdotool_ok=False):
    """Named _run_command stub for window-swap external move tests."""
    del timeout
    name = command[0] if command else ""
    code = _window_swap_command_returncode(name, wmctrl_ok=wmctrl_ok, xdotool_ok=xdotool_ok)
    return MagicMock(returncode=code, stdout="", stderr="")


def patch_external_window_move(*, wmctrl_ok=True, xdotool_ok=False):
    """Patch external wmctrl/xdotool boundaries without replacing owned move helpers."""

    def _which(cmd):
        if cmd == "wmctrl" and wmctrl_ok:
            return "/usr/bin/wmctrl"
        if cmd == "xdotool" and xdotool_ok:
            return "/usr/bin/xdotool"
        return None

    def _run(command, timeout=None):
        return _window_swap_run_command(
            command,
            timeout,
            wmctrl_ok=wmctrl_ok,
            xdotool_ok=xdotool_ok,
        )

    return (
        patch("asus_hotkey_daemon_window_swap.shutil.which", side_effect=_which),
        patch("asus_hotkey_daemon_session._run_command", side_effect=_run),
    )


@contextlib.contextmanager
def window_swap_monitor_patches(*, move_return=True, focus_monitor_index=None):
    """Patches for window-swap tests: sync worker + external move boundaries only."""
    wmctrl_ok, xdotool_ok = move_return, move_return
    with contextlib.ExitStack() as stack:
        stack.enter_context(patch_sync_window_swap_worker())
        stack.enter_context(patch_sync_daemon_threads())
        stack.enter_context(
            patch(
                "asus_hotkey_daemon_topology._focused_monitor_index",
                return_value=focus_monitor_index,
            )
        )
        # Keep sync swap path: event thread must not defer for extension priming.
        stack.enter_context(
            patch(
                "asus_hotkey_daemon_window_swap_gnome._gnome_window_swap_dbus_ready",
                return_value=True,
            )
        )
        stack.enter_context(
            patch(
                "asus_hotkey_daemon_window_swap._gnome_window_swap_dbus_ready_fast",
                return_value=True,
            )
        )
        for ctx in patch_external_window_move(wmctrl_ok=wmctrl_ok, xdotool_ok=xdotool_ok):
            stack.enter_context(ctx)
        yield
