"""CI full-DE wiring and Dockerfile pin tests for the Docker matrix."""

import shlex
import tempfile
import unittest
from pathlib import Path

from tests.unit.shell.docker_matrix_test_base import DockerMatrixFixture
from tests.unit.shell.shell_test_utils import run_shell_argv


class TestDockerMatrixCiAndImages(DockerMatrixFixture):
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

    def test_kill_pgid_list_terminates_sibling_group(self) -> None:
        """Fail-fast cleanup must terminate sibling process groups, not only leaders."""
        script = shlex.quote(str(self.repo_root / "scripts/docker-utils.sh"))
        proc = run_shell_argv(
            [
                "bash",
                "-c",
                (
                    f"source {script}; "
                    "child_file=$(mktemp); "
                    "setsid bash -c 'sleep 30 & echo $! >\"$1\"; wait' bash \"$child_file\" & "
                    "leader_pid=$!; "
                    "for _ in 1 2 3 4 5 6 7 8 9 10; do "
                    "[ -s \"$child_file\" ] && break; sleep 0.1; "
                    "done; "
                    "child_pid=$(cat \"$child_file\"); "
                    "rm -f \"$child_file\"; "
                    "setsid bash -c 'exit 1' & "
                    "fail_pid=$!; "
                    "wait \"$fail_pid\" || true; "
                    "_kill_pgid_list \"$leader_pid\"; "
                    "for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do "
                    "kill -0 \"$child_pid\" 2>/dev/null || break; sleep 0.05; "
                    "done; "
                    "if kill -0 \"$child_pid\" 2>/dev/null; then exit 9; fi; "
                    "if kill -0 \"$leader_pid\" 2>/dev/null; then exit 10; fi"
                ),
            ],
            env=self.env,
            timeout=20,
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + proc.stdout)

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

    def test_coverage_gate_log_slug_includes_mode_and_shard(self):
        """Parallel coverage workers must not share coverage-gate.log."""
        script = shlex.quote(str(self.repo_root / "scripts/run_docker_matrix.sh"))
        proc = run_shell_argv(
            [
                "bash",
                "-c",
                (
                    f"source {script}; "
                    "ASUS_COVERAGE_MODE=kcov ASUS_COVERAGE_SHARD=2 "
                    "_matrix_log_slug_for_image coverage-gate; "
                    "ASUS_COVERAGE_MODE=python ASUS_COVERAGE_SHARD=1 "
                    "_matrix_log_slug_for_image coverage-gate; "
                    "_matrix_log_slug_for_image ubuntu:26.04"
                ),
            ],
            env=self.env,
            timeout=10,
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        lines = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
        self.assertEqual(
            lines,
            ["coverage-gate-kcov-2", "coverage-gate-python-1", "ubuntu-26.04"],
        )

    def test_serial_target_fails_closed_on_kcov_suite_log(self):
        """Exit 0 with a kcov suite-failure log line must not report Passed."""
        script = shlex.quote(str(self.repo_root / "scripts/run_docker_matrix.sh"))
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "fake-coverage.log"
            proc = run_shell_argv(
                [
                    "bash",
                    "-c",
                    (
                        f"source {script}; "
                        "set +e; "
                        "run_target() { "
                        "echo '  ✗ kcov scenario suite failed (status 1)'; "
                        "return 0; "
                        "}; "
                        f"_run_one_serial_target coverage-gate {shlex.quote(str(log))}; "
                        "echo status=$?"
                    ),
                ],
                env=self.env,
                timeout=10,
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertIn("status=1", proc.stdout)



if __name__ == "__main__":
    unittest.main()
