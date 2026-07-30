#!/usr/bin/env bash
# kcov driver: exercise camera toggle verify/read failure branches via sourced helpers.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$REPO_ROOT" || exit 1

# shellcheck source=scripts/coverage/drivers/kcov_driver_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/kcov_driver_common.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/platform" "$tmp/icons" "$tmp/theme/Adwaita/symbolic/status"
printf '1\n' > "$tmp/platform/camera"
chmod 666 "$tmp/platform/camera"
printf '<svg><path stroke="#000"/></svg>\n' > "$tmp/icons/asus-camera-on-symbolic.svg"
printf '<svg><path stroke="#000"/></svg>\n' > "$tmp/icons/asus-camera-off-symbolic.svg"
printf '<svg/>\n' > "$tmp/theme/Adwaita/symbolic/status/camera-photo-symbolic.svg"
printf '<svg/>\n' > "$tmp/theme/Adwaita/symbolic/status/camera-disabled-symbolic.svg"

export SYS_PLATFORM_ROOT="$tmp/platform"
export ASUS_CAMERA_NODE="$tmp/platform/camera"
export ASUS_ICON_THEME_ROOT="$tmp/theme"
export ASUS_CAMERA_ICON_DIR="$tmp/icons"
export NOTIF_ID_ROOT="$tmp/notif"
# Skip host gnome-shell.css scans (huge; hangs under kcov).
export ASUS_NOTIF_APP_NAME_COLOR='#abc'
export ASUS_CAMERA_APP_NAME_COLOR='#abc'
mkdir -p "$NOTIF_ID_ROOT/$(id -u)"

# shellcheck source=bin/asus-camera-toggle.sh
_driver_source_required "$REPO_ROOT/bin/asus-camera-toggle.sh" camera_helpers quiet

_soft_expect 0 _camera_write_verified "$tmp/platform/camera" 0
_soft_expect 0 _read_camera_toggle_state "$tmp/platform/camera" >/dev/null
printf 'abc\n' > "$tmp/platform/camera"
_soft_expect 1 _read_camera_toggle_state "$tmp/platform/camera" >/dev/null
printf '5\n' > "$tmp/platform/camera"
_soft_expect 1 _read_camera_toggle_state "$tmp/platform/camera" >/dev/null
rm -f "$tmp/platform/camera"
_soft_expect 1 _read_camera_toggle_state "$tmp/platform/camera" >/dev/null
mkdir -p "$tmp/platform/camera"
_soft_expect 1 _camera_write_verified "$tmp/platform/camera" 1
rmdir "$tmp/platform/camera"
printf '0\n' > "$tmp/platform/camera"
chmod 666 "$tmp/platform/camera"
_soft_expect 1 _camera_sysfs_path_allowed "/etc/passwd" >/dev/null
_soft_expect 0 find_camera_node >/dev/null
_soft_expect 0 _exercise ASUS_CAMERA_FORCE_KEYCAP=1 _resolve_camera_notification_icon on >/dev/null
_soft_expect 0 _exercise ASUS_CAMERA_FORCE_KEYCAP=0 _resolve_camera_notification_icon on >/dev/null
_soft_expect 0 _exercise ASUS_CAMERA_FORCE_KEYCAP=0 _resolve_camera_notification_icon off >/dev/null
