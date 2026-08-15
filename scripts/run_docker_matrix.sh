#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/docker-utils.sh
source "$REPO_ROOT/scripts/docker-utils.sh"
DOCKER_BIN="${DOCKER_BIN:-docker}"
DOCKER_BUILD_CACHE_DIR="${DOCKER_BUILD_CACHE_DIR:-$REPO_ROOT/.cache/docker-buildx}"
MATRIX_RUN_ID="${MATRIX_RUN_ID:-$(date +%s)-$$}"
DRY_RUN=0
PARALLEL=1
COMPAT_ONLY=0
RUN_COVERAGE_GATE=0
SELECTED_DISTROS=()
ACTIVE_CONTAINERS=()
ACTIVE_PIDS=()
CLEANUP_RUNNING=0

# Always-on nine lanes (PR / local --full / compat). Do not shrink this list.
# Empty ASUS_CI_DE_FAMILY = stub/CLI. Full-DE variants use --de-family / CI job.
# Family splits (CI + local --distro-family) must stay in sync with DISTROS.
DISTRO_FAMILY_DEBIAN=(
    "ubuntu:26.04"
    "debian:trixie"
)
DISTRO_FAMILY_RHEL=(
    "fedora:44"
    "rocky:9"
    "almalinux:10"
)
DISTRO_FAMILY_SUSE_ARCH=(
    "opensuse/tumbleweed"
    "archlinux:latest"
    "opensuse/leap:16.0"
    "manjarolinux/base:latest"
)
DISTROS=(
    "${DISTRO_FAMILY_DEBIAN[@]}"
    "${DISTRO_FAMILY_RHEL[@]}"
    "${DISTRO_FAMILY_SUSE_ARCH[@]}"
)
DE_FAMILY="${ASUS_CI_DE_FAMILY:-}"
case "$DE_FAMILY" in
    ""|gnome|kde|xfce|lxqt|cinnamon|mate) ;;
    *)
        echo "Unsupported ASUS_CI_DE_FAMILY / DE_FAMILY: $DE_FAMILY" >&2
        echo "Allowed: gnome|kde|xfce|lxqt|cinnamon|mate (or empty)" >&2
        exit 1
        ;;
esac

# shellcheck source=scripts/docker_matrix_args.sh
source "$REPO_ROOT/scripts/docker_matrix_args.sh"

container_name_for_distro() {
    local image="$1"
    local distro_name="$image"
    echo "asus-zenbook-${distro_name//[^a-zA-Z0-9._-]/-}-${MATRIX_RUN_ID}"
}

register_active_container() {
    local name="$1"
    ACTIVE_CONTAINERS+=("$name")
}

register_active_pid() {
    local pid="$1"
    ACTIVE_PIDS+=("$pid")
}

cleanup_active_jobs_and_containers() {
    [[ "$CLEANUP_RUNNING" -eq 1 ]] && return
    CLEANUP_RUNNING=1
    _kill_active_pids
    _remove_active_containers
}

_kill_active_pids() {
    local pid
    for pid in ${ACTIVE_PIDS[@]+"${ACTIVE_PIDS[@]}"}; do
        _kill_pid_if_running "$pid"
    done
}

_kill_pid_if_running() {
    local pid="$1"
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
    fi
}

_remove_active_containers() {
    local name
    for name in ${ACTIVE_CONTAINERS[@]+"${ACTIVE_CONTAINERS[@]}"}; do
        "$DOCKER_BIN" rm -f "$name" >/dev/null 2>&1 || true
    done
}

handle_interrupt() {
    echo "Interrupted; stopping active Docker matrix containers..." >&2
    cleanup_active_jobs_and_containers
    exit 130
}

setup_signal_traps() {
    # Full container teardown only on interrupt; successful EXIT must not
    # docker-rm --rm containers that may already have exited cleanly.
    trap 'handle_interrupt' INT TERM HUP
    trap '_matrix_exit_handler $?' EXIT
}

