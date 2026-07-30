"""CI/local pipeline parity guards for shared smoke entrypoints."""

from __future__ import annotations

import unittest
from pathlib import Path


class TestPipelineCiParity(unittest.TestCase):
    """Ensure local --full and GitHub Actions share the same gate scripts."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.repo_root = Path(__file__).resolve().parents[3]

    def test_deb_smoke_script_uses_safe_local_apt_path(self) -> None:
        """Local .deb install must use ./ or absolute paths (not release/package)."""
        script = (self.repo_root / "scripts/run_deb_package_smoke.sh").read_text(encoding="utf-8")
        self.assertIn("_apt_install_local_deb", script)
        self.assertIn('install_path="./$deb_path"', script)
        self.assertIn("runuser -u", script)
        self.assertIn("SUDO_USER", script)
        self.assertIn("_cleanup_debian_build_tree", script)
        self.assertIn("trap '_cleanup_debian_build_tree' EXIT", script)
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

    def test_ci_log_slug_sanitizes_colon_for_artifacts(self) -> None:
        """upload-artifact rejects ':' and '/' in names (ubuntu:26.04 → ubuntu-26.04)."""
        ci = (self.repo_root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn('log_slug="${log_slug//\\//-}"', ci)
        self.assertIn('log_slug="${log_slug//:/-}"', ci)
        self.assertIn('log_slug="${log_slug//:/-}-de-${{ matrix.de_family }}"', ci)

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
            "docker/images/tests/rocky-9.Dockerfile",
            "docker/images/tests/almalinux-10.Dockerfile",
        ):
            text = (self.repo_root / rel).read_text(encoding="utf-8")
            self.assertRegex(text, r"(?m)^\s*alsa-utils-\[0-9\]\*\s*\\?\s*$", msg=rel)
            self.assertNotRegex(text, r"(?m)^\s*alsa-utils-\*\s*\\?\s*$", msg=rel)

    def test_ci_distro_tests_timeout_allows_rocky_cold_build(self) -> None:
        """Rocky cold poetry/PyGObject image builds exceed a 20-minute job cap."""
        ci = (self.repo_root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        # Bound the distro-tests job block: name … timeout-minutes before Full-DE.
        start = ci.index("distro-tests:")
        end = ci.index("distro-full-de:", start)
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

    def test_ci_deb_package_job_calls_shared_smoke_script(self) -> None:
        """CI deb-package must not inline a divergent install path."""
        ci = (self.repo_root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn("scripts/run_deb_package_smoke.sh", ci)
        self.assertIn("deb-package:", ci)
        self.assertNotIn('apt-get install -y "$ARTIFACT_DEB"', ci)
        self.assertNotIn("apt-get install -y \"$ARTIFACT_DEB\"", ci)

    def test_full_pipeline_runs_deb_package_smoke_step(self) -> None:
        """Local --full must include the same Debian smoke gate as CI."""
        bat = (self.repo_root / "scripts/build-and-test.sh").read_text(encoding="utf-8")
        self.assertIn("step_deb_package_smoke", bat)
        self.assertIn(
            "MODE_STEPS=(step_lint_in_docker step_deb_package_smoke step_tests_in_docker)",
            bat,
        )
        self.assertIn("scripts/run_deb_package_smoke.sh", bat)

    def test_pot_freshness_requires_git_tracked_template(self) -> None:
        """Pot check must fail when the template is only local/gitignored."""
        extract = (self.repo_root / "scripts/i18n/extract_pot.sh").read_text(encoding="utf-8")
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
            'echo 1000',
        )
        for rel in (
            "scripts/coverage/kcov-install-scenarios.sh",
            "scripts/coverage/kcov-screenpad-scenarios.sh",
        ):
            text = (self.repo_root / rel).read_text(encoding="utf-8")
            for token in forbidden:
                self.assertNotIn(token, text, msg=f"{rel} must not contain {token!r}")
            self.assertIn('uid="$(id -u)"', text, msg=rel)

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
