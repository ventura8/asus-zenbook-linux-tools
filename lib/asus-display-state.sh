#!/bin/bash
# Display-mode helper library (sourced by bin/asus-display-mode.sh).

_display_state_dir() {
    local user uid root
    if [ -n "${_ASUS_DISPLAY_MODE_DIR_CACHE:-}" ]; then
        printf '%s\n' "$_ASUS_DISPLAY_MODE_DIR_CACHE"
        return 0
    fi
    if [ -n "${ASUS_DISPLAY_MODE_STATE_PREFIX:-}" ]; then
        _ASUS_DISPLAY_MODE_DIR_CACHE="$(dirname "$ASUS_DISPLAY_MODE_STATE_PREFIX")"
        printf '%s\n' "$_ASUS_DISPLAY_MODE_DIR_CACHE"
        return 0
    fi
    user=$(_resolve_cycle_user)
    uid=$(_resolve_user_id "$user")
    uid="${uid:-$(id -u 2>/dev/null)}"
    uid="${uid:-0}"
    # Hotkey daemon uses ProtectHome=read-only (/run/user is RO); keep state
    # under RuntimeDirectory=asus-zenbook-notif like notification replace-IDs.
    root="${NOTIF_ID_ROOT:-/run/asus-zenbook-notif}"
    printf '%s/%s/asus-display-mode\n' "$root" "$uid"
}

_ensure_display_state_dir() {
    local dir="$1"
    _soft mkdir -p "$dir" 2>/dev/null
    _soft chmod 0700 "$dir" 2>/dev/null
}

_display_state_prefix() {
    local dir resolved
    if [ -n "${_ASUS_DISPLAY_MODE_PREFIX_CACHE:-}" ]; then
        echo "$_ASUS_DISPLAY_MODE_PREFIX_CACHE"
        return 0
    fi
    if [ -n "${ASUS_DISPLAY_MODE_STATE_PREFIX:-}" ]; then
        dir="$(dirname "$ASUS_DISPLAY_MODE_STATE_PREFIX")"
        _ensure_display_state_dir "$dir"
        resolved="$ASUS_DISPLAY_MODE_STATE_PREFIX"
        _ASUS_DISPLAY_MODE_PREFIX_CACHE="$resolved"
        _ASUS_DISPLAY_MODE_DIR_CACHE="$dir"
        echo "$resolved"
        return 0
    fi
    dir=$(_display_state_dir)
    _ensure_display_state_dir "$dir"
    resolved="${dir}/state"
    _ASUS_DISPLAY_MODE_PREFIX_CACHE="$resolved"
    _ASUS_DISPLAY_MODE_DIR_CACHE="$dir"
    echo "$resolved"
}

