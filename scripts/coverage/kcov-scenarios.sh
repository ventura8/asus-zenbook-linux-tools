#!/usr/bin/env bash

_kcov_driver() {
    printf '%s\n' "./scripts/coverage/drivers/$1"
}

_run_kcov_camera_not_writable() {
    local kcov_root="$1" camera_node="$2" platform_root
    platform_root=$(dirname "$camera_node")
    if [ "$(id -u)" -eq 0 ] && command -v runuser >/dev/null 2>&1; then
        # Root+runuser path cannot use kcov tracing, but must still capture logs and
        # fail fast on unexpected exits (expected: camera node not writable → 1).
        _kcov_expect_direct_run_env "1" "$kcov_root" cam_not_writable \
            SYS_PLATFORM_ROOT="$platform_root" ASUS_CAMERA_NODE="$camera_node" \
            runuser -u nobody -- ./bin/asus-camera-toggle.sh
        return $?
    fi
    _kcov_expect_run_env "1" "$kcov_root" cam_not_writable \
        SYS_PLATFORM_ROOT="$platform_root" ASUS_CAMERA_NODE="$camera_node" \
        ./bin/asus-camera-toggle.sh
}

_run_kcov_camera_scenarios() {
    local kcov_root="$1"
    _kcov_expect_run "1" "$kcov_root" cam_no_node ./bin/asus-camera-toggle.sh
    (
        local tmp
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        echo 1 > "$tmp/c"; chmod 666 "$tmp/c"
        _kcov_expect_run_env "0" "$kcov_root" cam_enabled \
            SYS_PLATFORM_ROOT="$tmp" ASUS_CAMERA_NODE="$tmp/c" ./bin/asus-camera-toggle.sh
        echo 0 > "$tmp/c"
        _kcov_expect_run_env "0" "$kcov_root" cam_disabled \
            SYS_PLATFORM_ROOT="$tmp" ASUS_CAMERA_NODE="$tmp/c" ./bin/asus-camera-toggle.sh
        # Absolute PREFIX + icon-dir overrides (template discovery branches).
        mkdir -p "$tmp/prefix/share/icons/hicolor/scalable/apps" "$tmp/icons"
        printf '<svg><path stroke="#000"/></svg>\n' > "$tmp/icons/asus-camera-on-symbolic.svg"
        printf '<svg><path stroke="#000"/></svg>\n' > "$tmp/icons/asus-camera-off-symbolic.svg"
        _kcov_expect_run_env "0" "$kcov_root" cam_icon_overrides \
            SYS_PLATFORM_ROOT="$tmp" ASUS_CAMERA_NODE="$tmp/c" \
            PREFIX="$tmp/prefix" ASUS_CAMERA_ICON_DIR="$tmp/icons" \
            ASUS_CAMERA_FORCE_KEYCAP=1 ASUS_CAMERA_APP_NAME_COLOR='#abc' \
            ./bin/asus-camera-toggle.sh
        _kcov_expect_run_env "0" "$kcov_root" cam_relative_prefix_warn \
            SYS_PLATFORM_ROOT="$tmp" ASUS_CAMERA_NODE="$tmp/c" \
            PREFIX=relative ASUS_CAMERA_ICON_DIR=relative \
            ./bin/asus-camera-toggle.sh
        echo 1 > "$tmp/c"
        if id nobody >/dev/null 2>&1; then
            chown nobody: "$tmp/c" 2>/dev/null || chown nobody:nogroup "$tmp/c" 2>/dev/null || true
        fi
        chmod 444 "$tmp/c"
        _run_kcov_camera_not_writable "$kcov_root" "$tmp/c"
    )

    (
        local tmp
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        mkdir -p "$tmp/usb/dev1"
        printf '13d3' > "$tmp/usb/dev1/idVendor"
        printf '1234' > "$tmp/usb/dev1/idProduct"
        printf '0e' > "$tmp/usb/dev1/bDeviceClass"
        printf '1' > "$tmp/usb/dev1/authorized"; chmod 666 "$tmp/usb/dev1/authorized"
        _kcov_expect_run_env "0" "$kcov_root" cam_usb_match SYS_BUS_USB_ROOT="$tmp/usb" ./bin/asus-camera-toggle.sh
    )

    (
        local tmp
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        mkdir -p "$tmp/usb/dev1" "$tmp/usb/dev1:1.0"
        printf '13d3' > "$tmp/usb/dev1/idVendor"
        printf '4321' > "$tmp/usb/dev1/idProduct"
        printf 'ff' > "$tmp/usb/dev1/bDeviceClass"
        printf '0e' > "$tmp/usb/dev1:1.0/bInterfaceClass"
        printf '1' > "$tmp/usb/dev1/authorized"; chmod 666 "$tmp/usb/dev1/authorized"
        _kcov_expect_run_env "0" "$kcov_root" cam_usb_interface_match SYS_BUS_USB_ROOT="$tmp/usb" ./bin/asus-camera-toggle.sh
    )

    (
        local tmp
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        mkdir -p "$tmp/usb/dev1"
        printf '13d3' > "$tmp/usb/dev1/idVendor"
        printf '1234' > "$tmp/usb/dev1/idProduct"
        printf 'ff' > "$tmp/usb/dev1/bDeviceClass"
        printf 'USB WebCam Device' > "$tmp/usb/dev1/product"
        printf '1' > "$tmp/usb/dev1/authorized"; chmod 666 "$tmp/usb/dev1/authorized"
        _kcov_expect_run_env "0" "$kcov_root" cam_usb_product_match SYS_BUS_USB_ROOT="$tmp/usb" ./bin/asus-camera-toggle.sh
    )

    (
        local tmp
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        ln -s /nonexistent/camera-node "$tmp/c"
        _kcov_expect_run_env "1" "$kcov_root" cam_symlink_unwritable \
            SYS_PLATFORM_ROOT="$tmp" ASUS_CAMERA_NODE="$tmp/c" ./bin/asus-camera-toggle.sh
    )
    _kcov_expect_run_env "0" "$kcov_root" cam_helpers \
        REPO_ROOT="$(pwd)" "$(_kcov_driver camera_helpers.sh)"
}

