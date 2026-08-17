#!/usr/bin/env bash
# MATE relocatable custom keybindings for the DESKTOP install component.

# slot|binding|name|action|backup_basename
_mate_shortcut_table() {
    local display control screenshot
    display=$(_asus_ui_label "ASUS Display Mode")
    control=$(_asus_ui_label "ASUS ZenBook Settings")
    screenshot=$(_asus_ui_label "ASUS Screenshot")
    printf 'asus-display-mode|XF86Display|%s|/usr/local/bin/asus-display-mode.sh|orig_mate_xf86display\n' \
        "$display"
    printf 'asus-control-center|<Super>F12|%s|/usr/local/bin/asus-control-center.sh|orig_mate_super_f12\n' \
        "$control"
    printf 'asus-screenshot|<Super><Shift>s|%s|/usr/local/bin/asus-screenshot.sh|orig_mate_super_shift_s\n' \
        "$screenshot"
}

_mate_custom_schema() {
    local slot="$1"
    printf '%s\n' \
        "org.mate.control-center.keybinding:/org/mate/desktop/keybindings/${slot}/"
}

_mate_atomic_write() {
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

_mate_write_state_file() {
    local dest="$1" value="$2" label="$3"
    if ! _mate_atomic_write "$dest" "$value"; then
        echo "  ✗ MATE configuration failed: could not write ${label} state." >&2
        return 1
    fi
}

_mate_mark_absent() {
    local dest="$1"
    _mate_atomic_write "${dest}.absent" ""
}

_mate_backup_slot() {
    local user="$1" bus="$2" slot="$3" dest="$4" schema val
    if [ -f "$dest" ] || [ -f "${dest}.absent" ]; then
        return 0
    fi
    schema=$(_mate_custom_schema "$slot")
    if val=$(_user_gsettings "$user" "$bus" get "$schema" binding 2>/dev/null); then
        _mate_write_slot_backup "$user" "$bus" "$schema" "$dest" "$val" || return 1
        return 0
    fi
    _mate_mark_absent "$dest"
}

_mate_optional_slot_value() {
    _user_gsettings "$1" "$2" get "$3" "$4" 2>/dev/null || return 0
}

_mate_write_slot_backup() {
    local user="$1" bus="$2" schema="$3" dest="$4" binding="$5"
    {
        printf 'binding=%s\n' "$binding"
        printf 'action=%s\n' "$(_mate_optional_slot_value "$user" "$bus" "$schema" action)"
        printf 'name=%s\n' "$(_mate_optional_slot_value "$user" "$bus" "$schema" name)"
    } > "${dest}.tmp" || {
        rm -f "${dest}.tmp"
        return 1
    }
    if ! mv "${dest}.tmp" "$dest"; then
        rm -f "${dest}.tmp"
        return 1
    fi
}

_mate_backup_all() {
    local user="$1" bus="$2" config_dir="$3"
    local slot binding name action backup
    while IFS='|' read -r slot binding name action backup; do
        [ -n "$slot" ] || continue
        _mate_backup_slot "$user" "$bus" "$slot" "$config_dir/$backup" || return 1
    done < <(_mate_shortcut_table)
}

_mate_set_slot() {
    local user="$1" bus_addr="$2" slot="$3" binding="$4" name="$5" action="$6"
    local schema
    schema=$(_mate_custom_schema "$slot")
    _user_gsettings "$user" "$bus_addr" set "$schema" name "$name" || return 1
    _user_gsettings "$user" "$bus_addr" set "$schema" action "$action" || return 1
    _user_gsettings "$user" "$bus_addr" set "$schema" binding "$binding" || return 1
}

_mate_apply_bindings() {
    local user="$1" bus="$2"
    local bus_addr="unix:path=$bus"
    local slot binding name action backup
    while IFS='|' read -r slot binding name action backup; do
        [ -n "$slot" ] || continue
        _mate_set_slot "$user" "$bus_addr" "$slot" "$binding" "$name" "$action" \
            || return 1
    done < <(_mate_shortcut_table)
    return 0
}

_mate_restore_slot() {
    local user="$1" bus="$2" slot="$3" dest="$4" schema line key val
    schema=$(_mate_custom_schema "$slot")
    if [ -f "${dest}.absent" ]; then
        _asus_soft _user_gsettings "$user" "$bus" reset-recursively "$schema"
        return 0
    fi
    [ -f "$dest" ] || return 0
    _mate_restore_slot_file "$user" "$bus" "$schema" "$dest"
}

_mate_restore_slot_file() {
    local user="$1" bus="$2" schema="$3" dest="$4" line key val
    while IFS= read -r line || [ -n "$line" ]; do
        key=${line%%=*}
        val=${line#*=}
        case "$key" in
            binding|action|name)
                _user_gsettings "$user" "$bus" set "$schema" "$key" "$val" || return 1
                ;;
        esac
    done < "$dest"
}

_mate_clear_config_dir() {
    local config_dir="$1"
    if _is_safe_config_dir "$config_dir"; then
        rm -rf "$config_dir"
        return 0
    fi
    return 1
}

restore_mate_shortcuts() {
    local user="$1" config_dir="$2" bus_path failed=0
    local slot binding name action backup user_id
    user_id=$(basename "$config_dir")
    bus_path="$(_install_resolve_session_bus_root)/$user_id/bus"
    while IFS='|' read -r slot binding name action backup; do
        _mate_restore_table_row "$user" "$bus_path" "$config_dir" \
            "$slot" "$backup" || failed=1
    done < <(_mate_shortcut_table)
    _mate_finish_restore "$config_dir" "$failed" || failed=1
    return "$failed"
}

_mate_restore_table_row() {
    local user="$1" bus_path="$2" config_dir="$3" slot="$4" backup="$5"
    [ -n "$slot" ] || return 0
    _mate_restore_slot "$user" "$bus_path" "$slot" "$config_dir/$backup"
}

_mate_finish_restore() {
    local config_dir="$1" failed="$2"
    if [ "$failed" -eq 0 ]; then
        _mate_clear_config_dir "$config_dir"
        return $?
    fi
    echo "Warning: failed to fully restore MATE shortcuts; preserving backup directory." >&2
    return 1
}

_mate_write_markers() {
    local config_dir="$1" target_user="$2"
    _mate_write_state_file "$config_dir/desktop_family" "mate" "desktop_family" \
        || return 1
    _mate_write_state_file "$config_dir/target_user" "$target_user" "target_user" || {
        rm -f "$config_dir/desktop_family" "$config_dir/target_user"
        return 1
    }
}

_set_mate_keybindings() {
    local user="$1" bus="$2" config_dir="$3"
    _mate_backup_all "$user" "$bus" "$config_dir" || return 1
    _mate_apply_bindings "$user" "$bus"
}

_mate_print_configure_progress() {
    _install_print_next_step "$(_asus_gettextf "Configuring MATE shortcuts for %s..." "$1")"
}

configure_mate_component() {
    local info target_user user_id bus_path config_dir
    info=$(_resolve_user_bus_info)
    if [ -z "$info" ]; then
        echo "  ✗ MATE configuration failed: desktop D-Bus session not found." >&2
        return 1
    fi
    target_user=$(echo "$info" | cut -d: -f1)
    user_id=$(echo "$info" | cut -d: -f2)
    bus_path=$(echo "$info" | cut -d: -f3-)
    _mate_print_configure_progress "$target_user"
    config_dir="${STATE_DIR}/${user_id}"
    _mate_prepare_state "$config_dir" "$target_user" || return 1
    if _set_mate_keybindings "$target_user" "$bus_path" "$config_dir"; then
        printf '  ✓ %s\n' "$(_asus_gettext "MATE shortcuts configured.")"
        return 0
    fi
    if ! restore_mate_shortcuts "$target_user" "$config_dir"; then
        echo "  ! Warning: MATE backup state remains under $config_dir for manual recovery." >&2
    fi
    echo "  ✗ MATE configuration failed: shortcut updates could not be applied." >&2
    return 1
}

_mate_prepare_state() {
    local config_dir="$1" target_user="$2"
    if ! mkdir -p "$config_dir"; then
        echo "  ✗ MATE configuration failed: could not create state directory." >&2
        return 1
    fi
    _mate_write_markers "$config_dir" "$target_user"
}
