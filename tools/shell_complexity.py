#!/usr/bin/env python3
"""Shell script cyclomatic complexity analyzer with A–F grading.

Calculates cyclomatic complexity (CCN) per function and script main block
for Bash/POSIX shell scripts based on decision points (if, elif, while, for,
until, case arms, &&, ||).

Usage:
  python3 tools/shell_complexity.py bin/*.sh install.sh               # enforce ≤ A
  python3 tools/shell_complexity.py install.sh --no-enforce            # report only
  python3 tools/shell_complexity.py bin/*.sh --max-grade B             # enforce ≤ B
"""

import argparse
import re
import sys
from pathlib import Path

# Control-flow keywords that each contribute +1 to CC
_KEYWORD_RE = re.compile(r"\b(?:if|elif|while|for|until)\b", re.MULTILINE)
# Logical short-circuit operators used as conditional branches
_LOGIC_RE = re.compile(r"&&|\|\|", re.MULTILINE)
# Case statement arm terminators (each arm beyond the first adds a branch)
_CASE_ARM_RE = re.compile(r";;&|;;|;&", re.MULTILINE)
# Case statement terminators used to subtract one baseline arm per case block
_ESAC_RE = re.compile(r"\besac\b", re.MULTILINE)
# Match bash function definitions: name() { ... } or function name { ... }
_FUNC_RE = re.compile(r"(?m)^(?:function\s+([a-zA-Z0-9_]+)|([a-zA-Z0-9_]+)\s*\(\s*\))\s*\{")
# Match bash heredoc delimiter after '<<'. Tab-strip (-) only when immediately after <<.
_HEREDOC_DELIMITER_RE = re.compile(r'^(?:"([^"]+)"|\'([^\']+)\'|(-[A-Za-z_][A-Za-z0-9_]*)|([A-Za-z_][A-Za-z0-9_]*))(?:\s|$)')

# A-F thresholds matching Radon / McCabe standards (CCN per block)
_THRESHOLDS: list[tuple[int, str]] = [
    (5, "A"),
    (10, "B"),
    (15, "C"),
    (20, "D"),
    (25, "E"),
]
_GRADE_ORDER: dict[str, int] = {grade: idx for idx, grade in enumerate(["A", "B", "C", "D", "E", "F"])}
_REPO_ROOT = Path(__file__).resolve().parent.parent


class ShellComplexityParseError(ValueError):
    """Raised when shell source cannot be sanitized or parsed for complexity."""


__all__ = [
    "ShellComplexityParseError",
    "analyse_paths",
    "analyse_script",
    "compute_ccn",
    "extract_functions",
    "extract_heredoc_delimiter",
    "find_matching_brace",
    "grade",
    "is_comment_start",
    "is_heredoc_start",
    "is_within_repo",
    "main_block_from_ranges",
    "matches_heredoc_delimiter",
    "report_result",
    "sanitize_shell",
]


def is_within_repo(path: Path, repo_root: Path = _REPO_ROOT) -> bool:
    """Return True when *path* resolves under *repo_root*."""
    try:
        path.resolve().relative_to(repo_root)
        return True
    except ValueError:
        return False


def _skip_heredoc_operator_prefix(text: str, pos: int) -> tuple[bool, int]:
    """Skip optional '-' and whitespace after '<<'; return (strip_tabs, next_pos)."""
    strip_tabs = pos < len(text) and text[pos] == "-"
    if strip_tabs:
        pos += 1
    while pos < len(text) and text[pos] in " \t":
        pos += 1
    return strip_tabs, pos


def extract_heredoc_delimiter(text: str, idx: int) -> tuple[str | None, bool, int]:
    """Parse heredoc delimiter after '<<' and return (delimiter, strip_tabs, next_idx)."""
    strip_tabs, pos = _skip_heredoc_operator_prefix(text, idx)
    match = _HEREDOC_DELIMITER_RE.match(text[pos:])
    if not match:
        return None, False, idx
    delimiter = next((group for group in match.groups() if group), None)
    return delimiter, strip_tabs, pos + match.end()


def _skip_single_quoted_span(text: str, idx: int) -> int:
    """Advance past a single-quoted span starting at *idx* without mutating text."""
    n = len(text)
    idx += 1
    while idx < n and text[idx] != "'":
        idx += 1
    return idx + 1 if idx < n else idx


def _skip_escaped_quoted_span(text: str, idx: int, quote: str) -> int:
    """Advance past a quoted span with backslash escapes without mutating text."""
    n = len(text)
    idx += 1
    while idx < n:
        ch = text[idx]
        if _is_escape_sequence(text, idx, ch):
            idx += 2
            continue
        if ch == quote:
            return idx + 1
        idx += 1
    return idx


