#!/usr/bin/env bash
# Shared labels and path primitives for the LXQt shortcut backend.

_lxqt_shortcut_table() {
    # key_chord|backup_basename|Comment|Exec
    # Comments use gettext when available; restore only needs key/backup columns.
    local display control screenshot
    display=$(_asus_ui_label "ASUS Display Mode")
    control=$(_asus_ui_label "ASUS ZenBook Settings")
    screenshot=$(_asus_ui_label "ASUS Screenshot")
    printf 'XF86Display|orig_lxqt_xf86display|%s|/usr/local/bin/asus-display-mode.sh\n' "$display"
    printf 'Meta%%2BP|orig_lxqt_meta_p|%s|/usr/local/bin/asus-display-mode.sh\n' "$display"
    printf 'Meta%%2BF12|orig_lxqt_meta_f12|%s|/usr/local/bin/asus-control-center.sh\n' "$control"
    printf 'Meta%%2BShift%%2BS|orig_lxqt_meta_shift_s|%s|/usr/local/bin/asus-screenshot.sh\n' "$screenshot"
}

_lxqt_user_home() {
    local user="$1" home_dir
    home_dir=$(getent passwd "$user" | cut -d: -f6 || true)
    [ -n "$home_dir" ] || return 1
    [ -d "$home_dir" ] || return 1
    printf '%s\n' "$home_dir"
}

_lxqt_conf_path() {
    printf '%s/.config/lxqt/globalkeyshortcuts.conf\n' "$1"
}

_lxqt_rm_tmp() {
    rm -f "$@"
}
