#!/usr/bin/env bash
# Mode dispatch helpers for build-and-test.sh (sourced).

_BUILD_MODES_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${_DOCKER_UTILS_LOADED:-}" ]; then
    # shellcheck source=scripts/docker-utils.sh
    source "${_BUILD_MODES_SCRIPT_DIR}/docker-utils.sh"
    _DOCKER_UTILS_LOADED=1
fi

_parallel_gate_pids=()
_parallel_gate_labels=()

_reset_parallel_gate_workers() {
    _parallel_gate_pids=()
    _parallel_gate_labels=()
}

_pipeline_mode_from_flag_primary() {
    case "$1" in
        --full) printf '%s\n' full ;;
        --lints-only) printf '%s\n' lints-only ;;
        --tests-only) printf '%s\n' tests-only ;;
        *) return 1 ;;
    esac
}

_pipeline_mode_from_flag_extra() {
    case "$1" in
        --kcov-only) printf '%s\n' kcov-only ;;
        --python-coverage-only) printf '%s\n' python-coverage-only ;;
        --coverage-merge-only) printf '%s\n' coverage-merge-only ;;
        --compat-only) printf '%s\n' compat-only ;;
        *) return 1 ;;
    esac
}

_set_pipeline_mode_flag() {
    local mapped=""
    mapped="$(_pipeline_mode_from_flag_primary "$1" || _pipeline_mode_from_flag_extra "$1")" || return 1
    MODE="$mapped"
}

_fill_python_coverage_shard_steps() {
    case "${ASUS_COVERAGE_SHARD:-}" in
        1)
            MODE_STEPS=(step_unit_tests step_export_python_coverage_shard)
            ;;
        2)
            MODE_STEPS=(step_e2e_tests step_export_python_coverage_shard)
            ;;
        "")
            MODE_STEPS=(step_unit_tests step_e2e_tests step_python_coverage)
            ;;
        *)
            echo "Unsupported ASUS_COVERAGE_SHARD='${ASUS_COVERAGE_SHARD}' (use 1|2 or empty)" >&2
            return 1
            ;;
    esac
    return 0
}

_fill_mode_steps_coverage() {
    local mode="$1"
    case "$mode" in
        tests-only)
            MODE_STEPS=(step_unit_tests step_kcov_coverage step_e2e_tests step_python_coverage)
            return 0
            ;;
        kcov-only)
            MODE_STEPS=(step_kcov_coverage)
            return 0
            ;;
        python-coverage-only)
            _fill_python_coverage_shard_steps
            return $?
            ;;
        coverage-merge-only)
            MODE_STEPS=(step_coverage_merge)
            return 0
            ;;
    esac
    return 1
}

_fill_mode_steps() {
    local mode="$1"
    MODE_STEPS=()
    case "$mode" in
        lints-only)
            MODE_STEPS=(step_lint_waves_parallel)
            ;;
        compat-only)
            MODE_STEPS=(step_unit_tests step_e2e_tests step_distro_compat_smoke)
            ;;
        full)
            MODE_STEPS=(
                step_preflight_clean_build_trees
                step_lint_and_deb_parallel
                step_post_lint_gates_parallel
                step_coverage_merge_host
            )
            ;;
        *)
            if _fill_mode_steps_coverage "$mode"; then
                return 0
            fi
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
    # Host may only orchestrate Docker for lint/full. These modes run product
    # unit/kcov/e2e on the host and must execute inside a matrix container.
    # coverage-merge-only is host-allowed (merge exported shards; no product tests).
    case "$MODE" in
        tests-only|compat-only|kcov-only|python-coverage-only) return 0 ;;
    esac
    return 1
}

_run_lint_wave_in_docker() {
    local wave="$1"
    set -euo pipefail
    export ASUS_LINT_WAVE="$wave"
    if ! ./scripts/lint-in-docker.sh 2>&1 | tee "$DISTRO_LOG_DIR/lint-docker-${wave}.log"; then
        return 1
    fi
}

_with_buildx_skip_prune() {
    # Parallel docker buildx jobs can race with local cache pruning/removal.
    local had_skip_prune=0 saved_skip_prune="" status=0
    if [ "${DOCKER_BUILDX_SKIP_PRUNE+x}" = "x" ]; then
        had_skip_prune=1
        saved_skip_prune="$DOCKER_BUILDX_SKIP_PRUNE"
    fi
    export DOCKER_BUILDX_SKIP_PRUNE=1
    "$@"
    status=$?
    if [ "$had_skip_prune" = 1 ]; then
        DOCKER_BUILDX_SKIP_PRUNE="$saved_skip_prune"
    else
        unset DOCKER_BUILDX_SKIP_PRUNE
    fi
    return "$status"
}

