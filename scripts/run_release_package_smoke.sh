#!/usr/bin/env bash
# Build every release package kind (same matrix as tag workflow build-packages).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="${REPO_ROOT}/reports/distro-logs"
ARTIFACTS_ROOT="${ASUS_RELEASE_ARTIFACTS_DIR:-$REPO_ROOT/artifacts}"
PARALLEL="${ASUS_RELEASE_PACKAGE_SMOKE_PARALLEL:-0}"

# shellcheck source=scripts/release_package_kinds.sh
source "${SCRIPT_DIR}/release_package_kinds.sh"
# shellcheck source=scripts/docker-utils.sh
source "${SCRIPT_DIR}/docker-utils.sh"

_usage() {
    cat <<EOF
Usage: $(basename "$0") [--all | KIND ...]

Build release packages and assert exactly one artifact per kind.
Kinds: ${RELEASE_PACKAGE_KINDS[*]}

Environment:
  ASUS_RELEASE_PACKAGE_SMOKE_PARALLEL=1  run kinds concurrently (separate artifact dirs)
  ASUS_RELEASE_INSTALL_SMOKE=1           install/remove each built package (default: 1)
  ASUS_RELEASE_SKIP_HOST_DEPS=1          skip prepare_release_package_host_deps.sh
EOF
}

_require_tool() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing required tool: %s\n' "$1" >&2
        return 1
    }
}

_release_smoke_wipe_kind_staging() {
    local kind="$1" artifacts_dir="$2"
    _release_wipe_dir_contents "$REPO_ROOT" "$artifacts_dir"
    if [[ "$kind" == rpm-* ]]; then
        _release_docker_rm "$REPO_ROOT" "${REPO_ROOT}/.rpm-build-${kind}"
    fi
    if [ "$kind" = "arch" ]; then
        _release_docker_rm "$REPO_ROOT" \
            "${REPO_ROOT}/packaging/arch/pkg" \
            "${REPO_ROOT}/packaging/arch/src"
    fi
}

_release_smoke_build_kind() {
    local kind="$1" artifacts_dir="$2" log_file="$3"
    (
        set -euo pipefail
        export ASUS_RELEASE_INSTALL_SMOKE="${ASUS_RELEASE_INSTALL_SMOKE:-1}"
        export ASUS_RELEASE_ARTIFACTS_DIR="$artifacts_dir"
        "${SCRIPT_DIR}/build_release_package.sh" "$kind"
    ) 2>&1 | tee "$log_file"
}

_release_smoke_validate_kind() {
    local kind="$1" artifacts_dir="$2" log_file="$3"
    (
        set -euo pipefail
        _release_pkg_validate_artifact "$kind" "$artifacts_dir" >/dev/null
    ) 2>&1 | tee -a "$log_file"
}

_release_smoke_install_kind() {
    local kind="$1" artifacts_dir="$2" log_file="$3"
    (
        set -euo pipefail
        # shellcheck source=scripts/release_package_install_smoke.sh
        source "${SCRIPT_DIR}/release_package_install_smoke.sh"
        _release_pkg_install_smoke "$kind" "$artifacts_dir"
    ) 2>&1 | tee -a "$log_file"
}

_build_one_kind() {
    local kind="$1"
    local artifacts_dir="${ARTIFACTS_ROOT}/${kind}"
    local log_file="${LOG_DIR}/release-package-smoke-${kind}.log"
    mkdir -p "$LOG_DIR"
    _release_smoke_wipe_kind_staging "$kind" "$artifacts_dir"
    _release_smoke_build_kind "$kind" "$artifacts_dir" "$log_file" || return 1
    _release_smoke_validate_kind "$kind" "$artifacts_dir" "$log_file" || return 1
    if [ "${ASUS_RELEASE_INSTALL_SMOKE:-1}" = "1" ]; then
        _release_smoke_install_kind "$kind" "$artifacts_dir" "$log_file" || return 1
    fi
    printf 'Release package smoke passed (%s).\n' "$kind"
}

_run_kinds_sequential() {
    local kind=""
    for kind in "$@"; do
        _build_one_kind "$kind"
    done
}

