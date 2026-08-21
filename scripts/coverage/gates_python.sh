#!/usr/bin/env bash

_coverage_cli_direct() {
    if command -v coverage >/dev/null 2>&1; then
        coverage "$@"
        return $?
    fi
    python3 -m coverage "$@"
}

_coverage_cli() {
    # Under sudo --full, coverage lives in the invoker's user site-packages.
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        if command -v runuser >/dev/null 2>&1; then
            runuser -u "$SUDO_USER" -- python3 -m coverage "$@"
            return $?
        fi
    fi
    _coverage_cli_direct "$@"
}

_report_missing_python_coverage_files() {
    local missing_files="$1"
    [ -n "$missing_files" ] || return 0
    echo "  ✗ Missing product Python files from coverage report:" >&2
    while IFS= read -r missing_entry; do
        echo "    - $missing_entry" >&2
    done <<< "$missing_files"
}

_python_coverage_total_percent() {
    local include_pattern="$1"
    _coverage_cli report --include="$include_pattern" --format=total
}

_python_coverage_write_json() {
    local include_pattern="$1" json_out="$2"
    _coverage_cli json -o "$json_out" --include="$include_pattern" >/dev/null
}

_coverage_scripts_dir() {
    # Absolute path of gates.sh's directory (for PYTHONPATH product_relpath imports).
    printf '%s\n' "${_GATES_SH_DIR}"
}

_python_files_below_from_json() {
    local json_path="$1" min_percent="$2" coverage_dir
    coverage_dir="$(_coverage_scripts_dir)"
    PYTHONPATH="$coverage_dir${PYTHONPATH:+:$PYTHONPATH}" python3 - "$json_path" "$min_percent" <<'PY'
import json
import sys

from product_relpath import to_product_rel

data = json.load(open(sys.argv[1], encoding="utf-8"))
min_pct = float(sys.argv[2])
files = data.get("files") or {}
for path in sorted(files):
    summary = files[path].get("summary") or {}
    pct = float(summary.get("percent_covered", 0.0))
    if pct < min_pct:
        print(f"{to_product_rel(path)}={pct:g}%")
PY
}

_list_missing_product_python_coverage_from_json() {
    local json_path="$1" product_files product_status coverage_dir
    product_files=$(_list_product_python_files)
    product_status=$?
    if [ "$product_status" -ne 0 ]; then
        return "$product_status"
    fi
    coverage_dir="$(_coverage_scripts_dir)"
    PRODUCT_FILES="$product_files" PYTHONPATH="$coverage_dir${PYTHONPATH:+:$PYTHONPATH}" \
        python3 - "$json_path" <<'PY'
import json
import os
import sys

from product_relpath import to_product_rel

data = json.load(open(sys.argv[1], encoding="utf-8"))
reported = {to_product_rel(p) for p in (data.get("files") or {})}
for expected in os.environ.get("PRODUCT_FILES", "").splitlines():
    if expected and expected not in reported:
        print(expected)
PY
}

_python_coverage_total_below() {
    local total_percent="$1" min_percent="$2"
    awk -v pct="$total_percent" -v min="$min_percent" \
        'BEGIN { exit !((pct + 0) < (min + 0)) }'
}

_python_coverage_require_total() {
    local include_pattern="$1"
    local -n __total_out=$2
    if __total_out=$(_python_coverage_total_percent "$include_pattern"); then
        return 0
    fi
    echo "  ✗ coverage report --format=total failed for include pattern: $include_pattern" >&2
    return 1
}

_python_coverage_require_json() {
    local include_pattern="$1" json_out="$2"
    if _python_coverage_write_json "$include_pattern" "$json_out"; then
        return 0
    fi
    echo "  ✗ coverage json failed for include pattern: $include_pattern" >&2
    return 1
}

_python_coverage_fill_below_total() {
    local total_percent="$1" min_percent="$2"
    local -n __below_out=$3
    __below_out=""
    if _python_coverage_total_below "$total_percent" "$min_percent"; then
        __below_out=yes
    fi
}

