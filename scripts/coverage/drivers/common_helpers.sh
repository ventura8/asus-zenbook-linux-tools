#!/usr/bin/env bash
# kcov driver: exercise lib/asus-bootstrap.sh and lib/asus-common.sh helpers.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$REPO_ROOT" || exit 1

# shellcheck source=scripts/coverage/drivers/kcov_driver_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/kcov_driver_common.sh"

_setup_common_bus_root() {
    if [ -n "${KCOV_BUS_ROOT:-}" ]; then
        BUS_ROOT="$KCOV_BUS_ROOT"
    else
        BUS_ROOT=$(mktemp -d)
        trap 'rm -rf "$BUS_ROOT"' EXIT
    fi
}

_ensure_common_bus_socket() {
    if [ -S "$BUS_ROOT/$(id -u)/bus" ]; then
        return 0
    fi
    _driver_bind_required "$BUS_ROOT/$(id -u)/bus" common_helpers
}

_source_common_or_die() {
    if _source_common_helper; then
        return 0
    fi
    echo "common_helpers: _source_common_helper failed after bootstrap" >&2
    exit 1
}

_other_existing_user() {
    # Pick a passwd user that is not the current user for privilege-drop paths.
    local cur candidate
    cur="$(id -un)"
    for candidate in nobody daemon www-data sshd; do
        if [ "$candidate" != "$cur" ] && getent passwd "$candidate" >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    echo "Warning: no non-root passwd candidate for kcov privilege-drop paths" \
        "(current user=$cur)." >&2
    if [ "$cur" = "root" ]; then
        return 1
    fi
    printf '%s\n' "$cur"
}

_run_common_other_user_priv_paths() {
    local other="$1" mock="$2" no_priv tool src
    # Privilege-drop via runuser.
    _exercise _run_as_user "$other" true >/dev/null
    # No runuser → sudo path.
    mkdir -p "$mock/sudo-only"
    ln -sf "$mock/sudo" "$mock/sudo-only/sudo"
    _exercise PATH="$mock/sudo-only:/bin:/usr/bin" _run_as_user "$other" true >/dev/null
    # Neither runuser nor sudo: isolated PATH without /bin or /usr/bin.
    no_priv=$(mktemp -d)
    for tool in bash sh true id getent env; do
        src=$(command -v "$tool" 2>/dev/null) || src=""
        [ -n "$src" ] || continue
        ln -sf "$src" "$no_priv/$tool"
    done
    _exercise PATH="$no_priv" _run_as_user "$other" true >/dev/null
    rm -rf "$no_priv"
}

_run_common_notify_paths() {
    local uid mock other saved_path missing_notif_root
    uid="$(id -u)"
    other="$(_other_existing_user)" || other=""
    mock=$(mktemp -d)
    saved_path="$PATH"
    # RETURN runs before this function's locals go out of scope, so the trap
    # can safely use saved_path and mock here.
    trap 'export PATH="$saved_path"; rm -rf "$mock"' RETURN
    printf '#!/bin/sh\necho 99\n' > "$mock/notify-send"
    printf '#!/bin/sh\nexit 1\n' > "$mock/gdbus"
    cat > "$mock/runuser" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    case "$1" in
        -u) shift 2 ;;
        --) shift; break ;;
        *) break ;;
    esac
done
exec "$@"
EOF
    cat > "$mock/sudo" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    case "$1" in
        -u) shift 2 ;;
        -*) shift ;;
        *) break ;;
    esac
