"""Shared fixtures for Docker matrix runner unit tests."""

import functools
import os
import shutil
import tempfile
import unittest
from pathlib import Path

import yaml

from tests.unit.shell.shell_test_utils import run_shell_argv

EXPECTED_DISTROS = (
    "ubuntu:26.04",
    "debian:trixie",
    "fedora:44",
    "rocky:10",
    "opensuse/tumbleweed",
    "archlinux:latest",
    "opensuse/leap:16.0",
    "almalinux:10",
    "manjarolinux/base:latest",
)

_DISTRO_TESTS_FAMILY_JOBS = (
    "distro-tests-debian",
    "distro-tests-rhel",
    "distro-tests-suse-arch",
)

_FULL_DE_FAMILY_JOBS = (
    "distro-full-de-debian",
    "distro-full-de-rhel",
    "distro-full-de-suse-arch",
)


@functools.lru_cache(maxsize=32)
def _cached_supported_distros(script_path: str, path: str, docker_bin: str) -> tuple[str, ...]:
    """Return supported distros for an explicit matrix runner environment."""
    env = os.environ.copy()
    env["PATH"] = path
    env["DOCKER_BIN"] = docker_bin
    proc = run_shell_argv(
        ["bash", script_path, "--print-supported-distros"],
        env=env,
        timeout=30,
    )
    if proc.returncode != 0:
        raise AssertionError(proc.stderr)
    return tuple(line.strip() for line in proc.stdout.splitlines() if line.strip())


