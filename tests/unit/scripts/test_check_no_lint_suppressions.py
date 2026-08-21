"""Tests for the no-lint-suppressions gate."""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from scripts.check_no_lint_suppressions import (
    _iter_scanned_files,
    find_lint_suppressions,
    main,
)

REPO_ROOT = Path(__file__).resolve().parents[3]


class TestNoLintSuppressionsGate(unittest.TestCase):
    """Verify suppressions are detected and clean trees pass."""

    def test_flags_inline_noqa_and_shellcheck_disable(self) -> None:
        """Inline noqa and shellcheck disable comments must fail the gate."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            (root / "bin").mkdir()
            bad_py = root / "bin" / "bad.py"
            bad_py.write_text("x = 1  # " + "noqa\n", encoding="utf-8")
            bad_sh = root / "bin" / "bad.sh"
            bad_sh.write_text("# shellcheck " + "disable" + "=SC2086\n", encoding="utf-8")
            hits = find_lint_suppressions(root)
            paths = {rel for rel, _lineno, _line in hits}
            self.assertIn("bin/bad.py", paths)
            self.assertIn("bin/bad.sh", paths)

    def test_flags_suppressions_under_tests_tree(self) -> None:
        """Unit and e2e test modules must not be exempt from the gate."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            unit = root / "tests" / "unit" / "bin"
            e2e = root / "tests" / "e2e" / "mock"
            unit.mkdir(parents=True)
            e2e.mkdir(parents=True)
            unit_bad = unit / "test_bad.py"
            e2e_bad = e2e / "test_bad.py"
            unit_bad.write_text("x = 1  # " + "noqa\n", encoding="utf-8")
            e2e_bad.write_text("# " + "type: ignore\n", encoding="utf-8")
            hits = find_lint_suppressions(root)
            paths = {rel for rel, _lineno, _line in hits}
            self.assertIn("tests/unit/bin/test_bad.py", paths)
            self.assertIn("tests/e2e/mock/test_bad.py", paths)

    def test_iter_scanned_files_includes_tests_package(self) -> None:
        """Walk discovery must include files under tests/ (no test exemption)."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            target_dir = root / "tests" / "unit"
            target_dir.mkdir(parents=True)
            sample = target_dir / "sample.py"
            sample.write_text("x = 1\n", encoding="utf-8")
            rels = [p.relative_to(root).as_posix() for p in _iter_scanned_files(root)]
            self.assertIn("tests/unit/sample.py", rels)

    def test_live_repo_tests_have_no_suppressions(self) -> None:
        """Shipped tests/ tree must stay clean (same rule as product code)."""
        hits = [
            hit
            for hit in find_lint_suppressions(REPO_ROOT)
            if hit[0].startswith("tests/")
        ]
        self.assertEqual(hits, [], msg=f"suppressions under tests/: {hits}")

    def test_live_repo_has_no_suppressions(self) -> None:
        """Whole scanned repo (including tests) must have zero suppressions."""
        hits = find_lint_suppressions(REPO_ROOT)
        self.assertEqual(hits, [], msg=f"repo suppressions: {hits}")

    def test_markdown_html_directive_not_policy_prose(self) -> None:
        """HTML-comment markdownlint directives fail; naming the token in prose does not."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            docs = root / "docs"
            docs.mkdir()
            directive = "<!-- " + "markdownlint-disable" + " MD013 -->\n"
            (docs / "bad.md").write_text(directive, encoding="utf-8")
            (docs / "policy.md").write_text(
                "Never use "
                + "markdownlint-disable"
                + " in docs; only HTML comments after "
                + "`<!--` count.\n",
                encoding="utf-8",
            )
            hits = find_lint_suppressions(root)
            paths = {rel for rel, _lineno, _line in hits}
            self.assertIn("docs/bad.md", paths)
            self.assertNotIn("docs/policy.md", paths)

    def test_flags_pylintrc_disable_list(self) -> None:
        """A pylintrc disable= list must fail the gate."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            rc = root / ".pylintrc"
            rc.write_text("[MESSAGES CONTROL]\n" + "disable" + " = C0114\n", encoding="utf-8")
            hits = find_lint_suppressions(root)
            self.assertTrue(any(rel == ".pylintrc" for rel, _n, _l in hits))

    def test_clean_tree_returns_empty(self) -> None:
        """A tree without suppressions must report no hits."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            (root / "bin").mkdir()
            (root / "bin" / "ok.py").write_text("x = 1\n", encoding="utf-8")
            (root / "tests" / "unit").mkdir(parents=True)
            (root / "tests" / "unit" / "ok.py").write_text("x = 1\n", encoding="utf-8")
            self.assertEqual(find_lint_suppressions(root), [])

    def test_main_exits_nonzero_on_hits(self) -> None:
        """CLI main must return 1 when suppressions exist in cwd."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            (root / "tests" / "unit").mkdir(parents=True)
            (root / "tests" / "unit" / "bad.py").write_text(
                "x = 1  # " + "noqa\n", encoding="utf-8"
            )
            prior = Path.cwd()
            try:
                os.chdir(root)
                self.assertEqual(main([]), 1)
            finally:
                os.chdir(prior)


if __name__ == "__main__":
    unittest.main()
