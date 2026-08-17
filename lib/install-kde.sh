#!/usr/bin/env bash
# KDE Plasma shortcut configuration for the DESKTOP install component.

_kde_first_cmd() {
    local cand
    for cand in "$@"; do
        if command -v "$cand" >/dev/null 2>&1; then
            command -v "$cand"
            return 0
        fi
    done
    return 1
}

_kde_kwriteconfig_bin() {
    _kde_first_cmd kwriteconfig6 kwriteconfig5
}

_kde_kreadconfig_bin() {
    _kde_first_cmd kreadconfig6 kreadconfig5
}

_kde_user_config_env() {
    local user="$1" home_dir config_home
    home_dir=$(getent passwd "$user" | cut -d: -f6 || true)
    [ -n "$home_dir" ] || return 1
    config_home="${home_dir}/.config"
    printf '%s\n%s\n' "$home_dir" "$config_home"
}

_kde_qdbus_bin() {
    _kde_first_cmd qdbus6 qdbus-qt6 qdbus
}

_kde_write_shortcut() {
    local user="$1" conf="$2" group="$3" key="$4" value="$5"
    local home_dir config_home
    {
        read -r home_dir
        read -r config_home
    } < <(_kde_user_config_env "$user") || return 1
    _install_run_as_user "$user" env HOME="$home_dir" XDG_CONFIG_HOME="$config_home" \
        "$conf" --file kglobalshortcutsrc --group "$group" --key "$key" "$value"
}

_kde_read_shortcut() {
    local user="$1" group="$2" key="$3"
    local home_dir config_home kread
    kread=$(_kde_kreadconfig_bin) || return 1
    {
        read -r home_dir
        read -r config_home
    } < <(_kde_user_config_env "$user") || return 1
    _install_run_as_user "$user" env HOME="$home_dir" XDG_CONFIG_HOME="$config_home" \
        "$kread" --file kglobalshortcutsrc --group "$group" --key "$key" 2>/dev/null
}

_kde_atomic_write_file() {
    local dest="$1" mode="$2" val="${3:-}" tmp
    tmp="${dest}.tmp"
    if [ "$mode" = "value" ]; then
        if ! printf '%s\n' "$val" > "$tmp"; then
            rm -f "$tmp"
            return 1
        fi
    elif ! : > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv "$tmp" "$dest"; then
        rm -f "$tmp"
        return 1
    fi
}

_kde_write_backup_value_or_absent() {
    local dest="$1" val="$2"
    if [ -n "$val" ]; then
        _kde_atomic_write_file "$dest" value "$val"
        return $?
    fi
    _kde_atomic_write_file "${dest}.absent" absent
}

_kde_backup_shortcut_key() {
    local user="$1" group="$2" key="$3" dest="$4" val
    if [ -f "$dest" ] || [ -f "${dest}.absent" ]; then
        return 0
    fi
    val=$(_kde_read_shortcut "$user" "$group" "$key") || return 0
    _kde_write_backup_value_or_absent "$dest" "$val"
}

_kde_backup_kscreen_group() {
    local user="$1" config_dir="$2"
    _kde_backup_shortcut_key "$user" "kscreen" "_launch" \
        "$config_dir/orig_kde_kscreen_launch"
    _kde_backup_shortcut_key "$user" "kscreen" "_k_friendly_name" \
        "$config_dir/orig_kde_kscreen_friendly"
}

_kde_restore_kscreen_key() {
    local user="$1" conf="$2" group="$3" key="$4" backup="$5"
    if [ -f "${backup}.absent" ]; then
        _delete_kde_shortcut_key "$user" "$conf" "$group" "$key"
        return 0
    fi
    [ -f "$backup" ] || return 0
    _kde_write_shortcut "$user" "$conf" "$group" "$key" "$(cat "$backup" 2>/dev/null)" || return 1
}

_kde_restore_kscreen_group() {
    local user="$1" conf="$2" config_dir="$3"
    _kde_restore_kscreen_key "$user" "$conf" "kscreen" "_launch" \
        "$config_dir/orig_kde_kscreen_launch" || return 1
    _kde_restore_kscreen_key "$user" "$conf" "kscreen" "_k_friendly_name" \
        "$config_dir/orig_kde_kscreen_friendly" || return 1
}

_kde_backup_marker() {
    local state_root="$1" config_dir="$2"
    printf 'kde\n' > "$state_root/desktop_family" || return 1
    printf 'kglobalshortcutsrc\n' > "$config_dir/kde_backend" || return 1
}

_kde_state_config_dir() {
    printf '%s/kde\n' "$1"
}

_apply_kde_shortcut_group() {
    local user="$1" conf="$2" group="$3" friendly="$4" binding="$5"
    _kde_write_shortcut "$user" "$conf" "$group" "_k_friendly_name" "$friendly" || return 1
    _kde_write_shortcut "$user" "$conf" "$group" "_launch" \
        "${binding},none,${friendly}" || return 1
}

