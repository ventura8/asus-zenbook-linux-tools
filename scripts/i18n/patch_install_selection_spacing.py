"""Spacing helpers for install-selection gettext patches."""

from __future__ import annotations

import re

CJK_SEPARATORS = ("。",)
_NONE_TOKEN = re.compile(r"(?<![A-Za-z])none(?![A-Za-z])")


def following_whitespace(text: str) -> str:
    """Return the leading whitespace of *text*."""
    idx = 0
    while idx < len(text) and text[idx].isspace():
        idx += 1
    return text[:idx]


def needs_prefix_space(separator: str, following: str) -> bool:
    """True when a reconstructed prefix should gain a trailing space."""
    if following or separator.endswith(" "):
        return False
    return separator not in CJK_SEPARATORS


def split_prefix(obsolete_msgstr: str, separators: tuple[str, ...]) -> str:
    """Keep separator plus any following whitespace as the nothing-installed prefix."""
    for separator in separators:
        if separator not in obsolete_msgstr:
            continue
        left, right = obsolete_msgstr.split(separator, 1)
        following = following_whitespace(right)
        prefix = left + separator + following
        if needs_prefix_space(separator, following):
            prefix += " "
        return prefix
    return ""


def space_english_or(text: str) -> str:
    """Separate glued English *or* from neighboring all/none tokens."""
    text = text.replace("ornone", "or none")
    text = text.replace("'all'or", "'all' or")
    text = text.replace("or'none'", "or 'none'")
    return text.replace("all,or", "all, or")


def apply_or_replacements(text: str, word: str) -> str:
    """Replace English *or* connectors with the localized word."""
    replacements = (
        ("'all' or 'none'", f"'all' {word} 'none'"),
        ("all, or none", f"all, {word} none"),
        ("all or none", f"all {word} none"),
    )
    for old, new in replacements:
        if old in text:
            text = text.replace(old, new)
    return text


def space_or_neighbors(text: str, word: str) -> str:
    """Keep the localized connector separated from all/none tokens."""
    escaped = re.escape(word)
    text = re.sub(rf"all,({escaped})", r"all, \1", text)
    text = re.sub(rf"all({escaped})", r"all \1", text)
    text = re.sub(rf"({escaped})none", r"\1 none", text)
    text = re.sub(rf"'all'({escaped})", r"'all' \1", text)
    text = re.sub(rf"({escaped})'none'", r"\1 'none'", text)
    text = re.sub(rf",({escaped})", r", \1", text)
    return _space_latin_connector(text, word, escaped)


def _space_latin_connector(text: str, word: str, escaped: str) -> str:
    """Insert a space when a Latin connector is glued to the next word."""
    if word == "or" or not re.search(r"[A-Za-z]", word):
        return text
    pattern = rf"(^|[\s,;:\"'])({escaped})(?=[^\W\d_])"
    return re.sub(pattern, r"\1\2 ", text)


def space_all_none_tokens(text: str) -> str:
    """Insert missing spaces around literal all/none tokens."""
    text = text.replace("' all'", "'all'").replace("' none'", "'none'")
    text = re.sub(r"'(all|none)' (?=[.,;:!?%])", r"'\1'", text)
    text = re.sub(r"(?<=\S)'(all|none)'", r" '\1'", text)
    text = re.sub(r"'(all|none)'(?=[^\s.,;:!?%'])", r"'\1' ", text)
    text = re.sub(r"(?<=\S)(?<![A-Za-z'])(all|none)\b", r" \1", text)
    return re.sub(r"\b(all|none)(?=[^\s.,;:!?%'\"A-Za-z])", r"\1 ", text)


def localize_or(text: str, lang: str, word: str) -> str:
    """Localize *or* and normalize spaces around all/none tokens."""
    if lang != "en":
        text = apply_or_replacements(text, word)
    text = space_or_neighbors(text, word)
    return space_all_none_tokens(text)


def has_none_token(text: str) -> bool:
    """True when *none* appears as a standalone token."""
    return bool(_NONE_TOKEN.search(text))


def ensure_none(text: str) -> str:
    """Append the none option when the string only mentions all."""
    if has_none_token(text):
        return text
    if "'all'" in text:
        return text.replace("'all'", "'all' or 'none'", 1)
    return re.sub(r"\ball\b", "all, or none", text, count=1)


def prefix_lacks_spacing(current: str, clause: str) -> bool:
    """True when *current* joins prefix and clause without a separating space."""
    if not clause or not current.endswith(clause):
        return False
    prefix = current[: -len(clause)]
    if not prefix:
        return False
    return not prefix[-1].isspace() and prefix[-1] not in CJK_SEPARATORS


def normalize_selection_text(text: str, lang: str, word: str) -> str:
    """Fix glued English *or*, ensure none, then localize the connector."""
    text = space_english_or(text)
    text = ensure_none(text)
    return localize_or(text, lang, word)
