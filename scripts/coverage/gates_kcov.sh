#!/usr/bin/env bash

_resolve_merged_kcov_coverage_json() {
    local merged="$1" preferred
    preferred="$merged/kcov-merged/coverage.json"
    if [ -f "$preferred" ]; then
        printf '%s\n' "$preferred"
        return 0
    fi
    echo "  ✗ Missing merged coverage.json at $preferred" >&2
    return 1
}

_require_kcov_run_dirs() {
    local kcov_root="$1"
    if [ -d "$kcov_root/runs" ] && [ -n "$(find "$kcov_root/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]; then
        return 0
    fi
    echo "  ✗ kcov --merge skipped: no run directories under $kcov_root/runs" >&2
    return 1
}

_merge_kcov_runs() {
    local kcov_root="$1" merged="$2" merge_status reports_root logs_dir saved_errexit
    reports_root=$(resolve_reports_root) || return 1
    logs_dir="$reports_root/distro-logs"
    mkdir -p "$logs_dir"
    saved_errexit=$(shopt -po errexit)
    set +e
    kcov --merge "$merged" "$kcov_root/runs"/* 2>&1 | tee "$logs_dir/kcov-merge.log"
    merge_status=${PIPESTATUS[0]}
    eval "$saved_errexit"
    if [ "$merge_status" -ne 0 ]; then
        echo "  ✗ kcov --merge failed with status $merge_status" >&2
        return 1
    fi
    return 0
}

_normalize_kcov_min_percent() {
    local min_percent="${KCOV_MIN_PERCENT:-90}"
    case "$min_percent" in
        ''|*[!0-9]*) min_percent=90 ;;
    esac
    if [ "$min_percent" -lt 90 ]; then
        min_percent=90
    fi
    printf '%s\n' "$min_percent"
}

_setup_kcov_temp_root() {
    _KCOV_TEMP_ROOT=$(mktemp -d)
    _KCOV_MERGED="$_KCOV_TEMP_ROOT/merged"
    _KCOV_JSON=""
    _KCOV_SAVED_EXIT_TRAP=$(trap -p EXIT)
    _KCOV_SAVED_EXIT_BODY=""
    # Saved trap body supports only a single-line EXIT handler without embedded
    # single quotes because teardown re-evaluates it via eval.
    if [[ ${_KCOV_SAVED_EXIT_TRAP} =~ ^trap\ --\ \'(.*)\'\ EXIT$ ]]; then
        _KCOV_SAVED_EXIT_BODY="${BASH_REMATCH[1]}"
    elif [ -n "${_KCOV_SAVED_EXIT_TRAP:-}" ]; then
        echo "  ✗ Existing EXIT trap is not a single-line form; refusing to" \
            "replace it for kcov temp cleanup." >&2
        echo "  ✗ Current trap: ${_KCOV_SAVED_EXIT_TRAP}" >&2
        rm -rf "$_KCOV_TEMP_ROOT"
        unset _KCOV_TEMP_ROOT _KCOV_MERGED _KCOV_JSON _KCOV_SAVED_EXIT_TRAP \
            _KCOV_SAVED_EXIT_BODY
        return 1
    fi
    # On EXIT, run the prior handler body (do not re-eval trap -p; that only
    # reinstalls). Explicit teardown restores via full _KCOV_SAVED_EXIT_TRAP.
    trap '_cleanup_kcov_temp_root "${_KCOV_TEMP_ROOT-}" "${_KCOV_MERGED-}" "${_KCOV_JSON-}"; eval "${_KCOV_SAVED_EXIT_BODY:-:}"' EXIT
}

_teardown_kcov_temp_root() {
    local kcov_root="$1" merged="$2" cov_json="$3"
    trap - EXIT
    _cleanup_kcov_temp_root "$kcov_root" "$merged" "$cov_json"
    eval "${_KCOV_SAVED_EXIT_TRAP:-trap - EXIT}"
    unset _KCOV_SAVED_EXIT_TRAP _KCOV_SAVED_EXIT_BODY _KCOV_TEMP_ROOT _KCOV_MERGED _KCOV_JSON
}

_export_and_teardown_kcov_shard() {
    local kcov_root="$1" merged="$2"
    _export_kcov_coverage_shard "$kcov_root" || return 1
    _teardown_kcov_temp_root "$kcov_root" "$merged" ""
}

_run_kcov_coverage_pipeline() {
    local kcov_root="$1" merged="$2" min_percent="$3"
    local cov_json status=0
    # Do not put scenario orchestration on the LHS of ||/&&: that disables
    # errexit for the whole function body and lets later successes mask
    # unexpected kcov scenario exits.
    set +e
    _run_and_merge_kcov_scenarios "$kcov_root" "$merged"
    status=$?
    set -e
    [ "$status" -eq 0 ] || return 1
    if [ -n "${ASUS_COVERAGE_SHARD:-}" ]; then
        _export_and_teardown_kcov_shard "$kcov_root" "$merged"
        return $?
    fi
    cov_json="$(_resolve_merged_kcov_coverage_json "$merged")" || return 1
    _KCOV_JSON="$cov_json"
    _finalize_kcov_coverage "$cov_json" "$min_percent" "$kcov_root" || return 1
    _teardown_kcov_temp_root "$kcov_root" "$merged" "$cov_json"
}

_copy_kcov_runs_into_shard_dest() {
    local kcov_root="$1" dest="$2"
    mkdir -p "$dest/runs" || return 1
    if [ -d "$kcov_root/runs" ]; then
        cp -a "$kcov_root/runs"/. "$dest/runs/" || return 1
    fi
    return 0
}

_export_kcov_shard_payload() {
    local kcov_root="$1" dest="$2"
    _mkdir_coverage_shard_dest "$dest" "kcov" || return 1
    _copy_kcov_runs_into_shard_dest "$kcov_root" "$dest" || return 1
    # Stamp only on successful export so merge never trusts stale shard trees.
    # Non-hidden name: GHA upload-artifact omits dotfiles unless include-hidden-files.
    _write_coverage_shard_ok_stamp "$dest" "kcov"
}

_export_kcov_coverage_shard() {
    local kcov_root="$1" shard="${ASUS_COVERAGE_SHARD}" dest reports_root
    _require_asus_coverage_shard_id "$shard" || return 1
    reports_root=$(resolve_reports_root) || return 1
    dest="$reports_root/coverage-shards/kcov-${shard}"
    _export_kcov_shard_payload "$kcov_root" "$dest" || return 1
    echo "  ✓ Exported kcov shard ${shard} runs to $dest"
}

_require_kcov_shard_ok_stamps() {
    local reports_root="$1" shard dest
    for shard in 1 2; do
        dest="$reports_root/coverage-shards/kcov-${shard}"
        if [ ! -f "$dest/shard_ok" ]; then
            echo "  ✗ Missing kcov shard stamp: $dest/shard_ok" \
                "(shard did not export successfully; refusing stale merge)" >&2
            return 1
        fi
        if [ ! -d "$dest/runs" ] || \
            [ -z "$(find "$dest/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]; then
            echo "  ✗ kcov shard kcov-${shard} has stamp but no run dirs" >&2
            return 1
        fi
    done
    return 0
}

_run_and_merge_kcov_scenarios() {
    local kcov_root="$1" merged="$2" status=0
    # Nested subshell restores real errexit even when this function was reached
    # via `cmd || return` (bash ignores set -e for the LHS of ||).
    set +e
    (
        set -euo pipefail
        run_shell_kcov_scenarios "$kcov_root"
    )
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
        echo "  ✗ kcov scenario suite failed (status $status)" >&2
        return 1
    fi
    _require_kcov_run_dirs "$kcov_root" || return 1
    _merge_kcov_runs "$kcov_root" "$merged" || return 1
}

step_kcov_coverage() {
    start_step "Running Shell Script Line Coverage (kcov)..."
    if ! command -v kcov &>/dev/null; then
        _handle_missing_kcov
        return 0
    fi
    local kcov_root merged min_percent status=0
    min_percent="$(_normalize_kcov_min_percent)"
    if ! _setup_kcov_temp_root; then
        echo "  ✗ Failed to set up kcov temporary coverage root." >&2
        exit 1
    fi
    kcov_root="$_KCOV_TEMP_ROOT"
    merged="$_KCOV_MERGED"
    set +e
    _run_kcov_coverage_pipeline "$kcov_root" "$merged" "$min_percent"
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
        exit 1
    fi
    if [ -n "${ASUS_COVERAGE_SHARD:-}" ]; then
        echo "  ✓ kcov coverage shard ${ASUS_COVERAGE_SHARD} scenarios completed (merge job gates %)."
        return 0
    fi
    echo "  ✓ Shell line coverage ≥ ${min_percent}% on product shell scripts (bin/, lib/, install.sh, uninstall.sh)."
}

_cleanup_kcov_temp_root() {
    local kcov_root="${1-}" merged="${2-}" cov_json="${3-}"
    [ -n "$kcov_root" ] || return 0
    [ -d "$kcov_root" ] || return 0
    _copy_kcov_report "$merged" "$cov_json" "$kcov_root/logs" || true
    rm -rf "$kcov_root"
}

_handle_missing_kcov() {
    if [ "${REQUIRE_KCOV:-0}" = "1" ]; then
        echo "  ✗ kcov is required but not installed (set REQUIRE_KCOV=0 to allow skipping locally)." >&2; exit 1
    fi
    echo "  ! kcov not installed locally (skipping shell coverage gate; enforced in CI)."
}

resolve_reports_root() {
    local repo_root="${REPO_ROOT:-$(pwd)}"
    local preferred_root="$repo_root/reports"
    if mkdir -p "$preferred_root" 2>/dev/null && [ -w "$preferred_root" ]; then
        echo "$preferred_root"
        return 0
    fi

    local fallback_root="${TMPDIR:-/tmp}/asus-zenbook-linux-tools-reports"
    if ! mkdir -p "$fallback_root"; then
        echo "  ✗ Failed to create reports directory: $fallback_root" >&2
        return 1
    fi
    echo "$fallback_root"
}

_copy_kcov_merged_report() {
    local merged="$1" cov_json="$2" report_dest="$3"
    # Wipe prior report artifacts so nested kcov HTML from older include-path
    # mistakes cannot accumulate under reports/kcov/<slug>/.
    if [ -d "$report_dest" ]; then
        find "$report_dest" -mindepth 1 -maxdepth 1 ! -name logs -exec rm -rf {} +
    else
        mkdir -p "$report_dest"
    fi
    if [ -d "$merged" ]; then
        cp -r "$merged/." "$report_dest/"
    fi
    if [ -n "$cov_json" ] && [ -f "$cov_json" ]; then
        cp "$cov_json" "$report_dest/coverage.json"
    fi
}

_copy_kcov_scenario_logs() {
    local logs_dir="$1" report_dest="$2"
    if [ -n "$logs_dir" ] && [ -d "$logs_dir" ]; then
        mkdir -p "$report_dest/logs"
        cp -r "$logs_dir/." "$report_dest/logs/"
    fi
}

_copy_kcov_scenario_logs_to_distro() {
    # Mirror scenario *.log into distro-logs for CI artifact upload on failure.
    local logs_dir="$1" reports_root="$2" dest
    [ -n "$logs_dir" ] && [ -d "$logs_dir" ] || return 0
    dest="$reports_root/distro-logs/kcov-scenarios"
    mkdir -p "$dest"
    cp -r "$logs_dir/." "$dest/"
}

_copy_kcov_report() {
    local merged="$1" cov_json="$2" logs_dir="${3:-}"
    local slug="${REPORT_DISTRO_SLUG:-local}"
    local reports_root report_dest
    reports_root=$(resolve_reports_root) || return 1
    if [ -z "$reports_root" ] || [ ! -d "$reports_root" ]; then
        echo "  ✗ Failed to resolve reports root for kcov copy" >&2
        return 1
    fi
    report_dest="$reports_root/kcov/${slug}"
    mkdir -p "$report_dest"
    _copy_kcov_merged_report "$merged" "$cov_json" "$report_dest"
    _copy_kcov_scenario_logs "$logs_dir" "$report_dest"
    _copy_kcov_scenario_logs_to_distro "$logs_dir" "$reports_root"
    echo "  ✓ Shell coverage report written to $report_dest/"
}

_collect_kcov_shard_runs() {
    local reports_root="$1" dest_runs="$2" shard_runs
    mkdir -p "$dest_runs"
    for shard_runs in \
        "$reports_root"/coverage-shards/kcov-*/runs \
        "$reports_root"/coverage-shards/coverage-shard-kcov-*/runs
    do
        [ -d "$shard_runs" ] || continue
        if [ -z "$(find "$shard_runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]; then
            continue
        fi
        cp -a "$shard_runs"/. "$dest_runs/"
    done
}

