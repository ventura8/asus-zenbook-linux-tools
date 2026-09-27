#!/usr/bin/env bash
# asus-uinput group + udev rule helpers for install-components.sh (ydotool /
# /dev/uinput access). Sourced by _source_install_component_uinput_helpers.

_uinput_group_users_record_path() {
    printf '%s/asus-uinput-group-users\n' "${STATE_DIR:?}"
    return $?
}

_legacy_input_group_users_record_path() {
    printf '%s/input-group-users\n' "${STATE_DIR:?}"
    return $?
}

_record_uinput_group_user() {
    local target_user="$1" record
    [[ -n "$target_user" ]] || return 0
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
        [[ "$token" = "$group_name" ]] && return 0
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
    if [[ "$revoke_failed" -eq 0 ]]; then
        rm -f "$record"
    fi
    return "$revoke_failed"
}

_uinput_revoke_record_ready() {
    local record="$1" group_name="$2"
    [[ -f "$record" ]] || return 1
    if ! getent group "$group_name" >/dev/null 2>&1; then
        rm -f "$record"
        return 1
    fi
}

_revoke_one_uinput_group_member() {
    local target_user="$1" group_name="$2"
    [[ -n "$target_user" ]] || return 0
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
    return $?
}

_resolve_uinput_rule_source() {
    local src_dir="$1" repo_root
    src_dir="${src_dir:-${INSTALL_SOURCE_DIR:-}}"
    if [[ -z "$src_dir" ]]; then
        repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        src_dir="$repo_root"
    fi
    printf '%s/udev/99-asus-uinput.rules\n' "$src_dir"
    return $?
}

_ensure_uinput_group() {
    _asus_is_staged_install && return 0
    if ! getent group asus-uinput >/dev/null 2>&1 \
        && ! groupadd -r asus-uinput 2>/dev/null; then
        echo "  ! Warning: could not create group asus-uinput." >&2
        return 0
    fi
}

_reload_uinput_udev_rule() {
    if ! _asus_is_staged_install && command -v udevadm >/dev/null 2>&1; then
        _asus_soft udevadm control --reload-rules
        _asus_soft udevadm trigger --subsystem-match=misc --name-match=uinput
    fi
    return $?
}

_install_uinput_udev_rule() {
    local rule_src rule_dest
    rule_src=$(_resolve_uinput_rule_source "${1:-}")
    if [[ ! -f "$rule_src" ]]; then
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
    [[ -n "$target_user" ]] || return 0
    _asus_is_staged_install && return 0
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
