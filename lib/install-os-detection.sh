#!/usr/bin/env bash
# OS family and package manager detection for install.sh / uninstall.sh

_trim_os_release_value() {
    local value="$1"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    printf '%s' "$value"
}

_lookup_os_family_exact() {
    local candidate="$1"
    case "$candidate" in
        ubuntu|debian|linuxmint|pop|kali|elementary) echo "debian"; return 0 ;;
        opensuse|opensuse-leap|opensuse-tumbleweed|sles|suse) echo "suse"; return 0 ;;
        fedora|rhel|centos|rocky|almalinux|amzn) echo "redhat"; return 0 ;;
        arch|manjaro|endeavouros|artix|steamos) echo "arch"; return 0 ;;
    esac
    return 1
}

_lookup_os_family_like() {
    local candidate="$1"
    case "$candidate" in
        *ubuntu*|*debian*) echo "debian"; return 0 ;;
        *opensuse*|*suse*) echo "suse"; return 0 ;;
        *fedora*|*rhel*|*centos*|*rocky*|*almalinux*|*amzn*) echo "redhat"; return 0 ;;
        *arch*|*manjaro*|*endeavouros*|*artix*) echo "arch"; return 0 ;;
    esac
    return 1
}

_read_os_release_values() {
    local os_id="" os_like="" key value
    if [ ! -r /etc/os-release ]; then
        return 0
    fi
    while IFS='=' read -r key value; do
        case "$key" in
            ID) os_id=$(_trim_os_release_value "$value") ;;
            ID_LIKE) os_like=$(_trim_os_release_value "$value") ;;
        esac
    done < /etc/os-release
    printf '%s\n%s\n' "$os_id" "$os_like"
}

_lookup_family_from_inputs() {
    local os_id="$1" os_like="$2" family

    family=$(_lookup_os_family_exact "$os_id") && { echo "$family"; return 0; }
    family=$(_lookup_os_family_like "$os_like") && { echo "$family"; return 0; }
    return 1
}

_has_supported_pkg_manager() {
    local cmd
    for cmd in apt-get apt zypper dnf yum pacman; do
        command -v "$cmd" &>/dev/null && return 0
    done
    return 1
}

_resolve_pkg_cmd_for_debian_or_suse() {
    local os_family="$1"

    case "$os_family" in
        suse) _resolve_suse_pkg_cmd ;;
        debian) _resolve_debian_pkg_cmd ;;
        *) return 1 ;;
    esac
}

_resolve_suse_pkg_cmd() {
    command -v zypper &>/dev/null || return 1
    _build_suse_pkg_cmd
}

_resolve_debian_pkg_cmd() {
    local pkg_manager

    for pkg_manager in apt-get apt; do
        if command -v "$pkg_manager" &>/dev/null; then
            _build_debian_pkg_cmd "$pkg_manager"
            return 0
        fi
    done

    return 1
}

_resolve_pkg_cmd_for_redhat_or_arch() {
    local os_family="$1"

    case "$os_family" in
        redhat) _resolve_redhat_pkg_cmd ;;
        arch) _resolve_arch_pkg_cmd ;;
        debian|suse) return 1 ;;
        *)
            # Empty/unrecognized families only: never probe foreign managers for
            # known debian/suse after their dedicated resolvers already failed.
            _resolve_any_supported_pkg_cmd
            ;;
    esac
}

_resolve_redhat_pkg_cmd() {
    local pkg_manager

    for pkg_manager in dnf yum; do
        if command -v "$pkg_manager" &>/dev/null; then
            _build_redhat_pkg_cmd "$pkg_manager"
            return 0
        fi
    done

    return 1
}

_resolve_arch_pkg_cmd() {
    command -v pacman &>/dev/null || return 1
    _build_arch_pkg_cmd
}

_resolve_any_supported_pkg_cmd() {
    if _resolve_redhat_pkg_cmd; then
        return 0
    fi
    if _resolve_arch_pkg_cmd; then
        return 0
    fi
    if _resolve_debian_pkg_cmd; then
        return 0
    fi
    _resolve_suse_pkg_cmd
}

