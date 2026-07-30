---
name: code-linter
description: Run ruff, pylint, yamllint, markdownlint, eslint, and shellcheck over repository files.
---

# Code Linter Skill

Use this skill to lint all Python scripts, shell scripts, GNOME extension JavaScript,
Markdown files, and YAML workflows without using suppression comments or inline ignores.

## Instructions

1. **Live Output & Persistent Logs**:

   ```bash
   set -euo pipefail
   mkdir -p reports/distro-logs
   ./scripts/run-lints.sh 2>&1 | tee reports/distro-logs/lints.log
   exit "${PIPESTATUS[0]}"
   ```

   Always run lint commands so users can watch live CLI output, and always save logs under `reports/distro-logs/`.

1. **Auto-fix First, Then Re-lint**:

   Before hand-editing lint failures, always run automatic formatters / delinters with safe autofix, then
   re-run the linters and only manually fix what remains. Do not rewrite autofixable issues by hand.

   Check `find` exit status **before** `mapfile` (process substitution hides find failures). Shared helper
   and prune set for repo-wide discovery:

   ```bash
   # Prune: .git, .venv*, .pytest_cache, .ruff_cache, .cache, node_modules, .tools, reports
   _mapfile_null_find() {
       local -n __arr=$1
       shift
       local __tmp __st=0
       __tmp=$(mktemp) || return 1
       find "$@" >"$__tmp" || __st=$?
       if [ "$__st" -ne 0 ]; then
           rm -f "$__tmp"
           return "$__st"
       fi
       mapfile -d '' -t __arr <"$__tmp"
       __st=$?
       rm -f "$__tmp"
       return "$__st"
   }

   _repo_prune_find0() {
       # usage: _repo_prune_find0 ARRAY_NAME <find -type/-name/-print0 args after prunes>
       local __name=$1
       shift
       _mapfile_null_find "$__name" . \
           -path './.git' -prune -o \
           -path './.venv*' -prune -o \
           -path './.pytest_cache' -prune -o \
           -path './.ruff_cache' -prune -o \
           -path './.cache' -prune -o \
           -path './node_modules' -prune -o \
           -path './.tools' -prune -o \
           -path './reports' -prune -o \
           -path './artifacts' -prune -o \
           -path './debian/asus-zenbook-linux-tools' -prune -o \
           -path './debian/tmp' -prune -o \
           -path './debian/.debhelper' -prune -o \
           "$@"
   }
   ```

   ```bash
   set -uo pipefail
   mkdir -p reports/distro-logs
   _repo_prune_find0 PYTHON_FILES -type f -name '*.py' -print0
   {
       ruff_check_status=0
       ruff_format_status=0
       ruff check --fix "${PYTHON_FILES[@]}" || ruff_check_status=$?
       ruff format "${PYTHON_FILES[@]}" || ruff_format_status=$?
       if [ "$ruff_check_status" -ne 0 ] || [ "$ruff_format_status" -ne 0 ]; then
           exit 1
       fi
   } 2>&1 | tee reports/distro-logs/lint-autofix-ruff.log
   exit "${PIPESTATUS[0]}"
   ```

   After Ruff, run repository-pinned markdownlint with `--fix`, then check-only. Prefer
   `markdownlint` on PATH; otherwise `npx -y markdownlint-cli@0.49.1`. Yamllint is check-only
   (no `--fix`).

   ```bash
   set -uo pipefail
   mkdir -p reports/distro-logs
   _repo_prune_find0 MD_FILES -type f \( -name '*.md' -o -name '*.markdown' \) -print0
   {
       if command -v markdownlint >/dev/null 2>&1; then
           md_cmd=(markdownlint)
       else
           md_cmd=(npx -y markdownlint-cli@0.49.1)
       fi
       "${md_cmd[@]}" --fix "${MD_FILES[@]}"
       "${md_cmd[@]}" "${MD_FILES[@]}"
   } 2>&1 | tee reports/distro-logs/lint-autofix-markdown.log
   exit "${PIPESTATUS[0]}"
   ```

   When ESLint is available, run `--fix` then check-only on `gnome/**/*.js` (do not widen
   `eslint.config.mjs`). Always `npm ci` when workspace deps are missing, then use only
   `./node_modules/.bin/eslint` — never global eslint / bare `npx eslint@…` (flat-config
   imports resolve from the repo root; CI clean checkouts break otherwise).

   ```bash
   set -uo pipefail
   mkdir -p reports/distro-logs
   _mapfile_null_find JS_FILES ./gnome -type f -name '*.js' -print0
   {
       if [ ! -x ./node_modules/.bin/eslint ] \
           || [ ! -d ./node_modules/@eslint/js ] \
           || [ ! -d ./node_modules/@stylistic/eslint-plugin ]; then
           npm ci || exit 1
       fi
       ./node_modules/.bin/eslint --config eslint.config.mjs --fix "${JS_FILES[@]}"
       ./node_modules/.bin/eslint --config eslint.config.mjs "${JS_FILES[@]}"
   } 2>&1 | tee reports/distro-logs/lint-autofix-eslint.log
   exit "${PIPESTATUS[0]}"
   ```

