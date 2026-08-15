#!/usr/bin/env bash
# Session discovery and desktop-environment helpers for product scripts.

_is_active_gui_session() {
    local sid="$1"
    local stype sstate
    stype=$(loginctl show-session "$sid" -p Type --value 2>/dev/null)
    sstate=$(loginctl show-session "$sid" -p State --value 2>/dev/null)
    [ "$sstate" = "active" ] && { [ "$stype" = "x11" ] || [ "$stype" = "wayland" ]; }
}

_extract_session_user() {
    local sid="$1"
    if _is_active_gui_session "$sid"; then
        local suser
        suser=$(loginctl show-session "$sid" -p Name --value 2>/dev/null)
        if [ -n "$suser" ]; then
            echo "$suser"
            return 0
        fi
    fi
    return 1
}

_loginctl_session_ids() {
    local sid
    while read -r sid; do
        [ -z "$sid" ] && continue
        printf '%s\n' "$sid"
    done < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}')
}

find_active_session_id() {
    local sid
    while read -r sid; do
        [ -z "$sid" ] && continue
        if _is_active_gui_session "$sid"; then
            echo "$sid"
            return 0
        fi
    done < <(_loginctl_session_ids)
    return 1
}

find_active_session_user() {
    local sid user
    while read -r sid; do
        [ -z "$sid" ] && continue
        if user=$(_extract_session_user "$sid") && [ -n "$user" ]; then
            echo "$user"
            return 0
        fi
    done < <(_loginctl_session_ids)
    return 1
}

_asus_proc_environ_value() {
    local pid="$1" key="$2" environ_file raw
    environ_file="${ASUS_PROC_ENVIRON_ROOT:-/proc}/$pid/environ"
    [ -r "$environ_file" ] || return 1
    raw=$(tr '\0' '\n' < "$environ_file" 2>/dev/null | grep -E "^${key}=" | head -n1) || true
    [ -n "$raw" ] || return 1
    printf '%s' "${raw#*=}"
}

_asus_session_leader_pid() {
    local sid="$1" leader
    sid="${sid:-$(find_active_session_id 2>/dev/null || true)}"
    [ -n "$sid" ] || return 1
    leader=$(loginctl show-session "$sid" -p Leader --value 2>/dev/null || true)
    case "$leader" in
        ''|*[!0-9]*) return 1 ;;
    esac
    echo "$leader"
}

_asus_user_runtime_dir() {
    local user="$1" uid root
    uid=$(id -u "$user" 2>/dev/null) || return 1
    # Prefer product helper from asus-common.sh when already loaded (same precedence).
    if declare -F _resolve_session_bus_root >/dev/null 2>&1; then
        root=$(_resolve_session_bus_root)
    else
        root="${BUS_ROOT:-${DBUS_BUS_ROOT:-${RUN_USER_ROOT:-/run/user}}}"
    fi
    printf '%s/%s' "$root" "$uid"
}

_asus_grep_env_line() {
    local key="$1"
    grep -m1 -E "^${key}="
}

# Negative-cache: once user-manager show-environment fails/times out, skip further
# calls in this process (fake D-Bus sockets can otherwise hang systemctl for minutes).
# Fetch/skip must run in the caller shell — never only inside $().
_ASUS_SYSTEMCTL_ENV_SKIP=""
_ASUS_SYSTEMCTL_ENV_CACHED_USER=""
_ASUS_SYSTEMCTL_ENV_BLOB=""
_ASUS_SYSTEMCTL_ENV_CACHE_VALID=""

_asus_systemctl_env_timeout() {
    local secs="${ASUS_SYSTEMCTL_ENV_TIMEOUT_SECS:-1}" status
    case "$secs" in
        ''|*[!0-9]*) secs=1 ;;
    esac
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
        status=$?
        if [ "$status" -eq 124 ]; then
            echo "Debug: systemctl --user show-environment timed out after ${secs}s" >&2
        fi
        return "$status"
    fi
    # Missing timeout must not set _ASUS_SYSTEMCTL_ENV_SKIP — run directly.
    "$@"
}

_asus_systemctl_show_env() {
    local user="$1" runtime="$2"
    # systemctl --user needs XDG_RUNTIME_DIR to reach the session manager.
    if [ "$(id -un 2>/dev/null)" = "$user" ]; then
        _asus_systemctl_env_timeout env XDG_RUNTIME_DIR="$runtime" \
            systemctl --user show-environment 2>/dev/null
        return $?
    fi
    command -v runuser >/dev/null 2>&1 || return 1
    _asus_systemctl_env_timeout runuser -u "$user" -- \
        env XDG_RUNTIME_DIR="$runtime" systemctl --user show-environment 2>/dev/null
}

