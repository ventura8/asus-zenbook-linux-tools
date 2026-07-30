"""Unit tests for installer VERSION single-source-of-truth helpers."""

import shlex
import tomllib
import unittest

from tests.unit.shell.shell_install_test_base import InstallTestBase
from tests.unit.shell.shell_test_utils import run_bash_c, run_shell_script


class TestInstallVersionBanner(InstallTestBase):
    """Verify setup banner reads VERSION and keeps poetry metadata in sync."""

    def test_setup_banner_shows_version_from_version_file(self):
        """Installer startup banner should display v-prefixed VERSION contents."""
        expected = (self.repo_root / "VERSION").read_text(encoding="utf-8").strip()
        proc = run_shell_script(self.script_path, env=self._build_install_env("WMI"), timeout=20)
        self.assertEqual(proc.returncode, 0)
        self.assertIn("ASUS ZenBook Linux Setup", proc.stdout)
        self.assertIn(f"v{expected}", proc.stdout)

    def test_format_display_version_helper(self):
        """Shared helper should format VERSION as a display tag."""
        shared = self.repo_root / "lib" / "install-shared.sh"
        expected = (self.repo_root / "VERSION").read_text(encoding="utf-8").strip()
        proc = run_bash_c(
            f"source {shlex.quote(str(shared))}; _format_display_version",
            timeout=5,
            log_name="format-display-version",
        )
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), f"v{expected}")

    def test_tui_title_and_message_include_version(self):
        """Selection TUI title and body should include the release version."""
        shared = self.repo_root / "lib" / "install-shared.sh"
        i18n = self.repo_root / "lib" / "asus-i18n.sh"
        selection = self.repo_root / "lib" / "install-selection.sh"
        expected = (self.repo_root / "VERSION").read_text(encoding="utf-8").strip()
        display = f"v{expected}"
        proc = run_bash_c(
            (
                f"source {shlex.quote(str(shared))}; "
                f"source {shlex.quote(str(i18n))}; "
                f"source {shlex.quote(str(selection))}; "
                "_tui_selection_title; echo '---'; _tui_selection_message"
            ),
            timeout=5,
            log_name="tui-version-text",
        )
        self.assertEqual(proc.returncode, 0)
        self.assertIn(f"ASUS ZenBook Linux Setup {display}", proc.stdout)
        self.assertIn("Space selects a component. Enter confirms. Esc cancels.", proc.stdout)

    def test_tui_scripted_selection_sets_install_choice(self):
        """Scripted ncurses TUI should apply selected component tags."""
        shared = self.repo_root / "lib" / "install-shared.sh"
        i18n = self.repo_root / "lib" / "asus-i18n.sh"
        selection = self.repo_root / "lib" / "install-selection.sh"
        proc = run_bash_c(
            (
                f"source {shlex.quote(str(shared))}; "
                f"source {shlex.quote(str(i18n))}; "
                f"source {shlex.quote(str(selection))}; "
                "ASUS_TUI_SCRIPT_KEYS=$'\\n' ASUS_DESKTOP_FAMILY=gnome "
                "_prompt_tui_selection 0 1; "
                'printf "choice=%s\\n" "$INSTALL_CHOICE"'
            ),
            timeout=10,
            log_name="tui-scripted-selection",
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + proc.stdout)
        self.assertIn("WMI", proc.stdout)
        self.assertIn("choice=", proc.stdout)

    def test_version_matches_pyproject(self):
        """VERSION file must match tool.poetry.version in pyproject.toml."""
        file_version = (self.repo_root / "VERSION").read_text(encoding="utf-8").strip()
        with (self.repo_root / "pyproject.toml").open("rb") as handle:
            poetry_version = tomllib.load(handle)["tool"]["poetry"]["version"]
        self.assertEqual(file_version, poetry_version)


if __name__ == "__main__":
    unittest.main()
