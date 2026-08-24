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
_LXQT_SECTIONS="$_LXQT_INSTALL_DIR/install-lxqt-sections.sh"
if [ ! -f "$_LXQT_SECTIONS" ]; then
    echo "Missing LXQt sections helper: $_LXQT_SECTIONS" >&2
    return 1
fi
# shellcheck source=lib/install-lxqt-sections.sh
. "$_LXQT_SECTIONS"

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

_lxqt_reject_symlink() {
    # Refuse to operate on a path that is, or resolves through, a symlink at
    # any parent component, since root must never chmod/chown/write through
    # a user-controlled link.
    local path="$1" prefix="" part
    IFS='/' read -ra _lxqt_path_parts <<< "$path"
    for part in "${_lxqt_path_parts[@]}"; do
        [ -n "$part" ] || continue
        prefix="$prefix/$part"
        [ -L "$prefix" ] && return 1
    done
    return 0
}

_lxqt_mkdir_chmod_0700() {
    # mkdir/chmod always dispatch through _install_run_as_user, which is a
    # same-user passthrough when already that user (non-root path) and a
    # privilege drop when running as root -- so this never mkdir/chmods
    # through a path as root. The symlink check itself is a pure read-only
    # lstat, harmless to run directly regardless of caller privilege; even a
    # race between the check and the dispatched mkdir/chmod can only ever
    # let the target user affect paths they already own, never escalate.
    local user="$1" path="$2"
    _lxqt_reject_symlink "$path" || return 1
    _install_run_as_user "$user" mkdir -p "$path" || return 1
    _install_run_as_user "$user" chmod 0700 "$path"
}

_lxqt_ensure_conf_dir() {
    local user="$1" home_dir
    home_dir=$(_lxqt_user_home "$user") || return 1
    _lxqt_mkdir_chmod_0700 "$user" "${home_dir}/.config" || return 1
    _lxqt_mkdir_chmod_0700 "$user" "${home_dir}/.config/lxqt"
}

_lxqt_atomic_write_conf_guard() {
    # restore_lxqt_shortcuts() calls _lxqt_atomic_write_conf directly (without
    # _lxqt_ensure_conf_dir), so every parent component of $conf must be
    # symlink-checked here too, not just the leaf.
    local conf="$1"
    _lxqt_reject_symlink "$conf" || return 1
    [ -e "$conf" ] && [ ! -f "$conf" ] && return 1
    return 0
}

_lxqt_write_tmp_and_swap() {
    local user="$1" tmp="$2" conf="$3" content_file="$4" st
    _install_run_as_user "$user" tee "$tmp" < "$content_file" > /dev/null
    st=$?
    [ "$st" -eq 0 ] || {
        _install_run_as_user "$user" rm -f "$tmp"
        return "$st"
    }
    _install_run_as_user "$user" mv -T "$tmp" "$conf"
    st=$?
    [ "$st" -eq 0 ] || _install_run_as_user "$user" rm -f "$tmp"
    return "$st"
}

_lxqt_atomic_write_conf() {
    # Written AS the target user (never as root): mktemp/write/mv all
    # dispatch through _install_run_as_user, so the actual mutation always
    # executes with the target user's own permissions.
    local user="$1" conf="$2" content_file="$3" tmp
    _lxqt_atomic_write_conf_guard "$conf" || return 1
    tmp="$(_install_run_as_user "$user" mktemp "${conf}.XXXXXX")" || return 1
    _lxqt_write_tmp_and_swap "$user" "$tmp" "$conf" "$content_file"
}

_lxqt_snapshot_fail_read() {
    local conf="$1" snap="$2" as_user="${3:-}"
    _lxqt_rm_tmp "$snap"
    if [ -n "$as_user" ]; then
        echo "  ✗ LXQt configuration failed: could not read $conf as $as_user." >&2
    else
        echo "  ✗ LXQt configuration failed: could not read $conf." >&2
    fi
    return 1
}

