#!/usr/bin/env bash
# GNOME configuration helper for install.sh
# Extracted to maintain modularity and line limits

# Parse/emit gsettings "as" arrays via GLib.Variant (no string scratch parsers).
_gsettings_python3_with_gi() {
    # Prefer PATH python3 when it has gi; else fall back to /usr/bin/python3
    # (Poetry venvs often shadow system python3 without PyGObject).
    local candidate
    for candidate in "$(command -v python3 2>/dev/null || true)" /usr/bin/python3; do
        [ -n "$candidate" ] && [ -x "$candidate" ] || continue
        if "$candidate" -c 'import gi' >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

_gsettings_as_array_op() {
    local op="$1" current="$2" py
    shift 2
    py=$(_gsettings_python3_with_gi) || {
        echo "GLib.Variant unavailable: no python3 with gi (install python3-gi / python3-gobject)" >&2
        return 1
    }
    "$py" - "$op" "$current" "$@" <<'PY'
import sys

try:
    import gi

    gi.require_version("GLib", "2.0")
    from gi.repository import GLib
except (ImportError, ValueError) as exc:
    print(f"GLib.Variant unavailable: {exc}", file=sys.stderr)
    sys.exit(1)


def _parse_as(text: str) -> list[str]:
    raw = (text or "").strip()
    if not raw or raw in ("[]", "@as []"):
        return []
    if not raw.startswith("@as "):
        raw = f"@as {raw}"
    try:
        variant = GLib.Variant.parse(None, raw, None, None)
    except (TypeError, ValueError, GLib.Error):
        raise SystemExit(f"unparsable gsettings 'as' value: {text!r}")
    if not variant.is_of_type(GLib.VariantType("as")):
        raise SystemExit(f"gsettings value is not of type 'as': {text!r}")
    return list(variant)


def _format_as(items: list[str]) -> str:
    if not items:
        return "[]"
    return str(GLib.Variant("as", items))


def main() -> int:
    if len(sys.argv) < 3:
        return 1
    op = sys.argv[1]
    items = _parse_as(sys.argv[2])
    args = sys.argv[3:]
    if op == "merge":
        for path in args:
            if path and path not in items:
                items.append(path)
    elif op == "drop":
        drop = set(args)
        items = [entry for entry in items if entry not in drop]
    else:
        return 1
    print(_format_as(items))
    return 0


raise SystemExit(main())
PY
}

_merge_custom_keybindings() {
    local current="$1"
    shift
    [ -n "$current" ] || current="[]"
    _gsettings_as_array_op merge "$current" "$@"
}

_ensure_keybinding_path() {
    local merged="$1" path="$2"
    _gsettings_as_array_op merge "$merged" "$path"
}

_drop_keybinding_path() {
    local merged="$1" path="$2"
    _gsettings_as_array_op drop "$merged" "$path"
}

_user_gsettings() {
    local user="$1" bus="$2"
    shift 2
    _run_as_user_on_session_bus "$user" "$bus" gsettings "$@"
}

_run_as_user_on_session_bus() {
    local user="$1" bus="$2" bus_addr runtime
    shift 2
    case "$bus" in
        unix:path=*)
            bus_addr="$bus"
            runtime="${bus#unix:path=}"
            runtime=$(dirname "$runtime")
            ;;
        *)
            bus_addr="unix:path=$bus"
            runtime=$(dirname "$bus")
            ;;
    esac
    _install_run_as_user "$user" env \
        DBUS_SESSION_BUS_ADDRESS="$bus_addr" \
        XDG_RUNTIME_DIR="$runtime" \
        "$@"
}

_gsettings_key_exists() {
    local user="$1" bus="$2" key_schema="$3" key_name="$4" keys
    # Capture then grep (no pipeline): grep -q closing early SIGPIPEs list-keys under pipefail.
    keys=$(_user_gsettings "$user" "$bus" list-keys "$key_schema" 2>/dev/null) || return 1
    grep -Fxq -- "$key_name" <<<"$keys"
}