1. **Python Linting**:

   Unit tests use `tests/unit/.pylintrc`. Keep its `init-hook` **flat** (no nested
   `for`/`if` bodies): ConfigParser strips leading indentation from multiline values.
   Do not disable `protected-access`; use `tests.unit.bin.attr_helpers.call_attr` /
   `get_attr` when tests must reach private helpers.

   ```bash
   set -euo pipefail
   mkdir -p reports/distro-logs
   _repo_prune_find0 PYTHON_FILES -type f -name '*.py' -print0
   _mapfile_null_find UNIT_TEST_FILES ./tests/unit -type f -name '*.py' -print0
   _mapfile_null_find PRODUCT_PYTHON_FILES . \
       -path './.git' -prune -o \
       -path './.venv*' -prune -o \
       -path './.pytest_cache' -prune -o \
       -path './.ruff_cache' -prune -o \
       -path './.cache' -prune -o \
       -path './node_modules' -prune -o \
       -path './.tools' -prune -o \
       -path './reports' -prune -o \
       -path './artifacts' -prune -o \
       -path './debian/asus-zenbook-linux-tools' -prune -o \
       -path './debian/tmp' -prune -o \
       -path './debian/.debhelper' -prune -o \
       -path './tests/unit' -prune -o \
       -type f -name '*.py' -print0
   {
       ruff check "${PYTHON_FILES[@]}"
       # Product/tools Python uses the default pylint config.
       pylint --max-line-length=140 "${PRODUCT_PYTHON_FILES[@]}"
       pylint --rcfile=tests/unit/.pylintrc --max-line-length=140 "${UNIT_TEST_FILES[@]}"
       VIOLATIONS=$(radon cc "${PYTHON_FILES[@]}" -n B -s)
       if [ -n "$VIOLATIONS" ]; then
          echo "$VIOLATIONS"
          exit 1
       fi
   } 2>&1 | tee reports/distro-logs/lint-python.log
   exit "${PIPESTATUS[0]}"
   ```

1. **Bash Linting & Syntax**:

   Shell complexity enforcement includes every `*.sh` under `scripts/` recursively and
   `docker/images/tests/scripts/`, not only top-level pipeline entrypoints. Keep each block at
   CCN ≤5 by extracting focused helpers; shared coverage-driver setup belongs in
   `scripts/coverage/drivers/kcov_driver_common.sh`. When desktop smoke dispatch growth would
   push `distro_install_smoke_desktop.sh` over 600 lines, keep family routing in
   `distro_install_smoke_desktop_dispatch.sh`.

   ```bash
   set -euo pipefail
   mkdir -p reports/distro-logs
   # Same discovery as scripts/run-lints.sh _resolve_shell_script_targets:
   # all pruned-repo *.sh (bin/, lib/, scripts/, docker/, …) plus Debian scripts.
   _repo_prune_find0 SHELL_FILES -type f -name '*.sh' -print0
   DEBIAN_SHELL=(
       debian/postinst debian/prerm debian/postrm debian/asus-zenbook-configure
   )
   {
       for shell_file in "${SHELL_FILES[@]}" "${DEBIAN_SHELL[@]}"; do
           [ -f "$shell_file" ] || continue
           bash -n "$shell_file"
       done
       shellcheck -x -P SCRIPTDIR "${SHELL_FILES[@]}" "${DEBIAN_SHELL[@]}"
   } 2>&1 | tee reports/distro-logs/lint-shell.log
   exit "${PIPESTATUS[0]}"
   ```