_copy_one_gha_coverage_shard_dir() {
    local src_dir="$1" dest_root="$2" name mode_shard
    name=$(basename "$src_dir")
    case "$name" in
        coverage-shard-*) ;;
        *) return 0 ;;
    esac
    mode_shard=${name#coverage-shard-}
    [ -n "$mode_shard" ] || return 0
    mkdir -p "$dest_root/$mode_shard"
    cp -a "$src_dir"/. "$dest_root/$mode_shard/"
}

_iter_gha_coverage_shard_dirs() {
    local src="$1" dest="$2" dir
    for dir in "$src"/coverage-shard-*; do
        [ -d "$dir" ] || continue
        _copy_one_gha_coverage_shard_dir "$dir" "$dest" || return 1
    done
}

# Map GHA download-artifact dirs (coverage-shard-kcov-1/…) to kcov-1/python-1 layout.
normalize_coverage_shard_artifacts() {
    local reports_root src dest
    reports_root=$(resolve_reports_root) || return 1
    src="$reports_root/coverage-shards-download"
    [ -d "$src" ] || return 0
    dest="$reports_root/coverage-shards"
    mkdir -p "$dest"
    _iter_gha_coverage_shard_dirs "$src" "$dest"
}

_rewrite_kcov_docker_workspace_prefix() {
    local runs_dir="$1" repo_root script_dir
    [ -d "$runs_dir" ] || return 0
    repo_root="${KCOV_REPO_ROOT:-$(_kcov_repo_root)}"
    [ -n "$repo_root" ] || return 1
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    python3 "$script_dir/rewrite_kcov_workspace_prefix.py" "$runs_dir" "$repo_root"
}