_kde_reconfigure_kglobalaccel() {
    local user="$1" home_dir config_home user_id runtime bus_addr qdbus_bin
    qdbus_bin=$(_kde_qdbus_bin) || return 1
    {
        read -r home_dir
        read -r config_home
    } < <(_kde_user_config_env "$user") || return 1
    user_id=$(id -u "$user" 2>/dev/null) || return 1
    runtime="$(_install_resolve_session_bus_root)/$user_id"
    bus_addr="unix:path=$runtime/bus"
    _install_run_as_user "$user" env HOME="$home_dir" XDG_CONFIG_HOME="$config_home" \
        XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="$bus_addr" \
        "$qdbus_bin" org.kde.kglobalaccel /kglobalaccel org.kde.KGlobalAccel.reconfigure \
        >/dev/null 2>&1
}

_kde_require_kscreen_backup() {
    local config_dir="$1"
    local launch="$config_dir/orig_kde_kscreen_launch"
    local friendly="$config_dir/orig_kde_kscreen_friendly"
    if { [ -f "$launch" ] || [ -f "${launch}.absent" ]; } \
        && { [ -f "$friendly" ] || [ -f "${friendly}.absent" ]; }; then
        return 0
    fi
    echo "  ✗ KDE configuration failed: kscreen shortcut backup missing." >&2
    return 1
}

_set_kde_keybindings() {
    local user="$1" conf="$2" config_dir="$3"
    local display_name settings_name screenshot_name
    [ -n "$conf" ] || return 1
    display_name=$(_asus_gettext "ASUS Display Mode")
    settings_name=$(_asus_gettext "ASUS ZenBook Settings")
    screenshot_name=$(_asus_gettext "ASUS Screenshot")
    _kde_backup_kscreen_group "$user" "$config_dir"
    _kde_require_kscreen_backup "$config_dir" || return 1
    _delete_kde_shortcut_group "$user" "$conf" "kscreen"
    _apply_asus_kde_shortcuts "$user" "$conf" \
        "$display_name" "$settings_name" "$screenshot_name" || return 1
    if ! _kde_reconfigure_kglobalaccel "$user"; then
        echo "  ! Warning: KGlobalAccel reconfigure failed; shortcuts written but may need a re-login." >&2
    fi
    return 0
}

_apply_asus_kde_shortcuts() {
    local user="$1" conf="$2" display_name="$3" settings_name="$4" screenshot_name="$5"
    _apply_kde_shortcut_group "$user" "$conf" "asus-display-mode.desktop" \
        "$display_name" "Meta+P" || return 1
    _apply_kde_shortcut_group "$user" "$conf" "asus-control-center.desktop" \
        "$settings_name" "Meta+Shift+F12" || return 1
    _apply_kde_shortcut_group "$user" "$conf" "asus-screenshot.desktop" \
        "$screenshot_name" "Meta+Shift+S" || return 1
}

_delete_kde_shortcut_key() {
    local user="$1" conf="$2" group="$3" key="$4"
    local home_dir config_home
    {
        read -r home_dir
        read -r config_home
    } < <(_kde_user_config_env "$user") || return 1
    _install_run_as_user "$user" env HOME="$home_dir" XDG_CONFIG_HOME="$config_home" \
        "$conf" --file kglobalshortcutsrc --group "$group" --key "$key" --delete >/dev/null 2>&1
}

_delete_kde_shortcut_group() {
    local user="$1" conf="$2" group="$3"
    _delete_kde_shortcut_key "$user" "$conf" "$group" "_launch"
    _delete_kde_shortcut_key "$user" "$conf" "$group" "_k_friendly_name"
}

_remove_kde_helper_desktops() {
    rm -f "${PREFIX:-}/usr/local/share/applications/asus-display-mode.desktop" \
        "${PREFIX:-}/usr/local/share/applications/asus-control-center.desktop" \
        "${PREFIX:-}/usr/local/share/applications/asus-screenshot.desktop"
}

_kde_cleanup_state_and_desktops() {
    local state_root="$1" config_dir
    _remove_kde_helper_desktops
    config_dir=$(_kde_state_config_dir "$state_root")
    if [ -d "$config_dir" ]; then
        rm -rf "$config_dir" || return 1
    fi
    return 0
}

restore_kde_shortcuts() {
    local user="$1" state_root="$2" config_dir conf group failed=0
    config_dir=$(_kde_state_config_dir "$state_root")
    conf=$(_kde_kwriteconfig_bin) || {
        _remove_kde_helper_desktops
        return 1
    }
    for group in asus-display-mode.desktop asus-control-center.desktop asus-screenshot.desktop; do
        _delete_kde_shortcut_group "$user" "$conf" "$group"
    done
    if ! _kde_restore_kscreen_group "$user" "$conf" "$config_dir"; then
        failed=1
    fi
    _kde_finish_restore "$user" "$state_root" "$failed" || failed=1
    return "$failed"
}

