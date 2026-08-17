"""Unit tests for the Docker matrix runner."""

import functools
import os
import shlex
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


class _DockerMatrixFixture(unittest.TestCase):
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
            images.extend(_DockerMatrixFixture._job_matrix_images(jobs, name))
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
        """Assert family-split full-DE jobs cover nine images with max-parallel 8."""
        self.assertNotIn("distro-full-de", jobs)
        images: list[str] = []
        for name in _FULL_DE_FAMILY_JOBS:
            self.assertIn(name, jobs)
            images.extend(self._job_matrix_images(jobs, name))
            self.assertEqual((jobs[name].get("strategy") or {}).get("max-parallel"), 8)
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
                complete, pending = _DockerMatrixFixture._consume_dockerfile_continuation(pending, line)
                if complete is not None:
                    joined.append(complete)
                continue
            pending = _DockerMatrixFixture._start_or_append_install_line(joined, line, install_token)
        if pending:
            joined.append(pending)
        return joined


class TestDockerMatrixRunner(_DockerMatrixFixture):
    """Dry-run matrix surfaces and always-on distro list parity."""

    def test_supported_distros_match_ci_and_dockerfiles(self):
        """Matrix runner, CI workflow, and test Dockerfiles must list the same distros."""
        supported = self._list_supported_distros()
        ci_images = self._ci_matrix_distro_images(self.repo_root)
        self.assertEqual(sorted(supported), sorted(ci_images))
        self.assertEqual(
            len(supported),
            len(EXPECTED_DISTROS),
            msg=f"always-on matrix must match EXPECTED_DISTROS: {supported}",
        )
        self.assertEqual(set(supported), set(EXPECTED_DISTROS))
        self.assertNotIn("almalinux:9", supported)
        for image in supported:
            dockerfile = self._dockerfile_for_distro_image(self.repo_root, image)
            self.assertTrue(dockerfile.is_file(), msg=str(dockerfile))
            text = dockerfile.read_text(encoding="utf-8")
            self.assertIn("ARG ASUS_CI_DE_FAMILY=", text)
            self.assertIn("install-de-family.sh", text)

    def test_dry_run_de_family_is_reported(self):
        """Dry-run with --de-family reports runtime DE install (F1, not baked tag)."""
        proc = self._run_docker_matrix(
            "--dry-run",
            "--compat-only",
            "--distro",
            "ubuntu:26.04",
            "--de-family",
            "gnome",
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        output = proc.stdout.lower()
        self.assertIn("ubuntu-26.04", output)
        self.assertIn("asus_ci_de_family=gnome", output)
        self.assertIn("runtime install-de-family", output)
        self.assertNotIn("asus-zenbook-test:ubuntu-26.04-de-gnome", output)

    def test_full_de_build_uses_stub_image_tag(self):
        """F1: --de-family must share the stub image tag with distro-tests."""
        script = (self.repo_root / "scripts/run_docker_matrix.sh").read_text(encoding="utf-8")
        self.assertIn("runtime ASUS_CI_DE_FAMILY", script)
        self.assertIn("_matrix_runtime_de_install_snippet", script)
        self.assertIn("install-de-family.sh", script)
        self.assertNotIn('tag="${tag}-de-${DE_FAMILY}"', script)
        self.assertNotIn('cache_key="${cache_key}__de_${DE_FAMILY}"', script)

    def test_ci_full_de_and_nested_jobs_are_always_on(self):
        """Full-DE family matrices + nested proofs live in push/PR ci.yml."""
        ci_path = self.repo_root / ".github/workflows/ci.yml"
        ci_text = ci_path.read_text(encoding="utf-8")
        data = yaml.safe_load(ci_text)
        jobs = data.get("jobs") or {}
        self._assert_full_de_family_jobs(jobs)
        self.assertIn("nested-session", jobs)
        self.assertIn("movefocused-nested", jobs)
        self.assertIn("sticky-osd-uinput", jobs)
        self._assert_ci_on_triggers(data, ci_text)
        self.assertFalse((self.repo_root / ".github/workflows/distro-full-de.yml").exists())
        self._assert_nested_proof_scripts()
        self.assertIn("gnome-shell", ci_text)
        self.assertIn("mutter", ci_text)
        self.assertIn("ydotool", ci_text)

    def test_install_de_family_kde_and_el10_xfconf(self):
        """Rocky/Alma 10 KDE use kf6; legacy rhel keeps kf5; EL10 XFCE builds xfconf."""
        script = (self.repo_root / "docker/images/tests/scripts/install-de-family.sh").read_text(encoding="utf-8")
        self.assertIn("kf6-kconfig", script)
        self.assertIn("kf5-kconfig", script)
        self.assertIn("rocky|almalinux|rhel", script)
        self.assertIn("_dnf_packages_for_family", script)
        self.assertIn("_install_xfconf_from_source", script)
        self.assertIn("_XFCONF_TARBALL_SHA256", script)
        self.assertNotIn("almalinux-xfce", script)
        # Alma images may ship curl-minimal; do not dnf-install conflicting curl.
        self.assertNotRegex(
            script,
            r"build_pkgs=\([\s\S]*?\bcurl\b",
        )
        self.assertIn("_skip_rhel_unpackaged_de", script)
        full_de = (self.repo_root / "scripts/distro_install_smoke_full_de.sh").read_text(encoding="utf-8")
        self.assertIn("kwriteconfig5", full_de)
        self.assertIn("_smoke_require_any_full_de_cli", full_de)

    def test_arch_family_images_retry_pacman_on_mirror_404(self):
        """Arch/Manjaro image builds retry pacman -Syu/-S for rolling-mirror 404s."""
        helper = (self.repo_root / "docker/images/tests/scripts/pacman-retry.sh").read_text(encoding="utf-8")
        self.assertIn("pacman -Syy", helper)
        de_family = (self.repo_root / "docker/images/tests/scripts/install-de-family.sh").read_text(encoding="utf-8")
        self.assertIn("pacman-retry.sh", de_family)
        self.assertIn("_pacman_retry_cmd", de_family)
        mirrors = (self.repo_root / "docker/images/tests/scripts/archlinux-mirrorlist").read_text(encoding="utf-8")
        self.assertIn("mirror.rackspace.com", mirrors)
        self.assertNotIn("geo.mirror.pkgbuild.com", mirrors)
        self.assertNotIn("fastly.mirror.pkgbuild.com", mirrors)
        arch = (self.repo_root / "docker/images/tests/archlinux-latest.Dockerfile").read_text(encoding="utf-8")
        self.assertIn("archlinux-mirrorlist", arch)
        self.assertIn("pacman-retry.sh", arch)
        self.assertNotIn("RUN pacman -Syu", arch)
        manjaro = (self.repo_root / "docker/images/tests/manjarolinux-base-latest.Dockerfile").read_text(encoding="utf-8")
        self.assertIn("pacman-retry.sh", manjaro)
        self.assertNotIn("RUN pacman -Syu", manjaro)
        self.assertNotIn("archlinux-mirrorlist", manjaro)

    def test_el10_images_install_matching_libcurl_devel(self):
        """Rocky/Alma kcov must install libcurl-devel at the installed libcurl VR."""
        helper = (self.repo_root / "docker/images/tests/scripts/el10-kcov-libcurl.sh").read_text(encoding="utf-8")
        self.assertIn("libcurl-devel-", helper)
        self.assertIn("--nobest", helper)
        self.assertNotIn("--skip-broken", helper)
        for name in ("rocky-10.Dockerfile", "almalinux-10.Dockerfile"):
            text = (self.repo_root / "docker/images/tests" / name).read_text(encoding="utf-8")
            self.assertIn("el10-kcov-libcurl.sh", text)
            joined = "\n".join(self._joined_dockerfile_install_commands(text, "dnf -y install"))
            self.assertNotIn("curl-minimal", joined)
            self.assertNotIn("libcurl-devel-*", joined)

    def test_dry_run_de_family_defaults_full_de_smoke(self):
        """Local --de-family implies ASUS_CI_FULL_DE=1 for real CLI probes."""
        proc = self._run_docker_matrix(
            "--dry-run",
            "--compat-only",
            "--distro",
            "ubuntu:26.04",
            "--de-family",
            "lxqt",
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        output = proc.stdout.lower()
        self.assertIn("asus_ci_de_family=lxqt", output)
        self.assertIn("runtime install-de-family", output)

    def test_alma_dockerfile_skips_unpackaged_rhel_tools(self):
        """AlmaLinux 10 image must not hard-require unpackaged xdotool/ydotool/evdev RPMs."""
        alma = (self.repo_root / "docker/images/tests/almalinux-10.Dockerfile").read_text(encoding="utf-8")
        alma_install = self._joined_dockerfile_install_commands(alma, "dnf -y install")
        self.assertTrue(alma_install)
        joined = "\n".join(alma_install)
        self.assertNotIn("ydotool", joined)
        self.assertNotIn("alsa-tools", joined)
        self.assertNotIn("xdotool", joined)
        self.assertNotIn("python3-evdev", joined)
        self.assertIn("almalinux:10@", alma)
        os_detect = (self.repo_root / "lib/install-os-detection.sh").read_text(encoding="utf-8")
        self.assertIn("_should_request_rpm_if_known", os_detect)
        self.assertIn("opensuse-leap", os_detect)

    def test_dry_run_lists_supported_distributions(self):
        """The Docker runner should list every supported distro in dry-run mode."""
        proc = self._run_docker_matrix("--dry-run")

        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        output = proc.stdout.lower()
        supported = self._list_supported_distros()
        for image in supported:
            self.assertIn(image.lower(), output)
        self.assertNotIn("kubuntu", output)
        self.assertNotIn("xubuntu", output)

    def test_dry_run_compat_only_mode_is_reported(self):
        """Dry-run compatibility mode should announce compatibility-only execution."""
        proc = self._run_docker_matrix("--dry-run", "--compat-only", "--distro", "ubuntu:26.04")

        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        output = proc.stdout.lower()
        self.assertIn("compatibility-only pipeline", output)
        self.assertIn("ubuntu-26.04.dockerfile", output)

    def test_distro_compat_smoke_script_exists_and_is_executable(self):
        """Matrix compatibility smoke entrypoint must exist and be runnable."""
        smoke = self.repo_root / "scripts" / "run_distro_install_smoke.sh"
        self.assertTrue(smoke.is_file())
        self.assertTrue(os.access(smoke, os.X_OK))
        desktop = self.repo_root / "scripts" / "distro_install_smoke_desktop.sh"
        live_pkg = self.repo_root / "scripts" / "distro_install_smoke_live_pkg.sh"
        self.assertTrue(desktop.is_file())
        self.assertTrue(live_pkg.is_file())
        smoke_text = smoke.read_text(encoding="utf-8")
        self.assertIn("distro_install_smoke_desktop.sh", smoke_text)
        self.assertIn("distro_install_smoke_live_pkg.sh", smoke_text)
        self.assertIn("_run_desktop_install_uninstall_cycles", smoke_text)


class TestDockerMatrixCiAndImages(_DockerMatrixFixture):
    """CI full-DE wiring, Dockerfile pins, and host UID helpers."""

    def test_ubuntu_dockerfile_includes_pygobject_and_desktop_cli_tools(self):
        """Ubuntu test image must ship PyGObject and light DESKTOP CLI packages."""
        dockerfile = (self.repo_root / "docker/images/tests/ubuntu-26.04.Dockerfile").read_text(encoding="utf-8")
        self.assertIn("python3-gi", dockerfile)
        self.assertIn("xfconf", dockerfile)
        self.assertIn("libkf6config-bin", dockerfile)
        # Still headless: no full desktop stack.
        self.assertNotIn("gnome-shell", dockerfile)
        self.assertNotIn("plasma-desktop", dockerfile)

    def test_ubuntu_dockerfile_scopes_sudo_to_ci_uid(self):
        """CI images grant passwordless sudo only to ASUS_CI_UID via #UID sudoers."""
        dockerfile = (self.repo_root / "docker/images/tests/ubuntu-26.04.Dockerfile").read_text(encoding="utf-8")
        asusci = (self.repo_root / "docker/images/tests/scripts/create-asusci-user.sh").read_text(encoding="utf-8")
        self.assertIn("ARG ASUS_CI_UID=1000", dockerfile)
        self.assertIn("create-asusci-user.sh", dockerfile)
        self.assertIn("NOPASSWD:ALL", asusci)
        self.assertIn("${ASUS_CI_UID}", asusci)
        self.assertIn("create-asusci-user: refuse", asusci)
        self.assertIn("^[1-9][0-9]*$", asusci)
        self.assertIn("_validate_positive_host_id ASUS_CI_UID", asusci)
        self.assertRegex(asusci, r"printf\s+'#%s\s+ALL=\(ALL\)\s+NOPASSWD:ALL\\n'")
        self.assertNotIn("ALL ALL=(ALL) NOPASSWD:ALL", dockerfile)
        self.assertNotIn("ALL ALL=(ALL) NOPASSWD:ALL", asusci)

    def test_docker_host_uid_gid_prefers_sudo_uid(self):
        """Under sudo, image builds must use SUDO_UID/SUDO_GID rather than root 0."""
        script = self.repo_root / "scripts" / "docker-utils.sh"
        proc = run_shell_argv(
            [
                "bash",
                "-c",
                (f"source {shlex.quote(str(script))} && ASUS_CI_UID= SUDO_UID=1001 SUDO_GID=1002 _docker_host_uid_gid"),
            ],
            env=self.env,
            timeout=10,
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertEqual(proc.stdout.strip(), "1001 1002")

    def test_docker_host_uid_gid_rejects_root(self):
        """UID/GID 0 must fail closed so create-asusci never usermods root."""
        script = self.repo_root / "scripts" / "docker-utils.sh"
        proc = run_shell_argv(
            [
                "bash",
                "-c",
                f"source {shlex.quote(str(script))} && ASUS_CI_UID=0 ASUS_CI_GID=0 _docker_host_uid_gid",
            ],
            env=self.env,
            timeout=10,
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Invalid ASUS_CI_UID", proc.stderr)

    def test_compat_smoke_wired_only_in_compat_only_pipeline(self):
        """Install smoke runs on matrix --compat-only, not coverage-gate tests-only."""
        compat = self._run_docker_matrix("--dry-run", "--compat-only", "--distro", "ubuntu:26.04")
        self.assertEqual(compat.returncode, 0, msg=compat.stderr)
        compat_out = compat.stdout.lower()
        self.assertIn("compatibility-only pipeline", compat_out)

        gate = self._run_docker_matrix("--dry-run", "--coverage-gate")
        self.assertEqual(gate.returncode, 0, msg=gate.stderr)
        gate_out = gate.stdout.lower()
        self.assertIn("tests-only pipeline", gate_out)
        self.assertNotIn("compatibility-only pipeline", gate_out)

    def test_distro_images_skip_unpackaged_ydotool(self):
        """Debian and Rocky images must not hard-require unpackaged ydotool."""
        debian = (self.repo_root / "docker/images/tests/debian-trixie.Dockerfile").read_text(encoding="utf-8")
        rocky = (self.repo_root / "docker/images/tests/rocky-10.Dockerfile").read_text(encoding="utf-8")
        debian_install_lines = self._joined_dockerfile_install_commands(debian, "apt-get install")
        rocky_install_lines = self._joined_dockerfile_install_commands(rocky, "dnf -y install")
        self.assertTrue(debian_install_lines, "expected non-empty debian apt-get install commands")
        self.assertTrue(rocky_install_lines, "expected non-empty rocky dnf install commands")
        self.assertTrue(all("ydotool" not in line for line in debian_install_lines))
        self.assertTrue(all("ydotool" not in line for line in rocky_install_lines))
        self.assertTrue(all("xdotool" not in line for line in rocky_install_lines))
        self.assertIn("rockylinux/rockylinux:10@", rocky)
        self.assertNotIn("rockylinux/rockylinux:9@", rocky)
        self.assertIn("git-[0-9]*", rocky)
        self.assertIn("gcc-[0-9]*", rocky)
        self.assertIn("gcc-c++-[0-9]*", rocky)
        self.assertIn("binutils-[0-9]*", rocky)
        self.assertIn("cmake-[0-9]*", rocky)
        self.assertIn("\n        python3.13 \\\n", rocky)
        self.assertNotIn("\n        git-* \\\n", rocky)
        self.assertNotIn("\n        binutils-* \\\n", rocky)
        self.assertNotIn("\n        python3.13-* \\\n", rocky)
        os_detect = (self.repo_root / "lib/install-os-detection.sh").read_text(encoding="utf-8")
        self.assertIn("_should_request_ydotool_deb", os_detect)
        self.assertIn("_should_request_ydotool_rpm", os_detect)
        self.assertIn("_should_request_suse_optional_pkg", os_detect)
        self.assertIn("_should_request_alsa_tools_rpm", os_detect)
        self.assertIn("_rhel_family_skips_optional_rpm", os_detect)

    def test_print_target_distros_strips_registry_before_tag(self):
        """Basename first, then digest/tag — registry:port paths must not become 'registry'."""
        script = shlex.quote(str(self.script_path))
        proc = run_shell_argv(
            [
                "bash",
                "-c",
                (
                    f"source {script} && _print_target_distros "
                    "registry:5000/team/ubuntu:26.04 "
                    "opensuse/tumbleweed "
                    "manjarolinux/base:latest "
                    "ubuntu@sha256:deadbeef"
                ),
            ],
            env=self.env,
            timeout=10,
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertIn("- ubuntu -> registry:5000/team/ubuntu:26.04", proc.stdout)
        self.assertIn("- tumbleweed -> opensuse/tumbleweed", proc.stdout)
        self.assertIn("- base -> manjarolinux/base:latest", proc.stdout)
        self.assertIn("- ubuntu -> ubuntu@sha256:deadbeef", proc.stdout)

    def test_dry_run_distro_family_expands_debian_slice(self):
        """--distro-family debian selects ubuntu + debian lanes only."""
        proc = self._run_docker_matrix("--dry-run", "--compat-only", "--distro-family", "debian")
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        out = proc.stdout
        self.assertIn("ubuntu:26.04", out)
        self.assertIn("debian:trixie", out)
        self.assertNotIn("fedora:44", out)
        self.assertNotIn("rocky:10", out)

    def test_dry_run_coverage_gate_target_is_reported(self):
        """Dry-run coverage-gate mode should reuse the debian:trixie Dockerfile."""
        proc = self._run_docker_matrix("--dry-run", "--coverage-gate")

        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        output = proc.stdout.lower()
        self.assertIn("coverage-gate", output)
        self.assertIn("debian-trixie.dockerfile", output)


if __name__ == "__main__":
    unittest.main()
