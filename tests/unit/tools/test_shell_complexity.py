"""Unit tests for heredoc parsing behavior in shell_complexity."""

import io
import os
import shutil
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from tools import shell_complexity


class ShellComplexityHeredocTests(unittest.TestCase):
    """Verify heredoc delimiters keep correct tab-stripping semantics."""

    def test_extract_heredoc_delimiter_preserves_dash_flag(self):
        """Delimiter parsing should expose whether the heredoc used <<-."""
        delimiter, strip_tabs, _next_idx = shell_complexity.extract_heredoc_delimiter("-EOF\n", 0)
        self.assertEqual(delimiter, "EOF")
        self.assertTrue(strip_tabs)

        delimiter, strip_tabs, _next_idx = shell_complexity.extract_heredoc_delimiter("EOF\n", 0)
        self.assertEqual(delimiter, "EOF")
        self.assertFalse(strip_tabs)

        delimiter, strip_tabs, _next_idx = shell_complexity.extract_heredoc_delimiter(" -EOF\n", 0)
        self.assertEqual(delimiter, "-EOF")
        self.assertFalse(strip_tabs)

    def test_matches_heredoc_delimiter_respects_tab_strip_mode(self):
        """Leading tabs are valid only for <<- heredocs, not plain << heredocs."""
        text = "\tEOF\nEOF\n"
        self.assertTrue(shell_complexity.matches_heredoc_delimiter(text, 0, 4, "EOF", True))
        self.assertFalse(shell_complexity.matches_heredoc_delimiter(text, 0, 4, "EOF", False))
        self.assertTrue(shell_complexity.matches_heredoc_delimiter(text, 5, 8, "EOF", False))

    def test_sanitize_shell_blanks_multiple_heredocs_fifo(self):
        """Multiple heredocs on one line blank bodies in declaration order."""
        text = "cat <<A <<B\nif in_a\nA\nif in_b\nB\nif true; then :; fi\n"
        clean = shell_complexity.sanitize_shell(text)
        self.assertNotIn("in_a", clean)
        self.assertNotIn("in_b", clean)
        self.assertIn("if true; then", clean)

    def test_collect_line_heredocs_skips_quoted_and_comment_openers(self):
        """Quoted or commented << on an opener line must not enqueue fake heredocs."""
        text = 'cat <<EOF && echo "<<FAKE" # <<NOPE\nif in_body\nEOF\nif true; then :; fi\n'
        clean = shell_complexity.sanitize_shell(text)
        self.assertNotIn("in_body", clean)
        self.assertIn('echo "<<FAKE"', clean)
        self.assertIn("if true; then", clean)
        self.assertEqual(shell_complexity.compute_ccn(text), 3)

    def test_compute_ccn_handles_multiple_case_blocks(self):
        """Case-arm baseline should be subtracted once per case statement."""
        code = """
case "$a" in
    1) echo one ;;
esac
case "$b" in
    1) echo one ;;
esac
"""
        self.assertEqual(shell_complexity.compute_ccn(code), 1)


