"""Shared mock environment builders for mocked E2E installer/uninstaller tests."""

from __future__ import annotations

import os
import shlex
import socket
from pathlib import Path

AF_UNIX_PATH_MAX = 108
MOCK_UID = 1000
MOCK_GID = 1000
MOCK_USERNAME = "mockuser"


def mock_install_env_base(**overrides):
    """Return a base mocked-install env dict with optional overrides."""
    env = dict(
        os.environ,
        ASUS_TEST_MODE="1",
        SKIP_ROOT_CHECK="1",
        SKIP_PKG_INSTALL="1",
    )
    env.update(overrides)
    return env


def write_executable(path: Path, body: str) -> None:
    """Write body to path and mark the file executable."""
    path.write_text(body, encoding="utf-8")
    path.chmod(0o755)


def _mock_sudo_script_body() -> str:
    """Return a sudo stub that preserves common flag/env assignment handling."""
    return (
        "#!/bin/sh\n"
        "while [ $# -gt 0 ]; do\n"
        '  case "$1" in\n'
        "    -E|-n) shift ;; \n"
        "    --user|--group|-u|-g|-p) shift; [ $# -gt 0 ] && shift ;; \n"
        "    --user=*|--group=*) shift ;; \n"
        "    --) shift; break ;; \n"
        '    -*) echo "unsupported sudo option: $1" >&2; exit 1 ;; \n'
        '    *=*) export "$1"; shift ;; \n'
        "    *) break ;; \n"
        "  esac\n"
        "done\n"
        'exec "$@"\n'
    )


def _install_mock_sudo(mock_bin: Path) -> None:
    """Install shared sudo mock script in mock_bin."""
    write_executable(mock_bin / "sudo", _mock_sudo_script_body())


def _install_session_user_stubs(
    mock_bin: Path,
    username: str,
    uid: int,
    gid: int,
    session=None,
) -> None:
    """Install parameterized loginctl/id stubs for session discovery."""
    session = session or {"id": "1", "type": "wayland"}
    session_id = str(session["id"])
    session_type = str(session["type"])
    username_q = shlex.quote(username)
    session_q = shlex.quote(session_id)
    type_q = shlex.quote(session_type)
    write_executable(
        mock_bin / "loginctl",
        "#!/bin/sh\n"
        f'if [ "$1" = "list-sessions" ]; then echo {session_q}; exit 0; fi\n'
        'if [ "$1" = "show-session" ]; then\n'
        '  prop=""\n'
        '  for arg in "$@"; do\n'
        '    case "$arg" in\n'
        '      --property=*) prop="${arg#--property=}" ;;\n'
        '      -p*) prop="${arg#-p}" ;;\n'
        '      Type|State|Name|Seat|Leader|User) prop="$arg" ;;\n'
        "    esac\n"
        "  done\n"
        '  case "$prop" in\n'
        f"    Type)  echo {type_q} ;;\n"
        "    State) echo active ;;\n"
        f"    Name)  echo {username_q} ;;\n"
        "    Seat)  echo seat0 ;;\n"
        "    Leader) echo 1 ;;\n"
        f"    User) echo {uid} ;;\n"
        "    *) exit 1 ;;\n"
        "  esac\n"
        "  exit 0\n"
        "fi\n"
        "exit 1\n",
    )
    write_executable(
        mock_bin / "id",
        "#!/bin/sh\n"
        f'case "$1" in\n  -u) echo {uid}; exit 0 ;;\n  -un) echo {username_q}; exit 0 ;;\n'
        f"  -g) echo {gid}; exit 0 ;;\nesac\n"
        'echo "id: unsupported flag: $*" >&2\n'
        "exit 1\n",
    )


def _install_mock_msgfmt(mock_bin: Path) -> None:
    """Install a fast msgfmt stub for DESTDIR catalog compile in mocked installs."""
    write_executable(
        mock_bin / "msgfmt",
        "#!/bin/sh\n"
        "out=''\n"
        "while [ $# -gt 0 ]; do\n"
        "  case \"$1\" in\n"
        "    -o) out=$2; shift 2 ;;\n"
        "    --check|--check-format) shift ;;\n"
        "    *) shift ;;\n"
        "  esac\n"
        "done\n"
        "[ -n \"$out\" ] || exit 1\n"
        ": > \"$out\"\n",
    )