_matrix_exit_handler() {
    local exit_status="$1"
    trap - EXIT
    _kill_active_pids
    if [ "$exit_status" -ne 0 ]; then
        _remove_active_containers
    fi
    exit "$exit_status"
}

dockerfile_for_distro() {
    local image
    image=$(_resolve_distro_image "$1")
    _distro_dockerfile "$image"
}

_resolve_distro_image() {
    local image="$1"
    if [[ "$image" == "coverage-gate" ]]; then
        # Lighter Debian base than Ubuntu for canonical kcov/Python coverage.
        echo "debian:trixie"
        return
    fi
    echo "$image"
}

_distro_family_images() {
    # Print family member images (one per line). Unknown family → exit 1.
    case "$1" in
        debian) printf '%s\n' "${DISTRO_FAMILY_DEBIAN[@]}" ;;
        rhel) printf '%s\n' "${DISTRO_FAMILY_RHEL[@]}" ;;
        suse-arch) printf '%s\n' "${DISTRO_FAMILY_SUSE_ARCH[@]}" ;;
        *)
            echo "Unsupported distro family: $1 (use debian|rhel|suse-arch)" >&2
            return 1
            ;;
    esac
}

_append_distro_family() {
    local family="$1" image
    while IFS= read -r image; do
        [[ -n "$image" ]] || continue
        SELECTED_DISTROS+=("$image")
    done < <(_distro_family_images "$family")
}

_distro_dockerfile() {
    local image="$1"
    local slug="${image//[:\/]/-}"
    local path="$REPO_ROOT/docker/images/tests/${slug}.Dockerfile"
    _echo_if_file_exists "$path"
}

_echo_if_file_exists() {
    local path="$1"
    if [[ -f "$path" ]]; then
        echo "$path"
        return
    fi
    echo ""
}

tag_for_distro() {
    # Stub/CLI image only (F1): full-DE installs packages at container start so
    # --de-family cells share the same tag/cache as distro-tests.
    local image slug
    image=$(_resolve_distro_image "$1")
    slug="${image//[:\/]/-}"
    echo "asus-zenbook-test:${slug}"
}

is_supported_distro() {
    local target="$1"
    local image
    for image in "${DISTROS[@]}"; do
        if [[ "$image" == "$target" ]]; then
            return 0
        fi
    done
    return 1
}

_matrix_tests_mode_flag() {
    # ASUS_COVERAGE_MODE selects coverage-gate job slices (CI); default = full tests-only.
    # ASUS_COVERAGE_SHARD=1|2 splits kcov/python work across matrix cells (merge job gates %).
    case "${ASUS_COVERAGE_MODE:-all}" in
        kcov) printf '%s\n' "--kcov-only" ;;
        python) printf '%s\n' "--python-coverage-only" ;;
        merge) printf '%s\n' "--coverage-merge-only" ;;
        all|"") printf '%s\n' "--tests-only" ;;
        *)
            echo "Unsupported ASUS_COVERAGE_MODE='${ASUS_COVERAGE_MODE}' (use all|kcov|python|merge)" >&2
            return 1
            ;;
    esac
}

_matrix_setup_tests_mode() {
    local mode="$1"
    if [[ "${mode}" == "compat-only" ]]; then
        printf '%s\n' "--compat-only"
        return 0
    fi
    _matrix_tests_mode_flag
}

_matrix_runtime_de_install_snippet() {
    # Emitted into the container setup script when ASUS_CI_FULL_DE=1 (F1).
    cat <<'RUNTIME_DE_EOF'
_asus_runtime_install_de_family() {
    local attempt=1 status=0 log
    log="$(mktemp)"
    trap 'rm -f "'"$log"'"' RETURN
    while [ "$attempt" -le 3 ]; do
        set +e
        sudo -n env ASUS_CI_DE_FAMILY="${ASUS_CI_DE_FAMILY}" \
            ./docker/images/tests/scripts/install-de-family.sh >"$log" 2>&1
        status=$?
        set -e
        cat "$log"
        if [ "$status" -eq 0 ]; then
            return 0
        fi
        if grep -Fq "unsupported ASUS_CI_DE_FAMILY" "$log"; then
            return "$status"
        fi
        echo "install-de-family attempt $attempt failed (status $status); retrying..." >&2
        attempt=$((attempt + 1))
    done
    return "$status"
}
_asus_runtime_install_de_family
RUNTIME_DE_EOF
}

