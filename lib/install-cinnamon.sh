#!/usr/bin/env bash
# Cinnamon custom keybindings for the DESKTOP install component (gsettings).

# slot|binding_array|name|command|backup_basename
_cinnamon_shortcut_table() {
    local display control screenshot
    display=$(_asus_ui_label "ASUS Display Mode")
    control=$(_asus_ui_label "ASUS ZenBook Settings")
    screenshot=$(_asus_ui_label "ASUS Screenshot")
    printf "asus-display-mode|['XF86Display']|%s|/usr/local/bin/asus-display-mode.sh|orig_cinnamon_xf86display\n" \
        "$display"
    printf "asus-control-center|['<Super>F12']|%s|/usr/local/bin/asus-control-center.sh|orig_cinnamon_super_f12\n" \
        "$control"
    printf "asus-screenshot|['<Super><Shift>s']|%s|/usr/local/bin/asus-screenshot.sh|orig_cinnamon_super_shift_s\n" \
        "$screenshot"
}

_cinnamon_custom_schema() {
    local slot="$1"
    printf '%s\n' \
        "org.cinnamon.desktop.keybindings.custom-keybinding:/org/cinnamon/desktop/keybindings/custom-keybindings/${slot}/"
}

_cinnamon_atomic_write() {
    local dest="$1" value="$2" tmp
    tmp="${dest}.tmp"
    if ! printf '%s\n' "$value" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv "$tmp" "$dest"; then
        rm -f "$tmp"
        return 1
    fi
}

_cinnamon_write_state_file() {
    local dest="$1" value="$2" label="$3"
    if ! _cinnamon_atomic_write "$dest" "$value"; then
        echo "  ✗ Cinnamon configuration failed: could not write ${label} state." >&2
        return 1
    fi
}

_cinnamon_mark_absent() {
    local dest="$1"
    _cinnamon_atomic_write "${dest}.absent" ""
}

_cinnamon_backup_key() {
    local user="$1" bus="$2" schema="$3" key="$4" dest="$5" val
    [ -f "$dest" ] && return 0
    if val=$(_user_gsettings "$user" "$bus" get "$schema" "$key" 2>/dev/null); then
        _cinnamon_atomic_write "$dest" "$val" || return 1
        return 0
    fi
    _cinnamon_mark_absent "$dest"
}

_cinnamon_backup_slot() {
    local user="$1" bus="$2" slot="$3" dest="$4" schema val
    if [ -f "$dest" ] || [ -f "${dest}.absent" ]; then
        return 0
    fi
    schema=$(_cinnamon_custom_schema "$slot")
    if val=$(_user_gsettings "$user" "$bus" get "$schema" binding 2>/dev/null); then
        _cinnamon_write_slot_backup "$user" "$bus" "$schema" "$dest" "$val" || return 1
        return 0
    fi
    _cinnamon_mark_absent "$dest"
}

_cinnamon_optional_slot_value() {
    _user_gsettings "$1" "$2" get "$3" "$4" 2>/dev/null || return 0
}

_cinnamon_write_slot_backup() {
    local user="$1" bus="$2" schema="$3" dest="$4" binding="$5"
    {
        printf 'binding=%s\n' "$binding"
        printf 'command=%s\n' "$(_cinnamon_optional_slot_value "$user" "$bus" "$schema" command)"
        printf 'name=%s\n' "$(_cinnamon_optional_slot_value "$user" "$bus" "$schema" name)"
    } > "${dest}.tmp" || {
        rm -f "${dest}.tmp"
        return 1
    }
    if ! mv "${dest}.tmp" "$dest"; then
        rm -f "${dest}.tmp"
        return 1
    fi
}

_cinnamon_backup_video_outputs() {
    local user="$1" bus="$2" config_dir="$3"
    if _gsettings_key_exists "$user" "$bus" \
        "org.cinnamon.desktop.keybindings.media-keys" "video-outputs"; then
        _cinnamon_backup_key "$user" "$bus" \
            "org.cinnamon.desktop.keybindings.media-keys" "video-outputs" \
            "$config_dir/orig_cinnamon_video_outputs" || return 1
    fi
}

_cinnamon_backup_table_row() {
    local user="$1" bus="$2" config_dir="$3" slot="$4" backup="$5"
    [ -n "$slot" ] || return 0
    _cinnamon_backup_slot "$user" "$bus" "$slot" "$config_dir/$backup"
}