_session_expiry_epoch() {
    local raw="$1"
    [[ "$raw" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$raw"
    return 0
}

_rewrite_display_mode_log_tail() {
    # Best-effort: keep the last max_bytes via temp+mv (OSD must not fail).
    local log="$1" max_bytes="$2" tmp
    tmp=$(mktemp "${log}.XXXXXX" 2>/dev/null) || return 0
    if ! tail -c "$max_bytes" "$log" >"$tmp" 2>/dev/null; then
        _soft rm -f "$tmp"
        return 0
    fi
    mv -f "$tmp" "$log" 2>/dev/null || _soft rm -f "$tmp"
}

_append_bounded_display_mode_log() {
    # Append then rewrite when oversized; all failures soft.
    local log="$1" line="$2" max_bytes="${3:-262144}" size
    echo "$line" >>"$log" 2>/dev/null || return 0
    size=$(wc -c <"$log" 2>/dev/null || echo 0)
    [ "${size:-0}" -gt "$max_bytes" ] 2>/dev/null || return 0
    _rewrite_display_mode_log_tail "$log" "$max_bytes"
}

_log_display_mode() {
    local msg="$1" dir log
    dir="${_ASUS_DISPLAY_MODE_DIR_CACHE:-}"
    if [ -z "$dir" ]; then
        dir=$(_display_state_dir)
        _ASUS_DISPLAY_MODE_DIR_CACHE="$dir"
    fi
    _ensure_display_state_dir "$dir"
    log="${dir}/asus-display-mode.log"
    # Bound growth under RuntimeDirectory; rewrite failures must not break OSD.
    _append_bounded_display_mode_log "$log" \
        "$(date '+%Y-%m-%d %H:%M:%S') [asus-display-mode] $msg"
}

_write_ctx() {
    local prefix="$1" active_user="$2" target="$3" backend="$4"
    _ensure_display_state_dir "$(dirname "$prefix")"
    _soft_write_stdout "${prefix}.ctx" printf '%s\n%s\n%s\n' "$active_user" "$target" "$backend"
}

_read_ctx() {
    local prefix="$1"
    local -n _ctx_user="$2" _ctx_target="$3" _ctx_backend="$4"
    _ctx_user=""
    _ctx_target=""
    _ctx_backend=""
    [ -f "${prefix}.ctx" ] || return 1
    _ctx_user=$(sed -n '1p' "${prefix}.ctx" 2>/dev/null)
    _ctx_target=$(sed -n '2p' "${prefix}.ctx" 2>/dev/null)
    _ctx_backend=$(sed -n '3p' "${prefix}.ctx" 2>/dev/null)
    _ctx_backend="${_ctx_backend:-ydotool}"
    return 0
}

_bump_session_expiry() {
    local prefix="$1" expiry
    _ensure_display_state_dir "$(dirname "$prefix")"
    expiry=$(( $(date +%s) + ${_OSD_IDLE_SECS:-2} ))
    _soft_write_stdout "${prefix}.session" echo "$expiry"
}

_session_is_active() {
    local prefix="$1" expiry now
    [ -f "${prefix}.session" ] || return 1
    expiry=$(_session_expiry_epoch "$(cat "${prefix}.session" 2>/dev/null)") || return 1
    now=$(date +%s)
    [ "$now" -lt "$expiry" ]
}

_osd_cancel_flag_path() {
    printf '%s.cancel\n' "$1"
}

_osd_cancel_in_progress() {
    [ -f "$(_osd_cancel_flag_path "$1")" ]
}

_mark_osd_cancel_in_progress() {
    _soft_write_stdout "$(_osd_cancel_flag_path "$1")" echo 1
}

_clear_osd_cancel_flag() {
    _soft rm -f "$(_osd_cancel_flag_path "$1")"
}

_osd_cleanup_marker_files() {
    local prefix="$1"
    _soft rm -f "${prefix}.session" "${prefix}.ctx" "${prefix}.wd.pid"
}

_dup_window_hit() {
    local now="$1" last_time="$2" now_len last_len diff
    now_len=${#now}
    last_len=${#last_time}
    if [ "$now_len" -gt 10 ] && [ "$last_len" -gt 10 ]; then
        diff=$(( (now - last_time) / 1000000 ))
        [ "$diff" -lt 0 ] && diff=0
        [ "$diff" -lt "$_DUP_WINDOW_MS" ]
        return $?
    fi
    # Seconds-resolution clocks: only treat equal timestamps as duplicates.
    [ "$now" -eq "$last_time" ]
}

_lock_is_duplicate() {
    local lock_file="$1" now="$2" last_time
    last_time=$(cat "$lock_file" 2>/dev/null)
    last_time="${last_time:-0}"
    [ -n "$now" ] && [ -n "$last_time" ] && _dup_window_hit "$now" "$last_time"
}

_is_duplicate_invoke() {
    local prefix lock_file now
    prefix="$(_display_state_prefix)"
    lock_file="${prefix}.lock"
    now=$(date +%s%N 2>/dev/null)
    if [[ ! "$now" =~ ^[0-9]+$ ]]; then
        now=$(date +%s)
    fi
    if [ -f "$lock_file" ] && _lock_is_duplicate "$lock_file" "$now"; then
        return 0
    fi
    _soft_write_stdout "$lock_file" echo "$now"
    return 1
}

