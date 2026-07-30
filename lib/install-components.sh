#!/usr/bin/env bash

_source_install_component_unit_helpers() {
    local helper_dir helper
    helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    helper="$helper_dir/install-components-units.sh"
    if [ ! -f "$helper" ]; then
        echo "Missing installer unit helper: $helper" >&2
        return 1
    fi
    # shellcheck source=lib/install-components-units.sh
    . "$helper"
}

_source_install_component_unit_helpers || return 1

_should_use_strict_component_mode() {
    local strict="$1"
    [ "${STRICT_COMPONENTS:-0}" = "1" ] || [ "$strict" = "1" ]
}

_install_unit() {
    local src_dir="$1" unit_name="$2" run_action="${3:-restart}" strict="${4:-0}"

    if ! cp "$src_dir/systemd/$unit_name" "$SYS_DIR/"; then
        echo "  ✗ Failed to copy unit file $src_dir/systemd/$unit_name to $SYS_DIR/" >&2
        return 1
    fi

    if _should_use_strict_component_mode "$strict"; then
        _run_unit_management_ops "$unit_name" "$run_action"
        return $?
    fi

    _run_unit_management_ops_unverified "$unit_name" "$run_action"
}

_copy_install_file() {
    local src="$1" dest="$2"
    if ! cp "$src" "$dest"; then
        echo "  ✗ Failed to copy $src to $dest" >&2
        return 1
    fi
    return 0
}

_copy_install_relpaths() {
    local src_dir="$1" dest="$2"
    shift 2
    local relpath
    for relpath in "$@"; do
        _copy_install_file "$src_dir/$relpath" "$dest" || return 1
    done
}

_is_systemd_unit_active() {
    local unit_name="$1"
    _run_command_with_timeout "${INSTALL_COMMAND_TIMEOUT:-5}" "$SYSTEMCTL" is-active "$unit_name" 2>/dev/null | grep -qx 'active'
}

_report_wmi_unit_result() {
    if _is_systemd_unit_active "asus-hotkey-daemon.service"; then
        printf '  ✓ %s\n' "$(_asus_gettext "WMI Hotkey daemon installed and active.")"
        return 0
    fi
    if [ "${INSTALL_ASSUME_UNIT_ACTIVE:-0}" = "1" ]; then
        printf '  ✓ %s\n' "$(_asus_gettext \
            "WMI Hotkey daemon installed (active state not verified in this environment).")"
        return 0
    fi
    echo "  ✗ WMI Hotkey daemon failed to start after installation." >&2
    return 1
}

_resolve_ydotool_session_user() {
    local target_user
    target_user=$(find_active_session_user || true)
    echo "${target_user:-${SUDO_USER:-${USER:-}}}"
}

_uinput_group_users_record_path() {
    printf '%s/asus-uinput-group-users\n' "${STATE_DIR:?}"
}

_legacy_input_group_users_record_path() {
    printf '%s/input-group-users\n' "${STATE_DIR:?}"
}

_record_uinput_group_user() {
    local target_user="$1" record
    [ -n "$target_user" ] || return 0
    mkdir -p "$STATE_DIR" || return 0
    record=$(_uinput_group_users_record_path)
    if grep -qxF "$target_user" "$record" 2>/dev/null; then
        return 0
    fi
    printf '%s\n' "$target_user" >> "$record" || return 0
}

_user_in_exact_group() {
    local username="$1" group_name="$2" token
    for token in $(id -nG "$username" 2>/dev/null); do
        [ "$token" = "$group_name" ] && return 0
    done
    return 1
}

_revoke_uinput_group_members_from_record() {
    local record="$1" group_name="$2" revoke_failed=0 target_user
    if ! _uinput_revoke_record_ready "$record" "$group_name"; then
        return 0
    fi
    while IFS= read -r target_user; do
        _revoke_one_uinput_group_member "$target_user" "$group_name" || revoke_failed=1
    done < "$record"
    if [ "$revoke_failed" -eq 0 ]; then
        rm -f "$record"
    fi
    return "$revoke_failed"
}

_uinput_revoke_record_ready() {
    local record="$1" group_name="$2"
    [ -f "$record" ] || return 1
    if ! getent group "$group_name" >/dev/null 2>&1; then
        rm -f "$record"
        return 1
    fi
}

_revoke_one_uinput_group_member() {
    local target_user="$1" group_name="$2"
    [ -n "$target_user" ] || return 0
    _user_in_exact_group "$target_user" "$group_name" || return 0
    if ! gpasswd -d "$target_user" "$group_name" >/dev/null 2>&1; then
        echo "  ! Warning: could not remove $target_user from group $group_name." >&2
        return 1
    fi
}