def _skip_quoted_span(text: str, idx: int, quote: str) -> int:
    """Advance past a quoted span starting at *idx* without mutating text."""
    if quote == "'":
        return _skip_single_quoted_span(text, idx)
    return _skip_escaped_quoted_span(text, idx, quote)


def _try_enqueue_line_heredoc(text: str, pos: int, pending: list[tuple[str, bool]]) -> int:
    """Enqueue one << heredoc at *pos* when present; always advance at least one char."""
    if text.startswith("<<<", pos):
        return pos + 3
    if not is_heredoc_start(text, pos):
        return pos + 1
    delim, strip_tabs, next_idx = extract_heredoc_delimiter(text, pos + 2)
    if delim is None:
        return pos + 1
    pending.append((delim, strip_tabs))
    return next_idx


def _advance_line_heredoc_scan(text: str, pos: int, line_end: int, pending: list[tuple[str, bool]]) -> int:
    """Advance one step while scanning a line for unquoted, non-comment heredocs."""
    if pos >= line_end:
        return pos
    ch = text[pos]
    if ch in "'\"`":
        return min(_skip_quoted_span(text, pos, ch), line_end)
    if is_comment_start(text, pos):
        return line_end
    return _try_enqueue_line_heredoc(text, pos, pending)


def _collect_line_heredocs(text: str, idx: int) -> tuple[int, list[tuple[str, bool]]]:
    """Collect << heredocs on the current physical line (FIFO; opener line preserved)."""
    line_end = text.find("\n", idx)
    if line_end == -1:
        line_end = len(text)
    pending: list[tuple[str, bool]] = []
    pos = idx
    while pos < line_end:
        pos = _advance_line_heredoc_scan(text, pos, line_end, pending)
    body_start = line_end + 1 if line_end < len(text) else line_end
    return body_start, pending


def _consume_line_comment(out: list[str], text: str, idx: int) -> int:
    """Blank a comment line starting at *idx* and return the next index."""
    n = len(text)
    while idx < n and text[idx] != "\n":
        out[idx] = " "
        idx += 1
    return idx


def _consume_single_quoted_span(out: list[str], text: str, idx: int) -> int:
    """Blank a single-quoted span starting at *idx* and return the next index."""
    n = len(text)
    out[idx] = " "
    idx += 1
    while idx < n:
        ch = text[idx]
        if ch != "\n":
            out[idx] = " "
        if ch == "'":
            return idx + 1
        idx += 1
    return idx


def _consume_escaped_quoted_span(out: list[str], text: str, idx: int, quote: str) -> int:
    """Blank a quoted span with backslash escapes and return the next index."""
    n = len(text)
    out[idx] = " "
    idx += 1
    while idx < n:
        ch = text[idx]
        _blank_char(out, idx, ch)
        if _is_escape_sequence(text, idx, ch):
            idx += 2
            continue
        if ch == quote:
            return idx + 1
        idx += 1
    return idx


def _blank_char(out: list[str], idx: int, ch: str) -> None:
    """Blank a character unless it is a newline."""
    if ch != "\n":
        out[idx] = " "


def _is_escape_sequence(text: str, idx: int, ch: str) -> bool:
    """Return True when the current character begins an escape sequence."""
    return ch == "\\" and idx + 1 < len(text)


def _consume_quoted_span(out: list[str], text: str, idx: int, quote: str) -> int:
    """Blank a quoted span starting at *idx* and return the next index."""
    if quote == "'":
        return _consume_single_quoted_span(out, text, idx)
    return _consume_escaped_quoted_span(out, text, idx, quote)


def _next_line_index(line_end: int, n: int) -> int:
    """Return the index immediately after the current line."""
    return line_end + 1 if line_end < n else line_end


def matches_heredoc_delimiter(text: str, start: int, line_end: int, delimiter: str, strip_tabs: bool) -> bool:
    """Return whether the current line matches a heredoc delimiter."""
    candidate = text[start:line_end]
    if strip_tabs:
        candidate = candidate.lstrip("\t")
    return candidate == delimiter


def _blank_range(out: list[str], start: int, end: int) -> None:
    """Replace a slice with spaces."""
    for pos in range(start, end):
        out[pos] = " "


