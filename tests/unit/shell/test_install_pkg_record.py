"""Unit tests for installer package recording used by uninstall dependency removal."""

import shlex
import unittest

from tests.unit.shell.shell_install_test_base import InstallTestBase
from tests.unit.shell.shell_test_utils import run_shell_script


class TestInstallPackageRecording(InstallTestBase):
    """Verify install.sh records newly installed packages for later uninstall."""

    def test_install_records_missing_packages_for_uninstall(self):
        """Verify successful dependency install writes packages into STATE_DIR for uninstall."""
        environment = self._build_install_env("WMI")
        environment["SKIP_PKG_INSTALL"] = "0"
        environment["INSTALL_OS_ID"] = "ubuntu"
        environment["INSTALL_OS_ID_LIKE"] = "debian"
        pkg_flag = self.dest_dir / "var/lib/asus-zenbook-linux-tools/.deps-installed"
        environment["ASUS_TEST_DPKG_INSTALLED_FLAG"] = str(pkg_flag)
        mock_bin = self._write_stubs(
            {
                "apt": "#!/bin/sh\nexit 0\n",
                "apt-get": (
                    f"#!/bin/sh\n"
                    f'case "$*" in\n'
                    f"  *install*) mkdir -p {shlex.quote(str(pkg_flag.parent))} && "
                    f"touch {shlex.quote(str(pkg_flag))} ;;\n"
                    f"esac\n"
                    f"exit 0\n"
                ),
                "dpkg": (
                    "#!/bin/sh\n"
                    'if [ "$1" = "-s" ]; then\n'
                    '  if [ "$2" = "ydotool" ]; then exit 0; fi\n'
                    '  if [ -f "${ASUS_TEST_DPKG_INSTALLED_FLAG:-}" ]; then\n'
                    '    case "$2" in\n'
                    "      python3-evdev|python3-gi|gettext|alsa-tools|alsa-utils|xdotool) exit 0 ;;\n"
                    "    esac\n"
                    "  fi\n"
                    "  exit 1\n"
                    "fi\n"
                    "exit 0\n"
                ),
                "dpkg-query": (
                    "#!/bin/sh\n"
                    'if [ "$1" = "-W" ]; then\n'
                    '  pkg=""\n'
                    '  for arg in "$@"; do pkg="$arg"; done\n'
                    '  if [ "$pkg" = "ydotool" ]; then echo installed; exit 0; fi\n'
                    '  if [ -f "${ASUS_TEST_DPKG_INSTALLED_FLAG:-}" ]; then\n'
                    '    case "$pkg" in\n'
                    "      python3-evdev|python3-gi|gettext|alsa-tools|alsa-utils|xdotool)\n"
                    "        echo installed; exit 0 ;;\n"
                    "    esac\n"
                    "  fi\n"
                    "  exit 1\n"
                    "fi\n"
                    "exit 0\n"
                ),
            }
        )
        environment["PATH"] = f"{mock_bin}:{environment['PATH']}"

        proc = run_shell_script(self.script_path, env=environment, timeout=20)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        record = self.dest_dir / "var/lib/asus-zenbook-linux-tools" / "installed-packages"
        self.assertTrue(record.is_file(), proc.stdout)
        recorded = record.read_text(encoding="utf-8")
        self.assertIn("python3-evdev", recorded)
        self.assertNotIn("ydotool", recorded)
        self.assertNotRegex(recorded, r"(^|[\s/])python3([\s]|$)")


if __name__ == "__main__":
    unittest.main()
