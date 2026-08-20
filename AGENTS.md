# Project Agent Rules & Development Guidelines

## Project Overview

`asus-zenbook-linux-tools` provides Python `evdev` event daemons, bash scripts, and systemd service units to support ASUS ZenBook hardware
features under Linux (WMI hotkeys, ScreenPad window swapping, audio amp fixes, and touchpad corner gestures).

- **Version single source of truth**: The release number lives only in the root `VERSION` file
  (currently `1.0.3`, displayed as `v1.0.3`). After bumping `VERSION`, run
  `scripts/sync_poetry_version.sh` (also invoked from `step_version_sync` and
  `install-poetry-deps.sh`) so `pyproject.toml` `tool.poetry.version` matches; do not hand-edit
  the poetry version. PKGBUILD, RPM `%version`, and Snap `adopt-info` read `VERSION` at build time
  (no `sed` on tracked packaging files). Cut notes with
  [`.agents/skills/release/SKILL.md`](.agents/skills/release/SKILL.md)
  (version from the current branch; reset `PPA_UPLOAD_REVISION` to `1` on a new `VERSION`).

## UI Localization

- User-facing setup, notification, display-profile, and desktop-shortcut strings use
  GNU gettext domain `asus-zenbook-linux-tools`. `po/SUPPORTED_LANGUAGES` is the single
  Whisper-aligned 99-language list; `po/*.po` is source of truth and `.mo` files are generated
  with `scripts/i18n/build_mo.sh`. Never hand-edit generated catalogs. Track
  `po/asus-zenbook-linux-tools.pot` in git (`.gitignore` keeps a blanket `*.pot` ignore
  with an explicit `!po/asus-zenbook-linux-tools.pot` exception). Lint freshness
  (`scripts/i18n/extract_pot.sh --check`) requires the template to be
  **git-tracked** (not merely present on disk) and byte-identical to a regenerate —
  so a local gitignored copy cannot hide a CI checkout failure. Local
  `./scripts/build-and-test.sh --full` also runs `scripts/run_deb_package_smoke.sh`
  (same script as the CI `package-smoke` matrix's `deb` cell) and release package smoke via
  `scripts/run_release_package_smoke.sh` (the other seven kinds with install/remove smoke; CI
  `package-smoke` matrix covers each kind (deb + seven); local `--full` runs native four in parallel plus
  portable three with host deps). Local `--full` is four host steps:
  `step_preflight_clean_build_trees` (Docker-alpine wipe of stale `.rpm-build*` /
  `packaging/arch/{pkg,src}`, AppImage `AppDir`, Flatpak `builddir`/`repo` /
  `.flatpak-builder`, and Snap `parts`/`stage`/`prime`), `step_lint_and_deb_parallel`, then
  `step_post_lint_gates_parallel` (release smoke + four coverage shards + three compat
  families concurrently), then host `step_coverage_merge_host` ≥90% gates. Target wall-clock
  ~30 minutes with warm buildx cache. Local `--full` keeps `ASUS_RELEASE_PACKAGE_SMOKE_PARALLEL=1`
  (four native kinds in parallel; portable AppImage/Flatpak/Snap run in a sibling worker).
  Each kind uses its own artifact dir under
  `artifacts/${kind}/`, isolated RPM tops `.rpm-build-${kind}`, and Docker `alpine` cleanup
  (`_release_docker_rm` / `_release_wipe_dir_contents`) so root-owned container outputs do
  not block host `rm -rf` or leave stale cross-distro RPMs. `_find_repo_files` in
  `scripts/run-lints.sh` also prunes `.rpm-build*`, `packaging/arch/{pkg,src}`,
  `packaging/appimage/AppDir`, `packaging/flatpak/{builddir,repo}`, `.flatpak-builder`,
  and `packaging/snap/{parts,stage,prime}` so ESLint/pylint/shellcheck never scan staged
  payload copies.
  Arch `makepkg` runs as a dedicated non-root user inside the Arch smoke container (root
  `makepkg` is rejected). The flock lock lives under
  `.cache/asus-arch-package-build/makepkg.lock` (inside the chowned cache dir) — a
  sibling `.cache/*.lock` fails with Permission denied when `.cache` is root- or
  host-owned on the CI bind mount.
- UI language precedence is test-only `ASUS_TEST_MODE=1` + `ASUS_UI_LANG`, then session
  `LC_ALL` → `LC_MESSAGES` → `LANG` → `LANGUAGE`, then process env
  `LC_ALL` → `LC_MESSAGES` → `LANG` → `LANGUAGE`, then English msgids. Empty or whitespace-only
  locale env vars are treated as unset. Bare language codes derive a UTF-8 `LC_MESSAGES` via
  `locale -a` / env scan when available (else `C.UTF-8`); catalog language still comes from
  `LANGUAGE`. Never **export** `LC_ALL` to gettext subprocesses (only `LANGUAGE` +
  `LC_MESSAGES`) and never document `ASUS_UI_LANG` as an end-user setting.
- **Always update translations for all languages when a translated string changes**:
  Any add, edit, or remove of a gettext msgid (shell `_asus_gettext` /
  `_asus_gettextf` / `ngettext` / `pgettext`, or Python equivalents) must update
  `po/asus-zenbook-linux-tools.pot` **and every** `po/*.po` in
  `po/SUPPORTED_LANGUAGES` in the **same change set**. Do not ship empty, fuzzy,
  or English-copied msgstr for non-English locales. Incomplete catalog updates are
  incomplete work (same as missing tests or a stale `install.sh.sha256`). Workflow:
  change the marked source string → `scripts/i18n/extract_pot.sh` →
  `scripts/i18n/sync_pos.sh` (or equivalent msgmerge) → fill/update msgstr in all
  languages → `scripts/i18n/check_catalog_quality.py` and `msgfmt -c` (lint driver).
  Completeness is also gated by unit tests in
  `tests/unit/scripts/test_check_catalog_quality.py` (`check_catalogs()` on live
  `po/*.po` plus empty/fuzzy `_validate_entry` cases) — not lint alone.
- Catalog updates must preserve printf placeholders, use `ngettext` for counts and `pgettext`
  for ambiguous labels, keep protocol tokens (`WMI`, `TOUCHPAD`, `SOUND`, `DESKTOP`) and
  product names stable, and contain no fuzzy or empty non-English UI entries. Reject
  generator junk that still looks “translated”: trailing `\n#` continuations, `#@`/`@#`
  tokens, leading `#` before printf placeholders (`#%d`), trailing bare `#`, and
  hallucinated `GSM`/`MHz` band lists (`check_catalog_quality.py` enforces this by
  comparing artifact match counts between each msgstr and its paired msgid /
  msgid_plural — a source hit does not excuse extra junk in the translation). Keep
  `PO-Revision-Date` as a real timestamp (never gettext’s `YEAR-MO-DA HO:MI+ZONE`
  placeholder — that makes `msgfmt --check` warn during install); seeder uses
  `PO_REVISION_DATE` in `scripts/i18n/seed_whisper_languages.py`. Run
  `scripts/i18n/extract_pot.sh --check`, `scripts/i18n/check_catalog_quality.py`, and
  `msgfmt -c` through the repository lint driver after changing marked strings.
  Protocol input token `all` and TUI key labels `Space`/`Enter`/`Esc` stay literal in
  msgstr (do not localize the token users must type or the physical key names).
- `asus-control-center.sh` opens each desktop's native Settings app (GNOME Settings Activate,
  then family-specific settings CLIs / `.desktop` files). There is no bundled preferences UI.

## Launchpad PPA Release (Ubuntu resolute)

