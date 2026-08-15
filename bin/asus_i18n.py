"""GNU gettext helpers shared by Python UI surfaces."""

from __future__ import annotations

import gettext
import os
from pathlib import Path

TEXTDOMAIN = "asus-zenbook-linux-tools"


def _normalize_language(value: str) -> str:
    """Return a gettext catalog code from a locale or LANGUAGE value."""
    language = value.split(":", maxsplit=1)[0]
    language = language.split(".", maxsplit=1)[0]
    language = language.split("@", maxsplit=1)[0]
    language = language.split("_", maxsplit=1)[0].lower()
    if language == "jv":
        return "jw"
    if language.isalpha() and 2 <= len(language) <= 3:
        return language
    return "en"


def _test_ui_language() -> str | None:
    if os.environ.get("ASUS_TEST_MODE") == "1" and os.environ.get("ASUS_UI_LANG"):
        return os.environ["ASUS_UI_LANG"]
    return None


def _session_ui_language() -> str:
    return os.environ.get("LC_MESSAGES") or os.environ.get("LANG") or os.environ.get("LANGUAGE") or "en"


def _requested_locale() -> str:
    """Resolve the current UI locale without changing process-wide locale state."""
    test_language = _test_ui_language()
    if test_language:
        return test_language
    return _session_ui_language()


def _locale_directories() -> list[Path]:
    """Return candidate locale roots in runtime priority order."""
    configured = os.environ.get("TEXTDOMAINDIR")
    if configured:
        return [Path(configured)]
    prefix = os.environ.get("PREFIX", "")
    checkout = Path(__file__).resolve().parents[1] / "locale"
    return [
        checkout,
        Path(f"{prefix}/usr/local/share/locale"),
        Path("/usr/share/locale"),
    ]


def _translation() -> gettext.NullTranslations:
    """Load the first matching catalog, falling back to English msgids."""
    language = _normalize_language(_requested_locale())
    for localedir in _locale_directories():
        try:
            return gettext.translation(
                TEXTDOMAIN,
                localedir=localedir,
                languages=[language],
                fallback=False,
            )
        except (FileNotFoundError, OSError):
            continue
    return gettext.NullTranslations()


def gettext_message(message: str) -> str:
    """Translate one complete English message."""
    return _translation().gettext(message)


def pgettext_message(context: str, message: str) -> str:
    """Translate an ambiguous message using gettext context."""
    return _translation().pgettext(context, message)


def ngettext_message(singular: str, plural: str, count: int) -> str:
    """Translate a plural message according to the active catalog."""
    return _translation().ngettext(singular, plural, count)