_parallel_lint_waves_skip_prune() {
    _with_buildx_skip_prune "$@"
}

_prune_buildx_cache_after_parallel() {
    local cache_dir="${DOCKER_BUILD_CACHE_DIR:-$REPO_ROOT/.cache/docker-buildx}"
    _docker_prune_buildx_local_cache "$cache_dir" "$cache_dir" || true
}

step_lint_waves_parallel() {
    # Host: cheap ∥ heavy lint containers. Inside a lint image: run-lints.sh only.
    local cheap_status=0 heavy_status=0 cheap_pid heavy_pid
    start_step "Running lint waves in Docker (cheap ∥ heavy)..."
    _ensure_distro_logs_dir
    if is_container_runtime; then
        if ! ./scripts/run-lints.sh 2>&1 | tee "$DISTRO_LOG_DIR/run-lints.log"; then
            echo "  ✗ Lint gate failed." >&2
            exit 1
        fi
        echo "  ✓ Lint waves passed."
        return 0
    fi
    _parallel_lint_waves_skip_prune _step_lint_waves_parallel_host
}

_step_lint_waves_parallel_host() {
    local cheap_status=0 heavy_status=0 cheap_pid heavy_pid
    _run_lint_wave_in_docker cheap &
    cheap_pid=$!
    _run_lint_wave_in_docker heavy &
    heavy_pid=$!
    _wait_bg_status "$cheap_pid" "lint-cheap" cheap_status
    _wait_bg_status "$heavy_pid" "lint-heavy" heavy_status
    if [ "$cheap_status" -ne 0 ] || [ "$heavy_status" -ne 0 ]; then
        echo "  ✗ Docker lint gate failed." >&2
        exit 1
    fi
    echo "  ✓ Lint waves passed."
}

step_preflight_clean_build_trees() {
    start_step "Cleaning stale release build trees before lint..."
    _ensure_distro_logs_dir
    if is_container_runtime; then
        return 0
    fi
    if ! command -v docker >/dev/null 2>&1; then
        echo "  ✗ docker required for preflight cleanup." >&2
        exit 1
    fi
    # shellcheck source=scripts/release_package_kinds.sh
    source "$REPO_ROOT/scripts/release_package_kinds.sh"
    _release_docker_rm_rpm_build_trees "$REPO_ROOT"
    _release_docker_rm_arch_staging "$REPO_ROOT"
    _release_docker_rm_portable_staging "$REPO_ROOT"
    echo "  ✓ Stale build trees cleared."
}

step_lint_and_deb_parallel() {
    # Mirror CI: lint cheap ∥ lint heavy ∥ deb-package (deb uses nocheck — no host tests).
    local cheap_status=0 heavy_status=0 deb_status=0
    local cheap_pid heavy_pid deb_pid
    start_step "Running lint waves ∥ Debian package smoke in parallel..."
    _ensure_distro_logs_dir
    if is_container_runtime; then
        echo "  ✗ step_lint_and_deb_parallel is host-orchestrator only." >&2
        exit 1
    fi
    _parallel_lint_waves_skip_prune _step_lint_and_deb_parallel_host
}

_step_lint_and_deb_parallel_host() {
    local cheap_status=0 heavy_status=0 deb_status=0
    local cheap_pid heavy_pid deb_pid
    _run_lint_wave_in_docker cheap &
    cheap_pid=$!
    _run_lint_wave_in_docker heavy &
    heavy_pid=$!
    setsid bash -c '
        set -o pipefail
        cd "$1"
        ./scripts/run_deb_package_smoke.sh 2>&1 | tee "$2"
    ' bash "$REPO_ROOT" "$DISTRO_LOG_DIR/deb-package.log" &
    deb_pid=$!
    _wait_bg_status "$cheap_pid" "lint-cheap" cheap_status
    _wait_bg_status "$heavy_pid" "lint-heavy" heavy_status
    _wait_bg_status "$deb_pid" "deb-package" deb_status
    if [ "$cheap_status" -ne 0 ] || [ "$heavy_status" -ne 0 ]; then
        echo "  ✗ Docker lint gate failed." >&2
        _kill_bg_pids "$deb_pid"
        exit 1
    fi
    if [ "$deb_status" -ne 0 ]; then
        echo "  ✗ Debian package smoke failed." >&2
        exit 1
    fi
    echo "  ✓ Lint waves and Debian package smoke passed."
}