_make_fake_powerprofilesctl() {
    local bin_dir="$1" state_file="$2" set_mode="${3:-ok}"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/powerprofilesctl" <<EOF
#!/bin/sh
case "\$1" in
  get)
    tr -d '[:space:]' < "$state_file"
    ;;
  set)
    if [ "$set_mode" = "fail" ]; then
      echo "powerprofilesctl set failed" >&2
      exit 1
    fi
    printf '%s\\n' "\$2" > "$state_file"
    ;;
  *)
    exit 1
    ;;
esac
EOF
    chmod +x "$bin_dir/powerprofilesctl"
}

_run_kcov_fan_scenarios() {
    local kcov_root="$1"
    local tmp mode
    # Force sysfs path: host powerprofilesctl would otherwise succeed with no node.
    _kcov_expect_run_env "1" "$kcov_root" fan_no_node \
        ASUS_FAN_USE_PPD=0 SYS_PLATFORM_ROOT="/tmp/asus-fan-missing-$$" \
        ./bin/asus-fan-toggle.sh
    for mode in 0 1 2; do
        (
            tmp=$(mktemp -d)
            trap 'rm -rf "$tmp"' EXIT
            echo "$mode" > "$tmp/f"; chmod 666 "$tmp/f"
            _kcov_expect_run_env "0" "$kcov_root" "fan_mode_$mode" \
                SYS_PLATFORM_ROOT="$tmp" ASUS_FAN_NODE="$tmp/f" ASUS_FAN_USE_PPD=0 \
                ./bin/asus-fan-toggle.sh
        )
    done
    (
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        echo 0 > "$tmp/f"; chmod 666 "$tmp/f"
        printf 'balanced\n' > "$tmp/ppd"
        _make_fake_powerprofilesctl "$tmp/bin" "$tmp/ppd"
        _kcov_expect_run_env "0" "$kcov_root" fan_ppd_balanced \
            PATH="$tmp/bin:$PATH" SYS_PLATFORM_ROOT="$tmp" ASUS_FAN_NODE="$tmp/f" \
            ASUS_FAN_USE_PPD=1 ./bin/asus-fan-toggle.sh
    )
    (
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        echo 1 > "$tmp/f"; chmod 666 "$tmp/f"
        printf 'performance\n' > "$tmp/ppd"
        _make_fake_powerprofilesctl "$tmp/bin" "$tmp/ppd"
        _kcov_expect_run_env "0" "$kcov_root" fan_ppd_performance \
            PATH="$tmp/bin:$PATH" SYS_PLATFORM_ROOT="$tmp" ASUS_FAN_NODE="$tmp/f" \
            ASUS_FAN_USE_PPD=1 ./bin/asus-fan-toggle.sh
    )
    (
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        echo 2 > "$tmp/f"; chmod 666 "$tmp/f"
        printf 'power-saver\n' > "$tmp/ppd"
        _make_fake_powerprofilesctl "$tmp/bin" "$tmp/ppd"
        _kcov_expect_run_env "0" "$kcov_root" fan_ppd_power_saver \
            PATH="$tmp/bin:$PATH" SYS_PLATFORM_ROOT="$tmp" ASUS_FAN_NODE="$tmp/f" \
            ASUS_FAN_USE_PPD=1 ./bin/asus-fan-toggle.sh
    )
    (
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        echo 0 > "$tmp/f"; chmod 666 "$tmp/f"
        printf 'balanced\n' > "$tmp/ppd"
        _make_fake_powerprofilesctl "$tmp/bin" "$tmp/ppd" fail
        _kcov_expect_run_env "0" "$kcov_root" fan_ppd_set_fallback \
            PATH="$tmp/bin:$PATH" SYS_PLATFORM_ROOT="$tmp" ASUS_FAN_NODE="$tmp/f" \
            ASUS_FAN_USE_PPD=1 ./bin/asus-fan-toggle.sh
    )
    (
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        echo 0 > "$tmp/f"; chmod 666 "$tmp/f"
        printf 'weird-profile\n' > "$tmp/ppd"
        _make_fake_powerprofilesctl "$tmp/bin" "$tmp/ppd"
        _kcov_expect_run_env "0" "$kcov_root" fan_ppd_unrecognized \
            PATH="$tmp/bin:$PATH" SYS_PLATFORM_ROOT="$tmp" ASUS_FAN_NODE="$tmp/f" \
            ASUS_FAN_USE_PPD=1 ./bin/asus-fan-toggle.sh
    )
    (
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        echo 0 > "$tmp/f"; chmod 666 "$tmp/f"
        _kcov_expect_run_env "0" "$kcov_root" fan_ppd_disabled \
            SYS_PLATFORM_ROOT="$tmp" ASUS_FAN_NODE="$tmp/f" \
            ASUS_FAN_USE_PPD=0 ./bin/asus-fan-toggle.sh
        _kcov_expect_run_env "1" "$kcov_root" fan_ppd_invalid \
            SYS_PLATFORM_ROOT="$tmp" ASUS_FAN_NODE="$tmp/f" \
            ASUS_FAN_USE_PPD=2 ./bin/asus-fan-toggle.sh
        # Outside override is ignored; empty platform tree → no node (sysfs-only).
        _kcov_expect_run_env "1" "$kcov_root" fan_node_outside_warn \
            SYS_PLATFORM_ROOT="$tmp/empty-platform" ASUS_FAN_NODE="/etc/hostname" \
            ASUS_FAN_USE_PPD=0 ./bin/asus-fan-toggle.sh
    )
    _kcov_expect_run_env "0" "$kcov_root" fan_helpers \
        REPO_ROOT="$(pwd)" "$(_kcov_driver fan_helpers.sh)"
}

