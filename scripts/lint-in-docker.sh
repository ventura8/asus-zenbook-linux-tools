#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/docker-utils.sh
source "$SCRIPT_DIR/docker-utils.sh"
DOCKER_BIN="${DOCKER_BIN:-docker}"
DOCKER_IMAGE="${DOCKER_LINT_IMAGE:-asus-zenbook-lint:py313}"
DOCKERFILE_PATH="${DOCKER_LINT_DOCKERFILE:-$REPO_ROOT/docker/images/lint/python-3.13-slim.Dockerfile}"
DOCKER_BUILD_CACHE_DIR="${DOCKER_BUILD_CACHE_DIR:-$REPO_ROOT/.cache/docker-buildx}"
MATRIX_RUN_ID="${MATRIX_RUN_ID:-$(date +%s)-$$}"
# Parallel wave containers need unique names (CI/local ASUS_LINT_WAVE matrix).
LINT_WAVE_SLUG="${ASUS_LINT_WAVE:-all}"
CONTAINER_NAME="asus-zenbook-lints-py313-${LINT_WAVE_SLUG}-${MATRIX_RUN_ID}"

_lint_soft() { "$@" || return 0; }

HOST_UID=""
HOST_GID=""
LINT_HOME="/tmp/asus-lint-home-${HOST_UID}"
LOG_DIR="$REPO_ROOT/reports/distro-logs"
LOG_FILE="$LOG_DIR/lint-docker-${LINT_WAVE_SLUG}.log"
# Per-wave build log so cheap∥heavy parallel hosts do not clobber tee output.
BUILD_LOG="$LOG_DIR/lint-python-3.13-slim-build-${LINT_WAVE_SLUG}.log"
# Repo-local mkdir lock (avoid predictable /tmp symlink traps under sudo --full).
LINT_BUILDX_LOCK_ROOT="${LINT_BUILDX_LOCK_ROOT:-${DOCKER_BUILD_CACHE_DIR}/.locks}"
mkdir -p "$LOG_DIR"

_LINT_BUILD_PID=""

_lint_stop_active_build() {
    if [ -z "${_LINT_BUILD_PID:-}" ]; then
        return 0
    fi
    if kill -0 "$_LINT_BUILD_PID" 2>/dev/null; then
        # Negative PID: terminate the setsid process group (docker build + tee).
        _lint_soft kill -TERM -- "-$_LINT_BUILD_PID" 2>/dev/null
    fi
    _lint_soft wait "$_LINT_BUILD_PID" 2>/dev/null
}

_lint_docker_handle_interrupt() {
    echo ""
    echo "Interrupted. Stopping lint container $CONTAINER_NAME..."
    _lint_stop_active_build
    _lint_soft "$DOCKER_BIN" stop "$CONTAINER_NAME" >/dev/null 2>&1
    _lint_soft "$DOCKER_BIN" rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    exit 130
}
trap _lint_docker_handle_interrupt INT TERM HUP

_lint_setup() {
    local uid_gid
    if ! command -v "$DOCKER_BIN" >/dev/null 2>&1; then
        echo "Docker is not installed or not on PATH." >&2
        return 1
    fi
    uid_gid=$(_docker_host_uid_gid) || return 1
    read -r HOST_UID HOST_GID <<< "$uid_gid" || return 1
    LINT_HOME="/tmp/asus-lint-home-${HOST_UID}"
    mkdir -p "$LOG_DIR"
    if [[ ! -f "$DOCKERFILE_PATH" ]]; then
        echo "Lint Dockerfile not found: $DOCKERFILE_PATH" >&2
        return 1
    fi
}

_lint_release_build_lock() {
    local lock_dir="$1"
    [ -n "${lock_dir:-}" ] || return 0
    rm -f "${lock_dir}/owner.pid" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true
}

