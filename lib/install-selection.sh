#!/usr/bin/env bash

# Side-effect output for install.sh after prompt_user_selection / noninteractive paths.
INSTALL_CHOICE="${INSTALL_CHOICE:-}"
export INSTALL_CHOICE

_trim_shell_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

_append_component_choice() {
    local parsed="$1"
    local component="$2"

    if [ -z "$parsed" ]; then
        printf '%s' "$component"
        return 0
    fi

    case " $parsed " in
        *" $component "*) printf '%s' "$parsed" ;;
        *) printf '%s %s' "$parsed" "$component" ;;
    esac
}

_is_valid_component_token() {
    local token="$1"
    case "$token" in
        1|2|3|4|WMI|TOUCHPAD|SOUND|GNOME|DESKTOP) return 0 ;;
        *) return 1 ;;
    esac
}

_resolve_desktop_family() {
    local family
    family="${ASUS_DESKTOP_FAMILY:-}"
    if [ -z "$family" ] && command -v asus_desktop_family >/dev/null 2>&1; then
        family=$(asus_desktop_family 2>/dev/null || true)
    fi
    printf '%s' "$family"
}

_desktop_family_supports_desktop_component() {
    case "$(_resolve_desktop_family)" in
        gnome|kde|xfce|lxqt|cinnamon|mate) return 0 ;;
        *) return 1 ;;
    esac
}

_default_all_components() {
    if _desktop_family_supports_desktop_component; then
        echo "WMI TOUCHPAD SOUND DESKTOP"
    else
        echo "WMI TOUCHPAD SOUND"
    fi
}

_normalize_component_selection() {
    local raw_input="$1"
    local normalized split_tokens token parsed=""
    local -a normalized_tokens=()

    normalized=$(printf '%s' "$raw_input" | tr '[:lower:]' '[:upper:]' | tr ';' ',')
    normalized=$(_trim_shell_whitespace "$normalized")
    if _print_special_component_selection "$normalized"; then
        return 0
    fi

    split_tokens=${normalized//,/ }
    read -r -a normalized_tokens <<< "$split_tokens"
    # Empty array under set -u: treat as empty selection (not unbound).
    if [ "${#normalized_tokens[@]}" -eq 0 ]; then
        echo ""
        return 0
    fi

    for token in "${normalized_tokens[@]+"${normalized_tokens[@]}"}"; do
        token="${token//\"/}"
        if ! _is_valid_component_token "$token"; then
            echo "Unknown component token: $token" >&2
            echo ""
            return 2
        fi
        parsed=$(_append_normalized_component_choice "$parsed" "$token")
    done

    _trim_shell_whitespace "$parsed"
}

_print_special_component_selection() {
    local normalized="$1"
    if [ -z "$normalized" ]; then
        echo ""
        return 0
    fi
    if [ "$normalized" = "ALL" ]; then
        _default_all_components
        return 0
    fi
    return 1
}

_append_normalized_component_choice() {
    local parsed="$1" token="$2"

    case "$token" in
        1|WMI) _append_component_choice "$parsed" "WMI" ;;
        2|TOUCHPAD) _append_component_choice "$parsed" "TOUCHPAD" ;;
        3|SOUND) _append_component_choice "$parsed" "SOUND" ;;
        4|GNOME|DESKTOP) _append_component_choice "$parsed" "DESKTOP" ;;
        *) printf '%s' "$parsed" ;;
    esac
}

_close_wizard_ui_fds() {
    if [ -n "${INSTALL_UI_IN_FD:-}" ]; then
        exec {INSTALL_UI_IN_FD}<&- || true
        INSTALL_UI_IN_FD=
    fi
    if [ -n "${INSTALL_UI_OUT_FD:-}" ]; then
        exec {INSTALL_UI_OUT_FD}>&- || true
        INSTALL_UI_OUT_FD=
    fi
}

_has_open_wizard_ui_fds() {
    [ -n "${INSTALL_UI_IN_FD:-}" ] && [ -n "${INSTALL_UI_OUT_FD:-}" ]
}

