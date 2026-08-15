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
                "  case \"$1\" in\n"
                "    -o) out=$2; shift 2 ;;\n"
                "    --check|--check-format) shift ;;\n"
                "    *) shift ;;\n"
                "  esac\n"
                "done\n"
                "[ -n \"$out\" ] || exit 1\n"
                ": > \"$out\"\n",
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
