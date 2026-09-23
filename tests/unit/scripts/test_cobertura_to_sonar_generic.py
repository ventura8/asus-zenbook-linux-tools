"""Unit tests for the kcov Cobertura to SonarQube generic coverage converter."""

from __future__ import annotations

import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
from xml.etree import ElementTree

from tests.unit.scripts.script_module_loader import load_scripts_module

_CONVERTER = load_scripts_module(
    "cobertura_to_sonar_generic",
    ("scripts", "coverage", "cobertura_to_sonar_generic.py"),
)

_COBERTURA = """<?xml version="1.0" ?>
<!DOCTYPE coverage SYSTEM 'http://cobertura.sourceforge.net/xml/coverage-04.dtd'>
<coverage line-rate="0.5">
  <sources><source>/workspace/</source></sources>
  <packages><package name="">
    <classes>
      <class name="a_sh__1" filename="bin/a.sh">
        <lines>
          <line number="1" hits="3"/>
          <line number="2" hits="0"/>
          <line number="0" hits="1"/>
          <line number="bad" hits="1"/>
          <line number="4"/>
        </lines>
      </class>
      <class name="a_sh__2" filename="bin/a.sh">
        <lines><line number="2" hits="7"/></lines>
      </class>
      <class name="no_filename"><lines><line number="9" hits="1"/></lines></class>
    </classes>
  </package></packages>
</coverage>
"""


def _write(directory: Path, name: str, text: str) -> Path:
    """Write *text* to ``directory/name`` and return the path."""
    path = directory / name
    path.write_text(text, encoding="utf-8")
    return path


def _run_main(*argv: str) -> tuple[int, str, str]:
    """Run the CLI with *argv*, capturing exit code, stdout and stderr."""
    out, err = StringIO(), StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        code = _CONVERTER.main(list(argv))
    return code, out.getvalue(), err.getvalue()


class TestConversion(unittest.TestCase):
    """Cobertura input becomes SonarQube generic coverage."""

    def test_converts_lines_and_merges_duplicate_classes(self) -> None:
        """Duplicate class blocks merge per line, keeping the highest hit count."""
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            source = _write(base, "cobertura.xml", _COBERTURA)
            destination = base / "out" / "shell-coverage.xml"
            self.assertEqual(_CONVERTER.convert(source, destination, base), 1)
            root = ElementTree.parse(destination).getroot()
            self.assertEqual(root.tag, "coverage")
            self.assertEqual(root.get("version"), "1")
            files = root.findall("file")
            self.assertEqual([node.get("path") for node in files], ["bin/a.sh"])
            covered = {
                node.get("lineNumber"): node.get("covered")
                for node in files[0].findall("lineToCover")
            }
            # Line 2 is 0 hits in one class and 7 in another: covered wins.
            self.assertEqual(covered, {"1": "true", "2": "true"})

    def test_skips_unusable_line_and_class_entries(self) -> None:
        """Line 0, non-numeric numbers, missing hits and unnamed classes drop out."""
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            source = _write(base, "cobertura.xml", _COBERTURA)
            destination = base / "shell-coverage.xml"
            _CONVERTER.convert(source, destination, base)
            body = destination.read_text(encoding="utf-8")
            for dropped in ('lineNumber="0"', 'lineNumber="4"', 'lineNumber="9"'):
                self.assertNotIn(dropped, body)


