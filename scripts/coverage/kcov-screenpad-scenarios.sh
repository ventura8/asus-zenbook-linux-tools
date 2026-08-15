#!/usr/bin/env bash
# ScreenPad toggle + brightness kcov scenarios (sourced by kcov-scenarios.sh).

_kcov_screenpad_brightness_osd_setup() {
    # Caller owns tmp lifecycle (mktemp + EXIT trap). $1=tmp $2=gdbus body.
    local tmp="$1" gdbus_body="$2" uid
    uid="$(id -u)"
    mkdir -p "$tmp/sp" "$tmp/bus/$uid" "$tmp/mock"
    echo 100 > "$tmp/sp/brightness"; echo 255 > "$tmp/sp/max_brightness"
    chmod 666 "$tmp/sp/brightness"
    _make_fake_loginctl_current_user "$tmp/mock"
    _make_fake_sudo_script "$tmp/mock"
    printf '%s\n' "$gdbus_body" > "$tmp/mock/gdbus"
    chmod +x "$tmp/mock/gdbus"
    _kcov_bind_unix_bus "$tmp/bus/$uid/bus"
}

_run_kcov_screenpad_brightness_scenarios() {
    local kcov_root="$1"
    local tmp
    _kcov_expect_run "1" "$kcov_root" spb_usage ./bin/asus-screenpad-brightness.sh
    (
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        mkdir -p "$tmp/sp"
        echo 100 > "$tmp/sp/brightness"; echo 255 > "$tmp/sp/max_brightness"
        chmod 666 "$tmp/sp/brightness"
        _kcov_expect_run_env "0" "$kcov_root" spb_up ASUS_SCREENPAD_NODE="$tmp/sp/brightness" \
            ./bin/asus-screenpad-brightness.sh up
        _kcov_expect_run_env "0" "$kcov_root" spb_down ASUS_SCREENPAD_NODE="$tmp/sp/brightness" \
            ./bin/asus-screenpad-brightness.sh down
        _kcov_expect_run_env "0" "$kcov_root" spb_get ASUS_SCREENPAD_NODE="$tmp/sp/brightness" \
            ./bin/asus-screenpad-brightness.sh get
        _kcov_expect_run_env "0" "$kcov_root" spb_set ASUS_SCREENPAD_NODE="$tmp/sp/brightness" \
            ./bin/asus-screenpad-brightness.sh set 50%
        _kcov_expect_run_env "0" "$kcov_root" spb_set_raw ASUS_SCREENPAD_NODE="$tmp/sp/brightness" \
            ./bin/asus-screenpad-brightness.sh set 40
        _kcov_expect_run_env "1" "$kcov_root" spb_set_invalid ASUS_SCREENPAD_NODE="$tmp/sp/brightness" \
            ./bin/asus-screenpad-brightness.sh set bogus
        chmod a-w "$tmp/sp/brightness"
        _kcov_expect_run_env "1" "$kcov_root" spb_not_writable ASUS_SCREENPAD_NODE="$tmp/sp/brightness" \
            ./bin/asus-screenpad-brightness.sh up
    )
    (
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        _kcov_screenpad_brightness_osd_setup "$tmp" "$(cat <<'EOF'
#!/bin/sh
case "$*" in
  *ShowOsd*|*ShowOSD*|*brightnessChanged*|*showProgress*) exit 1 ;;
  *Notifications.Notify*) echo '(uint32 42,)'; exit 0 ;;
  *) exit 1 ;;
esac
EOF
)"
        _kcov_expect_run_env "0" "$kcov_root" spb_notify_fallback \
            ASUS_SCREENPAD_NODE="$tmp/sp/brightness" \
            RUN_USER_ROOT="$tmp/bus" PATH="$tmp/mock:$PATH" \
            ./bin/asus-screenpad-brightness.sh up
    )
    (
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        _kcov_screenpad_brightness_osd_setup "$tmp" "$(cat <<'EOF'
#!/bin/sh
case "$*" in
  *ShowOsd*) exit 1 ;;
  *brightnessChanged*) echo '(true,)'; exit 0 ;;
  *) exit 1 ;;
esac
EOF
)"
        _kcov_expect_run_env "0" "$kcov_root" spb_plasma_osd \
            ASUS_SCREENPAD_NODE="$tmp/sp/brightness" \
            RUN_USER_ROOT="$tmp/bus" PATH="$tmp/mock:$PATH" \
            ./bin/asus-screenpad-brightness.sh up
    )
    (
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        _kcov_screenpad_brightness_osd_setup "$tmp" "$(cat <<'EOF'
#!/bin/sh
case "$*" in
  *ShowOsd*) exit 1 ;;
  *brightnessChanged*|*showProgress*) exit 1 ;;
  *ShowOSD*) echo '()'; exit 0 ;;
  *) exit 1 ;;
