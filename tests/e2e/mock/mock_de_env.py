"""Mock DE environment builders for multi-desktop E2E tests."""

from __future__ import annotations

import os
from pathlib import Path

from tests.e2e.mock.mock_env import (
    MOCK_GID,
    MOCK_UID,
    MOCK_USERNAME,
    _create_bus_socket,
    _create_shared_mock_bin,
    _install_mock_sudo,
    install_uninstall_mock_systemctl,
    mock_install_env_base,
    write_executable,
)


def _setup_de_base(tmp: str, de_token: str) -> tuple[dict[str, str], Path, Path, Path]:
    """Scaffold base directories and common stubs for DE testing."""
    root = Path(tmp)
    dest_dir = root / "dest"
    mock_bin = _create_shared_mock_bin(root)
    _install_mock_sudo(mock_bin)
    _create_bus_socket(root)

    home_dir = root / "home" / MOCK_USERNAME
    config_home = home_dir / ".config"
    config_home.mkdir(parents=True, exist_ok=True)
    state_dir = dest_dir / "var" / "lib" / "asus-zenbook-linux-tools"
    state_dir.mkdir(parents=True, exist_ok=True)
    notif_root = root / "notif"
    notif_root.mkdir(parents=True, exist_ok=True)

    # getent stub to return home_dir for mock user
    write_executable(
        mock_bin / "getent",
        f'#!/bin/sh\nif [ "$1" = "passwd" ] && [ "$2" = "{MOCK_USERNAME}" ]; then\n'
        f"  echo '{MOCK_USERNAME}:x:{MOCK_UID}:{MOCK_GID}:Mock User:{home_dir}:/bin/bash'\n"
        f"  exit 0\nfi\nexit 1\n",
    )

    family_map = {
        "KDE": "kde",
        "XFCE": "xfce",
        "LXQt": "lxqt",
        "X-Cinnamon": "cinnamon",
        "MATE": "mate",
        "GNOME": "gnome",
    }
    family = family_map.get(de_token, de_token.lower())

    systemctl_path = install_uninstall_mock_systemctl(mock_bin)

    env = mock_install_env_base(
        DESTDIR=str(dest_dir),
        SYSTEMCTL_CMD=str(systemctl_path),
        INSTALL_ASSUME_UNIT_ACTIVE="1",
        SKIP_ROOT_CHECK="1",
        SKIP_PKG_REMOVE="1",
        DBUS_BUS_ROOT=str(root / "bus-root"),
        RUN_USER_ROOT=str(root / "bus-root"),
        BUS_ROOT=str(root / "bus-root"),
        STATE_DIR=str(state_dir),
        NOTIF_ID_ROOT=str(notif_root),
        PATH=f"{mock_bin}:{os.environ.get('PATH', '')}",
        USER=MOCK_USERNAME,
        HOME=str(home_dir),
        XDG_CONFIG_HOME=str(config_home),
        XDG_CURRENT_DESKTOP=de_token,
        DESKTOP_SESSION=de_token,
        ASUS_DESKTOP_FAMILY=family,
    )
    return env, dest_dir, mock_bin, home_dir


def build_kde_mock_env(
    tmp: str,
    *,
    has_kwriteconfig: bool = True,
    use_qt6: bool = True,
) -> tuple[dict[str, str], Path, Path, Path]:
    """Scaffold mock environment for KDE Plasma E2E tests."""
    env, dest_dir, mock_bin, home_dir = _setup_de_base(tmp, "KDE")
    kglobalshortcutsrc = home_dir / ".config" / "kglobalshortcutsrc"
    kglobalshortcutsrc.write_text(
        "[org.kde.spectacle.desktop]\n"
        "RectangularRegionScreen=Meta+Shift+S\tPrint\tTake Rectangular Region Screenshot\n"
        "_k_friendly_name=Spectacle\n",
        encoding="utf-8",
    )

    qdbus_name = "qdbus6" if use_qt6 else "qdbus"
    write_executable(
        mock_bin / qdbus_name,
        "#!/bin/sh\n"
        "exit 0\n",
    )

    if has_kwriteconfig:
        kwrite_name = "kwriteconfig6" if use_qt6 else "kwriteconfig5"
        kread_name = "kreadconfig6" if use_qt6 else "kreadconfig5"

        write_executable(
            mock_bin / kwrite_name,
            "#!/bin/sh\n"
            "# Basic kwriteconfig stub\n"
            "exit 0\n",
        )
        write_executable(
            mock_bin / kread_name,
            "#!/bin/sh\n"
            "exit 0\n",
        )

    return env, dest_dir, mock_bin, home_dir


