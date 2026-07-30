"""Unit tests for install.sh package-manager command resolution."""

import os
import shlex
import shutil
import subprocess
import unittest
from pathlib import Path

from tests.unit.shell.shell_install_test_base import InstallTestBase
from tests.unit.shell.shell_test_utils import run_bash_c

_PKG_MANAGER_SPECS = {
    "apt": {
        "os_id": "ubuntu",
        "stubs": {
            "apt-get": "#!/bin/sh\nexit 0\n",
            "apt": "#!/bin/sh\nexit 0\n",
            "dpkg": '#!/bin/sh\nif [ "$1" = "-s" ]; then exit 1; fi\nexit 0\n',
        },
    },
    "zypper": {
        "os_id": "opensuse",
        "stubs": {
            "zypper": "#!/bin/sh\nexit 0\n",
            "rpm": "#!/bin/sh\nexit 1\n",
        },
    },
    "dnf": {
        "os_id": "fedora",
        "stubs": {
            "dnf": "#!/bin/sh\nexit 0\n",
            "rpm": "#!/bin/sh\nexit 1\n",
        },
    },
    "pacman": {
        "os_id": "arch",
        "stubs": {
            "pacman": '#!/bin/sh\nif [ "$1" = "-Q" ]; then exit 1; fi\nexit 0\n',
        },
    },
}


