---
name: pipeline-runner
description: Execute local pipeline checks, linting, code coverage, and test suites.
---

# Local Pipeline Runner Skill

Use this skill to validate project code quality, formatting, unit tests, and end-to-end tests locally before committing changes.

## Instructions

1. **New files**: Before finishing a change set that adds files, run applicable lint and tests on
   those paths (see **New files must be linted and tested** in root `AGENTS.md` and the
   `code-linter` / `test-runner` skills). Prefer targeted commands for a single new module; use
   `--full` or the relevant matrix lane when packaging, coverage gates, or cross-distro behavior
   changed.

1. Run pipeline/lint/test commands with live CLI streaming and persistent log capture under `reports/distro-logs/`.

- Before hand-editing lint failures, always run automatic formatters / delinters with safe autofix
  first (for example `ruff check --fix`, `ruff format`, `markdownlint --fix` when available,
  and `eslint --fix` for autofixable JS issues),
  re-lint, and only then manually fix remaining issues.
- Use `tee` so users can watch execution in real time and inspect saved logs afterward.
- Example full pipeline command:

  ```bash
  set -euo pipefail && sudo mkdir -p reports/distro-logs && \
    sudo timeout 10800 ./scripts/build-and-test.sh --full \
    2>&1 | sudo tee reports/distro-logs/full-pipeline.log
  ```

- Example single distro lane command:

  ```bash
  set -euo pipefail && sudo mkdir -p reports/distro-logs && \
  sudo timeout 3600 ./scripts/run_docker_matrix.sh --compat-only --distro rocky:10 \
  2>&1 | sudo tee reports/distro-logs/rocky-10.log
  ```

- `run_docker_matrix.sh` sources `scripts/docker_matrix_args.sh` for CLI parsing; keep both
  files in sync when adding matrix flags.

- Compatibility lanes must run `scripts/run_distro_install_smoke.sh` (wired via
  `build-and-test.sh --compat-only` only — not coverage-gate `--tests-only`):
  DESTDIR file install/uninstall, package availability for the OS family
  (including PyGObject / openSUSE versioned `python3XY-gobject`), DESKTOP
  gnome/kde/xfce/lxqt/cinnamon/mate configure cycles with stubbed
  session bus/CLI tools (extension tree + KDE `.desktop`s + XFCE state + LXQt
  `globalkeyshortcuts.conf`). XFCE `xfconf-query` stubs must quote `<…>` case
  patterns for dash `/bin/sh`. Inside the container — a live package cycle that
  removes sentinel deps
  (`xdotool`/`ydotool`), runs `install.sh`/`uninstall.sh` with `SKIP_PKG_*=0`,
  and asserts `installed-packages` recording plus real package removal. Test
  images include passwordless sudo for that path. Treat smoke failures as real
  distro compatibility bugs.

