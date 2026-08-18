#!/usr/bin/env bash
# XFCE shortcut configuration for the DESKTOP install component.

_xfce_run_query() {
    local user="$1" bus_path="$2"
    shift 2
    local bus_addr runtime
    case "$bus_path" in
        unix:path=*)
            bus_addr="$bus_path"
            runtime=$(dirname "${bus_path#unix:path=}")
            ;;
        *)
            bus_addr="unix:path=$bus_path"
            runtime=$(dirname "$bus_path")
            ;;
    esac
    _install_run_as_user "$user" env DBUS_SESSION_BUS_ADDRESS="$bus_addr" XDG_RUNTIME_DIR="$runtime" \
        xfconf-query "$@" </dev/null
}

_xfce_write_backup_value() {
    local dest="$1" val="$2" tmp
    tmp="${dest}.tmp"
    if ! printf '%s\n' "$val" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv "$tmp" "$dest"; then
        rm -f "$tmp"
        return 1
    fi
}

_xfce_write_state_file() {
    local dest="$1" value="$2" label="$3" tmp
    tmp="${dest}.tmp"
    if ! printf '%s\n' "$value" > "$tmp"; then
        echo "  ✗ XFCE configuration failed: could not write ${label} state." >&2
        rm -f "$tmp"
        return 1
    fi
    if ! mv "$tmp" "$dest"; then
        echo "  ✗ XFCE configuration failed: could not finalize ${label} state." >&2
        rm -f "$tmp"
        return 1
    fi
    return 0
}

_xfce_mark_backup_absent() {
    local dest="$1" tmp
    tmp="${dest}.absent.tmp"
    if ! : > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv "$tmp" "${dest}.absent"; then
        rm -f "$tmp"
        return 1
    fi
}

# Shared table: xfconf path | backup basename | install command
_xfce_shortcut_table() {
    cat <<'EOF'
/commands/custom/XF86Display|orig_xfce_xf86display|/usr/local/bin/asus-display-mode.sh
/commands/custom/<Super>F12|orig_xfce_super_f12|/usr/local/bin/asus-control-center.sh
/commands/custom/<Super><Shift>s|orig_xfce_super_shift_s|/usr/local/bin/asus-screenshot.sh
EOF
}

_xfce_backup_value_or_absent() {
    local dest="$1" val="$2"
    if [ -n "$val" ]; then
        _xfce_write_backup_value "$dest" "$val"
    else
        _xfce_mark_backup_absent "$dest"
    fi
}

_xfce_backup_from_query() {
    local dest="$1" status="$2" val="$3"
    case "$status" in
        0)
            # Status 0 always records the queried value, including empty string.
            _xfce_write_backup_value "$dest" "$val" || return 1
            ;;
        1)
            _xfce_mark_backup_absent "$dest" || return 1
            ;;
        *)
            # Channel / D-Bus / other failures: skip so uninstall cannot reset wrongly.
            ;;
    esac
    return 0
}

_xfce_backup_binding() {
    local user="$1" bus_path="$2" path="$3" dest="$4" val status
    if [ -f "$dest" ] || [ -f "${dest}.absent" ]; then
        return 0
    fi
    # Probe xfconf before interpreting a per-path query (skip backup if channel unavailable).
    if ! _xfce_run_query "$user" "$bus_path" -c xfce4-keyboard-shortcuts -l >/dev/null 2>&1; then
        return 0
    fi
    status=0
    val=$(_xfce_run_query "$user" "$bus_path" -c xfce4-keyboard-shortcuts -p "$path" 2>/dev/null) || status=$?
    _xfce_backup_from_query "$dest" "$status" "$val"
}

_xfce_require_backup_files() {
    local config_dir="$1"
    local path backup_name command dest
    while IFS='|' read -r path backup_name command; do
        [ -n "$backup_name" ] || continue
        dest="$config_dir/$backup_name"
        if [ ! -f "$dest" ] && [ ! -f "${dest}.absent" ]; then
            echo "  ✗ XFCE configuration failed: backup missing for $backup_name." >&2
            return 1
        fi
    done < <(_xfce_shortcut_table)
    return 0
}

_xfce_set_command_binding() {
    local user="$1" bus_path="$2" path="$3" command="$4"
    if _xfce_run_query "$user" "$bus_path" -c xfce4-keyboard-shortcuts -p "$path" >/dev/null 2>&1; then
        _xfce_run_query "$user" "$bus_path" -c xfce4-keyboard-shortcuts -p "$path" -s "$command" \
            || return 1
        return 0
    fi
    _xfce_run_query "$user" "$bus_path" -c xfce4-keyboard-shortcuts -p "$path" -n -t string \
        -s "$command" || return 1
}

_xfce_backup_marker() {
    local config_dir="$1"
    _xfce_write_state_file "$config_dir/desktop_family" "xfce" "desktop_family"
}

_xfce_backup_all_bindings() {
    local user="$1" bus_path="$2" config_dir="$3"
    local path backup_name command
    while IFS='|' read -r path backup_name command; do
        [ -n "$path" ] || continue
        _xfce_backup_binding "$user" "$bus_path" "$path" "$config_dir/$backup_name"
    done < <(_xfce_shortcut_table)
}

