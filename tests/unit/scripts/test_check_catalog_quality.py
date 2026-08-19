"""Unit tests for gettext catalog completeness and artifact detection."""

from __future__ import annotations

import subprocess
import unittest

from tests.unit.bin.attr_helpers import call_attr
from tests.unit.scripts.script_module_loader import load_scripts_module

_CATALOG = load_scripts_module(
    "check_catalog_quality",
    ("scripts", "i18n", "check_catalog_quality.py"),
)


class TestCatalogCompleteness(unittest.TestCase):
    """Fail when any shipped catalog is empty, fuzzy, or English-copied."""

    def test_empty_translation_is_rejected(self) -> None:
        """Blank msgstr must fail the completeness gate."""
        entry = _CATALOG.PoEntry(msgid="Camera privacy", msgstr={0: ""})
        with self.assertRaises(ValueError) as raised:
            call_attr(_CATALOG, "_validate_entry", entry, "de")
        self.assertIn("empty translation", str(raised.exception))

    def test_fuzzy_entry_is_rejected(self) -> None:
        """Fuzzy entries are not considered filled in."""
        entry = _CATALOG.PoEntry(
            msgid="Camera privacy",
            msgstr={0: "Kameraprivatsphäre"},
            flags={"fuzzy"},
        )
        with self.assertRaises(ValueError) as raised:
            call_attr(_CATALOG, "_validate_entry", entry, "de")
        self.assertIn("fuzzy entry", str(raised.exception))

    def test_all_shipped_catalogs_are_complete(self) -> None:
        """Live po/*.po catalogs must pass the same gate as heavy lint."""
        try:
            call_attr(_CATALOG, "check_catalogs")
        except (
            OSError,
            RuntimeError,
            subprocess.CalledProcessError,
            ValueError,
        ) as error:
            self.fail(f"shipped catalogs are incomplete: {error}")


class TestTranslationArtifactDetection(unittest.TestCase):
    """Reject machine-translation junk that empty/placeholder checks miss."""

    def test_trailing_hash_continuation_is_artifact(self) -> None:
        """Trailing newline-hash continuations are invalid UI text."""
        self.assertTrue(call_attr(_CATALOG, "_translation_has_artifact", "Balanced", "Taurite\n#"))

    def test_hash_before_printf_placeholder_is_artifact(self) -> None:
        """A leading hash must not prefix printf placeholders."""
        self.assertTrue(
            call_attr(
                _CATALOG,
                "_translation_has_artifact",
                "%d external display",
                "#%d paparan luaran",
            )
        )

    def test_hash_at_junk_is_artifact(self) -> None:
        """Broken generators leave #@ / @# tokens in msgstr."""
        self.assertTrue(
            call_attr(
                _CATALOG,
                "_translation_has_artifact",
                "ASUS ZenBook Linux Setup %s",
                "ASUS ZenBook Linux Setup #@ # # %s #@ @# #",
            )
        )

    def test_gsm_hallucination_is_artifact(self) -> None:
        """Hallucinated GSM band lists are not valid setup titles."""
        self.assertTrue(
            call_attr(
                _CATALOG,
                "_translation_has_artifact",
                "ASUS ZenBook Linux Setup %s",
                "%s GSM 850 MHz (B5), GSM 900 MHz (B8)",
            )
        )

    def test_clean_translation_is_not_artifact(self) -> None:
        """Ordinary translated strings must pass the artifact gate."""
        self.assertFalse(
            call_attr(
                _CATALOG,
                "_translation_has_artifact",
                "ASUS ZenBook Linux Setup %s",
                "Setélan ASUS ZenBook Linux %s",
            )
        )

    def test_source_artifact_does_not_permit_extra_translation_artifact(self) -> None:
        """A source match must not clear a different extra artifact in msgstr."""
        # Source has one MHz token; translation adds MHz plus a trailing hash.
        self.assertTrue(
            call_attr(
                _CATALOG,
                "_translation_has_artifact",
                "Radio band 900 MHz",
                "Radio band 900 MHz\n#",
            )
        )
        # Equal counts for the same pattern remain allowed.
        self.assertFalse(
            call_attr(
                _CATALOG,
                "_translation_has_artifact",
                "Radio band 900 MHz",
                "Radio band 900 MHz",
            )
        )

    def test_plural_entry_uses_msgid_plural_for_artifact_check(self) -> None:
        """Plural msgstr forms pair with msgid / msgid_plural sources."""
        entry = _CATALOG.PoEntry(
            msgid="%d external display",
            msgid_plural="%d external displays",
            msgstr={0: "%d paparan luaran", 1: "#%d paparan luaran"},
        )
        with self.assertRaises(ValueError) as raised:
            call_attr(_CATALOG, "_validate_translation_artifacts", entry, "id")
        self.assertIn("translation artifact", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
