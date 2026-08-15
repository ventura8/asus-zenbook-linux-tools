"""Unit tests for gettext catalog artifact detection."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

from tests.unit.bin.attr_helpers import call_attr


def _load_catalog_quality():
    """Load check_catalog_quality.py from scripts/i18n without packaging it."""
    repo_root = Path(__file__).resolve().parents[3]
    module_path = repo_root / "scripts" / "i18n" / "check_catalog_quality.py"
    # seed_whisper_languages is imported as a sibling module.
    sys.path.insert(0, str(module_path.parent))
    spec = importlib.util.spec_from_file_location("check_catalog_quality", module_path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


_CATALOG = _load_catalog_quality()


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