_can_open_wizard_ui_tty() {
    [ -t 0 ] || return 1
    [ -r /dev/tty ] && [ -w /dev/tty ]
}

_open_wizard_ui_out_fd() {
    exec {INSTALL_UI_OUT_FD}>/dev/tty && return 0
    exec {INSTALL_UI_IN_FD}<&-
    INSTALL_UI_IN_FD=
    return 1
}

_open_wizard_ui_fd() {
    [ "${INSTALL_FAKE_NO_TTY:-0}" = "1" ] && return 1
    _has_open_wizard_ui_fds && return 0
    _can_open_wizard_ui_tty || return 1
    exec {INSTALL_UI_IN_FD}</dev/tty || return 1
    _open_wizard_ui_out_fd
}

_print_selection_explainer() {
    local ui_out_fd="$1"
    {
        echo
        _asus_gettext "Why this dialog?"
        echo
        printf '  %s\n' "$(_asus_gettext "ASUS ZenBook hardware features are installed as optional components.")"
        printf '  %s\n' "$(_asus_gettext "Select only what you use to avoid unnecessary services and shortcuts.")"
        echo
        _asus_gettext "Available components:"
        echo
        printf '  1) WMI      %s\n' "$(_asus_gettext \
            "Installs the WMI hotkey daemon for ScreenPad brightness, fan Quiet/Balanced/Performance, camera privacy, and window swap across monitors.")"
        printf '  2) TOUCHPAD %s\n' "$(_asus_gettext \
            "Installs the touchpad Share gesture listener so a top-left corner tap opens your desktop screenshot tool (GNOME, Spectacle, and peers).")"
        printf '  3) SOUND    %s\n' "$(_asus_gettext \
            "Installs the speaker amplifier fix and a suspend/resume hook so supported ZenBook audio recovers after boot and after sleep.")"
        printf '  4) DESKTOP  %s\n' "$(_asus_gettext \
            "Adds Display Toggle, MyASUS Settings, and Share keyboard shortcuts for GNOME, KDE Plasma, XFCE, LXQt, Cinnamon, or MATE.")"
        echo
        printf '  %s\n' "$(_asus_gettext "The interface language follows your desktop session.")"
        echo
    } >&"$ui_out_fd"
}

_print_text_selection_intro() {
    local ui_out_fd="$1"
    {
        echo
        _asus_gettext "Text selection mode."
        echo
        _asus_gettext "Enter component numbers or names, separated by commas."
        echo
        _asus_gettext "Press Enter to install all recommended components, or enter 'all'."
        echo
    } >&"$ui_out_fd"
}

_reject_text_selection() {
    local ui_out_fd="$1" input="$2"
    _asus_gettextf "Invalid selection: %s. Enter numbers (1,2,3,4), component names, or all." "$input" \
        >&"$ui_out_fd"
    echo >&"$ui_out_fd"
}

_try_apply_text_selection() {
    # 0 applied, 1 retry, other hard-fail.
    local input="$1" ui_out_fd="$2" parsed status
    parsed=$(_normalize_component_selection "$input") || {
        status=$?
        if [ "$status" -eq 2 ]; then
            _reject_text_selection "$ui_out_fd" "$input"
            return 1
        fi
        return "$status"
    }
    if [ -n "$parsed" ]; then
        INSTALL_CHOICE="$parsed"
        return 0
    fi
    _reject_text_selection "$ui_out_fd" "$input"
    return 1
}

_default_text_selection_if_empty() {
    local input="$1"
    [ -n "$input" ] && return 1
    INSTALL_CHOICE="$(_default_all_components)"
    return 0
}

_prompt_text_selection_retry_or_fail() {
    local status="$1"
    [ "$status" -eq 1 ] && return 0
    return "$status"
}

_read_text_selection_input() {
    local ui_in_fd="$1"
    local -n _input_ref="$2"
    IFS= read -r -u "$ui_in_fd" _input_ref || _input_ref=""
}