1. **YAML & Markdown Linting**:

   ```bash
   set -euo pipefail
   mkdir -p reports/distro-logs
   _repo_prune_find0 YAML_FILES -type f \( -name '*.yml' -o -name '*.yaml' \) -print0
   _repo_prune_find0 MD_FILES -type f \( -name '*.md' -o -name '*.markdown' \) -print0
   {
       yamllint "${YAML_FILES[@]}"
       if command -v markdownlint >/dev/null 2>&1; then
           markdownlint "${MD_FILES[@]}"
       else
           npx -y markdownlint-cli@0.49.1 "${MD_FILES[@]}"
       fi
   } 2>&1 | tee reports/distro-logs/lint-yaml-markdown.log
   exit "${PIPESTATUS[0]}"
   ```

   Keep prose and normal code/tables ≤140 chars. Prefer readable install command wraps that break
   after trailing `&&` or `|` (or with `\`) so every physical line stays ≤140. Do not suppress
   MD013 and do not set `line-length.code_blocks` or `tables` to `false` in `.markdownlint.json`.
   Human-facing quick-install commands must remain pasteable **interactive** shell commands
   (`curl … | sudo bash`). Do not put `NONINTERACTIVE_CHOICE` in human README/release quick-starts;
   clearly labeled headless/automation sections in `docs/INSTRUCTIONS.md` may use it.

1. **JavaScript Linting (GNOME Shell extension)**:

   Discover and lint `*.js` under `./gnome` only (do not widen discovery or `eslint.config.mjs`).
   `run-lints.sh` installs workspace deps via `npm ci` when needed, then runs only
   `./node_modules/.bin/eslint`. The lint image provides Node/npm; it does **not** rely on a
   global eslint for flat-config imports. Keep `@eslint/js` in `package.json`. Do not use
   `eslint-disable` comments.

   ```bash
   set -euo pipefail
   mkdir -p reports/distro-logs
   _mapfile_null_find JS_FILES ./gnome -type f -name '*.js' -print0
   {
       if [ ! -x ./node_modules/.bin/eslint ] \
           || [ ! -d ./node_modules/@eslint/js ] \
           || [ ! -d ./node_modules/@stylistic/eslint-plugin ]; then
           npm ci
       fi
       ./node_modules/.bin/eslint --config eslint.config.mjs "${JS_FILES[@]}"
   } 2>&1 | tee reports/distro-logs/lint-javascript.log
   exit "${PIPESTATUS[0]}"
   ```

1. **Full lint driver**: [`../../../scripts/run-lints.sh`](../../../scripts/run-lints.sh) runs steps from the
   `LINT_STEPS` array. File discovery uses `_find_repo_files` (same prune set as the examples above:
   `.git`, `.venv*`, `.pytest_cache`, `.ruff_cache`, `.cache`, `node_modules`, `.tools`, `reports`,
   `artifacts`, `debian/asus-zenbook-linux-tools`, `debian/tmp`, `debian/.debhelper`).
   Best-effort ShellCheck system-lib symlinks use `_soft`, not `|| true`. Parallel
   `run-lints.sh` runs flock `/tmp/asus-zenbook-shellcheck-lib.lock` around stub
   install/cleanup (do not delete that lock file after release).

1. **Gettext catalogs**: marked user-visible string changes must regenerate and
   commit `po/asus-zenbook-linux-tools.pot` (`scripts/i18n/extract_pot.sh`) **and
   update every language in `po/SUPPORTED_LANGUAGES`** in the same change set
   (no empty/fuzzy/English-only msgstr for non-English locales). The template is
   tracked despite blanket `*.pot` in `.gitignore` via
   `!po/asus-zenbook-linux-tools.pot`. Freshness (`--check`) fails if the file is
   untracked/gitignored even when present on disk (CI checkout parity). The lint
   driver also runs `msgfmt -c` and `scripts/i18n/check_catalog_quality.py`; fix
   fuzzy entries, placeholders, plurals, empty translations, or canary failures at
   the source. `PO-Revision-Date` must be a real stamp (never `YEAR-MO-DA HO:MI+ZONE`);
   the seeder replaces that placeholder with `PO_REVISION_DATE`. Never bypass
   catalog checks or hand-edit generated `.mo` files. Shell `xgettext` must pass
   `--keyword=` (clear defaults) before project keywords so a bare `gettext`
   package name in `for pkg in … gettext alsa-tools …` is not scraped as a msgid.

1. **File-size gate (600 lines)** — step `[2/14]` runs `python3 scripts/check_file_size_limits.py`:

   - Scope: `bin/`, `lib/`, `tests/`, `tools/`, `scripts/`, `gnome/`, `docker/`, root `install.sh`,
     `uninstall.sh`, `shared_imports.py`, `sitecustomize.py`, and Debian maintainer scripts
     (`debian/postinst`, `debian/prerm`, `debian/postrm`, `debian/asus-zenbook-configure`).
   - Shell lint (`bash -n`, `shellcheck`, shell-complexity) uses `_find_repo_files` for all `*.sh`
     (including `docker/images/tests/scripts/`) plus those Debian scripts.
   - **If a file is too large**: split into smaller files (extract helpers, sibling modules, focused
     tests). Preserve comments, docstrings, and intentional blank lines — **do not** delete them to
     shrink line count.
   - Re-run `./scripts/run-lints.sh` (or at least the file-size step) after splitting.