def _consume_heredoc_body(out: list[str], text: str, idx: int, delimiter: str, strip_tabs: bool) -> int:
    """Blank heredoc lines until the delimiter line is reached."""
    n = len(text)
    while idx < n:
        line_end = text.find("\n", idx)
        if line_end == -1:
            line_end = n
        if matches_heredoc_delimiter(text, idx, line_end, delimiter, strip_tabs):
            return _next_line_index(line_end, n)
        _blank_range(out, idx, line_end)
        idx = _next_line_index(line_end, n)
    raise ShellComplexityParseError(f"unterminated heredoc for delimiter {delimiter!r}")


def _consume_quote_or_char(out: list[str], text: str, i: int) -> int:
    """Advance past a quoted span or a single literal character."""
    ch = text[i]
    if ch in "'\"`":
        return _consume_quoted_span(out, text, i, ch)
    return i + 1


def _consume_token(out: list[str], text: str, i: int, pending: list[tuple[str, bool]]) -> int:
    """Advance one sanitize token; may enqueue a heredoc body for the next loop."""
    if pending:
        delim, strip_tabs = pending.pop(0)
        return _consume_heredoc_body(out, text, i, delim, strip_tabs)
    if is_comment_start(text, i):
        return _consume_line_comment(out, text, i)
    if text.startswith("<<<", i):
        return i + 3
    if is_heredoc_start(text, i):
        next_i, pending[:] = _collect_line_heredocs(text, i)
        return next_i
    return _consume_quote_or_char(out, text, i)


def sanitize_shell(text: str) -> str:
    """Return shell source with comments, strings, and heredocs blanked."""
    out = list(text)
    n = len(text)
    i = 0
    pending: list[tuple[str, bool]] = []

    while i < n:
        i = _consume_token(out, text, i, pending)

    return "".join(out)


def _is_param_length_hash(text: str, idx: int) -> bool:
    """Return True when *idx* is the '#' in a ${#var} length expansion."""
    return idx >= 2 and text[idx - 2 : idx] == "${"


def is_comment_start(text: str, idx: int) -> bool:
    """Return True when *idx* begins a shell comment."""
    if idx >= len(text) or text[idx] != "#":
        return False
    if _is_param_length_hash(text, idx):
        return False
    prev = text[idx - 1] if idx > 0 else "\n"
    return prev in " \t\n;({&|)"


def is_heredoc_start(text: str, idx: int) -> bool:
    """Return True when *idx* begins a heredoc operator."""
    if idx + 1 >= len(text) or text[idx] != "<" or text[idx + 1] != "<":
        return False
    delimiter, _strip_tabs, _next_idx = extract_heredoc_delimiter(text, idx + 2)
    return delimiter is not None


def compute_ccn(code_block: str) -> int:
    """Return the cyclomatic complexity number (CCN) for a shell code block."""
    clean = sanitize_shell(code_block)
    keywords = len(_KEYWORD_RE.findall(clean))
    operators = len(_LOGIC_RE.findall(clean))
    arms = max(0, len(_CASE_ARM_RE.findall(clean)) - len(_ESAC_RE.findall(clean)))
    return 1 + keywords + operators + arms


def grade(ccn: int) -> str:
    """Map a CCN number to an A–F letter grade."""
    for threshold, letter in _THRESHOLDS:
        if ccn <= threshold:
            return letter
    return "F"


def find_matching_brace(text: str, start_idx: int) -> int:
    """Return index of closing brace matching opening brace at *start_idx*, or -1."""
    depth = 1
    for idx, ch in enumerate(text[start_idx + 1 :], start_idx + 1):
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if not depth:
                return idx

    return -1


def extract_functions(text: str) -> list[tuple[str, str, int, int]]:
    """Extract (func_name, body, start_idx, end_idx) tuples from shell script text."""
    functions: list[tuple[str, str, int, int]] = []
    sanitized_text = sanitize_shell(text)
    for match in _FUNC_RE.finditer(sanitized_text):
        func_name = match.group(1) or match.group(2)
        open_brace_idx = match.end() - 1
        close_brace_idx = find_matching_brace(sanitized_text, open_brace_idx)
        if close_brace_idx == -1:
            raise ShellComplexityParseError(f"unmatched braces while parsing function '{func_name}'")
        start_idx = match.start()
        end_idx = close_brace_idx + 1
        functions.append((func_name, text[start_idx:end_idx], start_idx, end_idx))
    return functions


