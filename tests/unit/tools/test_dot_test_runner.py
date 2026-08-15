"""Unit tests for tools/dot_test_runner.py."""

import io
import logging
import os
import sys
import tempfile
import textwrap
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from tests.unit.bin.attr_helpers import get_attr
from tools import dot_test_runner


class TestDotTestRunner(unittest.TestCase):
    """Coverage for class-dot unittest progress helpers."""

    def test_class_dot_result_prints_class_once_then_dots(self):
        """New classes emit a label; subsequent tests only emit dots."""

        class _AlphaCase(unittest.TestCase):
            """Minimal testcase for ClassDotResult progress output."""

            def test_one(self):
                """No-op test for dot progress."""

            def test_two(self):
                """No-op test for dot progress."""

        class _BetaCase(unittest.TestCase):
            """Second class for ClassDotResult progress output."""

            def test_one(self):
                """No-op test for dot progress."""

        stream = io.StringIO()
        result = dot_test_runner.ClassDotResult(stream, descriptions=False, verbosity=1)
        first = _AlphaCase("test_one")
        second = _AlphaCase("test_two")
        third = _BetaCase("test_one")

        result.startTest(first)
        result.addSuccess(first)
        result.startTest(second)
        result.addSuccess(second)
        result.startTest(third)
        result.addSuccess(third)

        output = stream.getvalue()
        self.assertRegex(output, r"_AlphaCase: \.\.")
        self.assertRegex(output, r"\n.*_BetaCase: \.")

    @staticmethod
    def _make_result_stream():
        """Build a minimal stream with writeln used by TextTestResult."""

        class _Stream:
            """Minimal stream with writeln used by unittest TextTestResult."""

            def __init__(self):
                self._buf = io.StringIO()

            def write(self, data):
                """Append raw bytes/text to the buffer."""
                self._buf.write(data)

            def writeln(self, data=""):
                """Append one line including a trailing newline."""
                self._buf.write(f"{data}\n")

            def flush(self):
                """Flush the underlying buffer."""
                self._buf.flush()

            def getvalue(self):
                """Return the full buffered stream contents."""
                return self._buf.getvalue()

        return _Stream()

    def test_print_errors_leads_with_newline(self):
        """printErrors should begin on a fresh line after dot progress."""
        stream = self._make_result_stream()
        result = dot_test_runner.ClassDotResult(stream, descriptions=False, verbosity=1)

        class Alpha(unittest.TestCase):
            """Nested failing case used only for printErrors formatting."""

            def test_fail(self):
                """Force a failure so printErrors emits a FAIL block."""
                self.fail("boom")

        test = Alpha("test_fail")
        result.startTest(test)
        try:
            test.test_fail()
        except unittest.TestCase.failureException:
            result.addFailure(test, sys.exc_info())
        result.printErrors()
        output = stream.getvalue()
        self.assertRegex(output, r"Alpha: F")
        self.assertIn("\n======================================================================", output)

    def test_add_error_and_skip_emit_markers(self):
        """addError and addSkip print E/s markers after the class label."""
        stream = self._make_result_stream()
        result = dot_test_runner.ClassDotResult(stream, descriptions=False, verbosity=1)

        class MarkerCase(unittest.TestCase):
            """Nested case used only for error/skip marker coverage."""

            def test_err(self):
                """Raise so addError records an ERROR marker."""
                raise RuntimeError("boom")

            def test_skip(self):
                """Placeholder skipped via addSkip."""

        err_test = MarkerCase("test_err")
        result.startTest(err_test)
        try:
            err_test.test_err()
        except RuntimeError:
            result.addError(err_test, sys.exc_info())
        skip_test = MarkerCase("test_skip")
        result.startTest(skip_test)
        result.addSkip(skip_test, "not applicable")
        output = stream.getvalue()
        self.assertIn("MarkerCase: Es", output)

    def test_add_subtest_stays_silent_on_success(self):
        """Successful subtests do not emit an extra progress marker."""
        stream = io.StringIO()
        result = dot_test_runner.ClassDotResult(stream, descriptions=False, verbosity=1)

        class SubCase(unittest.TestCase):
            """Nested case for subtest marker coverage."""

            def test_subs(self):
                """Run one passing subtest."""
                with self.subTest(label="a"):
                    ok = True
                    self.assertTrue(ok)

        test = SubCase("test_subs")
        test.run(result)
        self.assertIn("SubCase: .", stream.getvalue())
        self.assertNotIn("SubCase: ..", stream.getvalue())

    def _restore_sys_modules(self, modules_snapshot: dict) -> None:
        """Restore sys.modules to *modules_snapshot* after a temp-module run."""
        for name in list(sys.modules):
            if name not in modules_snapshot:
                sys.modules.pop(name, None)
        for name, mod in modules_snapshot.items():
            if name not in sys.modules:
                sys.modules[name] = mod

    def _run_main_with_temp_module(self, module_name: str, source: str, argv_extra: list[str] | None = None):
        """Discover/run a temp module while restoring sys.path and sys.modules."""
        path_snapshot = list(sys.path)
        modules_snapshot = dict(sys.modules)
        try:
            with tempfile.TemporaryDirectory() as tmp_dir:
                module_path = Path(tmp_dir) / module_name
                module_path.write_text(textwrap.dedent(source).lstrip(), encoding="utf-8")
                out = io.StringIO()
                argv = ["--start-dir", tmp_dir, "--top-level-dir", tmp_dir, "--pattern", "test_*.py"]
                if argv_extra:
                    argv.extend(argv_extra)
                with redirect_stdout(out), redirect_stderr(out):
                    code = dot_test_runner.main(argv)
                return code, out.getvalue()
        finally:
            sys.path[:] = path_snapshot
            self._restore_sys_modules(modules_snapshot)

    def test_main_runs_discovered_temp_suite_successfully(self):
        """main() returns 0 when discovered temp-module tests succeed."""
        code, output = self._run_main_with_temp_module(
            "test_temp_dot_runner.py",
            """
            import unittest

            class TempSuccess(unittest.TestCase):
                def test_ok(self):
                    self.assertTrue(True)
            """,
        )
        self.assertEqual(code, 0)
        self.assertIn("TempSuccess: .", output)

    def test_main_returns_failure_when_discovered_tests_fail(self):
        """main() returns 1 when a discovered temp-module test fails."""
        code, output = self._run_main_with_temp_module(
            "test_temp_dot_runner_fail.py",
            """
            import unittest

            class TempFailure(unittest.TestCase):
                def test_bad(self):
                    self.assertTrue(False)
            """,
            argv_extra=["--no-failfast"],
        )
        self.assertEqual(code, 1)
        self.assertIn("FAIL: test_bad", output)
        self.assertIn("Captured product logging:", output)

    def test_main_failfast_stops_after_first_failure(self):
        """Default fail-fast mode stops discovery runs after the first failure."""
        code, output = self._run_main_with_temp_module(
            "test_temp_dot_runner_failfast.py",
            """
            import unittest

            class TempFailFast(unittest.TestCase):
                def test_a_fail(self):
                    self.assertTrue(False)

                def test_b_later(self):
                    self.assertTrue(True)
            """,
        )
        self.assertEqual(code, 1)
        self.assertIn("FAIL: test_a_fail", output)
        self.assertIn("Ran 1 test", output)

    def test_expected_failure_and_unexpected_success_markers(self):
        """Expected-failure and unexpected-success emit x/u markers."""

        class _Case(unittest.TestCase):
            """Minimal cases for ClassDotResult marker coverage."""

            @unittest.expectedFailure
            def test_expected_fail(self):
                """Expected failure path."""
                self.fail("x")

            @unittest.expectedFailure
            def test_unexpected_success(self):
                """Unexpected success path."""
                self.assertEqual(1, 1)

        stream = self._make_result_stream()
        result = dot_test_runner.ClassDotResult(stream, descriptions=False, verbosity=1)
        fail_test = _Case("test_expected_fail")
        success_test = _Case("test_unexpected_success")
        result.startTest(fail_test)
        try:
            fail_test.debug()
        except AssertionError as err:
            result.addExpectedFailure(fail_test, (AssertionError, err, None))
        result.startTest(success_test)
        result.addUnexpectedSuccess(success_test)
        output = stream.getvalue()
        self.assertIn("x", output)
        self.assertIn("u", output)

    def test_add_subtest_failure_and_error_markers(self):
        """Failed subtests emit F; non-assertion errors emit E."""

        class _Case(unittest.TestCase):
            """SubTest carrier for ClassDotResult."""

            def test_sub(self):
                """Placeholder."""

        stream = self._make_result_stream()
        result = dot_test_runner.ClassDotResult(stream, descriptions=False, verbosity=1)
        test = _Case("test_sub")
        result.startTest(test)
        result.addSubTest(test, test, (AssertionError, AssertionError("f"), None))
        result.addSubTest(test, test, (RuntimeError, RuntimeError("e"), None))
        result.addSubTest(test, test, None)
        output = stream.getvalue()
        self.assertIn("F", output)
        self.assertIn("E", output)

    def test_install_captured_logging_writes_product_records(self):
        """install_captured_logging routes product logs to a file, not stderr."""
        root = logging.getLogger()
        previous_handlers = list(root.handlers)
        capture_state = get_attr(dot_test_runner, "_CAPTURE_STATE")
        previous_path = capture_state["path"]
        previous_handler = capture_state["handler"]
        previous_handle = logging.Logger.handle
        try:
            with tempfile.TemporaryDirectory() as tmp:
                log_path = Path(tmp) / "product.log"
                with mock.patch.dict(os.environ, {"UNIT_TEST_PRODUCT_LOG": str(log_path)}):
                    written = dot_test_runner.install_captured_logging(force=True)
                self.assertEqual(written, log_path)
                logging.getLogger("asus_unit_capture_probe").warning("captured-for-debug")
                text = log_path.read_text(encoding="utf-8")
            self.assertIn("captured-for-debug", text)
            self.assertIn("asus_unit_capture_probe", text)
        finally:
            logging.Logger.handle = previous_handle
            root.handlers.clear()
            for handler in previous_handlers:
                root.addHandler(handler)
            capture_state["path"] = previous_path
            capture_state["handler"] = previous_handler


if __name__ == "__main__":
    unittest.main()
