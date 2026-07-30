#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=scripts/coverage-utils.sh
source "$SCRIPT_DIR/coverage-utils.sh"
MODE="full"
declare -a MODE_STEPS=()
STEP_INDEX=0
STEP_TOTAL=0
_PIPELINE_MODE_SET=""

_sanitize_report_distro_slug() {
    local slug="${1:-local}"
    slug="${slug//\//-}"
    slug="${slug//:/-}"
    printf '%s\n' "$slug"
}

_coverage_percent_file() {
    local slug
    slug="$(_sanitize_report_distro_slug "${REPORT_DISTRO_SLUG:-local}")"
    printf '%s\n' "$REPO_ROOT/.coverage-percent.${slug}"
}

COVERAGE_PERCENT_FILE="$(_coverage_percent_file)"

_coverage_data_file() {
    # Parallel --compat-only matrix lanes share the bind mount; isolate coverage DBs.
    local slug
    slug="$(_sanitize_report_distro_slug "${REPORT_DISTRO_SLUG:-local}")"
    printf '%s\n' "$REPO_ROOT/.coverage.${slug}"
}

if [ -z "${COVERAGE_FILE:-}" ]; then
    COVERAGE_FILE="$(_coverage_data_file)"
    export COVERAGE_FILE
fi

usage() {
    cat <<'USAGE_EOF'
Usage: build-and-test.sh [--full|--lints-only|--tests-only|--compat-only]

Runs repository verification checks.
  --full         Lint in Docker, Debian .deb smoke (same as CI), then Docker coverage/compat
  --lints-only   Run lint checks only (calls run-lints.sh)
  --tests-only   Run unit, kcov, mocked E2E, and Python coverage (coverage-gate; no compat smoke)
  --compat-only  Run unit tests, mocked E2E, and distro install/uninstall compatibility smoke

Parallel matrix lanes set REPORT_DISTRO_SLUG; coverage data defaults to
.coverage.<slug> via COVERAGE_FILE so bind-mounted workspaces do not race.
USAGE_EOF
}

is_container_runtime() {
    if [ -f /.dockerenv ]; then
        return 0
    fi
    if [ -r /proc/1/cgroup ] && grep -Eq '(docker|containerd|kubepods|podman)' /proc/1/cgroup; then
        return 0
    fi
    return 1
}

_set_pipeline_mode_flag() {
    case "$1" in
        --full) MODE="full" ;;
        --lints-only) MODE="lints-only" ;;
        --tests-only) MODE="tests-only" ;;
        --compat-only) MODE="compat-only" ;;
        *) return 1 ;;
    esac
}

_handle_mode_arg() {
    if _set_pipeline_mode_flag "$1"; then
        if [ -n "${_PIPELINE_MODE_SET:-}" ] && [ "$_PIPELINE_MODE_SET" != "$1" ]; then
            echo "Conflicting pipeline mode flags: already '$_PIPELINE_MODE_SET', got '$1'" >&2
            usage >&2
            exit 1
        fi
        _PIPELINE_MODE_SET="$1"
        return 0
    fi
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
}

parse_args() {
    local arg
    _PIPELINE_MODE_SET=""
    for arg in "$@"; do
        _handle_mode_arg "$arg"
    done
}

_is_truthy() {
    local value="${1:-}"
    [[ "$value" == "1" || "$value" == "true" || "$value" == "TRUE" || "$value" == "yes" || "$value" == "YES" ]]
}

_ensure_distro_logs_dir() {
    local slug="${REPORT_DISTRO_SLUG:-}"
    local base="$REPO_ROOT/reports/distro-logs"
    if [ -n "$slug" ]; then
        slug="$(_sanitize_report_distro_slug "$slug")"
        DISTRO_LOG_DIR="$base/$slug"
    else
        DISTRO_LOG_DIR="$base"
    fi
    export DISTRO_LOG_DIR
    mkdir -p "$DISTRO_LOG_DIR"
}

