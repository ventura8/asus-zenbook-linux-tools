"""Shared text helpers for CI workflow parity unit tests."""

from __future__ import annotations


def workflow_section(text: str, start_marker: str, end_marker: str) -> str:
    """Return a workflow YAML slice; fail with a clear message when markers are absent."""
    try:
        start = text.index(start_marker)
        end = text.index(end_marker, start)
    except ValueError as exc:
        raise AssertionError(
            f"workflow section not found: {start_marker!r} .. {end_marker!r}"
        ) from exc
    return text[start:end]
