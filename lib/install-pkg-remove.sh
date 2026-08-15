#!/usr/bin/env bash
# Package removal helpers for uninstall (sourced by install-os-detection.sh).

_is_base_runtime_pkg() {
    case "$1" in
        python3|python) return 0 ;;
        *) return 1 ;;
    esac
}

_is_allowed_pkg_name() {
    local pkg="$1"
    case "$pkg" in
        -*) return 1 ;;
    esac
    [[ "$pkg" =~ ^[A-Za-z0-9._+-]+$ ]]
}

_fallback_remove_packages_for_family() {
    local family="$1" evdev_pkg
    case "$family" in
        debian) printf '%s\n' python3-evdev alsa-tools alsa-utils ydotool xdotool ;;
        suse)
            evdev_pkg=$(_resolve_suse_evdev_pkg)
            printf '%s\n' "$evdev_pkg" hda-verb alsa-tools \
                alsa-utils ydotool xdotool
            ;;
        redhat) printf '%s\n' python3-evdev alsa-tools alsa-utils ydotool xdotool ;;
        arch) printf '%s\n' python-evdev alsa-utils alsa-tools ydotool xdotool ;;
    esac
}

_emit_recorded_packages() {
    local pkg
    while IFS= read -r pkg; do
        _emit_non_base_pkg_line "$pkg"
    done < "$STATE_DIR/installed-packages"
}

_emit_non_base_pkg_line() {
    local pkg="$1"
    [ -n "$pkg" ] || return 0
    _is_base_runtime_pkg "$pkg" && return 0
    if ! _is_allowed_pkg_name "$pkg"; then
        echo "Warning: skipping disallowed package name in installed-packages record: $pkg" >&2
        return 0
    fi
    printf '%s\n' "$pkg"
}

_write_non_base_pkg_lines_from_file() {
    local src="$1" pkg
    [ -f "$src" ] || return 0
    while IFS= read -r pkg; do
        _emit_non_base_pkg_line "$pkg"
    done < "$src"
}

_mktemp_under_state_dir() {
    local prefix="$1" path
    path=$(mktemp "${STATE_DIR}/${prefix}.XXXXXX") || return 1
    [ -n "$path" ] || return 1
    printf '%s\n' "$path"
}

_mv_tmp_to_pkg_record() {
    local tmp_merge="$1" record="$2"
    if mv "$tmp_merge" "$record"; then
        return 0
    fi
    rm -f "$tmp_merge"
    return 1
}

_sort_non_base_packages_to_file() {
    local src="$1" dest="$2"
    if ! _write_non_base_pkg_lines_from_file "$src" | sort -u > "$dest"; then
        return 1
    fi
}

_emit_fallback_packages() {
    local family pkg
    family=$(_detect_os_family || true)
    [ -z "$family" ] && return 0
    while IFS= read -r pkg; do
        _emit_non_base_pkg_line "$pkg"
    done < <(_fallback_remove_packages_for_family "$family")
}

_read_packages_to_remove() {
    if [ -n "${STATE_DIR:-}" ] && [ -f "$STATE_DIR/installed-packages" ]; then
        _emit_recorded_packages
        return 0
    fi
    if [ "${ASUS_UNINSTALL_FALLBACK_PKGS:-0}" = "1" ]; then
        _emit_fallback_packages
        return 0
    fi
    return 0
}

_filter_installed_pkgs_dpkg() {
    local pkg status
    for pkg in "$@"; do
        status=$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null) || continue
        [ "$status" = "installed" ] && printf '%s\n' "$pkg"
    done
}

_filter_installed_pkgs_rpm() {
    local pkg
    for pkg in "$@"; do rpm -q "$pkg" &>/dev/null && printf '%s\n' "$pkg"; done
}

_filter_installed_pkgs_pacman() {
    local pkg
    for pkg in "$@"; do pacman -Q "$pkg" &>/dev/null && printf '%s\n' "$pkg"; done
}