- Tag push `v*` runs [`.github/workflows/ppa-release.yml`](.github/workflows/ppa-release.yml):
  GPG-sign a native source package and `dput "$PPA_NAME"` to
  `ppa:ventura8/asus-zenbook-linux-tools` (**resolute only**; built-in `ppa:` target,
  no custom `~/.dput.cf`), then attach **multi-format release artifacts** to the
  GitHub Release (`.deb`, Fedora/Rocky/openSUSE `.rpm`, Arch `.pkg.tar.zst`,
  AppImage, Flatpak bundle, classic Snap, plus **`SHA256SUMS`** manifest). Install docs
  require `grep -F 'asset' SHA256SUMS | sha256sum -c -` before installing a downloaded
  release asset; openSUSE RPMs use `zypper install --allow-unsigned-rpm` after checksum
  verification. No Launchpad API token — anonymous FTP + GPG only.
  The `build-packages` matrix job builds non-Debian artifacts in parallel with PPA upload.
  The `upload-to-ppa` and `build-packages` jobs set `permissions: { contents: read }`
  (least privilege) and `upload-to-ppa` runs in the protected GitHub Environment `ppa-release`
  (required reviewers,
  self-approval disabled). Both `upload-to-ppa` and `github-release` use
  `runs-on: ubuntu-26.04`. Workflow-level `concurrency` uses
  `group: ppa-release` with `cancel-in-progress: false`. Signing uses **repository** secrets
  `GPG_PRIVATE_KEY` / `GPG_PASSPHRASE` (do not move them to environment secrets).
  Before importing the signing key, the job rejects tags whose target commit is
  not an ancestor of the repository default branch. Source version is
  `${VERSION}+1ppa${PPA_UPLOAD_REVISION}~resolute1` (`PPA_UPLOAD_REVISION` in
  `ppa-release.yml`; bump when re-uploading the same `VERSION`, reset to `1` on
  a new release).
  Signing uses a short-lived `sign-code.sh` created under a temp directory outside the
  source tree (absolute `--sign-command`) that feeds
  `GPG_PASSPHRASE` via `gpg --passphrase-fd 0` (stdin), with
  `trap 'rm -rf "$SIGN_DIR"' EXIT` around `dpkg-buildpackage`.
  Fail closed when `GPG_PASSPHRASE` is empty **before** writing `sign-code.sh` or
  `chmod` (do not create the signing wrapper when credentials are missing).
  Importing `GPG_PRIVATE_KEY` starts with `set -euo pipefail`, writes a temp file then
  `trap 'rm -f "$GPG_KEY_FILE"' EXIT` immediately after `mktemp`. Derive
  `GPG_FINGERPRINT` from `gpg --show-keys` on that temp key file (not a first-hit
  scan of an ambient keyring); ownertrust and `-k` signing use that fingerprint
  (long key id = last 16 hex digits). Extract-version and changelog steps also use
  `set -euo pipefail`. The
  `github-release` job verifies `install.sh.sha256` before building `.deb`
  artifacts (same as `upload-to-ppa`); its apt install step also uses
  `set -euo pipefail`. After unsigned `-b` build, assert exactly one
  `../${PACKAGE_NAME}_*.deb` before copying into `artifacts/` (same exact-one glob
  rule as CI `package-smoke`'s `deb` cell). Smoke removes leftover parent/artifact debs for that
  package name before build so an older `1.0.0` next to a new `1.0.1` cannot fail
  the glob. CI `package-smoke`'s `deb` cell uses a `_require_exact_one_glob` helper that **returns**
  nonzero (does not `exit 1` from the function); callers check status and abort the
  step.
- **Shared native payload staging**: [`packaging/stage-payload.sh`](packaging/stage-payload.sh)
  is the single source of truth for copying product files into
  `/usr/share/asus-zenbook-linux-tools/` plus locale `.mo` catalogs and
  `/usr/sbin/asus-zenbook-configure`. [`debian/rules`](debian/rules) calls it;
  RPM/Arch/AppImage/Flatpak/Snap builders call the same script. Scriptlet parity
  lives in [`packaging/scriptlets/configure-common.sh`](packaging/scriptlets/configure-common.sh)
  (RPM `%post`/`%preun`/`%postun`, Arch `.install`). AppImage/Flatpak/Snap are
  **installer-only** portable bundles (still require root for systemd/udev); native
  packages remain recommended. **Arch staging:** [`packaging/stage-payload.sh`](packaging/stage-payload.sh)
  must not `mkdir` `/usr/sbin` (owned by Arch `filesystem`); install only
  `/usr/sbin/asus-zenbook-configure` via `install -Dm755`. **Flatpak host handoff:**
  `--filesystem=host` exposes the host at `/run/host`; the Flatpak wrapper sets
  `ASUS_HOST_ROOT=/run/host`, `ASUS_PORTABLE_HOST_INSTALL=1`, and `PREFIX=/run/host`
  so configure deploys to the host (not `/app` or sandbox `/usr/local`). Staged
  `DESTDIR`/`PREFIX` smoke skips udev/group unless `ASUS_PORTABLE_HOST_INSTALL=1`
  (`_asus_is_staged_install` in `lib/install-shared.sh`). **Snap CI:** `package-smoke` /
  tag `build-packages` snap cells run on **ubuntu-24.04** with
  `snapcraft pack --destructive-mode` (core24 rejects destructive builds on 26.04);
  Ubuntu 26.04+ local hosts fall back to `--use-lxd`. **RPM package-smoke:** copy RPMs with
  `cp "$rpm_path" "$artifacts_dir/"` (basename-only); openSUSE smoke uses
  `zypper install --allow-unsigned-rpm` with deps preinstalled; container uninstall
  treats systemctl transport failures (`System has not been booted with systemd`,
  `Failed to connect to bus`) as non-fatal in `uninstall.sh` (stop/disable/verify
  and `daemon-reload`).
- Packaging lives under [`debian/`](debian/). Payload is installed to
  `/usr/share/asus-zenbook-linux-tools/`; `postinst` hardcodes
  `/usr/sbin/asus-zenbook-configure` and runs it with `SKIP_PKG_INSTALL=1`
  on first-time `configure` only (empty previous-version argument). The interactive
  wizard runs only when `_can_use_tty` sees both stdin and stdout as TTYs (`[ -t 0 ] && [ -t 1 ]`). Upgrades
  skip the interactive wizard unless `DEBCONF_RECONFIGURE=1` (`dpkg-reconfigure`).
  `prerm` hardcodes
  `/usr/share/asus-zenbook-linux-tools/uninstall.sh` with `SKIP_PKG_REMOVE=1`.
  Teardown errors (missing helper or uninstall failure) log to stderr and `prerm`
  exits nonzero so dpkg reports removal failure (message states package removal is
  aborted); successful teardown continues to
  exit 0. `postinst`, `prerm`, and `postrm` use `set -e` only (not nounset /
  `pipefail`) so generated `#DEBHELPER#` snippets stay safe; interactive
  configure failure returns nonzero with a reconfigure hint.
  `postrm` removes `/var/lib/asus-zenbook-linux-tools` on purge and, on
  `remove`/`purge`/`upgrade`, deletes leftover `__pycache__` under
  `/usr/share/asus-zenbook-linux-tools` (`remove`/`purge` also drop empty share
  dirs). Bytecode is not dpkg-owned and otherwise triggers
  “directory … not empty so not removed”. Packaged configure and the
  hotkey/touchpad units set `PYTHONDONTWRITEBYTECODE=1`; uninstall strips
  `__pycache__` under `$BIN_DIR` via `_asus_remove_bin_bytecode` and records
  failure when that find/`rm` cleanup does not complete. Deb smoke
  (`scripts/run_deb_package_smoke.sh`) install → plant share `__pycache__` →
  `apt-get install --reinstall` (same version; plain reinstall is a no-op) →
  purge, and fails closed on leftover share paths or the
  dpkg “not empty” warning.
  Source `debian/control` sets `Rules-Requires-Root: no`, `Standards-Version: 4.7.2`,
  keeps
  `debhelper-compat` in `Build-Depends`, and lists `python3` /
  `python3-evdev (>= 1.6.0)` / `python3-dbus` / `python3-gi` / `python3-yaml`
  under `Build-Depends-Indep` (Architecture: all). `python3-gi` is required for
  Launchpad binary builds: `override_dh_auto_test` runs unit tests (no
  `nocheck` on LP) and GNOME keybinding helpers need GLib.Variant. Package
  `Depends` lists unversioned `python3` (no `>= 3.13` floor) and pins
  `python3-evdev (>= 1.6.0)` for `InputDevice.absinfo`.
  Wizard deploy still lands under `/usr/local` like `install.sh`.
  Reconfigure via `dpkg-reconfigure` or `asus-zenbook-configure`.
- CI also builds an unsigned `.deb` smoke in [`ci.yml`](.github/workflows/ci.yml)
  (`package-smoke`'s `deb` matrix cell and local `./scripts/build-and-test.sh --full` both call
  `scripts/run_deb_package_smoke.sh`: apt installs `python3-yaml` / `python3-gi` /
  gettext with the other Build-Depends, runs `dpkg-checkbuilddeps` before
  `dpkg-buildpackage -b -us -uc`
  (when the smoke is invoked under `sudo`, build drops to `SUDO_USER` via
  `runuser` so packaging matches CI’s non-root runner). **Deb smoke always sets
  `DEB_BUILD_OPTIONS=nocheck`** so `override_dh_auto_test` does **not** run
  product unit tests on the pipeline/CI host — unit/kcov/e2e stay in coverage
  Docker only. Smoke removes leftover `../${PACKAGE_NAME}_*.deb` and matching
  `artifacts/` debs before `-b`. Assert exactly one parent package `.deb` and one
  `artifacts/*.deb`, then
  noninteractive `apt-get install -y` of a `./`-or-absolute local `.deb` path
  (apt treats an unprefixed `dir/file.deb` as `release/package`), `dpkg -s`
  verify, and `apt-get purge` before upload). No TTY → postinst skips the
  interactive wizard. `lint` (cheap∥heavy matrix), `package-smoke`, `coverage`,
  and `distro-tests-*` each verify `install.sh.sha256` immediately after
  checkout. PPA `upload-to-ppa` / `github-release` apt paths likewise install
  `python3-yaml` / `python3-gi` / gettext and run `dpkg-checkbuilddeps` before
  `dpkg-buildpackage -S` / `-b`.
  Hotkey OSD cancel uses `asus_hotkey_daemon_osd._subprocess_run` (patch that
  alias in tests — never `asus_hotkey_daemon_osd.subprocess.run`, which rebinds
  stdlib `subprocess.run` for every importer).
  `debian/rules`
  uses `dh $@ --buildsystem=none`. `override_dh_auto_test` runs `bash -n` on
  product shell and `unittest discover` on `tests/unit` unless `DEB_BUILD_OPTIONS`
  contains `nocheck` (live output tee'd to
  `reports/distro-logs/deb-dh-auto-test.log` with `pipefail`).
  `override_dh_auto_install` enables `nullglob` with `set -e` and copies `lib/*.sh`,
  `systemd/*.service`, and icon globs via guarded loops so empty matches do not
  fail and real `cp` failures abort the recipe; `gnome/` and `udev/` are copied
  only when those directories exist; relative daemon symlinks under `bin/` are
  preserved with `cp -a`.
  `override_dh_clean` removes only that targeted test log (never wipes all of
  `reports/distro-logs/`). `postinst`
  runs `systemctl daemon-reload` only when systemd is live: treat printed
  `is-system-running` states `running|degraded|starting|maintenance` as live
  (do not rely on exit status alone); failures propagate on running systems.
  Successful interactive `_run_interactive_configure` also calls
  `_daemon_reload_if_live` before returning 0.
- Required GitHub Actions **repository** secrets (same key as Ubuntu-Hello PPA
  uploads; keep at repo scope — do not relocate to the `ppa-release` environment):
  `GPG_PRIVATE_KEY` (ASCII-armored private key) and `GPG_PASSPHRASE`.
  The `ppa-release` environment is for required-reviewer gating only.
- Maintainer one-time Launchpad setup: create PPA `asus-zenbook-linux-tools` under
  `ventura8`, enable **Resolute**, ensure the GPG public key is already validated on
  Launchpad. Per release: bump `VERSION`, merge workflow to default branch, push tag
  `vX.Y.Z` matching `VERSION`, wait for workflow + Launchpad publish.
- Export key for secrets (example key id):
  `gpg --export-secret-keys --armor B62A8A740D77C4E0 > asus-ppa-private.asc`
  then paste into GitHub repo secrets and `shred -u` the local file. Do not commit keys.
- Human Ubuntu install docs prefer the PPA one-liner; keep `curl|bash` for other distros.
  Do not put `NONINTERACTIVE_CHOICE` in human PPA/quick-start snippets.

## Code Style & Testing Enforcement

- **New files must be linted and tested**: When adding or creating files as part of a change
  set, run the applicable linters and tests before finishing — do not leave new paths unvalidated.
  Treat lint failures or missing tests on new product code the same as incomplete work (like a
  stale `install.sh.sha256` or outdated agent docs). Match existing layout (`tests/unit/` mirrors
  production structure; kcov scenarios for new product shell). Use
  [`.agents/skills/code-linter/SKILL.md`](.agents/skills/code-linter/SKILL.md) and
  [`.agents/skills/test-runner/SKILL.md`](.agents/skills/test-runner/SKILL.md), or targeted
  commands when the full pipeline is too heavy:
  - **Product Python** (`bin/`, `tools/`, `scripts/*.py`): `ruff` + `pylint`; add unit tests under
    `tests/unit/` when behavior is testable.
  - **Product shell** (pruned-repo `*.sh` including `bin/`, `lib/`, `scripts/`, `packaging/`
    builders, installers): `shellcheck` + `bash -n`; add kcov scenarios or unit shell tests when
    behavior is testable.
  - **GNOME JS** (`gnome/**/*.js`): `eslint`.
  - **Docs / workflows** (`*.md`, `.github/**/*.yml`, `*.yaml`): `markdownlint` / `yamllint`.
  - **Gettext catalogs** (`po/*.po`): `msgfmt -c` and catalog-quality checks when msgids change.
  - **Config-only / assets / packaging stubs**: lint when a gate applies; tests only when the file
    introduces testable logic (otherwise document why tests are not applicable).
  After edits, prefer `ReadLints` on touched paths and run the narrowest test/lint command that
  covers the new file before declaring the task done.
- **No Suppressions Allowed**: Never silence linters, type checkers, or quality
  gates. Forbidden in product, **tests/** (unit + e2e), packaging, CI, and tooling
  source — there is no test exemption:
  `# pylint: disable` / `disable-next`, `# noqa`, `# ruff: noqa`, `# type: ignore`,
  `# shellcheck disable`, `eslint-disable` (+ `-line` / `-next-line`),
  `markdownlint-disable` (only as an HTML comment directive after `<!--`; naming
  the token in policy prose is fine), `yamllint disable`, `# hadolint ignore`,
  `pragma: no cover`, `# nosec`, `# flake8: noqa`, `[tool.ruff.lint.per-file-ignores]`,
  pylint `disable=` lists, ESLint rule `"off"`, and markdownlint MD013 exemptions
  (`code_blocks` / `tables: false`). Path ignores for build caches (eslint `ignores`
  for `node_modules` / `.cache`) are not suppressions. Cheap-wave
  `step_no_lint_suppressions` (`scripts/check_no_lint_suppressions.py`) fails closed
  on any hit in scanned trees (including `tests/`) — fix the underlying issue; do not
  add an exception. Unit tests in `test_check_no_lint_suppressions.py` assert the live
  `tests/` tree and whole repo stay clean.
  Hyphenated CLI entrypoint names required by systemd (`asus-hotkey-daemon.py`,
  `asus-touchpad-share.py`) must be **symlinks** to underscore-valid Python modules
  so `N999` does not apply. Do **not** suppress `N999` with line/file `# noqa`,
  `# ruff: noqa`, `per-file-ignores`, or global `ignore`.
- **Failure Handling**: Do not hide, suppress, or downgrade real failures. If a component cannot be installed successfully,
  report the actual error and fail the install instead of claiming success.
- **Linting Integrity**: Never ignore or suppress lints, warnings, or test failures. Fix the underlying issue and keep the
  repository healthy. `tests/unit/.pylintrc` `init-hook` must stay **flat** (no nested `for`/`if` blocks): ConfigParser
  strips leading indentation from multiline values and nested Python will raise `IndentationError`.
  Do **not** disable `protected-access` in that rcfile; unit tests that need private helpers must call
  them via `tests.unit.bin.attr_helpers.call_attr` / `get_attr` (getattr by name), not `module._name`
  attribute access.
- **Auto-fix Before Manual Lint Fixes**: Always run automatic formatters / delinters with safe autofix **before**
  hand-editing for lint failures. Prefer tool-applied fixes first, then only manually repair what remains.
  Examples: `ruff check --fix` (and `ruff format` when formatting is in scope), `markdownlint --fix` when available,
  and any other project-supported autofix. Do not skip autofix and rewrite cleanable issues by hand.
- **Strict Linting Requirements**:
  - Python: Clean `ruff` and `pylint` (10.00/10 rating required; `step_pylint`
    passes `--fail-under=10` so a 9.98 score fails the gate).
  - Cyclomatic Complexity: `radon cc` **A-rank** maximum (all blocks must score ≤ 5).
  - Shell Scripts: `bash -n` syntax validation and `shellcheck` compliance.
    `scripts/run-lints.sh` runs `shellcheck -S warning` (fail on warning/error; info
    such as SC2317/SC2329 on dynamic `"$step"` / trap handlers must not fail the gate).
    `scripts/run-lints.sh` discovers all repo `*.sh` via `_find_repo_files` (same prune set
    as Python/YAML/Markdown), plus Debian maintainer scripts; that includes coverage
    scenario entrypoints (`scripts/coverage/kcov-scenarios.sh`, `kcov-install-scenarios.sh`,
    `kcov-screenpad-scenarios.sh`) and CI image helpers under `docker/images/tests/scripts/`.
    `_find_repo_files` must also prune `debian/asus-zenbook-linux-tools`, `debian/tmp`,
    `debian/.debhelper`, `artifacts`, `.rpm-build*`, `packaging/arch/pkg`,
    `packaging/arch/src`, `packaging/appimage/AppDir`, `packaging/flatpak/builddir`,
    `packaging/flatpak/repo`, `.flatpak-builder`, and `packaging/snap/{parts,stage,prime}`
    so a leftover package-build payload copy cannot make pylint
    `R0801` duplicate-code or ESLint `global` fail the lint gate. `run_deb_package_smoke.sh`
    cleans the debian tree before build and on EXIT; `--full` runs
    `step_preflight_clean_build_trees` for RPM/Arch/portable staging trees for the same reason.
  - JavaScript: Clean `eslint` on `gnome/**/*.js` (flat config `eslint.config.mjs`; no inline
    `eslint-disable`). GNOME Shell globals such as `global` are declared in the config.
    `scripts/run-lints.sh` `step_eslint` must `npm ci` into the workspace when
    `node_modules` lacks `eslint` / `@eslint/js` / `@stylistic/eslint-plugin`, then invoke
    **only** `./node_modules/.bin/eslint`. Do **not** fall back to a global `eslint` or bare
    `npx eslint@…` — flat-config imports resolve from the repo root, so a clean CI checkout
    (no bind-mounted host `node_modules`) fails that way while local lint-in-docker can pass.
    Keep `@eslint/js` listed in `package.json` `devDependencies` (config imports it directly).
    The lint Docker image provides Node/npm (and markdownlint-cli); it must not pretend a
    global eslint install is enough.
  - YAML: `yamllint` format validation (≤140 char lines, valid booleans).
  - Gettext PO: cheap-wave `step_po_lint` discovers repo `*.po` via `_find_repo_files` and
    runs `msgfmt -c --check-format` on each catalog (fail closed if `msgfmt` is missing or
    no `.po` files are found). Heavy-wave `step_i18n_catalogs` still runs
    `extract_pot.sh --check`, `seed_whisper_languages.py --check`, and
    `check_catalog_quality.py`. Python unit coverage also runs
    `tests/unit/scripts/test_check_catalog_quality.py`, which calls `check_catalogs()`
    so incomplete catalogs fail the unit suite without relying on lint alone.
  - Markdown: `markdownlint` compliance (≤140 char lines, proper blank lines).
    Prefer readable wraps that break after trailing `&&` or `|` (or with `\`) so each
    physical line stays ≤140. Do **not** suppress MD013 and do **not** disable MD013 for
    all code blocks or tables in `.markdownlint.json`.
  - **File size (600 lines)**: `scripts/check_file_size_limits.py` caps production and test
    files in `bin/`, `lib/`, `tests/`, `tools/`, `scripts/`, `gnome/` (including `.js`
    extension sources), `docker/` (CI image helpers), root installers, and Debian
    maintainer scripts (`debian/postinst`, `debian/prerm`, `debian/postrm`,
    `debian/asus-zenbook-configure`), at **600**
    physical lines. When a file exceeds the limit, **split it into smaller modules** (helpers,
    sibling `_*.sh` / `_*.py`, focused test modules) and wire imports/sources explicitly.
    **Never** “fix” a violation by deleting comments, docstrings, blank lines, or readable
    spacing—that is forbidden. Refactors must preserve behavior and coverage; re-run lint and
    tests after the split.
- **Install One-Liners (Interactive for Humans)**: Human-facing quick-install commands in
  `README.md` and release notes must be one pasteable interactive command in a fenced `bash`
  block (`curl … | sudo bash` or checksum-verified `… && sudo bash`). Prefer readable wraps that
  break after trailing `&&` or `|` (or with `\`) so each physical line stays ≤140 chars.
  Do **not** put `NONINTERACTIVE_CHOICE=…` in those human quick-start snippets.
  **Exception — headless/automation**: clearly labeled automation sections in
  `docs/INSTRUCTIONS.md` may use a `NONINTERACTIVE_CHOICE=…` install command (same wrap style).
  Piped `install.sh` re-exec binds stdin only (`exec </dev/tty`) so stdout/stderr stay on the
  caller’s pipes for CI logging; do not redirect `>/dev/tty 2>&1` on that re-exec.
- **Install script checksum (`install.sh.sha256`)**: Whenever `install.sh` changes, refresh
  `install.sh.sha256` in the **same change set** before finishing:
  `sha256sum install.sh > install.sh.sha256`, then confirm with `sha256sum -c install.sh.sha256`.
  Do not ship an `install.sh` edit without the matching checksum file. CI (`lint`,
  `package-smoke`, `coverage`, `distro-tests-*`) and PPA `upload-to-ppa` / `github-release`
  verify `install.sh.sha256` immediately after checkout — a stale hash fails the pipeline.
  Piped installs also verify the captured script against this file.
- **Code Coverage**: Minimum **90%** test coverage enforced on product Python via `coverage.py`
  (`coverage report` human tee for logs; gate totals via `coverage report --format=total` and
  per-file / missing-module checks via `coverage json` for
  `--include="$(_python_coverage_include_pattern)"`, threshold **90%).
  Coverage gates live behind thin facade `scripts/coverage/gates.sh` (sets `_GATES_SH_DIR`
  to `scripts/coverage/` and sources `gates_python.sh` / `gates_shell.sh` /
  `gates_kcov.sh`). Existing `source …/gates.sh` call sites stay unchanged.
  `_python_coverage_include_pattern` in `gates_python.sh` is derived from
  `_list_product_python_files` (find of `bin/` + `tools/` `*.py`, plus hardcodes
  `shared_imports.py`, `scripts/check_file_size_limits.py`, and `sitecustomize.py`) so new
  modules are gated without updating a separate glob string (do not widen to all
  `scripts/**/*.py`). Hardcoded extras also include
  `scripts/check_no_lint_suppressions.py` and `scripts/repo_scan_common.py`.
  Python coverage percent/missing-file gates share
  `scripts/coverage/product_relpath.py` `to_product_rel` (imported via `PYTHONPATH` from
  `_coverage_scripts_dir`); do not duplicate that normalizer in the gate heredocs.
  Match `bin/`, `tools/`, or `scripts/` only at a path segment boundary
  (`idx == 0` or prior `/`); strip a single leading `./` only (never `lstrip("./")`).
  Missing product Python modules are listed only via
  `_list_missing_product_python_coverage_from_json` (no awk report-text scanner).
  `_load_all_script_coverage` (in `gates_shell.sh`) passes `ASUS_PRODUCT_TOPLEVEL_SCRIPTS`
  as a leading env assign on the `python3` invocation only (do not `export` it into the
  parent shell).
  Product Bash (`bin/*.sh`, `lib/*.sh`, `install.sh`, `uninstall.sh`) is gated to
  **≥90%** line coverage via `kcov`.
  In product Bash, initialize associative arrays with `declare -A name` followed by
  explicit assignments; kcov counts compound-assignment entries as executable but cannot
  attribute hits to them.
  CI tooling under `scripts/*.sh` (except `scripts/check_file_size_limits.py` for Python)
  is excluded from those line-coverage gates and is validated with `bash -n`, `shellcheck`,
  and pipeline/e2e checks.
  `gates_shell.sh` `_list_product_shell_scripts` discovers `bin/` + `lib/` `*.sh` plus
  `install.sh` / `uninstall.sh` the same way (new helpers are required in the kcov report).
  `scripts/run-lints.sh` shell targets are all pruned-repo `*.sh` files plus Debian maintainer
  scripts (not a fixed `scripts/*.sh` / `scripts/coverage/*.sh` glob list).
- **Kcov Scenario Timeout Cap (45s)**: Per-scenario kcov runs must finish within **45 seconds**
  (`KCOV_RUN_TIMEOUT_SECS` is clamped to ≤45 in `scripts/coverage/common.sh`). Do **not** raise
  this cap to hide slow instrumentation. Use `timeout --signal=KILL` with no kill-after grace
  beyond the cap (do **not** switch to SIGTERM-first). Exit `124`/`137` is a real failure: fix
  include-path scope, scenario setup, or product/script behavior. Keep kcov `--include-path`
  limited to product shell (`bin/`, `lib/`, `install.sh`, `uninstall.sh`) — never the whole
  repository root. The sound kcov driver (`scripts/coverage/drivers/sound_helpers.sh`) requires
  `DEV_SND_ROOT` (scenarios set it); `SOUND_HELPER_MODE=remove` fails closed when
  `remove_installed_files` is not defined after sourcing the product script.
  Drivers that call `resolve_reports_root` (`sound_helpers`, `uninstall_helpers`,
  `shared_helpers`) must `source scripts/coverage/gates.sh` first — the helper lives in
  `gates_kcov.sh` and is not loaded by `kcov_driver_common.sh` alone.
  Install/DE kcov drivers must call `_driver_source_i18n` (loads `lib/asus-i18n.sh`)
  before exercising helpers that use `_asus_gettext` / `_asus_gettextf`.
  `SOUND_HELPER_MODE=remove` sources `uninstall.sh` with `ASUS_UNINSTALL_SOURCE_ONLY=1`
  and a stub `SYSTEMCTL_CMD` so `remove_installed_files` can succeed under kcov.
  The `uninstall_remove_deps` kcov scenario stubs `apt-get`, `apt-mark`, and `dpkg-query`
  (Debian remove builds `apt-mark auto … && apt-get … autoremove`).
  `_kcov_repo_root()` in `scripts/coverage/common.sh` resolves the repo root (env override,
  then path from `BASH_SOURCE`, else `pwd`) and may set `KCOV_REPO_ROOT` when called directly;
  subshells from `$()` cannot persist that assignment, so callers must assign
  `KCOV_REPO_ROOT="$(_kcov_repo_root)"` in the current shell. Leading `key=value` env prefixes
  for kcov runs share `_kcov_shift_leading_env_exports` in that file (also used by coverage
  drivers via `kcov_driver_common.sh`); it fails closed (exit 127) when prefixes consume all
  arguments. `_exercise` propagates nonzero status when `KCOV_EXERCISE_RETURN_STATUS=1` is set
  globally or as a **leading** `key=value` assign (scan stops at the first
  non-assignment, matching `_kcov_shift_leading_env_exports`). `_kcov_run` fails closed (exit 127) when `timeout` is absent.
  `_kcov_clamp_run_timeout` warns on stderr when `KCOV_RUN_TIMEOUT_SECS` is numeric
  but outside 1–45 before clamping to 45.
  Product kcov scenarios must use `_kcov_expect_run` / `_kcov_expect_run_env` with a single
  intended exit per label (not `0,255` CSV). Coverage drivers log under `reports/distro-logs/`
  (tee/`exec` where drivers source product shell). **Fail closed on unexpected exits:** never put
  `run_shell_kcov_scenarios` on the LHS of `||` (bash disables `errexit` there and the suite can
  print `✗ Unexpected kcov scenario exit` while still returning 0). `_run_and_merge_kcov_scenarios`
  runs the suite in a nested `( set -euo pipefail; … )` and checks status; `_kcov_expect_exit` /
  direct expect also append to `KCOV_SCENARIO_FAIL_FILE`, and `run_shell_kcov_scenarios` returns 1
  when that file is non-empty.   `_kcov_run` defaults `ASUS_I18N_FORCE_MSGID=1` so nested gettext
  does not make kcov+bash drop caller line hits (fan/camera/display notify coverage); `i18n_helpers`
  clears `ASUS_I18N_FORCE_MSGID` in-process when exercising real gettext/ngettext. kcov
  `--include-path` is product shell plus `scripts/coverage/drivers` (not the repo root):
  driver entrypoints must be included or sourced `lib/`/`bin/` hits are dropped. ScreenPad/camera kcov
  drivers set `ASUS_NOTIF_APP_NAME_COLOR` (skip host gnome-shell.css scans that hang under kcov).
  Installed-lib bootstrap scenarios isolate empty `SYS_PLATFORM_ROOT` / `SYS_CLASS_ROOT`, force
  `ASUS_FAN_USE_PPD=0`, and stub `loginctl` so live hardware/session cannot flip expected-1 exits
  to 0. `run_shell_kcov_scenarios` nonzero exit fails the kcov gate;
  `resolve_reports_root` fails when the fallback reports directory cannot be created.
  Distro install smoke (`scripts/run_distro_install_smoke.sh`) builds log paths under
  `$(resolve_reports_root)/distro-logs/` (source `scripts/coverage/gates.sh`; do not hardcode
  `$REPO_ROOT/reports`). Coverage drivers that `source` product libs
  (`os_detect_helpers`, `kde_helpers`, `components_helpers`) use guarded `if ! source …`
  with an explicit stderr diagnostic and no `>/dev/null 2>&1` on failure.
  `common_helpers` mkdir/bind only `$BUS_ROOT/$(id -u)` (no hard-coded UID `1000`).
  Kcov install/screenpad fixtures must likewise use `uid="$(id -u)"` for session bus
  and GNOME backup state roots (`bus_root/$uid`, `var/lib/.../$uid`) — never hardcode
  `1000`. Local Docker often maps host UID 1000; GitHub Actions `asusci` is typically
  1001, so a hardcoded bus under `/1000` makes `install_all` fail only in CI.
  `_run_kcov_cc_desktop_runs` EXIT trap always `rm -rf "$iso_tmp"` and removes
  `"$desk_iso"` only when non-empty. Isolated PATH dirs link real tools
  with `type -P` (`_kcov_isolated_bin_dir`, `_link_kcov_tool`, and selection kcov
  `_selection_link_tools` / `asus_desktop_family` stubs) rather than guessing paths
  or using `command -v` (builtins like `true`/`printf` must not become symlink targets).
  AF_UNIX session-bus and ydotool socket fixtures use `_kcov_bind_unix_bus` (alias
  `_bind_unix_socket_path` for drivers) in `scripts/coverage/common.sh`; do not duplicate bind
  helpers in scenario files. Bind creates the socket under a private `0700` owner dir then
  renames into place (avoids socket TOCTOU) and removes that dir; tool lookups use a fixed
  `/usr/bin:/bin` PATH so isolated driver PATHs still resolve `mktemp`/`mv`/`stat`/`python3`.
  Bind failure warns and returns nonzero (no `touch` file fallback). `_kcov_expect_direct_run_env` rejects exits 124/137 even when
  listed in `expected_csv`. `step_kcov_coverage` calls `_setup_kcov_temp_root` in the parent
  shell (never `$()`) so EXIT trap chaining and `_KCOV_*` teardown state persist. kcov driver
  diagnostic logs under `reports/distro-logs/` (e.g. `shared_helpers_*.log`) are kept after success;
  `shared_helpers.sh` tees those exercises live to stderr (not `/dev/null`). Driver
  `_link_iso_tools` in `kcov_driver_common.sh` links a default tool set or an optional caller list;
  `components_helpers.sh` must save outer `PATH` before `local PATH` shadows it.
  Direct (non-kcov) scenarios such as root+`runuser` `cam_not_writable` must still write
  stdout/stderr under `$kcov_root/logs/<label>.log` via `_kcov_expect_direct_run_env` and must
  fail fast on unexpected exits. Expected product errors (e.g. “not writable”) belong in that
  log file — never on the live pipeline console.
  Shell coverage gates in `gates_shell.sh` (`check_kcov_report_percentages`) key percentages by
  `KCOV_REPO_ROOT`-relative product paths (`bin/…`, `lib/…`, `install.sh`, `uninstall.sh`),
  not by basename alone. Merge/temp-root/`step_kcov_coverage`/`resolve_reports_root` live in
  `gates_kcov.sh`.

## Dependency & Mocking Policy

- **Prefer Real Dependencies**: Always use real packages and real system libraries over stubs or mocks.
  Install the actual dependency (in Docker images, pyproject.toml, or via apt) rather than creating a fake shim.
- **Never Mock Owned Code**: Do **not** mock, stub, or replace classes, functions, or modules owned by this
  repository (`bin/`, `lib/`, `scripts/`, installers). Tests must call the real owned implementation.
  Patch only external boundaries that cannot run in CI (e.g., `evdev.InputDevice`/`UInput`, physical devices,
  root-only kernel interfaces, live systemctl/loginctl when absent).
- **Mocks Only When Unavoidable**: Mocks and stubs are acceptable only for hardware-bound or privileged
  resources that cannot be present in a CI environment. Never mock a pure software library just to avoid
  installing it, and never invent a fake owned API to make a test pass.
- **No Stub Pollution**: Do not place stub `.py` files on `sys.path` to satisfy linters or type-checkers when the
  real package can be installed. Stubs hide real import errors and mask version mismatches.

## Test Suite Structure

- `tests/unit/`: Function-level unit tests matching production file structure.
  Tooling-focused unit modules live under `tests/unit/tools/` (shell complexity, dot test runner);
  `sitecustomize.py` unit tests live at `tests/unit/test_sitecustomize.py`.
  `tests/unit/scripts/` (file-size gate), and `tests/unit/e2e/` (e2e_utils helpers).
  Name unittest classes after the behavior under test; do **not** use `Coverage`,
  `Edge`, or `Extra` in test class or module names (prefer names like
  `TestAtKeyboardOsdCancel` or `TestDisplayModeScaleSelection`).
  Keep `_asus_manifest_wmi_src_relpaths` aligned with `_asus_manifest_bin_basenames`
  for every split hotkey/display module so DESTDIR deploy copies match uninstall.
  `step_python_coverage` must `exit 1` when `run_python_coverage_gate` fails
  (do not rely on bare `set -e` around the gate call alone).
- `tests/e2e/e2e_utils.py`: mock E2E subprocess runs tee live output to `reports/distro-logs/`
  (or any existing directory set via `E2E_LOG_DIR`),
  use `start_new_session` + process-group kill on timeout, and bound tee-thread joins after kill.
  After a normal exit, `_finalize_logged_success` timed-joins tee threads first; when either is
  still alive it kills the process group (even if the leader already exited) before the strict
  `join_tee_threads` call. `tests/shared/process_tee.kill_process_group` must not skip
  `killpg` solely because `proc.poll()` is set — pipe-holding descendants may outlive the leader.
  Command digest filenames use `hashlib.sha1(..., usedforsecurity=False)`.
  Shared `tests/shared/process_tee.join_tee_threads` fails closed (`RuntimeError`) when a tee
  thread is still alive after `POST_KILL_JOIN_SECS`.
- `tests/unit/shell/shell_test_utils.py`: shell unit tests **capture** stdout/stderr into
  per-command log files (override dir with `SHELL_UNIT_LOG_DIR`) and
  `CompletedProcess.stdout`/`stderr` for assertions — they do **not** discard output.
  By default they do **not** mirror to the live suite console (expected product
  `Error:`/`Warning:` lines look like suite failures); set `SHELL_UNIT_LIVE_TEE=1` to
  mirror. Default session logs use `mkdtemp(prefix="shell-unit-logs-")` under the
  system temp dir; once per process, prune other abandoned `shell-unit-logs-*`
  siblings older than one hour there while keeping the current session directory and
  any `SHELL_UNIT_LOG_DIR` override. Timeouts include the capture log path plus
  stdout/stderr in the AssertionError.
- `tests/e2e/mock/`: CI/local-gated process-level integration tests that run with mocks.
- `tests/e2e/real/`: Opt-in real-system integration tests for debugging and incident reproduction only.
- Run local CI-parity checks with `./scripts/build-and-test.sh` (`--full` =
  lint-in-docker ∥ Debian `.deb` smoke via `scripts/run_deb_package_smoke.sh` +
  Docker coverage/compat matrices — same gates as CI `lint` (cheap∥heavy) /
  `package-smoke`'s `deb` cell / `coverage` (kcov∥python) / `distro-tests-*` family jobs).
- Run real-system E2E explicitly with `sudo E2E_REAL_ALLOW_SYSTEM_CHANGES=1 ./scripts/run_real_e2e.sh`.
  `run_real_e2e.sh` splits traps: EXIT runs `cleanup_real_e2e "$?"` (preserve status);
  INT/TERM call cleanup with nonzero (130). Chown `.coverage.real-e2e` and
  `.coverage.real-e2e.*` after runs under sudo.
- Unit and mocked E2E runs use `tools/dot_test_runner.py` with **fail-fast enabled by
  default** (`--failfast`; opt out with `--no-failfast`). `build-and-test.sh` passes
  `--failfast` and exits immediately on the first failing suite instead of printing a
  success banner. Do not override `ClassDotResult.printErrors` (use stock
  `unittest.TextTestResult.printErrors`). `dot_test_runner.install_captured_logging`
  tees product `logging` into a capture file (under `DISTRO_LOG_DIR` /
  `SHELL_UNIT_LOG_DIR` / `UNIT_TEST_PRODUCT_LOG`, else temp) via `Logger.handle`
  so records remain available even when `assertLogs` disables propagate; a root
  NullHandler blocks `basicConfig` console spam. On suite failure the runner prints
  that path for debugging. Do **not** discard product stderr — capture it for
  assertions and post-mortem logs.
- Negative-path unit fixtures (CLI usage errors, intentional nested FAIL suites, shell
  complexity ✗ marks, expected hotkey grab/uinput failures) must capture stdout/stderr
  and logging (`assertLogs`) so they do not look like live suite failures in pipeline logs.
  Assert on the captured text; keep shell command logs and product logging files for
  debugging. Hotkey `_ImmediateThread.join` matches `Thread.join` (no-op; no re-raise); use
  `recorded_exception` for inline worker failures. Topology/deferred workers bind
  `_thread_factory` in `asus_hotkey_daemon_topology` / `asus_hotkey_daemon_window_swap`;
  unit helpers patch those execution-module bindings, not `threading.Thread` or the facade.
  After the hotkey split, patch/call private helpers on their owning modules
  (`_session`, `_topology_detect`, `_desktop_family`, `_window_swap`, `_window_swap_gnome`,
  `_window_move`, `_topology`); facade re-exports are import compatibility only.
  `window_swap_monitor_patches` patches `asus_hotkey_daemon_session._run_command`
  (named wrapper), not `subprocess.run`.

## Distro Matrix Governance

- Supported CI matrix lanes are defined across three files and must be updated together:
  - `docker/images/tests/*.Dockerfile`
  - `scripts/run_docker_matrix.sh`
  - `.github/workflows/ci.yml`
- Any distro-lane change must also update relevant docs and tests in the same change set:
  - `README.md`, `docs/INSTRUCTIONS.md`, `docs/architecture/README.md`, release notes under `docs/releases/`
  - `tests/unit/shell/test_docker_matrix.py` and any related installer detection tests
- **Always-on nine distro lanes** (every PR `distro-tests-{debian,rhel,suse-arch}`,
  local `--full` / default
  `run_docker_matrix.sh`, compat): `ubuntu:26.04`, `debian:trixie`, `fedora:44`,
  `rocky:10`, `opensuse/tumbleweed`, `archlinux:latest`, `opensuse/leap:16.0`,
  `almalinux:10` (not `:9`), `manjarolinux/base:latest`. Family lists live in
  `DISTRO_FAMILY_*` / `--distro-family debian|rhel|suse-arch`. No shrink feature flag;
  local `--distro <one>` is debug-only. Empty `ASUS_CI_DE_FAMILY` = stub/CLI images.
  CI `distro-tests-*` job `timeout-minutes` must stay **≥45** (Rocky/Alma cold
  poetry+PyGObject image builds exceeded the old 20m cap and GH reported the job
  as cancelled).
  `run_docker_matrix.sh` allowlists `DE_FAMILY` / `ASUS_CI_DE_FAMILY` to
  `gnome|kde|xfce|lxqt|cinnamon|mate` (or empty) before any heredoc / `bash -lc` that
  embeds the value. `_print_target_distros` takes basename first, then strips digest
  (`@…`) and tag (`:…`), so `registry:5000/team/ubuntu:26.04` prints `ubuntu`.
- **Always-on full-DE family jobs** (`ci.yml` `distro-full-de-{debian,rhel,suse-arch}`):
  same push/PR pipeline; matrices are family-split (same nine distros ×
  `gnome|kde|xfce|lxqt|cinnamon|mate` with Rocky/Alma cinnamon/mate/lxqt excludes —
  **48 cells**, `max-parallel: 20` per family job — OSS org limit for hosted runners).
  **F1 runtime DE:**
  matrix builds the same stub/CLI images as `distro-tests-*` (empty bake-time
  `ASUS_CI_DE_FAMILY`); `install-de-family.sh` runs in-container via `sudo -n`
  before smoke when `ASUS_CI_FULL_DE=1` (up to 3 retries on CDN flakes; unsupported
  family fails closed without retry). Arch/Manjaro stub `pacman -Syu`/`-S` and
  Full-DE `_install_pacman` must use `docker/images/tests/scripts/pacman-retry.sh`
  (default 3 attempts, wipe sync DBs as root, `pacman -Syy` between failures) so
  rolling-mirror 404s for a superseded package tarball do not fail the image build.
  Arch images COPY `archlinux-mirrorlist` (rackspace/kernel/osuosl — not
  geo/fastly.mirror.pkgbuild.com) before `-Syu`. Dockerfiles may keep
  empty-ARG no-op bake paths for local experiments; CI/matrix never pass a
  non-empty build-arg.
  Rocky/Alma/RHEL 10 XFCE builds pinned `xfconf` 4.18.1 from
  source at runtime (EPEL has `libxfce4util` but not `xfconf`; use image
  `curl`/`curl-minimal` already on PATH — do not `dnf install curl`, which conflicts
  with `curl-minimal`).
  `install-de-family.sh` xfconf fetch uses curl `--connect-timeout` / `--max-time`
  with retries; dnf build-dep cleanup must fail closed (no trailing `|| true`).
  Rocky 10 / Alma / Fedora KDE install `kf6-kconfig` (`kwriteconfig6`); legacy
  `rhel` Full-DE still falls back to `kf5-kconfig`.
  Sets `ASUS_CI_FULL_DE=1` + `--de-family`. Prefer real
  CLIs/schemas in smoke; stubs remain for deterministic wiring under the smoke bus.
  Curated packages via `docker/images/tests/scripts/install-de-family.sh`. **Not
  nightly.** Mocking integrity: never mock owned code; prefer real packages/CLIs.
- CI Docker builds use BuildKit `DOCKER_BUILDX_CACHE_BACKEND=gha` with a unique
  `DOCKER_BUILDX_CACHE_SCOPE` per stub image (lint; `tests-debian-trixie` for
  coverage; each of nine distros — **not** per DE family). Local builds keep default `local` under
  `.cache/docker-buildx`. Do not restore `.cache/docker-buildx` via `actions/cache`
  when using `gha`. Coverage is a GHA matrix job `coverage` with four
  `include` cells on **debian:trixie** (display `matrix.label`:
  `kcov bin-sound+ui`, `kcov install-lib`, `python unit tests`,
  `python e2e tests`; env still `ASUS_COVERAGE_MODE` /
  `ASUS_COVERAGE_SHARD` / `--kcov-only` / `--python-coverage-only`);
  shards export partial data under `reports/coverage-shards/`, then
  `coverage-merge` runs **on the host** (no Docker image): install
  `kcov` + `coverage.py`, normalize GHA `coverage-shards-download/`
  artifact dirs into `kcov-N`/`python-N`, rewrite Docker `/workspace`
  prefixes in kcov metadata, then one `coverage combine --keep` of
  all `coverage.dat` shards (never raw-`cp` the first shard — that skips
  `[tool.coverage.paths]` remapping of Docker `/workspace` → checkout),
  then `./scripts/build-and-test.sh --coverage-merge-only`
  enforces ≥90%.   Successful shard export writes a non-hidden `shard_ok`
  stamp under each `kcov-N`/`python-N` dir; merge **fails closed** without
  both kcov and both python stamps (do not merge stale Aug-dated runs after
  a failed worker that still printed Passed). Local `--full` wipes
  `reports/coverage-shards/` before starting coverage workers and, under
  `sudo`, **chowns** that directory to `$SUDO_USER` so container `--user`
  can create shard dirs (root-owned 755 is not other-writable). Export
  fails closed if mkdir or stamp write fails. After wave-2 workers succeed,
  local `require_exported_coverage_shards` must pass before the green banner
  (same stamp gate as host merge). CI coverage cells verify `shard_ok` (+ runs
  or `coverage.dat`) before upload and upload shard data only on `success()`
  so `coverage-merge` never sees incomplete artifacts. Serial
  coverage-gate logs are `coverage-gate-${MODE}-${SHARD}.log` so parallel
  cells do not truncate each other. `_run_one_serial_target` (in
  `scripts/docker_matrix_exec.sh`) captures `run_target | tee` via one
  `PIPESTATUS[@]` snapshot (reading `[0]` then `[1]` under `set -u` unbound-
  errors) and fails closed if the log contains
  `kcov scenario suite failed` while the process exit was 0. Kcov scenarios
  retry **once** on exit 137 (OOM/SIGKILL under parallel load); exit 124
  (true timeout) stays a hard failure. Under `sudo --full`, python coverage
  runs via `runuser -u "$SUDO_USER" -- python3 -m coverage`. Upload python
  shards with `include-hidden-files: true` (or non-hidden
  `coverage.dat`). Local `--full` mirrors host merge after the four
  Docker shard containers. Distro jobs need `coverage-merge` (and
  `lint`). Lint is a GHA matrix job `lint` with display labels
  `format+syntax` / `pylint+shellcheck` (env `ASUS_LINT_WAVE=cheap|heavy`);
  local `--full` runs both lint-in-docker wave containers in parallel
  with deb smoke.
  Parallel local waves serialize the shared lint image build with
  `mkdir` locks under `${DOCKER_BUILD_CACHE_DIR}/.locks/lint-image` (and set
  `DOCKER_BUILDX_SKIP_PRUNE=1`) so cheap∥heavy do not race the local
  `.cache/docker-buildx/lint-python-3.13-slim` export.
  `step_post_lint_gates_parallel` likewise wraps release ∥ coverage ∥ three
  compat families with `_with_buildx_skip_prune` (then one post-gate prune) so
  a finishing coverage/debian lane cannot `rm -rf` another family's buildx
  cache mid-export (`index.json.lock: no such file`).
  `docker_build_with_buildx_or_build` in `scripts/docker-utils.sh` likewise
  acquires `${cache_base_dir}/.locks/<cache-key>` via atomic `mkdir` for local
  backend exports so parallel coverage-gate shards (shared `tests-debian_trixie`
  scope) cannot corrupt buildx ingest blobs (repo-local locks avoid predictable
  `/tmp` symlink traps when `--full` runs under sudo). Lock owners write
  `owner.pid` **before** registering EXIT cleanup; missing-pid reap grace defaults
  to **30s** (`DOCKER_BUILDX_LOCK_GRACE_SECS`) so waiters cannot rmdir a live lock
  under parallel load. `_docker_prepare_lock_root`
  probes writability and **fails closed** when a prior `sudo` left `.locks`
  root-owned (instead of spinning until the lock timeout). Local `--full` wave 2 uses
  `_wait_bg_jobs_fail_fast` (and `run_docker_matrix.sh` parallel compat uses
  `wait -n -p` + `_kill_pgid_list` delegating to `_kill_pgid_list` in
  `docker-utils.sh`) so the first failing release/coverage/compat lane terminates
  sibling **process groups** (`setsid` workers + `kill -TERM -- "-$pid"`) instead
  of running every matrix to completion.
  CI workflow concurrency uses `group: ${{ github.workflow }}` with
  `cancel-in-progress: true` so a new push/PR sync **cancels** any prior CI run
  (does not queue behind it). PPA release keeps `cancel-in-progress: false`.
  **Host orchestrates only:** the machine that runs `--full` / CI job steps must
  never execute `run-lints.sh`, product unit/e2e, or coverage *collection* on the
  host — those run only inside Docker (`lint-in-docker.sh`, coverage shard
  containers / `--compat-only` matrix). Exception: `coverage-merge` /
  `--coverage-merge-only` runs on the host (merge already-exported kcov/python
  shard artifacts + ≥90% gates; no product test execution). Deb smoke may
  build/install on the host but always sets `DEB_BUILD_OPTIONS=nocheck` so
  `dh_auto_test` does not run product tests.
- Pin CI base images with `FROM tag@sha256:…` (keep the floating tag for Dependabot)
  including `fedora-44.Dockerfile`, `ubuntu-26.04.Dockerfile`, Leap/Alma/Manjaro.
  Fedora / Rocky / Alma test image `dnf install` lines use versioned name globs
  (`pkg-*`) so hadolint DL3041 stays clean; on Fedora 44 pin
  `python3-3.14*` / `python3-devel-3.14*` (default interpreter is 3.14). Install
  `systemd-[0-9]*` (not bare `systemd-*`) so `systemd-tests` /
  `systemd-standalone-*` are not pulled into conflicting requests. Prefer exact
  `zlib-devel` on Alma/Rocky when `-*` globs miss on EL mirrors.
  Use `alsa-utils-[0-9]*` (NEVRA), not `alsa-utils-*`: the latter matches only
  subpackages like `alsa-utils-alsabat` and skips the main `alsa-utils` RPM
  (Fedora 44 smoke then fails `rpm -q alsa-utils`). Install
  `gettext-*` (or Debian/Arch `gettext`, openSUSE `gettext-tools`) so `msgfmt` is
  present for WMI locale catalog compile in unit/smoke; DESTDIR unit/e2e helpers
  may stub `msgfmt` for speed. openSUSE
  Tumbleweed/Leap use quoted `'pkg>=0'` constraints for hadolint DL3037.
  openSUSE Tumbleweed/Leap test images install `kf6-kconfig` (provides `kwriteconfig6`)
  alongside `xfconf`. AlmaLinux 10 mirrors Rocky skip policy for unpackaged
  `ydotool`/`alsa-tools`/`xdotool`/`python3-evdev` (poetry + pip PyGObject). Manjaro is
  Arch-family (`ID=manjaro`); pacman mirrors differ from stock `archlinux:latest`.
  Pinned `FROM …@sha256` still `-Syu`s against rolling repos — Arch/Manjaro test
  images must not use a single-shot `RUN pacman -Syu && pacman -S`; route both
  through `pacman-retry.sh`. Arch also replaces `/etc/pacman.d/mirrorlist` with
  `archlinux-mirrorlist` so geo/fastly CDN split-brain 404s cannot loop on a stale
  `core.db`.
  Rocky/Alma 10 kcov builds run `el10-kcov-libcurl.sh`: align `libcurl`/`curl`
  with `--allowerasing --nobest`, then install `libcurl-devel-${VERSION}-${RELEASE}`
  matching the installed libcurl NEVRA (AppStream can advertise `el10_2.4` devel
  when BaseOS has no that `libcurl`). Fall back to `--nobest libcurl-devel` only
  when the exact NEVRA is absent. Do not `--skip-broken`.
  `install-poetry-deps.sh` removes `${HOME}/.cache/pypoetry` after
  `poetry install` only when `HOME` is set (`if [ -n "${HOME:-}" ]`) so `set -u`
  stays safe in minimal Docker `RUN` environments.
- `run_docker_matrix.sh --serial` wraps each `run_target | tee` pipeline in `if` so `set -e`
  / `pipefail` records lane failure without aborting remaining distros.
  `--coverage-gate` resolves image tag/cache identity via `_resolve_distro_image` to
  `debian:trixie` (Dockerfile `debian-trixie`, tag/cache `debian-trixie` /
  `debian__trixie`), not a literal `coverage-gate` slug. Distro-tests / full-DE
  image cache scopes use
  normalized distro slug only (F1: no `-de-*` / `__de_*` in image identity). Artifact
  log names may still include `de_family`. Pin GitHub Actions by full commit SHA with a
  `# vX.Y.Z` comment; keep every
  `uses:` action on a release that declares `runs.using: node24` (currently
  `actions/upload-artifact@043fb46d…` **v7.0.1**, not v4.6.x Node 20). Same pins
  in `.github/workflows/ci.yml` and `ppa-release.yml`; bump both together.
  `tests/unit/shell/test_pipeline_ci_parity.py` guards the upload-artifact SHA.
  `_docker_prune_one_oldest_cache` treats successful dir removal as progress even when
  `du` rounds unchanged; the prune loop is bounded by prunable candidate count.
  `_docker_prune_buildx_local_cache` / `docker_build_with_buildx_or_build` reject an empty
  `cache_base_dir` (fail closed). Legacy (non-buildx) `docker build` also calls
  `_docker_prune_buildx_local_cache` before build. Both paths pass
  `--build-arg TARGETARCH=…` from `_docker_host_targetarch` (`x86_64`/`amd64`→`amd64`,
  `aarch64`/`arm64`→`arm64`; other hosts fail closed). Oldest-cache `find -printf` uses a
  tab between mtime and path (`%T@\t%p`) so paths with spaces parse correctly.
  `lint-in-docker.sh` resolves `HOST_UID`/`HOST_GID` via `_docker_host_uid_gid`.
  Background image builds run under `setsid` so `_lint_stop_active_build` can
  `kill -TERM -- "-$pid"` the whole docker-build+tee process group on interrupt.
  `--distro` requires a non-option image token (missing or `--…` next arg is an error and
  does not consume a following flag as the image name). CLI/mode parsing lives in
  `scripts/docker_matrix_args.sh` (sourced by `run_docker_matrix.sh` after `docker-utils.sh`).
  Serial/parallel target runners live in `scripts/docker_matrix_exec.sh`
  (sourced after `run_target` is defined).
- SteamOS maps to the Arch package family via exact `ID=steamos` and
  `ID_LIKE=arch` detection tests; there is no dedicated SteamOS CI image.
  Ubuntu flavours (Xubuntu/Kubuntu/Lubuntu) share the Debian/apt path.
- Every `--compat-only` matrix lane must run
  `scripts/run_distro_install_smoke.sh` via `build-and-test.sh --compat-only`:
  real DESTDIR `install.sh`/`uninstall.sh`, installer package availability probes
  (`ydotool`/`xdotool`/evdev/`python3-gi`|`python3-gobject`|`python-gobject`/…),
  product shell `bash -n`, Python imports, multi-DE session-family checks, and
  DESKTOP configure cycles for gnome/kde/xfce/lxqt/cinnamon/mate (stubbed session bus + CLI
  tools; asserts Window Swap extension files, `enabled-extensions` mark, KDE
  `.desktop` helpers, XFCE xfconf state, LXQt `globalkeyshortcuts.conf` Exec
  lines, Cinnamon/MATE gsettings customs). After uninstall, stubs must show original config
  values restored (GNOME keybindings + enabled list without the window-swap UUID;
  KDE kscreen shortcuts; XFCE xfconf bindings; LXQt conf sections; Cinnamon/MATE
  customs). Failures here
  are real compatibility bugs.
  Live desktop proof honesty (do **not** oversell Docker):
  1. **Default always-9 stub/CLI (+ curated full-DE packages in `distro-full-de`):**
     install wiring / real CLI-schema smoke — **not** live panels.
  2. **Always-on limited nested proofs** (`ci.yml` nested-session / MoveFocused /
     sticky-osd jobs): CI **apt-installs** the full Shell/Mutter/Xvfb (or
     ydotool/Xvfb) dep set; scripts **hard-fail** if those commands are missing.
     Soft-skip only after packages are present when Shell/uinput still cannot
     start (env/DRM/kernel) — still **not** “live panel.” Scripts:
     `scripts/distro_nested_session_smoke.sh`,
     `scripts/distro_movefocused_nested_e2e.sh`,
     `scripts/distro_sticky_osd_uinput_e2e.sh`.
  3. **Out of scope / experimental only:** true DRM/panel/DM proof (privileged
     container or self-hosted KVM) — never standard Actions Docker; never claim from
     default CI. **GDM/SDDM** full greeter login in standard GH Actions Docker is
     locked **NO** (do not fake).
  MoveFocused / sticky OSD proof tiers:
  4. Unit/mocked MoveFocused + OSD markers (already covered) — not nested E2E.
  5. Nested MoveFocused limited E2E (Tier A GetFocusedMonitor; Tier B soft) —
     always-on job installs full Shell/mutter stack; asserts `org.gnome.Shell`
     (process or D-Bus) before Tier A; soft-skip only on env start failure
     (never missing packages).
  6. Sticky-marker / real ydotool path — always-on job installs ydotool+Xvfb
     (hard-fail if missing) and enables `/dev/uinput`; soft-skip only when
     uinput/ydotoold/injection fails after packages are present.
  7. True laptop Mutter OSD dialog / Fn/ScreenPad / ProtectHome unit path — **NO**
     on standard Actions Docker.
  Helpers live in `scripts/distro_install_smoke_desktop.sh` and
  `scripts/distro_install_smoke_live_pkg.sh` (sourced by the smoke entrypoint).
  FULL_DE probes: `scripts/distro_install_smoke_full_de.sh`.
  Debian `lxqt-globalkeys` may ship defaults as a directory
  (`/etc/xdg/lxqt/globalkeyshortcuts.conf/globalkeyshortcuts.conf`); the probe
  must accept that layout, not only a bare file at `/etc/xdg/lxqt/…`.
  XFCE `xfconf-query` stubs map Super+F12 via the exact `*'<Super>F12'` case pattern
  (quoted so dash `/bin/sh` does not treat `<…>` as redirection; not a bare `*F12`
  suffix match). Keep `*XF86Display` and quoted `*'<Super><Shift>s'` (plus legacy
  `*SuperShiftS`) key mappings. Unquoted `*<Super>F12)` under `#!/bin/sh` breaks
  the stub on Debian/Ubuntu (probe fails → “backup missing for orig_xfce_xf86display”).
  Desktop workspace prepare writes `_SMOKE_DESKTOP_*` globals and a status (no process
  substitution protocol); callers check status then read those globals.
  `_smoke_run_logged_step` must save/restore the caller’s errexit via
  `shopt -po errexit` around `set +e` + `tee` so pipeline status checks do not
  permanently disable `set -e` for later smoke steps.
  The coverage-gate stage (`--tests-only`) does **not** run this smoke; it only
  gates unit/kcov/e2e/Python coverage.
  Smoke helpers that register temp cleanup must use `trap … EXIT` (capture prior
  EXIT with `trap -p`, restore after success — same pattern as
  `_run_live_pkg_install_uninstall_cycle`) when `_smoke_fail` / early exits call
  `exit`, so temp dirs are removed on abort. Desktop family cycles run in a
  subshell so `set +e`/`-e` and cleanup traps stay local. Expand the temp
  path at registration so later returns cannot trip `set -u` on a stale `$tmp`.
  Parallel `--compat-only` lanes export `COVERAGE_FILE=.coverage.<slug>` and write
  `.coverage-percent.<slug>` from `REPORT_DISTRO_SLUG` so bind-mounted coverage artifacts do not race.
  Local `--full` badge updates resolve `anybadge` from PATH, `.venv/bin/anybadge`,
  the invoker's `~/.local/bin` under sudo, or poetry; create `.venv` with
  `anybadge==1.16.0` when poetry is unavailable on the host. Badge percents must match
  `^[0-9]+([.][0-9]+)?$` (decimals allowed). Badge write failures
  warn and continue (`return 0`); do not fail the pipeline solely on badge I/O.
  Pure Debian (`ID=debian`) does not package `ydotool`; the installer skips it
  there and Display Toggle falls back to `xdotool`/Mutter/settings. Ubuntu and
  other debian-family IDs still install `ydotool` when packaged. Smoke requires
  `ydotool` only when `apt-cache`/`dpkg` knows the package. openSUSE and Arch smoke treat
  `ydotool` and `alsa-tools` like RHEL-family: require them only when the package manager knows the package.
  SUSE `install_system_deps` likewise requests `ydotool` only via
  `_should_request_suse_optional_pkg` (`rpm -q` or `zypper search -x`) so Leap
  without a ydotool provider does not fail closed. When neither `xdotool` nor
  `ydotool` is packaged (Alma/Rocky peers), smoke skips the live package mutation
  cycle instead of failing on an empty sentinel list.
  openSUSE Tumbleweed/Leap package versioned `python3XY-evdev`,
  `python3XY-gobject`, and `python3XY-curses` (shared
  `_resolve_suse_versioned_python_pkg` via `_resolve_suse_evdev_pkg` /
  `_resolve_suse_gobject_pkg` / `_resolve_suse_curses_pkg`, digits from
  `/usr/bin/python3` first — not PATH `python3`) plus `hda-verb` (not unversioned
  `python3-evdev` / `python3-gobject` / `alsa-tools` by default); keep installer,
  smoke (`_required_pkgs_suse`), and the opensuse Dockerfiles aligned with those
  names. Prefer an already-installed unversioned `python3-evdev` /
  `python3-gobject` / `python3-curses` when the versioned package is absent.
  Rocky/RHEL do not package `ydotool` or
  `alsa-tools`/`hda-verb` (only `alsa-tools-firmware`); skip those RPMs there
  (Fedora still installs both). SOUND still installs fully automatically on
  Rocky/RHEL via bundled `bin/asus_hda_verb.py` (numeric hda-verb compatible
  helper) when system `hda-verb` is absent. Fallback to `asus_hda_verb.py` requires
  `python3` on `PATH` (same gate as `_resolve_hda_verb_bin`). Bundled-path search is
  shared via `_locate_bundled_python_hda_helper` (used by `_find_bundled_python_hda_helper`
  and `_resolve_hda_verb_bin`). When the sound helper
  runs as root (`EUID=0`), ignore env `BIN_ROOT` and only resolve `asus_hda_verb.py`
  beside the script or under `/usr/local/bin` (non-root may still use `BIN_ROOT`).
  `pack_verb`
  follows alsa-tools numeric
  `hda-verb` rules: 16-bit params when `verb <= 0xF` (encoded with `verb << 16`),
  when the verb’s low byte is zero, or for Realtek vendor verbs `0x400`–`0x4FF`
  (encoded with `verb << 8`); otherwise parameters are 8-bit with
  `(verb << 8) | (param & 0xFF)`. Word encoding stays `(nid << 24) | …`. Successful
  `asus_hda_verb.py` CLI writes print `value = 0x…` on **stdout** (errors on stderr).
  `bin/asus-sound-fix.sh` passes `SOUND_HDA_NID` as the fifth argument to
  `_run_one_hda_verb` / `_format_hda_verb_cmd` (default `0x20`). Validate
  `SOUND_HDA_NID` once at startup (decimal digits or `0x`-prefixed hex with **≤2**
  hex digits before `$((nid))`, final numeric value in `0–0xff`); reject invalid
  values fail closed with a clear stderr error. `asus_hda_verb.py` converts ioctl request numbers above
  `2**31-1` to signed 32-bit before `fcntl.ioctl`, and CLI `main` catches
  `struct.error` with the same stderr path as other failures.
  `bin/asus-sound-fix.sh`
  polls for
  `/dev/snd/hwC*D*` up to **75** attempts with **0.2s** sleeps between tries
  (`SOUND_HWDEV_POLL_ATTEMPTS` override must stay digits-only). The oneshot unit
  `asus-sound-fix.service` has no `ExecStartPre` hwdev poll—`ExecStart` relies on
  `poll_sound_hwdev` inside `bin/asus-sound-fix.sh` and does not set
  `StartLimitIntervalSec`/`StartLimitBurst`. The oneshot unit uses
  `ProtectSystem=strict`, `ProtectHome=read-only`,
  `StateDirectory=asus-zenbook-linux-tools`, and `ReadWritePaths=-/dev/snd`
  (leading `-` so missing paths do not block startup).
  `bin/asus-sound-fix.sh` captures verb stderr in separate temp files for system
  `hda-verb` vs the Python helper under `/var/lib/asus-zenbook-linux-tools`
  when writable (`_sound_verb_err_dir`); otherwise fall back to `${TMPDIR:-/tmp}`
  (not a hard-coded `/dev/shm`). Split `_run_one_hda_verb` into system/python
  helpers (`_run_system_hda_verb` / `_resolve_python_hda_helper` /
  `_run_python_hda_verb`) so each block stays CCN ≤5.
  The suspend/resume hook
  under `$HOOK_DIR` must invoke `/usr/local/bin/asus-sound-fix.sh` in its body (not
  `$BIN_DIR`), so resume uses the live install path outside DESTDIR staging.
  `rollback_sound_component` must also `rm -f "$HOOK_DIR/asus-sound-fix"` (not
  only disable the oneshot unit). Sound activation must fail closed on
  `systemctl daemon-reload` (do not soft-swallow): a wedged systemctl would
  otherwise pay reload timeout, then enable, then rollback disable+reload.
  When reload fails before enable, only remove the suspend hook (unit was never
  enabled).
  Dockerfile `rocky-10` uses `FROM rockylinux/rockylinux:10@sha256:…` (pinned digest)
  and must not hard-require `ydotool`, `alsa-tools`, or `xdotool`. EL10 `dnf`
  install lines must use `git-[0-9]*` / `gcc-[0-9]*` / `gcc-c++-[0-9]*` /
  `systemd-[0-9]*` (not bare `git-*` / `gcc-*` / `gcc-c++-*` / `systemd-*`) so
  cross-toolchains and git addons are not pulled. Do **not** rely
  on platform `python3-gobject` for CI `python3.13`: poetry installs
  `evdev` into the 3.13 venv, then `pip install 'PyGObject>=3.42,<3.52'` (pin below
  3.52 — newer PyGObject needs `girepository-2.0`, absent on EL9/EL10) with
  `gobject-introspection`/`cairo-gobject` (+ `-devel` during build); assert
  `import evdev; import gi` on the venv python before stripping build-only RPMs
  (`cmake`/`gcc`/`gcc-c++`/`make`/`binutils-devel`/…/`gobject-introspection-devel`/
  `cairo-gobject-devel`; keep `python3.13-devel` and `dbus-devel`), then smoke
  `kcov --version` fail-closed before/after stripping build deps and before
  `dnf clean all` (`kcov --help` exits 1 even when kcov works). AlmaLinux 10 mirrors that
  PyGObject pin; prefer exact `zlib-devel` (not `-*` globs that miss on current
  EL10 mirrors). kcov on Rocky/Alma needs `libcurl-devel` at the installed
  libcurl NEVRA (`el10-kcov-libcurl.sh`; `--nobest` fallback — not latest
  AppStream devel). Fedora test images use `git-[0-9]*` (not `git-*`) —
  so hadolint DL3041 stays happy without pulling `git-extras` /
  `git-pull-request`, which conflict on `/usr/bin/git-pull-request`.
  `debian-trixie` pins `FROM debian:trixie@sha256:…` (tag kept for Dependabot).
  Package install/remove must use
  `bash -c` (not `bash -lc`) so test PATH stubs are not wiped by login profiles.
  CI images preinstall those deps for unit/e2e imports; that is not enough to
  prove install works. Inside the container the smoke **purges sentinel packages**
  (`xdotool`/`ydotool`), runs `install.sh` with `SKIP_PKG_INSTALL=0` (up to 3
  attempts via `_live_pkg_install_with_retry` for CDN/zypper flakes), asserts they
  were recorded under `installed-packages`, then `uninstall.sh` with
  `SKIP_PKG_REMOVE=0` and asserts removal. Test images create an `asusci` account
  matching build-args `ASUS_CI_UID`/`ASUS_CI_GID` from `_docker_host_uid_gid` in
  `scripts/docker-utils.sh` (prefer `ASUS_CI_*` overrides, then `SUDO_UID`/`SUDO_GID`
  when the matrix runs under `sudo`, else `id -u`/`id -g`). Refuse UID/GID that
  fail `^[1-9][0-9]*$` (empty, non-numeric, zero, or zero-padded like `00`) so
  builds never usermod root; `create-asusci-user.sh` fails closed on those values.
  Reuse an existing group by name; `groupadd` only when both name and GID are free.
  When reusing the group by name, resolve that group's GID (`getent` field 3) into
  `PRIMARY_GID` and pass it to `useradd`/`usermod`/`chown -g` (do not always use
  `ASUS_CI_GID`). Container `--user` uses the same helper via `current_user_spec`
  (capture status, fail closed). If that UID already belongs to another username,
  `create-asusci-user.sh` renames/rehomes it so `ASUS_CI_USER` always owns the
  requested UID; after `usermod -d` (including the bare `-d` fallback when `-m`
  fails), `mkdir -p` + `chown` the home directory. Then grants passwordless sudo
  only to that UID via
  `/etc/sudoers.d/asus-ci` (`#UID ALL=(ALL) NOPASSWD:ALL`; hadolint rejects
  embedded newlines in `RUN`) and runs `visudo -c` when available. Host/local
  smoke skips live package mutation and only runs the DESTDIR file cycle.
  Live sentinel remove/reinstall stdout/stderr is appended under
  `$(resolve_reports_root)/distro-logs/distro-compat-pkg-mutation${REPORT_DISTRO_SLUG:+-<slug>}.log`;
  matrix
  `--compat-only` treats `/.dockerenv` or `/run/.containerenv` as in-container for live package
  mutation. Failed post-smoke sentinel restore
  fails the smoke after temp cleanup (including error paths).
- Mocked/CI E2E tests must enforce fast per-test timeouts (**20–30 seconds** inclusive).
  Values below 20 or above 30 are rejected in mock mode. The 300s real-system ceiling requires
  both `allow_real=True` and `E2E_REAL_ALLOW_SYSTEM_CHANGES=1`. Any timeout is a test failure.

## Command Execution & Live Reporting

- Always run lint/test/pipeline commands so output is visible live in the CLI.
- Always persist command output to files under `reports/distro-logs/` so users can monitor
  progress and review results. Parallel matrix lanes set `REPORT_DISTRO_SLUG`;
  `scripts/build-and-test.sh` `_ensure_distro_logs_dir` exports slug-scoped `DISTRO_LOG_DIR`
  from a fixed `$REPO_ROOT/reports/distro-logs` base (never append `$slug` onto an
  already slug-scoped `DISTRO_LOG_DIR`) and all pipeline tees use that directory.
- Prefer `tee`-based execution that streams and records simultaneously. Example pattern:

  ```bash
  set -euo pipefail && mkdir -p reports/distro-logs && \
    sudo timeout 10800 ./scripts/build-and-test.sh --full \
    2>&1 | tee reports/distro-logs/full-pipeline.log
  ```

- Distro lane runs must write per-lane logs under `reports/distro-logs/` with stable, descriptive filenames.

## Always Update Agent Docs

- **Mandatory on every change**: For bug fixes, small features, and large features alike, update
  agent markdown in the same change set. Do not ship code-only diffs when agent guidance is stale.
  The same rule applies to `install.sh.sha256`: any edit to `install.sh` must regenerate that
  checksum in the same change set (`sha256sum install.sh > install.sh.sha256`).
- **What to update**:
  - Root `AGENTS.md` when project rules, workflows, constraints, or component behavior change
  - Relevant skills under `.agents/skills/*/SKILL.md` when install, lint, test, coverage, systemd,
    PR review comment resolution (`resolve-pr-comments`), CodeRabbit CLI review
    or plugin Findings fix (`review-with-coderabbit`; must end with a summary
    report: fixed how / skipped why + counts), or other agent workflows
    need new steps or corrected guidance
- **What to capture**: New invariants, failure modes, sysfs/D-Bus/systemd quirks, preferred
  commands, and “do / don’t” lessons learned from the fix or feature—not a changelog dump.
- **Same PR / same commit set**: Treat outdated agent docs as incomplete work, same as missing
  tests, unlinted new files, or stale README/architecture notes.

## Hardware Helper Invariants

- **Installed lib bootstrap**: Product `bin/*.sh` helpers resolve `lib/asus-bootstrap.sh` from
  `../lib` (checkout) or `${ASUS_INSTALLED_LIB_DIR:-/usr/local/lib/asus-zenbook-linux-tools}`.
  Set `ASUS_FORCE_INSTALLED_LIB=1` to skip the checkout `../lib` branch (kcov installed-lib
  scenarios). Point `ASUS_INSTALLED_LIB_DIR` at a temp empty dir for the missing-lib path.
  Never bind-mount or write under shared `/usr/local/lib` (Docker matrix runs as non-root).
  Install deploys `asus-session.sh`, `asus-common.sh`, `asus-notif-icons.sh`,
  `asus-bootstrap.sh`, and `asus-display-mutter.sh` into `$LIB_DIR`. `asus-common.sh`
  is source-only (`BASH_SOURCE` guard exits with usage when executed as a script)
  and sources session + notif-icon peers from `_ASUS_COMMON_DIR`
  (`ASUS_COMMON_DIR` env override, else the sourced file’s directory) so kcov
  missing-peer scenarios can point at an empty/partial temp tree without copying
  the instrumented product file. `asus-notif-icons.sh` requires
  `asus-common.sh` first; CSS color extraction matches standalone `color:` (not
  `*-color:`) with shell helpers so kcov can attribute the parsing paths (do not
  embed an awk body that remains permanently uncovered). Theme glyph probes use `ASUS_ICON_THEME_ROOT` (default
  `/usr/share/icons`) for Adwaita/Yaru/hicolor paths. Display-mode sources the mutter
  helper after common. Kcov coverage
  gates must prefer product `bin/`/`lib/` paths over `/tmp` or
  `/usr/local` DESTDIR copies, and must read `merged/kcov-merged/coverage.json`
  (not an arbitrary per-run `coverage.json`).
- **Install/uninstall package deps**: After successful component selection, `install.sh` runs
  `install_system_deps` before deploying files (skipped when `SKIP_PKG_INSTALL=1` or when the
  user chose no components). Progress uses dynamic `[n/m]` totals from
  `_install_plan_progress_steps` / `_install_print_next_step` in `lib/install-shared.sh`:
  `Choose components` is unnumbered; post-selection work is deps (when not skipped) + scripts +
  optional DESKTOP configure. `_install_print_next_step` defaults unset
  `INSTALL_STEP_CURRENT`/`INSTALL_STEP_TOTAL` so `set -u` kcov DE drivers that call
  `configure_*` without `install.sh` planning do not abort. GNOME/KDE/Cinnamon/LXQt/MATE/XFCE
  configure steps use `_asus_gettextf` (Cinnamon/LXQt/MATE/XFCE print via a one-line helper
  so nested quotes do not inflate CCN). Empty selection is a successful no-op (no deps, no runtime deploy,
  no components; message `No components were selected. Nothing was installed.`). TUI Ok with
  nothing checked, `NONINTERACTIVE_CHOICE=` / `none`, or text `,` apply empty; Esc/Cancel still
  aborts; bare Enter in text mode still defaults to all recommended. Kcov `install_none` runs
  `install.sh` with `NONINTERACTIVE_CHOICE=none` so `_print_empty_install_completion` is covered.
  Helper load order sources
  `lib/install-shared.sh` before `lib/install-os-detection.sh` and desktop helpers.
  `check_root` in `lib/install-shared.sh` honors `SKIP_ROOT_CHECK` /
  `EFFECTIVE_UID_OVERRIDE` only when `ASUS_TEST_MODE=1`; otherwise it uses real `EUID`
  (tests, kcov, smoke, and mock e2e must set `ASUS_TEST_MODE=1` whenever those overrides
  are used). `_maybe_bootstrap_and_main` always runs `_bootstrap_installer_after_reexec` so
  `source install.sh` (including `ASUS_INSTALL_SOURCE_ONLY=1`) loads helpers before
  skipping `main`; unit/kcov rely on that. Piped/stdin installs require a validated
  `INSTALL_SOURCE_DIR` (`_export_install_source_dir_if_valid`);
  empty `BASH_SOURCE[0]` without that checkout fails closed. `_resolve_install_script_dir`
  fails closed when `cd`/`pwd` cannot resolve the installer directory.
  `_resolve_startup_library` trusts `INSTALL_SOURCE_DIR` only after the same
  `_install_source_dir_is_valid` check used by `_export_install_source_dir_if_valid`
  (requires `bin/` + `systemd/` under that path); otherwise it falls back to
  `SCRIPT_DIR`. `_reexec_from_tty_if_needed` registers `trap 'rm -f …' EXIT` immediately after
  `mktemp` of `_install_tmp_script` and clears that trap immediately before the final
  `exec bash`. Re-exec temp scripts and
  syntax logs use `mktemp` under `${TMPDIR:-/tmp}`; checksum verification runs
  immediately after stdin capture and before `bash -n`. `install.sh` records packages it
  newly installs into `${STATE_DIR}/installed-packages` **before** the package-manager install
  command runs, then **reconciles** the record afterward against actually installed package names
  (failed/partial installs drop entries that never landed; reconcile strips empty lines from the
  missing-package list before `grep -f` so blank patterns cannot drop every recorded name).
  When OS family detection is empty during reconcile, revert the pre-install record entries
  for that missing-file batch (`_revert_pkg_record_entries`) before returning.
  Package temp files (`asus-pkg-*`)
  use `mktemp` under `${STATE_DIR}` (fail closed when `mktemp` fails before use; same for
  TUI `choice_tmp` in `lib/install-selection-tui.sh`). Interactive component selection
  uses a Python ncurses checklist (`bin/asus_install_selection_tui.py` via
  `lib/install-selection-tui.sh`): Space/arrows/Enter/Esc, mouse click toggle/Ok/Cancel,
  and OS accent color (`ASUS_TUI_ACCENT_RGB` or GNOME/KDE resolve). Custom accent
  `init_color(16, …)` requires `curses.COLORS > 16` (16-color terminals use
  `nearest_ansi16`). Drawing reserves the bottom content row for Ok/Cancel so item
  descriptions never share that row (clip items above on short terminals such as
  24×80). Requires a
  working Python `curses` module (openSUSE `python3XY-curses`, Fedora
  `python3-curses`; Debian/Ubuntu ship it with `python3`). Each option shows the
  protocol tag (`WMI`/`TOUCHPAD`/`SOUND`/`DESKTOP`) plus a wrapped detailed description
  under it; keep the dialog header short (keys help only) so four multi-line descriptions
  fit a standard terminal. Text-mode fallback keeps the same detailed msgids. Headless
  tests use `--script-keys` / `ASUS_TUI_SCRIPT_KEYS`. Do not add `whiptail`/`libnewt`/`newt`
  as install dependencies.
  `uninstall.sh` removes those packages through the
  detected package manager (apt/dnf/zypper/pacman). Debian recorded-package filtering uses
  `dpkg-query -W -f='${db:Status-Status}'` and emits a name only when status equals
  `installed` (config-files leftovers do not count). `_pkg_remover_cmd_probe_any` succeeds
  only when `_resolve_pkg_remove_cmd` produces a non-empty command. Package-remove
  family dispatch reuses `_resolve_*_pkg_remove_cmd` resolvers then
  `_build_*_pkg_remove_cmd` builders (same split as install-side pkg resolvers).
  Arch recorded removal uses
  `pacman -Rs --noconfirm --unneeded` so required packages stay installed.
  `lib/install-os-detection.sh` must expose `install_os_detection_init` to source
  sibling `lib/install-pkg-remove.sh` via `_validate_required_source_file` (missing
  file fails closed with `return 1` from the fallback stub so sourced callers stay
  active); auto-init on source unless `ASUS_OS_DETECTION_SKIP_INIT=1`.
  `install_system_deps` resolves the family install command first, then sets
  `ASUS_PKG_MISSING_FILE` and re-resolves so the missing-package list is written
  only after a successful family command resolve. Empty `pkg_installer_cmd` must
  not mask resolver failure with bare `|| true`; `_report_no_pkg_installer`
  distinguishes unrecognized `INSTALL_OS_ID` from “all deps already installed” /
  missing package manager. System deps include GNOME
  PyGObject (`python3-gi` / `python3-gobject` / Arch `python-gobject`) so
  gsettings `as` helpers can use real `gi`. GNOME array helpers pick a
  `python3` that can `import gi` (PATH first, then `/usr/bin/python3`) so Poetry
  venvs without system site-packages do not break install. Debian/Ubuntu fallback package removal
  (`ASUS_UNINSTALL_FALLBACK_PKGS` and recorded remove) uses `apt-mark auto` then
  `apt-get`/`apt` `autoremove` **without** `--purge` (keep conffiles).
  When the OS family is unknown, `_resolve_any_supported_pkg_cmd` probes RHEL, Arch, Debian, then SUSE
  and returns immediately after the first successful command resolution.
  `uninstall.sh` `stop_and_disable_services` calls `_require_systemctl` first
  (command must exist/be executable). `_run_systemctl_capture` runs systemctl under
  `LC_ALL=C` so `_is_absent_unit_error` sees stable English stderr.
  `_verify_service_inactive` treats
  `timeout` exits 124/137 as failure and accepts `is-active` status `3` or `4`
  (systemd 259+ often returns `4` for inactive/not-loaded; older releases used `3`)
  or an absent-unit stderr as inactive — other non-zero exits fail even with
  empty stderr. `_print_residual_entries` must `return 0` after listing (cap 20,
  with a truncated notice when the cap is hit) so a final false status cannot
  fail uninstall under `set -e`.
  Shared product file lists live in `lib/install-file-manifest.sh`
  (consumed by `deploy_wmi_component` and `uninstall.sh` `remove_installed_files`).
  Remove helpers reserve the nameref name `_failed_ref` for the caller's failure
  flag (do not shadow it). Manifest remove helpers early-return when `BIN_DIR` / `LIB_DIR` / `SYS_DIR` are
  empty. Uninstall also removes legacy `$LIB_DIR/install-*.sh` leftovers that older installs
  may have copied beside product helpers (so `rmdir` of `LIB_DIR` can succeed).
  `_asus_remove_legacy_lib_install_helpers` must save/restore `nullglob` around that
  glob so callers' shell options are unchanged.
  `deploy_wmi_component` `chmod +x` derives basenames from `_asus_manifest_wmi_src_relpaths`
  (no duplicate hardcoded chmod list). Staged lib installs via `_stage_resolved_lib_copy`
  accept successful empty copies; report concrete cp/missing-path errors (do not reject
  solely because `-s` is empty).
  Clear the record only after `remove_system_deps` succeeds
  (`_clear_installed_packages_record`); do not unlink it from `remove_installed_files`, so
  a failed package removal can retry the same recorded set. When removal finds nothing to
  remove but a supported package manager is present, clear the record; if no supported
  manager is detected, preserve the record for a later retry on a full system.
  With no record, uninstall removes no packages unless `ASUS_UNINSTALL_FALLBACK_PKGS=1`
  (known project deps only; never base interpreters `python3`/`python`). Install record
  write (`_record_packages_installed`) and reconcile (`_reconcile_packages_installed`)
  must strip base interpreters via `_write_non_base_pkg_lines_from_file` before writing
  `installed-packages` (same filter as uninstall emit). Recorded emit paths must also
  filter base interpreters. Native `debian/source/options` uses `tar-ignore` for local
  caches (`.cache`, `.venv`, `node_modules`, `reports`, …) so `dpkg-buildpackage -S`
  cannot ship multi-GB buildx blobs. When `DESTDIR` is set and `SKIP_PKG_REMOVE` is
  unset, `uninstall.sh` defaults `SKIP_PKG_REMOVE=1` (honor an explicit override).
  Tests/kcov must set `SKIP_PKG_REMOVE=1` unless package-manager stubs are intentional.
  Use `SKIP_PKG_INSTALL=1` / `SKIP_PKG_REMOVE=1` symmetrically for staged DESTDIR runs
  (string compare to `"1"`, not arithmetic `-eq`).
  Debian/Ubuntu apt paths must set `-o Dpkg::Use-Pty=0` and run package commands with
  stdin from `/dev/null` so dpkg maintainer scripts cannot SIGTTOU-stop under
  `sudo`/`timeout` (looks like a hang after “Processing triggers…”).
- **asus-uinput group (ydotool / uinput)**: Membership grants write access to
  `/dev/uinput` and the ability to inject synthetic input. Install messaging near
  group/udev setup must state that privilege and that uninstall revokes recorded
  users. When install adds a session user to group
  `asus-uinput`, record the username only in `${STATE_DIR}/asus-uinput-group-users`
  (skip users already in the group; legacy `${STATE_DIR}/input-group-users` is still
  revoked on uninstall). `_record_uinput_group_user` soft-succeeds on `mkdir` / append
  failures (`|| return 0`) so a full disk cannot abort install after usermod.
  Skip group lookup/creation and usermod when `PREFIX` is set
  (staged installs still copy the udev rule). `uninstall.sh` revokes recorded users via
  `revoke_uinput_group_members` before package removal, then best-effort `groupdel
  asus-uinput` when `PREFIX` is empty (group deletion must not fail uninstall). Keep the
  recorded list when any `gpasswd -d` fails so a later uninstall can retry.
  `_resolve_ydotool_session_user` uses `target_user=$(find_active_session_user || true)`.
  Group membership checks split `id -nG` and exact-match the group token (do not use `grep -qw`, which
  can match similarly named groups). Rule match is `SUBSYSTEM=="misc", KERNEL=="uinput"`.
  After installing `99-asus-uinput.rules`, skip `udevadm`
  reload/trigger when `PREFIX` is set (staged DESTDIR); otherwise trigger with
  `udevadm trigger --subsystem-match=misc --name-match=uinput`.
  `remove_installed_files` deletes `${PREFIX:-}/etc/udev/rules.d/99-asus-uinput.rules` and
  reloads udev when `PREFIX` is empty.
- **GNOME keybinding restore (optional keys)**: Uninstall must restore
  `orig_switch_video_mode` and `orig_switch_monitor` only when those backup files exist.
  Modern GNOME may lack `switch-video-mode`; forcing `gsettings reset` on a missing key
  fails the whole uninstall. `_gsettings_key_exists` must capture `list-keys` then
  `grep -Fxq` via here-string (not `list-keys | grep -q`): under `set -o pipefail`,
  early `grep -q` exit SIGPIPEs the writer (exit 141) when the key is present. Always restore `orig_switch_monitor` when present because
  install may have rewritten Mutter `switch-monitor`.
  `_restore_schema_file` uses `gsettings set` for non-empty backups and `gsettings reset`
  when the backup file is missing **or empty**.
  When the fallback user is the `NO_SESSION_USER` sentinel, keep that username but set
  `user_id=""` (never use the sentinel string as a UID path segment) so restore helpers
  skip via the empty-UID checks. `resolve_fallback_user` guards `who|awk` with `|| true`
  under `set -e`/`pipefail`. GNOME `gsettings` restore/reset during uninstall must set
  `XDG_RUNTIME_DIR` to the D-Bus socket parent (`dirname` of `$BUS_ROOT/$uid/bus`) alongside
  `DBUS_SESSION_BUS_ADDRESS`. When `orig_custom_keybindings` is absent, emit a warning before
  resetting `custom-keybindings`. `remove_installed_files` always removes KDE helper
  `.desktop` files under `/usr/local/share/applications/` (not only during KDE shortcut restore).
- **Desktop shortcuts (`DESKTOP` / alias `GNOME`)**: Dispatch by
  `asus_desktop_family` to `lib/install-gnome.sh`, `lib/install-kde.sh`,
  `lib/install-xfce.sh`, `lib/install-lxqt.sh`, `lib/install-cinnamon.sh`, or
  `lib/install-mate.sh`. XFCE shortcut set/require/restore
  share one
  `_xfce_shortcut_table` (path|backup|command); uninstall must not `rm -rf`
  the XFCE `config_dir` after a successful `restore_xfce_shortcuts` (that helper
  already owns deletion). LXQt upserts Exec sections in
  `$HOME/.config/lxqt/globalkeyshortcuts.conf` (`XF86Display`, `Meta%2BP`,
  `Meta%2BF12`, `Meta%2BShift%2BS`) with atomic section backups + `.absent` /
  `.section` sidecars; best-effort `pkill -HUP lxqt-globalkeysd` must not fail
  install/restore alone; `restore_lxqt_shortcuts` owns safe `config_dir`
  deletion like XFCE. `Meta%2BP` also binds `asus-display-mode.sh` (runtime
  Display Toggle still prefers ydotool/xdotool Super+P; `XF86Display` covers the
  hardware Display key). Keep `install-lxqt.sh` ≤600 lines (split helpers if
  needed; never delete comments to shrink). Cinnamon uses
  `org.cinnamon.desktop.keybindings` custom-list + relocatable custom slots and
  clears `video-outputs` before binding `XF86Display` / `<Super>F12` /
  `<Super><Shift>s`. MATE uses relocatable
  `org.mate.control-center.keybinding:/org/mate/desktop/keybindings/<slot>/`
  (`name`/`action`/`binding`). Uninstall desktop restore helpers live in
  `lib/uninstall-desktop-restore.sh` (sourced by `uninstall.sh`).
  GNOME custom-keybindings / enabled-extensions list
  merge and drop use a shared GLib.Variant (`as`) helper (`_gsettings_as_array_op`),
  not string scratch-state parsers. Default “all” includes `DESKTOP` only for
  gnome/kde/xfce/lxqt/cinnamon/mate via shared `_desktop_family_supports_desktop_component` in
  `lib/install-selection.sh`. Uninstall reads `desktop_family` under `${STATE_DIR}/$uid`
  and restores the matching backend. GNOME/KDE/XFCE/LXQt/Cinnamon/MATE `target_user` state uses
  `target_user.tmp` + `mv` (fail closed on write/`mv`). `configure_gnome_component`
  must fail closed on `mkdir -p` of the per-user state dir and on writing
  `desktop_family` (same pattern as KDE). Uninstall
  `restore_desktop_shortcuts` prefers `${STATE_DIR}/$uid/target_user` when present and
  valid (`getent`), else the current session/fallback user. Shared `_is_safe_config_dir`
  in `lib/install-shared.sh` must canonicalize via `_canonical_install_path` before
  checks, fail closed when `STATE_DIR` is empty, and require the canonical path under
  `"$state_canonical"/*` only (reject empty, `/`, equality to `state_canonical`, or
  paths outside that prefix). `_install_run_as_user` prefers `runuser` then `sudo`
  (same order as product `_run_as_user`), with `--` after the username; same-user
  skips privilege drop. GNOME legacy binding clears pass `"''"` (quoted empty
  gsettings string), not a bare empty argument. XFCE `xfconf-query` under
  `_install_run_as_user` must use stdin `/dev/null`. GNOME
  `backup_gnome_keybinding` likewise fails closed on `.tmp` write/`mv`.
  KDE `_kde_write_backup_value_or_absent` and XFCE/LXQt backup writes must fail closed
  (atomic tmp in dest dir + `mv`; `_kde_atomic_write_file` /
  `_xfce_write_backup_value` / `_xfce_mark_backup_absent` /
  `_lxqt_atomic_write_file` must `rm -f` the temp on
  write/`mv` failure before returning 1). XFCE/LXQt state writes (`desktop_family`,
  `target_user`, and XFCE `xfce_bus_path`) go through labeled tmp+`mv` helpers.
  KDE `kwriteconfig` must run under
  `_install_run_as_user` with `HOME` / `XDG_CONFIG_HOME` set from `getent` (same `env`
  pattern as `_user_gsettings`). KDE shortcut deletes and `KGlobalAccel.reconfigure` prefer
  `qdbus6` / `qdbus-qt6` / `qdbus` (install fails closed when none are on `PATH`).
  On KDE restore, `KGlobalAccel.reconfigure` failure is a warning only (do not fail
  restore / preserve state for that alone).
  XFCE backups use sidecar `*.absent` marker files
  (not inline `__ABSENT__` values); require backup sidecars before applying bindings.
  Query status `1` marks absent; status `0` always records the queried value
  (including empty string) for restore. On restore, warn when both the backup
  value and `.absent` marker are missing.
  GNOME `_set_myasus_keybindings` treats partial optional-slot failures as
  warnings and still returns success so `_set_gnome_keybindings` does not fail
  the whole GNOME shortcut step.
  KDE install backs up native `kscreen` shortcuts before clearing Meta+P; failed KDE
  install/uninstall restore preserves `${STATE_DIR}/$uid` when restore fails.
  `configure_kde_component` must not `rm` `desktop_family`/`target_user` after a failed
  shortcut apply — warn that backup state remains for manual recovery (same pattern as
  Cinnamon/MATE); successful `restore_kde_shortcuts` already cleans via `_kde_finish_restore`.
  XFCE `xfconf-query` must receive `DBUS_SESSION_BUS_ADDRESS` / `XDG_RUNTIME_DIR`
  from the resolved bus path (persist `xfce_bus_path` via tmp+`mv` under state for restore).
  GNOME Window Swap helper (`asus-window-swap@ventura8.github.com`) is copied under
  `~/.local/share/gnome-shell/extensions/` then marked enabled via session-bus
  `gsettings` (`_run_as_user_on_session_bus` / `_user_gsettings`). Clearing
  `org.gnome.shell disable-user-extensions` (set `false`) is **mandatory** on
  enable (`_gnome_enable_window_swap_extension` and runtime primes) — the global
  kill switch leaves the UUID listed in `enabled-extensions` but **INACTIVE**
  with no `/org/gnome/Shell/Extensions/AsusWindowSwap` object (ScreenPad OSD
  falls to notifications only; window-swap cannot use `MoveFocused`). Do **not**
  treat “UUID present in enabled-extensions” as D-Bus-ready. Never enable with
  bare `sudo -u` (no `DBUS_SESSION_BUS_ADDRESS` → `dbus-launch` / dconf failure while
  install still prints success). Install **overwrites** `extension.js` /
  `metadata.json` in place — do **not** `gnome-extensions disable` + `rm -rf` on a
  live Wayland session (`ReloadExtension` is unimplemented; that drops ShowOsd
  until logout). Extension `disable()` must always `unexport()` even when
  `flush()` throws (null `_dbus` without unexport leaves `/AsusWindowSwap` stuck).
  Newly installed extensions are not loaded by a live Wayland Shell until
  logout/login; install must not claim the D-Bus API is live until then—chord
  fallback remains until one logout.
  Uninstall strips the UUID from `enabled-extensions` on the session bus before
  deleting the extension directory.
- **Session env (`lib/asus-session.sh`)**: Resolve `DISPLAY` /
  `WAYLAND_DISPLAY` / `XDG_SESSION_TYPE` / `XDG_CURRENT_DESKTOP` from
  `loginctl` Type, session leader `/proc/<pid>/environ`, then
  `systemctl --user show-environment`. Family order is xfce → kde → lxqt →
  cinnamon → mate → gnome → other: match `*cinnamon*` / `*mate*` **before**
  `*gnome*|*ubuntu*|*pop*` so Mint flavours are not misclassified as GNOME.
  Prefer xfce/kde/lxqt over ubuntu tokens in
  `XDG_CURRENT_DESKTOP` (Xubuntu/Kubuntu/Lubuntu). When the string would map to
  `gnome`, apply Mint bare-GNOME heuristics (`XDG_SESSION_DESKTOP` /
  `DESKTOP_SESSION` cinnamon|mate tokens, then `/usr/bin/cinnamon` vs
  `gnome-shell` / mate-session binaries, then gsettings schema presence) —
  never reclassify a true GNOME Shell session when secondary signals are absent.
  Wire the same rules in shell (`asus_desktop_family`) and Python
  (`desktop_family_hint`). Override with `ASUS_DESKTOP_FAMILY`.
  `_asus_user_runtime_dir` resolves the runtime root as
  `BUS_ROOT` → `DBUS_BUS_ROOT` → `RUN_USER_ROOT` → `/run/user` (same precedence as
  `lib/asus-common.sh`).
  Tests and kcov override the proc root with `ASUS_PROC_ENVIRON_ROOT`
  (default `/proc`; read `$root/$pid/environ`) — do not use a flat file override.
  Cap each `systemctl --user show-environment` with `timeout`
  (`ASUS_SYSTEMCTL_ENV_TIMEOUT_SECS` digits-only; empty/non-numeric → default **1**) when
  `timeout` is on `PATH`; if `timeout`
  is missing, run the command directly (do not treat that as a transport failure that sets
  `_ASUS_SYSTEMCTL_ENV_SKIP`). When `timeout` exits **124**, emit a Debug line on stderr
  then return that status (fetch path still sets skip). Negative-cache real transport failures in
  `_ASUS_SYSTEMCTL_ENV_SKIP` so a listening but non-D-Bus socket (unit fixtures,
  broken sessions) cannot stall helpers. `_asus_lookup_env_key` must set that skip
  flag in the caller shell from a distinct transport-failure exit status (not inside
  `$()` alone; do not cache absent-key misses). Cache one `show-environment` blob per
  session user (`_ASUS_SYSTEMCTL_ENV_BLOB`); treat `_ASUS_SYSTEMCTL_ENV_CACHE_VALID`
  as the hit flag so an empty blob still counts as cached. Resolve keys from that cache. Missing
  runtime dir returns status **1**; transport failures return **2** and set skip (only
  status 2).   Installer DE helpers use `_install_run_as_user` in `lib/install-*.sh` (default
  `INSTALL_COMMAND_TIMEOUT` **15s**, clamped by `INSTALL_COMMAND_TIMEOUT_MAX` (default
  **120** so `SOUND_FIX_PROBE_TIMEOUT` above 60s is not unexpectedly clamped)); `_run_command_with_timeout`
  uses a fixed **2s** `--kill-after` separate from the overall timeout; source
  `lib/asus-session.sh` in-place from `lib/install-shared.sh` (no `cd` into `lib/`).
  Product scripts keep `_run_as_user` from `lib/asus-common.sh` (sudo fallback uses
  `sudo -n -u` so missing credentials fail immediately). Session discovery shares
  `_loginctl_session_ids` between `find_active_session_id` and
  `find_active_session_user`. Installer wizard FDs opened for selection must be
  closed via `_close_wizard_ui_fds` after `prompt_user_selection` returns (success
  or failure). Uninstall `restore_gnome_shortcuts` takes already-resolved
  `user`/`uid` parameters (no nested `_resolve_target_user_info`).
  Kcov multi-DE coverage uses
  `scripts/coverage/drivers/{kde,xfce,lxqt,cinnamon,mate,display,session,common}_helpers.sh`
  plus mutter/xdotool/screenshot family scenarios.
  `_make_fake_loginctl_current_user` must install a username-aware `id` stub
  (`_make_fake_id_current_user` / unit `fake_id`): `id -un` must return a
  **username**, not the numeric uid, or `_run_as_user` same-user detection
  breaks and Settings launches can hang via `runuser` in containers without a
  matching passwd entry. Background Settings launches must spawn via
  `sh -c 'exec … </dev/null >/dev/null 2>&1 & echo $!'` under `_run_as_user` so the
  helper returns immediately without waiting on the child or holding stdout pipes.
  Shared `_check_launch_process` lives in `lib/asus-common.sh` (screenshot / control-center
  helpers must not keep local copies). `bin/asus-control-center.sh` prefers the
  matching DE settings app (`lxqt-config` on LXQt; `cinnamon-settings` /
  `mate-control-center` on those families; skip GNOME `Activate` for
  kde/xfce/lxqt/cinnamon/mate) and `_try_launch_cmd` returns
  the background PID via a nameref out-parameter (6th argument), not a global. It probes
  liveness after `ASUS_LAUNCH_CHECK_SECS` (default `0.2`). Use that duration only when it
  matches `^[0-9]+([.][0-9]+)?$`; otherwise `sleep 1` (do not invoke `sleep` with an
  invalid duration). On `gio launch` failure keep the exit status in the error message
  but always `return 1`. Unit tests should keep Settings stubs alive briefly and isolate PATH.
  For DE `.desktop` fallback coverage, use `_kcov_isolated_bin_dir` (PATH
  without real `systemsettings`/`gnome-control-center`/`lxqt-config`) and rewrite stub
  files
  after `cp` so symlink write-through cannot clobber system binaries.
- **Uninstall desktop restore**: `uninstall.sh` sources `lib/asus-i18n.sh` with the
  shared/os-detection/components/manifest helpers so LXQt/Cinnamon/MATE shortcut
  tables can call `_asus_ui_label` / `_asus_gettext` during restore (missing i18n
  left `asus-display-mode.sh` in `globalkeyshortcuts.conf`). `uninstall.sh` sources
  `lib/install-gnome.sh` once after
  the shared/os-detection/components/manifest helpers (soft: only when the file exists).
  `restore_gnome_shortcuts` still verifies the helper file exists but does **not**
  re-source it. Before sourcing `lib/install-kde.sh` /
  `lib/install-xfce.sh` / `lib/install-lxqt.sh`, verify the file exists and emit a
  clear error (same
  pattern as the top-level shared/os-detection guards).   Successful
  GNOME/KDE/XFCE/LXQt
  restore must `rm -rf` the per-user `$config_dir` backup via `_is_safe_config_dir`;
  failed restore preserves it. Residual library
  entries are listed with shell globs, capped at 20 (emit a truncated notice at the
  cap). Register `trap '_cleanup_uninstall_systemctl_temps' EXIT` only when
  `uninstall.sh` is executed as main (`BASH_SOURCE[0]` equals `$0` **or** is empty,
  and `ASUS_UNINSTALL_SOURCE_ONLY` is not `1` — same guard as the bottom main
  invocation). Track systemctl stderr temps in
  `_UNINSTALL_SYSTEMCTL_TEMPS` (push on create; remove the exact `err_file` path after
  use — not a LIFO/basename pop; EXIT iterates remaining paths) so nested
  `_run_systemctl_capture` stays nest-safe. GNOME gsettings restore/reset keep stderr
  (do not discard); `_reset_gnome_custom_bindings` status must propagate (do not
  swallow with `|| true`).
  Sourcing `uninstall.sh` for kcov/tests must set
  `ASUS_UNINSTALL_SOURCE_ONLY=1`
  (mirrors `ASUS_INSTALL_SOURCE_ONLY`) so `main` does not run.
- **KDE/XFCE/LXQt install markers**: After `_kde_backup_marker`, early `target_user.tmp`
  write/finalize failures must `rm -f` `$state_root/desktop_family` and
  `$state_root/target_user` (same cleanup as the later keybinding-failure path).
  XFCE `_xfce_backup_marker` failure messaging refers to the `desktop_family` marker
  (not shortcuts backup). `_xfce_backup_binding` probes `xfconf-query -c
  xfce4-keyboard-shortcuts -l` before per-path query backup; skip backup when the
  probe fails. XFCE state files use `_xfce_write_state_file` (tmp cleaned on write/`mv`
  failure). LXQt install markers follow the same early-cleanup pattern for
  `desktop_family` / `target_user` on backup or conf-write failure.
- **Install selection desktop family**: `_resolve_desktop_family` is shared by
  `_default_all_components` and `_desktop_default_on` (`ASUS_DESKTOP_FAMILY` or
  `asus_desktop_family`). `_print_special_component_selection` accepts `ALL` and `NONE`
  (literal token `none` stays untranslated like `all`). `_prompt_text_selection` treats
  normalize status **2** as invalid input and retries; other non-zero statuses hard-fail
  (noninteractive keeps hard-fail for status 2). Shared Invalid `NONINTERACTIVE_CHOICE` text
  lives in `_INVALID_NONINTERACTIVE_CHOICE_MSG` (mentions `all` and `none`; reuse in both
  normalize-failure branches). Combinatorial DESTDIR matrix lives in
  `tests/unit/shell/test_install_component_matrix.py` (16 subsets including empty).
  `_deploy_selected_component` must `*) return 1` for unknown component tokens.
- **Install shared libdir**: Existence checks for installed helpers must use
  `${LIB_DIR:-}` so an unset `LIB_DIR` does not expand to a relative path.
- **Fan profile toggle (`bin/asus-fan-toggle.sh`)**: Prefer `powerprofilesctl`
  (power-profiles-daemon) over writing `throttle_thermal_policy` alone. Writing only
  asus-wmi sysfs can leave `ActiveProfile` on `performance` (intel_pstate) while
  notifications claim Quiet/Silent.
  Mapping: `0/balanced`, `1/performance`, `2/power-saver` (Quiet). `_value_from_ppd_name`
  maps `balanced` explicitly and logs unrecognized PPD names to stderr before defaulting to `0`.
  Fall back to sysfs
  when PPD is absent or `set` fails. When PPD is available, a missing or read-only
  sysfs node must not fail the toggle; validate sysfs writability only on sysfs fallback.
  `ASUS_FAN_NODE` forces sysfs-only (unit/kcov) only when the canonical path is under
  `${SYS_PLATFORM_ROOT}` (`_fan_sysfs_path_allowed` prints the canonical path on
  success so `find_fan_node` uses the resolved node; otherwise warn on stderr, ignore override, and continue discovery);
  `ASUS_FAN_USE_PPD=1` forces the PPD path even with `ASUS_FAN_NODE` for coverage
  scenarios; when set, `ASUS_FAN_USE_PPD` must be `0` or `1` only — `0` disables
  powerprofilesctl immediately regardless of `ASUS_FAN_NODE`. Validate
  `ASUS_FAN_USE_PPD` once at fan-toggle startup (`_validate_asus_fan_use_ppd`) and
  reuse the stored mode in `_ppd_enabled` (lazy-validate when helpers are sourced
  without `main`). `_read_current_fan_value` must skip `cat` when `node` is empty
  (assume `0` with a stderr warning). Failed `cat` in `_read_current_fan_value` logs a
  stderr diagnostic then falls back to `0`. Fan sysfs discovery uses `SYS_PLATFORM_ROOT`
  (default `/sys/devices/platform`) for `asus-nb-wmi` / `asus-wmi` throttle nodes—same
  root as camera toggle, not ScreenPad `SYS_CLASS_ROOT`. Unit/kcov must set
  `SYS_PLATFORM_ROOT` to the temp tree when pointing `ASUS_FAN_NODE` at a fixture.
- **Camera toggle (`bin/asus-camera-toggle.sh`)**: `SYS_PLATFORM_ROOT` defaults to
  `/sys/devices/platform` for ASUS WMI camera nodes (`asus-nb-wmi/camera`, `asus-wmi/camera`).
  This differs from ScreenPad helpers, where `SYS_CLASS_ROOT` defaults to `/sys/class`.
  Unit tests that assert `screenpad_node_writable()` is false must keep that call
  inside the `SYS_CLASS_ROOT` / empty `ASUS_SCREENPAD_NODE` fixture — a host ZenBook
  has a real writable node, and `debian/rules` `override_dh_auto_test` (local
  `run_deb_package_smoke.sh`) runs unittest on the host. Topology unit tests that
  use `patch_sync_daemon_threads` / ImmediateThread must also patch
  `detect_swap_topology_map` — otherwise the inline worker probes live Mutter/xrandr
  and pollutes `last_known_monitors` for later assertions.
  Accept `ASUS_CAMERA_NODE` only when the canonical path is under
  `${SYS_PLATFORM_ROOT}` or `${SYS_BUS_USB_ROOT:-/sys/bus/usb/devices}`; otherwise
  warn on stderr, ignore the override, and continue discovery.
  `_camera_sysfs_path_allowed` prints the canonical path on success so
  `find_camera_node` uses the resolved node (not the raw override string).
  USB video class compares numerically
  (`0e` / `e` / `0E` → `0x0e`). Unit/kcov fixtures must set `SYS_PLATFORM_ROOT` (or
  `SYS_BUS_USB_ROOT`) so override nodes pass containment.
  After writing the sysfs toggle, read the node back and fail closed when the
  value does not match before sending user notifications. Fail closed on unread or
  non-numeric current values before computing the next toggle (do not assume enabled).
  Notifications prefer a matching system theme glyph when present
  (`camera-photo-symbolic` on / `camera-disabled-symbolic` off). Otherwise tint
  UX582HS F10 keycap templates from `assets/icons/asus-camera-*-symbolic.svg` to
  GNOME `.message-header` (emitting app-name) color via `lib/asus-notif-icons.sh`.
  Force keycap art with `ASUS_CAMERA_FORCE_KEYCAP=1`; override templates with
  `ASUS_CAMERA_ICON_DIR` (must be absolute like `PREFIX`; relative values warn and are
  ignored) / color with `ASUS_CAMERA_APP_NAME_COLOR` (or
  `ASUS_NOTIF_APP_NAME_COLOR`). Unit/kcov theme probes set `ASUS_ICON_THEME_ROOT`
  to a temp icon tree (do not branch on host Adwaita/Yaru under `/usr/share/icons`).
- **Notifications (`_send_user_notification` / `_send_synchronous_notification`)**:
  Best-effort only. Missing session context returns 0; empty `bus_addr` from
  `_prepare_user_notification_context` returns 0; reuse that `bus_addr` (derive
  `bus_root` with two `dirname` calls after stripping `unix:path=` so
  `XDG_RUNTIME_DIR="$bus_root/$user_id"` is correct) and do not re-resolve/reconstruct
  the session bus address.
  A present bus whose Notify
  backends fail (or `notify-send` exits non-zero) must also return 0 so
  camera/fan/ScreenPad toggles succeed under `set -e`. `_resolve_notif_target_user`
  uses `user=$(find_active_session_user || true)` and always returns 0 after
  optionally printing a username. Synchronous notification tags must match
  `^[A-Za-z0-9._-]+$` before `gdbus` / `notify-send` hints are built.
- **Display mode cycle (`bin/asus-display-mode.sh`)**: Sticky OSD/state/watchdog helpers live in
  `lib/asus-display-state.sh`, `lib/asus-display-watchdog.sh`, and `lib/asus-display-osd.sh`
  (hard-sourced in order after bootstrap/common/mutter). The entry script keeps flock,
  `--internal-*`, Mutter fallbacks, and `main`. Prefer native monitor OSD via
  sticky Super+P: `ydotool` first (Wayland/X11; GNOME/KDE when Super+P is bound),
  then `xdotool` on X11. On **GNOME**, fall back to Mutter D-Bus profile cycling via
  `asus_display_mode.py` (helpers in `lib/asus-display-mutter.sh`), then DE display
  settings. On **KDE/XFCE/LXQt/Cinnamon/MATE**, skip Mutter entirely
  (`_try_fallback_backends` opens DE settings only — locked equivalent: sticky
  Super+P OSD then `lxqt-config-monitor` / `cinnamon-settings display` /
  `mate-display-properties`; never `ApplyMonitorsConfig`). **Why not Mutter on
  LXQt/Cinnamon/MATE:** `org.gnome.Mutter.DisplayConfig` is owned by GNOME Shell /
  mutter, not those DEs (Cinnamon Muffin is not a drop-in for our GNOME path;
  MATE uses Marco). Calling it would fail closed or talk to a leftover GNOME bus.
  Mutter
  `ApplyMonitorsConfig` (GNOME path) uses method **2**
  (persistent). Mutter Python helpers require `timeout` on `PATH` (fail closed when absent).
  `_detect_current_mutter_state` / `_get_next_profile_info` soft-capture
  `_run_display_mode_python` failures (`|| detected=""` / `|| result=""`) so timeouts
  fall through to defaults without aborting under `set -e` (do not use bare `|| true`).
  `ASUS_DISPLAY_MODE_PYTHON_TIMEOUT_SECS` must be digits-only positive (default **5**);
  invalid/empty/zero clamp to 5. Fallback Mutter profile state uses
  `${NOTIF_ID_ROOT:-/run/asus-zenbook-notif}/$user_id/asus_disp_state`.
  `_log_display_mode` bounds `asus-display-mode.log` best-effort via
  `_append_bounded_display_mode_log` (append then `tail -c` rewrite via temp+`mv`
  when it exceeds **256 KiB**; rewrite failures must not fail the helper).
  Topology/layout helpers live in `asus_display_mode_layout.py`; `asus_display_mode_core.py`
  re-exports layout + profile APIs for backward-compatible imports. Profile cycle/labels live
  in `asus_display_mode_profiles.py` (imports layout only — no core↔profiles import cycle).
  Monitor dicts keep union `supported_scales` across modes and selected-mode
  `mode_scales`; `_choose_target_scale` validates `DISPLAY_SCALE` only against
  `mode_scales`.
  `_set_screenpad_backlight` and ScreenPad toggle restore clamp values to each node's
  `max_brightness`. Profile grouping is connector-first: built-in main
  (`DEFAULT_MAIN_CONNECTOR`), ScreenPad secondary (`DEFAULT_SECONDARY_CONNECTOR`, optional
  override `ASUS_SCREENPAD_CONNECTOR`) before `DP-*` dimension heuristics. When
  two built-in panels are present, `_choose_main` keeps one as main and the
  non-selected built-in is routed to `groups["screenpad"]` before externals.
  `_is_screenpad_like_external` rejects empty connector names before `DP-*` checks and
  requires exact width **and** height match against `DEFAULT_SECONDARY_MODE` (plus
  aspect tolerance) so a `3840x1080` `DP-*` panel is not treated as ScreenPad-like.
  `logical_size_from_mode` fails closed (`(None, None)`) on unresolved/invalid scale —
  no `DEFAULT_LOGICAL_*` fallback; `build_logical_monitors` raises `ValueError` before
  advancing `y_offset` when height is unresolved. Reserve
  `SECONDARY_VERTICAL_OFFSET` for layout positioning constants only.
  Soft file writes use `_soft_write_stdout` from `lib/asus-common.sh` (redirect inside
  the helper). Idle/dup/flock env overrides must be digits-only (`^[0-9]+$`) else `2` / `50` / `5`.
  Commit `3547bba` GNOME path: Mutter keeps `switch-monitor=['<Super>p']`;
  `install-gnome.sh` clears custom `<Super>p` and does **not** bind stock `F8`.
  Sticky session idle ~2s; duplicate suppress ~50ms (skipped while OSD session
  active). Daemon debounce for `asus-display-mode.sh` is ~50ms so Display Toggle
  cycles match native Super+P speed; other helpers stay at 300ms. Concurrent
  helper workers must serialize on `${prefix}.flock` (`flock -w`, default
  `ASUS_DISPLAY_MODE_FLOCK_WAIT_SECS` **5**; timeout fails closed) so a second press
  cannot Super-down before `.session` exists (that race made the first presses
  look like no-ops). Resolve ydotool by probing the existing socket first; only
  `systemctl --user start ydotool` when missing, then poll the socket briefly
  (do not return success with an empty socket — that made the first Display
  Toggle look like a no-op). Ydotool helpers (`_find`/`_wait`/`_resolve_ydotool_*`)
  must use local names like `sock_user` (never `active_user`) so nameref `_yd_user`
  writes the caller’s `active_user` instead of shadowing it. Watchdog lock backoff
  sleeps use numeric seconds (`printf '0.%03d'`), and `_watchdog_release_if_idle`
  reuses `_watchdog_expiry_needs_release`. If a sticky `.session` exists without a live
  watchdog, treat it as orphaned and reopen OSD instead of P-only cycling.
  Open OSD by writing `.ctx` +
  `.session` **before** Super-down + P (ydotool/xdotool); clear those markers if
  injection fails. Esc cancel treats either `.session` or `.ctx` as active so a
  late Esc still releases Super. Sticky OSD state/logs must live under
  `NOTIF_ID_ROOT` (`/run/asus-zenbook-notif/$uid/…`), not `/run/user`—hotkey
  `ProtectHome=read-only` makes `/run/user` read-only, so a missing sticky marker
  used to leave Super latched or (with eager release) hard-cycle without the
  monitor dialog. On OSD idle, `_release_osd_modifiers` keyups Super first
  (apply selection), then Shift/Ctrl/Alt L+R. Before opening a sticky session,
  clear non-Super modifiers so a stuck Shift cannot turn Super+P into
  Super+Shift+P.   Esc during an active sticky OSD (AT keyboard proxy) must **not** forward Esc
  via the AT uinput proxy.   Call `asus-display-mode.sh --cancel-osd` synchronously;
  that injects Esc then Super-up on the **same** ydotool/xdotool device that holds
  Super (cross-device Esc+Super-up races: apply selection or re-open OSD).
  `_handle_internal_mode --cancel-osd` returns `_cancel_osd_session` status (not
  forced 0) so lock-open failures propagate to the hotkey daemon. Cancel helper
  timeout caps at **1.0s** (`ASUS_DISPLAY_MODE_CANCEL_OSD_TIMEOUT_SECS`, default
  0.5).
  `_dismiss_osd_modifiers` sets `${prefix}.cancel` and drops `.session` before
  injecting Esc so idle watchdog `_release_osd_modifiers` (apply) cannot race Esc
  cancel; while `.cancel` is set the idle watchdog must not apply-release Super or
  tear down `.ctx` (only `--cancel-osd` dismiss clears markers). Brief sleep between
  treating Super-up as apply before Esc dismisses. The hotkey daemon arms a
  ~450ms display-mode dispatch cooldown after Esc cancel, releases AT-proxy
  Super/Shift/Ctrl/Alt ups (ydotool holds sticky Super separately), and clears
  buffered firmware Super+P so a echoed chord cannot
  immediately re-open the OSD. **Do not flush pending Super on OSD Esc** (regression:
  dialog disappears then reappears). On AT `KEY_ESC` while sticky OSD markers are
  active (`.session` or `.ctx`), `handle_at_key_event` must `reset_pending_meta`
  (drop the buffer) — never `flush_pending_meta` — before `handle_esc_on_at`.
  Flushing Super+P on the AT uinput races ydotool Esc dismiss and re-opens
  Mutter’s monitor dialog. When no OSD session is active, flush any buffered
  Super chord before forwarding Esc. Covered by
  `test_esc_during_osd_drops_pending_meta_without_flush`. Esc cancel runs
  `_run_cancel_display_osd`
  on a
  short-lived daemon `threading.Thread` (catch `RuntimeError` from `Thread.start`
  and reset `cancel_in_flight`); `cancel_in_flight` is safe without a lock because
  only the single hotkey event thread arms it; `release_proxy_modifier_keys`,
  `arm_display_osd_esc_cooldown`, and `_ESC_OSD` bookkeeping stay on the event
  thread. Esc cancel releases Super/Shift/Ctrl/Alt via
  `release_proxy_modifier_keys` in `asus_hotkey_daemon_at_proxy.py` (do not keep a
  Super-only duplicate). Cooldown and cancel-osd
  timeouts share `_bounded_float_env` in `asus_hotkey_daemon_osd.py`. On a normal Esc press that is forwarded (not OSD dismiss / not
  swallow-followup), clear `_ESC_OSD.swallowed_press` before `forward_key`; keep
  swallow-followup for Esc release/repeat after an OSD dismiss.
  `--cancel-osd` uses non-blocking `flock -n` and still dismisses if the lock is
  busy. Idle/expiry release still uses Super-up only (`_release_osd_modifiers`)
  to apply. OSD release clears `.session` and `.ctx`. Log `--cancel-osd`
  failures at warning (not debug).
  `ASUS_DISPLAY_MODE_STATE_PREFIX` caches its dirname in `_ASUS_DISPLAY_MODE_DIR_CACHE`
  (avoid repeated dirname under hot paths). Guard bare
  `_ASUS_DISPLAY_MODE_DIR_CACHE` / `_ASUS_DISPLAY_MODE_PREFIX_CACHE` reads with
  `${…:-}` so sourcing `lib/asus-display-state.sh` under `set -u` is safe before
  `bin/asus-display-mode.sh` initializes them; `_bump_session_expiry` uses
  `${_OSD_IDLE_SECS:-2}` like the watchdog. `_ensure_watchdog` acquires
  `${prefix}.wd.lock` via bounded-backoff atomic `mkdir` (`_acquire_watchdog_lock`):
  only the owner of a successful `mkdir` proceeds; a live `${prefix}.wd.pid` leaves
  the lock to that owner (return success without spawning); stale locks are cleared
  then retried so a dead lock cannot leave synthetic Super held without a watchdog.
  Watchdog lock cleanup relies on the RETURN trap only (no duplicated rmdir/trap-clear
  on early exits). Never treat spawn `$!` / `_spawn_detached_watchdog` stdout as liveness—only
  `${prefix}.wd.pid`.
  `_log_display_mode` bounds growth via `_append_bounded_display_mode_log` (best-effort
  when the log exceeds **256 KiB**). Watchdog processes write their own PID to
  `${prefix}.wd.pid` in `_run_internal_watchdog`
  (setsid re-exec) and in the no-`setsid` subshell before `_watchdog_poll_loop`; `_watchdog_poll_loop`
  itself does not write the PID file (the parent must not echo `$!`). After each
  `_watchdog_release_with_retries`, re-check `${prefix}.session` and continue polling
  when the sticky OSD was re-armed (future expiry); only return when the session is
  absent or remains expired/unrecoverable. Idle/expiry
  release must acquire `${prefix}.flock`, re-validate session expiry under that lock,
  then release modifiers so main/`--cancel-osd` cannot race. `_watchdog_release_with_retries`
  bounds `_watchdog_release_if_idle` with a wall-clock deadline
  (`ASUS_DISPLAY_MODE_WD_RELEASE_SECS`, default **10**, digits-only positive) and
  force-releases Super when the flock stays busy past that deadline. Start `ydotool` with
  `env XDG_RUNTIME_DIR=… DBUS_SESSION_BUS_ADDRESS=…` under `_run_as_user`
  (bare `VAR=value` is treated as the command by `runuser`). Override with
  `ASUS_DISPLAY_MODE_STATE_PREFIX` in tests. Ydotool socket discovery uses the
  active user’s `$DBUS_BUS_ROOT/$uid/.ydotool_socket` and `/run/ydotoold/socket`
  only (no `/tmp/.ydotool_socket`, no `/run/user/*` glob).
  Internal args (`--internal-watchdog`, `--cancel-osd`) must short-circuit in
  `main` via an explicit `case` (capture status, then `return "$status"`)—never
  `if _handle_internal_mode; then return $?; fi`, which drops watchdog failures
  into normal display switching. Watchdog setsid re-exec must use
  `_ASUS_DISPLAY_MODE_ENTRY` (set by `bin/asus-display-mode.sh` after sourcing
  libs)—never `BASH_SOURCE[0]` from `lib/asus-display-watchdog.sh` (that path
  has no `--internal-watchdog` handler and leaves sticky Super without a
  watchdog). `NOTIF_ID_ROOT` expansions must use
  `${NOTIF_ID_ROOT:-/run/asus-zenbook-notif}` under `set -u`.
  Display sticky OSD kcov: `disp_source_entry` / `disp_source_session` /
  `disp_source_backend` (`ASUS_KCOV_DISPLAY_SLICE=entry|session|backend`) split so
  each stays ≤45s after the state/watchdog/osd lib split—never one combined
  `disp_source_helpers` run that times out at 45s. Entry covers
  `bin/asus-display-mode.sh` bootstrap/main/lock paths; session covers watchdog +
  state; backend covers OSD/Mutter/settings. Prefer same-shell calls (not
  `_exercise` subshells) for product lines under kcov — nested `_exercise` often
  drops attribution; put critical same-shell work early in each slice. Do not call
  blocking `_run_internal_watchdog` under kcov;
  stub `gdbus` fail-fast in the backend slice (listening-but-dead AF_UNIX hangs).
  `_ensure_watchdog` RETURN traps must expand `lock_dir` when armed (not deferred
  `"$lock_dir"` under `set -u`). Disable switches:
  `ASUS_DISPLAY_MODE_DISABLE_YDOTOOL`, `_XDOTOOL`, `_MUTTER_CYCLE`, `_SETTINGS`.
- **Screenshot / Share**: `bin/asus-screenshot.sh` tries GNOME Shell D-Bus
  (`ShowScreenshotUI`, then `InteractiveScreenshot`), then Super+Shift+S /
  Print via `ydotool`/`xdotool`. After a successful keychord, do **not** call
  `ShowScreenshotUI` again to “confirm” — that queues a second selector so Esc
  dismisses one and the next reappears (seen on touchpad Share when D-Bus fails
  and the helper falls back to ydotool). Honor env `YDOTOOL_SOCKET` only when the
  socket path is under `${RUN_USER_ROOT}/$target_uid/` (or
  `ASUS_YDOTOOL_SOCKET_ALLOW=1` with `ASUS_TEST_MODE=1` for tests). Portal runs once in the top-level fallback
  path (`_try_fallback_screenshots`), not inside the GNOME family helper, and
  is capped with `timeout` via shared `_screenshot_timeout_secs` (positive-int,
  default **8**; `ASUS_PORTAL_SCREENSHOT_TIMEOUT_SECS` /
  `ASUS_GNOME_SCREENSHOT_TIMEOUT_SECS`) so a listening-but-dead bus cannot hang
  helpers. Family helpers: Spectacle (KDE), `xfce4-screenshooter -r` (XFCE),
  `screengrab -r` (LXQt; include `lxqt` in the fallback loop after xfce).
  Spectacle/XFCE/LXQt (`screengrab -r`) launch stubs
  in unit tests must stay alive briefly past `ASUS_LAUNCH_CHECK_SECS`.
  On GNOME it soft-ensures
  `show-screenshot-ui` includes `<Super><Shift>s` so Fn+F11 / touchpad Share
  work even when the DESKTOP component was not installed (Ubuntu defaults to
  Print only; InteractiveScreenshot is AccessDenied for peers on 26.04+).
  Run `_ensure_gnome_share_keybinding` only when the session’s primary desktop
  family is GNOME (not when GNOME is tried as a fallback in `_try_fallback_screenshots`).
  Before merge/set, if `${STATE_DIR}/$uid/orig_show_screenshot_ui` is absent and
  `gsettings get` returns a non-empty value, write that backup (uninstall restores
  it). Backup mkdir/write failures must fail closed; skip `gsettings set` when the
  backup cannot be persisted. Skip set on empty/malformed get; propagate
  `gsettings set` failures.
  InteractiveScreenshot gdbus stderr is kept (stdout still discarded) so failure
  text reaches the helper process for diagnostics.
  `deploy_touchpad_component` uses strict systemd
  verification (`_install_unit` … strict) and reports active vs failed like WMI.
 `asus_touchpad_share.py` preserves `curr_x`/`curr_y` on touch-down so corner
 gestures keep the last ABS position. Learned Share bounds live in
 `asus_touchpad_share_bounds.py` (public `compute_bounds` / `record_successful_tap`,
 `is_corner_gesture`; seed fractions, percentile recompute, JSON persistence).
 Share accepts only when both touch-down
 and touch-up stay inside the active corner bounds (not start-outside/end-inside
 drifts). Touch lifecycle uses **`BTN_TOUCH` only**
  (not `BTN_TOOL_FINGER`) so finger-count transitions cannot complete a gesture.
  Track contacts with an `ABS_MT_SLOT` → tracking-id map (`ABS_MT_TRACKING_ID`);
  `-1` removes that slot’s id (do not arbitrary-pop). `get_abs_axis` catches
 `KeyError` and `OSError` around `absinfo` so startup keeps default bounds.
 Share corner bounds seed from conservative fractions, then learn tighter
 normalized fractions from successful taps; persist to
 `/var/lib/asus-zenbook-linux-tools/touchpad-share-bounds.json` **only when**
 `learned_x_fraction` / `learned_y_fraction` change (sample-only updates stay
 in memory). Write failures log once per state path; in-memory learning continues
 when the default directory is not writable. Malformed state
 falls back to seeds, learning waits for enough samples, and learned fractions
 are clamped so they never expand beyond the seed region.
 Share state flow:

 ```mermaid
 flowchart TD
     startup[ServiceStartup] --> loadState[LoadSavedState]
     loadState --> validState{StateValid}
     validState -->|yes| activeBounds[UseLearnedBounds]
     validState -->|no| seedBounds[UseSeedBounds]
     activeBounds --> readEvents[ReadTouchEvents]
     seedBounds --> readEvents
     readEvents --> accepted{GestureAccepted}
     accepted -->|no| readEvents
     accepted -->|yes| sampleTap[NormalizeTapSample]
     sampleTap --> updateSamples[AppendBoundedSampleHistory]
     updateSamples --> enoughSamples{EnoughSamples}
     enoughSamples -->|no| readEvents
     enoughSamples -->|yes| recompute[PercentileRecomputeAndClamp]
     recompute --> fractionsChanged{FractionsChanged}
     fractionsChanged -->|yes| saveState[AtomicSaveState]
     fractionsChanged -->|no| readEvents
     saveState --> readEvents
 ```

 Cancel the Share gesture as
  soon as a second contact appears so two-finger taps cannot call
  `trigger_screenshot`.
  `trigger_screenshot` launches
  `asus-screenshot.sh` via `subprocess.Popen` and reaps the child on a daemon
  thread so the touch event loop is not blocked.
  `bin/asus-screenpad-toggle.sh` notifies with
  UX582HS keycap glyphs from `assets/icons/asus-screenpad-*-symbolic.svg`. At notify
  time it reads GNOME Shell `.message .message-header` color (emitting app-name /
  `message-source-title` inherits this) via shared `lib/asus-notif-icons.sh`, tints a
  copy under `NOTIF_ID_ROOT/<uid>/asus-screenpad-{on,off}.svg`, and passes that
  **file path** to Notify so the glyph is not recolored like a `*-symbolic` theme icon.
  Override color with `ASUS_NOTIF_APP_NAME_COLOR` / `ASUS_SCREENPAD_APP_NAME_COLOR`;
  override template discovery with `ASUS_SCREENPAD_ICON_DIR`. Valid notification
  tint colors are `#` plus hex lengths **3/4/6/8** only (`_is_valid_notif_color`);
  SVG tint writes atomically via temp+`mv`. Non-positive ScreenPad max brightness
  reports fraction `0.0000`; tinted ScreenPad icons must resolve to an existing
  file or theme glyph, else `video-joined-displays`. Equal-width panels; Off
  adds the slash through ScreenPad. Install deploys templates under
  `/usr/local/share/icons/hicolor/scalable/apps/` (and a share copy). Runtime
  ScreenPad icon discovery uses `/usr/local/share` when `PREFIX` is unset, else
  `${PREFIX%/}/usr/local/share` (same root as `deploy_wmi_component`). Fallback theme
  name `video-joined-displays` when templates are missing.
  Shared ScreenPad sysfs helpers live in `lib/asus-screenpad.sh` (toggle + brightness).
  Keep `ASUS_WINDOW_SWAP_EXT_UUID` with top-level constants near `SYS_CLASS_ROOT`
  (not buried beside OSD helpers).
  `_clamp_screenpad_brightness` must validate `value` and `max_val` with the same
  `^[0-9]+$` regex as `_read_screenpad_value` before numeric comparisons (non-matches
  become `0`). `_screenpad_read_notif_context` requires a plain `unix:path=/…` bus address (reject
  abstract sockets and `,guid=` / other suffixes) before deriving `bus_root`; fail closed
  otherwise. After writing ScreenPad brightness (toggle On/Off or brightness helper), read the
  node back and fail closed when the value does not match before sending user
  notifications (same pattern as camera toggle).
  `bin/asus-screenpad-brightness.sh` supports `up`/`down`/`set`/`get`; steps ~10% of
  `max_brightness`, clamps to `[1, max]` (Off stays on the toggle). Normalize
  `max_val=$((10#$max_val))` once at the start of `_parse_screenpad_set_value`. In
  `main`, a missing `set` argument prints usage before
  `_require_writable_screenpad_node`. Mutating `up`/`down`/`set`
  require a writable ScreenPad node; `get` only requires the node to exist (readable).
  On UX582HS,
  Fn brightness arrives on `"Asus WMI hotkeys"`, `"Video Bus"`, and sometimes AT
  as `KEY_BRIGHTNESSUP`/`DOWN`. Shift lives on i2c `"ASUE* Keyboard"` and/or AT;
  the daemon watches non-AT ASUE devices (no grab), tracks AT Shift in the AT
  proxy, exclusive-grabs Video Bus (+ WMI), and filters AT brightness the same
  way. Swallow only when Shift is held **and** `screenpad_brightness_ready`
  (helper exists + writable `ASUS_SCREENPAD_NODE` / `asus_screenpad` /
  `asus::screenpad` under `SYS_CLASS_ROOT`); otherwise forward main brightness.
  ~80 ms helper debounce; ~80 ms cross-source dedupe (AT key-down shares
  `_brightness_event_is_duplicate` with Video Bus / WMI). **Do not bind Alt**: ASUS
  layouts put brightness on F4/F5 (Alt+F4 collision). After a successful write,
  feedback order in `_notify_screenpad_brightness`: GNOME extension
  `ShowOsd(icon, level)` (`showOne(screenpad)` on GNOME 49+ when available —
  resolve `DP-3` via `get_monitor_for_connector`, else ScreenPad WxH geometry
  `3840x1100` / logical `1920x550`, else primary when ScreenPad is off; else
  `showAll`, else legacy `show(screenpad|primary, …)` on ≤48) → Plasma
  `org.kde.osdService.brightnessChanged(percent)` or
  `showProgress` with bare decimal GVariant args (no `int32:` prefixes) →
  LXQt Spec **`value`**-hint Notify via `lxqt-notificationd`
  (`_try_show_screenpad_lxqt_osd`; **no** public display-only LXQt OSD D-Bus —
  panel volume/backlight plugins are private; do not invent fragile APIs) →
  Cinnamon `org.Cinnamon.ShowOSD` on `/org/Cinnamon` (`a{sv}` with `icon` +
  `level` int32 0–100) → MATE Spec value-hint Notify
  (`_try_show_screenpad_mate_osd`; **no** public ShowOSD —
  `org.mate.SettingsDaemon.MediaKeys` is Grab/Release only;
  mate-power-manager brightness popup is private; never call
  `org.mate.PowerManager.Backlight.SetBrightness` for ScreenPad feedback —
  that mutates the main LCD) → replace-in-place notify
  (`screenpad-brightness` tag; XFCE and other DE stand-in). Never notify when a
  prior OSD path succeeded. ShowOsd gdbus must use
  `--dest org.gnome.Shell` (not `org.gnome.Shell.Extensions`) with object path
  `/org/gnome/Shell/Extensions/AsusWindowSwap`. On ShowOsd miss, brightness:
  (1) clears `org.gnome.shell disable-user-extensions` to `false` (global kill
  switch → UUID “enabled” but INACTIVE, no D-Bus → notify-only regression),
  (2) runs `gnome-extensions enable` for `asus-window-swap@…`,
  (3) retries ShowOsd briefly, then Plasma/LXQt/Cinnamon/MATE/notify fallback.
  Priming is best-effort (`_prime… || true`) so enable failures still retry
  ShowOsd — do **not** `|| return 1` after prime (that skipped retries and left
  notify-only under transient CLI errors). Shell and Plasma/Cinnamon
  `gdbus` OSD calls are wrapped with `timeout` via shared `_screenpad_osd_timeout_secs`
  (`ASUS_SCREENPAD_OSD_TIMEOUT_SECS`, default **2**, digits-only positive).
  After a ShowOsd miss + enable, `_retry_screenpad_shell_show_osd` sleeps only
  between attempts (not before the first), caps each retry call at **1s**, and
  uses **3** attempts so enable+OSD stays under the hotkey helper's 5s exec budget —
  do **not** expand to 5× long retries (helper `_exec_script` timeout is 5s and
  SIGTERM leaves notify-only). Do **not** call private `org.gnome.Shell.ShowOSD`.
  Id files use write-then-rename (and flock when available) under `NOTIF_ID_ROOT`.
  GNOME OSD needs the DESKTOP extension (logout once on Wayland for new JS).
  Display Toggle sticky OSD still needs `ydotool`. AT Super+P filtering lives in
  `asus_hotkey_daemon_at_proxy.py`; brightness chords in
  `asus_hotkey_daemon_brightness.py` (`try_handle_at_brightness_event`).
  `asus-touchpad-share.service` and
  `asus-hotkey-daemon.service` must keep `ProtectSystem=no` and must not set
  `NoNewPrivileges=yes`. Set `RuntimeDirectoryPreserve=yes` on both units so
  notification runtime state survives restarts alongside
  `RuntimeDirectory=asus-zenbook-notif`.

- **Session bus root precedence**: Resolve D-Bus socket roots as
  `BUS_ROOT` → `DBUS_BUS_ROOT` → `RUN_USER_ROOT` → `/run/user` (GNOME/XFCE/KDE/LXQt
  install helpers, `_enable_ydotool_user_unit`, and restore paths). Product code
  uses `_resolve_session_bus_root` in `lib/asus-common.sh` (session helpers prefer
  that when loaded; do **not** source `install-shared.sh` from product session).
  Installer code resolves this via `_install_resolve_session_bus_root` in
  `lib/install-shared.sh`.
  `_enable_ydotool_user_unit` fails closed when the session runtime dir or bus
  socket is absent (no silent success). `_enable_ydotoold_if_available` must treat
  that user-unit failure as best-effort so missing session prerequisites do not
  abort `install.sh`. Consumers of `_resolve_user_bus_info`
  must use `cut -d: -f3-` so paths with colons stay intact.
- **Session env as root**: `systemctl --user show-environment` lookups must set
  `XDG_RUNTIME_DIR` to `$runtime_root/<uid>` where `runtime_root` is resolved as
  `BUS_ROOT` → `DBUS_BUS_ROOT` → `RUN_USER_ROOT` → `/run/user` (same precedence as
  session helpers). Hard-coding only `/run/user/<uid>` skips override roots and can
  make desktop-family detection return `other` when GDM session Leader environ is
  empty. Settings / screenshot then skip GNOME paths or launch
  `gnome-control-center` without `XDG_CURRENT_DESKTOP`.
- **Window swap**: Monitor swap is split across `asus_hotkey_daemon_topology.py`,
  `asus_hotkey_daemon_window_swap_gnome.py`, and `asus_hotkey_daemon_window_swap.py`;
  `asus_hotkey_daemon_monitor.py` re-exports public APIs and `_thread_factory` for tests.
  Prefer Mutter topology, else `xrandr` (`asus_hotkey_daemon_xrandr.py` parses
  signed WxH±X±Y tokens); on GNOME emit Super+Shift+Arrow
  via uinput. On KDE/XFCE/LXQt/Cinnamon/MATE move via `wmctrl`/`xdotool` to the target monitor
  origin or a
  geometric neighbor; if both fail, return false (do **not** fall back to generic
  uinput chords on those families). **Locked for LXQt/Cinnamon/MATE:** do **not** port the GNOME
  Shell Window Swap extension — wmctrl→xdotool only. `desktop_family_hint()` reads
  `XDG_CURRENT_DESKTOP` from the cached desktop-session env first (systemd units
  often lack that key in the daemon process environ). Build the directional
  neighbor graph once per `_swap_direction_for_monitors` call and reuse it for
  cycle order and direction keys. Fail closed (no fake chord) when topology
  cache is empty. Once Mutter logical geometry is cached, do **not** replace it
  with xrandr physical pixels (signature churn rewinds the bounce step). Only
  reset the bounce step when the monitor *count* changes—same-count refreshes
  must keep the phase so the window is not stranded on the last display for
  Down no-ops. Before each hop on GNOME, prefer the Asus Window Swap Shell
  extension (`GetFocusedMonitor` / `MoveFocused`); when MoveFocused returns false for
  both planned and opposite directions, fall back to uinput Super+Shift+Arrow on the
  same press. When D-Bus is missing (`MoveFocused` unavailable), call
  `prime_gnome_window_swap_extension()` (session `gnome-extensions enable`) and
  retry before uinput. Topology-map monitors carry Mutter `index` (from
  `detect_topology_map`) for focus alignment — map Meta monitor index to list
  index via `_list_index_for_mutter_index`, do not assume enumerate order equals
  `win.get_monitor()` without the field.
  Do not use the pointer as a focus proxy for keyboard hotkeys (pointer often
  stays on the main display). Topology-map mode resolution must treat newer Mutter
  logical-monitor entries shaped as connector *specs*
  `(connector, vendor, product, serial)` by falling back to the connector's
  `is-current` physical mode — never treat vendor tokens like `BOE`/`SDC` as
  mode ids (that forced both displays to the ScreenPad default 550px height and
  broke last-monitor hit testing). `_looks_like_mode_id` requires numeric
  `WIDTHxHEIGHT` or `WIDTHxHEIGHT@Hz` (`re.fullmatch`), not merely “contains a digit”.
  Bounce along the stable cycle order with adjacent hops only.
  Unit tests that call `perform_window_swap` must patch external move boundaries
  (`_move_window_via_wmctrl` / `_move_window_via_xdotool` via
  `window_swap_monitor_patches`) and seed `LAST_*` topology cache state so host
  `xdotool`/`wmctrl` cannot move the IDE window.
- **Display Toggle hardware gap**: On ZenBook, Display Toggle often emits only a
  ~30ms firmware `Super+P` on the AT keyboard (WMI `0x38` may be absent). Quick
  `Super+P` makes Mutter hard-cycle with no OSD. The daemon must exclusive-grab the
  AT keyboard, proxy normal keys via uinput, swallow firmware-fast Super+P chords,
  and dispatch `asus-display-mode.sh`. Human held-Super+P is forwarded. In
  `_buffer_or_flush_non_meta`, arm `saw_p` only on KEY_P **key-down**
  (`event.value == 1`); KEY_P **releases must stay buffered** until Meta-up—
  flushing on release forwards the chord to Mutter and hard-cycles without the
  sticky OSD. Never map AT scancode `0x38` (Left Alt) through the WMI table.
  WMI `0x6B` / `KEY_TOUCHPAD_TOGGLE` stays unmapped and is forwarded via uinput
  for native toggle on all desktops.
- **Control center runtime root**: use `RUN_USER_ROOT` for both the D-Bus socket path and
  `XDG_RUNTIME_DIR` (same name as `lib/asus-common.sh`). Inject session
  `DISPLAY`/`WAYLAND_DISPLAY`/`XDG_CURRENT_DESKTOP` when launching Settings.
- **Hotkey / touchpad systemd hardening**: `asus-hotkey-daemon.service` and
  `asus-touchpad-share.service` must keep `ProtectSystem=no` (not `strict`/`full`)
  and must not set `NoNewPrivileges=yes`. `ProtectSystem=strict` remounts `/run`
  and `/tmp` read-only and, with `NoNewPrivileges`, breaks `runuser` (`pam_keyinit`),
  which fan/camera notifications, Settings/Share helpers, and Mutter topology need.
  Keep `ProtectHome=read-only` plus `RuntimeDirectory=asus-zenbook-notif` for
  replaceable notification IDs outside `/run/user` (hotkey and touchpad units share
  this runtime directory name; do not relocate touchpad state under `/run/user`).
  Helper dispatch logging uses shared `log_script_dispatch_outcome` next to
  `run_script_if_exists` in `bin/asus_hotkey_daemon_runtime.py` (do not duplicate
  in brightness/at_proxy/input). `_exec_script` must redirect
  `stdin`/`stdout`/`stderr` to `DEVNULL` (same isolation as cancel-osd workers).
  Document the shared runtime directory in both unit files, naming the peer unit.
  The touchpad unit must set `RuntimeDirectoryPreserve=yes` so that runtime dir
  survives service restarts. Do **not** add `Wants=`/`After=systemd-udev-settle.service`
  on touchpad or hotkey units (evdev nodes appear without blocking on udev settle).
  Hotkey and touchpad units add `ProtectKernelModules=yes`, `ProtectKernelLogs=yes`,
  `RestrictNamespaces=yes`, and `RestrictSUIDSGID=yes` alongside the relaxed paths above.
  Both hotkey and touchpad units must set `StartLimitIntervalSec=60` with
  `StartLimitBurst=10` so crash loops are bounded while
  still allowing brief `/dev/input` gaps. When the WMI hotkey device
  disappears (`OSError` on read), the event loop must exit (`SystemExit`) so
  systemd `Restart=always` can recover—do not continue select with a missing WMI fd.
  When the AT keyboard fd fails, `_mark_fd_gone` ungrabs/closes the physical kb and
  keyboard uinput proxy before cleanup and clears buffered Super+P / brightness
  modifier chord state; log AT `InputDevice` open failures.
  When the WMI fd fails, set `loop_state.wmi_fd = None` alongside `wmi_gone` so a
  recycled descriptor cannot be treated as the WMI device.
  `_dispatch_ready_fd` uses `dev_map.get(fd)` and returns when the fd is gone.
  Catch `BlockingIOError` separately and return without `_mark_fd_gone` (spurious
  readiness); retain `OSError` → `_mark_fd_gone` for genuine device loss.
  `close_input_device` / `_close_runtime_devices` tolerate `None` and second `close()`.
  Desktop `runuser`/`sudo -u` command builders must include `--` after the username
  so command tokens beginning with `-` are not treated as options.
  `asus_hotkey_daemon.py` must load `shared_imports.py` from `SCRIPT_DIR` first
  (install copies it to `/usr/local/bin/`), then the checkout repo root—never assume
  `dirname(bin) / shared_imports.py` alone (`/usr/local/shared_imports.py` does not exist).
  Register the loaded module in `sys.modules["shared_imports"]` before `exec_module`
  so reloads and nested imports share one instance. On `exec_module` failure,
  restore any prior `sys.modules["shared_imports"]` entry (or `pop` only when none
  existed) so a partial module is never left registered. The thin CLI shim must
  `raise SystemExit(_impl_module.main())` under `__main__`.
- **Hotkey daemon desktop-user cache**: `run_in_desktop_session` / `desktop_family_hint`
  are the public runtime APIs (`_*` aliases remain for tests). Implementation is split:
  `asus_hotkey_daemon_session.py` (desktop-user + systemctl env),
  `asus_hotkey_daemon_topology_detect.py` (Mutter/xrandr topology detect),
  `asus_hotkey_daemon_desktop_family.py` (Mint heuristics + `desktop_family_hint`);
  `asus_hotkey_daemon_runtime.py` keeps script debounce/exec and re-exports session/topology/family
  symbols via `__getattr__` so existing `patch("asus_hotkey_daemon_runtime.…")` paths keep working.
  `run_in_desktop_session` caches `(uid, username, session_id, expires_at, validated_until)`
  in `asus_hotkey_daemon_state` for ~2s with a session-env dict. Unit tests that only
  assert runuser vs sudo command construction must stub `_resolve_desktop_user` and
  `_session_env_for_sudo` (plus `shutil.which`) — do not rely on multi-call loginctl
  sequencing under load (cache-without-DISPLAY races made rocky:10 flake). Keep
  resolve / systemctl-env / display-refresh coverage in
  `tests/unit/bin/test_asus_hotkey_daemon_session_env.py`. `_is_active_gui_session`
  runs at most once per TTL via `validated_until` (skip while still current; refresh
  after a successful probe). Reserve a bounded budget
  (`_desktop_session_resolve_budget_secs`, ≤5s) for `_resolve_desktop_user` /
  `_detect_desktop_user` / `_session_env_for_sudo`; stop iterating loginctl sessions
  once that deadline has passed; pass the **full** caller timeout into `_run_command` for
  the actual command (do not feed leftover resolve-deadline crumbs). `_run_command`
  must pass `stdin=subprocess.DEVNULL` (same isolation as helper script exec). Re-detect only
  after expiry, when `_is_active_gui_session` no longer validates the cached session,
  or when the cached env lacks `DISPLAY`/`WAYLAND_DISPLAY` (GDM Leader environ is
  often empty at first probe). Script debounce uses `claim_script_slot` under
  `_LAST_SCRIPT_TIMES_LOCK` (atomic check+set); `_is_debounced` is `not claim`.
  `get_script_map` / `get_code_script_map` return dict copies (callers must not mutate
  the module maps). Fill missing
  display keys via `systemctl --user show-environment` under `runuser` (negative-cache transport
  failures like the shell helpers). `_user_from_gui_session` reads loginctl `Name` and `User`
  in one `show-session` call. `_systemctl_env_timeout_secs()` caps at **5.0** seconds.
  `_cached_systemctl_env_blob` returns `(need_fetch, blob)`;
  `blob_valid` tracks empty stdout. The runtime blob cache TTL matches
  `get_desktop_user_cache_seconds()` with expiry stored on write; failed fetches call
  `_mark_systemctl_env_skip()` then return `None`. Before the event loop,
  call `prime_desktop_user_cache()` **then** `prime_gnome_window_swap_extension()` (runs
  `gnome-extensions enable asus-window-swap@ventura8.github.com` when the UUID is in
  gsettings but Shell has not exported `/org/gnome/Shell/Extensions/AsusWindowSwap` yet),
  **then** `prime_topology_cache()` (session
  env must exist for Mutter topology at startup). Also call
  `prime_gnome_window_swap_extension()` from `prime_topology_cache()` and before
  cached/deferred window-swap moves when D-Bus is still absent. Firmware Super+P buffering is
  documented under Display Toggle hardware gap above.
  Clear via `clear_desktop_user_cache()` in test resets. Topology map detection is public as
  `detect_swap_topology_map` (not `_detect_swap_topology_map`).
  Swap topology fields (`signature`, `monitors`, `refresh`, `refreshed_live`, `source`)
  live in one locked dict in `asus_hotkey_daemon_state` with accessors
  (`get_`/`set_last_known_monitors`, `apply_detected_topology`, `clear_swap_topology_cache`,
  …). `prime_topology_cache()` must **synchronously** seed that monitor cache before
  the event loop (async-only priming made the first window-swap presses no-ops).
  Fall back to async refresh only when the sync probe returns empty.
  Window-swap D-Bus readiness caches **True** for `_WINDOW_SWAP_DBUS_READY_TTL_SECS=30`
  and **False** for `_WINDOW_SWAP_DBUS_NOT_READY_TTL_SECS=0.5` via
  `_gnome_window_swap_dbus_ready_ttl` — do **not** cache misses for the positive
  TTL (that forced every Fn press onto the deferred worker for ~30s). Prime
  deadline is `_WINDOW_SWAP_PRIME_DEADLINE_SECS=2` (not 5); `_wait_gnome_window_swap_dbus_ready`
  polls with `attempts=1` until ready or that deadline and returns bool.
  `_enable_gnome_window_swap_via_cli` clears `disable-user-extensions`, runs
  `gnome-extensions enable` with a short timeout, and **honors exit status**
  (do not treat enable as success after OSError-only catch). When
  `_run_cached_window_swap` defers, it **must pass already-usable monitors** into
  `_start_deferred_window_swap_worker(ui, step, monitors)` so the worker skips
  Mutter `detect_swap_topology_map` (re-detect + long prime made hops take tens
  of seconds). Deferred worker uses `_monitors_for_deferred_swap` then
  `attempts=1` for focus/`MoveFocused` so a missing D-Bus object falls through to
  uinput quickly — do **not** use default attempts=3 on the deferred path.
- **Window-swap topology**: never call blocking `detect_swap_topology_map` on the hotkey event
  thread. Schedule async refresh into the locked monitor cache and resolve swap direction from cache.
  `_schedule_topology_refresh` must call `_remember_topology_refresh(now)` after setting
  `in_flight` and **before** `worker.start()` (keep `RuntimeError` cleanup that clears
  `in_flight`). xrandr topology dicts from `split_xrandr_geometry` include `"scale": 1.0`;
  `parse_xrandr_topology_output` assigns `"index"` for Mutter parity.
  `_usable_monitors_for_swap` relies on `_refresh_monitors` only (no duplicate refresh schedule);
  cache reads are unsynchronized with async workers. `_emit_window_move` catches `OSError`, logs,
  and returns false. Treat fewer than two monitors as unavailable (do not fake `KEY_DOWN`). When the
  cache is empty or single-monitor, schedule async refresh and start a deferred
  detect+swap worker (topology detect runs off the event thread) so the first Fn
  press still moves the window; the worker commits `next_step` for the following
  press. While a swap/detect is in flight, coalesce later presses into one
  `pending` request and drain it from `_clear_window_swap_in_flight` (do not drop
  presses). `_take_pending_window_swap` pops pending and, when the queue is empty and
  no deferred worker owns the slot (`deferred_active`), clears `in_flight` under the
  same `_WINDOW_SWAP_LOCK` acquisition so a press cannot queue between unlock and
  clear. `_drain_pending_swap` must call that helper (single take implementation).
  When drain starts a deferred worker, leave `in_flight` for the worker’s completion path.
  `_start_deferred_window_swap_worker` must set `deferred_active=True` under the lock
  **before** `worker.start()` so a fast-completing worker cannot have its cleanup
  overwritten; on `RuntimeError` from `start()`, clear `deferred_active` and in-flight.
  Advance the bounce step only after a successful move. When topology
  is already cached **and** (on GNOME) the Window Swap extension D-Bus API is
  already ready, apply the hop synchronously so the first Fn press moves
  immediately. Sync event-thread gdbus hops (`_run_cached_window_swap`) and
  deferred hops both pass `attempts=1` through the Mutter window-swap call chain
  (do not use attempts=3 on deferred — multi-second stacks when D-Bus is absent).
  KDE/XFCE/LXQt cached hops must **not** run
  `wmctrl`/`xdotool` on the event thread — `_run_cached_window_swap` defers them
  via `_start_deferred_window_swap_worker` (pass monitors when usable). Event-path
  readiness uses a short-lived cache only (`_gnome_window_swap_dbus_ready_fast`);
  on cache miss return not-ready (no sync gdbus probe on the event thread) and defer.
  Keep retrying `_wait_gnome_window_swap_dbus_ready` /
  `_gnome_window_swap_dbus_ready` for worker threads only. Never call
  `prime_gnome_window_swap_extension()` (or other
  blocking enable/wait paths) on the hotkey event thread — if the extension is
  not ready, dispatch via `_start_deferred_window_swap_worker` (worker primes,
  then moves). Sync `prime_topology_cache` must run **after** `prime_desktop_user_cache`
  so Mutter D-Bus detect has session env at startup (retry once if the first
  probe is empty). Offload cold-cache detect+swap onto a deferred worker
  thread; keep `swap_step` mutations on the event thread via committed steps.
  If `worker.start()` fails, clear the in-flight flag under the
  lock before returning.
- **Kcov temp cleanup**: `step_kcov_coverage` must save/restore the caller's EXIT trap around its
  local temp-root cleanup. On EXIT, chain the prior handler via `_KCOV_SAVED_EXIT_BODY`
  (eval the body only); explicit `_teardown_kcov_temp_root` restores with the full
  `_KCOV_SAVED_EXIT_TRAP` from `trap -p`. Install helper scenarios register
  `trap 'rm -rf "$tmp"' EXIT` inside
  subshells immediately after `mktemp -d`. Coverage drivers that tee under
  `reports/distro-logs/` must resolve the log dir via `resolve_reports_root`
  (sound/uninstall helpers and `run_distro_install_smoke.sh`); display helpers keep cleanup on
  RETURN traps only
  (do not clear the trap early and duplicate cleanup). `_copy_kcov_report` also
  mirrors per-scenario logs into `reports/distro-logs/kcov-scenarios/` so CI can
  upload them on coverage-gate failure (not only the interleaved tee log). Shell
  coverage success text must use the configured
  `min_percent` (`KCOV_MIN_PERCENT`, default 90; clamped so values below 90 become 90),
  not a hardcoded `90%`. Coverage drivers must not
  use blanket `set +e`; assert expected negatives explicitly and fail closed on unexpected errors.
  Prefer `_soft_expect` for product calls with allowed statuses; keep `_soft` for cleanup only.
  Concurrent `run-lints.sh` ShellCheck system stubs under `/usr/local/lib/asus-zenbook-linux-tools`
  must serialize install/cleanup with `flock` on a shared `/tmp/asus-zenbook-shellcheck-lib.lock`
  (stable inode across checkouts; do not `rm` the lock after release).
  Install/uninstall kcov mocks must use `_make_fake_loginctl_current_user`
  (real passwd username + username-aware `id` stub)—never `ghost_user` plus
  `id` echoing only a UID, or GNOME `_install_run_as_user` fails closed with
  `Unknown target user`. Coverage drivers that call gettext-backed install
  helpers must source `lib/asus-i18n.sh` after `install-shared.sh`. Snippets
  passed to `_expect_bash_snippet_failure` must `export` overrides before
  `source`/`check_root` (prefix assigns apply only to the next simple command).
- **Real-system E2E guards**: Mock timeout helpers must not auto-promote to the 300s budget from
  `E2E_REAL_ALLOW_SYSTEM_CHANGES` alone—pass `allow_real=True` **and** require that env flag for the
  300s ceiling. Real install tests
  preflight a clean host, register cleanup only after that, and uninstall with `SKIP_PKG_REMOVE=1`.
  Destructive real uninstall also requires `E2E_REAL_ALLOW_DESTRUCTIVE_UNINSTALL=1` plus a
  test-owned sentinel under state. Driver traps: EXIT preserves `$?`; INT/TERM force nonzero
  cleanup (see Test Suite Structure / `run_real_e2e.sh`).
- **Shell complexity (`|| true`)**: `tools/shell_complexity.py` counts every `&&`/`||`. Unterminated heredocs,
  unmatched function braces, and paths outside the repository root are **hard failures** (exit 1 even with
  `--no-enforce`). The sanitizer skips bash `<<<` here-strings (not heredocs). `_collect_line_heredocs`
  is quote- and comment-aware: scan-only `_skip_quoted_span` skips quoted spans, collection stops at a
  comment, and only unquoted non-comment `<<` positions enqueue; the opener line is preserved for CCN.
  Prefer a
  shared `_soft() { "$@" || return 0; }` for best-effort side effects under `set -e` instead of
  sprinkling `|| true`. Keep `${#var}` length expansions — the sanitizer must not treat `${#` as a
  comment (regression covered in `tests/unit/tools/test_shell_complexity.py`).
  Every function in product shell (`bin/*.sh`, `lib/*.sh`, `install.sh`, `uninstall.sh`) **and**
  kcov coverage drivers (`scripts/coverage/drivers/*.sh`, including `<main>`) must remain
  A-grade (CCN ≤5). Drivers should use `_soft` (from `scripts/coverage/common.sh`) and
  `_restore_or_unset` (from `kcov_driver_common.sh`) instead of `cmd || true` / restore if-else
  blocks. When an EXIT trap cleans a `local` temp dir, expand the path at registration
  (`trap 'rm -rf "'"$tmp"'"' EXIT`) — a deferred `"$tmp"` under `set -u` fails after the
  function returns (scenario exit 1). `display_helpers.sh` sources sibling
  `display_helpers_watchdog.sh` and
  `display_helpers_backend.sh` to stay under the 600-line cap. Systemd unit lifecycle helpers
  used by `install-components.sh` live in
  `lib/install-components-units.sh`; keep that sibling source wired when changing component activation.
