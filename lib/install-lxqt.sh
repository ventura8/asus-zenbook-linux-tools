#!/usr/bin/env bash
# LXQt Global Keys: edit ~/.config/lxqt/globalkeyshortcuts.conf (INI sections).

_LXQT_INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LXQT_COMMON="$_LXQT_INSTALL_DIR/install-lxqt-common.sh"
if [ ! -f "$_LXQT_COMMON" ]; then
    echo "Missing LXQt common helper: $_LXQT_COMMON" >&2
    return 1
fi
# shellcheck source=lib/install-lxqt-common.sh
. "$_LXQT_COMMON"

_lxqt_atomic_write_file() {
    local dest="$1" mode="$2" val="${3:-}" tmp st
    tmp="${dest}.tmp"
    if [ "$mode" = "value" ]; then
        printf '%s\n' "$val" > "$tmp"
    else
        : > "$tmp"
    fi
    st=$?
    [ "$st" -eq 0 ] || {
        _lxqt_rm_tmp "$tmp"
        return "$st"
    }
    mv "$tmp" "$dest"
    st=$?
    [ "$st" -eq 0 ] || _lxqt_rm_tmp "$tmp"
    return "$st"
}

_lxqt_write_state_file() {
    local dest="$1" value="$2" label="$3" st
    _lxqt_atomic_write_file "$dest" value "$value"
    st=$?
    [ "$st" -eq 0 ] || {
        echo "  ✗ LXQt configuration failed: could not write ${label} state." >&2
        return "$st"
    }
    return 0
}

_lxqt_write_backup_value() {
    _lxqt_atomic_write_file "$1" value "$2"
}

_lxqt_mark_backup_absent() {
    _lxqt_atomic_write_file "${1}.absent" absent
}

_lxqt_write_section_id() {
    _lxqt_atomic_write_file "${1}.section" value "$2"
}

_lxqt_chown_path() {
    local user="$1" path="$2"
    [ "$(id -u)" -eq 0 ] || return 0
    [ -e "$path" ] || return 0
    chown "$user:" "$path" 2>/dev/null || true
}

_lxqt_mkdir_chmod_0700() {
    local path="$1"
    mkdir -p "$path" || return 1
    chmod 0700 "$path"
}

_lxqt_ensure_conf_dir() {
    local user="$1" home_dir conf_dir
    home_dir=$(_lxqt_user_home "$user") || return 1
    mkdir -p "${home_dir}/.config" || return 1
    chmod 0700 "${home_dir}/.config" 2>/dev/null || true
    conf_dir="${home_dir}/.config/lxqt"
    _lxqt_mkdir_chmod_0700 "$conf_dir" || return 1
    _lxqt_chown_path "$user" "${home_dir}/.config"
    _lxqt_chown_path "$user" "$conf_dir"
}

_lxqt_atomic_write_conf() {
    local user="$1" conf="$2" content_file="$3" tmp st
    tmp="${conf}.tmp"
    cat "$content_file" > "$tmp"
    st=$?
    [ "$st" -eq 0 ] || {
        _lxqt_rm_tmp "$tmp"
        return "$st"
    }
    mv "$tmp" "$conf"
    st=$?
    [ "$st" -eq 0 ] || {
        _lxqt_rm_tmp "$tmp"
        return "$st"
    }
    _lxqt_chown_path "$user" "$conf"
}

_lxqt_hdr_from_line() {
    local line="$1" hdr
    hdr="${line#\[}"
    printf '%s\n' "${hdr%\]}"
}

_lxqt_section_id_matches_key() {
    local hdr="$1" key="$2" rest
    case "$hdr" in
        "${key}".*)
            rest="${hdr#"${key}".}"
            [[ "$rest" =~ ^[0-9]+$ ]]
            return $?
            ;;
        *)
            return 1
            ;;
    esac
}

_lxqt_find_section_for_key() {
    local conf="$1" key="$2" line hdr
    [ -f "$conf" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            \[*\])
                hdr=$(_lxqt_hdr_from_line "$line")
                _lxqt_section_id_matches_key "$hdr" "$key" || continue
                printf '%s\n' "$hdr"
                return 0
                ;;
        esac
    done < "$conf"
    return 1
}

