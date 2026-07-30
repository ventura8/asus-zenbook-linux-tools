#!/bin/bash
# ASUS ZenBook Camera Privacy Toggle Helper

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

SYS_PLATFORM_ROOT="${SYS_PLATFORM_ROOT:-/sys/devices/platform}"


_send_notification() {
    local title="$1" msg="$2" state="$3" icon
    icon=$(_resolve_camera_notification_icon "$state")
    _send_user_notification "$title" "$msg" "$icon" "camera" "camera" "$icon"
}

_camera_system_icon_name() {
    # Prefer theme glyphs that match the F10 camera±slash silhouette when present.
    local state="$1"
    if [ "$state" = "on" ]; then
        printf '%s\n' "camera-photo-symbolic"
    else
        printf '%s\n' "camera-disabled-symbolic"
    fi
}

_camera_keycap_icon_name() {
    local state="$1"
    if [ "$state" = "on" ]; then
        printf '%s\n' "asus-camera-on-symbolic"
    else
        printf '%s\n' "asus-camera-toggle-symbolic"
    fi
}

_camera_keycap_svg_candidates() {
    local name="$1" script_dir installed_share
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # Empty PREFIX → wizard default /usr/local/share; set PREFIX (e.g. /usr)
    # → $PREFIX/share so packaged installs resolve under /usr/share.
    if [ -n "${PREFIX:-}" ]; then
        case "$PREFIX" in
            /*) installed_share="${PREFIX%/}/share" ;;
            *)
                echo "Warning: invalid PREFIX (must be absolute): ${PREFIX}; using /usr/local/share" >&2
                installed_share="/usr/local/share"
                ;;
        esac
    else
        installed_share="/usr/local/share"
    fi
    if [ -n "${ASUS_CAMERA_ICON_DIR:-}" ]; then
        case "$ASUS_CAMERA_ICON_DIR" in
            /*) printf '%s\n' "$ASUS_CAMERA_ICON_DIR/$name.svg" ;;
            *)
                echo "Warning: invalid ASUS_CAMERA_ICON_DIR (must be absolute):" \
                    "${ASUS_CAMERA_ICON_DIR}; ignoring" >&2
                ;;
        esac
    fi
    printf '%s\n' \
        "$script_dir/../assets/icons/$name.svg" \
        "$installed_share/icons/hicolor/scalable/apps/$name.svg" \
        "$installed_share/asus-zenbook-linux-tools/icons/$name.svg"
}

_find_camera_keycap_template_svg() {
    local state="$1" name candidate
    name=$(_camera_keycap_icon_name "$state")
    while IFS= read -r candidate; do
        if [ -n "$candidate" ] && [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(_camera_keycap_svg_candidates "$name")
    return 1
}

_resolve_camera_notification_icon() {
    # Prefer a matching system theme glyph; else tint UX582HS F10 keycap art to
    # the notification emitting-app-name (message-header) color.
    local state="$1" sys_name src
    if [ "${ASUS_CAMERA_FORCE_KEYCAP:-0}" != "1" ]; then
        sys_name=$(_camera_system_icon_name "$state")
        if _theme_icon_exists "$sys_name"; then
            printf '%s\n' "$sys_name"
            return 0
        fi
    fi
    src=$(_find_camera_keycap_template_svg "$state") || {
        printf '%s\n' "camera-web"
        return 0
    }
    _resolve_tinted_template_icon "$src" "asus-camera-$state" \
        "$(_camera_keycap_icon_name "$state")"
}

_camera_sysfs_path_allowed() {
    # Print canonical path on success so callers use the resolved node.
    local node="$1" canonical platform_root usb_root
    [ -n "$node" ] || return 1
    if command -v realpath >/dev/null 2>&1; then
        canonical=$(realpath -m -- "$node" 2>/dev/null) || canonical="$node"
    else
        canonical=$(readlink -f -- "$node" 2>/dev/null) || canonical="$node"
    fi
    platform_root="${SYS_PLATFORM_ROOT:-/sys/devices/platform}"
    usb_root="${SYS_BUS_USB_ROOT:-/sys/bus/usb/devices}"
    case "$canonical" in
        "$platform_root"/*|"$usb_root"/*)
            printf '%s\n' "$canonical"
            return 0
            ;;
    esac
    return 1
}

_matches_usb_video_class_file() {
    local class_file="$1"
    local class_val hex_digits
    [ -r "$class_file" ] || return 1
    class_val=$(tr '[:upper:]' '[:lower:]' < "$class_file" 2>/dev/null | tr -d '[:space:]')
    [[ "$class_val" =~ ^0*([0-9a-f]+)$ ]] || return 1
    hex_digits="${BASH_REMATCH[1]}"
    # USB class is one byte; reject overlong hex before $((16#…)) overflow.
    [ "${#hex_digits}" -le 2 ] || return 1
    [ "$((16#$hex_digits))" -eq 14 ]
}

_matches_usb_video_class() {
    local usb_node="$1"
    local interface_node

    _matches_usb_video_class_file "$usb_node/bDeviceClass" && return 0
    for interface_node in "$usb_node":*; do
        [ -e "$interface_node" ] || continue
        _matches_usb_video_class_file "$interface_node/bInterfaceClass" && return 0
    done
    return 1
}

_matches_camera_product() {
    local usb_node="$1"
    local prod_file="$usb_node/product" prod
    [ -r "$prod_file" ] || return 1
    prod=$(tr '[:upper:]' '[:lower:]' < "$prod_file" 2>/dev/null)
    case "$prod" in
        *webcam*|*camera*|*uvc*) return 0 ;;
    esac
    return 1
}

_matches_camera_usb_device() {
    local usb_node="$1"
    local vendor_file product_file vendor_id product_id

    vendor_file="$usb_node/idVendor"
    product_file="$usb_node/idProduct"
    [ -r "$vendor_file" ] || return 1
    [ -r "$product_file" ] || return 1

    vendor_id=$(tr -d '[:space:]' < "$vendor_file" 2>/dev/null)
    product_id=$(tr -d '[:space:]' < "$product_file" 2>/dev/null)

    case "$vendor_id:$product_id" in
        13d3:*|04f2:*|1bcf:*|0b05:*)
            _matches_usb_video_class "$usb_node" || _matches_camera_product "$usb_node"
            return $?
            ;;
    esac

    return 1
}

_select_writable_camera_auth_node() {
    local usb_node="$1" auth_node="$2"
    [ -w "$auth_node" ] || return 1
    _matches_camera_usb_device "$usb_node" || return 1
    _check_node "$auth_node"
}

_find_usb_camera_node() {
    local usb_node auth_node
    local usb_devices_root="${SYS_BUS_USB_ROOT:-/sys/bus/usb/devices}"
    for usb_node in "$usb_devices_root"/*; do
        [ -e "$usb_node" ] || continue
        auth_node="$usb_node/authorized"
        _select_writable_camera_auth_node "$usb_node" "$auth_node" && return 0
    done
    return 1
}

find_camera_node() {
    local allowed
    if [ -n "${ASUS_CAMERA_NODE:-}" ]; then
        if allowed=$(_camera_sysfs_path_allowed "$ASUS_CAMERA_NODE"); then
            printf '%s\n' "$allowed"
            return 0
        fi
        echo "Warning: ASUS_CAMERA_NODE='$ASUS_CAMERA_NODE' is outside" \
            "SYS_PLATFORM_ROOT/SYS_BUS_USB_ROOT; ignoring override" >&2
    fi
    _check_node "$SYS_PLATFORM_ROOT/asus-nb-wmi/camera" || \
    _check_node "$SYS_PLATFORM_ROOT/asus-wmi/camera" || \
    _find_usb_camera_node
}

_camera_write_verified() {
    local node="$1" new_val="$2" read_back
    if ! echo "$new_val" > "$node"; then
        echo "Error: Failed to write camera state to $node" >&2
        return 1
    fi
    read_back=$(cat "$node" 2>/dev/null) || {
        echo "Error: Failed to read camera state from $node" >&2
        return 1
    }
    if [ "$read_back" != "$new_val" ]; then
        echo "Error: Camera state verify failed on $node (expected $new_val, got $read_back)" >&2
        return 1
    fi
}

_read_camera_toggle_state() {
    local node="$1" curr
    curr=$(cat "$node" 2>/dev/null) || {
        echo "Error: Failed to read camera state from $node" >&2
        return 1
    }
    [[ "$curr" =~ ^[0-9]+$ ]] || {
        echo "Error: Camera state is non-numeric on $node (got ${curr:-empty})" >&2
        return 1
    }
    if [ "$curr" -ne 0 ] && [ "$curr" -ne 1 ]; then
        echo "Error: Invalid camera state on $node (expected 0 or 1, got $curr)" >&2
        return 1
    fi
    printf '%s\n' "$curr"
}

_toggle_camera_val() {
    local node="$1"
    local curr new_val status_text state
    curr=$(_read_camera_toggle_state "$node") || return 1
    if [ "$curr" -eq 1 ]; then
        new_val=0
        status_text=$(_asus_gettext "Camera disabled")
        state="off"
    else
        new_val=1
        status_text=$(_asus_gettext "Camera enabled")
        state="on"
    fi
    _camera_write_verified "$node" "$new_val" || return 1
    _send_notification "$(_asus_gettext "Camera privacy")" "$status_text" "$state"
}

main() {
    local node
    node=$(find_camera_node || true)
    if [ -z "$node" ]; then
        echo "Error: No camera control node found." >&2
        return 1
    fi

    if [ ! -w "$node" ]; then
        echo "Error: Camera control node is not writable: $node" >&2
        return 1
    fi

    _toggle_camera_val "$node"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
