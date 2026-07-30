#!/usr/bin/env bash
# Parallel kcov scenario shards (sourced by kcov-install-scenarios.sh).

_run_kcov_shard_bin_sound() {
    local kcov_root="$1"
    _run_kcov_bin_scenarios "$kcov_root"
    _run_kcov_sound_scenarios "$kcov_root"
    _run_kcov_sound_helper_scenarios "$kcov_root"
}

_run_kcov_shard_ui() {
    local kcov_root="$1"
    _run_kcov_screenshot_scenarios "$kcov_root"
    _run_kcov_screenshot_family_scenarios "$kcov_root"
    _run_kcov_control_center_scenarios "$kcov_root"
    _run_kcov_cc_family_desktop_scenarios "$kcov_root"
}

_run_kcov_shard_install_lib() {
    local kcov_root="$1"
    _run_kcov_install_uninstall_scenarios "$kcov_root"
    _run_kcov_product_lib_helpers "$kcov_root"
}

_kcov_run_one_named_shard() {
    local shard_id="$1" kcov_root="$2"
    case "$shard_id" in
        bin-sound) _run_kcov_shard_bin_sound "$kcov_root" ;;
        ui) _run_kcov_shard_ui "$kcov_root" ;;
        install-lib) _run_kcov_shard_install_lib "$kcov_root" ;;
        *)
            echo "  ✗ Unknown KCOV_SHARD='$shard_id' (use bin-sound|ui|install-lib)" >&2
            return 1
            ;;
    esac
}

_kcov_list_shards() {
    local want="${KCOV_SHARD:-}"
    local cov_shard="${ASUS_COVERAGE_SHARD:-}"
    if [ -n "$want" ]; then
        printf '%s\n' "$want"
        return 0
    fi
    # GHA/local matrix: ASUS_COVERAGE_SHARD=1|2 splits the three internal shards.
    case "$cov_shard" in
        1)
            printf '%s\n' bin-sound ui
            return 0
            ;;
        2)
            printf '%s\n' install-lib
            return 0
            ;;
        '')
            printf '%s\n' bin-sound ui install-lib
            return 0
            ;;
        *)
            echo "  ✗ Unknown ASUS_COVERAGE_SHARD='$cov_shard' (use 1|2 or empty)" >&2
            return 1
            ;;
    esac
}

_kcov_collect_shard_run_dirs() {
    local kcov_root="$1" shard_root run_dir
    for shard_root in "$kcov_root"/shard-*/runs; do
        [ -d "$shard_root" ] || continue
        if [ -z "$(find "$shard_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]; then
            continue
        fi
        mkdir -p "$kcov_root/runs"
        while IFS= read -r -d '' run_dir; do
            cp -a "$run_dir" "$kcov_root/runs/"
        done < <(find "$shard_root" -mindepth 1 -maxdepth 1 -type d -print0)
    done
}

_kcov_collect_shard_logs() {
    local kcov_root="$1" shard_logs
    mkdir -p "$kcov_root/logs"
    for shard_logs in "$kcov_root"/shard-*/logs; do
        [ -d "$shard_logs" ] || continue
        if [ -z "$(find "$shard_logs" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then
            continue
        fi
        cp -a "$shard_logs"/. "$kcov_root/logs/"
    done
}

_kcov_merge_shard_fail_files() {
    local kcov_root="$1" fail_file="$2" shard_fail
    : >"$fail_file"
    for shard_fail in "$kcov_root"/shard-*/.kcov_scenario_failures; do
        [ -f "$shard_fail" ] || continue
        cat "$shard_fail" >>"$fail_file"
    done
}

_kcov_wait_shard_pids() {
    local status=0 pid_status=0 i
    for i in "${!_KCOV_SHARD_PIDS[@]}"; do
        set +e
        wait "${_KCOV_SHARD_PIDS[$i]}"
        pid_status=$?
        set -e
        if [ "$pid_status" -ne 0 ]; then
            echo "  ✗ kcov shard ${_KCOV_SHARD_IDS[$i]} failed (status $pid_status)" >&2
            status=1
        fi
    done
    return "$status"
}

_kcov_start_shard_workers() {
    local kcov_root="$1"
    local shard_id shard_root fail_file pid
    _KCOV_SHARD_PIDS=()
    _KCOV_SHARD_IDS=()
    while IFS= read -r shard_id; do
        [ -n "$shard_id" ] || continue
        shard_root="$kcov_root/shard-$shard_id"
        mkdir -p "$shard_root/runs" "$shard_root/logs"
        fail_file="$shard_root/.kcov_scenario_failures"
        rm -f "$fail_file"
        (
            set -euo pipefail
            export KCOV_SCENARIO_FAIL_FILE="$fail_file"
            export KCOV_REPO_ROOT
            _kcov_run_one_named_shard "$shard_id" "$shard_root"
        ) &
        pid=$!
        _KCOV_SHARD_PIDS+=("$pid")
        _KCOV_SHARD_IDS+=("$shard_id")
    done < <(_kcov_list_shards)
}

run_shell_kcov_scenarios() {
    export KCOV_REPO_ROOT
    KCOV_REPO_ROOT="$(pwd)"
    local fail_file="$1/.kcov_scenario_failures"
    local status=0
    rm -f "$fail_file"
    export KCOV_SCENARIO_FAIL_FILE="$fail_file"
    _kcov_start_shard_workers "$1"
    set +e
    _kcov_wait_shard_pids
    status=$?
    set -e
    _kcov_merge_shard_fail_files "$1" "$fail_file"
    _kcov_collect_shard_run_dirs "$1"
    _kcov_collect_shard_logs "$1"
    if _kcov_fail_file_has_entries; then
        echo "  ✗ kcov scenario expectation failures recorded under $fail_file:" >&2
        cat "$fail_file" >&2
        return 1
    fi
    return "$status"
}