_detect_os_family() {
    local os_id="${INSTALL_OS_ID:-}"
    local os_like="${INSTALL_OS_ID_LIKE:-}"
    local family

    if [ -n "$os_id" ]; then
        family=$(_lookup_family_from_inputs "$os_id" "$os_like") && { echo "$family"; return 0; }
        return 1
    fi

    if [ -r /etc/os-release ]; then
        local release_values
        release_values=$(_read_os_release_values)
        os_id=$(printf '%s\n' "$release_values" | sed -n '1p')
        os_like=$(printf '%s\n' "$release_values" | sed -n '2p')
        family=$(_lookup_family_from_inputs "$os_id" "$os_like") && { echo "$family"; return 0; }
    fi

    return 1
}

_write_missing_pkg_list() {
    [ -z "${ASUS_PKG_MISSING_FILE:-}" ] && return 0
    if [ "$#" -eq 0 ]; then
        : > "$ASUS_PKG_MISSING_FILE"
        return 0
    fi
    printf '%s\n' "$@" > "$ASUS_PKG_MISSING_FILE"
}

_installed_packages_record_path() {
    printf '%s/installed-packages\n' "${STATE_DIR:?}"
}

_merge_sorted_package_record() {
    local packages_file="$1" record="$2" tmp_merge="$3"
    if [ -f "$record" ]; then
        sort -u "$packages_file" "$record" > "$tmp_merge"
        return $?
    fi
    sort -u "$packages_file" > "$tmp_merge"
}

_resolve_suse_versioned_python_pkg() {
    local suffix="$1" ver pkg py=/usr/bin/python3
    ver=$(_suse_python_version_digits "$py")
    [ -n "$ver" ] || { printf '%s\n' "python3-${suffix}"; return 0; }
    pkg="python${ver}-${suffix}"
    if rpm -q "$pkg" &>/dev/null; then
        printf '%s\n' "$pkg"
        return 0
    fi
    if rpm -q "python3-${suffix}" &>/dev/null; then
        printf '%s\n' "python3-${suffix}"
        return 0
    fi
    # Neither installed: request the versioned package (openSUSE Tumbleweed/Leap).
    printf '%s\n' "$pkg"
}

_resolve_suse_evdev_pkg() {
    _resolve_suse_versioned_python_pkg "evdev"
}

_resolve_suse_gobject_pkg() {
    _resolve_suse_versioned_python_pkg "gobject"
}

_resolve_suse_curses_pkg() {
    _resolve_suse_versioned_python_pkg "curses"
}

_suse_python_version_digits() {
    local py="$1"
    if [ -x "$py" ]; then
        "$py" -c 'import sys; print(f"{sys.version_info.major}{sys.version_info.minor}")' \
            2>/dev/null || return 0
    fi
}

_zypper_repo_has_pkg() {
    local pkg="$1"
    command -v zypper >/dev/null 2>&1 || return 1
    zypper --non-interactive search -x "$pkg" >/dev/null 2>&1
}

_should_request_suse_optional_pkg() {
    # Leap may lack ydotool while Tumbleweed packages it; only request when known.
    local pkg="$1"
    rpm -q "$pkg" &>/dev/null && return 0
    _zypper_repo_has_pkg "$pkg"
}

_append_suse_core_missing_pkgs() {
    local -n _suse_missing=$1
    local pkg evdev_pkg gobject_pkg curses_pkg
    evdev_pkg=$(_resolve_suse_evdev_pkg)
    gobject_pkg=$(_resolve_suse_gobject_pkg)
    curses_pkg=$(_resolve_suse_curses_pkg)
    for pkg in python3 "$evdev_pkg" "$gobject_pkg" "$curses_pkg" \
        gettext-tools hda-verb alsa-utils xdotool; do
        rpm -q "$pkg" &>/dev/null || _suse_missing+=("$pkg")
    done
}

_build_suse_pkg_cmd() {
    local missing=()
    _append_suse_core_missing_pkgs missing
    if _should_request_suse_optional_pkg ydotool; then
        rpm -q ydotool &>/dev/null || missing+=("ydotool")
    fi

    _write_missing_pkg_list ${missing[@]+"${missing[@]}"}
    [ "${#missing[@]}" -eq 0 ] && { echo ""; return 0; }
    echo "zypper in -y ${missing[*]} > /dev/null"
}

