#!/usr/bin/env bash
# kcov driver: exercise lib/install-selection.sh helpers as the main script.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$REPO_ROOT" || exit 1

# shellcheck source=scripts/coverage/drivers/kcov_driver_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/kcov_driver_common.sh"

# shellcheck source=lib/install-shared.sh
source "$REPO_ROOT/lib/install-shared.sh" >/dev/null 2>&1
# shellcheck source=lib/asus-i18n.sh
source "$REPO_ROOT/lib/asus-i18n.sh" >/dev/null 2>&1
# shellcheck source=lib/install-selection.sh
source "$REPO_ROOT/lib/install-selection.sh" >/dev/null 2>&1

_SELECTION_TEMP_DIRS=()
_SELECTION_TEMP_FILES=()

_cleanup_selection_temps() {
    local dir
    rm -f "${_SELECTION_TEMP_FILES[@]+"${_SELECTION_TEMP_FILES[@]}"}"
    for dir in "${_SELECTION_TEMP_DIRS[@]+"${_SELECTION_TEMP_DIRS[@]}"}"; do
        rm -rf "$dir"
    done
}

_selection_track_temp_dir() {
    _SELECTION_TEMP_DIRS+=("$1")
}

_selection_track_temp_file() {
    _SELECTION_TEMP_FILES+=("$1")
}

trap '_cleanup_selection_temps' EXIT

_run_selection_normalize() {
    _exercise _trim_shell_whitespace "  spaced  " >/dev/null
    _exercise _normalize_component_selection all >/dev/null
    _exercise ASUS_DESKTOP_FAMILY=kde _normalize_component_selection all >/dev/null
    _exercise ASUS_DESKTOP_FAMILY=lxqt _normalize_component_selection all >/dev/null
    _exercise ASUS_DESKTOP_FAMILY=cinnamon _normalize_component_selection all >/dev/null
    _exercise ASUS_DESKTOP_FAMILY=mate _normalize_component_selection all >/dev/null
    _exercise ASUS_DESKTOP_FAMILY=other _normalize_component_selection all >/dev/null
    _exercise _normalize_component_selection "1,2,GNOME" >/dev/null
    _exercise _normalize_component_selection "1,2,DESKTOP" >/dev/null
    _exercise _normalize_component_selection "wmi;touchpad" >/dev/null
    _exercise _normalize_component_selection "" >/dev/null
    _exercise _normalize_component_selection badtoken >/dev/null
    _exercise _is_valid_component_token WMI >/dev/null
    _exercise _is_valid_component_token 9 >/dev/null
    _exercise _append_component_choice "" WMI >/dev/null
    _exercise _append_component_choice "WMI" WMI >/dev/null
    _exercise _append_component_choice "WMI" SOUND >/dev/null
    _exercise _append_normalized_component_choice "" 1 >/dev/null
    _exercise _append_normalized_component_choice "" 2 >/dev/null
    _exercise _append_normalized_component_choice "" 3 >/dev/null
    _exercise _append_normalized_component_choice "" 4 >/dev/null
    _exercise _append_normalized_component_choice "" weird >/dev/null
}

_run_selection_noninteractive() {
    NONINTERACTIVE_CHOICE=all prompt_user_selection >/dev/null
    _exercise NONINTERACTIVE_CHOICE=bad prompt_user_selection >/dev/null
    unset NONINTERACTIVE_CHOICE
    _exercise INSTALL_FAKE_NO_TTY=1 prompt_user_selection >/dev/null
    _set_default_interactive_choice >/dev/null
    _tui_selection_title >/dev/null
    _tui_selection_message >/dev/null
    _tui_selection_message 40 >/dev/null
    _tui_wrap_text 40 "Select only the components you use." >/dev/null
    _tui_python_bin >/dev/null
    _tui_module_path >/dev/null
    _tui_resolve_accent_rgb >/dev/null
    ASUS_TUI_ACCENT_RGB="1 2 3" _tui_resolve_accent_rgb >/dev/null
    _exercise _should_use_text_fallback >/dev/null
    _exercise _has_open_wizard_ui_fds >/dev/null
    _exercise _can_open_wizard_ui_tty >/dev/null
    _exercise INSTALL_FAKE_NO_TTY=1 _open_wizard_ui_fd >/dev/null
    _handle_noninteractive_choice all >/dev/null
    _exercise _handle_noninteractive_choice bad >/dev/null
    _exercise INSTALL_FAKE_NO_TTY=1 _handle_interactive_choice >/dev/null
    _exercise INSTALL_PIPED_STDIN=1 _should_use_text_fallback >/dev/null
    _exercise _can_prompt_interactively >/dev/null
    _exercise _close_wizard_ui_fds >/dev/null
}

