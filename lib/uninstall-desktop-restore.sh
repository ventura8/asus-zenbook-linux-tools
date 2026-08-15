#!/usr/bin/env bash
# Desktop shortcut restore helpers for uninstall.sh (kde/xfce/lxqt/cinnamon/mate).

_restore_desktop_shortcuts_generic() {
    local label="$1" lib="$2" restore_fn="$3" target_user="$4" config_dir="$5"
    local kde_cleanup="${6:-0}"
    if [ ! -f "$lib" ]; then
        echo "Missing installer ${label} helper: $lib" >&2
        return 1
    fi
    _source_desktop_restore_lib "$lib" || return 1
    if "$restore_fn" "$target_user" "$config_dir"; then
        _cleanup_kde_restore_dir "$kde_cleanup" "$config_dir" || return 1
        return 0
    fi
    echo "Warning: failed to fully restore ${label} shortcuts; preserving backup directory for recovery." >&2
    return 1
}

_source_desktop_restore_lib() {
    local lib="$1"
    case "$lib" in
        */install-kde.sh)
            # shellcheck source=lib/install-kde.sh
            source "$lib"
            ;;
        */install-xfce.sh)
            # shellcheck source=lib/install-xfce.sh
            source "$lib"
            ;;
        */install-lxqt.sh)
            # shellcheck source=lib/install-lxqt.sh
            source "$lib"
            ;;
        *) _source_desktop_restore_lib_secondary "$lib" ;;
    esac
}

_source_desktop_restore_lib_secondary() {
    local lib="$1"
    case "$lib" in
        */install-cinnamon.sh)
            # shellcheck source=lib/install-cinnamon.sh
            source "$lib"
            ;;
        */install-mate.sh)
            # shellcheck source=lib/install-mate.sh
            source "$lib"
            ;;
        *)
            echo "Unknown desktop restore helper: $lib" >&2
            return 1
            ;;
    esac
}

_cleanup_kde_restore_dir() {
    local kde_cleanup="$1" config_dir="$2"
    if [ "$kde_cleanup" = "1" ]; then
        _is_safe_config_dir "$config_dir" || return 1
        rm -rf "$config_dir"
    fi
}

_restore_kde_desktop_shortcuts() {
    local target_user="$1" config_dir="$2"
    _restore_desktop_shortcuts_generic "KDE" "$SCRIPT_DIR/lib/install-kde.sh" \
        restore_kde_shortcuts "$target_user" "$config_dir" 1
}

_restore_xfce_desktop_shortcuts() {
    local target_user="$1" config_dir="$2"
    _restore_desktop_shortcuts_generic "XFCE" "$SCRIPT_DIR/lib/install-xfce.sh" \
        restore_xfce_shortcuts "$target_user" "$config_dir" 0
}

_restore_lxqt_desktop_shortcuts() {
    local target_user="$1" config_dir="$2"
    _restore_desktop_shortcuts_generic "LXQt" "$SCRIPT_DIR/lib/install-lxqt.sh" \
        restore_lxqt_shortcuts "$target_user" "$config_dir" 0
}

_restore_cinnamon_desktop_shortcuts() {
    local target_user="$1" config_dir="$2"
    _restore_desktop_shortcuts_generic "Cinnamon" "$SCRIPT_DIR/lib/install-cinnamon.sh" \
        restore_cinnamon_shortcuts "$target_user" "$config_dir" 0
}

_restore_mate_desktop_shortcuts() {
    local target_user="$1" config_dir="$2"
    _restore_desktop_shortcuts_generic "MATE" "$SCRIPT_DIR/lib/install-mate.sh" \
        restore_mate_shortcuts "$target_user" "$config_dir" 0
}

declare -gA _DESKTOP_RESTORE_FN_BY_FAMILY=(
    [kde]=_restore_kde_desktop_shortcuts
    [xfce]=_restore_xfce_desktop_shortcuts
    [lxqt]=_restore_lxqt_desktop_shortcuts
    [cinnamon]=_restore_cinnamon_desktop_shortcuts
    [mate]=_restore_mate_desktop_shortcuts
)

_restore_by_desktop_family() {
    local family="$1" target_user="$2" user_id="$3" config_dir="$4" restore_fn=""
    if [ -n "$family" ]; then
        restore_fn="${_DESKTOP_RESTORE_FN_BY_FAMILY[$family]-}"
    fi
    if [ -n "$restore_fn" ]; then
        "$restore_fn" "$target_user" "$config_dir"
        return $?
    fi
    if [ "$family" != gnome ] && [ -n "$family" ]; then
        echo "Warning: Unknown desktop_family '$family'; attempting GNOME restore." >&2
    fi
    restore_gnome_shortcuts "$target_user" "$user_id"
}