_filter_installed_pkgs_for_family() {
    local family="$1"
    shift
    [ "$#" -gt 0 ] || return 0
    case "$family" in
        debian) _filter_installed_pkgs_dpkg "$@" ;;
        suse|redhat) _filter_installed_pkgs_rpm "$@" ;;
        arch) _filter_installed_pkgs_pacman "$@" ;;
        *) return 1 ;;
    esac
}

_build_debian_pkg_remove_cmd() {
    local pkg_cmd="$1"
    shift
    local opts
    opts=$(_debian_apt_common_opts)
    [ "$#" -eq 0 ] && { echo ""; return 0; }
    # Mark as auto then autoremove: drop unused deps without --purge (keep conffiles).
    if [ "$pkg_cmd" = "apt" ]; then
        echo "DEBIAN_FRONTEND=noninteractive apt-mark auto $* && DEBIAN_FRONTEND=noninteractive apt $opts autoremove -y"
    else
        echo "DEBIAN_FRONTEND=noninteractive apt-mark auto $* && DEBIAN_FRONTEND=noninteractive apt-get $opts autoremove -y"
    fi
}

_build_suse_pkg_remove_cmd() {
    [ "$#" -eq 0 ] && { echo ""; return 0; }
    echo "zypper rm -y $* > /dev/null"
}

_build_redhat_pkg_remove_cmd() {
    local pkg_manager="$1"
    shift
    [ "$#" -eq 0 ] && { echo ""; return 0; }
    echo "$pkg_manager remove -y $* > /dev/null"
}

_build_arch_pkg_remove_cmd() {
    [ "$#" -eq 0 ] && { echo ""; return 0; }
    echo "pacman -Rs --noconfirm --unneeded $* > /dev/null"
}

_resolve_debian_pkg_remove_cmd() {
    local pkg_manager
    for pkg_manager in apt-get apt; do
        if command -v "$pkg_manager" &>/dev/null; then
            _build_debian_pkg_remove_cmd "$pkg_manager" "$@"
            return 0
        fi
    done
    return 1
}

_resolve_suse_pkg_remove_cmd() {
    command -v zypper &>/dev/null || return 1
    _build_suse_pkg_remove_cmd "$@"
}

_resolve_redhat_pkg_remove_cmd() {
    local pkg_manager
    for pkg_manager in dnf yum; do
        if command -v "$pkg_manager" &>/dev/null; then
            _build_redhat_pkg_remove_cmd "$pkg_manager" "$@"
            return 0
        fi
    done
    return 1
}

_resolve_arch_pkg_remove_cmd() {
    command -v pacman &>/dev/null || return 1
    _build_arch_pkg_remove_cmd "$@"
}

_build_pkg_remove_cmd_for_family() {
    local family="$1"
    shift
    case "$family" in
        debian) _resolve_debian_pkg_remove_cmd "$@" ;;
        suse) _resolve_suse_pkg_remove_cmd "$@" ;;
        redhat) _resolve_redhat_pkg_remove_cmd "$@" ;;
        arch) _resolve_arch_pkg_remove_cmd "$@" ;;
        *) return 1 ;;
    esac
}

_resolve_pkg_remove_cmd() {
    local os_family="$1"
    local -a candidates=() filtered=()
    mapfile -t candidates < <(_read_packages_to_remove)
    if [ "${#candidates[@]}" -gt 0 ]; then
        mapfile -t filtered < <(_filter_installed_pkgs_for_family "$os_family" "${candidates[@]}")
    fi
    _build_pkg_remove_cmd_for_family "$os_family" ${filtered[@]+"${filtered[@]}"}
}

_resolve_pkg_remove_cmd_for_family() {
    _resolve_pkg_remove_cmd "$1"
}

_pkg_remover_cmd_probe_any() {
    local family cmd
    for family in debian suse redhat arch; do
        cmd=$(_resolve_pkg_remove_cmd "$family") || continue
        [ -n "$cmd" ] || continue
        printf '%s\n' "$cmd"
        return 0
    done
    return 1
}

pkg_remover_cmd() {
    local os_family
    os_family=$(_detect_os_family || true)
    if [ -n "$os_family" ]; then
        _resolve_pkg_remove_cmd_for_family "$os_family"
        return $?
    fi
    _pkg_remover_cmd_probe_any
}

