#!/bin/bash
# Triggers Desktop Control Center / Settings for the active session user

_source_bootstrap_helper() {
    local script_dir installed_lib
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ "${ASUS_FORCE_INSTALLED_LIB:-0}" != "1" ] \
        && [ -f "$script_dir/../lib/asus-bootstrap.sh" ]; then
        . "$script_dir/../lib/asus-bootstrap.sh"
        return 0
    fi
    installed_lib="${ASUS_INSTALLED_LIB_DIR:-/usr/local/lib/asus-zenbook-linux-tools}"
    if [ -f "$installed_lib/asus-bootstrap.sh" ]; then
        . "$installed_lib/asus-bootstrap.sh"
        return 0
    fi
    echo "Error: Missing lib/asus-bootstrap.sh" >&2
    return 1
}

_source_bootstrap_helper || exit 1
_source_common_helper || exit 1

get_dbus_bus_path() {
    local target_user="$1" user_id bus_root bus_path
    user_id=$(id -u "$target_user" 2>/dev/null)
    if [ -z "$user_id" ]; then
        echo "Error: Unable to resolve user id for active user '$target_user'." >&2
        return 1
    fi

    bus_root="${RUN_USER_ROOT:-/run/user}"
    bus_path="$bus_root/$user_id/bus"
    if [ -S "$bus_path" ]; then
        echo "$bus_path"
        return 0
    fi

    echo "Error: D-Bus session socket not found for user '$target_user' at $bus_path." >&2
    return 1
}

_cc_user_env() {
    _asus_session_launch_env "$@"
}

_try_launch_cmd() {
    local cmd target_user target_uid runtime_root bus_addr launch_pid
    local -a env_args
    # Nameref target must not match a local here (callers pass `pid`).
    local -n _out_launch_pid="$6"
    cmd="$1" target_user="$2" target_uid="$3" runtime_root="$4" bus_addr="$5"
    _out_launch_pid=""
    _cc_user_env env_args "$target_user" "$target_uid" "$runtime_root" "$bus_addr"
    _run_as_user "$target_user" env "${env_args[@]}" \
        sh -c "command -v \"\$1\" >/dev/null 2>&1" sh "$cmd" || return 1
    launch_pid=$(_run_as_user "$target_user" env "${env_args[@]}" \
        sh -c "exec \"\$1\" </dev/null >/dev/null 2>&1 & echo \$!" sh "$cmd") || return 1
    _out_launch_pid="$launch_pid"
    return 0
}

_launch_via_desktop_file() {
    local file target_user target_uid runtime_root bus_addr launch_status
    local -a env_args
    file="$1" target_user="$2" target_uid="$3" runtime_root="$4" bus_addr="$5"
    _cc_user_env env_args "$target_user" "$target_uid" "$runtime_root" "$bus_addr"
    launch_status=0
    _run_as_user "$target_user" env "${env_args[@]}" \
        gio launch "$file" </dev/null >/dev/null 2>&1 || launch_status=$?
    if [ "$launch_status" -eq 0 ]; then
        return 0
    fi
    echo "Error: gio launch failed for $file (exit $launch_status)." >&2
    return 1
}

declare -A _SETTINGS_CMDS_BY_FAMILY
_SETTINGS_CMDS_BY_FAMILY[kde]="systemsettings systemsettings5 gnome-control-center xfce4-settings-manager"
_SETTINGS_CMDS_BY_FAMILY[xfce]="xfce4-settings-manager gnome-control-center systemsettings"
_SETTINGS_CMDS_BY_FAMILY[lxqt]="lxqt-config gnome-control-center systemsettings xfce4-settings-manager"
_SETTINGS_CMDS_BY_FAMILY[cinnamon]="cinnamon-settings gnome-control-center systemsettings"
_SETTINGS_CMDS_BY_FAMILY[mate]="mate-control-center gnome-control-center systemsettings"
_SETTINGS_CMDS_BY_FAMILY[gnome]="gnome-control-center systemsettings xfce4-settings-manager"
_DEFAULT_SETTINGS_CMDS="gnome-control-center systemsettings xfce4-settings-manager lxqt-config cinnamon-settings mate-control-center"

_settings_cmds_for_family() {
    local family="$1" commands
    local -a command_array
    commands="${_SETTINGS_CMDS_BY_FAMILY[$family]-$_DEFAULT_SETTINGS_CMDS}"
    read -r -a command_array <<<"$commands"
    printf '%s\n' "${command_array[@]}"
}

