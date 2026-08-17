#!/usr/bin/env bash
# Interactive ncurses component checklist for install.sh (sibling of install-selection.sh).

_ASUS_SELECTION_TUI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ASUS_TUI_DEFAULT_ACCENT_RGB="53 132 228"

_tui_selection_title() {
    _asus_gettextf "ASUS ZenBook Linux Setup %s" "$(_format_display_version)"
    echo
}

_tui_wrap_text() {
    local width="$1" text="$2"
    if command -v fold >/dev/null 2>&1; then
        printf '%s\n' "$text" | fold -s -w "$width" | sed 's/[[:blank:]]*$//'
        return 0
    fi
    printf '%s\n' "$text"
}

_tui_selection_message() {
    local wrap_width="${1:-68}"
    local keys
    # Component details live under each checklist row; keep the header short.
    keys=$(_asus_gettext "Space selects a component. Enter confirms. Esc cancels.")
    _tui_wrap_text "$wrap_width" "$keys"
}

_tui_python_bin() {
    command -v python3 2>/dev/null || return 1
}

_tui_try_module_candidate() {
    local candidate="$1"
    [ -f "$candidate" ] || return 1
    printf '%s' "$candidate"
}

_tui_module_path() {
    _tui_try_module_candidate "${SCRIPT_DIR:-}/bin/asus_install_selection_tui.py" && return 0
    _tui_try_module_candidate "${INSTALL_SOURCE_DIR:-}/bin/asus_install_selection_tui.py" && return 0
    _tui_try_module_candidate "${_ASUS_SELECTION_TUI_DIR}/../bin/asus_install_selection_tui.py"
}

_tui_desktop_family_hint() {
    local family="${ASUS_DESKTOP_FAMILY:-}"
    if [ -n "$family" ]; then
        printf '%s' "$family"
        return 0
    fi
    if command -v asus_desktop_family >/dev/null 2>&1; then
        asus_desktop_family 2>/dev/null || true
    fi
}

_tui_query_python_accent() {
    local py="$1" mod="$2" family="$3"
    PYTHONPATH="$(dirname "$mod"):${PYTHONPATH:-}" \
        ASUS_DESKTOP_FAMILY="$family" \
        "$py" -c \
        'from asus_install_selection_accent import format_accent_rgb, resolve_accent_rgb; import os; print(format_accent_rgb(resolve_accent_rgb(prefer_family=os.environ.get("ASUS_DESKTOP_FAMILY",""))))' \
        2>/dev/null || true
}

_tui_resolve_accent_rgb() {
    local py mod rgb family
    if [ -n "${ASUS_TUI_ACCENT_RGB:-}" ]; then
        printf '%s' "$ASUS_TUI_ACCENT_RGB"
        return 0
    fi
    py=$(_tui_python_bin) || {
        printf '%s' "$_ASUS_TUI_DEFAULT_ACCENT_RGB"
        return 0
    }
    mod=$(_tui_module_path) || {
        printf '%s' "$_ASUS_TUI_DEFAULT_ACCENT_RGB"
        return 0
    }
    family="$(_tui_desktop_family_hint)"
    rgb="$(_tui_query_python_accent "$py" "$mod" "$family")"
    printf '%s' "${rgb:-$_ASUS_TUI_DEFAULT_ACCENT_RGB}"
}

_desktop_default_on() {
    if _desktop_family_supports_desktop_component; then
        echo "ON"
    else
        echo "OFF"
    fi
}

_tui_desktop_cli_flag() {
    if [ "$(_desktop_default_on)" = "ON" ]; then
        printf '%s\n' --desktop-on
    fi
}

_run_tui_selection() {
    local ui_in_fd="$1"
    local ui_out_fd="$2"
    local choice_tmp="$3"
    local py mod title message rgb
    local -a desktop_flag=()
    local status=0

    py=$(_tui_python_bin) || return 2
    mod=$(_tui_module_path) || return 2
    title="$(_tui_selection_title)"
    message="$(_tui_selection_message 68)"
    rgb="$(_tui_resolve_accent_rgb)"
    mapfile -t desktop_flag < <(_tui_desktop_cli_flag)
    ASUS_TUI_ACCENT_RGB="$rgb" \
        ASUS_DISPLAY_VERSION="$(_format_display_version)" \
        PYTHONPATH="$(dirname "$mod"):${PYTHONPATH:-}" \
        "$py" "$mod" \
        --title "$title" \
        --message "$message" \
        --output "$choice_tmp" \
        "${desktop_flag[@]+"${desktop_flag[@]}"}" \
        <&"$ui_in_fd" >&"$ui_out_fd" 2>&"$ui_out_fd" || status=$?
    return "$status"
}

_apply_tui_selection() {
    local choice_tmp="$1"
    local ui_out_fd="$2"
    local raw_selection parsed normalize_status

    raw_selection=$(tr '\n' ',' <"$choice_tmp")
    parsed=$(_normalize_component_selection "$raw_selection") || {
        normalize_status=$?
        rm -f "$choice_tmp"
        return "$normalize_status"
    }
    rm -f "$choice_tmp"
    export INSTALL_CHOICE="$parsed"
    return 0
}

_handle_tui_selection_error() {
    local tui_rc="$1"
    local ui_out_fd="$2"
    local choice_tmp="$3"

    rm -f "$choice_tmp"
    if [ "$tui_rc" -eq 1 ]; then
        _asus_gettext "Installation cancelled by user." >&"$ui_out_fd"
        echo >&"$ui_out_fd"
        return 1
    fi
    return 2
}

_prompt_tui_selection_prepare() {
    local -n _choice_ref="$1"
    _tui_python_bin >/dev/null || return 2
    _tui_module_path >/dev/null || return 2
    _choice_ref=$(mktemp) || return 1
    [ -n "$_choice_ref" ] || return 1
    return 0
}

_prompt_tui_selection() {
    local ui_in_fd="$1"
    local ui_out_fd="$2"
    local choice_tmp tui_rc

    _prompt_tui_selection_prepare choice_tmp || return $?
    if _run_tui_selection "$ui_in_fd" "$ui_out_fd" "$choice_tmp"; then
        _apply_tui_selection "$choice_tmp" "$ui_out_fd"
        return $?
    fi
    tui_rc=$?
    _handle_tui_selection_error "$tui_rc" "$ui_out_fd" "$choice_tmp"
}
