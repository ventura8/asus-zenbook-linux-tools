#!/usr/bin/env bash
# Shared product file lists for install deploy + uninstall remove_installed_files.
# Callers must set BIN_DIR / LIB_DIR / SYS_DIR / HOOK_DIR / PREFIX as needed.
# Remove helpers take a nameref out-param named `_failed_ref` (reserved name:
# pass the caller's failure flag variable; do not shadow `_failed_ref` elsewhere).

_asus_manifest_bin_basenames() {
    printf '%s\n' \
        asus-hotkey-daemon.py \
        asus-touchpad-share.py \
        asus_touchpad_share.py \
        asus_touchpad_share_bounds.py \
        asus_hotkey_daemon.py \
        asus_hotkey_daemon_impl.py \
        asus_hotkey_daemon_input.py \
        asus_hotkey_daemon_brightness.py \
        asus_hotkey_daemon_at_proxy.py \
        asus_hotkey_daemon_osd.py \
        asus_hotkey_daemon_monitor.py \
        asus_hotkey_daemon_runtime.py \
        asus_hotkey_daemon_session.py \
        asus_hotkey_daemon_topology_detect.py \
        asus_hotkey_daemon_desktop_family.py \
        asus_hotkey_daemon_topology.py \
        asus_hotkey_daemon_threading.py \
        asus_hotkey_daemon_window_move.py \
        asus_hotkey_daemon_window_swap_gnome.py \
        asus_hotkey_daemon_window_swap.py \
        asus_hotkey_daemon_xrandr.py \
        asus_hotkey_daemon_state.py \
        asus_common.py \
        asus_i18n.py \
        shared_imports.py \
        asus-screenshot.sh \
        asus-sound-fix.sh \
        asus_hda_verb.py \
        asus-control-center.sh \
        asus-screenpad-toggle.sh \
        asus-screenpad-brightness.sh \
        asus-fan-toggle.sh \
        asus-camera-toggle.sh \
        asus-display-mode.sh \
        asus_display_mode.py \
        asus_display_mode_core.py \
        asus_display_mode_layout.py \
        asus_display_mode_profiles.py
}

_asus_manifest_wmi_src_relpaths() {
    # Checkout-relative paths copied into BIN_DIR by deploy_wmi_component.
    printf '%s\n' \
        bin/asus-hotkey-daemon.py \
        bin/asus_hotkey_daemon.py \
        bin/asus_hotkey_daemon_impl.py \
        bin/asus_hotkey_daemon_input.py \
        bin/asus_hotkey_daemon_brightness.py \
        bin/asus_hotkey_daemon_at_proxy.py \
        bin/asus_hotkey_daemon_osd.py \
        bin/asus_hotkey_daemon_monitor.py \
        bin/asus_hotkey_daemon_runtime.py \
        bin/asus_hotkey_daemon_session.py \
        bin/asus_hotkey_daemon_topology_detect.py \
        bin/asus_hotkey_daemon_desktop_family.py \
        bin/asus_hotkey_daemon_topology.py \
        bin/asus_hotkey_daemon_threading.py \
        bin/asus_hotkey_daemon_window_move.py \
        bin/asus_hotkey_daemon_window_swap_gnome.py \
        bin/asus_hotkey_daemon_window_swap.py \
        bin/asus_hotkey_daemon_xrandr.py \
        bin/asus_hotkey_daemon_state.py \
        bin/asus_common.py \
        bin/asus_i18n.py \
        shared_imports.py \
        bin/asus-screenshot.sh \
        bin/asus-control-center.sh \
        bin/asus-screenpad-toggle.sh \
        bin/asus-screenpad-brightness.sh \
        bin/asus-fan-toggle.sh \
        bin/asus-camera-toggle.sh \
        bin/asus-display-mode.sh \
        bin/asus_display_mode.py \
        bin/asus_display_mode_core.py \
        bin/asus_display_mode_layout.py \
        bin/asus_display_mode_profiles.py
}

_asus_manifest_wmi_chmod_relpaths() {
    # Executable entrypoints only (import-only modules stay non-exec after copy).
    printf '%s\n' \
        bin/asus-hotkey-daemon.py \
        bin/asus-screenshot.sh \
        bin/asus-control-center.sh \
        bin/asus-screenpad-toggle.sh \
        bin/asus-screenpad-brightness.sh \
        bin/asus-fan-toggle.sh \
        bin/asus-camera-toggle.sh \
        bin/asus-display-mode.sh
}