class DockerMatrixFixture(unittest.TestCase):
    """Stub docker PATH and helpers for matrix runner TestCases."""

    @classmethod
    def setUpClass(cls):
        """Create class-scoped stub docker bin and base env for stable lru_cache keys."""
        cls.repo_root = Path(__file__).resolve().parents[3]
        cls.script_path = cls.repo_root / "scripts" / "run_docker_matrix.sh"

        cls._tmp_dir = tempfile.mkdtemp()
        cls.fake_bin = Path(cls._tmp_dir) / "bin"
        cls.fake_bin.mkdir(parents=True, exist_ok=True)
        cls.docker_bin = cls.fake_bin / "docker"
        cls.docker_bin.write_text("#!/bin/sh\necho docker stub\n", encoding="utf-8")
        cls.docker_bin.chmod(0o755)

        cls._base_env = os.environ.copy()
        cls._base_env["PATH"] = f"{cls.fake_bin}:{cls._base_env['PATH']}"
        cls._base_env["DOCKER_BIN"] = str(cls.docker_bin)

    @classmethod
    def tearDownClass(cls):
        """Remove the class-scoped stub directory."""
        shutil.rmtree(cls._tmp_dir, ignore_errors=True)

    def setUp(self):
        """Give each test an isolated copy of the class Docker environment."""
        self.env = self._base_env.copy()

    def _run_docker_matrix(self, *args: str):
        """Run run_docker_matrix.sh with the prepared test environment."""
        return run_shell_argv(
            ["bash", str(self.script_path), *args],
            env=self.env,
            timeout=30,
        )

    def _list_supported_distros(self) -> list[str]:
        """Return distro images from the matrix runner's supported-distros surface."""
        return list(
            _cached_supported_distros(
                str(self.script_path),
                self._base_env["PATH"],
                self._base_env["DOCKER_BIN"],
            )
        )

    @staticmethod
    def _job_matrix_images(jobs: dict, name: str) -> list[str]:
        """Return matrix.image list for a CI job, or raise if missing."""
        job = jobs.get(name) or {}
        images = (job.get("strategy") or {}).get("matrix", {}).get("image")
        if not images:
            raise AssertionError(f"Could not parse {name} matrix images from ci.yml")
        return list(images)

    @staticmethod
    def _ci_matrix_distro_images(repo_root: Path) -> list[str]:
        """Load distro images from family-split distro-tests-* jobs in ci.yml."""
        data = yaml.safe_load((repo_root / ".github/workflows/ci.yml").read_text(encoding="utf-8"))
        jobs = data.get("jobs") or {}
        images: list[str] = []
        for name in _DISTRO_TESTS_FAMILY_JOBS:
            images.extend(DockerMatrixFixture._job_matrix_images(jobs, name))
        return images

    @staticmethod
    def _dockerfile_for_distro_image(repo_root: Path, image: str) -> Path:
        """Map a matrix distro image to its docker/images/tests Dockerfile path."""
        slug = image.replace(":", "-").replace("/", "-")
        return repo_root / "docker/images/tests" / f"{slug}.Dockerfile"

    def _assert_ci_on_triggers(self, data, ci_text):
        """Assert ci.yml runs on push/PR and is not schedule-only nightly."""
        on_block = data.get("on")
        if on_block is None:
            on_block = data.get(True) or {}
        if isinstance(on_block, dict) and on_block is not True:
            self.assertIn("push", on_block)
            self.assertIn("pull_request", on_block)
            self.assertNotIn("schedule", on_block)
        else:
            # PyYAML may parse "on" as True; fall back to raw text triggers.
            self.assertIn("push:", ci_text)
            self.assertIn("pull_request:", ci_text)
        self.assertNotIn("\nschedule:", ci_text)

    def _assert_nested_proof_scripts(self):
        """Assert nested/full-DE helper scripts exist and hard-require packages."""
        for rel in (
            "scripts/distro_nested_session_smoke.sh",
            "scripts/distro_movefocused_nested_e2e.sh",
            "scripts/distro_sticky_osd_uinput_e2e.sh",
            "scripts/distro_install_smoke_full_de.sh",
            "docker/images/tests/scripts/install-de-family.sh",
            "docker/images/tests/scripts/pacman-retry.sh",
            "docker/images/tests/scripts/archlinux-mirrorlist",
            "docker/images/tests/scripts/el10-kcov-libcurl.sh",
        ):
            path = self.repo_root / rel
            self.assertTrue(path.is_file(), msg=rel)
        mf = (self.repo_root / "scripts/distro_movefocused_nested_e2e.sh").read_text(encoding="utf-8")
        sticky = (self.repo_root / "scripts/distro_sticky_osd_uinput_e2e.sh").read_text(encoding="utf-8")
        full_de_smoke = (self.repo_root / "scripts/distro_install_smoke_full_de.sh").read_text(encoding="utf-8")
        self.assertIn("_require_runtime_pkgs", mf)
        self.assertIn("required command missing after CI install", mf)
        self.assertIn("--headless", mf)
        self.assertIn("_require_runtime_pkgs", sticky)
        self.assertIn("lxqt-globalkeysd", full_de_smoke)
        self.assertNotIn("lxqt) need=()", full_de_smoke)

    def _assert_alma_xfce_matrix_kept(self, full_de) -> None:
        """Alma XFCE builds xfconf from source — do not exclude that matrix cell."""
        excludes = (full_de.get("strategy") or {}).get("matrix", {}).get("exclude") or []
        self.assertNotIn({"image": "almalinux:10", "de_family": "xfce"}, excludes)
        self.assertIn({"image": "almalinux:10", "de_family": "lxqt"}, excludes)

    def _assert_full_de_family_jobs(self, jobs: dict) -> None:
        """Assert family-split full-DE jobs cover nine images with max-parallel 20."""
        self.assertNotIn("distro-full-de", jobs)
        images: list[str] = []
        for name in _FULL_DE_FAMILY_JOBS:
            self.assertIn(name, jobs)
            images.extend(self._job_matrix_images(jobs, name))
            self.assertEqual((jobs[name].get("strategy") or {}).get("max-parallel"), 20)
        self.assertEqual(len(images), 9)
        self.assertNotIn("almalinux:9", images)
        self._assert_alma_xfce_matrix_kept(jobs["distro-full-de-rhel"])

    @staticmethod
    def _consume_dockerfile_continuation(pending: str, line: str) -> tuple[str | None, str]:
        """Fold one continuation line into *pending*; return (joined, next_pending)."""
        if not line.strip():
            return None, pending
        pending = f"{pending} {line.lstrip()}"
        if pending.rstrip().endswith("\\"):
            return None, pending.rstrip()[:-1].rstrip()
        return pending, ""

    @staticmethod
    def _start_or_append_install_line(joined: list[str], line: str, install_token: str) -> str:
        """Append a complete install line or return a new pending continuation."""
        if install_token not in line:
            return ""
        if line.rstrip().endswith("\\"):
            return line.rstrip()[:-1].rstrip()
        joined.append(line)
        return ""

    @staticmethod
    def _joined_dockerfile_install_commands(text: str, install_token: str) -> list[str]:
        """Join Dockerfile continuation lines that belong to *install_token* commands."""
        joined: list[str] = []
        pending = ""
        for raw in text.splitlines():
            line = raw.rstrip()
            if pending:
                complete, pending = DockerMatrixFixture._consume_dockerfile_continuation(pending, line)
                if complete is not None:
                    joined.append(complete)
                continue
            pending = DockerMatrixFixture._start_or_append_install_line(joined, line, install_token)
        if pending:
            joined.append(pending)
        return joined