backup_gnome_keybinding() {
    local user="$1" bus="$2" key_schema="$3" key_name="$4" dest_file="$5"
    if [ -f "$dest_file" ]; then
        _read_existing_gnome_backup "$dest_file"
        return
    fi

    local val
    if val=$(_user_gsettings "$user" "$bus" get "$key_schema" "$key_name" 2>/dev/null); then
        if ! echo "$val" > "${dest_file}.tmp"; then
            echo "  ✗ Failed to write GNOME keybinding backup for $key_schema/$key_name." >&2
            return 1
        fi
        if ! mv "${dest_file}.tmp" "$dest_file"; then
            echo "  ✗ Failed to finalize GNOME keybinding backup for $key_schema/$key_name." >&2
            rm -f "${dest_file}.tmp"
            return 1
        fi
        echo "$val"
    fi
}

_read_existing_gnome_backup() {
    cat "$1" 2>/dev/null || return 0
}

_gsettings_set_key() {
    local user="$1" bus="$2" schema="$3" key="$4" value="$5"
    [ -n "$value" ] || {
        echo "  ✗ Refusing empty gsettings set for $schema/$key." >&2
        return 1
    }
    _user_gsettings "$user" "$bus" set "$schema" "$key" "$value"
}

_gsettings_restore_key() {
    local user="$1" bus="$2" schema="$3" key="$4" value="$5" label="$6"
    [ -n "$value" ] || return 0
    if _gsettings_set_key "$user" "$bus" "$schema" "$key" "$value"; then
        return 0
    fi
    echo "  ! Warning: failed to restore GNOME key $label ($schema/$key)." >&2
    return 1
}

_restore_optional_gsettings_value() {
    local user="$1" bus="$2" schema="$3" key="$4" value="$5"
    _gsettings_restore_key "$user" "$bus" "$schema" "$key" "$value" "$key"
}

_restore_custom_keybindings_file() {
    local user="$1" bus="$2" config_dir="$3"
    local orig_custom=""
    [ -f "$config_dir/orig_custom_keybindings" ] || return 0
    orig_custom=$(cat "$config_dir/orig_custom_keybindings" 2>/dev/null || true)
    [ -n "$orig_custom" ] || return 0
    _gsettings_restore_key "$user" "$bus" \
        "org.gnome.settings-daemon.plugins.media-keys" "custom-keybindings" "$orig_custom" \
        "custom-keybindings"
}

rollback_gnome_shortcuts() {
    local user="$1" bus="$2" config_dir="$3" orig_ss="$4" orig_ctrl="$5" orig_vm="$6" orig_sm="$7"
    local failed=0
    _gsettings_restore_key "$user" "$bus" \
        "org.gnome.shell.keybindings" "show-screenshot-ui" "$orig_ss" "show-screenshot-ui" || failed=1
    _gsettings_restore_key "$user" "$bus" \
        "org.gnome.settings-daemon.plugins.media-keys" "control-center" "$orig_ctrl" "control-center" || failed=1
    _rollback_gnome_optional_shortcuts "$user" "$bus" "$config_dir" \
        "$orig_vm" "$orig_sm" || failed=1
    return "$failed"
}

_rollback_gnome_optional_shortcuts() {
    local user="$1" bus="$2" config_dir="$3" orig_vm="$4" orig_sm="$5"
    local failed=0
    _gsettings_restore_key "$user" "$bus" \
        "org.gnome.settings-daemon.plugins.media-keys" "switch-video-mode" "$orig_vm" "switch-video-mode" || failed=1
    _restore_custom_keybindings_file "$user" "$bus" "$config_dir" || failed=1
    _gsettings_restore_key "$user" "$bus" \
        "org.gnome.mutter.keybindings" "switch-monitor" "$orig_sm" "switch-monitor" || failed=1
    return "$failed"
}

_gsettings_set_optional_path() {
    local user="$1" bus_addr="$2" schema="$3" key="$4" value="$5"
    _asus_soft _user_gsettings "$user" "$bus_addr" set "$schema" "$key" "$value"
}