def _create_shared_mock_bin(root: Path) -> Path:
    """Create mock-bin with loginctl and id stubs for session discovery."""
    mock_bin = root / "mock-bin"
    mock_bin.mkdir(parents=True, exist_ok=True)
    _install_session_user_stubs(mock_bin, username=MOCK_USERNAME, uid=MOCK_UID, gid=MOCK_GID)
    _install_mock_msgfmt(mock_bin)
    return mock_bin


def _create_bus_socket_at(bus_path: Path) -> None:
    """Bind a Unix domain socket at bus_path for D-Bus stub purposes.

    The socket is intentionally closed after bind: only the filesystem path must
    exist so session helpers treat the bus as present without a live listener.
    """
    path_bytes = os.fsencode(bus_path)
    if len(path_bytes) >= AF_UNIX_PATH_MAX:
        raise ValueError(f"Unix socket path exceeds AF_UNIX limit ({AF_UNIX_PATH_MAX}): {bus_path}")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.bind(str(bus_path))
    finally:
        sock.close()


def _create_bus_socket(root: Path) -> Path:
    """Create a fake session bus socket path under root/bus-root/MOCK_UID/bus."""
    bus_dir = root / "bus-root" / str(MOCK_UID)
    bus_dir.mkdir(parents=True, exist_ok=True)
    bus_socket = bus_dir / "bus"
    if bus_socket.exists():
        bus_socket.unlink()
    _create_bus_socket_at(bus_socket)
    return bus_socket


def install_uninstall_mock_systemctl(mock_bin: Path) -> Path:
    """Install a systemctl mock that reports all units inactive after stop."""
    systemctl_path = mock_bin / "systemctl"
    write_executable(
        systemctl_path,
        '#!/bin/sh\nif [ "$1" = "is-active" ]; then exit 3; fi\nexit 0\n',
    )
    return systemctl_path


def build_install_gsettings_script(*, include_switch_video_mode: bool = True) -> str:
    """Return a schema-aware gsettings mock for install-path GNOME keybinding tests."""
    media_keys = ["control-center", "custom-keybindings"]
    if include_switch_video_mode:
        media_keys = ["switch-video-mode", *media_keys]
    media_printf = "\\n".join(media_keys)
    return "".join(
        [
            "#!/bin/sh\n",
            'schema="$2"\n',
            'base_schema="${schema%%:*}"\n',
            'case "$1" in\n',
            "  list-keys)\n",
            '    case "$base_schema" in\n',
            "      org.gnome.shell.keybindings) echo show-screenshot-ui ;;\n",
            "      org.gnome.settings-daemon.plugins.media-keys)\n",
            f"        printf '{media_printf}\\n' ;;\n",
            "      org.gnome.mutter.keybindings) echo switch-monitor ;;\n",
            "      *) exit 1 ;;\n",
            "    esac\n",
            "    exit 0\n",
            "    ;;\n",
            "  get)\n",
            "    echo \"['mock']\"\n",
            "    exit 0\n",
            "    ;;\n",
            "  set|reset)\n",
            "    exit 0\n",
            "    ;;\n",
            "esac\n",
            "exit 1\n",
        ]
    )


def gsettings_key_exists_command(
    install_script: str,
    bus_path: str,
    schema: str,
    key: str,
) -> list[str]:
    """Argv for bash -c sourcing install.sh and exercising _gsettings_key_exists."""
    install_q = shlex.quote(install_script)
    bus_q = shlex.quote(bus_path)
    schema_q = shlex.quote(schema)
    key_q = shlex.quote(key)
    user_q = shlex.quote(MOCK_USERNAME)
    return [
        "bash",
        "-c",
        (f"source {install_q} && _gsettings_key_exists {user_q} {bus_q} {schema_q} {key_q}"),
    ]