_lxqt_snapshot_read_into() {
    # Empty snapshot when conf is absent; fail closed when it exists but
    # cannot be read (do not treat timeouts/permission errors as "empty").
    local snap="$1" conf="$2"
    if cat "$conf" > "$snap" 2>/dev/null; then
        return 0
    fi
    if [ ! -e "$conf" ]; then
        : > "$snap"
        return 0
    fi
    _lxqt_snapshot_fail_read "$conf" "$snap"
}

_lxqt_snapshot_read_as_user() {
    local user="$1" snap="$2" conf="$3"
    if _install_run_as_user "$user" cat "$conf" > "$snap" 2>/dev/null; then
        return 0
    fi
    if ! _install_run_as_user "$user" test -e "$conf"; then
        : > "$snap"
        return 0
    fi
    _lxqt_snapshot_fail_read "$conf" "$snap" "$user"
}

_lxqt_snapshot_conf() {
    # Read $conf's content AS the target user (never as root) into a fresh
    # temp file. All section parsing/backup logic must read from this
    # snapshot, never from $conf directly while running as root: a
    # symlinked conf path read by root would let an attacker swap the
    # symlink for a regular file between that read and the later
    # privilege-dropped write, exfiltrating root-readable content into a
    # file the attacker controls (TOCTOU). Reading as the target user means
    # the read can only ever disclose what that user could already access.
    # Missing conf → empty snapshot; present-but-unreadable → fail closed.
    local user="$1" conf="$2" snap
    snap=$(mktemp) || return 1
    if [ "$(id -u)" -eq 0 ]; then
        _lxqt_snapshot_read_as_user "$user" "$snap" "$conf" || return 1
    else
        _lxqt_snapshot_read_into "$snap" "$conf" || return 1
    fi
    printf '%s\n' "$snap"
}

_lxqt_reload_globalkeys() {
    local user="$1"
    _install_run_as_user "$user" pkill -HUP lxqt-globalkeysd >/dev/null 2>&1 && return 0
    pkill -HUP -u "$user" lxqt-globalkeysd >/dev/null 2>&1 && return 0
    echo "  ! Warning: could not reload lxqt-globalkeysd;" \
        "re-login or restart Global Keys to apply shortcuts." >&2
    return 0
}

_lxqt_restore_absent() {
    local user="$1" conf="$2" section_id="$3" work snap st
    work=$(mktemp) || return 1
    snap=$(_lxqt_snapshot_conf "$user" "$conf") || {
        _lxqt_rm_tmp "$work"
        return 1
    }
    _lxqt_conf_without_section "$snap" "$section_id" > "$work"
    st=$?
    _lxqt_rm_tmp "$snap"
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
    local user="$1" conf="$2" section_id="$3" backup="$4" work original snap st
    original=$(cat "$backup" 2>/dev/null) || return 1
    work=$(mktemp) || return 1
    snap=$(_lxqt_snapshot_conf "$user" "$conf") || {
        _lxqt_rm_tmp "$work"
        return 1
    }
    {
        _lxqt_conf_without_section "$snap" "$section_id"
        printf '%s\n' "$original"
    } > "$work"
    st=$?
    _lxqt_rm_tmp "$snap"
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

_lxqt_print_configure_progress() {
    _install_print_next_step "$(_asus_gettextf "Configuring LXQt Global Keys for %s..." "$1")"
}

configure_lxqt_component() {
    local ctx target_user user_id conf config_dir
    ctx=$(_lxqt_resolve_configure_context) || return 1
    target_user=$(echo "$ctx" | cut -d'|' -f1)
    user_id=$(echo "$ctx" | cut -d'|' -f2)
    conf=$(echo "$ctx" | cut -d'|' -f3)
    _lxqt_print_configure_progress "$target_user"
    config_dir="${STATE_DIR}/${user_id}"
    _lxqt_prepare_configure_dirs "$target_user" "$conf" "$config_dir" || return 1
    _lxqt_write_markers "$config_dir" "$target_user" || return 1
    _lxqt_try_set_or_fail "$target_user" "$conf" "$config_dir" || return 1
    printf '  ✓ %s\n' "$(_asus_gettext "LXQt Global Keys configured.")"
}