revoke_uinput_group_members() {
    local revoke_failed=0
    _revoke_uinput_group_members_from_record "$(_uinput_group_users_record_path)" "asus-uinput" || revoke_failed=1
    _revoke_uinput_group_members_from_record "$(_legacy_input_group_users_record_path)" "input" || revoke_failed=1
    return "$revoke_failed"
}

revoke_input_group_members() {
    revoke_uinput_group_members
}

_resolve_uinput_rule_source() {
    local src_dir="$1" repo_root
    src_dir="${src_dir:-${INSTALL_SOURCE_DIR:-}}"
    if [ -z "$src_dir" ]; then
        repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        src_dir="$repo_root"
    fi
    printf '%s/udev/99-asus-uinput.rules\n' "$src_dir"
}

_ensure_uinput_group() {
    [ -z "${PREFIX:-}" ] || return 0
    if ! getent group asus-uinput >/dev/null 2>&1; then
        if ! groupadd -r asus-uinput 2>/dev/null; then
            echo "  ! Warning: could not create group asus-uinput." >&2
            return 0
        fi
    fi
}

_reload_uinput_udev_rule() {
    if [ -z "${PREFIX:-}" ] && command -v udevadm >/dev/null 2>&1; then
        _asus_soft udevadm control --reload-rules
        _asus_soft udevadm trigger --subsystem-match=misc --name-match=uinput
    fi
}

_install_uinput_udev_rule() {
    local rule_src rule_dest
    rule_src=$(_resolve_uinput_rule_source "${1:-}")
    if [ ! -f "$rule_src" ]; then
        echo "  ! Warning: missing udev rule $rule_src; /dev/uinput access may fail." >&2
        return 0
    fi
    echo "  Adding group asus-uinput and udev rule for /dev/uinput."
    echo "  Group members may write /dev/uinput and inject synthetic input;" \
        "uninstall revokes recorded users from the group."
    _ensure_uinput_group
    rule_dest="${PREFIX:-}/etc/udev/rules.d/99-asus-uinput.rules"
    mkdir -p "$(dirname "$rule_dest")"
    if ! cp "$rule_src" "$rule_dest"; then
        echo "  ! Warning: could not install udev rule to $rule_dest." >&2
        return 0
    fi
    _reload_uinput_udev_rule
    return 0
}

_uinput_user_can_be_added() {
    local target_user="$1"
    [ -n "$target_user" ] || return 0
    [ -z "${PREFIX:-}" ] || return 0
    getent group asus-uinput >/dev/null 2>&1 || return 0
    return 1
}

_add_user_to_uinput_group() {
    local target_user="$1"
    if _uinput_user_can_be_added "$target_user"; then
        return 0
    fi
    if _user_in_exact_group "$target_user" asus-uinput; then
        return 0
    fi
    if usermod -aG asus-uinput "$target_user" 2>/dev/null; then
        _record_uinput_group_user "$target_user"
        return 0
    fi
    echo "  ! Warning: could not add $target_user to group asus-uinput; ydotool may be degraded." >&2
    return 0
}

_soft_systemctl() {
    local timeout_value="${INSTALL_COMMAND_TIMEOUT:-5}" log_file
    log_file=$(mktemp 2>/dev/null) || log_file=""
    if [ -z "$log_file" ] || [ ! -e "$log_file" ]; then
        echo "  ! Warning: could not create temporary log file for systemctl $* (best-effort ydotool units)." >&2
        return 0
    fi
    if _run_command_with_timeout "$timeout_value" "$SYSTEMCTL" "$@" >"$log_file" 2>&1; then
        rm -f "$log_file"
        return 0
    fi
    echo "  ! Warning: systemctl $* failed (best-effort ydotool units)." >&2
    cat "$log_file" >&2
    rm -f "$log_file"
    return 0
}

_systemd_system_unit_exists() {
    local unit="$1" candidate
    for candidate in \
        "${PREFIX:-}/etc/systemd/system/$unit" \
        /usr/lib/systemd/system/"$unit" \
        /lib/systemd/system/"$unit"; do
        [ -f "$candidate" ] && return 0
    done
    return 1
}

_enable_ydotool_system_units() {
    if _systemd_system_unit_exists ydotoold.service; then
        _soft_systemctl enable --now ydotoold.service
    fi
    if _systemd_system_unit_exists ydotool.service; then
        _soft_systemctl enable --now ydotool.service
    fi
}