_python_coverage_file_metrics() {
    local json_out="$1" min_percent="$2"
    local -n __below_files_out=$3 __missing_out=$4
    __below_files_out=$(_python_files_below_from_json "$json_out" "$min_percent") || return 1
    __missing_out=$(_list_missing_product_python_coverage_from_json "$json_out") || return 1
    return 0
}

_python_coverage_collect_structured() {
    # Sets namerefs: total_percent, below_total, below_files, missing_files.
    local include_pattern="$1" min_percent="$2" json_out="$3"
    local -n __total=$4 __below_total=$5 __below_files=$6 __missing=$7
    _python_coverage_require_total "$include_pattern" __total || return 1
    _python_coverage_require_json "$include_pattern" "$json_out" || return 1
    _python_coverage_fill_below_total "$__total" "$min_percent" __below_total
    _python_coverage_file_metrics "$json_out" "$min_percent" __below_files __missing || return 1
    return 0
}

_python_coverage_tee_report() {
    local include_pattern="$1" report_log="$2"
    local status=0 saved_errexit
    saved_errexit=$(shopt -po errexit)
    set +e
    _coverage_cli report --include="$include_pattern" 2>&1 | tee "$report_log"
    status=${PIPESTATUS[0]}
    eval "$saved_errexit"
    if [ "$status" -ne 0 ]; then
        echo "  ✗ coverage report failed for include pattern: $include_pattern" >&2
        return 1
    fi
    return 0
}

_python_coverage_gate_has_violations() {
    _python_coverage_below_threshold "$1" "$2" || [ -n "$3" ]
}

run_python_coverage_gate() {
    local include_pattern="$1"
    local min_percent="${2:-90}"
    local reports_root logs_dir report_log json_out
    local total_percent below_total below_files missing_files
    reports_root=$(resolve_reports_root) || return 1
    logs_dir="$reports_root/distro-logs"
    mkdir -p "$logs_dir"
    report_log="$logs_dir/python-coverage-report.log"
    json_out="$logs_dir/python-coverage.json"
    _python_coverage_tee_report "$include_pattern" "$report_log" || return 1
    _python_coverage_collect_structured "$include_pattern" "$min_percent" "$json_out" \
        total_percent below_total below_files missing_files || return 1
    if _python_coverage_gate_has_violations "$below_total" "$below_files" "$missing_files"; then
        _report_python_coverage_violations "$below_total" "$below_files" "$min_percent"
        _report_missing_python_coverage_files "$missing_files"
        return 1
    fi
    return 0
}

_product_python_additional_relpaths() {
    # Root/script product modules outside bin/ and tools/ (do not widen to all scripts/).
    printf '%s\n' shared_imports.py \
        scripts/check_file_size_limits.py \
        scripts/check_no_lint_suppressions.py \
        scripts/repo_scan_common.py \
        sitecustomize.py
}

_list_product_python_files() {
    # Real product modules only (find -type f skips hyphenated symlink entrypoints).
    local root
    root="${KCOV_REPO_ROOT:-}"
    if [ -z "$root" ]; then
        root="$(_kcov_repo_root)"
    fi
    _list_sorted_relpaths_under "$root" "product Python directories (bin/ or tools/)" \
        "*.py" bin tools || return $?
    _product_python_additional_relpaths
}

_python_coverage_include_pattern() {
    # Single source of truth with _list_product_python_files so new modules are gated.
    local files status=0
    files=$(_list_product_python_files) || status=$?
    if [ "$status" -ne 0 ]; then
        return "$status"
    fi
    if [ -z "$files" ]; then
        echo "  ✗ No product Python files found for coverage include pattern." >&2
        return 1
    fi
    paste -sd, - <<< "$files"
}

_python_coverage_below_threshold() {
    [ -n "$1" ] || [ -n "$2" ]
}

_report_python_coverage_violations() {
    local below_total="$1" below_files="$2" min_percent="$3"
    if [ -n "$below_total" ]; then
        echo "  ✗ Total Python coverage is below ${min_percent}%." >&2
    fi
    if [ -n "$below_files" ]; then
        echo "  ✗ Per-file Python coverage below ${min_percent}%:" >&2
        while IFS= read -r below_entry; do
            echo "    - $below_entry" >&2
        done <<< "$below_files"
    fi
}

