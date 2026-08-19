"""Unit tests for release package kind helpers and smoke entrypoints."""

from __future__ import annotations

import re
import stat
import tempfile
import unittest
from pathlib import Path

from tests.unit.shell.shell_test_utils import run_bash_c, run_shell_script

_REPO_ROOT = Path(__file__).resolve().parents[3]
_KINDS = _REPO_ROOT / "scripts/release_package_kinds.sh"
_PREPARE = _REPO_ROOT / "scripts/prepare_release_package_host_deps.sh"
_SMOKE = _REPO_ROOT / "scripts/run_release_package_smoke.sh"
_BUILDER = _REPO_ROOT / "scripts/build_release_package.sh"
_CI_YML = _REPO_ROOT / ".github/workflows/ci.yml"


def _matrix_kinds_from_ci_package_smoke() -> set[str]:
    """Parse package-smoke matrix pkg entries from ci.yml."""
    text = _CI_YML.read_text(encoding="utf-8")
    start = text.index("package-smoke:")
    end = text.index("\n  coverage:", start)
    block = text[start:end]
    return set(re.findall(r"^\s+- (rpm-[\w.-]+|arch|appimage|flatpak|snap)\s*$", block, re.MULTILINE))


def _kinds_from_release_package_kinds_sh() -> set[str]:
    """Evaluate RELEASE_PACKAGE_KINDS from the shared kinds script."""
    snippet = f"""
source '{_KINDS}'
printf '%s\\n' "${{RELEASE_PACKAGE_KINDS[@]}}"
"""
    proc = run_bash_c(snippet, timeout=10)
    if proc.returncode != 0:
        raise AssertionError(proc.stderr)
    return {line.strip() for line in proc.stdout.splitlines() if line.strip()}


class TestReleasePackageKinds(unittest.TestCase):
    """Validate shared release package kind metadata and artifact rules."""

    def test_new_shell_scripts_are_executable(self) -> None:
        """Smoke/prepare scripts must be executable for pipeline and CI invocations."""
        for rel in (
            "scripts/run_release_package_smoke.sh",
            "scripts/prepare_release_package_host_deps.sh",
            "scripts/build_release_package.sh",
        ):
            path = _REPO_ROOT / rel
            mode = path.stat().st_mode
            self.assertTrue(
                mode & stat.S_IXUSR,
                msg=f"{rel} must be executable (chmod +x)",
            )

    def test_kind_list_matches_workflow_matrix(self) -> None:
        """RELEASE_PACKAGE_KINDS must exactly match the CI package-smoke matrix."""
        self.assertEqual(_kinds_from_release_package_kinds_sh(), _matrix_kinds_from_ci_package_smoke())

    def test_kind_is_valid_accepts_known_kinds(self) -> None:
        """Known kinds return success from _release_pkg_kind_is_valid."""
        snippet = f"""
source '{_KINDS}'
_release_pkg_kind_is_valid rpm-fedora-44
"""
        proc = run_bash_c(snippet, timeout=10)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)

    def test_kind_is_valid_rejects_unknown(self) -> None:
        """Unknown kinds fail closed."""
        snippet = f"""
source '{_KINDS}'
_release_pkg_kind_is_valid not-a-package-kind
"""
        proc = run_bash_c(snippet, timeout=10)
        self.assertNotEqual(proc.returncode, 0, msg=proc.stdout)

    def test_artifact_glob_per_kind(self) -> None:
        """Each kind maps to the artifact filename pattern used on GitHub Releases."""
        cases = {
            "rpm-fedora-44": "asus-zenbook-linux-tools-*fc44*.rpm",
            "rpm-rocky-10": "asus-zenbook-linux-tools-*.el10.noarch.rpm",
            "rpm-opensuse-tw": "asus-zenbook-linux-tools-*-1.noarch.rpm",
            "arch": "asus-zenbook-linux-tools-*.pkg.tar.*",
            "appimage": "asus-zenbook-linux-tools-*-x86_64.AppImage",
            "flatpak": "asus-zenbook-linux-tools-*.flatpak",
            "snap": "asus-zenbook-linux-tools_*.snap",
        }
        for kind, expected in cases.items():
            with self.subTest(kind=kind):
                snippet = f"""
source '{_KINDS}'
_release_pkg_artifact_glob '{kind}'
"""
                proc = run_bash_c(snippet, timeout=10)
                self.assertEqual(proc.returncode, 0, msg=proc.stderr)
                self.assertEqual(proc.stdout.strip(), expected)

    def test_validate_artifact_requires_exactly_one_match(self) -> None:
        """Validation fails when zero or multiple artifacts match the kind glob."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            artifacts = Path(tmp_dir)
            (artifacts / "asus-zenbook-linux-tools-1.0.3-1.fc44.noarch.rpm").write_text(
                "rpm", encoding="utf-8"
            )
            ok_snippet = f"""