_run_selection_text_paths() {
    local ui_in ui_out
    out_file=$(mktemp)
    _selection_track_temp_file "$out_file"
    in_file=$(mktemp)
    _selection_track_temp_file "$in_file"
    exec {ui_out}>"$out_file"
    _print_selection_explainer "$ui_out"
    exec {ui_out}>&-
    printf '1\n' > "$in_file"
    exec {ui_in}<"$in_file"
    exec {ui_out}>"$out_file"
    _exercise _prompt_text_selection "$ui_in" "$ui_out" >/dev/null
    exec {ui_in}<&-
    exec {ui_out}>&-
    printf '\n' > "$in_file"
    exec {ui_in}<"$in_file"
    exec {ui_out}>"$out_file"
    _exercise _prompt_text_selection "$ui_in" "$ui_out" >/dev/null
    exec {ui_in}<&-
    exec {ui_out}>&-
    printf 'bad\n1\n' > "$in_file"
    exec {ui_in}<"$in_file"
    exec {ui_out}>"$out_file"
    _exercise _prompt_text_selection "$ui_in" "$ui_out" >/dev/null
    exec {ui_in}<&-
    exec {ui_out}>&-
}

_run_selection_tui_helpers() {
    local choice_tmp
    choice_tmp=$(mktemp)
    _selection_track_temp_file "$choice_tmp"
    _exercise ASUS_TUI_SCRIPT_KEYS=$'\n' _prompt_tui_selection 0 1 >/dev/null
    _exercise _handle_tui_selection_error 1 1 "$choice_tmp" >/dev/null
    _exercise _handle_tui_selection_error 2 1 "$choice_tmp" >/dev/null
    : > "$choice_tmp"
    _exercise _apply_tui_selection "$choice_tmp" 1 >/dev/null
    printf 'WMI\n' > "$choice_tmp"
    _apply_tui_selection "$choice_tmp" 1 >/dev/null
    _exercise INSTALL_UI_IN_FD=0 INSTALL_UI_OUT_FD=1 INSTALL_FAKE_NO_TTY=0 _open_wizard_ui_fd >/dev/null
    _exercise _has_open_wizard_ui_fds >/dev/null
    _exercise INSTALL_UI_IN_FD=0 INSTALL_UI_OUT_FD=1 INSTALL_PIPED_STDIN=0 _should_use_text_fallback >/dev/null
    choice_tmp=$(mktemp)
    _selection_track_temp_file "$choice_tmp"
    _exercise ASUS_TUI_SCRIPT_KEYS=$'\n' _run_tui_selection 0 1 "$choice_tmp" >/dev/null
    _exercise ASUS_TUI_SCRIPT_KEYS=$'\x1b' _run_tui_selection 0 1 "$choice_tmp" >/dev/null
}

_run_selection_interactive_fds() {
    local ui_in ui_out
    out_file2=$(mktemp)
    _selection_track_temp_file "$out_file2"
    in_file2=$(mktemp)
    _selection_track_temp_file "$in_file2"
    printf '1\n' > "$in_file2"
    exec {ui_in}<"$in_file2"
    exec {ui_out}>"$out_file2"
    _exercise ASUS_TUI_SCRIPT_KEYS=$'\n' INSTALL_UI_IN_FD=$ui_in INSTALL_UI_OUT_FD=$ui_out \
        INSTALL_PIPED_STDIN=0 INSTALL_FAKE_NO_TTY=0 \
        _handle_interactive_choice >/dev/null
    printf '1\n' > "$in_file2"
    exec {ui_in}<&-
    exec {ui_out}>&-
    exec {ui_in}<"$in_file2"
    exec {ui_out}>"$out_file2"
    _exercise INSTALL_UI_IN_FD=$ui_in INSTALL_UI_OUT_FD=$ui_out \
        INSTALL_PIPED_STDIN=1 _handle_interactive_choice >/dev/null
    unset INSTALL_UI_IN_FD INSTALL_UI_OUT_FD
    exec {ui_in}<&-
    exec {ui_out}>&-
}

_run_selection_missing_python() {
    local ui_in ui_out no_py tool tool_path
    missing_in=$(mktemp)
    _selection_track_temp_file "$missing_in"
    missing_out=$(mktemp)
    _selection_track_temp_file "$missing_out"
    printf '2\n' > "$missing_in"
    exec {ui_in}<"$missing_in"
    exec {ui_out}>"$missing_out"
    no_py=$(mktemp -d)
    _selection_track_temp_dir "$no_py"
    for tool in bash sh tr mktemp rm cat cut head fold; do
        tool_path=$(type -P "$tool" 2>/dev/null || true)
        if [ -n "$tool_path" ]; then
            ln -sf "$tool_path" "$no_py/$tool"
        fi
    done
    _exercise PATH="$no_py" INSTALL_UI_IN_FD=$ui_in INSTALL_UI_OUT_FD=$ui_out INSTALL_PIPED_STDIN=0 \
        _handle_interactive_choice >/dev/null
    _exercise PATH="$no_py" _prompt_tui_selection 0 1 >/dev/null
    exec {ui_in}<&-
    exec {ui_out}>&-
    unset INSTALL_UI_IN_FD INSTALL_UI_OUT_FD
    _exercise NONINTERACTIVE_CHOICE=all prompt_user_selection >/dev/null
}

