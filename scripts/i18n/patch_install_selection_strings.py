#!/usr/bin/env python3
"""Patch install-selection gettext updates from current and obsolete entries."""

from __future__ import annotations

import sys
from pathlib import Path

from patch_install_selection_spacing import (
    normalize_selection_text,
    prefix_lacks_spacing,
    split_prefix,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
PO_DIR = REPO_ROOT / "po"

NOTHING_MSGID = "No components were selected. Nothing was installed."
PRESS_MSGID = "Press Enter to install all recommended components, or enter 'all' or 'none'."
INVALID_MSGID = "Invalid selection: %s. Enter numbers (1,2,3,4), component names, all, or none."
OLD_CANCELLED = "No components were selected. Installation cancelled."

PREFIX_SEPARATORS = (". ", "。", "።", "۔", "।", "། ")
CANCEL_MARKERS = (
    "cancel",
    "Cancel",
    "キャンセル",
    "取消",
    "abgebrochen",
    "отменена",
    "cancel·lat",
    "An soke",
    "باتيل",
    "취소",
)

NOTHING_CLAUSE: dict[str, str] = {
    "en": "Nothing was installed.",
    "zh": "未安装任何内容。",
    "de": "Es wurde nichts installiert.",
    "es": "No se instaló nada.",
    "ru": "Ничего не было установлено.",
    "ko": "아무 것도 설치되지 않았습니다.",
    "fr": "Rien n'a été installé.",
    "ja": "何もインストールされませんでした。",
    "pt": "Nada foi instalado.",
    "tr": "Hiçbir şey yüklenmedi.",
    "pl": "Nic nie zostało zainstalowane.",
    "ca": "No s'ha instal·lat res.",
    "nl": "Er is niets geïnstalleerd.",
    "ar": "لم يتم تثبيت أي شيء.",
    "sv": "Ingenting installerades.",
    "it": "Non è stato installato nulla.",
    "id": "Tidak ada yang diinstal.",
    "hi": "कुछ भी स्थापित नहीं किया गया।",
    "fi": "Mitään ei asennettu.",
    "vi": "Không có gì được cài đặt.",
    "he": "שום דבר לא הותקן.",
    "uk": "Нічого не було встановлено.",
    "el": "Δεν εγκαταστάθηκε τίποτα.",
    "ms": "Tiada apa-apa yang dipasang.",
    "cs": "Nic nebylo nainstalováno.",
    "ro": "Nu a fost instalat nimic.",
    "da": "Intet blev installeret.",
    "hu": "Semmi sem lett telepítve.",
    "ta": "எதுவும் நிறுவப்படவில்லை.",
    "no": "Ingenting ble installert.",
    "th": "ไม่ได้ติดตั้งอะไรเลย",
    "ur": "کچھ بھی انسٹال نہیں ہوا۔",
    "hr": "Ništa nije instalirano.",
    "bg": "Нищо не беше инсталирано.",
    "lt": "Nieko nebuvo įdiegta.",
    "la": "Nihil installatum est.",
    "mi": "Kāore i whakauruhia he mea.",
    "ml": "ഒന്നും ഇൻസ്റ്റാൾ ചെയ്തിട്ടില്ല.",
    "cy": "Ni osodwyd dim.",
    "sk": "Nič nebolo nainštalované.",
    "te": "ఏదీ ఇన్‌స్టాల్ చేయలేదు.",
    "fa": "چیزی نصب نشد.",
    "lv": "Nekas netika instalēts.",
    "bn": "কিছুই ইনস্টল করা হয়নি।",
    "sr": "Ништа није инсталирано.",
    "az": "Heç nə quraşdırılmadı.",
    "sl": "Nič ni bilo nameščeno.",
    "kn": "ಏನೂ ಸ್ಥಾಪಿಸಲಾಗಿಲ್ಲ.",
    "et": "Midagi ei paigaldatud.",
    "mk": "Ништо не беше инсталирано.",
    "br": "Netra n'eus ket staliet.",
    "eu": "Ez da ezer instalatu.",
    "is": "Ekkert var sett upp.",
    "hy": "Ոչինչ չի տեղադրվել։",
    "ne": "केही पनि स्थापना गरिएन।",
    "mn": "Юу ч суулгагдаагүй.",
    "bs": "Ništa nije instalirano.",
    "kk": "Ештеңе орнатылмады.",
    "sq": "Asgjë nuk u instalua.",
    "sw": "Hakuna kilichosakinishwa.",
    "gl": "Non se instalou nada.",
    "mr": "काहीही स्थापित केले नाही.",
    "pa": "ਕੁਝ ਵੀ ਇੰਸਟਾਲ ਨਹੀਂ ਕੀਤਾ ਗਿਆ।",
    "si": "කිසිවක් ස්ථාපනය කර නොමැත.",
    "km": "គ្មានអ្វីត្រូវបានដំឡើងទេ។",
    "sn": "Hapana chakaiswa.",
    "yo": "Ko si nkan ti a fi sori ẹrọ.",
    "so": "Waxba lama rakibin.",
    "af": "Niks is geïnstalleer nie.",
    "oc": "Res es pas estat installat.",
    "ka": "არაფერი დაინსტალირდა.",
    "be": "Нічога не было ўсталявана.",
    "tg": "Чизе насб нашуд.",
    "sd": "ڪجهه به انسٽال نه ٿيو.",
    "gu": "કંઈપણ ઇન્સ્ટોલ થયું નહીં.",
    "am": "ምንም አልተጫነም።",
    "yi": "גאָרנישט איז אינסטאַלירט געוואָרן.",
    "lo": "ບໍ່ມີຫຍັງຖືກຕິດຕັ້ງ.",
    "uz": "Hech narsa o'rnatilmadi.",
    "fo": "Eingin varð sett upp.",
    "ht": "Pa gen anyen ki enstale.",
    "ps": "هیڅ شي نصب نشو.",
    "tk": "Hiç zat gurnalmady.",
    "nn": "Ingenting vart installert.",
    "mt": "Xejn ma ġie installat.",
    "sa": "किमपि संस्थापितं नास्ति।",
    "lb": "Et gouf näischt installéiert.",
    "my": "ဘာမှ ထည့်သွင်းမထားပါ။",
    "bo": "གཞིགས་འཇུག་བྱ་མེད།",
    "tl": "Walang nai-install.",
    "mg": "Tsy nisy nampidirina.",
    "as": "একো ইনষ্টল কৰা হোৱা নাই।",
    "tt": "Берни дә урнаштырылмады.",
    "haw": "ʻAʻole i hoʻokomo ʻia kekahi mea.",
    "ln": "Eloko moko etiamaki te.",
    "ha": "Ba a shigar da komai ba.",
    "ba": "Бер ниндәй ҙә нәмә урынлаштырылманы.",
    "jw": "Ora ana sing diinstal.",
    "su": "Teu aya anu diinstal.",
}

OR_WORD: dict[str, str] = {
    "en": "or",
    "zh": "或",
    "de": "oder",
    "es": "o",
    "ru": "или",
    "ko": "또는",
    "fr": "ou",
    "ja": "または",
    "pt": "ou",
    "tr": "veya",
    "pl": "lub",
    "ca": "o",
    "nl": "of",
    "ar": "أو",
    "sv": "eller",
    "it": "o",
    "id": "atau",
    "hi": "या",
    "fi": "tai",
    "vi": "hoặc",
    "he": "או",
    "uk": "або",
    "el": "ή",
    "ms": "atau",
    "cs": "nebo",
    "ro": "sau",
    "da": "eller",
    "hu": "vagy",
    "ta": "அல்லது",
    "no": "eller",
    "th": "หรือ",
    "ur": "یا",
    "hr": "ili",
    "bg": "или",
    "lt": "arba",
    "la": "vel",
    "mi": "rānei",
    "ml": "അല്ലെങ്കിൽ",
    "cy": "neu",
    "sk": "alebo",
    "te": "లేదా",
    "fa": "یا",
    "lv": "vai",
    "bn": "বা",
    "sr": "или",
    "az": "və ya",
    "sl": "ali",
    "kn": "ಅಥವಾ",
    "et": "või",
    "mk": "или",
    "br": "pe",
    "eu": "edo",
    "is": "eða",
    "hy": "կամ",
    "ne": "वा",
    "mn": "эсвэл",
    "bs": "ili",
    "kk": "немесе",
    "sq": "ose",
    "sw": "au",
    "gl": "ou",
    "mr": "किंवा",
    "pa": "ਜਾਂ",
    "si": "හෝ",
    "km": "ឬ",
    "sn": "kana",
    "yo": "tàbí",
    "so": "ama",
    "af": "of",
    "oc": "o",
    "ka": "ან",
    "be": "або",
    "tg": "ё",
    "sd": "يا",
    "gu": "અથવા",
    "am": "ወይም",
    "yi": "אָדער",
    "lo": "ຫຼື",
    "uz": "yoki",
    "fo": "ella",
    "ht": "oswa",
    "ps": "یا",
    "tk": "ýa-da",
    "nn": "eller",
    "mt": "jew",
    "sa": "वा",
    "lb": "oder",
    "my": "သို့မဟုတ်",
    "bo": "ཡང་ན",
    "tl": "o",
    "mg": "na",
    "as": "বা",
    "tt": "яки",
    "haw": "a i ʻole",
    "ln": "tǒ",
    "ha": "ko",
    "ba": "йәки",
    "jw": "utawa",
    "su": "atawa",
}

PREFIX_OVERRIDE: dict[str, str] = {
    "ha": "Ba a zaɓi wani sashi ba. ",
}

NOTHING_OVERRIDE: dict[str, str] = {
    "ca": "No s'ha seleccionat cap component. No s'ha instal·lat res.",
    "ba": "Бер ниндәй ҙә компонент һайланмаған. Бер ниндәй ҙә нәмә урынлаштырылманы.",
    "ha": "Ba a zaɓi wani sashi ba. Ba a shigar da komai ba.",
    "hy": "Ոչ մի բաղադրիչ չի ընտրվել։ Ոչինչ չի տեղադրվել։",
    "km": "មិនមានសមាសធាតុត្រូវបានជ្រើសរើសទេ។ គ្មានអ្វីត្រូវបានដំឡើងទេ។",
    "my": "မည်သည့် အစိတ်အပိုင်းကိုမျှ ရွေးမထားပါ။ ဘာမှ ထည့်သွင်းမထားပါ။",
    "la": "Nullae partes selectae sunt. Nihil installatum est.",
    "bn": "কোন উপাদান নির্বাচন করা হয়নি। কিছুই ইনস্টল করা হয়নি।",
    "tt": "Компонентлар сайланмады. Берни дә урнаштырылмады.",
}

PRESS_OVERRIDE: dict[str, str] = {
    "af": "Druk Enter om alle aanbevole komponente te installeer, of voer 'all' of 'none' in.",
}

INVALID_OVERRIDE: dict[str, str] = {
    "af": "Ongeldige keuse: %s. Voer nommers (1,2,3,4), komponentname, all of none in.",
    "ko": "잘못된 선택: %s. 숫자(1,2,3,4), 구성 요소 이름, all 또는 none을 입력하세요.",
    "ka": "არასწორი არჩევანი: %s. შეიყვანეთ რიცხვები (1,2,3,4), კომპონენტების სახელები, all, ან none.",
}


def _unquote_po_lines(lines: list[str]) -> str:
    parts: list[str] = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith('"') and stripped.endswith('"'):
            parts.append(stripped[1:-1])
    return "".join(parts)


def _quote_chunks(escaped: str, width: int) -> list[str]:
    chunks: list[str] = []
    rest = escaped
    while rest:
        if len(rest) <= width:
            chunks.append(rest)
            break
        cut = rest.rfind(" ", 0, width + 1)
        if cut <= 0:
            chunks.append(rest[:width])
            rest = rest[width:]
            continue
        chunks.append(rest[: cut + 1])
        rest = rest[cut + 1 :]
    return chunks


def _quote_po(text: str, width: int = 76) -> list[str]:
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    if len(escaped) <= width:
        return [f'msgstr "{escaped}"']
    chunks = _quote_chunks(escaped, width)
    return [f'msgstr "{chunks[0]}"'] + [f'"{chunk}"' for chunk in chunks[1:]]


def _strip_po_field(line: str, field: str) -> str:
    cleaned = line.removeprefix("#~ ").strip()
    prefix = f"{field} "
    if cleaned.startswith(prefix):
        return cleaned[len(prefix) :].strip()
    return cleaned


def _collect_continued_quoted(lines: list[str], idx: int) -> tuple[list[str], int]:
    collected: list[str] = []
    while idx < len(lines) and lines[idx].startswith('#~ "'):
        collected.append(lines[idx])
        idx += 1
    return collected, idx


def _obsolete_msgstr_ready(lines: list[str], idx: int) -> bool:
    return idx < len(lines) and lines[idx].startswith("#~ msgstr")


def _parse_obsolete_pair(lines: list[str], idx: int) -> tuple[int, tuple[str, str] | None]:
    if not lines[idx].startswith("#~ msgid"):
        return idx + 1, None
    msgid_lines = [lines[idx]]
    extra, idx = _collect_continued_quoted(lines, idx + 1)
    msgid_lines.extend(extra)
    if not _obsolete_msgstr_ready(lines, idx):
        return idx, None
    msgstr_lines = [lines[idx]]
    extra, idx = _collect_continued_quoted(lines, idx + 1)
    msgstr_lines.extend(extra)
    msgid = _unquote_po_lines([_strip_po_field(ln, "msgid") for ln in msgid_lines])
    msgstr = _unquote_po_lines([_strip_po_field(ln, "msgstr") for ln in msgstr_lines])
    return idx, (msgid, msgstr)


def _parse_obsolete_entries(content: str) -> dict[str, str]:
    entries: dict[str, str] = {}
    lines = content.splitlines()
    idx = 0
    while idx < len(lines):
        idx, parsed = _parse_obsolete_pair(lines, idx)
        if parsed:
            entries[parsed[0]] = parsed[1]
    return entries


def _split_prefix(obsolete_msgstr: str) -> str:
    return split_prefix(obsolete_msgstr, PREFIX_SEPARATORS)


def _has_cancel(text: str) -> bool:
    return any(marker in text for marker in CANCEL_MARKERS)


def _should_rebuild_nothing(current: str, clause: str) -> bool:
    if _has_cancel(current) or current == clause or not current:
        return True
    return prefix_lacks_spacing(current, clause)


def _rebuild_nothing(prefix: str, clause: str, lang: str) -> str:
    if not prefix and lang == "en":
        prefix = "No components were selected. "
    return prefix + clause


def _nothing_prefix(current: str, obsolete: str, lang: str) -> str:
    prefix = PREFIX_OVERRIDE.get(lang, "") or _split_prefix(obsolete) or _split_prefix(current)
    if _has_cancel(prefix):
        return _split_prefix(current) or _split_prefix(obsolete)
    return prefix


def _fix_nothing(current: str, obsolete: str, lang: str) -> str:
    if lang in NOTHING_OVERRIDE:
        return NOTHING_OVERRIDE[lang]
    clause = NOTHING_CLAUSE[lang]
    if _should_rebuild_nothing(current, clause):
        return _rebuild_nothing(_nothing_prefix(current, obsolete, lang), clause, lang)
    if lang == "ca":
        return current.replace("cap components", "cap component")
    return current


def _fix_press(current: str, lang: str) -> str:
    if lang in PRESS_OVERRIDE:
        return PRESS_OVERRIDE[lang]
    text = current or PRESS_MSGID
    return normalize_selection_text(text, lang, OR_WORD[lang])


def _fix_invalid(current: str, lang: str) -> str:
    if lang in INVALID_OVERRIDE:
        return INVALID_OVERRIDE[lang]
    text = current or INVALID_MSGID
    return normalize_selection_text(text, lang, OR_WORD[lang])


def _append_po_field_line(collected: list[str], line: str, in_field: bool) -> bool:
    if in_field and line.startswith('"'):
        collected.append(line.strip())
        return True
    return False


def _msgid_collect_step(line: str, in_msgid: bool, msgid_lines: list[str]) -> tuple[bool, bool]:
    if line.startswith("#") and not in_msgid:
        return False, False
    if line.startswith("msgid "):
        msgid_lines.append(line.removeprefix("msgid ").strip())
        return True, False
    if _append_po_field_line(msgid_lines, line, in_msgid):
        return True, False
    return in_msgid, in_msgid


def _read_msgid_from_block(block: list[str]) -> str:
    msgid_lines: list[str] = []
    in_msgid = False
    for line in block:
        in_msgid, stop = _msgid_collect_step(line, in_msgid, msgid_lines)
        if stop:
            break
    return _unquote_po_lines(msgid_lines)


def _read_msgstr_from_block(block: list[str]) -> str:
    msgstr_lines: list[str] = []
    in_msgstr = False
    for line in block:
        if line.startswith("msgstr"):
            in_msgstr = True
            msgstr_lines.append(line.removeprefix("msgstr").strip())
            continue
        if _append_po_field_line(msgstr_lines, line, in_msgstr):
            continue
        if in_msgstr:
            break
    return _unquote_po_lines(msgstr_lines)


def _replace_msgstr_in_block(block: list[str], msgstr: str) -> list[str]:
    out: list[str] = []
    idx = 0
    while idx < len(block):
        line = block[idx]
        if line.startswith("msgstr"):
            out.extend(_quote_po(msgstr))
            idx += 1
            while idx < len(block) and block[idx].startswith('"'):
                idx += 1
            continue
        out.append(line)
        idx += 1
    return out


def _translation_for_msgid(
    msgid: str,
    current: str,
    obsolete: dict[str, str],
    lang: str,
) -> str | None:
    if msgid == NOTHING_MSGID:
        return _fix_nothing(current, obsolete.get(OLD_CANCELLED, ""), lang)
    if msgid == PRESS_MSGID:
        return _fix_press(current, lang)
    if msgid == INVALID_MSGID:
        return _fix_invalid(current, lang)
    return None


def _split_po_blocks(content: str) -> list[list[str]]:
    blocks: list[list[str]] = []
    current: list[str] = []
    for line in content.splitlines():
        if line.strip():
            current.append(line)
            continue
        if current:
            blocks.append(current)
            current = []
        blocks.append([])
    if current:
        blocks.append(current)
    return blocks


def _apply_block_translation(block: list[str], obsolete: dict[str, str], lang: str) -> list[str]:
    msgid = _read_msgid_from_block(block)
    new_text = _translation_for_msgid(msgid, _read_msgstr_from_block(block), obsolete, lang)
    if new_text is None:
        return block
    return _replace_msgstr_in_block(block, new_text)


def _append_rebuilt_block(
    rebuilt: list[str],
    block: list[str],
    obsolete: dict[str, str],
    lang: str,
) -> None:
    if not block:
        rebuilt.append("")
        return
    if block[0].startswith("#~"):
        rebuilt.extend(block)
        return
    rebuilt.extend(_apply_block_translation(block, obsolete, lang))


def _patch_po_content(content: str, lang: str) -> str:
    obsolete = _parse_obsolete_entries(content)
    rebuilt: list[str] = []
    for block in _split_po_blocks(content):
        _append_rebuilt_block(rebuilt, block, obsolete, lang)
    text = "\n".join(rebuilt)
    if not text.endswith("\n"):
        text += "\n"
    return text


def _missing_maps(supported: list[str]) -> tuple[set[str], set[str]]:
    return set(supported) - set(NOTHING_CLAUSE), set(supported) - set(OR_WORD)


def _load_supported_languages() -> list[str]:
    raw = (PO_DIR / "SUPPORTED_LANGUAGES").read_text(encoding="utf-8")
    return [line.strip() for line in raw.splitlines() if line.strip()]


read_msgid_from_block = _read_msgid_from_block
read_msgstr_from_block = _read_msgstr_from_block
replace_msgstr_in_block = _replace_msgstr_in_block
split_po_blocks = _split_po_blocks
load_supported_languages = _load_supported_languages


def _fail_missing_maps(missing_clause: set[str], missing_or: set[str]) -> int:
    print(f"Missing NOTHING_CLAUSE: {sorted(missing_clause)}", file=sys.stderr)
    print(f"Missing OR_WORD: {sorted(missing_or)}", file=sys.stderr)
    return 1


def main() -> int:
    """CLI entry point."""
    supported = _load_supported_languages()
    missing_clause, missing_or = _missing_maps(supported)
    if missing_clause or missing_or:
        return _fail_missing_maps(missing_clause, missing_or)
    for lang in supported:
        path = PO_DIR / f"{lang}.po"
        path.write_text(_patch_po_content(path.read_text(encoding="utf-8"), lang), encoding="utf-8")
        print(f"Patched {lang}.po")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