_report_no_pkg_remover() {
    if _has_supported_pkg_manager; then
        echo "  No removable system dependencies found."
    else
        echo "  ! No supported package manager detected; skipping dependency removal."
    fi
}

_report_pkg_remove_failure() {
    local rc="$1"
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        echo "  ✗ Dependency removal timed out after 20 minutes." >&2
        echo "    Retry later or run with SKIP_PKG_REMOVE=1 to skip package removal." >&2
    else
        echo "  ✗ Dependency removal failed." >&2
        echo "    If apt/dpkg is locked, wait for other package operations to finish and rerun." >&2
    fi
    return 1
}

_run_pkg_remove_cmd() {
    local cmd="$1"
    # bash -c (not -lc) keeps caller PATH stubs effective in tests/CI.
    if command -v timeout &>/dev/null; then
        timeout --kill-after=10s 20m bash -c "$cmd" </dev/null || _report_pkg_remove_failure "$?"
        return $?
    fi
    bash -c "$cmd" </dev/null || _report_pkg_remove_failure "$?"
}

_clear_installed_packages_record() {
    [ -z "${STATE_DIR:-}" ] && return 0
    rm -f "$STATE_DIR/installed-packages"
}

_filter_missing_pkgs_for_record() {
    # Prints filtered temp path on success. Exit 2 when nothing remains to record.
    local packages_file="$1" tmp_filtered
    tmp_filtered=$(_mktemp_under_state_dir "asus-pkg-filtered") || return 1
    if ! _write_non_base_pkg_lines_from_file "$packages_file" > "$tmp_filtered"; then
        rm -f "$tmp_filtered"
        return 1
    fi
    if [ ! -s "$tmp_filtered" ]; then
        rm -f "$tmp_filtered"
        return 2
    fi
    printf '%s\n' "$tmp_filtered"
}

_merge_filtered_into_pkg_record() {
    local tmp_filtered="$1" record="$2" tmp_merge
    tmp_merge=$(_mktemp_under_state_dir "asus-pkg-record") || return 1
    if ! _merge_sorted_package_record "$tmp_filtered" "$record" "$tmp_merge"; then
        rm -f "$tmp_merge"
        return 1
    fi
    _mv_tmp_to_pkg_record "$tmp_merge" "$record"
}

_record_filtered_packages_or_skip() {
    local packages_file="$1" record="$2" tmp_filtered status
    tmp_filtered=$(_filter_missing_pkgs_for_record "$packages_file")
    status=$?
    [ "$status" -eq 2 ] && return 0
    [ "$status" -eq 0 ] || return 1
    if ! _merge_filtered_into_pkg_record "$tmp_filtered" "$record"; then
        rm -f "$tmp_filtered"
        return 1
    fi
    rm -f "$tmp_filtered"
}

_record_packages_installed() {
    local packages_file="$1" record
    [ -z "${STATE_DIR:-}" ] && return 0
    [ ! -s "$packages_file" ] && return 0
    mkdir -p "$STATE_DIR"
    record=$(_installed_packages_record_path)
    _record_filtered_packages_or_skip "$packages_file" "$record"
}

_reconcile_load_kept_packages() {
    # Writes kept package names (one per line) to stdout from record minus missing_file.
    local missing_file="$1" record="$2"
    local grep_kept_file grep_status=0
    [ -f "$record" ] || return 0
    grep_kept_file=$(_mktemp_under_state_dir "asus-pkg-kept") || return 1
    if grep -vxF -f <(sed '/^$/d' "$missing_file") "$record" > "$grep_kept_file"; then
        cat "$grep_kept_file"
        rm -f "$grep_kept_file"
        return 0
    else
        grep_status=$?
    fi
    rm -f "$grep_kept_file"
    [ "$grep_status" -eq 1 ]
}