_try_one_settings_cmd() {
    local cmd="$1" target_user="$2" target_uid="$3" runtime_root="$4" bus_addr="$5" pid
    _try_launch_cmd "$cmd" "$target_user" "$target_uid" "$runtime_root" "$bus_addr" pid || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    _check_launch_process "$pid" "$cmd"
}

_try_launch_cmd_from_list() {
    local target_user target_uid runtime_root bus_addr family cmd
    target_user="$1" target_uid="$2" runtime_root="$3" bus_addr="$4" family="$5"
    while read -r cmd; do
        [ -n "$cmd" ] || continue
        _try_one_settings_cmd "$cmd" "$target_user" "$target_uid" "$runtime_root" "$bus_addr" || continue
        return 0
    done < <(_settings_cmds_for_family "$family")
    return 1
}

_first_existing_desktop() {
    local candidate
    for candidate in "$@"; do
        [ -f "$candidate" ] || continue
        echo "$candidate"
        return 0
    done
    return 1
}

declare -A _DESKTOP_FILES_BY_FAMILY
_DESKTOP_FILES_BY_FAMILY[kde]="systemsettings.desktop org.kde.systemsettings.desktop"
_DESKTOP_FILES_BY_FAMILY[xfce]="xfce4-settings-manager.desktop"
_DESKTOP_FILES_BY_FAMILY[lxqt]="lxqt-config.desktop org.lxqt.lxqt-config.desktop"
_DESKTOP_FILES_BY_FAMILY[cinnamon]="cinnamon-settings.desktop"
_DESKTOP_FILES_BY_FAMILY[mate]="mate-control-center.desktop matecc.desktop"

_desktop_file_for_family() {
    local family="$1" root suffixes suffix
    local -a candidates=()
    root="${DESKTOP_DIR:-/usr/share/applications}"
    suffixes="${_DESKTOP_FILES_BY_FAMILY[$family]-}"
    for suffix in $suffixes; do
        candidates+=("$root/$suffix")
    done
    if [ "${#candidates[@]}" -gt 0 ]; then
        _first_existing_desktop "${candidates[@]}" && return 0
    fi
    _first_existing_desktop "$root/org.gnome.Settings.desktop"
}

_launch_settings_app() {
    local target_user="$1" bus_addr="$2" family="$3"
    local file target_uid runtime_root
    target_uid=$(id -u "$target_user" 2>/dev/null) || return 1
    runtime_root="${RUN_USER_ROOT:-/run/user}"
    _try_launch_cmd_from_list "$target_user" "$target_uid" "$runtime_root" "$bus_addr" "$family" && return 0
    file=$(_desktop_file_for_family "$family") || return 1
    _launch_via_desktop_file "$file" "$target_user" "$target_uid" "$runtime_root" "$bus_addr"
}

_try_gnome_settings_activate() {
    local target_user="$1" bus_addr="$2" target_uid runtime_root
    local -a env_args
    target_uid=$(id -u "$target_user" 2>/dev/null) || return 1
    runtime_root="${RUN_USER_ROOT:-/run/user}"
    _cc_user_env env_args "$target_user" "$target_uid" "$runtime_root" "$bus_addr"
    _run_as_user "$target_user" env "${env_args[@]}" \
        gdbus call --session --dest org.gnome.Settings --object-path /org/gnome/Settings \
        --method org.freedesktop.Application.Activate "{}" >/dev/null 2>&1
}

launch_control_center() {
    local target_user="$1" bus_path="$2"
    local bus_addr="unix:path=$bus_path" family target_uid runtime_root
    family=$(asus_desktop_family "$target_user")
    target_uid=$(id -u "$target_user" 2>/dev/null) || return 1
    runtime_root="${RUN_USER_ROOT:-/run/user}"
    # Ubuntu GNOME reports ubuntu:GNOME; when env lookup fails family is other —
    # still try Settings Activate before binary launch.
    case "$family" in
        kde|xfce|lxqt|cinnamon|mate) ;;
        *) _try_gnome_settings_activate "$target_user" "$bus_addr" && return 0 ;;
    esac
    _launch_settings_app "$target_user" "$bus_addr" "$family"
}

main() {
    local target_user bus_path
    if [ -n "${1:-}" ]; then
        echo "Usage: ${0##*/}" >&2
        return 2
    fi
    target_user=$(find_active_session_user)
    if [ -n "$target_user" ]; then
        if bus_path=$(get_dbus_bus_path "$target_user"); then
            launch_control_center "$target_user" "$bus_path"
            return $?
        fi
    else
        echo "Error: No active graphical session found." >&2
    fi
    return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