_enable_ydotoold_if_available() {
    local target_user src_dir
    command -v ydotool >/dev/null 2>&1 || return 0
    src_dir="${INSTALL_SOURCE_DIR:-}"
    _install_uinput_udev_rule "$src_dir"
    target_user=$(_resolve_ydotool_session_user)
    _add_user_to_uinput_group "$target_user"
    _enable_ydotool_system_units
    # Missing session runtime/bus must not abort the installer.
    _asus_soft _enable_ydotool_user_unit "$target_user"
}

_enable_ydotool_user_unit() {
    local target_user="$1" user_id bus_root runtime bus_path
    user_id=$(id -u "$target_user" 2>/dev/null)
    [ -n "$user_id" ] || return 1
    bus_root="$(_install_resolve_session_bus_root)"
    runtime="$bus_root/$user_id"
    bus_path="$runtime/bus"
    [ -d "$runtime" ] && [ -S "$bus_path" ] || return 1
    _install_run_as_user "$target_user" env XDG_RUNTIME_DIR="$runtime" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$bus_path" \
        systemctl --user enable --now ydotool
}

declare -gA _DESKTOP_CONFIGURE_FN_BY_FAMILY=(
    [kde]=configure_kde_component
    [xfce]=configure_xfce_component
    [lxqt]=configure_lxqt_component
    [cinnamon]=configure_cinnamon_component
    [mate]=configure_mate_component
)

configure_desktop_component() {
    local family configure_fn
    family="${ASUS_DESKTOP_FAMILY:-$(asus_desktop_family 2>/dev/null)}"
    configure_fn="${_DESKTOP_CONFIGURE_FN_BY_FAMILY[$family]-configure_gnome_component}"
    "$configure_fn"
}

_compile_one_locale_catalog() {
    local po_file="$1" locale_root="$2" lang catalog_dir output_tmp
    lang="${po_file##*/}"
    lang="${lang%.po}"
    catalog_dir="$locale_root/$lang/LC_MESSAGES"
    mkdir -p "$catalog_dir" || return 1
    output_tmp=$(mktemp "$catalog_dir/.asus-zenbook-linux-tools.mo.XXXXXX") || return 1
    if ! msgfmt --check --check-format -o "$output_tmp" "$po_file"; then
        rm -f "$output_tmp"
        return 1
    fi
    mv "$output_tmp" "$catalog_dir/asus-zenbook-linux-tools.mo"
}

_require_locale_build_inputs() {
    local src_dir="$1"
    local supported_file="$src_dir/po/SUPPORTED_LANGUAGES"
    if ! command -v msgfmt >/dev/null 2>&1; then
        echo "  ✗ gettext msgfmt is unavailable; UI catalogs cannot be installed." >&2
        return 1
    fi
    [ -f "$supported_file" ] || {
        echo "  ✗ Missing po/SUPPORTED_LANGUAGES." >&2
        return 1
    }
}

_compile_supported_locale_catalogs() {
    local src_dir="$1" locale_root="$2" supported_file po_file language
    supported_file="$src_dir/po/SUPPORTED_LANGUAGES"
    while IFS= read -r language; do
        [ -n "$language" ] || continue
        po_file="$src_dir/po/$language.po"
        [ -f "$po_file" ] || {
            echo "  ✗ Missing gettext catalog: $po_file" >&2
            return 1
        }
        _compile_one_locale_catalog "$po_file" "$locale_root" || return 1
    done < "$supported_file"
}

_install_javanese_locale_alias() {
    local locale_root="$1" catalog="asus-zenbook-linux-tools.mo"
    if [ -f "$locale_root/jw/LC_MESSAGES/$catalog" ]; then
        mkdir -p "$locale_root/jv/LC_MESSAGES" || return 1
        cp "$locale_root/jw/LC_MESSAGES/$catalog" \
            "$locale_root/jv/LC_MESSAGES/$catalog" || return 1
    fi
}

_deploy_locale_catalogs() {
    local src_dir="$1" locale_root
    [ -d "$src_dir/po" ] || return 0
    _require_locale_build_inputs "$src_dir" || return 1
    locale_root="${PREFIX:-}/usr/local/share/locale"
    _compile_supported_locale_catalogs "$src_dir" "$locale_root" || return 1
    _install_javanese_locale_alias "$locale_root"
}

_deploy_wmi_binaries() {
    local src_dir="$1"
    local -a wmi_rels=()
    mapfile -t wmi_rels < <(_asus_manifest_wmi_src_relpaths)
    _copy_install_relpaths "$src_dir" "$BIN_DIR/" ${wmi_rels[@]+"${wmi_rels[@]}"} || return 1
    local -a wmi_bins=()
    local -a wmi_chmod_rels=()
    local relpath
    mapfile -t wmi_chmod_rels < <(_asus_manifest_wmi_chmod_relpaths)
    for relpath in ${wmi_chmod_rels[@]+"${wmi_chmod_rels[@]}"}; do
        wmi_bins+=("$BIN_DIR/${relpath##*/}")
    done
    if [ "${#wmi_bins[@]}" -gt 0 ]; then
        chmod +x ${wmi_bins[@]+"${wmi_bins[@]}"} || return 1
    fi
}

