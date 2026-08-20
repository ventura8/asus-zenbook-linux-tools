"""CI/local pipeline parity guards for shared smoke entrypoints."""

from __future__ import annotations

import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path

from scripts.check_file_size_limits import _should_prune_dir, main


def _workflow_section(text: str, start_marker: str, end_marker: str) -> str:
    """Return a workflow YAML slice; fail with a clear message when markers are absent."""
    try:
        start = text.index(start_marker)
        end = text.index(end_marker, start)
    except ValueError as exc:
        raise AssertionError(
            f"workflow section not found: {start_marker!r} .. {end_marker!r}"
        ) from exc
    return text[start:end]


class TestPipelineCiParityPackaging(unittest.TestCase):
    """Deb smoke, lint discovery, and packaging-adjacent parity guards."""

    @classmethod
    def setUpClass(cls) -> None:
        """Resolve repository root once for packaging parity checks."""
        cls.repo_root = Path(__file__).resolve().parents[3]

    def test_deb_smoke_script_uses_safe_local_apt_path(self) -> None:
        """Local .deb install must use ./ or absolute paths (not release/package)."""
        script = (self.repo_root / "scripts/run_deb_package_smoke.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("_require_exact_one_glob", script)
        self.assertIn("_apt_install_local_deb", script)
        self.assertIn('install_path="./$deb_path"', script)
        self.assertIn("runuser -u", script)
        self.assertIn("SUDO_USER", script)
        self.assertIn("_cleanup_debian_build_tree", script)
        self.assertIn("trap '_cleanup_debian_build_tree' EXIT", script)
        self.assertIn("_remove_prior_package_debs", script)
        self.assertIn("../${PACKAGE_NAME}_*.deb", script)
        self.assertNotRegex(
            script,
            r'apt-get install -y "\$\{?ARTIFACT_DEB\}?"',
        )

    def test_lint_discovery_prunes_debian_packaging_trees(self) -> None:
        """Staged debian payload copies must not be linted as product sources."""
        run_lints = (self.repo_root / "scripts/run-lints.sh").read_text(encoding="utf-8")
        self.assertIn("./debian/asus-zenbook-linux-tools", run_lints)
        self.assertIn("./debian/tmp", run_lints)
        self.assertIn("./debian/.debhelper", run_lints)
        self.assertIn("./artifacts", run_lints)
        self.assertIn("./.rpm-build*", run_lints)
        self.assertIn("./packaging/arch/pkg", run_lints)
        self.assertIn("./packaging/arch/src", run_lints)
        self.assertIn("./packaging/appimage/AppDir", run_lints)
        self.assertIn("./packaging/flatpak/builddir", run_lints)
        self.assertIn("./.flatpak-builder", run_lints)
        self.assertIn("-name '.rpm-build*' -prune", run_lints)

    def test_file_size_limits_prunes_only_arch_staging_paths(self) -> None:
        """Only packaging/arch/{pkg,src} are pruned; other src/pkg dirs stay scanned."""
        self.assertTrue(_should_prune_dir("packaging/arch", "pkg"))
        self.assertTrue(_should_prune_dir("packaging/arch", "src"))
        self.assertFalse(_should_prune_dir("tools", "pkg"))
        self.assertFalse(_should_prune_dir("tests", "src"))
        self.assertFalse(_should_prune_dir("src", "nested"))

        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            tools_pkg = root / "tools" / "pkg"
            tools_src = root / "tools" / "src"
            tools_pkg.mkdir(parents=True)
            tools_src.mkdir(parents=True)
            (tools_pkg / "big.sh").write_text("#!/bin/bash\n" + "echo hi\n" * 700, encoding="utf-8")
            (tools_src / "big.sh").write_text("#!/bin/bash\n" + "echo hi\n" * 700, encoding="utf-8")
            (root / "bin").mkdir()
            (root / "bin" / "ok.sh").write_text("#!/bin/bash\necho ok\n", encoding="utf-8")

            stdout_buf = StringIO()
            stderr_buf = StringIO()
            with redirect_stdout(stdout_buf), redirect_stderr(stderr_buf):
                exit_code = main(root=root)
            self.assertEqual(exit_code, 1)
            output = stdout_buf.getvalue() + stderr_buf.getvalue()
            self.assertIn("tools/pkg/big.sh", output)
            self.assertIn("tools/src/big.sh", output)

    def test_eslint_uses_workspace_npm_ci_not_global_binary(self) -> None:
        """CI clean checkouts lack host node_modules; flat config needs npm ci."""
        run_lints = (self.repo_root / "scripts/run-lints.sh").read_text(encoding="utf-8")
        ensure_idx = run_lints.index("_ensure_eslint_workspace_deps")
        eslint_idx = run_lints.index("node_modules/.bin/eslint")
        self.assertLess(ensure_idx, eslint_idx)
        self.assertIn("npm ci", run_lints)
        self.assertIn("@eslint/js", run_lints)
        self.assertNotIn("_resolve_eslint_cmd", run_lints)
        package = (self.repo_root / "package.json").read_text(encoding="utf-8")
        self.assertIn('"@eslint/js"', package)
        dockerfile = (
            self.repo_root / "docker/images/lint/python-3.13-slim.Dockerfile"
        ).read_text(encoding="utf-8")
        # Global eslint alone cannot resolve workspace eslint.config.mjs imports.
        self.assertNotRegex(dockerfile, r"(?i)\bnpm\s+install\s+-g\b.*\beslint\b")
        self.assertNotRegex(dockerfile, r"(?i)\bnpm\s+i\s+-g\b.*\beslint\b")
        self.assertNotRegex(dockerfile, r"(?i)\beslint@")
        self.assertIn("nodejs", dockerfile)

    def test_full_de_lxqt_conf_probe_accepts_debian_nested_path(self) -> None:
        """Debian ships globalkeyshortcuts.conf as a directory containing the file."""
        script = (
            self.repo_root / "scripts/distro_install_smoke_full_de.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("_smoke_lxqt_conf_is_present", script)
        self.assertIn(
            "/etc/xdg/lxqt/globalkeyshortcuts.conf/globalkeyshortcuts.conf",
            script,
        )

    def test_fedora_family_images_pin_alsa_utils_nevra_glob(self) -> None:
        """alsa-utils-* only installs alsabat; smoke needs the main alsa-utils RPM."""
        for rel in (
            "docker/images/tests/fedora-44.Dockerfile",
            "docker/images/tests/rocky-10.Dockerfile",
            "docker/images/tests/almalinux-10.Dockerfile",
        ):
            text = (self.repo_root / rel).read_text(encoding="utf-8")
            self.assertRegex(text, r"(?m)^\s*alsa-utils-\[0-9\]\*\s*\\?\s*$", msg=rel)
            self.assertNotRegex(text, r"(?m)^\s*alsa-utils-\*\s*\\?\s*$", msg=rel)

    def test_ci_deb_package_job_calls_shared_smoke_script(self) -> None:
        """CI package-smoke deb cell must use the shared Debian smoke entrypoint."""
        ci = (self.repo_root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn("scripts/run_deb_package_smoke.sh", ci)
        self.assertIn("matrix.pkg == 'deb'", ci)
        self.assertNotIn('apt-get install -y "$ARTIFACT_DEB"', ci)
        self.assertNotIn("apt-get install -y \"$ARTIFACT_DEB\"", ci)

    def test_full_pipeline_runs_deb_package_smoke_step(self) -> None:
        """Local --full must include the same Debian smoke gate as CI."""
        bat = (self.repo_root / "scripts/build-and-test.sh").read_text(encoding="utf-8")
        modes = (self.repo_root / "scripts/build-and-test-modes.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("step_preflight_clean_build_trees", modes)
        self.assertIn("step_lint_and_deb_parallel", modes)
        self.assertIn("step_post_lint_gates_parallel", modes)
        self.assertIn("step_coverage_merge_host", modes)
        self.assertIn("scripts/run_deb_package_smoke.sh", modes)
        self.assertIn("scripts/run_release_package_smoke.sh", modes)
        self.assertIn("build-and-test-modes.sh", bat)

    def test_deb_smoke_skips_host_unit_tests(self) -> None:
        """Deb package smoke must use nocheck so unittest stays in coverage Docker."""
        script = (self.repo_root / "scripts/run_deb_package_smoke.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("nocheck", script)
        self.assertIn("DEB_BUILD_OPTIONS", script)
        self.assertIn("_smoke_install_upgrade_and_purge", script)
        self.assertIn("_smoke_plant_share_bytecode", script)
        self.assertIn("not empty so not removed", script)
        self.assertIn("--reinstall", script)
        modes = (self.repo_root / "scripts/build-and-test-modes.sh").read_text(
            encoding="utf-8"
        )
        # Host --full must not invoke in-process unit/kcov/e2e steps.
        self.assertIn("step_post_lint_gates_parallel", modes)
        self.assertIn("step_preflight_clean_build_trees", modes)
        self.assertIn("step_lint_and_deb_parallel", modes)
        self.assertIn("step_coverage_merge_host", modes)
        self.assertNotRegex(
            modes,
            r"full\)\s*\n\s*MODE_STEPS=\([^)]*step_unit_tests",
        )
        self.assertNotRegex(
            modes,
            r"full\)\s*\n\s*MODE_STEPS=\([^)]*step_kcov_coverage",
        )

    def test_arch_build_lock_lives_inside_chowned_cache_dir(self) -> None:
        """Arch flock lock must be under ARCH_CACHE_DIR (writable after chown)."""
        script = (self.repo_root / "packaging/arch/build-arch.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn('ARCH_CACHE_DIR="${REPO_ROOT}/.cache/asus-arch-package-build"', script)
        self.assertIn('"${ARCH_CACHE_DIR}/makepkg.lock"', script)
        self.assertNotIn('"${ARCH_CACHE_DIR}.lock"', script)
        self.assertIn("_chown_arch_build_paths", script)
        self.assertIn('chown -R "${user}:${user}" "$ARCH_DIR" "$ARCH_CACHE_DIR"', script)

    def test_release_package_kinds_are_shared_across_workflows(self) -> None:
        """CI package-smoke and tag build-packages must build the same artifact set."""
        kinds_script = (
            self.repo_root / "scripts/release_package_kinds.sh"
        ).read_text(encoding="utf-8")
        expected = [
            "rpm-fedora-44",
            "rpm-rocky-10",
            "rpm-opensuse-tw",
            "arch",
            "appimage",
            "flatpak",
            "snap",
        ]
        for kind in expected:
            self.assertIn(kind, kinds_script, msg=kind)
        ci = (self.repo_root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        ppa = (self.repo_root / ".github/workflows/ppa-release.yml").read_text(
            encoding="utf-8"
        )
        smoke_block = _workflow_section(ci, "package-smoke:", "\n  coverage:")
        build_block = _workflow_section(ppa, "build-packages:", "\n  github-release:")
        for kind in expected:
            self.assertIn(f"- {kind}", smoke_block, msg=f"ci package-smoke: {kind}")
            self.assertIn(f"- {kind}", build_block, msg=f"ppa build-packages: {kind}")
        builder = (
            self.repo_root / "scripts/build_release_package.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("release_package_kinds.sh", builder)
        self.assertIn("_release_pkg_validate_artifact", builder)
        smoke = (
            self.repo_root / "scripts/run_release_package_smoke.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("build_release_package.sh", smoke)
        self.assertIn("RELEASE_PACKAGE_KINDS", smoke)

    def test_ci_package_smoke_uses_shared_release_smoke_entrypoint(self) -> None:
        """Each CI package-smoke cell must build, validate, and install via shared smoke."""
        ci = (self.repo_root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn("run_release_package_smoke.sh", ci)
        self.assertIn("ASUS_RELEASE_INSTALL_SMOKE=1", ci)
        self.assertNotIn("run_rpm_package_smoke.sh", ci)
        self.assertIn(
            "matrix.pkg == 'snap' && 'ubuntu-24.04' || 'ubuntu-26.04'",
            ci,
        )

    def test_full_pipeline_runs_all_release_package_smoke_kinds(self) -> None:
        """Local --full must smoke-test every release kind (native ∥ portable)."""
        modes = (self.repo_root / "scripts/build-and-test-modes.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("ASUS_RELEASE_PACKAGE_SMOKE_PARALLEL=1", modes)
        self.assertIn("ASUS_RELEASE_INSTALL_SMOKE=1", modes)
        self.assertIn("scripts/run_release_package_smoke.sh", modes)
        self.assertIn("release-package-native-smoke", modes)
        self.assertIn("release-package-portable-smoke", modes)
        self.assertIn("rpm-fedora-44 rpm-rocky-10 rpm-opensuse-tw arch", modes)
        self.assertIn("appimage flatpak snap", modes)
        self.assertIn("step_post_lint_gates_parallel", modes)
        self.assertIn("_start_coverage_matrix_shards", modes)
        self.assertIn("_wait_bg_jobs_fail_fast", modes)
        self.assertIn("_start_compat_family_workers", modes)
        self.assertIn("_parallel_gate_pids", modes)
        self.assertIn("_start_release_smoke_worker", modes)
        self.assertIn("_parallel_gate_pids+=(\"$!\")", modes)

    def test_local_buildx_cache_serializes_per_scope(self) -> None:
        """Parallel coverage shards share debian:trixie cache; mkdir lock must serialize writes."""
        utils = (self.repo_root / "scripts/docker-utils.sh").read_text(encoding="utf-8")
        self.assertIn("_docker_buildx_local_lock_dir", utils)
        self.assertIn("_docker_acquire_local_buildx_lock", utils)
        self.assertIn("_docker_wait_mkdir_lock", utils)
        self.assertIn('mkdir "$lock_dir"', utils)
        self.assertIn("/.locks/", utils)

    def test_debian_build_depends_include_python3_gi(self) -> None:
        """Launchpad dh_auto_test needs python3-gi for GLib.Variant keybinding helpers."""
        control = (self.repo_root / "debian/control").read_text(encoding="utf-8")
        indep = control.split("Build-Depends-Indep:", 1)[1].split("Package:", 1)[0]
        self.assertRegex(indep, r"(?m)^\s*python3-gi\s*,?\s*$")
        ppa = (self.repo_root / ".github/workflows/ppa-release.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("PPA_UPLOAD_REVISION", ppa)
        self.assertIn("python3-gi", ppa)
        self.assertIn("gettext", ppa)

    def test_pot_freshness_requires_git_tracked_template(self) -> None:
        """Pot check must fail when the template is only local/gitignored."""
        extract = (self.repo_root / "scripts/i18n/extract_pot.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("_require_tracked_catalog", extract)
        self.assertIn("_git_in_repo", extract)
        self.assertIn("safe.directory=", extract)
        self.assertIn("ls-files --error-unmatch", extract)
        gitignore = (self.repo_root / ".gitignore").read_text(encoding="utf-8")
        self.assertIn("!po/asus-zenbook-linux-tools.pot", gitignore)
        pot = self.repo_root / "po/asus-zenbook-linux-tools.pot"
        self.assertTrue(pot.is_file(), msg="committed pot template must exist on disk")

    def test_kcov_fixtures_avoid_hardcoded_session_uid_1000(self) -> None:
        """GHA asusci is often UID 1001; bus/state under /1000 only passes locally."""
        forbidden = (
            "bus_root/1000",
            "bus/1000",
            "asus-zenbook-linux-tools/1000",
            "echo 1000",
        )
        for rel in (
            "scripts/coverage/kcov-install-scenarios.sh",
            "scripts/coverage/kcov-screenpad-scenarios.sh",
        ):
            text = (self.repo_root / rel).read_text(encoding="utf-8")
            for token in forbidden:
                self.assertNotIn(token, text, msg=f"{rel} must not contain {token!r}")
            self.assertIn('uid="$(id -u)"', text, msg=rel)


class TestPipelineCiParityWorkflow(unittest.TestCase):
    """GitHub Actions / local matrix and coverage workflow parity."""

    @classmethod
    def setUpClass(cls) -> None:
        """Resolve repository root once for workflow parity checks."""
        cls.repo_root = Path(__file__).resolve().parents[3]

    def test_ci_log_slug_sanitizes_colon_for_artifacts(self) -> None:
        """upload-artifact rejects ':' and '/' in names (ubuntu:26.04 → ubuntu-26.04)."""
        ci = (self.repo_root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn('log_slug="${log_slug//\\//-}"', ci)
        self.assertIn('log_slug="${log_slug//:/-}"', ci)
        self.assertIn('image_slug="${log_slug//:/-}"', ci)
        self.assertIn('log_slug="${image_slug}-de-${{ matrix.de_family }}"', ci)

    def test_ci_distro_tests_timeout_allows_rocky_cold_build(self) -> None:
        """Rocky cold poetry/PyGObject image builds exceed a 20-minute job cap."""
        ci = (self.repo_root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        start = ci.index("distro-tests-rhel:")
        end = ci.index("distro-tests-suse-arch:", start)
        block = ci[start:end]
        self.assertRegex(block, r"timeout-minutes:\s*([4-9][0-9]|[1-9][0-9]{2,})\b")
        self.assertNotRegex(block, r"timeout-minutes:\s*20\b")

    def test_ci_actions_pin_node24_upload_artifact(self) -> None:
        """upload-artifact must be Node 24 (v7+) — v4.6.2 forces Node 20 warnings."""
        approved = "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
        for rel in (".github/workflows/ci.yml", ".github/workflows/ppa-release.yml"):
            text = (self.repo_root / rel).read_text(encoding="utf-8")
            uses = [
                line.strip()
                for line in text.splitlines()
                if "actions/upload-artifact@" in line
            ]
            self.assertTrue(uses, msg=rel)
            for line in uses:
                self.assertIn(approved, line, msg=f"{rel}: {line}")
                self.assertIn("# v7.0.1", line, msg=f"{rel}: {line}")
            self.assertNotIn(
                "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
                text,
                msg=rel,
            )

    def test_ci_uses_gha_buildx_cache_backend(self) -> None:
        """CI must use BuildKit type=gha scopes, not actions/cache of .cache/docker-buildx."""
        ci = (self.repo_root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn("DOCKER_BUILDX_CACHE_BACKEND: gha", ci)
        self.assertIn("DOCKER_BUILDX_CACHE_SCOPE:", ci)
        self.assertNotIn("path: .cache/docker-buildx", ci)
        utils = (self.repo_root / "scripts/docker-utils.sh").read_text(encoding="utf-8")
        self.assertIn("type=gha,scope=", utils)
        self.assertIn("_docker_buildx_append_gha_cache_args", utils)

    def test_ci_coverage_jobs_are_split(self) -> None:
        """Coverage is mode×shard matrix (kcov|python)×(1|2) plus host merge gate."""
        ci = (self.repo_root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn("\n  coverage:\n", ci)
        self.assertIn("name: Coverage ${{ matrix.label }} (debian:trixie)", ci)
        self.assertIn("label: kcov bin-sound+ui", ci)
        self.assertIn("label: kcov install-lib", ci)
        self.assertIn("label: python unit tests", ci)
        self.assertIn("label: python e2e tests", ci)
        self.assertIn("ASUS_COVERAGE_MODE: ${{ matrix.mode }}", ci)
        self.assertIn("ASUS_COVERAGE_SHARD: ${{ matrix.shard }}", ci)
        self.assertIn("\n  coverage-merge:\n", ci)
        self.assertIn("include-hidden-files: true", ci)
        self.assertIn("--coverage-merge-only", ci)
        self.assertIn("coverage-shards-download", ci)
        self.assertIn("Install host merge tools", ci)
        gates_py = (self.repo_root / "scripts/coverage/gates_python.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("combine --keep --data-file=", gates_py)
        self.assertIn("_python_coverage_shard_data_files", gates_py)
        # Raw cp of the first shard skips /workspace path remapping on host merge.
        self.assertNotIn('cp -a "$shard_file" "$dest"', gates_py)
        self.assertNotIn("ASUS_COVERAGE_MODE: merge", ci)
        self.assertIn("needs: [lint, coverage-merge]", ci)
        self.assertNotIn("\n  coverage-kcov:\n", ci)
        self.assertNotIn("\n  coverage-python:\n", ci)
        self.assertNotIn("coverage-gate:", ci)
        bat = (self.repo_root / "scripts/build-and-test.sh").read_text(encoding="utf-8")
        self.assertIn("kcov-only", bat)
        self.assertIn("python-coverage-only", bat)
        self.assertIn("coverage-merge-only", bat)
        modes = (self.repo_root / "scripts/build-and-test-modes.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("step_coverage_parallel", modes)
        self.assertIn("step_coverage_merge_host", modes)
        self.assertIn("step_post_lint_gates_parallel", modes)
        self.assertIn("_run_coverage_merge_host", modes)
        self.assertIn("ASUS_COVERAGE_SHARD", modes)
        self.assertNotIn("_run_coverage_merge_docker", modes)
        matrix = (self.repo_root / "scripts/run_docker_matrix.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn('echo "debian:trixie"', matrix)
        self.assertIn("ASUS_DOCKER_MATRIX_COMPAT_ONLY", matrix)
        self.assertIn("ASUS_DOCKER_MATRIX_COVERAGE_GATE", matrix)
        self.assertIn("ASUS_DOCKER_MATRIX_DE_FAMILY", matrix)

    def test_ci_and_local_refuse_unstamped_coverage_shards(self) -> None:
        """GHA and local --full must fail closed without shard_ok (no stale merge)."""
        ci = (self.repo_root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn("Verify coverage shard export stamp", ci)
        self.assertIn('test -f "$dest/shard_ok"', ci)
        # Incomplete shards must not reach coverage-merge.
        upload_block = ci.split("Upload coverage shard data", 1)[1].split(
            "Upload kcov scenario logs", 1
        )[0]
        self.assertIn("if: success()", upload_block)
        self.assertNotIn("if: always()", upload_block)
        self.assertIn("if-no-files-found: error", upload_block)
        gates_kcov = (self.repo_root / "scripts/coverage/gates_kcov.sh").read_text(
            encoding="utf-8"
        )
        gates_py = (self.repo_root / "scripts/coverage/gates_python.sh").read_text(
            encoding="utf-8"
        )
        gates_shell = (self.repo_root / "scripts/coverage/gates_shell.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("_write_coverage_shard_ok_stamp", gates_shell)
        self.assertIn("_require_kcov_shard_ok_stamps", gates_kcov)
        self.assertIn("_require_python_shard_ok_stamps", gates_py)
        self.assertIn("require_exported_coverage_shards", gates_kcov)
        modes = (self.repo_root / "scripts/build-and-test-modes.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("_wipe_coverage_shards_dir", modes)
        self.assertIn("_chown_coverage_shards_dir_if_sudo", modes)
        self.assertIn("require_exported_coverage_shards || exit 1", modes)
        self.assertGreaterEqual(modes.count("require_exported_coverage_shards"), 2)

    def test_ci_lint_is_wave_matrix(self) -> None:
        """Lint is a GHA matrix with display labels; host never runs run-lints for --full."""
        ci = (self.repo_root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn("\n  lint:\n", ci)
        self.assertIn("name: Lint ${{ matrix.label }} (Docker)", ci)
        self.assertIn("label: format+syntax", ci)
        self.assertIn("label: pylint+shellcheck", ci)
        self.assertIn("wave: cheap", ci)
        self.assertIn("wave: heavy", ci)
        self.assertIn("ASUS_LINT_WAVE: ${{ matrix.wave }}", ci)
        self.assertNotIn("wave: [cheap, heavy]", ci)
        self.assertNotIn("\n  lint-docker:\n", ci)
        modes = (self.repo_root / "scripts/build-and-test-modes.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("step_lint_waves_parallel", modes)
        self.assertIn("lint-in-docker.sh", modes)
        lint_docker = (self.repo_root / "scripts/lint-in-docker.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("LINT_BUILDX_LOCK_ROOT", lint_docker)
        self.assertIn(".locks", lint_docker)
        self.assertIn("lint-image", lint_docker)
        self.assertIn("DOCKER_BUILDX_SKIP_PRUNE", modes)
        self.assertIn("_with_buildx_skip_prune", modes)
        self.assertIn("_run_post_lint_gates_workers", modes)
        self.assertIn("ASUS_LINT_WAVE", modes)
        self.assertNotIn("_run_lints_only_steps", modes)
        bat = (self.repo_root / "scripts/build-and-test.sh").read_text(encoding="utf-8")
        self.assertNotIn("_run_lints_only_steps", bat)
        self.assertIn("lints/tests only in Docker", bat)

    def test_lint_discovers_po_files_for_msgfmt(self) -> None:
        """Cheap-wave PO lint discovers repo *.po files and runs msgfmt -c."""
        run_lints = (self.repo_root / "scripts/run-lints.sh").read_text(encoding="utf-8")
        self.assertIn("find_po_files", run_lints)
        self.assertIn("step_po_lint", run_lints)
        self.assertIn("-name '*.po'", run_lints)
        self.assertIn("msgfmt -c --check-format", run_lints)
        wave1 = run_lints.split("LINT_WAVE1_STEPS=(", 1)[1].split(")", 1)[0]
        self.assertIn("step_po_lint", wave1)
        self.assertIn("step_no_lint_suppressions", wave1)
        self.assertIn("check_no_lint_suppressions.py", run_lints)

    def test_ci_distro_tests_are_family_split(self) -> None:
        """Compat lanes must use distro-tests-{debian,rhel,suse-arch} matrices."""
        ci = (self.repo_root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn("distro-tests-debian:", ci)
        self.assertIn("distro-tests-rhel:", ci)
        self.assertIn("distro-tests-suse-arch:", ci)
        self.assertNotIn("\ndistro-tests:\n", ci)
        self.assertIn("distro-full-de-debian:", ci)
        self.assertIn("distro-full-de-rhel:", ci)
        self.assertIn("distro-full-de-suse-arch:", ci)
        self.assertNotIn("\ndistro-full-de:\n", ci)
        modes = (self.repo_root / "scripts/build-and-test-modes.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("--distro-family", modes)
        self.assertIn("step_compat_family_matrices", modes)
        self.assertIn("_wait_bg_jobs_fail_fast", modes)

    def test_ci_cancels_previous_run_on_push(self) -> None:
        """New push/PR sync must cancel any prior CI run, not queue behind it."""
        ci = (self.repo_root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        # Workflow-wide group (not per-ref) so concurrent branch/PR runs cannot
        # starve runners while an older run finishes.
        self.assertRegex(
            ci,
            r"concurrency:\s*\n(?:\s*#[^\n]*\n)*\s*group:\s*\$\{\{\s*github\.workflow\s*\}\}",
        )
        self.assertRegex(
            ci,
            r"(?m)^\s*cancel-in-progress:\s*true\s*$",
        )
        self.assertNotRegex(
            ci,
            r"(?m)^\s*cancel-in-progress:\s*false\s*$",
        )

    def test_ci_full_de_max_parallel_is_twenty(self) -> None:
        """Full-DE matrix uses all 20 OSS concurrent GitHub-hosted runners."""
        ci = (self.repo_root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        start = ci.index("distro-full-de-debian:")
        end = ci.index("nested-session:", start)
        block = ci[start:end]
        self.assertIn("max-parallel: 20", block)

    def test_kcov_scenarios_run_in_parallel_shards(self) -> None:
        """Default kcov suite must shard bin-sound / ui / install-lib in parallel."""
        scenarios = (
            self.repo_root / "scripts/coverage/kcov-install-scenarios-shards.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("_kcov_start_shard_workers", scenarios)
        self.assertIn("bin-sound", scenarios)
        self.assertIn("install-lib", scenarios)
        self.assertIn("KCOV_SHARD", scenarios)
        parent = (
            self.repo_root / "scripts/coverage/kcov-install-scenarios.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("kcov-install-scenarios-shards.sh", parent)

    def test_coverage_gate_uploads_kcov_scenario_logs_on_failure(self) -> None:
        """CI must retain per-scenario kcov logs when coverage-gate fails."""
        ci = (self.repo_root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn("coverage-gate-kcov-logs", ci)
        self.assertIn("reports/distro-logs/kcov-scenarios/", ci)
        self.assertIn("reports/kcov/", ci)
        gates = (self.repo_root / "scripts/coverage/gates_kcov.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("_copy_kcov_scenario_logs_to_distro", gates)
        self.assertIn("distro-logs/kcov-scenarios", gates)