_lint_acquire_build_lock() {
    local -n _lint_lock_dir_ref="$1"
    local lock_root="" lock_dir="" deadline=$((SECONDS + ${DOCKER_BUILDX_LOCK_TIMEOUT_SECS:-1200}))
    _lint_lock_dir_ref=""
    lock_root="${LINT_BUILDX_LOCK_ROOT}"
    mkdir -p "$lock_root" || return 1
    # 755, not 700: shares this root with docker-utils.sh's lock (same path)
    # and must stay traversable by an unprivileged $SUDO_USER concurrently
    # running dh_clean's repo-wide find under `sudo --full` (see docker-utils.sh).
    chmod 755 "$lock_root" 2>/dev/null || true
    # Wave-independent: cheap∥heavy contend on one lock; docker_build also
    # serializes via the shared lint-python-3.13-slim cache-key lock.
    lock_dir="${lock_root}/lint-image"
    _docker_wait_mkdir_lock "$lock_dir" "$deadline" || return 1
    _docker_trap_add "_lint_release_build_lock '$lock_dir'" EXIT INT TERM
    if ! echo "$$" > "${lock_dir}/owner.pid" 2>/dev/null; then
        echo "Failed to record lint buildx lock owner: $lock_dir" >&2
        _lint_release_build_lock "$lock_dir"
        return 1
    fi
    _lint_lock_dir_ref="$lock_dir"
}

_build_lint_image() {
    local build_status lint_lock_dir=""
    # Cheap∥heavy share lint-image mkdir lock + lint-python-3.13-slim cache lock.
    _lint_acquire_build_lock lint_lock_dir || return 1
    set +e
    # setsid: tracked PID is the process-group leader of docker build + tee.
    setsid bash -c '
        set -o pipefail
        # shellcheck source=scripts/docker-utils.sh
        source "$1"
        docker_build_with_buildx_or_build \
            "$2" "$3" "$4" "$5" "$6" "$7" 2>&1 | tee "$8"
    ' bash \
        "$SCRIPT_DIR/docker-utils.sh" \
        "$DOCKER_BIN" \
        "$DOCKERFILE_PATH" \
        "$DOCKER_IMAGE" \
        "$REPO_ROOT" \
        "$DOCKER_BUILD_CACHE_DIR" \
        "lint-python-3.13-slim" \
        "$BUILD_LOG" &
    _LINT_BUILD_PID=$!
    wait "$_LINT_BUILD_PID"
    build_status=$?
    _LINT_BUILD_PID=""
    set -e
    _lint_release_build_lock "$lint_lock_dir"
    return "$build_status"
}

_lint_setup
_build_lint_image

setup_script=$(cat <<EOF
set -euo pipefail
export LANG="\${LANG:-C.UTF-8}"
export LC_ALL="\${LC_ALL:-C.UTF-8}"
export PATH="/opt/asus-zenbook-deps/.venv/bin:\${PATH}"
export ASUS_LINT_WAVE="${LINT_WAVE_SLUG}"
mkdir -p "\${HOME}" reports .ruff_cache .cache
./scripts/run-lints.sh
# Avoid recursively chowning docker-buildx cache (root-owned host mount).
# Only normalize ownership when the container is actually root (normal --user runs skip).
if [ "\$(id -u)" -eq 0 ]; then
    chown -R ${HOST_UID}:${HOST_GID} reports .ruff_cache 2>/dev/null || \
        echo "Warning: could not chown lint artifacts to ${HOST_UID}:${HOST_GID}" >&2
    if [ -d .cache ]; then
        find .cache -mindepth 1 -maxdepth 1 ! -name docker-buildx \
            -exec chown -R ${HOST_UID}:${HOST_GID} {} + 2>/dev/null || \
            echo "Warning: could not chown .cache lint artifacts to ${HOST_UID}:${HOST_GID}" >&2
    fi
fi
EOF
)

"$DOCKER_BIN" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || :
"$DOCKER_BIN" run --rm --name "$CONTAINER_NAME" \
    --user "${HOST_UID}:${HOST_GID}" \
    --env "HOME=${LINT_HOME}" \
    --env "ASUS_LINT_WAVE=${LINT_WAVE_SLUG}" \
    -v "$REPO_ROOT:/workspace" \
    -w /workspace \
    "$DOCKER_IMAGE" \
    /bin/bash -lc "$setup_script" 2>&1 | tee "$LOG_FILE"
exit "${PIPESTATUS[0]}"
