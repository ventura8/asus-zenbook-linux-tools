#!/usr/bin/env bash

# Source-only library: executing this file as a script must not pull in peers.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "Usage: . lib/asus-common.sh" >&2
    exit 1
fi

# Override for kcov missing-peer scenarios (empty/partial tmp tree).
_ASUS_COMMON_DIR="${ASUS_COMMON_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

_source_required_common_peer() {
    local file_name="$1" label="$2"
    if [ ! -f "$_ASUS_COMMON_DIR/$file_name" ]; then
        echo "Error: Missing $label helper lib/$file_name" >&2
        return 1
    fi
    # shellcheck source=/dev/null
    . "$_ASUS_COMMON_DIR/$file_name" || return 1
}

_source_common_peers() {
    _source_required_common_peer asus-session.sh session || return 1
    _source_required_common_peer asus-notif-icons.sh "notification icon" || return 1
    _source_required_common_peer asus-i18n.sh i18n || return 1
}

_source_common_peers || return 1

RUN_USER_ROOT="${RUN_USER_ROOT:-/run/user}"

_resolve_session_bus_root() {
    if [ -n "${BUS_ROOT:-}" ]; then
        printf '%s\n' "$BUS_ROOT"
        return 0
    fi
    if [ -n "${DBUS_BUS_ROOT:-}" ]; then
        printf '%s\n' "$DBUS_BUS_ROOT"
        return 0
    fi
    printf '%s\n' "${RUN_USER_ROOT:-/run/user}"
}

# ProtectHome=read-only makes /run/user read-only for systemd services, so
# replace-IDs must live outside it (see RuntimeDirectory=asus-zenbook-notif).
NOTIF_ID_ROOT="${NOTIF_ID_ROOT:-/run/asus-zenbook-notif}"

_soft() {
    # set -e safe ignore for best-effort side effects (counts once toward CCN).
    "$@" || return 0
}

_soft_write_stdout() {
    # Redirect inside the helper so redirect failures stay soft under set -e.
    local dest="$1"
    shift
    "$@" >"$dest" 2>/dev/null || return 0
}

_check_node() {
    local node="$1"
    [ -w "$node" ] && echo "$node" && return 0
    return 1
}

_notif_user_from_bus_entry() {
    local entry="$1" uid bus owner
    [ -d "$entry" ] || return 1
    uid=$(basename "$entry")
    case "$uid" in
        *[!0-9]*) return 1 ;;
    esac
    bus="$entry/bus"
    [ -S "$bus" ] || return 1
    owner=$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)
    [ -n "$owner" ] || return 1
    printf '%s\n' "$owner"
}