source '{_KINDS}'
_release_pkg_validate_artifact rpm-fedora-44 '{artifacts}'
"""
            proc = run_bash_c(ok_snippet, timeout=10)
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertTrue(proc.stdout.strip().endswith(".rpm"))

            (artifacts / "asus-zenbook-linux-tools-1.0.3-2.fc44.noarch.rpm").write_text(
                "rpm2", encoding="utf-8"
            )
            bad_snippet = f"""
source '{_KINDS}'
_release_pkg_validate_artifact rpm-fedora-44 '{artifacts}'
"""
            proc = run_bash_c(bad_snippet, timeout=10)
            self.assertNotEqual(proc.returncode, 0, msg=proc.stdout)
            self.assertIn("found 2", proc.stderr)

    def test_prepare_host_deps_rejects_unknown_kind(self) -> None:
        """Portable/RPM host-deps helper fails on unknown kinds."""
        proc = run_shell_script(_PREPARE, args=["unknown-kind"], timeout=10)
        self.assertNotEqual(proc.returncode, 0, msg=proc.stdout)
        self.assertIn("Unknown package kind", proc.stderr + proc.stdout)

    def test_smoke_usage_rejects_unknown_kind(self) -> None:
        """Smoke orchestrator validates kind tokens before building."""
        proc = run_shell_script(_SMOKE, args=["not-a-real-kind"], timeout=10)
        self.assertNotEqual(proc.returncode, 0, msg=proc.stdout)
        self.assertIn("Unknown package kind", proc.stderr + proc.stdout)

    def test_smoke_validates_kinds_before_docker(self) -> None:
        """Unknown kinds must fail with usage text even when docker is absent."""
        text = _SMOKE.read_text(encoding="utf-8")
        collect_idx = text.index("_collect_requested_kinds")
        docker_idx = text.index("_require_tool docker")
        self.assertLess(collect_idx, docker_idx)

    def test_smoke_runs_install_smoke_by_default(self) -> None:
        """Release smoke must install/remove portable bundles after artifact validation."""
        text = _SMOKE.read_text(encoding="utf-8")
        self.assertIn("ASUS_RELEASE_INSTALL_SMOKE", text)
        self.assertIn("release_package_install_smoke.sh", text)
        self.assertIn("_release_pkg_install_smoke", text)

    def test_parallel_workers_force_sequential_child_runs(self) -> None:
        """Parallel kind workers must not re-enter parallel mode (infinite recursion)."""
        text = _SMOKE.read_text(encoding="utf-8")
        self.assertIn("ASUS_RELEASE_PACKAGE_SMOKE_PARALLEL=0", text)
        self.assertIn("ASUS_RELEASE_SKIP_HOST_DEPS=1", text)
        self.assertIn("./scripts/run_release_package_smoke.sh", text)

    def test_repo_relative_path_for_docker_mounts(self) -> None:
        """Docker bind mounts need workspace-relative artifact directories."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            repo = Path(tmp_dir) / "repo"
            art = repo / "artifacts" / "rpm-fedora-44"
            art.mkdir(parents=True)
            missing = repo / ".rpm-build-rpm-opensuse-tw"
            snippet = f"""
source '{_KINDS}'
_release_repo_relative_path '{repo}' '{art}'
"""
            proc = run_bash_c(snippet, timeout=10)
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertEqual(proc.stdout.strip(), "artifacts/rpm-fedora-44")
            snippet_missing = f"""
source '{_KINDS}'
_release_repo_relative_path '{repo}' '{missing}'
"""
            proc = run_bash_c(snippet_missing, timeout=10)
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertEqual(proc.stdout.strip(), ".rpm-build-rpm-opensuse-tw")


