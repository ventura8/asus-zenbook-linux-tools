"""Shared helpers for display-mode unit tests."""

import contextlib
import importlib
import io
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import shared_imports


def require_dbus_module():
    """Import and return the real dbus module, failing if unavailable."""
    return importlib.import_module("dbus")


def _display_mode_module_path() -> Path:
    """Return the filesystem path for the display-mode backend module."""
    return Path(__file__).resolve().parents[3] / "bin" / "asus_display_mode.py"


def _ensure_bin_dir_on_sys_path(module_path: Path) -> None:
    """Ensure the display-mode module directory is importable."""
    bin_dir_path = str(module_path.parent)
    if bin_dir_path not in sys.path:
        sys.path.insert(0, bin_dir_path)


def _load_module_from_path(module_name: str, module_path: Path):
    """Load module_name directly from module_path and register it in sys.modules."""
    return shared_imports.load_module_from_path(module_name, str(module_path))


def _load_display_mode_module(module_name: str):
    """Load a display-mode-related module from bin/ by name."""
    require_dbus_module()
    module_path = _display_mode_module_path().with_name(f"{module_name}.py")
    _ensure_bin_dir_on_sys_path(module_path)
    existing = sys.modules.get(module_name)
    if existing is not None and getattr(existing, "__file__", None) == str(module_path):
        return existing
    return _load_module_from_path(module_name, module_path)


def load_asus_display_mode_module():
    """Import the display-mode backend module under test."""
    return _load_display_mode_module("asus_display_mode")


def load_asus_display_mode_core_module():
    """Import asus_display_mode_core after establishing the bin import path."""
    return _load_display_mode_module("asus_display_mode_core")


def build_mock_dbus_state():
    """Create a mocked D-Bus bus and interface pair for display-mode tests."""
    mock_bus = MagicMock()
    mock_bus_cls = MagicMock(return_value=mock_bus)
    mock_iface = MagicMock()
    return mock_bus_cls, mock_iface


@contextlib.contextmanager
def patch_mutter_display_config(get_current_state):
    """Patch SessionBus/Interface to return *get_current_state* from GetCurrentState."""
    mock_bus_cls, mock_iface = build_mock_dbus_state()
    mock_iface.GetCurrentState.return_value = get_current_state
    with patch("dbus.SessionBus", mock_bus_cls), patch("dbus.Interface", return_value=mock_iface):
        yield mock_iface


def run_display_mode_main(argv, state):
    """Run asus_display_mode.main() under Mutter patches; return (rc, mock_iface)."""
    asus_display_mode = load_asus_display_mode_module()
    with patch_mutter_display_config(state) as mock_iface, patch.object(sys, "argv", argv):
        return asus_display_mode.main(), mock_iface


def assert_display_mode_main_applies(test_case, argv, state):
    """Assert main() succeeds and calls ApplyMonitorsConfig once."""
    rc, mock_iface = run_display_mode_main(argv, state)
    test_case.assertEqual(rc, 0)
    mock_iface.ApplyMonitorsConfig.assert_called_once()
    return mock_iface


def four_monitor_topology_state():
    """Return a Mutter state tuple with four logical external monitors."""
    physical = [
        (
            ("HDMI-1", "DELL"),
            [("2560x1440@60.000", 2560, 1440, 60.0, 1.0, [], {"is-current": True})],
            {"is-builtin": False},
        ),
    ]
    logical = [(index * 1920, 0, 1.0, 0, index == 0, [("HDMI-1", "2560x1440@60.000", {})]) for index in range(4)]
    return (1, physical, logical, {})


def sample_builtin_screenpad_state():
    """Return a canonical current-state tuple with built-in and ScreenPad monitors."""
    return (
        1,
        [
            (("eDP-1", "SDC"), [("3840x2160@60.000", 3840, 2160, 60.0, 2.0, [], {"is-current": True})], {"is-builtin": True}),
            (("DP-3", "BOE"), [("3840x1100@60.017", 3840, 1100, 60.0, 2.0, [], {"is-preferred": True})], {"is-builtin": False}),
        ],
        [(0, 0, 2.0, 0, True, [("eDP-1", "3840x2160@60.000", {})])],
        {},
    )


def run_display_mode_main_reject(test_case, argv, expected_stderr, state=None):
    """Run main() expecting SystemExit(1) and *expected_stderr* text."""
    asus_display_mode = load_asus_display_mode_module()
    stderr = io.StringIO()
    topology = sample_builtin_screenpad_state() if state is None else state
    with (
        patch_mutter_display_config(topology),
        patch.object(sys, "argv", argv),
        patch("sys.stderr", stderr),
        test_case.assertRaises(SystemExit) as exc,
    ):
        asus_display_mode.main()
    test_case.assertEqual(exc.exception.code, 1)
    test_case.assertEqual(stderr.getvalue().strip(), expected_stderr)


def get_display_mode_core_helper(module, name: str):
    """Resolve a display-mode core helper symbol for unit tests."""
    return getattr(module, name)
