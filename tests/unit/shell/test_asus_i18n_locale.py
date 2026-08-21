"""Unit tests for lib/asus-i18n.sh locale resolution edge cases."""

from __future__ import annotations

import shlex
import shutil
import unittest
from pathlib import Path

from tests.unit.shell.shell_test_utils import run_bash_c


class TestAsusI18nLocaleResolution(unittest.TestCase):
    """Shell gettext helpers must treat empty locale env vars as unset."""

    def setUp(self) -> None:
        self.repo_root = Path(__file__).resolve().parents[3]
        self.i18n = self.repo_root / "lib" / "asus-i18n.sh"

    def test_empty_lc_messages_falls_back_to_lang(self) -> None:
        """An empty LC_MESSAGES export must not block LANG/LANGUAGE fallbacks."""
        proc = run_bash_c(
            (
                f"source {shlex.quote(str(self.i18n))}; "
                "_asus_resolve_ui_locale"
            ),
            env={
                "ASUS_TEST_MODE": "0",
                "LC_MESSAGES": "",
                "LANG": "de_DE.UTF-8",
                "LANGUAGE": "",
            },
            timeout=5,
            log_name="i18n-empty-lc-messages-resolve",
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + proc.stdout)
        self.assertEqual(proc.stdout.strip(), "de_DE.UTF-8")

    def test_lc_all_precedence_over_lc_messages(self) -> None:
        """Process locale lookup must honor LC_ALL before LC_MESSAGES."""
        proc = run_bash_c(
            (
                f"source {shlex.quote(str(self.i18n))}; "
                "_asus_resolve_ui_locale"
            ),
            env={
                "ASUS_TEST_MODE": "0",
                "LC_ALL": "fr_FR.UTF-8",
                "LC_MESSAGES": "de_DE.UTF-8",
                "LANG": "en_US.UTF-8",
            },
            timeout=5,
            log_name="i18n-lc-all-precedence",
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + proc.stdout)
        self.assertEqual(proc.stdout.strip(), "fr_FR.UTF-8")

    def test_session_lc_all_precedence_over_lc_messages(self) -> None:
        """Session UI language must honor LC_ALL before LC_MESSAGES."""
        proc = run_bash_c(
            (
                "asus_session_env_value() { "
                'local key="$1"; local value="${!key-}"; '
                'value="${value#"${value%%[![:space:]]*}"}"; '
                'value="${value%"${value##*[![:space:]]}"}"; '
                '[ -n "$value" ] || return 1; printf "%s\\n" "$value"; '
                "}; "
                f"source {shlex.quote(str(self.i18n))}; "
                "_asus_first_session_ui_language"
            ),
            env={
                "ASUS_TEST_MODE": "0",
                "LC_ALL": "fr_FR.UTF-8",
                "LC_MESSAGES": "de_DE.UTF-8",
                "LANG": "en_US.UTF-8",
            },
            timeout=5,
            log_name="i18n-session-lc-all-precedence",
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + proc.stdout)
        self.assertEqual(proc.stdout.strip(), "fr_FR.UTF-8")

    def test_malformed_locale_suffix_falls_back_to_c_utf8(self) -> None:
        """Locales with empty charset or modifier suffix must not reach setlocale."""
        proc = run_bash_c(
            (
                f"source {shlex.quote(str(self.i18n))}; "
                "_asus_lc_messages_for_gettext de_DE. de"
            ),
            env={},
            timeout=5,
            log_name="i18n-malformed-locale-dot",
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + proc.stdout)
        self.assertEqual(proc.stdout.strip(), "C.UTF-8")

        proc_at = run_bash_c(
            (
                f"source {shlex.quote(str(self.i18n))}; "
                "_asus_lc_messages_for_gettext de_DE@ de"
            ),
            env={},
            timeout=5,
            log_name="i18n-malformed-locale-at",
        )
        self.assertEqual(proc_at.returncode, 0, msg=proc_at.stderr + proc_at.stdout)
        self.assertEqual(proc_at.stdout.strip(), "C.UTF-8")

    def test_non_utf8_env_locale_is_rejected(self) -> None:
        """A non-UTF-8 env locale (e.g. ro_RO.ISO-8859-2) must not be returned as-is."""
        proc = run_bash_c(
            (
                f"source {shlex.quote(str(self.i18n))}; "
                "_asus_utf8_locale_for_language ro"
            ),
            env={
                "ASUS_TEST_MODE": "0",
                "LC_ALL": "ro_RO.ISO-8859-2",
                "LC_MESSAGES": "",
                "LANG": "",
            },
            timeout=5,
            log_name="i18n-non-utf8-env-locale-rejected",
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + proc.stdout)
        result = proc.stdout.strip()
        self.assertNotEqual(result, "ro_RO.ISO-8859-2")
        self.assertTrue(
            result.endswith(("UTF-8", "utf8")),
            msg=f"expected a UTF-8 locale fallback, got: {result!r}",
        )

    def test_bare_language_resolves_gettext_env(self) -> None:
        """Bare LANGUAGE=ro must normalize to ro with a valid LC_MESSAGES locale."""
        proc = run_bash_c(
            (
                f"source {shlex.quote(str(self.i18n))}; "
                "_asus_gettext_env"
            ),
            env={
                "ASUS_TEST_MODE": "0",
                "LC_ALL": "",
                "LC_MESSAGES": "",
                "LANG": "",
                "LANGUAGE": "ro",
            },
            timeout=5,
            log_name="i18n-bare-ro-gettext-env",
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + proc.stdout)
        lines = [line for line in proc.stdout.splitlines() if line.strip()]
        self.assertEqual(len(lines), 2, msg=lines)
        self.assertEqual(lines[0], "ro")
        self.assertNotEqual(lines[1], "")
        self.assertNotEqual(lines[1], "ro")

    def test_gettext_with_empty_lc_messages_avoids_setlocale_warning(self) -> None:
        """gettext subprocess must not receive an empty LC_MESSAGES value."""
        if not shutil.which("gettext"):
            self.skipTest("gettext unavailable")
        proc = run_bash_c(
            (
                f"source {shlex.quote(str(self.i18n))}; "
                "ASUS_I18N_FORCE_MSGID=0 _asus_gettext 'Hello'"
            ),
            env={
                "ASUS_TEST_MODE": "0",
                "LC_MESSAGES": "",
                "LANG": "",
                "LANGUAGE": "",
            },
            timeout=5,
            log_name="i18n-empty-lc-messages-gettext",
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + proc.stdout)
        self.assertEqual(proc.stdout, "Hello")
        self.assertNotIn("setlocale", proc.stderr)
        self.assertNotIn("cannot change locale", proc.stderr)


if __name__ == "__main__":
    unittest.main()
