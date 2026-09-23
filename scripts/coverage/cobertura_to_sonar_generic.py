#!/usr/bin/env python3
"""Convert a Cobertura coverage report into SonarQube generic coverage XML.

``sonar.coverageReportPaths`` accepts only Sonar's own "Generic Test Coverage"
format, while kcov emits Cobertura. Shell coverage therefore needs this
translation step before SonarQube can import it.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from xml.etree import ElementTree
from xml.sax.saxutils import escape

_ENTITY_DECLARATION = re.compile(rb"<!\s*ENTITY", re.IGNORECASE)


def _line_hit(line_node: ElementTree.Element) -> tuple[int, int] | None:
    """Return (line number, hit count) for a Cobertura line node, or None."""
    number = line_node.get("number")
    hits = line_node.get("hits")
    if number is None or hits is None:
        return None
    try:
        line_no = int(number)
        hit_count = int(hits)
    except ValueError:
        return None
    return (line_no, hit_count) if line_no >= 1 else None


def _merge_class_node(class_node: ElementTree.Element, lines: dict[int, int]) -> None:
    """Merge one class node's line hits into *lines* (max wins)."""
    for line_node in class_node.iter("line"):
        parsed = _line_hit(line_node)
        if parsed is None:
            continue
        line_no, hit_count = parsed
        # Same line can appear in several class blocks (sourced helpers).
        lines[line_no] = max(lines.get(line_no, 0), hit_count)


def _merge_class_lines(root: ElementTree.Element) -> dict[str, dict[int, int]]:
    """Map each source file to its line hit counts, merging duplicate classes."""
    files: dict[str, dict[int, int]] = {}
    for class_node in root.iter("class"):
        filename = class_node.get("filename")
        if filename:
            _merge_class_node(class_node, files.setdefault(filename, {}))
    return files


def _render(files: dict[str, dict[int, int]]) -> str:
    """Render the generic coverage document for *files*."""
    out = ['<?xml version="1.0" encoding="UTF-8"?>', '<coverage version="1">']
    for filename in sorted(files):
        out.append(f'  <file path="{escape(filename, {chr(34): "&quot;"})}">')
        for line_no in sorted(files[filename]):
            covered = "true" if files[filename][line_no] > 0 else "false"
            out.append(f'    <lineToCover lineNumber="{line_no}" covered="{covered}"/>')
        out.append("  </file>")
    out.append("</coverage>")
    return "\n".join(out) + "\n"


def _parse_cobertura(source: Path) -> ElementTree.Element:
    """Parse *source*, refusing documents that declare internal entities.

    ElementTree never fetches external entities, but expat still expands
    internal ones, which is what "billion laughs" and quadratic-blowup inputs
    rely on. kcov emits a plain external DOCTYPE and no entity declarations,
    so rejecting `<!ENTITY` blocks the amplification without a new dependency.

    The raw bytes are handed to the parser so the document's own encoding
    declaration decides how it is decoded: decoding here as UTF-8 would mangle
    non-ASCII ``filename`` attributes in a latin-1 report, and Sonar would then
    fail to match the coverage to its source file.
    """
    data = source.read_bytes()
    # Dropping NULs normalises UTF-16 to ASCII-ish so the scan catches an
    # entity declaration in any of the encodings expat accepts.
    if _ENTITY_DECLARATION.search(data.replace(b"\x00", b"")):
        raise ValueError(f"entity declarations are not accepted: {source}")
    return ElementTree.fromstring(data)


def _resolved_within(path: Path, base: Path) -> Path:
    """Resolve *path* and require it to stay inside *base*.

    Both paths come from the command line, so reads and writes are confined to
    the roots the caller names: no escaping through `..` or a symlink.
    """
    root_dir = base.resolve()
    resolved = path.resolve() if path.is_absolute() else (root_dir / path).resolve()
    try:
        resolved.relative_to(root_dir)
    except ValueError as exc:
        raise ValueError(f"path escapes {root_dir}: {path}") from exc
    return resolved


def convert(
    source: Path,
    destination: Path,
    base: Path | None = None,
    source_base: Path | None = None,
) -> int:
    """Write *source* Cobertura as generic coverage at *destination*; count files.

    *destination* must resolve inside *base* and *source* inside *source_base*
    (the merged kcov tree is a temp dir, so it gets its own root). Both default
    to *base*, then to the working directory.
    """
    write_root = base or Path.cwd()
    safe_destination = _resolved_within(destination, write_root)
    safe_source = _resolved_within(source, source_base or write_root)
    try:
        root = _parse_cobertura(safe_source)
    except (ValueError, ElementTree.ParseError):
        # The caller is best-effort and ignores this failure, so a stale report
        # left on disk would be handed to Sonar as if it were current.
        safe_destination.unlink(missing_ok=True)
        raise
    files = _merge_class_lines(root)
    if not files:
        # An empty document would still satisfy the workflow's `-s` check and be
        # handed to Sonar as real (zero) coverage: drop any stale file instead.
        safe_destination.unlink(missing_ok=True)
        return 0
    safe_destination.parent.mkdir(parents=True, exist_ok=True)
    safe_destination.write_text(_render(files), encoding="utf-8")
    return len(files)


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint: convert Cobertura input to generic coverage output."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Cobertura XML produced by kcov")
    parser.add_argument("destination", type=Path, help="generic coverage XML to write")
    parser.add_argument(
        "--base",
        type=Path,
        default=None,
        help="output root the destination must stay inside (default: cwd)",
    )
    parser.add_argument(
        "--source-base",
        type=Path,
        default=None,
        help="input root the source must stay inside (default: --base, else cwd)",
    )
    args = parser.parse_args(argv)
    if not args.source.is_file():
        print(f"Missing Cobertura report: {args.source}", file=sys.stderr)
        return 1
    try:
        count = convert(
            args.source, args.destination, args.base, args.source_base
        )
    except ElementTree.ParseError as exc:
        print(f"Malformed Cobertura report {args.source}: {exc}", file=sys.stderr)
        return 1
    except ValueError as exc:
        print(f"Refusing to convert {args.source}: {exc}", file=sys.stderr)
        return 1
    if not count:
        print(f"No files found in {args.source}", file=sys.stderr)
        return 1
    print(f"Wrote {args.destination} ({count} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