_cinnamon_backup_all() {
    local user="$1" bus="$2" config_dir="$3"
    local slot binding name cmd backup
    _cinnamon_backup_key "$user" "$bus" \
        "org.cinnamon.desktop.keybindings" "custom-list" \
        "$config_dir/orig_cinnamon_custom_list" || return 1
    _cinnamon_backup_video_outputs "$user" "$bus" "$config_dir" || return 1
    while IFS='|' read -r slot binding name cmd backup; do
        _cinnamon_backup_table_row "$user" "$bus" "$config_dir" "$slot" "$backup" || return 1
    done < <(_cinnamon_shortcut_table)
}

_cinnamon_set_slot() {
    local user="$1" bus_addr="$2" slot="$3" binding="$4" name="$5" cmd="$6"
    local schema
    schema=$(_cinnamon_custom_schema "$slot")
    _user_gsettings "$user" "$bus_addr" set "$schema" name "$name" || return 1
    _user_gsettings "$user" "$bus_addr" set "$schema" command "$cmd" || return 1
    _user_gsettings "$user" "$bus_addr" set "$schema" binding "$binding" || return 1
}

_cinnamon_apply_bindings() {
    local user="$1" bus="$2"
    local bus_addr="unix:path=$bus" current merged
    local slot binding name cmd backup
    current=$(_cinnamon_current_custom_list "$user" "$bus_addr")
    merged=$(_merge_custom_keybindings "$current" \
        "asus-display-mode" "asus-control-center" "asus-screenshot")
    [ -n "$merged" ] || return 1
    _user_gsettings "$user" "$bus_addr" \
        set org.cinnamon.desktop.keybindings custom-list "$merged" || return 1
    while IFS='|' read -r slot binding name cmd backup; do
        _cinnamon_apply_table_row "$user" "$bus_addr" "$slot" "$binding" "$name" "$cmd" || return 1
    done < <(_cinnamon_shortcut_table)
    _cinnamon_clear_video_outputs "$user" "$bus" "$bus_addr"
    return 0
}

_cinnamon_current_custom_list() {
    _user_gsettings "$1" "$2" get org.cinnamon.desktop.keybindings custom-list 2>/dev/null \
        || echo "[]"
}

_cinnamon_apply_table_row() {
    local user="$1" bus_addr="$2" slot="$3" binding="$4" name="$5" cmd="$6"
    [ -n "$slot" ] || return 0
    _cinnamon_set_slot "$user" "$bus_addr" "$slot" "$binding" "$name" "$cmd"
}

_cinnamon_clear_video_outputs() {
    local user="$1" bus="$2" bus_addr="$3"
    if _gsettings_key_exists "$user" "$bus" \
        "org.cinnamon.desktop.keybindings.media-keys" "video-outputs"; then
        _asus_soft _user_gsettings "$user" "$bus_addr" \
            set org.cinnamon.desktop.keybindings.media-keys video-outputs "[]"
    fi
}

_cinnamon_restore_key_file() {
    local user="$1" bus="$2" schema="$3" key="$4" dest="$5" val
    [ -f "${dest}.absent" ] && return 0
    [ -f "$dest" ] || return 0
    val=$(cat "$dest" 2>/dev/null || true)
    [ -n "$val" ] || return 0
    _user_gsettings "$user" "$bus" set "$schema" "$key" "$val"
}

_cinnamon_restore_slot() {
    local user="$1" bus="$2" slot="$3" dest="$4" schema line key val
    schema=$(_cinnamon_custom_schema "$slot")
    if [ -f "${dest}.absent" ]; then
        _asus_soft _user_gsettings "$user" "$bus" reset-recursively "$schema"
        return 0
    fi
    [ -f "$dest" ] || return 0
    _cinnamon_restore_slot_file "$user" "$bus" "$schema" "$dest"
}

_cinnamon_restore_slot_file() {
    local user="$1" bus="$2" schema="$3" dest="$4" line key val
    while IFS= read -r line || [ -n "$line" ]; do
        key=${line%%=*}
        val=${line#*=}
        case "$key" in
            binding|command|name)
                _user_gsettings "$user" "$bus" set "$schema" "$key" "$val" || return 1
                ;;
        esac
    done < "$dest"
}