class TestRefusedInput(unittest.TestCase):
    """Malformed, hostile, or empty reports never yield a coverage file."""

    def test_entity_declaration_is_refused(self) -> None:
        """Internal entity declarations (billion laughs) are rejected."""
        hostile = (
            '<?xml version="1.0"?>\n'
            '<!DOCTYPE coverage [<!ENTITY lol "lol">]>\n'
            "<coverage><packages/></coverage>\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            source = _write(base, "cobertura.xml", hostile)
            code, _, err = _run_main(
                str(source), str(base / "out.xml"), "--base", str(base)
            )
            self.assertEqual(code, 1)
            self.assertIn("entity declarations", err)
            self.assertFalse((base / "out.xml").exists())

    def test_empty_report_writes_nothing_and_clears_stale_output(self) -> None:
        """No files means no report, and any previous report is removed."""
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            source = _write(
                base, "cobertura.xml", "<coverage><packages/></coverage>\n"
            )
            destination = _write(base, "shell-coverage.xml", "<coverage/>\n")
            code, _, err = _run_main(
                str(source), str(destination), "--base", str(base)
            )
            self.assertEqual(code, 1)
            self.assertIn("No files found", err)
            self.assertFalse(destination.exists())

    def test_malformed_xml_is_reported(self) -> None:
        """A truncated document fails with a clear message, not a traceback."""
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            source = _write(base, "cobertura.xml", "<coverage><packages>\n")
            code, _, err = _run_main(
                str(source), str(base / "out.xml"), "--base", str(base)
            )
            self.assertEqual(code, 1)
            self.assertIn("Malformed Cobertura report", err)

    def test_missing_source_is_reported(self) -> None:
        """A missing input path fails before any output is created."""
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            code, _, err = _run_main(
                str(base / "nope.xml"), str(base / "out.xml"), "--base", str(base)
            )
            self.assertEqual(code, 1)
            self.assertIn("Missing Cobertura report", err)
            self.assertFalse((base / "out.xml").exists())

    def test_destination_outside_base_is_refused(self) -> None:
        """Writes may not escape the output root the caller names."""
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            outside = base / "outside"
            outside.mkdir()
            root = base / "reports"
            root.mkdir()
            source = _write(base, "cobertura.xml", _COBERTURA)
            code, _, err = _run_main(
                str(source), "../outside/escape.xml", "--base", str(root)
            )
            self.assertEqual(code, 1)
            self.assertIn("path escapes", err)
            self.assertFalse((outside / "escape.xml").exists())


    def test_source_outside_source_base_is_refused(self) -> None:
        """Reads may not escape the input root the caller names."""
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            merged = base / "merged"
            merged.mkdir()
            outside = _write(base, "cobertura.xml", _COBERTURA)
            code, _, err = _run_main(
                str(outside),
                str(base / "out.xml"),
                "--base",
                str(base),
                "--source-base",
                str(merged),
            )
            self.assertEqual(code, 1)
            self.assertIn("path escapes", err)
            self.assertFalse((base / "out.xml").exists())


class TestSeparateRoots(unittest.TestCase):
    """The CI shape: read from a temp merged tree, write into reports/."""

    def test_source_and_destination_may_use_different_roots(self) -> None:
        """A merged temp dir source writes into an unrelated reports root."""
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            merged = base / "merged" / "kcov-merged"
            merged.mkdir(parents=True)
            reports = base / "reports"
            reports.mkdir()
            source = _write(merged, "cobertura.xml", _COBERTURA)
            destination = reports / "coverage" / "merged" / "shell-coverage.xml"
            code, out, _ = _run_main(
                str(source),
                str(destination),
                "--base",
                str(reports),
                "--source-base",
                str(merged.parent),
            )
            self.assertEqual(code, 0)
            self.assertIn("(1 files)", out)
            self.assertTrue(destination.is_file())


class TestCliSuccess(unittest.TestCase):
    """Successful runs report what they wrote."""

    def test_main_reports_file_count(self) -> None:
        """A good conversion exits 0 and names the destination."""
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            source = _write(base, "cobertura.xml", _COBERTURA)
            destination = base / "shell-coverage.xml"
            code, out, _ = _run_main(
                str(source), str(destination), "--base", str(base)
            )
            self.assertEqual(code, 0)
            self.assertIn("(1 files)", out)
            self.assertTrue(destination.is_file())


if __name__ == "__main__":
    unittest.main()
