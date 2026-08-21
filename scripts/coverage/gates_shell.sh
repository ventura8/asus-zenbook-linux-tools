#!/usr/bin/env bash

_write_coverage_shard_ok_stamp() {
    local dest="$1" kind="$2" tmp=""
    tmp=$(mktemp -p "$dest" shard_ok.XXXXXX) || {
        echo "  ✗ Failed to create ${kind} shard stamp temp under $dest" >&2
        return 1
    }
    if ! date -u +%Y-%m-%dT%H:%M:%SZ >"$tmp"; then
        rm -f "$tmp"
        echo "  ✗ Failed to write ${kind} shard stamp: $dest/shard_ok" >&2
        return 1
    fi
    if ! mv -f "$tmp" "$dest/shard_ok"; then
        rm -f "$tmp"
        echo "  ✗ Failed to finalize ${kind} shard stamp: $dest/shard_ok" >&2
        return 1
    fi
    [ -f "$dest/shard_ok" ]
}

_require_asus_coverage_shard_id() {
    case "${1:-}" in
        1|2) return 0 ;;
        *)
            echo "  ✗ Unsupported ASUS_COVERAGE_SHARD='${1:-}' (use 1|2)" >&2
            return 1
            ;;
    esac
}

_mkdir_coverage_shard_dest() {
    local dest="$1" kind="$2"
    rm -rf "$dest"
    mkdir -p "$dest" || {
        echo "  ✗ Failed to create ${kind} shard dir: $dest" >&2
        return 1
    }
}

_pipefail_state() {
    # Echo 1 when pipefail is currently on, else 0.
    if [[ -o pipefail ]]; then
        echo 1
    else
        echo 0
    fi
}

_restore_pipefail() {
    local had_pipefail="$1"
    if [ "$had_pipefail" -eq 0 ]; then
        set +o pipefail
    else
        set -o pipefail
    fi
}

_finalize_kcov_coverage() {
    local cov_json="$1"
    local min_percent="${2:-90}"
    local kcov_root="${3:-}"
    if [ -z "$cov_json" ]; then
        echo "  ✗ Failed to generate shell coverage report" >&2
        return 1
    fi
    if ! check_kcov_report_percentages "$cov_json" "$min_percent" "$kcov_root"; then
        return 1
    fi
}

_list_sorted_relpaths_under() {
    # Validate dirs under root, find files matching pattern, print root-relative paths.
    # Usage: _list_sorted_relpaths_under <root> <err_label> <find-name-pattern> <dir>...
    local root="$1" err_label="$2" pattern="$3"
    shift 3
    local dir find_tmp find_status=0 find_list
    local -a find_roots=()
    for dir in "$@"; do
        _require_product_dir "$root" "$dir" "$err_label" || return 1
        find_roots+=("$root/$dir")
    done
    find_tmp=$(mktemp)
    find "${find_roots[@]}" -type f -name "$pattern" >"$find_tmp" || find_status=$?
    if [ "$find_status" -ne 0 ]; then
        rm -f "$find_tmp"
        echo "  ✗ Failed to list ${err_label} under $root" >&2
        return "$find_status"
    fi
    find_list=$(LC_ALL=C sort <"$find_tmp")
    rm -f "$find_tmp"
    _print_root_relative_paths "$root" "$find_list"
}

_require_product_dir() {
    local root="$1" dir="$2" err_label="$3"
    if [ -d "$root/$dir" ]; then
        return 0
    fi
    echo "  ✗ Missing ${err_label} under $root" >&2
    return 1
}

_print_root_relative_paths() {
    local root="$1" find_list="$2" abs rel
    while IFS= read -r abs; do
        [ -n "$abs" ] || continue
        rel="${abs#"$root"/}"
        printf '%s\n' "$rel"
    done <<< "$find_list"
}