_run_kinds_spawn_workers() {
    local kind=""
    local -n _rk_pids="$1" _rk_kinds="$2"
    shift 2
    for kind in "$@"; do
        setsid bash -c '
            set -euo pipefail
            cd "$1"
            ASUS_RELEASE_PACKAGE_SMOKE_PARALLEL=0 \
                ASUS_RELEASE_SKIP_HOST_DEPS=1 \
                ./scripts/run_release_package_smoke.sh "$2"
        ' bash "$REPO_ROOT" "$kind" &
        _rk_pids+=("$!")
        _rk_kinds+=("$kind")
    done
}

_run_kinds_wait_one() {
    local -n _rw_pids="$1" _rw_kinds="$2" _rw_failed="$3"
    local i=0 completed_pid="" completed_status=0
    completed_status=0
    wait -n -p completed_pid "${_rw_pids[@]}" || completed_status=$?
    for i in "${!_rw_pids[@]}"; do
        [ "${_rw_pids[$i]}" = "$completed_pid" ] || continue
        if [ "$completed_status" -ne 0 ]; then
            printf 'Release package smoke failed (%s).\n' "${_rw_kinds[$i]}" >&2
            _rw_failed=1
        fi
        unset '_rw_pids[i]'
        break
    done
}

_run_kinds_kill_remaining() {
    local -n _rk_pids="$1"
    local i=0
    local -a remaining=()
    for i in "${!_rk_pids[@]}"; do
        if kill -0 "${_rk_pids[$i]}" 2>/dev/null; then
            remaining+=("${_rk_pids[$i]}")
        fi
    done
    if [ "${#remaining[@]}" -gt 0 ]; then
        _kill_pgid_list "${remaining[@]}"
    fi
}

_run_kinds_parallel() {
    local pending=0 failed=0
    local -a pids=() kinds=()
    _run_kinds_spawn_workers pids kinds "$@"
    pending=${#pids[@]}
    while [ "$pending" -gt 0 ]; do
        _run_kinds_wait_one pids kinds failed
        pending=$((pending - 1))
        [ "$failed" -ne 0 ] && break
    done
    if [ "$failed" -ne 0 ]; then
        _run_kinds_kill_remaining pids
        return 1
    fi
    return 0
}

_collect_requested_kinds() {
    REQUESTED_KINDS=()
    if [ "$#" -eq 0 ] || [ "${1:-}" = "--all" ]; then
        REQUESTED_KINDS=("${RELEASE_PACKAGE_KINDS[@]}")
        return 0
    fi
    local kind=""
    for kind in "$@"; do
        if ! _release_pkg_kind_is_valid "$kind"; then
            echo "Unknown package kind: $kind" >&2
            _usage >&2
            return 1
        fi
        REQUESTED_KINDS+=("$kind")
    done
}

_prepare_release_smoke_host() {
    mkdir -p "$LOG_DIR" "$ARTIFACTS_ROOT"
    chmod +x "${SCRIPT_DIR}/build_release_package.sh" \
        "${SCRIPT_DIR}/prepare_release_package_host_deps.sh" \
        "${REPO_ROOT}/packaging/stage-payload.sh" \
        "${REPO_ROOT}/packaging/asus-zenbook-configure"
}

_prepare_portable_host_deps() {
    local kind=""
    for kind in "$@"; do
        case "$kind" in
            appimage | flatpak | snap)
                "${SCRIPT_DIR}/prepare_release_package_host_deps.sh" "$kind"
                ;;
        esac
    done
}

_run_requested_release_kinds() {
    local -a requested=("$@")
    if [ "$PARALLEL" = "1" ]; then
        _run_kinds_parallel "${requested[@]}"
        return $?
    fi
    _run_kinds_sequential "${requested[@]}"
}

main() {
    local -a requested=()
    set -o pipefail
    cd "$REPO_ROOT"
    _prepare_release_smoke_host
    _collect_requested_kinds "$@" || exit 1
    requested=("${REQUESTED_KINDS[@]}")
    _require_tool docker
    if [ "${ASUS_RELEASE_SKIP_HOST_DEPS:-0}" != "1" ]; then
        _prepare_portable_host_deps "${requested[@]}"
    fi
    _run_requested_release_kinds "${requested[@]}"
    printf 'All release package smoke builds passed (%s).\n' "${#requested[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
