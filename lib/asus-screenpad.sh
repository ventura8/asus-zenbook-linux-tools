#!/usr/bin/env bash
# Shared ScreenPad backlight helpers (toggle + brightness).
# Requires asus-common.sh (_check_node, _soft, _soft_write_stdout, notifications).

SYS_CLASS_ROOT="${SYS_CLASS_ROOT:-/sys/class}"
ASUS_WINDOW_SWAP_EXT_UUID="${ASUS_WINDOW_SWAP_EXT_UUID:-asus-window-swap@ventura8.github.com}"

find_screenpad_node() {
    if [ -n "${ASUS_SCREENPAD_NODE:-}" ]; then
        echo "$ASUS_SCREENPAD_NODE"
        return 0
    fi
    _check_node "$SYS_CLASS_ROOT/backlight/asus_screenpad/brightness" || \
    _check_node "$SYS_CLASS_ROOT/leds/asus::screenpad/brightness"
}

_read_screenpad_value() {
    local node="$1"
    local value
    value=$(cat "$node" 2>/dev/null || echo 0)
    [[ "$value" =~ ^[0-9]+$ ]] || value=0
    echo "$value"
}

_read_screenpad_max_value() {
    local node="$1"
    local max_path max_value
    max_path="$(dirname "$node")/max_brightness"
    max_value=$(cat "$max_path" 2>/dev/null || echo 255)
    if ! [[ "$max_value" =~ ^[1-9][0-9]*$ ]]; then
        max_value=255
    fi
    echo "$max_value"
}

_screenpad_brightness_state_file() {
    local user_id
    user_id=$(id -u "$(_resolve_notif_target_user 2>/dev/null || true)" 2>/dev/null || true)
    [ -n "$user_id" ] || user_id="0"
    printf '%s/%s/screenpad_brightness\n' \
        "${STATE_DIR:-/var/lib/asus-zenbook-linux-tools}" "$user_id"
}

_save_screenpad_brightness() {
    local value="$1" state_file parent
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 0
    state_file=$(_screenpad_brightness_state_file)
    parent=$(dirname "$state_file")
    _soft mkdir -p "$parent"
    _soft_write_stdout "$state_file" printf '%s\n' "$value"
}

_load_screenpad_brightness() {
    local state_file value
    state_file=$(_screenpad_brightness_state_file)
    [ -f "$state_file" ] || return 1
    value=$(_soft cat "$state_file")
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\n' "$value"
}

_screenpad_symbolic_icon_name() {
    local state="$1"
    if [ "$state" = "on" ]; then
        printf '%s\n' "asus-screenpad-on-symbolic"
    else
        printf '%s\n' "asus-screenpad-toggle-symbolic"
    fi
}

_screenpad_symbolic_svg_candidates() {
    local name="$1" lib_dir installed_share
    lib_dir="${_ASUS_LIB_DIR:-${_ASUS_COMMON_DIR:-}}"
    if [ -z "${PREFIX:-}" ]; then
        installed_share="/usr/local/share"
    else
        installed_share="${PREFIX%/}/usr/local/share"
    fi
    if [ -n "${ASUS_SCREENPAD_ICON_DIR:-}" ]; then
        printf '%s\n' "$ASUS_SCREENPAD_ICON_DIR/$name.svg"
    fi
    if [ -n "$lib_dir" ]; then
        printf '%s\n' "$lib_dir/../assets/icons/$name.svg"
    fi
    printf '%s\n' \
        "$installed_share/icons/hicolor/scalable/apps/$name.svg" \
        "$installed_share/asus-zenbook-linux-tools/icons/$name.svg"
}