_load_all_script_coverage() {
    local cov_json="$1" kcov_root="${2:-}"
    # Emit KCOV_REPO_ROOT-relative product paths (bin/…, lib/…, install.sh, uninstall.sh).
    ASUS_PRODUCT_TOPLEVEL_SCRIPTS="$(_list_product_toplevel_scripts | tr '\n' ' ')" \
    python3 - "$cov_json" "$kcov_root" <<'PY'
import json
import os
import sys

cov_json = sys.argv[1] if len(sys.argv) > 1 else ""
kcov_root = sys.argv[2] if len(sys.argv) > 2 else ""
kcov_real = ""
if kcov_root:
    try:
        kcov_real = os.path.realpath(kcov_root)
    except OSError:
        kcov_real = ""
repo_env = os.environ.get("KCOV_REPO_ROOT") or ""
repo_real = ""
if repo_env:
    try:
        repo_real = os.path.realpath(repo_env)
    except OSError:
        repo_real = ""

_TOPLEVEL = {name for name in os.environ.get("ASUS_PRODUCT_TOPLEVEL_SCRIPTS", "").split() if name}
if not _TOPLEVEL:
    _TOPLEVEL = {"install.sh", "uninstall.sh"}


def _is_product_path(file_path: str) -> bool:
    normalized = file_path.replace("\\", "/")
    tmp_root = os.environ.get("TMPDIR") or "/tmp"
    try:
        tmp_real = os.path.realpath(tmp_root)
    except OSError:
        tmp_real = tmp_root.rstrip("/") or "/tmp"
    try:
        real_path = os.path.realpath(file_path)
    except OSError:
        real_path = normalized
    if repo_real:
        if real_path != repo_real and not real_path.startswith(repo_real + os.sep):
            return False
    elif real_path == tmp_real or real_path.startswith(tmp_real + os.sep):
        return False
    if "/usr/local/lib/" in normalized or "/usr/local/bin/" in normalized:
        return False
    if kcov_real:
        if real_path == kcov_real or real_path.startswith(kcov_real + os.sep):
            return False
    base = os.path.basename(normalized)
    if base in _TOPLEVEL:
        return normalized.endswith("/" + base) or normalized == base
    return normalized.endswith("/bin/" + base) or normalized.endswith("/lib/" + base)


def _product_rel_key(file_path: str) -> str:
    """Map a covered file to a repo-relative product path key."""
    normalized = file_path.replace("\\", "/")
    try:
        real_path = os.path.realpath(file_path)
    except OSError:
        real_path = normalized
    if repo_real and (real_path == repo_real or real_path.startswith(repo_real + os.sep)):
        return os.path.relpath(real_path, repo_real).replace("\\", "/")
    base = os.path.basename(normalized)
    if base in _TOPLEVEL:
        return base
    if normalized.endswith("/bin/" + base) or "/bin/" + base in normalized:
        return "bin/" + base
    if normalized.endswith("/lib/" + base) or "/lib/" + base in normalized:
        return "lib/" + base
    return base


def _coverage_value(entry: dict) -> float:
    try:
        return float(entry.get("percent_covered") or 0)
    except (TypeError, ValueError):
        return 0.0


try:
    with open(cov_json, encoding="utf-8") as file_handle:
        data = json.load(file_handle)
except Exception as err:
    print(f"coverage.json parse error: {err}", file=sys.stderr)
    sys.exit(1)

best_by_name: dict[str, float] = {}
for file_entry in data.get("files", []):
    file_path = file_entry.get("file", "")
    if not _is_product_path(file_path):
        continue
    name = _product_rel_key(file_path)
    value = _coverage_value(file_entry)
    if name not in best_by_name or value > best_by_name[name]:
        best_by_name[name] = value
for name, value in sorted(best_by_name.items()):
    print(f"{name}\t{value}")
PY
}

_pct_meets_min() {
    local pct="$1" min_percent="$2"
    awk -v pct="$pct" -v min="$min_percent" 'BEGIN {
        if (pct == "") pct = 0
        if (min == "") min = 90
        exit !(pct + 0 >= min + 0)
    }'
}

_report_script_coverage_line() {
    local script="$1" pct="$2" min_percent="$3"
    if _pct_meets_min "$pct" "$min_percent"; then
        echo "  ✓ $script: ${pct}% line coverage"
        return 0
    fi
    echo "  ✗ $script: ${pct}% line coverage (< ${min_percent}%)"
    return 1
}

_list_product_toplevel_scripts() {
    # Shared allowlist of repo-root product shell entrypoints.
    printf '%s\n' install.sh uninstall.sh
}

_list_product_shell_scripts() {
    # Product/runtime shell only (bin helpers, shared libs, installers).
    # CI tooling under scripts/ is excluded from the line-coverage gate.
    local root
    root="${KCOV_REPO_ROOT:-}"
    if [ -z "$root" ]; then
        root="$(_kcov_repo_root)"
    fi
    _list_sorted_relpaths_under "$root" "product shell directories (bin/ or lib/)" \
        "*.sh" bin lib || return $?
    _list_product_toplevel_scripts
}

_fill_pct_by_name() {
    # Fills caller-scoped associative array pct_by_name (repo-relative keys).
    local cov_json="$1" kcov_root="$2"
    local script_name pct cov_rows load_status=0
    cov_rows=$(_load_all_script_coverage "$cov_json" "$kcov_root") || load_status=$?
    if [ "$load_status" -ne 0 ]; then
        return "$load_status"
    fi
    while IFS=$'\t' read -r script_name pct; do
        [ -n "$script_name" ] || continue
        pct_by_name["$script_name"]="$pct"
    done <<< "$cov_rows"
}

_check_scripts_against_pct_map() {
    # Uses caller-scoped scripts[] and pct_by_name (repo-relative keys).
    local min_percent="$1"
    local shell_cov_fail="" script pct
    for script in "${scripts[@]}"; do
        pct="${pct_by_name[$script]:-0}"
        if ! _report_script_coverage_line "$script" "$pct" "$min_percent"; then
            shell_cov_fail="$shell_cov_fail $script"
        fi
    done
    if [ -n "$shell_cov_fail" ]; then
        echo "  ✗ Shell coverage failures:$shell_cov_fail" >&2
        return 1
    fi
    return 0
}

_load_product_shell_scripts_for_gate() {
    local shell_scripts shell_status=0
    shell_scripts=$(_list_product_shell_scripts) || shell_status=$?
    if [ "$shell_status" -ne 0 ]; then
        echo "  ✗ Failed to list product shell scripts for coverage gate." >&2
        return "$shell_status"
    fi
    if [ -z "$shell_scripts" ]; then
        echo "  ✗ No product shell scripts found for coverage gate." >&2
        return 1
    fi
    mapfile -t scripts <<< "$shell_scripts"
    if [ "${#scripts[@]}" -eq 0 ]; then
        echo "  ✗ No product shell scripts found for coverage gate." >&2
        return 1
    fi
}

check_kcov_report_percentages() {
    local cov_json="$1"
    local min_percent="${2:-90}"
    local kcov_root="${3:-}"
    local -a scripts
    local -A pct_by_name=()
    _load_product_shell_scripts_for_gate || return $?
    _fill_pct_by_name "$cov_json" "$kcov_root" || return $?
    _check_scripts_against_pct_map "$min_percent"
}