_reset_native_display_binding() {
    local user="$1" bus_addr="$2"
    local bus_path="${bus_addr#unix:path=}"
    local schema

    if _gsettings_key_exists "$user" "$bus_path" "org.gnome.mutter.keybindings" "switch-monitor"; then
        _gsettings_set_optional_path "$user" "$bus_addr" \
            "org.gnome.mutter.keybindings" "switch-monitor" "['<Super>p']"
    fi

    if _gsettings_key_exists "$user" "$bus_path" "org.gnome.settings-daemon.plugins.media-keys" "switch-video-mode"; then
        _gsettings_set_optional_path "$user" "$bus_addr" \
            "org.gnome.settings-daemon.plugins.media-keys" "switch-video-mode" "[]"
    fi

    schema="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/asus-display-mode-superp/"
    _gsettings_set_optional_path "$user" "$bus_addr" "$schema" "binding" "''"
}

_set_custom_binding_slot() {
    local user="$1" bus_addr="$2" slot="$3" name="$4" cmd="$5" binding="$6"
    local schema="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/${slot}/"
    _user_gsettings "$user" "$bus_addr" set "$schema" name "$name" 2>/dev/null || return 1
    _user_gsettings "$user" "$bus_addr" set "$schema" command "$cmd" 2>/dev/null || return 1
    _user_gsettings "$user" "$bus_addr" set "$schema" binding "$binding" 2>/dev/null || return 1
}

_set_display_keybinding() {
    local user="$1" bus="$2"
    local bus_addr="unix:path=$bus" current merged
    _reset_native_display_binding "$user" "$bus_addr"
    current=$(_user_gsettings "$user" "$bus_addr" \
        get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null || echo "[]")
    merged=$(_merge_custom_keybindings "$current" \
        "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/asus-display-mode-xf86display/" \
        "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/myasus-1/" \
        "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/myasus-2/" \
        "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/myasus-3/" \
        "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/myasus-4/" \
        "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/myasus-5/" \
        "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/myasus-6/" \
        "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/myasus-7/")
    # Drop legacy F8 → display-mode binding so F8 stays stock.
    merged=$(_drop_keybinding_path "$merged" \
        "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/asus-display-mode-f8/")
    if [ -z "$merged" ]; then
        return 1
    fi
    _user_gsettings "$user" "$bus_addr" \
        set org.gnome.settings-daemon.plugins.media-keys custom-keybindings \
        "$merged" 2>/dev/null || return 1
    _set_display_binding_slots "$user" "$bus_addr"
}

_set_display_binding_slots() {
    local user="$1" bus_addr="$2"
    local f8_schema="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/asus-display-mode-f8/"
    _user_gsettings "$user" "$bus_addr" set "$f8_schema" binding "''" 2>/dev/null || true
    _set_custom_binding_slot "$user" "$bus_addr" "asus-display-mode-xf86display" \
        "$(_asus_gettext "ASUS Display Mode")" "/usr/local/bin/asus-display-mode.sh" "XF86Display" || return 1
}

_set_myasus_keybindings() {
    local user="$1" bus="$2"
    local bus_addr="unix:path=$bus"
    local keysyms=("XF86Launch1" "XF86Tools" "XF86Launch3" "XF86ControlCenter" "<Super>F12" "<Shift>F12" "<Ctrl>F12")
    local idx=1
    local failed=0
    local ks binding_name
    binding_name=$(_asus_gettext "ASUS ZenBook Settings")
    for ks in "${keysyms[@]}"; do
        _set_custom_binding_slot "$user" "$bus_addr" "myasus-$idx" \
            "$binding_name $idx" "/usr/local/bin/asus-control-center.sh" "$ks" \
            2>/dev/null || failed=$((failed + 1))
        idx=$((idx + 1))
    done
    if [ "$failed" -gt 0 ]; then
        echo "  ! Warning: failed to configure $failed MyASUS shortcut(s)." >&2
    fi
    return 0
}

_set_gnome_keybindings() {
    local user="$1" bus="$2"
    local err=0
    _gsettings_set_key "$user" "$bus" org.gnome.shell.keybindings show-screenshot-ui \
        "['Print', '<Super><Shift>s', '<Super><Shift>S']" || err=1

    _gsettings_set_key "$user" "$bus" org.gnome.settings-daemon.plugins.media-keys control-center \
        "['XF86Launch1', 'XF86Tools', 'XF86Launch2', 'XF86Launch3', 'XF86Launch4', 'XF86ControlCenter', 'XF86MyComputer', 'XF86Explorer', 'XF86VendorHome', 'XF86LaunchA']" || err=1

    _set_myasus_keybindings "$user" "$bus"
    _set_display_keybinding "$user" "$bus" || err=1
    return "$err"
}