_reconcile_write_filtered_record() {
    local record="$1"
    local tmp_raw tmp_merge
    tmp_raw=$(_mktemp_under_state_dir "asus-pkg-reconcile-raw") || return 1
    tmp_merge=$(_mktemp_under_state_dir "asus-pkg-reconcile") || {
        rm -f "$tmp_raw"
        return 1
    }
    cat > "$tmp_raw"
    if ! _sort_non_base_packages_to_file "$tmp_raw" "$tmp_merge"; then
        rm -f "$tmp_raw" "$tmp_merge"
        return 1
    fi
    rm -f "$tmp_raw"
    _mv_tmp_to_pkg_record "$tmp_merge" "$record"
}

_reconcile_build_raw_pkg_list() {
    local kept_file="$1"
    shift
    {
        cat "$kept_file"
        printf '%s\n' "$@"
    } | sed '/^$/d'
}

_reconcile_prepare_batch() {
    # Prints family on stdout; fills nameref arrays. Exit 2 when nothing to reconcile.
    local missing_file="$1"
    local -n _batch_ref="$2"
    local -n _installed_ref="$3"
    local family
    family=$(_detect_os_family || true)
    if [ -z "$family" ]; then
        _revert_pkg_record_entries "$missing_file"
        return 2
    fi
    mapfile -t _batch_ref < <(sed '/^$/d' "$missing_file")
    [ "${#_batch_ref[@]}" -gt 0 ] || return 2
    mapfile -t _installed_ref < <(_filter_installed_pkgs_for_family "$family" "${_batch_ref[@]}")
    printf '%s\n' "$family"
}

_reconcile_commit_record() {
    local missing_file="$1" record="$2"
    shift 2
    local kept_file status
    kept_file=$(_mktemp_under_state_dir "asus-pkg-kept-out") || return 1
    if ! _reconcile_load_kept_packages "$missing_file" "$record" > "$kept_file"; then
        rm -f "$kept_file"
        return 1
    fi
    _reconcile_build_raw_pkg_list "$kept_file" "$@" | _reconcile_write_filtered_record "$record"
    status=$?
    rm -f "$kept_file"
    return "$status"
}

_reconcile_begin() {
    local missing_file="$1"
    [ -n "${STATE_DIR:-}" ] && [ -n "${missing_file:-}" ] && [ -f "$missing_file" ] || return 2
    _reconcile_prepare_batch "$@"
}

_reconcile_packages_installed() {
    local missing_file="$1"
    local record status
    local -a batch=() installed=()
    _reconcile_begin "$missing_file" batch installed >/dev/null
    status=$?
    case "$status" in
        0)
            # Fail closed if prepare reported success with an empty missing batch.
            [ "${#batch[@]}" -gt 0 ] || return 1
            record=$(_installed_packages_record_path)
            _reconcile_commit_record "$missing_file" "$record" \
                ${installed[@]+"${installed[@]}"}
            ;;
        2) return 0 ;;
        *) return 1 ;;
    esac
}

_validate_pkg_remove_resolution() {
    local resolve_rc="$1"
    if [ "$resolve_rc" -ne 0 ]; then
        echo "  ! Failed to resolve package-manager family for dependency removal." >&2
        echo "    Preserving installed-packages record for a later retry." >&2
        return 1
    fi
}

_handle_empty_pkg_remove_cmd() {
    local cmd="$1"
    if [ -z "$cmd" ]; then
        _report_no_pkg_remover
        if _has_supported_pkg_manager; then
            _clear_installed_packages_record
        fi
        return 0
    fi
    return 1
}

remove_system_deps() {
    [ "${SKIP_PKG_REMOVE:-0}" = "1" ] && return 0
    echo "Removing system dependencies installed by this project..."
    local cmd resolve_rc=0
    cmd=$(pkg_remover_cmd) || resolve_rc=$?
    _validate_pkg_remove_resolution "$resolve_rc" || return 1
    if _handle_empty_pkg_remove_cmd "$cmd"; then
        return 0
    fi
    _execute_pkg_remove "$cmd"
}

_execute_pkg_remove() {
    local cmd="$1"
    echo "  Removing recorded or project dependencies..."
    if _run_pkg_remove_cmd "$cmd"; then
        _clear_installed_packages_record
        return 0
    fi
    return 1
}
