#!/usr/bin/env bash

# When executed from stdin (for example: curl ... | sudo bash), re-exec from a
# temp file attached to /dev/tty so interactive prompts behave like a normal
# script execution. Piped installs require an explicit INSTALL_SOURCE_DIR.
_is_stdin_executed_script() {
    [ -z "${BASH_SOURCE[0]-}" ]
}

_install_is_direct_execution() {
    [ "${BASH_SOURCE[0]-}" = "$0" ] || [ -z "${BASH_SOURCE[0]-}" ]
}

_should_reexec_from_tty() {
    _is_stdin_executed_script && [ -z "${INSTALL_STDIN_REEXEC:-}" ] && [ ! -t 0 ] && [ -r /dev/tty ] && [ -w /dev/tty ]
}

_reexec_capture_stdin_to_temp() {
    local tmp_script="$1"
    cat > "$tmp_script"
    local status=$?
    if [ "$status" -ne 0 ]; then
        echo "Error: Failed to write temporary installer script from stdin (exit $status)." >&2
        rm -f "$tmp_script"
        return "$status"
    fi
    if [ ! -s "$tmp_script" ]; then
        echo "Error: Temporary installer script is empty after stdin capture." >&2
        rm -f "$tmp_script"
        return 1
    fi
    return 0
}

_reexec_validate_temp_script() {
    local tmp_script="$1"
    local syntax_log status
    syntax_log=$(mktemp "${TMPDIR:-/tmp}/asus-zenbook-install-syntax.XXXXXX.log")
    bash -n "$tmp_script" >"$syntax_log" 2>&1
    status=$?
    if [ "$status" -ne 0 ]; then
        cat "$syntax_log" >&2
        rm -f "$syntax_log" "$tmp_script"
        return "$status"
    fi
    rm -f "$syntax_log"
    return 0
}

_install_source_dir_is_valid() {
    [ -n "${INSTALL_SOURCE_DIR:-}" ] \
        && [ -d "${INSTALL_SOURCE_DIR}/bin" ] \
        && [ -d "${INSTALL_SOURCE_DIR}/systemd" ]
}

# Never invent INSTALL_SOURCE_DIR from $PWD; only accept an explicit caller value.
_export_install_source_dir_if_valid() {
    if _install_source_dir_is_valid; then
        export INSTALL_SOURCE_DIR
        return 0
    fi
    unset INSTALL_SOURCE_DIR
    return 1
}

_reexec_verify_temp_script_checksum() {
    local tmp_script="$1" checksum_file expected actual
    if ! _install_source_dir_is_valid; then
        echo "Error: INSTALL_SOURCE_DIR must point at a checkout (bin/ + systemd/) for piped installs." >&2
        rm -f "$tmp_script"
        return 1
    fi
    checksum_file="$INSTALL_SOURCE_DIR/install.sh.sha256"
    if [ ! -f "$checksum_file" ]; then
        echo "Error: Missing checksum file: $checksum_file" >&2
        rm -f "$tmp_script"
        return 1
    fi
    expected=$(awk '{print $1; exit}' "$checksum_file")
    actual=$(sha256sum "$tmp_script" | awk '{print $1}')
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
        echo "Error: Temporary installer script failed install.sh.sha256 verification." >&2
        rm -f "$tmp_script"
        return 1
    fi
    return 0
}

_reexec_from_tty_if_needed() {
    local script_args=("$@")
    _should_reexec_from_tty || return 0

    _install_tmp_script="$(mktemp "${TMPDIR:-/tmp}/asus-zenbook-install.XXXXXX.sh")"
    # Clean temp on failure paths; clear trap immediately before successful exec.
    trap 'rm -f "${_install_tmp_script:-}"' EXIT
    _reexec_capture_stdin_to_temp "$_install_tmp_script" || return $?
    _reexec_verify_temp_script_checksum "$_install_tmp_script" || return $?
    _reexec_validate_temp_script "$_install_tmp_script" || return $?
    chmod +x "$_install_tmp_script"
    exec </dev/tty
    export INSTALL_STDIN_REEXEC=1 INSTALL_PIPED_STDIN=1 INSTALL_TEMP_SCRIPT="$_install_tmp_script"
    _export_install_source_dir_if_valid
    trap - EXIT
    exec bash "$_install_tmp_script" "${script_args[@]}"
}

_maybe_reexec_install() {
    [ "${ASUS_INSTALL_SOURCE_ONLY:-0}" = "1" ] && return 0
    _install_is_direct_execution || return 0
    _reexec_from_tty_if_needed "$@"
}