skip_python_coverage_reports() {
    _is_truthy "${SKIP_PYTHON_COVERAGE_REPORTS:-0}"
}

start_step() {
    local description="$1"
    STEP_INDEX=$((STEP_INDEX + 1))
    echo "[$STEP_INDEX/$STEP_TOTAL] $description"
}

step_unit_tests() {
    start_step "Running Unit Test Suite with Coverage..."
    if ! command -v coverage &>/dev/null; then
        echo "  ✗ coverage not installed." >&2
        exit 1
    fi
    _ensure_distro_logs_dir
    if ! coverage run "$REPO_ROOT/tools/dot_test_runner.py" \
        --start-dir tests/unit \
        --top-level-dir . \
        --failfast \
        2>&1 | tee "$DISTRO_LOG_DIR/unit-tests.log"; then
        echo "  ✗ Unit tests failed (fail-fast)." >&2
        exit 1
    fi
    echo "  ✓ Unit tests passed."
}

step_lint_in_docker() {
    start_step "Running all lint gates in Docker (python:3.13-slim)..."
    _ensure_distro_logs_dir
    if ! ./scripts/lint-in-docker.sh 2>&1 | tee "$DISTRO_LOG_DIR/lint-in-docker.log"; then
        echo "  ✗ Docker lint gate failed." >&2
        exit 1
    fi
    echo "  ✓ Docker lint gate passed."
}

step_deb_package_smoke() {
    # Same script as CI job `deb-package` (shared scripts/run_deb_package_smoke.sh).
    start_step "Running Debian package smoke (build/install/purge)..."
    _ensure_distro_logs_dir
    if ! ./scripts/run_deb_package_smoke.sh 2>&1 | tee "$DISTRO_LOG_DIR/deb-package.log"; then
        echo "  ✗ Debian package smoke failed." >&2
        exit 1
    fi
    echo "  ✓ Debian package smoke passed."
}

step_tests_in_docker() {
    start_step "Running canonical coverage gate in dedicated Docker image..."
    _ensure_distro_logs_dir
    if ! ./scripts/run_docker_matrix.sh --coverage-gate \
        2>&1 | tee "$DISTRO_LOG_DIR/docker-coverage-gate.log"; then
        echo "  ✗ Canonical coverage gate failed." >&2
        exit 1
    fi
    echo "  ✓ Canonical coverage gate passed."

    echo "Running cross-distro compatibility checks (coverage gates skipped)..."
    if ! ./scripts/run_docker_matrix.sh --compat-only \
        2>&1 | tee "$DISTRO_LOG_DIR/docker-compat-only.log"; then
        echo "  ✗ Docker distro compatibility test gate failed." >&2
        exit 1
    fi
    echo "  ✓ Docker distro compatibility test gate passed."
}