def build_install_mock_env(tmp: str) -> tuple[dict, Path, Path]:
    """Return environment, DESTDIR, and mock_bin for mock-backed installer tests."""
    root = Path(tmp)
    dest_dir = root / "dest"
    mock_bin = _create_shared_mock_bin(root)

    _install_mock_sudo(mock_bin)
    write_executable(
        mock_bin / "gsettings",
        build_install_gsettings_script(),
    )

    _create_bus_socket(root)

    env = mock_install_env_base(
        DESTDIR=str(dest_dir),
        SYSTEMCTL_CMD="true",
        INSTALL_ASSUME_UNIT_ACTIVE="1",
        DBUS_BUS_ROOT=str(root / "bus-root"),
        RUN_USER_ROOT=str(root / "bus-root"),
        BUS_ROOT=str(root / "bus-root"),
        PATH=f"{mock_bin}:{os.environ.get('PATH', '')}",
        USER=MOCK_USERNAME,
    )
    return env, dest_dir, mock_bin


def _write_gnome_backup_state(state_dir: Path) -> None:
    """Write the four GNOME keybinding backup files used by uninstall restore tests."""
    state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / "orig_show_screenshot_ui").write_text("['Print']", encoding="utf-8")
    (state_dir / "orig_control_center").write_text("['XF86Launch1']", encoding="utf-8")
    (state_dir / "orig_switch_video_mode").write_text("['<Super>p']", encoding="utf-8")
    (state_dir / "orig_switch_monitor").write_text("['<Super>p']", encoding="utf-8")


def _build_uninstall_common_env(
    tmp: str,
    *,
    bus_name: str = "bus-root",
    create_bus: bool = False,
    gnome_state: bool = False,
    fail_set: bool = False,
) -> tuple[dict, Path, Path | None]:
    """Shared DESTDIR/mock uninstall environment builder."""
    root = Path(tmp)
    dest_dir = root / "dest"
    mock_bin = _create_shared_mock_bin(root)
    systemctl_path = install_uninstall_mock_systemctl(mock_bin)
    _install_mock_sudo(mock_bin)
    state_dir: Path | None = None
    if gnome_state:
        state_dir = dest_dir / f"var/lib/asus-zenbook-linux-tools/{MOCK_UID}"
        _write_gnome_backup_state(state_dir)
    if create_bus:
        _create_bus_socket(root)
        write_executable(
            mock_bin / "gsettings",
            "#!/bin/sh\n"
            'if [ "${FAIL_GSETTINGS_SET:-0}" = "1" ] && [ "$1" = "set" ]; then exit 1; fi\n'
            'if [ "$1" = "reset" ]; then exit 0; fi\n'
            "exit 0\n",
        )
    env = dict(
        os.environ,
        ASUS_TEST_MODE="1",
        SKIP_ROOT_CHECK="1",
        SKIP_PKG_REMOVE="1",
        DESTDIR=str(dest_dir),
        SYSTEMCTL_CMD=str(systemctl_path),
        DBUS_BUS_ROOT=str(root / bus_name),
        PATH=f"{mock_bin}:{os.environ.get('PATH', '')}",
    )
    env.pop("BUS_ROOT", None)
    if fail_set:
        env["FAIL_GSETTINGS_SET"] = "1"
    return env, dest_dir, state_dir


def build_uninstall_restore_env(tmp: str, *, fail_set: bool = False) -> tuple[dict, Path, Path]:
    """Return environment plus state directory for uninstall restore-path tests."""
    env, dest_dir, state_dir = _build_uninstall_common_env(tmp, create_bus=True, gnome_state=True, fail_set=fail_set)
    assert state_dir is not None
    return env, dest_dir, state_dir


def build_uninstall_base_env(tmp: str) -> tuple[dict, Path]:
    """Return basic non-root-checked uninstall environment without restore state."""
    env, dest_dir, _state = _build_uninstall_common_env(tmp)
    return env, dest_dir