_matrix_setup_env_exports() {
    local -n _de_ref="$1" _full_ref="$2" _runtime_ref="$3"
    _de_ref=""
    _full_ref=""
    _runtime_ref=""
    if [ -n "$DE_FAMILY" ]; then
        _de_ref="export ASUS_CI_DE_FAMILY=\"${DE_FAMILY}\""
    fi
    if [ "${ASUS_CI_FULL_DE:-}" = "1" ]; then
        _full_ref="export ASUS_CI_FULL_DE=1"
    fi
    if [ "${ASUS_CI_FULL_DE:-}" = "1" ] && [ -n "$DE_FAMILY" ]; then
        _runtime_ref="$(_matrix_runtime_de_install_snippet)"
    fi
}

build_setup_script() {
    local distro_slug="$1"
    local mode="$2"
    local tests_mode skip_python_coverage_reports=0
    local de_family_export="" full_de_export="" runtime_de_block=""
    tests_mode="$(_matrix_setup_tests_mode "$mode")" || return 1
    if [[ "${mode}" == "compat-only" ]]; then
        skip_python_coverage_reports=1
    fi
    _matrix_setup_env_exports de_family_export full_de_export runtime_de_block
    cat <<EOF
set -euo pipefail
export PATH="/opt/asus-zenbook-deps/.venv/bin:\${PATH}"
export REPORT_DISTRO_SLUG="${distro_slug}"
export REQUIRE_KCOV=1
export SKIP_PYTHON_COVERAGE_REPORTS=${skip_python_coverage_reports}
export ASUS_COVERAGE_MODE="${ASUS_COVERAGE_MODE:-all}"
export ASUS_COVERAGE_SHARD="${ASUS_COVERAGE_SHARD:-}"
${de_family_export}
${full_de_export}
${runtime_de_block}
# Start a real D-Bus session so gdbus, gsettings, and notify-send have a live bus
if command -v dbus-launch &>/dev/null; then
    eval "\$(dbus-launch --sh-syntax)"
fi
./scripts/build-and-test.sh ${tests_mode}
EOF
}

current_user_spec() {
    local uid gid uid_gid
    # Prefer SUDO_UID when matrix is invoked via sudo so containers match the
    # asusci account baked with ASUS_CI_UID (never run bind-mount tests as root).
    uid_gid=$(_docker_host_uid_gid) || return 1
    read -r uid gid <<< "$uid_gid" || return 1
    printf '%s:%s\n' "$uid" "$gid"
}

_validate_build_inputs() {
    local dockerfile_path="$1" tag="$2" distro="$3"
    if [[ -z "$dockerfile_path" || -z "$tag" ]]; then
        echo "Unsupported distro: $distro" >&2
        return 1
    fi
    if [[ ! -f "$dockerfile_path" ]]; then
        echo "Dockerfile not found for $distro: $dockerfile_path" >&2
        return 1
    fi
    return 0
}

build_repo_image() {
    local distro="$1"
    local dockerfile_path tag cache_key resolved

    dockerfile_path=$(dockerfile_for_distro "$distro")
    tag=$(tag_for_distro "$distro")
    _validate_build_inputs "$dockerfile_path" "$tag" "$distro" || return 1

    resolved=$(_resolve_distro_image "$distro")
    # F1: never bake DE into the image; cache key is distro-only (shared with stub lanes).
    cache_key=$(echo "$resolved" | tr '/:' '__')
    echo "Building test image $tag from $dockerfile_path"
    if [ -n "$DE_FAMILY" ]; then
        echo "  runtime ASUS_CI_DE_FAMILY=$DE_FAMILY (not baked into image)"
    fi
    ASUS_CI_DE_FAMILY="" docker_build_with_buildx_or_build \
        "$DOCKER_BIN" \
        "$dockerfile_path" \
        "$tag" \
        "$REPO_ROOT" \
        "$DOCKER_BUILD_CACHE_DIR" \
        "tests-$cache_key"
}

