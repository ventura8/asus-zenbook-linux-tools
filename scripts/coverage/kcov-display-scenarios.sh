#!/usr/bin/env bash
# Display-mode (sticky OSD / Mutter / settings) kcov scenarios (sourced by kcov-scenarios.sh).

_kcov_write_display_mode_py() {
    local path="$1"
    cat > "$path" <<'EOF'
#!/usr/bin/env python3
import os
import sys
args = sys.argv[1:]
if args[:1] == ["--detect"]:
    print(os.environ.get("KCOV_DISP_DETECT", ""))
    raise SystemExit(0)
if args[:1] == ["--next"]:
    print(os.environ.get("KCOV_DISP_NEXT", ""))
    raise SystemExit(0)
if args[:1] == ["--apply-profile"]:
    raise SystemExit(0)
raise SystemExit(1)
EOF
    chmod +x "$path"
    return $?
}

_kcov_disp_run() {
    local expected="$1" kcov_root="$2" label="$3" tmp="$4"
    _kcov_expect_run_env "$expected" "$kcov_root" "$label" PATH="$tmp:$PATH" \
        ASUS_DISPLAY_MODE_DISABLE_YDOTOOL=1 \
        ASUS_DISPLAY_MODE_DISABLE_XDOTOOL=1 \
        KCOV_DISP_DETECT="${KCOV_DISP_DETECT:-all}" \
        KCOV_DISP_NEXT="${KCOV_DISP_NEXT:-main_only:Main Only}" \
        RUN_USER_ROOT="$tmp/bus" DBUS_BUS_ROOT="$tmp/bus" NOTIF_ID_ROOT="$tmp/notif" \
        SYS_CLASS_ROOT="$tmp/sys" BIN_ROOT="$tmp/bin" \
        ASUS_DISPLAY_MODE_STATE_PREFIX="$tmp/disp-$label" \
        ./bin/asus-display-mode.sh
    return $?
}

_kcov_setup_display_mode_fixture() {
    local tmp="$1" uid
    uid="$(id -u)"
    _make_fake_loginctl_current_user "$tmp"
    _make_fake_sudo_script "$tmp"
    mkdir -p "$tmp/bus/$uid" "$tmp/notif/$uid" "$tmp/sys/backlight/asus_screenpad" "$tmp/bin"
    _kcov_bind_unix_bus "$tmp/bus/$uid/bus"
    printf '255\n' > "$tmp/sys/backlight/asus_screenpad/brightness"
    chmod 666 "$tmp/sys/backlight/asus_screenpad/brightness"
    printf '#!/bin/sh\necho "(uint32 7,)"\n' > "$tmp/gdbus"
    chmod +x "$tmp/gdbus"
    return $?
}

_kcov_run_display_mode_bus_cases() {
    local kcov_root="$1" tmp="$2"
    printf '%s' "$_KCOV_STUB_EXIT0" > "$tmp/ydotool"
    chmod +x "$tmp/ydotool"
    _kcov_expect_run_env "0" "$kcov_root" disp_ydotool_success \
        PATH="$tmp:$PATH" \
        ASUS_DISPLAY_MODE_FORCE_LOCAL=1 \
        ASUS_DISPLAY_MODE_STATE_PREFIX="$tmp/disp" \
        ASUS_DISPLAY_MODE_IDLE_SECS=1 \
        ./bin/asus-display-mode.sh
    rm -f "$tmp/ydotool"
    printf '%s' "$_KCOV_STUB_EXIT0" > "$tmp/xdotool"
    chmod +x "$tmp/xdotool"
    _kcov_expect_run_env "0" "$kcov_root" disp_xdotool_success \
        PATH="$tmp:$PATH" \
        ASUS_DISPLAY_MODE_DISABLE_YDOTOOL=1 \
        ASUS_DISPLAY_MODE_FORCE_LOCAL=1 \
        ASUS_DISPLAY_MODE_FORCE_XDOTOOL=1 \
        ASUS_DISPLAY_MODE_STATE_PREFIX="$tmp/disp-x11" \
        ASUS_DISPLAY_MODE_IDLE_SECS=1 \
        DISPLAY=:0 XDG_SESSION_TYPE=x11 \
        ./bin/asus-display-mode.sh
    rm -f "$tmp/xdotool"
    _kcov_write_display_mode_py "$tmp/bin/asus_display_mode.py"
    KCOV_DISP_DETECT=all KCOV_DISP_NEXT="main_only:Main Only" \
        _kcov_disp_run "0" "$kcov_root" disp_mutter_cycle "$tmp"
    printf '%s' "$_KCOV_STUB_EXIT0" > "$tmp/gnome-control-center"
    chmod +x "$tmp/gnome-control-center"
    _kcov_expect_run_env "0" "$kcov_root" disp_settings_fallback \
        PATH="$tmp:$PATH" \
        ASUS_DISPLAY_MODE_DISABLE_YDOTOOL=1 \
        ASUS_DISPLAY_MODE_DISABLE_XDOTOOL=1 \
        ASUS_DISPLAY_MODE_DISABLE_MUTTER_CYCLE=1 \
        ASUS_DESKTOP_FAMILY=gnome \
        RUN_USER_ROOT="$tmp/bus" DBUS_BUS_ROOT="$tmp/bus" \
        ASUS_DISPLAY_MODE_STATE_PREFIX="$tmp/disp-settings" \
        ./bin/asus-display-mode.sh
    rm -f "$tmp/gnome-control-center"
    _kcov_expect_run_env "1" "$kcov_root" disp_ydotool_fail \
        ASUS_DISPLAY_MODE_DISABLE_YDOTOOL=1 \
        ASUS_DISPLAY_MODE_DISABLE_XDOTOOL=1 \
        ASUS_DISPLAY_MODE_DISABLE_MUTTER_CYCLE=1 \
        ASUS_DISPLAY_MODE_DISABLE_SETTINGS=1 \
        ASUS_DISPLAY_MODE_STATE_PREFIX="$tmp/disp-ydotool-fail" \
        ./bin/asus-display-mode.sh
    return $?
}

