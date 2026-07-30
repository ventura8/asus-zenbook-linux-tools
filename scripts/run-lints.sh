#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

_soft() { "$@" || return 0; }

cd "$REPO_ROOT"

STEP_INDEX=0
LINT_STEPS=(
    step_bash_syntax
    step_file_size_limits
    step_ruff
    step_pylint
    step_yamllint
    step_dockerfilelint
    step_toml_lint
    step_version_sync
    step_i18n_catalogs
    step_radon
    step_markdownlint
    step_eslint
    step_shellcheck
    step_shell_complexity
    step_systemd_verify
)
STEP_TOTAL=${#LINT_STEPS[@]}
SHELLCHECK_LIB_NAMES=(
    asus-bootstrap.sh
    asus-common.sh
    asus-i18n.sh
    asus-notif-icons.sh
    asus-session.sh
    asus-display-mutter.sh
    asus-display-state.sh
    asus-display-watchdog.sh
    asus-display-osd.sh
)
SHELL_SCRIPT_TARGETS=()

_find_repo_files() {
    # Prune dpkg-buildpackage install trees / artifacts so pylint never scores the
    # staged payload copy under debian/asus-zenbook-linux-tools as duplicate-code.
    find . \
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
        -type f \( "$@" \) -print | sort
}

find_python_files() {
    _find_repo_files -name '*.py'
}

find_markdown_files() {
    _find_repo_files -name '*.md' -o -name '*.markdown'
}

find_yaml_files() {
    _find_repo_files -name '*.yml' -o -name '*.yaml'
}

find_js_files() {
    _find_repo_files -name '*.js'
}

start_step() {
    local description="$1"
    STEP_INDEX=$((STEP_INDEX + 1))
    echo "[$STEP_INDEX/$STEP_TOTAL] $description"
}

step_bash_syntax() {
    start_step "Checking Bash Syntax..."
    local script
    _resolve_shell_script_targets
    for script in "${SHELL_SCRIPT_TARGETS[@]}"; do
        bash -n "$script"
    done
    echo "  ✓ Bash syntax valid."
}

_append_readable_shell_targets() {
    local entry
    for entry in "${found[@]}"; do
        entry="${entry#./}"
        [ -n "$entry" ] || continue
        if [ -r "$entry" ]; then
            SHELL_SCRIPT_TARGETS+=("$entry")
        fi
    done
}

_resolve_shell_script_targets() {
    # Repo-wide *.sh discovery (same prune set as Python/YAML/Markdown) so new
    # helpers under docker/, scripts/, etc. are covered without updating globs.
    local -a found=()
    local -a debian_shell=(
        debian/postinst
        debian/prerm
        debian/postrm
        debian/asus-zenbook-configure
    )
    SHELL_SCRIPT_TARGETS=()
    mapfile -t found < <(_find_repo_files -name '*.sh')
    _append_readable_shell_targets
    found=("${debian_shell[@]}")
    _append_readable_shell_targets
    if [ "${#SHELL_SCRIPT_TARGETS[@]}" -eq 0 ]; then
        echo "  ✗ No shell script targets found for bash -n." >&2
        exit 1
    fi
}

step_file_size_limits() {
    start_step "Enforcing file-size limits for production and test files..."
    python3 scripts/check_file_size_limits.py
    echo "  ✓ File-size limits passed."
}

step_ruff() {
    start_step "Running Python Ruff Check..."
    if command -v ruff &>/dev/null; then
        mapfile -t PYTHON_FILES < <(find_python_files)
        if [ "${#PYTHON_FILES[@]}" -eq 0 ]; then
            echo "  ✗ No product Python files found for Ruff." >&2
            exit 1
        fi
        ruff check "${PYTHON_FILES[@]}"
        echo "  ✓ Ruff check passed."
    else
        echo "  ✗ ruff not installed." >&2
        exit 1
    fi
}

step_pylint() {
    start_step "Running Python Pylint Check..."
    if command -v pylint &>/dev/null; then
        mapfile -t PYTHON_FILES < <(find_python_files | grep -Ev '^(\./)?tests/unit/')
        mapfile -t UNIT_TEST_FILES < <(find tests/unit -type f -name '*.py' | sort)
        if [ "${#PYTHON_FILES[@]}" -eq 0 ]; then
            echo "  ✗ No product Python files found for Pylint." >&2
            exit 1
        fi
        if [ "${#UNIT_TEST_FILES[@]}" -eq 0 ]; then
            echo "  ✗ No unit test Python files found for Pylint." >&2
            exit 1
        fi
        pylint --max-line-length=140 "${PYTHON_FILES[@]}"
        pylint --rcfile="$REPO_ROOT/tests/unit/.pylintrc" --max-line-length=140 "${UNIT_TEST_FILES[@]}"
        echo "  ✓ Pylint check passed."
    else
        echo "  ✗ pylint not installed." >&2
        exit 1
    fi
}

step_yamllint() {
    start_step "Running YAML Lint..."
    if command -v yamllint &>/dev/null; then
        mapfile -t YAML_FILES < <(find_yaml_files)
        if [ "${#YAML_FILES[@]}" -eq 0 ]; then
            echo "  ✓ Yamllint check passed."
            return
        fi
        yamllint "${YAML_FILES[@]}"
        echo "  ✓ Yamllint check passed."
    else
        echo "  ✗ yamllint not installed." >&2
        exit 1
    fi
}

step_dockerfilelint() {
    start_step "Running Dockerfile Lint..."
    if command -v hadolint &>/dev/null; then
        mapfile -t DOCKER_FILES < <(find docker -type f \( -name 'Dockerfile' -o -name '*.Dockerfile' \) | sort)
        if [ "${#DOCKER_FILES[@]}" -eq 0 ]; then
            echo "  ✗ No Dockerfiles found under docker/." >&2
            exit 1
        fi
        for dockerfile in "${DOCKER_FILES[@]}"; do
            hadolint "$dockerfile"
        done
        echo "  ✓ Dockerfile lint check passed."
    else
        echo "  ✗ hadolint not installed." >&2
        exit 1
    fi
}

step_toml_lint() {
    start_step "Running TOML Validation..."
    python3 - <<'PYEOF'
import sys
import tomllib

try:
    with open('pyproject.toml', 'rb') as handle:
        tomllib.load(handle)
except OSError as exc:
    print(f"  ✗ TOML validation failed: {exc}", file=sys.stderr)
    sys.exit(1)
except tomllib.TOMLDecodeError as exc:
    print(f"  ✗ TOML validation failed: {exc}", file=sys.stderr)
    sys.exit(1)
print("  ✓ TOML validation passed.")
PYEOF
}

step_version_sync() {
    start_step "Checking VERSION is the single source of truth..."
    python3 - <<'PYEOF'
from pathlib import Path
import sys
import tomllib

version_path = Path("VERSION")
if not version_path.is_file():
    print("  ✗ Missing VERSION file (single source of truth).", file=sys.stderr)
    sys.exit(1)

file_version = version_path.read_text(encoding="utf-8").strip()
if not file_version:
    print("  ✗ VERSION file is empty.", file=sys.stderr)
    sys.exit(1)

with Path("pyproject.toml").open("rb") as handle:
    data = tomllib.load(handle)
try:
    poetry_version = data["tool"]["poetry"]["version"]
except KeyError:
    print("  ✗ pyproject.toml missing tool.poetry.version.", file=sys.stderr)
    sys.exit(1)

if file_version != poetry_version:
    print(
        f"  ✗ VERSION ({file_version}) does not match "
        f"pyproject.toml tool.poetry.version ({poetry_version}).",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"  ✓ Version sync passed ({file_version}).")
PYEOF
}

step_i18n_catalogs() {
    start_step "Checking gettext catalogs..."
    scripts/i18n/extract_pot.sh --check
    python3 scripts/i18n/seed_whisper_languages.py --check
    python3 scripts/i18n/check_catalog_quality.py
}

step_radon() {
    start_step "Running Radon Cyclomatic Complexity Check (A-rank only)..."
    if command -v radon &>/dev/null; then
        mapfile -t PYTHON_FILES < <(find_python_files)
        if [ "${#PYTHON_FILES[@]}" -eq 0 ]; then
            echo "  ✗ No Python files found for Radon." >&2
            exit 1
        fi
        VIOLATIONS=$(radon cc "${PYTHON_FILES[@]}" -n B -s)
        if [ -n "$VIOLATIONS" ]; then
            echo "  ✗ Complexity violations (rank B or worse found):"
            echo "$VIOLATIONS"
            exit 1
        fi
        radon cc "${PYTHON_FILES[@]}" -s -a
        echo "  ✓ Radon complexity check passed (all blocks rank A)."
    else
        echo "  ✗ radon not installed." >&2
        exit 1
    fi
}

step_markdownlint() {
    start_step "Running MarkdownLint..."
    if command -v markdownlint &>/dev/null; then
        mapfile -t MD_FILES < <(find_markdown_files)
        if [ "${#MD_FILES[@]}" -eq 0 ]; then
            echo "  ✓ MarkdownLint check passed."
            return
        fi
        markdownlint "${MD_FILES[@]}"
        echo "  ✓ MarkdownLint check passed."
    elif command -v npx &>/dev/null; then
        mapfile -t MD_FILES < <(find_markdown_files)
        if [ "${#MD_FILES[@]}" -eq 0 ]; then
            echo "  ✓ MarkdownLint check passed."
            return
        fi
        npx -y markdownlint-cli@0.49.1 "${MD_FILES[@]}"
        echo "  ✓ MarkdownLint check passed."
    else
        echo "  ✗ markdownlint / npx not installed." >&2
        exit 1
    fi
}

_require_eslint_npm_manifest() {
    if ! command -v npm >/dev/null 2>&1; then
        echo "  ✗ npm is required to install ESLint deps from package-lock.json." >&2
        return 1
    fi
    if [ ! -f "$REPO_ROOT/package-lock.json" ] || [ ! -f "$REPO_ROOT/package.json" ]; then
        echo "  ✗ package.json / package-lock.json missing for ESLint npm ci." >&2
        return 1
    fi
}

_ensure_eslint_workspace_deps() {
    if _eslint_workspace_deps_ready; then
        return 0
    fi
    _require_eslint_npm_manifest || return 1
    _run_eslint_npm_ci
}

_eslint_workspace_deps_ready() {
    # eslint.config.mjs imports resolve from the repo root — global eslint alone is
    # not enough (CI clean checkouts fail without workspace node_modules).
    [ -x "$REPO_ROOT/node_modules/.bin/eslint" ] \
        && [ -d "$REPO_ROOT/node_modules/@eslint/js" ] \
        && [ -d "$REPO_ROOT/node_modules/@stylistic/eslint-plugin" ]
}

_run_eslint_npm_ci() {
    echo "  → Installing workspace ESLint deps via npm ci (CI/local parity)..."
    (cd "$REPO_ROOT" && npm ci) || return 1
    if _eslint_workspace_deps_ready; then
        return 0
    fi
    echo "  ✗ npm ci did not install eslint / @eslint/js / @stylistic." >&2
    return 1
}

step_eslint() {
    start_step "Running ESLint on JavaScript..."
    mapfile -t JS_FILES < <(find_js_files)
    if [ "${#JS_FILES[@]}" -eq 0 ]; then
        echo "  ✓ ESLint check passed (no JavaScript files)."
        return
    fi
    if ! _ensure_eslint_workspace_deps; then
        exit 1
    fi
    # Always use the workspace binary so flat-config imports resolve identically
    # in CI (no host node_modules) and local lint-in-docker (bind-mounted tree).
    "$REPO_ROOT/node_modules/.bin/eslint" \
        --config "$REPO_ROOT/eslint.config.mjs" \
        "${JS_FILES[@]}"
    echo "  ✓ ESLint check passed."
}

_maybe_link_shellcheck_lib() {
    local dest="$1"
    local name="$2"
    local only_missing="$3"
    local src="$REPO_ROOT/lib/$name"
    [ "$only_missing" = "1" ] && [ -e "$dest/$name" ] && return 0
    ln -sfn "$src" "$dest/$name"
}

_install_shellcheck_lib_symlinks() {
    local dest="$1"
    local only_missing="${2:-0}"
    local name
    # System stub dir may be unwritable under Docker --user; callers use _soft there.
    mkdir -p "$dest" 2>/dev/null || return 1
    for name in "${SHELLCHECK_LIB_NAMES[@]}"; do
        _maybe_link_shellcheck_lib "$dest" "$name" "$only_missing" || return 1
    done
}

ensure_shellcheck_installed_lib_paths() {
    # Prefer a repo-local cache destination for -P SCRIPTDIR resolution.
    # Also create best-effort absolute install-path stubs so SC1091 can follow
    # hardcoded /usr/local/lib/... sources used by product bin helpers.
    local cache_dest="${SHELLCHECK_LIB_DEST:-$REPO_ROOT/.cache/shellcheck-lib}"
    local system_dest="/usr/local/lib/asus-zenbook-linux-tools"
    # Shared across checkouts: flock inode must stay stable for the system symlink target.
    local lock_file="/tmp/asus-zenbook-shellcheck-lib.lock"

    if ! _install_shellcheck_lib_symlinks "$cache_dest" 0; then
        echo "  ✗ Cannot create ShellCheck helper symlinks under $cache_dest." >&2
        exit 1
    fi
    export SHELLCHECK_LIB_DEST="$cache_dest"
    export SHELLCHECK_SYSTEM_LIB_DEST="$system_dest"
    (
        flock 9
        _soft _install_shellcheck_lib_symlinks "$system_dest" 1
    ) 9>"$lock_file"
}

_cleanup_shellcheck_repo_symlink() {
    local path="$1" target
    [ -L "$path" ] || return 0
    target=$(readlink -f "$path" 2>/dev/null || true)
    case "$target" in
        "$REPO_ROOT"/*) rm -f "$path" ;;
    esac
}

_cleanup_shellcheck_lib_symlinks() {
    local dest="${SHELLCHECK_LIB_DEST:-$REPO_ROOT/.cache/shellcheck-lib}"
    local system_dest="${SHELLCHECK_SYSTEM_LIB_DEST:-/usr/local/lib/asus-zenbook-linux-tools}"
    local lock_file="/tmp/asus-zenbook-shellcheck-lib.lock"
    local name
    mkdir -p "$dest"
    for name in "${SHELLCHECK_LIB_NAMES[@]}"; do
        rm -f "$dest/$name"
    done
    (
        flock 9
        for name in "${SHELLCHECK_LIB_NAMES[@]}"; do
            _cleanup_shellcheck_repo_symlink "$system_dest/$name"
        done
    ) 9>"$lock_file"
}

# Registered EXIT cleanups. Steps toggle flags; one top trap runs all cleanups.
_LINT_CLEANUP_SHELLCHECK=0
_LINT_CLEANUP_SYSTEMD=0

_lint_register_shellcheck_cleanup() {
    _LINT_CLEANUP_SHELLCHECK=1
}

_lint_unregister_shellcheck_cleanup() {
    _LINT_CLEANUP_SHELLCHECK=0
}

_lint_register_systemd_cleanup() {
    _LINT_CLEANUP_SYSTEMD=1
}

_lint_unregister_systemd_cleanup() {
    _LINT_CLEANUP_SYSTEMD=0
}

_lint_run_registered_cleanups() {
    if [ "$_LINT_CLEANUP_SHELLCHECK" = "1" ]; then
        _cleanup_shellcheck_step
    fi
    if [ "$_LINT_CLEANUP_SYSTEMD" = "1" ]; then
        _cleanup_systemd_verify_step
    fi
}

_cleanup_shellcheck_step() {
    _cleanup_shellcheck_lib_symlinks
}

_cleanup_systemd_verify_step() {
    rm -rf "${_SYSTEMD_VERIFY_TMP_BIN:-}" "${_SYSTEMD_VERIFY_TMP_SVC:-}"
    _SYSTEMD_VERIFY_TMP_BIN=""
    _SYSTEMD_VERIFY_TMP_SVC=""
}

step_shellcheck() {
    start_step "Running ShellCheck..."
    if command -v shellcheck &>/dev/null; then
        _resolve_shell_script_targets
        _lint_register_shellcheck_cleanup
        ensure_shellcheck_installed_lib_paths
        # Severity floor: warning+. Info (SC2317/SC2329 on dynamic `"$step"` /
        # trap handlers, intentional single-quoted remote bash -c) must not fail CI.
        shellcheck -S warning -x -P "SCRIPTDIR:${SHELLCHECK_LIB_DEST}" \
            "${SHELL_SCRIPT_TARGETS[@]}"
        _cleanup_shellcheck_step
        _lint_unregister_shellcheck_cleanup
        echo "  ✓ ShellCheck passed."
    else
        echo "  ✗ shellcheck not installed." >&2
        exit 1
    fi
}

step_shell_complexity() {
    start_step "Running Shell Complexity Check (shellmetrics Rank A gate)..."
    _resolve_shell_script_targets
    python3 tools/shell_complexity.py "${SHELL_SCRIPT_TARGETS[@]}" --max-grade A
    echo "  ✓ Shell complexity check passed (all shell scripts rank A)."
}

_run_systemd_verify() {
        _SYSTEMD_VERIFY_TMP_BIN=$(mktemp -d)
        _SYSTEMD_VERIFY_TMP_SVC=$(mktemp -d)
        _lint_register_systemd_cleanup
        cp bin/asus-hotkey-daemon.py "$_SYSTEMD_VERIFY_TMP_BIN/asus-hotkey-daemon.py"
        cp bin/asus-touchpad-share.py "$_SYSTEMD_VERIFY_TMP_BIN/asus-touchpad-share.py"
        cp bin/asus-sound-fix.sh "$_SYSTEMD_VERIFY_TMP_BIN/asus-sound-fix.sh"
        chmod +x "$_SYSTEMD_VERIFY_TMP_BIN"/*
        local svc_count=0 had_nullglob=0
        if shopt -q nullglob; then
            had_nullglob=1
        fi
        shopt -s nullglob
        for svc in systemd/*.service; do
            svc_count=$((svc_count + 1))
            sed "s|/usr/local/bin|$_SYSTEMD_VERIFY_TMP_BIN|g" "$svc" \
                > "$_SYSTEMD_VERIFY_TMP_SVC/$(basename "$svc")"
        done
        if [ "$had_nullglob" -eq 0 ]; then
            shopt -u nullglob
        fi
        if [ "$svc_count" -eq 0 ]; then
            echo "  ✗ No systemd unit files matched systemd/*.service" >&2
            exit 1
        fi
        systemd-analyze verify "$_SYSTEMD_VERIFY_TMP_SVC"/*.service
        _cleanup_systemd_verify_step
        _lint_unregister_systemd_cleanup
        echo "  ✓ Systemd unit verification passed."
}

step_systemd_verify() {
    start_step "Verifying Systemd Unit Files..."
    if ! command -v systemd-analyze &>/dev/null; then
        echo "  ✗ systemd-analyze not installed." >&2
        exit 1
    fi
    _run_systemd_verify
}

run_all_lints() {
    trap '_lint_run_registered_cleanups' EXIT
    echo "=================================================="
    echo "      ASUS ZenBook Linux Tools Linting           "
    echo "=================================================="
    local step
    for step in "${LINT_STEPS[@]}"; do
        "$step"
    done
    _lint_run_registered_cleanups
    trap - EXIT
    echo "=================================================="
    echo "          All Linting Checks Passed!             "
    echo "=================================================="
}

# Prefer UTF-8 so ShellCheck can print source lines that contain ✓/✗ markers.
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

mkdir -p "$REPO_ROOT/reports/distro-logs"
run_all_lints 2>&1 | tee "$REPO_ROOT/reports/distro-logs/lints.log"
exit "${PIPESTATUS[0]}"