# shellcheck source=scripts/coverage/kcov-screenpad-scenarios.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kcov-screenpad-scenarios.sh"

_run_kcov_installed_lib_source_scenarios() {
    # Force installed-lib bootstrap without /tmp product copies (basename collide).
    # Isolate sysfs + disable fan PPD (live ZenBook / powerprofilesctl), and stub
    # loginctl so screenshot/control-center/display-mode cannot succeed via the
    # host session (expected_success stays a single exit, usually 1).
    local kcov_root="$1" script_path="$2" label_prefix="$3" expected_success="${4:-0}" status=0
    (
        local repo_root tmp_root had_errexit=0 run_status=0
        repo_root="$(_kcov_repo_root)"
        tmp_root=$(mktemp -d)
        mkdir -p "$tmp_root/empty"
        _kcov_make_stub "$tmp_root/loginctl"
        trap 'rm -rf "$tmp_root"' EXIT INT TERM
        case "$-" in *e*) had_errexit=1 ;; esac
        _kcov_expect_run_env "$expected_success" "$kcov_root" "${label_prefix}_installed_lib" \
            PATH="$tmp_root:$PATH" \
            ASUS_FORCE_INSTALLED_LIB=1 ASUS_INSTALLED_LIB_DIR="$repo_root/lib" \
            ASUS_FAN_USE_PPD=0 SYS_PLATFORM_ROOT="$tmp_root/empty" \
            SYS_CLASS_ROOT="$tmp_root/empty" "$script_path" \
            || run_status=$?
        _kcov_expect_run_env "1" "$kcov_root" "${label_prefix}_missing_lib" \
            PATH="$tmp_root:$PATH" \
            ASUS_FORCE_INSTALLED_LIB=1 ASUS_INSTALLED_LIB_DIR="$tmp_root/empty" \
            ASUS_FAN_USE_PPD=0 SYS_PLATFORM_ROOT="$tmp_root/empty" \
            SYS_CLASS_ROOT="$tmp_root/empty" "$script_path" \
            || run_status=$?
        _restore_errexit_state "$had_errexit"
        trap - EXIT INT TERM
        rm -rf "$tmp_root"
        exit "$run_status"
    ) || status=$?
    return "$status"
}

