#!/usr/bin/env bash
# Shared notification icon helpers: app-name color + SVG tinting + theme probes.
# Requires asus-common.sh sourced first (_run_as_user, _soft, notifications).

_notif_gsettings_value() {
    local schema="$1" key="$2" user value
    user=$(_resolve_notif_target_user 2>/dev/null || true)
    [ -n "$user" ] || return 1
    value=$(_run_as_user "$user" gsettings get "$schema" "$key" 2>/dev/null) || return 1
    value="${value#\'}"
    value="${value%\'}"
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

_notif_shell_css_candidates() {
    local theme scheme
    theme=$(_soft _notif_gsettings_value org.gnome.desktop.interface gtk-theme)
    scheme=$(_soft _notif_gsettings_value org.gnome.desktop.interface color-scheme)
    if [ -n "$theme" ]; then
        printf '%s\n' \
            "/usr/share/gnome-shell/theme/$theme/gnome-shell.css" \
            "/usr/share/themes/$theme/gnome-shell/gnome-shell.css"
    fi
    if [ "$scheme" = "prefer-dark" ] || [[ "$theme" == *-dark ]]; then
        printf '%s\n' \
            "/usr/share/gnome-shell/theme/Yaru-dark/gnome-shell.css" \
            "/usr/share/themes/Yaru-dark/gnome-shell/gnome-shell.css"
    fi
    printf '%s\n' \
        "/usr/share/gnome-shell/theme/Yaru/gnome-shell.css" \
        "/usr/share/themes/Yaru/gnome-shell/gnome-shell.css"
}

_css_line_message_header_starts() {
    local pattern='\.message[[:space:]]+\.message-header[[:space:]]*\{'
    [[ "$1" =~ $pattern ]]
}

_css_line_color() {
    local line="$1"
    [[ "$line" =~ (^|[[:space:]])color:[[:space:]]*(#[0-9A-Fa-f]+) ]] || return 1
    printf '%s\n' "${BASH_REMATCH[2]}"
}

_css_message_header_color_from_line() {
    local line="$1" in_header="$2"
    [ "$in_header" -eq 1 ] || return 1
    _css_line_color "$line"
}

_css_message_header_state_before() {
    local line="$1" state="$2"
    if _css_line_message_header_starts "$line"; then
        printf '1\n'
        return 0
    fi
    printf '%s\n' "$state"
}

_css_message_header_state_after() {
    local line="$1" state="$2"
    if [[ "$line" == *"}"* ]]; then
        printf '0\n'
        return 0
    fi
    printf '%s\n' "$state"
}

_extract_css_message_header_color() {
    # Emitting-app name uses .message-header color (message-source-title inherits it).
    local css_file="$1" line color in_header=0
    local -a lines
    [ -f "$css_file" ] || return 1
    mapfile -t lines < "$css_file" || return 1
    for line in "${lines[@]}"; do
        in_header=$(_css_message_header_state_before "$line" "$in_header")
        if color=$(_css_message_header_color_from_line "$line" "$in_header"); then
            printf '%s\n' "$color"
            return 0
        fi
        in_header=$(_css_message_header_state_after "$line" "$in_header")
    done
    return 1
}

_is_valid_notif_color() {
    # Accept #RGB / #RGBA / #RRGGBB / #RRGGBBAA only (not length 5 or 7).
    local color="$1" hex
    [[ "$color" =~ ^#[0-9A-Fa-f]+$ ]] || return 1
    hex="${color#\#}"
    case "${#hex}" in
        3|4|6|8) return 0 ;;
        *) return 1 ;;
    esac
}

_notif_override_app_name_color() {
    local color="${ASUS_NOTIF_APP_NAME_COLOR:-}"
    [ -n "$color" ] || color="${ASUS_SCREENPAD_APP_NAME_COLOR:-}"
    [ -n "$color" ] || color="${ASUS_CAMERA_APP_NAME_COLOR:-}"
    _is_valid_notif_color "$color" || return 1
    printf '%s\n' "$color"
}

_notif_css_app_name_color() {
    local color css_file
    while IFS= read -r css_file; do
        [ -n "$css_file" ] || continue
        color=$(_extract_css_message_header_color "$css_file") || true
        if _is_valid_notif_color "$color"; then
            printf '%s\n' "$color"
            return 0
        fi
    done < <(_notif_shell_css_candidates)
    return 1
}

_notification_app_name_color() {
    _notif_override_app_name_color || _notif_css_app_name_color
}

_TINT_SVG_TMP=""

_prepare_tint_svg_temp() {
    local src="$1" dest="$2" color="$3"
    _is_valid_notif_color "$color" || return 1
    [ -f "$src" ] || return 1
    _TINT_SVG_TMP=$(mktemp "${dest}.XXXXXX") || return 1
}

_render_tinted_svg() {
    local src="$1" tmp="$2" color="$3"
    if ! sed -e "s/stroke=\"[^\"]*\"/stroke=\"$color\"/g" "$src" >"$tmp" \
        || [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        return 1
    fi
}

_tint_svg_stroke() {
    local src="$1" dest="$2" color="$3" tmp
    _prepare_tint_svg_temp "$src" "$dest" "$color" || return 1
    tmp="$_TINT_SVG_TMP"
    _render_tinted_svg "$src" "$tmp" "$color" || return 1
    if ! chmod a+r "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$dest"
}

_notif_tinted_icon_path() {
    local stem="$1" user_id
    user_id=$(id -u "$(_resolve_notif_target_user 2>/dev/null || true)" 2>/dev/null || true)
    [ -n "$user_id" ] || user_id="0"
    printf '%s/%s/%s.svg\n' "${NOTIF_ID_ROOT:-/run/asus-zenbook-notif}" "$user_id" "$stem"
}

_theme_icon_svg_candidates() {
    local name="$1"
    local root="${ASUS_ICON_THEME_ROOT:-/usr/share/icons}"
    printf '%s\n' \
        "$root/Adwaita/symbolic/status/${name}.svg" \
        "$root/Adwaita/symbolic/devices/${name}.svg" \
        "$root/Adwaita/scalable/status/${name}.svg" \
        "$root/Adwaita/scalable/devices/${name}.svg" \
        "$root/Yaru/scalable/status/${name}.svg" \
        "$root/Yaru/scalable/devices/${name}.svg" \
        "$root/hicolor/scalable/status/${name}.svg" \
        "$root/hicolor/scalable/apps/${name}.svg"
}

_theme_icon_exists() {
    local name="$1" candidate
    while IFS= read -r candidate; do
        [ -n "$candidate" ] && [ -f "$candidate" ] && return 0
    done < <(_theme_icon_svg_candidates "$name")
    return 1
}

_resolve_tinted_template_icon() {
    # Tint template SVG to message-header (app name) color; return file path.
    local template="$1" stem="$2" fallback="$3" color dest parent
    [ -f "$template" ] || {
        printf '%s\n' "$fallback"
        return 0
    }
    color=$(_notification_app_name_color) || {
        printf '%s\n' "$fallback"
        return 0
    }
    dest=$(_notif_tinted_icon_path "$stem")
    parent=$(dirname "$dest")
    _soft mkdir -p "$parent"
    if _tint_svg_stroke "$template" "$dest" "$color"; then
        printf '%s\n' "$dest"
        return 0
    fi
    printf '%s\n' "$fallback"
}
