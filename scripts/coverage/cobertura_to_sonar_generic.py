#!/usr/bin/env python3
"""Convert a Cobertura coverage report into SonarQube generic coverage XML.

``sonar.coverageReportPaths`` accepts only Sonar's own "Generic Test Coverage"
format, while kcov emits Cobertura. Shell coverage therefore needs this
translation step before SonarQube can import it.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from xml.etree import ElementTree
from xml.sax.saxutils import escape


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


def _destination_within(destination: Path, base: Path) -> Path:
    """Resolve *destination* and require it to stay inside *base*.

    The path comes from the command line, so writes are confined to the output
    root the caller names: no escaping through `..` or a symlink.
    """
    root_dir = base.resolve()
    resolved = (
        destination.resolve()
        if destination.is_absolute()
        else (root_dir / destination).resolve()
    )
    try:
        resolved.relative_to(root_dir)
    except ValueError as exc:
        raise ValueError(f"path escapes {root_dir}: {destination}") from exc
    return resolved


def convert(source: Path, destination: Path, base: Path | None = None) -> int:
    """Write *source* Cobertura as generic coverage at *destination*; count files.

    Reading *source* is unconstrained (the merged kcov tree is a temp dir);
    *destination* must resolve inside *base* (default: the working directory).
    """
    safe_destination = _destination_within(destination, base or Path.cwd())
    root = ElementTree.parse(source).getroot()
    files = _merge_class_lines(root)
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
    args = parser.parse_args(argv)
    if not args.source.is_file():
        print(f"Missing Cobertura report: {args.source}", file=sys.stderr)
        return 1
    try:
        count = convert(args.source, args.destination, args.base)
    except ElementTree.ParseError as exc:
        print(f"Malformed Cobertura report {args.source}: {exc}", file=sys.stderr)
        return 1
    except ValueError as exc:
        print(f"Refusing to write outside the working tree: {exc}", file=sys.stderr)
        return 1
    if not count:
        print(f"No files found in {args.source}", file=sys.stderr)
        return 1
    print(f"Wrote {args.destination} ({count} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
