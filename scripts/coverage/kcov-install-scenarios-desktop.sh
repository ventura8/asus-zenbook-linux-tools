#!/usr/bin/env bash
# Desktop-family control-center kcov scenarios, sourced by kcov-install-scenarios.sh.

declare -A _KCOV_CC_COMMAND_BY_FAMILY
_KCOV_CC_COMMAND_BY_FAMILY[kde]=systemsettings
_KCOV_CC_COMMAND_BY_FAMILY[xfce]=xfce4-settings-manager
_KCOV_CC_COMMAND_BY_FAMILY[lxqt]=lxqt-config
_KCOV_CC_COMMAND_BY_FAMILY[cinnamon]=cinnamon-settings
_KCOV_CC_COMMAND_BY_FAMILY[mate]=mate-control-center
_KCOV_CC_COMMAND_BY_FAMILY[gnome]=gnome-control-center

_run_kcov_cc_desktop_runs() {
    local kcov_root="$1" tmp="$2"
    (
        local iso_tmp cmd desk_iso=""
        iso_tmp=$(mktemp -d)
        trap 'rm -rf "$iso_tmp"; if [ -n "${desk_iso:-}" ]; then rm -rf "$desk_iso"; fi' EXIT
        _setup_isolated_kcov_env "$tmp" "$iso_tmp"
        for cmd in gnome-control-center systemsettings xfce4-settings-manager; do
            _kcov_make_stub "$iso_tmp/$cmd" 'sleep 1; exit 0'
            _kcov_expect_run_env "0" "$kcov_root" "cc_${cmd}" PATH="$iso_tmp:$PATH" \
                RUN_USER_ROOT="$tmp/bus_root" DBUS_BUS_ROOT="$tmp/bus_root" LOGINCTL_STYPE=wayland \
                ASUS_LAUNCH_CHECK_SECS=0.01 ./bin/asus-control-center.sh
            rm -f "$iso_tmp/$cmd"
        done

        mkdir -p "$iso_tmp/apps" "$iso_tmp/empty"
        touch "$iso_tmp/apps/org.gnome.Settings.desktop"
        desk_iso=$(mktemp -d)
        _kcov_isolated_bin_dir "$desk_iso"
        rm -f "$iso_tmp/gnome-control-center" "$iso_tmp/systemsettings" \
            "$iso_tmp/systemsettings5" "$iso_tmp/xfce4-settings-manager" \
            "$iso_tmp/gdbus" "$iso_tmp/gio"
        rm -f "$desk_iso/loginctl" "$desk_iso/sudo" "$desk_iso/id"
        _soft cp -a "$tmp/loginctl" "$tmp/sudo" "$tmp/id" "$desk_iso/"
        _kcov_make_stub "$desk_iso/gdbus" 'exit 1'
        _kcov_make_stub "$desk_iso/gio" 'sleep 1; exit 0'
        _kcov_expect_run_env "0" "$kcov_root" cc_desktop_app PATH="$desk_iso" \
            RUN_USER_ROOT="$tmp/bus_root" DBUS_BUS_ROOT="$tmp/bus_root" DESKTOP_DIR="$iso_tmp/apps" \
            ASUS_LAUNCH_CHECK_SECS=0.01 ./bin/asus-control-center.sh
        _kcov_expect_run_env "1" "$kcov_root" cc_desktop_empty PATH="$desk_iso" \
            RUN_USER_ROOT="$tmp/bus_root" DBUS_BUS_ROOT="$tmp/bus_root" DESKTOP_DIR="$iso_tmp/empty" \
            ./bin/asus-control-center.sh
        _kcov_make_stub "$desk_iso/gio" 'exit 1'
        _kcov_expect_run_env "1" "$kcov_root" cc_desktop_gio_fail PATH="$desk_iso" \
            RUN_USER_ROOT="$tmp/bus_root" DBUS_BUS_ROOT="$tmp/bus_root" DESKTOP_DIR="$iso_tmp/apps" \
            ./bin/asus-control-center.sh
        rm -f "$desk_iso/gnome-control-center" "$desk_iso/gdbus"
        _kcov_make_stub "$desk_iso/gnome-control-center" 'exit 42'
        _kcov_make_stub "$desk_iso/gdbus" 'exit 1'
        _kcov_expect_run_env "1" "$kcov_root" cc_launch_dies PATH="$desk_iso" \
            RUN_USER_ROOT="$tmp/bus_root" DBUS_BUS_ROOT="$tmp/bus_root" \
            ./bin/asus-control-center.sh
    )
}

_run_kcov_cc_family_desktop_scenarios() {
    local kcov_root="$1"
    (
        local tmp uid iso family cmd
        tmp=$(mktemp -d)
        uid="$(id -u)"
        iso=$(mktemp -d)
        trap 'rm -rf "$tmp" "$iso"' EXIT
        _make_fake_loginctl_current_user "$tmp"
        _make_fake_sudo_script "$tmp"
        mkdir -p "$tmp/bus_root/$uid" "$tmp/apps"
        _kcov_bind_unix_bus "$tmp/bus_root/$uid/bus"
        _kcov_make_stub "$tmp/gdbus" 'exit 1'
        touch "$tmp/apps/systemsettings.desktop" \
            "$tmp/apps/org.kde.systemsettings.desktop" \
            "$tmp/apps/xfce4-settings-manager.desktop" \
            "$tmp/apps/lxqt-config.desktop" \
            "$tmp/apps/cinnamon-settings.desktop" \
            "$tmp/apps/mate-control-center.desktop"
        _kcov_make_stub "$tmp/gio"
        _kcov_isolated_bin_dir "$iso" gio gdbus loginctl sudo
        # Copy stubs as files (not through iso symlinks to system binaries).
        rm -f "$iso/loginctl" "$iso/sudo" "$iso/id" "$iso/gdbus" "$iso/gio" \
            "$iso/systemsettings" "$iso/systemsettings5" \
            "$iso/gnome-control-center" "$iso/xfce4-settings-manager" "$iso/lxqt-config"
        _soft cp -a "$tmp/loginctl" "$tmp/sudo" "$tmp/id" "$iso/"
        _kcov_make_stub "$iso/gdbus" 'exit 1'
        _kcov_make_stub "$iso/gio"

        for family in kde xfce lxqt cinnamon mate gnome; do
            cmd="${_KCOV_CC_COMMAND_BY_FAMILY[$family]}"
            _kcov_make_stub "$iso/$cmd" 'sleep 1'
            _kcov_expect_run_env "0" "$kcov_root" "cc_${family}_command" PATH="$iso" \
                RUN_USER_ROOT="$tmp/bus_root" DESKTOP_DIR="$tmp/apps" \
                ASUS_DESKTOP_FAMILY="$family" ASUS_LAUNCH_CHECK_SECS=0.01 \
                ./bin/asus-control-center.sh
            rm -f "$iso/$cmd"
        done

        _kcov_expect_run_env "0" "$kcov_root" cc_lxqt_desktop PATH="$iso" \
            RUN_USER_ROOT="$tmp/bus_root" DESKTOP_DIR="$tmp/apps" \
            ASUS_DESKTOP_FAMILY=lxqt ./bin/asus-control-center.sh
        _kcov_make_stub "$iso/gio" 'exit 1'
        _kcov_expect_run_env "1" "$kcov_root" cc_desktop_launch_failure PATH="$iso" \
            RUN_USER_ROOT="$tmp/bus_root" DESKTOP_DIR="$tmp/apps" \
            ASUS_DESKTOP_FAMILY=mate ./bin/asus-control-center.sh
    )
}
