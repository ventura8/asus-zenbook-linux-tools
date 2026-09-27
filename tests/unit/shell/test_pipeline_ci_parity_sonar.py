"""SonarQube analysis wiring guards: report paths and the CI sonar job."""

from __future__ import annotations

import unittest
from pathlib import Path

from tests.unit.shell.ci_workflow_utils import workflow_section


class TestSonarQubeAnalysisWiring(unittest.TestCase):
    """SonarQube job must consume the coverage the pipeline already produces."""

    @classmethod
    def setUpClass(cls) -> None:
        """Resolve repository root once for SonarQube wiring checks."""
        cls.repo_root = Path(__file__).resolve().parents[3]

    def test_sonar_properties_point_at_pipeline_coverage_reports(self) -> None:
        """Report paths must match what the coverage-merge step writes."""
        props = (self.repo_root / "sonar-project.properties").read_text(encoding="utf-8")
        self.assertIn(
            "sonar.python.coverage.reportPaths=reports/coverage/merged/coverage.xml",
            props,
        )
        # Shell coverage must be Sonar generic XML, never kcov's Cobertura:
        # sonar.coverageReportPaths rejects Cobertura and fails the scan.
        self.assertIn(
            "sonar.coverageReportPaths=reports/coverage/merged/shell-coverage.xml",
            props,
        )
        self.assertNotIn("sonar.coverageReportPaths=reports/kcov", props)
        self.assertIn("sonar.projectKey=", props)
        self.assertIn("sonar.organization=", props)

    def test_merge_step_writes_python_xml_for_sonar(self) -> None:
        """merge_python_coverage_shards must emit the XML Sonar reads."""
        gates = (self.repo_root / "scripts/coverage/gates_python.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("_write_merged_python_coverage_xml", gates)
        self.assertIn("coverage/merged", gates)
        # Shell conversion must read the merged tree inside the kcov merge, before
        # that temp dir is removed: the host merge never writes reports/kcov/<slug>/.
        kcov_gates = (self.repo_root / "scripts/coverage/gates_kcov.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("_write_sonar_generic_shell_coverage", kcov_gates)
        self.assertIn(
            '_write_sonar_generic_shell_coverage "$merged" "$reports_root"', kcov_gates
        )
        self.assertIn("coverage/merged/shell-coverage.xml", kcov_gates)
        self.assertTrue(
            (self.repo_root / "scripts/coverage/cobertura_to_sonar_generic.py").is_file()
        )

    def test_ci_sonar_job_uploads_and_consumes_merged_reports(self) -> None:
        """coverage-merge uploads merged reports; the sonar job downloads them."""
        workflow = (self.repo_root / ".github/workflows/ci.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("name: coverage-merged-reports", workflow)
        self.assertIn("reports/coverage/merged/shell-coverage.xml", workflow)
        self.assertNotIn("reports/kcov/coverage-gate-kcov-all", workflow)
        sonar = workflow_section(workflow, "  sonarqube:", "  distro-tests-debian:")
        self.assertIn("needs: coverage-merge", sonar)
        self.assertIn("fetch-depth: 0", sonar)
        self.assertIn("SonarSource/sonarqube-scan-action@", sonar)
        # upload-artifact strips the common ancestor: unpack into the directory
        # the properties name, or the generic-coverage sensor fails the scan.
        self.assertIn("path: reports/coverage/merged", sonar)
        # Missing reports must warn and blank the property, not fail the scan.
        self.assertIn("-Dsonar.coverageReportPaths=", sonar)
        self.assertIn("-Dsonar.python.coverage.reportPaths=", sonar)
        self.assertIn("SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}", sonar)
        # Fork PRs have no SONAR_TOKEN; the job must not run there.
        self.assertIn(
            "github.event.pull_request.head.repo.full_name == github.repository",
            sonar,
        )


if __name__ == "__main__":
    unittest.main()
