#!/usr/bin/env bash
# Sourced by distro_install_smoke_desktop.sh — LXQt DESKTOP configure asserts.

_SMOKE_LXQT_ORIG_EXEC="/usr/bin/old-display"

_smoke_seed_lxqt_conf() {
    local home_dir="$1" conf_dir conf
    conf_dir="${home_dir}/.config/lxqt"
    mkdir -p "$conf_dir"
    conf="${conf_dir}/globalkeyshortcuts.conf"
    cat > "$conf" <<EOF
[XF86Display.42]
Comment=Old Display
Enabled=true
Exec=${_SMOKE_LXQT_ORIG_EXEC}

[Keep.1]
Comment=Keep Me
Enabled=true
Exec=/usr/bin/keep
EOF
}

_smoke_write_lxqt_stubs() {
    local mock_bin="$1"
    printf '#!/bin/sh\nexit 0\n' > "$mock_bin/pkill"
    chmod +x "$mock_bin/pkill"
}

_smoke_assert_lxqt_installed() {
    local dest="$1" home_dir="$2" uid="$3"
    local state_dir conf
    state_dir="$dest/var/lib/asus-zenbook-linux-tools/$uid"
    conf="$home_dir/.config/lxqt/globalkeyshortcuts.conf"
    _smoke_assert_family_marker "$state_dir" lxqt
    _smoke_require_file "$conf" "LXQt globalkeyshortcuts.conf missing"
    _smoke_require_grep "asus-display-mode.sh" "$conf" "LXQt XF86Display Exec missing"
    _smoke_require_grep "Meta%2BP" "$conf" "LXQt Meta+P section missing"
    _smoke_require_grep "asus-control-center.sh" "$conf" "LXQt Meta+F12 Exec missing"
    _smoke_require_grep "asus-screenshot.sh" "$conf" "LXQt Meta+Shift+S Exec missing"
    if [ ! -f "$state_dir/orig_lxqt_xf86display" ]; then
        _smoke_require_file "$state_dir/orig_lxqt_xf86display.absent" \
            "LXQt XF86Display backup missing"
    fi
    if [ ! -f "$state_dir/orig_lxqt_meta_p" ]; then
        _smoke_require_file "$state_dir/orig_lxqt_meta_p.absent" \
            "LXQt Meta+P backup missing"
    fi
}

_smoke_assert_lxqt_uninstalled() {
    local dest="$1" home_dir="$2" uid="$3"
    local state_dir conf
    state_dir="$dest/var/lib/asus-zenbook-linux-tools/$uid"
    conf="$home_dir/.config/lxqt/globalkeyshortcuts.conf"
    _smoke_assert_marker_cleared "$state_dir" LXQt
    _smoke_require_file "$conf" "LXQt conf missing after uninstall"
    if grep -Fq "asus-display-mode.sh" "$conf" 2>/dev/null; then
        _smoke_fail "LXQt conf still contains asus-display-mode.sh after uninstall"
    fi
    if grep -Fq "asus-control-center.sh" "$conf" 2>/dev/null; then
        _smoke_fail "LXQt conf still contains asus-control-center.sh after uninstall"
    fi
    if grep -Fq "asus-screenshot.sh" "$conf" 2>/dev/null; then
        _smoke_fail "LXQt conf still contains asus-screenshot.sh after uninstall"
    fi
    _smoke_require_grep "$_SMOKE_LXQT_ORIG_EXEC" "$conf" \
        "LXQt original XF86Display Exec not restored"
    _smoke_require_grep "/usr/bin/keep" "$conf" "LXQt unrelated section was removed"
}