_prompt_text_selection() {
    local ui_in_fd="$1"
    local ui_out_fd="$2"
    local input status

    _print_text_selection_intro "$ui_out_fd"
    while true; do
        printf '%s ' "$(_asus_gettext "Components [default: all]:")" >&"$ui_out_fd"
        _read_text_selection_input "$ui_in_fd" input
        _default_text_selection_if_empty "$input" && return 0
        _try_apply_text_selection "$input" "$ui_out_fd" && return 0
        status=$?
        _prompt_text_selection_retry_or_fail "$status" || return "$status"
    done
}

_INVALID_NONINTERACTIVE_CHOICE_MSG=\
'Invalid NONINTERACTIVE_CHOICE. Use names (WMI, TOUCHPAD, SOUND, DESKTOP/GNOME), indexes (1-4), or all.'

_handle_noninteractive_choice() {
    local noninteractive_choice="$1"
    local parsed_choice

    if parsed_choice=$(_normalize_component_selection "$noninteractive_choice"); then
        :
    else
        local normalize_status=$?
        echo "$_INVALID_NONINTERACTIVE_CHOICE_MSG" >&2
        return "$normalize_status"
    fi
    if [ -z "$parsed_choice" ]; then
        echo "$_INVALID_NONINTERACTIVE_CHOICE_MSG" >&2
        return 1
    fi

    INSTALL_CHOICE="$parsed_choice"
    return 0
}

_set_default_interactive_choice() {
    INSTALL_CHOICE="$(_default_all_components)"
    echo "No interactive terminal detected; defaulting to: $INSTALL_CHOICE" >&2
}

_should_use_text_fallback() {
    [ "${INSTALL_PIPED_STDIN:-0}" = "1" ] && return 0
    [ -t 0 ] && return 1
    # Non-tty stdin still allows the TUI when wizard FDs were pre-opened.
    ! _has_open_wizard_ui_fds
}

_can_prompt_interactively() {
    _has_open_wizard_ui_fds && return 0
    [ -t 0 ] && _open_wizard_ui_fd
}

_tui_or_text_selection() {
    local ui_in_fd="$1" ui_out_fd="$2" rc=0
    _prompt_tui_selection "$ui_in_fd" "$ui_out_fd" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    [ "$rc" -eq 1 ] && return 1
    _prompt_text_selection "$ui_in_fd" "$ui_out_fd"
}

_handle_interactive_choice() {
    local ui_in_fd ui_out_fd

    if ! _can_prompt_interactively; then
        _set_default_interactive_choice
        return 0
    fi

    ui_in_fd="$INSTALL_UI_IN_FD"
    ui_out_fd="$INSTALL_UI_OUT_FD"
    _print_selection_explainer "$ui_out_fd"

    if _should_use_text_fallback; then
        _prompt_text_selection "$ui_in_fd" "$ui_out_fd"
        return $?
    fi
    _tui_or_text_selection "$ui_in_fd" "$ui_out_fd"
}

prompt_user_selection() {
    local noninteractive_choice="${NONINTERACTIVE_CHOICE:-}"
    local status=0

    if [ -n "${NONINTERACTIVE_CHOICE+x}" ]; then
        _handle_noninteractive_choice "$noninteractive_choice" || status=$?
        _close_wizard_ui_fds
        return "$status"
    fi

    _handle_interactive_choice || status=$?
    _close_wizard_ui_fds
    return "$status"
}

_install_selection_tui_init() {
    local tui_lib
    if ! declare -F _validate_required_source_file >/dev/null 2>&1; then
        _validate_required_source_file() {
            local file_path="$1" label="$2"
            if [ -f "$file_path" ]; then
                return 0
            fi
            echo "Missing ${label}: $file_path" >&2
            return 1
        }
    fi
    tui_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install-selection-tui.sh"
    if ! _validate_required_source_file "$tui_lib" "installer selection TUI helper"; then
        return 1
    fi
    # shellcheck source=lib/install-selection-tui.sh
    . "$tui_lib"
}

if [ "${ASUS_SELECTION_SKIP_TUI_INIT:-0}" != "1" ]; then
    _install_selection_tui_init || return 1 2>/dev/null || exit 1
fi