apply_gnome_shortcuts() {
    local user="$1" bus="$2" orig_ss="$3" orig_ctrl="$4" orig_vm="$5" config_dir="$6" orig_sm="$7"
    if ! echo "$user" > "$config_dir/target_user.tmp"; then
        echo "  ✗ GNOME configuration failed: could not write target_user state." >&2
        return 1
    fi
    if ! mv "$config_dir/target_user.tmp" "$config_dir/target_user"; then
        echo "  ✗ GNOME configuration failed: could not finalize target_user state." >&2
        rm -f "$config_dir/target_user.tmp"
        return 1
    fi

    if _set_gnome_keybindings "$user" "$bus"; then
        printf '  ✓ %s\n' "$(_asus_gettext \
            "Shortcuts registered for Print/Super-Shift-s, XF86Launch1/XF86Tools, and XF86Display (F8 left unchanged).")"
        return 0
    fi

    rollback_gnome_shortcuts "$user" "$bus" "$config_dir" "$orig_ss" "$orig_ctrl" "$orig_vm" "$orig_sm"
    echo "  ✗ GNOME configuration failed: shortcut updates could not be applied." >&2
    return 1
}

_resolve_target_user_for_bus() {
    local target_user
    target_user=$(find_active_session_user 2>/dev/null || true)
    [ -z "$target_user" ] && target_user="${SUDO_USER:-}"
    [ -z "$target_user" ] && target_user=$(whoami 2>/dev/null || true)
    printf '%s\n' "$target_user"
}

_resolve_user_id_for_bus() {
    local target_user="$1"
    id -u "$target_user" 2>/dev/null || true
}

_resolve_bus_path_for_user() {
    local user_id="$1"
    printf '%s/%s/bus\n' "$(_install_resolve_session_bus_root)" "$user_id"
}

_has_bus_socket_for_user() {
    local user_id="$1" bus_path="$2"
    [ -n "$user_id" ] && [ -S "$bus_path" ]
}

_resolve_user_bus_info() {
    local target_user user_id bus_path
    target_user=$(_resolve_target_user_for_bus)
    user_id=$(_resolve_user_id_for_bus "$target_user")
    bus_path=$(_resolve_bus_path_for_user "$user_id")
    if _has_bus_socket_for_user "$user_id" "$bus_path"; then
        echo "$target_user:$user_id:$bus_path"
    fi
    return 0
}

_backup_optional_gnome_key() {
    local target_user="$1" bus_path="$2" schema="$3" key="$4" dest="$5"
    _gsettings_key_exists "$target_user" "$bus_path" "$schema" "$key" || return 0
    backup_gnome_keybinding "$target_user" "$bus_path" "$schema" "$key" "$dest"
}

_apply_gnome_config() {
    local target_user="$1" bus_path="$2" config_dir="$3"
    local orig_ss orig_ctrl orig_vm="" orig_sm=""
    orig_ss=$(backup_gnome_keybinding "$target_user" "$bus_path" "org.gnome.shell.keybindings" "show-screenshot-ui" "$config_dir/orig_show_screenshot_ui")
    orig_ctrl=$(backup_gnome_keybinding "$target_user" "$bus_path" "org.gnome.settings-daemon.plugins.media-keys" "control-center" "$config_dir/orig_control_center")
    orig_vm=$(_backup_optional_gnome_key "$target_user" "$bus_path" \
        "org.gnome.settings-daemon.plugins.media-keys" "switch-video-mode" "$config_dir/orig_switch_video_mode")
    orig_sm=$(_backup_optional_gnome_key "$target_user" "$bus_path" \
        "org.gnome.mutter.keybindings" "switch-monitor" "$config_dir/orig_switch_monitor")
    backup_gnome_keybinding "$target_user" "$bus_path" "org.gnome.settings-daemon.plugins.media-keys" "custom-keybindings" "$config_dir/orig_custom_keybindings" >/dev/null || true

    if [ -f "$config_dir/orig_show_screenshot_ui" ] && [ -f "$config_dir/orig_control_center" ]; then
        apply_gnome_shortcuts "$target_user" "$bus_path" "$orig_ss" "$orig_ctrl" "$orig_vm" "$config_dir" "$orig_sm"
        return $?
    fi

    echo "  ✗ GNOME configuration failed: required backup state was not available." >&2
    return 1
}