_finalize_merged_kcov_temp() {
    local tmp="$1" merged="$2" min_percent="$3" cov_json
    _require_kcov_run_dirs "$tmp" || return 1
    _rewrite_kcov_docker_workspace_prefix "$tmp/runs" || return 1
    _merge_kcov_runs "$tmp" "$merged" || return 1
    cov_json="$(_resolve_merged_kcov_coverage_json "$merged")" || return 1
    _finalize_kcov_coverage "$cov_json" "$min_percent" "$tmp"
}

_merge_kcov_shards_from_reports() {
    local reports_root="$1" tmp="$2" merged="$3" min_percent="$4"
    _require_kcov_shard_ok_stamps "$reports_root" || return 1
    mkdir -p "$tmp/runs"
    _collect_kcov_shard_runs "$reports_root" "$tmp/runs" || return 1
    _finalize_merged_kcov_temp "$tmp" "$merged" "$min_percent"
}

merge_kcov_coverage_shards() {
    local reports_root tmp merged min_percent
    reports_root=$(resolve_reports_root) || return 1
    normalize_coverage_shard_artifacts || return 1
    tmp=$(mktemp -d)
    merged="$tmp/merged"
    min_percent="$(_normalize_kcov_min_percent)"
    if ! _merge_kcov_shards_from_reports "$reports_root" "$tmp" "$merged" "$min_percent"; then
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "$tmp"
    echo "  ✓ Merged kcov shards meet ≥${min_percent}% line coverage."
}

# Shared local/--full and GHA pre-merge gate: all four shard exports must be stamped.
require_exported_coverage_shards() {
    local reports_root
    reports_root=$(resolve_reports_root) || return 1
    _require_kcov_shard_ok_stamps "$reports_root" || return 1
    _require_python_shard_ok_stamps "$reports_root" || return 1
    echo "  ✓ All coverage shard exports present (kcov-1/2, python-1/2)."
}