_cinnamon_clear_config_dir() {
    local config_dir="$1"
    if _is_safe_config_dir "$config_dir"; then
        rm -rf "$config_dir"
        return 0
    fi
    return 1
}

restore_cinnamon_shortcuts() {
    local user="$1" config_dir="$2" bus_path failed=0
    local slot binding name cmd backup user_id
    user_id=$(basename "$config_dir")
    bus_path="$(_install_resolve_session_bus_root)/$user_id/bus"
    while IFS='|' read -r slot binding name cmd backup; do
        _cinnamon_restore_table_row "$user" "$bus_path" "$config_dir" \
            "$slot" "$backup" || failed=1
    done < <(_cinnamon_shortcut_table)
    _cinnamon_restore_global_keys "$user" "$bus_path" "$config_dir" || failed=1
    _cinnamon_finish_restore "$config_dir" "$failed" || failed=1
    return "$failed"
}

_cinnamon_restore_global_keys() {
    local user="$1" bus_path="$2" config_dir="$3" failed=0
    _cinnamon_restore_key_file "$user" "$bus_path" \
        "org.cinnamon.desktop.keybindings" "custom-list" \
        "$config_dir/orig_cinnamon_custom_list" || failed=1
    _cinnamon_restore_key_file "$user" "$bus_path" \
        "org.cinnamon.desktop.keybindings.media-keys" "video-outputs" \
        "$config_dir/orig_cinnamon_video_outputs" || failed=1
    return "$failed"
}

_cinnamon_restore_table_row() {
    local user="$1" bus_path="$2" config_dir="$3" slot="$4" backup="$5"
    [ -n "$slot" ] || return 0
    _cinnamon_restore_slot "$user" "$bus_path" "$slot" "$config_dir/$backup"
}

_cinnamon_finish_restore() {
    local config_dir="$1" failed="$2"
    if [ "$failed" -eq 0 ]; then
        _cinnamon_clear_config_dir "$config_dir"
        return $?
    fi
    echo "Warning: failed to fully restore Cinnamon shortcuts; preserving backup directory." >&2
    return 1
}

_cinnamon_write_markers() {
    local config_dir="$1" target_user="$2"
    _cinnamon_write_state_file "$config_dir/desktop_family" "cinnamon" \
        "desktop_family" || return 1
    _cinnamon_write_state_file "$config_dir/target_user" "$target_user" \
        "target_user" || {
        rm -f "$config_dir/desktop_family" "$config_dir/target_user"
        return 1
    }
}

_set_cinnamon_keybindings() {
    local user="$1" bus="$2" config_dir="$3"
    _cinnamon_backup_all "$user" "$bus" "$config_dir" || return 1
    _cinnamon_apply_bindings "$user" "$bus"
}

_cinnamon_print_configure_progress() {
    _install_print_next_step "$(_asus_gettextf "Configuring Cinnamon shortcuts for %s..." "$1")"
}

configure_cinnamon_component() {
    local info target_user user_id bus_path config_dir
    info=$(_resolve_user_bus_info)
    if [ -z "$info" ]; then
        echo "  ✗ Cinnamon configuration failed: desktop D-Bus session not found." >&2
        return 1
    fi
    target_user=$(echo "$info" | cut -d: -f1)
    user_id=$(echo "$info" | cut -d: -f2)
    bus_path=$(echo "$info" | cut -d: -f3-)
    _cinnamon_print_configure_progress "$target_user"
    config_dir="${STATE_DIR}/${user_id}"
    _cinnamon_prepare_state "$config_dir" "$target_user" || return 1
    if _set_cinnamon_keybindings "$target_user" "$bus_path" "$config_dir"; then
        printf '  ✓ %s\n' "$(_asus_gettext "Cinnamon shortcuts configured.")"
        return 0
    fi
    if ! restore_cinnamon_shortcuts "$target_user" "$config_dir"; then
        echo "  ! Warning: Cinnamon backup state remains under $config_dir for manual recovery." >&2
    fi
    echo "  ✗ Cinnamon configuration failed: shortcut updates could not be applied." >&2
    return 1
}

_cinnamon_prepare_state() {
    local config_dir="$1" target_user="$2"
    if ! mkdir -p "$config_dir"; then
        echo "  ✗ Cinnamon configuration failed: could not create state directory." >&2
        return 1
    fi
    _cinnamon_write_markers "$config_dir" "$target_user"
}