_kde_finish_restore() {
    local user="$1" state_root="$2" failed="$3"
    if [ "$failed" -ne 0 ]; then
        _remove_kde_helper_desktops
        return 1
    fi
    if ! _kde_reconfigure_kglobalaccel "$user"; then
        echo "  ! Warning: KGlobalAccel reconfigure failed during restore; continuing." >&2
    fi
    _kde_cleanup_state_and_desktops "$state_root"
}

_write_kde_helper_desktops() {
    local apps_dir="${PREFIX:-}/usr/local/share/applications"
    local display_name settings_name screenshot_name
    display_name=$(_asus_gettext "ASUS Display Mode")
    settings_name=$(_asus_gettext "ASUS ZenBook Settings")
    screenshot_name=$(_asus_gettext "ASUS Screenshot")
    mkdir -p "$apps_dir" || return 1
    cat > "$apps_dir/asus-display-mode.desktop" <<EOF || return 1
[Desktop Entry]
Type=Application
Name=${display_name}
Exec=/usr/local/bin/asus-display-mode.sh
NoDisplay=true
EOF
    cat > "$apps_dir/asus-control-center.desktop" <<EOF || return 1
[Desktop Entry]
Type=Application
Name=${settings_name}
Exec=/usr/local/bin/asus-control-center.sh
NoDisplay=true
EOF
    cat > "$apps_dir/asus-screenshot.desktop" <<EOF || return 1
[Desktop Entry]
Type=Application
Name=${screenshot_name}
Exec=/usr/local/bin/asus-screenshot.sh
NoDisplay=true
EOF
}

_kde_install_precheck() {
    local info="$1"
    if [ -z "$info" ]; then
        echo "  ✗ KDE configuration failed: desktop D-Bus session not found." >&2
        return 1
    fi
    if ! _kde_kwriteconfig_bin >/dev/null; then
        echo "  ✗ KDE configuration failed: kwriteconfig5/6 not found." >&2
        return 1
    fi
    if ! _kde_kreadconfig_bin >/dev/null; then
        echo "  ✗ KDE configuration failed: kreadconfig5/6 not found." >&2
        return 1
    fi
    if ! _kde_qdbus_bin >/dev/null; then
        echo "  ✗ KDE configuration failed: qdbus6/qdbus-qt6/qdbus not found." >&2
        return 1
    fi
    return 0
}

_kde_apply_keybindings_or_restore() {
    local target_user="$1" conf="$2" config_dir="$3" state_root="$4"
    if _set_kde_keybindings "$target_user" "$conf" "$config_dir"; then
        printf '  ✓ %s\n' "$(_asus_gettext "KDE Plasma shortcuts configured.")"
        return 0
    fi
    if ! restore_kde_shortcuts "$target_user" "$state_root"; then
        echo "  ! Warning: KDE backup state remains under $state_root for manual recovery." >&2
    fi
    echo "  ✗ KDE configuration failed: shortcut updates could not be applied." >&2
    return 1
}

configure_kde_component() {
    local info target_user user_id state_root config_dir conf
    info=$(_resolve_user_bus_info)
    _kde_install_precheck "$info" || return 1
    conf=$(_kde_kwriteconfig_bin)

    target_user=$(echo "$info" | cut -d: -f1)
    user_id=$(echo "$info" | cut -d: -f2)
    _install_print_next_step "$(_asus_gettextf "Configure KDE Plasma shortcuts for %s" "$target_user")"
    state_root="${STATE_DIR}/${user_id}"
    config_dir=$(_kde_state_config_dir "$state_root")
    _kde_prepare_install_state "$state_root" "$config_dir" "$target_user" || return 1
    _kde_apply_keybindings_or_restore "$target_user" "$conf" "$config_dir" "$state_root"
}

_kde_write_target_user_state() {
    local state_root="$1" target_user="$2"
    if ! echo "$target_user" > "$state_root/target_user.tmp"; then
        echo "  ✗ KDE configuration failed: could not write target_user state." >&2
        rm -f "$state_root/target_user.tmp"
        rm -f "$state_root/desktop_family" "$state_root/target_user"
        return 1
    fi
    if ! mv "$state_root/target_user.tmp" "$state_root/target_user"; then
        echo "  ✗ KDE configuration failed: could not finalize target_user state." >&2
        rm -f "$state_root/target_user.tmp"
        rm -f "$state_root/desktop_family" "$state_root/target_user"
        return 1
    fi
}

_kde_prepare_install_state() {
    local state_root="$1" config_dir="$2" target_user="$3"
    if ! mkdir -p "$config_dir"; then
        echo "  ✗ KDE configuration failed: could not create state directory." >&2
        return 1
    fi
    if ! _kde_backup_marker "$state_root" "$config_dir"; then
        echo "  ✗ KDE configuration failed: could not back up existing shortcuts." >&2
        return 1
    fi
    _kde_write_target_user_state "$state_root" "$target_user" || return 1
    if ! _write_kde_helper_desktops; then
        echo "  ✗ KDE configuration failed: could not write helper desktop files." >&2
        rm -f "$state_root/desktop_family" "$state_root/target_user"
        return 1
    fi
}