_copy_python_coverage_dat_to_shard() {
    local src="$1" dest="$2" shard="$3"
    if [ ! -f "$src" ]; then
        echo "  ✗ Missing coverage data file for python shard ${shard}: $src" >&2
        return 1
    fi
    # Non-hidden name so GHA upload-artifact includes it without special flags.
    cp -a "$src" "$dest/coverage.dat"
}

_export_python_shard_payload() {
    local dest="$1" shard="$2"
    _mkdir_coverage_shard_dest "$dest" "python" || return 1
    _copy_python_coverage_dat_to_shard "${COVERAGE_FILE:-.coverage}" "$dest" "$shard" \
        || return 1
    _write_coverage_shard_ok_stamp "$dest" "python"
}

_export_python_coverage_shard_file() {
    local shard="${ASUS_COVERAGE_SHARD:-}" reports_root dest
    [ -n "$shard" ] || return 0
    reports_root=$(resolve_reports_root) || return 1
    dest="$reports_root/coverage-shards/python-${shard}"
    _export_python_shard_payload "$dest" "$shard" || return 1
    echo "  ✓ Exported python coverage shard ${shard} to $dest"
}

_require_python_shard_ok_stamps() {
    local reports_root="$1" shard dest
    for shard in 1 2; do
        dest="$reports_root/coverage-shards/python-${shard}"
        if [ ! -f "$dest/shard_ok" ]; then
            echo "  ✗ Missing python shard stamp: $dest/shard_ok" \
                "(shard did not export successfully; refusing stale merge)" >&2
            return 1
        fi
        if [ ! -f "$dest/coverage.dat" ] && [ ! -f "$dest/.coverage" ]; then
            echo "  ✗ python shard python-${shard} has stamp but no coverage data" >&2
            return 1
        fi
    done
    return 0
}

_python_coverage_shard_data_files() {
    local reports_root="$1" shard_file
    # Prefer normalized python-N layout; also accept raw GHA download names.
    for shard_file in \
        "$reports_root"/coverage-shards/python-*/coverage.dat \
        "$reports_root"/coverage-shards/python-*/.coverage \
        "$reports_root"/coverage-shards/coverage-shard-python-*/coverage.dat \
        "$reports_root"/coverage-shards/coverage-shard-python-*/.coverage
    do
        [ -f "$shard_file" ] || continue
        printf '%s\n' "$shard_file"
    done
}

_combine_python_coverage_shards() {
    # Combine every shard in one coverage.py invocation so [tool.coverage.paths]
    # remaps Docker /workspace → checkout. A raw cp of the first shard leaves
    # /workspace paths that do not match relative --include=bin/* gates.
    local reports_root="$1" dest="$2"
    local -a shard_files=()
    local shard_file
    rm -f "$dest"
    while IFS= read -r shard_file; do
        [ -n "$shard_file" ] || continue
        shard_files+=("$shard_file")
    done < <(_python_coverage_shard_data_files "$reports_root")
    if [ "${#shard_files[@]}" -eq 0 ]; then
        return 1
    fi
    _coverage_cli combine --keep --data-file="$dest" "${shard_files[@]}"
}

_merge_python_shards_from_reports() {
    local reports_root="$1" combined="$2" include_pattern
    _require_python_shard_ok_stamps "$reports_root" || return 1
    _combine_python_coverage_shards "$reports_root" "$combined" || return 1
    export COVERAGE_FILE="$combined"
    include_pattern="$(_python_coverage_include_pattern)"
    run_python_coverage_gate "$include_pattern"
}

merge_python_coverage_shards() {
    local reports_root combined
    reports_root=$(resolve_reports_root) || return 1
    normalize_coverage_shard_artifacts || return 1
    combined="$reports_root/coverage-shards/.coverage.merged"
    if ! _merge_python_shards_from_reports "$reports_root" "$combined"; then
        echo "  ✗ Failed to combine python coverage shards" \
            "under $reports_root/coverage-shards" >&2
        return 1
    fi
    echo "  ✓ Merged python shards meet ≥90% coverage."
}