_run_selection_close_and_special() {
    exec {INSTALL_UI_IN_FD}</dev/null
    exec {INSTALL_UI_OUT_FD}>/dev/null
    export INSTALL_UI_IN_FD INSTALL_UI_OUT_FD
    _close_wizard_ui_fds
    unset INSTALL_UI_IN_FD INSTALL_UI_OUT_FD
    _print_special_component_selection "" >/dev/null
    _print_special_component_selection ALL >/dev/null
    _print_special_component_selection NONE >/dev/null
    _print_special_component_selection WMI >/dev/null || true
    _exercise ASUS_DESKTOP_FAMILY=gnome _desktop_default_on >/dev/null
    _exercise ASUS_DESKTOP_FAMILY=other _desktop_default_on >/dev/null
    local ui_out
    ui_out=$(mktemp)
    _selection_track_temp_file "$ui_out"
    exec {ui_out_fd}>"$ui_out"
    _reject_text_selection "$ui_out_fd" "badtoken" || true
    exec {ui_out_fd}>&-
}

_selection_link_tools() {
    local dest="$1"
    shift
    local tool tool_path
    for tool in "$@"; do
        tool_path=$(type -P "$tool" 2>/dev/null || true)
        if [ -n "$tool_path" ]; then
            ln -sf "$tool_path" "$dest/$tool"
        fi
    done
}

_run_selection_tui_wrap_and_family() {
    local no_fold
    no_fold=$(mktemp -d)
    _selection_track_temp_dir "$no_fold"
    _selection_link_tools "$no_fold" bash sh printf sed tr mktemp rm cat cut head
    _exercise PATH="$no_fold" _tui_wrap_text 40 "one two three four" >/dev/null
    _exercise ASUS_DESKTOP_FAMILY=xfce _tui_desktop_family_hint >/dev/null
    ln -sf "$(type -P true)" "$no_fold/asus_desktop_family"
    _exercise PATH="$no_fold:$PATH" ASUS_DESKTOP_FAMILY= _tui_desktop_family_hint >/dev/null
}

_run_selection_tui_accent_misses() {
    local no_py saved_tui_dir
    no_py=$(mktemp -d)
    _selection_track_temp_dir "$no_py"
    _selection_link_tools "$no_py" bash sh printf tr mktemp rm cat cut head
    unset ASUS_TUI_ACCENT_RGB || true
    _exercise PATH="$no_py" _tui_resolve_accent_rgb >/dev/null
    saved_tui_dir="${_ASUS_SELECTION_TUI_DIR}"
    _ASUS_SELECTION_TUI_DIR=/nonexistent
    _exercise SCRIPT_DIR=/nonexistent INSTALL_SOURCE_DIR=/nonexistent \
        ASUS_TUI_ACCENT_RGB= _tui_resolve_accent_rgb >/dev/null
    _ASUS_SELECTION_TUI_DIR="$saved_tui_dir"
}

_run_selection_tui_apply_and_cancel() {
    local choice_tmp ui_out
    _exercise ASUS_DESKTOP_FAMILY=gnome _tui_desktop_cli_flag >/dev/null
    choice_tmp=$(mktemp)
    _selection_track_temp_file "$choice_tmp"
    printf 'BADTOKEN\n' >"$choice_tmp"
    ui_out=$(mktemp)
    _selection_track_temp_file "$ui_out"
    exec {ui_out_fd}>"$ui_out"
    _exercise _apply_tui_selection "$choice_tmp" "$ui_out_fd" >/dev/null
    exec {ui_out_fd}>&-
    _exercise ASUS_TUI_SCRIPT_KEYS=$'\x1b' _prompt_tui_selection 0 1 >/dev/null
}

_run_selection_tui_coverage_boost() {
    _run_selection_tui_wrap_and_family
    _run_selection_tui_accent_misses
    _run_selection_tui_apply_and_cancel
}

_run_selection_edge_paths() {
    local ui_in ui_out in_file out_file
    # Comma-only input → empty selection branch in normalize.
    _exercise _normalize_component_selection "," >/dev/null
    # Empty NONINTERACTIVE_CHOICE when the variable is set.
    _exercise NONINTERACTIVE_CHOICE= _handle_noninteractive_choice "" >/dev/null
    # Hard-fail status from text apply retry helper.
    _exercise _prompt_text_selection_retry_or_fail 5 >/dev/null
    # Comma-only text selection applies an empty choice.
    out_file=$(mktemp)
    _selection_track_temp_file "$out_file"
    in_file=$(mktemp)
    _selection_track_temp_file "$in_file"
    printf ',\n' >"$in_file"
    exec {ui_in}<"$in_file"
    exec {ui_out}>"$out_file"
    _exercise _prompt_text_selection "$ui_in" "$ui_out" >/dev/null
    exec {ui_in}<&-
    exec {ui_out}>&-
}

_run_selection_normalize
_run_selection_noninteractive
_run_selection_text_paths
_run_selection_tui_helpers
_run_selection_interactive_fds
_run_selection_missing_python
_run_selection_close_and_special
_run_selection_tui_coverage_boost
_run_selection_edge_paths