_lxqt_bump_max_file() {
    local max_file="$1" id="$2" cur
    [[ "$id" =~ ^[0-9]+$ ]] || return 0
    cur=$(cat "$max_file" 2>/dev/null || echo 0)
    [ "$id" -gt "$cur" ] || return 0
    printf '%s\n' "$id" > "$max_file"
}

_lxqt_max_section_id() {
    local conf="$1" line hdr id max_file
    max_file=$(mktemp) || return 1
    printf '0\n' > "$max_file"
    if [ -f "$conf" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                \[*\])
                    hdr=$(_lxqt_hdr_from_line "$line")
                    id="${hdr##*.}"
                    _lxqt_bump_max_file "$max_file" "$id"
                    ;;
            esac
        done < "$conf"
    fi
    cat "$max_file"
    _lxqt_rm_tmp "$max_file"
}

_lxqt_extract_section() {
    local conf="$1" section_id="$2"
    [ -f "$conf" ] || return 1
    awk -v sid="$section_id" '
        BEGIN { found=0 }
        /^\[/ {
            h=$0; sub(/^\[/,"",h); sub(/\]$/,"",h)
            if (found) exit 0
            found=(h==sid)
        }
        found { print }
        END { if (!found) exit 1 }
    ' "$conf"
}

_lxqt_conf_without_section() {
    local conf="$1" section_id="$2"
    [ -f "$conf" ] || return 0
    awk -v sid="$section_id" '
        /^\[/ {
            h=$0; sub(/^\[/,"",h); sub(/\]$/,"",h)
            skip=(h==sid)
            if (!skip) print
            next
        }
        !skip { print }
    ' "$conf"
}

_lxqt_format_section() {
    local section_id="$1" comment="$2" exec_cmd="$3"
    printf '[%s]\nComment=%s\nEnabled=true\nExec=%s\n' \
        "$section_id" "$comment" "$exec_cmd"
}

_lxqt_backup_dest_ok() {
    local dest="$1"
    [ -f "$dest" ] && return 0
    [ -f "${dest}.absent" ]
}

_lxqt_require_one_backup() {
    local dest="$1" backup_name="$2"
    _lxqt_backup_dest_ok "$dest" || {
        echo "  ✗ LXQt configuration failed: backup missing for $backup_name." >&2
        return 1
    }
    [ -f "${dest}.section" ] || {
        echo "  ✗ LXQt configuration failed: section id missing for $backup_name." >&2
        return 1
    }
}

_lxqt_require_backup_files() {
    local config_dir="$1"
    local key backup_name comment exec_cmd
    while IFS='|' read -r key backup_name comment exec_cmd; do
        [ -n "$backup_name" ] || continue
        _lxqt_require_one_backup "$config_dir/$backup_name" "$backup_name" || return 1
    done < <(_lxqt_shortcut_table)
}

_lxqt_backup_existing_section() {
    local conf="$1" dest="$2" section_id="$3" original
    original=$(_lxqt_extract_section "$conf" "$section_id") || return 1
    _lxqt_write_backup_value "$dest" "$original" || return 1
    _lxqt_write_section_id "$dest" "$section_id"
}

_lxqt_backup_one() {
    local conf="$1" config_dir="$2" key="$3" backup_name="$4"
    local dest section_id
    dest="$config_dir/$backup_name"
    _lxqt_backup_dest_ok "$dest" && return 0
    section_id=$(_lxqt_find_section_for_key "$conf" "$key" || true)
    [ -n "$section_id" ] || {
        _lxqt_mark_backup_absent "$dest"
        return $?
    }
    _lxqt_backup_existing_section "$conf" "$dest" "$section_id"
}

_lxqt_backup_all() {
    local conf="$1" config_dir="$2"
    local key backup_name comment exec_cmd
    while IFS='|' read -r key backup_name comment exec_cmd; do
        [ -n "$key" ] || continue
        _lxqt_backup_one "$conf" "$config_dir" "$key" "$backup_name" || return 1
    done < <(_lxqt_shortcut_table)
}

_lxqt_section_numeric_id() {
    local section_id="$1" id
    id="${section_id##*.}"
    [[ "$id" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$id"
}

_lxqt_note_section_max_file() {
    local max_file="$1" section_id="$2" num
    num=$(_lxqt_section_numeric_id "$section_id" || true)
    [ -n "$num" ] || return 0
    _lxqt_bump_max_file "$max_file" "$num"
}

_lxqt_reuse_or_read_section_file() {
    local dest="$1" max_file="$2" section_id
    [ -f "${dest}.section" ] || return 1
    section_id=$(cat "${dest}.section" 2>/dev/null) || return 1
    _lxqt_note_section_max_file "$max_file" "$section_id"
}

_lxqt_choose_section_id() {
    local conf="$1" key="$2" max_file="$3" section_id cur
    section_id=$(_lxqt_find_section_for_key "$conf" "$key" || true)
    if [ -z "$section_id" ]; then
        cur=$(cat "$max_file")
        section_id="${key}.$((cur + 1))"
        printf '%s\n' "$((cur + 1))" > "$max_file"
        printf '%s\n' "$section_id"
        return 0
    fi
    _lxqt_note_section_max_file "$max_file" "$section_id"
    printf '%s\n' "$section_id"
}

_lxqt_assign_section_id() {
    local conf="$1" key="$2" dest="$3" max_file="$4" section_id
    _lxqt_reuse_or_read_section_file "$dest" "$max_file" && return 0
    section_id=$(_lxqt_choose_section_id "$conf" "$key" "$max_file") || return 1
    _lxqt_write_section_id "$dest" "$section_id"
}

_lxqt_assign_all_section_ids() {
    local conf="$1" config_dir="$2" max_file="$3"
    local key backup_name comment exec_cmd
    while IFS='|' read -r key backup_name comment exec_cmd; do
        [ -n "$key" ] || continue
        _lxqt_assign_section_id "$conf" "$key" "$config_dir/$backup_name" "$max_file" || return 1
    done < <(_lxqt_shortcut_table)
}

_lxqt_prepare_section_ids() {
    local conf="$1" config_dir="$2" max_file st
    max_file=$(mktemp) || return 1
    trap '_lxqt_rm_tmp "$max_file"' RETURN
    _lxqt_max_section_id "$conf" > "$max_file" || return 1
    _lxqt_assign_all_section_ids "$conf" "$config_dir" "$max_file"
    st=$?
    trap - RETURN
    _lxqt_rm_tmp "$max_file"
    return "$st"
}

_lxqt_append_blank_if_nonempty() {
    local path="$1"
    [ -s "$path" ] || return 0
    printf '\n'
}

_lxqt_apply_one_to_file() {
    local conf="$1" out="$2" section_id="$3" comment="$4" exec_cmd="$5"
    local tmp_body st
    tmp_body=$(mktemp) || return 1
    _lxqt_conf_without_section "$conf" "$section_id" > "$tmp_body"
    st=$?
    [ "$st" -eq 0 ] || {
        _lxqt_rm_tmp "$tmp_body"
        return "$st"
    }
    {
        cat "$tmp_body"
        _lxqt_append_blank_if_nonempty "$tmp_body"
        _lxqt_format_section "$section_id" "$comment" "$exec_cmd"
    } > "$out"
    st=$?
    _lxqt_rm_tmp "$tmp_body"
    return "$st"
}

_lxqt_read_section_id_file() {
    local dest="$1" section_id
    section_id=$(cat "${dest}.section" 2>/dev/null) || return 1
    [ -n "$section_id" ] || return 1
    printf '%s\n' "$section_id"
}

_lxqt_seed_work_file() {
    local conf="$1" work="$2"
    [ -f "$conf" ] || {
        : > "$work"
        return $?
    }
    cat "$conf" > "$work"
}

_lxqt_apply_row() {
    local work="$1" next="$2" dest="$3" comment="$4" exec_cmd="$5"
    local section_id
    section_id=$(_lxqt_read_section_id_file "$dest") || return 1
    _lxqt_apply_one_to_file "$work" "$next" "$section_id" "$comment" "$exec_cmd" || return 1
    mv "$next" "$work"
}

_lxqt_apply_table_to_work() {
    local work="$1" config_dir="$2" next_file="$3"
    local key backup_name comment exec_cmd next
    next=$(cat "$next_file")
    while IFS='|' read -r key backup_name comment exec_cmd; do
        [ -n "$key" ] || continue
        _lxqt_apply_row "$work" "$next" "$config_dir/$backup_name" \
            "$comment" "$exec_cmd" || return 1
        next=$(mktemp) || return 1
        printf '%s\n' "$next" > "$next_file"
    done < <(_lxqt_shortcut_table)
}

_lxqt_mktemp_or_fail() {
    mktemp || return 1
}

_lxqt_run_apply_with_temps() {
    local user="$1" conf="$2" config_dir="$3" work="$4" next_file="$5"
    trap '_lxqt_rm_tmp "$work" "$(cat "$next_file" 2>/dev/null)" "$next_file"' RETURN
    _lxqt_seed_work_file "$conf" "$work" || return 1
    _lxqt_apply_table_to_work "$work" "$config_dir" "$next_file" || return 1
    _lxqt_atomic_write_conf "$user" "$conf" "$work"
}

_lxqt_apply_all_bindings() {
    local user="$1" conf="$2" config_dir="$3" work next_file st
    work=$(_lxqt_mktemp_or_fail) || return 1
    next_file=$(_lxqt_mktemp_or_fail) || {
        _lxqt_rm_tmp "$work"
        return 1
    }
    _lxqt_mktemp_or_fail > "$next_file" || {
        _lxqt_rm_tmp "$work" "$next_file"
        return 1
    }
    _lxqt_run_apply_with_temps "$user" "$conf" "$config_dir" "$work" "$next_file"
    st=$?
    trap - RETURN
    _lxqt_rm_tmp "$work" "$(cat "$next_file" 2>/dev/null)" "$next_file"
    return "$st"
}

_lxqt_reload_globalkeys() {
    local user="$1"
    _install_run_as_user "$user" pkill -HUP lxqt-globalkeysd >/dev/null 2>&1 && return 0
    pkill -HUP -u "$user" lxqt-globalkeysd >/dev/null 2>&1 && return 0
    echo "  ! Warning: could not reload lxqt-globalkeysd;" \
        "re-login or restart Global Keys to apply shortcuts." >&2
    return 0
}

_set_lxqt_keybindings() {
    local user="$1" conf="$2" config_dir="$3"
    _lxqt_backup_all "$conf" "$config_dir" || return 1
    _lxqt_prepare_section_ids "$conf" "$config_dir" || return 1
    _lxqt_require_backup_files "$config_dir" || return 1
    _lxqt_apply_all_bindings "$user" "$conf" "$config_dir" || return 1
    _lxqt_reload_globalkeys "$user"
}

_lxqt_restore_absent() {
    local user="$1" conf="$2" section_id="$3" work st
    work=$(mktemp) || return 1
    _lxqt_conf_without_section "$conf" "$section_id" > "$work"
    st=$?
    [ "$st" -eq 0 ] || {
        _lxqt_rm_tmp "$work"
        return "$st"
    }
    _lxqt_atomic_write_conf "$user" "$conf" "$work"
    st=$?
    _lxqt_rm_tmp "$work"
    return "$st"
}

_lxqt_restore_backup_value() {
    local user="$1" conf="$2" section_id="$3" backup="$4" work original st
    original=$(cat "$backup" 2>/dev/null) || return 1
    work=$(mktemp) || return 1
    {
        _lxqt_conf_without_section "$conf" "$section_id"
        printf '%s\n' "$original"
    } > "$work"
    st=$?
    [ "$st" -eq 0 ] || {
        _lxqt_rm_tmp "$work"
        return "$st"
    }
    _lxqt_atomic_write_conf "$user" "$conf" "$work"
    st=$?
    _lxqt_rm_tmp "$work"
    return "$st"
}

_lxqt_restore_one() {
    local user="$1" conf="$2" backup="$3" section_id
    [ -f "${backup}.section" ] || {
        echo "  ! Warning: LXQt restore skipped: section id missing for $backup." >&2
        return 0
    }
    section_id=$(_lxqt_read_section_id_file "$backup") || return 1
    [ -f "${backup}.absent" ] && {
        _lxqt_restore_absent "$user" "$conf" "$section_id"
        return $?
    }
    [ -f "$backup" ] || {
        echo "  ! Warning: LXQt restore skipped for $section_id:" \
            "backup and .absent marker both missing." >&2
        return 0
    }
    _lxqt_restore_backup_value "$user" "$conf" "$section_id" "$backup"
}

_lxqt_clear_config_dir_if_safe() {
    local config_dir="$1"
    _is_safe_config_dir "$config_dir" || return 1
    rm -rf "$config_dir"
}

_lxqt_restore_all_rows() {
    local user="$1" conf="$2" config_dir="$3" failed=0
    local key backup_name comment exec_cmd
    while IFS='|' read -r key backup_name comment exec_cmd; do
        [ -n "$backup_name" ] || continue
        _lxqt_restore_one "$user" "$conf" "$config_dir/$backup_name" || failed=1
    done < <(_lxqt_shortcut_table)
    return "$failed"
}

restore_lxqt_shortcuts() {
    local user="$1" config_dir="$2" home_dir conf
    home_dir=$(_lxqt_user_home "$user") || {
        echo "Warning: failed to resolve HOME for LXQt restore." >&2
        return 1
    }
    conf=$(_lxqt_conf_path "$home_dir")
    _lxqt_restore_all_rows "$user" "$conf" "$config_dir" || {
        echo "Warning: failed to fully restore LXQt shortcuts; preserving backup directory." >&2
        return 1
    }
    _lxqt_reload_globalkeys "$user"
    _lxqt_clear_config_dir_if_safe "$config_dir"
}

_lxqt_fail_configure() {
    local target_user="$1" config_dir="$2"
    restore_lxqt_shortcuts "$target_user" "$config_dir" || \
        echo "  ! Warning: LXQt backup state remains under $config_dir for manual recovery." >&2
    echo "  ✗ LXQt configuration failed: shortcut updates could not be applied." >&2
    return 1
}

_lxqt_write_markers() {
    local config_dir="$1" target_user="$2"
    _lxqt_write_state_file "$config_dir/desktop_family" "lxqt" "desktop_family" || return 1
    _lxqt_write_state_file "$config_dir/target_user" "$target_user" "target_user" || {
        rm -f "$config_dir/desktop_family" "$config_dir/target_user"
        return 1
    }
}

_lxqt_conf_writable() {
    local conf="$1"
    [ -e "$conf" ] || return 0
    [ -w "$conf" ]
}

_lxqt_resolve_configure_context() {
    local info target_user user_id home_dir conf
    info=$(_resolve_user_bus_info)
    [ -n "$info" ] || {
        echo "  ✗ LXQt configuration failed: desktop D-Bus session not found." >&2
        return 1
    }
    target_user=$(echo "$info" | cut -d: -f1)
    user_id=$(echo "$info" | cut -d: -f2)
    home_dir=$(_lxqt_user_home "$target_user") || {
        echo "  ✗ LXQt configuration failed: could not resolve HOME for $target_user." >&2
        return 1
    }
    conf=$(_lxqt_conf_path "$home_dir")
    printf '%s|%s|%s\n' "$target_user" "$user_id" "$conf"
}

_lxqt_prepare_configure_dirs() {
    local target_user="$1" conf="$2" config_dir="$3"
    _lxqt_ensure_conf_dir "$target_user" || {
        echo "  ✗ LXQt configuration failed: could not create LXQt config directory." >&2
        return 1
    }
    _lxqt_conf_writable "$conf" || {
        echo "  ✗ LXQt configuration failed: conf not writable: $conf" >&2
        return 1
    }
    mkdir -p "$config_dir" || {
        echo "  ✗ LXQt configuration failed: could not create state directory." >&2
        return 1
    }
}

_lxqt_try_set_or_fail() {
    local target_user="$1" conf="$2" config_dir="$3"
    _set_lxqt_keybindings "$target_user" "$conf" "$config_dir" && return 0
    _lxqt_fail_configure "$target_user" "$config_dir"
}

configure_lxqt_component() {
    local ctx target_user user_id conf config_dir
    ctx=$(_lxqt_resolve_configure_context) || return 1
    target_user=$(echo "$ctx" | cut -d'|' -f1)
    user_id=$(echo "$ctx" | cut -d'|' -f2)
    conf=$(echo "$ctx" | cut -d'|' -f3)
    echo "[4/4] Configuring LXQt Global Keys for $target_user..."
    config_dir="${STATE_DIR}/${user_id}"
    _lxqt_prepare_configure_dirs "$target_user" "$conf" "$config_dir" || return 1
    _lxqt_write_markers "$config_dir" "$target_user" || return 1
    _lxqt_try_set_or_fail "$target_user" "$conf" "$config_dir" || return 1
    printf '  ✓ %s\n' "$(_asus_gettext "LXQt Global Keys configured.")"
}