_maybe_reexec_install "$@" || exit $?

set -euo pipefail

_validate_required_source_file() {
    local file_path="$1" label="$2"
    if [ -f "$file_path" ]; then
        return 0
    fi
    echo "Missing ${label}: $file_path" >&2
    exit 1
}

_resolve_startup_library() {
    local file_name="$1"
    # Trust INSTALL_SOURCE_DIR only after the same checkout validation as export.
    if _install_source_dir_is_valid; then
        printf '%s/lib/%s\n' "$INSTALL_SOURCE_DIR" "$file_name"
        return 0
    fi
    printf '%s/lib/%s\n' "$SCRIPT_DIR" "$file_name"
}

_load_install_helper_libraries() {
    _validate_required_source_file "$INSTALL_OS_DETECTION_LIB" "install helper"
    _validate_required_source_file "$INSTALL_GNOME_LIB" "GNOME helper"
    _validate_required_source_file "$INSTALL_KDE_LIB" "KDE helper"
    _validate_required_source_file "$INSTALL_XFCE_LIB" "XFCE helper"
    _validate_required_source_file "$INSTALL_LXQT_LIB" "LXQt helper"
    _validate_required_source_file "$INSTALL_CINNAMON_LIB" "Cinnamon helper"
    _validate_required_source_file "$INSTALL_MATE_LIB" "MATE helper"
    _validate_required_source_file "$INSTALL_SHARED_LIB" "installer shared helper"
    _validate_required_source_file "$INSTALL_I18N_LIB" "i18n helper"
    _validate_required_source_file "$INSTALL_SELECTION_LIB" "installer selection helper"
    _validate_required_source_file "$INSTALL_COMPONENTS_LIB" "installer component helper"
    _validate_required_source_file "$INSTALL_MANIFEST_LIB" "installer file manifest"
    # shellcheck source=lib/install-shared.sh
    source "$INSTALL_SHARED_LIB"
    # shellcheck source=lib/asus-i18n.sh
    source "$INSTALL_I18N_LIB"
    # shellcheck source=lib/install-os-detection.sh
    source "$INSTALL_OS_DETECTION_LIB"
    # shellcheck source=lib/install-gnome.sh
    source "$INSTALL_GNOME_LIB"
    # shellcheck source=lib/install-kde.sh
    source "$INSTALL_KDE_LIB"
    # shellcheck source=lib/install-xfce.sh
    source "$INSTALL_XFCE_LIB"
    # shellcheck source=lib/install-lxqt.sh
    source "$INSTALL_LXQT_LIB"
    # shellcheck source=lib/install-cinnamon.sh
    source "$INSTALL_CINNAMON_LIB"
    # shellcheck source=lib/install-mate.sh
    source "$INSTALL_MATE_LIB"
    # shellcheck source=lib/install-selection.sh
    source "$INSTALL_SELECTION_LIB"
    # shellcheck source=lib/install-components.sh
    source "$INSTALL_COMPONENTS_LIB"
    # shellcheck source=lib/install-file-manifest.sh
    source "$INSTALL_MANIFEST_LIB"
}

_bootstrap_installer_after_reexec() {
    PREFIX="${DESTDIR:-}"
    BIN_DIR="${PREFIX}/usr/local/bin"
    LIB_DIR="${PREFIX}/usr/local/lib/asus-zenbook-linux-tools"
    SYS_DIR="${PREFIX}/etc/systemd/system"
    HOOK_DIR="${PREFIX}/lib/systemd/system-sleep"
    export STATE_DIR="${PREFIX}/var/lib/asus-zenbook-linux-tools"
    export BUS_ROOT="${DBUS_BUS_ROOT:-/run/user}"
    SYSTEMCTL="${SYSTEMCTL_CMD:-systemctl}"
    SUDO_CMD="${SUDO_CMD:-sudo}"
    STRICT_COMPONENTS="${INSTALL_STRICT_COMPONENTS:-0}"

    if [ -n "${BASH_SOURCE[0]-}" ]; then
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    elif _install_source_dir_is_valid; then
        SCRIPT_DIR="$INSTALL_SOURCE_DIR"
    else
        echo "Error: Unable to resolve installer source directory (set INSTALL_SOURCE_DIR for piped installs)." >&2
        exit 1
    fi
    INSTALL_OS_DETECTION_LIB="$(_resolve_startup_library install-os-detection.sh)"
    INSTALL_GNOME_LIB="$(_resolve_startup_library install-gnome.sh)"
    INSTALL_KDE_LIB="$(_resolve_startup_library install-kde.sh)"
    INSTALL_XFCE_LIB="$(_resolve_startup_library install-xfce.sh)"
    INSTALL_LXQT_LIB="$(_resolve_startup_library install-lxqt.sh)"
    INSTALL_CINNAMON_LIB="$(_resolve_startup_library install-cinnamon.sh)"
    INSTALL_MATE_LIB="$(_resolve_startup_library install-mate.sh)"
    INSTALL_SHARED_LIB="$(_resolve_startup_library install-shared.sh)"
    INSTALL_I18N_LIB="$(_resolve_startup_library asus-i18n.sh)"
    INSTALL_SELECTION_LIB="$(_resolve_startup_library install-selection.sh)"
    INSTALL_COMPONENTS_LIB="$(_resolve_startup_library install-components.sh)"
    INSTALL_MANIFEST_LIB="$(_resolve_startup_library install-file-manifest.sh)"
    _load_install_helper_libraries

    if [ -n "${INSTALL_TEMP_SCRIPT:-}" ] && [ -f "${INSTALL_TEMP_SCRIPT}" ]; then
        trap 'rm -f "${INSTALL_TEMP_SCRIPT}"' EXIT
    fi
}