_start_release_smoke_worker() {
    local log_path="$1"
    local skip_host_deps="$2"
    local label="$3"
    shift 3
    setsid bash -c '
        set -o pipefail
        cd "$1"
        log_file="$2"
        chmod +x ./scripts/run_release_package_smoke.sh \
            ./scripts/build_release_package.sh \
            ./scripts/prepare_release_package_host_deps.sh \
            ./packaging/stage-payload.sh \
            ./packaging/asus-zenbook-configure
        export ASUS_RELEASE_INSTALL_SMOKE=1
        export ASUS_RELEASE_PACKAGE_SMOKE_PARALLEL=1
        export ASUS_RELEASE_SKIP_HOST_DEPS="$3"
        shift 3
        ./scripts/run_release_package_smoke.sh "$@" \
            2>&1 | tee "$log_file"
    ' bash "$REPO_ROOT" "$log_path" "$skip_host_deps" "$@" &
    _parallel_gate_pids+=("$!")
    _parallel_gate_labels+=("$label")
}

_step_post_lint_release_native_worker() {
    _start_release_smoke_worker "$DISTRO_LOG_DIR/release-package-native-smoke.log" 1 \
        "release-package-native-smoke" \
        rpm-fedora-44 rpm-rocky-10 rpm-opensuse-tw arch
}

_step_post_lint_release_portable_worker() {
    _start_release_smoke_worker "$DISTRO_LOG_DIR/release-package-portable-smoke.log" 0 \
        "release-package-portable-smoke" \
        appimage flatpak snap
}

_wait_bg_status() {
    # Wait on pid; print label on failure. Echo status via nameref.
    local pid="$1" label="$2" status_ref="$3" code=0
    set +e
    wait "$pid"
    code=$?
    set -e
    printf -v "$status_ref" '%s' "$code"
    if [ "$code" -ne 0 ]; then
        echo "  ✗ Failed: $label" >&2
    fi
}

_kill_bg_pids() {
    _kill_pgid_list "$@"
}

_wait_bg_handle_done() {
    # nameref: pids_ref labels_ref; args: done_pid code → 0 continue, 1 fail-fast
    local -n _wb_pids="$1" _wb_labels="$2"
    local done_pid="$3" code="$4" i=0
    for i in "${!_wb_pids[@]}"; do
        if [ "${_wb_pids[$i]}" != "$done_pid" ]; then
            continue
        fi
        if [ "$code" -ne 0 ]; then
            echo "  ✗ Failed: ${_wb_labels[$i]}" >&2
            unset "_wb_pids[i]" "_wb_labels[i]"
            _wb_pids=("${_wb_pids[@]}")
            _wb_labels=("${_wb_labels[@]}")
            _kill_bg_pids "${_wb_pids[@]}"
            return 1
        fi
        echo "  ✓ Passed: ${_wb_labels[$i]}"
        unset "_wb_pids[i]" "_wb_labels[i]"
        _wb_pids=("${_wb_pids[@]}")
        _wb_labels=("${_wb_labels[@]}")
        return 0
    done
    echo "  ✗ wait -n completed unknown PID: $done_pid" >&2
    _kill_bg_pids "${_wb_pids[@]}"
    return 1
}

_wait_bg_jobs_fail_fast() {
    # Wait for any background job; on first failure kill siblings and return 1.
    local -a pids=("${_parallel_gate_pids[@]}")
    local -a labels=("${_parallel_gate_labels[@]}")
    local done_pid="" code=0

    while [ "${#pids[@]}" -gt 0 ]; do
        done_pid=""
        set +e
        wait -n -p done_pid "${pids[@]}"
        code=$?
        set -e
        if [ -z "$done_pid" ]; then
            echo "  ✗ wait -n returned without a completed PID" >&2
            _kill_bg_pids "${pids[@]}"
            return 1
        fi
        _wait_bg_handle_done pids labels "$done_pid" "$code" || return 1
    done
    return 0
}

_start_compat_family_workers() {
    local family=""
    for family in debian rhel suse-arch; do
        setsid bash -c '
            set -euo pipefail
            cd "$1"
            ./scripts/run_docker_matrix.sh --compat-only --distro-family "$2" \
                2>&1 | tee "$3"
        ' bash "$REPO_ROOT" "$family" \
            "$DISTRO_LOG_DIR/compat-family-${family}.log" &
        _parallel_gate_pids+=("$!")
        _parallel_gate_labels+=("compat-family-${family}")
    done
}

_chown_coverage_shards_dir_if_sudo() {
    local shards_dir="$1"
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        chown "$SUDO_USER:" "$shards_dir" || return 1
    fi
    return 0
}