_xfce_apply_all_bindings() {
    local user="$1" bus_path="$2"
    local path backup_name command
    while IFS='|' read -r path backup_name command; do
        [ -n "$path" ] || continue
        _xfce_set_command_binding "$user" "$bus_path" "$path" "$command" || return 1
    done < <(_xfce_shortcut_table)
    return 0
}

_set_xfce_keybindings() {
    local user="$1" bus_path="$2" config_dir="$3"
    _xfce_backup_all_bindings "$user" "$bus_path" "$config_dir"
    _xfce_require_backup_files "$config_dir" || return 1
    _xfce_apply_all_bindings "$user" "$bus_path" || return 1
    return 0
}

_xfce_print_configure_progress() {
    _install_print_next_step "$(_asus_gettextf "Configuring XFCE shortcuts for %s..." "$1")"
}

configure_xfce_component() {
    local info target_user user_id bus_path config_dir
    info=$(_resolve_user_bus_info)
    _xfce_component_precheck "$info" || return 1
    target_user=$(echo "$info" | cut -d: -f1)
    user_id=$(echo "$info" | cut -d: -f2)
    bus_path=$(echo "$info" | cut -d: -f3-)
    _xfce_print_configure_progress "$target_user"
    config_dir="${STATE_DIR}/${user_id}"
    _xfce_prepare_component_state "$config_dir" "$target_user" "$bus_path" || return 1

    if _set_xfce_keybindings "$target_user" "$bus_path" "$config_dir"; then
        printf '  ✓ %s\n' "$(_asus_gettext "XFCE shortcuts configured.")"
        return 0
    fi
    if ! restore_xfce_shortcuts "$target_user" "$config_dir"; then
        echo "  ! Warning: XFCE backup state remains under $config_dir for manual recovery." >&2
    fi
    echo "  ✗ XFCE configuration failed: shortcut updates could not be applied." >&2
    return 1
}

_xfce_component_precheck() {
    local info="$1"
    if [ -z "$info" ]; then
        echo "  ✗ XFCE configuration failed: desktop D-Bus session not found." >&2
        return 1
    fi
    if ! command -v xfconf-query >/dev/null 2>&1; then
        echo "  ✗ XFCE configuration failed: xfconf-query not found." >&2
        return 1
    fi
}

_xfce_prepare_component_state() {
    local config_dir="$1" target_user="$2" bus_path="$3"
    if ! mkdir -p "$config_dir"; then
        echo "  ✗ XFCE configuration failed: could not create state directory." >&2
        return 1
    fi
    if ! _xfce_backup_marker "$config_dir"; then
        return 1
    fi
    if ! _xfce_write_state_file "$config_dir/target_user" "$target_user" "target_user"; then
        return 1
    fi
    if ! _xfce_write_state_file "$config_dir/xfce_bus_path" "$bus_path" "session bus path"; then
        return 1
    fi
}

_xfce_restore_absent() {
    local user="$1" bus_path="$2" path="$3"
    _xfce_run_query "$user" "$bus_path" -c xfce4-keyboard-shortcuts -p "$path" -r \
        >/dev/null 2>&1
}

_xfce_restore_value() {
    local user="$1" bus_path="$2" path="$3" val="$4"
    _xfce_run_query "$user" "$bus_path" -c xfce4-keyboard-shortcuts -p "$path" -s "$val" \
        >/dev/null 2>&1
}

_xfce_restore_one() {
    local user="$1" bus_path="$2" path="$3" backup="$4" val
    if [ -f "${backup}.absent" ]; then
        _xfce_restore_absent "$user" "$bus_path" "$path"
        return $?
    fi
    if [ ! -f "$backup" ]; then
        echo "  ! Warning: XFCE restore skipped for $path: backup and .absent marker both missing." >&2
        return 0
    fi
    val=$(cat "$backup" 2>/dev/null)
    _xfce_restore_value "$user" "$bus_path" "$path" "$val"
}

_xfce_resolve_restore_bus() {
    local config_dir="$1" bus_path user_id
    if [ -f "$config_dir/xfce_bus_path" ]; then
        bus_path=$(cat "$config_dir/xfce_bus_path" 2>/dev/null || true)
        [ -n "$bus_path" ] && { printf '%s\n' "$bus_path"; return 0; }
    fi
    user_id=$(basename "$config_dir")
    printf '%s/%s/bus\n' "$(_install_resolve_session_bus_root)" "$user_id"
}

restore_xfce_shortcuts() {
    local user="$1" config_dir="$2" bus_path failed=0
    local path backup_name command
    bus_path=$(_xfce_resolve_restore_bus "$config_dir")
    while IFS='|' read -r path backup_name command; do
        [ -n "$path" ] || continue
        _xfce_restore_one "$user" "$bus_path" "$path" \
            "$config_dir/$backup_name" || failed=1
    done < <(_xfce_shortcut_table)
    _xfce_finish_restore "$config_dir" "$failed" || failed=1
    return "$failed"
}

_xfce_finish_restore() {
    local config_dir="$1" failed="$2"
    if [ "$failed" -ne 0 ]; then
        echo "Warning: failed to fully restore XFCE shortcuts; preserving backup directory." >&2
        return 1
    fi
    _is_safe_config_dir "$config_dir" || return 1
    rm -rf "$config_dir"
}