def build_uninstall_missing_bus_env(tmp: str) -> tuple[dict, Path]:
    """Return uninstall environment with GNOME backup state and no D-Bus session socket."""
    env, dest_dir, _state = _build_uninstall_common_env(tmp, bus_name="no-bus", gnome_state=True)
    return env, dest_dir


def _gsettings_stub_script_body() -> str:
    """Return a gsettings stub that mocks GNOME schemas and fails closed otherwise."""
    body = (
        "#!/bin/sh\n"
        'schema="$2"\n'
        'base_schema="${schema%%:*}"\n'
        'case "$base_schema" in\n'
        "  org.gnome.*)\n"
        '    case "$1" in\n'
        "      list-keys)\n"
        '        case "$base_schema" in\n'
        "          org.gnome.shell.keybindings)               echo show-screenshot-ui ;;\n"
        "          org.gnome.settings-daemon.plugins.media-keys)\n"
        "            printf 'control-center\\ncustom-keybindings\\nswitch-video-mode\\n' ;;\n"
        "          org.gnome.mutter.keybindings)               echo switch-monitor ;;\n"
        "        esac; exit 0 ;;\n"
        '      get) echo "[]"; exit 0 ;;\n'
        "      set|reset) exit 0 ;;\n"
        "    esac ;;\n"
        "esac\n"
        "exit 1\n"
    )
    return body


def build_minimal_mock_env(tmp: str) -> tuple[dict, Path, Path]:
    """Build installer env with mocks for CI-only boundaries.

    Includes stubs or passthroughs for: systemctl, loginctl/id session discovery,
    sudo, apt-get/dpkg package detection, hda-verb sound helpers, gsettings session
    checks, and fake sound hardware paths when tests need them.
    """
    root = Path(tmp)
    dest_dir = root / "dest"
    mock_bin = root / "mock-bin"
    mock_bin.mkdir(parents=True, exist_ok=True)

    # systemctl: unconditional success stub; no actual service ops
    write_executable(
        mock_bin / "systemctl",
        "#!/bin/sh\nexit 0\n",
    )
    _install_mock_sudo(mock_bin)

    # loginctl/id: session stubs for the current process user
    _install_session_user_stubs(mock_bin, username=MOCK_USERNAME, uid=MOCK_UID, gid=MOCK_GID)
    write_executable(mock_bin / "apt-get", "#!/bin/sh\nexit 0\n")
    write_executable(mock_bin / "dpkg", "#!/bin/sh\nexit 1\n")

    # Sound hardware stubs
    proc_asound = root / "proc" / "asound" / "card0"
    proc_asound.mkdir(parents=True, exist_ok=True)
    (proc_asound / "codec#0").write_text("Codec: Realtek ALC294\n", encoding="utf-8")
    dev_snd = root / "dev" / "snd"
    dev_snd.mkdir(parents=True, exist_ok=True)
    hw_dev = dev_snd / "hwC0D0"
    hw_dev.write_text("", encoding="utf-8")
    write_executable(mock_bin / "hda-verb", "#!/bin/sh\nexit 0\n")
    write_executable(mock_bin / "gsettings", _gsettings_stub_script_body())
    bus_root = root / "dbus"
    user_bus_dir = bus_root / str(MOCK_UID)
    user_bus_dir.mkdir(parents=True, exist_ok=True)
    bus_path = user_bus_dir / "bus"
    if bus_path.exists():
        bus_path.unlink()
    _create_bus_socket_at(bus_path)

    env = mock_install_env_base(
        DESTDIR=str(dest_dir),
        SYSTEMCTL_CMD=str(mock_bin / "systemctl"),
        INSTALL_ASSUME_UNIT_ACTIVE="1",
        DBUS_BUS_ROOT=str(bus_root),
        PROC_ASOUND_ROOT=str(root / "proc" / "asound"),
        DEV_SND_ROOT=str(dev_snd),
        INSTALL_OS_ID="ubuntu",
        PATH=f"{mock_bin}:{os.environ.get('PATH', '')}",
        USER=MOCK_USERNAME,
    )
    return env, dest_dir, mock_bin