_run_kcov_bin_scenarios() {
    local kcov_root="$1"
    _run_kcov_camera_scenarios "$kcov_root"
    _run_kcov_fan_scenarios "$kcov_root"
    _run_kcov_screenpad_scenarios "$kcov_root"
    _run_kcov_installed_lib_source_scenarios "$kcov_root" ./bin/asus-camera-toggle.sh cam "1"
    _run_kcov_installed_lib_source_scenarios "$kcov_root" ./bin/asus-fan-toggle.sh fan "1"
    _run_kcov_installed_lib_source_scenarios "$kcov_root" ./bin/asus-screenpad-toggle.sh sp "1"
    _run_kcov_installed_lib_source_scenarios "$kcov_root" ./bin/asus-screenpad-brightness.sh spb "1"
    _run_kcov_installed_lib_source_scenarios "$kcov_root" ./bin/asus-screenshot.sh ss "1"
    _run_kcov_installed_lib_source_scenarios "$kcov_root" ./bin/asus-control-center.sh cc "1"
    _run_kcov_installed_lib_source_scenarios "$kcov_root" ./bin/asus-display-mode.sh disp "1"
    _run_kcov_display_mode_scenarios "$kcov_root"
}

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
}

_kcov_run_display_mode_bus_cases() {
    local kcov_root="$1" tmp="$2"
    printf '#!/bin/sh\nexit 0\n' > "$tmp/ydotool"
    chmod +x "$tmp/ydotool"
    _kcov_expect_run_env "0" "$kcov_root" disp_ydotool_success \
        PATH="$tmp:$PATH" \
        ASUS_DISPLAY_MODE_FORCE_LOCAL=1 \
        ASUS_DISPLAY_MODE_STATE_PREFIX="$tmp/disp" \
        ASUS_DISPLAY_MODE_IDLE_SECS=1 \
        ./bin/asus-display-mode.sh
    rm -f "$tmp/ydotool"
    printf '#!/bin/sh\nexit 0\n' > "$tmp/xdotool"
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
    printf '#!/bin/sh\nexit 0\n' > "$tmp/gnome-control-center"
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
}