class TestInstallPkgCmd(InstallTestBase):
    """pkg_installer_cmd resolution across apt/zypper/dnf/pacman."""

    def _prepare_mock_pkg_tools(self, package_manager: str) -> dict:
        """Create mock package-manager binaries and environment for a test case."""
        if package_manager not in _PKG_MANAGER_SPECS:
            raise ValueError(f"unsupported package manager {package_manager}")
        mock_bin = Path(self.tmp_dir) / f"mock-bin-{package_manager}"
        environment = os.environ.copy()
        spec = _PKG_MANAGER_SPECS[package_manager]
        environment["INSTALL_OS_ID"] = spec["os_id"]
        self._write_mock_pkg_binaries(mock_bin, package_manager)
        environment["PATH"] = f"{mock_bin}:{environment['PATH']}"

        return environment

    def _write_mock_pkg_binaries(self, mock_bin: Path, package_manager: str) -> None:
        """Write the specific mocked package-manager binaries for the selected backend."""
        self._write_stubs(_PKG_MANAGER_SPECS[package_manager]["stubs"], mock_bin=mock_bin)

    def _run_bash_pkg_installer_cmd(self, environment: dict) -> subprocess.CompletedProcess[str]:
        """Source install-os-detection.sh and run pkg_installer_cmd in a bash subshell."""
        os_detect = shlex.quote(str(self.repo_root / "lib" / "install-os-detection.sh"))
        return run_bash_c(f"set -e; source {os_detect}; pkg_installer_cmd", env=environment, timeout=10)

    def _run_pkg_installer_cmd(
        self, package_manager: str, os_id: str | None = None
    ) -> subprocess.CompletedProcess[str]:
        """Return the package-manager install command selected by install.sh."""
        environment = self._prepare_mock_pkg_tools(package_manager)
        if os_id is not None:
            environment["INSTALL_OS_ID"] = os_id
        return self._run_bash_pkg_installer_cmd(environment)

    def test_ubuntu_package_manager_detection_prefers_apt(self):
        """Ubuntu requests ydotool via apt; pure Debian skips unpackaged ydotool."""
        cases = (
            ("apt", None, ("apt-get", "ydotool"), ()),
            ("apt", "debian", ("xdotool",), ("ydotool",)),
        )
        for backend, os_id, must_include, must_exclude in cases:
            with self.subTest(backend=backend, os_id=os_id):
                proc = self._run_pkg_installer_cmd(backend, os_id=os_id)
                self.assertEqual(proc.returncode, 0, msg=proc.stderr)
                for token in must_include:
                    self.assertIn(token, proc.stdout)
                for token in must_exclude:
                    self.assertNotIn(token, proc.stdout)

    def test_opensuse_package_manager_detection_uses_zypper(self):
        """SUSE-style installs select zypper commands."""
        proc = self._run_pkg_installer_cmd("zypper")
        self.assertEqual(proc.returncode, 0)
        self.assertIn("zypper", proc.stdout)
        self.assertRegex(proc.stdout, r"python3\d+-evdev|python3-evdev")
        self.assertRegex(proc.stdout, r"python3\d+-gobject|python3-gobject")

    def test_opensuse_skips_unpackaged_ydotool(self):
        """Leap-like zypper: do not request ydotool when search finds no provider."""
        environment = self._prepare_mock_pkg_tools("zypper")
        mock_bin = Path(environment["PATH"].split(":", 1)[0])
        zypper = mock_bin / "zypper"
        zypper.write_text(
            "#!/bin/sh\n"
            'if [ "$1" = "--non-interactive" ] && [ "$2" = "search" ]; then\n'
            '  case " $* " in\n'
            '    *" ydotool "*) exit 1 ;;\n'
            "  esac\n"
            "fi\n"
            "exit 0\n",
            encoding="utf-8",
        )
        zypper.chmod(0o755)
        proc = self._run_bash_pkg_installer_cmd(environment)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertIn("zypper", proc.stdout)
        self.assertNotIn("ydotool", proc.stdout)

    def test_fedora_package_manager_detection_uses_dnf(self):
        """Fedora-like installs select dnf and still request ydotool."""
        proc = self._run_pkg_installer_cmd("dnf")
        self.assertEqual(proc.returncode, 0)
        self.assertIn("dnf install -y", proc.stdout)
        self.assertIn("ydotool", proc.stdout)

    def test_arch_package_manager_detection_uses_pacman(self):
        """Arch-like installs select pacman and Arch package names."""
        proc = self._run_pkg_installer_cmd("pacman")
        self.assertEqual(proc.returncode, 0)
        self.assertIn("pacman -S --noconfirm", proc.stdout)
        self.assertIn("python", proc.stdout.split())
        self.assertIn("python-evdev", proc.stdout)

    @staticmethod
    def _symlink_one_required_bin(mock_bin: Path, name: str) -> None:
        """Symlink one host binary into *mock_bin*, skipping existing links."""
        src = shutil.which(name)
        missing = src is None or not Path(src).exists()
        if missing:
            raise AssertionError(f"Required test dependency not found in PATH: {name}")
        link = mock_bin / name
        if link.exists() or link.is_symlink():
            return
        link.symlink_to(src)

    def _symlink_required_bins(self, mock_bin: Path, names: tuple[str, ...]) -> None:
        """Symlink required host binaries into an isolated mock PATH directory."""
        for name in names:
            self._symlink_one_required_bin(mock_bin, name)

    def test_no_supported_package_manager_returns_empty_command(self):
        """Skip path when no supported package manager is present."""
        environment = os.environ.copy()
        environment["INSTALL_OS_ID"] = "unknown"
        mock_bin = Path(self.tmp_dir) / "mock-bin"
        mock_bin.mkdir(parents=True, exist_ok=True)
        # Isolated PATH: only mock-bin (no /bin → /usr/bin merge exposing apt/dnf).
        self._symlink_required_bins(
            mock_bin,
            ("bash", "cat", "grep", "sed", "mktemp", "mkdir", "rm", "mv", "dirname", "pwd"),
        )
        environment["PATH"] = str(mock_bin)
        proc = self._run_bash_pkg_installer_cmd(environment)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, "")
        self._assert_no_pkg_installer_report(environment)

    def _assert_no_pkg_installer_report(self, environment):
        """Assert `_report_no_pkg_installer` names unknown OS or missing managers."""
        os_detect = shlex.quote(str(self.repo_root / "lib" / "install-os-detection.sh"))
        report_env = environment.copy()
        report_env["ASUS_OS_DETECTION_SKIP_INIT"] = "1"
        report = run_bash_c(
            f"set -e; source {os_detect}; _report_no_pkg_installer",
            env=report_env,
            timeout=10,
        )
        combined = f"{report.stdout}\n{report.stderr}"
        unknown = "Unrecognized INSTALL_OS_ID=unknown" in combined
        missing = "No supported package manager detected" in combined
        self.assertTrue(unknown or missing, msg=combined)


if __name__ == "__main__":
    unittest.main()