_first_notif_bus_user() {
    local entry owner
    for entry in "$(_resolve_session_bus_root)"/*; do
        if owner=$(_notif_user_from_bus_entry "$entry"); then
            printf '%s\n' "$owner"
            return 0
        fi
    done
    return 1
}

_resolve_notif_target_user() {
    local user candidate=""
    if ! user=$(find_active_session_user); then
        user=""
    fi
    if [ -n "$user" ]; then
        echo "$user"
        return 0
    fi
    candidate=$(_first_notif_bus_user) || candidate=""
    if [ -n "$candidate" ]; then
        echo "$candidate"
    fi
    return 0
}

_is_valid_notification_tag() {
    local tag="$1"
    [[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]]
}

_notif_id_file_path() {
    local user_id="$1" id_suffix="$2"
    _is_valid_notification_tag "$id_suffix" || return 1
    printf '%s/%s/.asus_notif_%s.id' "$NOTIF_ID_ROOT" "$user_id" "$id_suffix"
}

_prepare_notif_id_state() {
    # Ensure id dir exists; print id_file then prev_id (two lines).
    local user_id="$1" id_suffix="$2" id_file
    _soft _ensure_notif_id_dir "$user_id"
    id_file=$(_notif_id_file_path "$user_id" "$id_suffix") || return 1
    printf '%s\n' "$id_file"
    _get_notif_prev_id "$id_file"
}

_send_notification_backends() {
    # Shared dbus-then-notify-send path for sync and user notifications.
    local user="$1" user_id="$2" bus_addr="$3" bus_root="$4" prev_id="$5"
    local icon="$6" title="$7" msg="$8" sync_tag="$9" id_file="${10}" fallback_icon="${11}"
    if _try_dbus_notify_backend "$user" "$user_id" "$bus_addr" "$bus_root" \
        "$prev_id" "$icon" "$title" "$msg" "$sync_tag" "$id_file"; then
        return 0
    fi
    _send_notify_send_fallback "$user" "$user_id" "$bus_addr" "$bus_root" "$prev_id" "$sync_tag" \
        "$fallback_icon" "$title" "$msg" "$id_file"
}

_ensure_notif_id_dir() {
    local user_id="$1"
    mkdir -p "$NOTIF_ID_ROOT/$user_id" 2>/dev/null
}

_check_launch_process() {
    local pid="$1" cmd="$2"
    local wait_secs="${ASUS_LAUNCH_CHECK_SECS:-0.2}"
    if [[ "$wait_secs" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        sleep "$wait_secs"
    else
        sleep 1
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "Error: $cmd failed to start." >&2
        return 1
    fi
    return 0
}

_launch_background_with_env() {
    local target_user="$1" proc_label="$2" avail_script="$3" spawn_script="$4"
    shift 4
    local -a env_args=("$@")
    local pid
    _run_as_user "$target_user" env "${env_args[@]}" sh -c "$avail_script" || return 1
    pid=$(_run_as_user "$target_user" env "${env_args[@]}" sh -c "$spawn_script") || return 1
    _check_launch_process "$pid" "$proc_label"
}

_asus_session_launch_env() {
    # Fill nameref array with runtime/D-Bus plus filtered session display env.
    # Nameref name _asus_env_out_ref is reserved to avoid colliding with caller locals.
    local -n _asus_env_out_ref="$1"
    local target_user="$2" target_uid="$3" runtime_root="$4" bus_addr="$5" line
    _asus_env_out_ref=(
        "XDG_RUNTIME_DIR=${runtime_root}/${target_uid}"
        "DBUS_SESSION_BUS_ADDRESS=${bus_addr}"
    )
    while IFS= read -r line; do
        case "$line" in
            DISPLAY=*|WAYLAND_DISPLAY=*|XDG_SESSION_TYPE=*|XDG_CURRENT_DESKTOP=*)
                _asus_env_out_ref+=("$line")
                ;;
        esac
    done < <(asus_export_session_env_args "$target_user")
}

_run_as_user() {
    local target_user="$1"
    shift
    if [ "$(id -un 2>/dev/null)" = "$target_user" ]; then
        "$@"
        return $?
    fi
    if ! getent passwd "$target_user" >/dev/null 2>&1; then
        echo "Error: Unknown target user '$target_user'." >&2
        return 1
    fi
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$target_user" -- "$@"
        return $?
    fi
    if command -v sudo >/dev/null 2>&1; then
        sudo -n -u "$target_user" -- "$@"
        return $?
    fi
    echo "Error: Unable to drop privileges to '$target_user' (need runuser or sudo)." >&2
    return 1
}

_send_dbus_notify() {
    local user="$1" user_id="$2" bus_addr="$3" bus_root="$4" prev_id="$5" icon="$6" title="$7" msg="$8" tag="$9"
    _is_valid_notification_tag "$tag" || return 1
    _run_as_user "$user" env XDG_RUNTIME_DIR="$bus_root/$user_id" DBUS_SESSION_BUS_ADDRESS="$bus_addr" gdbus call \
        --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
        --method org.freedesktop.Notifications.Notify "ASUS ZenBook" "$prev_id" "$icon" "$title" "$msg" "[]" \
        "{'x-canonical-private-synchronous': <'$tag'>, 'synchronous': <'$tag'>}" 2000 2>/dev/null
}

_extract_notif_id() {
    local res="$1"
    local new_id
    new_id=$(printf '%s' "$res" | awk -F'uint32 ' 'NF>1 {print $2; exit}' | tr -d ',()[:space:]')
    if [ -z "$new_id" ]; then
        new_id=$(printf '%s' "$res" | tr -d '[:space:]')
    fi
    case "$new_id" in
        ''|0|*[!0-9]*) return 1 ;;
    esac
    printf '%s' "$new_id"
}

_write_notif_id_temp() {
    local new_id="$1" tmp="$2"
    if ! printf '%s\n' "$new_id" > "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
}

_locked_commit_notif_id() {
    local tmp="$1" id_file="$2"
    (
        flock -w 1 9 || exit 1
        mv -f "$tmp" "$id_file"
    ) 9>"$id_file.lock" 2>/dev/null
}

_commit_notif_id() {
    local tmp="$1" id_file="$2"
    if command -v flock >/dev/null 2>&1; then
        if ! _locked_commit_notif_id "$tmp" "$id_file"; then
            rm -f "$tmp" 2>/dev/null
            return 1
        fi
        return 0
    fi
    if ! mv -f "$tmp" "$id_file" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
}

_write_notif_id_file() {
    local new_id="$1" id_file="$2"
    local tmp dir
    dir=$(dirname "$id_file")
    _soft mkdir -p "$dir"
    tmp=$(mktemp "$dir/.asus_notif_XXXXXX" 2>/dev/null) || return 1
    _write_notif_id_temp "$new_id" "$tmp" || return 1
    _commit_notif_id "$tmp" "$id_file"
}

_read_notif_id_file() {
    local id_file="$1"
    local value=""
    if command -v flock >/dev/null 2>&1; then
        value=$(flock -s -w 1 "$id_file.lock" cat "$id_file" 2>/dev/null) || value=""
    else
        value=$(cat "$id_file" 2>/dev/null) || value=""
    fi
    printf '%s' "$value"
}

_normalize_notif_prev_id() {
    local value="$1"
    case "$value" in
        *[!0-9]*|""|0) echo 0 ;;
        *) echo "$value" ;;
    esac
}

_get_notif_prev_id() {
    local id_file="$1" value=""
    if [ -f "$id_file" ]; then
        value=$(_read_notif_id_file "$id_file")
    fi
    _normalize_notif_prev_id "$value"
}

_save_notif_id() {
    local res="$1" id_file="$2"
    local new_id
    new_id=$(_extract_notif_id "$res") || return 1
    _write_notif_id_file "$new_id" "$id_file"
}

_try_dbus_notify_backend() {
    local user="$1" user_id="$2" bus_addr="$3" bus_root="$4" prev_id="$5"
    local icon="$6" title="$7" msg="$8" tag="$9" id_file="${10}"
    local res
    res=$(_send_dbus_notify "$user" "$user_id" "$bus_addr" "$bus_root" \
        "$prev_id" "$icon" "$title" "$msg" "$tag") || return 1
    _soft _save_notif_id "$res" "$id_file"
    return 0
}

_send_synchronous_notification() {
    local user="$1" user_id="$2" bus_root="$3" id_suffix="$4" tag="$5" icon="$6" title="$7" msg="$8"
    local bus_addr id_file prev_id

    bus_addr="unix:path=$bus_root/$user_id/bus"
    {
        read -r id_file
        read -r prev_id
    } < <(_prepare_notif_id_state "$user_id" "$id_suffix") || return 0

    _send_notification_backends "$user" "$user_id" "$bus_addr" "$bus_root" \
        "$prev_id" "$icon" "$title" "$msg" "$tag" "$id_file" "$icon"
}

_prepare_user_notification_context() {
    local user user_id bus_path bus_root
    user=$(_resolve_notif_target_user)
    [ -n "$user" ] || return 1
    user_id=$(id -u "$user" 2>/dev/null)
    [ -n "$user_id" ] || return 1
    bus_root="$(_resolve_session_bus_root)"
    bus_path="$bus_root/$user_id/bus"
    [ -S "$bus_path" ] || return 1
    printf '%s\n' "$user" "$user_id" "unix:path=$bus_path"
}

_send_notify_send_fallback() {
    local user="$1" user_id="$2" bus_addr="$3" bus_root="$4" prev_id="$5" sync_tag="$6"
    local fallback_icon="$7" title="$8" msg="$9" id_file="${10}"
    local printed
    _is_valid_notification_tag "$sync_tag" || return 1
    printed=$(_run_as_user "$user" env XDG_RUNTIME_DIR="$bus_root/$user_id" DBUS_SESSION_BUS_ADDRESS="$bus_addr" \
        notify-send -p -a "$(_asus_gettext "ASUS ZenBook")" -r "$prev_id" -i "$fallback_icon" \
        -h "string:x-canonical-private-synchronous:$sync_tag" \
        -h "string:synchronous:$sync_tag" -t 2000 "$title" "$msg" \
        </dev/null 2>/dev/null) || return 0
    _soft _save_notif_id "$printed" "$id_file"
    return 0
}

_send_user_notification() {
    local title="$1" msg="$2" icon="$3" id_suffix="$4" sync_tag="$5" fallback_icon="$6"
    local user user_id bus_addr bus_root id_file prev_id

    if [ -z "$fallback_icon" ]; then
        fallback_icon="$icon"
    fi

    {
        read -r user
        read -r user_id
        read -r bus_addr
    } < <(_prepare_user_notification_context) || return 0

    [ -n "$bus_addr" ] || return 0
    # Derive bus_root from the prepared address; do not re-resolve/reconstruct.
    # unix:path=$bus_root/$uid/bus → dirname twice yields the session bus root.
    bus_root=$(dirname "$(dirname "${bus_addr#unix:path=}")")
    {
        read -r id_file
        read -r prev_id
    } < <(_prepare_notif_id_state "$user_id" "$id_suffix") || return 0

    _send_notification_backends "$user" "$user_id" "$bus_addr" "$bus_root" \
        "$prev_id" "$icon" "$title" "$msg" "$sync_tag" "$id_file" "$fallback_icon"
    return 0
}