def build_xfce_mock_env(
    tmp: str,
) -> tuple[dict[str, str], Path, Path, Path]:
    """Scaffold mock environment for XFCE E2E tests."""
    env, dest_dir, mock_bin, home_dir = _setup_de_base(tmp, "XFCE")

    # xfconf-query stub
    write_executable(
        mock_bin / "xfconf-query",
        "#!/bin/sh\n"
        'case "$1" in\n'
        '  -c)\n'
        '    case "$3" in\n'
        "      -p)\n"
        '        if [ "$5" = "-s" ] || [ "$5" = "--set" ]; then exit 0; fi\n'
        '        if [ "$5" = "-r" ] || [ "$5" = "--reset" ]; then exit 0; fi\n'
        '        if [ "$5" = "-n" ] || [ "$5" = "--create" ]; then exit 0; fi\n'
        '        if [ "$#" -le 4 ]; then echo "mock_val"; exit 0; fi\n'
        "        ;;\n"
        "      -l|--list) exit 0 ;;\n"
        "    esac\n"
        "    ;;\n"
        "  --version) echo 'xfconf-query 4.18.0'; exit 0 ;;\n"
        "esac\n"
        "exit 0\n",
    )

    return env, dest_dir, mock_bin, home_dir


def build_lxqt_mock_env(
    tmp: str,
) -> tuple[dict[str, str], Path, Path, Path]:
    """Scaffold mock environment for LXQt E2E tests."""
    env, dest_dir, mock_bin, home_dir = _setup_de_base(tmp, "LXQt")
    lxqt_dir = home_dir / ".config" / "lxqt"
    lxqt_dir.mkdir(parents=True, exist_ok=True)
    conf_path = lxqt_dir / "globalkeyshortcuts.conf"
    conf_path.write_text(
        "[General]\n"
        "version=1.4.0\n\n"
        "[Control_Center.desktop]\n"
        "Comment=Launch Settings\n"
        "Enabled=true\n"
        "Exec=lxqt-config\n"
        "Shortcut=XF86Launch1\n",
        encoding="utf-8",
    )

    write_executable(
        mock_bin / "qdbus",
        "#!/bin/sh\nexit 0\n",
    )

    return env, dest_dir, mock_bin, home_dir


def build_cinnamon_mock_env(
    tmp: str,
) -> tuple[dict[str, str], Path, Path, Path]:
    """Scaffold mock environment for Cinnamon E2E tests."""
    env, dest_dir, mock_bin, home_dir = _setup_de_base(tmp, "X-Cinnamon")

    write_executable(
        mock_bin / "gsettings",
        "#!/bin/sh\n"
        'schema="$2"\n'
        'case "$1" in\n'
        '  list-keys) echo "custom-list" ;;\n'
        "  list-schemas)\n"
        "    printf 'org.cinnamon.desktop.keybindings\\norg.cinnamon.desktop.keybindings.custom-keybinding\\n'\n"
        "    ;;\n"
        '  get) echo "['"'"'custom0'"'"']" ;;\n'
        "  set|reset) exit 0 ;;\n"
        "esac\n"
        "exit 0\n",
    )

    return env, dest_dir, mock_bin, home_dir


def build_mate_mock_env(
    tmp: str,
) -> tuple[dict[str, str], Path, Path, Path]:
    """Scaffold mock environment for MATE E2E tests."""
    env, dest_dir, mock_bin, home_dir = _setup_de_base(tmp, "MATE")

    write_executable(
        mock_bin / "gsettings",
        "#!/bin/sh\n"
        'schema="$2"\n'
        'case "$1" in\n'
        "  list-keys) echo 'run-command-1' ;;\n"
        "  list-schemas)\n"
        "    printf 'org.mate.control-center.keybinding\\norg.mate.Marco.global-keybindings\\n'\n"
        "    ;;\n"
        '  get) echo "['"'"'mock'"'"']" ;;\n'
        "  set|reset) exit 0 ;;\n"
        "esac\n"
        "exit 0\n",
    )

    return env, dest_dir, mock_bin, home_dir