1. Run `./scripts/build-and-test.sh --full` from the repository root.
   `--full` must stay CI-parity with four host-orchestrated steps (~30 min warm cache):
   (1) `step_preflight_clean_build_trees` — Docker-alpine wipe of stale `.rpm-build*` and
   `packaging/arch/{pkg,src}` before lint; (2) lint waves in Docker (cheap ∥ heavy) ∥
   `scripts/run_deb_package_smoke.sh` with **`DEB_BUILD_OPTIONS=nocheck`** (no host unit
   tests; smoke covers install → plant share `__pycache__` → upgrade → purge and fails
   on dpkg “not empty” leftovers); (3) `step_post_lint_gates_parallel` — release package smoke (native worker: four
   RPM/Arch kinds ∥ portable worker: AppImage/Flatpak/Snap) ∥ coverage matrix (4 labeled cells
   on **debian:trixie**) ∥ three `--distro-family` compat matrices; (4) host
   `step_coverage_merge_host` ≥90% gates (merge only; no product tests).
   Do not drop the deb smoke from local `--full`.
   **Host orchestrates only** — never run `run-lints.sh`, `coverage run`, or
   unit/e2e on the pipeline machine; lints/tests execute only inside Docker.
   Exception: `coverage-merge` / `--coverage-merge-only` runs on the host
   (kcov + coverage.py merge of already-exported shard artifacts only).
   Background workers use **`setsid bash -c`** with **`set -euo pipefail`**, explicit
   **`cd "$1"`**, positional args passed after the script name, and **`2>&1 | tee "$log"`**:

   ```bash
   setsid bash -c '
       set -euo pipefail
       cd "$1"
       ./scripts/run_docker_matrix.sh --coverage-gate \
           2>&1 | tee "$2"
   ' bash "$REPO_ROOT" "$DISTRO_LOG_DIR/coverage-kcov-1.log" &
   ```

   `_wait_bg_status` waits on the **setsid leader PID**; pipefail ensures tee records
   real command failures. Before coverage workers start, wipe
   `reports/coverage-shards/` (and under `sudo`, chown that dir to `$SUDO_USER`)
   and require each exported `kcov-N`/`python-N` dir to
   contain a non-hidden `shard_ok` stamp at merge time (refuse stale shards).
   After wave-2 workers succeed, call `require_exported_coverage_shards` before
   the green banner (same gate as GHA `Verify coverage shard export stamp`).
   CI uploads shard data only on `success()` after that stamp check.
   Serial matrix logs for coverage cells are `coverage-gate-${MODE}-${SHARD}.log`.
   Wave 2 uses `_wait_bg_jobs_fail_fast` so the first failing
   release/coverage/compat lane kills sibling **process groups** (`setsid` workers +
   `_kill_pgid_list` in `docker-utils.sh`); `run_docker_matrix.sh` parallel compat uses
   the same `wait -n -p` pattern. Local lint cheap∥heavy share one
   `${DOCKER_BUILD_CACHE_DIR}/.locks/lint-image` mkdir lock (plus the shared
   `lint-python-3.13-slim` buildx cache lock). Local buildx cache exports serialize
   per scope via `mkdir` locks under `${cache_base_dir}/.locks/<cache-key>` in
   `docker-utils.sh` (parallel coverage-gate shards share `tests-debian_trixie`).
   `_find_repo_files` in `scripts/run-lints.sh` must prune `.rpm-build*`,
   `packaging/arch/pkg`, `packaging/arch/src`, `packaging/appimage/AppDir`,
   `packaging/flatpak/{builddir,repo}`, `.flatpak-builder`, and
   `packaging/snap/{parts,stage,prime}` (staged release payloads are not product
   sources). Python shards must be merged with one `coverage combine --keep` of all
   `coverage.dat` files (never raw-`cp` the first shard — that skips
   `[tool.coverage.paths]` remapping of Docker `/workspace` paths).
   CI `lint` job names use `format+syntax` / `pylint+shellcheck` (env
   still `ASUS_LINT_WAVE=cheap|heavy`); `coverage` job names use
   `kcov bin-sound+ui` / `kcov install-lib` / `python unit tests` /
   `python e2e tests`; distro jobs are family-split
   (`distro-tests-*` / `distro-full-de-*`).
   CI concurrency: `group: ${{ github.workflow }}` + `cancel-in-progress: true`
   (new push cancels the previous CI run; do not queue behind it).
   Full-DE cells use **runtime** `install-de-family.sh` on stub images (F1).
   Arch/Manjaro image `pacman -Syu`/`-S` (and Full-DE `_install_pacman`) retry via
   `docker/images/tests/scripts/pacman-retry.sh`. Arch CI images pin
   `archlinux-mirrorlist` (not geo/fastly) so stale `core.db` 404s cannot loop.
   Rocky/Alma kcov installs `libcurl-devel` via `el10-kcov-libcurl.sh` at the
   installed libcurl NEVRA (`--nobest` fallback; AppStream/BaseOS can skew).
   Deb smoke must clean `debian/asus-zenbook-linux-tools` (and related dh state) on
   EXIT so a leftover staged payload cannot make the next lint pass fail pylint
   `R0801` duplicate-code. Gettext freshness also requires
   `po/asus-zenbook-linux-tools.pot` to be
   **git-tracked** (a local-only/gitignored file is not enough).
   Arch package smoke (`packaging/arch/build-arch.sh`) flock-locks under
   `.cache/asus-arch-package-build/makepkg.lock` (inside the chowned cache dir);
   do not use a sibling `.cache/*.lock` (Permission denied for the makepkg user
   on a host-owned `.cache` bind mount).

