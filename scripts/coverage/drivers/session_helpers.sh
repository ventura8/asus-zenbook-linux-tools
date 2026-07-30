#!/usr/bin/env bash
# kcov driver: exercise lib/asus-session.sh helpers as the main script.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$REPO_ROOT" || exit 1

# shellcheck source=scripts/coverage/drivers/kcov_driver_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/kcov_driver_common.sh"

# shellcheck source=lib/asus-session.sh
source "$REPO_ROOT/lib/asus-session.sh" >/dev/null 2>&1

_run_family_string_parsers() {
    # Same-shell: kcov drops _exercise hits on session family helpers.
    _soft asus_desktop_family_from_string "XFCE:ubuntu" >/dev/null
    _soft asus_desktop_family_from_string "KDE:Plasma" >/dev/null
    _soft asus_desktop_family_from_string "LXQt:ubuntu" >/dev/null
    _soft asus_desktop_family_from_string "X-Cinnamon" >/dev/null
    _soft asus_desktop_family_from_string "MATE" >/dev/null
    _soft asus_desktop_family_from_string "ubuntu:GNOME" >/dev/null
    _soft asus_desktop_family_from_string "unknown" >/dev/null
}

_run_family_override_parsers() {
    ASUS_DESKTOP_FAMILY=kde _soft asus_desktop_family >/dev/null
    ASUS_DESKTOP_FAMILY=lxqt _soft asus_desktop_family >/dev/null
    ASUS_DESKTOP_FAMILY=cinnamon _soft asus_desktop_family >/dev/null
    ASUS_DESKTOP_FAMILY=mate _soft asus_desktop_family >/dev/null
    _soft _asus_first_nonempty "" "" "kept" >/dev/null
    _soft _asus_first_nonempty >/dev/null
    _soft _asus_desktop_token_family "X-Cinnamon" >/dev/null
    _soft _asus_desktop_token_family "mate-session" >/dev/null
    _soft _asus_desktop_token_family "gnome" >/dev/null
}

_run_family_mint_probes() {
    _soft _asus_probe_mint_session_tokens "cinnamon" "" >/dev/null
    _soft _asus_probe_mint_session_tokens "" "mate" >/dev/null
    _soft _asus_probe_mint_session_tokens "" "" >/dev/null
    _soft _asus_probe_de_binary_family >/dev/null
    _soft _asus_probe_de_schema_family >/dev/null
    _soft _asus_mint_bare_gnome_family "" >/dev/null
}

_run_family_timeout_and_infer() {
    local to_dir
    # Timeout-debug + infer wayland (same-shell).
    to_dir=$(mktemp -d)
    printf '#!/bin/sh\nexit 124\n' > "$to_dir/timeout"
    chmod +x "$to_dir/timeout"
    PATH="$to_dir:$PATH" ASUS_SYSTEMCTL_ENV_TIMEOUT_SECS=1 \
        _soft _asus_systemctl_env_timeout true >/dev/null 2>&1
    PATH="$to_dir:$PATH" ASUS_SYSTEMCTL_ENV_TIMEOUT_SECS=bad \
        _soft _asus_systemctl_env_timeout true >/dev/null 2>&1
    rm -rf "$to_dir"
    # Seed systemctl env blob so infer_session_type hits wayland branch.
    _ASUS_SYSTEMCTL_ENV_BLOB=$'WAYLAND_DISPLAY=wayland-kcov\nDISPLAY=\n'
    _ASUS_SYSTEMCTL_ENV_CACHE_VALID=1
    _ASUS_SYSTEMCTL_ENV_CACHED_USER="$(id -un)"
    _ASUS_SYSTEMCTL_ENV_SKIP=""
    _soft _asus_infer_session_type "c1" >/dev/null
    _soft _asus_infer_session_type "" >/dev/null 2>&1
}

_run_family_parsers() {
    _run_family_string_parsers
    _run_family_override_parsers
    _run_family_mint_probes
    _run_family_timeout_and_infer
}

_run_proc_environ() {
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "$tmp/1"
    printf 'DISPLAY=:9\0WAYLAND_DISPLAY=wayland-9\0XDG_CURRENT_DESKTOP=XFCE:ubuntu\0' \
        > "$tmp/1/environ"
    ASUS_PROC_ENVIRON_ROOT="$tmp" _soft _asus_proc_environ_value 1 DISPLAY >/dev/null
    ASUS_PROC_ENVIRON_ROOT="$tmp" _soft _asus_proc_environ_value 1 WAYLAND_DISPLAY >/dev/null
    ASUS_PROC_ENVIRON_ROOT=/missing _soft _asus_proc_environ_value 1 DISPLAY >/dev/null
    rm -rf "$tmp"
}