ASUS_GNOME_WINDOW_SWAP_UUID="asus-window-swap@ventura8.github.com"

_gnome_window_swap_extension_src() {
    local root="${INSTALL_SOURCE_DIR:-}"
    if [ -z "$root" ] && [ -n "${BASH_SOURCE[0]:-}" ]; then
        root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    fi
    printf '%s\n' "$root/gnome/$ASUS_GNOME_WINDOW_SWAP_UUID"
}

_gsettings_enabled_ext_add() {
    local current="$1" uuid="$2"
    _gsettings_as_array_op merge "$current" "$uuid"
}

_gsettings_enabled_ext_remove() {
    local current="$1" uuid="$2"
    _gsettings_as_array_op drop "$current" "$uuid"
}

_gnome_mark_extension_enabled() {
    local user="$1" bus="$2" uuid="$3" current next
    current=$(_user_gsettings "$user" "$bus" get org.gnome.shell enabled-extensions 2>/dev/null) || return 1
    next=$(_gsettings_enabled_ext_add "$current" "$uuid")
    [ -n "$next" ] || return 1
    [ "$next" = "$current" ] && return 0
    _user_gsettings "$user" "$bus" set org.gnome.shell enabled-extensions "$next"
}

_gnome_mark_extension_disabled() {
    local user="$1" bus="$2" uuid="$3" current next
    current=$(_user_gsettings "$user" "$bus" get org.gnome.shell enabled-extensions 2>/dev/null) || return 0
    next=$(_gsettings_enabled_ext_remove "$current" "$uuid")
    [ -n "$next" ] || return 0
    [ "$next" = "$current" ] && return 0
    _user_gsettings "$user" "$bus" set org.gnome.shell enabled-extensions "$next" || true
}

_gnome_disable_extension_cli() {
    local target_user="$1" bus="$2" uuid="$3"
    if [ -n "$bus" ]; then
        _asus_soft _run_as_user_on_session_bus "$target_user" "$bus" \
            gnome-extensions disable "$uuid"
        return 0
    fi
    _asus_soft _install_run_as_user "$target_user" gnome-extensions disable "$uuid"
}

_gnome_copy_window_swap_extension_files() {
    local target_user="$1" home_dir="$2" src="$3" uuid="$4"
    # Overwrite in place — never rm -rf an active dest. On Wayland, disable+rm
    # drops /AsusWindowSwap and Shell cannot ReloadExtension until logout.
    _install_run_as_user "$target_user" env HOME="$home_dir" bash -c '
        set -e
        src="$1"
        home="$2"
        uuid="$3"
        dest="$home/.local/share/gnome-shell/extensions/$uuid"
        mkdir -p "$dest"
        cp -a "$src/extension.js" "$src/metadata.json" "$dest/"
    ' _ "$src" "$home_dir" "$uuid"
}

_gnome_hint_wayland_extension_reload() {
    local target_user="$1"
    [ "$(asus_session_type "$target_user" 2>/dev/null || true)" = "wayland" ] || return 0
    echo "  → On Wayland, log out and back in before the extension is active in Shell."
}

_gnome_resolve_user_home() {
    local target_user="$1" home_dir
    home_dir=$(getent passwd "$target_user" | cut -d: -f6 || true)
    [ -n "$home_dir" ] || {
        echo "  ✗ Failed to resolve home directory for $target_user." >&2
        return 1
    }
    printf '%s\n' "$home_dir"
}

