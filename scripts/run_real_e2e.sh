#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SHARED_LIB="$REPO_ROOT/lib/install-shared.sh"
cd "$REPO_ROOT"

if [[ ! -f "$INSTALL_SHARED_LIB" ]]; then
    echo "Missing installer shared helper: $INSTALL_SHARED_LIB" >&2
    exit 1
fi
# shellcheck source=../lib/install-shared.sh
source "$INSTALL_SHARED_LIB"

if [[ "${E2E_REAL_ALLOW_SYSTEM_CHANGES:-0}" != "1" ]]; then
    echo "Refusing to run real-system end-to-end tests without explicit opt-in." >&2
    echo "Run with: sudo E2E_REAL_ALLOW_SYSTEM_CHANGES=1 ./scripts/run_real_e2e.sh" >&2
    exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "Real-system E2E tests require root privileges." >&2
    echo "Run with: sudo E2E_REAL_ALLOW_SYSTEM_CHANGES=1 ./scripts/run_real_e2e.sh" >&2
    exit 1
fi

if ! command -v coverage &>/dev/null; then
    echo "coverage is required to run real-system end-to-end tests." >&2
    exit 1
fi

_real_e2e_cleanup_timeout() {
    local cleanup_timeout="${ASUS_REAL_E2E_CLEANUP_TIMEOUT_SECS:-90}"
    case "$cleanup_timeout" in
        ''|*[!0-9]*) cleanup_timeout=90 ;;
        *) ;;
    esac
    if [[ "$cleanup_timeout" -lt 30 ]]; then
        cleanup_timeout=30
    fi
    printf '%s\n' "$cleanup_timeout"
    return 0
}

cleanup_real_e2e() {
    trap - EXIT INT TERM
    local test_rc="$1"
    local cleanup_rc=0
    local cleanup_timeout
    cleanup_timeout="$(_real_e2e_cleanup_timeout)"
    echo "Running post-test cleanup via uninstall.sh..."
    mkdir -p "$REPO_ROOT/reports/distro-logs"
    cleanup_rc=0
    _run_command_with_timeout "$cleanup_timeout" bash -c \
        'set -o pipefail; ./uninstall.sh 2>&1 | tee -a "$1/reports/distro-logs/real-e2e-cleanup.log"' \
        bash "$REPO_ROOT" \
        || cleanup_rc=$?
    _chown_real_e2e_artifacts

    if [[ "$cleanup_rc" -ne 0 ]]; then
        echo "Warning: uninstall cleanup failed with exit code $cleanup_rc." >&2
        if [[ "$test_rc" -eq 0 ]]; then
            exit "$cleanup_rc"
        fi
    fi

    exit "$test_rc"
}

_chown_real_e2e_artifacts() {
    [[ -n "${SUDO_UID:-}" ]] || return 0
    [[ -n "${SUDO_GID:-}" ]] || return 0
    _asus_soft chown -R "${SUDO_UID}:${SUDO_GID}" "$REPO_ROOT/reports"
    if [[ -f "$REPO_ROOT/.coverage.real-e2e" ]]; then
        _asus_soft chown "${SUDO_UID}:${SUDO_GID}" "$REPO_ROOT/.coverage.real-e2e"
    fi
    # coverage.py may also emit numbered companion files for parallel runs.
    shopt -s nullglob
    local cov_extra
    for cov_extra in "$REPO_ROOT"/.coverage.real-e2e.*; do
        _asus_soft chown "${SUDO_UID}:${SUDO_GID}" "$cov_extra"
    done
    shopt -u nullglob
}

_cleanup_real_e2e_on_signal() {
    cleanup_real_e2e 130
}

_require_clean_host() {
    # The EXIT cleanup runs uninstall.sh; on a host with a live install that
    # would tear down the user's working setup, so refuse before arming it.
    local dirty=""
    dirty="$(PYTHONDONTWRITEBYTECODE=1 python3 -c \
        'from tests.e2e.e2e_utils import host_dirty_paths; print("\n".join(host_dirty_paths()))')" \
        || return 1
    if [[ -n "$dirty" ]]; then
        echo "Refusing to run real-system E2E: host already has an install (cleanup would uninstall it)." >&2
        sed 's/^/  /' <<< "$dirty" >&2
        echo "Uninstall first (sudo ./uninstall.sh), then re-run." >&2
        return 1
    fi
    return 0
}

# set -e exits here when the host is not clean.
_require_clean_host

trap 'cleanup_real_e2e "$?"' EXIT
trap '_cleanup_real_e2e_on_signal' INT TERM

export E2E_TEST_TIMEOUT="${E2E_TEST_TIMEOUT:-20}"
# Runs under sudo: without this, root-owned tests/**/__pycache__ lands in the
# checkout and the next non-root dh_clean (deb smoke) fails with EACCES.
export PYTHONDONTWRITEBYTECODE=1

echo "Running real-system end-to-end tests (timeout ${E2E_TEST_TIMEOUT}s)..."
mkdir -p "$REPO_ROOT/reports/distro-logs"
coverage run --data-file=.coverage.real-e2e -m unittest discover -s tests/e2e/real -t . \
    2>&1 | tee "$REPO_ROOT/reports/distro-logs/real-e2e.log"
echo "Real-system end-to-end tests completed successfully."