run_docker() {
    local image="$1"
    local runtime_image
    local container_name
    local setup_script

    if ! command -v "$DOCKER_BIN" >/dev/null 2>&1; then
        echo "Docker is not installed or not on PATH." >&2
        exit 1
    fi

    runtime_image=$(tag_for_distro "$image")
    container_name=$(container_name_for_distro "$image")
    register_active_container "$container_name"

    build_repo_image "$image"
    local distro_slug="${image//[:\/]/-}"
    if [[ "$COMPAT_ONLY" -eq 1 ]]; then
        setup_script=$(build_setup_script "$distro_slug" "compat-only")
    else
        setup_script=$(build_setup_script "$distro_slug" "full-tests")
    fi

    # Remove any stale container with the same name (e.g. from a previous Ctrl-C)
    "$DOCKER_BIN" rm -f "$container_name" 2>/dev/null || true

    echo "Running $image via $runtime_image"
    local user_spec
    user_spec=$(current_user_spec) || {
        echo "Failed to resolve container user (UID:GID)" >&2
        return 1
    }
    "$DOCKER_BIN" run --rm --name "$container_name" \
        --user "$user_spec" \
        -v "$REPO_ROOT:/workspace" \
        -w /workspace \
        "$runtime_image" \
        /bin/bash -lc "$setup_script"
}

run_target() {
    local image="$1"
    if [[ "$DRY_RUN" == "1" ]]; then
        local dockerfile_path
        local tag
        dockerfile_path=$(dockerfile_for_distro "$image")
        tag=$(tag_for_distro "$image")
        echo "[dry-run] Would build $tag from $dockerfile_path"
        if [ -n "$DE_FAMILY" ]; then
            echo "[dry-run] ASUS_CI_DE_FAMILY=$DE_FAMILY (runtime install-de-family)"
        fi
        if [[ "$COMPAT_ONLY" -eq 1 ]]; then
            echo "[dry-run] Would run compatibility-only pipeline on $image"
        else
            echo "[dry-run] Would run full tests-only pipeline on $image"
        fi
        return 0
    fi
    if [[ "$COMPAT_ONLY" -eq 1 ]]; then
        echo "Running compatibility-only pipeline on $image"
    else
        echo "Running full tests-only pipeline on $image"
    fi
    run_docker "$image"
}

_print_distro_log() {
    local name="$1" log="$2"
    printf '\n%s\n' "══════════════════════════════════════"
    printf '  FAILURE LOG: %s\n' "$name"
    printf '%s\n\n' "══════════════════════════════════════"
    cat "$log"
}

_print_failure_details() {
    local -n __names="$1" __logs="$2" __failing_indices="$3"
    local idx
    for idx in "${__failing_indices[@]}"; do
        _print_distro_log "${__names[$idx]}" "${__logs[$idx]}"
    done
}

_collect_parallel_results() {
    local -n _pids="$1" _names="$2" _logs="$3"
    local idx code failures=0
    local failing_indices=()
    for idx in "${!_pids[@]}"; do
        code=0
        wait "${_pids[$idx]}" || code=$?
        if [[ "$code" -eq 0 ]]; then
            printf '  ✓ Passed: %s\n' "${_names[$idx]}"
        else
            printf '  ✗ Failed: %s  →  %s\n' "${_names[$idx]}" "${_logs[$idx]}" >&2
            failures=1
            failing_indices+=("$idx")
        fi
    done
    _print_failure_details _names _logs failing_indices
    return "$failures"
}

_run_targets_dry() {
    local image
    for image in "$@"; do
        run_target "$image"
    done
}

_restore_buildx_skip_prune() {
    local had_skip_prune="$1" saved_skip_prune="$2"
    if [ "$had_skip_prune" = 1 ]; then
        DOCKER_BUILDX_SKIP_PRUNE="$saved_skip_prune"
    else
        unset DOCKER_BUILDX_SKIP_PRUNE
    fi
}