_asus_manifest_lib_basenames() {
    printf '%s\n' \
        asus-session.sh \
        asus-i18n.sh \
        asus-common.sh \
        asus-notif-icons.sh \
        asus-bootstrap.sh \
        asus-display-mutter.sh \
        asus-display-state.sh \
        asus-display-watchdog.sh \
        asus-display-osd.sh \
        asus-screenpad.sh
}

_asus_manifest_sys_unit_basenames() {
    printf '%s\n' \
        asus-hotkey-daemon.service \
        asus-touchpad-share.service \
        asus-sound-fix.service
}

_asus_manifest_desktop_basenames() {
    printf '%s\n' \
        asus-display-mode.desktop \
        asus-control-center.desktop \
        asus-screenshot.desktop
}

_asus_manifest_icon_basenames() {
    printf '%s\n' \
        asus-screenpad-toggle-symbolic.svg \
        asus-screenpad-on-symbolic.svg \
        asus-camera-toggle-symbolic.svg \
        asus-camera-on-symbolic.svg \
        asus-screenpad-toggle.svg \
        asus-screenpad-on.svg \
        asus-screenpad-toggle.png \
        asus-screenpad-on.png
}

_asus_manifest_share_root() {
    printf '%s\n' "${PREFIX:-}/usr/local/share"
}

_asus_remove_manifest_bin_files() {
    local -n _failed_ref="$1"
    local name
    [ -n "${BIN_DIR:-}" ] || return 0
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        rm -f "$BIN_DIR/$name" || _failed_ref=1
    done < <(_asus_manifest_bin_basenames)
}

_asus_remove_manifest_lib_files() {
    local -n _failed_ref="$1"
    local name
    [ -n "${LIB_DIR:-}" ] || return 0
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        rm -f "$LIB_DIR/$name" || _failed_ref=1
    done < <(_asus_manifest_lib_basenames)
}

_asus_nullglob_push() {
    if shopt -q nullglob; then
        _ASUS_NULLGLOB_SAVED=1
    else
        _ASUS_NULLGLOB_SAVED=0
        shopt -s nullglob
    fi
}

_asus_nullglob_pop() {
    if [ "${_ASUS_NULLGLOB_SAVED:-1}" -eq 0 ]; then
        shopt -u nullglob
    fi
    unset _ASUS_NULLGLOB_SAVED
}

_asus_remove_legacy_lib_install_helpers() {
    # Older installs may have copied installer helpers into LIB_DIR; remove leftovers.
    local -n _failed_ref="$1"
    local path
    [ -d "${LIB_DIR:-}" ] || return 0
    _asus_nullglob_push
    for path in "$LIB_DIR"/install-*.sh; do
        rm -f "$path" || _failed_ref=1
    done
    _asus_nullglob_pop
}

_asus_remove_manifest_sys_files() {
    local -n _failed_ref="$1"
    local name
    [ -n "${SYS_DIR:-}" ] || return 0
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        rm -f "$SYS_DIR/$name" || _failed_ref=1
    done < <(_asus_manifest_sys_unit_basenames)
}

_asus_remove_manifest_locale_files() {
    local -n _failed_ref="$1"
    local share="$2" catalog
    _asus_nullglob_push
    for catalog in "$share"/locale/*/LC_MESSAGES/asus-zenbook-linux-tools.mo; do
        rm -f "$catalog" || _failed_ref=1
    done
    _asus_nullglob_pop
}

_asus_remove_manifest_desktop_files() {
    local -n _failed_ref="$1"
    local share="$2" name
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        rm -f "$share/applications/$name" || _failed_ref=1
    done < <(_asus_manifest_desktop_basenames)
}

_asus_remove_one_manifest_icon() {
    local -n _failed_ref="$1"
    local share="$2" name="$3"
    case "$name" in
        *.png)
            rm -f "$share/icons/hicolor/48x48/apps/$name" || _failed_ref=1
            ;;
        *)
            rm -f "$share/icons/hicolor/scalable/apps/$name" || _failed_ref=1
            ;;
    esac
    rm -f "$share/asus-zenbook-linux-tools/icons/$name" || _failed_ref=1
}

_asus_remove_manifest_icon_files() {
    local -n _failed_ref="$1"
    local share="$2" name
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        _asus_remove_one_manifest_icon "$1" "$share" "$name"
    done < <(_asus_manifest_icon_basenames)
}

_asus_remove_manifest_share_files() {
    local -n _failed_ref="$1"
    local share
    share=$(_asus_manifest_share_root)
    _asus_remove_manifest_desktop_files "$1" "$share"
    _asus_remove_manifest_icon_files "$1" "$share"
    _asus_remove_manifest_locale_files "$1" "$share"
}
