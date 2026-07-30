"""Display-mode shell D-Bus startup fixture.

Loaded via ``tests/fixtures/display_mode_shell_sitecustomize.py`` when
``ASUS_DISPLAY_MODE_SHELL_TEST=1`` and ``ASUS_DISPLAY_MODE_DBUS_STARTUP`` point
at this file. Patches only the external ``dbus.SessionBus`` boundary so
``bin/asus_display_mode.py`` runs unchanged while shell tests stay hermetic.
"""

from __future__ import annotations

import atexit
import os
import sys
from unittest.mock import MagicMock, patch

if os.environ.get("ASUS_DISPLAY_MODE_SHELL_TEST") == "1":
    try:
        import dbus
    except ImportError:
        print(
            "display_mode_shell_dbus_startup: python3-dbus is required for this fixture",
            file=sys.stderr,
        )
        raise SystemExit(1) from None

    _BUILTIN_STATE = (
        1,
        [
            (
                ("eDP-1", "SDC"),
                [("3840x2160@60.000", 3840, 2160, 60.0, 2.0, [], {"is-current": True})],
                {"is-builtin": True},
            ),
            (
                ("DP-3", "BOE"),
                [("3840x1100@60.017", 3840, 1100, 60.0, 2.0, [], {"is-preferred": True})],
                {"is-builtin": False},
            ),
        ],
        [
            (0, 0, 2.0, 0, True, [("eDP-1", "3840x2160@60.000", {})]),
            (0, 2160, 2.0, 0, False, [("DP-3", "3840x1100@60.017", {})]),
        ],
        {},
    )

    def _build_mock_iface():
        mock_iface = MagicMock()
        mock_iface.GetCurrentState.return_value = _BUILTIN_STATE
        mock_iface.ApplyMonitorsConfig.return_value = None
        return mock_iface

    def _session_bus_factory(*_args, **_kwargs):
        mock_bus = MagicMock()
        mock_obj = MagicMock()
        mock_bus.get_object.return_value = mock_obj
        return mock_bus

    _mock_iface = _build_mock_iface()

    def _interface_factory(_obj, _iface_name):
        return _mock_iface

    _patcher_bus = patch.object(dbus, "SessionBus", side_effect=_session_bus_factory)
    _patcher_iface = patch.object(dbus, "Interface", side_effect=_interface_factory)
    _patcher_bus.start()
    _patcher_iface.start()
    atexit.register(_patcher_bus.stop)
    atexit.register(_patcher_iface.stop)