_kcov_run_display_mode_sticky_cases() {
    local kcov_root="$1" tmp="$2"
    printf '#!/bin/sh\nexit 0\n' > "$tmp/ydotool"
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
}

_run_kcov_display_mode_scenarios() {
    local kcov_root="$1"
    (
        local tmp
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        _kcov_setup_display_mode_fixture "$tmp"
        _kcov_run_display_mode_bus_cases "$kcov_root" "$tmp"
        _kcov_run_display_mode_sticky_cases "$kcov_root" "$tmp"
    )
}

_run_kcov_sound_scenarios() {
    local kcov_root="$1"
    (
        local tmp
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        mkdir -p "$tmp/snd" "$tmp/asound"
        _kcov_expect_run_env "1" "$kcov_root" snd_no_card DEV_SND_ROOT="$tmp/snd" PROC_ASOUND_ROOT="$tmp/asound" \
            ./bin/asus-sound-fix.sh
    )
    (
        local tmp
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        mkdir -p "$tmp/snd" "$tmp/asound/card0"
        touch "$tmp/snd/hwC0D0"
        printf "AD1988\n" > "$tmp/asound/card0/codec#0"
        _kcov_expect_run_env "1" "$kcov_root" snd_mismatch_codec DEV_SND_ROOT="$tmp/snd" PROC_ASOUND_ROOT="$tmp/asound" \
            ./bin/asus-sound-fix.sh
    )
    (
        local tmp
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        mkdir -p "$tmp/snd" "$tmp/asound/card0" "$tmp/bin" "$tmp/empty-bin"
        touch "$tmp/snd/hwC0D0"
        printf "ALC294\n" > "$tmp/asound/card0/codec#0"
        # Isolate from checkout asus_hda_verb.py so the missing-tool path is covered.
        cp ./bin/asus-sound-fix.sh "$tmp/asus-sound-fix.sh"
        _kcov_expect_run_env "1" "$kcov_root" snd_no_hda_verb \
            PATH="$tmp/bin:$PATH" BIN_ROOT="$tmp/empty-bin" \
            DEV_SND_ROOT="$tmp/snd" PROC_ASOUND_ROOT="$tmp/asound" \
            "$tmp/asus-sound-fix.sh"
        _kcov_make_stub "$tmp/bin/hda-verb" 'exit 1'
        _kcov_expect_run_env "1" "$kcov_root" snd_fail_verb PATH="$tmp/bin:$PATH" DEV_SND_ROOT="$tmp/snd" PROC_ASOUND_ROOT="$tmp/asound" \
            ./bin/asus-sound-fix.sh
        _kcov_make_stub "$tmp/bin/hda-verb"
        _kcov_expect_run_env "0" "$kcov_root" snd_success PATH="$tmp/bin:$PATH" DEV_SND_ROOT="$tmp/snd" \
            PROC_ASOUND_ROOT="$tmp/asound" ./bin/asus-sound-fix.sh
    )
}