_asus_env_blob_key_value() {
    local blob="$1" key="$2" value
    value=$(printf '%s\n' "$blob" | _asus_grep_env_line "$key") || true
    [ -n "$value" ] || return 1
    printf '%s' "${value#*=}"
}

_asus_systemctl_env_cache_hit() {
    local user="$1"
    [ "$user" = "${_ASUS_SYSTEMCTL_ENV_CACHED_USER:-}" ] && [ -n "${_ASUS_SYSTEMCTL_ENV_CACHE_VALID:-}" ]
}

_asus_systemctl_env_runtime() {
    local user="$1" runtime
    runtime=$(_asus_user_runtime_dir "$user") || return 1
    [ -d "$runtime" ] || return 1
    if [ "$(id -un 2>/dev/null)" != "$user" ] && ! command -v runuser >/dev/null 2>&1; then
        return 1
    fi
    printf '%s\n' "$runtime"
}

_asus_systemctl_env_fetch_blob() {
    local user="$1" runtime out
    runtime=$(_asus_systemctl_env_runtime "$user") || return 1
    if ! out=$(_asus_systemctl_show_env "$user" "$runtime"); then
        _ASUS_SYSTEMCTL_ENV_SKIP=1
        _ASUS_SYSTEMCTL_ENV_BLOB=""
        _ASUS_SYSTEMCTL_ENV_CACHE_VALID=""
        return 2
    fi
    _ASUS_SYSTEMCTL_ENV_CACHED_USER="$user"
    _ASUS_SYSTEMCTL_ENV_BLOB="$out"
    _ASUS_SYSTEMCTL_ENV_CACHE_VALID=1
    return 0
}

_asus_systemctl_env_blob_for_user() {
    local user="$1"
    [ -n "$user" ] || return 1
    [ -z "${_ASUS_SYSTEMCTL_ENV_SKIP:-}" ] || return 2
    if _asus_systemctl_env_cache_hit "$user"; then
        return 0
    fi
    _asus_systemctl_env_fetch_blob "$user"
}

_asus_systemctl_user_env_value() {
    local user="$1" key="$2" status
    [ -n "$user" ] || return 1
    _asus_systemctl_env_blob_for_user "$user"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _asus_env_blob_key_value "$_ASUS_SYSTEMCTL_ENV_BLOB" "$key"
}

# Prime systemctl env globals in the caller shell before any $() lookups.
_asus_ensure_systemctl_env() {
    local user="$1" status
    [ -n "$user" ] || return 1
    _asus_systemctl_env_blob_for_user "$user"
    status=$?
    return "$status"
}

_asus_print_if_set() {
    local value="$1"
    [ -n "$value" ] || return 1
    printf '%s' "$value"
    return 0
}

_asus_lookup_from_leader() {
    local key="$1" sid="$2" leader value
    leader=$(_asus_session_leader_pid "$sid" 2>/dev/null || true)
    [ -n "$leader" ] || return 1
    value=$(_asus_proc_environ_value "$leader" "$key" 2>/dev/null || true)
    _asus_print_if_set "$value"
}

# Reads leader environ or the already-primed systemctl blob. Call
# _asus_ensure_systemctl_env in the parent shell first so skip/blob persist.
_asus_lookup_env_key() {
    local key="$1" sid="$2" value
    _asus_lookup_from_leader "$key" "$sid" && return 0
    [ -z "${_ASUS_SYSTEMCTL_ENV_SKIP:-}" ] || return 1
    [ -n "${_ASUS_SYSTEMCTL_ENV_CACHE_VALID:-}" ] || return 1
    value=$(_asus_env_blob_key_value "$_ASUS_SYSTEMCTL_ENV_BLOB" "$key" 2>/dev/null) || return 1
    _asus_print_if_set "$value"
}

_asus_resolve_session_ids() {
    # Prints sid then user on separate lines for callers.
    local user="${1:-}" sid
    sid="${ASUS_SESSION_ID:-$(find_active_session_id 2>/dev/null || true)}"
    [ -n "$user" ] || user=$(find_active_session_user 2>/dev/null || true)
    printf '%s\n%s\n' "$sid" "$user"
}