_debian_apt_common_opts() {
    printf '%s' \
        '-o DPkg::Lock::Timeout=60 -o Acquire::Retries=2 ' \
        '-o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15 ' \
        '-o Dpkg::Use-Pty=0'
}

_os_release_id() {
    local id="${INSTALL_OS_ID:-}" release_values
    if [ -z "$id" ]; then
        release_values=$(_read_os_release_values)
        id=$(printf '%s\n' "$release_values" | head -n1)
    fi
    printf '%s' "$id"
}

_should_request_ydotool_deb() {
    # Debian lacks ydotool; Ubuntu/derivatives package it (xdotool still covers OSD).
    [ "$(_os_release_id)" != "debian" ]
}

_emit_missing_if_absent_dpkg() {
    dpkg -s "$1" &>/dev/null || printf '%s\n' "$1"
}

_collect_missing_debian_pkgs() {
    local pkg
    for pkg in python3 python3-evdev python3-gi gettext alsa-tools alsa-utils xdotool; do
        _emit_missing_if_absent_dpkg "$pkg"
    done
    _should_request_ydotool_deb && _emit_missing_if_absent_dpkg ydotool
    return 0
}

_build_debian_pkg_cmd() {
    local pkg_cmd="$1" opts
    local -a missing=()
    opts=$(_debian_apt_common_opts)
    mapfile -t missing < <(_collect_missing_debian_pkgs)
    _write_missing_pkg_list ${missing[@]+"${missing[@]}"}
    [ "${#missing[@]}" -eq 0 ] && { echo ""; return 0; }
    if [ "$pkg_cmd" = "apt" ]; then
        echo "DEBIAN_FRONTEND=noninteractive apt $opts update && DEBIAN_FRONTEND=noninteractive apt $opts install -y ${missing[*]}"
        return 0
    fi
    echo "DEBIAN_FRONTEND=noninteractive apt-get $opts update && DEBIAN_FRONTEND=noninteractive apt-get $opts install -y ${missing[*]}"
}

_detect_debian_or_suse_pkg_cmd() {
    local os_family
    os_family=$(_detect_os_family || true)
    # When INSTALL_OS_ID is explicitly set but unrecognised, don't fall back to probing
    if [ -n "${INSTALL_OS_ID:-}" ] && [ -z "$os_family" ]; then
        return 1
    fi
    _resolve_pkg_cmd_for_debian_or_suse "$os_family"
}

_rhel_family_skips_optional_rpm() {
    # Rocky/RHEL/Alma: no ydotool; alsa-tools-firmware only (no hda-verb). Fedora has both.
    case "$(_os_release_id)" in
        rocky|rhel|almalinux|centos|amzn) return 0 ;;
        *) return 1 ;;
    esac
}

_should_request_ydotool_rpm() { ! _rhel_family_skips_optional_rpm; }
_should_request_alsa_tools_rpm() { ! _rhel_family_skips_optional_rpm; }

_rpm_repo_has_pkg() {
    local pkg="$1"
    if command -v dnf >/dev/null 2>&1; then
        dnf info -q "$pkg" >/dev/null 2>&1
        return $?
    fi
    return 1
}

_should_request_rpm_if_known() {
    # EL10 (Alma) may lack python3-evdev / xdotool that EL9 still packages.
    local pkg="$1"
    rpm -q "$pkg" &>/dev/null && return 0
    _rpm_repo_has_pkg "$pkg"
}

_emit_missing_if_absent_rpm() {
    rpm -q "$1" &>/dev/null || printf '%s\n' "$1"
}

_collect_missing_redhat_core_pkgs() {
    local pkg
    for pkg in python3 python3-gobject gettext alsa-utils; do
        _emit_missing_if_absent_rpm "$pkg"
    done
}

_collect_missing_redhat_input_pkgs() {
    _should_request_rpm_if_known python3-evdev && _emit_missing_if_absent_rpm python3-evdev
    _should_request_rpm_if_known python3-curses && _emit_missing_if_absent_rpm python3-curses
    _should_request_rpm_if_known xdotool && _emit_missing_if_absent_rpm xdotool
    return 0
}