1. **Keep fixing until the pipeline succeeds.** Do not stop after the first failure report.
   Treat every lint/test/coverage/matrix failure as blocking work:

- Diagnose the failure from the live output / `reports/distro-logs/` log.
- Apply autofix tools first, then hand-fix the remaining root cause.
- Re-run the full pipeline (or the failed stage when iterating locally, then re-run `--full`
  before declaring success).
- Repeat until `./scripts/build-and-test.sh --full` exits 0 with 0 errors and 0 warnings.
- **Never** ignore, suppress, disable, or downgrade failures to make the pipeline pass.
  Forbidden: `# pylint: disable`, `# noqa`, `# type: ignore`, `# shellcheck disable`,
  `# ruff: noqa`, `per-file-ignores`, markdownlint disable wraps, lowering thresholds, skipping
  tests, or claiming success while any gate still fails. Cheap-wave
  `step_no_lint_suppressions` (`scripts/check_no_lint_suppressions.py`) fails closed on
  any of those tokens in scanned source/config — fix the code, do not add an allowlist.
- Prefer real code/test/docs fixes that satisfy the existing gates.
- **Kcov timeouts stay at ≤45s.** Never raise `KCOV_RUN_TIMEOUT_SECS` (or scenario budgets)
  above 45 seconds to paper over slow kcov runs. The runner clamps to 45s and uses
  `timeout --signal=KILL` with no kill-after grace (do not change to SIGTERM-first). Exit
  `124`/`137` means fix the root cause (include-path too broad, hung scenario, slow product
  path). Keep `--include-path` scoped to product shell only (`bin/`, `lib/`, `install.sh`,
  `uninstall.sh`).

1. Verify all script-reported steps complete with 0 errors and 0 warnings:

- Bash syntax check (`bash -n`)
- File-size validation (`python3 scripts/check_file_size_limits.py`) — **600-line cap** on scoped
  production/test files (`bin/`, `lib/`, `tests/`, `tools/`, `scripts/`, `gnome/`, `docker/`, root
  installers, and Debian maintainer scripts under `debian/`). Only `packaging/arch/{pkg,src}` are
  pruned from the walk (other repo `pkg/` / `src/` dirs stay scanned). Failures are fixed by
  **splitting into smaller files**, never by removing
  comments, docstrings, or blank lines to trim the count.
- Version sync (`scripts/sync_poetry_version.sh` via `step_version_sync`) — root `VERSION` is the
  sole release number; pyproject.toml `tool.poetry.version` is synced output, not hand-edited.
- Ruff linting (same filtered command set used by `scripts/build-and-test.sh`)
- Gettext PO syntax (`msgfmt -c --check-format` on every `_find_repo_files` `*.po` in
  cheap-wave `step_po_lint`) plus template freshness and all 99 catalog checks
  (`extract_pot.sh --check`, `msgcmp`, quality gates including a real `PO-Revision-Date` —
  never the `YEAR-MO-DA` placeholder that warns during install locale compile;
  placeholder/plural/fuzzy validation, and translated canaries)