_asus_infer_session_type() {
    local sid="$1"
    if [ -n "$(_asus_lookup_env_key "WAYLAND_DISPLAY" "$sid" 2>/dev/null || true)" ]; then
        echo "wayland"
        return 0
    fi
    if [ -n "$(_asus_lookup_env_key "DISPLAY" "$sid" 2>/dev/null || true)" ]; then
        echo "x11"
        return 0
    fi
    return 1
}

_asus_loginctl_session_type() {
    local sid="$1"
    [ -n "$sid" ] || return 1
    loginctl show-session "$sid" -p Type --value 2>/dev/null
}

_asus_first_nonempty() {
    local value
    for value in "$@"; do
        [ -n "$value" ] || continue
        printf '%s' "$value"
        return 0
    done
    return 1
}

asus_session_type() {
    local user="${1:-}" sid stype
    {
        read -r sid
        read -r user
    } < <(_asus_resolve_session_ids "$user")
    _asus_ensure_systemctl_env "$user" || true
    stype=$(_asus_loginctl_session_type "$sid" 2>/dev/null || true)
    if [ -z "$stype" ]; then
        stype=$(_asus_session_type_from_env "$sid")
    fi
    printf '%s' "$stype"
}

_asus_session_type_from_env() {
    local sid="$1" stype
    stype=$(_asus_lookup_env_key "XDG_SESSION_TYPE" "$sid" 2>/dev/null) || stype=""
    if [ -z "$stype" ]; then
        stype=$(_asus_infer_session_type "$sid" 2>/dev/null) || stype=""
    fi
    printf '%s' "$stype"
}

_asus_primary_desktop_family() {
    local desktop
    desktop=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    case "$desktop" in
        *xfce*) echo "xfce" ;;
        *kde*|*plasma*) echo "kde" ;;
        *lxqt*) echo "lxqt" ;;
        *) return 1 ;;
    esac
}

_asus_secondary_desktop_family() {
    local desktop="$1"
    case "$desktop" in
        *cinnamon*) echo "cinnamon" ;;
        *mate*) echo "mate" ;;
        *gnome*|*ubuntu*|*pop*) echo "gnome" ;;
        *) echo "other" ;;
    esac
}

asus_desktop_family_from_string() {
    local desktop family
    desktop=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    if family=$(_asus_primary_desktop_family "$desktop"); then
        printf '%s\n' "$family"
        return 0
    fi
    _asus_secondary_desktop_family "$desktop"
}

_asus_desktop_token_family() {
    local text
    text=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    case "$text" in
        *cinnamon*) printf '%s\n' cinnamon ;;
        *mate*) printf '%s\n' mate ;;
        *) return 1 ;;
    esac
}

_asus_probe_de_binary_family() {
    # Prefer cinnamon/mate only when gnome-shell is absent (true GNOME stays gnome).
    if [ -x /usr/bin/gnome-shell ]; then
        return 1
    fi
    if [ -x /usr/bin/cinnamon ]; then
        printf '%s\n' cinnamon
        return 0
    fi
    if [ -x /usr/bin/mate-session ] || [ -x /usr/bin/mate-panel ]; then
        printf '%s\n' mate
        return 0
    fi
    return 1
}

_asus_probe_de_schema_family() {
    local schemas
    command -v gsettings >/dev/null 2>&1 || return 1
    schemas=$(gsettings list-schemas 2>/dev/null) || return 1
    printf '%s\n' "$schemas" | grep -Fxq -- "org.cinnamon.desktop.keybindings" && {
        printf '%s\n' cinnamon
        return 0
    }
    printf '%s\n' "$schemas" | grep -Fxq -- "org.mate.control-center.keybinding" && {
        printf '%s\n' mate
        return 0
    }
    return 1
}

_asus_probe_mint_session_tokens() {
    local session_desktop="$1" desktop_session="$2" hit=""
    hit=$(_asus_desktop_token_family "$session_desktop" 2>/dev/null) || hit=""
    if [ -z "$hit" ]; then
        hit=$(_asus_desktop_token_family "$desktop_session" 2>/dev/null) || hit=""
    fi
    [ -n "$hit" ] || return 1
    printf '%s\n' "$hit"
}

_asus_probe_mint_tokens_for_sid() {
    local sid="$1" session_desktop desktop_session
    session_desktop=$(_asus_lookup_env_key "XDG_SESSION_DESKTOP" "$sid" 2>/dev/null || true)
    desktop_session=$(_asus_lookup_env_key "DESKTOP_SESSION" "$sid" 2>/dev/null || true)
    _asus_probe_mint_session_tokens "$session_desktop" "$desktop_session"
}