class ShellComplexityCoreTests(unittest.TestCase):
    """Cover core parser/analyzer helpers for shell complexity calculations."""

    def setUp(self):
        """Create an isolated scratch directory for each test case.

        Scratch lives under a per-process repo subdirectory so enforced
        in-repo path checks still pass, while parallel Docker matrix lanes
        (shared bind mount) cannot race on a shared ``tests/.tmp-tests`` parent.
        """
        repo_root = Path(__file__).resolve().parents[2]
        self._scratch_parent = repo_root / ".tmp-tests" / f"shell-complexity-{os.getpid()}"
        self._scratch_parent.mkdir(parents=True, exist_ok=True)
        self._scratch_root = tempfile.mkdtemp(dir=str(self._scratch_parent), prefix="case-")
        self.addCleanup(shutil.rmtree, self._scratch_root, True)
        self.addCleanup(shutil.rmtree, self._scratch_parent, True)

    def _scratch_dir(self) -> Path:
        """Return a per-test subdirectory under the isolated scratch root."""
        path = Path(self._scratch_root) / "case"
        path.mkdir(exist_ok=True)
        return path

    def test_extract_heredoc_delimiter_invalid(self):
        """Invalid heredoc syntax should return no delimiter and unchanged index."""
        delimiter, strip_tabs, idx = shell_complexity.extract_heredoc_delimiter("!bad\n", 0)
        self.assertIsNone(delimiter)
        self.assertFalse(strip_tabs)
        self.assertEqual(idx, 0)

    def test_extract_heredoc_delimiter_quoted(self):
        """Quoted heredoc delimiters should parse correctly."""
        delimiter, strip_tabs, _idx = shell_complexity.extract_heredoc_delimiter('"EOF" \n', 0)
        self.assertEqual(delimiter, "EOF")
        self.assertFalse(strip_tabs)

    def test_sanitize_shell_blanks_comment_and_strings(self):
        """Sanitizer should blank comments and quoted spans while keeping structure."""
        text = "echo 'if' # if should be blanked\nif true; then echo ok; fi\n"
        clean = shell_complexity.sanitize_shell(text)
        self.assertIn("if true; then", clean)
        self.assertNotIn("# if should be blanked", clean)

    def test_sanitize_shell_blanks_heredoc_body(self):
        """Sanitizer should blank heredoc body content before complexity scanning."""
        text = "cat <<EOF\nif should_not_count\nEOF\nif true; then :; fi\n"
        clean = shell_complexity.sanitize_shell(text)
        self.assertIn("if true; then", clean)
        self.assertNotIn("should_not_count", clean)

    def test_sanitize_shell_keeps_operator_on_heredoc_line(self):
        """Logical operators on the heredoc opener line should still count toward CCN."""
        text = "cat <<EOF && if true; then :; fi\nbody\nEOF\n"
        self.assertEqual(shell_complexity.compute_ccn(text), 3)

    def test_sanitize_shell_skips_here_string_operator(self):
        """Bash <<< here-strings must not be parsed as heredoc openers."""
        text = 'if true; then x=$(cat <<< "if nested"); fi\n'
        self.assertEqual(shell_complexity.compute_ccn(text), 2)

    def test_analyse_paths_hard_fails_unterminated_heredoc(self):
        """Unterminated heredocs are fatal parse errors during analysis."""
        bad = self._scratch_dir() / "bad-heredoc.sh"
        bad.write_text("cat <<EOF\nunterminated\n", encoding="utf-8")
        err = io.StringIO()
        with redirect_stdout(io.StringIO()), redirect_stderr(err):
            all_pass, hard_fail = shell_complexity.analyse_paths([bad], "A", enforce=True)
        self.assertFalse(all_pass)
        self.assertTrue(hard_fail)
        self.assertIn("unterminated heredoc", err.getvalue())

    def test_analyse_paths_hard_fails_unmatched_function_braces(self):
        """Unmatched function braces are fatal parse errors during analysis."""
        bad = self._scratch_dir() / "bad-braces.sh"
        bad.write_text("broken_fn() { if true; then echo ok;\n", encoding="utf-8")
        err = io.StringIO()
        with redirect_stdout(io.StringIO()), redirect_stderr(err):
            all_pass, hard_fail = shell_complexity.analyse_paths([bad], "A", enforce=True)
        self.assertFalse(all_pass)
        self.assertTrue(hard_fail)
        self.assertIn("unmatched braces", err.getvalue())

    def test_sanitize_shell_warns_on_unterminated_heredoc(self):
        """Unterminated heredocs raise when sanitize_shell consumes the body."""
        text = "cat <<EOF\nunterminated\n"
        with self.assertRaises(shell_complexity.ShellComplexityParseError):
            shell_complexity.sanitize_shell(text)

    def test_comment_and_heredoc_start_helpers(self):
        """Token detectors should identify comment starts and heredoc operators."""
        self.assertTrue(shell_complexity.is_comment_start("\n#x", 1))
        self.assertTrue(shell_complexity.is_comment_start("cmd & #x", 6))
        self.assertTrue(shell_complexity.is_comment_start("cmd | #x", 6))
        self.assertTrue(shell_complexity.is_comment_start(") #x", 2))
        self.assertFalse(shell_complexity.is_comment_start("a#x", 1))
        self.assertFalse(shell_complexity.is_comment_start("${#now}", 2))
        self.assertTrue(shell_complexity.is_heredoc_start("cat <<EOF\n", 4))
        self.assertFalse(shell_complexity.is_heredoc_start("cat <EOF\n", 4))

    def test_grade_thresholds(self):
        """Grade mapping should follow configured CCN threshold bands."""
        self.assertEqual(shell_complexity.grade(1), "A")
        self.assertEqual(shell_complexity.grade(7), "B")
        self.assertEqual(shell_complexity.grade(12), "C")
        self.assertEqual(shell_complexity.grade(18), "D")
        self.assertEqual(shell_complexity.grade(23), "E")
        self.assertEqual(shell_complexity.grade(40), "F")

    def test_find_matching_brace_nested(self):
        """Brace matcher should find the closing brace for nested blocks."""
        script = "fn() { if true; then { echo nested; } fi; }"
        open_idx = script.index("{")
        close_idx = shell_complexity.find_matching_brace(script, open_idx)
        self.assertEqual(script[close_idx], "}")

    def test_extract_functions_and_main_block(self):
        """Function extraction should return named ranges and a main block."""
        text = "helper() { echo one; }\nmain_cmd\n"
        funcs = shell_complexity.extract_functions(text)
        self.assertEqual(len(funcs), 1)
        self.assertEqual(funcs[0][0], "helper")
        main_block = shell_complexity.main_block_from_ranges(text, funcs)
        self.assertIn("main_cmd", main_block)

    def test_analyse_script_reports_function_blocks(self):
        """Script analysis should include each function and optional main block."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            script = Path(tmp_dir) / "sample.sh"
            script.write_text("#!/bin/sh\nsample_fn() { if true; then echo ok; fi; }\n", encoding="utf-8")
            rows = shell_complexity.analyse_script(script)
            names = [row[0] for row in rows]
            self.assertIn("sample_fn", names)

    def test_analyse_paths_enforces_grade_in_repo(self):
        """Enforced analysis passes for a minimal in-repo helper script."""
        project_path = self._scratch_dir() / "sample_complexity.sh"
        project_path.write_text(
            "#!/bin/sh\nsample_fn() { echo ok; }\n",
            encoding="utf-8",
        )
        out = io.StringIO()
        err = io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            all_pass, hard_fail = shell_complexity.analyse_paths([project_path], "A", enforce=True)
        self.assertTrue(all_pass)
        self.assertFalse(hard_fail)
        self.assertIn("sample_complexity.sh", out.getvalue())

    def test_analyse_paths_rejects_outside_repo(self):
        """Analyzer should fail enforced runs for scripts outside the repository root."""
        tmp_base = Path(tempfile.gettempdir())
        if shell_complexity.is_within_repo(tmp_base):
            self.skipTest("system temp dir resolves inside repository root")
        with tempfile.TemporaryDirectory(dir=str(tmp_base)) as tmp_dir:
            external_script = Path(tmp_dir) / "outside.sh"
            external_script.write_text("#!/bin/sh\n", encoding="utf-8")
            err = io.StringIO()
            with redirect_stdout(io.StringIO()), redirect_stderr(err):
                all_pass, hard_fail = shell_complexity.analyse_paths([external_script], "A", enforce=True)
        self.assertFalse(all_pass)
        self.assertTrue(hard_fail)
        self.assertIn("outside repository root", err.getvalue())

    def test_analyse_paths_rejects_missing_paths(self):
        """Analyzer should fail enforced runs when a script path is missing."""
        missing = Path("definitely-not-a-real-shell-script.sh")
        err = io.StringIO()
        with redirect_stdout(io.StringIO()), redirect_stderr(err):
            all_pass, hard_fail = shell_complexity.analyse_paths([missing], "A", enforce=True)
        self.assertFalse(all_pass)
        self.assertTrue(hard_fail)
        self.assertIn("missing or unreadable", err.getvalue())

    def test_main_exit_codes(self):
        """CLI entrypoint should return expected exit codes across enforcement modes."""
        scratch = self._scratch_dir()
        good_script = scratch / "good.sh"
        good_script.write_text("#!/bin/sh\nsample_fn() { echo ok; }\n", encoding="utf-8")
        bad_script = scratch / "bad.sh"
        bad_script.write_text(
            "#!/bin/sh\ncomplex() {\n  if a; then if b; then if c; then if d; then if e; then if f; then :; fi; fi; fi; fi; fi; fi;\n}\n",
            encoding="utf-8",
        )

        with self.subTest("success"):
            out = io.StringIO()
            with redirect_stdout(out), redirect_stderr(io.StringIO()):
                self.assertEqual(
                    shell_complexity.main(["--max-grade", "A", str(good_script)]),
                    0,
                )
            self.assertIn("good.sh", out.getvalue())

        with self.subTest("enforce_fail"):
            out = io.StringIO()
            with redirect_stdout(out), redirect_stderr(io.StringIO()):
                self.assertEqual(
                    shell_complexity.main(["--max-grade", "A", str(bad_script)]),
                    1,
                )
            self.assertIn("CCN=7", out.getvalue())

        with self.subTest("no_enforce"):
            out = io.StringIO()
            with redirect_stdout(out), redirect_stderr(io.StringIO()):
                self.assertEqual(
                    shell_complexity.main(["--no-enforce", "--max-grade", "A", str(bad_script)]),
                    0,
                )
            self.assertIn("CCN=7", out.getvalue())

        with self.subTest("no_enforce_missing_still_fails"):
            missing = scratch / "missing.sh"
            err = io.StringIO()
            with redirect_stdout(io.StringIO()), redirect_stderr(err):
                self.assertEqual(
                    shell_complexity.main(["--no-enforce", "--max-grade", "A", str(missing)]),
                    1,
                )
            self.assertIn("missing or unreadable", err.getvalue())


if __name__ == "__main__":
    unittest.main()