- Pylint (same discovery as [scripts/run-lints.sh](../../../scripts/run-lints.sh) `find_python_files`):

  ```bash
  find_python_files() {
      find . \
          -path './.git' -prune -o \
          -path './.venv*' -prune -o \
          -path './.pytest_cache' -prune -o \
          -path './.ruff_cache' -prune -o \
          -path './.cache' -prune -o \
          -path './node_modules' -prune -o \
          -path './.tools' -prune -o \
          -path './reports' -prune -o \
          -type f -name '*.py' -print | sort
  }
  py_list=$(mktemp)
  find_python_files >"$py_list" || { rm -f "$py_list"; exit 1; }
  mapfile -t PYTHON_FILES < <(grep -Ev '^(\./)?tests/unit/' "$py_list" || true)
  rm -f "$py_list"
  unit_list=$(mktemp)
  find tests/unit -type f -name '*.py' | sort >"$unit_list" || {
      rm -f "$unit_list"
      exit 1
  }
  mapfile -t UNIT_TEST_FILES < "$unit_list"
  rm -f "$unit_list"
  pylint --fail-under=10 --max-line-length=140 "${PYTHON_FILES[@]}"
  pylint --fail-under=10 --rcfile=tests/unit/.pylintrc --max-line-length=140 "${UNIT_TEST_FILES[@]}"
  ```

- Yamllint (`find_yaml_files` / `yamllint` on all repo `*.yml` / `*.yaml`, excluding generated dirs)
- Radon cyclomatic complexity A-rank enforcement for Python files
- MarkdownLint (all repo `*.md`, including root `AGENTS.md`; same prunes as `find_markdown_files` in
  `scripts/run-lints.sh` — `.git`, `.venv*`, `.pytest_cache`, `.ruff_cache`, `.cache`,
  `node_modules`, `.tools`, `reports`):

  ```bash
  find_markdown_files() {
      find . \
          -path './.git' -prune -o \
          -path './.venv*' -prune -o \
          -path './.pytest_cache' -prune -o \
          -path './.ruff_cache' -prune -o \
          -path './.cache' -prune -o \
          -path './node_modules' -prune -o \
          -path './.tools' -prune -o \
          -path './reports' -prune -o \
          -type f \( -name '*.md' -o -name '*.markdown' \) -print | sort
  }
  md_list=$(mktemp)
  find_markdown_files >"$md_list" || { rm -f "$md_list"; exit 1; }
  mapfile -t MD_FILES < "$md_list"
  rm -f "$md_list"
  markdownlint "${MD_FILES[@]}"
  ```

- ShellCheck (`shellcheck`)
- Shell Cyclomatic Complexity:

  ```bash
  python3 tools/shell_complexity.py \
    install.sh uninstall.sh bin/*.sh lib/*.sh scripts/*.sh \
    debian/postinst debian/prerm debian/postrm debian/asus-zenbook-configure \
    --max-grade A
  ```

- Systemd unit verification (`systemd-analyze verify`)
- Python unit tests (`coverage run tools/dot_test_runner.py --start-dir tests/unit --top-level-dir . --failfast`)
- Shell line coverage gate (`kcov` line coverage $\ge 90\%$ on product shell:
  `bin/*.sh`, `lib/*.sh`, `install.sh`, and `uninstall.sh`)
  Boost `install.sh` via `scripts/coverage/drivers/install_reexec_helpers.sh`
  (stdin capture empty/write-fail/validate, `INSTALL_SOURCE_DIR` resolve paths,
  in-process `_validate_required_source_file` miss — nested `bash -c` is not
  attributed by kcov). Do not invent product-only coverage branches for re-exec.
  Distro smoke `_verify_helper_scripts_fail_closed` must clear its RETURN trap
  (path expanded at trap registration) so `main` return cannot hit `set -u` on
  a stale `$tmp`. Parallel `--compat-only` lanes use `COVERAGE_FILE=.coverage.<slug>`
  (`REPORT_DISTRO_SLUG`) so bind-mounted coverage DBs do not race.