_collect_missing_redhat_optional_pkgs() {
    _collect_missing_redhat_input_pkgs
    _should_request_alsa_tools_rpm && _emit_missing_if_absent_rpm alsa-tools
    _should_request_ydotool_rpm && _emit_missing_if_absent_rpm ydotool
    return 0
}

_collect_missing_redhat_pkgs() {
    _collect_missing_redhat_core_pkgs
    _collect_missing_redhat_optional_pkgs
}

_build_redhat_pkg_cmd() {
    local pkg_manager="$1"
    local -a missing=()
    mapfile -t missing < <(_collect_missing_redhat_pkgs)
    _write_missing_pkg_list ${missing[@]+"${missing[@]}"}
    [ "${#missing[@]}" -eq 0 ] && { echo ""; return 0; }
    echo "$pkg_manager install -y ${missing[*]} > /dev/null"
}

_build_arch_pkg_cmd() {
    local missing=() pkg

    for pkg in python python-evdev python-gobject gettext \
        alsa-utils alsa-tools ydotool xdotool; do
        pacman -Q "$pkg" &>/dev/null || missing+=("$pkg")
    done

    _write_missing_pkg_list ${missing[@]+"${missing[@]}"}
    [ "${#missing[@]}" -eq 0 ] && { echo ""; return 0; }
    echo "pacman -S --noconfirm ${missing[*]} > /dev/null"
}

_detect_redhat_or_arch_pkg_cmd() {
    local os_family
    os_family=$(_detect_os_family || true)
    # When INSTALL_OS_ID is explicitly set but unrecognised, don't fall back to probing
    if [ -n "${INSTALL_OS_ID:-}" ] && [ -z "$os_family" ]; then
        return 1
    fi
    _resolve_pkg_cmd_for_redhat_or_arch "$os_family"
}

pkg_installer_cmd() {
    _detect_debian_or_suse_pkg_cmd || _detect_redhat_or_arch_pkg_cmd
}

_report_no_pkg_installer() {
    local family=""
    if [ -n "${INSTALL_OS_ID:-}" ]; then
        family=$(_detect_os_family 2>/dev/null) || family=""
        if [ -z "$family" ]; then
            echo "  ! Unrecognized INSTALL_OS_ID=${INSTALL_OS_ID}; skipping dependency installation." >&2
            return 0
        fi
    fi
    if _has_supported_pkg_manager; then
        echo "  All system dependencies already installed."
    else
        echo "  ! No supported package manager detected; skipping dependency installation."
    fi
}

_report_pkg_install_failure() {
    local rc="$1"
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        echo "  ✗ Dependency installation timed out after 20 minutes." >&2
        echo "    Retry later or run with SKIP_PKG_INSTALL=1 if dependencies are already installed." >&2
    else
        echo "  ✗ Dependency installation failed." >&2
        echo "    If apt/dpkg is locked, wait for other package operations to finish and rerun." >&2
    fi
    return 1
}

_run_pkg_install_cmd() {
    local cmd="$1"
    # bash -c (not -lc) keeps caller PATH stubs; stdin /dev/null avoids SIGTTIN.
    if command -v timeout &>/dev/null; then
        timeout --kill-after=10s 20m bash -c "$cmd" </dev/null || _report_pkg_install_failure "$?"
        return $?
    fi
    bash -c "$cmd" </dev/null || _report_pkg_install_failure "$?"
}

# Package removal lives in a sibling module (file-size gate); source before install_system_deps
# so reconcile helpers can filter installed package names.
install_os_detection_init() {
    local pkg_remove_lib
    if ! declare -F _validate_required_source_file >/dev/null 2>&1; then
        _validate_required_source_file() {
            local file_path="$1" label="$2"
            if [ -f "$file_path" ]; then
                return 0
            fi
            echo "Missing ${label}: $file_path" >&2
            return 1
        }
    fi
    pkg_remove_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install-pkg-remove.sh"
    if ! _validate_required_source_file "$pkg_remove_lib" "package removal helper"; then
        return 1
    fi
    # shellcheck source=lib/install-pkg-remove.sh
    . "$pkg_remove_lib"
}

if [ "${ASUS_OS_DETECTION_SKIP_INIT:-0}" != "1" ]; then
    install_os_detection_init || return 1 2>/dev/null || exit 1