_kcov_run_display_mode_sticky_cases() {
    local kcov_root="$1" tmp="$2"
    printf '%s' "$_KCOV_STUB_EXIT0" > "$tmp/ydotool"
    chmod +x "$tmp/ydotool"
    _kcov_expect_run_env "0" "$kcov_root" disp_sticky_open \
        PATH="$tmp:$PATH" \
        ASUS_DISPLAY_MODE_FORCE_LOCAL=1 \
        ASUS_DISPLAY_MODE_STATE_PREFIX="$tmp/disp-sticky" \
        ASUS_DISPLAY_MODE_IDLE_SECS=30 \
        ASUS_DISPLAY_MODE_DUP_MS=1 \
        ./bin/asus-display-mode.sh
    _kcov_expect_run_env "0" "$kcov_root" disp_sticky_cycle \
        PATH="$tmp:$PATH" \
        ASUS_DISPLAY_MODE_FORCE_LOCAL=1 \
        ASUS_DISPLAY_MODE_STATE_PREFIX="$tmp/disp-sticky" \
        ASUS_DISPLAY_MODE_IDLE_SECS=30 \
        ASUS_DISPLAY_MODE_DUP_MS=1 \
        ./bin/asus-display-mode.sh
    # Immediate re-invoke should hit duplicate suppression while session inactive.
    _kcov_expect_run_env "0" "$kcov_root" disp_dup_suppress \
        PATH="$tmp:$PATH" \
        ASUS_DISPLAY_MODE_FORCE_LOCAL=1 \
        ASUS_DISPLAY_MODE_STATE_PREFIX="$tmp/disp-dup" \
        ASUS_DISPLAY_MODE_IDLE_SECS=1 \
        ASUS_DISPLAY_MODE_DUP_MS=60000 \
        ./bin/asus-display-mode.sh
    _kcov_expect_run_env "0" "$kcov_root" disp_dup_suppress_hit \
        PATH="$tmp:$PATH" \
        ASUS_DISPLAY_MODE_FORCE_LOCAL=1 \
        ASUS_DISPLAY_MODE_STATE_PREFIX="$tmp/disp-dup" \
        ASUS_DISPLAY_MODE_IDLE_SECS=1 \
        ASUS_DISPLAY_MODE_DUP_MS=60000 \
        ./bin/asus-display-mode.sh
    rm -f "$tmp/ydotool"
    return $?
}

_run_kcov_display_mode_scenarios() {
    local kcov_root="$1"
    (
        local tmp
        tmp=$(mktemp -d)
        trap _kcov_rm_scenario_tmp EXIT
        _kcov_setup_display_mode_fixture "$tmp"
        _kcov_run_display_mode_bus_cases "$kcov_root" "$tmp"
        _kcov_run_display_mode_sticky_cases "$kcov_root" "$tmp"
    )
    return $?
}
