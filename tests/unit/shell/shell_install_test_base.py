"""Shared InstallTestBase fixture for install.sh unit tests."""

from __future__ import annotations

import os
import shutil
import tempfile
import unittest
from pathlib import Path

from tests.unit.shell.shell_test_utils import (
    PROJECT_ROOT,
    bind_unix_socket,
    setup_mock_install_tree,
    write_stubs,
)


class InstallTestBase(unittest.TestCase):
    """Shared fixture setup for install.sh unit tests."""

    def setUp(self):
        """Create a temp DESTDIR tree and install.sh path for each test."""
        self.repo_root = PROJECT_ROOT
        self.script_path = self.repo_root / "install.sh"
        self.tmp_dir = tempfile.mkdtemp()
        self.dest_dir, self.bin_dir, self.sys_dir, self.hook_dir = setup_mock_install_tree(self.tmp_dir)

    def tearDown(self):
        """Remove the temp directory created in setUp."""
        shutil.rmtree(self.tmp_dir, ignore_errors=True)

    def _setup_mock_sound_hardware(self, environment: dict) -> None:
        """Mock /proc/asound and /dev/snd for sound hardware detection."""
        root = Path(self.tmp_dir)
        codec = root / "proc" / "asound" / "card0" / "codec#0"
        codec.parent.mkdir(parents=True, exist_ok=True)
        codec.write_text("Codec: Realtek ALC294\n", encoding="utf-8")
        (root / "dev" / "snd").mkdir(parents=True, exist_ok=True)
        (root / "dev" / "snd" / "hwC0D0").write_text("", encoding="utf-8")
        environment["PROC_ASOUND_ROOT"] = str(root / "proc" / "asound")
        environment["DEV_SND_ROOT"] = str(root / "dev" / "snd")

    def _write_stubs(self, stubs: dict[str, str], mock_bin: Path | None = None) -> Path:
        """Write executable stubs into mock-bin and return that directory."""
        if mock_bin is None:
            mock_bin = Path(self.tmp_dir) / "mock-bin"
        return write_stubs(stubs, mock_bin)

    def _build_install_env(self, choice: str | None = "WMI TOUCHPAD", skip_root: str = "1"):
        """Build a common DESTDIR install environment for installer unit tests."""
        environment = os.environ.copy()
        environment.pop("BUS_ROOT", None)
        environment["ASUS_TEST_MODE"] = "1"
        environment["SKIP_ROOT_CHECK"] = skip_root
        environment["SKIP_PKG_INSTALL"] = "1"
        if choice is None:
            environment.pop("NONINTERACTIVE_CHOICE", None)
        else:
            environment["NONINTERACTIVE_CHOICE"] = choice
        environment["DESTDIR"] = str(self.dest_dir)
        environment["SYSTEMCTL_CMD"] = "true"
        environment["INSTALL_ASSUME_UNIT_ACTIVE"] = "1"
        environment["PATH"] = f"{self._ensure_test_msgfmt_bin()}:{environment.get('PATH', '')}"
        return environment

    def _ensure_test_msgfmt_bin(self) -> str:
        """Provide a fast msgfmt stub so DESTDIR installs do not require host gettext."""
        mock_bin = Path(self.tmp_dir) / "msgfmt-bin"
        mock_bin.mkdir(parents=True, exist_ok=True)
        stub = mock_bin / "msgfmt"
        if not stub.exists():
            stub.write_text(
                "#!/bin/sh\n"
                "out=''\n"
                "while [ $# -gt 0 ]; do\n"
                '  case "$1" in\n'
                "    -o) out=$2; shift 2 ;;\n"
                "    --check|--check-format) shift ;;\n"
                "    *) shift ;;\n"
                "  esac\n"
                "done\n"
                '[ -n "$out" ] || exit 1\n'
                ': > "$out"\n',
                encoding="utf-8",
            )
            stub.chmod(0o755)
        return str(mock_bin)

    def _setup_dbus_session_socket(self, uid: str | int = "1000") -> Path:
        """Create a session D-Bus socket path under tmp_dir for installer tests."""
        bus_root = Path(self.tmp_dir) / "dbus" / str(uid)
        bus_root.mkdir(parents=True, exist_ok=True)
        bus_path = bus_root / "bus"
        if bus_path.exists():
            bus_path.unlink()
        bind_unix_socket(bus_path)
        return bus_path

    def _setup_gnome_session_stubs(self, environment: dict, sudo_script_body: str) -> Path:
        """Create loginctl/sudo/id stubs for GNOME-path tests."""
        mock_bin = self._write_stubs(
            {
                "loginctl": (
                    "#!/bin/sh\n"
                    'if [ "$1" = "list-sessions" ]; then\n'
                    "  echo '1'\n"
                    "  exit 0\n"
                    "fi\n"
                    'if [ "$1" = "show-session" ]; then\n'
                    '  if [ "$2" = "1" ]; then\n'
                    '    case "$3" in\n'
                    "      -p)\n"
                    '        case "$4" in\n'
                    "          Type) echo 'wayland' ;;\n"
                    "          State) echo 'active' ;;\n"
                    "          Name) echo 'testuser' ;;\n"
                    "          Seat) echo 'seat0' ;;\n"
                    "        esac\n"
                    "        ;;\n"
                    "    esac\n"
                    "  fi\n"
                    "fi\n"
                    "exit 0\n"
                ),
                "sudo": sudo_script_body,
                "id": ('#!/bin/sh\nif [ "$1" = "-u" ]; then\n  echo 1000\n  exit 0\nfi\nexit 0\n'),
            }
        )

        environment["PATH"] = f"{mock_bin}:{environment['PATH']}"
        return mock_bin

    def _setup_gnome_install_stubs(self, environment: dict) -> Path:
        """GNOME install stubs with passthrough privilege drop and session bus."""
        mock_bin = self._setup_gnome_session_stubs(
            environment,
            "#!/bin/sh\n"
            "while [ $# -gt 0 ]; do\n"
            '  case "$1" in\n'
            "    -n) shift ;;\n"
            "    -u) shift 2 ;;\n"
            "    -E) shift ;;\n"
            "    --) shift; break ;;\n"
            '    *=*) export "$1"; shift ;;\n'
            "    *) break ;;\n"
            "  esac\n"
            "done\n"
            'exec "$@"\n',
        )
        self._setup_dbus_session_socket()
        self._write_stubs(
            {
                "gsettings": (
                    "#!/bin/sh\n"
                    'if [ "$1" = "get" ]; then\n'
                    "  echo '[]'\n"
                    "  exit 0\n"
                    "fi\n"
                    'if [ "$1" = "list-keys" ]; then\n'
                    "  printf '%s\\n' 'show-screenshot-ui' 'control-center'"
                    " 'custom-keybindings'\n"
                    "  exit 0\n"
                    "fi\n"
                    "exit 0\n"
                ),
                "hda-verb": "#!/bin/sh\nexit 0\n",
                "getent": (
                    "#!/bin/sh\n"
                    'if [ "$1" = "passwd" ] && [ "$2" = "testuser" ]; then\n'
                    '  echo "testuser:x:1000:1000:testuser:/home/testuser:/bin/sh"\n'
                    "  exit 0\n"
                    "fi\n"
                    "exit 1\n"
                ),
                "runuser": (
                    "#!/bin/sh\n"
                    "while [ $# -gt 0 ]; do\n"
                    '  case "$1" in\n'
                    "    -u) shift 2 ;;\n"
                    "    --) shift; break ;;\n"
                    "    *) shift ;;\n"
                    "  esac\n"
                    "done\n"
                    'exec "$@"\n'
                ),
                "gnome-extensions": "#!/bin/sh\nexit 0\n",
            },
            mock_bin=mock_bin,
        )
        environment["DBUS_BUS_ROOT"] = str(Path(self.tmp_dir) / "dbus")
        environment["ASUS_DESKTOP_FAMILY"] = "gnome"
        return mock_bin

    def _setup_sound_install_stubs(self, environment: dict) -> None:
        """Mock sound hardware nodes and hda-verb for SOUND component installs."""
        self._setup_mock_sound_hardware(environment)
        mock_bin = self._write_stubs({"hda-verb": "#!/bin/sh\nexit 0\n"})
        environment["PATH"] = f"{mock_bin}:{environment['PATH']}"

    def _prepend_apt_stubs(self, environment: dict, *, dpkg_query_exit: int) -> None:
        """Prepend apt/apt-get/dpkg stubs; dpkg -s exit controls 'already installed'."""
        mock_bin = self._write_stubs(
            {
                "apt": "#!/bin/sh\nexit 0\n",
                "apt-get": "#!/bin/sh\nexit 0\n",
                "dpkg": f'#!/bin/sh\nif [ "$1" = "-s" ]; then exit {dpkg_query_exit}; fi\nexit 0\n',
            }
        )
        environment["PATH"] = f"{mock_bin}:{environment['PATH']}"