_deploy_wmi_icon_assets() {
    local src_dir="$1"
    # UX582HS ScreenPad/camera keycap templates (hicolor *-symbolic SVGs).
    local icon_share="${PREFIX:-}/usr/local/share"
    mkdir -p "$icon_share/icons/hicolor/scalable/apps" \
        "$icon_share/asus-zenbook-linux-tools/icons" || return 1
    _copy_install_relpaths "$src_dir" "$icon_share/icons/hicolor/scalable/apps/" \
        assets/icons/asus-screenpad-toggle-symbolic.svg \
        assets/icons/asus-screenpad-on-symbolic.svg \
        assets/icons/asus-camera-toggle-symbolic.svg \
        assets/icons/asus-camera-on-symbolic.svg || return 1
    _copy_install_relpaths "$src_dir" "$icon_share/asus-zenbook-linux-tools/icons/" \
        assets/icons/asus-screenpad-toggle-symbolic.svg \
        assets/icons/asus-screenpad-on-symbolic.svg \
        assets/icons/asus-camera-toggle-symbolic.svg \
        assets/icons/asus-camera-on-symbolic.svg || return 1
}

_deploy_wmi_static_assets() {
    local src_dir="$1"
    _deploy_wmi_icon_assets "$src_dir" || return 1
    _deploy_locale_catalogs "$src_dir"
}

deploy_wmi_component() {
    local src_dir="$1" icon_share="${PREFIX:-}/usr/local/share"
    _deploy_wmi_binaries "$src_dir" || return 1
    _deploy_wmi_static_assets "$src_dir" || return 1
    _asus_soft gtk-update-icon-cache -f -t "$icon_share/icons/hicolor"

    _enable_ydotoold_if_available

    if _install_unit "$src_dir" "asus-hotkey-daemon.service" "restart" 1; then
        _report_wmi_unit_result
        return $?
    fi

    echo "  ✗ WMI Hotkey daemon failed to restart." >&2
    return 1
}

_report_touchpad_unit_result() {
    if _is_systemd_unit_active "asus-touchpad-share.service"; then
        printf '  ✓ %s\n' "$(_asus_gettext "Touchpad Share gesture listener installed and active.")"
        return 0
    fi
    if [ "${INSTALL_ASSUME_UNIT_ACTIVE:-0}" = "1" ]; then
        printf '  ✓ %s\n' "$(_asus_gettext \
            "Touchpad Share gesture listener installed (active state not verified in this environment).")"
        return 0
    fi
    echo "  ✗ Touchpad Share gesture listener failed to start after installation." >&2
    return 1
}

deploy_touchpad_component() {
    local src_dir="$1"
    _copy_install_relpaths "$src_dir" "$BIN_DIR/" \
        bin/asus-touchpad-share.py bin/asus_touchpad_share.py bin/asus_common.py \
        shared_imports.py bin/asus-screenshot.sh || return 1
    if [ -n "${BIN_DIR:-}" ]; then
        chmod +x "$BIN_DIR/asus-touchpad-share.py" "$BIN_DIR/asus_touchpad_share.py" \
            "$BIN_DIR/asus-screenshot.sh" || return 1
    fi

    if _install_unit "$src_dir" "asus-touchpad-share.service" "restart" 1; then
        _report_touchpad_unit_result
        return $?
    fi
    echo "  ✗ Touchpad Share gesture listener failed to restart." >&2
    return 1
}

rollback_sound_component() {
    _run_command_with_timeout "${INSTALL_COMMAND_TIMEOUT:-5}" "$SYSTEMCTL" disable --now asus-sound-fix.service 2>/dev/null || true
    _run_command_with_timeout "${INSTALL_COMMAND_TIMEOUT:-5}" "$SYSTEMCTL" daemon-reload 2>/dev/null || true
    if [ -n "${HOOK_DIR:-}" ]; then
        rm -f "$HOOK_DIR/asus-sound-fix"
    fi
}

create_suspend_hook() {
    mkdir -p "$HOOK_DIR" || return 1
    cat << EOF > "$HOOK_DIR/asus-sound-fix" || return 1
#!/bin/sh
case "\$1" in
    post)
        /usr/local/bin/asus-sound-fix.sh
        ;;
