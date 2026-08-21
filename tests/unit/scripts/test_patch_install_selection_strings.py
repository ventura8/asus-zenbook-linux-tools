"""Unit tests for install-selection gettext spacing helpers."""

from __future__ import annotations

import unittest

from tests.unit.bin.attr_helpers import call_attr
from tests.unit.scripts.script_module_loader import load_scripts_module

_SPACING = load_scripts_module(
    "patch_install_selection_spacing",
    ("scripts", "i18n", "patch_install_selection_spacing.py"),
)
_PATCHER = load_scripts_module(
    "patch_install_selection_strings",
    ("scripts", "i18n", "patch_install_selection_strings.py"),
)

AMHARIC_OBSOLETE = "ምንም ክፍሎች አልተመረጡም። መጫኑ ተሰርዟል።"
ARABIC_GLUED = "اختيار غير صالح: %s. أدخل أرقامًا (1,2,3,4) أو أسماء مكوّنات أو all, أوnone."


class TestInstallSelectionSpacing(unittest.TestCase):
    """Keep all/none tokens and sentence prefixes readable after patching."""

    def test_split_prefix_keeps_space_after_amharic_separator(self) -> None:
        """Obsolete Ethiopic full stop must retain the following space."""
        prefix = call_attr(_PATCHER, "_split_prefix", AMHARIC_OBSOLETE)
        self.assertTrue(prefix.endswith("። "))
        self.assertIn("ምንም ክፍሎች አልተመረጡም። ", prefix)

    def test_localize_or_spaces_arabic_none(self) -> None:
        """Localized *or* must stay separated from the none token."""
        spaced = call_attr(_SPACING, "localize_or", ARABIC_GLUED, "ar", "أو")
        self.assertIn("أو none", spaced)
        self.assertNotIn("أوnone", spaced)

    def test_ensure_none_does_not_treat_ornone_as_none_token(self) -> None:
        """Glued ornone is not a completed none option."""
        self.assertFalse(call_attr(_SPACING, "has_none_token", "ornone"))
        self.assertEqual(call_attr(_SPACING, "ensure_none", "all"), "all, or none")

    def test_normalize_english_ornone(self) -> None:
        """English invalid-selection text must render or none, not ornone."""
        text = "Invalid selection: %s. Enter numbers (1,2,3,4), component names, all, ornone."
        normalized = call_attr(_SPACING, "normalize_selection_text", text, "en", "or")
        self.assertIn("or none", normalized)
        self.assertNotIn("ornone", normalized)

    def test_quoted_all_none_keep_inner_spacing(self) -> None:
        """Quoted all/none tokens must not gain an inner space."""
        text = "Press Enter, or enter 'all' or 'none'."
        normalized = call_attr(_SPACING, "normalize_selection_text", text, "en", "or")
        self.assertIn("'all'", normalized)
        self.assertIn("'none'", normalized)
        self.assertNotIn("' all'", normalized)
        self.assertNotIn("' none'", normalized)
        self.assertNotIn("'none' .", normalized)

    def test_latin_connector_not_glued_to_next_word(self) -> None:
        """Localized or must not merge into the following Latin word."""
        glued = "ousaisissez 'all' ou 'none'."
        spaced = call_attr(_SPACING, "localize_or", glued, "fr", "ou")
        self.assertIn("ou saisissez", spaced)
        self.assertNotIn("ousaisissez", spaced)

    def test_latin_connector_before_unicode_letter(self) -> None:
        """Connectors must split from following letters such as Lithuanian į."""
        glued = "arbaįveskite 'all' arba 'none'."
        spaced = call_attr(_SPACING, "localize_or", glued, "lt", "arba")
        self.assertIn("arba įveskite", spaced)
        self.assertNotIn("arbaįveskite", spaced)