_verify_mock_e2e_discovery_targets() {
    _ensure_distro_logs_dir
    if ! python3 - <<'PY' 2>&1 | tee "$DISTRO_LOG_DIR/mock-e2e-discovery.log"
import sys
import unittest
from pathlib import Path


def iter_tests(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from iter_tests(item)
        else:
            yield item


bin_tests = sorted(Path("tests/e2e/mock/bin").glob("test_*.py"))
if not bin_tests:
    print(
        "  ✗ No mock E2E bin tests found under tests/e2e/mock/bin/test_*.py",
        file=sys.stderr,
    )
    raise SystemExit(1)

suite = unittest.defaultTestLoader.discover(
    start_dir="tests/e2e/mock",
    pattern="test*.py",
    top_level_dir="tests/e2e",
)
modules = {test.__class__.__module__ for test in iter_tests(suite)}
required = {f"mock.bin.{path.stem}" for path in bin_tests}
missing = sorted(required - modules)
if missing:
    print("  ✗ Missing mocked E2E discovery targets:", ", ".join(missing), file=sys.stderr)
    raise SystemExit(1)
print(f"  ✓ Mocked E2E discovery includes {len(required)} bin test modules.")
PY
    then
        echo "  ✗ Mocked E2E discovery check failed." >&2
        exit 1
    fi
}

step_e2e_tests() {
    start_step "Running Mocked End-to-End Test Suite with Coverage..."
    if ! command -v coverage &>/dev/null; then
        echo "  ✗ coverage not installed." >&2
        exit 1
    fi
    _verify_mock_e2e_discovery_targets
    _ensure_distro_logs_dir
    if ! (
        export PYTHONPATH="$REPO_ROOT"
        cd tests/e2e/mock
        coverage run -a \
            "$REPO_ROOT/tools/dot_test_runner.py" \
            --start-dir . \
            --top-level-dir .. \
            --failfast
    ) 2>&1 | tee "$DISTRO_LOG_DIR/mocked-e2e-tests.log"; then
        echo "  ✗ Mocked end-to-end tests failed (fail-fast)." >&2
        exit 1
    fi
    echo "  ✓ Mocked end-to-end tests passed."
}

step_distro_compat_smoke() {
    start_step "Running distro install/uninstall compatibility smoke..."
    _ensure_distro_logs_dir
    if ! ./scripts/run_distro_install_smoke.sh 2>&1 \
        | tee "$DISTRO_LOG_DIR/distro-compat-smoke.log"; then
        echo "  ✗ Distro compatibility smoke failed." >&2
        exit 1
    fi
    echo "  ✓ Distro compatibility smoke passed."
}

_write_python_coverage_reports() {
    local include_pattern
    include_pattern="$(_python_coverage_include_pattern)"
    local slug
    slug="$(_sanitize_report_distro_slug "${REPORT_DISTRO_SLUG:-local}")"
    local reports_root
    reports_root="$(resolve_reports_root)"
    local report_dir="$reports_root/coverage/${slug}"
    mkdir -p "$report_dir"
    coverage html --include="$include_pattern" -d "$report_dir/html"
    coverage xml --include="$include_pattern" -o "$report_dir/coverage.xml"
    coverage json --include="$include_pattern" -o "$report_dir/coverage.json"
    echo "  ✓ Python coverage reports written to $report_dir/"
}

_extract_total_coverage_percent() {
    awk '
        /^TOTAL[[:space:]]+/ {
            gsub("%", "", $NF)
            print $NF
            exit
        }
    '
}

_coverage_percent_from_data_file() {
    local include_pattern="${1:-$(_python_coverage_include_pattern)}"
    coverage report --include="$include_pattern" 2>/dev/null | _extract_total_coverage_percent
}

_coverage_percent_from_artifact_file() {
    [ -f "$COVERAGE_PERCENT_FILE" ] || return 1
    awk 'NF { print $1; exit }' "$COVERAGE_PERCENT_FILE"
}

_coverage_percent_from_data_if_available() {
    [ -f "${COVERAGE_FILE:-$REPO_ROOT/.coverage}" ] || return 1
    _coverage_percent_from_data_file
}

_persist_coverage_percent_artifact() {
    local percent="$1"
    printf '%s\n' "$percent" > "$COVERAGE_PERCENT_FILE"
}

_require_coverage_cli() {
    if command -v coverage &>/dev/null; then
        return 0
    fi
    echo "  ✗ coverage not installed." >&2
    exit 1
}

_run_python_coverage_gate_or_die() {
    local include_pattern="$1"
    if run_python_coverage_gate "$include_pattern" 90; then
        return 0
    fi
    echo "  ✗ Python coverage gate failed." >&2
    exit 1
}

_maybe_persist_coverage_percent() {
    local include_pattern="$1"
    local percent=""
    percent=$(_coverage_percent_from_data_file "$include_pattern") || percent=""
    [ -n "$percent" ] || return 0
    _persist_coverage_percent_artifact "$percent"
}

step_python_coverage() {
    start_step "Enforcing Minimum 90% Code Coverage..."
    local include_pattern
    include_pattern="$(_python_coverage_include_pattern)"
    _require_coverage_cli
    _run_python_coverage_gate_or_die "$include_pattern"
    _maybe_persist_coverage_percent "$include_pattern"

    if skip_python_coverage_reports; then
        echo "  - Skipping Python coverage report generation (SKIP_PYTHON_COVERAGE_REPORTS=1)."
        return
    fi

    _write_python_coverage_reports
}

is_ci_environment() {
    [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]
}

_coverage_percent_from_coverage_gate_log() {
    _ensure_distro_logs_dir
    local log_file="$DISTRO_LOG_DIR/coverage-gate.log"
    [ -f "$log_file" ] || return 1
    _extract_total_coverage_percent < "$log_file"
}

_resolve_badge_coverage_percent() {
    local percent="" provider
    for provider in _coverage_percent_from_data_if_available _coverage_percent_from_coverage_gate_log _coverage_percent_from_artifact_file; do
        percent=$("$provider" || true)
        [[ "$percent" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
        echo "$percent"
        return 0
    done
    return 1
}

_invoking_user_home() {
    # Resolve the invoking user's home without elevating into root's PATH.
    if [ -n "${SUDO_USER:-}" ]; then
        getent passwd "$SUDO_USER" | cut -d: -f6
        return 0
    fi
    printf '%s\n' "${HOME:-}"
}

_prepend_invoking_user_local_bin() {
    local user_home local_bin
    # Never put a user-writable ~/.local/bin on root's PATH.
    [ "$(id -u)" -eq 0 ] && return 0
    user_home=$(_invoking_user_home)
    user_home="${user_home:-}"
    local_bin="${user_home}/.local/bin"
    [ -n "$user_home" ] && [ -d "$local_bin" ] || return 0
    PATH="${local_bin}:${PATH}"
    export PATH
}

_poetry_run_as_invoker() {
    local poetry_bin
    poetry_bin=$(command -v poetry) || return 1
    if [ -n "${SUDO_USER:-}" ] && [ "$(id -u)" -eq 0 ]; then
        sudo -u "$SUDO_USER" -H -- "$poetry_bin" -C "$REPO_ROOT" run "$@"
        return $?
    fi
    "$poetry_bin" -C "$REPO_ROOT" run "$@"
}

_echo_if_executable() {
    local path="$1"
    [ -n "$path" ] && [ -x "$path" ] || return 1
    printf '%s\n' "$path"
}

_anybadge_from_invoker_local_bin() {
    local user_home
    [ -n "${SUDO_USER:-}" ] && [ "$(id -u)" -eq 0 ] || return 1
    user_home=$(_invoking_user_home)
    [ -n "$user_home" ] || return 1
    _echo_if_executable "$user_home/.local/bin/anybadge"
}

_anybadge_from_poetry() {
    local candidate
    candidate=$(_poetry_run_as_invoker bash -c 'command -v anybadge') || return 1
    case "$candidate" in
        ''|*[[:space:]]*)
            echo "Invalid anybadge path from poetry: ${candidate:-<empty>}" >&2
            return 1
            ;;
    esac
    _echo_if_executable "$candidate" || {
        echo "anybadge path is not executable: $candidate" >&2
        return 1
    }
}

_resolve_anybadge_launcher() {
    if command -v anybadge &>/dev/null; then
        echo anybadge
        return 0
    fi
    _echo_if_executable "$REPO_ROOT/.venv/bin/anybadge" && return 0
    _anybadge_from_invoker_local_bin && return 0
    _anybadge_from_poetry
}

_run_anybadge() {
    local percent="$1" output_file="$2" anybadge_bin="$3"
    if [ -n "${SUDO_USER:-}" ] && [ "$(id -u)" -eq 0 ]; then
        sudo -u "$SUDO_USER" -H -- "$anybadge_bin" --overwrite --label "coverage" \
            --value "$percent" --suffix "%" --file "$output_file" \
            50=red 75=orange 90=green >/dev/null
        return $?
    fi
    "$anybadge_bin" --overwrite --label "coverage" --value "$percent" --suffix "%" --file "$output_file" \
        50=red 75=orange 90=green >/dev/null
}

_write_badge_with_anybadge() {
    local percent="$1" output_file="$2" anybadge_bin
    if ! anybadge_bin=$(_resolve_anybadge_launcher); then
        echo "  ✗ anybadge is required for local badge updates." >&2
        return 1
    fi
    _run_anybadge "$percent" "$output_file" "$anybadge_bin"
}

update_local_coverage_badge() {
    if is_ci_environment; then
        return
    fi

    if is_container_runtime; then
        return
    fi

    _prepend_invoking_user_local_bin

    local percent
    if ! percent=$(_resolve_badge_coverage_percent); then
        echo "  ! Warning: Could not derive coverage percent; skipping badge update." >&2
        return 0
    fi

    mkdir -p "$REPO_ROOT/assets"
    if ! _write_badge_with_anybadge "$percent" "$REPO_ROOT/assets/coverage.svg"; then
        echo "  ! Warning: Failed to write coverage badge; continuing." >&2
        return 0
    fi
    echo "  ✓ Coverage badge overwritten at assets/coverage.svg (${percent}%)."
}

_fill_mode_steps() {
    local mode="$1"
    MODE_STEPS=()
    case "$mode" in
        lints-only)
            MODE_STEPS=(_run_lints_only_steps)
            ;;
        tests-only)
            MODE_STEPS=(step_unit_tests step_kcov_coverage step_e2e_tests step_python_coverage)
            ;;
        compat-only)
            MODE_STEPS=(step_unit_tests step_e2e_tests step_distro_compat_smoke)
            ;;
        full)
            MODE_STEPS=(step_lint_in_docker step_deb_package_smoke step_tests_in_docker)
            ;;
        *)
            echo "Unsupported mode: $mode" >&2
            return 1
            ;;
    esac
}