_prepare_install_runtime() {
    local script_dir="$1"
    local installer
    local -a installers=(
        _install_session_helper
        _install_i18n_helper
        _install_common_helper
        _install_notif_icons_helper
        _install_screenpad_helper
        _install_bootstrap_helper
        _install_display_mutter_helper
        _install_display_state_helper
        _install_display_watchdog_helper
        _install_display_osd_helper
    )
    mkdir -p "$BIN_DIR" "$SYS_DIR" "$LIB_DIR"
    for installer in "${installers[@]}"; do
        "$installer" "$script_dir" || exit 1
    done
}

_pwd_of_bash_source_dir() {
    local script_dir
    if ! script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; then
        echo "Error: Unable to resolve installer source directory." >&2
        return 1
    fi
    printf '%s\n' "$script_dir"
}

_resolve_install_script_dir() {
    if _install_source_dir_is_valid; then
        printf '%s\n' "$INSTALL_SOURCE_DIR"
        return 0
    fi

    if [ "${INSTALL_STDIN_REEXEC:-}" = "1" ] || [ -z "${BASH_SOURCE[0]-}" ]; then
        echo "Error: INSTALL_SOURCE_DIR must be set for piped/stdin installs." >&2
        exit 1
    fi

    _pwd_of_bash_source_dir || exit 1
}

_prepare_install_selection() {
    local script_dir="$1"
    _source_session_helper "$script_dir" || exit 1
    print_setup_banner 1
    printf '%s\n' "$(_asus_gettext "Choose components")"
    prompt_user_selection || exit 1
}

_print_empty_install_completion() {
    echo "=================================================="
    printf '      %s\n' "$(_asus_gettext "No components were selected. Nothing was installed.")"
    echo "=================================================="
}

main() {
    check_root

    local script_dir choice
    _export_install_source_dir_if_valid || true
    script_dir=$(_resolve_install_script_dir)
    _prepare_install_selection "$script_dir"
    choice="$INSTALL_CHOICE"

    if [ -z "$choice" ]; then
        _print_empty_install_completion
        return 0
    fi

    _install_plan_progress_steps "$choice"
    install_system_deps || exit 1

    _install_print_next_step "$(_asus_gettext "Install scripts and services")"
    _prepare_install_runtime "$script_dir"

    if run_installer_selected_components "$choice" "$script_dir"; then
        echo "=================================================="
        printf '      %s\n' "$(_asus_gettext "Installation complete.")"
        printf '      %s\n' "$(_asus_gettext "ASUS ZenBook Linux Tools is ready to use.")"
        echo "=================================================="
        return 0
    fi

    echo "==================================================" >&2
    echo "      Installation failed with one or more component errors." >&2
    echo "==================================================" >&2
    return 1
}

_maybe_bootstrap_and_main() {
    # Always load helper libraries when sourced or executed so unit/kcov can
    # call installer functions after `source install.sh` (SOURCE_ONLY or not).
    _bootstrap_installer_after_reexec
    [ "${ASUS_INSTALL_SOURCE_ONLY:-0}" = "1" ] && return 0
    _install_is_direct_execution || return 0
    main "$@"
}

_maybe_bootstrap_and_main "$@"