fi

_revert_pkg_record_entries() {
    # Drop pre-recorded package names from missing_file when install cannot reconcile.
    local missing_file="$1"
    local record tmp_merge grep_status
    record=$(_pkg_revert_record "$missing_file") || return 0
    tmp_merge=$(_create_pkg_revert_temp) || return 1
    _write_reverted_pkg_record "$missing_file" "$record" "$tmp_merge" || return 1
    if ! mv "$tmp_merge" "$record"; then
        rm -f "$tmp_merge"
        return 1
    fi
}

_pkg_revert_record() {
    local missing_file="$1" record
    _pkg_revert_inputs_exist "$missing_file" || return 1
    record=$(_installed_packages_record_path)
    [ -f "$record" ] || return 1
    printf '%s\n' "$record"
}

_create_pkg_revert_temp() {
    local tmp
    tmp=$(mktemp "${STATE_DIR}/asus-pkg-revert.XXXXXX") || return 1
    [ -n "$tmp" ] || return 1
    printf '%s\n' "$tmp"
}

_pkg_revert_inputs_exist() {
    local missing_file="$1"
    [ -n "${STATE_DIR:-}" ] || return 1
    [ -n "${missing_file:-}" ] || return 1
    [ -f "$missing_file" ]
}

_write_reverted_pkg_record() {
    local missing_file="$1" record="$2" tmp_merge="$3" grep_status
    if grep -vxF -f <(sed '/^$/d' "$missing_file") "$record" > "$tmp_merge"; then
        return 0
    else
        grep_status=$?
        if [ "$grep_status" -ne 1 ]; then
            rm -f "$tmp_merge"
            return 1
        fi
        : > "$tmp_merge"
    fi
}

_prepare_pkg_install() {
    local -n _pkg_cmd_out="$1" _missing_file_out="$2"
    mkdir -p "$STATE_DIR"
    _missing_file_out=$(mktemp "${STATE_DIR}/asus-pkg-missing.XXXXXX") || return 1
    [ -n "$_missing_file_out" ] || return 1
    # Resolve family command first without writing the missing list.
    if ! _pkg_cmd_out=$(pkg_installer_cmd); then
        _report_no_pkg_installer
        rm -f "$_missing_file_out"
        return 2
    fi
    if [ -z "$_pkg_cmd_out" ]; then
        _report_no_pkg_installer
        rm -f "$_missing_file_out"
        return 2
    fi
    # Only after a successful resolve, capture the missing-package list for recording.
    ASUS_PKG_MISSING_FILE="$_missing_file_out"
    pkg_installer_cmd >/dev/null
    unset ASUS_PKG_MISSING_FILE
}

_execute_pkg_install() {
    local cmd="$1" missing_file="$2"
    echo "  Installing missing dependencies..."
    _record_packages_installed "$missing_file" || {
        rm -f "$missing_file"
        return 1
    }
    if _run_pkg_install_cmd "$cmd"; then
        if ! _reconcile_packages_installed "$missing_file"; then
            rm -f "$missing_file"
            echo "  ✗ Failed to reconcile installed package record." >&2
            return 1
        fi
        rm -f "$missing_file"
        return 0
    fi
    _asus_soft _reconcile_packages_installed "$missing_file"
    rm -f "$missing_file"
    return 1
}

install_system_deps() {
    [ "${SKIP_PKG_INSTALL:-0}" = "1" ] && return 0
    printf '[2/4] %s\n' "$(_asus_gettext "Install system dependencies")"
    printf '  %s\n' "$(_asus_gettext "This can take a few minutes while packages are downloaded and installed.")"
    local cmd missing_file prepare_status=0
    _prepare_pkg_install cmd missing_file || prepare_status=$?
    _finish_system_deps_prepare "$cmd" "$missing_file" "$prepare_status"
}

_finish_system_deps_prepare() {
    local cmd="$1" missing_file="$2" prepare_status="$3"
    if [ "$prepare_status" -eq 2 ]; then
        return 0
    fi
    [ "$prepare_status" -eq 0 ] || return "$prepare_status"
    _execute_pkg_install "$cmd" "$missing_file"
}