esac
EOF
    if [ -n "${HOOK_DIR:-}" ]; then
        chmod +x "$HOOK_DIR/asus-sound-fix" || return 1
    fi
}

_chmod_sound_bins() {
    [ -n "${BIN_DIR:-}" ] || return 0
    chmod +x "$BIN_DIR/asus-sound-fix.sh" "$BIN_DIR/asus_hda_verb.py"
}

deploy_sound_component() {
    local src_dir="$1"
    local probe_timeout="${SOUND_FIX_PROBE_TIMEOUT:-25}"
    _copy_install_relpaths "$src_dir" "$BIN_DIR/" \
        bin/asus-sound-fix.sh bin/asus_hda_verb.py || return 1
    _chmod_sound_bins || return 1
    _copy_install_file "$src_dir/systemd/asus-sound-fix.service" "$SYS_DIR/" || return 1
    create_suspend_hook || return 1
    _activate_sound_component "$probe_timeout"
}

_remove_sound_suspend_hook() {
    if [ -n "${HOOK_DIR:-}" ]; then
        rm -f "$HOOK_DIR/asus-sound-fix"
    fi
}

_sound_activation_failed() {
    echo "  ✗ Sound fix service activation failed." >&2
    _remove_sound_suspend_hook
    return 1
}

_enable_sound_service_or_rollback() {
    local log_file="$1"
    if _enable_sound_service "$log_file"; then
        rm -f "$log_file"
        return 0
    fi
    echo "  ✗ Sound fix service activation failed." >&2
    _print_nonempty_sound_log "$log_file"
    rm -f "$log_file"
    rollback_sound_component
    return 1
}

_probe_sound_fix_or_rollback() {
    local probe_timeout="$1"
    if _run_command_with_timeout "$probe_timeout" env \
        ASUS_SOUND_STATE_DIR="${STATE_DIR}" \
        SOUND_HWDEV_POLL_ATTEMPTS="${SOUND_HWDEV_POLL_ATTEMPTS:-15}" \
        "$BIN_DIR/asus-sound-fix.sh"; then
        return 0
    fi
    echo "  ✗ Sound fix installation failed: hardware probe did not succeed." >&2
    rollback_sound_component
    return 1
}

_activate_sound_component() {
    local probe_timeout="$1" log_file
    # Fail closed on daemon-reload: soft-swallowing a hang paid a full timeout then
    # still ran enable + rollback (two more hangs) under wedged systemctl.
    if ! _run_command_with_timeout "${INSTALL_COMMAND_TIMEOUT:-5}" "$SYSTEMCTL" daemon-reload; then
        _sound_activation_failed
        return 1
    fi
    log_file=$(mktemp)
    if ! _valid_unit_log_file "$log_file"; then
        echo "  ✗ Sound fix service activation failed: could not create temporary log file." >&2
        rollback_sound_component
        return 1
    fi
    _enable_sound_service_or_rollback "$log_file" || return 1
    _probe_sound_fix_or_rollback "$probe_timeout" || return 1
    printf '  ✓ %s\n' "$(_asus_gettext "Sound fix installed with a suspend and resume hook.")"
}

_enable_sound_service() {
    _run_command_with_timeout "${INSTALL_COMMAND_TIMEOUT:-5}" "$SYSTEMCTL" \
        enable --now asus-sound-fix.service >"$1" 2>&1
}

_print_nonempty_sound_log() {
    local log_file="$1"
    if [ -s "$log_file" ]; then
        cat "$log_file" >&2
    fi
}

_is_component_selected() {
    local choice="$1" component="$2"
    case " $choice " in
        *" $component "*) return 0 ;;
    esac
    return 1
}

_deploy_selected_component() {
    local component="$1" script_dir="$2"

    case "$component" in
        WMI) deploy_wmi_component "$script_dir" ;;
        TOUCHPAD) deploy_touchpad_component "$script_dir" ;;
        SOUND) deploy_sound_component "$script_dir" ;;
        DESKTOP) configure_desktop_component ;;
        *) return 1 ;;
    esac
}

run_installer_selected_components() {
    local choice="$1" script_dir="$2"
    local component had_failure=0

    # Normalize legacy GNOME token to DESKTOP for deployment.
    choice=${choice//GNOME/DESKTOP}

    for component in WMI TOUCHPAD SOUND DESKTOP; do
        if _is_component_selected "$choice" "$component"; then
            if ! _deploy_selected_component "$component" "$script_dir"; then
                had_failure=1
            fi
        fi
    done

    [ "$had_failure" -eq 0 ] && return 0
    return 1
}
