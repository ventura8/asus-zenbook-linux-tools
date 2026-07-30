#!/usr/bin/env python3
"""Run unittest discovery with class-name + dot progress output."""

from __future__ import annotations

import argparse
import logging
import os
import sys
import tempfile
import unittest
from pathlib import Path


class ClassDotResult(unittest.TextTestResult):
    """Print class names once, then dot progress for each test."""

    def __init__(self, stream, descriptions, verbosity, **kwargs):
        super().__init__(stream, descriptions, verbosity, **kwargs)
        self._last_class = None

    def startTest(self, test):
        """Begin a test and print its class name when the class changes."""
        super().startTest(test)
        class_key = f"{test.__class__.__module__}.{test.__class__.__qualname__}"
        if class_key != self._last_class:
            if self._last_class is not None:
                self.stream.write("\n")
            self.stream.write(f"{test.__class__.__qualname__}: ")
            self.stream.flush()
            self._last_class = class_key

    def _emit_result_marker(self, marker, delegate, test, *args):
        """Delegate to TestResult, then emit one progress marker."""
        delegate(self, test, *args)
        self.stream.write(marker)
        self.stream.flush()

    def addSuccess(self, test):
        """Record a success and emit a progress dot."""
        self._emit_result_marker(".", unittest.TestResult.addSuccess, test)

    def addError(self, test, err):
        """Record an error and emit an E marker."""
        self._emit_result_marker("E", unittest.TestResult.addError, test, err)

    def addFailure(self, test, err):
        """Record a failure and emit an F marker."""
        self._emit_result_marker("F", unittest.TestResult.addFailure, test, err)

    def addSkip(self, test, reason):
        """Record a skip and emit an s marker."""
        self._emit_result_marker("s", unittest.TestResult.addSkip, test, reason)

    def addExpectedFailure(self, test, err):
        """Record an expected failure and emit an x marker."""
        self._emit_result_marker("x", unittest.TestResult.addExpectedFailure, test, err)

    def addUnexpectedSuccess(self, test):
        """Record an unexpected success and emit a u marker."""
        self._emit_result_marker("u", unittest.TestResult.addUnexpectedSuccess, test)

    def addSubTest(self, test, subtest, err):
        """Emit F or E for a failed subtest; stay silent on success."""
        if err is None:
            unittest.TestResult.addSubTest(self, test, subtest, err)
            return
        if issubclass(err[0], test.failureException):
            self.stream.write("F")
        else:
            self.stream.write("E")
        self.stream.flush()
        unittest.TestResult.addSubTest(self, test, subtest, err)


class ClassDotRunner(unittest.TextTestRunner):
    """TextTestRunner that uses ClassDotResult for progress output."""

    resultclass = ClassDotResult

    def run_paths(self, start_dir: str, top_level_dir: str, pattern: str = "test*.py") -> unittest.TestResult | None:
        """Discover tests under start_dir and run them; return None when empty."""
        suite = unittest.TestLoader().discover(
            start_dir=start_dir,
            top_level_dir=top_level_dir,
            pattern=pattern,
        )
        if not suite.countTestCases():
            return None
        return self.run(suite)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Discover and run unittest suites with class-dot progress.",
    )
    parser.add_argument("--start-dir", required=True, help="Directory to start discovery from")
    parser.add_argument("--top-level-dir", required=True, help="Top-level directory for imports")
    parser.add_argument(
        "--pattern",
        default="test*.py",
        help="Filename pattern for unittest discovery (default: test*.py)",
    )
    parser.add_argument(
        "--failfast",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Stop on the first failure or error (default: enabled).",
    )
    return parser


_CAPTURE_STATE: dict[str, object] = {
    "path": None,
    "handler": None,
}
_ORIGINAL_LOGGER_HANDLE = logging.Logger.handle


def _product_logging_path() -> Path:
    """Resolve where captured product logging should be written."""
    override = os.environ.get("UNIT_TEST_PRODUCT_LOG", "").strip()
    if override:
        return Path(override)
    for key in ("DISTRO_LOG_DIR", "SHELL_UNIT_LOG_DIR"):
        base = os.environ.get(key, "").strip()
        if base:
            return Path(base) / f"unit-product-logging-{os.getpid()}.log"
    return Path(tempfile.gettempdir()) / f"asus-unit-product-logging-{os.getpid()}.log"


def _close_capture_handler() -> None:
    """Close and drop the active product-log FileHandler."""
    handler = _CAPTURE_STATE["handler"]
    if isinstance(handler, logging.Handler):
        handler.close()
    _CAPTURE_STATE["handler"] = None


def _install_handle_tee(handler: logging.Handler) -> None:
    """Tee every Logger.handle record into *handler* (works with assertLogs)."""

    def _handle(self: logging.Logger, record: logging.LogRecord) -> None:
        if not self.disabled and self.filter(record):
            handler.handle(record)
        _ORIGINAL_LOGGER_HANDLE(self, record)

    logging.Logger.handle = _handle


def install_captured_logging(*, force: bool = False) -> Path:
    """Capture product logging to a file for debugging (not the live console).

    Product mains call ``logging.basicConfig``, which would attach a root
    StreamHandler and spam INFO/WARNING into the suite console. A root
    NullHandler makes basicConfig a no-op. Records are also teed into a capture
    file via ``Logger.handle`` so they remain available for debugging even when
    ``assertLogs`` sets ``propagate=False``. Nested ``main()`` calls reuse the
    same capture file; pass ``force=True`` only in dedicated helper unit tests.
    """
    existing = _CAPTURE_STATE["path"]
    if isinstance(existing, Path) and not force:
        return existing
    path = _product_logging_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    _close_capture_handler()
    handler = logging.FileHandler(path, mode="w", encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(levelname)s %(name)s: %(message)s"))
    handler.setLevel(logging.DEBUG)
    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(logging.NullHandler())
    root.setLevel(logging.DEBUG)
    _install_handle_tee(handler)
    _CAPTURE_STATE["handler"] = handler
    _CAPTURE_STATE["path"] = path
    return path


def main(argv: list[str] | None = None) -> int:
    """Discover tests and exit 0 on success, 1 on failure."""
    log_path = install_captured_logging()
    args = _build_parser().parse_args(argv)
    runner = ClassDotRunner(stream=sys.stdout, verbosity=1, failfast=args.failfast)
    result = runner.run_paths(
        start_dir=args.start_dir,
        top_level_dir=args.top_level_dir,
        pattern=args.pattern,
    )
    if result is None:
        print("No tests discovered.", file=sys.stderr)
        return 1
    if not result.wasSuccessful():
        print(f"Captured product logging: {log_path}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