- Mocked E2E tests (`coverage run -a tools/dot_test_runner.py --start-dir tests/e2e/mock --top-level-dir . --failfast`)
- Python code coverage gate (every real product `.py` file must appear at $\ge 90\%$, not only TOTAL).
  CI uses `run_python_coverage_gate` from `scripts/coverage/gates.sh` (thin facade sourcing
  `gates_python.sh` / `gates_shell.sh` / `gates_kcov.sh`; per-file plus TOTAL checks).
  Manual parity:

  ```bash
  # shellcheck source=scripts/coverage/gates.sh
  source scripts/coverage/gates.sh
  include_pattern="$(_python_coverage_include_pattern)"
  coverage report --include="$include_pattern"
  coverage report --include="$include_pattern" --format=total
  run_python_coverage_gate "$include_pattern" 90
  ```

  `run_python_coverage_gate` tees the human report, then gates on
  `coverage report --format=total` plus per-file / missing-module checks from
  `coverage json` (do not parse awk `$NF` from the human report).

  `_python_coverage_include_pattern` is derived from `_list_product_python_files` (find of
  `bin/` + `tools/` `*.py` plus `shared_imports.py`, `scripts/check_file_size_limits.py`,
  `sitecustomize.py`) so newly added product modules are included without a separate glob.
  Percent-below and missing-file JSON gates import shared `to_product_rel` from
  `scripts/coverage/product_relpath.py` (via `_GATES_SH_DIR` / `PYTHONPATH`); do not
  re-inline that normalizer in the gate heredocs.

- Coverage badge update (`coverage-badge`)

1. Validate distro test matrix coverage includes the always-on nine:

- `ubuntu:26.04`
- `debian:trixie`
- `fedora:44`
- `rocky:10`
- `opensuse/tumbleweed`
- `archlinux:latest`
- `opensuse/leap:16.0`
- `almalinux:10`
- `manjarolinux/base:latest`

Also validate always-on `ci.yml` `distro-full-de` (nine × DE families with
Rocky/Alma cinnamon/mate/lxqt excludes) and limited nested/MoveFocused/sticky
jobs. Nested jobs must apt-install full Shell/Mutter/Xvfb or ydotool sets and
hard-fail if those packages are missing; soft-skip only after install when
Shell/uinput still cannot start. **Not nightly.** SteamOS compatibility is
covered through the Arch lane and Arch-derivative detection tests.
Pin workflow `uses:` by commit SHA (`# vX.Y.Z` comment) on Node 24 runtimes
only (`actions/upload-artifact` **v7.0.1+**, not v4.6.x); keep `ci.yml` and
`ppa-release.yml` in sync (`test_ci_actions_pin_node24_upload_artifact`).
Rocky 10 Full-DE KDE uses `kf6-kconfig` / `kwriteconfig6` (same as Alma 10). Alma/RHEL 10
Full-DE XFCE builds pinned `xfconf` from source (`_install_xfconf_from_source`).

1. Enforce fast mocked E2E policy:

- Mocked/CI E2E test commands must use per-test timeout budgets between 20 and 30 seconds.
- Timeout overruns are failures and must never be suppressed.

1. Launchpad PPA release (tag `v*`):

- Workflow [`.github/workflows/ppa-release.yml`](../../../.github/workflows/ppa-release.yml)
  signs and uploads to `ppa:ventura8/asus-zenbook-linux-tools` (resolute only).
- Source version uses `PPA_UPLOAD_REVISION` (`${VERSION}+1ppa${PPA_UPLOAD_REVISION}~resolute1`);
  bump the revision when re-uploading the same `VERSION`.
- `debian/control` `Build-Depends-Indep` must include `python3-gi` (Launchpad runs
  `dh_auto_test` without `nocheck`; GNOME keybinding unit tests need GLib.Variant).
- `upload-to-ppa` uses `permissions: { contents: read }` and passphrase-via-stdin
  (`gpg --passphrase-fd 0`) with a trap-cleaned `sign-code.sh`.
- Requires **repository** secrets `GPG_PRIVATE_KEY` and `GPG_PASSPHRASE` (no
  Launchpad token; do not relocate them to environment secrets). The job may use
  GitHub Environment `ppa-release` for required-reviewer gating only.