run_targets_parallel() {
    # In dry-run mode, just run sequentially so output isn't redirected.
    if [[ "$DRY_RUN" == "1" ]]; then
        _run_targets_dry "$@"
        return
    fi
    # Parallel buildx jobs can race with local cache pruning/removal.
    local had_skip_prune=0 saved_skip_prune=""
    if [ "${DOCKER_BUILDX_SKIP_PRUNE+x}" = "x" ]; then
        had_skip_prune=1
        saved_skip_prune="$DOCKER_BUILDX_SKIP_PRUNE"
    fi
    export DOCKER_BUILDX_SKIP_PRUNE=1
    local log_dir="$REPO_ROOT/reports/distro-logs"
    mkdir -p "$log_dir"
    local pids=() names=() logs=()
    local image slug log container_name
    for image in "$@"; do
        slug="${image//[:\/]/-}"
        log="$log_dir/${slug}.log"
        logs+=("$log")
        container_name=$(container_name_for_distro "$image")
        register_active_container "$container_name"
        printf '  ▶ Launching: %s  →  reports/distro-logs/%s.log\n' "$image" "$slug"
        (
            trap - EXIT INT TERM
            run_target "$image" 2>&1 | tee "$log"
        ) &
        pids+=("$!")
        register_active_pid "$!"
        names+=("$image")
    done
    printf '\nWaiting for all distros...\n'
    local failures=0
    _collect_parallel_results pids names logs || failures=$?
    _restore_buildx_skip_prune "$had_skip_prune" "$saved_skip_prune"
    _docker_prune_buildx_local_cache "$DOCKER_BUILD_CACHE_DIR" "$DOCKER_BUILD_CACHE_DIR"
    return "$failures"
}

_print_target_distros() {
    local image distro_name
    echo "Target distros:"
    for image in "$@"; do
        # Path first (handles registry:port/...), then digest/tag — not %%:* first.
        distro_name="${image##*/}"
        distro_name="${distro_name%%@*}"
        distro_name="${distro_name%%:*}"
        echo "- $distro_name -> $image"
    done
}

_run_one_serial_target() {
    local image="$1" log="$2" code=0
    if [[ "$DRY_RUN" == "1" ]]; then
        run_target "$image" || code=$?
    else
        run_target "$image" 2>&1 | tee "$log" || code=${PIPESTATUS[0]:-1}
    fi
    return "$code"
}

_report_serial_target() {
    local image="$1" log="$2" code="$3"
    if [[ "$code" -ne 0 ]]; then
        printf '  ✗ Failed: %s  →  %s\n' "$image" "$log" >&2
        return 1
    fi
    printf '  ✓ Passed: %s\n' "$image"
}

_run_serial_targets() {
    local image log_dir="$REPO_ROOT/reports/distro-logs"
    local slug log failures=0 code
    mkdir -p "$log_dir"
    for image in "$@"; do
        slug="${image//[:\/]/-}"
        log="$log_dir/${slug}.log"
        code=0
        _run_one_serial_target "$image" "$log" || code=$?
        _report_serial_target "$image" "$log" "$code" || failures=1
    done
    return "$failures"
}

_run_all_targets() {
    if [[ "$PARALLEL" -eq 1 && $# -gt 1 ]]; then
        run_targets_parallel "$@"
        return $?
    fi
    _run_serial_targets "$@"
}

main() {
    setup_signal_traps
    parse_args "$@"
    validate_mode_selection

    local targets=()
    if [[ "$RUN_COVERAGE_GATE" -eq 1 ]]; then
        targets=("coverage-gate")
    elif [[ "${#SELECTED_DISTROS[@]}" -gt 0 ]]; then
        _validate_selected_distros
        targets=("${SELECTED_DISTROS[@]}")
    else
        targets=("${DISTROS[@]}")
    fi

    _print_target_distros "${targets[@]}"
    _run_all_targets "${targets[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