esac
EOF
)"
        _kcov_expect_run_env "0" "$kcov_root" spb_cinnamon_osd \
            ASUS_SCREENPAD_NODE="$tmp/sp/brightness" \
            ASUS_DESKTOP_FAMILY=cinnamon \
            RUN_USER_ROOT="$tmp/bus" PATH="$tmp/mock:$PATH" \
            ./bin/asus-screenpad-brightness.sh up
    )
    (
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        _kcov_screenpad_brightness_osd_setup "$tmp" "$(cat <<'EOF'
#!/bin/sh
case "$*" in
  *ShowOsd*|*ShowOSD*|*brightnessChanged*|*showProgress*) exit 1 ;;
  *Notifications.Notify*) echo '(uint32 42,)'; exit 0 ;;
  *) exit 1 ;;
esac
EOF
)"
        _kcov_expect_run_env "0" "$kcov_root" spb_lxqt_osd \
            ASUS_SCREENPAD_NODE="$tmp/sp/brightness" \
            ASUS_DESKTOP_FAMILY=lxqt \
            RUN_USER_ROOT="$tmp/bus" PATH="$tmp/mock:$PATH" \
            ./bin/asus-screenpad-brightness.sh up
    )
    (
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        _kcov_screenpad_brightness_osd_setup "$tmp" "$(cat <<'EOF'
#!/bin/sh
case "$*" in
  *ShowOsd*|*ShowOSD*|*brightnessChanged*|*showProgress*) exit 1 ;;
  *Notifications.Notify*) echo '(uint32 42,)'; exit 0 ;;
  *) exit 1 ;;
esac
EOF
)"
        _kcov_expect_run_env "0" "$kcov_root" spb_mate_osd \
            ASUS_SCREENPAD_NODE="$tmp/sp/brightness" \
            ASUS_DESKTOP_FAMILY=mate \
            RUN_USER_ROOT="$tmp/bus" PATH="$tmp/mock:$PATH" \
            ./bin/asus-screenpad-brightness.sh up
    )
}

_run_kcov_screenpad_scenarios() {
    local kcov_root="$1"
    local tmp
    _kcov_expect_run "1" "$kcov_root" sp_no_node ./bin/asus-screenpad-toggle.sh
    (
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        echo 128 > "$tmp/b"; echo 255 > "$tmp/max_brightness"; chmod 666 "$tmp/b"
        _kcov_expect_run_env "0" "$kcov_root" sp_on ASUS_SCREENPAD_NODE="$tmp/b" ./bin/asus-screenpad-toggle.sh
        echo 0 > "$tmp/b"
        _kcov_expect_run_env "0" "$kcov_root" sp_off ASUS_SCREENPAD_NODE="$tmp/b" ./bin/asus-screenpad-toggle.sh
        chmod a-w "$tmp/b"
        _kcov_expect_run_env "1" "$kcov_root" sp_not_writable ASUS_SCREENPAD_NODE="$tmp/b" \
            ./bin/asus-screenpad-toggle.sh
    )
    (
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        mkdir -p "$tmp/sp" "$tmp/state/$(id -u)"
        echo 0 > "$tmp/sp/brightness"
        echo 200 > "$tmp/sp/max_brightness"
        chmod 666 "$tmp/sp/brightness"
        # Saved brightness above max → clamp path in _apply_screenpad_on.
        echo 9999 > "$tmp/state/$(id -u)/screenpad_brightness"
        _kcov_expect_run_env "0" "$kcov_root" sp_restore_clamp \
            ASUS_SCREENPAD_NODE="$tmp/sp/brightness" STATE_DIR="$tmp/state" \
            ./bin/asus-screenpad-toggle.sh
    )
    (
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        mkdir -p "$tmp/sp"
        echo 0 > "$tmp/sp/brightness"; echo 200 > "$tmp/sp/max_brightness"; chmod 666 "$tmp/sp/brightness"
        _kcov_expect_run_env "0" "$kcov_root" sp_max_bright ASUS_SCREENPAD_NODE="$tmp/sp/brightness" ./bin/asus-screenpad-toggle.sh
    )
    (
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        uid="$(id -u)"
        mkdir -p "$tmp/sp" "$tmp/bus/$uid" "$tmp/mock"
        echo 128 > "$tmp/sp/brightness"; chmod 666 "$tmp/sp/brightness"
        _make_fake_loginctl_current_user "$tmp/mock"
        _make_fake_sudo_script "$tmp/mock"
        printf '#!/bin/sh\necho "(uint32 42,)"\n' > "$tmp/mock/gdbus"; chmod +x "$tmp/mock/gdbus"
        _kcov_bind_unix_bus "$tmp/bus/$uid/bus"
        _kcov_expect_run_env "0" "$kcov_root" sp_notify ASUS_SCREENPAD_NODE="$tmp/sp/brightness" \
            RUN_USER_ROOT="$tmp/bus" PATH="$tmp/mock:$PATH" ./bin/asus-screenpad-toggle.sh
    )
    _run_kcov_screenpad_brightness_scenarios "$kcov_root"
    _kcov_expect_run_env "0" "$kcov_root" screenpad_helpers \
        REPO_ROOT="$(pwd)" "$(_kcov_driver screenpad_helpers.sh)"
}