done
exec "$@"
EOF
    chmod +x "$mock"/*
    export PATH="$mock:$PATH"
    _exercise _check_node /etc/hostname >/dev/null
    _exercise _check_node /missing-asus-node >/dev/null
    printf '#!/bin/sh\nexit 0\n' > "$mock/loginctl"
    chmod +x "$mock/loginctl"
    _exercise RUN_USER_ROOT="$BUS_ROOT" PATH="$mock:$saved_path" _resolve_notif_target_user >/dev/null
    missing_notif_root=$(mktemp -d "$BUS_ROOT/missing-notif.XXXXXX")
    _exercise _get_notif_prev_id "$missing_notif_root/asus-missing-notif-id" >/dev/null
    rm -rf "$missing_notif_root"
    _exercise _extract_notif_id "(uint32 7,)" >/dev/null
    _exercise _extract_notif_id "(uint32 0,)" >/dev/null
    _exercise _extract_notif_id "not-an-id" >/dev/null
    _exercise NOTIF_ID_ROOT="$BUS_ROOT" _ensure_notif_id_dir "$uid" >/dev/null
    echo 42 > "$BUS_ROOT/$uid/.asus_notif_cam.id"
    _exercise NOTIF_ID_ROOT="$BUS_ROOT" \
        _get_notif_prev_id "$(_notif_id_file_path "$uid" cam)" >/dev/null
    echo abc > "$BUS_ROOT/$uid/.asus_notif_bad.id"
    _exercise _get_notif_prev_id "$BUS_ROOT/$uid/.asus_notif_bad.id" >/dev/null
    _exercise RUN_USER_ROOT="$BUS_ROOT" NOTIF_ID_ROOT="$BUS_ROOT" \
        _send_user_notification "t" "m" "icon" "cam" "tag" "fallback" >/dev/null
    _exercise RUN_USER_ROOT="$BUS_ROOT" NOTIF_ID_ROOT="$BUS_ROOT" \
        _send_user_notification "t" "m" "icon" "cam" "tag" "" >/dev/null
    _exercise RUN_USER_ROOT="$BUS_ROOT" _prepare_user_notification_context >/dev/null
    _exercise RUN_USER_ROOT="$BUS_ROOT" NOTIF_ID_ROOT="$BUS_ROOT" \
        _send_synchronous_notification "$(id -un)" "$uid" "$BUS_ROOT" \
        "cam" "tag" "icon" "title" "msg" >/dev/null
    _exercise _run_as_user "$(id -un)" true >/dev/null
    _exercise _run_as_user "asus-missing-user-$$" true >/dev/null
    if [ -n "$other" ]; then
        _run_common_other_user_priv_paths "$other" "$mock"
    fi
    _exercise _write_notif_id_file "9" "$BUS_ROOT/$uid/.asus_notif_write.id" >/dev/null
    _exercise _save_notif_id "(uint32 11,)" "$BUS_ROOT/$uid/.asus_notif_save.id" >/dev/null
    _exercise _save_notif_id "bad" "$BUS_ROOT/$uid/.asus_notif_save.id" >/dev/null
    export PATH="$saved_path"
    rm -rf "$mock"
    trap - RETURN
}

_common_expect_env() {
    local expected="$1"
    shift
    _soft_expect "$expected" _exercise KCOV_EXERCISE_RETURN_STATUS=1 "$@"
}

_run_notif_icon_css_paths() {
    local tmp="$1" css="$2"
    # Same-shell: _common_expect_env/_exercise drop kcov hits on notif-icons.
    PATH="$tmp:$PATH"
    _soft _extract_css_message_header_color "$css" >/dev/null
    _soft _extract_css_message_header_color "$tmp/css-alt.css" >/dev/null
    _soft _extract_css_message_header_color "$tmp/missing.css" >/dev/null
    _soft _css_line_message_header_starts ".message .message-header {"
    _soft _css_line_color "  color: #abcdef;" >/dev/null
    _soft _css_message_header_color_from_line "  color: #abcdef;" 1 >/dev/null
    _soft _css_message_header_color_from_line "  color: #abcdef;" 0 >/dev/null
    _soft _css_message_header_state_before ".message .message-header {" 0 >/dev/null
    _soft _css_message_header_state_after "  }" 1 >/dev/null
    _soft _notif_gsettings_value org.gnome.desktop.interface gtk-theme >/dev/null
    _soft _notif_shell_css_candidates >/dev/null
    # Stub candidates to tiny fixtures so host gnome-shell.css cannot hang kcov.
    # Avoid RETURN traps around this nested override (nested returns fire them).
    _notif_shell_css_candidates() {
        printf '%s\n' "$css" "$tmp/css-alt.css" "$tmp/missing.css"
    }
    _soft _notif_css_app_name_color >/dev/null
    # shellcheck source=lib/asus-notif-icons.sh
    . "${_ASUS_LIB_DIR}/asus-notif-icons.sh"
}

_run_notif_icon_color_valid_paths() {
    local color
    for color in '#abc' '#abcd' '#abcdef' '#abcdef12'; do
        _soft _is_valid_notif_color "$color"
    done
    _soft _is_valid_notif_color '#abcde'
    _soft _is_valid_notif_color red
}

_run_notif_icon_override_paths() {
    ASUS_NOTIF_APP_NAME_COLOR='#123456' _soft _notif_override_app_name_color >/dev/null
    _soft unset ASUS_NOTIF_APP_NAME_COLOR
    ASUS_SCREENPAD_APP_NAME_COLOR='#1234' _soft _notif_override_app_name_color >/dev/null
    _soft unset ASUS_SCREENPAD_APP_NAME_COLOR
    ASUS_CAMERA_APP_NAME_COLOR='#123' _soft _notif_override_app_name_color >/dev/null
    _soft unset ASUS_CAMERA_APP_NAME_COLOR
    _soft _notif_override_app_name_color >/dev/null
}

_run_notif_icon_tint_paths() {
    local tmp="$1" src="$2" dest="$3" theme_root="$4"
    _soft _prepare_tint_svg_temp "$tmp/missing.svg" "$dest" '#123456'
    _soft _prepare_tint_svg_temp "$src" "$dest" invalid
    _soft _tint_svg_stroke "$src" "$dest" '#123456'
    : > "$tmp/empty.svg"
    _soft _render_tinted_svg "$tmp/empty.svg" "$tmp/empty-tinted.svg" '#123456'
    _soft _notif_tinted_icon_path "asus-test" >/dev/null
    ASUS_ICON_THEME_ROOT="$theme_root"
    _soft _theme_icon_exists camera-photo-symbolic
    _soft _theme_icon_exists missing-icon
    _soft _theme_icon_svg_candidates camera-photo-symbolic >/dev/null
    _soft _resolve_tinted_template_icon "$tmp/missing.svg" test fallback >/dev/null
    _soft _resolve_tinted_template_icon "$src" test fallback >/dev/null
}

_run_notif_icon_resolve_paths() {
    local tmp="$1" src="$2"
    ASUS_NOTIF_APP_NAME_COLOR='#654321'
    NOTIF_ID_ROOT="$tmp/notif"
    _soft _resolve_tinted_template_icon "$src" test fallback >/dev/null
    : > "$tmp/blocked-root"
    NOTIF_ID_ROOT="$tmp/blocked-root"
    _soft _resolve_tinted_template_icon "$src" blocked fallback >/dev/null
    ASUS_NOTIF_APP_NAME_COLOR='#654321' _soft _notification_app_name_color >/dev/null
}

_restore_notif_icon_env() {
    local saved_path="$1" saved_icon_root="$2" saved_notif_root="$3"
    local saved_notif_color="$4" saved_screenpad_color="$5" saved_camera_color="$6"
    PATH="$saved_path"
    _restore_or_unset ASUS_ICON_THEME_ROOT "$saved_icon_root"
    _restore_or_unset NOTIF_ID_ROOT "$saved_notif_root"
    _restore_or_unset ASUS_NOTIF_APP_NAME_COLOR "$saved_notif_color"
    _restore_or_unset ASUS_SCREENPAD_APP_NAME_COLOR "$saved_screenpad_color"
    _restore_or_unset ASUS_CAMERA_APP_NAME_COLOR "$saved_camera_color"
}

_run_notif_icon_paths() {
    local tmp css src dest theme_root saved_path
    local saved_icon_root saved_notif_color saved_screenpad_color saved_camera_color
    local saved_notif_root
    tmp=$(mktemp -d)
    css="$tmp/gnome-shell.css"
    src="$tmp/template.svg"
    dest="$tmp/tinted.svg"
    theme_root="$tmp/icons"
    cat > "$css" <<'EOF'
.message .message-header {
  border-color: #000000;
  color: #a1b2c3;
}
EOF
    # Alternate CSS shapes for header/color helpers.
    cat > "$tmp/css-alt.css" <<'EOF'
.other { color: #111111; }
.message .message-header {
  color: #fedcba;
}
.after { color: #222222; }
EOF
    printf '<svg><path stroke="#000000"/></svg>\n' > "$src"
    cat > "$tmp/gsettings" <<'EOF'
#!/bin/sh
case "$*" in
    *gtk-theme) printf "'Yaru-dark'\n" ;;
    *color-scheme) printf "'prefer-dark'\n" ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$tmp/gsettings"
    mkdir -p "$theme_root/Adwaita/symbolic/status"
    cp "$src" "$theme_root/Adwaita/symbolic/status/camera-photo-symbolic.svg"
    saved_path="$PATH"
    saved_notif_color="${ASUS_NOTIF_APP_NAME_COLOR-}"
    saved_screenpad_color="${ASUS_SCREENPAD_APP_NAME_COLOR-}"
    saved_camera_color="${ASUS_CAMERA_APP_NAME_COLOR-}"
    saved_icon_root="${ASUS_ICON_THEME_ROOT-}"
    saved_notif_root="${NOTIF_ID_ROOT-}"
    _run_notif_icon_css_paths "$tmp" "$css"
    _run_notif_icon_color_valid_paths
    _run_notif_icon_override_paths
    _run_notif_icon_tint_paths "$tmp" "$src" "$dest" "$theme_root"
    _run_notif_icon_resolve_paths "$tmp" "$src"
    _restore_notif_icon_env "$saved_path" "$saved_icon_root" "$saved_notif_root" \
        "$saved_notif_color" "$saved_screenpad_color" "$saved_camera_color"
    rm -rf "$tmp"
}

_restore_asus_lib_dir() {
    local had_lib_dir="$1" saved_lib_dir="$2"
    if [ "$had_lib_dir" = 1 ]; then
        _ASUS_LIB_DIR="$saved_lib_dir"
    else
        unset _ASUS_LIB_DIR
    fi
}

_run_missing_common_path() {
    local saved_lib_dir had_lib_dir=0 missing_lib
    if [ -n "${_ASUS_LIB_DIR+set}" ]; then
        saved_lib_dir="$_ASUS_LIB_DIR"
        had_lib_dir=1
    fi
    missing_lib=$(mktemp -d)
    rm -rf "$missing_lib"
    _ASUS_LIB_DIR="$missing_lib"
    # Same-shell call so kcov attributes bootstrap error lines (not _exercise).
    _soft _source_common_helper >/dev/null 2>&1
    _restore_asus_lib_dir "$had_lib_dir" "${saved_lib_dir-}"
}

_run_source_common_failure_path() {
    # File exists but sourcing fails → bootstrap error lines after the existence check.
    local tmp saved_lib_dir had_lib_dir=0
    if [ -n "${_ASUS_LIB_DIR+set}" ]; then
        saved_lib_dir="$_ASUS_LIB_DIR"
        had_lib_dir=1
    fi
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    printf 'return 1\n' > "$tmp/asus-common.sh"
    _ASUS_LIB_DIR="$tmp"
    _soft _source_common_helper >/dev/null 2>&1
    _restore_asus_lib_dir "$had_lib_dir" "${saved_lib_dir-}"
    trap - RETURN
    rm -rf "$tmp"
}

_run_missing_session_helper_path() {
    # Cover asus-common.sh early return when asus-session.sh is absent.
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    _exercise ASUS_COMMON_DIR="$tmp" bash -c ". '$REPO_ROOT/lib/asus-common.sh'" >/dev/null 2>&1
    trap - RETURN
    rm -rf "$tmp"
}

_run_missing_notif_icons_helper_path() {
    # Cover asus-common.sh early return when asus-notif-icons.sh is absent.
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    cp "$REPO_ROOT/lib/asus-session.sh" "$tmp/asus-session.sh"
    cp "$REPO_ROOT/lib/asus-i18n.sh" "$tmp/asus-i18n.sh"
    _exercise ASUS_COMMON_DIR="$tmp" bash -c ". '$REPO_ROOT/lib/asus-common.sh'" >/dev/null 2>&1
    trap - RETURN
    rm -rf "$tmp"
}

_run_common_near_miss_paths() {
    local -a env_out=()
    local uid bus_root
    uid="$(id -u)"
    bus_root="${BUS_ROOT:-${KCOV_BUS_ROOT:-/run/user}}"
    # Usage-when-executed path (source-only guard).
    _soft bash "$REPO_ROOT/lib/asus-common.sh" >/dev/null 2>&1
    # Invalid ASUS_LAUNCH_CHECK_SECS → sleep 1 fallback inside _check_launch_process.
    ASUS_LAUNCH_CHECK_SECS=bad _soft _check_launch_process "$$" "kcov-launch" >/dev/null
    # Session env out-array fill (same-shell for kcov attribution).
    _soft _asus_session_launch_env env_out "$(id -un)" "$uid" \
        "$bus_root" "unix:path=$bus_root/$uid/bus" >/dev/null
    _soft test "${#env_out[@]}" -gt 0
}

_try_first_notif_empty_bus() {
    local empty_bus="$1"
    (
        BUS_ROOT="$empty_bus" DBUS_BUS_ROOT="$empty_bus" RUN_USER_ROOT="$empty_bus" \
            _first_notif_bus_user >/dev/null
    )
}

_run_common_bootstrap_near_misses() {
    local empty_bus
    # Bootstrap error paths before _exercise-heavy notify work (kcov attribution).
    _run_missing_common_path
    _run_source_common_failure_path
    # Tiny same-shell near-misses for the last few common.sh lines.
    _soft _check_node "/nonexistent-kcov-node-$$" >/dev/null
    mkdir -p "$BUS_ROOT/not-a-uid"
    _soft _notif_user_from_bus_entry "$BUS_ROOT/not-a-uid" >/dev/null
    empty_bus=$(mktemp -d)
    _soft _try_first_notif_empty_bus "$empty_bus"
    rm -rf "$empty_bus"
}

_run_common_kcov_exercises() {
    _run_common_bootstrap_near_misses
    _run_common_near_miss_paths
    _run_notif_icon_paths
    _run_common_notify_paths
    _run_missing_session_helper_path
    _run_missing_notif_icons_helper_path
}

_setup_common_bus_root
mkdir -p "$BUS_ROOT/$(id -u)"
_ensure_common_bus_socket

# shellcheck source=lib/asus-bootstrap.sh
_driver_source_required "$REPO_ROOT/lib/asus-bootstrap.sh" common_helpers
_source_common_or_die
_run_common_kcov_exercises