_find_screenpad_template_svg() {
    local state="$1" name candidate
    name=$(_screenpad_symbolic_icon_name "$state")
    while IFS= read -r candidate; do
        if [ -n "$candidate" ] && [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(_screenpad_symbolic_svg_candidates "$name")
    return 1
}

_resolve_screenpad_notification_icon() {
    local state="$1" src name icon
    name=$(_screenpad_symbolic_icon_name "$state")
    src=$(_find_screenpad_template_svg "$state") || {
        printf '%s\n' "video-joined-displays"
        return 0
    }
    icon=$(_resolve_tinted_template_icon "$src" "asus-screenpad-$state" "$name")
    # File-path tint result, or a theme glyph that actually exists.
    if [[ "$icon" == /* ]] && [ -f "$icon" ]; then
        printf '%s\n' "$icon"
        return 0
    fi
    if _theme_icon_exists "$icon"; then
        printf '%s\n' "$icon"
        return 0
    fi
    printf '%s\n' "video-joined-displays"
}

_screenpad_step_size() {
    local max_val="$1" step
    step=$((max_val / 10))
    [ "$step" -ge 1 ] || step=1
    printf '%s\n' "$step"
}

_clamp_screenpad_brightness() {
    local value="$1" max_val="$2"
    [[ "$value" =~ ^[0-9]+$ ]] || value=0
    [[ "$max_val" =~ ^[0-9]+$ ]] || max_val=0
    if [ "$value" -lt 1 ]; then
        value=1
    fi
    if [ "$value" -gt "$max_val" ]; then
        value="$max_val"
    fi
    printf '%s\n' "$value"
}

_screenpad_write_verified() {
    local node="$1" new_val="$2" read_back
    if ! echo "$new_val" > "$node"; then
        echo "Error: Failed to write ScreenPad brightness to $node" >&2
        return 1
    fi
    read_back=$(cat "$node" 2>/dev/null) || {
        echo "Error: Failed to read ScreenPad brightness from $node" >&2
        return 1
    }
    if [ "$read_back" != "$new_val" ]; then
        echo "Error: ScreenPad brightness verify failed on $node (expected $new_val, got $read_back)" >&2
        return 1
    fi
}

_write_screenpad_brightness() {
    local node="$1" value="$2"
    _screenpad_write_verified "$node" "$value" || return 1
    _save_screenpad_brightness "$value"
}

_screenpad_level_fraction() {
    local curr="$1" max_val="$2"
    if [ "$max_val" -le 0 ]; then
        printf '0.0000\n'
        return 0
    fi
    # C locale so gdbus always receives a '.' decimal (not locale commas).
    LC_ALL=C awk -v c="$curr" -v m="$max_val" 'BEGIN { printf "%.4f\n", c / m }'
}

_screenpad_percent() {
    local curr="$1" max_val="$2"
    if [ "$max_val" -le 0 ]; then
        printf '0\n'
        return 0
    fi
    LC_ALL=C awk -v c="$curr" -v m="$max_val" \
        'BEGIN { printf "%d\n", (c * 100 + m / 2) / m }'
}

_screenpad_bus_addr_is_unix_path() {
    # Plain unix:path= only (no abstract sockets or ,guid= suffixes).
    case "$1" in
        unix:path=/*) return 0 ;;
        *) return 1 ;;
    esac
}

_screenpad_load_notif_fields() {
    # Prints user, user_id, bus_addr on success.
    local user user_id bus_addr
    {
        read -r user
        read -r user_id
        read -r bus_addr
    } < <(_prepare_user_notification_context) || return 1
    [ -n "$user" ] && [ -n "$user_id" ] && [ -n "$bus_addr" ] || return 1
    printf '%s\n' "$user" "$user_id" "$bus_addr"
}

_screenpad_read_notif_context() {
    local user user_id bus_addr bus_root
    {
        read -r user
        read -r user_id
        read -r bus_addr
    } < <(_screenpad_load_notif_fields) || return 1
    _screenpad_bus_addr_is_unix_path "$bus_addr" || return 1
    bus_root=$(dirname "$(dirname "${bus_addr#unix:path=}")")
    printf '%s\n' "$user" "$user_id" "$bus_addr" "$bus_root"
}

_screenpad_session_run() {
    local user="$1" user_id="$2" bus_addr="$3" bus_root="$4"
    shift 4
    _run_as_user "$user" env XDG_RUNTIME_DIR="$bus_root/$user_id" \
        DBUS_SESSION_BUS_ADDRESS="$bus_addr" "$@"
}

_screenpad_osd_timeout_secs() {
    local osd_timeout="${ASUS_SCREENPAD_OSD_TIMEOUT_SECS:-2}"
    case "$osd_timeout" in
        ''|*[!0-9]*|0) osd_timeout=2 ;;
    esac
    printf '%s\n' "$osd_timeout"
}

_call_screenpad_shell_show_osd() {
    local user="$1" user_id="$2" bus_addr="$3" bus_root="$4" level="$5"
    local osd_timeout="${6:-}"
    if [ -z "$osd_timeout" ]; then
        osd_timeout="$(_screenpad_osd_timeout_secs)"
    fi
    _screenpad_session_run "$user" "$user_id" "$bus_addr" "$bus_root" \
        timeout "$osd_timeout" gdbus call --session \
        --dest org.gnome.Shell \
        --object-path /org/gnome/Shell/Extensions/AsusWindowSwap \
        --method org.gnome.Shell.Extensions.AsusWindowSwap.ShowOsd \
        "display-brightness-symbolic" "$level" >/dev/null 2>&1
}

_prime_screenpad_window_swap_extension() {
    local user="$1" user_id="$2" bus_addr="$3" bus_root="$4"
    # Global kill switch leaves the UUID "enabled" but inactive — no D-Bus OSD.
    if command -v gsettings >/dev/null 2>&1; then
        _screenpad_session_run "$user" "$user_id" "$bus_addr" "$bus_root" \
            gsettings set org.gnome.shell disable-user-extensions false \
            >/dev/null 2>&1 || true
    fi
    command -v gnome-extensions >/dev/null 2>&1 || return 1
    _screenpad_session_run "$user" "$user_id" "$bus_addr" "$bus_root" \
        gnome-extensions enable "$ASUS_WINDOW_SWAP_EXT_UUID" >/dev/null 2>&1
}

_retry_screenpad_shell_show_osd() {
    local user="$1" user_id="$2" bus_addr="$3" bus_root="$4" level="$5"
    local _i
    # Cap retries so enable+OSD stays under the hotkey helper's 5s exec budget.
    for _i in 1 2 3; do
        if _call_screenpad_shell_show_osd "$user" "$user_id" "$bus_addr" "$bus_root" \
            "$level" 1; then
            return 0
        fi
        [ "$_i" -lt 3 ] && sleep 0.1
    done
    return 1
}

_try_show_screenpad_shell_osd() {
    local level="$1" user user_id bus_addr bus_root
    {
        read -r user
        read -r user_id
        read -r bus_addr
        read -r bus_root
    } < <(_screenpad_read_notif_context) || return 1
    if _call_screenpad_shell_show_osd "$user" "$user_id" "$bus_addr" "$bus_root" \
        "$level"; then
        return 0
    fi
    # Reinstall can rm -rf the extension while Shell still lists it enabled;
    # brightness then hits UnknownMethod and falls back to notifications only.
    # Priming is best-effort: still retry ShowOsd even when enable fails
    # (e.g. transient gnome-extensions CLI errors).
    _prime_screenpad_window_swap_extension "$user" "$user_id" "$bus_addr" \
        "$bus_root" || true
    _retry_screenpad_shell_show_osd "$user" "$user_id" "$bus_addr" "$bus_root" \
        "$level"
}

_call_screenpad_osd_gdbus() {
    local user="$1" user_id="$2" bus_addr="$3" bus_root="$4"
    local osd_timeout
    shift 4
    osd_timeout="$(_screenpad_osd_timeout_secs)"
    _screenpad_session_run "$user" "$user_id" "$bus_addr" "$bus_root" \
        timeout "$osd_timeout" gdbus call --session "$@" >/dev/null 2>&1
}

_try_show_screenpad_plasma_osd() {
    local percent="$1" user user_id bus_addr bus_root
    {
        read -r user
        read -r user_id
        read -r bus_addr
        read -r bus_root
    } < <(_screenpad_read_notif_context) || return 1
    # Plasma exports /org/kde/osdService from plasmashell.
    if _call_screenpad_osd_gdbus "$user" "$user_id" "$bus_addr" "$bus_root" \
        --dest org.kde.plasmashell \
        --object-path /org/kde/osdService \
        --method org.kde.osdService.brightnessChanged \
        "$percent"; then
        return 0
    fi
    _call_screenpad_osd_gdbus "$user" "$user_id" "$bus_addr" "$bus_root" \
        --dest org.kde.plasmashell \
        --object-path /org/kde/osdService \
        --method org.kde.osdService.showProgress \
        "video-display-brightness" "$percent" "100" "" false
}

_try_show_screenpad_cinnamon_osd() {
    # Public Cinnamon OSD (display-only; does not change backlight):
    # dest org.Cinnamon, path /org/Cinnamon, method org.Cinnamon.ShowOSD (a{sv}).
    # Evidence: linuxmint/cinnamon js/ui/cinnamonDBus.js + src/main.c
    # (CINNAMON_DBUS_SERVICE). Params: icon (s), level (i 0–100), optional label.
    # Always probe (like Plasma): ServiceUnknown fails fast when absent.
    local percent="$1" user user_id bus_addr bus_root
    [[ "$percent" =~ ^[0-9]+$ ]] || return 1
    {
        read -r user
        read -r user_id
        read -r bus_addr
        read -r bus_root
    } < <(_screenpad_read_notif_context) || return 1
    _call_screenpad_osd_gdbus "$user" "$user_id" "$bus_addr" "$bus_root" \
        --dest org.Cinnamon \
        --object-path /org/Cinnamon \
        --method org.Cinnamon.ShowOSD \
        "{'icon': <'display-brightness-symbolic'>, 'level': <int32 $percent>}"
}

_screenpad_resolve_family() {
    local user="${1:-}" family
    family="${ASUS_DESKTOP_FAMILY:-}"
    if [ -n "$family" ]; then
        printf '%s\n' "$family"
        return 0
    fi
    [ -n "$user" ] || return 1
    asus_desktop_family "$user" 2>/dev/null
}

_call_screenpad_value_notify() {
    # Desktop Notifications Spec value hint (public; lxqt-notificationd accepts it).
    local user="$1" user_id="$2" bus_addr="$3" bus_root="$4"
    local prev_id="$5" icon="$6" title="$7" msg="$8" tag="$9" percent="${10}"
    local osd_timeout
    _is_valid_notification_tag "$tag" || return 1
    [[ "$percent" =~ ^[0-9]+$ ]] || return 1
    osd_timeout="$(_screenpad_osd_timeout_secs)"
    _screenpad_session_run "$user" "$user_id" "$bus_addr" "$bus_root" \
        timeout "$osd_timeout" gdbus call --session \
        --dest org.freedesktop.Notifications \
        --object-path /org/freedesktop/Notifications \
        --method org.freedesktop.Notifications.Notify \
        "ASUS ZenBook" "$prev_id" "$icon" "$title" "$msg" "[]" \
        "{'x-canonical-private-synchronous': <'$tag'>, 'synchronous': <'$tag'>, 'value': <int32 $percent>}" \
        2000 2>/dev/null
}

_screenpad_value_hint_notify() {
    local percent="$1" user="$2" user_id="$3" bus_addr="$4" bus_root="$5"
    local icon id_file prev_id res
    icon=$(_resolve_screenpad_notification_icon "on")
    {
        read -r id_file
        read -r prev_id
    } < <(_prepare_notif_id_state "$user_id" "screenpad-brightness") || return 1
    res=$(_call_screenpad_value_notify "$user" "$user_id" "$bus_addr" "$bus_root" \
        "$prev_id" "$icon" "ScreenPad Brightness" "${percent}%" \
        "screenpad-brightness" "$percent") || return 1
    _soft _save_notif_id "$res" "$id_file"
    return 0
}

_try_show_screenpad_lxqt_osd() {
    # Research lock: no public display-only LXQt OSD D-Bus.
    # - plugin-volume OSD is private (global_key_shortcuts.client.activated also
    #   mutates volume — unusable for ScreenPad).
    # - plugin-backlight is a panel slider popup only (no ShowOSD method).
    # - lxqt-notificationd = Notifications Spec; does not paint a level bar from
    #   `value`, but Spec Notify + replace/synchronous (+ value hint) is the only
    #   public feedback path. Do not invent private panel APIs.
    local percent="$1" user user_id bus_addr bus_root family
    {
        read -r user
        read -r user_id
        read -r bus_addr
        read -r bus_root
    } < <(_screenpad_read_notif_context) || return 1
    family=$(_screenpad_resolve_family "$user") || return 1
    [ "$family" = "lxqt" ] || return 1
    _screenpad_value_hint_notify "$percent" "$user" "$user_id" "$bus_addr" "$bus_root"
}

_try_show_screenpad_mate_osd() {
    # Research lock: no public MATE display-only OSD.
    # - org.mate.SettingsDaemon.MediaKeys = Grab/Release media-player keys only.
    # - mate-power-manager brightness popup is private (gpm_backlight_dialog_show).
    # - org.mate.PowerManager.Backlight.SetBrightness mutates main LCD — never use
    #   for ScreenPad feedback. Spec value-hint Notify is the public stand-in.
    local percent="$1" user user_id bus_addr bus_root family
    {
        read -r user
        read -r user_id
        read -r bus_addr
        read -r bus_root
    } < <(_screenpad_read_notif_context) || return 1
    family=$(_screenpad_resolve_family "$user") || return 1
    [ "$family" = "mate" ] || return 1
    _screenpad_value_hint_notify "$percent" "$user" "$user_id" "$bus_addr" "$bus_root"
}

_try_show_screenpad_percent_osds() {
    local percent="$1"
    if _try_show_screenpad_plasma_osd "$percent"; then
        return 0
    fi
    if _try_show_screenpad_lxqt_osd "$percent"; then
        return 0
    fi
    if _try_show_screenpad_cinnamon_osd "$percent"; then
        return 0
    fi
    _try_show_screenpad_mate_osd "$percent"
}

_notify_screenpad_brightness() {
    local curr="$1" max_val="$2"
    local level percent icon
    level=$(_screenpad_level_fraction "$curr" "$max_val")
    if _try_show_screenpad_shell_osd "$level"; then
        return 0
    fi
    percent=$(_screenpad_percent "$curr" "$max_val")
    if _try_show_screenpad_percent_osds "$percent"; then
        return 0
    fi
    # XFCE and other DEs: replace-in-place notify is the OSD stand-in.
    icon=$(_resolve_screenpad_notification_icon "on")
    _send_user_notification "$(_asus_gettext "ScreenPad brightness")" "${percent}%" \
        "$icon" "screenpad-brightness" "screenpad-brightness" "$icon"
}