_asus_probe_mint_binary_family() {
    _asus_probe_de_binary_family 2>/dev/null
}

_asus_probe_mint_schema_family() {
    _asus_probe_de_schema_family 2>/dev/null
}

_asus_mint_bare_gnome_family() {
    local sid="$1" probe hit
    for probe in _asus_probe_mint_tokens_for_sid \
        _asus_probe_mint_binary_family _asus_probe_mint_schema_family; do
        if hit=$("$probe" "$sid"); then
            printf '%s\n' "$hit"
            return 0
        fi
    done
    return 1
}

_asus_refine_gnome_family() {
    local sid="$1" family="$2" probed
    if [ "$family" = gnome ]; then
        probed=$(_asus_mint_bare_gnome_family "$sid" 2>/dev/null) || probed=""
        if [ -n "$probed" ]; then
            family="$probed"
        fi
    fi
    printf '%s\n' "$family"
}

_asus_detect_desktop_family() {
    local user="$1" sid desktop family
    {
        read -r sid
        read -r user
    } < <(_asus_resolve_session_ids "$user")
    _asus_ensure_systemctl_env "$user" || true
    desktop=$(_asus_lookup_env_key "XDG_CURRENT_DESKTOP" "$sid" 2>/dev/null || true)
    family=$(asus_desktop_family_from_string "$desktop")
    _asus_refine_gnome_family "$sid" "$family"
}

asus_desktop_family() {
    local user="${1:-}" override
    override="${ASUS_DESKTOP_FAMILY:-}"
    if [ -n "$override" ]; then
        echo "$override"
        return 0
    fi
    _asus_detect_desktop_family "$user"
}

asus_session_env_value() {
    local key="$1" user="${2:-}" sid
    {
        read -r sid
        read -r user
    } < <(_asus_resolve_session_ids "$user")
    _asus_ensure_systemctl_env "$user" || true
    _asus_lookup_env_key "$key" "$sid" 2>/dev/null || true
}

_asus_print_env_assignment() {
    local key="$1" value="$2"
    [ -n "$value" ] || return 0
    printf '%s=%s\n' "$key" "$value"
}

_asus_leader_environ_blob() {
    local sid="$1" leader environ_file
    leader=$(_asus_session_leader_pid "$sid" 2>/dev/null || true)
    [ -n "$leader" ] || return 1
    environ_file="${ASUS_PROC_ENVIRON_ROOT:-/proc}/$leader/environ"
    [ -r "$environ_file" ] || return 1
    tr '\0' '\n' < "$environ_file" 2>/dev/null
}

_asus_try_print_env_from_blob() {
    local key="$1" blob="$2" value
    [ -n "$blob" ] || return 1
    value=$(_asus_env_blob_key_value "$blob" "$key" 2>/dev/null || true)
    [ -n "$value" ] || return 1
    _asus_print_env_assignment "$key" "$value"
}

_asus_try_print_from_systemctl_cache() {
    local key="$1"
    [ -n "${_ASUS_SYSTEMCTL_ENV_CACHE_VALID:-}" ] || return 1
    _asus_try_print_env_from_blob "$key" "$_ASUS_SYSTEMCTL_ENV_BLOB"
}

_asus_export_session_env_key() {
    local key="$1" sid="$2" leader_blob="$3" value
    _asus_try_print_env_from_blob "$key" "$leader_blob" && return 0
    _asus_try_print_from_systemctl_cache "$key" && return 0
    # Leader blob already scanned above; only re-read /proc when it was empty.
    if [ -z "$leader_blob" ]; then
        value=$(_asus_lookup_from_leader "$key" "$sid" 2>/dev/null || true)
        _asus_print_env_assignment "$key" "$value"
        return 0
    fi
    _asus_print_env_assignment "$key" ""
}

asus_export_session_env_args() {
    local user="${1:-}" sid leader_blob
    {
        read -r sid
        read -r user
    } < <(_asus_resolve_session_ids "$user")
    _asus_ensure_systemctl_env "$user" || true
    leader_blob=$(_asus_leader_environ_blob "$sid" 2>/dev/null || true)
    _asus_export_session_env_key DISPLAY "$sid" "$leader_blob"
    _asus_export_session_env_key WAYLAND_DISPLAY "$sid" "$leader_blob"
    _asus_export_session_env_key XDG_SESSION_TYPE "$sid" "$leader_blob"
    _asus_export_session_env_key XDG_CURRENT_DESKTOP "$sid" "$leader_blob"
}