- CI also runs Debian package smoke (`dpkg-buildpackage -b -us -uc`) on push/PR via
  the `package-smoke` matrix's `deb` cell. That smoke must exercise an upgrade path
  (reinstall with planted share `__pycache__` via `apt-get install --reinstall`)
  and fail closed if purge leaves
  `/usr/share/asus-zenbook-linux-tools` or prints dpkg “not empty so not removed”.
- Tag version must match the root `VERSION` file.
- `github-release` attaches **seven package targets** (`.deb`, three `.rpm`, Arch,
  AppImage, Flatpak, Snap) plus **`artifacts/SHA256SUMS`**; install docs require
  `grep -F 'asset' SHA256SUMS | sha256sum -c -` before local asset install (openSUSE:
  `zypper install --allow-unsigned-rpm` so dependencies resolve normally).
- `ppa-release.yml` must glob `../*.changes` and fail unless **exactly one** match exists.
- Native `debian/source/options` must `tar-ignore` local caches (`.cache`, `.venv`,
  `node_modules`, `reports`, …) so `-S` uploads stay small on dirty trees.
- Install `installed-packages` record write/reconcile must strip base interpreters
  (`python3`/`python`) the same way uninstall emit does.

1. Install checksum gate (mandatory with every `install.sh` change):

- After checkout, CI runs `sha256sum -c install.sh.sha256` (`lint`, `package-smoke`,
  `coverage`, `distro-tests-*`, and PPA jobs).
- **Whenever `install.sh` changes**, refresh `install.sh.sha256` in the same change set:
  `sha256sum install.sh > install.sh.sha256`. Do not leave a stale checksum.
- Confirm locally with `sha256sum -c install.sh.sha256` before declaring success.

1. Kcov coverage gate invariants:

- `kcov --merge` failures are hard failures (do not swallow with `|| true`).
- Parse `coverage.json` once for all product scripts; compare thresholds in shell (`awk`),
  not per-script Python re-parses. Gate keys are `KCOV_REPO_ROOT`-relative paths
  (`bin/…`, `lib/…`, `install.sh`, `uninstall.sh`), not basenames.
- `_kcov_repo_root()` memoizes `KCOV_REPO_ROOT` per shell process (explicit env, then
  `scripts/coverage` parent via `BASH_SOURCE`, else `pwd`). Isolated kcov PATH stubs
  symlink host tools discovered with `type -P` (`_kcov_isolated_bin_dir`, `_link_kcov_tool`).
- Keep product-path filtering and prefer `merged/kcov-merged/coverage.json`.
- Shared stub helper: `_kcov_make_stub` in `scripts/coverage/common.sh` for kcov
  install/scenario fixtures. Session/ydotool sockets use `_kcov_bind_unix_bus` there
  (drivers: `_bind_unix_socket_path` via `kcov_driver_common.sh`). Call `_setup_kcov_temp_root`
  in the parent shell inside `step_kcov_coverage` — not `$()` — so EXIT traps persist.
- Coverage drivers must keep temporary-file cleanup in their registered EXIT/RETURN traps;
  restore redirected descriptors before trap cleanup finishes, and resolve diagnostic logs
  through `resolve_reports_root`. `_install_print_next_step` must tolerate unset
  `INSTALL_STEP_*` counters (`set -u` kcov DE `configure_*` drivers skip `install.sh` planning).
- Coverage-driver environment scanning must stop at invalid assignment keys while preserving
  `KCOV_EXERCISE_RETURN_STATUS`; missing-peer tests should source the repository helper with
  `ASUS_COMMON_DIR` pointing at an empty/partial staging directory. AF_UNIX fixture bind
  warnings include the staging-path length so isolated-path failures are diagnosable.

1. Run real-system E2E only when debugging host-specific issues:

  ```bash
  set -euo pipefail
  mkdir -p reports/distro-logs
  sudo E2E_REAL_ALLOW_SYSTEM_CHANGES=1 ./scripts/run_real_e2e.sh \
    2>&1 | tee reports/distro-logs/real-e2e-tests.log
  ```