_run_kcov_sound_helper_scenarios() {
    local kcov_root="$1"
    (
        local tmp driver
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        driver="$(_kcov_driver sound_helpers.sh)"
        mkdir -p "$tmp/snd" "$tmp/asound/card0" "$tmp/bin" "$tmp/dest"
        touch "$tmp/snd/hwC0D0"
        printf "ALC294\n" > "$tmp/asound/card0/codec#0"
        printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/hda-verb"
        chmod +x "$tmp/bin/hda-verb"
        _kcov_expect_run_env "0" "$kcov_root" snd_helpers PATH="$tmp/bin:$PATH" \
            DEV_SND_ROOT="$tmp/snd" PROC_ASOUND_ROOT="$tmp/asound" SOUND_HELPER_MODE=apply \
            REPO_ROOT="$(pwd)" "$driver"
        _kcov_expect_run_env "0" "$kcov_root" snd_helper_python_fallback PATH="/usr/bin:/bin" \
            DEV_SND_ROOT="$tmp/snd" PROC_ASOUND_ROOT="$tmp/asound" SOUND_HELPER_MODE=fallback \
            REPO_ROOT="$(pwd)" "$driver"
        cat <<'EOF' > "$tmp/bin/hda-verb"
#!/bin/sh
if [ "${HDA_VERB_FAIL_ARG:-}" = "${4:-}" ]; then
    exit 1
fi
exit 0
EOF
        chmod +x "$tmp/bin/hda-verb"
        _kcov_expect_run_env "1" "$kcov_root" snd_helper_second_verb_fail PATH="$tmp/bin:$PATH" \
            HDA_VERB_FAIL_ARG=0x4a4b DEV_SND_ROOT="$tmp/snd" PROC_ASOUND_ROOT="$tmp/asound" \
            SOUND_HELPER_MODE=verbs REPO_ROOT="$(pwd)" "$driver"
        _kcov_expect_run_env "1" "$kcov_root" snd_helper_third_verb_fail PATH="$tmp/bin:$PATH" \
            HDA_VERB_FAIL_ARG=0xf DEV_SND_ROOT="$tmp/snd" PROC_ASOUND_ROOT="$tmp/asound" \
            SOUND_HELPER_MODE=verbs REPO_ROOT="$(pwd)" "$driver"
        _kcov_expect_run_env "1" "$kcov_root" snd_helper_fourth_verb_fail PATH="$tmp/bin:$PATH" \
            HDA_VERB_FAIL_ARG=0x74 DEV_SND_ROOT="$tmp/snd" PROC_ASOUND_ROOT="$tmp/asound" \
            SOUND_HELPER_MODE=verbs REPO_ROOT="$(pwd)" "$driver"
        _kcov_expect_run_env "0" "$kcov_root" snd_helper_remove_installed_files PATH="$tmp/bin:$PATH" \
            DEV_SND_ROOT="$tmp/snd" PROC_ASOUND_ROOT="$tmp/asound" DESTDIR="$tmp/dest" \
            SOUND_HELPER_MODE=remove REPO_ROOT="$(pwd)" "$driver"
        printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/hda-verb"
        chmod +x "$tmp/bin/hda-verb"
        _kcov_expect_run_env "0" "$kcov_root" snd_helper_poll_loop PATH="$tmp/bin:$PATH" \
            DEV_SND_ROOT="$tmp/snd" PROC_ASOUND_ROOT="$tmp/asound" SOUND_HWDEV_POLL_ATTEMPTS=1 \
            SOUND_HELPER_MODE=apply REPO_ROOT="$(pwd)" "$driver"
    )
}

