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
CONTAINER_NAME="asus-zenbook-lints-py313-${MATRIX_RUN_ID}"

_lint_soft() { "$@" || return 0; }

HOST_UID=""
HOST_GID=""
LINT_HOME="/tmp/asus-lint-home-${HOST_UID}"
LOG_DIR="$REPO_ROOT/reports/distro-logs"
LOG_FILE="$LOG_DIR/lint-python-3.13-slim.log"
BUILD_LOG="$LOG_DIR/lint-python-3.13-slim-build.log"
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

_build_lint_image() {
    local build_status
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
    return "$build_status"
}

_lint_setup
_build_lint_image

setup_script=$(cat <<EOF
set -euo pipefail
export LANG="\${LANG:-C.UTF-8}"
export LC_ALL="\${LC_ALL:-C.UTF-8}"
export PATH="/opt/asus-zenbook-deps/.venv/bin:\${PATH}"
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
    -v "$REPO_ROOT:/workspace" \
    -w /workspace \
    "$DOCKER_IMAGE" \
    /bin/bash -lc "$setup_script" 2>&1 | tee "$LOG_FILE"
exit "${PIPESTATUS[0]}"
