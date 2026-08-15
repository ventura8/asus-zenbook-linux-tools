"""Unit tests for bin/asus_i18n.py."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from bin import asus_i18n
from tests.unit.bin.attr_helpers import call_attr


class TestAsusI18n(unittest.TestCase):
    """Validate gettext locale resolution for Python UI surfaces."""

    def test_test_mode_language_overrides_session(self) -> None:
        """Test-only ASUS_UI_LANG wins over session locale variables."""
        with mock.patch.dict(
            os.environ,
            {"ASUS_TEST_MODE": "1", "ASUS_UI_LANG": "ro", "LC_MESSAGES": "en_US.UTF-8"},
            clear=False,
        ):
            self.assertEqual(asus_i18n.gettext_message("Unknown msgid"), "Unknown msgid")

    def test_session_locale_is_used_without_test_override(self) -> None:
        """Session locale drives catalog lookup when no test override is set."""
        with mock.patch.dict(
            os.environ,
            {"ASUS_TEST_MODE": "0", "LC_MESSAGES": "de_DE.UTF-8"},
            clear=False,
        ):
            self.assertEqual(asus_i18n.gettext_message("Unknown msgid"), "Unknown msgid")

    def test_invalid_locale_falls_back_to_english_msgids(self) -> None:
        """Missing catalogs keep the English source strings."""
        self.assertEqual(asus_i18n.gettext_message("Message"), "Message")
        self.assertEqual(asus_i18n.pgettext_message("context", "Message"), "Message")
        self.assertEqual(asus_i18n.ngettext_message("one item", "many items", 2), "many items")

    def test_normalize_language_aliases_and_invalid(self) -> None:
        """jv maps to jw; non-alpha tokens fall back to English."""
        self.assertEqual(call_attr(asus_i18n, "_normalize_language", "jv_ID.UTF-8"), "jw")
        self.assertEqual(call_attr(asus_i18n, "_normalize_language", "!!!"), "en")

    def test_translation_continues_after_missing_catalog(self) -> None:
        """FileNotFoundError/OSError for a locale dir falls through to NullTranslations."""
        with (
            mock.patch("gettext.translation", side_effect=FileNotFoundError),
            mock.patch.dict(os.environ, {"TEXTDOMAINDIR": "/missing-locale-$$"}, clear=False),
        ):
            self.assertEqual(asus_i18n.gettext_message("Hello"), "Hello")

    def test_catalog_translation_when_present(self) -> None:
        """Compiled catalogs translate known msgids for the active locale."""
        with tempfile.TemporaryDirectory(prefix="asus-i18n-test-") as temporary:
            catalog_dir = Path(temporary) / "ro" / "LC_MESSAGES"
            catalog_dir.mkdir(parents=True)
            po_path = Path(__file__).resolve().parents[3] / "po" / "ro.po"
            if not po_path.is_file():
                self.skipTest("Romanian catalog unavailable in checkout")
            if not shutil.which("msgfmt"):
                self.skipTest("gettext msgfmt unavailable")
            subprocess.run(
                [
                    "msgfmt",
                    "-o",
                    str(catalog_dir / "asus-zenbook-linux-tools.mo"),
                    str(po_path),
                ],
                check=True,
            )
            with mock.patch.dict(
                os.environ,
                {
                    "ASUS_TEST_MODE": "1",
                    "ASUS_UI_LANG": "ro",
                    "TEXTDOMAINDIR": temporary,
                },
                clear=False,
            ):
                self.assertEqual(asus_i18n.gettext_message("Balanced"), "Echilibrat")


if __name__ == "__main__":
    unittest.main()
