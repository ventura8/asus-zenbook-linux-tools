"""Unit tests for the Docker matrix runner surfaces."""

import os
import unittest

import yaml

from tests.unit.shell.docker_matrix_test_base import (
    EXPECTED_DISTROS,
    DockerMatrixFixture,
)


class TestDockerMatrixRunner(DockerMatrixFixture):
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



if __name__ == "__main__":
    unittest.main()