def main_block_from_ranges(text: str, function_ranges: list[tuple[str, str, int, int]]) -> str:
    """Return the non-function portions of a shell script."""
    parts = []
    cursor = 0
    for _func_name, _body, start_idx, end_idx in sorted(function_ranges, key=lambda item: item[2]):
        if cursor < start_idx:
            parts.append(text[cursor:start_idx])
        cursor = max(cursor, end_idx)
    if cursor < len(text):
        parts.append(text[cursor:])
    return "\n".join(parts).strip()


def _analyse_block(block_name: str, body: str) -> tuple[str, int, str]:
    """Analyze a single code block and return a result tuple."""
    ccn = compute_ccn(body)
    return block_name, ccn, grade(ccn)


def _analyse_function_blocks(functions: list[tuple[str, str, int, int]]) -> list[tuple[str, int, str]]:
    """Analyze function blocks only."""
    return [_analyse_block(func_name, body) for func_name, body, _, _ in functions]


def analyse_script(path: Path) -> list[tuple[str, int, str]]:
    """Analyze a shell script at *path* and return list of (block_name, ccn, grade)."""
    text = path.read_text(encoding="utf-8")
    functions = extract_functions(text)
    if not functions:
        return [_analyse_block("<main>", text)]

    results = _analyse_function_blocks(functions)
    main_block = main_block_from_ranges(text, functions)
    if main_block:
        results.append(_analyse_block("<main>", main_block))
    return results


def _report_script_blocks(path: Path, config: tuple[int, bool]) -> bool:
    """Report complexity for all blocks in path; return True when all pass."""
    path_pass = True
    for block_name, ccn, block_grade in analyse_script(path):
        if not report_result(path, block_name, ccn, block_grade, config):
            path_pass = False
    return path_pass


def _analyse_path(path: Path, config: tuple[int, bool]) -> tuple[bool, bool]:
    """Analyze one script path.

    Returns ``(passed, hard_fail)`` where *hard_fail* is True for missing or
    out-of-repo paths (always fatal, even under ``--no-enforce``).
    """
    if not path.exists():
        print(f"  ✗ {path}: missing or unreadable", file=sys.stderr)
        return False, True
    if not is_within_repo(path):
        print(f"  ✗ {path}: outside repository root", file=sys.stderr)
        return False, True
    try:
        return _report_script_blocks(path, config), False
    except ShellComplexityParseError as err:
        print(f"  ✗ {path}: {err}", file=sys.stderr)
        return False, True
    except (OSError, UnicodeDecodeError) as err:
        print(f"  ✗ {path}: {err}", file=sys.stderr)
        return False, True


def analyse_paths(paths: list[Path], max_grade: str, enforce: bool) -> tuple[bool, bool]:
    """Print complexity for each function/main in paths.

    Returns ``(all_pass, hard_fail)``. *hard_fail* is True when any path is missing
    or outside the repository (always fatal, even under ``--no-enforce``).
    """
    if max_grade not in _GRADE_ORDER:
        raise ValueError(f"Invalid max_grade: {max_grade!r}")
    config = (_GRADE_ORDER[max_grade], enforce)
    all_pass = True
    hard_fail = False
    for path in sorted(paths):
        passed, path_hard = _analyse_path(path, config)
        hard_fail = hard_fail or path_hard
        all_pass = all_pass and passed
    return all_pass, hard_fail


def report_result(path: Path, block_name: str, ccn: int, block_grade: str, config: tuple[int, bool]) -> bool:
    """Print a single analysis result and return whether it passes."""
    max_idx, enforce = config
    ok = _GRADE_ORDER[block_grade] <= max_idx
    symbol = "\u2713" if ok else ("\u2717" if enforce else "!")
    print(f"  {symbol} {path} [{block_name}]: CCN={ccn} ({block_grade})")
    return ok


def _build_parser() -> argparse.ArgumentParser:
    """Return the CLI argument parser."""
    parser = argparse.ArgumentParser(description="Shell script cyclomatic complexity analyzer with A-F grading.")
    parser.add_argument("scripts", nargs="+", type=Path, metavar="SCRIPT")
    parser.add_argument(
        "--max-grade",
        default="A",
        choices=["A", "B", "C", "D", "E", "F"],
        help="Maximum allowed grade (default: A).",
    )
    parser.add_argument(
        "--no-enforce",
        action="store_true",
        help="Print grades without failing on violations.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    """Entry point: parse args, analyze scripts, return exit code."""
    args = _build_parser().parse_args(argv)
    all_pass, hard_fail = analyse_paths(args.scripts, args.max_grade, enforce=not args.no_enforce)
    if hard_fail:
        return 1
    return 0 if (all_pass or args.no_enforce) else 1


if __name__ == "__main__":
    sys.exit(main())