class TestReleasePackageBuilders(unittest.TestCase):
    """Parity checks for per-format release builders and shared staging."""

    def test_build_release_package_enables_arch_install_smoke(self) -> None:
        """Arch release builds must honor ASUS_RELEASE_INSTALL_SMOKE for pacman -U."""
        text = _BUILDER.read_text(encoding="utf-8")
        self.assertIn("ASUS_ARCH_INSTALL_SMOKE=\"${ASUS_RELEASE_INSTALL_SMOKE:-1}\"", text)
        self.assertIn("ASUS_RELEASE_INSTALL_SMOKE", text)

    def test_snap_build_uses_destructive_mode_on_ubuntu_2404(self) -> None:
        """core24 snaps use destructive-mode only on Ubuntu 24.04; newer hosts use LXD."""
        snap_build = (_REPO_ROOT / "packaging/snap/build-snap.sh").read_text(encoding="utf-8")
        prepare = _PREPARE.read_text(encoding="utf-8")
        self.assertIn("_ubuntu_version_id", snap_build)
        self.assertIn('[ "$host_ver" = "24.04" ]', snap_build)
        self.assertIn("_lxd_profile_ready", snap_build)
        self.assertIn("_lxd_run", snap_build)
        self.assertIn("snapcraft pack --destructive-mode", snap_build)
        self.assertIn("snapcraft pack --use-lxd", snap_build)
        self.assertIn("sudo -n", snap_build)
        self.assertIn("Passwordless sudo", snap_build)
        self.assertIn("release_package_kinds.sh", snap_build)
        self.assertIn('[ "$host_ver" = "24.04" ]', prepare)
        self.assertIn("gettext", prepare)
        self.assertIn("flatpak --user remote-add", prepare)

    def test_rpm_smoke_copies_basename_and_uses_zypper_install(self) -> None:
        """RPM release smoke must preserve NEVRA basenames and resolve openSUSE deps."""
        text = _BUILDER.read_text(encoding="utf-8")
        self.assertIn('cp "$rpm_path" "$artifacts_dir/"', text)
        self.assertNotIn("asus-zenbook-linux-tools-${VERSION}-el10.noarch.rpm", text)
        self.assertIn("zypper --non-interactive install --allow-unsigned-rpm", text)
        self.assertIn("python313-evdev", text)

    def test_builder_reports_release_failure_not_unknown_kind(self) -> None:
        """Failed portable builds must not fall through to Unknown package kind."""
        text = _BUILDER.read_text(encoding="utf-8")
        self.assertIn("Release build failed for", text)
        self.assertIn("_release_pkg_kind_is_valid", text)

    def test_appimage_builder_uses_extract_and_run(self) -> None:
        """AppImage CI must invoke appimagetool via APPIMAGE_EXTRACT_AND_RUN."""
        appimage_build = (_REPO_ROOT / "packaging/appimage/build-appimage.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("APPIMAGE_EXTRACT_AND_RUN=1", appimage_build)
        self.assertNotIn("appimagetool-extract", appimage_build)
        self.assertIn("20251108/runtime-x86_64", appimage_build)
        self.assertIn("_verify_cached_sha256", appimage_build)

    def test_stage_payload_installs_sbin_file_without_mkdir(self) -> None:
        """Shared staging must install configure via install -D without mkdir sbin."""
        stage = (_REPO_ROOT / "packaging/stage-payload.sh").read_text(encoding="utf-8")
        self.assertIn('install -Dm755', stage)
        self.assertNotIn('"${PKG_SBIN}"', stage)

    def test_arch_pkgbuild_avoids_sbin_directory_conflict(self) -> None:
        """Arch packages must not claim /usr/sbin (owned by filesystem)."""
        pkgbuild = (_REPO_ROOT / "packaging/arch/PKGBUILD").read_text(encoding="utf-8")
        self.assertIn('rmdir "${pkgdir}/usr/sbin"', pkgbuild)
        self.assertIn("/usr/bin/asus-zenbook-configure", pkgbuild)

    def test_flatpak_wrapper_exports_host_install_handoff(self) -> None:
        """Flatpak configure wrapper must target /run/host for host deployment."""
        wrapper = (_REPO_ROOT / "packaging/flatpak/asus-zenbook-configure-wrapper").read_text(
            encoding="utf-8"
        )
        self.assertIn("ASUS_PORTABLE_HOST_INSTALL=1", wrapper)
        self.assertIn("ASUS_HOST_ROOT=/run/host", wrapper)
        self.assertIn("/run/host/etc", wrapper)
        metainfo = (
            _REPO_ROOT / "packaging/flatpak/org.github.ventura8.AsusZenBookLinuxTools.metainfo.xml"
        ).read_text(encoding="utf-8")
        self.assertIn("asus-zenbook-linux-tools", metainfo)

    def test_rpm_build_script_logs_matches_on_stderr(self) -> None:
        """RPM builder diagnostics must not pollute stdout capture paths."""
        rpm_build = (_REPO_ROOT / "packaging/rpm/build-rpm.sh").read_text(encoding="utf-8")
        self.assertIn('>&2', rpm_build)

    def test_flatpak_builder_uses_user_install(self) -> None:
        """Flatpak release builds must not require system-wide ConfigureRemote."""
        flatpak_build = (_REPO_ROOT / "packaging/flatpak/build-flatpak.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("flatpak-builder --user", flatpak_build)
        self.assertIn("_flatpak_run_as_builder_user", flatpak_build)
        self.assertIn("runuser -u", flatpak_build)
        self.assertIn("_flatpak_wipe_staging", flatpak_build)

    def test_builder_preserves_nonzero_builder_status(self) -> None:
        """Failed builders must report the real exit status (not if-cmd $? = 0)."""
        text = _BUILDER.read_text(encoding="utf-8")
        self.assertIn("else", text)
        self.assertIn("status=$?", text)
        self.assertIn("Release build failed for", text)

    def test_builder_sources_shared_kinds_helper(self) -> None:
        """Release builder validates artifacts through release_package_kinds.sh."""
        text = _BUILDER.read_text(encoding="utf-8")
        self.assertIn("release_package_kinds.sh", text)
        self.assertIn("_release_pkg_validate_artifact", text)
