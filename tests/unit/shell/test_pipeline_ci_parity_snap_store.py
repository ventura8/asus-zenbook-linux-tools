"""Snap Store publish wiring guards for the tag release workflow."""

from __future__ import annotations

import unittest
from pathlib import Path

from tests.unit.shell.ci_workflow_utils import workflow_section


class TestSnapStorePublishWiring(unittest.TestCase):
    """Every tag release must attempt the store upload and fail when it cannot."""

    @classmethod
    def setUpClass(cls) -> None:
        """Load the release workflow and its store publish job once."""
        repo_root = Path(__file__).resolve().parents[3]
        cls.workflow = (repo_root / ".github/workflows/ppa-release.yml").read_text(encoding="utf-8")
        cls.job = cls.workflow[cls.workflow.index("  publish-snap-store:") :]

    def test_job_survives_unrelated_build_failures_and_uses_the_built_snap(self) -> None:
        """Only a failed PPA upload skips it; it publishes the release build artifact."""
        self.assertIn("if: ${{ !cancelled() && needs.upload-to-ppa.result == 'success' }}", self.job)
        self.assertIn("needs: [upload-to-ppa, build-packages]", self.job)
        self.assertIn("name: release-pkg-snap", self.job)

    def test_missing_credentials_fail_closed(self) -> None:
        """An unset store secret is a job failure, never a silent skip."""
        self.assertIn("secrets.SNAPCRAFT_STORE_CREDENTIALS", self.job)
        self.assertIn('if [ -z "$SNAPCRAFT_STORE_CREDENTIALS" ]; then', self.job)
        self.assertNotIn("continue-on-error", self.job)
        self.assertNotIn("|| true", self.job)

    def test_upload_releases_to_stable(self) -> None:
        """Upload and channel release happen in one snapcraft call."""
        self.assertIn('snapcraft upload --release=stable "${snaps[0]}"', self.job)

    def test_github_release_does_not_wait_for_the_store(self) -> None:
        """A store refusal must not withhold the GitHub Release assets."""
        release_job = workflow_section(self.workflow, "  github-release:", "  publish-snap-store:")
        self.assertIn("needs: [upload-to-ppa, build-packages]", release_job)


if __name__ == "__main__":
    unittest.main()