_run_kcov_control_center_scenarios() {
    local kcov_root="$1"
    (
        local tmp
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        _kcov_make_stub "$tmp/loginctl"
        _kcov_expect_run_env "1" "$kcov_root" cc_no_session PATH="$tmp:$PATH" ./bin/asus-control-center.sh
    )
    (
        local tmp
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        _make_fake_loginctl_script "$tmp"
        _kcov_make_stub "$tmp/id" 'exit 1'
        _kcov_expect_run_env "1" "$kcov_root" cc_invalid_user PATH="$tmp:$PATH" ./bin/asus-control-center.sh
    )
    (
        local tmp uid
        tmp=$(mktemp -d)
        uid="$(id -u)"
        trap 'rm -rf "$tmp"' EXIT
        _make_fake_loginctl_current_user "$tmp"
        _make_fake_sudo_script "$tmp"
        _kcov_expect_run_env "1" "$kcov_root" cc_no_bus PATH="$tmp:$PATH" \
            RUN_USER_ROOT="$tmp/nonexistent_bus_dir" DBUS_BUS_ROOT="$tmp/nonexistent_bus_dir" \
            ./bin/asus-control-center.sh

        mkdir -p "$tmp/bus_root/$uid"
        _kcov_bind_unix_bus "$tmp/bus_root/$uid/bus"
        # Keep Settings stubs alive past ASUS_LAUNCH_CHECK_SECS (default 0.2).
        printf '#!/bin/sh\nsleep 1; exit 0\n' > "$tmp/gdbus"
        chmod +x "$tmp/gdbus"
        _kcov_expect_run_env "0" "$kcov_root" cc_gdbus_success PATH="$tmp:$PATH" \
            RUN_USER_ROOT="$tmp/bus_root" DBUS_BUS_ROOT="$tmp/bus_root" \
            ASUS_LAUNCH_CHECK_SECS=0.01 ./bin/asus-control-center.sh

        printf '#!/bin/sh\nexit 1\n' > "$tmp/gdbus"
        chmod +x "$tmp/gdbus"
        printf '#!/bin/sh\nsleep 1; exit 0\n' > "$tmp/systemsettings"
        chmod +x "$tmp/systemsettings"
        _kcov_expect_run_env "0" "$kcov_root" cc_systemsettings_success PATH="$tmp:$PATH" \
            RUN_USER_ROOT="$tmp/bus_root" DBUS_BUS_ROOT="$tmp/bus_root" \
            ASUS_LAUNCH_CHECK_SECS=0.01 ./bin/asus-control-center.sh

        rm -f "$tmp/systemsettings"
        _run_kcov_cc_desktop_runs "$kcov_root" "$tmp"
    )
    _kcov_expect_run_env "0" "$kcov_root" cc_dispatch_helpers \
        REPO_ROOT="$(pwd)" "$(_kcov_driver control_center_helpers.sh)"
    _kcov_expect_run_env "0" "$kcov_root" cc_dispatch_installed_lib \
        ASUS_FORCE_INSTALLED_LIB=1 ASUS_INSTALLED_LIB_DIR="$(pwd)/lib" \
        REPO_ROOT="$(pwd)" "$(_kcov_driver control_center_helpers.sh)"
    _kcov_expect_run_env "1" "$kcov_root" cc_dispatch_missing_lib \
        ASUS_FORCE_INSTALLED_LIB=1 ASUS_INSTALLED_LIB_DIR="/missing-asus-kcov-lib" \
        REPO_ROOT="$(pwd)" "$(_kcov_driver control_center_helpers.sh)"
}

_run_kcov_screenshot_scenarios() {
    local kcov_root="$1"
    (
        local tmp
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        _kcov_make_stub "$tmp/loginctl"
        _kcov_expect_run_env "1" "$kcov_root" ss_no_session PATH="$tmp:$PATH" ./bin/asus-screenshot.sh
    )
    (
        local tmp
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        _make_fake_loginctl_script "$tmp"
        _kcov_expect_run_env "1" "$kcov_root" ss_unknown_uid PATH="$tmp:$PATH" ./bin/asus-screenshot.sh
    )
    (
        local tmp uid
        tmp=$(mktemp -d)
        uid="$(id -u)"
        trap 'rm -rf "$tmp"' EXIT
        _make_fake_loginctl_current_user "$tmp"
        printf '#!/bin/sh\nexit 0\n' > "$tmp/gdbus"
        chmod +x "$tmp/gdbus"
        _make_fake_sudo_script "$tmp"
        mkdir -p "$tmp/bus_root/$uid"
        _kcov_bind_unix_bus "$tmp/bus_root/$uid/bus"
        _kcov_expect_run_env "0" "$kcov_root" ss_success PATH="$tmp:$PATH" \
            RUN_USER_ROOT="$tmp/bus_root" ./bin/asus-screenshot.sh
    )
}


# Install/uninstall/product-lib kcov scenarios live in a sibling module to keep
# this file under the repository line-count limit.
_KCOV_SCENARIOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/coverage/kcov-install-scenarios.sh
source "$_KCOV_SCENARIOS_DIR/kcov-install-scenarios.sh"