_gnome_enable_window_swap_extension() {
    local target_user="$1" bus="$2" uuid="$3"
    if ! _gnome_mark_extension_enabled "$target_user" "$bus" "$uuid"; then
        echo "  ✗ Failed to mark $uuid enabled in org.gnome.shell" >&2
        return 1
    fi
    # Global kill switch leaves extensions "enabled" but inactive (no D-Bus).
    _asus_soft _run_as_user_on_session_bus "$target_user" "$bus" \
        gsettings set org.gnome.shell disable-user-extensions false
    _asus_soft _run_as_user_on_session_bus "$target_user" "$bus" \
        gnome-extensions enable "$uuid"
}

_gnome_window_swap_extension_src_ok() {
    local src="$1"
    [ -f "$src/metadata.json" ] || return 1
    [ -f "$src/extension.js" ]
}

_install_gnome_window_swap_extension() {
    local target_user="$1" bus="$2" src uuid="$ASUS_GNOME_WINDOW_SWAP_UUID" home_dir
    src="$(_gnome_window_swap_extension_src)"
    _gnome_window_swap_extension_src_ok "$src" || return 1
    home_dir=$(_gnome_resolve_user_home "$target_user") || return 1
    # Do not gnome-extensions disable before copy on a live session: Wayland cannot
    # ReloadExtension, so disable drops ShowOsd until logout. In-place overwrite
    # keeps a loaded D-Bus export; new JS applies after the next login.
    _gnome_copy_window_swap_extension_files "$target_user" "$home_dir" "$src" \
        "$uuid" || return 1
    # Enable via the live session bus. Bare sudo -u has no DBUS_SESSION_BUS_ADDRESS,
    # so gnome-extensions falls back to dbus-launch (often missing) and dconf fails
    # while install still looks successful.
    _gnome_enable_window_swap_extension "$target_user" "$bus" "$uuid" || return 1
    printf '  ✓ %s\n' "$(_asus_gettext "GNOME ASUS Window Swap extension installed.")"
    _gnome_hint_wayland_extension_reload "$target_user"
}

remove_gnome_window_swap_extension() {
    local target_user="$1" bus="${2:-}" uuid="$ASUS_GNOME_WINDOW_SWAP_UUID" home_dir
    home_dir=$(_gnome_resolve_user_home "$target_user") || return 0
    if [ -n "$bus" ]; then
        _asus_soft _gnome_mark_extension_disabled "$target_user" "$bus" "$uuid"
    fi
    _gnome_disable_extension_cli "$target_user" "$bus" "$uuid"
    _asus_soft _install_run_as_user "$target_user" env HOME="$home_dir" bash -c '
        home="$1"
        uuid="$2"
        rm -rf "$home/.local/share/gnome-shell/extensions/$uuid"
    ' _ "$home_dir" "$uuid"
}

_gnome_write_desktop_family_state() {
    local config_dir="$1"
    if ! mkdir -p "$config_dir"; then
        echo "  ✗ GNOME configuration failed: could not create state directory." >&2
        return 1
    fi
    if ! printf 'gnome\n' > "$config_dir/desktop_family"; then
        echo "  ✗ GNOME configuration failed: could not write desktop_family state." >&2
        return 1
    fi
    return 0
}

configure_gnome_component() {
    local info target_user user_id bus_path
    info=$(_resolve_user_bus_info)
    if [ -z "$info" ]; then
        echo "  ✗ GNOME configuration failed: desktop D-Bus session not found." >&2
        return 1
    fi

    target_user=$(echo "$info" | cut -d: -f1)
    user_id=$(echo "$info" | cut -d: -f2)
    bus_path=$(echo "$info" | cut -d: -f3-)

    _install_print_next_step "$(_asus_gettextf "Configure GNOME shortcuts for %s" "$target_user")"
    local config_dir="${STATE_DIR}/${user_id}"
    _gnome_write_desktop_family_state "$config_dir" || return 1

    if ! _apply_gnome_config "$target_user" "$bus_path" "$config_dir"; then
        return 1
    fi
    _gnome_install_optional_window_swap "$target_user" "$bus_path"
    printf '  ✓ %s\n' "$(_asus_gettext "GNOME shortcuts configured.")"
    return 0
}

_gnome_install_optional_window_swap() {
    if ! _install_gnome_window_swap_extension "$1" "$2"; then
        echo "  ⚠ ASUS Window Swap GNOME extension not enabled (Wayland swap may need 2 presses)." >&2
    fi
}