_get_step_total() {
    if ! _fill_mode_steps "$1"; then
        return 1
    fi
    echo "${#MODE_STEPS[@]}"
}

_is_container_only_mode() {
    case "$MODE" in
        lints-only|tests-only|compat-only) return 0 ;;
    esac
    return 1
}

_print_host_mode_hint() {
    if [ "$MODE" = "lints-only" ]; then
        echo "Run lints with: ./scripts/run-lints.sh" >&2
        return 0
    fi
    echo "Run tests in Docker with: ./scripts/run_docker_matrix.sh" >&2
}

_check_host_execution_disabled() {
    if _is_container_only_mode && ! is_container_runtime; then
        echo "Host execution for '$MODE' is disabled." >&2
        _print_host_mode_hint
        exit 1
    fi
}

_run_lints_only_steps() {
    start_step "Running all lints via run-lints.sh..."
    _ensure_distro_logs_dir
    if ! ./scripts/run-lints.sh 2>&1 | tee "$DISTRO_LOG_DIR/run-lints.log"; then
        echo "  ✗ Lint gate failed." >&2
        exit 1
    fi
}

_run_mode_steps() {
    local step
    _fill_mode_steps "$MODE" || exit 1
    for step in "${MODE_STEPS[@]}"; do
        "$step"
    done
}

main() {
    parse_args "$@"

    if ! STEP_TOTAL=$(_get_step_total "$MODE"); then
        echo "Unsupported mode: $MODE" >&2
        exit 1
    fi
    STEP_INDEX=0

    echo "=================================================="
    echo "      ASUS ZenBook Linux Tools Local Pipeline      "
    echo "=================================================="

    _check_host_execution_disabled
    _run_mode_steps
    update_local_coverage_badge

    echo "=================================================="
    echo "          All Pipeline Checks Passed!             "
    echo "=================================================="
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