_write_systemctl_env_stubs() {
    local tmp="$1"
    mkdir -p "$tmp/bin" "$tmp/run/$(id -u)"
    cat > "$tmp/bin/systemctl" <<'EOF'
#!/bin/sh
case "$XDG_RUNTIME_DIR" in
  */*) echo DISPLAY=:7; echo XDG_CURRENT_DESKTOP=KDE:ubuntu; echo XDG_SESSION_TYPE=wayland ;;
  *) exit 1 ;;
esac
EOF
    chmod +x "$tmp/bin/systemctl"
    cat > "$tmp/bin/timeout" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  case "$1" in
    --signal=*|--kill-after=*) shift ;;
    -*) shift ;;
    [0-9]*|*[0-9]s) shift; break ;;
    *) break ;;
  esac
done
exec "$@"
EOF
    chmod +x "$tmp/bin/timeout"
    cat > "$tmp/bin/loginctl" <<'EOF'
#!/bin/sh
if [ "$1" = "list-sessions" ]; then
    printf 'c1\n'
    exit 0
fi
if [ "$1" = "show-session" ]; then
    case "$4" in
        Type) echo wayland ;;
        State) echo active ;;
        Name) id -un ;;
        User) id -u ;;
        Leader) echo 1 ;;
        *) echo "" ;;
    esac
    exit 0
fi
exit 1
EOF
    chmod +x "$tmp/bin/loginctl"
}

_run_systemctl_env_lookups() {
    local user="$1"
    _soft _asus_systemctl_user_env_value "$user" DISPLAY >/dev/null
    _soft asus_session_env_value DISPLAY "$user" >/dev/null
    _soft asus_session_type "$user" >/dev/null
    _soft asus_export_session_env_args "$user" >/dev/null
    _soft find_active_session_user >/dev/null
    _soft find_active_session_id >/dev/null
}

_run_systemctl_env_timeouts() {
    local user="$1"
    ASUS_SYSTEMCTL_ENV_TIMEOUT_SECS=1 \
        _soft _asus_systemctl_user_env_value "$user" DISPLAY >/dev/null
    ASUS_SYSTEMCTL_ENV_TIMEOUT_SECS=bad \
        _soft _asus_systemctl_user_env_value "$user" DISPLAY >/dev/null
    _soft _asus_detect_desktop_family "$user" >/dev/null
    _soft _asus_infer_session_type c1 >/dev/null
    _soft _asus_session_type_from_env c1 >/dev/null
    _soft _asus_probe_mint_tokens_for_sid c1 >/dev/null
}

_run_systemctl_env() {
    local tmp user saved_path
    tmp=$(mktemp -d)
    user="$(id -un)"
    _write_systemctl_env_stubs "$tmp"
    saved_path="$PATH"
    export PATH="$tmp/bin:$PATH"
    export RUN_USER_ROOT="$tmp/run"
    _run_systemctl_env_lookups "$user"
    _run_systemctl_env_timeouts "$user"
    PATH="$saved_path"
    _soft unset RUN_USER_ROOT
    trap - RETURN
    rm -rf "$tmp"
}

_run_schema_family_helpers() {
    local tmp saved_path
    tmp=$(mktemp -d)
    cat > "$tmp/gsettings" <<'EOF'
#!/bin/sh
printf '%s\n' "${KCOV_SESSION_SCHEMA:-org.cinnamon.desktop.keybindings}"
EOF
    chmod +x "$tmp/gsettings"
    saved_path="$PATH"
    PATH="$tmp:$PATH"
    KCOV_SESSION_SCHEMA=org.cinnamon.desktop.keybindings \
        _soft _asus_probe_de_schema_family >/dev/null
    KCOV_SESSION_SCHEMA=org.mate.control-center.keybinding \
        _soft _asus_probe_de_schema_family >/dev/null
    KCOV_SESSION_SCHEMA=org.example.none \
        _soft _asus_probe_de_schema_family >/dev/null
    KCOV_SESSION_SCHEMA=org.cinnamon.desktop.keybindings \
        _soft _asus_probe_mint_schema_family ignored >/dev/null
    PATH="$saved_path"
    rm -rf "$tmp"
}

_run_family_parsers
_run_proc_environ
_run_systemctl_env
_run_schema_family_helpers