_wipe_coverage_shards_dir() {
    # Drop stale shard trees before parallel export so a failed worker cannot
    # leave yesterday's runs for a false-green merge. Under sudo --full the
    # host orchestrator is root; chown to SUDO_USER so docker --user can mkdir
    # shard dirs (root-owned 755 is not other-writable).
    local reports_root shards_dir
    reports_root=$(resolve_reports_root) || return 1
    shards_dir="$reports_root/coverage-shards"
    rm -rf "$shards_dir"
    mkdir -p "$shards_dir" || return 1
    _chown_coverage_shards_dir_if_sudo "$shards_dir" || return 1
}

_start_coverage_matrix_shards() {
    local mode shard=""
    for mode in kcov python; do
        for shard in 1 2; do
            setsid bash -c '
                set -euo pipefail
                cd "$1"
                export ASUS_COVERAGE_MODE="$2"
                export ASUS_COVERAGE_SHARD="$3"
                ./scripts/run_docker_matrix.sh --coverage-gate \
                    2>&1 | tee "$4"
            ' bash "$REPO_ROOT" "$mode" "$shard" \
                "$DISTRO_LOG_DIR/coverage-${mode}-${shard}.log" &
            _parallel_gate_pids+=("$!")
            _parallel_gate_labels+=("coverage-${mode}-${shard}")
        done
    done
}

_run_post_lint_gates_workers() {
    _step_post_lint_release_native_worker
    _step_post_lint_release_portable_worker
    _start_coverage_matrix_shards
    _start_compat_family_workers
    _wait_bg_jobs_fail_fast
}

step_post_lint_gates_parallel() {
    _reset_parallel_gate_workers
    start_step "Running release ∥ coverage ∥ compat in parallel..."
    _ensure_distro_logs_dir
    if is_container_runtime; then
        echo "  ✗ step_post_lint_gates_parallel is host-orchestrator only." >&2
        exit 1
    fi
    _wipe_coverage_shards_dir || exit 1
    if ! _with_buildx_skip_prune _run_post_lint_gates_workers; then
        _prune_buildx_cache_after_parallel
        echo "  ✗ Post-lint parallel gate failed (fail-fast)." >&2
        exit 1
    fi
    _prune_buildx_cache_after_parallel
    # Same fail-closed stamp gate as GHA coverage-merge (refuse green without exports).
    require_exported_coverage_shards || exit 1
    echo "  ✓ Release smoke, coverage shards, and compat matrices passed."
}

_run_coverage_merge_host() {
    (
        set -euo pipefail
        unset ASUS_COVERAGE_SHARD || true
        step_coverage_merge 2>&1 | tee "$DISTRO_LOG_DIR/coverage-merge.log"
    )
}

step_coverage_merge_host() {
    start_step "Merging coverage shards and enforcing ≥90% gates..."
    _ensure_distro_logs_dir
    if is_container_runtime; then
        echo "  ✗ step_coverage_merge_host is host-orchestrator only." >&2
        exit 1
    fi
    _run_coverage_merge_host
    echo "  ✓ Coverage merge gates passed."
}

_run_coverage_parallel_shards() {
    _start_coverage_matrix_shards
    _wait_bg_jobs_fail_fast
}

step_coverage_parallel() {
    # Standalone helper: coverage shards then merge (used by docs/tests references).
    # Wipe first so local matches GHA fresh-checkout merge (no stale shard_ok trees).
    _reset_parallel_gate_workers
    start_step "Running coverage matrix kcov×2 ∥ python×2 then merge (debian:trixie)..."
    _ensure_distro_logs_dir
    _wipe_coverage_shards_dir || exit 1
    if ! _with_buildx_skip_prune _run_coverage_parallel_shards; then
        _prune_buildx_cache_after_parallel
        echo "  ✗ Coverage shard failed (fail-fast)." >&2
        exit 1
    fi
    _prune_buildx_cache_after_parallel
    require_exported_coverage_shards || exit 1
    _run_coverage_merge_host
    echo "  ✓ Coverage matrix shards and merge gates passed."
}

_run_compat_family_workers_wait() {
    _start_compat_family_workers
    _wait_bg_jobs_fail_fast
}

step_compat_family_matrices() {
    # Standalone helper: three compat families in parallel.
    _reset_parallel_gate_workers
    start_step "Running distro family matrices in parallel (debian ∥ rhel ∥ suse-arch)..."
    _ensure_distro_logs_dir
    if ! _with_buildx_skip_prune _run_compat_family_workers_wait; then
        _prune_buildx_cache_after_parallel
        echo "  ✗ Docker distro compatibility test gate failed (fail-fast)." >&2
        exit 1
    fi
    _prune_buildx_cache_after_parallel
    echo "  ✓ Docker distro family compatibility matrices passed."
}
