#!/usr/bin/env bash
# Mode dispatch helpers for build-and-test.sh (sourced).

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
            MODE_STEPS=(step_lint_and_deb_parallel step_coverage_parallel step_compat_family_matrices)
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
    ./scripts/lint-in-docker.sh 2>&1 | tee "$DISTRO_LOG_DIR/lint-docker-${wave}.log"
}

_parallel_lint_waves_skip_prune() {
    # Parallel lint image builds share local buildx cache; skip prune mid-flight.
    local had_skip_prune=0 saved_skip_prune=""
    if [ "${DOCKER_BUILDX_SKIP_PRUNE+x}" = "x" ]; then
        had_skip_prune=1
        saved_skip_prune="$DOCKER_BUILDX_SKIP_PRUNE"
    fi
    export DOCKER_BUILDX_SKIP_PRUNE=1
    "$@"
    local status=$?
    if [ "$had_skip_prune" = 1 ]; then
        DOCKER_BUILDX_SKIP_PRUNE="$saved_skip_prune"
    else
        unset DOCKER_BUILDX_SKIP_PRUNE
    fi
    return "$status"
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
    (
        set -euo pipefail
        ./scripts/run_deb_package_smoke.sh 2>&1 | tee "$DISTRO_LOG_DIR/deb-package.log"
    ) &
    deb_pid=$!
    _wait_bg_status "$cheap_pid" "lint-cheap" cheap_status
    _wait_bg_status "$heavy_pid" "lint-heavy" heavy_status
    _wait_bg_status "$deb_pid" "deb-package" deb_status
    if [ "$cheap_status" -ne 0 ] || [ "$heavy_status" -ne 0 ]; then
        echo "  ✗ Docker lint gate failed." >&2
        exit 1
    fi
    if [ "$deb_status" -ne 0 ]; then
        echo "  ✗ Debian package smoke failed." >&2
        exit 1
    fi
    echo "  ✓ Lint waves and Debian package smoke passed."
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

_run_one_coverage_matrix_cell() {
    local mode="$1" shard="$2"
    set -euo pipefail
    export ASUS_COVERAGE_MODE="$mode"
    export ASUS_COVERAGE_SHARD="$shard"
    ./scripts/run_docker_matrix.sh --coverage-gate \
        2>&1 | tee "$DISTRO_LOG_DIR/coverage-${mode}-${shard}.log"
}

_start_coverage_matrix_shards() {
    local mode shard
    local -n _pids_ref=$1
    local -n _labels_ref=$2
    _pids_ref=()
    _labels_ref=()
    for mode in kcov python; do
        for shard in 1 2; do
            _run_one_coverage_matrix_cell "$mode" "$shard" &
            _pids_ref+=("$!")
            _labels_ref+=("coverage-${mode}-${shard}")
        done
    done
}

_wait_coverage_matrix_shards() {
    local -n _pids_ref=$1
    local -n _labels_ref=$2
    local i st=0
    for i in "${!_pids_ref[@]}"; do
        _wait_bg_status "${_pids_ref[$i]}" "${_labels_ref[$i]}" st
        if [ "$st" -ne 0 ]; then
            echo "  ✗ Coverage shard ${_labels_ref[$i]} failed." >&2
            exit 1
        fi
    done
}

_run_coverage_merge_host() {
    set -euo pipefail
    unset ASUS_COVERAGE_SHARD || true
    # Host-only: merge exported shard artifacts (no Docker image rebuild).
    step_coverage_merge 2>&1 | tee "$DISTRO_LOG_DIR/coverage-merge.log"
}

step_coverage_parallel() {
    # Mirror CI: mode×shard matrix (kcov|python)×(1|2) then host merge ≥90% gates.
    local pids=() labels=()
    start_step "Running coverage matrix kcov×2 ∥ python×2 then merge (debian:trixie)..."
    _ensure_distro_logs_dir
    _start_coverage_matrix_shards pids labels
    _wait_coverage_matrix_shards pids labels
    _run_coverage_merge_host
    echo "  ✓ Coverage matrix shards and merge gates passed."
}

_run_one_compat_family() {
    local family="$1"
    set -euo pipefail
    ./scripts/run_docker_matrix.sh --compat-only --distro-family "$family" \
        2>&1 | tee "$DISTRO_LOG_DIR/compat-family-${family}.log"
}

step_compat_family_matrices() {
    # Three package-family matrices in parallel (same nine lanes as CI distro-tests-*).
    local debian_status=0 rhel_status=0 suse_status=0
    local debian_pid rhel_pid suse_pid
    start_step "Running distro family matrices in parallel (debian ∥ rhel ∥ suse-arch)..."
    _ensure_distro_logs_dir
    _run_one_compat_family debian &
    debian_pid=$!
    _run_one_compat_family rhel &
    rhel_pid=$!
    _run_one_compat_family suse-arch &
    suse_pid=$!
    _wait_bg_status "$debian_pid" "compat-family-debian" debian_status
    _wait_bg_status "$rhel_pid" "compat-family-rhel" rhel_status
    _wait_bg_status "$suse_pid" "compat-family-suse-arch" suse_status
    if [ "$debian_status" -ne 0 ] || [ "$rhel_status" -ne 0 ] || [ "$suse_status" -ne 0 ]; then
        echo "  ✗ Docker distro compatibility test gate failed." >&2
        exit 1
    fi
    echo "  ✓ Docker distro family compatibility matrices passed."
}
