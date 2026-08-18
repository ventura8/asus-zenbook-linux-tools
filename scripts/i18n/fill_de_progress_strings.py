#!/usr/bin/env python3
"""Fill Cinnamon/LXQt/MATE/XFCE install-progress msgids from GNOME configure strings."""

from __future__ import annotations

import importlib.util
from pathlib import Path
from types import ModuleType

SCRIPT_DIR = Path(__file__).resolve().parent


def _load_patcher() -> ModuleType:
    path = SCRIPT_DIR / "patch_install_selection_strings.py"
    spec = importlib.util.spec_from_file_location("patch_install_selection_strings", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_PATCHER = _load_patcher()
PO_DIR = _PATCHER.PO_DIR
read_msgid_from_block = _PATCHER.read_msgid_from_block
read_msgstr_from_block = _PATCHER.read_msgstr_from_block
replace_msgstr_in_block = _PATCHER.replace_msgstr_in_block
split_po_blocks = _PATCHER.split_po_blocks
load_supported_languages = _PATCHER.load_supported_languages

GNOME_MSGID = "Configure GNOME shortcuts for %s"
CINNAMON_MSGID = "Configuring Cinnamon shortcuts for %s..."
LXQT_MSGID = "Configuring LXQt Global Keys for %s..."
MATE_MSGID = "Configuring MATE shortcuts for %s..."
XFCE_MSGID = "Configuring XFCE shortcuts for %s..."

GNOME_TOKEN = {
    "ar": "جنوم",
    "bn": "জিনোম",
    "bo": "ཇི་ནོམ་",
    "fa": "گنوم",
    "gu": "જીનોમ",
    "kn": "ಗ್ನೋಮ್",
    "ko": "그놈",
    "ml": "ഗ്നോം",
    "pa": "ਗਨੋਮ",
    "ps": "ګینوم",
    "sr": "ГНОМЕ",
    "ta": "க்னோம்",
    "te": "గ్నోమ్",
}

ENGLISH_PROGRESS = {
    "Cinnamon": CINNAMON_MSGID,
    "LXQt Global Keys": LXQT_MSGID,
    "MATE": MATE_MSGID,
    "XFCE": XFCE_MSGID,
}


def _with_ellipsis(text: str) -> str:
    stripped = text.rstrip(".")
    if stripped.endswith("..."):
        return stripped
    return stripped + "..."


def _replace_gnome_token(gnome: str, lang: str, replacement: str) -> str | None:
    token = GNOME_TOKEN.get(lang, "GNOME")
    if token in gnome:
        return gnome.replace(token, replacement, 1)
    for marker in ("GNOME", "Gnome"):
        if marker in gnome:
            return gnome.replace(marker, replacement, 1)
    return None


def _progress_from_gnome(gnome: str, lang: str, replacement: str) -> str:
    if lang == "en":
        return ENGLISH_PROGRESS[replacement]
    replaced = _replace_gnome_token(gnome, lang, replacement)
    if replaced is not None:
        return _with_ellipsis(replaced)
    return _with_ellipsis(f"{replacement}: {gnome}")


def _collect_gnome(blocks: list[list[str]]) -> str:
    for block in blocks:
        if read_msgid_from_block(block) == GNOME_MSGID:
            return read_msgstr_from_block(block)
    return GNOME_MSGID


def _has_leftover_gnome(text: str) -> bool:
    return "Gnome" in text


def _fill_block(block: list[str], translations: dict[str, str]) -> list[str]:
    msgid = read_msgid_from_block(block)
    if msgid not in translations:
        return block
    current = read_msgstr_from_block(block)
    if current and not _has_leftover_gnome(current):
        return block
    return replace_msgstr_in_block(block, translations[msgid])


def _de_progress_translations(gnome: str, lang: str) -> dict[str, str]:
    return {
        CINNAMON_MSGID: _progress_from_gnome(gnome, lang, "Cinnamon"),
        LXQT_MSGID: _progress_from_gnome(gnome, lang, "LXQt Global Keys"),
        MATE_MSGID: _progress_from_gnome(gnome, lang, "MATE"),
        XFCE_MSGID: _progress_from_gnome(gnome, lang, "XFCE"),
    }


def _fill_po(content: str, lang: str) -> str:
    blocks = split_po_blocks(content)
    gnome = _collect_gnome(blocks) or GNOME_MSGID
    translations = _de_progress_translations(gnome, lang)
    rebuilt: list[str] = []
    for block in blocks:
        if not block:
            rebuilt.append("")
            continue
        rebuilt.extend(_fill_block(block, translations))
    text = "\n".join(rebuilt)
    if not text.endswith("\n"):
        text += "\n"
    return text


def main() -> int:
    """CLI entry point."""
    for lang in load_supported_languages():
        path = PO_DIR / f"{lang}.po"
        path.write_text(_fill_po(path.read_text(encoding="utf-8"), lang), encoding="utf-8")
        print(f"Filled DE progress in {lang}.po")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
